# Yggdrasil on OpenWrt - Routed LAN, SLAAC and Optional LuCI/DNS Modules

Native Yggdrasil routing for ordinary IPv6-capable LAN devices, implemented with the normal OpenWrt network stack.

The goal of this guide is to make OpenWrt the Yggdrasil gateway for a LAN: the router runs Yggdrasil, receives its node address and routed `/64`, advertises that routed prefix on `br-lan` with RA/SLAAC, and allows ordinary LAN devices to become reachable through Yggdrasil **without running Yggdrasil themselves**.

The design is intentionally modular:

```text
Part I   Core Yggdrasil LAN
         required for routed /64 + SLAAC + firewall

Part II  LAN inventory / LuCI Status
         optional operational UI

Part III DNS over Yggdrasil / friendly names
         optional naming and remote resolver access
```

> **Target platform:** OpenWrt 25.12+ with `apk`, `netifd`, `odhcpd`, `dnsmasq`, firewall4, rpcd and LuCI.
>
> **The final design was validated on a real OpenWrt 25.12.5 router.** The deployed router used a local logical interface name `ygg`; this guide deliberately standardizes new installations on `ygg0`.
>
> **Guide by Plasmoid (Neuroslopped)**

> Want the shortest tested path? See [QUICKSTART.md](QUICKSTART.md). This README
> remains the authoritative guide for architecture, rationale, safety,
> troubleshooting, maintenance and removal.

The core setup does **not** require:

- Yggdrasil on ordinary LAN clients;
- NAT66 for the routed Yggdrasil `/64`;
- stateful DHCPv6 address assignment;
- a second OpenWrt-generated ULA prefix;
- Docker, Podman or systemd;
- a custom DNS daemon;
- a background LAN inventory daemon;
- a database;
- unrestricted `ygg0 -> lan` forwarding.

The optional status module also does not require `getHostHints` as its source of truth.

---

## Contents

1. [What this setup provides](#1-what-this-setup-provides)
2. [Modular architecture](#2-modular-architecture)
3. [Requirements](#3-requirements)
4. [Where the design came from](#4-where-the-design-came-from)
5. [Development path and discarded alternatives](#5-development-path-and-discarded-alternatives)
6. [Part I - Install the core packages](#6-part-i---install-the-core-packages)
7. [Create the Yggdrasil interface](#7-create-the-yggdrasil-interface)
8. [Configure peers and multicast peering](#8-configure-peers-and-multicast-peering)
9. [Enable Yggdrasil Jumper](#9-enable-yggdrasil-jumper)
10. [Advertise the routed Yggdrasil `/64` to LAN](#10-advertise-the-routed-yggdrasil-64-to-lan)
11. [Configure the core firewall](#11-configure-the-core-firewall)
12. [Verify the core system](#12-verify-the-core-system)
13. [Part II - Optional LAN inventory and LuCI Status](#13-part-ii---optional-lan-inventory-and-luci-status)
14. [Part III - Optional DNS module](#14-part-iii---optional-dns-module)
15. [How Auto-IP actually works](#15-how-auto-ip-actually-works)
16. [Why the final design is shaped this way](#16-why-the-final-design-is-shaped-this-way)
17. [Troubleshooting notes from the real deployment](#17-troubleshooting-notes-from-the-real-deployment)
18. [Updating and maintenance](#18-updating-and-maintenance)
19. [Removing the setup](#19-removing-the-setup)
20. [Sources and acknowledgements](#20-sources-and-acknowledgements)
21. [Final state](#21-final-state)
22. [Maintainer / AI-agent handoff](#22-maintainer--ai-agent-handoff)

---

## 1. What this setup provides

OpenWrt becomes the only Yggdrasil router required inside the LAN.

The router itself gets a normal Yggdrasil node address from Yggdrasil's `200::/7` address space and a routed subnet associated with the same node identity.

Conceptually:

```text
Yggdrasil node
├── node address       2xx:....
└── routed subnet      3xx:....::/64
```

OpenWrt advertises the routed `/64` on the LAN.

Ordinary IPv6-capable devices then use standard SLAAC:

```text
Printer
KVM appliance
PC
TV
camera
embedded appliance
```

They do not need a local Yggdrasil daemon.

IPv4 remains ordinary OpenWrt DHCPv4:

```text
LAN IPv4
└── DHCPv4
    └── 192.168.x.x / 10.x.x.x / etc.
```

The IPv6 profile used by this guide is:

```text
Yggdrasil routed IPv6
└── RA + SLAAC
    └── routed /64

Stateful DHCPv6
└── disabled

OpenWrt-generated ULA
└── disabled in this profile

Link-local IPv6
└── fe80::/64 remains normal
```

Remote Yggdrasil nodes are not automatically trusted. Routing makes the subnet reachable; firewall policy decides who may use that reachability.

---

## 2. Modular architecture

### 2.1 Part I - Core Yggdrasil LAN

This is the actual networking system.

```text
                         PUBLIC YGGDRASIL
                                │
                         remote peers
                                │
                                ▼
                    ┌──────────────────────┐
                    │       OpenWrt        │
                    │                      │
                    │ ygg0                 │
                    │ proto: yggdrasil     │
                    │ node: 2xx:...        │
                    │ routed: 3xx:.../64   │
                    └──────────┬───────────┘
                               │
                        routed Ygg /64
                               │
                         odhcpd RA/SLAAC
                               │
                               ▼
                            br-lan
                      ┌────────┼────────┐
                      │        │        │
                      ▼        ▼        ▼
                   Printer   KVM box    PC
                   no Ygg    no Ygg    no Ygg
```

Core components:

```text
Yggdrasil
netifd / UCI
odhcpd
firewall4
```

The core system works perfectly well if Parts II and III are never installed.

### 2.2 Part II - Optional inventory and LuCI Status

This is an operational convenience layer. It is dynamic by default and does not require manual enrollment of every LAN client.

```text
active DHCPv4 leases
│   └── dynamic clients live exactly for the DHCP lease lifetime
│
├───────────────┐
│               │
▼               ▼
config host     IPv6 neighbour state
persistent      current observed SLAAC addresses
identity        matched by MAC
│               │
└───────┬───────┘
        │
        ▼
merge by MAC
        │
        ├── optional config domain
        │   └── canonical Ygg IPv6 + optional DNS name
        │
        ├── active ARP / IPv6 probe
        │
        ▼
 Status -> Yggdrasil
```

The lifetime rules are deliberately simple:

```text
DHCP-only client
└── visible while its DHCPv4 lease is active
    ├── probe succeeds -> Online
    └── probe fails    -> Offline

config host client
└── persistent row
    ├── probe succeeds -> Online
    └── probe fails    -> Offline
```

The backend does not automatically write discovered clients or observed SLAAC addresses into UCI, a database or a cache. A one-time guest therefore disappears automatically when DHCP forgets the lease.

`config host` is a persistence/metadata overlay, **not** an allow-list for appearing in the table. The LuCI page can create or remove that overlay directly with `Pin` / `Unpin`. Pinning does **not** reserve the IPv4 address unless the user explicitly enables that option.

If a persistent host already has a static DHCP IPv4 reservation, the row uses `Manage` and requires an explicit destructive confirmation before deleting that `config host`, because doing so also deletes the reservation. Shared multi-MAC, duplicate-MAC and complex host sections are never deleted automatically.

`config domain` is also optional for the status module. When it exists, its Ygg IPv6 is treated as canonical and displayed first. When it does not exist, current Ygg SLAAC addresses observed for that MAC can still be displayed dynamically. Pin/Unpin never deletes `config domain` records.

### 2.3 Part III - Optional DNS module

DNS is not required for routing or SLAAC.

Without it, direct access still works:

```text
ssh user@3xx:....
http://[3xx:....]/
```

The DNS module adds convenient names:

```text
mydevice.home.arpa
server.home.arpa
printer.home.arpa
```

and optionally makes the OpenWrt DNS service reachable over Yggdrasil.

Important implementation detail: the final status backend reuses standard OpenWrt `config domain` records as the persistent store for canonical Ygg IPv6 addresses. Therefore `config domain` is a **shared data primitive** between the status and DNS features. That does not make remote DNS access mandatory: port 53 and client-side split DNS remain optional.

---

## 3. Requirements

You need:

- OpenWrt with working IPv6 support;
- root access to the router;
- LuCI if you want to follow the UI-oriented steps;
- a working transport path to one or more Yggdrasil peers;
- ordinary IPv6 support on LAN devices that should receive routed Yggdrasil addresses.

This guide targets OpenWrt 25.12+ and therefore uses:

```text
apk
```

It assumes the usual logical LAN network and bridge:

```text
network: lan
device:  br-lan
```

If your installation uses different names, substitute them deliberately.

For a new deployment the guide standardizes the Yggdrasil logical interface as:

```text
ygg0
```

Do not rename a remote-only working Yggdrasil interface casually. If your only management path is currently Yggdrasil, an interface migration can disconnect you.

---

## 4. Where the design came from

The final system was not invented as a single monolithic service. The core routing came from Yggdrasil/OpenWrt mechanisms, while the later LAN inventory/status design was assembled after comparing several existing OpenWrt projects that each solved one part of the problem well.

The useful result was **not** to install all of those projects. The result was to identify the smallest mechanisms worth keeping and implement them with the OpenWrt stack already present on the router.

| Project / mechanism | What it already solved | Why it was not used wholesale | What survived in the final design |
| --- | --- | --- | --- |
| Yggdrasil + Yggdrasil-OpenWrt | Native Yggdrasil node, peers, routed subnet, OpenWrt integration | It is the foundation, but not a complete managed-LAN inventory/status system | `ygg0`, routed `/64`, netifd/LuCI, multicast peering, RA/SLAAC model |
| Yggdrasil-Jumper | Attempts more direct peerings / NAT traversal | Optimization only; base routing must not depend on it | Optional Jumper flags in the `ygg0` profile |
| AndreBL/ip6neigh | SLAAC discovery, predefined hosts, stable vs temporary address handling, local IPv6 DNS | Permanent service, monitor/DAD/cache/OUI/DDNS machinery is much larger than needed | Persistent host identity must be separate from transient neighbour state |
| OpenWrt-list-client-devices | Lightweight DHCP/static/`ip neigh` client correlation | Runtime list is not an authoritative canonical IPv6 inventory | Device identity centred on MAC |
| luci-app-wechatpush | Active ping/arping online detection | Large notification/traffic feature set and extra dependencies | One short active `arping` probe instead of trusting cache state |
| internet-detector | Checks can run only while WebUI is open | Its subject is Internet availability, not LAN inventory | On-demand RPC checks + UI polling model |
| ha-openwrt | Multi-source tracking and persistent presence history | Requires Home Assistant and solves a broader problem | Independent confirmation of identity/history vs runtime presence separation |
| luci-app-wrtbwmon | IPv6-aware display and MAC-based host identity | Traffic accounting is unrelated and may conflict with routing/offloading | Independent confirmation that MAC is a better identity key than IP |
| OpenWrt `dnsmasq` + `config domain` | Native persistent name -> IP records | No reason to add a second resolver | Canonical Ygg IPv6 + `home.arpa` without a custom DNS daemon |

### 4.1 Yggdrasil and Yggdrasil-OpenWrt - native routed `/64`

References:

```text
https://yggdrasil-network.github.io/configuration.html
https://yggdrasil-openwrt.github.io/openwrt-config-basic.html
```

These provide the foundation:

```text
Yggdrasil node
      │
      ├── node address
      └── routed subnet
               │
               ▼
        LAN interface /64
               │
               ▼
             RA/SLAAC
```

The OpenWrt integration supplies the native `netifd`/LuCI model instead of a hand-managed Linux TUN service.

Ideas retained in the final design:

- Yggdrasil as a logical OpenWrt interface;
- remote peers;
- multicast peering on a LAN interface;
- routing the node's Yggdrasil `/64` to ordinary LAN devices;
- letting standard IPv6 RA/SLAAC do client addressing;
- treating firewall authorization separately from routing.

The final guide goes further by selecting only the Yggdrasil prefix class for LAN, disabling stateful DHCPv6, removing the extra OpenWrt-generated ULA from this profile, and adding optional inventory/status/DNS layers.

### 4.2 Yggdrasil-Jumper - optional path optimization

Reference:

```text
https://github.com/one-d-wide/yggdrasil-jumper
```

Jumper is a companion optimization layer. It attempts to create more direct peerings between active Yggdrasil endpoints, including NAT-traversal cases, without replacing ordinary Yggdrasil routing.

The retained idea is simple:

```text
normal Yggdrasil path always exists
              │
              └── Jumper may establish a shorter path
```

The final OpenWrt profile lets the native Yggdrasil protocol integration manage Jumper rather than creating another hand-written service.

### 4.3 AndreBL/ip6neigh - persistent host identity must not equal transient NDP state

Project:

```text
https://github.com/AndreBL/ip6neigh
```

This project was the closest conceptual match to the problem that appeared during development: OpenWrt can observe SLAAC addresses dynamically, but runtime neighbour information is not a durable inventory.

`ip6neigh` already distinguishes predefined hosts from dynamically discovered IPv6 state, uses `/etc/config/dhcp` for predefined hosts, and distinguishes preferred/non-temporary addresses from temporary SLAAC addresses.

The key idea retained was:

```text
persistent device identity
        !=
current neighbour-cache observation
```

That directly led to the final lifetime split: a persistent `config host` must not disappear merely because NDP becomes `FAILED`, while a DHCP-only client must not be made permanent merely because it was observed once.

What was deliberately **not** copied:

- a continuously running `ip6neigh` service;
- `ip -6 monitor neigh`;
- DAD sniffing with `tcpdump`;
- OUI/manufacturer databases;
- generated `/tmp/hosts/ip6neigh` files;
- its own runtime cache;
- automatic collection of every privacy address;
- DDNS/firewall machinery.

The final implementation keeps the separation between durable identity and transient observation, but adds DHCP as the natural ephemeral lifetime source: active leases create dynamic rows, while `config host` creates persistent rows.

### 4.4 OpenWrt-list-client-devices - identify the device, not the current IP

Project:

```text
https://github.com/SimplyProgrammer/OpenWrt-list-client-devices
```

This lightweight script combines DHCP/static information with `ip neigh` and displays MAC, hostname, interface and neighbour state for devices regardless of connection type.

The important conceptual confirmation was that **MAC-centred device identity is more stable than IP-centred identity**.

We did not copy its vendor lookup or make its runtime neighbour list authoritative. In the final system, row lifetime comes from either an active DHCP lease or persistent UCI, while neighbour data only enriches those rows with current IPv6 state.

### 4.5 luci-app-wechatpush - active presence detection with ping/arping

Project:

```text
https://github.com/tty228/luci-app-wechatpush
```

The project explicitly uses active `ping`/`arping` detection because passive router state can be misleading for online/offline detection, especially with sleeping clients.

That solved another problem encountered during development: an IPv6 neighbour in `STALE` state can be completely healthy, while an offline device may remain in cache for some time.

The retained idea became:

```text
IPv4 answers ARP
       OR
any known Ygg IPv6 answers
       │
       ├── yes -> Online
       └── no  -> Offline
```

The full notification plugin was intentionally not installed. The final system needs only `iputils-arping` and a tiny probe function.

### 4.6 internet-detector + LuCI Poll - check only while the page is open

Projects/documentation:

```text
https://github.com/gSpotx2f/luci-app-internet-detector
https://openwrt.github.io/luci/jsapi/LuCI.poll.html
```

`internet-detector` demonstrates a particularly useful UI model: checks can run only while the web interface is open instead of requiring permanent monitoring.

LuCI itself provides `poll.add(fn, interval)` for periodic page-side polling.

That became the final status model:

```text
open Status -> Yggdrasil
        │
        ▼
RPC merges active DHCP leases + persistent hosts
        │
        ├── enriches them with current SLAAC addresses
        ▼
short active probes
        │
        ▼
Online / Offline
        │
        ▼
repeat every 15 seconds

close the page
        │
        ▼
no monitoring process remains
```

No cron job and no daemon are needed.

### 4.7 ha-openwrt and luci-app-wrtbwmon - independent confirmation

Related projects:

```text
https://github.com/FaserF/ha-openwrt
https://github.com/brvphoenix/luci-app-wrtbwmon
```

These were useful as independent confirmation rather than direct implementation sources.

`ha-openwrt` combines DHCP with ARP/NDP and persistent device history, separating device identity/history from current presence. `luci-app-wrtbwmon` identifies hosts by unique MAC rather than by changing IP and supports IPv6.

Neither project is required by this guide.

### 4.8 OpenWrt `dnsmasq` + RFC 8375 - no custom DNS subsystem

References:

```text
https://openwrt.org/
https://datatracker.ietf.org/doc/html/rfc8375
```

During development, a separate inventory/DNS generator was considered. It turned out to be unnecessary.

OpenWrt already understands standard UCI records of the form:

```text
config domain
        option name 'host.home.arpa'
        option ip   '<IPv6-address>'
```

and the existing `dnsmasq` service can publish them.

RFC 8375 reserves:

```text
home.arpa.
```

for locally served names in home networks.

The resulting simplification was important:

```text
no custom DNS daemon
no custom hosts generator
no DNS database
no DNS cron job
```

### 4.9 Final synthesis

The final LAN-status architecture can be summarized as:

```text
ip6neigh
└── persistent identity != transient SLAAC observation

OpenWrt-list-client-devices
└── device identity centred on MAC

luci-app-wechatpush
└── active arping/ping presence detection

internet-detector + LuCI poll
└── checks only while WebUI is open

OpenWrt DHCP lease state
└── natural TTL / garbage collection for dynamic clients

OpenWrt dnsmasq + RFC 8375
└── optional config domain + home.arpa

                 │
                 ▼
       dynamic inventory merge
       ├── active DHCP lease
       │   └── ephemeral client lifetime
       ├── config host
       │   └── persistent identity / metadata
       ├── IPv6 neighbour state
       │   └── current SLAAC addresses by MAC
       └── config domain
           └── optional canonical Ygg IPv6 / DNS alias
                 │
                 ▼
        one-shot rpcd backend
                 │
                 ▼
      Status -> Yggdrasil
```

The final system is therefore a synthesis of existing ideas implemented with native OpenWrt mechanisms, not a verbatim copy of any one project.

---

## 5. Development path and discarded alternatives

Several earlier versions were useful stepping stones but are **not** the final architecture. They are documented here so that they are not accidentally reintroduced later.

### 5.1 `getHostHints` as the authoritative LAN table - discarded

An early LuCI view built its client list from `luci-rpc getHostHints` and current NDP state.

This failed conceptually:

```text
device powers off / NDP ages out
          │
          ▼
address becomes FAILED or disappears
          │
          ▼
getHostHints stops reporting it
          │
          ▼
old dashboard loses the device/address
```

Real tests showed that a previously used stable IPv6 could become reachable again after the client returned and NDP was refreshed. Therefore neighbour-cache visibility is not proof that an address ceased to exist.

The final rule is more precise:

```text
getHostHints is not the inventory source

active DHCP lease -> dynamic row lifetime
config host       -> persistent row lifetime
ip -6 neigh       -> current IPv6 enrichment only
```

This keeps dynamic discovery without turning transient neighbour state into a permanent database.

### 5.2 Separate `/etc/config/yggdrasil-status` inventory - considered, then removed

A dedicated UCI file was considered:

```text
/etc/config/yggdrasil-status
```

It would have worked, but it would have created a second lifetime model and duplicated data already owned by DHCP/UCI.

The final design deliberately uses existing OpenWrt state:

```text
/tmp/dhcp.leases
└── dynamic clients, automatically garbage-collected by lease expiry

/etc/config/dhcp -> config host
└── persistent clients / optional fixed IPv4 metadata

/etc/config/dhcp -> config domain
└── optional canonical Ygg IPv6 / DNS name
```

No additional inventory database or cleanup mechanism is necessary.

### 5.3 Custom `option ygg_ipv6` inside `config host` - considered, then removed

Another intermediate design was:

```text
config host
        option name 'device'
        option mac '...'
        option ygg_ipv6 '3xx:...'
```

This kept everything in one section, but `ygg_ipv6` would have been a custom field understood only by our code.

The final implementation does not require a stored canonical address at all for a dynamic client: current SLAAC addresses are discovered from IPv6 neighbour state by MAC.

For devices where a persistent canonical address is useful, standard `config domain` can provide it and can also be consumed by `dnsmasq` if the optional DNS module is enabled.

### 5.4 Mandatory EUI-64 - rejected

At one point the desired model was described as:

```text
Ygg /64 + MAC-derived EUI-64 = permanent address
```

That is convenient for devices that naturally use EUI-64, but the router cannot universally force every SLAAC client to use a MAC-derived IID. Modern operating systems may use stable/privacy mechanisms instead.

Final requirement:

> SLAAC clients do not need to use EUI-64, and a canonical address is not mandatory for dynamic dashboard visibility.

A persistent canonical address may be configured for infrastructure where a stable reference is useful. Temporary/privacy addresses may continue to exist and can be shown as runtime observations without being stored permanently.

### 5.5 Stateful DHCPv6 for deterministic IPv6 - considered, then rejected

OpenWrt/odhcpd can support DHCPv6/static host identifiers, but returning to stateful DHCPv6 would make the design less universal and is unnecessary for the core Yggdrasil routed `/64` use case.

The final core therefore remains:

```text
RA + SLAAC
DHCPv6 disabled
```

### 5.6 `.lan` - replaced by `home.arpa`

Early naming examples used:

```text
nanokvm.lan
```

The final design uses the standards-reserved home-network namespace:

```text
mydevice.home.arpa
```

### 5.7 Passive NUD state as `Online` - rejected

`REACHABLE`, `STALE` and similar neighbour states are useful diagnostics but do not mean the same thing as "this managed device answers now".

Final state is actively probed on demand.

### 5.8 Permanent monitoring service - rejected

The status page does not need a daemon, persistent history or a database.

The final implementation performs probes only when LuCI asks for them.

---

## 6. Part I - Install the core packages

Update package metadata and install the native Yggdrasil/OpenWrt integration:

```sh
apk update
apk add yggdrasil luci-proto-yggdrasil
```

Install Jumper if you want the final tested profile including direct-path optimization:

```sh
apk add yggdrasil-jumper
```

Core package roles:

- `yggdrasil` — Yggdrasil router and OpenWrt protocol support;
- `luci-proto-yggdrasil` — LuCI/netifd integration;
- `yggdrasil-jumper` — optional optimization used by the tested final profile.

Check:

```sh
command -v yggdrasil
command -v yggdrasilctl
ubus list | grep '^luci.yggdrasil$'
```

Do **not** install `iputils-arping` unless you also want Part II. It is not required by the routed-LAN core.

---

## 7. Create the Yggdrasil interface

In LuCI:

```text
Network
└── Interfaces
    └── Add new interface
```

Create:

```text
Name:     ygg0
Protocol: Yggdrasil
```

Generate a new key pair or restore an existing private key.

The private key is the Yggdrasil node identity. Preserve it if you want to preserve the same node address and routed subnet.

A generalized final-profile UCI section looks like:

```text
config interface 'ygg0'
        option proto 'yggdrasil'
        option private_key '<PRIVATE_KEY>'
        option public_key '<PUBLIC_KEY>'
        option jumper_enable '1'
        option jumper_loglevel 'info'
        option allocate_listen_addresses '1'
        option jumper_autofill_listen_addresses '1'
        option multipath 'off'
```

If Jumper is intentionally omitted, the `jumper_*` and automatic listen-address options are not required for the core routed-LAN concept.

Check:

```sh
ifstatus ygg0
ubus call network.interface.ygg0 status
```

A working node should report a Yggdrasil node address and a routed prefix.

---

## 8. Configure peers and multicast peering

### 8.1 Remote peers

Use a small set of current public peers from:

```text
https://github.com/yggdrasil-network/public-peers
```

Example UCI type for a `ygg0` peer:

```text
config yggdrasil_ygg0_peer
        option address 'tls://example-peer-1.invalid:12345'

config yggdrasil_ygg0_peer
        option address 'tls://example-peer-2.invalid:23456'
```

The URIs above are placeholders. Do not copy stale peer addresses from documentation blindly.

### 8.2 Local multicast peering

Enable local discovery for **full Yggdrasil nodes** on the LAN bridge:

```text
config yggdrasil_ygg0_interface
        list interface 'br-lan'
        option beacon '1'
        option listen '1'
```

This is separate from routed-prefix clients:

```text
ordinary SLAAC client
└── does not run Yggdrasil
└── only receives an address from routed /64

full LAN Yggdrasil node
└── may discover ygg0 by multicast peering
```

---

## 9. Enable Yggdrasil Jumper

The final tested profile used Jumper.

Configure:

```text
option jumper_enable '1'
option jumper_loglevel 'info'
option allocate_listen_addresses '1'
option jumper_autofill_listen_addresses '1'
```

Conceptually:

```text
normal Yggdrasil path exists
          │
          ▼
Jumper may establish a more direct peering
          │
          ├── success -> shorter path
          └── failure -> normal path remains
```

Jumper is an optimization, not a requirement for base reachability.

Check:

```sh
logread | grep -Ei 'ygg0|jumper'
```

---

## 10. Advertise the routed Yggdrasil `/64` to LAN

This is the core Auto-IP step.

### 10.1 Select only the Yggdrasil prefix class

```sh
uci set network.lan.ip6assign='64'
uci -q delete network.lan.ip6class
uci add_list network.lan.ip6class='ygg'
```

The key setting is:

```text
list ip6class 'ygg'
```

It ensures that LAN receives the Yggdrasil prefix class instead of indiscriminately consuming every available IPv6 prefix source.

### 10.2 Remove the extra OpenWrt ULA for this profile

```sh
uci -q delete network.globals.ula_prefix
```

This removes the additional OpenWrt-generated `fdxx:...` prefix from this profile. It does not disable IPv6 or link-local addresses.

### 10.3 Configure SLAAC-only Router Advertisements

```sh
uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_slaac='1'
uci -q delete dhcp.lan.ra_flags
uci add_list dhcp.lan.ra_flags='none'
uci set dhcp.lan.ra_default='2'
uci set dhcp.lan.ra_preference='medium'
```

Commit and apply:

```sh
uci commit network
uci commit dhcp
/etc/init.d/network reload
/etc/init.d/odhcpd restart
```

The resulting LAN model is:

```text
ygg0 routed /64
       │
       ▼
    br-lan
       │
    odhcpd RA
       │
       ▼
     SLAAC
```

Check:

```sh
ubus call dhcp ipv6ra
ip -6 neigh show dev br-lan
```

A normal LAN client should have:

```text
3xx:....  Yggdrasil-routed address
fe80::    link-local address
```

It does not need Yggdrasil installed locally.

---

## 11. Configure the core firewall

Yggdrasil is a routable overlay and should be treated as untrusted by default.

### 11.1 Dedicated `ygg` zone

Create a dedicated zone for the logical interface:

```text
config zone
        option name 'ygg'
        option input 'REJECT'
        option output 'ACCEPT'
        option forward 'DROP'
        list network 'ygg0'
```

Do not enable masquerading. The routed `/64` is real IPv6 routing, not NAT66.

### 11.2 Do not add blanket forwarding

Do not create a generic:

```text
config forwarding
        option src 'ygg'
        option dest 'lan'
```

and do not create a blanket `lan -> ygg` forwarding merely because the routed prefix exists.

The final tested security model used explicit trusted source addresses.

### 11.3 Trusted Yggdrasil clients -> LAN

Generalized form of the tested rule:

```text
config rule
        option name 'YGG-Trusted-to-LAN'
        option src 'ygg'
        option dest 'lan'
        option family 'ipv6'
        list proto 'all'
        list src_ip '<TRUSTED_YGG_IPV6_1>'
        list src_ip '<TRUSTED_YGG_IPV6_2>'
        option target 'ACCEPT'
        option enabled '1'
```

Use the remote clients' stable Yggdrasil node addresses.

### 11.4 Trusted Yggdrasil clients -> router

Router INPUT is a separate policy path from forwarding to LAN.

Generalized form of the tested rule:

```text
config rule
        option name 'YGG-Trusted-to-Router'
        option src 'ygg'
        option family 'ipv6'
        list proto 'tcp'
        list src_ip '<TRUSTED_YGG_IPV6_1>'
        list src_ip '<TRUSTED_YGG_IPV6_2>'
        option target 'ACCEPT'
        option enabled '1'
```

The tested profile allowed TCP services on the router for the trusted Ygg addresses. A stricter deployment may additionally constrain destination ports.

### 11.5 Commit and apply

```sh
uci commit firewall
/etc/init.d/firewall restart
```

Inspect the generated firewall:

```sh
fw4 print
```

or:

```sh
nft list ruleset
```

DNS port 53 is **not** part of the required core rules. It is handled separately in Part III.

---

## 12. Verify the core system

Do not consider the installation complete because the interface merely says `up`.

Verify each layer.

### 12.1 Yggdrasil interface

```sh
ifstatus ygg0
ubus call network.interface.ygg0 status
```

Confirm:

- interface is up;
- node address exists;
- routed prefix exists.

### 12.2 Peers

```sh
yggdrasilctl getPeers
```

At least one usable peer should be up.

### 12.3 LAN prefix advertisement

```sh
ubus call dhcp ipv6ra
```

Confirm the advertised `/64` belongs to the Yggdrasil prefix class.

### 12.4 DHCPv6 is disabled

```sh
uci get dhcp.lan.dhcpv6
```

Expected:

```text
disabled
```

### 12.5 SLAAC is enabled

```sh
uci get dhcp.lan.ra
uci get dhcp.lan.ra_slaac
```

Expected:

```text
server
1
```

### 12.6 LAN prefix class

```sh
uci get network.lan.ip6assign
uci get network.lan.ip6class
```

Expected properties:

```text
64
ygg
```

### 12.7 No generated ULA in this profile

```sh
uci -q get network.globals.ula_prefix || echo 'ULA disabled'
```

### 12.8 Real LAN device

From the router:

```sh
ip -6 neigh show dev br-lan
```

From a trusted remote Yggdrasil client, test a known routed LAN IPv6 directly:

```sh
ping -6 <LAN_YGG_IPV6>
```

For HTTP:

```text
http://[<LAN_YGG_IPV6>]/
```

If the direct routed IPv6 works, the core system is complete. Everything below is optional.

---

## 13. Part II - Optional LAN inventory and LuCI Status

The core does not need this module.

The status module is a dynamic operational view of the LAN. It deliberately separates **device lifetime**, **reachability state** and **persistent management**.

### 13.1 Final lifetime model

There are two classes of rows.

#### Dynamic DHCP clients

An active DHCPv4 lease is enough for a device to appear in the table. No `config host` is required.

```text
/tmp/dhcp.leases
        │
        ├── lease active -> row exists
        │                  ├── probe succeeds -> Online
        │                  └── probe fails    -> Offline
        │
        └── lease expired -> row disappears
```

The backend checks the lease expiry timestamp itself, so an already-expired line is not treated as an active client even if it temporarily remains in the lease file.

This is the garbage-collection policy for guests and other temporary devices. The status module does not create its own history database or retention timer.

#### Persistent clients

A normal OpenWrt `config host` makes a device persistent in the table:

```text
config host
        option name '<HOSTNAME>'
        option mac '<MAC>'
```

Its row remains even with no current DHCP lease:

```text
config host exists
        │
        ├── probe succeeds -> Online
        └── probe fails    -> Offline
```

`config host` is therefore a persistence/metadata mechanism, **not a requirement for dynamic discovery**.

### 13.2 Merge identity by MAC

The backend combines active DHCP leases and persistent `config host` entries by MAC address.

```text
active DHCP lease ──────┐
                        ├── merge by MAC -> one row
config host ────────────┘
```

When both exist:

- `config host` name wins over the DHCP hostname;
- a configured fixed IPv4 wins over the current lease address;
- the device is marked persistent;
- a fixed IPv4 reservation is reported separately to the UI;
- the row is emitted only once.

When only the lease exists, the DHCP hostname and IPv4 are used. A hostname of `*` is shown as empty/unknown rather than being invented.

### 13.3 Runtime Yggdrasil IPv6 discovery

The routed Ygg `/64` is discovered from the global `/64` currently assigned to the LAN bridge. In the profile used by this guide, `ip6class 'ygg'` means that this global LAN `/64` is the Yggdrasil routed prefix.

The backend then reads:

```text
ip -6 neigh show dev br-lan
```

and associates observed Ygg SLAAC addresses with devices by MAC.

These addresses are **runtime enrichment only**:

```text
config domain exists      -> show the canonical address only
no canonical, EUI-64 seen -> show the stable modified EUI-64 only
privacy-only client       -> show all observed addresses
no association            -> do not invent an address
```

Nothing observed here is written back into UCI, a file or a database.

This stable-first policy prevents historical privacy IIDs in the NDP cache from
flooding the UI. It also prevents polling from repeatedly probing every old IID
and keeping those neighbour entries active. Clients that do not expose a
modified EUI-64, including privacy-only phones, may still display multiple
addresses. The router does not assign or remove any client address here.

### 13.4 Optional canonical Ygg IPv6

A stored canonical address is not required for a client to appear in the dashboard.

If a persistent canonical Ygg address is useful, add a normal `config domain` record:

```text
config domain 'ygg_mydevice'
        option name 'mydevice.home.arpa'
        option ip '<CANONICAL_YGG_IPV6>'
```

For a host named `MyDevice`, the backend looks for:

```text
mydevice.home.arpa
```

using the BusyBox-safe lowercase operation:

```sh
tr 'A-Z' 'a-z'
```

When a canonical address exists:

- it is displayed first;
- it remains visible even when neighbour state disappears;
- it is the only IPv6 address displayed and probed for that persistent row;
- the corresponding `home.arpa` name is shown in the DNS column.

Without a matching `config domain`, the dashboard prefers an observed modified
EUI-64 address. If none exists, it shows the observed privacy addresses and
`DNS: —`.

### 13.5 Online / Offline semantics

Lifetime and state are intentionally independent.

For every row the backend tries:

```text
IPv4 -> one ARP probe on br-lan
          │
          ├── success -> Online
          └── failure
                 │
                 ▼
       selected Ygg IPv6 address(es)
                 │
                 ├── any replies -> Online
                 └── none reply  -> Offline
```

For a DHCP-only client, `Offline` does **not** immediately delete the row. The row remains until its DHCP lease expires.

For a persistent `config host`, `Offline` never removes the row.

### 13.6 Pin / Unpin persistent devices from the dashboard

The final UI can promote a dynamic client to a persistent client without leaving `Status -> Yggdrasil`.

A dynamic row shows:

```text
Dynamic  [ Pin ]
```

`Pin` opens a dialog with the current DHCP hostname (or an empty field for an unnamed client) and an optional checkbox:

```text
Hostname: <name>

[ ] Reserve current IPv4 <address>
```

The IPv4 reservation checkbox is **off by default**. With it disabled, Pin creates only a normal OpenWrt `config host` containing hostname + MAC:

```uci
config host 'ygg_status_<MAC_WITHOUT_COLONS>'
        option name '<HOSTNAME>'
        option mac '<MAC>'
```

That changes only the row lifetime:

```text
active DHCP lease expires
        │
        ▼
row remains because config host exists
        │
        └── Online / Offline continues to come from active probes
```

If `Reserve current IPv4` is enabled, the same section also receives:

```uci
option ip '<CURRENT_IPV4>'
```

The backend re-reads the **current active DHCP lease** when the Pin RPC runs and validates the address server-side. It does not trust an IPv4 value cached in the browser.

The persistence column uses four normal states:

```text
Dynamic     [ Pin ]
Pinned      [ Unpin ]
Persistent  [ Unpin ]
Static      [ Manage ]
```

`Pinned` means the host section was created by this dashboard. `Persistent` means an ordinary pre-existing OpenWrt `config host` was found. Both are native UCI records; the labels only make their origin clear.

For a simple single-MAC host without a fixed IPv4, `Unpin` removes the matching `config host`. If an active DHCP lease still exists, the device immediately falls back to `Dynamic` and remains visible until that lease expires.

A static DHCP reservation is intentionally handled as a destructive case. `Static [Manage]` opens a dialog that states that removing persistence also removes the reserved IPv4. Only the explicit action:

```text
Unpin and remove reservation
```

sends the confirmed delete request.

The backend also refuses to auto-delete host sections when it cannot prove that deletion is isolated and safe. Such rows show `Manage` and are directed to the standard `Network -> DHCP and DNS` page. Automatic Unpin is blocked when:

- one `config host` contains multiple MAC addresses;
- the same MAC appears in more than one `config host` section;
- the host section contains additional DHCP options beyond `name`, `mac` and optional `ip`.

This prevents a status-page button from silently deleting tags, DUID/hostid policy or unrelated device configuration.

Additional safeguards:

- Pin validates MAC and hostname on the router;
- Pin requires a currently active DHCP lease;
- the optional IPv4 reservation is taken from that current lease, not from the browser;
- Pin/Unpin refuses to run while the `dhcp` UCI package has uncommitted changes;
- `/etc/config/dhcp` is backed up before every mutation;
- UCI is committed and only `dnsmasq` is reloaded after a successful change;
- if commit or reload fails, the previous DHCP configuration is restored;
- `config domain` records are never deleted by Pin/Unpin.

A `config domain` record is attached by the dashboard only to a **persistent** host identity. A DHCP-only client that happens to claim the same hostname cannot inherit another device's canonical Ygg IPv6 / DNS metadata.

Pin/Unpin therefore changes persistent DHCP metadata only. It does not reload the network, firewall, Yggdrasil or odhcpd.

### 13.7 Install the only additional probe dependency

```sh
apk add iputils-arping
```

Check:

```sh
command -v arping
```

### 13.8 Install the dynamic rpcd backend

Create:

```text
/usr/libexec/rpcd/luci.yggdrasil-status
```

with the following contents:

```sh
#!/bin/sh

#
# Dynamic Yggdrasil LAN inventory for OpenWrt.
#
# Lifetime model:
#   - config host         -> persistent row
#   - active DHCPv4 lease -> dynamic row for exactly the lease lifetime
#   - neighbour entries   -> stable-first runtime IPv6 enrichment; never persisted
#   - config domain       -> optional canonical Ygg IPv6 + DNS alias
#
# Management model:
#   - Pin   -> create a normal config host (name + MAC)
#   - Pin + reserve IPv4 -> additionally store the current IPv4 reservation
#   - Unpin -> remove the matching single-MAC config host
#   - static IPv4 removal requires explicit confirmation
#   - config domain records are never deleted by Pin/Unpin
#
# Online state:
#   IPv4 ARP OR any known Ygg IPv6 response
#
# No daemon.
# No cron.
# No DB.
# No persistent runtime cache.
# No getHostHints as inventory source.
#

. /lib/functions.sh
. /usr/share/libubox/jshn.sh

LAN_NET='lan'
DNS_SUFFIX='home.arpa'
LEASE_FILE='/tmp/dhcp.leases'
DHCP_CONFIG='/etc/config/dhcp'
PIN_SECTION_PREFIX='ygg_status_'
DHCP_LOCK_FILE='/var/lock/yggdrasil-status-dhcp.lock'


lower() {
	printf '%s' "$1" | tr 'A-Z' 'a-z'
}


normalize_mac() {
	lower "${1%% *}"
}


valid_mac() {
	printf '%s\n' "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}


valid_hostname() {
	local vh_name="$1"

	[ -n "$vh_name" ] || return 1
	[ "${#vh_name}" -le 63 ] || return 1

	case "$vh_name" in
		-*|*-|*[!A-Za-z0-9-]*) return 1 ;;
	esac

	return 0
}


first_ipv4() {
	local fi_value="$1"
	local fi_token

	fi_value="$(printf '%s' "$fi_value" | tr ',' ' ')"

	for fi_token in $fi_value; do
		if valid_ipv4 "$fi_token"; then
			printf '%s\n' "$fi_token"
			return 0
		fi
	done

	return 1
}


valid_ipv4() {
	printf '%s\n' "$1" | awk -F. '
		NF != 4 { exit 1 }
		{
			for (i = 1; i <= 4; i++) {
				if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255)
					exit 1
			}
		}
	'
}


mac_was_emitted() {
	local mwe_mac
	mwe_mac="$(normalize_mac "$1")"

	case "$EMITTED_MACS" in
		*"|${mwe_mac}|"*) return 0 ;;
	esac

	return 1
}


remember_emitted_mac() {
	local rem_mac
	rem_mac="$(normalize_mac "$1")"
	EMITTED_MACS="${EMITTED_MACS}|${rem_mac}|"
}


lease_is_active() {
	local lia_expiry="$1"

	case "$lia_expiry" in
		''|*[!0-9]*) return 1 ;;
		0) return 0 ;;
	esac

	[ "$lia_expiry" -gt "$NOW" ]
}


acquire_dhcp_lock() {
	local adl_mode="$1"

	exec 9>>"$DHCP_LOCK_FILE" || return 1
	case "$adl_mode" in
		shared) flock -s 9 ;;
		*) flock -n 9 ;;
	esac
}


# Return success when a config host contains options beyond the small set that
# this page can safely reason about. Such sections are still shown as
# persistent, but automatic Unpin is disabled so tags, DUID/hostid settings or
# other DHCP policy cannot be removed accidentally.
host_section_has_extra_options() {
	local hse_selector="$1"
	local hse_line

	while IFS= read -r hse_line; do
		[ -n "$hse_line" ] || continue

		case "$hse_line" in
			"dhcp.${hse_selector}=host"|\
			"dhcp.${hse_selector}.name="*|\
			"dhcp.${hse_selector}.mac="*|\
			"dhcp.${hse_selector}.ip="*)
				;;
			*)
				return 0
				;;
		esac
	done <<EOF
$(uci -q show "dhcp.${hse_selector}" 2>/dev/null)
EOF

	return 1
}


# Locate persistent config-host metadata by MAC.
#
# Safety invariants for Unpin:
#   - a section containing multiple MACs is never deleted here;
#   - a MAC present in multiple host sections is never deleted here;
#   - a section with extra/unknown options is never deleted here.
#
# This prevents a status-page action from silently destroying unrelated DHCP
# policy.
match_host_section_by_mac() {
	local mh_section="$1"
	local mh_wanted="$2"
	local mh_macs mh_candidate mh_count=0 mh_matched=0

	config_get mh_macs "$mh_section" mac
	[ -n "$mh_macs" ] || return 0

	mh_macs="$(printf '%s' "$mh_macs" | tr ',' ' ')"

	for mh_candidate in $mh_macs; do
		mh_count=$((mh_count + 1))
		if [ "$(normalize_mac "$mh_candidate")" = "$(normalize_mac "$mh_wanted")" ]; then
			mh_matched=1
		fi
	done

	[ "$mh_matched" -eq 1 ] || return 0

	FOUND_HOST_MATCH_COUNT=$((FOUND_HOST_MATCH_COUNT + 1))

	# Keep metadata from the first matching section, but continue scanning to
	# detect duplicate host sections that refer to the same MAC.
	[ -z "$FOUND_HOST_SECTION" ] || return 0

	FOUND_HOST_SECTION="$mh_section"
	FOUND_HOST_SELECTOR="$mh_section"
	FOUND_HOST_MAC_COUNT="$mh_count"
	FOUND_HOST_ALL_MACS="$mh_macs"
	config_get FOUND_HOST_NAME "$mh_section" name
	config_get FOUND_HOST_IP "$mh_section" ip
}


find_host_by_mac() {
	FOUND_HOST_SECTION=''
	FOUND_HOST_SELECTOR=''
	FOUND_HOST_NAME=''
	FOUND_HOST_IP=''
	FOUND_HOST_ALL_MACS=''
	FOUND_HOST_MAC_COUNT=0
	FOUND_HOST_MATCH_COUNT=0
	FOUND_HOST_MANAGED=0
	FOUND_HOST_STATIC_IPV4=''
	FOUND_HOST_COMPLEX=0
	FOUND_HOST_AMBIGUOUS=0

	config_foreach match_host_section_by_mac host "$1"

	[ -n "$FOUND_HOST_SECTION" ] || return 1

	case "$FOUND_HOST_SECTION" in
		${PIN_SECTION_PREFIX}*) FOUND_HOST_MANAGED=1 ;;
	esac

	FOUND_HOST_STATIC_IPV4="$(first_ipv4 "$FOUND_HOST_IP" 2>/dev/null || true)"
	[ "$FOUND_HOST_MATCH_COUNT" -gt 1 ] && FOUND_HOST_AMBIGUOUS=1
	if host_section_has_extra_options "$FOUND_HOST_SELECTOR"; then
		FOUND_HOST_COMPLEX=1
	fi

	return 0
}


# Find the active DHCP lease for a MAC. Used by Pin so that the optional static
# reservation always comes from the currently remembered lease, never from a
# stale UI value supplied by the browser.
find_active_lease_by_mac() {
	local fal_wanted fal_expiry fal_mac fal_ip fal_name fal_clientid fal_rest

	LEASE_MATCH_EXPIRY=''
	LEASE_MATCH_IPV4=''
	LEASE_MATCH_NAME=''
	fal_wanted="$(normalize_mac "$1")"

	[ -r "$LEASE_FILE" ] || return 1

	while IFS=' ' read -r fal_expiry fal_mac fal_ip fal_name fal_clientid fal_rest; do
		[ -n "$fal_mac" ] || continue
		lease_is_active "$fal_expiry" || continue
		[ "$(normalize_mac "$fal_mac")" = "$fal_wanted" ] || continue

		LEASE_MATCH_EXPIRY="$fal_expiry"
		LEASE_MATCH_IPV4="$fal_ip"
		LEASE_MATCH_NAME="$fal_name"
		[ "$LEASE_MATCH_NAME" = '*' ] && LEASE_MATCH_NAME=''
		return 0
	done < "$LEASE_FILE"

	return 1
}


# Canonical record lookup. A matching config domain is optional.
find_canonical_domain() {
	local fcd_host="$1"
	local fcd_wanted fcd_i fcd_name fcd_ip

	CANONICAL_IPV6=''
	DNS_ALIAS=''

	[ -n "$fcd_host" ] || return 1

	fcd_wanted="$(lower "$fcd_host").${DNS_SUFFIX}"
	fcd_i=0

	while uci -q get "dhcp.@domain[$fcd_i]" >/dev/null 2>&1; do
		fcd_name="$(uci -q get "dhcp.@domain[$fcd_i].name" 2>/dev/null)"
		fcd_ip="$(uci -q get "dhcp.@domain[$fcd_i].ip" 2>/dev/null)"

		if [ -n "$fcd_name" ] && [ "$(lower "$fcd_name")" = "$fcd_wanted" ]; then
			case "$fcd_ip" in
				*:*)
					CANONICAL_IPV6="$fcd_ip"
					DNS_ALIAS="$fcd_name"
					return 0
					;;
			esac
		fi

		fcd_i=$((fcd_i + 1))
	done

	return 1
}


# Locate the logical netifd interface backed by the Yggdrasil proto handler.
select_ygg_network() {
	local syn_section="$1"
	local syn_proto

	[ -z "$YGG_NET" ] || return 0
	config_get syn_proto "$syn_section" proto
	[ "$syn_proto" = 'yggdrasil' ] || return 0
	YGG_NET="$syn_section"
}


# Determine the routed /64 delegated by the Yggdrasil netifd interface. This
# deliberately does not select the first global /64 from br-lan: WAN prefix
# delegation or another overlay may legitimately add more prefixes later.
find_lan_ygg_prefix() {
	local flyp_addr

	[ -n "$YGG_NET" ] || return 0

	flyp_addr="$(
		ubus call "network.interface.${YGG_NET}" status 2>/dev/null |
			jsonfilter -e '@["ipv6-prefix"][@.class="ygg"].address' 2>/dev/null |
			head -n 1
	)"

	printf '%s\n' "$flyp_addr" |
		awk '
			NF {
				split($1, h, ":")
				if (h[1] != "" && h[2] != "" && h[3] != "" && h[4] != "") {
					print tolower(h[1] ":" h[2] ":" h[3] ":" h[4] ":")
					exit
				}
			}
		'
}


# A REACHABLE neighbor entry is a recent kernel-confirmed success, so avoid
# spawning another probe for it. STALE/DELAY/PROBE/FAILED are not treated as
# Online or Offline; those states still fall through to an active probe.
neighbor_recently_reachable() {
	local nrr_addr="$1"

	case "$nrr_addr" in
		*:*) ip -6 neigh show to "$nrr_addr" dev "$LAN_DEV" 2>/dev/null ;;
		*)   ip neigh show to "$nrr_addr" dev "$LAN_DEV" 2>/dev/null ;;
	esac | grep -qw 'REACHABLE'
}


# Runtime SLAAC addresses associated with a MAC in the kernel neighbor table.
# These are enrichment only and are never written to UCI or a cache.
observed_ipv6_for_mac() {
	local o6_wanted="$1"

	[ -n "$LAN_YGG_PREFIX" ] || return 0

	ip -6 neigh show dev "$LAN_DEV" 2>/dev/null |
		awk -v wanted="$(normalize_mac "$o6_wanted")" -v prefix="$LAN_YGG_PREFIX" '
		{
			addr = tolower($1)
			mac = ""

			for (i = 1; i <= NF; i++) {
				if ($i == "lladdr" && (i + 1) <= NF) {
					mac = tolower($(i + 1))
					break
				}
			}

			if (mac != wanted)
				next

			if (index(addr, prefix) != 1)
				next

			if (!seen[addr]++)
				print $1
		}
	'
}


eui64_ipv6_for_mac() {
	local e64_mac e64_old_ifs e64_first

	e64_mac="$(normalize_mac "$1")"
	valid_mac "$e64_mac" || return 1

	e64_old_ifs="$IFS"
	IFS=':'
	set -- $e64_mac
	IFS="$e64_old_ifs"
	[ "$#" -eq 6 ] || return 1

	e64_first="$((0x$1 ^ 2))"
	printf '%s%02x%s:%sff:fe%s:%s%s\n' \
		"$LAN_YGG_PREFIX" "$e64_first" "$2" "$3" "$4" "$5" "$6"
}


append_unique_ipv6() {
	local aui_addr="$1"
	local aui_current

	[ -n "$aui_addr" ] || return 0

	for aui_current in $KNOWN_IPV6; do
		[ "$(lower "$aui_current")" = "$(lower "$aui_addr")" ] && return 0
	done

	KNOWN_IPV6="${KNOWN_IPV6}${KNOWN_IPV6:+ }${aui_addr}"
}


build_known_ipv6() {
	local bki_mac="$1"
	local bki_addr bki_eui64 bki_observed

	KNOWN_IPV6=''
	if [ -n "$CANONICAL_IPV6" ]; then
		append_unique_ipv6 "$CANONICAL_IPV6"
		return 0
	fi

	bki_eui64="$(eui64_ipv6_for_mac "$bki_mac" 2>/dev/null || true)"
	bki_observed="$(observed_ipv6_for_mac "$bki_mac")"

	# A modified EUI-64 address is stable and unambiguous when the client uses
	# one. Prefer it over privacy IIDs so historical NDP entries do not flood
	# the UI or get kept alive by repeated presence probes. Clients that do not
	# expose EUI-64 (notably privacy-only devices) retain all observed addresses.
	for bki_addr in $bki_observed; do
		if [ -n "$bki_eui64" ] && [ "$(lower "$bki_addr")" = "$bki_eui64" ]; then
			append_unique_ipv6 "$bki_addr"
			return 0
		fi
	done

	for bki_addr in $bki_observed; do
		append_unique_ipv6 "$bki_addr"
	done
}


probe_online() {
	local po_ipv4="$1"
	local po_addr

	if [ -n "$po_ipv4" ] && neighbor_recently_reachable "$po_ipv4"; then
		return 0
	fi

	for po_addr in $KNOWN_IPV6; do
		if neighbor_recently_reachable "$po_addr"; then
			return 0
		fi
	done

	if [ -n "$po_ipv4" ] && command -v arping >/dev/null 2>&1; then
		if arping -I "$LAN_DEV" -c 1 -f -w 1 "$po_ipv4" >/dev/null 2>&1; then
			return 0
		fi
	fi

	for po_addr in $KNOWN_IPV6; do
		if ping -6 -c 1 -W 1 "$po_addr" >/dev/null 2>&1; then
			return 0
		fi
	done

	return 1
}


emit_client() {
	local ec_name="$1"
	local ec_mac="$2"
	local ec_ipv4="$3"
	local ec_persistent="$4"
	local ec_lease_expiry="$5"
	local ec_static_ipv4="$6"
	local ec_managed_pin="$7"
	local ec_shared_host="$8"
	local ec_complex_host="$9"
	local ec_ambiguous_host="${10}"
	local ec_online=0
	local ec_primary_ipv6=''
	local ec_addr ec_protected_host=0

	[ -n "$ec_mac" ] || return 0

	# A config domain is persistent metadata keyed by hostname. Only attach it
	# to a persistent config-host identity; a DHCP-only client can claim an
	# arbitrary hostname and must not inherit another device's canonical record.
	if [ "$ec_persistent" -eq 1 ]; then
		find_canonical_domain "$ec_name" || true
	else
		CANONICAL_IPV6=''
		DNS_ALIAS=''
	fi

	build_known_ipv6 "$ec_mac"

	ec_primary_ipv6="$CANONICAL_IPV6"
	[ -n "$ec_primary_ipv6" ] || ec_primary_ipv6="${KNOWN_IPV6%% *}"

	if probe_online "$ec_ipv4"; then
		ec_online=1
	fi

	json_add_object ""
	json_add_string hostname "$ec_name"
	json_add_string mac "$ec_mac"
	json_add_string ipv4 "$ec_ipv4"
	json_add_string ipv6 "$ec_primary_ipv6"
	json_add_string canonical_ipv6 "$CANONICAL_IPV6"
	json_add_array ipv6_addresses
	for ec_addr in $KNOWN_IPV6; do
		json_add_string "" "$ec_addr"
	done
	json_close_array
	json_add_string dns "$DNS_ALIAS"
	json_add_int online "$ec_online"
	json_add_int persistent "$ec_persistent"
	json_add_int static_ipv4 "$([ -n "$ec_static_ipv4" ] && echo 1 || echo 0)"
	json_add_string reserved_ipv4 "$ec_static_ipv4"
	[ "$ec_shared_host" -eq 1 ] && ec_protected_host=1
	[ "$ec_complex_host" -eq 1 ] && ec_protected_host=1
	[ "$ec_ambiguous_host" -eq 1 ] && ec_protected_host=1

	json_add_int managed_pin "$ec_managed_pin"
	json_add_int shared_host "$ec_shared_host"
	json_add_int complex_host "$ec_complex_host"
	json_add_int ambiguous_host "$ec_ambiguous_host"
	json_add_int protected_host "$ec_protected_host"
	json_add_string lease_expiry "$ec_lease_expiry"
	json_close_object

	remember_emitted_mac "$ec_mac"
}


# Dynamic rows: active DHCPv4 leases. Their lifetime is exactly the DHCP lease
# lifetime. No extra history is kept.
emit_dynamic_leases() {
	local ed_expiry ed_mac ed_ipv4 ed_hostname ed_clientid ed_rest
	local ed_name ed_persistent ed_static_ipv4 ed_managed ed_shared ed_complex ed_ambiguous

	[ -r "$LEASE_FILE" ] || return 0

	while IFS=' ' read -r ed_expiry ed_mac ed_ipv4 ed_hostname ed_clientid ed_rest; do
		[ -n "$ed_mac" ] || continue
		lease_is_active "$ed_expiry" || continue
		mac_was_emitted "$ed_mac" && continue

		ed_name="$ed_hostname"
		[ "$ed_name" = '*' ] && ed_name=''
		ed_persistent=0
		ed_static_ipv4=''
		ed_managed=0
		ed_shared=0
		ed_complex=0
		ed_ambiguous=0

		if find_host_by_mac "$ed_mac"; then
			ed_persistent=1
			[ -n "$FOUND_HOST_NAME" ] && ed_name="$FOUND_HOST_NAME"
			ed_static_ipv4="$FOUND_HOST_STATIC_IPV4"
			ed_managed="$FOUND_HOST_MANAGED"
			[ "$FOUND_HOST_MAC_COUNT" -gt 1 ] && ed_shared=1
			ed_complex="$FOUND_HOST_COMPLEX"
			ed_ambiguous="$FOUND_HOST_AMBIGUOUS"
			[ -n "$ed_static_ipv4" ] && ed_ipv4="$ed_static_ipv4"
		fi

		emit_client "$ed_name" "$ed_mac" "$ed_ipv4" "$ed_persistent" "$ed_expiry" "$ed_static_ipv4" "$ed_managed" "$ed_shared" "$ed_complex" "$ed_ambiguous"
	done < "$LEASE_FILE"
}


# Persistent rows without an active DHCP lease. They stay visible as Offline.
emit_persistent_host() {
	local eph_section="$1"
	local eph_macs eph_mac eph_name eph_ipv4 eph_managed eph_shared eph_complex eph_ambiguous

	config_get eph_macs "$eph_section" mac
	[ -n "$eph_macs" ] || return 0
	eph_macs="$(printf '%s' "$eph_macs" | tr ',' ' ')"

	for eph_mac in $eph_macs; do
		mac_was_emitted "$eph_mac" && continue

		# Re-resolve by MAC so duplicate sections and section safety metadata are
		# computed consistently even for persistent hosts without a live lease.
		find_host_by_mac "$eph_mac" || continue

		eph_name="$FOUND_HOST_NAME"
		eph_ipv4="$FOUND_HOST_STATIC_IPV4"
		eph_managed="$FOUND_HOST_MANAGED"
		eph_shared=0
		[ "$FOUND_HOST_MAC_COUNT" -gt 1 ] && eph_shared=1
		eph_complex="$FOUND_HOST_COMPLEX"
		eph_ambiguous="$FOUND_HOST_AMBIGUOUS"

		emit_client "$eph_name" "$eph_mac" "$eph_ipv4" 1 "" "$eph_ipv4" "$eph_managed" "$eph_shared" "$eph_complex" "$eph_ambiguous"
	done
}


rpc_clients() {
	LAN_DEV="$(uci -q get network.${LAN_NET}.device)"
	[ -n "$LAN_DEV" ] || LAN_DEV='br-lan'

	NOW="$(date +%s)"
	YGG_NET=''
	config_load network
	config_foreach select_ygg_network interface
	LAN_YGG_PREFIX="$(find_lan_ygg_prefix)"
	EMITTED_MACS=''

	acquire_dhcp_lock shared || true
	config_load dhcp

	json_init
	json_add_array clients
	emit_dynamic_leases
	config_foreach emit_persistent_host host
	json_close_array
	json_dump
}


json_reply() {
	local jr_ok="$1"
	local jr_code="$2"
	local jr_message="$3"

	json_init
	json_add_int ok "$jr_ok"
	json_add_string code "$jr_code"
	json_add_string message "$jr_message"
	json_dump
}


json_reply_device() {
	local jrd_ok="$1"
	local jrd_code="$2"
	local jrd_message="$3"
	local jrd_mac="$4"
	local jrd_name="$5"
	local jrd_ipv4="$6"

	json_init
	json_add_int ok "$jrd_ok"
	json_add_string code "$jrd_code"
	json_add_string message "$jrd_message"
	json_add_string mac "$jrd_mac"
	json_add_string hostname "$jrd_name"
	json_add_string reserved_ipv4 "$jrd_ipv4"
	json_dump
}


read_request() {
	local rr_input
	rr_input="$(cat)"
	json_load "$rr_input" 2>/dev/null || return 1
	return 0
}


backup_dhcp_config() {
	DHCP_BACKUP="/tmp/yggdrasil-status-dhcp.$$.bak"
	cp -p "$DHCP_CONFIG" "$DHCP_BACKUP" || return 1
}


restore_dhcp_config() {
	[ -n "$DHCP_BACKUP" ] && [ -f "$DHCP_BACKUP" ] || return 0
	cp -p "$DHCP_BACKUP" "$DHCP_CONFIG" || true
	uci -q revert dhcp >/dev/null 2>&1 || true
	/etc/init.d/dnsmasq reload >/dev/null 2>&1 || true
}


finish_dhcp_config() {
	rm -f "$DHCP_BACKUP"
	DHCP_BACKUP=''
}


dhcp_has_pending_changes() {
	[ -n "$(uci -q changes dhcp 2>/dev/null)" ]
}


commit_and_reload_dhcp() {
	if ! uci commit dhcp; then
		restore_dhcp_config
		return 1
	fi

	if ! /etc/init.d/dnsmasq reload >/dev/null 2>&1; then
		restore_dhcp_config
		return 1
	fi

	finish_dhcp_config
	return 0
}


rpc_pin() {
	local rp_mac rp_name rp_reserve rp_section rp_ipv4=''

	read_request || {
		json_reply 0 'invalid_request' 'Invalid JSON request.'
		return 0
	}

	json_get_var rp_mac mac
	json_get_var rp_name name
	json_get_var rp_reserve reserve_ipv4

	rp_mac="$(normalize_mac "$rp_mac")"

	valid_mac "$rp_mac" || {
		json_reply 0 'invalid_mac' 'Invalid MAC address.'
		return 0
	}

	acquire_dhcp_lock exclusive || {
		json_reply 0 'busy' 'Another DHCP configuration update is already in progress.'
		return 0
	}

	NOW="$(date +%s)"
	config_load dhcp

	if find_host_by_mac "$rp_mac"; then
		json_reply_device 1 'already_persistent' 'Device is already persistent.' "$rp_mac" "$FOUND_HOST_NAME" "$FOUND_HOST_STATIC_IPV4"
		return 0
	fi

	find_active_lease_by_mac "$rp_mac" || {
		json_reply 0 'no_active_lease' 'The device no longer has an active DHCP lease.'
		return 0
	}

	[ -n "$rp_name" ] || rp_name="$LEASE_MATCH_NAME"

	valid_hostname "$rp_name" || {
		json_reply 0 'invalid_hostname' 'Hostname must be 1-63 characters using letters, digits or hyphens, and cannot start or end with a hyphen.'
		return 0
	}

	case "$rp_reserve" in
		1|true)
			rp_ipv4="$LEASE_MATCH_IPV4"
			if ! valid_ipv4 "$rp_ipv4"; then
				json_reply 0 'no_ipv4' 'The active lease does not contain a usable IPv4 address.'
				return 0
			fi
			;;
	esac

	rp_section="${PIN_SECTION_PREFIX}$(printf '%s' "$rp_mac" | tr -d ':')"

	if dhcp_has_pending_changes; then
		json_reply 0 'pending_uci_changes' 'DHCP has uncommitted UCI changes. Apply or revert them before using Pin/Unpin.'
		return 0
	fi

	if uci -q get "dhcp.${rp_section}" >/dev/null 2>&1; then
		json_reply 0 'section_collision' 'A Yggdrasil status pin section with this name already exists.'
		return 0
	fi

	DHCP_BACKUP=''
	backup_dhcp_config || {
		json_reply 0 'backup_failed' 'Could not back up /etc/config/dhcp.'
		return 0
	}

	if ! uci set "dhcp.${rp_section}=host" ||
	   ! uci set "dhcp.${rp_section}.name=${rp_name}" ||
	   ! uci set "dhcp.${rp_section}.mac=${rp_mac}"; then
		restore_dhcp_config
		finish_dhcp_config
		json_reply 0 'uci_failed' 'Could not create the persistent host entry.'
		return 0
	fi

	if [ -n "$rp_ipv4" ] && ! uci set "dhcp.${rp_section}.ip=${rp_ipv4}"; then
		restore_dhcp_config
		finish_dhcp_config
		json_reply 0 'uci_failed' 'Could not store the IPv4 reservation.'
		return 0
	fi

	if ! commit_and_reload_dhcp; then
		finish_dhcp_config
		json_reply 0 'reload_failed' 'Could not commit/reload DHCP configuration; the previous configuration was restored.'
		return 0
	fi

	json_reply_device 1 'pinned' 'Device pinned successfully.' "$rp_mac" "$rp_name" "$rp_ipv4"
}


rpc_unpin() {
	local ru_mac ru_confirm ru_static ru_section

	read_request || {
		json_reply 0 'invalid_request' 'Invalid JSON request.'
		return 0
	}

	json_get_var ru_mac mac
	json_get_var ru_confirm confirm_static
	ru_mac="$(normalize_mac "$ru_mac")"

	valid_mac "$ru_mac" || {
		json_reply 0 'invalid_mac' 'Invalid MAC address.'
		return 0
	}

	acquire_dhcp_lock exclusive || {
		json_reply 0 'busy' 'Another DHCP configuration update is already in progress.'
		return 0
	}

	config_load dhcp

	if ! find_host_by_mac "$ru_mac"; then
		json_reply 1 'already_dynamic' 'Device is already dynamic.'
		return 0
	fi

	if [ "$FOUND_HOST_MATCH_COUNT" -gt 1 ]; then
		json_reply 0 'ambiguous_host' 'This MAC appears in more than one config host section. Resolve the duplicate in Network -> DHCP and DNS before using Unpin.'
		return 0
	fi

	if [ "$FOUND_HOST_MAC_COUNT" -gt 1 ]; then
		json_reply 0 'shared_host' 'This config host contains multiple MAC addresses. Unpin it from the standard DHCP configuration to avoid affecting other devices.'
		return 0
	fi

	if [ "$FOUND_HOST_COMPLEX" -eq 1 ]; then
		json_reply 0 'complex_host' 'This config host contains additional DHCP options. Edit it in Network -> DHCP and DNS so those settings are not removed accidentally.'
		return 0
	fi

	ru_static="$FOUND_HOST_STATIC_IPV4"

	if [ -n "$ru_static" ]; then
		case "$ru_confirm" in
			1|true) ;;
			*)
				json_reply_device 0 'static_confirmation_required' 'This device has a static DHCP reservation. Removing this persistent entry will also remove the reserved IPv4 address.' "$ru_mac" "$FOUND_HOST_NAME" "$ru_static"
				return 0
				;;
		esac
	fi

	ru_section="$FOUND_HOST_SELECTOR"

	if dhcp_has_pending_changes; then
		json_reply 0 'pending_uci_changes' 'DHCP has uncommitted UCI changes. Apply or revert them before using Pin/Unpin.'
		return 0
	fi

	DHCP_BACKUP=''
	backup_dhcp_config || {
		json_reply 0 'backup_failed' 'Could not back up /etc/config/dhcp.'
		return 0
	}

	if ! uci -q delete "dhcp.${ru_section}"; then
		restore_dhcp_config
		finish_dhcp_config
		json_reply 0 'uci_failed' 'Could not remove the persistent host entry.'
		return 0
	fi

	if ! commit_and_reload_dhcp; then
		finish_dhcp_config
		json_reply 0 'reload_failed' 'Could not commit/reload DHCP configuration; the previous configuration was restored.'
		return 0
	fi

	json_reply_device 1 'unpinned' 'Device unpinned successfully. Any matching config domain record was left untouched.' "$ru_mac" "$FOUND_HOST_NAME" "$ru_static"
}


case "$1" in
	list)
		printf '%s\n' '{"clients":{},"pin":{"mac":"","name":"","reserve_ipv4":false},"unpin":{"mac":"","confirm_static":false}}'
		;;

	call)
		case "$2" in
			clients) rpc_clients ;;
			pin) rpc_pin ;;
			unpin) rpc_unpin ;;
		esac
		;;
esac
```

Make it executable and validate its shell syntax:

```sh
chmod 0755 /usr/libexec/rpcd/luci.yggdrasil-status
sh -n /usr/libexec/rpcd/luci.yggdrasil-status
```

### 13.9 Install the rpcd ACL

Create:

```text
/usr/share/rpcd/acl.d/yggdrasil-status.json
```

```json
{
	"yggdrasil-status": {
		"description": "Read and manage Yggdrasil status LAN inventory",
		"read": {
			"ubus": {
				"network.interface": [ "dump" ],
				"luci.yggdrasil": [ "getPeers" ],
				"luci.yggdrasil-status": [ "clients" ]
			},
			"uci": [ "network" ]
		},
		"write": {
			"ubus": {
				"luci.yggdrasil-status": [ "pin", "unpin" ]
			}
		}
	}
}
```

The ACL keeps read-only status access separate from the two mutating RPC methods, `pin` and `unpin`.

### 13.10 Install the LuCI menu entry

Create:

```text
/usr/share/luci/menu.d/yggdrasil-status.json
```

```json
{
	"admin/status/yggdrasil": {
		"title": "Yggdrasil",
		"order": 5,
		"action": {
			"type": "view",
			"path": "status/yggdrasil"
		},
		"depends": {
			"acl": [ "yggdrasil-status" ]
		}
	}
}
```

### 13.11 Install the frontend

Create:

```text
/www/luci-static/resources/view/status/yggdrasil.js
```

```javascript
'use strict';
'require view';
'require rpc';
'require uci';
'require poll';
'require ui';


var callInterfaces = rpc.declare({
	object: 'network.interface',
	method: 'dump',
	expect: { interface: [] }
});


var callPeers = rpc.declare({
	object: 'luci.yggdrasil',
	method: 'getPeers',
	params: [ 'interface' ],
	expect: { peers: [] }
});


var callClients = rpc.declare({
	object: 'luci.yggdrasil-status',
	method: 'clients',
	expect: { clients: [] }
});


var callPin = rpc.declare({
	object: 'luci.yggdrasil-status',
	method: 'pin',
	params: [ 'mac', 'name', 'reserve_ipv4' ]
});


var callUnpin = rpc.declare({
	object: 'luci.yggdrasil-status',
	method: 'unpin',
	params: [ 'mac', 'confirm_static' ]
});


function cleanURI(uri) {
	return uri ? String(uri).replace(/\?.*$/, '') : '—';
}


function dataUnit(value) {
	return value != null
		? '%.2mB'.format(value)
		: '—';
}


function rate(value) {
	return value > 0
		? '%.2mB/s'.format(value)
		: '—';
}


function lastError(peer) {
	if (peer.up || !peer.last_error)
		return '—';

	if (peer.last_error_time)
		return '%t ago: %s'.format(
			peer.last_error_time,
			peer.last_error
		);

	return peer.last_error;
}


function makeTable(headers, rows, id, compactColumns) {
	var attrs = { 'class': 'table' };
	var compact = compactColumns || [];

	if (id)
		attrs.id = id;

	var table = E('table', attrs, [
		E('tr', { 'class': 'tr table-titles' },
			headers.map(function(header, i) {
				return E('th', {
					'class': 'th',
					'style': compact.indexOf(i) !== -1
						? 'width: 1%; white-space: nowrap; text-align: center'
						: null
				}, header);
			})
		)
	]);

	rows.forEach(function(row) {
		table.appendChild(E('tr', { 'class': 'tr' },
			row.map(function(value, i) {
				var isCompact = compact.indexOf(i) !== -1;

				return E('td', {
					'class': 'td',
					'data-title': headers[i],
					'style': isCompact
						? 'width: 1%; white-space: nowrap; text-align: center; word-break: normal'
						: 'word-break: break-word'
				}, value == null || value === '' ? '—' : value);
			})
		));
	});

	return table;
}


function ipv6Cell(client) {
	var addresses = Array.isArray(client.ipv6_addresses)
		? client.ipv6_addresses.slice()
		: [];

	if (!addresses.length && client.ipv6)
		addresses.push(client.ipv6);

	if (!addresses.length)
		return '—';

	return E('div', {}, addresses.map(function(addr) {
		var attrs = {};

		if (client.canonical_ipv6 && addr === client.canonical_ipv6) {
			attrs.style = 'font-weight: 600';
			attrs.title = _('Canonical address');
		}

		return E('div', attrs, addr);
	}));
}


function backendError(result) {
	return result && result.message
		? result.message
		: _('The operation failed.');
}


function notifyError(message) {
	ui.addNotification(null, E('p', {}, message), 'error');
}


function refreshClients() {
	return callClients().then(function(clients) {
		replaceClientTable(clients || []);
		return clients;
	});
}


function validHostname(name) {
	return /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(name);
}


function showPinDialog(client) {
	var initialName = client.hostname || '';
	var nameInput = E('input', {
		'class': 'cbi-input-text',
		'type': 'text',
		'value': initialName,
		'placeholder': _('Device hostname'),
		'maxlength': 63,
		'style': 'width: 100%'
	});

	var reserveAttrs = { 'type': 'checkbox' };

	if (!client.ipv4)
		reserveAttrs.disabled = '';

	var reserveInput = E('input', reserveAttrs);

	var errorBox = E('div', {
		'style': 'display:none; color:#dc2626; margin-top:.5em'
	});

	var saveButton;

	function showError(message) {
		errorBox.textContent = message;
		errorBox.style.display = '';
	}

	saveButton = E('button', {
		'class': 'btn cbi-button-positive important',
		'click': function(ev) {
			ev.preventDefault();

			var name = String(nameInput.value || '').trim();
			var reserve = !!reserveInput.checked;

			if (!validHostname(name)) {
				showError(_('Hostname must be 1-63 characters using letters, digits or hyphens, and cannot start or end with a hyphen.'));
				return;
			}

			errorBox.style.display = 'none';
			saveButton.disabled = true;

			callPin(client.mac, name, reserve)
				.then(function(result) {
					if (!result || !result.ok) {
						showError(backendError(result));
						saveButton.disabled = false;
						return;
					}

					ui.hideModal();
					return refreshClients();
				})
				.catch(function(err) {
					showError(err.message || String(err));
					saveButton.disabled = false;
				});
		}
	}, _('Save'));

	ui.showModal(_('Pin device'), [
		E('p', {}, _('Pinning creates a normal OpenWrt config host entry so this device remains visible after its DHCP lease expires.')),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Hostname')),
			E('div', { 'class': 'cbi-value-field' }, nameInput)
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('IPv4 reservation')),
			E('div', { 'class': 'cbi-value-field' }, [
				E('label', {}, [
					reserveInput,
					' ',
					client.ipv4
						? _('Reserve current IPv4 %s').format(client.ipv4)
						: _('No current IPv4 address is available')
				])
			])
		]),
		E('p', {}, _('The IPv4 reservation is optional and is disabled by default.')),
		errorBox,
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, _('Cancel')),
			' ',
			saveButton
		])
	]);

	nameInput.focus();
}


function performUnpin(client, confirmStatic, errorBox, button) {
	button.disabled = true;

	return callUnpin(client.mac, !!confirmStatic)
		.then(function(result) {
			if (result && result.code === 'static_confirmation_required') {
				ui.hideModal();
				client.static_ipv4 = 1;
				client.reserved_ipv4 = result.reserved_ipv4 || client.reserved_ipv4 || client.ipv4 || '';
				showUnpinDialog(client);
				return;
			}

			if (!result || !result.ok) {
				errorBox.textContent = backendError(result);
				errorBox.style.display = '';
				button.disabled = false;
				return;
			}

			ui.hideModal();
			return refreshClients();
		})
		.catch(function(err) {
			errorBox.textContent = err.message || String(err);
			errorBox.style.display = '';
			button.disabled = false;
		});
}


function showUnpinDialog(client) {
	var errorBox = E('div', {
		'style': 'display:none; color:#dc2626; margin-top:.5em'
	});
	var paragraphs = [];
	var confirmStatic = !!client.static_ipv4;
	var actionLabel = _('Unpin');
	var actionButton;

	paragraphs.push(E('p', {}, _('After unpinning, the device remains in the table only while an active DHCP lease exists.')));

	if (!client.managed_pin) {
		paragraphs.push(E('p', {}, _('This persistent entry is an existing OpenWrt config host record, not one created by the Yggdrasil status Pin button. Unpinning removes that config host section from /etc/config/dhcp.')));
	}

	if (client.shared_host) {
		paragraphs.push(E('p', { 'style': 'color:#dc2626; font-weight:600' }, _('This config host contains multiple MAC addresses. It cannot be safely removed from this page. Use Network -> DHCP and DNS to edit it manually.')));
	}

	if (confirmStatic) {
		paragraphs.push(E('p', { 'style': 'color:#dc2626; font-weight:600' },
			_('This device has a static DHCP reservation. Removing this persistent entry will also remove the reserved IPv4 address %s.').format(client.reserved_ipv4 || client.ipv4 || '—')
		));
		actionLabel = _('Unpin and remove reservation');
	}

	paragraphs.push(E('p', {}, _('Any separate config domain canonical IPv6 / DNS record is left untouched.')));

	var actionAttrs = {
		'class': 'btn cbi-button-negative important',
		'click': function(ev) {
			ev.preventDefault();
			performUnpin(client, confirmStatic, errorBox, actionButton);
		}
	};

	if (client.shared_host)
		actionAttrs.disabled = '';

	actionButton = E('button', actionAttrs, actionLabel);

	ui.showModal(_('Unpin device'), paragraphs.concat([
		errorBox,
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, _('Cancel')),
			' ',
			actionButton
		])
	]));
}


function showProtectedHostDialog(client) {
	var reasons = [];

	if (client.shared_host)
		reasons.push(_('the config host contains multiple MAC addresses'));

	if (client.ambiguous_host)
		reasons.push(_('this MAC appears in more than one config host section'));

	if (client.complex_host)
		reasons.push(_('the config host contains additional DHCP options'));

	ui.showModal(_('Manage persistent device'), [
		E('p', {}, _('This device is persistent, but the Yggdrasil status page will not delete its OpenWrt config host automatically.')),
		E('p', { 'style': 'font-weight:600' }, reasons.length
			? _('Reason: %s.').format(reasons.join('; '))
			: _('The host record requires manual review.')),
		E('p', {}, _('Use Network -> DHCP and DNS to edit or remove this host record safely.')),
		E('p', {}, _('Any separate config domain canonical IPv6 / DNS record is independent and is not changed here.')),
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn cbi-button-positive important',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, _('Close'))
		])
	]);
}


function persistenceCell(client) {
	var label;
	var button;

	if (!client.persistent) {
		label = E('span', { 'style': 'font-weight:600' }, _('Dynamic'));
		button = E('button', {
			'class': 'btn cbi-button-action',
			'style': 'width:100%',
			'click': function(ev) {
				ev.preventDefault();
				showPinDialog(client);
			}
		}, _('Pin'));
	}
	else {
		label = E('span', { 'style': 'font-weight:600' },
			client.static_ipv4
				? _('Static')
				: (client.managed_pin ? _('Pinned') : _('Persistent')));

		if (client.protected_host) {
			button = E('button', {
				'class': 'btn cbi-button-action',
				'style': 'width:100%',
				'click': function(ev) {
					ev.preventDefault();
					showProtectedHostDialog(client);
				}
			}, _('Manage'));
		}
		else {
			button = E('button', {
				'class': 'btn cbi-button-action',
				'style': 'width:100%',
				'click': function(ev) {
					ev.preventDefault();
					showUnpinDialog(client);
				}
			}, client.static_ipv4 ? _('Manage') : _('Unpin'));
		}
	}

	return E('div', {
		'style': 'display:grid; grid-template-columns:6em 5.5em; gap:.5em; align-items:center; white-space:nowrap'
	}, [ label, button ]);
}


function makeClientTable(clients) {
	var headers = [
		_('Hostname'),
		_('MAC'),
		_('IPv4'),
		_('Yggdrasil IPv6'),
		_('DNS'),
		_('State'),
		_('Persistence')
	];

	var rows = (clients || []).map(function(client) {
		return [
			client.hostname || '—',
			client.mac || '—',
			client.ipv4 || '—',
			ipv6Cell(client),
			client.dns || '—',
			client.online
				? E('span', { 'style': 'color: #16a34a; font-weight: 600' }, _('Online'))
				: E('span', { 'style': 'color: #dc2626; font-weight: 600' }, _('Offline')),
			persistenceCell(client)
		];
	});

	rows.sort(function(a, b) {
		return String(a[0]).localeCompare(String(b[0]));
	});

	return makeTable(headers, rows, 'yggdrasil-lan-clients');
}


function replaceClientTable(clients) {
	var oldTable = document.getElementById('yggdrasil-lan-clients');

	if (!oldTable)
		return;

	var newTable = makeClientTable(clients);
	oldTable.parentNode.replaceChild(newTable, oldTable);
}


return view.extend({
	load: function() {
		return Promise.all([
			callInterfaces(),
			callClients(),
			uci.load('network')
		]).then(function(data) {
			var interfaces = (data[0] || []).filter(function(iface) {
				return iface.proto === 'yggdrasil';
			});

			return Promise.all(interfaces.map(function(iface) {
				return callPeers(iface.interface).catch(function() {
					return [];
				});
			})).then(function(peers) {
				return {
					interfaces: interfaces,
					clients: data[1] || [],
					peers: peers
				};
			});
		});
	},


	render: function(data) {
		var interfaces = data.interfaces;

		if (!interfaces.length)
			return E([
				E('h2', {}, _('Yggdrasil')),
				E('em', {}, _('No Yggdrasil interface found.'))
			]);

		var nodeRows = [];

		interfaces.forEach(function(iface) {
			var address = (iface['ipv6-address'] || [])[0];

			var subnet = (iface['ipv6-prefix'] || []).find(function(p) {
				return p.class === 'ygg';
			});

			var publicKey =
				uci.get('network', iface.interface, 'public_key') || '—';

			nodeRows.push([
				iface.interface,
				iface.up ? _('Up') : _('Down'),
				address ? address.address : '—',
				subnet ? subnet.address + '/' + subnet.mask : '—',
				publicKey,
				iface.up ? '%t'.format(iface.uptime || 0) : '—'
			]);
		});

		var peerRows = [];

		interfaces.forEach(function(iface, index) {
			(data.peers[index] || []).forEach(function(peer) {
				peerRows.push([
					iface.interface,
					cleanURI(peer.remote),
					peer.up ? _('Up') : _('Down'),
					peer.inbound ? _('In') : _('Out'),
					peer.address || '—',
					peer.up ? '%t'.format(peer.uptime || 0) : '—',
					peer.up && peer.latency
						? '%.2f ms'.format(peer.latency / 1000000)
						: '—',
					dataUnit(peer.bytes_recvd),
					dataUnit(peer.bytes_sent),
					rate(peer.rate_recvd),
					rate(peer.rate_sent),
					peer.priority != null ? String(peer.priority) : '—',
					peer.cost != null ? String(peer.cost) : '—',
					lastError(peer)
				]);
			});
		});

		var content = [
			E('h2', {}, _('Yggdrasil')),
			E('h3', {}, _('Node')),
			makeTable(
				[
					_('Interface'),
					_('State'),
					_('Yggdrasil address'),
					_('Routed subnet'),
					_('Public key'),
					_('Uptime')
				],
				nodeRows,
				null,
				[1]
			),
			E('h3', {}, _('Peers'))
		];

		if (peerRows.length) {
			content.push(makeTable(
				[
					_('Interface'),
					_('URI'),
					_('State'),
					_('Dir'),
					_('IP Address'),
					_('Uptime'),
					_('RTT'),
					_('RX'),
					_('TX'),
					_('Down'),
					_('Up'),
					_('Pr'),
					_('Cost'),
					_('Last Error')
				],
				peerRows,
				null,
				[2, 3, 11, 12]
			));
		}
		else {
			content.push(E('em', {}, _('No peers found.')));
		}

		content.push(
			E('h3', {}, _('LAN clients')),
			makeClientTable(data.clients)
		);

		/*
		 * Dynamic rows live for the DHCP lease lifetime; persistent config-host
		 * rows remain. Pin/Unpin modifies only config host records. Polling runs
		 * only while this page is open and refreshes the LAN table every 15 sec.
		 */
		poll.add(function() {
			return refreshClients().catch(function() {});
		}, 15);

		return E(content);
	},


	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
```

The final frontend:

- shows node information and Yggdrasil peers;
- shows active DHCP clients dynamically;
- keeps `config host` devices persistently;
- merges dynamic and persistent sources by MAC;
- shows the stable-first selected Ygg SLAAC set from neighbour state;
- shows canonical Ygg IPv6 / DNS metadata only for a persistent identity;
- renders `Online` in green and `Offline` in red;
- exposes `Dynamic`, `Pinned`, `Persistent` and `Static` states;
- lets a dynamic device be pinned with an optional current IPv4 reservation;
- requires an explicit destructive confirmation before deleting a static reservation;
- refuses automatic deletion of shared, duplicate-MAC or complex host records;
- polls the clients RPC every 15 seconds while the page is open.

### 13.12 Restart only the UI/RPC layer

```sh
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
```

No network reload is required merely to install or update the status page.

Check the RPC object and signatures:

```sh
ubus -v list luci.yggdrasil-status
```

It should expose:

```text
clients
pin
unpin
```

Then test the read-only inventory method:

```sh
ubus call luci.yggdrasil-status clients
```

A DHCP-only client can look like:

```json
{
        "hostname": "Laptop",
        "mac": "AA:BB:CC:DD:EE:FF",
        "ipv4": "192.168.1.143",
        "ipv6": "3xx:....",
        "canonical_ipv6": "",
        "ipv6_addresses": [
                "3xx:...."
        ],
        "dns": "",
        "online": 1,
        "persistent": 0,
        "static_ipv4": 0,
        "reserved_ipv4": "",
        "managed_pin": 0,
        "shared_host": 0,
        "complex_host": 0,
        "ambiguous_host": 0,
        "protected_host": 0,
        "lease_expiry": "<UNIX_TIMESTAMP>"
}
```

A persistent device with a canonical record and static IPv4 reservation can look like:

```json
{
        "hostname": "MyServer",
        "mac": "11:22:33:44:55:66",
        "ipv4": "192.168.1.123",
        "ipv6": "3xx:....",
        "canonical_ipv6": "3xx:....",
        "ipv6_addresses": [
                "3xx:...."
        ],
        "dns": "myserver.home.arpa",
        "online": 0,
        "persistent": 1,
        "static_ipv4": 1,
        "reserved_ipv4": "192.168.1.123",
        "managed_pin": 1,
        "shared_host": 0,
        "complex_host": 0,
        "ambiguous_host": 0,
        "protected_host": 0,
        "lease_expiry": ""
}
```

Open:

```text
Status -> Yggdrasil
```

### 13.13 Garbage collection requires no extra service

The lifetime policy is entirely native:

```text
DHCP-only client
└── lifetime = active DHCP lease

persistent config host
└── lifetime = UCI configuration

observed IPv6 addresses
└── lifetime = kernel neighbour state
```

Pin adds a normal persistent `config host`; Unpin removes it. Neither operation creates a separate inventory database or retention mechanism.

The frontend uses LuCI's polling loop. `poll.add()` invokes the clients RPC only while the page is open.

Therefore the module still requires:

```text
no daemon
no cron
no DB
no persistent runtime cache
no custom garbage collector
```

---

## 14. Part III - Optional DNS module

DNS is an add-on to the routed-LAN system.

The core routing path does not depend on it.

### 14.1 What is already shared with Part II

If Part II uses `config domain`, `dnsmasq` already has persistent address/name records available through standard OpenWrt configuration.

For example:

```text
config domain 'ygg_mydevice'
        option name 'mydevice.home.arpa'
        option ip '<CANONICAL_YGG_IPV6>'
```

If you do not want the status module, you may still create the same records purely for DNS.

### 14.2 Keep `home.arpa` local

Add to the main `dnsmasq` section:

```text
list server '/home.arpa/'
```

This tells `dnsmasq` not to forward unknown `home.arpa` names to ordinary upstream resolvers.

Commit and restart DNS:

```sh
uci commit dhcp
/etc/init.d/dnsmasq restart
```

Local control test on OpenWrt:

```sh
nslookup myserver.home.arpa 127.0.0.1
```

### 14.3 Expose DNS over Yggdrasil - tested final behavior

The current tested router configuration allows TCP/UDP port 53 only from the
same trusted Ygg `/128` addresses used for administration and LAN access:

```text
config rule 'ygg_dns'
        option name 'Allow-DNS-from-Trusted-Yggdrasil'
        option src 'ygg'
        option proto 'tcp udp'
        option dest_port '53'
        list src_ip '<TRUSTED_YGG_IPV6_1>'
        list src_ip '<TRUSTED_YGG_IPV6_2>'
        option target 'ACCEPT'
```

This is an INPUT rule to OpenWrt itself. It is not `ygg -> lan` forwarding and does not open DNS on WAN.

Apply:

```sh
uci commit firewall
/etc/init.d/firewall restart
```

Then query the router's Yggdrasil node address from another Yggdrasil client:

```sh
nslookup myserver.home.arpa <ROUTER_YGG_IPV6>
```

If this returns the canonical routed LAN IPv6, the server side of DNS-over-Yggdrasil is working.

### 14.4 Broader DNS access is optional

A deployment may deliberately omit `src_ip` to expose DNS to the whole Ygg
zone, but that is broader than the current tested configuration and is not
needed for trusted remote clients:

```text
config rule 'ygg_dns'
        option name 'Allow-DNS-from-Yggdrasil'
        option src 'ygg'
        option proto 'tcp udp'
        option dest_port '53'
        option target 'ACCEPT'
```

### 14.5 Client-side split DNS is a separate client concern

The OpenWrt side can answer:

```text
*.home.arpa -> canonical Ygg-routed LAN IPv6
```

over the router's Yggdrasil node address.

For convenient use, a remote client may configure a split resolver:

```text
home.arpa only -> OpenWrt Ygg DNS
all other DNS  -> normal Wi-Fi/Ethernet/VPN resolver
```

That is client-specific and is intentionally outside the OpenWrt routing
core. Do not replace a client's global DNS with the OpenWrt Ygg resolver merely
to obtain `home.arpa` resolution.

The tested Linux client uses `systemd-resolved`, fixes Yggdrasil to
`IfName: ygg0`, and applies the router DNS plus route-only domain `~home.arpa`
from a Yggdrasil systemd service drop-in. Wi-Fi remains the default DNS route.
Reference helper/drop-in files are included under `client/linux/`.

Do not save the externally created Ygg interface as a persistent NetworkManager
TUN profile. At boot NetworkManager can otherwise occupy `tun0` first, forcing
Yggdrasil onto `tun1` while split DNS remains attached to the dead interface.
Merely placing the router second in `/etc/resolv.conf` is also not split DNS:
resolver ordering is failover rather than suffix routing.

The router module is complete once direct queries such as this succeed:

```sh
nslookup myserver.home.arpa <ROUTER_YGG_IPV6>
```

---

## 15. How Auto-IP actually works

"Auto-IP" in this guide is not a custom address allocator.

It is normal IPv6 prefix delegation plus Router Advertisements and SLAAC.

### 15.1 Yggdrasil identity determines the routed subnet

The router's Yggdrasil private key determines its node identity. That identity determines both the node address and its routed subnet.

Therefore preserving the private key is critical if you want the same routed `/64` after reinstalling the router.

### 15.2 OpenWrt selects the Yggdrasil prefix class

```text
network.lan.ip6assign = 64
network.lan.ip6class  = ygg
```

This tells netifd which prefix source should feed LAN.

### 15.3 odhcpd advertises the `/64`

`odhcpd` sends Router Advertisements with the SLAAC autonomous flag enabled.

The client learns:

```text
prefix = 3xx:....::/64
```

### 15.4 The client chooses its IID

The router advertises the prefix. The client forms the lower 64-bit interface identifier according to its own IPv6 implementation.

That may be:

- EUI-64 on some embedded devices;
- a stable/privacy IID on modern operating systems;
- another stable implementation-specific IID.

The core routing system does not require one particular IID algorithm.

### 15.5 Canonical address is optional metadata, not an SLAAC assignment

A client may have multiple simultaneous SLAAC/privacy addresses.

For a purely dynamic client, the status page can simply show the addresses currently associated with its MAC:

```text
current device addresses:
3xx:A
3xx:B
3xx:C
```

Nothing is persisted automatically.

For infrastructure where one stable address should remain visible even while neighbour state is absent, an optional canonical `config domain` can record that address:

```text
observed addresses:
3xx:A
3xx:B
3xx:C

optional canonical address:
3xx:A
```

The canonical record does not cause the address to exist on the client. It only records a stable address that the client already uses.

---

## 16. Why the final design is shaped this way

### 16.1 Why standardize on `ygg0`

A deterministic logical name makes UCI sections, firewall references and documentation predictable.

The real tested router pre-dated this standardization and used `ygg`. The guide uses `ygg0` for clean new installations rather than copying that local historical name.

### 16.2 Why native OpenWrt integration

OpenWrt already owns the components that must cooperate:

```text
Yggdrasil -> netifd
prefix     -> network.lan
RA         -> odhcpd
security   -> firewall4
status     -> rpcd/LuCI
DNS        -> dnsmasq (optional)
```

Adding a container or a second network-management layer would make prefix delegation and firewall ownership less direct.

### 16.3 Why SLAAC instead of stateful DHCPv6

The core requirement is simply to make ordinary IPv6 clients use the routed `/64`.

RA/SLAAC already does that without requiring a stateful DHCPv6 address lease mechanism.

### 16.4 Why the extra ULA is removed

This particular profile intentionally keeps LAN IPv6 simple:

```text
Ygg-routed prefix
+
link-local
```

IPv4 DHCP continues independently.

A deployment that needs a ULA for another reason may keep one, but that is a different profile and should be documented explicitly rather than mixed into this guide silently.

### 16.5 Why no blanket `ygg -> lan`

Routing and authorization are separate:

```text
routing:
this /64 is reachable

firewall:
these source addresses are allowed to use it
```

This avoids exposing the entire LAN to the public Yggdrasil overlay.

### 16.6 Why `getHostHints` is not authoritative

`getHostHints` is useful diagnostic context, but it is not used as the inventory database.

Dynamic lifetime comes from active DHCP leases. Persistent lifetime comes from `config host`. IPv6 neighbour state is used only to enrich those rows with current SLAAC addresses.

This avoids both failure modes:

```text
neighbour entry disappears
-> persistent device does not disappear

one-time guest appears
-> guest is not written permanently anywhere
```

### 16.7 Why `config host` is an overlay rather than the whole inventory

`config host` remains the native OpenWrt place for persistent device identity and optional DHCPv4 reservation information.

But requiring it for every row would turn a dynamic LAN view into a manually curated allow-list. The final backend therefore uses:

```text
active DHCP lease -> dynamic row
config host       -> persistent row / metadata override
```

A guest is visible while DHCP remembers the lease and disappears afterwards. Infrastructure explicitly described by `config host` remains visible as `Offline` when powered down. The final LuCI page exposes this distinction directly: `Pin` creates the persistent `config host`, while `Unpin` removes it.

Pinning normally stores only hostname + MAC. Reserving the current IPv4 is a separate checkbox and is off by default. If a static reservation already exists, the UI uses `Manage` and the backend refuses deletion until the destructive removal of both persistence and the reserved IPv4 is explicitly confirmed. Shared multi-MAC, duplicate-MAC and complex `config host` records are not deleted from this page at all.

### 16.8 Why canonical IPv6 uses `config domain`

A canonical IPv6 is optional for the dashboard. Dynamic clients can be displayed using their current SLAAC addresses alone.

When a persistent canonical address is desired, a custom `ygg_ipv6` field would work, but standard `config domain` already stores a persistent name/address pair and is understood by `dnsmasq`.

This lets the status UI and optional DNS module reuse the same record without another parser or generator.

### 16.9 Why `home.arpa`

RFC 8375 reserves `home.arpa.` for locally served names in home networks.

This is cleaner than inventing a pseudo-domain that may conflict with other naming systems.

### 16.10 Why Online = ARP OR known Ygg IPv6

Neighbour state is not sufficiently precise for live presence.

An active ARP probe is a strong direct-LAN IPv4 presence signal. If that fails,
the backend tries the selected Ygg IPv6 set: the canonical address when
configured, otherwise an observed modified EUI-64, otherwise the observed
privacy-only addresses.

```text
ARP success -> Online
else any known Ygg IPv6 replies -> Online
else -> Offline
```

The result changes only the `State` field. It does not decide how long a row exists; row lifetime is controlled by DHCP or `config host`.

### 16.11 Why no monitoring daemon

The status page is not a monitoring/time-series system.

It only needs fresh state while somebody is looking at it.

Long-term monitoring belongs elsewhere; this page is an on-demand operational view.

### 16.12 Why DNS is a separate optional module

Yggdrasil routing does not need DNS.

The core system is useful with direct IPv6 addresses. DNS adds ergonomics, not reachability.

The only intentional coupling is data reuse: `config domain` can serve both as the status module's canonical-address record and as a `dnsmasq` name record.

### 16.13 Why Jumper remains optional

The network must work without Jumper. Jumper may improve path quality, but it is not allowed to become a single point of failure for base Yggdrasil reachability.

---

## 17. Troubleshooting notes from the real deployment

These points are included because they came from actual failures during development rather than hypothetical edge cases.

### 17.1 `FAILED` NDP does not prove the client's IPv6 disappeared

A neighbour entry such as:

```text
3xx:.... dev br-lan FAILED
```

means the router could not currently resolve/reach that neighbour. It does **not** prove the address was removed from the client.

During testing, stable client addresses became reachable again after the device returned and NDP was refreshed.

Use active tests and client state before concluding that SLAAC itself changed the address.

### 17.2 `STALE` can be a healthy device

`STALE` is a neighbour-cache state, not an Offline verdict.

A printer in `STALE` state remained completely usable. This is one reason the final dashboard performs active probes.

### 17.3 Historical SLAAC addresses can accumulate in NDP

A client may legitimately have stable plus temporary/privacy addresses. The
router advertises a prefix; the client chooses its IID(s).

The original v4 status page displayed every Ygg address associated with a MAC
in `ip -6 neigh`. On a long-running router this included many historical
privacy IIDs. Polling also probed those entries, which could keep the NDP set
busy even after a client had stopped using the addresses.

v5 uses stable-first selection: a canonical `config domain` wins; otherwise an
observed modified EUI-64 wins; privacy-only clients retain all observed
addresses. Nothing is persisted, and no address is assigned to or removed from
the client.

For a DHCP-only client, the device row itself still disappears when the DHCP
lease expires.

### 17.4 BusyBox lowercase bug found during final backend testing

An earlier backend used:

```sh
tr '[:upper:]' '[:lower:]'
```

On the tested router this did not lowercase hostnames as expected in the actual execution path. That prevented:

```text
MyDevice
```

from matching:

```text
mydevice.home.arpa
```

The tested final backend therefore uses:

```sh
tr 'A-Z' 'a-z'
```

Do not "clean up" that line back to the earlier form without testing it on the target BusyBox/OpenWrt environment.

### 17.5 DNS timeout over Ygg may be firewall, not dnsmasq

During development, local `home.arpa` records already worked and `dnsmasq` was listening, but direct DNS queries over Yggdrasil timed out.

The missing piece was an INPUT firewall rule for TCP/UDP 53 from the `ygg` zone.

Always distinguish:

```text
DNS record exists?
DNS listener exists?
firewall permits Ygg -> router:53?
```

### 17.6 Do not use runtime host hints as an inventory repair tool

If rows disappear because the backend was changed to use `getHostHints` as its inventory database, the fix is not to continuously "wake" NDP with pings. Restore the explicit lifetime model instead:

```text
active DHCP lease -> dynamic row
config host       -> persistent row
neighbour state   -> runtime IPv6 enrichment only
```

---

## 18. Updating and maintenance

### 18.1 Preserve the Yggdrasil identity

Before an upgrade, back up the network configuration and private key securely.

For example:

```sh
uci export network > /root/network-before-ygg-update.conf
```

Do not regenerate the Yggdrasil keypair during an ordinary update unless you intentionally want a new node identity and routed subnet.

### 18.2 Back up the optional status module

If Part II is installed:

```sh
tar -czf /root/yggdrasil-status-backup.tar.gz \
        /usr/libexec/rpcd/luci.yggdrasil-status \
        /usr/share/rpcd/acl.d/yggdrasil-status.json \
        /usr/share/luci/menu.d/yggdrasil-status.json \
        /www/luci-static/resources/view/status/yggdrasil.js

uci export dhcp > /root/dhcp-before-ygg-status-update.conf
```

The DHCP backup matters because persistent Pin/Unpin state is stored as normal `config host` records rather than in a private status database.

### 18.3 Update deliberately

For the packages you actually installed:

```sh
apk update
apk upgrade yggdrasil luci-proto-yggdrasil yggdrasil-jumper
```

Do not assume every future package keeps the exact same UCI options.

### 18.4 Post-update verification

Re-run the relevant layer checks:

```sh
ifstatus ygg0
yggdrasilctl getPeers
ubus call dhcp ipv6ra
fw4 print
```

If Part II is installed:

```sh
ubus -v list luci.yggdrasil-status
ubus call luci.yggdrasil-status clients
```

Confirm that `clients`, `pin` and `unpin` are all present before relying on the management buttons in LuCI.

If Part III is installed:

```sh
nslookup <HOST>.home.arpa <ROUTER_YGG_IPV6>
```

Then test actual remote access to a permitted LAN service.

---

## 19. Removing the setup

Removal is modular too.

### 19.1 Remove only Part III DNS-over-Ygg access

Delete the `ygg_dns` firewall rule and, if no longer wanted, the `home.arpa` local-zone directive and `config domain` records used purely for DNS.

Then:

```sh
uci commit firewall
uci commit dhcp
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
```

If Part II still uses the same `config domain` records as canonical addresses, keep those records.

### 19.2 Remove only Part II status UI

```sh
rm -f /usr/libexec/rpcd/luci.yggdrasil-status
rm -f /usr/share/rpcd/acl.d/yggdrasil-status.json
rm -f /usr/share/luci/menu.d/yggdrasil-status.json
rm -f /www/luci-static/resources/view/status/yggdrasil.js
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
```

You may then remove `iputils-arping` if nothing else needs it.

Inventory `config host` entries may be kept because they are normal OpenWrt device/DHCP configuration. Removing the LuCI module itself does not delete them. If you do not want dashboard-created pins to remain, use `Unpin` before removing the module or remove the corresponding `config host` records manually.

Be careful with static reservations: deleting a `config host` that contains `option ip` also removes that DHCP reservation. `config domain` canonical IPv6 / DNS records are separate and are not removed automatically.

### 19.3 Remove the core Yggdrasil LAN setup

Because removing the core can destroy remote management reachability, do this only with an alternate management path available.

Remove the explicit Yggdrasil firewall rules and zone, restore the LAN IPv6 policy you actually want, and only then remove Yggdrasil packages.

Example package removal after configuration cleanup:

```sh
apk del yggdrasil-jumper luci-proto-yggdrasil yggdrasil
```

Do not blindly delete IPv6 settings without deciding what prefix/RA design replaces the Yggdrasil profile.

---

## 20. Sources and acknowledgements

The final design combines upstream documentation, existing OpenWrt projects and direct testing. The projects below are cited according to the concrete ideas they contributed or confirmed.

### Yggdrasil

```text
https://yggdrasil-network.github.io/
https://yggdrasil-network.github.io/configuration.html
https://github.com/yggdrasil-network/yggdrasil-go
https://github.com/yggdrasil-network/public-peers
```

Used for:

- Yggdrasil node/routed-subnet semantics;
- configuration and peer model;
- public peer discovery.

### Yggdrasil-OpenWrt

```text
https://yggdrasil-openwrt.github.io/openwrt-config-basic.html
```

Used for/confirmed:

- native OpenWrt Yggdrasil interface model;
- netifd/LuCI configuration;
- multicast peering;
- advertising a routed Yggdrasil subnet to LAN.

### Yggdrasil-Jumper

```text
https://github.com/one-d-wide/yggdrasil-jumper
```

Used for the optional direct-path/NAT-traversal optimization layer.

### AndreBL/ip6neigh

```text
https://github.com/AndreBL/ip6neigh
```

Concepts retained:

- SLAAC device/address association;
- predefined persistent hosts;
- distinction between preferred/stable and temporary addresses;
- persistent identity should survive runtime neighbour churn.

The final design does not install or copy the full `ip6neigh` daemon/cache/DAD/OUI/DDNS stack.

### OpenWrt-list-client-devices

```text
https://github.com/SimplyProgrammer/OpenWrt-list-client-devices
```

Concept retained:

- treat MAC as the stable device identity while DHCP/neighbor information is runtime context.

### luci-app-wechatpush

```text
https://github.com/tty228/luci-app-wechatpush
```

Concept retained:

- active `ping`/`arping` presence detection can be more accurate than passive cache state.

The full notification package is not required.

### internet-detector

```text
https://github.com/gSpotx2f/luci-app-internet-detector
```

Concept retained:

- availability checks may run only while the WebUI is open instead of requiring permanent monitoring.

### LuCI Poll API

```text
https://openwrt.github.io/luci/jsapi/LuCI.poll.html
```

Used directly by the final frontend for 15-second on-page refreshes.

### ha-openwrt

```text
https://github.com/FaserF/ha-openwrt
```

Independent architectural confirmation:

- multi-source DHCP + ARP/NDP device tracking;
- persistent identity/history separated from current presence.

It is not required by this guide.

### luci-app-wrtbwmon

```text
https://github.com/brvphoenix/luci-app-wrtbwmon
```

Independent architectural confirmation:

- host identity by MAC rather than changing IP;
- IPv6-aware client presentation.

It is not required by this guide.

### OpenWrt / odhcpd / dnsmasq / firewall4 / rpcd / LuCI

```text
https://openwrt.org/
https://github.com/openwrt/odhcpd
https://github.com/openwrt/luci
```

The final implementation intentionally uses the normal OpenWrt stack instead of adding parallel infrastructure.

### RFC 8375 - `home.arpa`

```text
https://datatracker.ietf.org/doc/html/rfc8375
```

Used for the local DNS namespace.

### What is original to this final synthesis

The exact combination in this README is not copied verbatim from any single source.

The final synthesis includes:

- standardized logical interface `ygg0` for clean installations;
- Yggdrasil routed `/64` selected with `ip6class 'ygg'`;
- SLAAC-only LAN profile with DHCPv6 disabled;
- OpenWrt-generated ULA removed for this profile;
- dedicated `ygg` firewall zone;
- trusted Ygg `/128` ACLs for LAN/router access;
- Jumper as an optional optimization;
- multicast peering for full local Yggdrasil nodes;
- dynamic rows from active DHCPv4 leases;
- persistent overlay from `config host`;
- dynamic and persistent sources merged by MAC;
- current SLAAC addresses from IPv6 neighbour state;
- optional canonical Ygg IPv6 from standard `config domain`;
- no `getHostHints` as authoritative LAN inventory;
- `Online = ARP OR any known Ygg IPv6`;
- one-shot rpcd backend;
- LuCI-only 15-second polling;
- green `Online` and red `Offline`;
- optional `home.arpa`/DNS-over-Ygg module;
- tested BusyBox-safe lowercase implementation using `tr 'A-Z' 'a-z'`.

---

## 21. Final state

### 21.1 Core only

A successful Part I installation ends with:

```text
OpenWrt
│
├── Yggdrasil ygg0
│   ├── stable node identity
│   ├── node address 2xx:...
│   ├── routed /64 3xx:...::/64
│   ├── public peers
│   ├── local multicast peering
│   └── optional Jumper
│
├── LAN br-lan
│   ├── DHCPv4 remains normal
│   ├── DHCPv6 disabled
│   ├── RA server enabled
│   ├── SLAAC enabled
│   └── Yggdrasil prefix class only
│
└── firewall4
    ├── zone ygg: INPUT REJECT
    ├── zone ygg: OUTPUT ACCEPT
    ├── zone ygg: FORWARD DROP
    ├── trusted Ygg /128 -> selected router access
    └── trusted Ygg /128 -> LAN
```

Ordinary LAN devices need only IPv6 support.

### 21.2 With optional Part II

```text
active DHCPv4 leases
├── dynamic devices
└── lifetime = DHCP lease
          │
          ├──────────────┐
          │              │
          ▼              ▼
     config host     ip -6 neigh
     persistent      current SLAAC
     overlay          addresses
          │              │
          └──────┬───────┘
                 │ merge by MAC
                 ▼
       optional config domain
       canonical Ygg IPv6 / name
                 │
                 ▼
         rpcd one-shot backend
                 │
                 ├── ARP probe
                 └── Ygg IPv6 probe(s)
                 │
                 ▼
        Status -> Yggdrasil
        ├── Online / Offline
        └── Persistence
            ├── Dynamic [Pin]
            ├── Pinned  [Unpin]
            ├── Persistent [Unpin]
            └── Static / protected [Manage]
```

A one-time guest is not permanently learned: it disappears when its DHCP lease expires. `Pin` promotes a device to a normal persistent `config host`; `Unpin` returns it to DHCP-lifetime behavior. Reserving the current IPv4 is optional and disabled by default. If a static reservation exists, `Manage` explicitly warns that deleting the host record also deletes that reserved IPv4. Shared multi-MAC, duplicate-MAC and complex host sections are never automatically removed.

No background monitor or custom garbage collector is added.

### 21.3 With optional Part III

```text
remote Ygg client
       │
       │ DNS query to router Ygg IPv6
       ▼
OpenWrt dnsmasq
       │
       └── host.home.arpa
              │
              ▼
        canonical 3xx:...
```

Client-side split DNS may route only `home.arpa` to OpenWrt while leaving normal Internet DNS untouched.

The essential property remains the same in every variant:

> **Yggdrasil runs on the router, while ordinary LAN devices receive and use the router's routed Yggdrasil `/64` through standard IPv6 RA/SLAAC.**

---

## 22. Maintainer / AI-agent handoff

This README is intentionally more than an end-user installation guide. It is also the long-form technical record of the final architecture.

For a new maintainer or AI agent, the distribution package also contains:

```text
AI_CONTEXT.md       compact authoritative architecture + rewrite contract
CHANGELOG.md        evolution from early prototypes through status v5
TEST_PLAN.md        regression matrix required before a new release
REFERENCE_CONFIG.md compact generalized UCI model
source/             unpacked v5 source code
packages/           ready-to-install v5 archive + checksum
MANIFEST.md         package inventory and hashes
```

### 22.1 Current implementation baseline

At this handoff point:

```text
Core network       working on real OpenWrt 25.12.5
Status module      v5
Dynamic inventory DHCPv4 lease lifetime
Persistent overlay config host
Runtime Ygg IPv6  stable-first selection from ip -6 neigh, merged by MAC
Canonical IPv6    optional config domain
Presence           ARP OR known Ygg IPv6 probe
Management         Pin / Unpin / protected Manage path
DNS                optional module
```

The current v5 module has been installed and verified on the real router.

### 22.2 The five rules that explain almost everything

```text
1. Every IPv6-capable LAN client may receive the routed Ygg /64 via RA/SLAAC.

2. DHCP lease = temporary memory.
   A dynamic device remains in the dashboard exactly while dnsmasq remembers
   its active DHCPv4 lease.

3. config host = persistence overlay.
   It does not define the whole LAN inventory; it keeps selected devices visible
   after their DHCP lease expires.

4. MAC = device identity.
   Canonical or modified EUI-64 IPv6 is preferred for display/probing; a
   privacy-only client may still have multiple rotating runtime addresses.

5. config domain = optional canonical Ygg IPv6 + home.arpa metadata.
   It is not required for SLAAC or dynamic discovery.
```

### 22.3 Status v5 state machine

```text
                    active DHCP lease
                           │
                           ▼
                    Dynamic [Pin]
                           │
                 Pin name + MAC
                           │
                           ▼
                    Pinned [Unpin]
                           │
                         Unpin
                           │
              ┌────────────┴────────────┐
              │                         │
       lease still active         no active lease
              │                         │
              ▼                         ▼
           Dynamic                    removed

Existing simple config host
        -> Persistent [Unpin]

Config host with fixed IPv4
        -> Static [Manage]
        -> explicit confirmation before removing reservation

Multi-MAC / duplicate-MAC / extra DHCP options
        -> Protected [Manage]
        -> status page refuses automatic deletion
```

### 22.4 Source-of-truth rules for a rewrite

If another agent rewrites the implementation, it should treat the following as invariants unless requirements explicitly change:

- do not require `config host` for a dynamic DHCP client to appear;
- do not persist every observed SLAAC/privacy IPv6;
- prefer canonical or observed modified EUI-64 addresses over historical privacy IIDs;
- do not use `getHostHints` or NUD state as authoritative inventory/presence;
- do not force EUI-64;
- do not switch the profile back to stateful DHCPv6 without a deliberate architecture change;
- do not add a background inventory daemon, cron job, database, or history cache merely to solve presence;
- do not silently delete `config domain` during Pin/Unpin;
- do not silently delete a static IPv4 reservation;
- do not delete multi-MAC, duplicate-MAC, or complex DHCP host sections automatically;
- do not overwrite pending uncommitted DHCP UCI edits;
- keep rollback around persistent DHCP mutations;
- keep DNS optional and separate from the routed-LAN core;
- keep the firewall deny-by-default and avoid blanket `ygg -> lan` forwarding;
- when documenting the tested DNS module, distinguish the actually tested zone-wide port-53 rule from optional `/128` hardening;
- use `ygg0` as the generalized documentation name, while accepting that an existing router may use a different logical interface name.

### 22.5 Code map

The optional v5 module consists of exactly four installed runtime files:

```text
/usr/libexec/rpcd/luci.yggdrasil-status
/usr/share/rpcd/acl.d/yggdrasil-status.json
/usr/share/luci/menu.d/yggdrasil-status.json
/www/luci-static/resources/view/status/yggdrasil.js
```

Its RPC object is:

```text
luci.yggdrasil-status
```

with methods:

```text
clients
pin
unpin
```

For the exact request/response schema, failure codes, rollback behavior, known limitations, and rewrite order, read `AI_CONTEXT.md` before changing the code.

### 22.6 Known edge cases a new agent must understand

- dynamic inventory is deliberately based on **active DHCPv4 leases**; an IPv6-only device with no DHCPv4 lease needs a new lifetime design if it must appear dynamically;
- `ip -6 neigh` is runtime enrichment only, so an address may temporarily disappear from the UI if the router no longer knows its MAC mapping;
- the current backend assumes one logical LAN (`network.lan`, normally `br-lan`);
- Ygg-prefix detection follows the netifd `proto=yggdrasil` interface and delegated `class=ygg`; multiple Ygg interfaces would require an explicit selection policy;
- renaming a persistent host does not automatically rename its independent `config domain` record;
- Unpin deliberately leaves `config domain` untouched;
- a rotating private Wi-Fi MAC is a new identity; an old dynamic MAC disappears with its DHCP lease, while an old pinned MAC remains until manually changed.

### 22.7 Release discipline

Do not call a future release finished after only `sh -n`.

At minimum test:

```text
DHCP-only client
expired guest lease
persistent client without lease
persistent + active lease merge
stable EUI-64 + privacy IPv6 selection
privacy-only multiple IPv6 fallback
canonical IPv6 precedence
hostname collision isolation
ARP / IPv6 presence fallbacks
Pin without IPv4
Pin with current IPv4
Unpin simple host
static reservation confirmation
multi-MAC protection
duplicate-MAC protection
complex-host protection
pending-UCI protection
DHCP rollback
installer rollback
ACL/menu JSON
frontend JavaScript
archive checksum
README/source consistency
```

The full matrix is in `TEST_PLAN.md`.

### 22.8 Minimal context for a new agent

If context budget is tight, provide the agent only these files, in this order:

```text
1. AI_CONTEXT.md
2. source/yggdrasil-status-v5/root/usr/libexec/rpcd/luci.yggdrasil-status
3. source/yggdrasil-status-v5/www/luci-static/resources/view/status/yggdrasil.js
4. source/yggdrasil-status-v5/root/usr/share/rpcd/acl.d/yggdrasil-status.json
5. source/yggdrasil-status-v5/root/usr/share/luci/menu.d/yggdrasil-status.json
6. TEST_PLAN.md
```

That set is sufficient to understand the current status implementation and rewrite it safely. Use this full README when changing the core network, DNS module, provenance, or installation guide.
