# WSL2 Ubuntu Server Configuration Guide

> **Context:** Setting up WSL2 Ubuntu instances on Windows 11 machines for LAN-accessible server deployment — covering networking, SSH, Docker, and filesystem permissions.

# TODO to edit/restructure this documentation later:
place this step somewhere:

this is to ensure docker uses IPv4
(hehe) 1.14 had no daemon.json at all, so Docker used its own defaults which on that machine happened to prefer IPv6 ([::]) instead of IPv4 (0.0.0.0).
sudo nano /etc/docker/daemon.json
add/paste this:
{
  "ip": "0.0.0.0"
}
then sudo service docker restart

ip route add subnets to grant all machines access to the apps in a server

NEW NA TALAGA
[boot]
systemd = true
command = service ssh start ; GW=$(ip route | grep default | awk '{print $3}') ; ip route add 192.168.0.0/24 via $GW ; ip route add 192.168.1.0/24 via $GW ; ip route add 192.168.2.0/24 via $GW ; ip route add 192.168.3.0/24 via $GW ; ip route add 10.0.0.0/8 via $GW ; ip route add 172.16.0.0/12 via $GW

crontab for workers (1.14 1.15 in current case)
*/5 * * * * cd /var/www && docker compose pull ppc --quiet && docker compose up -d --no-deps ppc && docker cp www-ppc-1:/var/www/public /var/www/ppc/ > /dev/null 2>&1

this will auto pull ghcr apps every 5mins.

verify (should look something like this):
telfordprogrammer@TSPI-SERVER-04:/var/www/ppc$ ip route
default via 192.168.1.1 dev enP38159p0s0 proto kernel 
10.0.0.0/8 via 192.168.1.1 dev enP38159p0s0 
169.254.73.152/30 dev loopback0 proto kernel scope link src 169.254.73.153 
172.16.0.0/12 via 192.168.1.1 dev enP38159p0s0 
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 
172.18.0.0/16 dev br-7b1241acf266 proto kernel scope link src 172.18.0.1 
192.168.0.0/22 dev enP38159p0s0 proto kernel scope link src 192.168.1.16 
192.168.0.0/16 via 192.168.1.1 dev enP38159p0s0 

virtioproxy is now the required networking mode for internet access (very important)
[wsl2]
networkingMode=virtioproxy
dnsTunneling=true
firewall=false

---

## Table of Contents

1. [WSL2 Network Configuration (Bridged Mode)](#1-wsl2-network-configuration-bridged-mode)
2. [DNS Resolution Fix](#2-dns-resolution-fix)
3. [SSH Server Setup (Port 2222)](#3-ssh-server-setup-port-2222)
4. [Windows Firewall Rules](#4-windows-firewall-rules)
   - [Windows Firewall (Layer 1)](#41-windows-firewall-layer-1)
   - [Hyper-V Firewall (Layer 2 — Bridged Mode Required)](#42-hyper-v-firewall-layer-2--bridged-mode-required)
5. [Docker Swarm Ports (Reserved for Later)](#5-docker-swarm-ports-reserved-for-later)
6. [Static IP Assignment (Suppress DHCP)](#6-static-ip-assignment-suppress-dhcp)
7. [Filesystem Permissions](#7-filesystem-permissions)
8. [Docker Group Access](#8-docker-group-access)

---

## 1. WSL2 Network Configuration (Bridged Mode)

Edit `.wslconfig` on the **Windows host** (located at `C:\Users\<YourUser>\.wslconfig`):

```ini
[wsl2]
networkingMode virtioproxy
dnsTunneling=false
firewall=false
```

---

## 2. DNS Resolution Fix

Bridged mode often loses automatic DNS. Fix it by hardcoding a nameserver:

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

> **Note:** WSL may regenerate `/etc/resolv.conf` on restart. To make this permanent, also add `generateResolvConf=false` under `[network]` in `.wslconfig`, and ensure the file isn't a symlink (`ls -la /etc/resolv.conf`). If it is, unlink it first: `sudo unlink /etc/resolv.conf`.

---

## 3. SSH Server Setup (Port 2222)

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

## 4. Windows Firewall Rules

WSL2 in bridged mode still passes through Windows's firewall stack. Two firewall layers exist and **both** may need rules.

### 4.1 Windows Firewall (Layer 1)

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

### 4.2 Hyper-V Firewall (Layer 2 — Bridged Mode Required)

In bridged/mirrored networking modes, Hyper-V has its own firewall that sits **below** the Windows Firewall. It blocks traffic before Windows even sees it.

```powershell
New-NetFirewallHyperVRule `
  -DisplayName "Allow WSL SSH Port 2222" `
  -Direction Inbound `
  -LocalPorts 2222 `
  -Action Allow
```

> **This is the rule most people miss.** If SSH is timing out from LAN despite the Windows firewall rule being present, a missing Hyper-V rule is almost always the cause.

---

## 6. Static IP Assignment (Suppress DHCP)

DHCP reassigning your WSL IP breaks VS Code Remote SSH connections and any LAN service that depends on a stable IP.

### Kill the DHCP client

```bash
sudo pkill dhcpcd
```

---

## 7. Filesystem Permissions (`/var/www`)

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
| `chmod g+s /var/www` | Sets the **setgid bit** on the directory. New files created inside inherit the `www-data` group automatically, instead of defaulting to the creating user's primary group. This is what keeps permissions consistent as you create new app directories. |
| `usermod -aG www-data $(whoami)` | Adds your user to the `www-data` group so you can write to group-owned files without `sudo`. |

> **Log out and back in** (or run `newgrp www-data`) after `usermod` for the group change to take effect in the current session.

---

## 8. Docker Group Access

Allows your user to run `docker` commands without `sudo`.

```bash
sudo usermod -aG docker $USER
newgrp docker
```

**Why:**

- By default, the Docker socket (`/var/run/docker.sock`) is owned by the `docker` group. Only root and members of that group can access it.
- `usermod -aG docker $USER` adds you to the group persistently.
- `newgrp docker` applies the change in the **current shell session** immediately, without needing to log out.

> `newgrp` only affects the current terminal. Open a new terminal or re-login for the change to be globally active.

---

## Quick Reference Checklist

- [ ] `.wslconfig` set to bridged mode with correct vmSwitch
- [ ] `/etc/resolv.conf` has a working nameserver
- [ ] `apt update` succeeds
- [ ] `sshd_config` — port 2222, ListenAddress 0.0.0.0
- [ ] `ssh.socket` disabled; `ssh` service enabled
- [ ] Windows Firewall rule for port 2222
- [ ] Hyper-V Firewall rule for port 2222
- [ ] Docker Swarm ports opened (2377, 7946 TCP/UDP, 4789 UDP)
- [ ] Static IP assigned; gateway route set
- [ ] `/etc/wsl.conf` boot command for IP persistence
- [ ] `/var/www` permissions and setgid bit set
- [ ] User added to `www-data` and `docker` groups
