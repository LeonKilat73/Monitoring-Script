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

> `resource_audit.sh` — Full resource pressure audit (coming soon)

---

## Requirements

- Linux (RHEL/CentOS/Rocky or Ubuntu/Debian)
- cPanel/WHM environment
- Run as **root**
- No additional packages required — uses standard system tools only (`ps`, `awk`, `grep`, `ss`, `df`, `exim`, `csf`, `imunify360-agent`)

---

## Installation

### Option 1 — Clone via Git (recommended)

```bash
git clone git@github.com:YOURORG/hostmon.git /opt/hostmon
chmod +x /opt/hostmon/*.sh
```

### Option 2 — wget single script

```bash
wget -O /opt/hostmon/cpu_investigate.sh \
    https://raw.githubusercontent.com/YOURORG/hostmon/main/cpu_investigate.sh
chmod +x /opt/hostmon/cpu_investigate.sh
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
bash mail_investigate.sh                              # Full report
bash mail_investigate.sh --user johndoe              # Focus on account
bash mail_investigate.sh --user johndoe --action report   # Show their queue
bash mail_investigate.sh --user johndoe --action freeze   # Stop their mail
bash mail_investigate.sh --user johndoe --action unfreeze # Resume delivery
bash mail_investigate.sh --user johndoe --action remove   # Purge their queue ⚠
bash mail_investigate.sh --user johndoe --action block    # Block options menu
bash mail_investigate.sh --user johndoe --action suspend  # Suspend account
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
- Running state, testing mode check, LFD daemon status
- Permanent deny count, whitelist count, temp block count
- Key security settings from `csf.conf` with risky values highlighted

**LFD Log Analysis:**
- Top attacking IPs with pattern detection
- Services being targeted (SSH, FTP, SMTP, POP3, IMAP, WHM, wp-login, xmlrpc)
- Port scan detections
- Resource/process abuse triggers
- WordPress/xmlrpc specific blocks
- Email/script abuse blocks (LF_SCRIPT alerts)
- Current temporary block list

**Imunify360:**
- Service running state
- Feature status (WAF, Proactive Defense, Malware Scanner) with disabled features highlighted
- Recent incidents list
- Recent malware detections from log
- Blacklisted IPs sample
- Proactive Defense mode

**iptables:**
- Total rule count with performance warning if >3000
- Per-chain rule breakdown
- ipset usage

**Connection Analysis:**
- Total / Established / SYN_RECV / TIME_WAIT / CLOSE_WAIT
- SYN flood detection with mitigation steps
- Top source IPs by connection count
- Busiest destination ports with service names

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
├── mail_investigate.sh     # Mail queue investigation
├── firewall_status.sh      # Firewall health and attack analysis
├── resource_audit.sh       # Full resource audit (coming soon)
└── README.md
```

> Each script is fully self-contained. No shared libraries, no config files required.

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

- [ ] `resource_audit.sh` — Combined CPU/RAM pressure score per account + MySQL + PHP-FPM audit + decision helper (upgrade vs optimize vs abuse)
- [ ] Slack posting flag (`--slack`) across all scripts
- [ ] Ansible role for full deployment
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
