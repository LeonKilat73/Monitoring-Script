#!/bin/bash
# =============================================================================
# firewall_status.sh — Self-contained Firewall Investigation
# Drop anywhere, run as root. No external dependencies.
#
# PURPOSE: Investigate CSF and Imunify360 health when Zabbix fires a
#          firewall alert. Answers:
#   - Is CSF/LFD actually running and healthy?
#   - What attack patterns has LFD detected recently?
#   - Is Imunify360 running? Any malware or WAF events?
#   - Is iptables overloaded with too many rules?
#   - Any active connection floods happening right now?
#
# USAGE:
#   bash firewall_status.sh                   # Full report (60min lookback)
#   bash firewall_status.sh --minutes 30      # Change lookback window
#   bash firewall_status.sh --block 1.2.3.4   # Block IP via CSF
#   bash firewall_status.sh --unblock 1.2.3.4 # Unblock IP from CSF
#   bash firewall_status.sh --check 1.2.3.4   # Check if IP is blocked anywhere
# =============================================================================

LOOKBACK=60
BLOCK_IP=""
UNBLOCK_IP=""
CHECK_IP=""
ATTACK_THRESHOLD=10

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --minutes) LOOKBACK="$2";   shift ;;
        --block)   BLOCK_IP="$2";   shift ;;
        --unblock) UNBLOCK_IP="$2"; shift ;;
        --check)   CHECK_IP="$2";   shift ;;
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

_confirm() {
    echo ""
    echo -e "  ${Y}⚠  $1${N}"
    echo -ne "  Type YES to confirm: "
    read -r answer
    [ "$answer" = "YES" ]
}

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
CSF_LOG="/var/log/lfd.log"
IMUNIFY_LOG="/var/log/imunify360/console.log"

echo ""
echo -e "${B}╔══════════════════════════════════════════════════════════════╗${N}"
echo -e "${B}  FIREWALL STATUS — ${HOSTNAME}${N}"
echo -e "${D}  $(date '+%Y-%m-%d %H:%M:%S')  |  Lookback: ${LOOKBACK} minutes${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════════╝${N}"

# =============================================================================
# QUICK ACTIONS — Block / Unblock / Check (run and exit)
# =============================================================================
if [ -n "$BLOCK_IP" ]; then
    hdr "QUICK ACTION — BLOCK IP: ${BLOCK_IP}"
    echo ""
    if ! command -v csf &>/dev/null; then
        crit "CSF not found — cannot block."
        exit 1
    fi
    if _confirm "Permanently block ${BLOCK_IP} via CSF?"; then
        csf -d "$BLOCK_IP" "Blocked by firewall_status.sh on $(date '+%Y-%m-%d %H:%M')"
        ok "IP ${BLOCK_IP} added to CSF permanent deny list."
        info "To unblock later: bash firewall_status.sh --unblock ${BLOCK_IP}"
    else
        info "Cancelled."
    fi
    exit 0
fi

if [ -n "$UNBLOCK_IP" ]; then
    hdr "QUICK ACTION — UNBLOCK IP: ${UNBLOCK_IP}"
    echo ""
    if ! command -v csf &>/dev/null; then
        crit "CSF not found."
        exit 1
    fi
    if _confirm "Remove ${UNBLOCK_IP} from all CSF block lists?"; then
        csf -dr "$UNBLOCK_IP" 2>/dev/null && ok "Removed from permanent deny list." || \
            info "Was not in permanent deny list."
        csf -tr "$UNBLOCK_IP" 2>/dev/null && ok "Removed from temp block list." || \
            info "Was not in temp block list."
        # Also remove from Imunify if available
        if command -v imunify360-agent &>/dev/null; then
            imunify360-agent blacklist ip delete --ip "$UNBLOCK_IP" 2>/dev/null && \
                ok "Removed from Imunify360 blacklist." || true
        fi
    else
        info "Cancelled."
    fi
    exit 0
fi

if [ -n "$CHECK_IP" ]; then
    hdr "IP STATUS CHECK — ${CHECK_IP}"
    echo ""

    # CSF permanent deny
    if grep -qE "^${CHECK_IP}(\s|$|#)" /etc/csf/csf.deny 2>/dev/null; then
        crit "${CHECK_IP} — IN CSF permanent deny list (csf.deny)"
        grep -E "^${CHECK_IP}" /etc/csf/csf.deny | \
            while IFS= read -r l; do echo -e "    ${D}$l${N}"; done
    else
        ok "${CHECK_IP} — NOT in CSF permanent deny list"
    fi

    # CSF whitelist
    if grep -qE "^${CHECK_IP}(\s|$|#)" /etc/csf/csf.allow 2>/dev/null; then
        ok "${CHECK_IP} — IN CSF whitelist (csf.allow)"
    fi

    # CSF temp blocks
    echo ""
    if command -v csf &>/dev/null; then
        TEMP_HIT=$(csf -t 2>/dev/null | grep "${CHECK_IP}")
        if [ -n "$TEMP_HIT" ]; then
            warn "${CHECK_IP} — IN CSF temporary block list:"
            echo "$TEMP_HIT" | while IFS= read -r l; do echo "    $l"; done
        else
            ok "${CHECK_IP} — NOT in CSF temp block list"
        fi
    fi

    # Imunify360
    echo ""
    if command -v imunify360-agent &>/dev/null; then
        I360_HIT=$(imunify360-agent blacklist ip list 2>/dev/null | grep "${CHECK_IP}")
        if [ -n "$I360_HIT" ]; then
            warn "${CHECK_IP} — IN Imunify360 blacklist"
        else
            ok "${CHECK_IP} — NOT in Imunify360 blacklist"
        fi
    fi

    # Recent LFD activity
    echo ""
    info "Recent LFD log entries for ${CHECK_IP}:"
    LFD_HITS=$(grep "${CHECK_IP}" "$CSF_LOG" 2>/dev/null | tail -8)
    if [ -n "$LFD_HITS" ]; then
        warn "LFD history found:"
        echo "$LFD_HITS" | while IFS= read -r l; do echo -e "    ${D}$l${N}"; done
    else
        ok "No LFD log entries found for this IP."
    fi

    # Active connections
    echo ""
    info "Active connections from ${CHECK_IP}:"
    ACTIVE=$(ss -tn state established 2>/dev/null | grep "${CHECK_IP}")
    if [ -n "$ACTIVE" ]; then
        warn "Active connections exist:"
        echo "$ACTIVE" | while IFS= read -r l; do echo "    $l"; done
    else
        ok "No active connections from this IP."
    fi

    echo ""
    sep
    echo -e "${G}${B}  Check complete — $(date '+%H:%M:%S')${N}"
    sep
    echo ""
    exit 0
fi

# =============================================================================
# SECTION 1 — CSF Health & Status
# =============================================================================
hdr "1. CSF (ConfigServer Security & Firewall) STATUS"
echo ""

if ! command -v csf &>/dev/null; then
    warn "CSF not installed or not found in PATH."
    info "Install guide: https://configserver.com/cp/csf.html"
else
    # Running state
    if csf --status 2>/dev/null | grep -qE "RUNNING|Chain CSF"; then
        ok "CSF firewall: RUNNING"
    else
        crit "CSF firewall: STOPPED or not loaded"
        warn "  Fix: csf -r"
    fi

    # Testing mode (flushes rules every 5 min — extremely dangerous in production)
    if grep -q "^TESTING = \"1\"" /etc/csf/csf.conf 2>/dev/null; then
        crit "TESTING MODE is ON — rules flush every 5 minutes — server is exposed!"
        warn "  Fix: set TESTING = \"0\" in /etc/csf/csf.conf  then: csf -r"
    else
        ok "Testing mode: OFF (good)"
    fi

    # LFD daemon
    echo ""
    if pgrep -x lfd &>/dev/null; then
        LFD_PID=$(pgrep -x lfd | head -1)
        LFD_UPTIME=$(ps -p "$LFD_PID" -o etime= 2>/dev/null | tr -d ' ')
        ok "LFD daemon: RUNNING  (PID: ${LFD_PID}  uptime: ${LFD_UPTIME})"
    else
        crit "LFD daemon: NOT RUNNING — brute force detection is inactive!"
        warn "  Fix: service lfd start"
    fi

    # Block / Allow counts
    echo ""
    DENY_COUNT=$(grep -cE "^[^#[:space:]]" /etc/csf/csf.deny  2>/dev/null || echo 0)
    ALLOW_COUNT=$(grep -cE "^[^#[:space:]]" /etc/csf/csf.allow 2>/dev/null || echo 0)
    TEMP_COUNT=$(csf -t 2>/dev/null | grep -c "IP:" || echo 0)

    printf "  %-38s ${R}%s${N}\n"  "Permanent blocked IPs  (csf.deny):"  "$DENY_COUNT"
    printf "  %-38s ${G}%s${N}\n"  "Whitelisted IPs        (csf.allow):" "$ALLOW_COUNT"
    printf "  %-38s ${Y}%s${N}\n"  "Temporary blocks       (csf -t):"    "$TEMP_COUNT"

    echo ""
    if [ "${DENY_COUNT:-0}" -gt 5000 ]; then
        warn "csf.deny has ${DENY_COUNT} entries — this many rules can degrade iptables performance"
        info "  Consider using ipset for bulk IP blocks to reduce overhead"
    else
        ok "Deny list size is manageable (${DENY_COUNT} entries)."
    fi

    # Config last modified
    echo ""
    CONF_MOD=$(stat -c '%y' /etc/csf/csf.conf 2>/dev/null | cut -d. -f1)
    info "csf.conf last modified: ${CONF_MOD:-unknown}"

    # Key security settings from csf.conf
    echo ""
    info "Key CSF security settings:"
    echo ""
    printf "    ${B}%-30s %s${N}\n" "SETTING" "VALUE"
    echo "    ──────────────────────────────────────────"
    for KEY in TESTING SMTP_BLOCK LF_SSHD LF_FTPD LF_IMAPD LF_SMTPAUTH \
               LF_SCRIPT_ALERT CT_LIMIT CT_INTERVAL PS_LIMIT PORTFLOOD \
               LF_TRIGGER SYNFLOOD SYNFLOOD_RATE SYNFLOOD_BURST; do
        VAL=$(grep "^${KEY} = " /etc/csf/csf.conf 2>/dev/null | \
              awk -F'"' '{print $2}')
        [ -z "$VAL" ] && VAL=$(grep "^${KEY} = " /etc/csf/csf.conf 2>/dev/null | \
                               awk '{print $3}')
        if [ -n "$VAL" ]; then
            # Highlight risky values
            CLR=$N
            [ "$KEY" = "TESTING" ] && [ "$VAL" = "1" ] && CLR=$R
            [ "$KEY" = "SMTP_BLOCK" ] && [ "$VAL" = "0" ] && CLR=$Y
            [ "$KEY" = "SYNFLOOD" ] && [ "$VAL" = "0" ] && CLR=$Y
            printf "    ${CLR}%-30s %s${N}\n" "${KEY}:" "$VAL"
        fi
    done
fi

# =============================================================================
# SECTION 2 — LFD Log Analysis
# =============================================================================
hdr "2. LFD LOG ANALYSIS (last ${LOOKBACK} minutes)"
echo ""

if [ ! -f "$CSF_LOG" ]; then
    warn "LFD log not found at: ${CSF_LOG}"
    info "Also check: /var/log/messages  or  journalctl -u lfd"
else
    # Pull recent log lines (tail is faster than awk date parsing on large logs)
    LFD_RECENT=$(tail -3000 "$CSF_LOG" 2>/dev/null)

    BLOCK_COUNT=$(echo "$LFD_RECENT" | grep -cE "Blocked|DENY|blocked in|triggered" || echo 0)
    info "Block/trigger events in recent log: ${BLOCK_COUNT}"

    # Top blocked IPs
    echo ""
    info "Top IPs appearing in LFD log:"
    echo ""
    printf "    ${B}%-6s %-18s %-s${N}\n" "COUNT" "IP ADDRESS" "FLAG"
    echo "    ──────────────────────────────────────────────────────────"
    echo "$LFD_RECENT" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | \
        grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' | \
        sort | uniq -c | sort -rn | head -15 | \
        while read -r cnt ip; do
            CLR=$N; FLAG="—"
            if [ "$cnt" -ge "$ATTACK_THRESHOLD" ]; then
                CLR=$R; FLAG="◄ ATTACK PATTERN"
            elif [ "$cnt" -ge 3 ]; then
                CLR=$Y; FLAG="◄ Repeated hits"
            fi
            printf "    ${CLR}%-6s %-18s %s${N}\n" "$cnt" "$ip" "$FLAG"
        done

    # Attack service breakdown
    echo ""
    info "Services being targeted:"
    echo ""
    echo "$LFD_RECENT" | \
        grep -oE 'sshd|SSH|FTP|SMTP|POP3|IMAP|HTTP|WHM|cPanel|wp-login|xmlrpc|dovecot' | \
        tr '[:lower:]' '[:upper:]' | \
        sort | uniq -c | sort -rn | \
        while read -r cnt svc; do
            printf "    %-6s %s\n" "$cnt" "$svc"
        done

    # Port scans
    echo ""
    PORTSCAN=$(echo "$LFD_RECENT" | grep -ciE "port scan|PORTSCAN" || echo 0)
    if [ "${PORTSCAN:-0}" -gt 0 ]; then
        warn "Port scan detections: ${PORTSCAN}"
        echo "$LFD_RECENT" | grep -iE "port scan|PORTSCAN" | tail -5 | \
            while IFS= read -r l; do echo -e "    ${D}$l${N}"; done
    else
        ok "No port scan events in log."
    fi

    # Resource/process abuse (LF_RESOURCE triggers)
    echo ""
    RESOURCE_BLOCKS=$(echo "$LFD_RECENT" | \
        grep -ciE "resource|excessive|proc limit|fork bomb|nproc" || echo 0)
    if [ "${RESOURCE_BLOCKS:-0}" -gt 0 ]; then
        warn "Resource abuse triggers: ${RESOURCE_BLOCKS}"
        echo "$LFD_RECENT" | grep -iE "resource|excessive|proc limit|nproc" | tail -8 | \
            while IFS= read -r l; do echo -e "    ${D}$l${N}"; done
    else
        ok "No resource abuse triggers detected."
    fi

    # WordPress / xmlrpc blocks
    echo ""
    WP_BLOCKS=$(echo "$LFD_RECENT" | grep -ciE "wp-login|xmlrpc|wordpress" || echo 0)
    if [ "${WP_BLOCKS:-0}" -gt 0 ]; then
        warn "WordPress/xmlrpc related entries: ${WP_BLOCKS}"
        echo "$LFD_RECENT" | grep -iE "wp-login|xmlrpc|wordpress" | tail -5 | \
            while IFS= read -r l; do echo -e "    ${D}$l${N}"; done
    else
        ok "No WordPress/xmlrpc attack entries."
    fi

    # Email-related blocks (spam, LF_SCRIPT)
    echo ""
    EMAIL_BLOCKS=$(echo "$LFD_RECENT" | \
        grep -ciE "script alert|LF_SCRIPT|email limit|smtp" || echo 0)
    if [ "${EMAIL_BLOCKS:-0}" -gt 0 ]; then
        warn "Email/script related LFD blocks: ${EMAIL_BLOCKS}"
        echo "$LFD_RECENT" | grep -iE "script alert|LF_SCRIPT|email limit" | tail -5 | \
            while IFS= read -r l; do echo -e "    ${D}$l${N}"; done
    else
        ok "No LFD email/script abuse blocks."
    fi

    # Current temp blocks
    echo ""
    info "Current CSF temporary blocks:"
    TEMP_LIST=$(csf -t 2>/dev/null | grep "IP:")
    if [ -n "$TEMP_LIST" ]; then
        echo "$TEMP_LIST" | tail -15 | \
            while IFS= read -r l; do echo "    $l"; done
    else
        echo -e "    ${D}(no temporary blocks active)${N}"
    fi
fi

# =============================================================================
# SECTION 3 — Imunify360 Status & Events
# =============================================================================
hdr "3. IMUNIFY360 STATUS & EVENTS"
echo ""

if ! command -v imunify360-agent &>/dev/null; then
    warn "Imunify360 not installed or not found in PATH."
    info "Expected: /usr/bin/imunify360-agent"
else
    # Service running state
    SVC_STATUS=$(systemctl is-active imunify360 2>/dev/null || \
                 service imunify360 status 2>/dev/null | grep -oE 'running|stopped' | head -1)

    if [ "$SVC_STATUS" = "active" ] || [ "$SVC_STATUS" = "running" ]; then
        ok "Imunify360 service: RUNNING"
    else
        crit "Imunify360 service: ${SVC_STATUS:-UNKNOWN}"
        warn "  Fix: systemctl restart imunify360"
    fi

    # Version
    echo ""
    info "Installed version:"
    imunify360-agent version 2>/dev/null | head -3 | \
        while IFS= read -r l; do echo "    $l"; done

    # Feature status — highlight anything disabled
    echo ""
    info "Feature status (disabled features highlighted):"
    imunify360-agent feature-management status 2>/dev/null | \
        grep -iE "waf|modsec|proactive|malware|realtime|reputation|av" | \
        while IFS= read -r l; do
            if echo "$l" | grep -qiE "disabled|off|false|0"; then
                echo -e "    ${Y}$l${N}  ◄ DISABLED"
            else
                echo -e "    ${G}$l${N}"
            fi
        done

    # Recent incidents
    echo ""
    info "Recent Imunify360 incidents (last 10):"
    imunify360-agent incidents list --limit 10 2>/dev/null | \
        while IFS= read -r l; do echo "    $l"; done

    # Malware events from log file
    echo ""
    info "Recent malware detections from log:"
    if [ -f "$IMUNIFY_LOG" ]; then
        MALWARE=$(tail -500 "$IMUNIFY_LOG" 2>/dev/null | \
                  grep -iE "malware|infected|trojan|virus|webshell|dropper" | tail -10)
        if [ -n "$MALWARE" ]; then
            warn "Malware events found:"
            echo "$MALWARE" | while IFS= read -r l; do echo -e "    ${Y}$l${N}"; done
        else
            ok "No recent malware events in Imunify360 log."
        fi
    else
        warn "Imunify360 log not found at: ${IMUNIFY_LOG}"
        info "Also check: /var/log/imunify360/error.log"
    fi

    # Imunify blacklist sample
    echo ""
    info "Imunify360 blacklisted IPs (sample, last 10):"
    imunify360-agent blacklist ip list 2>/dev/null | tail -10 | \
        while IFS= read -r l; do echo "    $l"; done || \
    imunify360-agent blocked-port list 2>/dev/null | tail -10 | \
        while IFS= read -r l; do echo "    $l"; done

    # Proactive defense status
    echo ""
    info "Proactive Defense mode:"
    imunify360-agent proactive-defense status 2>/dev/null | \
        while IFS= read -r l; do
            if echo "$l" | grep -qiE "disabled|off"; then
                echo -e "    ${Y}$l${N}  ◄ Consider enabling"
            else
                echo -e "    ${G}$l${N}"
            fi
        done
fi

# =============================================================================
# SECTION 4 — iptables Rule Health
# =============================================================================
hdr "4. IPTABLES RULE HEALTH"
echo ""

if ! command -v iptables &>/dev/null; then
    warn "iptables command not found."
else
    TOTAL_RULES=$(iptables  -L -n 2>/dev/null | \
        grep -cE "^ACCEPT|^DROP|^REJECT|^LOG|^RETURN|^DENY" || echo 0)
    IP6_RULES=$(ip6tables -L -n 2>/dev/null | \
        grep -cE "^ACCEPT|^DROP|^REJECT|^LOG|^RETURN|^DENY" || echo 0)

    printf "  %-35s %s\n" "IPv4 iptables rules:"  "$TOTAL_RULES"
    printf "  %-35s %s\n" "IPv6 ip6tables rules:"  "$IP6_RULES"
    echo ""

    if [ "${TOTAL_RULES:-0}" -gt 3000 ]; then
        crit "Rule count is HIGH (${TOTAL_RULES}) — packet processing may be slow"
        warn "  Each packet must traverse all rules — large lists = CPU overhead"
        warn "  Fix: use ipset for bulk IP blocks (csf supports this natively)"
    elif [ "${TOTAL_RULES:-0}" -gt 1000 ]; then
        warn "Rule count is elevated (${TOTAL_RULES}) — monitor for performance impact"
    else
        ok "Rule count is healthy (${TOTAL_RULES} rules)."
    fi

    # Per-chain breakdown
    echo ""
    info "Rules per chain (non-empty only):"
    iptables -L -n 2>/dev/null | grep "^Chain" | \
        while IFS= read -r line; do
            CHAIN=$(echo "$line" | awk '{print $2}')
            COUNT=$(iptables -L "$CHAIN" -n 2>/dev/null | tail -n +3 | wc -l)
            [ "${COUNT:-0}" -gt 0 ] && \
                printf "    %-30s %s rules\n" "$CHAIN" "$COUNT"
        done

    # ipset
    echo ""
    if command -v ipset &>/dev/null; then
        IPSET_COUNT=$(ipset list 2>/dev/null | grep -c "^Name:" || echo 0)
        info "ipset sets in use: ${IPSET_COUNT}"
        if [ "${IPSET_COUNT:-0}" -gt 0 ]; then
            ipset list 2>/dev/null | \
                grep -E "^Name:|^Number of entries:" | \
                paste - - | \
                while IFS= read -r l; do echo "    $l"; done
        fi
    else
        info "ipset not installed — recommended for large block lists"
    fi
fi

# =============================================================================
# SECTION 5 — Active Connection Analysis
# =============================================================================
hdr "5. ACTIVE CONNECTION ANALYSIS"
echo ""

SS_OUT=$(ss -s 2>/dev/null)
TOTAL_CONN=$(echo "$SS_OUT"  | grep "Total:"     | awk '{print $2}')
ESTAB_CONN=$(echo "$SS_OUT"  | grep -i "estab"   | grep -oE '[0-9]+' | head -1)
SYN_RECV=$(echo   "$SS_OUT"  | grep -i "synrecv" | grep -oE '[0-9]+' | head -1)
TIME_WAIT=$(echo  "$SS_OUT"  | grep -i "timewait"| grep -oE '[0-9]+' | head -1)
CLOSE_WAIT=$(echo "$SS_OUT"  | grep -i "closewait"| grep -oE '[0-9]+' | head -1)

printf "  %-30s %s\n"          "Total connections:"  "${TOTAL_CONN:-?}"
printf "  %-30s ${G}%s${N}\n"  "Established:"        "${ESTAB_CONN:-?}"

# SYN_RECV coloring
SYN_CLR=$G
[ "${SYN_RECV:-0}" -gt 50  ] && SYN_CLR=$Y
[ "${SYN_RECV:-0}" -gt 100 ] && SYN_CLR=$R
printf "  %-30s ${SYN_CLR}%s${N}\n" "SYN_RECV (flood indicator):" "${SYN_RECV:-0}"
printf "  %-30s %s\n"  "TIME_WAIT:"   "${TIME_WAIT:-0}"
printf "  %-30s %s\n"  "CLOSE_WAIT:"  "${CLOSE_WAIT:-0}"

echo ""
if [ "${SYN_RECV:-0}" -gt 100 ]; then
    crit "SYN_RECV is VERY HIGH (${SYN_RECV}) — SYN flood attack likely in progress"
    warn "  Immediate: echo 1 > /proc/sys/net/ipv4/tcp_syncookies"
    warn "  CSF: enable SYNFLOOD and SYNFLOOD_RATE in csf.conf"
elif [ "${SYN_RECV:-0}" -gt 50 ]; then
    warn "SYN_RECV is elevated (${SYN_RECV}) — watch closely"
else
    ok "SYN_RECV is normal (${SYN_RECV:-0})."
fi

# Top source IPs
echo ""
info "Top source IPs by active connections:"
echo ""
printf "    ${B}%-6s %-18s %-s${N}\n" "CONNS" "IP ADDRESS" "FLAG"
echo "    ──────────────────────────────────────────────────────────"
ss -tn state established 2>/dev/null | awk 'NR>1{print $5}' | \
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
    sort | uniq -c | sort -rn | head -12 | \
    while read -r cnt ip; do
        CLR=$N; FLAG="—"
        [ "$cnt" -ge 100 ] && CLR=$R && FLAG="◄ POSSIBLE FLOOD"
        [ "$cnt" -ge 30  ] && [ "$cnt" -lt 100 ] && CLR=$Y && FLAG="◄ Elevated"
        printf "    ${CLR}%-6s %-18s %s${N}\n" "$cnt" "$ip" "$FLAG"
    done

# Busiest ports with service name
echo ""
info "Busiest destination ports:"
echo ""
ss -tn state established 2>/dev/null | awk 'NR>1{print $4}' | \
    rev | cut -d: -f1 | rev | \
    sort | uniq -c | sort -rn | head -12 | \
    while read -r cnt port; do
        SVC=""
        case "$port" in
            21)   SVC="FTP"                ;;  22)   SVC="SSH"          ;;
            25)   SVC="SMTP"               ;;  80)   SVC="HTTP"         ;;
            110)  SVC="POP3"               ;;  143)  SVC="IMAP"         ;;
            443)  SVC="HTTPS"              ;;  465)  SVC="SMTPS"        ;;
            587)  SVC="SMTP Submission"    ;;  993)  SVC="IMAPS"        ;;
            995)  SVC="POP3S"              ;;  2082) SVC="cPanel"       ;;
            2083) SVC="cPanel SSL"         ;;  2086) SVC="WHM"          ;;
            2087) SVC="WHM SSL"            ;;  2095) SVC="Webmail"      ;;
            2096) SVC="Webmail SSL"        ;;  3306) SVC="MySQL"        ;;
            8080) SVC="HTTP Alt"           ;;  8443) SVC="HTTPS Alt"    ;;
        esac
        [ -n "$SVC" ] && SVC=" (${SVC})"
        printf "    %-6s port %-6s%s\n" "$cnt" "$port" "$SVC"
    done

# =============================================================================
# SECTION 6 — Recommendations & Quick Reference
# =============================================================================
hdr "6. RECOMMENDATIONS & QUICK REFERENCE"
echo ""

echo -e "  ${B}If under active attack right now:${N}"
echo ""
echo -e "  ${C}1.${N} Find attacker IP  → Section 2 (top LFD IPs) or Section 5 (top connections)"
echo -e "  ${C}2.${N} Check IP details  → bash firewall_status.sh --check <IP>"
echo -e "  ${C}3.${N} Block immediately → bash firewall_status.sh --block <IP>"
echo -e "  ${C}4.${N} SYN flood active  → echo 1 > /proc/sys/net/ipv4/tcp_syncookies"
echo -e "  ${C}5.${N} CSF stopped       → csf -r"
echo -e "  ${C}6.${N} LFD stopped       → service lfd start"
echo -e "  ${C}7.${N} Imunify stopped   → systemctl restart imunify360"
echo ""

echo -e "  ${B}Recommended CSF hardening settings (/etc/csf/csf.conf):${N}"
echo ""
echo -e "  ${D}SMTP_BLOCK = 1${N}           Block non-Exim outbound SMTP from user processes"
echo -e "  ${D}LF_SCRIPT_ALERT = 500${N}    Alert when PHP script sends too many emails"
echo -e "  ${D}CT_LIMIT = 100${N}           Max connections per IP before temp block"
echo -e "  ${D}PORTFLOOD = 80;tcp;20;5${N}  Port flood protection on HTTP"
echo -e "  ${D}PS_LIMIT = 10${N}            Port scan detection threshold"
echo -e "  ${D}LF_SSHD = 5${N}             Block after 5 failed SSH attempts"
echo -e "  ${D}SYNFLOOD = 1${N}             Enable SYN flood protection"
echo -e "  ${D}SYNFLOOD_RATE = 100/s${N}    Max SYN packets per second"
echo ""

sep
echo -e "${B}  QUICK REFERENCE ONE-LINERS${N}"
sep
echo ""
echo -e "  ${D}# Block an IP permanently via CSF:${N}"
echo    "  csf -d <IP>  \"Reason here\""
echo ""
echo -e "  ${D}# Temporary block for 1 hour:${N}"
echo    "  csf -td <IP> 3600 \"Temp: suspicious activity\""
echo ""
echo -e "  ${D}# Unblock an IP (perm + temp):${N}"
echo    "  csf -dr <IP> && csf -tr <IP>"
echo ""
echo -e "  ${D}# Reload all CSF rules:${N}"
echo    "  csf -r"
echo ""
echo -e "  ${D}# Watch LFD log live:${N}"
echo    "  tail -f /var/log/lfd.log"
echo ""
echo -e "  ${D}# View active temp blocks:${N}"
echo    "  csf -t"
echo ""
echo -e "  ${D}# Top attacking IPs in LFD log:${N}"
echo    "  tail -2000 /var/log/lfd.log | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | sort | uniq -c | sort -rn | head -20"
echo ""
echo -e "  ${D}# All open listening ports:${N}"
echo    "  ss -tlnp"
echo ""
echo -e "  ${D}# Active connections per IP (top 20):${N}"
echo    "  ss -tn state established | awk 'NR>1{print \$5}' | grep -oE '[0-9.]+' | sort | uniq -c | sort -rn | head -20"
echo ""
echo -e "  ${D}# Imunify360 — whitelist an IP:${N}"
echo    "  imunify360-agent whitelist ip add <IP>"
echo ""
echo -e "  ${D}# Imunify360 — blacklist an IP:${N}"
echo    "  imunify360-agent blacklist ip add --ip <IP> --ttl 0 --comment \"Spam\""
echo ""
echo -e "  ${D}# Enable SYN cookies immediately (survives until reboot):${N}"
echo    "  echo 1 > /proc/sys/net/ipv4/tcp_syncookies"
echo ""

sep
echo -e "${G}${B}  Done — $(date '+%H:%M:%S')${N}"
sep
echo ""
