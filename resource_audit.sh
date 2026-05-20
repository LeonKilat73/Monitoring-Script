#!/bin/bash
# =============================================================================
# resource_audit.sh — Self-contained Resource Audit
# Drop anywhere, run as root. No external dependencies.
#
# PURPOSE: Full server resource consumption audit. Answers:
#   - Which cPanel accounts are putting the most pressure on the server?
#   - Is this abuse, a legitimate heavy site, or a server capacity problem?
#   - What is MySQL doing and who is hammering it?
#   - How are PHP workers distributed across accounts?
#   - What is RAM actually being used for?
#   - Should we upgrade, optimize, throttle, or suspend?
#
# USAGE:
#   bash resource_audit.sh                  # Full audit
#   bash resource_audit.sh --user johndoe   # Deep-dive on one account
#   bash resource_audit.sh --top 20         # Show more accounts (default: 15)
# =============================================================================

TARGET_USER=""
TOP_COUNT=15

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --user) TARGET_USER="$2"; shift ;;
        --top)  TOP_COUNT="$2";   shift ;;
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

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
read LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_AVAIL_KB=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
MEM_USED_KB=$(( MEM_TOTAL_KB - MEM_AVAIL_KB ))
MEM_USED_PCT=$(( MEM_USED_KB * 100 / MEM_TOTAL_KB ))
MEM_TOTAL_MB=$(( MEM_TOTAL_KB / 1024 ))
MEM_USED_MB=$(( MEM_USED_KB / 1024 ))

echo ""
echo -e "${B}╔══════════════════════════════════════════════════════════════╗${N}"
echo -e "${B}  RESOURCE AUDIT — ${HOSTNAME}${N}"
echo -e "${D}  $(date '+%Y-%m-%d %H:%M:%S')  |  Cores: ${CPU_CORES}  |  Load: ${LOAD1} ${LOAD5} ${LOAD15}${N}"
echo -e "${D}  RAM: ${MEM_USED_MB}MB / ${MEM_TOTAL_MB}MB used (${MEM_USED_PCT}%)${N}"
[ -n "$TARGET_USER" ] && echo -e "${D}  Account filter: ${TARGET_USER}${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════════╝${N}"


# =============================================================================
# SERVICE HEALTH CHECK — Nginx, Apache/LiteSpeed, MySQL
# =============================================================================
hdr "0. CRITICAL SERVICE HEALTH CHECK"
echo ""

# Helper: get process uptime from PID
_proc_uptime() {
    local pid="$1"
    local result="unknown"
    if [ -f "/proc/${pid}/stat" ]; then
        local start uptime_s hz age
        start=$(awk '{print $22}' /proc/${pid}/stat 2>/dev/null)
        uptime_s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
        if [ -n "$start" ] && [ -n "$uptime_s" ] && [ "$hz" -gt 0 ]; then
            age=$(( uptime_s - start/hz ))
            if   [ "$age" -ge 86400 ]; then result="$(( age/86400 ))d $(( (age%86400)/3600 ))h"
            elif [ "$age" -ge 3600  ]; then result="$(( age/3600 ))h$(( (age%3600)/60 ))m"
            elif [ "$age" -ge 60    ]; then result="$(( age/60 ))m$(( age%60 ))s"
            else result="${age}s"
            fi
        fi
    fi
    echo "$result"
}

# Helper: get memory usage of a process group in MB
_proc_mem_mb() {
    local pattern="$1"
    ps aux | grep -E "$pattern" | grep -v grep | \
        awk '{sum+=$6} END {printf "%.0f", sum/1024}'
}

printf "  ${B}%-20s %-12s %-10s %-10s %-10s %-s${N}\n" \
    "SERVICE" "STATUS" "PID" "UPTIME" "MEM(MB)" "EXTRA"
echo "  ──────────────────────────────────────────────────────────────────────"

# ---- Nginx ----
NGINX_PID=$(pgrep -f "nginx: master" 2>/dev/null | head -1)
if [ -z "$NGINX_PID" ]; then
    NGINX_PID=$(pgrep -x nginx 2>/dev/null | head -1)
fi

if [ -n "$NGINX_PID" ]; then
    NGINX_UPTIME=$(_proc_uptime "$NGINX_PID")
    NGINX_MEM=$(_proc_mem_mb "nginx")
    NGINX_WORKERS=$(pgrep -c -f "nginx: worker" 2>/dev/null || pgrep -c nginx 2>/dev/null || echo "?")
    NGINX_CPU=$(ps aux | grep nginx | grep -v grep | \
                awk '{sum+=$3} END {printf "%.1f", sum+0}')
    printf "  ${G}%-20s %-12s %-10s %-10s %-10s %-s${N}\n" \
        "Nginx" "RUNNING" "$NGINX_PID" "$NGINX_UPTIME" "${NGINX_MEM}MB" \
        "workers: ${NGINX_WORKERS}  cpu: ${NGINX_CPU}%"

    # Nginx stub_status
    NGINX_ACTIVE=""
    for NURL in "http://127.0.0.1/nginx_status" \
                "http://127.0.0.1:8080/nginx_status" \
                "http://127.0.0.1/status"; do
        NSTATUS=$(curl -sk --max-time 2 "$NURL" 2>/dev/null)
        if [ -n "$NSTATUS" ]; then
            NGINX_ACTIVE=$(echo "$NSTATUS" | grep "Active" | awk '{print $3}')
            NGINX_WRITING=$(echo "$NSTATUS" | grep "Writing" | awk '{print $4}')
            NGINX_WAITING=$(echo "$NSTATUS" | grep "Waiting" | awk '{print $6}')
            break
        fi
    done

    if [ -n "$NGINX_ACTIVE" ]; then
        NGINX_CLR=$G
        [ "${NGINX_ACTIVE:-0}" -ge 200 ] && NGINX_CLR=$Y
        [ "${NGINX_ACTIVE:-0}" -ge 500 ] && NGINX_CLR=$R
        printf "  ${D}%-20s${N} active: ${NGINX_CLR}%s${N}  writing: %s  waiting: %s\n" \
            "  └─ connections" \
            "${NGINX_ACTIVE}" "${NGINX_WRITING:-?}" "${NGINX_WAITING:-?}"
        [ "${NGINX_ACTIVE:-0}" -ge 500 ] && \
            crit "  Nginx connections critically high (${NGINX_ACTIVE}) — possible flood"
        [ "${NGINX_ACTIVE:-0}" -ge 200 ] && [ "${NGINX_ACTIVE:-0}" -lt 500 ] && \
            warn "  Nginx connections elevated (${NGINX_ACTIVE}) — monitor"
    else
        printf "  ${D}%-20s${N} stub_status not enabled\n" "  └─ connections"
    fi
else
    printf "  ${Y}%-20s %-12s${N}\n" "Nginx" "NOT RUNNING"
    warn "  Nginx is not running — if used as proxy, requests go direct to Apache"
    info "  Start: systemctl start nginx"
fi

# ---- Apache / LiteSpeed ----
echo ""
HTTPD_NAME=""; HTTPD_PID=""
if   pgrep -x lshttpd &>/dev/null; then
    HTTPD_NAME="LiteSpeed"; HTTPD_PID=$(pgrep -x lshttpd | head -1)
elif pgrep -x httpd   &>/dev/null; then
    HTTPD_NAME="Apache (httpd)"; HTTPD_PID=$(pgrep -x httpd | head -1)
elif pgrep -x apache2 &>/dev/null; then
    HTTPD_NAME="Apache (apache2)"; HTTPD_PID=$(pgrep -x apache2 | head -1)
fi

if [ -n "$HTTPD_PID" ]; then
    HTTPD_UPTIME=$(_proc_uptime "$HTTPD_PID")
    HTTPD_BIN=$([ "$HTTPD_NAME" = "LiteSpeed" ] && echo "lshttpd" || \
                (pgrep -x httpd &>/dev/null && echo "httpd" || echo "apache2"))
    HTTPD_WORKERS=$(pgrep -c "$HTTPD_BIN" 2>/dev/null || echo "?")
    HTTPD_MEM=$(_proc_mem_mb "$HTTPD_BIN")
    HTTPD_CPU=$(ps aux | grep "$HTTPD_BIN" | grep -v grep | \
                awk '{sum+=$3} END {printf "%.1f", sum+0}')

    printf "  ${G}%-20s %-12s %-10s %-10s %-10s %-s${N}\n" \
        "$HTTPD_NAME" "RUNNING" "$HTTPD_PID" "$HTTPD_UPTIME" "${HTTPD_MEM}MB" \
        "workers: ${HTTPD_WORKERS}  cpu: ${HTTPD_CPU}%"

    # Apache server-status summary
    ASTATUS=$(curl -sk --max-time 3 "http://127.0.0.1/server-status?auto" 2>/dev/null)
    if [ -n "$ASTATUS" ]; then
        BUSY=$(echo "$ASTATUS" | grep -i "BusyWorkers" | awk '{print $2}')
        IDLE=$(echo "$ASTATUS" | grep -i "IdleWorkers" | awk '{print $2}')
        RPS=$(echo  "$ASTATUS" | grep -i "ReqPerSec"   | awk '{print $2}')
        TOTAL_W=$(( ${BUSY:-0} + ${IDLE:-0} ))
        BUSY_CLR=$G
        [ -n "$BUSY" ] && [ "$TOTAL_W" -gt 0 ] && {
            BUSY_PCT=$(( BUSY * 100 / TOTAL_W ))
            [ "$BUSY_PCT" -ge 80 ] && BUSY_CLR=$Y
            [ "$BUSY_PCT" -ge 95 ] && BUSY_CLR=$R
        }
        printf "  ${D}%-20s${N} busy: ${BUSY_CLR}%s${N}  idle: %s  req/s: %s\n" \
            "  └─ server-status" \
            "${BUSY:-?}" "${IDLE:-?}" "${RPS:-?}"
        [ "${BUSY_PCT:-0}" -ge 95 ] && \
            crit "  Apache/LiteSpeed near capacity (${BUSY_PCT}% workers busy)"
        [ "${BUSY_PCT:-0}" -ge 80 ] && [ "${BUSY_PCT:-0}" -lt 95 ] && \
            warn "  Apache/LiteSpeed workers heavily loaded (${BUSY_PCT}%)"
    else
        printf "  ${D}%-20s${N} server-status not enabled\n" "  └─ server-status"
    fi
else
    printf "  ${R}%-20s %-12s${N}\n" "Apache/LiteSpeed" "NOT RUNNING"
    crit "  No web server detected — site requests will fail!"
    info "  Start Apache: systemctl start httpd"
    info "  Start LiteSpeed: systemctl start lsws"
fi

# ---- MySQL / MariaDB ----
echo ""
MYSQL_RUNNING=false
MYSQL_PID=""
MYSQL_NAME=""

# Try multiple detection methods
for SVC in mysqld mariadbd; do
    PID=$(pgrep -x "$SVC" 2>/dev/null | head -1)
    if [ -n "$PID" ]; then
        MYSQL_RUNNING=true
        MYSQL_PID="$PID"
        MYSQL_NAME="$SVC"
        break
    fi
done

# Fallback: pgrep -f for full path matches like /usr/sbin/mysqld
if [ "$MYSQL_RUNNING" = false ]; then
    for SVC in mysqld mariadbd; do
        PID=$(pgrep -f "$SVC" 2>/dev/null | head -1)
        if [ -n "$PID" ]; then
            MYSQL_RUNNING=true
            MYSQL_PID="$PID"
            MYSQL_NAME="$SVC (via path)"
            break
        fi
    done
fi

# Fallback: systemctl
if [ "$MYSQL_RUNNING" = false ]; then
    for SVC in mysqld mariadb mysql; do
        if systemctl is-active "$SVC" &>/dev/null; then
            MYSQL_RUNNING=true
            MYSQL_NAME="$SVC (systemctl)"
            MYSQL_PID=$(systemctl show -p MainPID "$SVC" 2>/dev/null | cut -d= -f2)
            break
        fi
    done
fi

# Fallback: socket file
if [ "$MYSQL_RUNNING" = false ]; then
    for SOCK in /var/lib/mysql/mysql.sock /tmp/mysql.sock /run/mysqld/mysqld.sock; do
        if [ -S "$SOCK" ]; then
            MYSQL_RUNNING=true
            MYSQL_NAME="MySQL (socket found)"
            break
        fi
    done
fi

if [ "$MYSQL_RUNNING" = true ]; then
    MYSQL_UPTIME=$(_proc_uptime "${MYSQL_PID:-0}")
    MYSQL_MEM=$(_proc_mem_mb "mysqld|mariadbd")
    MYSQL_CPU=$(ps aux | grep -E 'mysqld|mariadbd' | grep -v grep | \
                awk '{sum+=$3} END {printf "%.1f", sum+0}')
    MYSQL_CLR=$G
    [ "$(echo "${MYSQL_CPU:-0} >= 40" | bc -l 2>/dev/null)" = "1" ] && MYSQL_CLR=$Y
    [ "$(echo "${MYSQL_CPU:-0} >= 80" | bc -l 2>/dev/null)" = "1" ] && MYSQL_CLR=$R

    printf "  ${G}%-20s %-12s %-10s %-10s %-10s %-s${N}\n" \
        "${MYSQL_NAME}" "RUNNING" "${MYSQL_PID:-—}" \
        "${MYSQL_UPTIME}" "${MYSQL_MEM}MB" \
        "cpu: ${MYSQL_CLR}${MYSQL_CPU}%${N}"

    # Connection stats if we can connect
    if mysql -e "SELECT 1;" &>/dev/null 2>&1; then
        THREADS=$(mysql -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null | \
                  awk 'NR==2{print $2}')
        MAX_CONN=$(mysql -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | \
                   awk 'NR==2{print $2}')
        RUNNING_T=$(mysql -e "SHOW STATUS LIKE 'Threads_running';" 2>/dev/null | \
                    awk 'NR==2{print $2}')
        SLOW_Q=$(mysql -e "SHOW STATUS LIKE 'Slow_queries';" 2>/dev/null | \
                 awk 'NR==2{print $2}')
        CONN_CLR=$G
        if [ -n "$THREADS" ] && [ -n "$MAX_CONN" ] && [ "$MAX_CONN" -gt 0 ]; then
            CONN_PCT=$(( THREADS * 100 / MAX_CONN ))
            [ "$CONN_PCT" -ge 70 ] && CONN_CLR=$Y
            [ "$CONN_PCT" -ge 90 ] && CONN_CLR=$R
            printf "  ${D}%-20s${N} conn: ${CONN_CLR}%s/%s${N}  running: %s  slow_q: %s\n" \
                "  └─ status" \
                "$THREADS" "$MAX_CONN" "${RUNNING_T:-?}" "${SLOW_Q:-?}"
            [ "$CONN_PCT" -ge 90 ] && \
                crit "  MySQL connections at ${CONN_PCT}% — risk of 'Too many connections'"
            [ "$CONN_PCT" -ge 70 ] && [ "$CONN_PCT" -lt 90 ] && \
                warn "  MySQL connections at ${CONN_PCT}% capacity"
        fi
    else
        printf "  ${D}%-20s${N} /root/.my.cnf not set — cannot query stats\n" "  └─ status"
    fi
else
    printf "  ${R}%-20s %-12s${N}\n" "MySQL/MariaDB" "NOT RUNNING"
    crit "  MySQL/MariaDB is not running — all database-driven sites will fail!"
    info "  Start: systemctl start mysqld  or  systemctl start mariadb"
fi

# ---- Summary line ----
echo ""
ALL_OK=true
[ -z "$NGINX_PID" ]   && warn "Nginx: not running"    && ALL_OK=false
[ -z "$HTTPD_PID" ]   && crit "Web server: not running" && ALL_OK=false
[ "$MYSQL_RUNNING" = false ] && crit "MySQL: not running" && ALL_OK=false
[ "$ALL_OK" = true ]  && ok "All critical services are running."

# =============================================================================
# SECTION 1 — Resource Pressure Score per cPanel Account
# Score = CPU% + (MEM% × 0.5)
# Gives a single comparable number per account showing total server impact
# =============================================================================
hdr "1. RESOURCE PRESSURE SCORE — ALL cPANEL ACCOUNTS"
echo ""
echo -e "  ${D}Score = CPU% + (RAM% × 0.5)  —  higher score = more server pressure${N}"
echo ""
printf "${B}  %-20s %8s %8s %8s %7s  %-s${N}\n" \
    "ACCOUNT" "CPU%" "MEM%" "SCORE" "PROCS" "VERDICT"
echo "  ──────────────────────────────────────────────────────────────────────"

declare -A A_CPU A_MEM A_CNT A_CMD A_SCORE

while IFS= read -r line; do
    USR=$(echo "$line" | awk '{print $1}')
    CPU=$(echo "$line" | awk '{print $3}')
    MEM=$(echo "$line" | awk '{print $4}')
    CMD=$(echo "$line" | awk '{print $11}')
    [ -f "/var/cpanel/users/${USR}" ] || continue
    [ -n "$TARGET_USER" ] && [ "$USR" != "$TARGET_USER" ] && continue
    A_CPU[$USR]=$(echo "${A_CPU[$USR]:-0} + ${CPU:-0}" | bc 2>/dev/null || echo 0)
    A_MEM[$USR]=$(echo "${A_MEM[$USR]:-0} + ${MEM:-0}" | bc 2>/dev/null || echo 0)
    A_CNT[$USR]=$(( ${A_CNT[$USR]:-0} + 1 ))
    [ -z "${A_CMD[$USR]}" ] && A_CMD[$USR]="$CMD"
done < <(ps aux | awk 'NR>1')

# Calculate scores
TOP_ACCOUNT=""
TOP_SCORE=0
for USR in "${!A_CPU[@]}"; do
    A_SCORE[$USR]=$(echo "${A_CPU[$USR]} + (${A_MEM[$USR]} * 0.5)" | \
                   bc 2>/dev/null | awk '{printf "%.1f", $1}')
    # Track highest scorer for decision helper
    SCORE_I=${A_SCORE[$USR]%.*}
    if [ "${SCORE_I:-0}" -gt "${TOP_SCORE:-0}" ]; then
        TOP_SCORE=${SCORE_I}
        TOP_ACCOUNT=$USR
    fi
done

for USR in $(for k in "${!A_SCORE[@]}"; do
                 echo "${A_SCORE[$k]} $k"
             done | sort -rn | awk '{print $2}' | head -"$TOP_COUNT"); do

    CPU="${A_CPU[$USR]}"
    MEM="${A_MEM[$USR]}"
    SCORE="${A_SCORE[$USR]}"
    CNT="${A_CNT[$USR]}"
    SCORE_I=${SCORE%.*}

    CLR=$G; VERDICT="Normal"
    if   [ "${SCORE_I:-0}" -ge 100 ]; then CLR=$R; VERDICT="CRITICAL — investigate now"
    elif [ "${SCORE_I:-0}" -ge 50  ]; then CLR=$Y; VERDICT="HIGH — likely causing issues"
    elif [ "${SCORE_I:-0}" -ge 20  ]; then CLR=$C; VERDICT="Elevated — monitor"
    fi

    printf "${CLR}  %-20s %8s %8s %8s %7s  %-s${N}\n" \
        "$USR" "${CPU}%" "${MEM}%" "$SCORE" "$CNT" "$VERDICT"
done

[ -n "$TOP_ACCOUNT" ] && {
    echo ""
    info "Highest pressure account: ${B}${TOP_ACCOUNT}${N} (score: ${TOP_SCORE})"
    info "Deep-dive: bash resource_audit.sh --user ${TOP_ACCOUNT}"
}

# =============================================================================
# SECTION 2 — RAM Usage Breakdown
# =============================================================================
hdr "2. RAM USAGE BREAKDOWN"
echo ""

# Overall RAM
RAM_CLR=$G
[ "$MEM_USED_PCT" -ge 80 ] && RAM_CLR=$Y
[ "$MEM_USED_PCT" -ge 95 ] && RAM_CLR=$R

printf "  %-30s ${RAM_CLR}%s MB / %s MB (%s%%)${N}\n" \
    "RAM Used / Total:" "$MEM_USED_MB" "$MEM_TOTAL_MB" "$MEM_USED_PCT"

# Swap
SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
SWAP_FREE=$(grep SwapFree  /proc/meminfo | awk '{print $2}')
SWAP_USED=$(( SWAP_TOTAL - SWAP_FREE ))
SWAP_TOTAL_MB=$(( SWAP_TOTAL / 1024 ))
SWAP_USED_MB=$(( SWAP_USED / 1024 ))

if [ "$SWAP_TOTAL" -gt 0 ]; then
    SWAP_PCT=$(( SWAP_USED * 100 / SWAP_TOTAL ))
    SWAP_CLR=$G
    [ "$SWAP_PCT" -ge 50 ] && SWAP_CLR=$Y
    [ "$SWAP_PCT" -ge 80 ] && SWAP_CLR=$R
    printf "  %-30s ${SWAP_CLR}%s MB / %s MB (%s%%)${N}\n" \
        "Swap Used / Total:" "$SWAP_USED_MB" "$SWAP_TOTAL_MB" "$SWAP_PCT"
    [ "$SWAP_PCT" -ge 50 ] && \
        warn "High swap usage — server is memory-constrained. RAM upgrade recommended."
else
    printf "  %-30s %s\n" "Swap:" "Not configured"
fi

# Top RAM consumers by process
echo ""
info "Top processes by RAM usage:"
echo ""
printf "  ${B}%-7s %-14s %6s %6s  %-s${N}\n" "PID" "USER" "%MEM" "RSS MB" "COMMAND"
echo "  ──────────────────────────────────────────────────────────────────"
ps aux --sort=-%mem | awk 'NR>1' | head -12 | \
while IFS= read -r line; do
    PID=$(echo "$line" | awk '{print $2}')
    USR=$(echo "$line" | awk '{print $1}')
    MEM=$(echo "$line" | awk '{print $4}')
    RSS=$(echo "$line" | awk '{print $6}')
    RSS_MB=$(( ${RSS:-0} / 1024 ))
    CMD=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ' | cut -c1-55)
    [ -z "$CMD" ] && CMD=$(echo "$line" | awk '{print $11}')
    CPANEL_TAG=""
    [ -f "/var/cpanel/users/${USR}" ] && CPANEL_TAG=" [cP]"
    MEM_I=${MEM%.*}
    CLR=$N
    [ "${MEM_I:-0}" -ge 10 ] && CLR=$Y
    [ "${MEM_I:-0}" -ge 20 ] && CLR=$R
    printf "${CLR}  %-7s %-14s %6s %6s  %-s${N}%s\n" \
        "$PID" "$USR" "$MEM" "$RSS_MB" "$CMD" "$CPANEL_TAG"
done

# Top cPanel accounts by RAM
echo ""
info "Top cPanel accounts by total RAM:"
echo ""
printf "  ${B}%-20s %8s %10s${N}\n" "ACCOUNT" "TOT MEM%" "APPROX MB"
echo "  ──────────────────────────────────────────────────────────────────"
for USR in $(for k in "${!A_MEM[@]}"; do
                 echo "${A_MEM[$k]} $k"
             done | sort -rn | awk '{print $2}' | head -10); do
    MEM="${A_MEM[$USR]}"
    MEM_I=${MEM%.*}
    APPROX_MB=$(echo "$MEM_I * $MEM_TOTAL_MB / 100" | bc 2>/dev/null || echo "?")
    CLR=$N
    [ "${MEM_I:-0}" -ge 20 ] && CLR=$Y
    [ "${MEM_I:-0}" -ge 40 ] && CLR=$R
    printf "${CLR}  %-20s %8s %10s MB${N}\n" "$USR" "${MEM}%" "$APPROX_MB"
done

# =============================================================================
# SECTION 3 — MySQL Resource Audit
# =============================================================================
hdr "3. MYSQL RESOURCE AUDIT"
echo ""

# Detect MySQL/MariaDB using multiple reliable methods
# pgrep -x alone misses full paths like /usr/sbin/mysqld on cPanel servers
MYSQL_RUNNING=false
pgrep -fE "mysqld|mariadbd"      &>/dev/null && MYSQL_RUNNING=true
systemctl is-active mysqld       &>/dev/null && MYSQL_RUNNING=true
systemctl is-active mariadb      &>/dev/null && MYSQL_RUNNING=true
systemctl is-active mysql        &>/dev/null && MYSQL_RUNNING=true
[ -S /var/lib/mysql/mysql.sock ] && MYSQL_RUNNING=true
[ -S /tmp/mysql.sock ]           && MYSQL_RUNNING=true

if [ "$MYSQL_RUNNING" = false ]; then
    warn "MySQL/MariaDB does not appear to be running."
    info "Check: systemctl status mysqld  or  systemctl status mariadb"
elif ! mysql -e "SELECT 1;" &>/dev/null 2>&1; then
    warn "Cannot connect to MySQL. Create /root/.my.cnf:"
    echo ""
    echo -e "    ${D}cat > /root/.my.cnf << EOF${N}"
    echo -e "    ${D}[client]${N}"
    echo -e "    ${D}user=root${N}"
    echo -e "    ${D}password=YOUR_PASSWORD${N}"
    echo -e "    ${D}EOF${N}"
    echo -e "    ${D}chmod 600 /root/.my.cnf${N}"
else
    # MySQL CPU usage
    MYSQL_CPU=$(ps aux | grep -E 'mysqld|mariadbd' | grep -v grep | \
                awk '{sum+=$3} END {printf "%.1f", sum+0}')
    MYSQL_MEM=$(ps aux | grep -E 'mysqld|mariadbd' | grep -v grep | \
                awk '{sum+=$4} END {printf "%.1f", sum+0}')
    MYSQL_CLR=$G
    [ "$(echo "$MYSQL_CPU > 40" | bc -l)" = "1" ] && MYSQL_CLR=$Y
    [ "$(echo "$MYSQL_CPU > 80" | bc -l)" = "1" ] && MYSQL_CLR=$R
    echo -e "  MySQL process CPU: ${MYSQL_CLR}${MYSQL_CPU}%${N}  RAM: ${MYSQL_MEM}%"

    # Key status metrics
    echo ""
    info "MySQL global status (key metrics):"
    echo ""
    printf "  ${B}%-40s %s${N}\n" "METRIC" "VALUE"
    echo "  ──────────────────────────────────────────────────────────────────"
    mysql -e "SHOW GLOBAL STATUS;" 2>/dev/null | \
        grep -E "^(Threads_connected|Threads_running|Slow_queries|Questions|\
Max_used_connections|Aborted_connects|Table_locks_waited|\
Innodb_buffer_pool_reads|Innodb_buffer_pool_read_requests|\
Created_tmp_disk_tables|Handler_read_rnd_next)" | \
        while IFS=$'\t' read -r key val; do
            # Flag concerning values
            CLR=$N; FLAG=""
            case "$key" in
                Slow_queries)
                    [ "${val:-0}" -gt 100 ] && CLR=$Y && FLAG=" ◄ HIGH"  ;;
                Table_locks_waited)
                    [ "${val:-0}" -gt 0   ] && CLR=$Y && FLAG=" ◄ LOCK CONTENTION" ;;
            esac
            printf "${CLR}  %-40s %s%s${N}\n" "$key" "$val" "$FLAG"
        done

    # Connection capacity
    echo ""
    THREADS_CONN=$(mysql -e "SHOW STATUS LIKE 'Threads_connected';" 2>/dev/null | \
                   awk 'NR==2{print $2}')
    MAX_CONN=$(mysql -e "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | \
               awk 'NR==2{print $2}')
    if [ -n "$THREADS_CONN" ] && [ -n "$MAX_CONN" ] && [ "$MAX_CONN" -gt 0 ]; then
        CONN_PCT=$(( THREADS_CONN * 100 / MAX_CONN ))
        CONN_CLR=$G
        [ "$CONN_PCT" -ge 70 ] && CONN_CLR=$Y
        [ "$CONN_PCT" -ge 90 ] && CONN_CLR=$R
        printf "  %-40s ${CONN_CLR}%s / %s (%s%%)${N}\n" \
            "Connections used/max:" "$THREADS_CONN" "$MAX_CONN" "$CONN_PCT"
        [ "$CONN_PCT" -ge 80 ] && \
            warn "MySQL connections near capacity — risk of 'Too many connections' errors"
    fi

    # InnoDB buffer pool hit ratio
    echo ""
    READS=$(mysql -e "SHOW STATUS LIKE 'Innodb_buffer_pool_reads';" \
            2>/dev/null | awk 'NR==2{print $2}')
    READ_REQS=$(mysql -e "SHOW STATUS LIKE 'Innodb_buffer_pool_read_requests';" \
                2>/dev/null | awk 'NR==2{print $2}')
    if [ -n "$READS" ] && [ -n "$READ_REQS" ] && [ "${READ_REQS:-0}" -gt 0 ]; then
        HIT_RATIO=$(echo "scale=2; (1 - $READS/$READ_REQS) * 100" | bc 2>/dev/null)
        HIT_CLR=$G
        [ "$(echo "$HIT_RATIO < 95" | bc -l 2>/dev/null)" = "1" ] && HIT_CLR=$Y
        [ "$(echo "$HIT_RATIO < 90" | bc -l 2>/dev/null)" = "1" ] && HIT_CLR=$R
        printf "  %-40s ${HIT_CLR}%s%%${N}\n" "InnoDB buffer pool hit ratio:" "$HIT_RATIO"
        [ "$(echo "$HIT_RATIO < 95" | bc -l 2>/dev/null)" = "1" ] && \
            warn "Low buffer pool hit ratio — consider increasing innodb_buffer_pool_size"
    fi

    # Slow / active queries
    echo ""
    info "Active queries running > 5 seconds:"
    SLOW_Q=$(mysql -e "SHOW FULL PROCESSLIST;" 2>/dev/null | \
             awk -F'\t' 'NR>1 && $7+0 > 5 && $5 != "Sleep"')
    if [ -n "$SLOW_Q" ]; then
        echo ""
        printf "  ${B}%-6s %-15s %-15s %6s  %-s${N}\n" "ID" "USER" "DB" "TIME(s)" "QUERY"
        echo "  ──────────────────────────────────────────────────────────────────"
        echo "$SLOW_Q" | while IFS=$'\t' read -r id usr host db cmd tm state info; do
            warn "  %-6s %-15s %-15s %6s  %-s" "$id" "$usr" "$db" "$tm" "${info:0:60}"
        done
    else
        ok "No active queries running > 5 seconds."
    fi

    # Top connections per cPanel user
    echo ""
    info "MySQL connections by cPanel account:"
    mysql -e "SELECT user, COUNT(*) AS conns, SUM(time) AS total_time
              FROM information_schema.processlist
              WHERE user NOT IN ('root','system user','event_scheduler','rdsadmin')
              GROUP BY user ORDER BY conns DESC LIMIT 12;" 2>/dev/null | \
        tail -n +2 | \
        while IFS=$'\t' read -r usr conns total_time; do
            # cPanel DB users are prefixed with up to 8 chars of account name
            ACCT_PREFIX=$(echo "$usr" | cut -c1-8)
            printf "    %-20s %4s conns  total_time: %ss  (account prefix: %s)\n" \
                "$usr" "$conns" "${total_time:-0}" "$ACCT_PREFIX"
        done

    # Top databases by size
    echo ""
    info "Top databases by size:"
    echo ""
    printf "  ${B}%-40s %12s${N}\n" "DATABASE" "SIZE"
    echo "  ──────────────────────────────────────────────────────────────────"
    mysql -e "
        SELECT table_schema,
               ROUND(SUM(data_length + index_length)/1024/1024, 1) AS size_mb
        FROM information_schema.tables
        WHERE table_schema NOT IN
            ('information_schema','performance_schema','mysql','sys')
        GROUP BY table_schema
        ORDER BY size_mb DESC LIMIT 15;" 2>/dev/null | tail -n +2 | \
        while IFS=$'\t' read -r db size; do
            SIZE_I=${size%.*}
            CLR=$N
            [ "${SIZE_I:-0}" -ge 1000 ] && CLR=$Y
            [ "${SIZE_I:-0}" -ge 5000 ] && CLR=$R
            printf "${CLR}  %-40s %10s MB${N}\n" "$db" "$size"
        done
fi

# =============================================================================
# SECTION 4 — PHP Workers & Process Audit
# =============================================================================
hdr "4. PHP WORKERS & PROCESS AUDIT"
echo ""

# PHP version counts in use
info "PHP processes by type and version:"
echo ""
printf "  ${B}%-35s %s${N}\n" "PHP HANDLER" "COUNT"
echo "  ──────────────────────────────────────────────────────────────────"

# lsphp (LiteSpeed PHP)
LSPHP_COUNT=$(ps aux | grep -c "[l]sphp" || echo 0)
[ "${LSPHP_COUNT:-0}" -gt 0 ] && \
    printf "  %-35s %s\n" "lsphp (LiteSpeed):" "$LSPHP_COUNT"

# PHP-FPM per version
for VER in 54 55 56 70 71 72 73 74 80 81 82 83; do
    VER_DOT="${VER:0:1}.${VER:1}"
    COUNT=$(ps aux | grep -c "[e]a-php${VER}" || echo 0)
    [ "${COUNT:-0}" -gt 0 ] && \
        printf "  %-35s %s\n" "PHP-FPM ${VER_DOT} (ea-php${VER}):" "$COUNT"
done

# PHP-CGI
PHP_CGI=$(ps aux | grep -c "[p]hp-cgi" || echo 0)
[ "${PHP_CGI:-0}" -gt 0 ] && \
    printf "  %-35s %s\n" "PHP-CGI:" "$PHP_CGI"

# PHP CLI (often abuse indicator)
PHP_CLI=$(ps aux | grep "[p]hp " | grep -v "fpm\|cgi" | wc -l)
PHP_CLI_CLR=$N
[ "${PHP_CLI:-0}" -ge 5  ] && PHP_CLI_CLR=$Y
[ "${PHP_CLI:-0}" -ge 20 ] && PHP_CLI_CLR=$R
printf "  %-35s ${PHP_CLI_CLR}%s${N}\n" "PHP CLI (scripts/abuse indicator):" "$PHP_CLI"

# lsphp by account
if [ "${LSPHP_COUNT:-0}" -gt 0 ]; then
    echo ""
    info "lsphp workers grouped by cPanel account:"
    echo ""
    printf "  ${B}%-20s %8s  %-s${N}\n" "ACCOUNT" "WORKERS" "TOP SCRIPT"
    echo "  ──────────────────────────────────────────────────────────────────"
    ps aux | grep "[l]sphp" | awk '{print $1}' | \
        sort | uniq -c | sort -rn | head -15 | \
        while read -r cnt usr; do
            # Get top script for this user
            TOP_SCRIPT=$(ps aux | grep "[l]sphp" | grep "^${usr} " | \
                         grep -oE '/home/[^/]+/[^ ]+' | head -1 | \
                         sed "s|/home/${usr}/||" | cut -c1-40)
            CLR=$N
            [ "$cnt" -ge 20 ] && CLR=$Y
            [ "$cnt" -ge 50 ] && CLR=$R
            printf "${CLR}  %-20s %8s  %-s${N}\n" "$usr" "$cnt" "${TOP_SCRIPT:-—}"
        done
fi

# Long-running PHP CLI (> 2 min — spam scripts, scrapers, crypto miners)
echo ""
info "Long-running PHP CLI processes (>2 min — investigate these):"
LONG_PHP_FOUND=0
ps aux | grep "[p]hp " | grep -vE "fpm|cgi" | \
    while IFS= read -r line; do
        PID=$(echo "$line"  | awk '{print $2}')
        USR=$(echo "$line"  | awk '{print $1}')
        CPU=$(echo "$line"  | awk '{print $3}')
        ETIME=$(echo "$line" | awk '{print $10}')
        # Parse elapsed time
        MINS=$(echo "$ETIME" | awk -F: '{
            if(NF==3) print $1*60+$2
            else if(NF==2) print $1
            else print 0}')
        if [ "${MINS:-0}" -ge 2 ]; then
            CMD=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ' | cut -c1-70)
            warn "  PID: $PID | User: $USR | CPU: ${CPU}% | Elapsed: $ETIME"
            echo -e "    ${D}$CMD${N}"
            LONG_PHP_FOUND=$((LONG_PHP_FOUND + 1))
        fi
    done
[ "$LONG_PHP_FOUND" -eq 0 ] && ok "No long-running PHP CLI processes found."

# PHP-FPM socket status (if available)
echo ""
info "PHP-FPM pool status (via sockets):"
FPM_FOUND=0
for VER in 54 55 56 70 71 72 73 74 80 81 82 83; do
    SOCK="/var/run/ea-php${VER}-php-fpm.sock"
    [ -S "$SOCK" ] || continue
    VER_DOT="${VER:0:1}.${VER:1}"
    FPM_STATUS=$(curl -s --unix-socket "$SOCK" \
                 "http://localhost/status" 2>/dev/null)
    if [ -n "$FPM_STATUS" ]; then
        echo ""
        echo -e "    ${B}PHP ${VER_DOT} FPM:${N}"
        echo "$FPM_STATUS" | \
            grep -E "pool:|active processes:|idle processes:|max children reached|listen queue" | \
            while IFS= read -r l; do echo "      $l"; done
        FPM_FOUND=$((FPM_FOUND + 1))
    fi
done
[ "$FPM_FOUND" -eq 0 ] && \
    info "No PHP-FPM status pages reachable (status page may not be configured)"

# =============================================================================
# SECTION 5 — CloudLinux LVE Audit (if available)
# =============================================================================
hdr "5. CLOUDLINUX LVE AUDIT"
echo ""

if ! command -v lvectl &>/dev/null && ! command -v lveinfo &>/dev/null; then
    warn "CloudLinux LVE tools not found (lvectl/lveinfo)"
    info "If CloudLinux is installed: check WHM → CloudLinux → LVE Manager"
else
    # LVE historical — top CPU and memory users
    if command -v lveinfo &>/dev/null; then
        info "LVE top CPU consumers (last 1 hour):"
        echo ""
        lveinfo --period=1h --by-cpu --limit=12 \
            --show-columns=user,aCPU,mCPU,lCPU,aEP,mEP,aVMem,mVMem \
            2>/dev/null || warn "lveinfo returned no data (lve-stats may not be running)"

        echo ""
        info "LVE top memory consumers (last 1 hour):"
        echo ""
        lveinfo --period=1h --by-mem --limit=12 \
            --show-columns=user,aVMem,mVMem,lVMem,aCPU,aEP \
            2>/dev/null || true
    fi

    # Live LVE snapshot
    if command -v lveps &>/dev/null; then
        echo ""
        info "Live LVE snapshot (lveps):"
        echo ""
        lveps --show-cpu 2>/dev/null | head -20 || \
            warn "lveps returned no output"
    elif [ -f /var/lve/info ]; then
        echo ""
        info "Live LVE data (/var/lve/info):"
        echo ""
        printf "  ${B}%-20s %8s %8s %6s %6s${N}\n" "UID/USER" "CPU%" "MEM" "EP" "NPROC"
        echo "  ──────────────────────────────────────────────────────────────────"
        awk -F: 'NR>1 && $2>0 {
            printf "  %-20s %8s %8s %6s %6s\n", $1, $2, $3, $7, $6
        }' /var/lve/info 2>/dev/null | sort -k2 -rn | head -15
    fi

    # Accounts hitting LVE limits
    echo ""
    info "Accounts hitting LVE limits (fault events in last 1h):"
    if command -v lveinfo &>/dev/null; then
        lveinfo --period=1h --limit=10 \
            --show-columns=user,mCPU,mEP,mVMem,lCPU,lEP,lVMem \
            --by-fault=cpu 2>/dev/null | head -15 || true
    fi
fi

# =============================================================================
# SECTION 6 — Web Server Slot Usage
# =============================================================================
hdr "6. WEB SERVER SLOT USAGE"
echo ""

WS=""; WS_BIN=""
if   pgrep -x lshttpd  &>/dev/null; then WS="LiteSpeed"; WS_BIN="lshttpd"
elif pgrep -x httpd    &>/dev/null; then WS="Apache";    WS_BIN="httpd"
elif pgrep -x apache2  &>/dev/null; then WS="Apache";    WS_BIN="apache2"
fi

if [ -z "$WS" ]; then
    warn "No Apache/LiteSpeed process detected."
else
    WS_COUNT=$(pgrep -c "$WS_BIN" 2>/dev/null || echo 0)
    WS_CPU=$(ps aux | grep "$WS_BIN" | grep -v grep | \
             awk '{sum+=$3} END {printf "%.1f", sum+0}')
    WS_MEM=$(ps aux | grep "$WS_BIN" | grep -v grep | \
             awk '{sum+=$4} END {printf "%.1f", sum+0}')

    info "Web server  : $WS"
    info "Workers     : $WS_COUNT processes"
    info "CPU total   : ${WS_CPU}%"
    info "RAM total   : ${WS_MEM}%"

    # Apache server-status
    echo ""
    ASTATUS=$(curl -sk --max-time 3 "http://127.0.0.1/server-status?auto" 2>/dev/null)
    if [ -n "$ASTATUS" ]; then
        info "Apache server-status:"
        echo "$ASTATUS" | \
            grep -E "BusyWorkers|IdleWorkers|ReqPerSec|BytesPerSec|Uptime" | \
            while IFS= read -r l; do echo "    $l"; done
    fi

    # Workers per user
    echo ""
    info "Web server workers per cPanel account:"
    echo ""
    printf "  ${B}%-20s %8s${N}\n" "ACCOUNT" "WORKERS"
    echo "  ──────────────────────────────────────────────────────────────────"
    ps aux | grep "$WS_BIN" | grep -v grep | \
        awk '{print $1}' | sort | uniq -c | sort -rn | head -15 | \
        while read -r cnt usr; do
            CLR=$N
            [ "$cnt" -ge 20 ] && CLR=$Y
            [ "$cnt" -ge 50 ] && CLR=$R
            printf "${CLR}  %-20s %8s${N}\n" "$usr" "$cnt"
        done
fi

# =============================================================================
# SECTION 7 — Decision Helper: Upgrade vs Optimize vs Abuse
# =============================================================================
hdr "7. DECISION HELPER — WHAT ACTION TO TAKE"
echo ""

CPU_TOTAL=$(ps aux | awk 'NR>1 {sum+=$3} END {printf "%.0f", sum+0}')
LOAD1_INT=${LOAD1%.*}
LOAD_MULTI=$(echo "scale=1; $LOAD1 / $CPU_CORES" | bc 2>/dev/null || echo "?")

printf "  ${B}%-35s %s${N}\n" "METRIC" "VALUE"
echo "  ──────────────────────────────────────────────────────────────────"
printf "  %-35s %s%%\n"    "Total CPU across all procs:"  "$CPU_TOTAL"
printf "  %-35s %s%%\n"    "Total RAM used:"               "$MEM_USED_PCT"
printf "  %-35s %s\n"      "Load average (1m/5m/15m):"    "$LOAD1 / $LOAD5 / $LOAD15"
printf "  %-35s %s cores\n" "CPU cores:"                  "$CPU_CORES"
printf "  %-35s %sx\n"     "Load multiplier (load/cores):" "$LOAD_MULTI"
[ -n "$TOP_ACCOUNT" ] && \
printf "  %-35s %s (score: %s)\n" "Highest pressure account:" "$TOP_ACCOUNT" "$TOP_SCORE"

echo ""
sep
echo -e "${B}  DIAGNOSIS${N}"
sep
echo ""

ISSUES=0

# --- Single account abuse
if [ -n "$TOP_ACCOUNT" ] && [ "${TOP_SCORE:-0}" -ge 80 ]; then
    crit "Account ${TOP_ACCOUNT} has pressure score ${TOP_SCORE} — likely the culprit"
    echo -e "    ${Y}→${N} Run: bash cpu_investigate.sh --user ${TOP_ACCOUNT}"
    echo -e "    ${Y}→${N} Check for brute force, spam scripts, or runaway processes"
    echo -e "    ${Y}→${N} Throttle via LVE: lvectl set ${TOP_ACCOUNT} --speed=50% --ncpu=1"
    echo -e "    ${Y}→${N} Or suspend: whmapi1 suspendacct user=${TOP_ACCOUNT} reason='Resource abuse'"
    ISSUES=$((ISSUES + 1))
fi

# --- High load vs cores
if [ "${LOAD1_INT:-0}" -ge $(( CPU_CORES * 3 )) ]; then
    crit "Load ${LOAD1} is 3x+ core count — server severely overloaded"
    echo -e "    ${Y}→${N} This is beyond normal spikes — identify and suspend top account above"
    echo -e "    ${Y}→${N} Check for DDoS or brute force: bash firewall_status.sh"
    ISSUES=$((ISSUES + 1))
elif [ "${LOAD1_INT:-0}" -ge "$CPU_CORES" ]; then
    warn "Load ${LOAD1} exceeds core count (${CPU_CORES})"
    echo -e "    ${Y}→${N} Monitor — if persistent over 15m, investigate top account"
    ISSUES=$((ISSUES + 1))
else
    ok "Load is within acceptable range for ${CPU_CORES} cores."
fi

# --- RAM pressure
if [ "$MEM_USED_PCT" -ge 95 ]; then
    crit "RAM at ${MEM_USED_PCT}% — OOM killer risk"
    echo -e "    ${Y}→${N} Immediate: identify top RAM account above and throttle/migrate"
    echo -e "    ${Y}→${N} Check MySQL innodb_buffer_pool_size — may be oversized"
    echo -e "    ${Y}→${N} Long-term: RAM upgrade or migrate heavy accounts to VPS"
    ISSUES=$((ISSUES + 1))
elif [ "$MEM_USED_PCT" -ge 80 ]; then
    warn "RAM at ${MEM_USED_PCT}% — elevated"
    echo -e "    ${Y}→${N} Optimize MySQL buffer pool and PHP memory limits"
    echo -e "    ${Y}→${N} Consider migrating top RAM accounts to VPS plans"
    ISSUES=$((ISSUES + 1))
fi

# --- Swap in use
if [ "${SWAP_TOTAL:-0}" -gt 0 ] && [ "${SWAP_PCT:-0}" -ge 50 ]; then
    crit "Swap at ${SWAP_PCT}% — system is memory-swapping"
    echo -e "    ${Y}→${N} Server is RAM-constrained. Processes are using slow disk swap."
    echo -e "    ${Y}→${N} Action: RAM upgrade is the correct fix here"
    echo -e "    ${Y}→${N} Short-term: migrate heaviest RAM accounts to dedicated VPS"
    ISSUES=$((ISSUES + 1))
fi

# --- Both CPU and RAM high → capacity issue
if [ "${CPU_TOTAL:-0}" -ge 150 ] && [ "$MEM_USED_PCT" -ge 80 ]; then
    crit "Both CPU and RAM are under heavy sustained load"
    echo -e "    ${Y}→${N} Pattern: server is genuinely at capacity, not just one bad account"
    echo -e "    ${Y}→${N} Action: migrate top 3-5 heaviest accounts to VPS/cloud"
    echo -e "    ${Y}→${N} Or: upgrade server CPU/RAM"
    ISSUES=$((ISSUES + 1))
fi

# --- CPU high, RAM OK → single account or attack
if [ "${CPU_TOTAL:-0}" -ge 200 ] && [ "$MEM_USED_PCT" -lt 70 ]; then
    warn "CPU heavily loaded but RAM is normal — likely single account or attack"
    echo -e "    ${Y}→${N} Run: bash cpu_investigate.sh  to identify the process"
    echo -e "    ${Y}→${N} Check Section 5 (connection analysis) in: bash firewall_status.sh"
    ISSUES=$((ISSUES + 1))
fi

# --- Many PHP CLI processes
if [ "${PHP_CLI:-0}" -ge 10 ]; then
    warn "High PHP CLI process count (${PHP_CLI}) — possible spam scripts or scrapers"
    echo -e "    ${Y}→${N} Run: bash mail_investigate.sh  to check for mail queue issues"
    echo -e "    ${Y}→${N} Check Section 4 above for long-running PHP CLI by account"
    ISSUES=$((ISSUES + 1))
fi

# --- MySQL connection pressure
if [ -n "$CONN_PCT" ] && [ "${CONN_PCT:-0}" -ge 80 ]; then
    warn "MySQL connections at ${CONN_PCT}% capacity"
    echo -e "    ${Y}→${N} Tune: max_connections in /etc/my.cnf"
    echo -e "    ${Y}→${N} Enable: query cache or connection pooling (ProxySQL)"
    echo -e "    ${Y}→${N} Audit: slow query log for inefficient queries"
    ISSUES=$((ISSUES + 1))
fi

echo ""
if [ "$ISSUES" -eq 0 ]; then
    ok "No critical resource issues detected. Server appears healthy."
fi

# =============================================================================
# SECTION 8 — Optimization Quick Reference
# =============================================================================
hdr "8. OPTIMIZATION QUICK REFERENCE"
echo ""

echo -e "  ${B}LVE / CloudLinux:${N}"
echo ""
echo -e "  ${D}# View LVE limits for account:${N}"
echo    "  lvectl get <username>"
echo ""
echo -e "  ${D}# Throttle CPU for abusive account:${N}"
echo    "  lvectl set <username> --speed=50% --ncpu=1"
echo ""
echo -e "  ${D}# Set memory limit:${N}"
echo    "  lvectl set <username> --vmem=512M"
echo ""
echo -e "  ${D}# Reset to default limits:${N}"
echo    "  lvectl delete <username>"
echo ""
echo -e "  ${D}# View LVE usage history (last 24h):${N}"
echo    "  lveinfo --period=24h --by-cpu --limit=20"
echo ""
echo -e "  ${B}MySQL Optimization:${N}"
echo ""
echo -e "  ${D}# Live active queries:${N}"
echo    "  mysql -e 'SHOW FULL PROCESSLIST\G' | grep -B5 'Time: [0-9][0-9]'"
echo ""
echo -e "  ${D}# Kill a slow query:${N}"
echo    "  mysql -e 'KILL QUERY <process_id>;'"
echo ""
echo -e "  ${D}# Check slow query log:${N}"
echo    "  tail -100 /var/lib/mysql/*-slow.log"
echo ""
echo -e "  ${D}# InnoDB buffer pool size (should be 70-80% of RAM):${N}"
echo    "  mysql -e \"SHOW VARIABLES LIKE 'innodb_buffer_pool_size';\""
echo ""
echo -e "  ${B}PHP Worker Tuning:${N}"
echo ""
echo -e "  ${D}# Restart PHP-FPM for a version:${N}"
echo    "  service ea-php82-php-fpm restart"
echo ""
echo -e "  ${D}# lsphp workers by account (live):${N}"
echo    "  ps aux | grep lsphp | grep -v grep | awk '{print \$1}' | sort | uniq -c | sort -rn"
echo ""
echo -e "  ${D}# Kill all lsphp for one account:${N}"
echo    "  pkill -u <username> lsphp"
echo ""
echo -e "  ${B}Account Management:${N}"
echo ""
echo -e "  ${D}# Suspend via WHM CLI:${N}"
echo    "  whmapi1 suspendacct user=<username> reason='Resource abuse'"
echo ""
echo -e "  ${D}# Unsuspend:${N}"
echo    "  whmapi1 unsuspendacct user=<username>"
echo ""
echo -e "  ${D}# Get account resource usage summary:${N}"
echo    "  whmapi1 accountsummary user=<username>"
echo ""

sep
echo -e "${G}${B}  Done — $(date '+%H:%M:%S')${N}"
sep
echo ""
