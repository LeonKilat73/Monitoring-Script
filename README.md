# hostmon — Web Hosting Investigation Suite

> Self-contained Bash investigation scripts for cPanel/WHM shared hosting servers.
> Triggered manually via SSH after Zabbix alerts fire.
> **No dependencies. No config files. Drop anywhere and run.**

---

## The Problem This Solves

Zabbix tells you *that* something is wrong — CPU at 90%, disk at 85%, mail queue at 2000.
These scripts tell you **WHO, WHAT, and WHY** — and give you the one-liners to fix it.

```
Zabbix Alert: "CPU 90% on web01"
        ↓
bash cpu_investigate.sh
        ↓
→ Account: sorre657 — lsphp running wp-login.php brute force
→ Attack IPs identified
→ Suggested fix: csf -d <IP>
```

---

## Scripts

| Script | Trigger | What It Answers |
|---|---|---|
| `cpu_investigate.sh` | CPU spike alert | Which account/process/attack is causing it |
| `disk_investigate.sh` | Disk space alert | Which account/files + dry-run cleanup report |
| `mail_investigate.sh` | Mail queue alert | Spam source, PHP script, SMTP abuse, blacklist check |
| `firewall_status.sh` | Firewall alert | CSF/Imunify360 health, attack patterns, connection floods |
| `resource_audit.sh` | Memory/load alert | Service health (Nginx/Apache/MySQL) + resource pressure + MySQL + PHP + decision helper |

---

## Requirements

- Linux (RHEL/CentOS/Rocky or Ubuntu/Debian)
- cPanel/WHM environment
- Run as **root**
- No additional packages required — uses standard system tools only
  (`ps`, `awk`, `grep`, `ss`, `df`, `bc`, `exim`, `csf`, `imunify360-agent`, `mysql`)

---

## Installation

### Option 1 — Clone via Git (recommended)

```bash
git clone git@github.com:YOURORG/hostmon.git /opt/hostmon
chmod +x /opt/hostmon/*.sh
```

### Option 2 — wget single script

```bash
wget -O cpu_investigate.sh \
    https://raw.githubusercontent.com/YOURORG/hostmon/main/cpu_investigate.sh
chmod +x cpu_investigate.sh
```

### Option 3 — Deploy to all servers via Ansible

```yaml
# deploy_hostmon.yml
- hosts: all_linux
  tasks:
    - name: Clone hostmon repo
      git:
        repo: git@github.com:YOURORG/hostmon.git
        dest: /opt/hostmon
        version: main
        force: yes

    - name: Set executable permissions
      file:
        path: "{{ item }}"
        mode: '0750'
      with_fileglob:
        - /opt/hostmon/*.sh

    - name: Ensure log directory exists
      file:
        path: /var/log/hostmon
        state: directory
        mode: '0750'
```

```bash
ansible-playbook deploy_hostmon.yml -i your_inventory
```

---

## Usage

### cpu_investigate.sh

Run after a CPU spike alert to identify the source.

```bash
bash cpu_investigate.sh                   # Full investigation
bash cpu_investigate.sh --user sorre657  # Focus on one cPanel account
bash cpu_investigate.sh --top 25         # Show top 25 processes (default: 15)
```

**What it shows:**
- Top processes by CPU — full command line, elapsed time, cPanel account tag
- CPU rollup per cPanel account with verdict (Normal / Elevated / HIGH / CRITICAL)
- CloudLinux LVE usage — historical via `lveinfo`, live via `lveps`
- Web server worker count and Apache `server-status` active requests
- Top domains/accounts by recent web hits (cPanel domlogs)
- Active abuse detection: wp-login brute force, xmlrpc abuse, processes in `/tmp`, connection floods
- Recommendations + one-liners based on live conditions

---

### disk_investigate.sh

Run after a disk space alert to find what is filling the server.

```bash
bash disk_investigate.sh                   # Full scan
bash disk_investigate.sh --user johndoe   # Focus on one account
bash disk_investigate.sh --top 20         # Show more accounts (default: 10)
```

**What it shows:**
- Partition overview with color-coded usage (yellow ≥75%, red ≥90%)
- Top cPanel accounts by disk usage
- Per-account directory breakdown + largest individual files
- Mail queue size + largest mailboxes + spam/trash folders
- MySQL database sizes
- **Dry-run cleanup report** — shows what COULD be deleted with estimated space savings:
  - Old rotated log files
  - `/tmp` and `/var/tmp` files
  - cPanel bandwidth cache
  - Old backup archives in home dirs
  - Compressed domlogs

> ⚠ Nothing is ever deleted automatically. All cleanup is dry-run only.

---

### mail_investigate.sh

Run after a mail queue alert to identify and stop spam.

```bash
bash mail_investigate.sh                                       # Full report
bash mail_investigate.sh --user johndoe                       # Focus on account
bash mail_investigate.sh --user johndoe --action report       # Show their queue
bash mail_investigate.sh --user johndoe --action freeze       # Stop their mail
bash mail_investigate.sh --user johndoe --action unfreeze     # Resume delivery
bash mail_investigate.sh --user johndoe --action remove       # Purge their queue ⚠
bash mail_investigate.sh --user johndoe --action block        # Block options menu
bash mail_investigate.sh --user johndoe --action suspend      # Suspend account
```

**What it shows:**
- Queue total with breakdown: active / deferred / frozen
- Top senders by message count, mapped to cPanel account, with spam verdict
- Top recipient domains (where is it going?)
- PHP originating script detection (`X-PHP-Originating-Script` header parsing)
- Sample message header inspection with spam heuristics
- SMTP authentication abuse detection (credential stuffing, brute force)
- **Live DNSBL blacklist check** against 7 major lists (Spamhaus, SpamCop, Barracuda, etc.)
- Action menu: freeze / unfreeze / remove / block / suspend (all require typed `YES` confirmation)
- Hardening recommendations + essential one-liners

---

### firewall_status.sh

Run after a firewall or security alert to assess CSF and Imunify360 health.

```bash
bash firewall_status.sh                      # Full report (60min lookback)
bash firewall_status.sh --minutes 30        # Change lookback window
bash firewall_status.sh --check 1.2.3.4    # Check if IP is blocked anywhere
bash firewall_status.sh --block 1.2.3.4    # Block IP via CSF (with confirmation)
bash firewall_status.sh --unblock 1.2.3.4  # Unblock from CSF + Imunify360
```

**What it shows:**

**CSF Health:**
- Running state, testing mode check, LFD daemon status + uptime
- Permanent deny count, whitelist count, temp block count
- Key security settings from `csf.conf` with risky values highlighted in red/yellow

**LFD Log Analysis:**
- Top attacking IPs (private IPs filtered out) with pattern detection
- Services being targeted (SSH, FTP, SMTP, POP3, IMAP, WHM, wp-login, xmlrpc)
- Port scan detections
- Resource/process abuse triggers
- WordPress/xmlrpc specific blocks
- Email/script abuse blocks (LF_SCRIPT alerts)
- Current temporary block list

**Imunify360:**
- Service running state
- Feature status (WAF, Proactive Defense, Malware Scanner) — disabled features highlighted
- Recent incidents list
- Recent malware detections from log
- Proactive Defense mode

**iptables:**
- Total rule count with performance warning if >3000
- Per-chain rule breakdown
- ipset usage

**Connection Analysis:**
- Total / Established / SYN_RECV / TIME_WAIT / CLOSE_WAIT
- SYN flood detection with immediate mitigation steps
- Top source IPs by connection count with flood flag
- Busiest destination ports with service names (SSH, HTTP, SMTP, WHM, MySQL, etc.)

---

### resource_audit.sh

Run after a memory or sustained load alert for a full resource picture.
Also useful as a general daily health snapshot.

```bash
bash resource_audit.sh                   # Full audit
bash resource_audit.sh --user johndoe   # Deep-dive on one account
bash resource_audit.sh --top 20         # Show more accounts (default: 15)
```

**What it shows:**

**Section 0 — Critical Service Health Check (runs first):**
- Checks Nginx, Apache/LiteSpeed, and MySQL/MariaDB are actually running
- Shows PID, uptime, memory usage (MB), CPU%, and worker count per service
- Nginx: live connection stats (active / writing / waiting) from `stub_status`
- Apache/LiteSpeed: busy vs idle workers from `server-status` with saturation warning
- MySQL: connection count vs max_connections with threshold warnings
- Summary line: all-green OK or specific service alerts
- Uses 6 detection methods for MySQL (pgrep, pgrep -f, systemctl, socket file) — reliably detects MariaDB regardless of process name

**Section 1 — Resource Pressure Score:**
- Combined score per cPanel account: `CPU% + (RAM% × 0.5)`
- Verdict per account: Normal / Elevated / HIGH / CRITICAL
- Identifies the single highest-pressure account automatically
- Quick deep-dive command suggestion for top offender

**Section 2 — RAM Breakdown:**
- Total RAM and swap usage with color-coded thresholds
- OOM kill risk warning when RAM > 95%
- Top processes by actual RSS memory in MB
- Top cPanel accounts by total RAM consumption with approximate MB

**Section 3 — MySQL Resource Audit:**
- MySQL process CPU and RAM percentage
- Key global status metrics with flagged anomalies (slow queries, lock waits)
- Connection capacity usage (threads used vs max_connections) with warning at 70%+
- InnoDB buffer pool hit ratio — warns if below 95%
- Active queries running > 5 seconds
- Connections per cPanel account (mapped via DB user prefix)
- Top databases by size in MB

**Section 4 — PHP Workers:**
- Worker count by type: lsphp (LiteSpeed), PHP-FPM per version, PHP-CGI, PHP-CLI
- lsphp workers grouped by cPanel account with top script shown
- Long-running PHP CLI processes (>2 min) flagged as potential spam/abuse
- PHP-FPM pool status via socket (active/idle workers, max children reached)

**Section 5 — CloudLinux LVE:**
- Historical top CPU and memory consumers via `lveinfo`
- Live per-account LVE snapshot via `lveps` or `/var/lve/info`
- Accounts hitting LVE fault limits

**Section 6 — Web Server Slots:**
- LiteSpeed or Apache worker count, CPU%, RAM%
- Apache `server-status` busy/idle workers
- Worker count per cPanel account

**Section 7 — Decision Helper:**
- Pattern-based diagnosis across 7 scenarios:
  - Single account abuse → throttle via LVE or suspend
  - Load 3x+ core count → severe overload, immediate action
  - RAM > 95% → OOM kill risk, upgrade or migrate
  - High swap usage → RAM-constrained, upgrade needed
  - Both CPU and RAM high → server at capacity, plan migration
  - CPU high with normal RAM → single account or attack
  - High PHP CLI count → spam scripts, check mail queue
- All recommendations include the exact commands to run

**Section 8 — Optimization Quick Reference:**
- LVE throttle and limit commands
- MySQL kill query, slow log check, buffer pool tuning
- PHP-FPM restart per version
- lsphp kill per account
- Account suspend/unsuspend via WHM CLI

---

## Output Format

All scripts use a consistent color-coded terminal output:

| Symbol | Color | Meaning |
|---|---|---|
| `✔` | Green | Healthy / Normal |
| `•` | Cyan | Informational |
| `▲` | Yellow | Warning — monitor or investigate |
| `✖` | Red | Critical — action required |

---

## Security Notes

- All scripts **must be run as root**
- All destructive actions (queue removal, account suspension, IP blocking) require typing `YES` to confirm
- Disk cleanup is **dry-run only** — reports candidates but never deletes
- Scripts are read-only except for explicit `--action` or `--block/--unblock` flags

---

## Directory Structure

```
/opt/hostmon/
├── cpu_investigate.sh      # CPU spike investigation
├── disk_investigate.sh     # Disk space investigation
├── mail_investigate.sh     # Mail queue & spam investigation
├── firewall_status.sh      # CSF + Imunify360 health & attack analysis
├── resource_audit.sh       # Full resource audit + decision helper
└── README.md
```

> Each script is fully self-contained. No shared libraries, no config files required.

---

## MySQL Setup (for resource_audit.sh and disk_investigate.sh)

Both scripts connect to MySQL for database stats. Create `/root/.my.cnf` on each server:

```bash
cat > /root/.my.cnf << 'EOF'
[client]
user=root
password=YOUR_MYSQL_ROOT_PASSWORD
EOF
chmod 600 /root/.my.cnf
```

---

## Logs

Scripts write activity logs to `/var/log/hostmon/` (created automatically):

```
/var/log/hostmon/
├── cpu_investigate.log
├── disk_investigate.log
├── mail_investigate.log
└── firewall_status.log
```

---

## Updating Scripts on All Servers

Since each server has the repo cloned to `/opt/hostmon`, updates are a single Ansible command:

```bash
ansible all -m git -a \
    "repo=git@github.com:YOURORG/hostmon.git dest=/opt/hostmon version=main force=yes" \
    -i your_inventory
```

Or per server:

```bash
cd /opt/hostmon && git pull
```

---

## Roadmap

- [x] `cpu_investigate.sh` — CPU investigation with LVE + abuse detection
- [x] `disk_investigate.sh` — Disk investigation with dry-run cleanup
- [x] `mail_investigate.sh` — Mail queue + spam investigation + DNSBL check
- [x] `firewall_status.sh` — CSF + Imunify360 health + attack analysis
- [x] `resource_audit.sh` — Service health check (Nginx/Apache/MySQL) + full resource audit + decision helper
- [ ] Slack posting flag (`--slack`) across all scripts
- [ ] Ansible role for streamlined deployment
- [ ] Slack slash command wrapper for remote triggering without SSH

---

## Contributing

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/my-improvement`
3. Test on a staging cPanel server before submitting
4. Submit a pull request with a description of what was changed and why

---

## License

Internal use. All rights reserved.
