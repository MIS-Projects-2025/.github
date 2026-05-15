# WSL2 Ubuntu Server Configuration Guide

> **Context:** Setting up WSL2 Ubuntu instances on Windows 11 machines for LAN-accessible server deployment — covering networking, SSH, Docker, and filesystem permissions.

# TODO to edit/restructure this documentation later:
place this step somewhere:
Docker expects HTTPS by default. Since your registry is HTTP, you need to mark it as insecure on 1.16:
sudo nano /etc/docker/daemon.json
add/paste this:
{
  "insecure-registries": ["192.168.1.16:5000"]
}
then sudo service docker restart

In Windows PowerShell (admin): Add Windows Firewall rules for Swarm ports. Set up port proxies with netsh
New-NetFirewallRule -DisplayName "Docker Swarm 2377" -Direction Inbound -Protocol TCP -LocalPort 2377 -Action Allow
New-NetFirewallRule -DisplayName "Docker Swarm 7946 TCP" -Direction Inbound -Protocol TCP -LocalPort 7946 -Action Allow
New-NetFirewallRule -DisplayName "Docker Swarm 7946 UDP" -Direction Inbound -Protocol UDP -LocalPort 7946 -Action Allow
New-NetFirewallRule -DisplayName "Docker Swarm 4789" -Direction Inbound -Protocol UDP -LocalPort 4789 -Action Allow
New-NetFirewallRule -DisplayName "Docker Registry" -Direction Inbound -Protocol TCP -LocalPort 5000 -Action Allow

$wsl2ip = (wsl hostname -I).Trim().Split()[0]
netsh interface portproxy add v4tov4 listenport=2377 listenaddress=0.0.0.0 connectport=2377 connectaddress=$wsl2ip
netsh interface portproxy add v4tov4 listenport=7946 listenaddress=0.0.0.0 connectport=7946 connectaddress=$wsl2ip
netsh interface portproxy add v4tov4 listenport=5000 listenaddress=0.0.0.0 connectport=5000 connectaddress=$wsl2ip
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
networkingMode=bridged
vmSwitch=WSL-Bridge
dnsTunneling=false
firewall=false
```

**Why each setting:**

| Setting | Reason |
|---|---|
| `networkingMode=bridged` | Puts the WSL2 VM directly on your LAN instead of behind Windows NAT. This is required so other machines on `192.168.1.x` can reach the WSL instance by its own IP. |
| `vmSwitch=WSL-Bridge` | Specifies the Hyper-V virtual switch to use. You must create this switch in Hyper-V Manager first, connected to your physical NIC. |
| `dnsTunneling=false` | Disables WSL's DNS tunneling proxy. Needed when you're on a bridged network with your own DNS setup. |
| `firewall=false` | Disables the WSL-managed Hyper-V firewall layer. You'll be managing firewall rules manually. |

> **Restart WSL after any `.wslconfig` change:** `wsl --shutdown` in PowerShell, then reopen Ubuntu.

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

## 5. Docker Swarm Ports (Reserved for Later)

These ports are needed for Docker Swarm inter-node communication across servers. Open them now so they're ready when Swarm is initialized.

Run in **PowerShell as Administrator**:

```powershell
# Swarm management port (manager nodes)
New-NetFirewallRule -DisplayName "Docker Swarm 2377" -Direction Inbound -Protocol TCP -LocalPort 2377 -Action Allow

# Node discovery and gossip
New-NetFirewallRule -DisplayName "Docker Swarm 7946 TCP" -Direction Inbound -Protocol TCP -LocalPort 7946 -Action Allow
New-NetFirewallRule -DisplayName "Docker Swarm 7946 UDP" -Direction Inbound -Protocol UDP -LocalPort 7946 -Action Allow

# VXLAN overlay network (container-to-container across hosts)
New-NetFirewallRule -DisplayName "Docker Swarm 4789" -Direction Inbound -Protocol UDP -LocalPort 4789 -Action Allow
```

| Port | Protocol | Purpose |
|---|---|---|
| 2377 | TCP | Swarm manager API — used by `docker swarm join` and orchestration |
| 7946 | TCP/UDP | Node gossip — health checks and cluster state sync between nodes |
| 4789 | UDP | VXLAN — the overlay network tunneling traffic between containers on different hosts |

> Also add corresponding Hyper-V firewall rules for these ports using `New-NetFirewallHyperVRule` if cross-host container networking doesn't work after joining the Swarm.

---

## 6. Static IP Assignment (Suppress DHCP)

DHCP reassigning your WSL IP breaks VS Code Remote SSH connections and any LAN service that depends on a stable IP.

### Kill the DHCP client

```bash
sudo pkill dhcpcd
```

### Assign a static IP manually

```bash
sudo ip addr flush dev eth0
sudo ip addr add 192.168.1.115/22 dev eth0
sudo ip route add default via 192.168.1.1 dev eth0
```

**Why each command:**

| Command | Reason |
|---|---|
| `ip addr flush dev eth0` | Removes all current IP assignments from the interface before adding a new one. Prevents IP conflicts. |
| `ip addr add 192.168.1.115/22 dev eth0` | Assigns the static IP. `/22` covers the `192.168.0.x`–`192.168.3.x` range — verify this matches your actual subnet mask. If your network uses `/24` (255.255.255.0), use `/24` here instead. |
| `ip route add default via 192.168.1.1 dev eth0` | Sets the default gateway so traffic destined outside the LAN has a path out. |

> **These settings don't survive WSL restarts.** To make them persistent, add the commands to `/etc/wsl.conf` under a `[boot]` command, or write a startup script. Example `/etc/wsl.conf` addition:
>
> ```ini
> [boot]
> command = "pkill dhcpcd; ip addr flush dev eth0; ip addr add 192.168.1.115/22 dev eth0; ip route add default via 192.168.1.1 dev eth0"
> ```

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
