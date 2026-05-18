#!/bin/bash
# =============================================================================
# /opt/hostmon/mail_investigate.sh
# =============================================================================
# PURPOSE: When Zabbix fires a mail queue alert, run this to find out:
#   - How big is the queue and what type of mail is in it
#   - Which cPanel account / email address is the spam source
#   - Whether queued mail looks legitimate or bulk/spam
#   - Options to freeze, remove, or block the offending account/address
#
# USAGE:
#   bash mail_investigate.sh                    # Full investigation
#   bash mail_investigate.sh --user joe         # Focus on cPanel account
#   bash mail_investigate.sh --slack            # Post findings to Slack
#   bash mail_investigate.sh --action freeze    # Freeze queue for account
#   bash mail_investigate.sh --action remove    # Remove queue for account (with confirm)
#   bash mail_investigate.sh --action block     # Block outbound mail for account
#
# ACTIONS ARE PROMPTED — nothing executes without admin confirmation
# =============================================================================

HOSTMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HOSTMON_DIR}/lib/common.sh"
require_root
require_cmds exim awk grep sort

TARGET_USER=""
POST_SLACK=false
ACTION=""

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --user)   TARGET_USER="$2"; shift ;;
        --slack)  POST_SLACK=true ;;
        --action) ACTION="$2"; shift ;;
    esac
    shift
done

SLACK_BUFFER=""
_sbuf() { SLACK_BUFFER+="$*"$'\n'; }

# =============================================================================
# HELPERS
# =============================================================================

# Ask admin for confirmation before any destructive action
_confirm() {
    local prompt="$1"
    echo ""
    echo -e "${C_YELLOW}  ⚠  ${prompt}${C_RESET}"
    echo -ne "  Type YES to confirm: "
    read -r answer
    [ "$answer" = "YES" ]
}

# Map an email sender domain/user back to a cPanel account
_email_to_cpanel() {
    local email="$1"
    local domain="${email#*@}"
    local user="${email%@*}"

    # Check /etc/userdomains (cPanel domain→user map)
    if [ -f /etc/userdomains ]; then
        local cpanel_user
        cpanel_user=$(grep -i "^${domain}:" /etc/userdomains 2>/dev/null | \
                      awk '{print $2}' | head -1)
        [ -n "$cpanel_user" ] && echo "$cpanel_user" && return
    fi

    # Check if local system user matches
    id "$user" &>/dev/null && echo "$user" && return

    echo "unknown"
}

# =============================================================================
# SECTION 1 — Queue overview snapshot
# =============================================================================
section_queue_overview() {
    section "1. MAIL QUEUE OVERVIEW"
    echo ""

    _sbuf "=== MAIL QUEUE OVERVIEW ==="

    # Total queue size
    local total_count
    total_count=$(exim -bpc 2>/dev/null || echo "0")

    local color="$C_GREEN"
    [ "$total_count" -gt 500  ] && color="$C_YELLOW"
    [ "$total_count" -gt 2000 ] && color="$C_RED"

    echo -e "  ${C_BOLD}Total messages in queue:${C_RESET} ${color}${total_count}${C_RESET}"
    _sbuf "Queue total: $total_count messages"

    # Queue age breakdown — frozen vs active vs deferred
    local frozen_count active_count deferred_count
    frozen_count=$(exim -bp 2>/dev/null | grep -c "frozen" || echo 0)
    deferred_count=$(exim -bp 2>/dev/null | \
                     grep -v frozen | grep -c "^\s*[0-9]" || echo 0)
    active_count=$((total_count - frozen_count - deferred_count))
    [ "$active_count" -lt 0 ] && active_count=0

    printf "\n  %-25s %s\n" "Active (queued to send):" "$active_count"
    printf   "  %-25s %s\n" "Deferred (retry later):"  "$deferred_count"
    printf   "  %-25s %s\n" "Frozen (stuck/failed):"   "$frozen_count"

    _sbuf "Active: $active_count | Deferred: $deferred_count | Frozen: $frozen_count"

    # Queue disk usage
    echo ""
    local queue_size
    queue_size=$(du -sh /var/spool/exim/input 2>/dev/null | awk '{print $1}')
    log_info "Queue disk usage: ${queue_size:-unknown}"
    _sbuf "Queue disk: $queue_size"

    # Alert if queue is dangerously large
    if [ "$total_count" -gt 5000 ]; then
        log_crit "Queue exceeds 5000 — server may be blacklisted or under active spam attack"
        _sbuf "CRITICAL: Queue > 5000 — blacklist risk"
    elif [ "$total_count" -gt 1000 ]; then
        log_warn "Queue exceeds 1000 — investigate spam source immediately"
        _sbuf "WARNING: Queue > 1000"
    elif [ "$total_count" -gt 200 ]; then
        log_warn "Queue is elevated (${total_count}) — monitor closely"
    else
        log_ok "Queue size is within normal range."
    fi
}

# =============================================================================
# SECTION 2 — Top senders (who is filling the queue)
# =============================================================================
section_top_senders() {
    section "2. TOP SENDERS IN QUEUE"
    echo ""

    _sbuf ""
    _sbuf "=== TOP SENDERS ==="

    printf "${C_BOLD}%-6s %-45s %-20s %-s${C_RESET}\n" \
        "COUNT" "SENDER ADDRESS" "cPANEL ACCOUNT" "VERDICT"
    echo "──────────────────────────────────────────────────────────────────────"

    # Extract all sender addresses from queue
    local queue_data
    queue_data=$(exim -bp 2>/dev/null)

    declare -A sender_count
    while IFS= read -r line; do
        # Lines with sender look like:  1d  2.3K abc123def <sender@domain.com>
        if echo "$line" | grep -qE '<[^>]+@[^>]+>'; then
            local sender
            sender=$(echo "$line" | grep -oE '<[^>]+>' | tr -d '<>' | head -1)
            [ -n "$sender" ] && sender_count["$sender"]=$(( ${sender_count["$sender"]:-0} + 1 ))
        fi
    done <<< "$queue_data"

    local rank=0
    for sender in $(for k in "${!sender_count[@]}"; do
                        echo "${sender_count[$k]} $k"
                    done | sort -rn | awk '{print $2}' | \
                    { [ -n "$TARGET_USER" ] && \
                      while IFS= read -r s; do
                          cpanel=$(_email_to_cpanel "$s")
                          [ "$cpanel" = "$TARGET_USER" ] && echo "$s"
                      done || cat; }); do

        local count="${sender_count[$sender]}"
        local cpanel_account
        cpanel_account=$(_email_to_cpanel "$sender")

        # Determine verdict
        local verdict color
        if [ "$count" -ge 500 ]; then
            verdict="SPAM — suspend immediately"; color="$C_RED"
        elif [ "$count" -ge 100 ]; then
            verdict="Likely spam — investigate";  color="$C_YELLOW"
        elif [ "$count" -ge 20 ]; then
            verdict="Elevated — monitor";          color="$C_CYAN"
        else
            verdict="Normal";                      color="$C_RESET"
        fi

        printf "${color}%-6s %-45s %-20s %-s${C_RESET}\n" \
            "$count" "$sender" "$cpanel_account" "$verdict"

        _sbuf "$(printf '%-6s %-45s %-20s %-s' \
            "$count" "$sender" "$cpanel_account" "$verdict")"

        rank=$((rank + 1))
        [ "$rank" -ge "$TOP_ACCOUNTS_COUNT" ] && break
    done
}

# =============================================================================
# SECTION 3 — Top recipient domains (where is spam going)
# =============================================================================
section_top_recipients() {
    section "3. TOP RECIPIENT DOMAINS"
    echo ""

    _sbuf ""
    _sbuf "=== TOP RECIPIENTS ==="

    log_info "Recipient domains with most queued messages:"
    echo ""

    # Parse recipient lines from exim -bp (lines with @domain after sender block)
    exim -bp 2>/dev/null | \
        grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | \
        awk -F@ '{print $2}' | \
        sort | uniq -c | sort -rn | head -20 | \
        while read -r count domain; do
            local flag=""
            # Flag if sending to same domain in bulk (possible targeted attack)
            [ "$count" -ge 100 ] && flag=" ◄ BULK TARGET"
            printf "  %-6s %s%s\n" "$count" "$domain" "$flag"
            _sbuf "  RCPT: $count -> $domain$flag"
        done
}

# =============================================================================
# SECTION 4 — Sample message inspection (is it spam?)
# =============================================================================
section_sample_inspection() {
    section "4. SAMPLE MESSAGE INSPECTION"
    echo ""

    _sbuf ""
    _sbuf "=== SAMPLE MESSAGES ==="

    log_info "Sampling queued message headers to classify content..."
    echo ""

    local spam_indicators=0
    local sample_count=0

    # Get up to 10 message IDs from the queue
    local msg_ids
    msg_ids=$(exim -bp 2>/dev/null | awk '/^\s*[0-9]+[smhdw]/{print $3}' | \
              head -10)

    for msg_id in $msg_ids; do
        [ -z "$msg_id" ] && continue
        sample_count=$((sample_count + 1))

        local msg_header
        msg_header=$(exim -Mvh "$msg_id" 2>/dev/null | head -40)

        local sender subject from_header
        sender=$(echo "$msg_header"     | grep -i "^return-path:" | head -1)
        from_header=$(echo "$msg_header" | grep -i "^from:"       | head -1)
        subject=$(echo "$msg_header"    | grep -i "^subject:"     | head -1)

        echo -e "  ${C_BOLD}Message: ${msg_id}${C_RESET}"
        echo    "  $sender"
        echo    "  $from_header"
        echo    "  $subject"

        # Spam heuristics
        local flags=()

        # Check for missing/forged headers
        echo "$msg_header" | grep -qi "^x-spam"         && flags+=("X-Spam header present")
        echo "$msg_header" | grep -qi "^x-php-originating-script" && \
            flags+=("PHP-originated — check script path")
        ! echo "$msg_header" | grep -qi "^message-id:"  && flags+=("Missing Message-ID")
        ! echo "$msg_header" | grep -qi "^date:"        && flags+=("Missing Date header")
        echo "$subject" | grep -qiE 'viagra|casino|lottery|winner|prize|click here|urgent|verify your|account suspended|bitcoin|crypto' && \
            flags+=("Spam keyword in subject")

        # PHP script path (cPanel logs it)
        local php_script
        php_script=$(echo "$msg_header" | grep -i "x-php-originating-script" | \
                     grep -oE '/home/[^:]+' | head -1)
        [ -n "$php_script" ] && flags+=("Sent via PHP: $php_script")

        if [ ${#flags[@]} -gt 0 ]; then
            spam_indicators=$((spam_indicators + 1))
            for flag in "${flags[@]}"; do
                log_warn "    ◄ $flag"
                _sbuf "  SPAM FLAG [$msg_id]: $flag"
            done
        else
            log_ok "    No obvious spam indicators."
        fi

        echo ""
    done

    echo "──────────────────────────────────────────────────────────────"
    log_info "Sampled ${sample_count} messages | Spam indicators: ${spam_indicators}/${sample_count}"
    _sbuf "Sampled: $sample_count | Spam flags: $spam_indicators"
}

# =============================================================================
# SECTION 5 — PHP script origination (which script is sending mail)
# =============================================================================
section_php_origination() {
    section "5. PHP MAIL SCRIPT ORIGINATION"
    echo ""

    _sbuf ""
    _sbuf "=== PHP ORIGINATING SCRIPTS ==="

    log_info "Checking which PHP scripts are generating queued mail..."
    echo ""

    # Parse X-PHP-Originating-Script headers from all queued messages
    declare -A script_count
    local msg_ids
    msg_ids=$(exim -bp 2>/dev/null | awk '/^\s*[0-9]+[smhdw]/{print $3}' | head -200)

    for msg_id in $msg_ids; do
        [ -z "$msg_id" ] && continue
        local script
        script=$(exim -Mvh "$msg_id" 2>/dev/null | \
                 grep -i "x-php-originating-script" | \
                 grep -oE '/home/[^ ]+' | head -1)
        [ -n "$script" ] && \
            script_count["$script"]=$(( ${script_count["$script"]:-0} + 1 ))
    done

    if [ ${#script_count[@]} -eq 0 ]; then
        log_ok "No PHP originating script headers found in sampled messages."
        log_dim "(Mail may be sent via SMTP auth or sendmail directly)"
        _sbuf "No PHP originating scripts detected in sample."
        return
    fi

    printf "${C_BOLD}%-8s %-50s %-s${C_RESET}\n" "COUNT" "SCRIPT PATH" "OWNER"
    echo "──────────────────────────────────────────────────────────────────────"

    for script in $(for k in "${!script_count[@]}"; do
                        echo "${script_count[$k]} $k"
                    done | sort -rn | awk '{print $2}'); do

        local count="${script_count[$script]}"
        local owner
        owner=$(stat -c '%U' "$script" 2>/dev/null || echo "unknown")
        local color="$C_RESET"
        [ "$count" -ge 50 ] && color="$C_RED"
        [ "$count" -ge 10 ] && [ "$count" -lt 50 ] && color="$C_YELLOW"

        printf "${color}%-8s %-50s %-s${C_RESET}\n" "$count" "$script" "$owner"
        _sbuf "PHP SCRIPT: $count msgs from $script (owner: $owner)"

        # Try to determine if script is a known CMS mailer or suspicious
        case "$script" in
            */wp-includes/*|*/wp-content/*)
                log_dim "    → WordPress mailer (check for spam plugins or compromised theme)"
                ;;
            */components/com_*/|*/joomla/*)
                log_dim "    → Joomla component (check for vulnerable extension)"
                ;;
            */tmp/*|*/cache/*)
                log_crit "    → Script in tmp/cache dir — HIGHLY SUSPICIOUS (webshell/dropper)"
                _sbuf "  CRITICAL: script in /tmp or /cache — likely malware"
                ;;
            */public_html/*)
                log_dim "    → In public_html — review script for mail() abuse"
                ;;
        esac
    done
}

# =============================================================================
# SECTION 6 — SMTP auth abuse (brute-forced or compromised credentials)
# =============================================================================
section_smtp_auth_abuse() {
    section "6. SMTP AUTH ABUSE DETECTION"
    echo ""

    _sbuf ""
    _sbuf "=== SMTP AUTH ==="

    local exim_main_log="/var/log/exim_mainlog"
    [ ! -f "$exim_main_log" ] && exim_main_log="/var/log/exim/mainlog"

    if [ ! -f "$exim_main_log" ]; then
        log_warn "Exim main log not found. Checked: /var/log/exim_mainlog"
        return
    fi

    # Authenticated senders in last hour
    log_info "Top SMTP authenticated senders (last 1000 log lines):"
    echo ""

    tail -1000 "$exim_main_log" 2>/dev/null | \
        grep "A=dovecot_plain\|A=plain\|A=login\|authenticated" | \
        grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | \
        sort | uniq -c | sort -rn | head -15 | \
        while read -r count email; do
            local cpanel_account
            cpanel_account=$(_email_to_cpanel "$email")
            local flag=""
            local color="$C_RESET"
            [ "$count" -ge 200 ] && flag=" ◄ CREDENTIAL ABUSE" && color="$C_RED"
            [ "$count" -ge 50  ] && flag=" ◄ HIGH VOLUME"       && color="$C_YELLOW"
            printf "${color}  %-6s %-40s %-20s%s${C_RESET}\n" \
                "$count" "$email" "$cpanel_account" "$flag"
            _sbuf "  SMTP AUTH: $count $email ($cpanel_account)$flag"
        done

    # Failed auth attempts (credential stuffing / brute force)
    echo ""
    log_info "Recent SMTP authentication failures (last 1000 lines):"
    local auth_fails
    auth_fails=$(tail -1000 "$exim_main_log" 2>/dev/null | \
                 grep -c "authenticator failed\|535 " || echo 0)

    if [ "$auth_fails" -gt 50 ]; then
        log_crit "SMTP auth failures: ${auth_fails} — possible credential stuffing attack"
        _sbuf "SMTP AUTH FAILURES: $auth_fails — brute force risk"
    elif [ "$auth_fails" -gt 10 ]; then
        log_warn "SMTP auth failures: ${auth_fails}"
        _sbuf "SMTP auth failures: $auth_fails"
    else
        log_ok "SMTP auth failures: ${auth_fails} (normal)"
    fi

    # IPs with most auth failures
    echo ""
    log_info "IPs with most SMTP auth failures:"
    tail -1000 "$exim_main_log" 2>/dev/null | \
        grep "authenticator failed\|535 " | \
        grep -oE '\[([0-9]{1,3}\.){3}[0-9]{1,3}\]' | tr -d '[]' | \
        sort | uniq -c | sort -rn | head -10 | \
        while read -r count ip; do
            printf "  %-6s %s\n" "$count" "$ip"
        done
}

# =============================================================================
# SECTION 7 — Blacklist check for server IP
# =============================================================================
section_blacklist_check() {
    section "7. SERVER IP BLACKLIST CHECK"
    echo ""

    _sbuf ""
    _sbuf "=== BLACKLIST CHECK ==="

    # Get main outbound IP
    local server_ip
    server_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
                hostname -I | awk '{print $1}')

    log_info "Checking server IP: ${server_ip}"
    echo ""

    if [ -z "$server_ip" ]; then
        log_warn "Could not determine server IP."
        return
    fi

    # Reverse the IP for DNSBL lookups
    local reversed_ip
    reversed_ip=$(echo "$server_ip" | awk -F. '{print $4"."$3"."$2"."$1}')

    # Common DNSBLs
    local -a dnsbls=(
        "zen.spamhaus.org"
        "bl.spamcop.net"
        "dnsbl.sorbs.net"
        "b.barracudacentral.org"
        "dnsbl-1.uceprotect.net"
        "cbl.abuseat.org"
        "psbl.surriel.com"
    )

    local listed_count=0
    printf "${C_BOLD}  %-40s %s${C_RESET}\n" "DNSBL" "STATUS"
    echo "  ──────────────────────────────────────────────────"

    for dnsbl in "${dnsbls[@]}"; do
        local lookup="${reversed_ip}.${dnsbl}"
        local result
        result=$(host -t A "$lookup" 2>/dev/null | grep "has address")

        if [ -n "$result" ]; then
            printf "  ${C_RED}%-40s LISTED ◄${C_RESET}\n" "$dnsbl"
            _sbuf "  BLACKLISTED on: $dnsbl"
            listed_count=$((listed_count + 1))
        else
            printf "  ${C_GREEN}%-40s clean${C_RESET}\n" "$dnsbl"
        fi
    done

    echo ""
    if [ "$listed_count" -gt 0 ]; then
        log_crit "Server IP is listed on ${listed_count} DNSBL(s) — delist immediately"
        log_warn "  Spamhaus delist : https://www.spamhaus.org/lookup/"
        log_warn "  SpamCop delist  : https://www.spamcop.net/bl.shtml"
        log_warn "  Barracuda delist: https://www.barracudacentral.org/rbl/removal-request"
        _sbuf "LISTED ON $listed_count DNSBLS — delist urgently"
    else
        log_ok "Server IP is not listed on any checked DNSBL."
        _sbuf "IP clean on all checked DNSBLs."
    fi
}

# =============================================================================
# SECTION 8 — ACTION MENU (all actions require confirmation)
# =============================================================================
section_action_menu() {
    section "8. ADMIN ACTION MENU"
    echo ""

    if [ -z "$TARGET_USER" ] && [ -z "$ACTION" ]; then
        log_dim "Run with --user <account> --action <action> to take action."
        log_dim "Available actions:"
        echo ""
        printf "  ${C_BOLD}%-20s %-s${C_RESET}\n" "ACTION" "WHAT IT DOES"
        echo "  ──────────────────────────────────────────────────"
        printf "  %-20s %-s\n" "freeze"    "Freeze all queued messages for account (stops sending)"
        printf "  %-20s %-s\n" "unfreeze"  "Unfreeze messages (resume sending)"
        printf "  %-20s %-s\n" "remove"    "DELETE all queued messages for account (irreversible)"
        printf "  %-20s %-s\n" "block"     "Block outbound email for account via Exim ACL / CSF"
        printf "  %-20s %-s\n" "suspend"   "Suspend cPanel account entirely (WHM API)"
        printf "  %-20s %-s\n" "report"    "Show full message list for account"
        echo ""
        log_dim "Example: bash mail_investigate.sh --user johndoe --action freeze"
        return
    fi

    [ -z "$TARGET_USER" ] && {
        log_warn "Specify --user <account> to perform an action."
        return
    }

    log_info "Target account : ${TARGET_USER}"
    log_info "Action         : ${ACTION}"

    # Count messages for this account
    local account_msg_count
    account_msg_count=$(exim -bp 2>/dev/null | \
        grep -A2 "" | \
        awk -v user="$TARGET_USER" '
            /<[^>]*@/ {
                split($0, a, "<"); split(a[2], b, "@");
                split(b[2], c, ">");
                domain = c[1]
            }
            /[0-9a-zA-Z]{16}/ { msgid = $3 }
        ' | wc -l || echo 0)

    # Simpler count via grep on domain
    local user_domain
    user_domain=$(grep -i "^[^:]*:.*${TARGET_USER}$" /etc/userdomains 2>/dev/null | \
                  awk '{print $1}' | tr -d ':' | head -1)

    echo ""

    case "$ACTION" in

        # ---------------------------------------------------------------
        freeze)
            log_warn "Will FREEZE all queued messages for: ${TARGET_USER}"
            [ -n "$user_domain" ] && \
                log_dim "  Domain: $user_domain"

            if _confirm "Freeze all outgoing mail for ${TARGET_USER}?"; then
                local frozen=0
                for msg_id in $(exim -bp 2>/dev/null | \
                    awk '/^\s*[0-9]+[smhdw]/{print $3}'); do
                    local sender
                    sender=$(exim -Mvh "$msg_id" 2>/dev/null | \
                             grep -i "^return-path:" | \
                             grep -i "@${user_domain}" | head -1)
                    if [ -n "$sender" ] || \
                       exim -Mvh "$msg_id" 2>/dev/null | \
                           grep -qi "${TARGET_USER}"; then
                        exim -Mf "$msg_id" 2>/dev/null && \
                            frozen=$((frozen + 1))
                    fi
                done
                log_ok "Frozen ${frozen} messages for ${TARGET_USER}."
                write_log "mail_investigate" \
                    "ACTION: Froze $frozen messages for $TARGET_USER"
            else
                log_info "Action cancelled."
            fi
            ;;

        # ---------------------------------------------------------------
        unfreeze)
            log_info "Will UNFREEZE queued messages for: ${TARGET_USER}"
            if _confirm "Unfreeze and resume sending for ${TARGET_USER}?"; then
                local thawed=0
                for msg_id in $(exim -bp 2>/dev/null | grep frozen | \
                    awk '{print $3}'); do
                    exim -Mvh "$msg_id" 2>/dev/null | \
                        grep -qi "${TARGET_USER}" && {
                        exim -Mt "$msg_id" 2>/dev/null && \
                            thawed=$((thawed + 1))
                    }
                done
                log_ok "Unfrozen ${thawed} messages for ${TARGET_USER}."
                write_log "mail_investigate" \
                    "ACTION: Unfroze $thawed messages for $TARGET_USER"
            else
                log_info "Action cancelled."
            fi
            ;;

        # ---------------------------------------------------------------
        remove)
            log_crit "Will PERMANENTLY DELETE all queued mail for: ${TARGET_USER}"
            log_crit "THIS CANNOT BE UNDONE."
            if _confirm "PERMANENTLY DELETE queued mail for ${TARGET_USER}?"; then
                local removed=0
                for msg_id in $(exim -bp 2>/dev/null | \
                    awk '/^\s*[0-9]+[smhdw]/{print $3}'); do
                    exim -Mvh "$msg_id" 2>/dev/null | \
                        grep -qi "${TARGET_USER}" && {
                        exim -Mrm "$msg_id" 2>/dev/null && \
                            removed=$((removed + 1))
                    }
                done
                log_ok "Removed ${removed} messages for ${TARGET_USER}."
                write_log "mail_investigate" \
                    "ACTION: Removed $removed messages for $TARGET_USER"
            else
                log_info "Action cancelled."
            fi
            ;;

        # ---------------------------------------------------------------
        block)
            echo ""
            log_warn "Block options for ${TARGET_USER}:"
            echo ""
            printf "  ${C_BOLD}[1]${C_RESET} Block via Exim sender ACL (blocks SMTP outbound only)\n"
            printf "  ${C_BOLD}[2]${C_RESET} Block via CSF (blocks all outbound port 25/465/587)\n"
            printf "  ${C_BOLD}[3]${C_RESET} Disable cPanel email routing entirely (WHM API)\n"
            printf "  ${C_BOLD}[4]${C_RESET} Cancel\n"
            echo ""
            echo -ne "  Choose [1-4]: "
            read -r block_choice

            case "$block_choice" in
                1)
                    log_info "Adding ${TARGET_USER} to Exim sender block list..."
                    if _confirm "Add to /etc/blockedsenders (Exim deny list)?"; then
                        echo "*@${user_domain}" >> /etc/blockedsenders
                        # Reload Exim
                        /scripts/restartsrv_exim &>/dev/null || \
                            service exim restart &>/dev/null
                        log_ok "Domain ${user_domain} added to /etc/blockedsenders"
                        log_dim "  To remove: edit /etc/blockedsenders and restart Exim"
                        write_log "mail_investigate" \
                            "ACTION: Blocked $user_domain in Exim sender ACL"
                    fi
                    ;;
                2)
                    log_info "Blocking outbound port 25/465/587 for ${TARGET_USER} via CSF..."
                    if command -v csf &>/dev/null; then
                        if _confirm "Block SMTP ports for UID of ${TARGET_USER}?"; then
                            local uid
                            uid=$(id -u "$TARGET_USER" 2>/dev/null)
                            if [ -n "$uid" ]; then
                                # Add UID-based outbound block in CSF
                                echo "SMTP_BLOCK_UID = ${uid}" >> \
                                    /etc/csf/csf.conf
                                csf -r &>/dev/null
                                log_ok "SMTP ports blocked for UID ${uid} (${TARGET_USER}) via CSF"
                                write_log "mail_investigate" \
                                    "ACTION: CSF SMTP block for UID $uid ($TARGET_USER)"
                            else
                                log_warn "Could not determine UID for ${TARGET_USER}"
                            fi
                        fi
                    else
                        log_warn "CSF not found. Use --action block with WHM or Exim instead."
                    fi
                    ;;
                3)
                    log_info "Disabling email routing for ${TARGET_USER} via WHM API..."
                    if _confirm "Disable email routing for ${TARGET_USER}?"; then
                        local api_result
                        api_result=$(whm_api "disableemaildomains" \
                                     "domain=${user_domain}")
                        if echo "$api_result" | grep -q '"status":1'; then
                            log_ok "Email routing disabled for ${user_domain} via WHM API"
                            write_log "mail_investigate" \
                                "ACTION: WHM email routing disabled for $TARGET_USER"
                        else
                            log_warn "WHM API call may have failed — check manually in WHM"
                            log_dim "  API response: $(echo "$api_result" | head -c 200)"
                        fi
                    fi
                    ;;
                4)
                    log_info "Block action cancelled."
                    ;;
            esac
            ;;

        # ---------------------------------------------------------------
        suspend)
            log_crit "Will SUSPEND cPanel account: ${TARGET_USER}"
            log_warn "This disables the entire account, not just email."
            if _confirm "SUSPEND account ${TARGET_USER} via WHM?"; then
                local api_result
                api_result=$(whm_api "suspendacct" \
                             "user=${TARGET_USER}&reason=Spam+investigation")
                if echo "$api_result" | grep -q '"status":1\|suspended'; then
                    log_ok "Account ${TARGET_USER} suspended via WHM API."
                    write_log "mail_investigate" \
                        "ACTION: Suspended account $TARGET_USER via WHM"
                else
                    log_warn "WHM API response unclear — verify in WHM manually"
                    log_dim "$(echo "$api_result" | head -c 200)"
                fi
            else
                log_info "Suspend cancelled."
            fi
            ;;

        # ---------------------------------------------------------------
        report)
            section "FULL QUEUE LISTING — ${TARGET_USER}"
            echo ""
            exim -bp 2>/dev/null | grep -A3 "${TARGET_USER}\|${user_domain}" | \
                head -100
            ;;

        *)
            log_warn "Unknown action: ${ACTION}"
            log_dim "Valid: freeze | unfreeze | remove | block | suspend | report"
            ;;
    esac
}

# =============================================================================
# SECTION 9 — Recommendations
# =============================================================================
section_recommendations() {
    section "9. RECOMMENDATIONS"
    echo ""

    _sbuf ""
    _sbuf "=== RECOMMENDATIONS ==="

    echo -e "  ${C_BOLD}Immediate Actions (if spam detected):${C_RESET}"
    echo ""
    printf "  ${C_CYAN}%-5s${C_RESET} %-s\n" "1." \
        "Identify top sender with --action report, freeze with --action freeze"
    printf "  ${C_CYAN}%-5s${C_RESET} %-s\n" "2." \
        "If PHP script found: delete/quarantine the script, change account password"
    printf "  ${C_CYAN}%-5s${C_RESET} %-s\n" "3." \
        "If SMTP credential abuse: reset email password immediately via cPanel"
    printf "  ${C_CYAN}%-5s${C_RESET} %-s\n" "4." \
        "Remove spam from queue: --action remove (after freezing, confirm queue is spam)"
    printf "  ${C_CYAN}%-5s${C_RESET} %-s\n" "5." \
        "If IP blacklisted: delist AFTER source is stopped, not before"

    echo ""
    echo -e "  ${C_BOLD}Preventive Hardening (Exim / cPanel):${C_RESET}"
    echo ""
    printf "  ${C_DIM}%-5s${C_RESET} %-s\n" "•" \
        "WHM → Exim Config → Set hourly outbound relay limit per domain (e.g. 300/hr)"
    printf "  ${C_DIM}%-5s${C_RESET} %-s\n" "•" \
        "WHM → Exim Config → Enable 'Count mailman deliveries against sender' limits"
    printf "  ${C_DIM}%-5s${C_RESET} %-s\n" "•" \
        "WHM → Exim Config → Enable 'Require HELO before MAIL' + 'Require valid HELO'"
    printf "  ${C_DIM}%-5s${C_RESET} %-s\n" "•" \
        "CSF: Set SMTP_BLOCK=1 to prevent non-Exim SMTP outbound from user processes"
    printf "  ${C_DIM}%-5s${C_RESET} %-s\n" "•" \
        "CSF: Set LF_SCRIPT_ALERT=1 to alert when a script sends >LF_SCRIPT_LIMIT mails"
    printf "  ${C_DIM}%-5s${C_RESET} %-s\n" "•" \
        "Imunify360: Enable proactive defense to block webshell/dropper execution"
    printf "  ${C_DIM}%-5s${C_RESET} %-s\n" "•" \
        "Enable SPF, DKIM, and DMARC for all hosted domains"
    printf "  ${C_DIM}%-5s${C_RESET} %-s\n" "•" \
        "Consider Mailchannels or outbound relay filtering for high-volume shared servers"

    echo ""
    echo -e "  ${C_BOLD}Useful one-liners (run as root):${C_RESET}"
    echo ""
    echo -e "  ${C_DIM}# Count queue${C_RESET}"
    echo    "  exim -bpc"
    echo ""
    echo -e "  ${C_DIM}# View full queue${C_RESET}"
    echo    "  exim -bp"
    echo ""
    echo -e "  ${C_DIM}# Flush/retry all deferred messages${C_RESET}"
    echo    "  exim -qff"
    echo ""
    echo -e "  ${C_DIM}# Remove ALL frozen messages (use with care)${C_RESET}"
    echo    "  exiqgrep -z -i | xargs exim -Mrm"
    echo ""
    echo -e "  ${C_DIM}# Remove all messages from a specific sender${C_RESET}"
    echo    "  exiqgrep -f 'user@domain.com' -i | xargs exim -Mrm"
    echo ""
    echo -e "  ${C_DIM}# View a specific message header${C_RESET}"
    echo    "  exim -Mvh <message-id>"
    echo ""
    echo -e "  ${C_DIM}# View message body${C_RESET}"
    echo    "  exim -Mvb <message-id>"
    echo ""
    echo -e "  ${C_DIM}# Test if IP is in Spamhaus${C_RESET}"
    echo    "  host <reversed-ip>.zen.spamhaus.org"

    _sbuf "Recommendations listed above."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    header "MAIL QUEUE INVESTIGATION REPORT"
    write_log "mail_investigate" "Mail investigation started"

    [ -n "$TARGET_USER" ] && log_info "Account filter: ${TARGET_USER}"

    section_queue_overview
    section_top_senders
    section_top_recipients
    section_sample_inspection
    section_php_origination
    section_smtp_auth_abuse
    section_blacklist_check

    # Only show action menu if --action or if no filter (show help)
    if [ -n "$ACTION" ] || [ -z "$TARGET_USER" ]; then
        section_action_menu
    fi

    section_recommendations

    echo ""
    section "INVESTIGATION COMPLETE"
    log_info "Log: ${LOG_DIR}/mail_investigate.log"
    write_log "mail_investigate" "Mail investigation complete"

    if [ "$POST_SLACK" = true ]; then
        slack_post "Mail Queue Investigation" "$SLACK_BUFFER"
        log_info "Findings posted to Slack."
    else
        log_dim "Tip: run with --slack to post findings to Slack"
    fi
}

main "$@"
