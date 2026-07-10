original source of this docs is here: https://claude.ai/share/6d600ba9-6e32-4e90-a447-4923cc3c0041

# TSPI-SERVER-05 Dual-Network Docker/WSL2 Access — README

## Why this document exists

`TSPI-SERVER-05` is **not a typical deployment box**. Unlike other servers, it has
**two physical Ethernet adapters**, each on a different subnet, because it needs to
serve two separate networks that do **not** route to each other:

| Network (SSID)      | Subnet             | Server IP on that subnet | Purpose |
|----------------------|---------------------|----------------------------|---------|
| **Telford Computers** | `192.168.1.0/22` (approx, incl. `192.168.3.x`) | `192.168.1.17` | General office/company network |
| **TSPI_V-One**         | `172.16.4.0/23`     | `172.16.4.19`               | Restricted network — only the 200 IC-processing machines, locked down for security so they can (in principle) only reach `tspi-server-05` |

Because of this, **the standard "one server = one IP" assumptions that work on every
other server do not apply here.** This doc explains why, what broke, how it was
diagnosed, and the exact configuration needed to make Docker apps (via WSL2)
reachable from **both** networks — matching how XAMPP/Apache already worked
natively on port 89.

If you're setting up a **normal single-NIC server**, most of this doesn't apply —
skip to [Simple servers (single NIC)](#simple-servers-single-nic) at the bottom.

---

## 1. Background: how the server is reachable

### Native Windows apps (XAMPP / Apache, port 89)
Apache runs directly on the Windows host. It binds to `0.0.0.0:89`, meaning it
listens on **every** network interface on the machine — both `192.168.1.17` and
`172.16.4.19`. This is why port 89 "just worked" from both networks from day one,
with no extra configuration. Native Windows apps don't have to deal with any of the
WSL2 networking complexity described below.

### Dockerized apps (via WSL2, e.g. nginx on 7100/7110/7111)
Docker runs **inside WSL2**, which is a lightweight VM with its own virtual network
stack. WSL2's networking mode determines how (or whether) traffic from the outside
world — including from `172.16.4.19` — ever reaches containers running inside it.
This is where everything got complicated.

---

## 2. WSL2 networking modes — what we tried and why

`.wslconfig` (lives at `%UserProfile%\.wslconfig` on the Windows host) controls
WSL2's networking behavior via the `[wsl2]` section's `networkingMode` key.

### `networkingMode=mirrored`
- WSL2 mirrors the host's **real network interfaces 1:1** — inside WSL2, `ip a`
  showed both `eth0` (`172.16.4.19`) and `eth1` (`192.168.1.17`), matching the
  Windows host's two physical NICs exactly.
- **Problem:** on this machine, combining `mirrored` mode with `firewall=false`
  caused Windows Firewall to silently drop *all* inbound external traffic — not
  just to WSL2/Docker ports, but even to the natively-running Apache. Local
  (`localhost`) access still worked, which made this confusing to diagnose (see
  [Section 4](#4-symptom-external-access-broke-completely-after-enabling-mirrored-mode)).
- Flipping to `firewall=true` fixed Apache/XAMPP access again, but **broke Docker
  port access from every network** — 7100/7110/7111 stopped responding externally
  even after adding explicit inbound firewall rules for those ports.
- **Verdict: do not use `mirrored` mode on this machine.** It's unreliable given
  the dual-NIC + firewall interaction here. (`mirrored` mode may be fine on
  single-NIC servers — untested.)

### `networkingMode=virtioproxy` (current, stable default)
- WSL2 uses its own internal virtual network, and Windows proxies traffic in and
  out to the WSL2 VM.
- This is what **every other (single-NIC) server** in the environment uses, and it
  works there without any extra steps beyond opening the right firewall port.
- On `TSPI-SERVER-05`, it works correctly **when the client and server are on the
  same subnet as the "primary" interface** (`192.168.1.17` ↔ Telford Computers),
  but has a **specific bug/limitation when proxying to the secondary NIC's IP
  (`172.16.4.19`) from a client on that same subnet** (TSPI_V-One):
  - TCP handshake completes and even `Test-NetConnection` reports success.
  - But actual HTTP response data never arrives — connection just hangs, or
    resets, depending on which side of the network you're testing from.
  - Confirmed via `tcpdump` inside WSL2: the full response (including a clean FIN
    close) *does* leave the container and *does* leave the physical NIC
    (`enP20126p0s0`) — the packets go out correctly on the Windows/WSL side. The
    loss/reset happens **after** that point, somewhere in virtioproxy's internal
    proxying/NAT logic for the non-primary interface, or possibly in
    reverse-path-filtering behavior triggered by the proxy rewriting source
    addresses in a way upstream network gear doesn't like.
  - Ruled out as *not* the cause: MTU/PMTU blackhole (tested clean up to 1472
    bytes), ARP resolution (resolves instantly and correctly), Windows Firewall
    profile settings (default/unconfigured, not blocking), routing table (correct
    routes and metrics present for both subnets).
- **Verdict: `virtioproxy` is correct and required, but is not sufficient by
  itself for the `172.16.4.19` (TSPI_V-One) path — needs the `portproxy`
  workaround below.**

### Final `.wslconfig` used on TSPI-SERVER-05:
```ini
[wsl2]
networkingMode=virtioproxy
firewall=true
memory=12GB
processors=4
swap=4GB
```

---

## 3. The fix: Windows native `portproxy` (the key workaround for dual-NIC servers)

Since virtioproxy reliably forwards to `127.0.0.1` (localhost) on the Windows host
for any WSL2/Docker published port, but has a bug forwarding to the *secondary*
external IP (`172.16.4.19`), the fix is to **bypass virtioproxy's cross-IP
forwarding entirely** using Windows' own built-in port forwarding
(`netsh interface portproxy`), which sits at the OS level and works completely
independently of WSL2's internal proxy logic.

**Concept:** tell Windows "anything that arrives on IP X, port Y, forward it to
`127.0.0.1:Y`" — and since WSL2 always exposes Docker's published ports on
`localhost` of the Windows host (regardless of networking mode), this reliably
reaches the container.

### Commands used (run in an elevated/Administrator PowerShell)

For each port your Docker app publishes, and for **each IP the server needs to be
reachable on**:

```powershell
# TSPI_V-One side (172.16.4.19)
netsh interface portproxy add v4tov4 listenaddress=172.16.4.19 listenport=7100 connectaddress=127.0.0.1 connectport=7100
netsh interface portproxy add v4tov4 listenaddress=172.16.4.19 listenport=7110 connectaddress=127.0.0.1 connectport=7110
netsh interface portproxy add v4tov4 listenaddress=172.16.4.19 listenport=7111 connectaddress=127.0.0.1 connectport=7111

# Telford Computers side (192.168.1.17) — added for consistency/robustness,
# even though this side happened to work without it
netsh interface portproxy add v4tov4 listenaddress=192.168.1.17 listenport=7100 connectaddress=127.0.0.1 connectport=7100
netsh interface portproxy add v4tov4 listenaddress=192.168.1.17 listenport=7110 connectaddress=127.0.0.1 connectport=7110
netsh interface portproxy add v4tov4 listenaddress=192.168.1.17 listenport=7111 connectaddress=127.0.0.1 connectport=7111
```

Verify all active rules:
```powershell
netsh interface portproxy show all
```

Remove a rule if needed (e.g. reconfiguring a port):
```powershell
netsh interface portproxy delete v4tov4 listenaddress=172.16.4.19 listenport=7100
```

### ⚠️ This step is NOT needed on other (single-NIC) servers
All other servers in the environment use plain `virtioproxy` with a single
network interface and reportedly work fine with **just** the firewall rule below
— no `portproxy` entries exist or are known to be configured on them. The
`portproxy` workaround is specifically compensating for the dual-NIC /
secondary-interface forwarding bug found on `TSPI-SERVER-05`. If you're setting up
a new single-NIC server, try without `portproxy` first (see
[Section 6](#6-simple-servers-single-nic)).

---

## 4. Symptom: external access broke completely after enabling mirrored mode

**What happened:** after switching to `networkingMode=mirrored`, *nothing* was
reachable externally — not Docker apps, not even XAMPP on port 89 — from either
network. `localhost` access on the server itself worked fine the whole time,
which made it look like the apps themselves were broken (they weren't).

**Root cause:** `mirrored` networking mode requires Windows Firewall's mirrored
inbound-allow integration to function. The `.wslconfig` had `firewall=false` set
(intended to reduce WSL-specific firewall friction), but this setting also
suppressed the automatic inbound-allow behavior mirrored mode depends on —
affecting **all** inbound traffic to the host, not just WSL2 traffic.

**Fix applied:** switched `firewall=false` → `firewall=true`. This restored
external access to port 89, but Docker ports remained broken (see below), which is
what ultimately led to abandoning `mirrored` mode entirely in favor of
`virtioproxy` + explicit `portproxy` rules.

**Lesson:** if XAMPP/Apache AND Docker apps both suddenly become unreachable
externally at the same time (while `localhost` still works), suspect a
`.wslconfig` networking mode change first — it's a host-wide firewall/networking
issue, not an application-level bug.

---

## 5. Full diagnostic path (for future reference / similar issues)

This is the order of checks that isolated the problem, useful as a general
troubleshooting checklist for "app not reachable externally, works locally":

1. **`ipconfig /all`** (host) — confirm the IP/subnet/gateway actually assigned to
   each adapter is what you expect. DHCP failures show up as `169.254.x.x` APIPA
   addresses with no gateway.
2. **`ping <target IP>`** — confirms basic Layer 3 reachability.
3. **`Test-NetConnection <IP> -Port <port>`** — confirms the TCP port is open
   and accepting connections. **Note:** this only validates the handshake — it
   does NOT confirm that a full request/response cycle completes. This gave a
   false sense of confidence during this investigation; always follow up with an
   actual `curl -v` test.
4. **`curl.exe <url> -v`** (from client) — shows the real HTTP exchange, or
   exactly where it hangs/resets if broken.
5. **`curl -v http://localhost:<port>/`** (on the server itself, inside WSL2) —
   confirms the app/container is actually healthy and serving correctly,
   isolating "app problem" from "network path problem."
6. **`sudo tcpdump -i any port <port> -n`** (inside WSL2) — shows exactly which
   interfaces (physical NIC → docker bridge → veth → container) the packets
   traverse, and where they stop. This was the single most useful diagnostic
   step — it proved the response data *was* leaving the server correctly, meaning
   the problem was downstream of WSL2/Docker, not inside it.
7. **`arp -a`** (client) — rules out ARP/duplicate-IP issues; check the resolved
   MAC matches the server's real NIC MAC.
8. **`ping -f -l <size>`** (client, decreasing size) — tests for a Path MTU
   blackhole (large packets silently dropped, small ones fine). Ruled out in this
   case up to 1472 bytes.
9. **`route print`** (host) — confirms correct routes/metrics exist for each
   subnet the server needs to serve.
10. **DNS-specific checks** (`nslookup`, `dig`, `cat /etc/resolv.conf`) — see
    [Section 5a](#5a-dns-specific-notes) below; a completely separate class of
    issue from the port-forwarding problem, but easy to confuse with it since
    both manifest as "can't reach the server."

### 5a. DNS-specific notes

Separately from the port-forwarding saga above, WSL2's DNS resolution needed its
own fix:

- **Symptom:** `nslookup tspi-server-05` failed inside WSL2 (`SERVFAIL` or wrong
  servers queried), while the same lookup worked fine from Windows PowerShell.
- **Root cause #1 — corrupted auto-generated resolver:** WSL2's
  auto-generated `/etc/resolv.conf` contained bogus nameservers (`1.0.0.2`,
  `1.0.0.3`) alongside the correct one (`192.168.1.2`), inherited from a stale/odd
  Windows adapter DNS config. Fixed by setting `generateResolvConf = false` in
  `/etc/wsl.conf` and manually writing `/etc/resolv.conf`.
- **Root cause #2 — missing DNS search domain:** even after fixing the
  nameserver, an **unqualified** query (`tspi-server-05`, no domain) returned
  `SERVFAIL`, while the **fully-qualified** name (`tspi-server-05.tspi.com`)
  resolved fine. This is because WSL2 didn't carry over Windows' DNS suffix
  search list. Fixed by adding a `search tspi.com` line to `/etc/resolv.conf`.

**Final working `/etc/resolv.conf` inside WSL2:**
```
nameserver 192.168.1.2
search tspi.com
```

**Final `/etc/wsl.conf`:**
```ini
[boot]
systemd=true
command = /usr/local/bin/wsl-startup.sh

[network]
generateResolvConf = false
```

- **Note on `ping tspi-server-05` showing `127.0.1.1`:** this WSL2 instance's own
  hostname *is* `TSPI-SERVER-05`, so `/etc/hosts` short-circuits the name to
  loopback (`127.0.1.1`) before DNS is even consulted. This is expected/harmless
  self-resolution, not a bug — Linux checks `/etc/hosts` before DNS by default.

- **Note on TSPI_V-One clients specifically:** devices connected to `TSPI_V-One`
  are assigned **public Cloudflare Family DNS** (`1.1.1.3`/`1.0.0.3`) by that
  network's DHCP — completely unrelated to the internal `tspi.com` DNS zone.
  Hostname resolution "working" there was actually **mDNS/`.local` link-local
  multicast discovery** kicking in as a Windows fallback (visible as
  `TSPI-SERVER-05.local` resolving to an `fe80::` IPv6 link-local address), not
  real DNS. This only works because the client happens to be on the same physical
  broadcast segment — it is not a reliable mechanism to depend on, and does **not**
  imply general IP routing is working. See Section 6 note on TSPI_V-One's design.

---

## 6. Why TSPI_V-One clients must use `172.16.4.19`, never `192.168.1.17`

TSPI_V-One-connected devices (the 200 IC-processing machines and similar) get
DHCP addresses on the `172.16.4.0/23` subnet (e.g. `172.16.5.176`). The server's
`192.168.1.17` address lives on a **completely different subnet**
(`192.168.1.0/22`-ish). There is **no routing configured between these two
subnets** — this appears to be intentional network segmentation for the
security-restricted TSPI_V-One network (limiting the 200 machines to reach
essentially only the server, and nothing else on the broader company network).

Because of this:
- `ping 192.168.1.17` / any access to `192.168.1.17` **will never work** from a
  TSPI_V-One-connected device, and this is not fixable from either endpoint — it
  would require a network admin to add cross-subnet routing, which may
  intentionally not exist for security reasons.
- The correct, working address for TSPI_V-One clients is the server's
  **second NIC's IP**: `172.16.4.19` — since that IP lives on the *same* subnet as
  TSPI_V-One clients, no routing is required at all (same broadcast domain).

### Summary — which address to use, from where

| Client network        | Use this address           | Notes |
|------------------------|------------------------------|-------|
| Telford Computers        | `192.168.1.17` or `tspi-server-05` (DNS-resolvable) | Full DNS available; hostname works normally |
| TSPI_V-One                | `172.16.4.19` **only**        | No DNS for internal zone on this network; no cross-subnet routing to `192.168.1.x`; hostname resolution here is unreliable mDNS fallback, don't depend on it |

**Recommendation:** hardcode `172.16.4.19` (not the hostname) in anything
deployed to/used by TSPI_V-One-restricted machines, until/unless:
- TSPI_V-One's DHCP is reconfigured to hand out the internal DNS server
  (`192.168.1.2`) instead of public Cloudflare DNS, **and**
- a DNS record is added resolving to `172.16.4.19` specifically for clients on
  that segment (split-horizon DNS), since `tspi-server-05` currently always
  resolves to `192.168.1.17` regardless of which network asks.

---

## 7. Checklist: adding a new Dockerized app/port on TSPI-SERVER-05

Every time a new container is published on a new port (e.g. `docker run -p
7200:7200 ...` or equivalent in `docker-compose.yml`), the following steps are
**all required** for it to be reachable from both networks — missing any one of
them will cause exactly the "works locally, not externally" confusion documented
above.

1. **Confirm the container publishes on `0.0.0.0`, not `127.0.0.1`** — e.g.
   `0.0.0.0:7200->7200/tcp` in `docker ps` output. If it only shows the bare
   container port with no `0.0.0.0:` prefix, it's internal-only (fine for
   PHP-FPM/backend services that nginx proxies to, but wrong for anything meant
   to be hit directly).
2. **Add the port to nginx's `default.conf`** (`listen` directives, `map
   $server_port $app_name` block, `server_name` list) — see existing config in
   `/var/www` for the pattern.
3. **Add a Windows Firewall inbound rule** (Administrator PowerShell):
   ```powershell
   New-NetFirewallRule -DisplayName "WSL App 7200" -Direction Inbound -Protocol TCP -LocalPort 7200 -Action Allow
   ```
4. **Add `portproxy` rules for both server IPs** (Administrator PowerShell):
   ```powershell
   netsh interface portproxy add v4tov4 listenaddress=172.16.4.19 listenport=7200 connectaddress=127.0.0.1 connectport=7200
   netsh interface portproxy add v4tov4 listenaddress=192.168.1.17 listenport=7200 connectaddress=127.0.0.1 connectport=7200
   ```
5. **Test from both networks** with `curl -v`, not just `Test-NetConnection`
   (which only proves the handshake works, not that data actually flows — see
   Section 5, step 3).

---

## 8. Simple servers (single NIC)

For servers with only **one** network interface (i.e. every other server besides
`TSPI-SERVER-05`), the dual-NIC-specific complexity above (mirrored-mode firewall
interaction, `portproxy` workaround, subnet segmentation) does not apply. The
baseline setup should be:

```ini
[wsl2]
networkingMode=virtioproxy
firewall=true
```

Plus, per published port:
```powershell
New-NetFirewallRule -DisplayName "WSL App <port>" -Direction Inbound -Protocol TCP -LocalPort <port> -Action Allow
```

That should be sufficient. **If a single-NIC server also exhibits the "handshake
succeeds but response never arrives" symptom**, the `portproxy` workaround from
Section 3 (using that server's one IP) is worth trying, but this has not been
confirmed necessary on any single-NIC server to date — treat it as a fallback, not
a default step.

---

## 9. Quick reference — key file locations

| File | Location | Purpose |
|------|----------|---------|
| `.wslconfig` | `C:\Users\<user>\.wslconfig` (Windows host) | WSL2 networking mode, resources |
| `wsl.conf` | `/etc/wsl.conf` (inside WSL2) | Boot behavior, DNS auto-generation toggle |
| `resolv.conf` | `/etc/resolv.conf` (inside WSL2) | DNS nameserver + search domain (manually maintained, not auto-generated) |
| nginx config | `/var/www/.../default.conf` or similar (inside WSL2) | Port routing to PHP-FPM containers |
| Firewall rules | Windows Defender Firewall (view via `Get-NetFirewallRule -DisplayName "*WSL*"`) | Per-port inbound allow rules |
| Port forwarding | `netsh interface portproxy show all` | Cross-IP forwarding rules (dual-NIC workaround) |

---

## 10. Known-good end state (as of this writing)

- **`.wslconfig`:** `networkingMode=virtioproxy`, `firewall=true`
- **DNS:** manual `/etc/resolv.conf` with `nameserver 192.168.1.2` + `search
  tspi.com`, `generateResolvConf=false` in `/etc/wsl.conf`
- **Firewall:** explicit inbound allow rules for each Docker port (7100, 7110,
  7111, ...)
- **Port forwarding:** `portproxy` rules mapping both `172.16.4.19:<port>` and
  `192.168.1.17:<port>` → `127.0.0.1:<port>` for each published Docker port
- **Access confirmed working:**
  - Telford Computers → `192.168.1.17:89` ✅, `192.168.1.17:7100` ✅
  - TSPI_V-One → `172.16.4.19:89` ✅, `172.16.4.19:7100` ✅ (after portproxy fix)
- **Known limitation (by design, not a bug):** `192.168.1.17` is unreachable from
  TSPI_V-One, and `172.16.4.19` is unreachable from Telford Computers — these are
  on non-routed subnets and each network must use its own matching IP.
