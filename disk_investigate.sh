#!/bin/bash
# =============================================================================
# /opt/hostmon/disk_investigate.sh
# =============================================================================
# PURPOSE: When Zabbix fires a disk space alert, run this to find out:
#   - Which cPanel accounts are consuming the most disk space
#   - Which specific files/directories are the biggest culprits
#   - What old logs, tmp files, caches could be cleaned (DRY RUN ONLY)
#
# USAGE:
#   bash disk_investigate.sh                    # Scan all accounts
#   bash disk_investigate.sh --user joe         # Focus on specific account
#   bash disk_investigate.sh --partition /home  # Specific partition
#   bash disk_investigate.sh --slack            # Post findings to Slack
# =============================================================================

HOSTMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${HOSTMON_DIR}/lib/common.sh"
require_root
require_cmds df du awk find sort

TARGET_USER=""
TARGET_PARTITION=""
POST_SLACK=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --user)      TARGET_USER="$2";      shift ;;
        --partition) TARGET_PARTITION="$2"; shift ;;
        --slack)     POST_SLACK=true ;;
    esac
    shift
done

SLACK_BUFFER=""
_sbuf() { SLACK_BUFFER+="$*"$'\n'; }

# =============================================================================
# SECTION 1 — Partition overview
# =============================================================================
section_partition_overview() {
    section "1. DISK PARTITION OVERVIEW"
    echo ""
    printf "${C_BOLD}%-20s %6s %6s %6s %5s  %-s${C_RESET}\n" \
        "FILESYSTEM" "SIZE" "USED" "AVAIL" "USE%" "MOUNTED ON"
    echo "──────────────────────────────────────────────────────────────"

    _sbuf "=== PARTITIONS ==="
    _sbuf "$(printf '%-20s %6s %6s %6s %5s %-s' FS SIZE USED AVAIL USE% MOUNT)"

    while IFS= read -r line; do
        local use_pct
        use_pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
        local color="$C_RESET"
        [ "${use_pct:-0}" -ge 90 ] && color="$C_RED"
        [ "${use_pct:-0}" -ge 75 ] && [ "${use_pct:-0}" -lt 90 ] && color="$C_YELLOW"

        echo -e "${color}${line}${C_RESET}"
        _sbuf "$line"
    done < <(df -h | tail -n +2 | grep -vE '^tmpfs|^devtmpfs|udev|/dev/loop')
}

# =============================================================================
# SECTION 2 — Top cPanel accounts by disk usage
# =============================================================================
section_account_disk_usage() {
    section "2. TOP cPANEL ACCOUNTS BY DISK USAGE"
    echo ""

    _sbuf ""
    _sbuf "=== ACCOUNT DISK USAGE ==="

    if [ ! -d /home ]; then
        log_warn "/home not found — skipping account scan."
        return
    fi

    printf "${C_BOLD}%-20s %10s  %-s${C_RESET}\n" "ACCOUNT" "DISK USED" "HOME PATH"
    echo "──────────────────────────────────────────────────────────────"

    local scan_base="/home"
    [ -n "$TARGET_PARTITION" ] && scan_base="$TARGET_PARTITION"

    local count=0
    while IFS= read -r line; do
        local size path account
        size=$(echo "$line"    | awk '{print $1}')
        path=$(echo "$line"    | awk '{print $2}')
        account=$(basename "$path")

        # Only process cPanel accounts
        [ -f "/var/cpanel/users/${account}" ] || continue

        local color="$C_RESET"
        # Highlight large accounts (crude but effective)
        [[ "$size" == *G ]] && {
            local gigs=${size%G}
            [ "${gigs%.*}" -ge 20 ] && color="$C_RED"
            [ "${gigs%.*}" -ge 10 ] && [ "${gigs%.*}" -lt 20 ] && color="$C_YELLOW"
        }

        printf "${color}%-20s %10s  %-s${C_RESET}\n" "$account" "$size" "$path"
        _sbuf "$(printf '%-20s %10s  %-s' "$account" "$size" "$path")"

        count=$((count + 1))
        [ "$count" -ge "$TOP_ACCOUNTS_COUNT" ] && break

    done < <(du -sh "${scan_base}"/*/  2>/dev/null | sort -rh | \
             { [ -n "$TARGET_USER" ] && grep "/${TARGET_USER}/" || cat; })
}

# =============================================================================
# SECTION 3 — Drill down into account directories
# =============================================================================
section_account_drilldown() {
    local accounts_to_scan=()

    if [ -n "$TARGET_USER" ]; then
        accounts_to_scan=("$TARGET_USER")
    else
        # Take top 5 disk consumers
        while IFS= read -r line; do
            local path account
            path=$(echo "$line" | awk '{print $2}')
            account=$(basename "$path")
            [ -f "/var/cpanel/users/${account}" ] && \
                accounts_to_scan+=("$account")
            [ "${#accounts_to_scan[@]}" -ge 5 ] && break
        done < <(du -sh /home/*/ 2>/dev/null | sort -rh)
    fi

    for account in "${accounts_to_scan[@]}"; do
        local home_dir="/home/${account}"
        [ -d "$home_dir" ] || continue

        section "3. DISK BREAKDOWN — ${account}"
        echo ""
        _sbuf ""
        _sbuf "=== BREAKDOWN: $account ==="

        printf "${C_BOLD}%-12s %-s${C_RESET}\n" "SIZE" "PATH"
        echo "──────────────────────────────────────────────────────────────"

        # Top subdirectories
        du -sh "${home_dir}"/*/  2>/dev/null | sort -rh | head -15 | \
        while IFS= read -r line; do
            local size path
            size=$(echo "$line" | awk '{print $1}')
            path=$(echo "$line" | awk '{print $2}' | sed "s|${home_dir}/||")
            printf "%-12s %-s\n" "$size" "$path"
            _sbuf "$(printf '%-12s %-s' "$size" "$path")"
        done

        # Biggest individual files under this account
        echo ""
        log_info "Largest files under ${account}:"
        find "$home_dir" -type f -size +"$DISK_MIN_FILE_SIZE" \
             2>/dev/null | \
             xargs -I{} du -sh {} 2>/dev/null | \
             sort -rh | head -10 | \
        while IFS= read -r line; do
            local size file
            size=$(echo "$line" | awk '{print $1}')
            file=$(echo "$line" | awk '{print $2}' | sed "s|${home_dir}/||")
            printf "  %-12s %-s\n" "$size" "$file"
            _sbuf "  FILE: $size  $file"
        done
    done
}

# =============================================================================
# SECTION 4 — Mail queue / mailboxes (common disk hog)
# =============================================================================
section_mail_analysis() {
    section "4. MAIL QUEUE & MAILBOX ANALYSIS"
    echo ""

    _sbuf ""
    _sbuf "=== MAIL ==="

    # Exim mail queue
    if command -v exim &>/dev/null; then
        local queue_count
        queue_count=$(exim -bpc 2>/dev/null || echo "0")
        if [ "${queue_count:-0}" -gt 100 ]; then
            log_warn "Exim queue: ${queue_count} messages (HIGH — possible spam)"
            _sbuf "MAIL QUEUE HIGH: $queue_count messages"

            # Top senders in queue
            log_info "Top senders in Exim queue:"
            exim -bp 2>/dev/null | grep "<" | \
                awk '{print $4}' | sort | uniq -c | sort -rn | head -10 | \
                while read -r count addr; do
                    printf "  %-5s %s\n" "$count" "$addr"
                done
        else
            log_ok "Exim queue: ${queue_count} messages (normal)"
            _sbuf "Mail queue: $queue_count messages (OK)"
        fi
    fi

    # Largest mailboxes
    echo ""
    log_info "Largest mailboxes:"
    find /home -path "*/mail/*" -name "*.mbx" -o \
               -path "*/mail/*" -name "cur" -type d \
               2>/dev/null | head -5 | while read -r mbox; do
        local size
        size=$(du -sh "$mbox" 2>/dev/null | awk '{print $1}')
        local owner
        owner=$(stat -c '%U' "$mbox" 2>/dev/null)
        printf "  %-12s %-20s %s\n" "$size" "$owner" "$mbox"
    done

    # Spam/trash folders
    echo ""
    log_info "Large spam/trash folders:"
    find /home -type d \( -name "spam" -o -name ".Spam" -o \
                          -name "Trash" -o -name ".Trash" \) \
               2>/dev/null | while read -r d; do
        local size
        size=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
        [[ "$size" == "0"* ]] && continue
        local owner
        owner=$(stat -c '%U' "$d" 2>/dev/null)
        printf "  %-12s %-20s %s\n" "$size" "$owner" "$d"
        _sbuf "  SPAM/TRASH: $size $owner $d"
    done | sort -rh | head -15
}

# =============================================================================
# SECTION 5 — DRY RUN CLEANUP REPORT
# Shows what WOULD be cleaned — never deletes anything
# =============================================================================
section_dry_run_cleanup() {
    section "5. DRY-RUN CLEANUP REPORT  ⚠  READ-ONLY — NOTHING WILL BE DELETED"
    echo ""
    echo -e "${C_YELLOW}  This section shows what COULD be safely removed.${C_RESET}"
    echo -e "${C_YELLOW}  Review carefully before any manual deletion.${C_RESET}"
    echo ""

    _sbuf ""
    _sbuf "=== DRY-RUN CLEANUP (nothing deleted) ==="

    local total_reclaimable=0
    declare -a cleanup_candidates

    # --- Old Apache/cPanel access logs
    log_info "Old rotated logs (>${DISK_OLD_LOG_DAYS} days):"
    while IFS= read -r f; do
        local size_bytes
        size_bytes=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        local size_human
        size_human=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        printf "  %-12s %s\n" "$size_human" "$f"
        cleanup_candidates+=("$size_bytes|LOG|$f")
        total_reclaimable=$((total_reclaimable + size_bytes))
        _sbuf "  [LOG] $size_human  $f"
    done < <(find /home -type f \( -name "*.log.*" -o -name "*.log.gz" \
                                 -o -name "access_log.*" -o -name "error_log.*" \) \
             -mtime +"$DISK_OLD_LOG_DAYS" -size +"1M" 2>/dev/null | head -30)

    # --- /tmp files older than threshold
    echo ""
    log_info "Old /tmp files (>${DISK_OLD_TMP_DAYS} days):"
    while IFS= read -r f; do
        local size_bytes
        size_bytes=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        local size_human
        size_human=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        printf "  %-12s %s\n" "$size_human" "$f"
        cleanup_candidates+=("$size_bytes|TMP|$f")
        total_reclaimable=$((total_reclaimable + size_bytes))
        _sbuf "  [TMP] $size_human  $f"
    done < <(find /tmp /var/tmp -type f \
             -mtime +"$DISK_OLD_TMP_DAYS" 2>/dev/null | head -30)

    # --- cPanel bandwidth log cache
    echo ""
    log_info "cPanel bandwidth logs (usually safe to clear on old entries):"
    while IFS= read -r f; do
        local size_human
        size_human=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        printf "  %-12s %s\n" "$size_human" "$f"
        _sbuf "  [BWLOG] $size_human  $f"
    done < <(find /var/cpanel/bandwidth -type f \
             -mtime +"$DISK_OLD_LOG_DAYS" 2>/dev/null | head -20)

    # --- cPanel user backup files left in home dirs
    echo ""
    log_info "cPanel backup files in home directories:"
    while IFS= read -r f; do
        local size_bytes
        size_bytes=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
        local size_human
        size_human=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
        local owner
        owner=$(stat -c '%U' "$f" 2>/dev/null)
        printf "  %-12s %-15s %s\n" "$size_human" "$owner" "$f"
        cleanup_candidates+=("$size_bytes|BACKUP|$f")
        total_reclaimable=$((total_reclaimable + size_bytes))
        _sbuf "  [BACKUP] $size_human $owner $f"
    done < <(find /home -maxdepth 3 -type f \
             \( -name "backup-*.tar.gz" -o -name "*.backup.tar.gz" \
                -o -name "backup_*.zip" \) \
             -mtime +"$DISK_OLD_BACKUP_DAYS" 2>/dev/null | head -20)

    # --- Summary
    echo ""
    echo "──────────────────────────────────────────────────────────────"
    local total_human
    total_human=$(human_bytes "$total_reclaimable")
    echo -e "${C_BOLD}  Total potentially reclaimable: ${C_GREEN}${total_human}${C_RESET}"
    echo ""
    echo -e "${C_YELLOW}  ⚠  To clean, an admin must manually review and delete.${C_RESET}"
    echo -e "${C_YELLOW}     Suggested command pattern (verify path first):${C_RESET}"
    echo -e "${C_DIM}     find /tmp -type f -mtime +${DISK_OLD_TMP_DAYS} -delete${C_RESET}"
    echo -e "${C_DIM}     find /home -name '*.log.gz' -mtime +${DISK_OLD_LOG_DAYS} -delete${C_RESET}"

    _sbuf ""
    _sbuf "Total reclaimable: ${total_human}"
    _sbuf "NOTE: Dry run only. Nothing was deleted."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    header "DISK INVESTIGATION REPORT"
    write_log "disk_investigate" "Investigation started"

    [ -n "$TARGET_USER" ]      && log_info "User filter     : ${TARGET_USER}"
    [ -n "$TARGET_PARTITION" ] && log_info "Partition filter: ${TARGET_PARTITION}"

    section_partition_overview
    section_account_disk_usage
    section_account_drilldown
    section_mail_analysis
    section_dry_run_cleanup

    echo ""
    section "INVESTIGATION COMPLETE"
    log_info "Full log: ${LOG_DIR}/disk_investigate.log"
    write_log "disk_investigate" "Investigation complete"

    if [ "$POST_SLACK" = true ]; then
        slack_post "Disk Investigation" "$SLACK_BUFFER"
        log_info "Findings posted to Slack."
    else
        log_dim "Tip: run with --slack to post findings to Slack"
    fi
}

main "$@"
