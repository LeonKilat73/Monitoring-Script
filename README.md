# hostmon — Web Hosting Investigation Suite

> Self-contained Bash investigation scripts for cPanel/WHM shared hosting servers.
> Triggered manually via SSH after Zabbix alerts fire.
> **Drop anywhere and run. No config files. No shared libraries.**

---

## The Problem This Solves

Zabbix tells you *that* something is wrong — CPU at 90%, disk at 85%, mail queue at 2000.
These scripts tell you **WHO, WHAT, and WHY** — and give you the exact commands to fix it.

```
Zabbix Alert: "CPU 90% on web01"
        ↓
bash cpu_investigate.sh
        ↓
→ Account: sorre657 — lsphp running wp-login.php brute force
→ Top attacking IP: 1.2.3.4 (42 connections)
→ Fix: csf -d 1.2.3.4
→ Nginx rate limit: /etc/nginx/conf.d/users/sorre657.conf
```

---

## Scripts & Support Files

| File | Type | Purpose |
|---|---|---|
| `cpu_investigate.sh` | Bash script | CPU spike investigation |
| `disk_investigate.sh` | Bash script | Disk space investigation |
| `mail_investigate.sh` | Bash script | Mail queue & spam investigation |
| `firewall_status.sh` | Bash script | CSF + Imunify360 health & attack analysis |
| `resource_audit.sh` | Bash script | Service health + full resource audit |
| `lib_apache_parser.py` | Python helper | Apache server-status parser (used by cpu_investigate.sh) |

> `lib_apache_parser.py` must be in the **same directory** as `cpu_investigate.sh`

---

## Requirements

- Linux (RHEL/CentOS/Rocky or Ubuntu/Debian)
- cPanel/WHM environment
- Run as **root**
- Standard tools: `ps`, `awk`, `grep`, `ss`, `df`, `bc`, `curl`, `python3`
- Optional but recommended: `lynx` (for `apachectl fullstatus`)
- cPanel-specific: `exim`, `csf`, `imunify360-agent`, `mysql`, `lveinfo`, `lveps`

```bash
# Install lynx for apachectl fullstatus support
yum install lynx -y       # RHEL/Rocky/CentOS
apt install lynx -y       # Ubuntu/Debian
```

---

## Installation

### Option 1 — Clone via Git (recommended)

```bash
git clone git@github.com:YOURORG/hostmon.git /opt/hostmon
chmod +x /opt/hostmon/*.sh
```

### Option 2 — wget individual files

```bash
mkdir -p /opt/hostmon
cd /opt/hostmon

wget https://raw.githubusercontent.com/YOURORG/hostmon/main/cpu_investigate.sh
wget https://raw.githubusercontent.com/YOURORG/hostmon/main/disk_investigate.sh
wget https://raw.githubusercontent.com/YOURORG/hostmon/main/mail_investigate.sh
wget https://raw.githubusercontent.com/YOURORG/hostmon/main/firewall_status.sh
wget https://raw.githubusercontent.com/YOURORG/hostmon/main/resource_audit.sh
wget https://raw.githubusercontent.com/YOURORG/hostmon/main/lib_apache_parser.py

chmod +x /opt/hostmon/*.sh
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

    - name: Set executable permissions on scripts
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

    - name: Install lynx (for apachectl fullstatus)
      package:
        name: lynx
        state: present
```

```bash
ansible-playbook deploy_hostmon.yml -i your_inventory
```

---

## Usage

### cpu_investigate.sh + lib_apache_parser.py

Run after a CPU spike alert to identify the source.
**Both files must be in the same directory.**

```bash
bash cpu_investigate.sh                    # Full investigation
bash cpu_investigate.sh --user sorre657   # Focus on one cPanel account
bash cpu_investigate.sh --top 25          # Show top 25 processes (default: 15)
```

**What it shows:**

**Section 1 — Top Processes (top -c style):**
- Full command line per process (shows exact script path e.g. `lsphp:/home/user/wp-login.php`)
- Elapsed runtime, CPU%, MEM%, cPanel account tag
- Color coded: yellow ≥20% CPU, red ≥50% CPU

**Section 2 — CPU Rollup per cPanel Account:**
- Total CPU% and MEM% summed across all processes per account
- Verdict: Normal / Elevated / HIGH / CRITICAL
- Tracks highest pressure account for use in recommendations

**Section 3 — CloudLinux LVE Faults (last 15 minutes):**
- Runs exactly:
  ```
  lveinfo -d --period=15m --limit 20 -o any_faults \
    --show-columns id,from,to,iopsf,iof,cpuf,epf,pmemf,mcpu,ucpu,uep,upmem,nprocf
  ```
- Column legend printed inline
- Additional top-CPU view via `lveinfo --by-cpu`
- Live snapshot via `lveps --show-cpu` or `/var/lve/info`
- Auto-detects which accounts have CPU/EP/MEM faults with specific `lvectl` fix commands

**Section 4 — Apache Full Status (via lib_apache_parser.py):**

Five-strategy parser handles all Apache configurations automatically:

| Priority | Source | When available |
|---|---|---|
| 1 | `apachectl fullstatus` via lynx | Full detail: Client IP, VHost, CPU, active request URL |
| 2 | HTML `<table>` from `/server-status` | `ExtendedStatus On` in httpd.conf |
| 3 | Packed `<pre>` scoreboard | `ExtendedStatus Off` (default on most cPanel servers) |
| 4 | `?auto` plain text | Always — summary counts only |
| 5 | Scoreboard char counts | Always — mode letter counts only |

Output includes:
- Apache summary: busy/idle workers, utilization %, req/sec, uptime
- Worker mode counts (Waiting, Writing, Reading, DNS lookup, etc.)
- Full worker table with Srv, PID, Acc cur/child/slot, Mode, CPU, Client, VHost
- Active request URLs shown inline for Writing (W) workers
- **Top Client IPs** with flood detection and `csf -d` command
- **Top VHosts** being served with load flags
- **Top URLs** being served — wp-login.php and xmlrpc.php flagged automatically
- **Culprit Summary** — pinpoints exactly who/what is causing the load with fix commands

Worker Mode legend:

| Letter | Meaning | Watch for |
|---|---|---|
| `_` | Waiting (idle) | Normal |
| `W` | Writing — actively serving | High count = heavy traffic |
| `R` | Reading request | Normal |
| `K` | Keepalive | Normal |
| `D` | DNS lookup | High count = resolver problem |
| `G` | Graceful finish | Normal during restarts |
| `.` | Open slot | Normal |

> Enable full Client/VHost detail: WHM → Apache Config → Global Config → ExtendedStatus = On

**Section 5 — Nginx Status & Per-Account Config:**
- Process count, master/worker breakdown, CPU%, RAM%, uptime
- Live `stub_status`: active connections, reading, writing, waiting, total requests
- Color-coded flood detection (yellow ≥200 connections, red ≥500)
- Recent Nginx error log with severity coloring
- Global rate limiting scan across all of `/etc/nginx/`
- **Per-account config directory** `/etc/nginx/conf.d/users/` — lists all account configs and their rules
- Checks if top CPU account has a protection config, warns if missing

**Section 6 — Abuse & Attack Indicators:**
- wp-login.php brute force — active processes + attacker IPs from domlogs
- xmlrpc.php abuse — active processes
- Processes executing from `/tmp` or `/dev/shm` (malware indicator)
- Top source IPs by active connections with flood flag

**Section 7 — Recommendations:**
- Load-based diagnosis with specific account name and `lvectl`/`whmapi1` commands
- Apache worker saturation — explains WHY, CAUSE, and FIX steps
- Nginx flood prevention — ready-to-use config templates
- wp-login brute force — block IPs, rate limit, ModSecurity tips
- MySQL high CPU — processlist and slow query commands

**Section 7 — Nginx Per-Account Block Templates:**

Four ready-to-use templates for `/etc/nginx/conf.d/users/<account>.conf`:

| Template | What it does |
|---|---|
| A | Rate-limit `wp-login.php` + silently block `xmlrpc.php` for one account |
| B | Block specific attacker IPs or subnets using `geo` |
| C | Full protection — rate limit all requests + wp-login + xmlrpc + bad user agents |
| D | Country block using GeoIP module |

Step-by-step instructions:
1. Ensure `include /etc/nginx/conf.d/users/*.conf;` is in `nginx.conf`
2. Add global `limit_req_zone` and `limit_conn_zone` in `http {}` block
3. Create per-account `.conf` file from template
4. Test and reload: `nginx -t && systemctl reload nginx`

Live one-liner generated using the top CPU account detected in Section 2.

---

### disk_investigate.sh

Run after a disk space alert to find what is filling the server.

```bash
bash disk_investigate.sh                   # Full scan
bash disk_investigate.sh --user johndoe   # Focus on one account
bash disk_investigate.sh --top 20         # Show more accounts (default: 10)
```

**What it shows:**
- Partition overview — color-coded usage (yellow ≥75%, red ≥90%)
- Top cPanel accounts by disk usage with size color-coding
- Per-account directory breakdown + largest individual files (>10MB)
- Mail queue size + largest mailboxes + spam/trash folder sizes
- MySQL database sizes per schema in MB
- **Dry-run cleanup report** — never deletes anything, shows:
  - Old rotated log files (>14 days, >1MB)
  - `/tmp` and `/var/tmp` files (>3 days)
  - cPanel bandwidth cache (>14 days)
  - Old backup archives in home dirs (>7 days)
  - Compressed domlogs (>14 days)
  - Per-category subtotals + total reclaimable space
  - Safe cleanup commands to run manually after review

> ⚠ Nothing is ever deleted. All cleanup is dry-run and read-only.

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
- Queue total with breakdown: active / deferred / frozen + disk usage
- Color-coded severity (yellow >200, red >1000, critical >5000)
- Top senders by count mapped to cPanel account with spam verdict
- Top recipient domains — bulk target detection
- PHP originating script detection via `X-PHP-Originating-Script` headers
- Script classification: WordPress, Joomla, `/tmp` (malware), `public_html`
- Sample message header inspection — spam heuristics (missing headers, keywords)
- SMTP auth abuse: top authenticated senders, auth failure count, brute force IPs
- **Live DNSBL blacklist check** — Spamhaus, SpamCop, Barracuda, SORBS, UCEprotect, CBL, PSBL
- Delist URLs shown if IP is listed
- Action menu — all require typed `YES` confirmation:
  - `freeze` — freeze queue messages per account
  - `unfreeze` — resume delivery
  - `remove` — permanently delete queue (irreversible)
  - `block` — three options: Exim ACL, CSF UID block, WHM API email routing disable
  - `suspend` — suspend entire cPanel account via `whmapi1`
- Hardening recommendations: Exim rate limits, HELO enforcement, CSF SMTP_BLOCK, Imunify Proactive Defense, SPF/DKIM/DMARC
- Essential one-liners: exiqgrep, exim -Mrm, queue flush, freeze all, delist check

---

### firewall_status.sh

Run after a firewall or security alert.

```bash
bash firewall_status.sh                      # Full report (60min lookback)
bash firewall_status.sh --minutes 30        # Change lookback window
bash firewall_status.sh --check 1.2.3.4    # Check if IP is blocked anywhere
bash firewall_status.sh --block 1.2.3.4    # Block IP via CSF (with confirmation)
bash firewall_status.sh --unblock 1.2.3.4  # Unblock from CSF + Imunify360
```

**Quick actions** (`--check`, `--block`, `--unblock`) run and exit immediately — no full report.

**What it shows:**

**CSF Health:**
- Running state, testing mode check (red alert if TESTING=1), LFD daemon status + PID + uptime
- Permanent deny count, whitelist count, temp block count
- Large deny list warning (>5000 entries = iptables performance risk)
- Key security settings from `csf.conf` — risky values highlighted (TESTING, SMTP_BLOCK, SYNFLOOD)

**LFD Log Analysis:**
- Top attacking IPs — private IPs filtered, attack pattern flag at configurable threshold
- Services targeted: SSH, FTP, SMTP, POP3, IMAP, WHM, cPanel, wp-login, xmlrpc, dovecot
- Port scan detections
- Resource/process abuse triggers (LF_RESOURCE, nproc limits)
- WordPress/xmlrpc blocks
- Email/script abuse blocks (LF_SCRIPT alerts)
- Current temporary block list

**Imunify360:**
- Service running state with restart command if down
- Feature status — disabled features highlighted in yellow
- Recent incidents list
- Malware detections from console log
- Blacklisted IPs sample
- Proactive Defense mode status

**iptables:**
- IPv4 and IPv6 rule counts with performance warning if >3000
- Per-chain rule breakdown (non-empty chains only)
- ipset usage

**Connection Analysis:**
- Total / Established / SYN_RECV / TIME_WAIT / CLOSE_WAIT
- SYN flood detection — immediate mitigation: `echo 1 > /proc/sys/net/ipv4/tcp_syncookies`
- Top source IPs with flood flag and `csf -d` command
- Busiest destination ports with service names (SSH, HTTP, SMTP, WHM, MySQL, cPanel, Webmail)

---

### resource_audit.sh

Run after a memory or sustained load alert. Also useful as a daily health snapshot.

```bash
bash resource_audit.sh                   # Full audit
bash resource_audit.sh --user johndoe   # Deep-dive on one account
bash resource_audit.sh --top 20         # Show more accounts (default: 15)
```

**Section 0 — Critical Service Health Check (always runs first):**

Checks three critical services and shows a summary table:

```
SERVICE              STATUS       PID        UPTIME     MEM(MB)    EXTRA
──────────────────────────────────────────────────────────────────────────
Nginx                RUNNING      12345      3d 2h      48MB       workers: 4  cpu: 0.3%
  └─ connections     active: 42   writing: 5  waiting: 37
Apache (httpd)       RUNNING      12346      3d 2h      320MB      workers: 24  cpu: 12.4%
  └─ server-status   busy: 18  idle: 6  req/s: 4.2
mysqld               RUNNING      12347      3d 2h      1240MB     cpu: 8.1%
  └─ status          conn: 45/150  running: 3  slow_q: 2
```

- **Nginx** — process count, uptime, CPU/RAM, stub_status connections (flood warning at ≥200/≥500)
- **Apache/LiteSpeed** — auto-detected, worker count, server-status busy/idle with saturation warning
- **MySQL/MariaDB** — 6 detection methods (pgrep, pgrep -f, systemctl, socket file) — works regardless of process name or install method. Shows connections used/max with warning at 70%+
- Summary line: ✔ all OK or specific alerts with fix commands

**Section 1 — Resource Pressure Score:**
- Score = `CPU% + (RAM% × 0.5)` per cPanel account
- Verdict: Normal / Elevated / HIGH / CRITICAL
- Tracks highest pressure account, suggests deep-dive command

**Section 2 — RAM Breakdown:**
- Total RAM and swap with color-coded thresholds
- OOM kill risk warning at >95% RAM
- Top processes by RSS in MB
- Top cPanel accounts by RAM with approximate MB

**Section 3 — MySQL Resource Audit:**
- Process CPU/RAM
- Global status: slow queries, lock waits, connection count vs max
- InnoDB buffer pool hit ratio — warns below 95%
- Active queries running >5 seconds
- Connections mapped to cPanel accounts via DB user prefix
- Top databases by size in MB

**Section 4 — PHP Workers:**
- Count by type: lsphp, PHP-FPM per version, PHP-CGI, PHP-CLI
- lsphp workers by account with top script
- Long-running PHP CLI (>2 min) flagged as abuse
- PHP-FPM pool status via socket

**Section 5 — CloudLinux LVE:**
- Historical top CPU and memory consumers via `lveinfo`
- Live snapshot via `lveps` or `/var/lve/info`
- Accounts hitting fault limits

**Section 6 — Web Server Slots:**
- Worker count, CPU%, RAM% for Apache/LiteSpeed
- Per-account worker count

**Section 7 — Decision Helper:**
7 pattern-based diagnoses with account-specific commands:
- Single account abuse → `lvectl set` or `whmapi1 suspendacct`
- Load 3x+ cores → severe overload, immediate action
- RAM >95% → OOM risk, migrate or upgrade
- High swap → RAM constrained, upgrade
- Both CPU+RAM high → capacity issue, plan migration
- CPU high, RAM normal → single account or attack
- High PHP CLI → spam scripts, check mail queue

**Section 8 — Optimization Quick Reference:**
- LVE throttle, limit, history commands
- MySQL kill query, slow log, buffer pool tuning
- PHP-FPM restart per version, lsphp kill per account
- Account suspend/unsuspend via WHM CLI

---

## Directory Structure

```
/opt/hostmon/
├── cpu_investigate.sh        # CPU spike investigation
├── lib_apache_parser.py      # Apache status parser (required by cpu_investigate.sh)
├── disk_investigate.sh       # Disk space investigation
├── mail_investigate.sh       # Mail queue & spam investigation
├── firewall_status.sh        # CSF + Imunify360 health & attack analysis
├── resource_audit.sh         # Service health + full resource audit
└── README.md
```

> `lib_apache_parser.py` must be in the same directory as `cpu_investigate.sh`.
> All other scripts are fully self-contained with no external dependencies.

---

## Output Format

All scripts use consistent color-coded terminal output:

| Symbol | Color | Meaning |
|---|---|---|
| `✔` | Green | Healthy / Normal |
| `•` | Cyan | Informational |
| `▲` | Yellow | Warning — monitor or investigate |
| `✖` | Red | Critical — action required |

---

## Security Notes

- All scripts **must be run as root**
- All destructive actions require typing `YES` to confirm — nothing runs silently
- Disk cleanup is **dry-run only** — shows candidates, never deletes
- Scripts are read-only by default — only `--action` and `--block/--unblock` flags make changes

---

## MySQL Setup

Scripts that query MySQL (`resource_audit.sh`, `disk_investigate.sh`) need `/root/.my.cnf`:

```bash
cat > /root/.my.cnf << 'EOF'
[client]
user=root
password=YOUR_MYSQL_ROOT_PASSWORD
EOF
chmod 600 /root/.my.cnf
```

---

## Apache server-status Setup

Required for full Apache worker detail in `cpu_investigate.sh`.

**Enable in WHM:**
WHM → Apache Configuration → Global Configuration → Server Status = On, ExtendedStatus = On

**Or add manually to httpd.conf:**
```apache
<Location /server-status>
    SetHandler server-status
    Require ip 127.0.0.1
    ExtendedStatus On
</Location>
```

Then reload: `service httpd reload`

> Without `ExtendedStatus On`, Client IP/VHost/CPU columns will not be available.
> The parser still works — it falls back to scoreboard mode counts.

---

## Nginx Per-Account Protection Setup

`cpu_investigate.sh` checks and generates configs for `/etc/nginx/conf.d/users/`.

**One-time setup:**
```bash
# 1. Create the directory
mkdir -p /etc/nginx/conf.d/users

# 2. Add to nginx.conf inside http {} block
include /etc/nginx/conf.d/users/*.conf;

# 3. Add global rate limit zones to nginx.conf inside http {} block
limit_req_zone $binary_remote_addr zone=global_rate:10m rate=60r/m;
limit_req_zone $binary_remote_addr zone=login_rate:10m  rate=10r/m;
limit_conn_zone $binary_remote_addr zone=conn_limit:10m;

# 4. Test and reload
nginx -t && systemctl reload nginx
```

**Quick per-account protection (copy-paste):**
```bash
ACCT=johndoe
cat > /etc/nginx/conf.d/users/${ACCT}.conf << EOF
# Protection for ${ACCT}
location ~* /wp-login\.php$ { limit_req zone=login_rate burst=3 nodelay; }
location ~* /xmlrpc\.php$   { return 444; }
EOF
nginx -t && systemctl reload nginx
```

---

## Logs

Scripts write to `/var/log/hostmon/` (auto-created):

```
/var/log/hostmon/
├── cpu_investigate.log
├── disk_investigate.log
├── mail_investigate.log
└── firewall_status.log
```

---

## Updating All Servers

```bash
# All servers at once via Ansible
ansible all -m git -a \
    "repo=git@github.com:YOURORG/hostmon.git dest=/opt/hostmon version=main force=yes" \
    -i your_inventory

# Single server
cd /opt/hostmon && git pull
```

---

## Roadmap

- [x] `cpu_investigate.sh` — CPU investigation, LVE faults, Apache full status, Nginx status, per-account Nginx block templates
- [x] `lib_apache_parser.py` — Robust 5-strategy Apache status parser
- [x] `disk_investigate.sh` — Disk investigation with dry-run cleanup
- [x] `mail_investigate.sh` — Mail queue + spam + DNSBL blacklist check + action menu
- [x] `firewall_status.sh` — CSF + Imunify360 health + LFD analysis + connection flood detection
- [x] `resource_audit.sh` — Service health (Nginx/Apache/MySQL) + resource audit + decision helper
- [ ] Slack `--slack` flag across all scripts
- [ ] Ansible role for streamlined deployment
- [ ] Slack slash command wrapper for remote triggering without SSH

---

## Contributing

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/my-improvement`
3. Test on a staging cPanel server before submitting
4. Submit a pull request with description of what changed and why

---

## License

Internal use. All rights reserved.
