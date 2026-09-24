# Architecture and contracts

This is the canonical description of current behavior and design decisions.
Use [installation](installation.md) for commands, [operations](operations.md)
for recovery, and [development](development.md) for verification. History is
context, not an instruction to restore an abandoned approach.

## Module boundaries

```text
Core:    Yggdrasil -> netifd delegated /64 -> LAN -> odhcpd RA/SLAAC
Status:  DHCP leases + config host -> MAC identity -> NDP/canonical IPv6 -> RPC -> LuCI
DNS:     ygg0 address/prefix -> generated /tmp/hosts file (+ config domain) -> dnsmasq -> trusted port 53 -> split DNS
```

Core routing does not depend on status, DNS or Jumper. Status does not require
remote DNS access. `config domain` is intentionally shared metadata: it can
provide a canonical address for status and a native DNS record without a
second database. The automated default deploy enables status, DNS, Jumper and
LAN multicast; each is separately skippable. Optional means independent, not
necessarily disabled by default.

The profile targets OpenWrt 25.12+ with apk, netifd, odhcpd, dnsmasq and
firewall4. Status uses rpcd, LuCI, UCI, libubox jshn, jsonfilter, BusyBox ash, flock and
iputils-arping. It also reads the Yggdrasil admin socket through `yggdrasilctl`
when present; without it the LAN table simply reports no native node addresses. Host-side Python/Node tooling is not a router dependency.

## Core network

The router's private key determines its Yggdrasil identity, node address and
routed subnet. Preserve it across reinstalls or hardware migration. A node has
a native `2xx:` address and routes a `3xx:...::/64`; ordinary LAN clients use
that routed prefix without a local Yggdrasil daemon.

Full Yggdrasil nodes may coexist on the LAN and multicast-peer with the router.
The two address kinds stay distinct: a node's router-prefix Wi-Fi/Ethernet SLAAC
address is its LAN address, and its native TUN/node address remains peer-table
data. The LAN table reports that native address in its own column, attributed
by MAC, so a self-contained node is distinguishable from a device that reaches
Yggdrasil only through the router. An NDP `router` flag does not change the MAC
identity or create another device.

The deployer never edits a package file. The one stock defect it works
around — the proto handler can send its link-up update before the TUN device
exists on a cold boot, after which netifd leaves the interface `pending` with
no address, no prefix and no firewall-zone device — is handled by a hotplug
script of its own, `/etc/hotplug.d/net/50-yggdrasil-pending`, which restarts
an interface still pending ten seconds after its device appeared (operations:
"The cold-boot race and the hotplug guard").

The current clean-install interface name is `ygg0`; older deployments used
`ygg`. netifd derives a delegated prefix's class from its providing interface
name. An LAN `ip6class` list, if any, must admit that class. Setting `ip6class`
on the Yggdrasil interface does not rename its published class.

### The overlay (deployer 2.0)

The routed `/64` is **added** to the LAN beside whatever OpenWrt already
advertises there: the native delegated prefix when the uplink has IPv6, and
the stock ULA (`network.globals.ula_prefix`, a `/48` carved to `ip6assign`).
An IPv4-only site therefore ends up with Yggdrasil + ULA on the LAN, a
dual-stack site with native + ULA + Yggdrasil. Stock IPv6 keeps working as it
did before the deployer ran; that is the premise, verified on a dual-stack LTE
router on 2026-09-18 (`docs/history` keeps the 1.x replacement design).

The LAN's RA/DHCPv6 configuration is the operator's. Stock OpenWrt runs the
hybrid `dhcpv6=server`, `ra=server`, `ra_slaac=1`, `ra_flags` =
`managed-config` + `other-config`: every client forms SLAAC addresses (stable,
privacy, temporary) **and** every DHCPv6-capable client also takes one
stateful address per prefix from odhcpd, with the same IID in each prefix.
The deployer never writes `dhcpv6`, `ra_slaac`, `ra_flags`, `ra_preference`
or `ula_prefix`. What it writes on the LAN:

| Setting | 2.0 |
| --- | --- |
| `network.<lan>.ip6assign` | kept; `64` only when absent. netifd falls back to longer lengths down to /64 when the requested length does not fit, so stock `60` takes the routed `/64` whole (measured). After the reload the deployer checks `ifstatus <lan>` for the actual assignment and fails, with rollback, if the prefix did not reach the LAN |
| `network.<lan>.ip6class` | absent: left alone (no restriction). An operator's own list: kept, the Ygg class appended when missing |
| `dhcp.<lan>.ra` | `server` |
| `dhcp.<lan>.ra_default` | `2`: a default route is announced even without a native uplink, so a client's reply to a Yggdrasil source has a route on an IPv4-only site. On a dual-stack router this changes nothing while the uplink is up; while it is down, clients keep a default and IPv6-only destinations fail instead of being unreachable up front - Happy Eyeballs is the application's fallback, not the router's |
| `config host` reservations | `--host` as in 1.9.0, plus `leasetime '2m'` (2.2; an operator's own value is kept): odhcpd renews at half the lifetime, so a reserved address in a prefix that appeared late - the Ygg /64 after a reboot, a native prefix after an LTE reconnect, a new /64 after a key change - reaches the client within about a minute instead of at the stock 45-minute lease's renew; it also bounds that host's DHCPv4 lease. They need the LAN's DHCPv6 server, which stock has. `--host` on a LAN whose operator disabled DHCPv6 (or set `dhcpv6_na=0` / `ra_offlink=1`) is refused in preflight, before anything is written; the deployer does not override those settings |

A reserved address (`option hostid`) lands in **every** prefix the LAN
advertises - `<native>::10`, `<ula>::10`, `<ygg>::10` - because odhcpd uses one
IID per lease. It is a stable *destination*, not the client's outbound
identity: with the stock hybrid the client also holds SLAAC addresses, and a
client with privacy extensions prefers its temporary address as source (RFC
6724 rule 7 precedes the longest-match rule 8). Measured on Linux clients on
the dual-stack test router: without temporary addresses the source toward
`200::/7` is the routed-prefix address (the reservation, where one exists);
with temporary addresses it is a temporary routed-prefix address. In every
case the source prefix was the right one; a native source toward Yggdrasil
was not observed (the A flag is per interface, so both prefixes get the same
kinds of addresses). Remote `/128` allow-lists on the reserved address
therefore match inbound traffic to that host, not necessarily its outbound
connections. Android does DHCPv6 by policy not at all and takes SLAAC
addresses from the routed prefix as from any other.

The deployer takes the status module's DHCP lock before it stages any `dhcp`
change, so a Pin/Unpin in progress makes it stop with nothing touched.
`odhcpd reload` (SIGHUP) applies the change and keeps the bound leases; the
restart fallback, and a rollback's restart, empty the router's lease record
until clients renew.

### Fresh router, not a migration

The deployer targets a stock router. A router deployed with 1.x (its LAN
replaced by the routed /64: `ip6class`, no ULA, a deployer-owned RA mode) is
brought to 2.0 by reinstalling: reset to stock, install 2.0 with the same
peers, trusted addresses and reservations, and the old identity via
`--private-key-file` (the node address and the routed /64 follow the key).
`--dhcpv6`, `--slaac` and the `[flags]` entries of the same name are refused
with an explanation rather than ignored, so an old settings file is updated
consciously. There is no in-place migration logic and no watchdog: the
deployer's own backup + rollback on a fatal error is the recovery path, and
a router reached only over the LAN being changed is what the second
management path (Yggdrasil to the router, or a console) is for.

### Firewall

A dedicated `ygg` firewall zone is deny-by-default: INPUT REJECT, OUTPUT ACCEPT,
FORWARD DROP, no NAT66. Explicit trusted source `/128` rules authorize
forwarding to LAN separately from router INPUT. The router rule permits TCP,
UDP and ICMP from trusted sources; it is not restricted to ports 22/80/443, and
it is also what opens DNS (port 53) to them — there is no separate DNS rule
since deployer 2.0.4. Restricting ports further is optional hardening, not the
current default.

LAN hosts may **initiate** connections into Yggdrasil through the router
(deployer 2.0, on by default): one explicit stateful rule `LAN-to-Yggdrasil`
(`src <the LAN's zone>`, `dest ygg`, `family ipv6`, `dest_ip 200::/7`, ACCEPT), the way
stock lets the LAN initiate toward the WAN. It is a rule with a destination,
not a zone forwarding, so anything else the tunnel might carry one day is not
forwarded by accident. It changes nothing inbound: unsolicited traffic from
Yggdrasil still reaches only what the trusted rules name. What it does add:
every LAN host can reach any Yggdrasil node (a compromised LAN host gains an
egress the same way it has one to the Internet), remote nodes see this
router's whole routed `/64`, and the LAN's outbound flows now exercise the
Yggdrasil path MTU (1280, PMTUD via the router's ICMPv6 PTB). `--no-lan-forward`
(also `[flags] no-lan-forward`) removes the rule; established flows end on
their own, the rule's removal does not cut them. Hosts that run their own
Yggdrasil node keep using it: their own `200::/7` route wins over the router's
default, so their LAN routed-prefix address is only their inbound identity -
as in 1.x.

Verification is in three classes: what the deployer wrote or requires is
asserted (`ra`, `ra_default`, the prefix actually assigned to the LAN, an
admitting `ip6class`, the zone, the rule in UCI and in the live nft ruleset,
reservations, odhcpd running); the
operator's LAN settings are reported, never asserted; leases are information
(a client asks on renew, reconnect or reboot).

## Inventory data model

| Source | Role | Lifetime and authority |
| --- | --- | --- |
| Active `/tmp/dhcp.leases` entry | Dynamic identity, current IPv4 and hostname | Until lease expires/disappears; expiry `0` means unlimited |
| `/etc/config/dhcp` `config host` | Persistent identity and optional reservation | Until explicit removal; may exist without a lease or IPv4 reservation |
| Kernel `ip -6 neigh` | Observed IPv6 enrichment matched by MAC; ties a bound DHCPv6 lease to a MAC when no `config host` or DUID does | Runtime only; never creates persistence or extends row lifetime; never an authorisation |
| Established Yggdrasil peer link | Native node address of a LAN device running its own daemon | Remembered for exactly the lifetime of the row it belongs to, in that row's own storage class; never creates a row or extends one |
| `config domain` | Optional canonical IPv6 and DNS name | Persistent metadata for an existing persistent identity |
| `/tmp/hosts/yggdrasil-<iface>` (deployer 2.3+) | Generated names `<router>.<zone>`, `<--host>.<zone>`, `<--dns-host>.<zone>` with the node's current addresses; canonical IPv6 for a matching persistent identity after operator `config domain` records | Rebuilt by a hotplug hook on every ifup/ifupdate/ifdown of the Ygg interface; follows a node key changed by hand; tmpfs only |
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
otherwise a bound DHCPv6 lease  -> lease address(es) first, then the observed set
otherwise observed modified EUI-64 -> that address only
otherwise -> all unique observed addresses for that MAC in the Ygg prefix
```

A DHCPv6 lease is attributed to a row by MAC through one resolver
(`mac_for_lease`, shared by the table and by Pin), in order of authority:
`host` - a `config host` ties the lease's DUID (with its IAID, normalised the
way odhcpd reads it - an exact `DUID%IAID` section wins over a DUID-only one)
to a `mac`; `duid` - the MAC embedded in a DUID-LLT or DUID-LL, the same rule
odhcpd applies when it matches `config host` by MAC, accepted only with
hardware type 1, a non-zero MAC (an all-zero one is a firmware defect) and a
MAC the LAN has seen in a DHCPv4 lease or a neighbour entry (Windows keeps
one DUID per machine, made on whichever adapter came first, so a Wi-Fi
client can carry an Ethernet MAC that is not here);
`neighbor` - the LAN neighbour table: every address of the lease, in any
prefix the LAN carries, that a neighbour entry attributes to one and the
same MAC. Two different MACs for one lease, or none, attribute nothing. The
neighbour branch is what names a DUID-UUID client (NetworkManager, systemd)
without a `config host`; it is an observation of the moment - a sleeping or
silent host has no entry and stays unattributed until it speaks - never
stored, never an authorisation, and it cannot keep a row alive: a lease known
this way alone does not make its client pinnable, and Pin records a DUID on
such a match only while the kernel has just confirmed the neighbour entry
(REACHABLE), never on a stale one. A lease no branch can attribute has its
routed-prefix addresses probed once per `clients` call (one echo request
each, in the background, at most 16): a client that never sources traffic
from its leased address - Windows prefers its temporary one - has no
neighbour entry for it until somebody talks to that address, and the
neighbour solicitation the probe triggers is what creates the entry, whether
or not the echo itself is answered. Only leases
whose `flags` contain `bound` count. The lease is the router's own record of
what it handed out, which is why it outranks anything merely observed but not
the operator's canonical record. `ipv6_source` names the branch taken and
`ipv6_lease_match` how the lease was attributed;
`reserved_ipv6` is 1 when the row's `config host` carries `hostid`, or when
it carries an IPv4 `ip` without `hostid` and the bound lease sits on the
suffix odhcpd derives from it (`.235 -> ::235`).

A bound lease also creates a row of its own for a client that holds no DHCPv4
lease (an IPv6-only host), named from the lease's hostname, living as long as
odhcpd lists the lease as bound - but only when the resolver names its MAC,
because the row *is* the MAC. A DUID-UUID client with neither a DHCPv4 lease
nor a `config host` gets its row through the neighbour branch while it is
seen on the LAN, and stays invisible while it is not; that row cannot be
pinned until the client has a DHCPv4 lease or a `config host` (Pin needs
identity evidence, not an observation).

The computed EUI-64 must actually be observed. Never invent an address merely
from a MAC. The canonical address is the primary IPv6 and rendered in bold;
otherwise the first selected address is primary. Runtime addresses are never
written to UCI or a database.

They are remembered, though. The neighbour table forgets a device within
minutes of it going quiet, which is far shorter than the lifetime of the row it
belongs to, so a switched-off pinned machine or an idle BMC would show an empty
address column. When a MAC has no observed address and no canonical record, the
backend replays the addresses it saw last and reports `ipv6_live: 0` so the page
can dim them. A canonical address needs no memory: it is `config domain`
metadata and already persistent. The memory follows the storage rule below, and
an address whose prefix is not the router's current routed prefix is dropped on
the way out — after the router's Yggdrasil identity changes, every address
remembered under the old prefix is dead, and showing one would be worse than
showing nothing.

Memory covers a device the router has already seen. A device it has never seen
needs the address to arrive somehow, and it cannot be derived: RFC 7217 mixes
the prefix into the interface identifier, so it is neither the identifier in the
host's link-local address nor the one in its MAC, and a privacy identifier is
random by design. The backend therefore asks, in two steps.

First it sends ICMPv6 echo requests to `ff02::1` on the LAN bridge, **sourced
from the router's own routed address**. Each device then answers from the
address it would use to reach that prefix — exactly the address this page
reports. Sourcing the request from the router's link-local instead draws
link-local replies only and is useless here. Three requests are sent rather than
one: a device has to resolve the router's routed address before it can reply
from its own, and on the test LAN a single request drew no replies at all while
three drew every device.

The replies name the addresses but do not record them, because the kernel
populates the neighbour table when it transmits, not when it receives. So the
second step sends one unicast probe to each newly named address, and that is
what stores the address together with the MAC this inventory merges on. The
router's own address, link-local replies, foreign prefixes and repeats are
skipped, and the number of confirmations is capped so a crowded LAN cannot turn
one inventory pass into an unbounded burst.

The whole exchange is detached, so an open page never waits for it, and it runs
only when some row was online while its address was missing or recalled. A LAN
whose devices are all known sends nothing at all. The addresses it uncovers
appear on the next pass, so a device that has just joined fills in within one
poll instead of waiting for traffic of its own. A host that ignores echo
requests to multicast addresses stays undiscovered until it talks.

A recalled address stays eligible for presence probing. That is deliberate: a
pinned row with no active lease has no IPv4 to `arping`, so before this memory
existed such a row had no address to probe at all and was always reported
Offline. Presence still follows the order in [Presence](#presence) and a
recalled address only ever adds a probe, never a verdict of its own.

This stable-first policy avoids repeatedly displaying/probing historical
privacy IIDs when a stable address is available. It does not remove addresses
from clients or force every privacy-only client down to one address. The full
[SLAAC incident report](history/slaac-address-fix.md) is preserved separately.

### Native node addresses

`yggdrasilctl -json getPeers` on `unix:///tmp/yggdrasil/<ygg-interface>.sock`
reports every peer link with its native `0200::/8` address. A LAN node found by
multicast peers over its link-local address with the LAN device as the URI zone
(percent-encoded), and an explicitly configured LAN peering uses its LAN IP.
The backend keeps only established links whose endpoint is a literal address on
this LAN, resolves that endpoint to a MAC through the kernel neighbour table,
and deduplicates the inbound/outbound pair a device normally produces. The
neighbour table is the only mapping from a peer's address to a MAC, which is
the identity this inventory merges on.

Peer fields are read by name when the name is known (`remote`/`endpoint`/`uri`,
`address`/`ip`) and by shape otherwise: a transport URI and a `0200::/8` address
are unambiguous on sight, and a value picked by name is re-checked against that
shape. An upstream field rename therefore degrades to shape matching instead of
silently emptying the column.

A device that stops peering keeps its last known native address, and a device
the neighbour table has forgotten keeps its last known routed addresses. Both
memories are files of `<mac> <address>` lines, all rewritten on every inventory
pass and pruned to the MACs still emitted, so an address lives exactly as long
as the row it belongs to — the DHCP lease or `config host` still decides that
lifetime — and vanishes with it. A fresh observation replaces everything
remembered for that MAC, so a node that changes its identity is corrected as
soon as the router sees the new address. `ygg_node_live` and `ipv6_live` report
whether each column comes from a current observation or from memory; the LuCI
page dims a remembered address.

The rule is that a row's memory shares that row's storage class, because the
memory must not outlive the row and must not die before it either:

| File | Holds | Covers | Survives a reboot |
| --- | --- | --- | --- |
| `/tmp/yggdrasil-status-nodes` | native node address | every emitted row | No; a lease-backed row does not survive one either |
| `/etc/yggdrasil-status-nodes` | native node address | only rows backed by a `config host` | Yes, exactly like the `config host` that produced the row |
| `/tmp/yggdrasil-status-lan` | routed-prefix addresses | every emitted row | No; a lease-backed row does not survive one either |
| `/etc/yggdrasil-status-lan` | routed-prefix addresses | only rows backed by a `config host` | Yes, exactly like the `config host` that produced the row |

A pinned device that is switched off when the power fails therefore comes back
with both of its address columns intact, while a guest's are forgotten with the
lease. Precedence on each pass is live observation, then the tmpfs memory, then
the flash memory. A flash copy is replaced only when its content actually
changes, so the 15-second poll behind an open LuCI page does not write to flash
on every tick; a node address changes only when the device changes its key, and
a routed address only when the client changes its interface identifier.
A pass that runs without a routed prefix - netifd has not finished bringing the
Yggdrasil interface up after a reboot, say - can neither observe an address nor
replay one, so it skips the routed memories entirely instead of pruning them. It
would otherwise delete a good memory because of a transient fault rather than
because a row went away, which is exactly what happened on the reboot that
produced this rule.

Unpinning a device drops its MAC from the persistent set, so the next pass
removes it from both flash memories. Nothing is written to UCI or a database,
the files are not configuration and are never read as such, and the installer
neither creates nor removes them.

The flash memories survive a reboot and a power cut, which is what they exist
for. They do **not** survive a `sysupgrade`: OpenWrt's default keep list covers
`/etc/config/` but not these files, so an upgrade preserves the pin and loses
the addresses until the device is seen once more. Adding the paths to
`/etc/sysupgrade.conf` closes that gap; the installer does not do it, because
editing an upgrade policy is not a status page's business. A factory reset
clears everything, and a device that rotates its MAC becomes a different
identity with no pin, exactly as it does for every other row.

A native address is never probed for presence — reaching it would test the
overlay, not the LAN — and is never merged into the routed-prefix address set.

### Presence

Current implementation order in `probe_online()`:

1. A selected IPv4/IPv6 neighbor with kernel NUD `REACHABLE` means Online
   without another probe (a recent kernel-confirmed success).
2. Otherwise, try IPv4 `arping -I "$LAN_DEV" -c 1 -f -w 1` when IPv4 is known.
3. If needed, try `ping -6 -c 1 -W 1` against selected IPv6 addresses.
4. No success means Offline.

Steps 2-3 share one 8 s budget per `clients` call: each active probe costs
about a second and runs for every row the neighbour table does not confirm,
so many offline rows would otherwise stretch the call. ubus would allow 30 s,
but the browser gives an RPC 20 s and a call near that leaves the page on its
spinner for good, so the budget stays well below it. A row reached after the budget is spent is reported `probed: 0` and
shown as "Unknown" - not asked, not guessed; the next refresh asks again.

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
{"clients":{},"pin":{"mac":"","name":"","reserve_ipv4":false,"reserve_ipv6":""},"unpin":{"mac":"","confirm_static":false}}
```

`clients` returns an object containing `clients`, an array of objects:

| Field | Type / meaning |
| --- | --- |
| `hostname`, `mac`, `ipv4` | Strings; identity and selected IPv4 |
| `ipv6` | String; primary selected IPv6 |
| `canonical_ipv6` | String; empty when absent |
| `ipv6_addresses` | Array of strings; stable-first selected set |
| `ipv6_source` | String; `canonical`, `dhcpv6`, `eui64`, `observed`, `remembered` or empty |
| `ipv6_lease_match` | String; with `ipv6_source` `dhcpv6`: `host`, `duid` or `neighbor` - how the lease was tied to this MAC (status 6.1); empty otherwise |
| `reserved_ipv6` | Integer 0/1; the row's `config host` carries a DHCPv6 `hostid`, or an IPv4 `ip` whose implicit suffix the bound lease sits on |
| `dhcpv6_served` | Integer 0/1; some interface has `dhcpv6=server` (the page offers an IPv6 suffix in Pin only then) |
| `ygg_node_ipv6` | String; primary native node address, empty when the device runs no daemon |
| `ygg_node_addresses` | Array of strings; all native node addresses seen for that MAC |
| `ygg_node` | Integer 0/1; the device is a self-contained Yggdrasil node |
| `ygg_node_live` | Integer 0/1; the address comes from a current peer link rather than memory |
| `dns` | String; lowercase JSON key, optional canonical DNS alias |
| `online`, `persistent`, `static_ipv4` | Integer 0/1 flags |
| `ipv6_native` | Array of strings; the device's global addresses outside the routed prefix (native and ULA) from the neighbour table, display only (status 6.2) |
| `probed` | Integer 0/1; 0 when the call's probe budget was spent before this row could be probed (status 6.1.3) |
| `reserved_ipv4` | String; configured valid reservation or empty |
| `managed_pin`, `shared_host`, `complex_host`, `ambiguous_host`, `protected_host` | Integer 0/1 flags |
| `lease_expiry` | String; lease timestamp, empty for a lease-free persistent row |

Mutations return integer `ok`, string `code` and `message`; device replies
also contain `mac`, `hostname`, `reserved_ipv4`. Do not silently change these
types to booleans/numbers when refactoring.

Pin outcomes: `pinned`, `already_persistent`, `invalid_request`, `invalid_mac`,
`busy`, `no_active_lease`, `invalid_hostname`, `no_ipv4`, `dhcpv6_not_served`,
`invalid_hostid`, `hostid_taken`, `pending_uci_changes`, `section_collision`,
`backup_failed`, `uci_failed`, `reload_failed`. `reserve_ipv6` is a hex
suffix (1-16 digits, not 0 = dynamic, not 1 = the router), accepted only where
DHCPv6 is served and refused when any `config host` already claims it,
explicitly (`hostid`) or implicitly (an IPv4 `ip`). Pin writes `hostid` and,
when the resolver attributes a bound lease to the device at the moment of
the pin, that lease's `duid` (with IAID) as well, so a DUID-UUID client
matches; without a lease the reply says the reservation applies only to a
DUID-LLT/LL client. Device replies carry `reserved_ipv6` (the reserved
address).

Unpin outcomes: `unpinned`, `already_dynamic`, `invalid_request`, `invalid_mac`,
`busy`, `static_confirmation_required`, `ambiguous_host`, `shared_host`,
`complex_host`, `reserved_ipv6`, `pending_uci_changes`, `backup_failed`,
`uci_failed`, `reload_failed`. `hostid` is a known option, not a "complex"
one. A section carrying a `hostid` this page's own Pin wrote (a managed pin)
is unpinned under the same `static_confirmation_required` step as an IPv4
reservation, and the reply names the address; one written by hand or by the
deployer is refused with `reserved_ipv6` - the status page does not delete
reservations it did not make; the `hostid` option is removed in the DHCP page
(or `uci delete dhcp.<section>.hostid`) first. Omitting a `--host` line from
a deployer rerun does not remove it either; only its derived DNS record goes.
A section with an IPv4 `ip` and no `hostid` is an implicit IPv6 reservation
while DHCPv6 is served (`.235 -> ::235`); it is flagged `reserved_ipv6` only
while the lease actually sits there, it does not protect the row, Unpin asks
the usual static-reservation confirmation and, whenever any interface has
`dhcpv6=server`, reloads odhcpd after dnsmasq so the removal actually reaches
the DHCPv6 server.

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
    option ip6assign '60'          # stock value kept; no ip6class
# network.globals.ula_prefix stays as stock generated it.

# /etc/config/dhcp (stock hybrid RA/DHCPv6 kept; the deployer writes ra and ra_default)
config dhcp 'lan'
    option interface 'lan'
    option dhcpv4 'server'
    option dhcpv6 'server'
    option ra 'server'
    option ra_default '2'
    option ra_slaac '1'
    list ra_flags 'managed-config'
    list ra_flags 'other-config'

config host 'ygg_host_nas'          # --host nas=<MAC>=10 -> <every LAN prefix>::10
    option name 'nas'
    option mac '<MAC>'
    option hostid '10'

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

config rule 'ygg_lan_out'           # absent with --no-lan-forward
    option name 'LAN-to-Yggdrasil'
    option src 'lan'
    option dest 'ygg'
    option family 'ipv6'
    option proto 'all'
    option dest_ip '200::/7'
    option target 'ACCEPT'

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
    option proto 'tcp udp icmp'
    list src_ip '<TRUSTED_YGG_IPV6>'
    option target 'ACCEPT'
```

## Decisions and rejected alternatives

| Decision | Reason and consequence |
| --- | --- |
| Native netifd/UCI/odhcpd/firewall4 | One owner for routing, prefix advertisement and policy; no container or parallel network manager |
| Overlay, not replacement (2.0) | The routed /64 is one more prefix beside native IPv6 and the ULA; the LAN's RA/DHCPv6 configuration is the operator's. 1.x replaced the LAN's IPv6 (`ip6class`, no ULA, its own RA mode), which broke native IPv6 on dual-stack uplinks and took Android off the routed prefix in managed mode. The stock hybrid gives DHCPv6-capable clients a reservable stateful address per prefix while every client keeps SLAAC |
| `ra_default=2` kept (D1) | The one RA setting the overlay needs: replies to Yggdrasil sources need a default route on an IPv4-only site. Route Information Options (RFC 4191) for `200::/7` were rejected: odhcpd derives them only from `unreachable` routes with `ra_default=0`, Linux ignores them by default, Android accepts /48-/64 only |
| LAN may initiate into Yggdrasil (D5, 2.0) | One explicit stateful rule to `200::/7`, opt-out `--no-lan-forward`. 1.x had no such forwarding, an unweighed default inherited from the remote-access use case. No NAT66: a wrong-source packet fails closed in Yggdrasil instead of being rewritten |
| Reinstall instead of migration | Guessing whose settings a 1.x-shaped LAN carries (`ra_slaac=0`, a missing ULA) is exactly the kind of cleverness that goes wrong on a router nobody can reach; a reset plus the old key reproduces the identity and the routed /64 exactly |
| Assignment length kept, prefix assignment verified | Forcing `ip6assign=64` removes downstream delegation space an operator planned for; netifd takes the routed /64 with stock 60 anyway. `ip6class`/`ip6assign` express a wish, so `ifstatus` is checked after the reload |
| Reservations through native `config host` `hostid` | odhcpd already implements matching (DUID, or MAC for DUID-LLT/LL) and the implicit IPv4-derived IID; the deployer only validates, checks collisions and writes the section |
| DHCP lease lifetime plus `config host` persistence | Guests disappear naturally; no custom TTL, history DB or cron cleanup |
| A row's remembered addresses stored like the row itself | A pinned row survives a reboot, so what is remembered about it must too; a lease-backed one must not. Storage class follows row lifetime instead of a blanket "never touch flash" rule |
| Remembered routed addresses discarded on a prefix change | A routed address is only meaningful under the prefix it was formed from; showing one from a retired prefix is worse than showing nothing |
| MAC-centric identity | Changing IP/privacy addresses do not create separate device identities; randomized MACs still do |
| NDP enrichment, not `getHostHints` authority | Neighbor churn must not erase persistent identities or preserve expired guests |
| Native `config domain` | Shared canonical address/DNS metadata for operator records without custom `option ygg_ipv6`, a new UCI inventory file or resolver (the deployer's own key-derived names are generated since 2.3, below) |
| `home.arpa` rather than `.lan` | RFC 8375 reserves a locally served home namespace |
| Generated names, not static records (2.3) | The router's names derive from the node key (node address, routed /64 + `hostid`). Static `config domain` records kept the addresses of the key the deployer ran with; a key changed in LuCI left them stale. `/etc/yggdrasil-openwrt/dns-hosts` writes them into dnsmasq's hosts directory (as odhcpd does for its leases) and sends SIGHUP; a hook on the Ygg interface runs it. Nothing is written to flash at run time |
| One zone per router, no forwarding between routers | `--dns-domain` (default `home.arpa`; per site e.g. `spb.home.arpa`, or a name under `.internal`) is answered locally, and `home.arpa` always stays local. Routers do not forward each other's zones, so none depends on another; a client that needs several routers' zones needs a resolver of its own that routes each zone to its router |
| On-page RPC polling | Operational dashboard, not permanent monitoring or traffic accounting |
| Stable-first selection | Stop displaying/probing historical privacy addresses when a canonical or observed EUI-64 exists; preserve privacy-only behavior |
| Explicit trusted sources | Route existence is separate from authorization; no unsolicited inbound reaches the LAN beyond the named /128s |
| Jumper optional | Direct-path optimization must not become a dependency for base reachability |
| Self-contained deployer | One downloaded file can run on BusyBox without a source checkout or shell-library loader |
| apk only | opkg releases are unvalidated and have incompatible assumptions; fail at preflight instead of promising unsupported compatibility |
| Replace supplied peer list | Idempotent desired state rather than `--add-peers` accumulation |
| Retry down peers when an uplink comes up (2.5) | Yggdrasil doubles the pause between reconnection attempts up to 1h8m and cannot tell that the uplink is back: after an LTE modem replug the public peers returned 15 minutes after the uplink. Its defaults stay; `/etc/hotplug.d/iface/70-yggdrasil-peers` sends `addpeer` for every configured peer on each `ifup` of another interface. For a configured peer yggdrasil-go (0.5.12, `links.add`) only kicks it: a peer waiting out its backoff tries at once, a connected one is not touched. Interface-bound peers are skipped; the log carries only a count (a URI may hold a password) |
| Local `--status-pkg`, no `--status-url` | Local/fork/offline builds do not need another arbitrary download switch |
| Follow the newest release, no baked-in version | A new status module must not require a new deployer; the resolved tag is strictly validated before it reaches a URL |
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
`br-lan`). Deployer `--lan` does not reconfigure it. The status DNS suffix is
the deployer's zone (`/etc/yggdrasil-openwrt/dns.conf`), `home.arpa` without it.
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
