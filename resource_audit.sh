#!/bin/bash
# =============================================================================
# /opt/hostmon/resource_audit.sh
# =============================================================================
# PURPOSE: Full resource consumption audit — answers "is this load normal
#          or do we need to upgrade / optimize / suspend an account?"
#
#   - Top cPanel accounts by CPU + RAM combined
#   - MySQL: slow queries, top databases, connection hogs
#   - PHP-FPM pool status per account
#   - Apache/LiteSpeed slot consumption
#   - Decision helper: upgrade vs optimize vs abuse
#
# USAGE:
#   bash resource_audit.sh                # Full audit
#   bash resource_audit.sh --user joe     # Single account deep-dive
#   bash resource_audit.sh --slack        # Also post to Slack
# =============================================================================

HOSTMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HOSTMON_DIR}/lib/common.sh"
require_root
require_cmds ps awk sort grep

TARGET_USER=""
POST_SLACK=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --user)  TARGET_USER="$2"; shift ;;
        --slack) POST_SLACK=true ;;
    esac
    shift
done

SLACK_BUFFER=""
_sbuf() { SLACK_BUFFER+="$*"$'\n'; }

# =============================================================================
# SECTION 1 — Combined resource score per cPanel account
# Score = CPU% + (MEM% * 0.5) — gives a single "load pressure" number
# =============================================================================
section_combined_resource_score() {
    section "1. RESOURCE PRESSURE SCORE — ALL cPANEL ACCOUNTS"
    echo ""
    log_dim "Score = CPU% + (RAM% × 0.5) — higher = more server pressure"
    echo ""

    _sbuf "=== RESOURCE SCORE ==="
    _sbuf "$(printf '%-20s %8s %8s %8s %10s' ACCOUNT CPU% MEM% SCORE PROCESSES)"

    printf "${C_BOLD}%-20s %8s %8s %8s %10s  %-s${C_RESET}\n" \
        "ACCOUNT" "CPU%" "MEM%" "SCORE" "PROCESSES" "VERDICT"
    echo "──────────────────────────────────────────────────────────────────────"

    declare -A acc_cpu acc_mem acc_pcount

    # Aggregate from ps
    while IFS= read -r line; do
        local user cpu mem
        user=$(echo "$line" | awk '{print $1}')
        cpu=$(echo "$line"  | awk '{print $3}')
        mem=$(echo "$line"  | awk '{print $4}')

        [ -f "/var/cpanel/users/${user}" ] || continue

        acc_cpu[$user]=$(echo "${acc_cpu[$user]:-0} + ${cpu:-0}" | bc 2>/dev/null)
        acc_mem[$user]=$(echo "${acc_mem[$user]:-0} + ${mem:-0}" | bc 2>/dev/null)
        acc_pcount[$user]=$(( ${acc_pcount[$user]:-0} + 1 ))

    done < <(ps aux | tail -n +2 | \
             { [ -n "$TARGET_USER" ] && grep "^${TARGET_USER} " || cat; })

    # Calculate scores and sort
    declare -A acc_score
    for user in "${!acc_cpu[@]}"; do
        acc_score[$user]=$(echo "${acc_cpu[$user]} + (${acc_mem[$user]} * 0.5)" | \
                           bc 2>/dev/null | awk '{printf "%.1f", $1}')
    done

    for user in $(for k in "${!acc_score[@]}"; do
                      echo "${acc_score[$k]} $k"
                  done | sort -rn | awk '{print $2}' | head -"$TOP_ACCOUNTS_COUNT"); do

        local cpu="${acc_cpu[$user]}"
        local mem="${acc_mem[$user]}"
        local score="${acc_score[$user]}"
        local procs="${acc_pcount[$user]}"
        local score_int=${score%.*}

        # Verdict
        local verdict color
        if   [ "${score_int:-0}" -ge 100 ]; then
            verdict="CRITICAL — suspend/investigate"; color="$C_RED"
        elif [ "${score_int:-0}" -ge 50 ]; then
            verdict="HIGH — may need limits/upgrade";  color="$C_YELLOW"
        elif [ "${score_int:-0}" -ge 20 ]; then
            verdict="ELEVATED — monitor";               color="$C_CYAN"
        else
            verdict="Normal";                           color="$C_GREEN"
        fi

        printf "${color}%-20s %8s %8s %8s %10s  %-s${C_RESET}\n" \
            "$user" "${cpu}%" "${mem}%" "$score" "$procs" "$verdict"

        _sbuf "$(printf '%-20s %8s %8s %8s %10s  %-s' \
            "$user" "${cpu}%" "${mem}%" "$score" "$procs" "$verdict")"
    done
}

# =============================================================================
# SECTION 2 — MySQL resource analysis
# =============================================================================
section_mysql_audit() {
    section "2. MYSQL RESOURCE AUDIT"
    echo ""

    _sbuf ""
    _sbuf "=== MYSQL ==="

    if ! pgrep -x mysqld &>/dev/null && ! pgrep -x mariadbd &>/dev/null; then
        log_warn "MySQL/MariaDB is not running."
        return
    fi

    if ! mysql -e "SELECT 1;" &>/dev/null; then
        log_warn "Cannot connect to MySQL. Ensure /root/.my.cnf exists with correct credentials."
        return
    fi

    # --- Global status snapshot
    log_info "MySQL key metrics:"
    mysql -e "SHOW GLOBAL STATUS;" 2>/dev/null | \
        grep -E "^(Threads_connected|Threads_running|Questions|Slow_queries|\
Max_used_connections|Aborted_connects|Table_locks_waited|Innodb_buffer_pool_reads)" | \
        while IFS=$'\t' read -r key val; do
            printf "  %-40s %s\n" "$key" "$val"
        done

    # --- Databases by size
    echo ""
    log_info "Top databases by size:"
    mysql -e "
        SELECT table_schema AS 'Database',
               ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) AS 'Size_MB'
        FROM information_schema.tables
        GROUP BY table_schema
        ORDER BY Size_MB DESC LIMIT 15;" 2>/dev/null | \
        while IFS=$'\t' read -r db size; do
            printf "  %-40s %s MB\n" "$db" "$size"
        done

    # --- Active slow queries (running > 5 seconds)
    echo ""
    log_info "Active queries running > 5 seconds:"
    local slow_found=0
    mysql -e "SHOW FULL PROCESSLIST;" 2>/dev/null | \
        awk 'NR>1 && $7 > 5 && $8 != "Sleep"' | \
        while IFS=$'\t' read -r id user host db cmd time state info; do
            log_warn "  ID: $id | User: $user | DB: $db | Time: ${time}s | Query: ${info:0:80}"
            _sbuf "  SLOW QUERY: user=$user db=$db time=${time}s"
            slow_found=$((slow_found + 1))
        done
    [ "$slow_found" -eq 0 ] && log_ok "No slow queries running."

    # --- Map MySQL users to cPanel accounts
    echo ""
    log_info "MySQL users with most active connections:"
    mysql -e "SELECT user, COUNT(*) as connections, SUM(time) as total_time
              FROM information_schema.processlist
              WHERE user NOT IN ('root','system user','event_scheduler')
              GROUP BY user ORDER BY connections DESC LIMIT 10;" 2>/dev/null | \
        while IFS=$'\t' read -r user conns time; do
            # Try to map mysql user prefix to cpanel account (cpanel uses user_dbname)
            local cpanel_account
            cpanel_account=$(echo "$user" | cut -c1-8)
            printf "  %-20s %-6s connections, total_time: %ss (acct: %s)\n" \
                "$user" "$conns" "$time" "$cpanel_account"
        done
}

# =============================================================================
# SECTION 3 — PHP-FPM pool status
# =============================================================================
section_php_fpm_audit() {
    section "3. PHP-FPM POOL STATUS"
    echo ""

    _sbuf ""
    _sbuf "=== PHP-FPM ==="

    # Find all PHP-FPM socket/status paths
    local status_found=0
    for php_ver in 5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3; do
        local fpm_status_path="/opt/cpanel/ea-php${php_ver/./}/root/usr/sbin/php-fpm"
        local socket_path="/var/run/ea-php${php_ver/./}-php-fpm.sock"

        if [ -S "$socket_path" ]; then
            log_info "PHP ${php_ver} FPM socket found: $socket_path"

            # Query status via curl to the socket (if status page enabled)
            local fpm_status
            fpm_status=$(curl -s --unix-socket "$socket_path" \
                         "http://localhost/status?full" 2>/dev/null | head -30)

            if [ -n "$fpm_status" ]; then
                echo "$fpm_status" | grep -E "pool:|active processes:|idle processes:|max children reached" | \
                    while read -r l; do log_dim "    $l"; done
                status_found=$((status_found + 1))
            fi
        fi
    done

    # Fallback: count PHP-FPM processes per version
    if [ "$status_found" -eq 0 ]; then
        log_info "PHP-FPM process counts by version:"
        ps aux | grep php-fpm | grep -v grep | \
            awk '{print $11}' | sort | uniq -c | sort -rn | \
            while read -r count cmd; do
                printf "  %-5s %s\n" "$count" "$cmd"
                _sbuf "  PHP-FPM: $count x $cmd"
            done
    fi

    # Long-running PHP CLI (potential abuse — report from cpu_investigate too)
    echo ""
    log_info "PHP CLI processes running > 2 minutes (potential abuse):"
    local found=0
    ps aux | grep "php " | grep -v "php-fpm\|php-cgi\|grep" | \
        while IFS= read -r line; do
            local pid elapsed user cmd
            pid=$(echo "$line"     | awk '{print $2}')
            user=$(echo "$line"    | awk '{print $1}')
            elapsed=$(echo "$line" | awk '{print $11}')
            cmd=$(cat /proc/"$pid"/cmdline 2>/dev/null | tr '\0' ' ' | cut -c1-80)
            local mins
            mins=$(echo "$elapsed" | awk -F: '{if(NF==3) print $1*60+$2; else print $1}')
            if [ "${mins:-0}" -ge 2 ]; then
                log_warn "  PID $pid | User: $user | Elapsed: $elapsed"
                log_dim  "  $cmd"
                _sbuf "  LONG PHP CLI: pid=$pid user=$user elapsed=$elapsed"
                found=$((found + 1))
            fi
        done
    [ "$found" -eq 0 ] && log_ok "No long-running PHP CLI processes."
}

# =============================================================================
# SECTION 4 — Decision helper: Upgrade vs Optimize vs Abuse
# =============================================================================
section_decision_helper() {
    section "4. ADMIN DECISION HELPER"
    echo ""

    _sbuf ""
    _sbuf "=== DECISION HELPER ==="

    log_info "Analyzing patterns to suggest next action..."
    echo ""

    local cpu_total mem_total load_1min cpu_cores
    cpu_total=$(ps aux | awk 'NR>1 {sum+=$3} END {printf "%.0f", sum}')
    mem_total=$(ps aux | awk 'NR>1 {sum+=$4} END {printf "%.0f", sum}')
    cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    read load_1min _ < /proc/loadavg

    local high_load_multiplier
    high_load_multiplier=$(echo "$load_1min / $cpu_cores" | bc -l | awk '{printf "%.1f", $1}')

    printf "${C_BOLD}  %-30s %s${C_RESET}\n" "Metric" "Value"
    echo "  ──────────────────────────────────────────────"
    printf "  %-30s %s%%\n"  "Total CPU% across procs"  "$cpu_total"
    printf "  %-30s %s%%\n"  "Total MEM% across procs"  "$mem_total"
    printf "  %-30s %s\n"    "Load average (1m)"         "$load_1min"
    printf "  %-30s %s cores\n" "CPU cores"              "$cpu_cores"
    printf "  %-30s %sx\n"   "Load multiplier"           "$high_load_multiplier"

    echo ""
    echo -e "  ${C_BOLD}Recommended Actions:${C_RESET}"

    # --- Pattern-based suggestions
    local load_int=${high_load_multiplier%.*}

    # CPU overloaded but RAM OK → likely single account CPU abuse or runaway PHP
    if [ "$cpu_total" -ge 200 ] && [ "$mem_total" -lt 80 ]; then
        log_warn "  → CPU overloaded with normal RAM: likely single account abuse or runaway process"
        log_warn "    Action: Run cpu_investigate.sh --slack to identify culprit"
        _sbuf "SUGGEST: CPU abuse investigation"
    fi

    # Both CPU and RAM high → genuine server capacity issue
    if [ "$cpu_total" -ge 150 ] && [ "$mem_total" -ge 80 ]; then
        log_crit "  → Both CPU and RAM are under heavy load"
        log_crit "    Action: Consider server upgrade or migrating heavy accounts to dedicated VPS"
        _sbuf "SUGGEST: Server upgrade or account migration"
    fi

    # Load very high relative to cores → too many concurrent processes
    if [ "${load_int:-0}" -ge 3 ]; then
        log_warn "  → Load is ${high_load_multiplier}x CPU cores — too many concurrent processes"
        log_warn "    Action: Review PHP-FPM max_children, Apache MaxRequestWorkers, MySQL max_connections"
        _sbuf "SUGGEST: Tune concurrency limits (PHP/Apache/MySQL)"
    fi

    # RAM high, CPU normal → memory leak or swap abuse
    if [ "$mem_total" -ge 90 ] && [ "$cpu_total" -lt 100 ]; then
        log_warn "  → High RAM usage with normal CPU: possible memory leak or misconfigured service"
        log_warn "    Action: Check MySQL innodb_buffer_pool_size, PHP memory_limit, and swap usage"
        _sbuf "SUGGEST: Memory config audit (MySQL buffer pool, PHP limits)"
    fi

    local mysql_conns
    mysql_conns=$(mysql -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null | \
                  awk 'NR==2 {print $2}')
    local mysql_max
    mysql_max=$(mysql -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | \
                awk 'NR==2 {print $2}')

    if [ -n "$mysql_conns" ] && [ -n "$mysql_max" ]; then
        local mysql_pct=$(( (mysql_conns * 100) / mysql_max ))
        if [ "$mysql_pct" -ge 80 ]; then
            log_warn "  → MySQL at ${mysql_pct}% connection capacity (${mysql_conns}/${mysql_max})"
            log_warn "    Action: Enable query caching, audit slow queries, or raise max_connections"
            _sbuf "SUGGEST: MySQL connection limit tuning ($mysql_pct% used)"
        fi
    fi

    echo ""
    log_ok "Decision helper complete."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    header "RESOURCE AUDIT REPORT"
    write_log "resource_audit" "Audit started"

    [ -n "$TARGET_USER" ] && log_info "Account filter: ${TARGET_USER}"

    section_combined_resource_score
    section_mysql_audit
    section_php_fpm_audit
    section_decision_helper

    echo ""
    section "AUDIT COMPLETE"
    log_info "Log saved to: ${LOG_DIR}/resource_audit.log"
    write_log "resource_audit" "Audit complete"

    if [ "$POST_SLACK" = true ]; then
        slack_post "Resource Audit Report" "$SLACK_BUFFER"
        log_info "Findings posted to Slack."
    else
        log_dim "Tip: run with --slack to post findings to Slack"
    fi
}

main "$@"
