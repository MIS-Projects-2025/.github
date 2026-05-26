# WSL2 Ubuntu Server Configuration Guide

> **Context:** Setting up WSL2 Ubuntu instances on Windows 11 machines for LAN-accessible server deployment — covering networking, SSH, Docker, and filesystem permissions.

---

## Table of Contents

1. [SSH Server Setup (Port 2222)](#1-ssh-server-setup-port-2222)
2. [VS Code Remote SSH Configuration](#2-vs-code-remote-ssh-configuration)
3. [WSL2 Network Configuration (virtioproxy)](#3-wsl2-network-configuration-virtioproxy)
4. [Persistent Subnet Routes via `/etc/wsl.conf`](#4-persistent-subnet-routes-via-etcwslconf)
5. [DNS Resolution Fix](#5-dns-resolution-fix)
6. [Windows Firewall Rules](#6-windows-firewall-rules)
   - [6.1 Windows Firewall (Layer 1)](#61-windows-firewall-layer-1)
   - [6.2 Hyper-V Firewall (Layer 2)](#62-hyper-v-firewall-layer-2)
7. [Docker Swarm Ports](#7-docker-swarm-ports)
8. [Static IP Assignment (Suppress DHCP)](#8-static-ip-assignment-suppress-dhcp)
9. [Filesystem Permissions (`/var/www`)](#9-filesystem-permissions-varwww)
10. [Docker Group Access and IPv4 Configuration](#10-docker-group-access-and-ipv4-configuration)
11. [Auto-Pull Crontab for Workers](#11-auto-pull-crontab-for-workers)

---

## 1. SSH Server Setup (Port 2222)

Port 22 is typically used by Windows's own OpenSSH server. Using **port 2222** for WSL avoids the conflict.

### Install and configure

```bash
sudo apt install openssh-server -y
sudo nano /etc/ssh/sshd_config
```

Add or uncomment these lines:

```
Port 2222
ListenAddress 0.0.0.0
PasswordAuthentication yes
```

**Why:**

- `Port 2222` — Avoids conflict with Windows's SSH on port 22.
- `ListenAddress 0.0.0.0` — Listens on all interfaces, including the bridged LAN IP. Without this it may only listen on loopback.
- `PasswordAuthentication yes` — Allows password-based login (useful for initial setup; switch to key-based auth when stable).

### Disable socket-based activation

By default, newer OpenSSH uses systemd socket activation (`ssh.socket`), which can interfere with the manually configured port. Disable it:

```bash
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh
```

**Why:** `ssh.socket` intercepts connections before `sshd` reads its config, so your port/listen settings get ignored. Running `ssh` (the service) directly ensures your `sshd_config` is respected.

### Restart SSH

```bash
sudo service ssh restart
# or if systemd is available:
sudo systemctl restart ssh
```

---

## 2. VS Code Remote SSH Configuration

Install the **Remote - SSH** extension in VS Code, then configure it to connect to the WSL2 instance over LAN.

**Open the SSH config file:**

Press `Ctrl + Shift + P` → search for **Remote-SSH: Open SSH Configuration File** → select the user-level config (e.g. `C:\Users\<YourUser>\.ssh\config`).

**Add the host entry:**

```
Host mis-wsl2
  HostName 192.168.2.221
  User telfordmis
  Port 2222
```

Replace `192.168.2.221` and `telfordmis` with the actual LAN IP and username of the target WSL2 instance. After saving, the host `mis-wsl2` will appear in the Remote Explorer panel.

---

## 3. WSL2 Network Configuration (virtioproxy)

Edit `.wslconfig` on the **Windows host** (located at `C:\Users\<YourUser>\.wslconfig`):

```ini
[wsl2]
networkingMode=virtioproxy
dnsTunneling=true
firewall=false
```

> **Note:** `virtioproxy` is the required networking mode for internet access in current WSL2 builds. Earlier docs may reference `bridged` mode — use `virtioproxy` instead.

---

## 4. Persistent Subnet Routes via `/etc/wsl.conf`

WSL2 loses `ip route` additions on restart. Use the `[boot]` command in `/etc/wsl.conf` to restore routes and start SSH automatically on every WSL2 launch.

Edit `/etc/wsl.conf` inside the WSL2 instance:

```bash
sudo nano /etc/wsl.conf
```

Add:

```ini
[boot]
systemd = true
command = service ssh start ; GW=$(ip route | grep default | awk '{print $3}') ; ip route add 192.168.0.0/24 via $GW ; ip route add 192.168.1.0/24 via $GW ; ip route add 192.168.2.0/24 via $GW ; ip route add 192.168.3.0/24 via $GW ; ip route add 10.0.0.0/8 via $GW ; ip route add 172.16.0.0/12 via $GW
```

**What this does:**

- Starts the SSH service on boot.
- Detects the current default gateway dynamically.
- Adds routes for all relevant subnets (`192.168.x.x`, `10.x.x.x`, `172.16.x.x`) so machines on other LAN segments can reach apps hosted inside WSL2.

### Verify routes after boot

```bash
ip route
```

Expected output (example):

```
default via 192.168.1.1 dev enP38159p0s0 proto kernel
10.0.0.0/8 via 192.168.1.1 dev enP38159p0s0
172.16.0.0/12 via 192.168.1.1 dev enP38159p0s0
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1
192.168.0.0/22 dev enP38159p0s0 proto kernel scope link src 192.168.1.16
192.168.0.0/16 via 192.168.1.1 dev enP38159p0s0
```

---

## 5. DNS Resolution Fix

`virtioproxy` mode may lose automatic DNS. Fix it by hardcoding a nameserver:

```bash
sudo nano /etc/resolv.conf
```

Add or replace the content with:

```
nameserver 8.8.8.8
```

Then verify connectivity:

```bash
sudo apt update
```

> **Note:** WSL may regenerate `/etc/resolv.conf` on restart. To make this permanent, add `generateResolvConf=false` under `[network]` in `.wslconfig`, and ensure the file isn't a symlink (`ls -la /etc/resolv.conf`). If it is, unlink it first: `sudo unlink /etc/resolv.conf`.

---

## 6. Windows Firewall Rules

WSL2 in virtioproxy mode still passes through Windows's firewall stack. Two firewall layers exist and **both** may need rules.

### 6.1 Windows Firewall (Layer 1)

Run in **PowerShell as Administrator**:

```powershell
New-NetFirewallRule `
  -Name "AllowSSH-WSL-2222" `
  -DisplayName "Allow SSH WSL (Port 2222)" `
  -Direction Inbound `
  -Protocol TCP `
  -LocalPort 2222 `
  -Action Allow
```

This opens port 2222 in the standard Windows Defender Firewall.

### 6.2 Hyper-V Firewall (Layer 2)

Hyper-V has its own firewall that sits **below** the Windows Firewall. It blocks traffic before Windows even sees it.

```powershell
New-NetFirewallHyperVRule `
  -DisplayName "Allow WSL SSH Port 2222" `
  -Direction Inbound `
  -LocalPorts 2222 `
  -Action Allow
```

> **This is the rule most people miss.** If SSH is timing out from LAN despite the Windows firewall rule being present, a missing Hyper-V rule is almost always the cause.

---

## 7. Docker Swarm Ports

Open these ports on both the Windows Firewall and Hyper-V Firewall layers (same method as Section 6) for each Swarm node:

| Port | Protocol | Purpose |
|------|----------|---------|
| 2377 | TCP | Swarm cluster management |
| 7946 | TCP + UDP | Node-to-node communication |
| 4789 | UDP | Overlay network (VXLAN) |

---

## 8. Static IP Assignment (Suppress DHCP)

DHCP reassigning your WSL IP breaks VS Code Remote SSH connections and any LAN service that depends on a stable IP.

### Kill the DHCP client

```bash
sudo pkill dhcpcd
```

Assign the static IP and gateway manually after killing DHCP, or configure it in the `[boot]` command in `/etc/wsl.conf` (see Section 4).

---

## 9. Filesystem Permissions (`/var/www`)

Grants your user and the `www-data` group (used by nginx/PHP-FPM) shared write access to the web root.

```bash
sudo chown -R $(whoami):www-data /var/www
sudo chmod -R 775 /var/www
sudo chmod g+s /var/www
sudo usermod -aG www-data $(whoami)
```

**What each command does:**

| Command | Effect |
|---|---|
| `chown -R $(whoami):www-data /var/www` | Makes you the owner and `www-data` the group on all files under `/var/www`. |
| `chmod -R 775 /var/www` | Owner and group get full read/write/execute; others get read/execute only. |
| `chmod g+s /var/www` | Sets the **setgid bit**. New files created inside inherit the `www-data` group automatically. |
| `usermod -aG www-data $(whoami)` | Adds your user to the `www-data` group so you can write to group-owned files without `sudo`. |

> **Log out and back in** (or run `newgrp www-data`) after `usermod` for the group change to take effect in the current session.

### Fix: New files not inheriting group write permission

`chmod g+s` ensures new files inherit the `www-data` **group**, but not group write permission — Linux still applies the creating user's `umask`, which typically masks out group write (`umask 022`).

Fix it by setting `umask 002` permanently for your user:

```bash
echo "umask 002" >> ~/.bashrc
source ~/.bashrc
```

This ensures newly created files get `664` (`rw-rw-r--`) and directories `775` — group write included.

Also apply to root, since scripts may run with `sudo`:

```bash
echo "umask 002" >> /root/.bashrc
```

---

## 10. Docker Group Access and IPv4 Configuration

### Docker group (run Docker without `sudo`)

```bash
sudo usermod -aG docker $USER
newgrp docker
```

**Why:**

- The Docker socket (`/var/run/docker.sock`) is owned by the `docker` group. Only root and group members can access it.
- `usermod -aG docker $USER` adds you persistently.
- `newgrp docker` applies the change in the **current shell session** immediately.

> `newgrp` only affects the current terminal. Open a new terminal or re-login for the change to be globally active.

### Fix: Docker defaulting to IPv6

If Docker binds to `[::]` (IPv6) instead of `0.0.0.0` (IPv4), create or edit `/etc/docker/daemon.json`:

```bash
sudo nano /etc/docker/daemon.json
```

Add:

```json
{
  "ip": "0.0.0.0"
}
```

Then restart Docker:

```bash
sudo service docker restart
```

> This is especially common on machines where `/etc/docker/daemon.json` didn't exist at all — Docker falls back to its own defaults, which on some WSL2 builds prefer IPv6.

---

## 11. Auto-Pull Crontab for Workers

On worker nodes (e.g. servers `.14`, `.15`), set up a crontab to auto-pull updated images from the private registry every 5 minutes:

```bash
crontab -e
```

Add:

```cron
*/5 * * * * cd /var/www && docker compose pull ppc --quiet && docker compose up -d --no-deps ppc && docker cp www-ppc-1:/var/www/public /var/www/ppc/ > /dev/null 2>&1
```

**What this does:**

- Pulls the latest `ppc` image from the registry quietly.
- Restarts only the `ppc` container without touching other services (`--no-deps`).
- Copies the updated `/public` folder out of the container into the host path.
- Suppresses all output to avoid noisy cron mail.

---

## Quick Reference Checklist

- [ ] `.wslconfig` set to `virtioproxy` with `dnsTunneling=true`, `firewall=false`
- [ ] `/etc/resolv.conf` has a working nameserver (`8.8.8.8`)
- [ ] `apt update` succeeds
- [ ] `sshd_config` — port 2222, `ListenAddress 0.0.0.0`
- [ ] `ssh.socket` disabled; `ssh` service enabled and running
- [ ] VS Code Remote SSH config added for the host
- [ ] Windows Firewall rule for port 2222
- [ ] Hyper-V Firewall rule for port 2222
- [ ] Docker Swarm ports opened (2377 TCP, 7946 TCP/UDP, 4789 UDP) on both firewall layers
- [ ] Static IP assigned; DHCP client killed
- [ ] `/etc/wsl.conf` boot command set (SSH start + subnet routes)
- [ ] Routes verified with `ip route`
- [ ] `/var/www` ownership, permissions, and setgid bit set
- [ ] `umask 002` added to `~/.bashrc` and `/root/.bashrc`
- [ ] User added to `www-data` and `docker` groups
- [ ] `/etc/docker/daemon.json` set to `"ip": "0.0.0.0"`
- [ ] Auto-pull crontab configured on worker nodes
