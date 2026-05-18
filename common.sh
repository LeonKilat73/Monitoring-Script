#!/bin/bash
# =============================================================================
# /opt/hostmon/lib/common.sh — Shared Library
# =============================================================================
# Source this in every hostmon script:
#   source "$(dirname "$0")/lib/common.sh"
# =============================================================================

# Guard against double-sourcing
[ -n "$_HOSTMON_COMMON_LOADED" ] && return 0
_HOSTMON_COMMON_LOADED=1

# Resolve config relative to lib/../config/monitor.conf
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_BASE_DIR="$(dirname "$_LIB_DIR")"
CONFIG_FILE="${_BASE_DIR}/config/monitor.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] monitor.conf not found at: $CONFIG_FILE" >&2
    exit 1
fi
source "$CONFIG_FILE"

# -----------------------------------------------------------------------------
# TERMINAL COLORS
# -----------------------------------------------------------------------------
if [ -t 1 ]; then
    C_RED='\033[0;31m';    C_YELLOW='\033[1;33m'; C_GREEN='\033[0;32m'
    C_CYAN='\033[0;36m';   C_BOLD='\033[1m';       C_DIM='\033[2m'
    C_RESET='\033[0m'
else
    C_RED=''; C_YELLOW=''; C_GREEN=''; C_CYAN=''; C_BOLD=''; C_DIM=''; C_RESET=''
fi

# -----------------------------------------------------------------------------
# OUTPUT HELPERS
# -----------------------------------------------------------------------------
log_info()  { echo -e "${C_CYAN}[INFO]${C_RESET}  $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_RESET}  $*"; }
log_crit()  { echo -e "${C_RED}[CRIT]${C_RESET}  $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_RESET}  $*"; }
log_dim()   { echo -e "${C_DIM}        $*${C_RESET}"; }

section() {
    echo ""
    echo -e "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
    echo -e "${C_BOLD}  $*${C_RESET}"
    echo -e "${C_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
}

header() {
    local server
    server=$(hostname -f 2>/dev/null || hostname)
    echo ""
    echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════════╗${C_RESET}"
    echo -e "${C_BOLD}  $1${C_RESET}"
    echo -e "${C_DIM}  Server : ${server}${C_RESET}"
    echo -e "${C_DIM}  Time   : $(date +"$TIMESTAMP_FORMAT")${C_RESET}"
    echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════════╝${C_RESET}"
}

# -----------------------------------------------------------------------------
# LOGGING TO FILE
# -----------------------------------------------------------------------------
_ensure_log_dir() {
    mkdir -p "$LOG_DIR"
}

write_log() {
    local script="$1"
    local message="$2"
    _ensure_log_dir
    echo "[$(date +"$TIMESTAMP_FORMAT")] $message" >> "${LOG_DIR}/${script}.log"
}

# -----------------------------------------------------------------------------
# SLACK POSTING
# Full findings block posted to Slack
# Usage: slack_post "Script Name" "message body (plain text)"
# -----------------------------------------------------------------------------
slack_post() {
    [ "$SLACK_ENABLED" != "true" ] && return 0

    local title="$1"
    local body="$2"
    local server
    server=$(hostname -f 2>/dev/null || hostname)

    # Truncate if too long (Slack block limit)
    body="${body:0:2900}"

    local payload
    payload=$(cat <<EOF
{
    "username": "${SLACK_USERNAME}",
    "icon_emoji": ":mag:",
    "blocks": [
        {
            "type": "header",
            "text": { "type": "plain_text", "text": ":mag: ${title} — ${server}" }
        },
        {
            "type": "section",
            "text": { "type": "mrkdwn", "text": "\`\`\`${body}\`\`\`" }
        },
        {
            "type": "context",
            "elements": [
                { "type": "mrkdwn", "text": "HostMon v${HOSTMON_VERSION} | $(date +'%Y-%m-%d %H:%M:%S')" }
            ]
        }
    ]
}
EOF
)
    curl -s -o /dev/null -X POST \
        -H 'Content-type: application/json' \
        --data "$payload" \
        "$SLACK_WEBHOOK_URL"
}

# -----------------------------------------------------------------------------
# WHM API HELPER
# Usage: whm_api "listaccts" "searchtype=user&search=username"
# Returns: raw JSON response
# -----------------------------------------------------------------------------
whm_api() {
    local function_name="$1"
    local query_params="${2:-}"

    curl -sk \
        -H "Authorization: whm root:${WHM_API_TOKEN}" \
        "${WHM_PROTO}://${WHM_HOST}:${WHM_PORT}/json-api/${function_name}?api.version=1&${query_params}"
}

# -----------------------------------------------------------------------------
# GET CPANEL USERNAME FROM PROCESS PID
# Useful for mapping a suspicious PID back to a hosting account
# -----------------------------------------------------------------------------
pid_to_cpanel_user() {
    local pid="$1"
    local owner
    owner=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')

    # If it's a system user, check if it maps to a cPanel account
    if id "$owner" &>/dev/null; then
        # Check if this user has a cPanel home directory
        if [ -d "/home/${owner}/public_html" ] || \
           [ -f "/var/cpanel/users/${owner}" ]; then
            echo "$owner"
            return
        fi
    fi

    # Try to find via /proc ownership
    local proc_user
    proc_user=$(stat -c '%U' /proc/"$pid" 2>/dev/null)
    echo "${proc_user:-unknown}"
}

# -----------------------------------------------------------------------------
# GET ALL CPANEL ACCOUNTS (fast, from local system)
# -----------------------------------------------------------------------------
get_all_cpanel_users() {
    # Primary: read from /var/cpanel/users/ (always available, no API needed)
    if [ -d /var/cpanel/users ]; then
        ls /var/cpanel/users/ 2>/dev/null | grep -v '^\.' | sort
    else
        # Fallback: WHM API
        whm_api "listaccts" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); \
             [print(a['user']) for a in d.get('data',{}).get('acct',[])]" \
            2>/dev/null
    fi
}

# -----------------------------------------------------------------------------
# HUMAN READABLE BYTES
# -----------------------------------------------------------------------------
human_bytes() {
    local bytes="$1"
    if   [ "$bytes" -ge 1073741824 ]; then printf "%.1fG" "$(echo "$bytes/1073741824" | bc -l)"
    elif [ "$bytes" -ge 1048576 ];    then printf "%.1fM" "$(echo "$bytes/1048576"    | bc -l)"
    elif [ "$bytes" -ge 1024 ];       then printf "%.1fK" "$(echo "$bytes/1024"       | bc -l)"
    else printf "%dB" "$bytes"
    fi
}

# -----------------------------------------------------------------------------
# RUNTIME CHECK — ensure running as root
# -----------------------------------------------------------------------------
require_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${C_RED}[ERROR]${C_RESET} This script must be run as root." >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# DEPENDENCY CHECK
# Usage: require_cmds curl awk python3
# -----------------------------------------------------------------------------
require_cmds() {
    local missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${C_RED}[ERROR]${C_RESET} Missing required commands: ${missing[*]}" >&2
        exit 1
    fi
}
