# AI_CONTEXT.md — OpenWrt + Yggdrasil routed LAN project handoff

This file is the compact **maintainer / AI-agent source of context** for the project documented in `README.md`.

Its purpose is to let another agent understand the design, safely modify it, or rewrite it from scratch **without needing the original long development chats**.

The human-facing guide remains `README.md`. The currently deployed optional LuCI status module is **v5**. Its code is included in this package and is the authoritative source for implementation details.

---

## 1. Current project status

Current state at handoff:

- core routed-Yggdrasil LAN architecture is working on a real OpenWrt 25.12.5 router;
- ordinary LAN clients receive the router's routed Yggdrasil `/64` through RA/SLAAC without running Yggdrasil themselves;
- DHCPv6 is intentionally disabled;
- the optional LuCI `Status -> Yggdrasil` module has evolved to **v5**;
- v5 was installed on the real router and its stable-first client inventory was verified against the live NDP table;
- v4 adds safe `Pin / Unpin` persistence management directly from the status page;
- the deployed v4 maintenance revision serializes DHCP mutations with `flock`, selects the Ygg prefix through netifd `class=ygg`, and avoids redundant probes for recently `REACHABLE` neighbors;
- v5 prevents historical privacy IID accumulation from flooding the dashboard: canonical metadata wins, otherwise an observed modified EUI-64 wins, while privacy-only clients retain multiple observed addresses;
- the DNS layer is optional and is not required for routing, SLAAC, firewalling, or the status page's dynamic discovery;
- the tested router now restricts DNS-over-Ygg to the same trusted source `/128` addresses used for administration, and a Linux client was validated with route-only `~home.arpa` split DNS;
- minor future UI/polish changes may still happen, but the architecture below should be treated as the current intended design.

Target platform used during development:

```text
OpenWrt 25.12+
apk
netifd
odhcpd
dnsmasq
firewall4 / nftables
rpcd
LuCI
```

The real tested router happened to use logical Yggdrasil interface name `ygg`. **Documentation standardizes new installations on `ygg0`**. This is a naming/generalization choice, not a different architecture.

---

## 2. Authority order

When documentation and code disagree, use this order:

1. **Current v5 source code** in `source/yggdrasil-status-v5/` for status-module behavior.
2. **This file (`AI_CONTEXT.md`)** for architecture, invariants, rationale, and rewrite constraints.
3. **`README.md`** for the full installation/user guide and upstream research history.
4. **`CHANGELOG.md`** for evolution of the design.
5. Historical ideas are context only; do not reintroduce them merely because they appeared earlier.

For network behavior, the final intended architecture in this handoff takes precedence over intermediate installers or old snapshots.

---

## 3. Top-level architecture

The system is intentionally split into three modules.

```text
PART I — CORE YGGDRASIL LAN
required

Yggdrasil on OpenWrt
        │
        ├── node address 2xx:...
        └── routed /64   3xx:...::/64
                         │
                         ▼
                      br-lan
                         │
                     odhcpd RA
                         │
                       SLAAC
                         │
                         ▼
              ordinary LAN devices
              get Ygg-routed IPv6
              without Yggdrasil daemon

PART II — OPTIONAL STATUS / INVENTORY

DHCPv4 leases + config host
          │
          ├── merge identity by MAC
          ├── ip -6 neigh = runtime SLAAC enrichment
          ├── config domain = optional canonical IPv6/DNS metadata
          └── active ARP/IPv6 probes = Online/Offline
                         │
                         ▼
                 Status -> Yggdrasil

PART III — OPTIONAL DNS

config domain
hostname.home.arpa -> canonical Ygg IPv6
          │
        dnsmasq
          │
 optional Ygg -> router TCP/UDP 53
          │
 client-side split DNS if desired
```

**Module boundaries are deliberate.** Part I works without Part II or Part III. Part II works without remote DNS access. Part III is a convenience layer.

---

## 4. Core network invariants

These are the key semantics that should not be changed casually.

### 4.1 One OpenWrt Yggdrasil router, ordinary or full-node LAN clients

The router runs Yggdrasil. Ordinary LAN devices do not need Yggdrasil installed.

Full Yggdrasil nodes may coexist on the LAN and use multicast peering. The
tested LAN includes a Linux laptop and an Android phone in this mode. Each has
two independent address roles:

```text
native Ygg TUN address -> its own 2xx: node identity / peer table
Wi-Fi SLAAC address    -> router's 3xx: routed /64 / LAN-client table
```

The status backend filters LAN addresses to the router's delegated
`class=ygg` prefix, so it does not confuse a full node's native address with an
RA/SLAAC address. Such clients may enable IPv6 forwarding and therefore appear
with the NDP `router` flag; inventory identity remains the MAC address.

The router receives:

```text
Ygg node address  -> 2xx:....
routed subnet     -> 3xx:....::/64
```

OpenWrt advertises that routed `/64` on LAN.

### 4.2 SLAAC, not stateful DHCPv6

Final model:

```text
network.lan.ip6assign = 64
network.lan.ip6class  = ygg

dhcp.lan.dhcpv6      = disabled
dhcp.lan.ra           = server
dhcp.lan.ra_slaac     = 1
dhcp.lan.ra_flags     = none
```

The client chooses its IPv6 interface identifier. It may use:

- EUI-64;
- stable privacy IID;
- temporary/privacy addresses;
- more than one address simultaneously.

Do **not** assume EUI-64 is universal.

### 4.3 Extra OpenWrt ULA removed in this profile

The chosen profile removes OpenWrt's automatically generated `fdxx:` ULA prefix so LAN clients do not receive an additional unrelated ULA from this router.

Link-local `fe80::/64` remains normal and required.

### 4.4 `ip6class='ygg'` matters

LAN should consume the Yggdrasil prefix class, not indiscriminately advertise every IPv6 prefix source.

### 4.5 Ygg firewall is deny-by-default

Dedicated zone concept:

```text
zone ygg
input   REJECT
output  ACCEPT
forward DROP
network ygg0
```

No NAT66 is needed for the routed `/64`.

Do **not** add blanket `ygg -> lan` forwarding. The tested design uses explicit source `/128` ACL rules for trusted remote Yggdrasil clients.

Router INPUT and forwarding to LAN are separate rules.

### 4.6 Jumper is optional optimization

The tested profile uses Yggdrasil Jumper, but base routed-LAN reachability must not depend on Jumper succeeding.

---

## 5. Status module v5 — intended data model

The status module is deliberately **dynamic first**, with persistence as an overlay.

### 5.1 Identity key

MAC address is the primary merge key for LAN client identity.

This avoids treating each new SLAAC/privacy IPv6 address as a new device.

### 5.2 Dynamic device lifetime

An active DHCPv4 lease creates a dynamic row.

```text
active /tmp/dhcp.leases entry
        │
        ▼
Dynamic row exists
        │
        ├── device answers probe -> Online
        └── no probe response    -> Offline

lease expires / disappears
        │
        ▼
Dynamic-only row disappears
```

There is **no additional history database, TTL, cron cleanup, or persistent runtime cache**.

DHCP's own lease lifetime is the garbage collector.

This was chosen specifically so a guest who connects once does not remain in the dashboard forever.

### 5.3 Persistent device lifetime

A normal OpenWrt `config host` creates a persistent identity.

```uci
config host
    option name 'Laptop'
    option mac 'AA:BB:CC:DD:EE:FF'
```

It does not need an IPv4 reservation.

Persistent behavior:

```text
config host exists
        │
        ├── active lease exists -> merge into same row
        └── no active lease     -> row remains, normally Offline
```

Thus:

```text
config host != list of all devices
config host  = persistence overlay / known infrastructure metadata
```

### 5.4 DHCP-only clients must appear

A client must **not** need a manually created `config host` to appear in `Status -> Yggdrasil`.

This requirement was discovered on the real network when:

- a Windows laptop had an active DHCPv4 lease and a valid Ygg/SLAAC IPv6;
- an iPhone had an active DHCPv4 lease and several Ygg/SLAAC privacy IPv6 addresses;
- both were missing from the older dashboard because only `config host` entries were enumerated.

v3/v4 corrected this by using active DHCP leases as the dynamic inventory source.

### 5.5 Runtime IPv6 is enrichment, not persistent inventory

Runtime Ygg/SLAAC addresses come from:

```sh
ip -6 neigh show dev <LAN_BRIDGE>
```

They are associated with a row by MAC.

They are never automatically written to UCI, a file, or a database.

Address selection for display and probing is stable-first:

```text
canonical config domain -> use only the canonical address
observed modified EUI-64 -> use only that stable address
privacy-only client      -> retain all observed addresses
```

This prevents historical privacy IIDs in the NDP table from flooding the UI
or being kept active by repeated status probes. It does not assign, deprecate,
or remove any client address. Privacy-only clients such as iOS devices may
still have several valid IPv6 addresses at once and rotate them later.

### 5.6 Canonical Ygg IPv6 is optional metadata

For a persistent host, a matching `config domain` may define one canonical address:

```uci
config domain
    option name 'laptop.home.arpa'
    option ip '303:....'
```

The status backend matches this by lowercased hostname:

```text
<config-host-name>.home.arpa
```

Canonical address rules:

- optional;
- only attached to a **persistent** host identity;
- displayed in bold in the IPv6 cell;
- added to the list of known IPv6 addresses for probing;
- does not assign SLAAC addresses;
- does not change runtime privacy addresses on the client;
- takes precedence over observed addresses in the status display and probe set;
- `Pin`/`Unpin` do not create/delete `config domain` records automatically.

The persistent-only condition prevents a DHCP-only client from claiming another device's canonical record merely by sending the same hostname.

### 5.7 Online/Offline is active presence, not NUD state

Do not interpret `REACHABLE`, `STALE`, or `FAILED` as the final Online state.

Final rule:

```text
ARP probe to current IPv4 succeeds
OR
IPv6 ping to any selected canonical/stable/observed Ygg address succeeds
        │
        ▼
Online

otherwise
        ▼
Offline
```

Current backend uses:

```sh
arping -I "$LAN_DEV" -c 1 -f -w 1 "$ipv4"
ping -6 -c 1 -W 1 "$ipv6"
```

`iputils-arping` is therefore a Part II dependency.

### 5.8 `getHostHints` is explicitly not authoritative

The old implementation relied on LuCI `getHostHints` / NDP-derived runtime observations. This failed conceptually because an NDP entry becoming `FAILED` could make a still-valid stable IPv6 disappear from the UI.

Final v5 inventory does **not** use `getHostHints` as its source of truth.

---

## 6. Pin / Unpin model in v5

The status page can convert a dynamic client into a persistent OpenWrt host record.

### 6.1 Pin

For a dynamic row:

```text
Dynamic [Pin]
```

Pin dialog asks for:

- hostname;
- optional `Reserve current IPv4` checkbox.

Default behavior is intentionally:

```text
reserve IPv4 = OFF
```

Pin without IPv4 creates:

```uci
config host 'ygg_status_<mac_without_colons>'
    option name '<hostname>'
    option mac '<normalized_mac>'
```

The section prefix is:

```text
ygg_status_
```

This lets the UI identify records created by itself (`managed_pin=1`).

### 6.2 Optional IPv4 reservation

If the checkbox is enabled, the backend **re-reads the active DHCP lease on the router** and uses that IPv4.

It does not trust an IPv4 value sent by the browser.

The created record becomes:

```uci
config host 'ygg_status_<mac>'
    option name '<hostname>'
    option mac '<mac>'
    option ip '<current_active_lease_ipv4>'
```

### 6.3 Unpin

Simple single-MAC host record with no extra unknown options can be removed from the status page.

After Unpin:

```text
if active DHCP lease remains
    -> row immediately becomes Dynamic
else
    -> row disappears
```

### 6.4 Static reservation confirmation

If the host record contains a static IPv4 reservation, the UI must not silently remove it.

The backend returns:

```text
static_confirmation_required
```

The UI then requires explicit confirmation for:

```text
Unpin and remove reservation
```

### 6.5 Protected host records

The status page refuses automatic deletion when it cannot prove deletion is safe.

Protected cases:

1. one `config host` contains multiple MAC addresses;
2. the same MAC appears in multiple `config host` sections;
3. the host section contains additional DHCP options beyond the small recognized set (`name`, `mac`, `ip`).

UI state becomes `Manage`, and the user is directed to standard:

```text
Network -> DHCP and DNS
```

This prevents the status page from deleting tags, DUID/hostid settings, or other unrelated DHCP policy.

### 6.6 Existing host records are legitimate

A persistent record does not need to have been created by this module.

States shown by the frontend:

```text
Dynamic      -> no config host; [Pin]
Pinned       -> config host created by this module; [Unpin]
Persistent   -> simple existing config host; [Unpin]
Static       -> persistent host with IPv4 reservation; [Manage] / confirmation path
Protected    -> multi-MAC / duplicate / complex; [Manage]
```

---

## 7. Status module file map

Installed files:

```text
/usr/libexec/rpcd/luci.yggdrasil-status
/usr/share/rpcd/acl.d/yggdrasil-status.json
/usr/share/luci/menu.d/yggdrasil-status.json
/www/luci-static/resources/view/status/yggdrasil.js
```

Package tree in this handoff:

```text
source/yggdrasil-status-v5/
├── install.sh
├── README.md
├── root/
│   ├── usr/libexec/rpcd/luci.yggdrasil-status
│   ├── usr/share/rpcd/acl.d/yggdrasil-status.json
│   └── usr/share/luci/menu.d/yggdrasil-status.json
└── www/luci-static/resources/view/status/yggdrasil.js
```

### Backend

Language:

```text
BusyBox /bin/sh (ash)
OpenWrt /lib/functions.sh
libubox jshn
UCI
```

Responsibilities:

- enumerate active DHCPv4 leases;
- enumerate persistent `config host` records;
- merge by MAC;
- enrich with stable-first runtime Ygg/SLAAC IPv6 neighbors;
- attach optional canonical `config domain` metadata;
- actively probe presence;
- expose RPC `clients`, `pin`, `unpin`;
- perform safe UCI mutations for Pin/Unpin.

### Frontend

Language/API:

```text
LuCI JavaScript view
rpc
uci
poll
ui
```

Responsibilities:

- Node table;
- Peer table;
- LAN clients table;
- IPv6 address list with canonical address bolded;
- Online/Offline colors;
- Persistence state;
- Pin dialog;
- Unpin/static-confirmation dialogs;
- protected-host explanation;
- 15-second refresh while the page is open.

There is no background poll when the page is closed.

---

## 8. RPC contract

rpcd object:

```text
luci.yggdrasil-status
```

Methods:

```text
clients
pin
unpin
```

`list` signature emitted by backend:

```json
{
  "clients": {},
  "pin": {
    "mac": "",
    "name": "",
    "reserve_ipv4": false
  },
  "unpin": {
    "mac": "",
    "confirm_static": false
  }
}
```

### 8.1 `clients` response fields

Each client object currently contains:

```text
hostname          string
mac               string
ipv4              string
ipv6              string          primary display IPv6
canonical_ipv6    string          optional canonical record
ipv6_addresses    array[string]   stable-first selected runtime set
DNS               exposed as field `dns`
online            0/1
persistent        0/1
static_ipv4       0/1
reserved_ipv4     string
managed_pin       0/1
shared_host       0/1
complex_host      0/1
ambiguous_host    0/1
protected_host    0/1
lease_expiry      string
```

Actual JSON key is lowercase:

```text
dns
```

### 8.2 `pin` request

```json
{
  "mac": "aa:bb:cc:dd:ee:ff",
  "name": "Laptop",
  "reserve_ipv4": false
}
```

Important result/error codes currently used:

```text
pinned
already_persistent
invalid_request
invalid_mac
no_active_lease
invalid_hostname
no_ipv4
pending_uci_changes
section_collision
backup_failed
uci_failed
reload_failed
```

### 8.3 `unpin` request

```json
{
  "mac": "aa:bb:cc:dd:ee:ff",
  "confirm_static": false
}
```

Important result/error codes:

```text
unpinned
already_dynamic
static_confirmation_required
ambiguous_host
shared_host
complex_host
pending_uci_changes
backup_failed
uci_failed
reload_failed
```

If changing the RPC schema, update backend, ACL, frontend, README, AI_CONTEXT, tests, and installer validation together.

---

## 9. UCI mutation and rollback safety

Pin/Unpin are allowed to modify `/etc/config/dhcp`, so safety is important.

Current backend behavior:

1. acquire an exclusive `flock` shared by Pin and Unpin;
2. refuse mutation if `uci changes dhcp` is non-empty;
3. copy `/etc/config/dhcp` to a temporary backup;
4. apply UCI mutation;
5. `uci commit dhcp`;
6. reload `dnsmasq`;
7. on commit/reload failure, restore previous DHCP file and reload again;
8. remove temporary backup after successful completion.

The installer independently backs up the old status module files under:

```text
/root/yggdrasil-status-backup-YYYYMMDD-HHMMSS
```

Installer changes only the optional LuCI/rpcd module and may install `iputils-arping` if missing.

Installer intentionally does **not**:

```text
reload network
restart firewall
restart Yggdrasil
restart odhcpd
change routing
change Ygg firewall ACLs
```

It restarts only `rpcd` after replacing the module files.

This matters because the router may be managed remotely over Yggdrasil.

---

## 10. Optional DNS module

DNS is a separate convenience module.

The core routed LAN works without it.

### 10.1 Why `config domain` is shared with status metadata

OpenWrt already supports:

```uci
config domain
    option name 'host.home.arpa'
    option ip '303:....'
```

Using this avoids:

- a custom DNS daemon;
- a separate database;
- a custom hosts-file generator;
- cron synchronization;
- duplicate canonical-address storage.

Therefore one record can serve two roles:

```text
persistent canonical Ygg IPv6 metadata for status
+
standard dnsmasq DNS record
```

DNS as a **network service** is still optional.

### 10.2 Namespace

Use:

```text
home.arpa
```

not `.lan` for the designed private home namespace.

### 10.3 Tested remote DNS firewall behavior

The current tested DNS-over-Ygg rule allows TCP/UDP port 53 only from the
trusted Ygg `/128` addresses already authorized for administration/LAN access.

Generalized tested behavior:

```uci
config rule 'ygg_dns'
    option name 'Allow-DNS-from-Trusted-Yggdrasil'
    option src 'ygg'
    option proto 'tcp udp'
    option dest_port '53'
    list src_ip '<TRUSTED_YGG_IPV6_1>'
    list src_ip '<TRUSTED_YGG_IPV6_2>'
    option target 'ACCEPT'
```

### 10.4 Client split DNS is out of core scope

A remote client may configure a split resolver for `home.arpa` pointing to the OpenWrt Ygg node address.

The tested Linux client uses `systemd-resolved`. Yggdrasil has a fixed
`IfName: ygg0`, and a systemd drop-in applies the router node address plus the
route-only domain `~home.arpa` after Yggdrasil creates the interface. Wi-Fi
remains the default DNS route.

Do not persist an externally assumed Ygg TUN as a NetworkManager TUN profile.
NetworkManager may then create an empty persistent `tun0` before Yggdrasil at
boot, forcing Yggdrasil onto `tun1` while DNS remains attached to dead `tun0`.
Putting the router second in plain `resolv.conf` is not equivalent: resolver
ordering is failover, not suffix routing.

This is a client-side concern and must not be bundled into the OpenWrt routing core.

In particular, previous Android work intentionally preserved Android's normal DNS stack rather than replacing it with a custom dnsmasq/CoreDNS/unbound service.

---

## 11. Development history — important lessons

The final architecture came from several iterations. These rejected approaches should stay rejected unless a new requirement justifies reopening them.

### 11.1 `getHostHints`-only inventory — rejected

Problem:

```text
NDP entry becomes FAILED / disappears
        │
        ▼
getHostHints loses IPv6
        │
        ▼
UI incorrectly loses device/address
```

Real testing showed that a direct probe could repopulate the same stable IPv6 later. Therefore transient neighbor state is not authoritative persistent identity.

### 11.2 Separate `/etc/config/yggdrasil-status` inventory — considered, removed

It would work, but duplicated state already representable by native OpenWrt UCI.

Final design instead uses:

```text
config host   -> persistence / hostname / MAC / optional static IPv4
config domain -> optional canonical IPv6 / DNS alias
DHCP lease    -> dynamic lifetime
neighbors     -> runtime IPv6 enrichment
```

### 11.3 Custom `option ygg_ipv6` in `config host` — considered, removed

Rejected in favor of standard `config domain` for canonical address metadata.

### 11.4 Mandatory EUI-64 — rejected

Some devices naturally use EUI-64. Others use stable privacy or rotating addresses. OpenWrt RA advertises the prefix; the client chooses the IID.

Final requirement is not “must be EUI-64”. It is only:

> if a device needs a canonical persistent Ygg address, explicitly record one stable address.

### 11.5 Stateful DHCPv6 — considered, rejected

`odhcpd` can do stateful DHCPv6/static host IDs, but the target architecture intentionally uses SLAAC for broader client compatibility and alignment with routed Ygg `/64` behavior.

### 11.6 `.lan` — replaced with `home.arpa`

`home.arpa` is the intended home-network namespace.

### 11.7 Passive NUD state as Online — rejected

`STALE` may be healthy. `FAILED` may be transient. Use active probes.

### 11.8 Permanent monitoring daemon — rejected

The dashboard should check only while the page is open. No daemon/cron/DB is needed.

---

## 12. Upstream/project influences

The complete discussion and links are in `README.md`, section “Where the design came from”. Key influences:

### Yggdrasil / Yggdrasil-OpenWrt

Provided the native routed `/64` and OpenWrt integration model.

### Yggdrasil-Jumper

Optional path optimization used by the tested profile.

### AndreBL/ip6neigh

Most important conceptual LAN-inventory influence:

- persistent/predefined identity must be separate from transient NDP observations;
- native `/etc/config/dhcp` is a useful known-host source;
- privacy addresses should not replace canonical identity;
- active probing is useful.

Not copied:

- permanent neighbor-monitor service;
- tcpdump DAD snooping;
- own cache;
- vendor DB;
- EUI-64 guessing;
- custom hosts file;
- DDNS/firewall machinery.

### OpenWrt-list-client-devices

Reinforced MAC-centric device identity and combining runtime DHCP/neighbor information around one device.

### luci-app-wechatpush

Reinforced active `arping`/ping presence checks rather than trusting passive cache state.

### luci-app-internet-detector + LuCI Poll API

Reinforced one-shot rpcd checks with polling only while the LuCI page is open.

### ha-openwrt / wrtbwmon

Independent confirmation of separating identity/history from current runtime presence and of MAC-centric device grouping. They are not direct implementation dependencies.

---

## 13. Implementation bugs already found and fixed

Do not accidentally reintroduce these during rewrite.

### 13.1 BusyBox lowercase portability

This failed on the real OpenWrt/BusyBox environment:

```sh
tr '[:upper:]' '[:lower:]'
```

The final backend uses:

```sh
tr 'A-Z' 'a-z'
```

This was necessary for matching names such as mixed-case hostnames to lowercase `home.arpa` records.

### 13.2 BusyBox ash variable scope issue

During v4 development, a helper-function arrangement allowed a variable such as `mac` to be overwritten because `ash` shell functions share dynamically scoped variables unless carefully localized.

The code was simplified to remove that fragile path.

When rewriting shell code:

- use distinctive local variable prefixes;
- declare locals in every helper;
- do not assume lexical scoping.

### 13.3 IPv4 validation test bug

An intermediate `awk` form could incorrectly report success due to how exit status was handled. Current `valid_ipv4()` was corrected and should be covered by tests.

### 13.4 Anonymous UCI sections

OpenWrt `config host` sections may be anonymous and addressed as `@host[n]` during enumeration. Code must operate on the actual section identifier/selector it receives from OpenWrt helpers and must not assume every section has a friendly explicit name.

### 13.5 Dynamic hostname must not inherit canonical DNS metadata

DHCP hostnames are client-controlled. Attaching `config domain` solely by hostname to a dynamic client would allow accidental/colliding canonical metadata.

Current code only attaches canonical `config domain` records when a matching persistent `config host` exists.

---

## 14. Known limitations / future improvement candidates

These are not necessarily bugs, but a future agent should know them before redesigning.

### 14.1 Dynamic inventory is DHCPv4-based

A dynamic row is born from an active DHCPv4 lease.

A pure IPv6-only client with no DHCPv4 lease and no persistent `config host` will not become a dynamic row merely because an NDP entry exists.

This is intentional for the current network because DHCP lease lifetime is the chosen garbage-collection policy. If IPv6-only dynamic clients become a requirement, a separate lifetime model will be needed.

### 14.2 Runtime IPv6 visibility depends on current neighbor knowledge

A client may still own a valid SLAAC address even if the router currently has no `lladdr` mapping for it in `ip -6 neigh`.

For persistent hosts, a canonical `config domain` can still keep the known address visible. Dynamic-only runtime addresses may temporarily disappear from the row until neighbor discovery sees them again.

When no canonical record exists, v5 prefers an observed modified EUI-64 and
hides the other privacy IIDs for that row. A privacy-only client has no
protocol-visible stable/temporary distinction in NDP, so all of its observed
addresses remain eligible.

Do not “fix” this by permanently storing every observed privacy address.

### 14.3 Multiple LAN prefixes

The backend resolves the logical netifd interface whose protocol is
`yggdrasil`, then selects its delegated prefix with `class=ygg`. It therefore
does not depend on the Ygg prefix being the first global `/64` on `br-lan`.

Multiple Yggdrasil interfaces or multiple `class=ygg` prefixes would still
require an explicit interface-selection policy.

### 14.4 One logical LAN inventory

Backend constants currently assume:

```text
LAN_NET='lan'
LAN bridge from network.lan.device, fallback br-lan
```

Multi-LAN/VLAN support would require explicit design rather than simply looping over interfaces.

### 14.5 Hostname rules are intentionally simple

Pin accepts a single DNS-label hostname, 1–63 characters, letters/digits/hyphens, no leading/trailing hyphen.

### 14.6 `config domain` can become orphaned

Unpin deliberately leaves `config domain` untouched because DNS/canonical metadata is a separate module and destructive cross-module cleanup would be surprising.

If a user later wants “remove device completely”, implement that as a separate explicit action with confirmation.

### 14.7 Rename semantics

Canonical lookup is hostname-based. If a persistent `config host` is renamed but its `config domain` is not updated, canonical metadata will no longer match.

Do not silently rewrite DNS records unless the UI explicitly offers that operation.

### 14.8 Randomized Wi-Fi MACs

If a client rotates its private/random Wi-Fi MAC, it is a new identity from this module's perspective. The old dynamic identity disappears naturally when its old DHCP lease expires. A pinned old MAC remains persistent until manually changed/unpinned.

### 14.9 Presence probes can be policy-sensitive

Some hosts may block IPv6 echo. IPv4 ARP is attempted first when IPv4 is known. A host that neither answers ARP nor any known IPv6 ping will show Offline even if some application-specific connectivity exists.

If presence semantics are expanded later, keep active testing explicit and avoid mapping NUD state directly to Online.

---

## 15. Rewrite contract for another agent

If you need to rewrite the implementation, preserve these semantics unless the user explicitly changes them.

### Must preserve

1. Ordinary LAN clients get routed Ygg IPv6 through RA/SLAAC.
2. DHCPv6 remains disabled in the current profile.
3. Dynamic rows live exactly as long as their active DHCPv4 lease.
4. Persistent `config host` rows survive lease expiry.
5. Identity is merged by MAC.
6. Runtime SLAAC/privacy addresses are not persisted automatically.
7. Canonical metadata takes precedence; otherwise an observed modified EUI-64 takes precedence; privacy-only clients retain multiple observed addresses.
8. Canonical address/DNS metadata is optional.
9. Dynamic hostnames cannot inherit canonical metadata without persistent identity.
10. Online state is active probe based.
11. No background daemon, cron, DB, or runtime history cache unless a new requirement clearly needs one.
12. Pin defaults to **no IPv4 reservation**.
13. Static IPv4 reservation deletion requires explicit confirmation.
14. Multi-MAC, duplicate-MAC, and complex host sections are protected from automatic deletion.
15. Pin/Unpin must refuse to overwrite existing pending DHCP UCI edits.
16. DHCP config mutation must have rollback behavior.
17. `config domain` is never silently deleted by Pin/Unpin.
18. Status-module installation must not casually reload network/firewall/Yggdrasil on a remotely managed router.
19. DNS remains optional and separate from core routing.
20. Do not silently replace tested firewall behavior with a different security policy in documentation; label hardening variants as optional.
21. New documentation should use `ygg0` as the canonical interface name while noting existing deployments may use another logical name.
22. Keep native full-node Ygg addresses separate from router-prefix LAN SLAAC addresses in status semantics and documentation.

### Prefer to preserve

- native OpenWrt UCI rather than a custom inventory database;
- BusyBox-compatible shell;
- rpcd + LuCI native mechanisms;
- 15-second page-open polling;
- minimal package dependencies;
- one contiguous copy/paste block when giving the user a sequence of terminal commands.

---

## 16. If rewriting from scratch

Recommended order:

1. Read `README.md` sections 2, 5, 13, 14, 16, 17.
2. Read this file fully.
3. Read backend source first.
4. Write down the intended client object schema before coding.
5. Implement pure read-only `clients` behavior first.
6. Test dynamic/persistent merge and lifetime.
7. Add canonical/runtime IPv6 enrichment.
8. Add active probing.
9. Add Pin without static IPv4.
10. Add optional IPv4 reservation.
11. Add Unpin safety guards.
12. Add UCI backup/rollback.
13. Only then implement the LuCI dialogs.
14. Keep ACL write permissions limited to `pin`/`unpin`.
15. Run the full `TEST_PLAN.md` before packaging.
16. Update README + AI_CONTEXT + CHANGELOG together.
17. Install on router only after local/synthetic validation.
18. On remote router upgrades, avoid network/firewall restart unless the change truly requires it.

---

## 17. Mandatory release checks

Before calling a new revision “final”:

```text
backend shell syntax
BusyBox shell compatibility
ACL JSON validity
menu JSON validity
frontend JavaScript syntax
RPC list signature
clients fixture tests
DHCP lease expiry behavior
persistent offline behavior
stable EUI-64 + privacy selection
multi-address privacy-only client
canonical IPv6 precedence
Pin without IPv4
Pin with IPv4
Unpin simple host
static confirmation
multi-MAC protection
duplicate-MAC protection
complex-host protection
pending UCI changes protection
rollback on commit/reload failure
installer backup/rollback
README/source consistency
archive integrity
checksums
```

See `TEST_PLAN.md` for the detailed matrix.

---

## 18. Interaction / operational constraints for this project

When assisting the user with this router:

- assume remote access may be through Yggdrasil;
- avoid broad firewall edits;
- avoid restarting `network`, firewall, Yggdrasil, or odhcpd during a UI-only update;
- back up before changing persistent configuration;
- distinguish the Yggdrasil logical interface from unrelated VPN/TUN interfaces;
- give sequential terminal commands as **one contiguous copy/paste block**;
- do not introduce a custom DNS daemon unless the user explicitly asks for a new architecture;
- do not bundle Android client DNS changes into the OpenWrt core design.

---

## 19. Quick mental model

If you remember only one block, remember this:

```text
CORE
Ygg routed /64 -> br-lan -> RA/SLAAC -> every IPv6-capable LAN client

STATUS
DHCP lease     -> temporary row / DHCP lifetime is garbage collection
config host    -> persistent row
MAC            -> identity merge key
ip -6 neigh    -> current SLAAC/privacy addresses only
config domain  -> optional canonical Ygg IPv6 + home.arpa metadata
ARP OR IPv6 ping -> Online

MANAGEMENT
Dynamic   [Pin]
Pinned    [Unpin]
Static    [Manage + explicit destructive confirmation]
Complex/shared/duplicate config host -> protected / manual DHCP UI

DNS
optional; core routing does not need it
home.arpa via native dnsmasq
remote port 53 rule is a separate module

ANTI-GOALS
no getHostHints authority
no forced EUI-64
no stateful DHCPv6
no custom inventory DB
no daemon/cron/history cache
no blanket ygg -> lan forwarding
```

That is the essence of the current system.
