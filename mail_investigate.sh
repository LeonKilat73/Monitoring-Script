#!/bin/bash
# =============================================================================
# mail_investigate.sh — Self-contained Mail Queue Investigation
# Drop anywhere, run as root. No external dependencies.
#
# PURPOSE: When Zabbix fires a mail queue alert, find out:
#   - Queue size, frozen vs deferred vs active breakdown
#   - Which cPanel account / email address is the spam source
#   - Which PHP script is originating the mail
#   - SMTP credential abuse detection
#   - Server IP blacklist check
#   - Actions: freeze, unfreeze, remove, block, suspend (all require confirmation)
#
# USAGE:
#   bash mail_investigate.sh                          # Full report
#   bash mail_investigate.sh --user johndoe           # Focus on one account
#   bash mail_investigate.sh --user johndoe --action freeze
#   bash mail_investigate.sh --user johndoe --action remove
#   bash mail_investigate.sh --user johndoe --action block
#   bash mail_investigate.sh --user johndoe --action suspend
#   bash mail_investigate.sh --user johndoe --action report
# =============================================================================

TARGET_USER=""
ACTION=""
TOP_COUNT=15

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --user)   TARGET_USER="$2"; shift ;;
        --action) ACTION="$2";      shift ;;
        --top)    TOP_COUNT="$2";   shift ;;
    esac
    shift
done

# --- Colors
R='\033[0;31m'; Y='\033[1;33m'; G='\033[0;32m'
C='\033[0;36m'; B='\033[1m';    D='\033[2m'; N='\033[0m'

# --- Root check
if [ "$EUID" -ne 0 ]; then
    echo "Run as root." >&2
    exit 1
fi

sep()  { echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${N}"; }
hdr()  { echo ""; sep; echo -e "${B}  $*${N}"; sep; }
info() { echo -e "  ${C}•${N} $*"; }
warn() { echo -e "  ${Y}▲${N} $*"; }
crit() { echo -e "  ${R}✖${N} $*"; }
ok()   { echo -e "  ${G}✔${N} $*"; }

# Confirm prompt — requires typing YES
_confirm() {
    echo ""
    echo -e "  ${Y}⚠  $1${N}"
    echo -ne "  Type YES to confirm: "
    read -r answer
    [ "$answer" = "YES" ]
}

# Map email address to cPanel account via /etc/userdomains
_email_to_cpanel() {
    local email="$1"
    local domain="${email#*@}"
    local user="${email%@*}"
    if [ -f /etc/userdomains ]; then
        local found
        found=$(grep -i "^${domain}:" /etc/userdomains 2>/dev/null | \
                awk '{print $2}' | head -1)
        [ -n "$found" ] && echo "$found" && return
    fi
    id "$user" &>/dev/null && echo "$user" && return
    echo "unknown"
}

# Get domain for a cPanel user
_user_to_domain() {
    local user="$1"
    grep -i ":.*${user}$" /etc/userdomains 2>/dev/null | \
        awk -F: '{print $1}' | head -1 | tr -d ' '
}

HOSTNAME=$(hostname -f 2>/dev/null || hostname)

echo ""
echo -e "${B}╔══════════════════════════════════════════════════════════════╗${N}"
echo -e "${B}  MAIL QUEUE INVESTIGATION — ${HOSTNAME}${N}"
echo -e "${D}  $(date '+%Y-%m-%d %H:%M:%S')${N}"
[ -n "$TARGET_USER" ] && echo -e "${D}  Account filter: ${TARGET_USER}${N}"
[ -n "$ACTION"      ] && echo -e "${D}  Action: ${ACTION}${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════════╝${N}"

# Exim check — bail early with helpful message if not found
if ! command -v exim &>/dev/null; then
    echo ""
    crit "Exim not found in PATH. Is this a cPanel/Exim server?"
    echo ""
    exit 1
fi

# =============================================================================
# SECTION 1 — Queue overview
# =============================================================================
hdr "1. MAIL QUEUE OVERVIEW"
echo ""

TOTAL_COUNT=$(exim -bpc 2>/dev/null || echo "0")
QUEUE_DISK=$(du -sh /var/spool/exim/input 2>/dev/null | awk '{print $1}')

# Color the total count
QCLR=$G
[ "${TOTAL_COUNT:-0}" -gt 200  ] && QCLR=$Y
[ "${TOTAL_COUNT:-0}" -gt 1000 ] && QCLR=$R

echo -e "  ${B}Total messages in queue :${N} ${QCLR}${TOTAL_COUNT}${N}"
echo -e "  ${B}Queue disk usage        :${N} ${QUEUE_DISK:-unknown}"
echo ""

# Breakdown: frozen / deferred / active
FROZEN_COUNT=$(exim -bp 2>/dev/null | grep -c "frozen" || echo 0)
DEFERRED_COUNT=$(exim -bp 2>/dev/null | grep -v frozen | \
                 awk '/^\s+[0-9]/' | wc -l || echo 0)
ACTIVE_COUNT=$(( TOTAL_COUNT - FROZEN_COUNT - DEFERRED_COUNT ))
[ "$ACTIVE_COUNT" -lt 0 ] && ACTIVE_COUNT=0

printf "  %-28s ${G}%s${N}\n" "Active (queued to send):"  "$ACTIVE_COUNT"
printf "  %-28s ${Y}%s${N}\n" "Deferred (retry pending):" "$DEFERRED_COUNT"
printf "  %-28s ${R}%s${N}\n" "Frozen (stuck/failed):"    "$FROZEN_COUNT"
echo ""

if   [ "${TOTAL_COUNT:-0}" -gt 5000 ]; then
    crit "Queue exceeds 5000 — server may already be blacklisted. Act immediately."
elif [ "${TOTAL_COUNT:-0}" -gt 1000 ]; then
    crit "Queue exceeds 1000 — spam source must be identified and stopped now."
elif [ "${TOTAL_COUNT:-0}" -gt 200 ]; then
    warn "Queue elevated (${TOTAL_COUNT}) — investigate and monitor closely."
else
    ok   "Queue size is within normal range."
fi

# =============================================================================
# SECTION 2 — Top senders in queue
# =============================================================================
hdr "2. TOP SENDERS IN QUEUE"
echo ""

printf "${B}  %-6s %-42s %-20s %-s${N}\n" \
    "COUNT" "SENDER ADDRESS" "cPANEL ACCOUNT" "VERDICT"
echo "  ──────────────────────────────────────────────────────────────────────"

# Parse all sender addresses from exim -bp output
declare -A SENDER_COUNT
while IFS= read -r line; do
    if echo "$line" | grep -qE '<[^>]*@[^>]*>'; then
        SENDER=$(echo "$line" | grep -oE '<[^>]+>' | tr -d '<>' | head -1)
        [ -n "$SENDER" ] && \
            SENDER_COUNT["$SENDER"]=$(( ${SENDER_COUNT["$SENDER"]:-0} + 1 ))
    fi
done < <(exim -bp 2>/dev/null)

RANK=0
for SENDER in $(for k in "${!SENDER_COUNT[@]}"; do
                    echo "${SENDER_COUNT[$k]} $k"
                done | sort -rn | awk '{print $2}'); do

    CNT="${SENDER_COUNT[$SENDER]}"
    CPANEL_ACCT=$(_email_to_cpanel "$SENDER")

    # Filter by user if specified
    if [ -n "$TARGET_USER" ] && [ "$CPANEL_ACCT" != "$TARGET_USER" ]; then
        continue
    fi

    CLR=$N; VERDICT="Normal"
    if   [ "$CNT" -ge 500 ]; then CLR=$R; VERDICT="SPAM — suspend immediately"
    elif [ "$CNT" -ge 100 ]; then CLR=$Y; VERDICT="Likely spam — investigate"
    elif [ "$CNT" -ge 20  ]; then CLR=$C; VERDICT="Elevated — monitor"
    fi

    printf "${CLR}  %-6s %-42s %-20s %-s${N}\n" \
        "$CNT" "$SENDER" "$CPANEL_ACCT" "$VERDICT"

    RANK=$((RANK + 1))
    [ "$RANK" -ge "$TOP_COUNT" ] && break
done

[ "$RANK" -eq 0 ] && info "No sender addresses found in queue."

# =============================================================================
# SECTION 3 — Top recipient domains
# =============================================================================
hdr "3. TOP RECIPIENT DOMAINS (where is it going?)"
echo ""

info "Recipient domains with most queued messages:"
echo ""
exim -bp 2>/dev/null | \
    grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | \
    awk -F@ '{print $2}' | \
    sort | uniq -c | sort -rn | head -15 | \
    while read -r cnt domain; do
        FLAG=""
        CLR=$N
        [ "$cnt" -ge 100 ] && FLAG=" ◄ BULK TARGET" && CLR=$Y
        printf "${CLR}    %-6s %s%s${N}\n" "$cnt" "$domain" "$FLAG"
    done

# =============================================================================
# SECTION 4 — PHP script origination
# =============================================================================
hdr "4. PHP MAIL SCRIPT ORIGINATION"
echo ""

info "Scanning queued message headers for X-PHP-Originating-Script..."
echo ""

declare -A SCRIPT_COUNT
MSG_IDS=$(exim -bp 2>/dev/null | awk '/^\s+[0-9]+[smhdw]/{print $3}' | head -150)

for MSG_ID in $MSG_IDS; do
    [ -z "$MSG_ID" ] && continue
    SCRIPT=$(exim -Mvh "$MSG_ID" 2>/dev/null | \
             grep -i "x-php-originating-script" | \
             grep -oE '/home/[^ ]+' | head -1)
    [ -n "$SCRIPT" ] && \
        SCRIPT_COUNT["$SCRIPT"]=$(( ${SCRIPT_COUNT["$SCRIPT"]:-0} + 1 ))
done

if [ ${#SCRIPT_COUNT[@]} -eq 0 ]; then
    ok "No PHP originating script headers found in sampled messages."
    info "(Mail may be sent via SMTP auth or direct sendmail call)"
else
    printf "  ${B}%-8s %-50s %-s${N}\n" "COUNT" "SCRIPT PATH" "OWNER"
    echo "  ──────────────────────────────────────────────────────────────────────"

    for SCRIPT in $(for k in "${!SCRIPT_COUNT[@]}"; do
                        echo "${SCRIPT_COUNT[$k]} $k"
                    done | sort -rn | awk '{print $2}'); do
        CNT="${SCRIPT_COUNT[$SCRIPT]}"
        OWNER=$(stat -c '%U' "$SCRIPT" 2>/dev/null || echo "unknown")
        CLR=$N
        [ "$CNT" -ge 50 ] && CLR=$R
        [ "$CNT" -ge 10 ] && [ "$CNT" -lt 50 ] && CLR=$Y

        printf "${CLR}  %-8s %-50s %-s${N}\n" "$CNT" "$SCRIPT" "$OWNER"

        # Classify the script
        case "$SCRIPT" in
            */wp-includes/*|*/wp-content/*)
                info "  → WordPress mailer — check for compromised plugin or theme" ;;
            */components/*|*/joomla/*)
                info "  → Joomla component — check for vulnerable extension" ;;
            */tmp/*|*/cache/*)
                crit "  → Script in /tmp or /cache — HIGHLY SUSPICIOUS (webshell/dropper)" ;;
            */public_html/*)
                info "  → In public_html — review script for mail() abuse" ;;
        esac
    done
fi

# =============================================================================
# SECTION 5 — Sample message inspection
# =============================================================================
hdr "5. SAMPLE MESSAGE HEADER INSPECTION"
echo ""

info "Sampling up to 8 queued messages for spam indicators..."
echo ""

SPAM_FLAGS=0
SAMPLE=0
MSG_IDS=$(exim -bp 2>/dev/null | awk '/^\s+[0-9]+[smhdw]/{print $3}' | head -8)

for MSG_ID in $MSG_IDS; do
    [ -z "$MSG_ID" ] && continue
    SAMPLE=$((SAMPLE + 1))

    HDR=$(exim -Mvh "$MSG_ID" 2>/dev/null | head -40)
    FROM_HDR=$(echo  "$HDR" | grep -i "^from:"        | head -1)
    RETURN=$(echo    "$HDR" | grep -i "^return-path:" | head -1)
    SUBJECT=$(echo   "$HDR" | grep -i "^subject:"     | head -1)
    PHP_HDR=$(echo   "$HDR" | grep -i "x-php-originating-script" | head -1)

    echo -e "  ${B}── Message: ${MSG_ID} ──${N}"
    [ -n "$RETURN"  ] && echo "    $RETURN"
    [ -n "$FROM_HDR"] && echo "    $FROM_HDR"
    [ -n "$SUBJECT" ] && echo "    $SUBJECT"
    [ -n "$PHP_HDR" ] && echo -e "    ${Y}$PHP_HDR${N}"

    # Spam heuristics
    FLAGS=()
    [ -z "$(echo "$HDR" | grep -i '^message-id:')" ]  && FLAGS+=("Missing Message-ID")
    [ -z "$(echo "$HDR" | grep -i '^date:')" ]         && FLAGS+=("Missing Date header")
    echo "$HDR" | grep -qi "^x-spam"                   && FLAGS+=("X-Spam header present")
    [ -n "$PHP_HDR" ]                                  && FLAGS+=("PHP-originated mail")
    echo "$SUBJECT" | grep -qiE \
        'viagra|casino|lottery|winner|prize|urgent|verify|suspended|bitcoin|crypto|click here' && \
        FLAGS+=("Spam keyword in subject")

    if [ ${#FLAGS[@]} -gt 0 ]; then
        SPAM_FLAGS=$((SPAM_FLAGS + 1))
        for F in "${FLAGS[@]}"; do
            warn "    ◄ $F"
        done
    else
        ok   "    No obvious spam indicators."
    fi
    echo ""
done

echo "  ──────────────────────────────────────────────────────────────────────"
info "Sampled: ${SAMPLE} messages | Spam flags: ${SPAM_FLAGS}/${SAMPLE}"

# =============================================================================
# SECTION 6 — SMTP auth abuse detection
# =============================================================================
hdr "6. SMTP AUTH ABUSE DETECTION"
echo ""

EXIM_LOG="/var/log/exim_mainlog"
[ ! -f "$EXIM_LOG" ] && EXIM_LOG="/var/log/exim/mainlog"

if [ ! -f "$EXIM_LOG" ]; then
    warn "Exim main log not found. Checked: /var/log/exim_mainlog and /var/log/exim/mainlog"
else
    # Top authenticated senders
    info "Top SMTP authenticated senders (last 2000 log lines):"
    echo ""
    printf "  ${B}%-6s %-40s %-20s${N}\n" "COUNT" "EMAIL" "cPANEL ACCOUNT"
    echo "  ──────────────────────────────────────────────────────────────────────"
    tail -2000 "$EXIM_LOG" 2>/dev/null | \
        grep -E "A=dovecot_plain|A=plain|A=login|authenticated" | \
        grep -oE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | \
        sort | uniq -c | sort -rn | head -12 | \
        while read -r cnt email; do
            ACCT=$(_email_to_cpanel "$email")
            CLR=$N; FLAG=""
            [ "$cnt" -ge 200 ] && CLR=$R && FLAG=" ◄ CREDENTIAL ABUSE"
            [ "$cnt" -ge 50  ] && [ "$cnt" -lt 200 ] && CLR=$Y && FLAG=" ◄ HIGH VOLUME"
            [ -n "$TARGET_USER" ] && [ "$ACCT" != "$TARGET_USER" ] && continue
            printf "${CLR}  %-6s %-40s %-20s%s${N}\n" \
                "$cnt" "$email" "$ACCT" "$FLAG"
        done

    # Auth failures
    echo ""
    AUTH_FAILS=$(tail -2000 "$EXIM_LOG" 2>/dev/null | \
                 grep -cE "authenticator failed|535 " || echo 0)
    if [ "${AUTH_FAILS:-0}" -ge 50 ]; then
        crit "SMTP auth failures in last 2000 lines: ${AUTH_FAILS} — possible credential stuffing"
    elif [ "${AUTH_FAILS:-0}" -ge 10 ]; then
        warn "SMTP auth failures: ${AUTH_FAILS}"
    else
        ok   "SMTP auth failures: ${AUTH_FAILS} (normal)"
    fi

    # Top IPs with auth failures
    echo ""
    info "IPs with most SMTP auth failures:"
    tail -2000 "$EXIM_LOG" 2>/dev/null | \
        grep -E "authenticator failed|535 " | \
        grep -oE '\[([0-9]{1,3}\.){3}[0-9]{1,3}\]' | tr -d '[]' | \
        sort | uniq -c | sort -rn | head -8 | \
        while read -r cnt ip; do
            printf "    %-6s %s\n" "$cnt" "$ip"
        done
fi

# =============================================================================
# SECTION 7 — Server IP blacklist check (DNSBL)
# =============================================================================
hdr "7. SERVER IP BLACKLIST CHECK (DNSBL)"
echo ""

SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || \
            curl -s --max-time 5 icanhazip.com 2>/dev/null || \
            hostname -I | awk '{print $1}')

if [ -z "$SERVER_IP" ]; then
    warn "Could not determine server IP — skipping blacklist check."
else
    info "Server outbound IP: ${SERVER_IP}"
    echo ""

    REVERSED_IP=$(echo "$SERVER_IP" | awk -F. '{print $4"."$3"."$2"."$1}')

    declare -a DNSBLS=(
        "zen.spamhaus.org"
        "bl.spamcop.net"
        "dnsbl.sorbs.net"
        "b.barracudacentral.org"
        "dnsbl-1.uceprotect.net"
        "cbl.abuseat.org"
        "psbl.surriel.com"
    )

    LISTED=0
    printf "  ${B}%-40s %-s${N}\n" "DNSBL" "STATUS"
    echo "  ──────────────────────────────────────────────────────────────────────"

    for DNSBL in "${DNSBLS[@]}"; do
        RESULT=$(host -t A "${REVERSED_IP}.${DNSBL}" 2>/dev/null | grep "has address")
        if [ -n "$RESULT" ]; then
            printf "  ${R}%-40s LISTED ◄${N}\n" "$DNSBL"
            LISTED=$((LISTED + 1))
        else
            printf "  ${G}%-40s clean${N}\n" "$DNSBL"
        fi
    done

    echo ""
    if [ "$LISTED" -gt 0 ]; then
        crit "IP is listed on ${LISTED} DNSBL(s) — delist AFTER stopping spam source"
        warn "  Spamhaus : https://www.spamhaus.org/lookup/"
        warn "  SpamCop  : https://www.spamcop.net/bl.shtml"
        warn "  Barracuda: https://www.barracudacentral.org/rbl/removal-request"
    else
        ok "Server IP is clean on all checked DNSBLs."
    fi
fi

# =============================================================================
# SECTION 8 — Action menu
# =============================================================================
hdr "8. ADMIN ACTIONS"
echo ""

if [ -z "$TARGET_USER" ] && [ -z "$ACTION" ]; then
    info "No action specified. Available actions (require --user):"
    echo ""
    printf "  ${B}%-12s %-s${N}\n" "ACTION" "WHAT IT DOES"
    echo "  ──────────────────────────────────────────────────────────────────────"
    printf "  %-12s %-s\n" "report"   "Show full queue listing for account"
    printf "  %-12s %-s\n" "freeze"   "Freeze all queued messages (stops sending)"
    printf "  %-12s %-s\n" "unfreeze" "Unfreeze messages (resume delivery)"
    printf "  %-12s %-s\n" "remove"   "DELETE all queued messages for account ⚠"
    printf "  %-12s %-s\n" "block"    "Block outbound email (Exim ACL / CSF / WHM)"
    printf "  %-12s %-s\n" "suspend"  "Suspend entire cPanel account via WHM API"
    echo ""
    info "Example: bash mail_investigate.sh --user johndoe --action freeze"
elif [ -n "$ACTION" ] && [ -z "$TARGET_USER" ]; then
    warn "--action requires --user to be specified."
    info "Example: bash mail_investigate.sh --user johndoe --action ${ACTION}"
else
    USER_DOMAIN=$(_user_to_domain "$TARGET_USER")
    info "Account : ${TARGET_USER}"
    info "Domain  : ${USER_DOMAIN:-not found}"
    info "Action  : ${ACTION}"

    case "$ACTION" in

        # -------------------------------------------------------------------
        report)
            echo ""
            info "Full queue listing for ${TARGET_USER} / ${USER_DOMAIN}:"
            echo ""
            exim -bp 2>/dev/null | grep -A3 \
                "${TARGET_USER}\|${USER_DOMAIN}" | head -80
            ;;

        # -------------------------------------------------------------------
        freeze)
            warn "Will FREEZE all queued messages for: ${TARGET_USER}"
            if _confirm "Freeze outgoing mail for ${TARGET_USER}?"; then
                FROZEN=0
                for MSG_ID in $(exim -bp 2>/dev/null | \
                    awk '/^\s+[0-9]+[smhdw]/{print $3}'); do
                    exim -Mvh "$MSG_ID" 2>/dev/null | \
                        grep -qi "${TARGET_USER}\|${USER_DOMAIN}" && {
                        exim -Mf "$MSG_ID" 2>/dev/null && \
                            FROZEN=$((FROZEN + 1))
                    }
                done
                ok "Frozen ${FROZEN} messages for ${TARGET_USER}."
            else
                info "Action cancelled."
            fi
            ;;

        # -------------------------------------------------------------------
        unfreeze)
            info "Will UNFREEZE queued messages for: ${TARGET_USER}"
            if _confirm "Unfreeze and resume delivery for ${TARGET_USER}?"; then
                THAWED=0
                for MSG_ID in $(exim -bp 2>/dev/null | grep frozen | \
                    awk '{print $3}'); do
                    exim -Mvh "$MSG_ID" 2>/dev/null | \
                        grep -qi "${TARGET_USER}\|${USER_DOMAIN}" && {
                        exim -Mt "$MSG_ID" 2>/dev/null && \
                            THAWED=$((THAWED + 1))
                    }
                done
                ok "Unfrozen ${THAWED} messages for ${TARGET_USER}."
            else
                info "Action cancelled."
            fi
            ;;

        # -------------------------------------------------------------------
        remove)
            crit "Will PERMANENTLY DELETE all queued mail for: ${TARGET_USER}"
            crit "THIS CANNOT BE UNDONE."
            if _confirm "PERMANENTLY DELETE queued mail for ${TARGET_USER}?"; then
                REMOVED=0
                for MSG_ID in $(exim -bp 2>/dev/null | \
                    awk '/^\s+[0-9]+[smhdw]/{print $3}'); do
                    exim -Mvh "$MSG_ID" 2>/dev/null | \
                        grep -qi "${TARGET_USER}\|${USER_DOMAIN}" && {
                        exim -Mrm "$MSG_ID" 2>/dev/null && \
                            REMOVED=$((REMOVED + 1))
                    }
                done
                ok "Removed ${REMOVED} messages for ${TARGET_USER}."
            else
                info "Action cancelled."
            fi
            ;;

        # -------------------------------------------------------------------
        block)
            echo ""
            warn "Block options for ${TARGET_USER} (${USER_DOMAIN}):"
            echo ""
            printf "  ${B}[1]${N} Block via Exim sender ACL (/etc/blockedsenders)\n"
            printf "  ${B}[2]${N} Block SMTP ports via CSF (port 25/465/587 for UID)\n"
            printf "  ${B}[3]${N} Disable email routing via WHM API\n"
            printf "  ${B}[4]${N} Cancel\n"
            echo ""
            echo -ne "  Choose [1-4]: "
            read -r CHOICE

            case "$CHOICE" in
                1)
                    if _confirm "Add *@${USER_DOMAIN} to /etc/blockedsenders?"; then
                        echo "*@${USER_DOMAIN}" >> /etc/blockedsenders
                        /scripts/restartsrv_exim &>/dev/null || \
                            service exim restart &>/dev/null
                        ok "Added *@${USER_DOMAIN} to /etc/blockedsenders. Exim restarted."
                        info "To remove: edit /etc/blockedsenders and restart Exim"
                    fi
                    ;;
                2)
                    if command -v csf &>/dev/null; then
                        UID_NUM=$(id -u "$TARGET_USER" 2>/dev/null)
                        if [ -n "$UID_NUM" ]; then
                            if _confirm "Block SMTP ports for UID ${UID_NUM} (${TARGET_USER}) via CSF?"; then
                                # CSF SMTP_ALLOWLOCAL_PORTS blocks per-uid outbound
                                echo ""
                                info "Adding to CSF — editing /etc/csf/csf.conf..."
                                # Safer: use csf allow/deny or LF_SCRIPT_ALERT
                                warn "Manual step: In /etc/csf/csf.conf set:"
                                warn "  SMTP_BLOCK = 1"
                                warn "  SMTP_ALLOWEDPORTS = 25,465,587"
                                warn "Then add UID ${UID_NUM} to SMTP_BLOCK_EXCEPTIONS exceptions list (inverted)"
                                warn "Or use: csf --deny <IP> for attacker IP blocking"
                                info "Restarting CSF after changes: csf -r"
                            fi
                        else
                            warn "Could not find UID for ${TARGET_USER}"
                        fi
                    else
                        warn "CSF not found — use Exim ACL or WHM option instead."
                    fi
                    ;;
                3)
                    if _confirm "Disable email routing for ${USER_DOMAIN} via WHM API?"; then
                        WHM_TOKEN=$(cat /etc/wwwacct.conf 2>/dev/null | \
                                    grep -i "api_token" | awk '{print $2}')
                        RESULT=$(curl -sk \
                            -H "Authorization: whm root:${WHM_TOKEN}" \
                            "https://localhost:2087/json-api/disableemaildomains?api.version=1&domain=${USER_DOMAIN}" \
                            2>/dev/null)
                        if echo "$RESULT" | grep -q '"status":1'; then
                            ok "Email routing disabled for ${USER_DOMAIN}"
                        else
                            warn "WHM API response unclear — verify in WHM manually"
                            info "WHM → Email → MX Entry → set to Remote Mail Exchanger"
                        fi
                    fi
                    ;;
                4) info "Block cancelled." ;;
                *) warn "Invalid choice." ;;
            esac
            ;;

        # -------------------------------------------------------------------
        suspend)
            crit "Will SUSPEND entire cPanel account: ${TARGET_USER}"
            warn "This disables ALL services for the account, not just email."
            if _confirm "SUSPEND account ${TARGET_USER} via WHM?"; then
                RESULT=$(whmapi1 suspendacct \
                    user="${TARGET_USER}" \
                    reason="Spam investigation $(date +%Y-%m-%d)" \
                    2>/dev/null)
                if echo "$RESULT" | grep -q "result: 1\|suspended"; then
                    ok "Account ${TARGET_USER} suspended."
                else
                    warn "whmapi1 response unclear — verify in WHM → Account Functions → Suspend"
                fi
            else
                info "Suspend cancelled."
            fi
            ;;

        *)
            warn "Unknown action: ${ACTION}"
            info "Valid: report | freeze | unfreeze | remove | block | suspend"
            ;;
    esac
fi

# =============================================================================
# SECTION 9 — Recommendations & one-liners
# =============================================================================
hdr "9. RECOMMENDATIONS & QUICK REFERENCE"
echo ""

echo -e "  ${B}Immediate Actions (if spam confirmed):${N}"
echo ""
echo -e "  ${C}1.${N} Identify culprit → Section 2 (top senders) or Section 4 (PHP script)"
echo -e "  ${C}2.${N} Freeze queue first → bash mail_investigate.sh --user <acct> --action freeze"
echo -e "  ${C}3.${N} If PHP script: delete/quarantine it, change account password"
echo -e "  ${C}4.${N} If SMTP credential abuse: reset email password in cPanel immediately"
echo -e "  ${C}5.${N} Remove spam from queue → --action remove (after freeze + confirm it's spam)"
echo -e "  ${C}6.${N} Delist IP ONLY after spam source is stopped — not before"
echo ""

echo -e "  ${B}Preventive Hardening (WHM / Exim / CSF):${N}"
echo ""
echo -e "  ${D}•${N} WHM → Exim Config → Max hourly emails per domain (e.g. 300/hr)"
echo -e "  ${D}•${N} WHM → Exim Config → Require HELO before MAIL + Require valid HELO"
echo -e "  ${D}•${N} CSF → SMTP_BLOCK=1 (blocks non-Exim SMTP from user processes)"
echo -e "  ${D}•${N} CSF → LF_SCRIPT_ALERT=1 (alert when script sends too many mails)"
echo -e "  ${D}•${N} Imunify360 → Enable Proactive Defense (blocks webshells)"
echo -e "  ${D}•${N} Ensure SPF, DKIM, DMARC are set for all hosted domains"
echo ""

sep
echo -e "${B}  QUICK REFERENCE ONE-LINERS${N}"
sep
echo ""
echo -e "  ${D}# Total queue count:${N}"
echo    "  exim -bpc"
echo ""
echo -e "  ${D}# Full queue listing:${N}"
echo    "  exim -bp | head -50"
echo ""
echo -e "  ${D}# Top senders in queue:${N}"
echo    "  exim -bp | grep -oE '<[^>]+>' | tr -d '<>' | sort | uniq -c | sort -rn | head -20"
echo ""
echo -e "  ${D}# Flush/retry all deferred:${N}"
echo    "  exim -qff"
echo ""
echo -e "  ${D}# Remove ALL frozen messages (careful!):${N}"
echo    "  exiqgrep -z -i | xargs exim -Mrm"
echo ""
echo -e "  ${D}# Remove all messages from one sender:${N}"
echo    "  exiqgrep -f 'user@domain.com' -i | xargs exim -Mrm"
echo ""
echo -e "  ${D}# Remove all messages TO one recipient domain:${N}"
echo    "  exiqgrep -r '@domain.com' -i | xargs exim -Mrm"
echo ""
echo -e "  ${D}# View message header:${N}"
echo    "  exim -Mvh <message-id>"
echo ""
echo -e "  ${D}# View message body:${N}"
echo    "  exim -Mvb <message-id>"
echo ""
echo -e "  ${D}# Check if your IP is in Spamhaus:${N}"
echo    "  host \$(curl -s ifconfig.me | awk -F. '{print \$4\".\"\$3\".\"\$2\".\"\$1}').zen.spamhaus.org"
echo ""
echo -e "  ${D}# Suspend account via WHM CLI:${N}"
echo    "  whmapi1 suspendacct user=<username> reason='Spam'"
echo ""

sep
echo -e "${G}${B}  Done — $(date '+%H:%M:%S')${N}"
sep
echo ""
