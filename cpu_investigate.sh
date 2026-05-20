#!/bin/bash
# =============================================================================
# cpu_investigate.sh — Self-contained CPU Investigation
# Drop anywhere, run as root. No external dependencies.
#
# USAGE:
#   bash cpu_investigate.sh
#   bash cpu_investigate.sh --user sorre657
#   bash cpu_investigate.sh --top 20
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

echo ""
echo -e "${B}╔══════════════════════════════════════════════════════════════╗${N}"
echo -e "${B}  CPU INVESTIGATION — ${HOSTNAME}${N}"
echo -e "${D}  $(date '+%Y-%m-%d %H:%M:%S')  |  Cores: ${CPU_CORES}  |  Load: ${LOAD1} ${LOAD5} ${LOAD15}${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════════╝${N}"

LOAD1_INT=${LOAD1%.*}
LOAD_COLOR=$G
[ "${LOAD1_INT:-0}" -ge "$CPU_CORES" ]                && LOAD_COLOR=$Y
[ "${LOAD1_INT:-0}" -ge $(( CPU_CORES * 2 )) ]        && LOAD_COLOR=$R
echo -e "\n  Load average: ${LOAD_COLOR}${LOAD1} (1m)  ${LOAD5} (5m)  ${LOAD15} (15m)${N}  on ${CPU_CORES} cores"

# =============================================================================
# SECTION 1 — top -c style: full command, sorted by CPU
# =============================================================================
hdr "1. TOP PROCESSES BY CPU  (top -c style)"
echo ""
printf "${B}  %-7s %-14s %5s %5s %9s  %-s${N}\n" \
    "PID" "USER" "%CPU" "%MEM" "ELAPSED" "COMMAND (full)"
echo "  ────────────────────────────────────────────────────────────────────"

PS_OUTPUT=$(ps aux --sort=-%cpu 2>/dev/null | awk 'NR>1')
[ -n "$TARGET_USER" ] && PS_OUTPUT=$(echo "$PS_OUTPUT" | grep "^${TARGET_USER} ")

echo "$PS_OUTPUT" | head -"$TOP_COUNT" | \
while IFS= read -r line; do
    PID=$(echo "$line" | awk '{print $2}')
    USR=$(echo "$line" | awk '{print $1}')
    CPU=$(echo "$line" | awk '{print $3}')
    MEM=$(echo "$line" | awk '{print $4}')

    # Process age from /proc
    ELAPSED="?"
    if [ -f "/proc/$PID/stat" ]; then
        START=$(awk '{print $22}' /proc/$PID/stat 2>/dev/null)
        UPTIME_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
        if [ -n "$START" ] && [ -n "$UPTIME_S" ] && [ "$HZ" -gt 0 ]; then
            AGE=$(( UPTIME_S - START/HZ ))
            if   [ "$AGE" -ge 3600 ]; then ELAPSED="$(( AGE/3600 ))h$(( (AGE%3600)/60 ))m"
            elif [ "$AGE" -ge 60 ];   then ELAPSED="$(( AGE/60 ))m$(( AGE%60 ))s"
            else                           ELAPSED="${AGE}s"
            fi
        fi
    fi

    # Full cmdline for context (shows script path like lsphp shows wp-cron.php)
    CMD=$(cat /proc/$PID/cmdline 2>/dev/null | tr '\0' ' ' | sed 's/  */ /g' | cut -c1-65)
    [ -z "$CMD" ] && CMD=$(echo "$line" | awk '{for(i=11;i<=NF;i++) printf $i" "; print ""}')

    CPU_I=${CPU%.*}
    CLR=$N
    [ "${CPU_I:-0}" -ge 50 ] && CLR=$R
    [ "${CPU_I:-0}" -ge 20 ] && [ "${CPU_I:-0}" -lt 50 ] && CLR=$Y

    CPANEL_TAG=""
    [ -f "/var/cpanel/users/${USR}" ] && CPANEL_TAG=" [cP]"

    printf "${CLR}  %-7s %-14s %5s %5s %9s  %-s${N}%s\n" \
        "$PID" "$USR" "$CPU" "$MEM" "$ELAPSED" "$CMD" "$CPANEL_TAG"
done

# =============================================================================
# SECTION 2 — Per cPanel account CPU rollup with verdict
# =============================================================================
hdr "2. CPU ROLLUP BY cPANEL ACCOUNT"
echo ""
printf "${B}  %-20s %8s %8s %6s  %-s${N}\n" \
    "ACCOUNT" "TOT CPU%" "TOT MEM%" "PROCS" "VERDICT"
echo "  ────────────────────────────────────────────────────────────────────"

declare -A A_CPU A_MEM A_CNT A_CMD

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

for USR in $(for k in "${!A_CPU[@]}"; do echo "${A_CPU[$k]} $k"; done | \
             sort -rn | awk '{print $2}' | head -15); do
    CPU="${A_CPU[$USR]}"
    MEM="${A_MEM[$USR]}"
    CNT="${A_CNT[$USR]}"
    CPU_I=${CPU%.*}
    CLR=$G; VERDICT="Normal"
    if   [ "${CPU_I:-0}" -ge 100 ]; then CLR=$R; VERDICT="CRITICAL — investigate now"
    elif [ "${CPU_I:-0}" -ge 50  ]; then CLR=$Y; VERDICT="HIGH — likely issue"
    elif [ "${CPU_I:-0}" -ge 20  ]; then CLR=$C; VERDICT="Elevated — monitor"
    fi
    printf "${CLR}  %-20s %8s %8s %6s  %-s${N}\n" \
        "$USR" "${CPU}%" "${MEM}%" "$CNT" "$VERDICT"
done

# =============================================================================
# SECTION 3 — CloudLinux LVE usage
# =============================================================================
hdr "3. CLOUDLINUX LVE — TOP RESOURCE CONSUMERS"
echo ""

if command -v lveinfo &>/dev/null; then
    info "LVE historical — top CPU consumers (last 1 hour):"
    echo ""
    lveinfo --period=1h --by-cpu --limit=10 \
        --show-columns=user,aCPU,mCPU,lCPU,aEP,mEP 2>/dev/null || \
        warn "lveinfo returned no data"
    echo ""
fi

if command -v lveps &>/dev/null; then
    info "LVE live snapshot (lveps --show-cpu):"
    echo ""
    lveps --show-cpu 2>/dev/null | head -25 || warn "lveps returned no output"
elif [ -f /var/lve/info ]; then
    info "LVE live data (/var/lve/info):"
    echo ""
    printf "  ${B}%-20s %8s %8s %6s %6s${N}\n" "USER/UID" "CPU%" "MEM" "EP" "NPROC"
    echo "  ──────────────────────────────────────────────────"
    awk -F: 'NR>1 && $2>0 {
        printf "  %-20s %8s %8s %6s %6s\n", $1, $2, $3, $7, $6
    }' /var/lve/info 2>/dev/null | sort -k2 -rn | head -15
else
    warn "CloudLinux LVE tools not found"
    info "Check WHM → CloudLinux → LVE Manager for per-account limits"
fi

# =============================================================================
# SECTION 4 — Web server status + domain/account hit pattern
# =============================================================================
hdr "4. WEB SERVER — ACTIVE REQUESTS & DOMAIN HIT PATTERN"
echo ""

# Detect web server
WS=""; WS_BIN=""
if   pgrep -x lshttpd  &>/dev/null; then WS="LiteSpeed"; WS_BIN="lshttpd"
elif pgrep -x httpd    &>/dev/null; then WS="Apache";    WS_BIN="httpd"
elif pgrep -x apache2  &>/dev/null; then WS="Apache";    WS_BIN="apache2"
fi

if [ -n "$WS" ]; then
    WS_PROCS=$(pgrep -c "$WS_BIN" 2>/dev/null || echo "?")
    WS_CPU=$(ps aux | grep "$WS_BIN" | grep -v grep | \
             awk '{sum+=$3} END {printf "%.1f", sum+0}')
    info "Web server: ${WS} | Workers: ${WS_PROCS} | CPU: ${WS_CPU}%"
fi

# Apache mod_status
echo ""
info "Apache server-status:"
ASTATUS=$(curl -sk --max-time 3 "http://127.0.0.1/server-status?auto" 2>/dev/null)
if [ -n "$ASTATUS" ]; then
    echo "$ASTATUS" | grep -E "BusyWorkers|IdleWorkers|ReqPerSec|Total Accesses" | \
        while IFS= read -r l; do echo -e "    $l"; done

    echo ""
    info "Active requests right now (from server-status):"
    FULL=$(curl -sk --max-time 3 "http://127.0.0.1/server-status" 2>/dev/null)
    # Extract the requests table — grab lines with GET/POST/HEAD
    echo "$FULL" | grep -oE '(GET|POST|HEAD|PUT|DELETE) [^ ]+ HTTP' | \
        sort | uniq -c | sort -rn | head -15 | \
        while read -r cnt req; do printf "    %-6s %s\n" "$cnt" "$req"; done
else
    warn "server-status not reachable — enable in WHM → Apache Config → Server Status"
fi

# Per-domain domlogs — top hit accounts
echo ""
info "Top accounts by recent web hits (cPanel domlogs):"
if [ -d /usr/local/apache/domlogs ]; then
    declare -A DOM_HITS
    for domlog in /usr/local/apache/domlogs/*/; do
        ACCT=$(basename "$domlog")
        [ -f "/var/cpanel/users/${ACCT}" ] || continue
        [ -n "$TARGET_USER" ] && [ "$ACCT" != "$TARGET_USER" ] && continue
        HITS=$(find "$domlog" -name "*.log" -o -name "*access*" 2>/dev/null | \
               xargs -I{} tail -500 {} 2>/dev/null | wc -l)
        [ "${HITS:-0}" -gt 0 ] && DOM_HITS[$ACCT]=$HITS
    done
    for ACCT in $(for k in "${!DOM_HITS[@]}"; do
                      echo "${DOM_HITS[$k]} $k"; done | \
                  sort -rn | awk '{print $2}' | head -15); do
        printf "    %-20s %s recent log lines\n" "$ACCT" "${DOM_HITS[$ACCT]}"
    done
else
    warn "cPanel domlogs not found at /usr/local/apache/domlogs"
fi

# =============================================================================
# SECTION 5 — Abuse indicators
# =============================================================================
hdr "5. ABUSE & ATTACK INDICATORS"
echo ""

# wp-login brute force
info "wp-login.php brute force (active processes):"
WP_PROCS=$(ps aux | grep -i "wp-login" | grep -v grep)
if [ -n "$WP_PROCS" ]; then
    crit "ACTIVE wp-login.php processes — brute force likely in progress:"
    echo "$WP_PROCS" | while IFS= read -r l; do
        USR=$(echo "$l" | awk '{print $1}')
        PID=$(echo "$l" | awk '{print $2}')
        CPU=$(echo "$l" | awk '{print $3}')
        echo -e "    ${R}PID $PID${N} | User: ${Y}$USR${N} | CPU: ${R}${CPU}%${N}"
    done
    echo ""
    info "Attacker IPs from domlogs (wp-login hits):"
    grep -rh "wp-login" /usr/local/apache/domlogs/ 2>/dev/null | \
        awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | \
        while read -r cnt ip; do printf "    %-6s %s\n" "$cnt" "$ip"; done
else
    ok "No wp-login.php brute force processes active."
fi

# xmlrpc abuse
echo ""
info "xmlrpc.php abuse (active processes):"
XMLRPC=$(ps aux | grep -i "xmlrpc" | grep -v grep)
if [ -n "$XMLRPC" ]; then
    crit "xmlrpc.php processes running:"
    echo "$XMLRPC" | awk '{printf "    PID: %-8s User: %-15s CPU: %s%%\n", $2, $1, $3}'
else
    ok "No xmlrpc.php abuse detected."
fi

# Processes from /tmp
echo ""
info "Processes running from /tmp (malware indicator):"
SHADY=$(ls -la /proc/[0-9]*/exe 2>/dev/null | grep -E '-> /tmp/|-> /dev/shm/|-> /var/tmp/')
if [ -n "$SHADY" ]; then
    crit "SUSPICIOUS — processes executing from temp dirs:"
    echo "$SHADY" | while IFS= read -r l; do echo -e "    ${R}$l${N}"; done
else
    ok "No processes running from /tmp or /dev/shm."
fi

# Connection flood
echo ""
info "Top source IPs by active connections:"
ss -tn state established 2>/dev/null | awk 'NR>1{print $5}' | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
    sort | uniq -c | sort -rn | head -8 | \
    while read -r cnt ip; do
        CLR=$N; FLAG=""
        [ "$cnt" -ge 100 ] && CLR=$R && FLAG=" ◄ POSSIBLE FLOOD"
        [ "$cnt" -ge 30  ] && [ "$cnt" -lt 100 ] && CLR=$Y && FLAG=" ◄ ELEVATED"
        printf "${CLR}    %-6s %s%s${N}\n" "$cnt" "$ip" "$FLAG"
    done

# =============================================================================
# SECTION 6 — Suggestions
# =============================================================================
hdr "6. RECOMMENDATIONS"
echo ""

LOAD_I=${LOAD1%.*}
if [ "${LOAD_I:-0}" -ge $(( CPU_CORES * 3 )) ]; then
    crit "Load ${LOAD1} is 3x core count — server severely overloaded"
    echo -e "    ${Y}→${N} Check Section 2 above for the top account and suspend/throttle immediately"
    echo -e "    ${Y}→${N} Check Section 5 for active attack patterns"
elif [ "${LOAD_I:-0}" -ge "$CPU_CORES" ]; then
    warn "Load ${LOAD1} exceeds core count (${CPU_CORES})"
    echo -e "    ${Y}→${N} Monitor accounts in Section 2. Set LVE limits if persistent."
else
    ok "Load is within normal range."
fi

if [ -n "$WP_PROCS" ]; then
    echo ""
    crit "wp-login brute force is actively consuming CPU"
    echo -e "    ${Y}→${N} Block attacker IPs:  csf -d <IP>"
    echo -e "    ${Y}→${N} Block pattern via Imunify WAF or CSF port flood settings"
    echo -e "    ${Y}→${N} Notify account owner — recommend Cloudflare or login limiter plugin"
fi

MYSQL_CPU=$(ps aux | grep -E 'mysqld|mariadbd' | grep -v grep | \
            awk '{sum+=$3} END {printf "%.0f", sum+0}')
if [ "${MYSQL_CPU:-0}" -ge 40 ]; then
    echo ""
    warn "MySQL at ${MYSQL_CPU}% CPU"
    echo -e "    ${Y}→${N} Run: mysql -e 'SHOW FULL PROCESSLIST\\G' | grep -A5 'Time: [0-9][0-9]'"
    echo -e "    ${Y}→${N} Check: tail -50 /var/lib/mysql/*-slow.log"
fi

echo ""
sep
echo -e "${B}  QUICK REFERENCE ONE-LINERS${N}"
sep
echo ""
echo -e "  ${D}# Watch live CPU every 2 seconds:${N}"
echo    "  watch -n2 'ps aux --sort=-%cpu | head -20'"
echo ""
echo -e "  ${D}# All lsphp grouped by account:${N}"
echo    "  ps aux | grep lsphp | grep -v grep | awk '{print \$1}' | sort | uniq -c | sort -rn"
echo ""
echo -e "  ${D}# wp-login attacker IPs from domlogs:${N}"
echo    "  grep -rh wp-login /usr/local/apache/domlogs/ 2>/dev/null | awk '{print \$1}' | sort | uniq -c | sort -rn | head -20"
echo ""
echo -e "  ${D}# Block an IP via CSF:${N}"
echo    "  csf -d <IP>  \"wp-login flood $(date +%Y-%m-%d)\""
echo ""
echo -e "  ${D}# Throttle account via LVE (50% of 1 core):${N}"
echo    "  lvectl set <username> --speed=50% --ncpu=1"
echo ""
echo -e "  ${D}# Check LVE limits for account:${N}"
echo    "  lvectl get <username>"
echo ""
echo -e "  ${D}# Suspend via WHM API:${N}"
echo    "  whmapi1 suspendacct user=<username> reason='CPU abuse'"
echo ""
echo -e "  ${D}# MySQL slow query check:${N}"
echo    "  mysql -e 'SHOW FULL PROCESSLIST\G' | grep -B2 'Time: [0-9][0-9]'"
echo ""
echo -e "${G}${B}  Done — $(date '+%H:%M:%S')${N}"
echo ""
