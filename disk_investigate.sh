#!/bin/bash
# =============================================================================
# disk_investigate.sh — Self-contained Disk Investigation
# Drop anywhere, run as root. No external dependencies.
#
# PURPOSE: When Zabbix fires a disk space alert, find out:
#   - Which partitions are full
#   - Which cPanel accounts are consuming the most space
#   - Which specific files/directories are the culprits
#   - What old logs, tmp, cache files COULD be cleaned (dry-run only)
#
# USAGE:
#   bash disk_investigate.sh                     # Full scan all accounts
#   bash disk_investigate.sh --user johndoe      # Focus on one account
#   bash disk_investigate.sh --top 20            # Show more accounts
# =============================================================================

TARGET_USER=""
TOP_COUNT=10
OLD_LOG_DAYS=14
OLD_TMP_DAYS=3
OLD_BACKUP_DAYS=7
MIN_FILE_SIZE="10M"

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

# Human readable bytes
human_bytes() {
    local b="${1:-0}"
    if   [ "$b" -ge 1073741824 ]; then printf "%.1fG" "$(echo "$b/1073741824" | bc -l)"
    elif [ "$b" -ge 1048576 ];    then printf "%.1fM" "$(echo "$b/1048576"    | bc -l)"
    elif [ "$b" -ge 1024 ];       then printf "%.1fK" "$(echo "$b/1024"       | bc -l)"
    else printf "%dB" "$b"
    fi
}

HOSTNAME=$(hostname -f 2>/dev/null || hostname)

echo ""
echo -e "${B}╔══════════════════════════════════════════════════════════════╗${N}"
echo -e "${B}  DISK INVESTIGATION — ${HOSTNAME}${N}"
echo -e "${D}  $(date '+%Y-%m-%d %H:%M:%S')${N}"
[ -n "$TARGET_USER" ] && echo -e "${D}  Account filter: ${TARGET_USER}${N}"
echo -e "${B}╚══════════════════════════════════════════════════════════════╝${N}"

# =============================================================================
# SECTION 1 — Partition overview
# =============================================================================
hdr "1. DISK PARTITION OVERVIEW"
echo ""
printf "${B}  %-25s %6s %6s %6s %5s  %-s${N}\n" \
    "FILESYSTEM" "SIZE" "USED" "AVAIL" "USE%" "MOUNTED ON"
echo "  ──────────────────────────────────────────────────────────────────"

while IFS= read -r line; do
    USE_PCT=$(echo "$line" | awk '{print $5}' | tr -d '%')
    CLR=$N
    FLAG=""
    [ "${USE_PCT:-0}" -ge 90 ] && CLR=$R && FLAG=" ◄ CRITICAL"
    [ "${USE_PCT:-0}" -ge 75 ] && [ "${USE_PCT:-0}" -lt 90 ] && CLR=$Y && FLAG=" ◄ WARNING"
    echo -e "${CLR}  ${line}${FLAG}${N}"
done < <(df -h | tail -n +2 | grep -vE '^tmpfs|^devtmpfs|udev|/dev/loop')

# =============================================================================
# SECTION 2 — Top cPanel accounts by disk usage
# =============================================================================
hdr "2. TOP cPANEL ACCOUNTS BY DISK USAGE"
echo ""

if [ ! -d /home ]; then
    warn "/home not found — skipping account scan."
else
    printf "${B}  %-20s %10s  %-s${N}\n" "ACCOUNT" "DISK USED" "HOME PATH"
    echo "  ──────────────────────────────────────────────────────────────────"

    COUNT=0
    while IFS= read -r line; do
        SIZE=$(echo "$line"    | awk '{print $1}')
        PATH_=$(echo "$line"   | awk '{print $2}')
        ACCT=$(basename "$PATH_")

        [ -f "/var/cpanel/users/${ACCT}" ] || continue
        [ -n "$TARGET_USER" ] && [ "$ACCT" != "$TARGET_USER" ] && continue

        CLR=$N
        if [[ "$SIZE" == *G ]]; then
            GIGS=${SIZE%G}
            GIGS_INT=${GIGS%.*}
            [ "${GIGS_INT:-0}" -ge 20 ] && CLR=$R
            [ "${GIGS_INT:-0}" -ge 10 ] && [ "${GIGS_INT:-0}" -lt 20 ] && CLR=$Y
        fi

        printf "${CLR}  %-20s %10s  %-s${N}\n" "$ACCT" "$SIZE" "$PATH_"
        COUNT=$((COUNT + 1))
        [ "$COUNT" -ge "$TOP_COUNT" ] && break

    done < <(du -sh /home/*/ 2>/dev/null | sort -rh)
fi

# =============================================================================
# SECTION 3 — Per-account directory breakdown (top 5 consumers or --user)
# =============================================================================
hdr "3. ACCOUNT DIRECTORY BREAKDOWN"
echo ""

declare -a ACCOUNTS_TO_SCAN

if [ -n "$TARGET_USER" ]; then
    ACCOUNTS_TO_SCAN=("$TARGET_USER")
else
    # Auto-pick top 3 disk-consuming cPanel accounts
    while IFS= read -r line; do
        PATH_=$(echo "$line" | awk '{print $2}')
        ACCT=$(basename "$PATH_")
        [ -f "/var/cpanel/users/${ACCT}" ] && ACCOUNTS_TO_SCAN+=("$ACCT")
        [ "${#ACCOUNTS_TO_SCAN[@]}" -ge 3 ] && break
    done < <(du -sh /home/*/ 2>/dev/null | sort -rh)
fi

for ACCT in "${ACCOUNTS_TO_SCAN[@]}"; do
    HOME_DIR="/home/${ACCT}"
    [ -d "$HOME_DIR" ] || continue

    echo ""
    echo -e "  ${B}Account: ${Y}${ACCT}${N}  (${HOME_DIR})"
    echo "  ──────────────────────────────────────────────────────────────────"

    printf "  ${B}%-12s %-s${N}\n" "SIZE" "DIRECTORY"

    # Top subdirectories
    du -sh "${HOME_DIR}"/*/  2>/dev/null | sort -rh | head -12 | \
    while IFS= read -r line; do
        SIZE=$(echo "$line" | awk '{print $1}')
        DIR=$(echo  "$line" | awk '{print $2}' | sed "s|${HOME_DIR}/||")
        CLR=$N
        [[ "$SIZE" == *G ]] && CLR=$Y
        printf "${CLR}  %-12s %-s${N}\n" "$SIZE" "$DIR"
    done

    # Largest individual files
    echo ""
    info "Largest files in ${ACCT} (>${MIN_FILE_SIZE}):"
    find "$HOME_DIR" -type f -size +"$MIN_FILE_SIZE" 2>/dev/null | \
        xargs -I{} du -sh {} 2>/dev/null | \
        sort -rh | head -10 | \
    while IFS= read -r line; do
        SIZE=$(echo "$line" | awk '{print $1}')
        FILE=$(echo "$line" | awk '{print $2}' | sed "s|${HOME_DIR}/||")
        printf "    %-12s %-s\n" "$SIZE" "$FILE"
    done
done

# =============================================================================
# SECTION 4 — Mail queue & mailbox disk usage
# =============================================================================
hdr "4. MAIL QUEUE & MAILBOX DISK USAGE"
echo ""

# Exim queue size
if command -v exim &>/dev/null; then
    QUEUE_COUNT=$(exim -bpc 2>/dev/null || echo "0")
    QUEUE_DISK=$(du -sh /var/spool/exim/input 2>/dev/null | awk '{print $1}')
    if [ "${QUEUE_COUNT:-0}" -gt 100 ]; then
        crit "Exim queue: ${QUEUE_COUNT} messages | Disk: ${QUEUE_DISK:-unknown}"
        info "Top senders in queue:"
        exim -bp 2>/dev/null | grep -oE '<[^>]+>' | tr -d '<>' | \
            sort | uniq -c | sort -rn | head -10 | \
            while read -r cnt addr; do printf "    %-6s %s\n" "$cnt" "$addr"; done
    else
        ok "Exim queue: ${QUEUE_COUNT} messages | Disk: ${QUEUE_DISK:-unknown}"
    fi
else
    warn "Exim not found — skipping queue check."
fi

# Largest mailbox directories
echo ""
info "Largest mailbox directories per account:"
find /home -maxdepth 3 -type d -name "mail" 2>/dev/null | \
    while read -r maildir; do
        ACCT=$(echo "$maildir" | awk -F/ '{print $3}')
        [ -n "$TARGET_USER" ] && [ "$ACCT" != "$TARGET_USER" ] && continue
        SIZE=$(du -sh "$maildir" 2>/dev/null | awk '{print $1}')
        [[ "$SIZE" == "0"* ]] && continue
        printf "    %-12s %-20s %s\n" "$SIZE" "$ACCT" "$maildir"
    done | sort -rh | head -15

# Spam/Trash folders
echo ""
info "Large Spam/Trash folders (disk hogs):"
find /home -type d \( -iname "spam" -o -iname ".spam" \
                   -o -iname "trash" -o -iname ".trash" \
                   -o -iname "junk"  -o -iname ".junk" \) \
    2>/dev/null | while read -r d; do
    [ -n "$TARGET_USER" ] && [[ "$d" != *"/$TARGET_USER/"* ]] && continue
    SIZE=$(du -sh "$d" 2>/dev/null | awk '{print $1}')
    [[ "$SIZE" == "0"* ]] && continue
    OWNER=$(stat -c '%U' "$d" 2>/dev/null)
    printf "    %-12s %-20s %s\n" "$SIZE" "$OWNER" "$d"
done | sort -rh | head -15

# =============================================================================
# SECTION 5 — MySQL database sizes
# =============================================================================
hdr "5. MYSQL DATABASE SIZES"
echo ""

if mysql -e "SELECT 1;" &>/dev/null 2>&1; then
    info "Top databases by size:"
    echo ""
    printf "  ${B}%-40s %12s${N}\n" "DATABASE" "SIZE"
    echo "  ──────────────────────────────────────────────────────────────────"
    mysql -e "
        SELECT table_schema AS db,
               ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) AS size_mb
        FROM information_schema.tables
        WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
        GROUP BY table_schema
        ORDER BY size_mb DESC LIMIT 20;" 2>/dev/null | tail -n +2 | \
    while IFS=$'\t' read -r db size; do
        CLR=$N
        SIZE_INT=${size%.*}
        [ "${SIZE_INT:-0}" -ge 5000 ] && CLR=$R
        [ "${SIZE_INT:-0}" -ge 1000 ] && [ "${SIZE_INT:-0}" -lt 5000 ] && CLR=$Y
        printf "${CLR}  %-40s %10s MB${N}\n" "$db" "$size"
    done

    # MySQL data dir total
    echo ""
    MYSQL_DIR_SIZE=$(du -sh /var/lib/mysql 2>/dev/null | awk '{print $1}')
    info "Total MySQL data directory: ${MYSQL_DIR_SIZE:-unknown}  (/var/lib/mysql)"
else
    warn "Cannot connect to MySQL — ensure /root/.my.cnf exists."
    info "  cat > /root/.my.cnf << EOF"
    info "  [client]"
    info "  user=root"
    info "  password=YOUR_PASSWORD"
    info "  EOF"
    info "  chmod 600 /root/.my.cnf"
fi

# =============================================================================
# SECTION 6 — DRY-RUN CLEANUP REPORT (read-only, nothing deleted)
# =============================================================================
hdr "6. DRY-RUN CLEANUP REPORT  ⚠  NOTHING WILL BE DELETED"
echo ""
echo -e "  ${Y}This section shows what COULD be safely removed.${N}"
echo -e "  ${Y}Review carefully before any manual deletion.${N}"
echo ""

TOTAL_RECLAIMABLE=0

# --- Old rotated log files
info "Old rotated logs (>${OLD_LOG_DAYS} days, >1MB):"
LOG_TOTAL=0
while IFS= read -r f; do
    SIZE_B=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    SIZE_H=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
    printf "    %-12s %s\n" "$SIZE_H" "$f"
    LOG_TOTAL=$((LOG_TOTAL + SIZE_B))
    TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + SIZE_B))
done < <(find /home -type f \( \
    -name "*.log.gz" -o \
    -name "*.log.[0-9]*" -o \
    -name "access_log.*" -o \
    -name "error_log.*" \
    \) -mtime +"$OLD_LOG_DAYS" -size +1M 2>/dev/null | \
    { [ -n "$TARGET_USER" ] && grep "/home/${TARGET_USER}/" || cat; } | \
    head -30)
[ "$LOG_TOTAL" -gt 0 ] && echo -e "    ${G}  → Subtotal: $(human_bytes $LOG_TOTAL)${N}"

# --- Old /tmp files
echo ""
info "Old /tmp files (>${OLD_TMP_DAYS} days):"
TMP_TOTAL=0
while IFS= read -r f; do
    SIZE_B=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    SIZE_H=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
    printf "    %-12s %s\n" "$SIZE_H" "$f"
    TMP_TOTAL=$((TMP_TOTAL + SIZE_B))
    TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + SIZE_B))
done < <(find /tmp /var/tmp -type f -mtime +"$OLD_TMP_DAYS" 2>/dev/null | head -30)
[ "$TMP_TOTAL" -gt 0 ] && echo -e "    ${G}  → Subtotal: $(human_bytes $TMP_TOTAL)${N}"

# --- cPanel bandwidth cache
echo ""
info "Old cPanel bandwidth logs (>${OLD_LOG_DAYS} days):"
BW_TOTAL=0
while IFS= read -r f; do
    SIZE_B=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    SIZE_H=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
    printf "    %-12s %s\n" "$SIZE_H" "$f"
    BW_TOTAL=$((BW_TOTAL + SIZE_B))
    TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + SIZE_B))
done < <(find /var/cpanel/bandwidth -type f \
    -mtime +"$OLD_LOG_DAYS" 2>/dev/null | head -20)
[ "$BW_TOTAL" -gt 0 ] && echo -e "    ${G}  → Subtotal: $(human_bytes $BW_TOTAL)${N}"

# --- Old backup archives left in home dirs
echo ""
info "Old backup archives in home dirs (>${OLD_BACKUP_DAYS} days):"
BAK_TOTAL=0
while IFS= read -r f; do
    SIZE_B=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    SIZE_H=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
    OWNER=$(stat -c '%U' "$f" 2>/dev/null)
    printf "    %-12s %-15s %s\n" "$SIZE_H" "$OWNER" "$f"
    BAK_TOTAL=$((BAK_TOTAL + SIZE_B))
    TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + SIZE_B))
done < <(find /home -maxdepth 3 -type f \( \
    -name "backup-*.tar.gz" -o \
    -name "*.backup.tar.gz" -o \
    -name "backup_*.zip" -o \
    -name "*.tar.gz" \) \
    -mtime +"$OLD_BACKUP_DAYS" 2>/dev/null | \
    { [ -n "$TARGET_USER" ] && grep "/home/${TARGET_USER}/" || cat; } | \
    head -20)
[ "$BAK_TOTAL" -gt 0 ] && echo -e "    ${G}  → Subtotal: $(human_bytes $BAK_TOTAL)${N}"

# --- cPanel access logs in domlogs
echo ""
info "cPanel domlogs older than ${OLD_LOG_DAYS} days:"
DOM_TOTAL=0
while IFS= read -r f; do
    SIZE_B=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
    SIZE_H=$(du -sh "$f" 2>/dev/null | awk '{print $1}')
    printf "    %-12s %s\n" "$SIZE_H" "$f"
    DOM_TOTAL=$((DOM_TOTAL + SIZE_B))
    TOTAL_RECLAIMABLE=$((TOTAL_RECLAIMABLE + SIZE_B))
done < <(find /usr/local/apache/domlogs -type f \( \
    -name "*.gz" -o -name "*.bz2" \) \
    -mtime +"$OLD_LOG_DAYS" 2>/dev/null | \
    { [ -n "$TARGET_USER" ] && grep "/${TARGET_USER}" || cat; } | \
    head -30)
[ "$DOM_TOTAL" -gt 0 ] && echo -e "    ${G}  → Subtotal: $(human_bytes $DOM_TOTAL)${N}"

# --- Summary
echo ""
sep
echo -e "${B}  TOTAL POTENTIALLY RECLAIMABLE: ${G}$(human_bytes $TOTAL_RECLAIMABLE)${N}"
sep
echo ""
echo -e "  ${Y}⚠  Nothing was deleted. To clean, run these manually after reviewing:${N}"
echo ""
echo -e "  ${D}# Remove old tmp files:${N}"
echo    "  find /tmp /var/tmp -type f -mtime +${OLD_TMP_DAYS} -delete"
echo ""
echo -e "  ${D}# Remove old rotated logs in home dirs:${N}"
echo    "  find /home -type f -name '*.log.gz' -mtime +${OLD_LOG_DAYS} -delete"
echo ""
echo -e "  ${D}# Remove old compressed domlogs:${N}"
echo    "  find /usr/local/apache/domlogs -name '*.gz' -mtime +${OLD_LOG_DAYS} -delete"
echo ""
echo -e "  ${D}# cPanel built-in log cleanup (safe):${N}"
echo    "  /scripts/clean_user_php_log"
echo    "  /scripts/mysqlcheck --all-databases"
echo ""
echo -e "  ${D}# Check what's eating /var specifically:${N}"
echo    "  du -sh /var/* 2>/dev/null | sort -rh | head -20"

echo ""
sep
echo -e "${G}${B}  Done — $(date '+%H:%M:%S')${N}"
sep
echo ""
