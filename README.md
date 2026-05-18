# hostmon — Web Hosting Investigation Suite

Investigation scripts for cPanel/WHM servers. Triggered manually via SSH
after Zabbix alerts fire. Answers WHO, WHAT, and WHY — not just that
something is wrong.

---

## Scripts

| Script | When to Run | What It Answers |
|---|---|---|
| `cpu_investigate.sh` | After CPU spike alert | Which account/process/attack is causing it |
| `resource_audit.sh` | After memory/load alert | Full resource pressure score + DB/PHP audit |
| `disk_investigate.sh` | After disk space alert | Which account/files + dry-run cleanup report |
| `firewall_status.sh` | After firewall alert | CSF/Imunify360 health, patterns, connection floods |

---

## Setup

```bash
# 1. Clone to each server
git clone git@github.com:yourorg/hostmon.git /opt/hostmon

# 2. Set permissions
chmod +x /opt/hostmon/*.sh

# 3. Configure
vi /opt/hostmon/config/monitor.conf
#   → Set SLACK_WEBHOOK_URL
#   → Set WHM_API_TOKEN  (WHM → Dev → API Tokens)

# 4. Create MySQL credentials file (for resource_audit + cpu_investigate)
cat > /root/.my.cnf <<EOF
[client]
user=root
password=YOUR_MYSQL_ROOT_PASSWORD
EOF
chmod 600 /root/.my.cnf

# 5. Create log directory
mkdir -p /var/log/hostmon
```

---

## Usage

```bash
# CPU spike alert fired:
bash /opt/hostmon/cpu_investigate.sh
bash /opt/hostmon/cpu_investigate.sh --slack          # post findings to Slack
bash /opt/hostmon/cpu_investigate.sh --user johndoe   # focus on one account

# Disk space alert fired:
bash /opt/hostmon/disk_investigate.sh
bash /opt/hostmon/disk_investigate.sh --user johndoe

# Memory/load alert fired:
bash /opt/hostmon/resource_audit.sh
bash /opt/hostmon/resource_audit.sh --slack

# Firewall alert fired:
bash /opt/hostmon/firewall_status.sh
bash /opt/hostmon/firewall_status.sh --minutes 30     # change lookback window
```

---

## Deploy to All Servers via Ansible

```yaml
# deploy_hostmon.yml
- hosts: all_linux
  tasks:
    - name: Clone hostmon
      git:
        repo: git@github.com:yourorg/hostmon.git
        dest: /opt/hostmon
        version: main
        force: yes

    - name: Set permissions
      file:
        path: /opt/hostmon
        mode: '0750'
        recurse: yes

    - name: Ensure log directory
      file:
        path: /var/log/hostmon
        state: directory
        mode: '0750'
```

```bash
ansible-playbook deploy_hostmon.yml -i your_inventory
```

---

## Directory Structure

```
/opt/hostmon/
├── config/
│   └── monitor.conf          # All config lives here
├── lib/
│   └── common.sh             # Shared functions (colors, Slack, WHM API)
├── cpu_investigate.sh
├── resource_audit.sh
├── disk_investigate.sh
├── firewall_status.sh
└── README.md
```

---

## Adding a New Server

1. Push to your repo
2. Run the Ansible playbook against the new host
3. Edit `monitor.conf` if any thresholds differ (or use a host-specific override)

---

## Logs

All logs written to `/var/log/hostmon/`:
- `cpu_investigate.log`
- `resource_audit.log`
- `disk_investigate.log`
- `firewall_status.log`
# Monitoring-Script
