# Architecture and contracts

This is the canonical description of current behavior and design decisions.
Use [installation](installation.md) for commands, [operations](operations.md)
for recovery, and [development](development.md) for verification. History is
context, not an instruction to restore an abandoned approach.

## Module boundaries

```text
Core:    Yggdrasil -> netifd delegated /64 -> LAN -> odhcpd RA/SLAAC
Status:  DHCP leases + config host -> MAC identity -> NDP/canonical IPv6 -> RPC -> LuCI
DNS:     config domain -> dnsmasq -> optional trusted remote port 53 -> split DNS
```

Core routing does not depend on status, DNS or Jumper. Status does not require
remote DNS access. `config domain` is intentionally shared metadata: it can
provide a canonical address for status and a native DNS record without a
second database. The automated default deploy enables status, DNS, Jumper and
LAN multicast; each is separately skippable. Optional means independent, not
necessarily disabled by default.

The profile targets OpenWrt 25.12+ with apk, netifd, odhcpd, dnsmasq and
firewall4. Status uses rpcd, LuCI, UCI, libubox jshn, BusyBox ash, flock and
iputils-arping. Host-side Python/Node tooling is not a router dependency.

## Core network

The router's private key determines its Yggdrasil identity, node address and
routed subnet. Preserve it across reinstalls or hardware migration. A node has
a native `2xx:` address and routes a `3xx:...::/64`; ordinary LAN clients use
that routed prefix without a local Yggdrasil daemon.

Full Yggdrasil nodes may coexist on the LAN and multicast-peer with the router.
Their native TUN/node address belongs in the peer table; their router-prefix
Wi-Fi/Ethernet SLAAC address belongs in the LAN table. An NDP `router` flag does
not change the MAC identity or create another device.

The current clean-install interface name is `ygg0`; older deployments used
`ygg`. netifd derives a delegated prefix's class from its providing interface
name. LAN `ip6class` must match that class. Setting `ip6class` on the Yggdrasil
interface does not rename its published class. A mismatch can silently leave
LAN without the routed prefix.

LAN uses RA/SLAAC, not stateful DHCPv6. The client selects its IID and may use
EUI-64, stable privacy, temporary addresses or several simultaneously. The
router does not force an IID. This profile removes OpenWrt's generated ULA;
link-local IPv6 and normal DHCPv4 remain. Keeping an additional ULA is a
separate deliberately documented profile, not a silent default change.

A dedicated `ygg` firewall zone is deny-by-default: INPUT REJECT, OUTPUT ACCEPT,
FORWARD DROP. There is no NAT66 or blanket forwarding in either direction.
Explicit trusted source `/128` rules authorize forwarding to LAN separately
from router INPUT. The tested router rule permits TCP from trusted sources;
it is not restricted to ports 22/80/443. Restricting ports further is optional
hardening, not the current default. Trusted DNS permits TCP/UDP 53 separately.

## Inventory data model

| Source | Role | Lifetime and authority |
| --- | --- | --- |
| Active `/tmp/dhcp.leases` entry | Dynamic identity, current IPv4 and hostname | Until lease expires/disappears; expiry `0` means unlimited |
| `/etc/config/dhcp` `config host` | Persistent identity and optional reservation | Until explicit removal; may exist without a lease or IPv4 reservation |
| Kernel `ip -6 neigh` | Observed IPv6 enrichment matched by MAC | Runtime only; never creates persistence or extends row lifetime |
| `config domain` | Optional canonical IPv6 and DNS name | Persistent metadata for an existing persistent identity |
| Recent reachability / active probes | Online/Offline | A presence result, independent of identity lifetime |

Merge by normalized MAC, not IP. Emit each MAC once. For a matching persistent
host, its name overrides the DHCP hostname and a valid configured static IPv4
overrides the current lease IPv4. A dynamic lease does not require `config
host`. Expired leases are ignored even if still present in the lease file.
Persistent hosts without a lease remain visible, normally Offline unless a
known address answers.

A randomized Wi-Fi MAC is a new identity. Its previous dynamic identity expires
with its old lease; an explicitly pinned old MAC remains until changed/unpinned.
A pure IPv6-only client without DHCPv4 or `config host` is not discovered as a
dynamic row. That is the consequence of the chosen DHCP lifetime model, not a
reason to silently turn NDP into a permanent inventory.

### IPv6 selection

The backend selects the first configured interface with `proto=yggdrasil`,
reads that interface's delegated prefix matching its class, and falls back to
its first published prefix. It does not choose an arbitrary global LAN `/64`.
The v5.1 fix removed the assumption that the interface must be named `ygg`.

For a persistent host, canonical metadata is matched case-insensitively by
`<config-host-name>.home.arpa`. A DHCP-only client cannot claim another host's
canonical record by sending the same hostname. A canonical record records an
address the client already uses; it does not assign or stabilize SLAAC.

Display and probing use the same selected set:

```text
canonical config domain present -> canonical address only
otherwise observed modified EUI-64 -> that address only
otherwise -> all unique observed addresses for that MAC in the Ygg prefix
```

The computed EUI-64 must actually be observed. Never invent an address merely
from a MAC. The canonical address is the primary IPv6 and rendered in bold;
otherwise the first selected address is primary. Runtime addresses are not
written to UCI, files, caches or a database.

This stable-first policy avoids repeatedly displaying/probing historical
privacy IIDs when a stable address is available. It does not remove addresses
from clients or force every privacy-only client down to one address. The full
[SLAAC incident report](history/slaac-address-fix.md) is preserved separately.

### Presence

Current implementation order in `probe_online()`:

1. A selected IPv4/IPv6 neighbor with kernel NUD `REACHABLE` means Online
   without another probe (a recent kernel-confirmed success).
2. Otherwise, try IPv4 `arping -I "$LAN_DEV" -c 1 -f -w 1` when IPv4 is known.
3. If needed, try `ping -6 -c 1 -W 1` against selected IPv6 addresses.
4. No success means Offline.

`STALE`, `DELAY`, `PROBE`, `FAILED` or missing NDP entries are not an Online or
Offline verdict by themselves. Row existence still depends on DHCP/UCI, not
presence. A host may block probes while an application remains accessible.
Online is not a guarantee about a particular application service.

Earlier prose said not to map *any* NUD state to Online; that omitted the
intentional `REACHABLE` optimization. The contract above matches the existing
code; the documentation cleanup did not change the algorithm.

### Pin and Unpin

| State | Meaning | Action |
| --- | --- | --- |
| Dynamic | Lease only | Pin |
| Pinned | Host section created by this module | Unpin |
| Persistent | Existing simple native host section | Unpin |
| Static | Host has a valid IPv4 reservation | Manage, then explicit destructive confirmation |
| Protected | Shared MAC section, duplicate identity or unknown host options | Manage in standard DHCP UI, never delete automatically |

Pin creates `config host 'ygg_status_<mac_without_colons>'` with a validated
hostname and normalized MAC. `Reserve current IPv4` defaults to **off**. When
requested, the backend rereads and validates the active lease; it does not
trust an IPv4 supplied by the browser. No active lease means no Pin mutation.
Existing persistent identities are not duplicated.

Unpin removes only a simple single-MAC host section. A static reservation
requires `confirm_static=true`; removing that section also removes its
reservation. Multiple MACs, duplicate sections for one MAC, or options beyond
`name`, `mac`, `ip` prevent automatic deletion. Both named and anonymous UCI
sections must work. An active lease leaves a formerly pinned row Dynamic;
without a lease it disappears. Neither operation deletes `config domain`.

Persistent mutations acquire `/var/lock/yggdrasil-status-dhcp.lock` using
exclusive nonblocking flock, refuse pending DHCP UCI edits, back up the DHCP
file, mutate, commit and reload dnsmasq. On reported failure the code attempts
to restore the backup and reload. This is not a guarantee against power loss
or every external concurrent writer. A shared read lock coordinates inventory
with this module's mutations. A concurrent Pin/Unpin returns `busy`.

## RPC and installed files

The rpcd object is `luci.yggdrasil-status`:

```json
{"clients":{},"pin":{"mac":"","name":"","reserve_ipv4":false},"unpin":{"mac":"","confirm_static":false}}
```

`clients` returns an object containing `clients`, an array of objects:

| Field | Type / meaning |
| --- | --- |
| `hostname`, `mac`, `ipv4` | Strings; identity and selected IPv4 |
| `ipv6` | String; primary selected IPv6 |
| `canonical_ipv6` | String; empty when absent |
| `ipv6_addresses` | Array of strings; stable-first selected set |
| `dns` | String; lowercase JSON key, optional canonical DNS alias |
| `online`, `persistent`, `static_ipv4` | Integer 0/1 flags |
| `reserved_ipv4` | String; configured valid reservation or empty |
| `managed_pin`, `shared_host`, `complex_host`, `ambiguous_host`, `protected_host` | Integer 0/1 flags |
| `lease_expiry` | String; lease timestamp, empty for a lease-free persistent row |

Mutations return integer `ok`, string `code` and `message`; device replies
also contain `mac`, `hostname`, `reserved_ipv4`. Do not silently change these
types to booleans/numbers when refactoring.

Pin outcomes: `pinned`, `already_persistent`, `invalid_request`, `invalid_mac`,
`busy`, `no_active_lease`, `invalid_hostname`, `no_ipv4`, `pending_uci_changes`,
`section_collision`, `backup_failed`, `uci_failed`, `reload_failed`.

Unpin outcomes: `unpinned`, `already_dynamic`, `invalid_request`, `invalid_mac`,
`busy`, `static_confirmation_required`, `ambiguous_host`, `shared_host`,
`complex_host`, `pending_uci_changes`, `backup_failed`, `uci_failed`,
`reload_failed`.

| Source relative to `source/yggdrasil-status/` | Installed path |
| --- | --- |
| `root/usr/libexec/rpcd/luci.yggdrasil-status` | `/usr/libexec/rpcd/luci.yggdrasil-status` |
| `root/usr/share/rpcd/acl.d/yggdrasil-status.json` | `/usr/share/rpcd/acl.d/yggdrasil-status.json` |
| `root/usr/share/luci/menu.d/yggdrasil-status.json` | `/usr/share/luci/menu.d/yggdrasil-status.json` |
| `www/luci-static/resources/view/status/yggdrasil.js` | `/www/luci-static/resources/view/status/yggdrasil.js` |

The backend is a one-shot rpcd program, not a daemon. The frontend renders
node, peer and client tables; it refreshes clients every 15 seconds while the
page is open. Pin/Unpin errors are shown to the user, not hidden as successful
changes. ACL writes are limited to the mutation methods. A schema change must
update backend, frontend, ACL where relevant, installer validation, tests and
this contract together; do not embed full source copies in Markdown.

The module installer backs up these four files, installs iputils-arping if
needed, checks shell syntax, restarts rpcd and validates the object/methods
and nonempty clients result. Its rollback restores prior module files. It does
not restart network/firewall/Yggdrasil/odhcpd or alter their configuration.
It is separate from the whole-network deployer and does not provide a fully
transactional package-manager rollback.

## Expected configuration

These are excerpts, not complete replacement configuration files. Preserve
site-specific IPv4, wireless and other unrelated settings. Placeholders must
be replaced deliberately. Commands belong in [installation](installation.md).

```uci
# /etc/config/network
config interface 'ygg0'
    option proto 'yggdrasil'
    option private_key '<PRIVATE_KEY>'
    option public_key '<PUBLIC_KEY>'
    option jumper_enable '1'
    option jumper_loglevel 'info'
    option allocate_listen_addresses '1'
    option jumper_autofill_listen_addresses '1'
    option multipath 'off'

config yggdrasil_ygg0_peer
    option address '<CURRENT_PEER_URI>'

config yggdrasil_ygg0_interface
    list interface 'br-lan'
    option beacon '1'
    option listen '1'

config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    list ipaddr '<LAN_IPV4/CIDR>'
    option ip6assign '64'
    list ip6class 'ygg0'
# network.globals.ula_prefix is absent in this profile.

# /etc/config/dhcp (DHCPv4 start/limit/leasetime remain site-specific)
config dhcp 'lan'
    option interface 'lan'
    option dhcpv4 'server'
    option dhcpv6 'disabled'
    option ra 'server'
    option ra_default '2'
    option ra_preference 'medium'
    option ra_slaac '1'
    list ra_flags 'none'

config host 'ygg_status_aabbccddeeff'
    option name 'Laptop'
    option mac 'aa:bb:cc:dd:ee:ff'
    # Optional, only for a deliberate IPv4 reservation:
    # option ip '192.168.1.143'

config domain
    option name 'laptop.home.arpa'
    option ip '<STABLE_YGG_ROUTED_IPV6>'
# Add list server '/home.arpa/' to the existing dnsmasq section for DNS.
```

```uci
# /etc/config/firewall
config zone
    option name 'ygg'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'DROP'
    list network 'ygg0'

config rule
    option name 'YGG-Trusted-to-LAN'
    option src 'ygg'
    option dest 'lan'
    option family 'ipv6'
    list proto 'all'
    list src_ip '<TRUSTED_YGG_IPV6>'
    option target 'ACCEPT'

config rule
    option name 'YGG-Trusted-to-Router'
    option src 'ygg'
    option family 'ipv6'
    list proto 'tcp'
    list src_ip '<TRUSTED_YGG_IPV6>'
    option target 'ACCEPT'

config rule 'ygg_dns'
    option name 'Allow-DNS-from-Trusted-Yggdrasil'
    option src 'ygg'
    option proto 'tcp udp'
    option dest_port '53'
    list src_ip '<TRUSTED_YGG_IPV6>'
    option target 'ACCEPT'
```

## Decisions and rejected alternatives

| Decision | Reason and consequence |
| --- | --- |
| Native netifd/UCI/odhcpd/firewall4 | One owner for routing, prefix advertisement and policy; no container or parallel network manager |
| SLAAC rather than stateful DHCPv6 | Ordinary IPv6 clients form their own addresses; do not assume universal EUI-64 support |
| DHCP lease lifetime plus `config host` persistence | Guests disappear naturally; no custom TTL, history DB or cron cleanup |
| MAC-centric identity | Changing IP/privacy addresses do not create separate device identities; randomized MACs still do |
| NDP enrichment, not `getHostHints` authority | Neighbor churn must not erase persistent identities or preserve expired guests |
| Native `config domain` | Shared canonical address/DNS metadata without custom `option ygg_ipv6`, a new UCI inventory file, generated hosts file or resolver |
| `home.arpa` rather than `.lan` | RFC 8375 reserves a locally served home namespace |
| On-page RPC polling | Operational dashboard, not permanent monitoring or traffic accounting |
| Stable-first selection | Stop displaying/probing historical privacy addresses when a canonical or observed EUI-64 exists; preserve privacy-only behavior |
| Explicit trusted sources | Route existence is separate from authorization; no blanket LAN exposure |
| Jumper optional | Direct-path optimization must not become a dependency for base reachability |
| Self-contained deployer | One downloaded file can run on BusyBox without a source checkout or shell-library loader |
| apk only | opkg releases are unvalidated and have incompatible assumptions; fail at preflight instead of promising unsupported compatibility |
| Replace supplied peer list | Idempotent desired state rather than `--add-peers` accumulation |
| Local `--status-pkg`, no `--status-url` | Local/fork/offline builds do not need another arbitrary download switch |
| Restart netifd after new proto packages | Reload alone did not register the new handler in the recorded hardware test |
| `list server '/home.arpa/'` | Avoid the observed invalid joined dnsmasq `list local` output |

DNS names do not require replacing client-wide DNS. The Linux reference uses
systemd-resolved route-only `~home.arpa` with a fixed Ygg `IfName: ygg0` and a
service drop-in after the interface exists. Resolver order in resolv.conf is
failover, not suffix routing. A persistent NetworkManager TUN profile may
occupy the desired TUN before Yggdrasil. Keep Android's normal DNS stack and
unrelated client changes outside the OpenWrt core.

## Limitations and scope

There is one logical status LAN (`LAN_NET='lan'`, device from UCI, fallback
`br-lan`) and a fixed status DNS suffix `home.arpa`. Deployer `--lan` and
`--dns-domain` do not automatically reconfigure these backend constants.
Multi-LAN/VLAN, multiple Ygg interfaces or several delegated prefixes need an
explicit selection/lifetime policy, not an unreviewed loop over interfaces.

Runtime visibility depends on neighbor knowledge; a valid client address can
be temporarily absent when the router has no MAC mapping. Privacy-only NDP
entries do not expose a reliable stable/temporary distinction. Do not fix
this by permanently collecting every privacy IID.

Pin names are single DNS labels (1-63 letters/digits/hyphens, no leading or
trailing hyphen). Canonical lookup follows the host name; renaming a host
without its domain record breaks the association. Unpin intentionally leaves
DNS records, which can become orphaned. Complete removal or coordinated DNS
rename would be separate explicit actions.

## Sources and acknowledgements

The synthesis combines the following upstream mechanisms and project ideas;
it does not install or copy every referenced project's complete stack.

| Source | Contribution / boundary |
| --- | --- |
| [Yggdrasil](https://yggdrasil-network.github.io/) and [configuration](https://yggdrasil-network.github.io/configuration.html) | Node identity, routed subnet and peer model |
| [yggdrasil-go](https://github.com/yggdrasil-network/yggdrasil-go) and [public peers](https://github.com/yggdrasil-network/public-peers) | Implementation and current peer discovery |
| [Yggdrasil-OpenWrt](https://yggdrasil-openwrt.github.io/openwrt-config-basic.html) | Native OpenWrt integration, multicast and routed LAN |
| [Yggdrasil-Jumper](https://github.com/one-d-wide/yggdrasil-jumper) | Optional direct-path/NAT-traversal optimization |
| [AndreBL/ip6neigh](https://github.com/AndreBL/ip6neigh) | Durable identity versus neighbor state; not its daemon, DAD/tcpdump, OUI DB, cache, hosts generator or DDNS/firewall machinery |
| [OpenWrt-list-client-devices](https://github.com/SimplyProgrammer/OpenWrt-list-client-devices) | MAC-centric DHCP/neighbor correlation; not vendor lookup as a dependency |
| [luci-app-wechatpush](https://github.com/tty228/luci-app-wechatpush) | Active ARP/ping detection; not its notification/traffic stack |
| [internet-detector](https://github.com/gSpotx2f/luci-app-internet-detector) and [LuCI Poll API](https://openwrt.github.io/luci/jsapi/LuCI.poll.html) | On-demand checks and page-open polling |
| [ha-openwrt](https://github.com/FaserF/ha-openwrt) | Independent multi-source presence/lifetime confirmation; Home Assistant is not required |
| [luci-app-wrtbwmon](https://github.com/brvphoenix/luci-app-wrtbwmon) | IPv6-aware MAC identity; traffic accounting is outside scope |
| [OpenWrt](https://openwrt.org/), [odhcpd](https://github.com/openwrt/odhcpd), [LuCI](https://github.com/openwrt/luci) | Native network/configuration/UI stack, with dnsmasq, firewall4 and rpcd |
| [RFC 8375](https://datatracker.ietf.org/doc/html/rfc8375) | The home.arpa namespace |

The project's contribution is this particular routed-LAN profile, native
state/lifetime model, safe Pin/Unpin workflow and optional integration, not a
new IPv6 address-allocation protocol.
