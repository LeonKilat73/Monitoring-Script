#!/bin/bash
# =============================================================================
# /opt/hostmon/cpu_investigate.sh
# =============================================================================
# PURPOSE: When Zabbix fires a CPU spike alert, run this to find out:
#   - Which processes are consuming CPU
#   - Which cPanel account owns them
#   - Whether it looks like abuse, an attack, or legitimate load
#   - What PHP/MySQL/Apache workers are doing
#
# USAGE:
#   bash cpu_investigate.sh               # Full investigation
#   bash cpu_investigate.sh --user joe    # Focus on specific cPanel account
#   bash cpu_investigate.sh --slack       # Also post findings to Slack
# =============================================================================

source "$(dirname "$0")/lib/common.sh"
require_root
require_cmds ps awk grep curl

# Parse args
TARGET_USER=""
POST_SLACK=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --user)   TARGET_USER="$2"; shift ;;
        --slack)  POST_SLACK=true ;;
        *)        ;;
    esac
    shift
done

SLACK_BUFFER=""
_sbuf() { SLACK_BUFFER+="$*"$'\n'; }

# =============================================================================
# SECTION 1 — SNAPSHOT: Top CPU processes right now
# =============================================================================
section_top_processes() {
    section "1. TOP CPU-CONSUMING PROCESSES (live snapshot)"

    echo ""
    printf "${C_BOLD}%-6s %-10s %-6s %-6s %-s${C_RESET}\n" \
        "PID" "USER" "%CPU" "%MEM" "COMMAND"
    echo "──────────────────────────────────────────────────────────────"

    _sbuf "=== TOP CPU PROCESSES ==="
    _sbuf "$(printf '%-6s %-12s %-6s %-6s %-s' PID USER %CPU %MEM COMMAND)"

    local line_count=0
    while IFS= read -r line; do
        local pid user cpu mem cmd
        pid=$(echo "$line"  | awk '{print $1}')
        user=$(echo "$line" | awk '{print $2}')
        cpu=$(echo "$line"  | awk '{print $3}')
        mem=$(echo "$line"  | awk '{print $4}')
        cmd=$(echo "$line"  | awk '{print $11}')

        # Classify the process
        local flag=""
        local color="$C_RESET"

        # Check if CPU exceeds threshold
        local cpu_int=${cpu%.*}
        if [ "${cpu_int:-0}" -ge "$CPU_PROC_THRESHOLD" ]; then
            flag=" ◄ HIGH"
            color="$C_YELLOW"
        fi

        # Flag suspicious patterns
        case "$cmd" in
            *perl*|*python*|*php*|*ruby*)
                # Check for known attack scripts
                local cmdline
                cmdline=$(cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ')
                case "$cmdline" in
                    *spam*|*flood*|*brute*|*masscan*|*nmap*|*sqlmap*)
                        flag=" ◄ SUSPICIOUS"
                        color="$C_RED"
                        ;;
                esac
                ;;
            *crypto*|*minerd*|*xmrig*|*cpuminer*)
                flag=" ◄ POSSIBLE CRYPTOMINER"
                color="$C_RED"
                ;;
        esac

        # Map user to cPanel account
        local cpanel_tag=""
        if [ -d "/home/${user}/public_html" ] || \
           [ -f "/var/cpanel/users/${user}" ]; then
            cpanel_tag=" [cPanel]"
        fi

        printf "${color}%-6s %-10s %-6s %-6s %-30s${C_RESET}%s%s\n" \
            "$pid" "${user}${cpanel_tag}" "$cpu" "$mem" "$cmd" "$flag" ""

        _sbuf "$(printf '%-6s %-14s %-6s %-6s %-30s%s' \
            "$pid" "${user}" "$cpu" "$mem" "$cmd" "$flag")"

        line_count=$((line_count + 1))
        [ "$line_count" -ge 20 ] && break

    done < <(ps aux --sort=-%cpu | tail -n +2 | \
             { [ -n "$TARGET_USER" ] && grep "^${TARGET_USER}" || cat; })
}

# =============================================================================
# SECTION 2 — Per cPanel account CPU usage rollup
# =============================================================================
section_account_rollup() {
    section "2. CPU USAGE BY cPANEL ACCOUNT"
    echo ""
    printf "${C_BOLD}%-20s %-10s %-10s %-s${C_RESET}\n" \
        "ACCOUNT" "TOTAL%CPU" "PROCESSES" "TOP COMMAND"
    echo "──────────────────────────────────────────────────────────────"

    _sbuf ""
    _sbuf "=== CPU BY ACCOUNT ==="
    _sbuf "$(printf '%-20s %-10s %-10s %-s' ACCOUNT TOTAL%CPU PROCESSES TOP_CMD)"

    declare -A acc_cpu acc_pcount acc_topcmd

    while IFS= read -r line; do
        local user cpu cmd
        user=$(echo "$line" | awk '{print $1}')
        cpu=$(echo "$line"  | awk '{print $3}')
        cmd=$(echo "$line"  | awk '{print $11}')

        # Only count cPanel users
        [ -f "/var/cpanel/users/${user}" ] || continue

        # Accumulate
        acc_cpu[$user]=$(echo "${acc_cpu[$user]:-0} + ${cpu:-0}" | bc 2>/dev/null)
        acc_pcount[$user]=$(( ${acc_pcount[$user]:-0} + 1 ))
        [ -z "${acc_topcmd[$user]}" ] && acc_topcmd[$user]="$cmd"

    done < <(ps aux --sort=-%cpu | tail -n +2)

    # Sort by CPU descending and print
    for user in $(for k in "${!acc_cpu[@]}"; do
                      echo "${acc_cpu[$k]} $k"
                  done | sort -rn | awk '{print $2}' | head -"$TOP_ACCOUNTS_COUNT"); do

        local total_cpu="${acc_cpu[$user]}"
        local pcount="${acc_pcount[$user]}"
        local topcmd="${acc_topcmd[$user]}"
        local color="$C_RESET"

        # Color-code by severity
        local cpu_int=${total_cpu%.*}
        [ "${cpu_int:-0}" -ge 50 ] && color="$C_RED"
        [ "${cpu_int:-0}" -ge 20 ] && [ "${cpu_int:-0}" -lt 50 ] && color="$C_YELLOW"

        printf "${color}%-20s %-10s %-10s %-s${C_RESET}\n" \
            "$user" "${total_cpu}%" "$pcount" "$topcmd"

        _sbuf "$(printf '%-20s %-10s %-10s %-s' \
            "$user" "${total_cpu}%" "$pcount" "$topcmd")"
    done
}

# =============================================================================
# SECTION 3 — Apache/LiteSpeed worker analysis
# =============================================================================
section_apache_workers() {
    section "3. APACHE / LITESPEED WORKER ANALYSIS"
    echo ""

    _sbuf ""
    _sbuf "=== WEB SERVER WORKERS ==="

    # Detect web server
    local ws_bin=""
    if pgrep -x httpd    &>/dev/null; then ws_bin="httpd"
    elif pgrep -x apache2 &>/dev/null; then ws_bin="apache2"
    elif pgrep -x lshttpd &>/dev/null; then ws_bin="lshttpd"
    fi

    if [ -z "$ws_bin" ]; then
        log_warn "No recognized web server process found running."
        _sbuf "No web server process detected."
        return
    fi

    local ws_count
    ws_count=$(pgrep -c "$ws_bin" 2>/dev/null || echo "0")
    local ws_cpu
    ws_cpu=$(ps aux | grep "$ws_bin" | grep -v grep | \
             awk '{sum+=$3} END {printf "%.1f", sum}')

    log_info "Web server  : $ws_bin"
    log_info "Workers     : $ws_count processes"
    log_info "Total %CPU  : ${ws_cpu}%"

    _sbuf "Web server : $ws_bin | Workers: $ws_count | CPU: ${ws_cpu}%"

    # Show server-status if available (Apache mod_status)
    if [ -f /usr/local/apache/bin/apachectl ]; then
        local server_status
        server_status=$(curl -sk "http://localhost/server-status?auto" 2>/dev/null | head -20)
        if [ -n "$server_status" ]; then
            echo ""
            log_info "Apache mod_status:"
            echo "$server_status" | grep -E "BusyWorkers|IdleWorkers|ReqPerSec|BytesPerSec" | \
                while read -r l; do log_dim "  $l"; done
        fi
    fi

    # Top Apache-spawned users (from /proc)
    echo ""
    log_info "Top domains/users generating Apache workers:"
    ps aux | grep "$ws_bin" | grep -v grep | \
        awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | \
        while read -r count user; do
            printf "  %-5s requests from user: %s\n" "$count" "$user"
        done
}

# =============================================================================
# SECTION 4 — PHP process analysis (PHP-FPM pools + CGI)
# =============================================================================
section_php_workers() {
    section "4. PHP PROCESS ANALYSIS"
    echo ""

    _sbuf ""
    _sbuf "=== PHP PROCESSES ==="

    # Count PHP workers by handler
    local php_fpm_count  php_cgi_count php_cli_count
    php_fpm_count=$(pgrep -c "php-fpm"  2>/dev/null || echo 0)
    php_cgi_count=$(pgrep -c "php-cgi"  2>/dev/null || echo 0)
    php_cli_count=$(ps aux | grep "php " | grep -v grep | wc -l)

    log_info "PHP-FPM workers : $php_fpm_count"
    log_info "PHP-CGI workers : $php_cgi_count"
    log_info "PHP CLI procs   : $php_cli_count"

    _sbuf "PHP-FPM: $php_fpm_count | PHP-CGI: $php_cgi_count | PHP-CLI: $php_cli_count"

    # Flag long-running PHP CLI (often abuse — spammers, crypto, scrapers)
    echo ""
    log_info "Long-running PHP CLI processes (>60s — investigate these):"
    local found_long=0
    while IFS= read -r line; do
        local pid elapsed cmd user
        pid=$(echo "$line"     | awk '{print $1}')
        user=$(echo "$line"    | awk '{print $2}')
        elapsed=$(echo "$line" | awk '{print $10}')
        cmd=$(cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ' | cut -c1-80)

        # Convert elapsed (MM:SS or HH:MM:SS) — flag if > 1 min
        local mins
        mins=$(echo "$elapsed" | awk -F: '{if(NF==3) print $1*60+$2; else print $1}')
        if [ "${mins:-0}" -ge 1 ]; then
            log_warn "  PID $pid | User: $user | Elapsed: $elapsed"
            log_dim  "  CMD: $cmd"
            _sbuf "  LONG PHP: PID=$pid user=$user elapsed=$elapsed cmd=$cmd"
            found_long=$((found_long + 1))
        fi
    done < <(ps aux | grep "php " | grep -v grep | grep -v "php-fpm" | grep -v "php-cgi")

    [ "$found_long" -eq 0 ] && log_ok "No long-running PHP CLI processes found."
}

# =============================================================================
# SECTION 5 — MySQL query analysis
# =============================================================================
section_mysql() {
    section "5. MYSQL ACTIVE QUERY ANALYSIS"
    echo ""

    _sbuf ""
    _sbuf "=== MYSQL ==="

    # Check if MySQL is running
    if ! pgrep -x mysqld &>/dev/null && ! pgrep -x mariadbd &>/dev/null; then
        log_warn "MySQL/MariaDB not running."
        return
    fi

    # Try to get processlist (reads from /root/.my.cnf if present)
    local process_list
    process_list=$(mysql -e "SHOW FULL PROCESSLIST;" 2>/dev/null)

    if [ -z "$process_list" ]; then
        log_warn "Could not connect to MySQL. Ensure /root/.my.cnf has credentials."
        _sbuf "MySQL: could not connect"
        return
    fi

    local total_queries sleep_queries slow_queries
    total_queries=$(echo "$process_list" | tail -n +2 | wc -l)
    sleep_queries=$(echo "$process_list" | grep -c "Sleep")
    slow_queries=$(echo "$process_list"  | awk '$7 > 10 {print}' | wc -l)

    log_info "Total connections  : $total_queries"
    log_info "Sleeping           : $sleep_queries"
    log_warn "Queries > 10s      : $slow_queries"

    _sbuf "MySQL: total=$total_queries sleeping=$sleep_queries slow(>10s)=$slow_queries"

    if [ "$slow_queries" -gt 0 ]; then
        echo ""
        log_warn "SLOW / ACTIVE QUERIES:"
        echo "$process_list" | awk 'NR==1 || $7 > 5' | \
            awk '{printf "  %-6s %-15s %-8s %-s\n", $1, $3, $7, $8}' | head -15
    fi

    # Top databases by connection
    echo ""
    log_info "Top databases by connection count:"
    echo "$process_list" | tail -n +2 | awk '{print $4}' | \
        sort | uniq -c | sort -rn | head -10 | \
        awk '{printf "  %-5s connections to db: %s\n", $1, $2}'
}

# =============================================================================
# SECTION 6 — Attack pattern detection
# =============================================================================
section_attack_detection() {
    section "6. POTENTIAL ATTACK / ABUSE DETECTION"
    echo ""

    _sbuf ""
    _sbuf "=== ATTACK DETECTION ==="

    local suspicious_found=0

    # --- High connection count from single IP (SYN flood / HTTP flood)
    log_info "Checking for connection floods..."
    local top_ip ip_count
    top_ip=$(ss -tn state established 2>/dev/null | \
             awk 'NR>1 {print $5}' | cut -d: -f1 | \
             sort | uniq -c | sort -rn | head -1)
    ip_count=$(echo "$top_ip" | awk '{print $1}')
    top_ip_addr=$(echo "$top_ip" | awk '{print $2}')

    if [ "${ip_count:-0}" -ge 50 ]; then
        log_crit "Possible flood: IP ${top_ip_addr} has ${ip_count} connections"
        _sbuf "FLOOD: $top_ip_addr = $ip_count connections"
        suspicious_found=$((suspicious_found + 1))
    else
        log_ok "No connection flood detected. Top IP: ${top_ip_addr} (${ip_count} conns)"
    fi

    # --- Processes running from /tmp or /dev/shm (malware indicator)
    echo ""
    log_info "Checking for processes running from /tmp or /dev/shm..."
    local shady_procs
    shady_procs=$(ls -la /proc/[0-9]*/exe 2>/dev/null | grep -E '/tmp|/dev/shm|/var/tmp')
    if [ -n "$shady_procs" ]; then
        log_crit "SUSPICIOUS: Processes executing from temp directories:"
        echo "$shady_procs" | while read -r l; do log_warn "  $l"; done
        _sbuf "MALWARE INDICATOR: processes from /tmp or /dev/shm"
        suspicious_found=$((suspicious_found + 1))
    else
        log_ok "No processes running from /tmp or /dev/shm."
    fi

    # --- Check for known crypto miner process names
    echo ""
    log_info "Checking for cryptominer indicators..."
    local miner_hits
    miner_hits=$(ps aux | grep -iE 'xmrig|minerd|cpuminer|cryptonight|stratum' | grep -v grep)
    if [ -n "$miner_hits" ]; then
        log_crit "CRYPTOMINER DETECTED:"
        echo "$miner_hits" | while read -r l; do log_warn "  $l"; done
        _sbuf "CRYPTOMINER: $miner_hits"
        suspicious_found=$((suspicious_found + 1))
    else
        log_ok "No cryptominer processes detected."
    fi

    # --- Summary
    echo ""
    if [ "$suspicious_found" -gt 0 ]; then
        log_crit "Total suspicious indicators found: $suspicious_found"
        _sbuf "TOTAL SUSPICIOUS: $suspicious_found"
    else
        log_ok "No obvious attack/abuse patterns detected."
        _sbuf "No attack patterns detected."
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    header "CPU INVESTIGATION REPORT"
    write_log "cpu_investigate" "Investigation started"

    [ -n "$TARGET_USER" ] && log_info "Filtering for cPanel user: ${TARGET_USER}"

    section_top_processes
    section_account_rollup
    section_apache_workers
    section_php_workers
    section_mysql
    section_attack_detection

    echo ""
    section "INVESTIGATION COMPLETE"
    log_info "Full log saved to: ${LOG_DIR}/cpu_investigate.log"

    write_log "cpu_investigate" "Investigation complete"

    if [ "$POST_SLACK" = true ]; then
        slack_post "CPU Investigation" "$SLACK_BUFFER"
        log_info "Findings posted to Slack."
    else
        echo ""
        log_dim "Tip: run with --slack to post findings to Slack automatically"
    fi
}

main "$@"
