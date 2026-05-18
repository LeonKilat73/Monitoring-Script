#!/bin/bash
# =============================================================================
# /opt/hostmon/firewall_status.sh
# =============================================================================
# PURPOSE: Investigate CSF and Imunify360 health, block patterns,
#          rule effectiveness, and whether the firewall itself is overloaded.
#
# USAGE:
#   bash firewall_status.sh               # Full firewall report
#   bash firewall_status.sh --slack       # Also post to Slack
#   bash firewall_status.sh --minutes 30  # Lookback window override
# =============================================================================

HOSTMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HOSTMON_DIR}/lib/common.sh"
require_root
require_cmds awk grep sort

POST_SLACK=false
LOOKBACK="${FIREWALL_LOOKBACK_MINUTES}"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --slack)   POST_SLACK=true ;;
        --minutes) LOOKBACK="$2"; shift ;;
    esac
    shift
done

SLACK_BUFFER=""
_sbuf() { SLACK_BUFFER+="$*"$'\n'; }

# =============================================================================
# SECTION 1 — CSF Status & Health
# =============================================================================
section_csf_status() {
    section "1. CSF (ConfigServer Security & Firewall) STATUS"
    echo ""

    _sbuf "=== CSF STATUS ==="

    if ! command -v csf &>/dev/null; then
        log_warn "CSF not installed or not in PATH."
        _sbuf "CSF: not found"
        return
    fi

    # Is CSF running?
    local csf_status
    if csf --status 2>/dev/null | grep -q "RUNNING"; then
        log_ok "CSF is RUNNING"
        _sbuf "CSF: RUNNING"
    else
        log_crit "CSF is STOPPED or in TEST MODE"
        _sbuf "CSF: STOPPED — CRITICAL"
    fi

    # Is CSF in testing mode? (iptables flushed every 5 min — very dangerous)
    if grep -q "^TESTING = \"1\"" /etc/csf/csf.conf 2>/dev/null; then
        log_crit "CSF is in TESTING MODE — firewall rules flush every 5 minutes!"
        _sbuf "CSF WARNING: TESTING MODE ENABLED"
    else
        log_ok "CSF testing mode: OFF (good)"
    fi

    # LFD (Login Failure Daemon) status
    echo ""
    if pgrep -x lfd &>/dev/null; then
        log_ok "LFD daemon: RUNNING"
        _sbuf "LFD: RUNNING"
    else
        log_crit "LFD daemon: NOT RUNNING — brute force detection is inactive"
        _sbuf "LFD: NOT RUNNING — CRITICAL"
    fi

    # CSF block counts
    echo ""
    local csf_deny_count csf_temp_count
    csf_deny_count=$(wc -l < /etc/csf/csf.deny 2>/dev/null || echo 0)
    csf_temp_count=$(csf -t 2>/dev/null | grep -c "IP:" || echo 0)

    log_info "Permanent blocks (csf.deny)  : ${csf_deny_count}"
    log_info "Temporary blocks (csf -t)    : ${csf_temp_count}"
    _sbuf "CSF permanent blocks: $csf_deny_count | temp blocks: $csf_temp_count"

    # Warn if deny list is very large (performance concern)
    if [ "$csf_deny_count" -gt 5000 ]; then
        log_warn "csf.deny has ${csf_deny_count} entries — consider using CIDR blocks or ipset for performance"
        _sbuf "CSF WARN: Large deny list may impact iptables performance"
    fi

    # Recent CSF config changes
    echo ""
    log_info "Last CSF config modification:"
    stat /etc/csf/csf.conf 2>/dev/null | grep Modify | \
        sed 's/Modify:/  Modified:/'
}

# =============================================================================
# SECTION 2 — LFD Log Analysis (brute force, port scans, bans)
# =============================================================================
section_lfd_analysis() {
    section "2. LFD LOG ANALYSIS (last ${LOOKBACK} minutes)"
    echo ""

    _sbuf ""
    _sbuf "=== LFD LOG (last ${LOOKBACK}m) ==="

    if [ ! -f "$CSF_LOG" ]; then
        log_warn "LFD log not found at: $CSF_LOG"
        _sbuf "LFD log not found"
        return
    fi

    # Get log entries from the last N minutes
    local since_time
    since_time=$(date -d "${LOOKBACK} minutes ago" '+%b %e %H:%M' 2>/dev/null || \
                 date -v-"${LOOKBACK}"M '+%b %e %H:%M' 2>/dev/null)

    local lfd_recent
    lfd_recent=$(awk -v since="$since_time" '$0 >= since' "$CSF_LOG" 2>/dev/null | \
                 tail -500)

    # --- Block events
    local block_count
    block_count=$(echo "$lfd_recent" | grep -c "Blocked\|DENY\|blocked" || echo 0)
    log_info "Block events in last ${LOOKBACK}m : ${block_count}"
    _sbuf "Blocks in last ${LOOKBACK}m: $block_count"

    # --- Top blocked IPs
    echo ""
    log_info "Top blocked IPs:"
    echo "$lfd_recent" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
        sort | uniq -c | sort -rn | head -10 | \
        while read -r count ip; do
            local flag=""
            [ "$count" -ge "$ATTACK_PATTERN_THRESHOLD" ] && \
                flag=" ◄ PATTERN ATTACK" && \
                _sbuf "  ATTACK PATTERN: $ip = $count blocks"
            printf "  %-6s %s%s\n" "$count" "$ip" \
                "${flag:+ ${C_RED}${flag}${C_RESET}}"
        done

    # --- Attack types
    echo ""
    log_info "Attack types detected:"
    echo "$lfd_recent" | grep -oE 'SSH|FTP|SMTP|POP3|IMAP|HTTP|WHM|cPanel' | \
        sort | uniq -c | sort -rn | \
        while read -r count svc; do
            printf "  %-6s %s login attacks\n" "$count" "$svc"
            _sbuf "  Attack type: $svc x$count"
        done

    # --- Port scans
    echo ""
    local portscan_count
    portscan_count=$(echo "$lfd_recent" | grep -ci "port scan\|PORTSCAN" || echo 0)
    if [ "$portscan_count" -gt 0 ]; then
        log_warn "Port scan detections: ${portscan_count}"
        _sbuf "PORT SCANS: $portscan_count"
        echo "$lfd_recent" | grep -i "port scan\|PORTSCAN" | tail -5 | \
            while read -r l; do log_dim "  $l"; done
    else
        log_ok "No port scan events in window."
    fi

    # --- Excessive resource usage blocks (cPanel/WHM accounts)
    echo ""
    local resource_blocks
    resource_blocks=$(echo "$lfd_recent" | grep -ci "resource\|excessive\|processes\|fork" || echo 0)
    if [ "$resource_blocks" -gt 0 ]; then
        log_warn "Resource abuse blocks: ${resource_blocks}"
        echo "$lfd_recent" | grep -i "resource\|excessive\|processes" | tail -10 | \
            while read -r l; do log_dim "  $l"; done
        _sbuf "RESOURCE ABUSE BLOCKS: $resource_blocks"
    fi
}

# =============================================================================
# SECTION 3 — Imunify360 Status & Events
# =============================================================================
section_imunify_status() {
    section "3. IMUNIFY360 STATUS"
    echo ""

    _sbuf ""
    _sbuf "=== IMUNIFY360 ==="

    if ! command -v imunify360-agent &>/dev/null; then
        log_warn "Imunify360 not installed or not in PATH."
        _sbuf "Imunify360: not found"
        return
    fi

    # Service health
    local svc_status
    svc_status=$(systemctl is-active imunify360 2>/dev/null || \
                 service imunify360 status 2>/dev/null | grep -oE 'running|stopped')
    if [ "$svc_status" = "active" ] || [ "$svc_status" = "running" ]; then
        log_ok "Imunify360 service: RUNNING"
        _sbuf "Imunify360: RUNNING"
    else
        log_crit "Imunify360 service: ${svc_status:-UNKNOWN} — investigate immediately"
        _sbuf "Imunify360: DOWN — $svc_status"
    fi

    # Imunify agent status
    echo ""
    log_info "Imunify360 agent status:"
    imunify360-agent version 2>/dev/null | while read -r l; do log_dim "  $l"; done

    # Recent blocked IPs
    echo ""
    log_info "Recently blocked IPs (Imunify360):"
    imunify360-agent blocked-port list 2>/dev/null | head -15 | \
        while read -r l; do log_dim "  $l"; done

    # Malware detections
    echo ""
    log_info "Recent malware scan events:"
    if [ -f "$IMUNIFY_LOG" ]; then
        local malware_events
        malware_events=$(tail -200 "$IMUNIFY_LOG" 2>/dev/null | \
                         grep -i "malware\|infected\|virus\|trojan" | tail -10)
        if [ -n "$malware_events" ]; then
            log_warn "Malware events found:"
            echo "$malware_events" | while read -r l; do log_dim "  $l"; done
            _sbuf "MALWARE EVENTS:"
            _sbuf "$malware_events"
        else
            log_ok "No recent malware events in log."
        fi
    else
        log_warn "Imunify360 log not found at: $IMUNIFY_LOG"
    fi

    # Imunify WAF status
    echo ""
    log_info "WAF (Web Application Firewall) status:"
    imunify360-agent feature-management status 2>/dev/null | \
        grep -iE "waf|modsec" | while read -r l; do log_dim "  $l"; done

    # Top attacked domains (from Imunify)
    echo ""
    log_info "Imunify360 — incidents summary:"
    imunify360-agent incidents list --limit 10 2>/dev/null | \
        while read -r l; do log_dim "  $l"; done
    _sbuf "Imunify360 incidents listed above."
}

# =============================================================================
# SECTION 4 — iptables rule count & performance check
# =============================================================================
section_iptables_health() {
    section "4. IPTABLES HEALTH & PERFORMANCE"
    echo ""

    _sbuf ""
    _sbuf "=== IPTABLES ==="

    if ! command -v iptables &>/dev/null; then
        log_warn "iptables not found."
        return
    fi

    # Rule counts per chain
    log_info "Rule counts per chain:"
    iptables -L --line-numbers -n 2>/dev/null | grep "^Chain" | \
        while read -r line; do
            local chain refs
            chain=$(echo "$line" | awk '{print $2}')
            refs=$(iptables -L "$chain" -n 2>/dev/null | tail -n +3 | wc -l)
            printf "  %-30s %s rules\n" "$chain" "$refs"
        done

    # Total rule count
    local total_rules
    total_rules=$(iptables -L -n 2>/dev/null | grep -c "^[A-Z]" || echo 0)
    local ip6_rules
    ip6_rules=$(ip6tables -L -n 2>/dev/null | grep -c "^[A-Z]" || echo 0)

    echo ""
    log_info "Total iptables rules  : ${total_rules}"
    log_info "Total ip6tables rules : ${ip6_rules}"

    if [ "$total_rules" -gt 3000 ]; then
        log_warn "High rule count may impact packet processing performance."
        log_warn "Consider: ipset-based blocking instead of individual IP rules."
        _sbuf "IPTABLES WARN: $total_rules rules — performance risk"
    else
        log_ok "Rule count is within normal range."
        _sbuf "iptables rules: $total_rules (OK)"
    fi

    # Check if ipset is in use (good practice)
    echo ""
    if command -v ipset &>/dev/null; then
        local ipset_count
        ipset_count=$(ipset list 2>/dev/null | grep -c "^Name:" || echo 0)
        log_info "ipset sets in use: ${ipset_count}"
        _sbuf "ipset sets: $ipset_count"
    else
        log_dim "ipset not installed (optional optimization for large block lists)"
    fi
}

# =============================================================================
# SECTION 5 — Active connection flood detection (real-time)
# =============================================================================
section_connection_analysis() {
    section "5. ACTIVE CONNECTIONS — FLOOD DETECTION"
    echo ""

    _sbuf ""
    _sbuf "=== CONNECTIONS ==="

    local total_conn established syn_recv time_wait
    total_conn=$(ss -s 2>/dev/null | grep "Total:" | awk '{print $2}' || echo 0)
    established=$(ss -s 2>/dev/null | grep "estab"   | awk '{print $4}' | tr -d ',' || echo 0)
    syn_recv=$(ss -s 2>/dev/null | grep "synrecv"  | awk '{print $2}' || echo 0)
    time_wait=$(ss -s 2>/dev/null | grep "timewait" | awk '{print $2}' || echo 0)

    log_info "Total connections  : ${total_conn}"
    log_info "Established        : ${established}"
    log_info "SYN_RECV           : ${syn_recv} $([ "${syn_recv:-0}" -gt 100 ] && echo '◄ POSSIBLE SYN FLOOD')"
    log_info "TIME_WAIT          : ${time_wait}"

    _sbuf "Connections: total=$total_conn estab=$established syn_recv=$syn_recv time_wait=$time_wait"

    if [ "${syn_recv:-0}" -gt 100 ]; then
        log_crit "SYN_RECV count is HIGH — possible SYN flood attack in progress"
        _sbuf "SYN FLOOD ALERT: $syn_recv SYN_RECV connections"
    fi

    # Top source IPs by connection count
    echo ""
    log_info "Top source IPs by active connections:"
    ss -tn state established 2>/dev/null | awk 'NR>1 {print $5}' | \
        cut -d: -f1 | sort | uniq -c | sort -rn | head -10 | \
        while read -r count ip; do
            local flag=""
            [ "$count" -ge 50 ] && flag=" ◄ INVESTIGATE" && color="$C_RED" || color="$C_RESET"
            printf "${color}  %-6s %s%s${C_RESET}\n" "$count" "$ip" "$flag"
            _sbuf "  IP: $ip = $count conns$flag"
        done

    # Ports under heaviest load
    echo ""
    log_info "Most active destination ports:"
    ss -tn state established 2>/dev/null | awk 'NR>1 {print $4}' | \
        rev | cut -d: -f1 | rev | sort | uniq -c | sort -rn | head -10 | \
        while read -r count port; do
            printf "  %-6s port %-6s\n" "$count" "$port"
        done
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    header "FIREWALL STATUS REPORT (CSF + Imunify360)"
    write_log "firewall_status" "Firewall check started"

    section_csf_status
    section_lfd_analysis
    section_imunify_status
    section_iptables_health
    section_connection_analysis

    echo ""
    section "FIREWALL CHECK COMPLETE"
    log_info "Log saved to: ${LOG_DIR}/firewall_status.log"
    write_log "firewall_status" "Firewall check complete"

    if [ "$POST_SLACK" = true ]; then
        slack_post "Firewall Status Report" "$SLACK_BUFFER"
        log_info "Findings posted to Slack."
    else
        log_dim "Tip: run with --slack to post findings to Slack"
    fi
}

main "$@"
