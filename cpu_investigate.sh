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
[ "${LOAD1_INT:-0}" -ge "$CPU_CORES" ]             && LOAD_COLOR=$Y
[ "${LOAD1_INT:-0}" -ge $(( CPU_CORES * 2 )) ]     && LOAD_COLOR=$R
echo -e "\n  Load: ${LOAD_COLOR}${LOAD1} (1m)  ${LOAD5} (5m)  ${LOAD15} (15m)${N}  on ${CPU_CORES} cores"

# =============================================================================
# SECTION 1 — Top processes by CPU (top -c style)
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
# SECTION 2 — Per cPanel account CPU rollup
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

TOP_CPU_ACCOUNT=""
TOP_CPU_SCORE=0

for USR in $(for k in "${!A_CPU[@]}"; do echo "${A_CPU[$k]} $k"; done | \
             sort -rn | awk '{print $2}' | head -"$TOP_COUNT"); do
    CPU="${A_CPU[$USR]}"
    MEM="${A_MEM[$USR]}"
    CNT="${A_CNT[$USR]}"
    CPU_I=${CPU%.*}
    CLR=$G; VERDICT="Normal"
    if   [ "${CPU_I:-0}" -ge 100 ]; then CLR=$R; VERDICT="CRITICAL — investigate now"
    elif [ "${CPU_I:-0}" -ge 50  ]; then CLR=$Y; VERDICT="HIGH — likely issue"
    elif [ "${CPU_I:-0}" -ge 20  ]; then CLR=$C; VERDICT="Elevated — monitor"
    fi
    # Track top account for recommendations
    if [ "${CPU_I:-0}" -gt "${TOP_CPU_SCORE:-0}" ]; then
        TOP_CPU_SCORE=${CPU_I}
        TOP_CPU_ACCOUNT=$USR
    fi
    printf "${CLR}  %-20s %8s %8s %6s  %-s${N}\n" \
        "$USR" "${CPU}%" "${MEM}%" "$CNT" "$VERDICT"
done

# =============================================================================
# SECTION 3 — CloudLinux LVE (with your exact column format)
# =============================================================================
hdr "3. CLOUDLINUX LVE — RESOURCE FAULTS (last 15 minutes)"
echo ""

if ! command -v lveinfo &>/dev/null; then
    warn "lveinfo not found — CloudLinux may not be installed."
    info "Check: WHM → CloudLinux → LVE Manager"
else
    info "LVE fault report (last 15m) — accounts hitting resource limits:"
    echo ""

    # Your exact requested column format
    lveinfo -d --period=15m --limit 20 -o any_faults \
        --show-columns id,from,to,iopsf,iof,cpuf,epf,pmemf,mcpu,ucpu,uep,upmem,nprocf \
        2>/dev/null || warn "lveinfo returned no data (lve-stats may not be running)"

    echo ""
    info "Column reference:"
    echo -e "  ${D}id=account  from/to=time window  iopsf=IOPS faults  iof=IO faults${N}"
    echo -e "  ${D}cpuf=CPU faults  epf=entry process faults  pmemf=physical mem faults${N}"
    echo -e "  ${D}mcpu=max CPU%  ucpu=avg CPU%  uep=avg entry procs  upmem=avg phys mem${N}"
    echo -e "  ${D}nprocf=nproc faults (too many processes)${N}"

    # Additional: top by CPU for context
    echo ""
    info "LVE top CPU consumers (last 15m) — for comparison:"
    echo ""
    lveinfo --period=15m --by-cpu --limit=10 \
        --show-columns=id,aCPU,mCPU,lCPU,aEP,mEP 2>/dev/null || true

    # Live snapshot
    echo ""
    if command -v lveps &>/dev/null; then
        info "LVE live snapshot right now (lveps):"
        echo ""
        lveps --show-cpu 2>/dev/null | head -20 || \
            warn "lveps returned no output"
    elif [ -f /var/lve/info ]; then
        info "LVE live data (/var/lve/info):"
        echo ""
        printf "  ${B}%-20s %8s %8s %6s %6s${N}\n" "UID/USER" "CPU%" "MEM" "EP" "NPROC"
        echo "  ──────────────────────────────────────────────────"
        awk -F: 'NR>1 && $2>0 {
            printf "  %-20s %8s %8s %6s %6s\n", $1, $2, $3, $7, $6
        }' /var/lve/info 2>/dev/null | sort -k2 -rn | head -15
    fi

    # LVE recommendations based on faults
    echo ""
    LVE_CPU_FAULTS=$(lveinfo --period=15m -o cpuf --limit=1 \
        --show-columns=id,cpuf 2>/dev/null | awk 'NR>2 && $2>0 {print $1}' | head -1)
    LVE_EP_FAULTS=$(lveinfo --period=15m -o epf --limit=1 \
        --show-columns=id,epf 2>/dev/null | awk 'NR>2 && $2>0 {print $1}' | head -1)
    LVE_MEM_FAULTS=$(lveinfo --period=15m -o pmemf --limit=1 \
        --show-columns=id,pmemf 2>/dev/null | awk 'NR>2 && $2>0 {print $1}' | head -1)

    if [ -n "$LVE_CPU_FAULTS" ] || [ -n "$LVE_EP_FAULTS" ] || [ -n "$LVE_MEM_FAULTS" ]; then
        echo ""
        warn "LVE faults detected in last 15m — accounts are hitting limits:"
        [ -n "$LVE_CPU_FAULTS" ] && \
            echo -e "    ${Y}→${N} CPU faults: ${LVE_CPU_FAULTS} — account hitting CPU limit"
        [ -n "$LVE_EP_FAULTS"  ] && \
            echo -e "    ${Y}→${N} EP faults:  ${LVE_EP_FAULTS} — too many entry processes (PHP workers)"
        [ -n "$LVE_MEM_FAULTS" ] && \
            echo -e "    ${Y}→${N} MEM faults: ${LVE_MEM_FAULTS} — account hitting memory limit"
        echo -e "    ${Y}→${N} View current limits: lvectl get <username>"
        echo -e "    ${Y}→${N} Raise CPU limit:     lvectl set <username> --speed=200%"
        echo -e "    ${Y}→${N} Raise EP limit:      lvectl set <username> --maxEntryProcs=20"
        echo -e "    ${Y}→${N} Or upgrade in WHM:   WHM → CloudLinux → LVE Manager"
    else
        ok "No LVE faults detected in last 15 minutes."
    fi
fi

# =============================================================================
# SECTION 4 — Apache Full Status
# =============================================================================
hdr "4. APACHE FULL STATUS"
echo ""

# Detect web server
WS=""; WS_BIN=""
if   pgrep -x lshttpd  &>/dev/null; then WS="LiteSpeed"; WS_BIN="lshttpd"
elif pgrep -x httpd    &>/dev/null; then WS="Apache";    WS_BIN="httpd"
elif pgrep -x apache2  &>/dev/null; then WS="Apache";    WS_BIN="apache2"
fi

if [ -z "$WS" ]; then
    warn "No Apache or LiteSpeed process detected."
else
    WS_PROCS=$(pgrep -c "$WS_BIN" 2>/dev/null || echo "?")
    WS_CPU=$(ps aux | grep "$WS_BIN" | grep -v grep | \
             awk '{sum+=$3} END {printf "%.1f", sum+0}')
    WS_MEM=$(ps aux | grep "$WS_BIN" | grep -v grep | \
             awk '{sum+=$4} END {printf "%.1f", sum+0}')

    # Web server uptime from oldest worker process
    WS_OLDEST_PID=$(pgrep "$WS_BIN" 2>/dev/null | head -1)
    WS_UPTIME="unknown"
    if [ -n "$WS_OLDEST_PID" ] && [ -f "/proc/${WS_OLDEST_PID}/stat" ]; then
        START=$(awk '{print $22}' /proc/${WS_OLDEST_PID}/stat 2>/dev/null)
        UPTIME_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
        if [ -n "$START" ] && [ -n "$UPTIME_S" ] && [ "$HZ" -gt 0 ]; then
            AGE=$(( UPTIME_S - START/HZ ))
            if   [ "$AGE" -ge 86400 ]; then WS_UPTIME="$(( AGE/86400 ))d $(( (AGE%86400)/3600 ))h"
            elif [ "$AGE" -ge 3600 ];  then WS_UPTIME="$(( AGE/3600 ))h$(( (AGE%3600)/60 ))m"
            else                            WS_UPTIME="$(( AGE/60 ))m"
            fi
        fi
    fi

    echo -e "  ${B}Web Server  :${N} ${WS} (${WS_BIN})"
    echo -e "  ${B}Workers     :${N} ${WS_PROCS} processes"
    echo -e "  ${B}CPU total   :${N} ${WS_CPU}%"
    echo -e "  ${B}RAM total   :${N} ${WS_MEM}%"
    echo -e "  ${B}Est. uptime :${N} ${WS_UPTIME} (oldest worker)"
fi

# --- Apache server-status auto summary
echo ""
info "Apache server-status (auto):"
ASTATUS_AUTO=$(curl -sk --max-time 4 "http://127.0.0.1/server-status?auto" 2>/dev/null)
if [ -n "$ASTATUS_AUTO" ]; then
    BUSY=$(echo    "$ASTATUS_AUTO" | grep -i "BusyWorkers"  | awk '{print $2}')
    IDLE=$(echo    "$ASTATUS_AUTO" | grep -i "IdleWorkers"  | awk '{print $2}')
    RPS=$(echo     "$ASTATUS_AUTO" | grep -i "ReqPerSec"    | awk '{print $2}')
    BPS=$(echo     "$ASTATUS_AUTO" | grep -i "BytesPerSec"  | awk '{print $2}')
    ACCESSES=$(echo "$ASTATUS_AUTO"| grep -i "Total Accesses" | awk '{print $3}')
    UPTIME_A=$(echo "$ASTATUS_AUTO"| grep -i "^Uptime"      | awk '{print $2}')

    # Format Apache uptime
    if [ -n "$UPTIME_A" ]; then
        A_DAYS=$(( UPTIME_A / 86400 ))
        A_HRS=$(( (UPTIME_A % 86400) / 3600 ))
        A_MIN=$(( (UPTIME_A % 3600) / 60 ))
        APACHE_UPTIME="${A_DAYS}d ${A_HRS}h ${A_MIN}m"
    fi

    echo ""
    printf "  ${B}%-28s${N} %s\n" "Busy workers:"     "${BUSY:-?}"
    printf "  ${B}%-28s${N} %s\n" "Idle workers:"     "${IDLE:-?}"
    printf "  ${B}%-28s${N} %s req/s\n" "Requests/sec:"    "${RPS:-?}"
    printf "  ${B}%-28s${N} %s bytes/s\n" "Bytes/sec:"       "${BPS:-?}"
    printf "  ${B}%-28s${N} %s\n" "Total accesses:"   "${ACCESSES:-?}"
    printf "  ${B}%-28s${N} %s\n" "Apache uptime:"    "${APACHE_UPTIME:-${UPTIME_A:-?}}"

    # Worker capacity check
    if [ -n "$BUSY" ] && [ -n "$IDLE" ]; then
        TOTAL_W=$(( BUSY + IDLE ))
        BUSY_PCT=$(( BUSY * 100 / TOTAL_W ))
        BUSY_CLR=$G
        [ "$BUSY_PCT" -ge 80 ] && BUSY_CLR=$Y
        [ "$BUSY_PCT" -ge 95 ] && BUSY_CLR=$R
        echo ""
        printf "  ${B}%-28s${N} ${BUSY_CLR}%s%% (%s/%s workers)${N}\n" \
            "Worker utilization:" "$BUSY_PCT" "$BUSY" "$TOTAL_W"
        [ "$BUSY_PCT" -ge 95 ] && \
            crit "Apache is near full capacity — new requests may queue or fail"
        [ "$BUSY_PCT" -ge 80 ] && [ "$BUSY_PCT" -lt 95 ] && \
            warn "Apache workers are heavily loaded (${BUSY_PCT}%)"
    fi
else
    warn "Apache server-status not reachable at http://127.0.0.1/server-status"
    info "Enable in WHM → Apache Configuration → Global Configuration → Server Status"
    info "Or add to httpd.conf:"
    echo -e "    ${D}<Location /server-status>${N}"
    echo -e "    ${D}  SetHandler server-status${N}"
    echo -e "    ${D}  Require ip 127.0.0.1${N}"
    echo -e "    ${D}</Location>${N}"
fi

# --- Apache full status — the table you asked for
# Srv PID Acc M CPU SS Req Dur Conn Child Slot Client Protocol VHost
echo ""
info "Apache full status — active request table (Srv PID Acc M CPU SS Req Dur Conn Child Slot Client Protocol VHost):"
echo ""

ASTATUS_FULL=$(curl -sk --max-time 4 "http://127.0.0.1/server-status" 2>/dev/null)
if [ -n "$ASTATUS_FULL" ]; then
    # Strip HTML and extract the worker table
    # Look for lines that contain the slot data pattern
    CLEAN=$(echo "$ASTATUS_FULL" | sed 's/<[^>]*>//g' | sed '/^$/d')

    # Print header
    printf "  ${B}%-6s %-8s %-6s %-2s %-6s %-6s %-5s %-8s %-6s %-6s %-6s %-16s %-8s %-s${N}\n" \
        "Srv" "PID" "Acc" "M" "CPU" "SS" "Req" "Dur" "Conn" "Child" "Slot" "Client" "Proto" "VHost"
    echo "  ──────────────────────────────────────────────────────────────────────────────────────────────"

    # Extract worker rows — they start with a digit (slot number)
    # Apache status page format varies — we parse the pre/table section
    echo "$CLEAN" | grep -E "^[[:space:]]*[0-9]+-[0-9]+" | head -40 | \
    while IFS= read -r l; do
        echo "  $l"
    done

    # Fallback: if table parsing didn't work, show raw cleaned lines
    PARSED_COUNT=$(echo "$CLEAN" | grep -cE "^[[:space:]]*[0-9]+-[0-9]+" || echo 0)
    if [ "${PARSED_COUNT:-0}" -eq 0 ]; then
        # Try alternative: lines with GET/POST patterns
        echo "$ASTATUS_FULL" | \
            grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[^"]*"(GET|POST|HEAD)[^"]*"' | \
            head -20 | while IFS= read -r l; do echo "    $l"; done

        # Show top active URLs being served
        echo ""
        info "Top active requests (URL pattern):"
        echo "$ASTATUS_FULL" | grep -oE '"(GET|POST|HEAD|PUT|DELETE) [^"]*"' | \
            sort | uniq -c | sort -rn | head -15 | \
            while read -r cnt req; do printf "    %-6s %s\n" "$cnt" "$req"; done
    fi

    # Top client IPs from full status
    echo ""
    info "Top client IPs in server-status:"
    echo "$ASTATUS_FULL" | \
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
        grep -vE '^(127\.|::1)' | \
        sort | uniq -c | sort -rn | head -10 | \
        while read -r cnt ip; do
            CLR=$N; FLAG=""
            [ "$cnt" -ge 20 ] && CLR=$R && FLAG=" ◄ HIGH — possible flood"
            [ "$cnt" -ge 10 ] && [ "$cnt" -lt 20 ] && CLR=$Y && FLAG=" ◄ Elevated"
            printf "${CLR}    %-6s %s%s${N}\n" "$cnt" "$ip" "$FLAG"
        done

    # Top VHosts being hit
    echo ""
    info "Top VHosts being served right now:"
    echo "$ASTATUS_FULL" | \
        grep -oE 'vhost[^<]*|<td>[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' | \
        tr -d '<td>' | grep '\.' | \
        sort | uniq -c | sort -rn | head -10 | \
        while read -r cnt vh; do printf "    %-6s %s\n" "$cnt" "$vh"; done
else
    warn "Could not retrieve full Apache status page."
fi

# =============================================================================
# SECTION 5 — Nginx Status (as proxy)
# =============================================================================
hdr "5. NGINX STATUS (PROXY LAYER)"
echo ""

NGINX_RUNNING=false
pgrep -x nginx &>/dev/null && NGINX_RUNNING=true
pgrep -f nginx &>/dev/null && NGINX_RUNNING=true

if [ "$NGINX_RUNNING" = false ]; then
    info "Nginx is not running on this server."
    info "If you expect Nginx as a proxy, check: systemctl status nginx"
else
    NGINX_PROCS=$(pgrep -c nginx 2>/dev/null || echo "?")
    NGINX_CPU=$(ps aux | grep nginx | grep -v grep | \
                awk '{sum+=$3} END {printf "%.1f", sum+0}')
    NGINX_MEM=$(ps aux | grep nginx | grep -v grep | \
                awk '{sum+=$4} END {printf "%.1f", sum+0}')

    # Nginx uptime from master process
    NGINX_MASTER_PID=$(pgrep -f "nginx: master" 2>/dev/null | head -1)
    NGINX_UPTIME="unknown"
    if [ -n "$NGINX_MASTER_PID" ] && [ -f "/proc/${NGINX_MASTER_PID}/stat" ]; then
        START=$(awk '{print $22}' /proc/${NGINX_MASTER_PID}/stat 2>/dev/null)
        UPTIME_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
        HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
        if [ -n "$START" ] && [ -n "$UPTIME_S" ] && [ "$HZ" -gt 0 ]; then
            AGE=$(( UPTIME_S - START/HZ ))
            if   [ "$AGE" -ge 86400 ]; then NGINX_UPTIME="$(( AGE/86400 ))d $(( (AGE%86400)/3600 ))h"
            elif [ "$AGE" -ge 3600 ];  then NGINX_UPTIME="$(( AGE/3600 ))h$(( (AGE%3600)/60 ))m"
            else                            NGINX_UPTIME="$(( AGE/60 ))m"
            fi
        fi
    fi

    echo -e "  ${B}Nginx processes :${N} ${NGINX_PROCS}"
    echo -e "  ${B}CPU total       :${N} ${NGINX_CPU}%"
    echo -e "  ${B}RAM total       :${N} ${NGINX_MEM}%"
    echo -e "  ${B}Uptime          :${N} ${NGINX_UPTIME}"

    # Worker vs master breakdown
    echo ""
    NGINX_WORKERS=$(pgrep -c -f "nginx: worker" 2>/dev/null || echo "?")
    NGINX_MASTER=$(pgrep -c -f "nginx: master" 2>/dev/null || echo "?")
    info "Master processes : ${NGINX_MASTER}"
    info "Worker processes : ${NGINX_WORKERS}"

    # Nginx stub_status (if enabled)
    echo ""
    info "Nginx stub_status:"
    NGINX_STATUS=""
    for STATUS_URL in \
        "http://127.0.0.1/nginx_status" \
        "http://127.0.0.1:8080/nginx_status" \
        "http://127.0.0.1/status"; do
        NGINX_STATUS=$(curl -sk --max-time 3 "$STATUS_URL" 2>/dev/null)
        [ -n "$NGINX_STATUS" ] && break
    done

    if [ -n "$NGINX_STATUS" ]; then
        ACTIVE=$(echo "$NGINX_STATUS"  | grep "Active"   | awk '{print $3}')
        READING=$(echo "$NGINX_STATUS" | grep "Reading"  | awk '{print $2}')
        WRITING=$(echo "$NGINX_STATUS" | grep "Writing"  | awk '{print $4}')
        WAITING=$(echo "$NGINX_STATUS" | grep "Waiting"  | awk '{print $6}')
        HANDLED=$(echo "$NGINX_STATUS" | grep "handled"  | awk 'NR==2{print $2}')
        REQUESTS=$(echo "$NGINX_STATUS"| grep "requests" | awk 'NR==2{print $3}')

        echo ""
        printf "  ${B}%-28s${N} %s\n" "Active connections:"  "${ACTIVE:-?}"
        printf "  ${B}%-28s${N} %s\n" "Reading:"             "${READING:-?}"
        printf "  ${B}%-28s${N} %s\n" "Writing:"             "${WRITING:-?}"
        printf "  ${B}%-28s${N} %s\n" "Waiting (keepalive):" "${WAITING:-?}"
        printf "  ${B}%-28s${N} %s\n" "Connections handled:" "${HANDLED:-?}"
        printf "  ${B}%-28s${N} %s\n" "Total requests:"      "${REQUESTS:-?}"

        # Flood detection from Nginx
        echo ""
        if [ -n "$ACTIVE" ] && [ "${ACTIVE:-0}" -ge 500 ]; then
            crit "Nginx active connections: ${ACTIVE} — possible flood or traffic spike"
        elif [ -n "$ACTIVE" ] && [ "${ACTIVE:-0}" -ge 200 ]; then
            warn "Nginx active connections: ${ACTIVE} — elevated, monitor closely"
        else
            ok "Nginx active connections: ${ACTIVE:-?} — normal range"
        fi

        if [ -n "$WRITING" ] && [ "${WRITING:-0}" -ge 100 ]; then
            warn "High WRITING count (${WRITING}) — Nginx is actively sending many responses"
            echo -e "    ${Y}→${N} Possible DDoS or traffic spike — check Section 7 for attacking IPs"
        fi
    else
        warn "Nginx stub_status not reachable."
        info "To enable, add to nginx.conf server block:"
        echo -e "    ${D}location /nginx_status {${N}"
        echo -e "    ${D}  stub_status on;${N}"
        echo -e "    ${D}  allow 127.0.0.1;${N}"
        echo -e "    ${D}  deny all;${N}"
        echo -e "    ${D}}${N}"
    fi

    # Nginx error log — recent errors
    echo ""
    info "Recent Nginx errors (last 20 lines):"
    NGINX_ERRLOG=""
    for ERRLOG in /var/log/nginx/error.log \
                  /usr/local/nginx/logs/error.log \
                  /var/log/nginx/error_log; do
        [ -f "$ERRLOG" ] && NGINX_ERRLOG="$ERRLOG" && break
    done

    if [ -n "$NGINX_ERRLOG" ]; then
        tail -20 "$NGINX_ERRLOG" 2>/dev/null | \
            grep -vE "^\s*$" | \
            while IFS= read -r l; do
                if echo "$l" | grep -qi "crit\|emerg\|alert"; then
                    echo -e "    ${R}$l${N}"
                elif echo "$l" | grep -qi "error"; then
                    echo -e "    ${Y}$l${N}"
                else
                    echo -e "    ${D}$l${N}"
                fi
            done
    else
        info "Nginx error log not found. Checked common paths."
    fi

    # Nginx flood prevention info
    echo ""
    info "Nginx rate limiting status:"
    NGINX_CONF=""
    for CONF in /etc/nginx/nginx.conf \
                /usr/local/nginx/conf/nginx.conf \
                /etc/nginx/conf.d/default.conf; do
        [ -f "$CONF" ] && NGINX_CONF="$CONF" && break
    done

    if [ -n "$NGINX_CONF" ]; then
        RATE_LIMIT=$(grep -E "limit_req|limit_conn" "$NGINX_CONF" 2>/dev/null | head -5)
        if [ -n "$RATE_LIMIT" ]; then
            ok "Rate limiting is configured:"
            echo "$RATE_LIMIT" | while IFS= read -r l; do echo -e "    ${D}$l${N}"; done
        else
            warn "No limit_req or limit_conn found in ${NGINX_CONF}"
            echo -e "    ${Y}→${N} Consider adding rate limiting — see Section 6 recommendations"
        fi
    fi
fi

# =============================================================================
# SECTION 6 — Abuse & Attack Indicators
# =============================================================================
hdr "6. ABUSE & ATTACK INDICATORS"
echo ""

# wp-login brute force
info "wp-login.php brute force (active processes):"
WP_PROCS=$(ps aux | grep -i "wp-login" | grep -v grep)
if [ -n "$WP_PROCS" ]; then
    crit "ACTIVE wp-login.php processes — brute force in progress:"
    echo "$WP_PROCS" | while IFS= read -r l; do
        USR=$(echo "$l" | awk '{print $1}')
        PID=$(echo "$l" | awk '{print $2}')
        CPU=$(echo "$l" | awk '{print $3}')
        echo -e "    ${R}PID $PID${N} | User: ${Y}$USR${N} | CPU: ${R}${CPU}%${N}"
    done
    echo ""
    info "Attacker IPs (from domlogs):"
    grep -rh "wp-login" /usr/local/apache/domlogs/ 2>/dev/null | \
        awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | \
        while read -r cnt ip; do
            printf "    ${R}%-6s %s${N}  ← block with: csf -d %s\n" "$cnt" "$ip" "$ip"
        done
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

# Processes from /tmp (malware)
echo ""
info "Processes executing from /tmp or /dev/shm (malware indicator):"
SHADY=$(ls -la /proc/[0-9]*/exe 2>/dev/null | \
        grep -E '-> /tmp/|-> /dev/shm/|-> /var/tmp/')
if [ -n "$SHADY" ]; then
    crit "SUSPICIOUS — processes in temp directories:"
    echo "$SHADY" | while IFS= read -r l; do echo -e "    ${R}$l${N}"; done
else
    ok "No processes running from /tmp or /dev/shm."
fi

# Connection flood check
echo ""
info "Top source IPs by active connections:"
echo ""
printf "    ${B}%-6s %-18s %-s${N}\n" "CONNS" "IP" "FLAG"
echo "    ──────────────────────────────────────────────────────────"
ss -tn state established 2>/dev/null | awk 'NR>1{print $5}' | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
    sort | uniq -c | sort -rn | head -10 | \
    while read -r cnt ip; do
        CLR=$N; FLAG="—"
        [ "$cnt" -ge 100 ] && CLR=$R && FLAG="◄ POSSIBLE FLOOD"
        [ "$cnt" -ge 30  ] && [ "$cnt" -lt 100 ] && CLR=$Y && FLAG="◄ Elevated"
        printf "    ${CLR}%-6s %-18s %s${N}\n" "$cnt" "$ip" "$FLAG"
    done

# =============================================================================
# SECTION 7 — Recommendations
# =============================================================================
hdr "7. RECOMMENDATIONS"
echo ""

LOAD_I=${LOAD1%.*}

# --- Load-based
if [ "${LOAD_I:-0}" -ge $(( CPU_CORES * 3 )) ]; then
    crit "Load ${LOAD1} is 3x+ core count (${CPU_CORES}) — server critically overloaded"
    echo -e "    ${Y}→${N} Immediate: identify top account in Section 2 and throttle or suspend"
    echo -e "    ${Y}→${N} Run: whmapi1 suspendacct user=${TOP_CPU_ACCOUNT:-ACCOUNT} reason='CPU abuse'"
    echo -e "    ${Y}→${N} Or throttle: lvectl set ${TOP_CPU_ACCOUNT:-ACCOUNT} --speed=50% --ncpu=1"
elif [ "${LOAD_I:-0}" -ge "$CPU_CORES" ]; then
    warn "Load ${LOAD1} exceeds core count (${CPU_CORES})"
    echo -e "    ${Y}→${N} Monitor. If sustained > 15 minutes, investigate top account in Section 2"
    [ -n "$TOP_CPU_ACCOUNT" ] && \
        echo -e "    ${Y}→${N} Top account right now: ${B}${TOP_CPU_ACCOUNT}${N} — run: bash cpu_investigate.sh --user ${TOP_CPU_ACCOUNT}"
else
    ok "Load is within normal range (${LOAD1} on ${CPU_CORES} cores)."
fi

# --- Apache worker saturation
if [ -n "$BUSY_PCT" ] && [ "${BUSY_PCT:-0}" -ge 95 ]; then
    echo ""
    crit "Apache workers near saturation (${BUSY_PCT}%)"
    echo -e "    ${Y}→${N} WHY: too many concurrent requests — likely attack or traffic spike"
    echo -e "    ${Y}→${N} CAUSE: could be wp-login/xmlrpc flood, legit traffic, or slow PHP"
    echo -e "    ${Y}→${N} FIX (immediate): identify flood IPs in Section 6 → csf -d <IP>"
    echo -e "    ${Y}→${N} FIX (tune): raise MaxRequestWorkers in WHM → Apache Config"
    echo -e "    ${Y}→${N} FIX (long-term): move to LiteSpeed or add Nginx as front proxy"
elif [ -n "$BUSY_PCT" ] && [ "${BUSY_PCT:-0}" -ge 80 ]; then
    echo ""
    warn "Apache workers heavily loaded (${BUSY_PCT}%)"
    echo -e "    ${Y}→${N} WHY: high concurrent request volume"
    echo -e "    ${Y}→${N} FIX: check if specific accounts or URLs are causing it (Section 4)"
fi

# --- Nginx flood prevention
if [ "$NGINX_RUNNING" = true ]; then
    echo ""
    info "Nginx flood prevention recommendations:"
    echo ""
    echo -e "  ${D}# Add rate limiting to nginx.conf (inside http {} block):${N}"
    echo    "  limit_req_zone \$binary_remote_addr zone=one:10m rate=30r/m;"
    echo ""
    echo -e "  ${D}# Apply rate limit in server/location block:${N}"
    echo    "  limit_req zone=one burst=10 nodelay;"
    echo ""
    echo -e "  ${D}# Limit connections per IP:${N}"
    echo    "  limit_conn_zone \$binary_remote_addr zone=addr:10m;"
    echo    "  limit_conn addr 10;"
    echo ""
    echo -e "  ${D}# Block bad user agents in nginx.conf:${N}"
    echo    "  if (\$http_user_agent ~* (bot|crawler|spider|scan)) { return 444; }"
    echo ""
    echo -e "  ${D}# Reload Nginx after changes:${N}"
    echo    "  nginx -t && systemctl reload nginx"
fi

# --- wp-login active
if [ -n "$WP_PROCS" ]; then
    echo ""
    crit "wp-login.php brute force is consuming CPU right now"
    echo -e "    ${Y}→${N} WHY: attacker is trying to guess WordPress credentials"
    echo -e "    ${Y}→${N} CAUSE: site has no login protection or rate limiting"
    echo -e "    ${Y}→${N} BLOCK attacker IPs: grep wp-login domlogs | awk '{print \$1}' | sort | uniq -c | sort -rn"
    echo -e "    ${Y}→${N} Then: csf -d <IP>  for each attacking IP"
    echo -e "    ${Y}→${N} PREVENT: advise owner to install Cloudflare, Wordfence, or login limiter"
    echo -e "    ${Y}→${N} PREVENT: block wp-login at Nginx level with rate limiting above"
    echo -e "    ${Y}→${N} PREVENT: WHM → ModSecurity → enable WordPress ruleset"
fi

# --- MySQL high
MYSQL_CPU=$(ps aux | grep -E 'mysqld|mariadbd' | grep -v grep | \
            awk '{sum+=$3} END {printf "%.0f", sum+0}')
if [ "${MYSQL_CPU:-0}" -ge 40 ]; then
    echo ""
    warn "MySQL is using ${MYSQL_CPU}% CPU"
    echo -e "    ${Y}→${N} WHY: slow queries, missing indexes, or too many connections"
    echo -e "    ${Y}→${N} CHECK: mysql -e 'SHOW FULL PROCESSLIST\\G'"
    echo -e "    ${Y}→${N} CHECK: tail -50 /var/lib/mysql/*-slow.log"
    echo -e "    ${Y}→${N} FIX: kill long-running query: mysql -e 'KILL QUERY <id>;'"
fi

echo ""
sep
echo -e "${B}  QUICK REFERENCE ONE-LINERS${N}"
sep
echo ""
echo -e "  ${D}# Watch live CPU every 2 seconds:${N}"
echo    "  watch -n2 'ps aux --sort=-%cpu | head -20'"
echo ""
echo -e "  ${D}# LVE faults last 15 minutes:${N}"
echo    "  lveinfo -d --period=15m --limit 20 -o any_faults --show-columns id,from,to,iopsf,iof,cpuf,epf,pmemf,mcpu,ucpu,uep,upmem,nprocf"
echo ""
echo -e "  ${D}# All lsphp grouped by account:${N}"
echo    "  ps aux | grep lsphp | grep -v grep | awk '{print \$1}' | sort | uniq -c | sort -rn"
echo ""
echo -e "  ${D}# wp-login attacker IPs from domlogs:${N}"
echo    "  grep -rh wp-login /usr/local/apache/domlogs/ 2>/dev/null | awk '{print \$1}' | sort | uniq -c | sort -rn | head -20"
echo ""
echo -e "  ${D}# Block an IP via CSF:${N}"
echo    "  csf -d <IP>  \"reason\""
echo ""
echo -e "  ${D}# Throttle account CPU via LVE:${N}"
echo    "  lvectl set <username> --speed=50% --ncpu=1"
echo ""
echo -e "  ${D}# Check LVE limits for account:${N}"
echo    "  lvectl get <username>"
echo ""
echo -e "  ${D}# Suspend account via WHM:${N}"
echo    "  whmapi1 suspendacct user=<username> reason='CPU abuse'"
echo ""
echo -e "  ${D}# Apache worker count right now:${N}"
echo    "  curl -sk http://127.0.0.1/server-status?auto | grep -E 'BusyWorkers|IdleWorkers'"
echo ""
echo -e "  ${D}# Nginx active connections:${N}"
echo    "  curl -sk http://127.0.0.1/nginx_status"
echo ""
echo -e "  ${D}# Reload Nginx safely:${N}"
echo    "  nginx -t && systemctl reload nginx"
echo ""
echo -e "  ${D}# MySQL slow queries running now:${N}"
echo    "  mysql -e 'SHOW FULL PROCESSLIST\G' | grep -B5 'Time: [0-9][0-9]'"
echo ""

sep
echo -e "${G}${B}  Done — $(date '+%H:%M:%S')${N}"
sep
echo ""
