original source of this docs is here: https://claude.ai/share/6d600ba9-6e32-4e90-a447-4923cc3c0041

# TSPI-SERVER-05 Dual-Network Docker/WSL2 Access — README

## Why this document exists

`TSPI-SERVER-05` is **not a typical deployment box**. Unlike other servers, it has
**two physical Ethernet adapters**, each on a different subnet, because it needs to
serve two separate networks that do **not** route to each other at the client-subnet
level:

| Network (SSID)      | Subnet             | Server IP on that subnet | Purpose |
|----------------------|---------------------|----------------------------|---------|
| **Telford Computers** | `192.168.20.0/24` and neighboring `192.168.x.0/24` ranges, reached via gateway `192.168.20.1` | `192.168.20.30` *(previously `192.168.1.17` — see [Section 11](#11-ip-change-history))* | General office/company network |
| **TSPI_V-One**         | `172.16.4.0/23`     | `172.16.4.19`               | Restricted network — only the 200 IC-processing machines, locked down for security so they can (in principle) only reach `tspi-server-05` |

Because of this, **the standard "one server = one IP" assumptions that work on every
other server do not apply here.** This doc explains why, what broke, how it was
diagnosed, and the exact configuration needed to make Docker apps (via WSL2)
reachable from **both** networks — matching how XAMPP/Apache already worked
natively on port 89.

If you're setting up a **normal single-NIC server**, most of this doesn't apply —
skip to [Simple servers (single NIC)](#8-simple-servers-single-nic) at the bottom.

---

## 1. Background: how the server is reachable

### Native Windows apps (XAMPP / Apache, port 89)
Apache runs directly on the Windows host. It binds to `0.0.0.0:89`, meaning it
listens on **every** network interface on the machine — both `172.16.4.19` and
whatever the "Telford Computers" NIC's current IP is. This is why port 89 "just
worked" from both networks from day one, with no extra configuration. Native
Windows apps don't have to deal with any of the WSL2 networking complexity
described below.

### Dockerized apps (via WSL2, e.g. nginx on 7100/7110/7111/7112...)
Docker runs **inside WSL2**, which is a lightweight VM with its own virtual network
stack. WSL2's networking mode determines how (or whether) traffic from the outside
world ever reaches containers running inside it. This is where everything got
complicated — **two separate, unrelated bugs** were found and fixed, documented in
Sections 2–3 (Windows-side proxying) and Section 4a (WSL2-internal kernel routing).

---

## 2. WSL2 networking modes — what we tried and why

`.wslconfig` (lives at `%UserProfile%\.wslconfig` on the Windows host) controls
WSL2's networking behavior via the `[wsl2]` section's `networkingMode` key.

### `networkingMode=mirrored`
- WSL2 mirrors the host's **real network interfaces 1:1** — inside WSL2, `ip a`
  showed both physical NICs directly, matching the Windows host exactly.
- **Problem:** on this machine, combining `mirrored` mode with `firewall=false`
  caused Windows Firewall to silently drop *all* inbound external traffic — not
  just to WSL2/Docker ports, but even to the natively-running Apache. Local
  (`localhost`) access still worked, which made this confusing to diagnose (see
  [Section 5](#5-symptom-external-access-broke-completely-after-enabling-mirrored-mode)).
- Flipping to `firewall=true` fixed Apache/XAMPP access again, but **broke Docker
  port access from every network** — ports stopped responding externally even
  after adding explicit inbound firewall rules for those ports.
- **Verdict: do not use `mirrored` mode on this machine.** It's unreliable given
  the dual-NIC + firewall interaction here. (`mirrored` mode may be fine on
  single-NIC servers — untested.)

### `networkingMode=virtioproxy` (current, stable default)
- WSL2 uses its own internal virtual network, and Windows proxies traffic in and
  out to the WSL2 VM.
- This is what **every other (single-NIC) server** in the environment uses, and it
  works there without any extra steps beyond opening the right firewall port.
- On `TSPI-SERVER-05`, it works correctly **when the client and server are on the
  same subnet as the "primary" interface**, but had a **specific bug/limitation
  when proxying to the secondary NIC's IP from a client on that same subnet**:
  - TCP handshake completes and even `Test-NetConnection` reports success.
  - But actual HTTP response data never arrives — connection just hangs, or
    resets, depending on which side of the network you're testing from.
  - Confirmed via `tcpdump` inside WSL2: the full response (including a clean FIN
    close) *does* leave the container and *does* leave the physical NIC — the
    packets go out correctly on the Windows/WSL side. The loss/reset happens
    **after** that point, somewhere in virtioproxy's internal proxying/NAT logic
    for the non-primary interface, or possibly in reverse-path-filtering
    behavior triggered by the proxy rewriting source addresses in a way upstream
    network gear doesn't like.
  - Ruled out as *not* the cause: MTU/PMTU blackhole (tested clean up to 1472
    bytes), ARP resolution (resolves instantly and correctly), Windows Firewall
    profile settings (default/unconfigured, not blocking), routing table (correct
    routes and metrics present for both subnets).
- **Verdict: `virtioproxy` is correct and required, but is not sufficient by
  itself for reaching the secondary NIC's IP from a same-subnet client — needs
  the `portproxy` workaround below.**

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
external IP, the fix is to **bypass virtioproxy's cross-IP forwarding entirely**
using Windows' own built-in port forwarding (`netsh interface portproxy`), which
sits at the OS level and works completely independently of WSL2's internal proxy
logic.

**Concept:** tell Windows "anything that arrives on IP X, port Y, forward it to
`127.0.0.1:Y`" — and since WSL2 always exposes Docker's published ports on
`localhost` of the Windows host (regardless of networking mode), this reliably
reaches the container.

### Commands used (run in an elevated/Administrator PowerShell)

For each port your Docker app publishes, and for **each IP the server needs to be
reachable on** (both NICs):

```powershell
# TSPI_V-One side (172.16.4.19)
netsh interface portproxy add v4tov4 listenaddress=172.16.4.19 listenport=7100 connectaddress=127.0.0.1 connectport=7100
netsh interface portproxy add v4tov4 listenaddress=172.16.4.19 listenport=7110 connectaddress=127.0.0.1 connectport=7110
netsh interface portproxy add v4tov4 listenaddress=172.16.4.19 listenport=7111 connectaddress=127.0.0.1 connectport=7111
netsh interface portproxy add v4tov4 listenaddress=172.16.4.19 listenport=7112 connectaddress=127.0.0.1 connectport=7112

# Telford Computers side (current IP — see Section 11 for IP history)
netsh interface portproxy add v4tov4 listenaddress=192.168.20.30 listenport=7100 connectaddress=127.0.0.1 connectport=7100
netsh interface portproxy add v4tov4 listenaddress=192.168.20.30 listenport=7110 connectaddress=127.0.0.1 connectport=7110
netsh interface portproxy add v4tov4 listenaddress=192.168.20.30 listenport=7111 connectaddress=127.0.0.1 connectport=7111
netsh interface portproxy add v4tov4 listenaddress=192.168.20.30 listenport=7112 connectaddress=127.0.0.1 connectport=7112
```

Verify all active rules:
```powershell
netsh interface portproxy show all
```

Remove a rule if needed (e.g. reconfiguring a port, or an IP changes):
```powershell
netsh interface portproxy delete v4tov4 listenaddress=172.16.4.19 listenport=7100
```

### ⚠️ Housekeeping: `portproxy` rules are IP-specific and do NOT self-update
Unlike the WSL2-internal routing fix in [Section 4a](#4a-wsl2-internal-routing-bug-cross-subnet-clients-on-the-telford-side),
`portproxy` rules are tied to a literal IP address. **If the server's IP on the
Telford Computers NIC changes again** (as it already has once — see Section 11),
old rules pointing at the stale IP will linger harmlessly (they just won't match
any real traffic) and **new rules must be added for the new IP** for every port.
There is currently no dynamic/self-updating equivalent of this step — it must be
redone by hand after any IP change. Check what's currently configured with
`netsh interface portproxy show all` any time IP or port issues come up.

### ⚠️ This step is NOT needed on other (single-NIC) servers
All other servers in the environment use plain `virtioproxy` with a single
network interface and reportedly work fine with **just** the firewall rule below
— no `portproxy` entries exist or are known to be configured on them. The
`portproxy` workaround is specifically compensating for the dual-NIC /
secondary-interface forwarding bug found on `TSPI-SERVER-05`. If you're setting up
a new single-NIC server, try without `portproxy` first (see
[Section 8](#8-simple-servers-single-nic)).

---

## 4. A second, unrelated bug: WSL2-internal kernel routing (cross-subnet clients)

After the `portproxy` fix above, a **different** problem appeared later: clients on
subnets that are *not directly adjacent* to the server's own `/24` (e.g. a client on
`192.168.21.x` trying to reach the server on `192.168.20.30`) still hung with no
response, **even though `portproxy` and the firewall rule were both already
correctly configured.**

This turned out to be a completely separate bug from Sections 2–3, living entirely
**inside the WSL2 Linux VM's own kernel routing table**, not in Windows.

### 4a. WSL2-internal routing bug: cross-subnet clients on the Telford side

**Symptom (diagnosed via `tcpdump` inside WSL2):**
```
SYN arrives from client  →  forwarded into Docker bridge  →  nginx generates SYN-ACK
                                                                      ↓
                                                    SYN-ACK comes back INTO the bridge
                                                                      ↓
                                                         [ ...then NOTHING. ]
                              (SYN-ACK never gets forwarded back out the physical NIC)
```
The reply was generated correctly and reached the Docker bridge, but was never sent
back out to the real network. Confirmed with:
```bash
sudo tcpdump -i any port <port> -n
```

**Root cause:** the server's network interface inside WSL2 was configured with a
subnet mask **larger than the server's actual local subnet** — e.g. a `/23` mask
(`192.168.20.30/23`) instead of the correct `/24`. Linux auto-generates an on-link
route from that mask, meaning it believed the **entire** `/23` range (both
`192.168.20.0/24` AND `192.168.21.0/24`) was directly reachable on the local segment
with no gateway needed (ARP only). In reality, only the server's own `/24` is truly
local — anything in the "other half" of that `/23` (like a `192.168.21.x` client)
is actually only reachable **through the gateway**. Because WSL2 incorrectly
believed it could reach `192.168.21.x` directly, it tried to ARP for it instead of
routing through the gateway — and the reply was silently dropped instead of ever
being sent.

This bug is **completely unrelated** to the `virtioproxy`/`portproxy` issue in
Sections 2–3 — it lives entirely inside the WSL2 Linux kernel's own routing table,
not in Windows' proxying layer. Both bugs can be present at once and must both be
fixed independently.

**Why this will keep recurring for new/unknown subnets:** any client subnet that
happens to fall inside the oversized on-link block (or that has no matching route
at all) will hit this same silent-drop behavior. The original stopgap fix was
adding explicit routes per subnet by hand:
```bash
# OLD APPROACH — fragile, had to be redone for every new client subnet:
ip route add 192.168.21.0/24 via 192.168.20.1 dev enP15810p0s0
```
This works, but doesn't scale — every time a new client subnet shows up (which has
already happened multiple times as the network has grown/changed), someone has to
notice the failure, diagnose it again, and manually add another route.

### 4b. The permanent fix — dynamic on-link route correction

Instead of manually tracking every possible client subnet, the interface's
**on-link route itself** is corrected at every WSL2 boot to match the server's
*actual* local subnet (a proper `/24`), regardless of what the DHCP/static-assigned
mask says. Everything else then automatically and correctly falls through to the
**default route** (via the gateway) — which is exactly where cross-subnet traffic
is supposed to go, and requires zero maintenance when new client subnets appear.

This is fully dynamic — it re-detects the interface name, current IP, and existing
on-link route fresh on every boot, so it keeps working even if:
- the server's IP changes again
- the interface name changes (has already happened — see Section 11)
- the DHCP-assigned subnet mask changes

**Section added to `/usr/local/bin/wsl-startup.sh`:**
```bash
# ---------------------------------------------------------------------------
# ROUTING FIX — dynamic on-link subnet correction
# ---------------------------------------------------------------------------
# PROBLEM:
#   This server's network interface is sometimes configured with a subnet
#   mask larger than its true local subnet (e.g. /23 instead of /24), which
#   Linux auto-generates into an on-link route covering TWO /24 ranges as if
#   both were on the same local network segment (no gateway needed).
#
#   In reality, only the server's own /24 is truly on-link. Client machines
#   on the OTHER /24 inside that oversized range are actually reached
#   through the gateway, not directly.
#
#   Because of the incorrect broad on-link route, this WSL2 VM would try to
#   ARP for those "other half" clients directly instead of routing through
#   the gateway — the reply (SYN-ACK / HTTP response) would get generated
#   fine by nginx/Docker, but then get silently dropped instead of ever
#   being sent out. Result: TCP handshake succeeds, but no actual data ever
#   arrives at the client — connections just hang or reset. Confirmed via
#   tcpdump: the SYN-ACK reached the Docker bridge but never made it out
#   the physical interface.
#
#   This recurs for ANY client subnet outside the server's true /24 that
#   falls within the mis-sized block, and keeps breaking for new client
#   subnets over time unless fixed at the routing level rather than patched
#   per-subnet by hand.
#
# FIX:
#   On every WSL boot, detect the interface, its current IP, and delete
#   whatever broad on-link route the kernel auto-generated for it, then
#   replace it with a CORRECT /24 on-link route matching the server's
#   actual local subnet. Everything else automatically falls through to
#   the default route (via the gateway) — no need to manually add
#   per-subnet routes for every new client network that shows up.
#
#   Fully dynamic — no hardcoded IP/subnet/interface name. Safe to leave in
#   place even if the server's IP or interface changes in the future.
#
# See: README-TSPI-SERVER-05-NETWORKING.md, Section 4
# ---------------------------------------------------------------------------
IFACE=$(ip route | grep default | awk '{print $5}')
GW=$(ip route | grep default | awk '{print $3}')
MYIP=$(ip -4 addr show $IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
ip route del $(ip route | grep "dev $IFACE proto kernel scope link" | awk '{print $1}') dev $IFACE 2>/dev/null || true
ip route add ${MYIP%.*}.0/24 dev $IFACE proto kernel scope link src $MYIP 2>/dev/null || true
```

**One-time manual cleanup note:** if old explicit per-subnet routes (from the
previous stopgap approach, e.g. `192.168.21.0/24 via $GW`, or old hardcoded
`192.168.0.0/24`, `10.0.0.0/8`, `172.16.0.0/12` entries) are still sitting in the
live kernel routing table from before this fix was deployed, they won't
automatically disappear just because the script was edited — routes persist until
explicitly removed or the VM restarts. Clear them once manually, e.g.:
```bash
sudo ip route del 192.168.20.0/24 via 192.168.20.1 dev enP15810p0s0
```
Then confirm a clean state with `ip route` — you should see only the `default via
...` route plus the corrected `/24` on-link entry and the Docker bridge routes,
nothing else subnet-specific. After a full `wsl --shutdown` + restart, the startup
script re-applies the fix automatically every time, so this manual step should
never need to be repeated.

**Verification after applying:**
```bash
ip route
```
Expected result — no oversized on-link block, no long list of manually-added
per-subnet routes:
```
default via 192.168.20.1 dev enP15810p0s0 proto kernel
192.168.20.0/24 dev enP15810p0s0 proto kernel scope link src 192.168.20.30
172.17.0.0/16 dev docker0 ...
172.18.0.0/16 dev docker_gwbridge ...
172.19.0.0/16 dev br-... ...
```

---

## 5. Symptom: external access broke completely after enabling mirrored mode

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
external access to port 89, but Docker ports remained broken (see Section 2), which
is what ultimately led to abandoning `mirrored` mode entirely in favor of
`virtioproxy` + explicit `portproxy` rules.

**Lesson:** if XAMPP/Apache AND Docker apps both suddenly become unreachable
externally at the same time (while `localhost` still works), suspect a
`.wslconfig` networking mode change first — it's a host-wide firewall/networking
issue, not an application-level bug.

---

## 6. Full diagnostic path (for future reference / similar issues)

This is the order of checks that isolated both bugs, useful as a general
troubleshooting checklist for "app not reachable externally, works locally":

1. **`ipconfig /all`** (host) — confirm the IP/subnet/gateway actually assigned to
   each adapter is what you expect. DHCP failures show up as `169.254.x.x` APIPA
   addresses with no gateway (see [Section 6a](#6a-client-side-dhcpapipa-failures)
   below — this is a *third*, completely separate class of failure, seen on client
   laptops rather than the server).
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
   step across BOTH bugs found — in each case, it proved the response data *was*
   being generated correctly, narrowing the problem to a specific point in the
   forwarding path rather than the application itself.
7. **`arp -a`** (client) — rules out ARP/duplicate-IP issues; check the resolved
   MAC matches the server's real NIC MAC.
8. **`ping -f -l <size>`** (client, decreasing size) — tests for a Path MTU
   blackhole (large packets silently dropped, small ones fine). Ruled out in this
   case up to 1472 bytes both times this was tested.
9. **`route print`** (Windows host) / **`ip route`** (inside WSL2) — confirms
   correct routes/metrics exist for each subnet the server needs to serve. This
   is what ultimately revealed the Section 4 bug — comparing the WSL2-internal
   routing table against what it *should* have been.
10. **DNS-specific checks** (`nslookup`, `dig`, `cat /etc/resolv.conf`) — see
    [Section 6b](#6b-dns-specific-notes) below; a completely separate class of
    issue from the port-forwarding/routing problems, but easy to confuse with it
    since both manifest as "can't reach the server."

### 6a. Client-side DHCP/APIPA failures

Distinct from anything on the server: TSPI_V-One-connected **client laptops**
sometimes fail to get a valid DHCP lease at all, ending up with a self-assigned
`169.254.x.x` (APIPA) address and no default gateway. This has happened more than
once and looks identical to a server-side outage from the user's perspective
("nothing works"), but is actually local to that one client device (or, if
widespread, a TSPI_V-One access point/DHCP server problem — not something fixable
from the server or from this documentation).

**Symptom:**
```
Autoconfiguration IPv4 Address. . : 169.254.200.99
Default Gateway . . . . . . . . . : (blank)
```

**Attempted fixes, in order:**
1. `ipconfig /release` / `ipconfig /renew` — often fails outright ("no operation
   can be performed... media disconnected" or hangs indefinitely) precisely
   *because* there's no valid lease to renew in the first place.
2. `ipconfig /renew "Wi-Fi"` (adapter-specific) — may also just hang.
3. Fully disconnect/reconnect the SSID via the Windows UI (system tray Wi-Fi
   flyout) rather than `netsh wlan connect` (which requires admin rights + OS
   Location permission to even enumerate networks, and fails without them).
4. Toggle the Wi-Fi radio off/on entirely (not just disconnect/reconnect to the
   SSID) — forces a cleaner re-association.
5. If none of the above resolve it within a minute or two, and/or other devices
   on TSPI_V-One are simultaneously affected, this points to a genuine DHCP
   server/access-point outage on that network segment — escalate to whoever
   manages TSPI_V-One's infrastructure. Not fixable from any client or from the
   server.

### 6b. DNS-specific notes

Separately from the port-forwarding/routing sagas above, WSL2's DNS resolution
needed its own fix:

- **Symptom:** `nslookup tspi-server-05` failed inside WSL2 (`SERVFAIL` or wrong
  servers queried), while the same lookup worked fine from Windows PowerShell.
- **Root cause #1 — corrupted auto-generated resolver:** WSL2's
  auto-generated `/etc/resolv.conf` contained bogus nameservers (`1.0.0.2`,
  `1.0.0.3`) alongside the correct internal DNS server, inherited from a
  stale/odd Windows adapter DNS config. Fixed by setting `generateResolvConf =
  false` in `/etc/wsl.conf` and manually writing `/etc/resolv.conf`.
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
*(Nameserver IP is the internal DNS server's own address, unrelated to the
server's own IP changes documented in Section 11.)*

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
  imply general IP routing is working. See Section 7 note on TSPI_V-One's design.

---

## 7. Why TSPI_V-One clients must use `172.16.4.19`, never the Telford Computers IP

TSPI_V-One-connected devices (the 200 IC-processing machines and similar) get
DHCP addresses on the `172.16.4.0/23` subnet (e.g. `172.16.5.176`). The server's
Telford-side address lives on a **completely different subnet**. There is **no
routing configured between these two networks at the infrastructure level** — this
appears to be intentional network segmentation for the security-restricted
TSPI_V-One network (limiting the 200 machines to reach essentially only the
server, and nothing else on the broader company network).

Because of this:
- Access to the server's Telford Computers IP **will never work** from a
  TSPI_V-One-connected device, and this is not fixable from either endpoint — it
  would require a network admin to add cross-subnet routing at the
  router/infrastructure level, which may intentionally not exist for security
  reasons. (This is distinct from the Section 4 bug, which was about routing
  *within* the Telford Computers side's own set of subnets — TSPI_V-One is a
  separate, deliberately unrouted network entirely.)
- The correct, working address for TSPI_V-One clients is the server's
  **second NIC's IP**: `172.16.4.19` — since that IP lives on the *same* subnet as
  TSPI_V-One clients, no routing is required at all (same broadcast domain).

### Summary — which address to use, from where

| Client network        | Use this address           | Notes |
|------------------------|------------------------------|-------|
| Telford Computers        | `192.168.20.30` (current — see Section 11) or `tspi-server-05` (DNS-resolvable) | Full DNS available; hostname works normally |
| TSPI_V-One                | `172.16.4.19` **only**        | No DNS for internal zone on this network; no cross-subnet routing to the Telford side; hostname resolution here is unreliable mDNS fallback, don't depend on it |

**Recommendation:** hardcode `172.16.4.19` (not the hostname) in anything
deployed to/used by TSPI_V-One-restricted machines, until/unless:
- TSPI_V-One's DHCP is reconfigured to hand out the internal DNS server instead of
  public Cloudflare DNS, **and**
- a DNS record is added resolving to `172.16.4.19` specifically for clients on
  that segment (split-horizon DNS), since `tspi-server-05` currently always
  resolves to the Telford-side IP regardless of which network asks.

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
succeeds but response never arrives" symptom**, either:
- the `portproxy` workaround from Section 3 (using that server's one IP), or
- the Section 4 on-link routing fix, if that server's interface also has an
  oversized subnet mask and clients on a neighboring subnet are affected

...are both worth trying, but neither has been confirmed necessary on any
single-NIC server to date — treat both as fallbacks, not default steps.

---

## 9. Checklist: adding a new Dockerized app/port on TSPI-SERVER-05

Every time a new container is published on a new port (e.g. `docker run -p
7200:7200 ...` or equivalent in `docker-compose.yml`), the following steps are
**all required** for it to be reachable from both networks — missing any one of
them will cause exactly the "works locally, not externally" confusion documented
above. (The Section 4 routing fix, once in place, does NOT need to be redone per
port — it's a one-time, port-independent fix. Only steps 1–5 below are per-port.)

1. **Confirm the container publishes on `0.0.0.0`, not `127.0.0.1`** — e.g.
   `0.0.0.0:7200->7200/tcp` in `docker ps` output. If it only shows the bare
   container port with no `0.0.0.0:` prefix, it's internal-only (fine for
   PHP-FPM/backend services that nginx proxies to, but wrong for anything meant
   to be hit directly).
2. **Add the port to nginx's `default.conf`** (`listen` directives, `map
   $server_port $app_name` block, `server_name` list). **Double-check the
   `resolver` directive is `127.0.0.11` (Docker's embedded DNS), not
   `127.0.0.1`** — a typo here causes `send() failed (111: Connection refused)
   while resolving` errors and 502s for every app, not just the new one.
3. **Add a Windows Firewall inbound rule** (Administrator PowerShell):
   ```powershell
   New-NetFirewallRule -DisplayName "WSL App 7200" -Direction Inbound -Protocol TCP -LocalPort 7200 -Action Allow
   ```
4. **Add `portproxy` rules for both server IPs** (Administrator PowerShell —
   check current IPs first, see Section 11):
   ```powershell
   netsh interface portproxy add v4tov4 listenaddress=172.16.4.19 listenport=7200 connectaddress=127.0.0.1 connectport=7200
   netsh interface portproxy add v4tov4 listenaddress=192.168.20.30 listenport=7200 connectaddress=127.0.0.1 connectport=7200
   ```
5. **Test from both networks** with `curl -v`, not just `Test-NetConnection`
   (which only proves the handshake works, not that data actually flows — see
   Section 6, step 3).

---

## 10. Quick reference — key file locations

| File | Location | Purpose |
|------|----------|---------|
| `.wslconfig` | `C:\Users\<user>\.wslconfig` (Windows host) | WSL2 networking mode, resources |
| `wsl.conf` | `/etc/wsl.conf` (inside WSL2) | Boot behavior, DNS auto-generation toggle |
| `resolv.conf` | `/etc/resolv.conf` (inside WSL2) | DNS nameserver + search domain (manually maintained, not auto-generated) |
| `wsl-startup.sh` | `/usr/local/bin/wsl-startup.sh` (inside WSL2) | Runs on every WSL boot: permissions, the Section 4 routing fix, network share mounts, container restarts |
| nginx config | `/var/www/.../default.conf` or similar (inside WSL2) | Port routing to PHP-FPM containers |
| Firewall rules | Windows Defender Firewall (view via `Get-NetFirewallRule -DisplayName "*WSL*"`) | Per-port inbound allow rules |
| Port forwarding | `netsh interface portproxy show all` | Cross-IP forwarding rules (Section 3 workaround) |

---

## 11. IP change history

The server's IP on the "Telford Computers" side has changed at least once. Always
verify the *current* IP with `ipconfig /all` on the host rather than trusting any
IP hardcoded in older notes, chat logs, or this document's earlier sections where
noted:

| Date/period | Telford-side IP | TSPI_V-One-side IP | Notes |
|---|---|---|---|
| Earlier | `192.168.1.17` | `172.16.4.19` | Original setup; most of the diagnostic history in this doc happened under this IP |
| Current | `192.168.20.30` | `172.16.4.19` (unchanged) | IP changed; `portproxy` rules had to be re-added for the new IP (old ones left in place, harmless but stale — clean up with `netsh interface portproxy delete` when convenient); this IP change is also what first exposed the Section 4 routing bug, since the new IP came with a `/23` mask exposing neighboring client subnets that weren't on-link before |

**When the IP changes again:** update `portproxy` rules (Section 3) — this is the
only manual step that doesn't self-heal. The Section 4 routing fix and DNS config
(Section 6b) are both dynamic/IP-independent and require no changes.

---

## 12. Known-good end state (as of this writing)

- **`.wslconfig`:** `networkingMode=virtioproxy`, `firewall=true`
- **DNS:** manual `/etc/resolv.conf` with internal nameserver + `search tspi.com`,
  `generateResolvConf=false` in `/etc/wsl.conf`
- **Firewall:** explicit inbound allow rules for each Docker port (7100, 7110,
  7111, 7112, ...)
- **Port forwarding:** `portproxy` rules mapping both `172.16.4.19:<port>` and
  the current Telford-side IP `:<port>` → `127.0.0.1:<port>` for each published
  Docker port (Section 3)
- **WSL2-internal routing:** dynamic on-link `/24` correction in
  `wsl-startup.sh`, self-healing on every boot regardless of IP/interface
  changes (Section 4)
- **Access confirmed working:**
  - Telford Computers → server IP `:89` ✅, `:7100`–`:7112` ✅
  - TSPI_V-One → `172.16.4.19:89` ✅, `172.16.4.19:7100`–`:7112` ✅
  - Cross-subnet Telford clients (e.g. neighboring `/24`s reached via gateway) →
    ✅ after Section 4 fix
- **Known limitation (by design, not a bug):** the Telford-side IP is
  unreachable from TSPI_V-One, and `172.16.4.19` is unreachable from Telford
  Computers — these are on non-routed networks by design and each network must
  use its own matching IP (see Section 7).
