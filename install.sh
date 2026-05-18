#!/bin/bash
# =============================================================================
# install.sh — Hostmon Suite Installer
# =============================================================================
# Run this once on each server after cloning the repo:
#   bash /opt/hostmon/install.sh
#
# Or bootstrap from GitHub directly:
#   curl -sSL https://raw.githubusercontent.com/YOURORG/hostmon/main/install.sh | bash
# =============================================================================

set -e

INSTALL_DIR="/opt/hostmon"
LOG_DIR="/var/log/hostmon"
CONF_FILE="${INSTALL_DIR}/config/monitor.conf"

# Colors
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

_ok()   { echo -e "${GREEN}[OK]${RESET}    $*"; }
_info() { echo -e "${CYAN}[INFO]${RESET}  $*"; }
_warn() { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
_err()  { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}  Hostmon — Web Hosting Investigation Suite         ${RESET}"
echo -e "${BOLD}  Installer v1.0.0                                  ${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${RESET}"
echo ""

# --- Root check
[ "$EUID" -ne 0 ] && _err "Run as root: sudo bash install.sh"

# --- Determine script location (works whether run from clone or curl pipe)
if [ -n "$BASH_SOURCE" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/cpu_investigate.sh" ]; then
    SCRIPT_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_SRC="$INSTALL_DIR"
fi

_info "Source directory : $SCRIPT_SRC"
_info "Install target   : $INSTALL_DIR"
_info "Log directory    : $LOG_DIR"
echo ""

# --- Create directory structure
_info "Creating directory structure..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/lib"
mkdir -p "$LOG_DIR"
_ok "Directories created."

# --- Copy files if installing from a different source path
if [ "$SCRIPT_SRC" != "$INSTALL_DIR" ]; then
    _info "Copying scripts to $INSTALL_DIR..."
    cp "${SCRIPT_SRC}"/*.sh           "${INSTALL_DIR}/"        2>/dev/null || true
    cp "${SCRIPT_SRC}/lib/common.sh"  "${INSTALL_DIR}/lib/"    2>/dev/null || \
        _warn "lib/common.sh not found in source — copy manually"
    cp "${SCRIPT_SRC}/config/monitor.conf" "${INSTALL_DIR}/config/" 2>/dev/null || \
        _warn "config/monitor.conf not found — will create template"
    _ok "Files copied."
fi

# --- Verify all expected files exist
_info "Verifying files..."
MISSING=0
for f in \
    "${INSTALL_DIR}/lib/common.sh" \
    "${INSTALL_DIR}/config/monitor.conf" \
    "${INSTALL_DIR}/cpu_investigate.sh" \
    "${INSTALL_DIR}/resource_audit.sh" \
    "${INSTALL_DIR}/disk_investigate.sh" \
    "${INSTALL_DIR}/firewall_status.sh" \
    "${INSTALL_DIR}/mail_investigate.sh"; do

    if [ -f "$f" ]; then
        _ok "  Found: $f"
    else
        _warn "  MISSING: $f"
        MISSING=$((MISSING + 1))
    fi
done

[ "$MISSING" -gt 0 ] && _err "$MISSING file(s) missing. Check your repo clone."

# --- Set permissions
_info "Setting permissions..."
chmod 750 "${INSTALL_DIR}"/*.sh
chmod 640 "${INSTALL_DIR}/lib/common.sh"
chmod 640 "${INSTALL_DIR}/config/monitor.conf"
chmod 750 "$LOG_DIR"
_ok "Permissions set (scripts: 750, config: 640)."

# --- Check for required system commands
_info "Checking system dependencies..."
DEPS_MISSING=0
for cmd in ps awk grep sort curl bc exim csf; do
    if command -v "$cmd" &>/dev/null; then
        _ok "  $cmd — found"
    else
        _warn "  $cmd — NOT FOUND (some checks will be skipped)"
        DEPS_MISSING=$((DEPS_MISSING + 1))
    fi
done

# --- Check MySQL connectivity
echo ""
_info "Checking MySQL connectivity..."
if mysql -e "SELECT 1;" &>/dev/null; then
    _ok "MySQL: connected via /root/.my.cnf"
else
    _warn "MySQL: cannot connect. Create /root/.my.cnf:"
    echo ""
    echo "    cat > /root/.my.cnf << 'EOF'"
    echo "    [client]"
    echo "    user=root"
    echo "    password=YOUR_MYSQL_ROOT_PASSWORD"
    echo "    EOF"
    echo "    chmod 600 /root/.my.cnf"
    echo ""
fi

# --- Check config for placeholder values
echo ""
_info "Checking monitor.conf for unconfigured values..."
if grep -q "YOUR/WEBHOOK/URL" "$CONF_FILE" 2>/dev/null; then
    _warn "Slack webhook not set — edit: ${CONF_FILE}"
    _warn "  → Set SLACK_WEBHOOK_URL"
fi
if grep -q "YOUR_WHM_API_TOKEN" "$CONF_FILE" 2>/dev/null; then
    _warn "WHM API token not set — edit: ${CONF_FILE}"
    _warn "  → WHM → Development → API Tokens → Generate"
fi

# --- Create a quick-run wrapper in /usr/local/bin
_info "Creating /usr/local/bin/hostmon wrapper..."
cat > /usr/local/bin/hostmon << 'WRAPPER'
#!/bin/bash
# Hostmon quick launcher — run from anywhere
HOSTMON_DIR="/opt/hostmon"

if [ -z "$1" ]; then
    echo ""
    echo "Usage: hostmon <script> [options]"
    echo ""
    echo "Scripts:"
    echo "  cpu       cpu_investigate.sh"
    echo "  disk      disk_investigate.sh"
    echo "  resource  resource_audit.sh"
    echo "  firewall  firewall_status.sh"
    echo "  mail      mail_investigate.sh"
    echo ""
    echo "Options: --user <account>  --slack  --action <action>"
    echo ""
    echo "Examples:"
    echo "  hostmon cpu"
    echo "  hostmon cpu --user johndoe"
    echo "  hostmon mail --user johndoe --action freeze"
    echo "  hostmon disk --slack"
    exit 0
fi

CMD="$1"; shift
case "$CMD" in
    cpu)      bash "${HOSTMON_DIR}/cpu_investigate.sh"  "$@" ;;
    disk)     bash "${HOSTMON_DIR}/disk_investigate.sh" "$@" ;;
    resource) bash "${HOSTMON_DIR}/resource_audit.sh"   "$@" ;;
    firewall) bash "${HOSTMON_DIR}/firewall_status.sh"  "$@" ;;
    mail)     bash "${HOSTMON_DIR}/mail_investigate.sh" "$@" ;;
    *)
        echo "Unknown script: $CMD"
        echo "Valid: cpu | disk | resource | firewall | mail"
        exit 1
        ;;
esac
WRAPPER

chmod +x /usr/local/bin/hostmon
_ok "Wrapper created: /usr/local/bin/hostmon"

# --- Final summary
echo ""
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
echo -e "${BOLD}══════════════════════════════════════════════════${RESET}"
echo ""
echo -e "  ${BOLD}Configure:${RESET}  vi ${INSTALL_DIR}/config/monitor.conf"
echo ""
echo -e "  ${BOLD}Run:${RESET}"
echo    "    hostmon cpu                        # CPU investigation"
echo    "    hostmon cpu --user <account>       # Focus on account"
echo    "    hostmon mail                       # Mail queue report"
echo    "    hostmon mail --user <acct> --action freeze"
echo    "    hostmon disk --slack               # Post to Slack"
echo    "    hostmon firewall"
echo    "    hostmon resource"
echo ""
[ "$DEPS_MISSING" -gt 0 ] && \
    _warn "$DEPS_MISSING optional command(s) missing — related checks will skip gracefully."
echo ""
