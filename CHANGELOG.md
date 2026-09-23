# CHANGELOG — OpenWrt + Yggdrasil routed LAN / LuCI Status

## Deployer 2.0.4 - one rule lets trusted nodes reach the router: TCP, UDP, ICMP

- `YGG-Trusted-to-Router` now admits `tcp udp icmp` (was `tcp`); fw4 renders
  the ICMP part as `ipv6-icmp`, so trusted nodes can ping the router over
  Yggdrasil and use any UDP service on it.
- That rule now carries DNS as well, so stage 6 no longer writes the separate
  `Allow-DNS-from-Trusted-Yggdrasil` (`ygg_dns`) rule, and stage 5 deletes one
  left by an earlier run. Two rules fewer in `input_ygg` for the same access.
- `stage_verify` checks the router rule's protocols and the absence of
  `ygg_dns` instead of the old rule's port.

## Deployer 2.0.3 - the guard is in place before the first network reload

- `install_hotplug_guard` now runs before `stage_yggdrasil`. The stage's own
  `network reload`/`restart` plays the same race as a cold boot; with the
  guard written after it, a race during installation left `ygg0` pending and
  `stage_wait` died with "no node address". Now the guard heals it (+10 s) and
  the install goes on. The guard text is unchanged, so an installed router
  needs no rerun. Found in an independent review (Astra).

## Status 6.2.3 - the native IPv6 column shows only the prefixes the LAN has now

- After a renumbering odhcpd keeps announcing the old prefix as deprecated
  (RFC 9096) and the router's neighbour table keeps entries for it long after
  the clients dropped those addresses, so the page listed the old native
  prefix next to the current one. `native_ipv6_for_mac` now keeps an address
  only when it lies in a non-deprecated global prefix that br-lan carries at
  that moment (compared by expanded address and prefix length, so compressed
  forms and the ULA /60 match); with no global prefix on br-lan it shows none.
- Verified on the router's BusyBox awk before release: the six stale
  addresses of the previous prefix disappear, the current ones stay.

## Status 6.2.2 - the native IPv6 column no longer admits 200::/7

- `native_ipv6_for_mac` matched `^[23][0-9a-f]*:`, which also takes any
  `2xx:`/`3xx:` Yggdrasil address; it now requires a four-digit first group,
  i.e. `2000::/3` as its comment says. The router's own routed prefix was
  already excluded before this test, so a normal install shows no change.

## Deployer 2.0.2 - the cold-boot race, handled without touching the package

The stock netifd proto handler sends its link-up update before yggdrasil has
created the `ygg0` TUN device; on a cold boot netifd then rejects the update
(`notify_proto … (Unknown error)`) and leaves the interface `pending` forever:
no address, no prefix, no device in the `ygg` zone, every Yggdrasil packet
rejected by the router itself. Seen once during 1.x testing as an unexplained
rarity, seen again on 2026-09-21 after an unattended reboot, root-caused in
netifd (`device_claim` on a missing device).

- 2.0.1 (same day, superseded) patched `/lib/netifd/proto/yggdrasil.sh`.
  Rejected by the owner: a package file is never edited — `apk upgrade`
  would undo it silently. 2.0.2 restores that decision.
- New `install_hotplug_guard`: writes `/etc/hotplug.d/net/50-yggdrasil-pending`.
  On the device's hotplug `add` it waits 10 s in the background and, if the
  interface is still `pending` and the device is unchanged (ifindex), restarts
  it via `ubus call network.interface.<iface> down`/`up`; at most five
  restarts per boot. Idempotent, dry-run aware, interface name substituted. (Review: ubus down/up instead of `ifup`,
  ifindex guard against stale timers, `pending` is the right predicate.)
- Verified on the router with an induced failure (update sent before the
  daemon): `Unknown error` → guard restart at +10 s → `is now up` at +11 s;
  quiet on healthy bring-ups. On one of two validation cold reboots the
  genuine race occurred and the guard recovered the interface (boot+19 s).
  Test `tests/deploy-hotplug-guard.sh`.
- Not fixed upstream (`openwrt/packages` master, 2026-09-21); no PR by the
  owner's decision.

## Status v6.2.1 - the LAN table no longer risks the browser's RPC timeout

`clients` probed for up to 20 s. The browser's LuCI client gives an RPC 20 s,
and a call that approaches it leaves the page loading forever - which is what
the status page did over Yggdrasil while the owner was away. The probe budget
is now 8 s; rows not reached are shown "Unknown" and probed by the next
15-second refresh, as before.

## Status v6.2 - the table shows native addresses and stops breaking them

- New column "Native IPv6": the device's global addresses outside the routed
  prefix (native `2000::/3` and ULA `fc00::/7`) as the neighbour table shows
  them; display only, never stored. A device that has not used such an
  address through the router shows "—" with a tooltip saying so. RPC rows
  carry `ipv6_native` (array).
- MAC, IPv4, the address columns and DNS are monospace and never broken
  inside a value; the table scrolls horizontally instead of wrapping letters.

## Status v6.1.3 - presence probes share one time budget

`clients` once ran past ubus's 30 s limit: every row the neighbour table did
not confirm cost an ARP probe plus one IPv6 probe per known address, all
sequential. Active probes now share a 20 s budget per call; a row reached
after it is spent is reported `probed: 0` and shown as "Unknown", not
guessed offline. A recent REACHABLE entry still counts without probing.
(Astra: a per-row cap would not bound the total and could mark a host
offline whose live address came third - hence the budget.)

## Status v6.1.2 - probe fixes

The background probe of v6.1.1 inherited the shared DHCP lock, so Pin/Unpin
could answer "busy" while it ran; it now closes the lock first. An expired
DHCPv4 lease no longer counts as "this MAC is on the LAN" when a DUID's
embedded MAC is checked (consistent with `lease_is_active`).

## Status v6.1.1 - a lease nobody could be tied to gets probed once

Windows sources its traffic from a temporary address and its DUID-LLT carries
the MAC of whichever adapter came first, so the router had no neighbour entry
for the leased `::670`-style address and the lease stayed unattributed for
good. `clients` now sends one echo request, in the background, to every
routed-prefix address of an unattributed lease (bounded to 16): the answer
does not matter, the neighbour solicitation it triggers teaches the kernel
which MAC holds the address, and the next call attributes the lease through
the neighbour branch. Measured with two Windows 11 laptops on Wi-Fi.

## Status v6.1 - one lease resolver, and the neighbour table names DUID-UUID clients

v6.0 attributed a DHCPv6 lease through a `config host` or the MAC inside a
DUID-LLT/LL, so a NetworkManager or systemd-networkd client (DUID-UUID) with
no reservation had no row and no bold lease address, although the router
could see which device answered for the leased address. One resolver now
serves the table and Pin alike:

- `mac_for_lease`: `config host` DUID map (the operator's word), then the
  MAC inside a DUID-LLT/LL - only with hardware type 1, a non-zero MAC and
  a MAC the LAN has actually seen (DHCPv4 lease or neighbour entry): a
  Windows 11 laptop on Wi-Fi presented a DUID-LLT made on its Ethernet
  adapter, which would have produced a phantom row - then the LAN neighbour
  table over every address of the lease in every prefix the LAN carries. One MAC attributes; two different MACs, or none,
  attribute nothing. The neighbour branch is an observation of the moment:
  never stored, never an authorisation, never a reason to keep a row.
- Rows carry `ipv6_lease_match` (`host`, `duid`, `neighbor`); the page says
  in the address tooltip when a lease was matched through the neighbour
  table.
- Pin uses the same resolver (with the LAN device and the host DUID map set
  up first), so the `duid` it records is the lease the row shows - but a
  lease attributed only through the neighbour table is not evidence for a
  pin, and the `duid` is recorded on such a match only while the kernel has
  just confirmed the entry (REACHABLE), never on a stale one.
- The stock hybrid LAN of deployer 2.0 gives a DHCPv6 client one lease
  address per prefix; the resolver reads all of them, the table still shows
  the routed-prefix one.

Validated on the test router: a NetworkManager laptop (DUID-UUID) whose
`config host` carried only the MAC was attributed through the neighbour
table (`neighbor`), and through the section (`host`) once its `duid` was
back; a dhcpcd host shows `duid`; a BMC port with an all-zero DUID and no
neighbour entry stays unattributed, as intended. Noted on the way: odhcpd
drops a client's lease on reload when its `config host` section changes, and
`odhcpd restart` (the guard's restore path) empties the lease record until
clients renew.

## Deployer 2.0.0 - the routed /64 joins the LAN instead of replacing its IPv6

1.x made the routed `/64` the LAN's only IPv6: `ip6class` kept every other
prefix off the LAN, the stock ULA was deleted and the RA ran in one of two
deployer-owned modes. On a router whose uplink has IPv6 that broke native
IPv6 for every LAN client, and the managed mode took Android off the routed
prefix. Measured on a dual-stack LTE router (2026-09-18): the stock hybrid RA
gives every DHCPv6 client one stateful address per prefix with the same IID,
so reservations work on stock as they did in managed mode, while SLAAC stays
on for everyone. Hence 2.0, breaking:

- The LAN stage writes `ra=server`, `ra_default=2` and - only when unset -
  `ip6assign=64`. `dhcpv6`, `ra_slaac`, `ra_flags`, `ra_preference` and
  `ula_prefix` are the operator's and are never written. An existing
  `ip6class` list is kept and made to admit the Yggdrasil class. After the
  reload the stage checks
  that netifd actually assigned the routed `/64` to the LAN (stock
  `ip6assign=60` takes it whole) and fails, with rollback, if not.
- `--dhcpv6`, `--slaac` and the `[flags]` entries are refused with an
  explanation. A 1.x router is reinstalled, not migrated: reset to stock and
  run 2.0 with the old key (`--private-key-file`), peers, trusted addresses
  and reservations. No in-place migration logic.
- `--host` reservations no longer need a mode; they need the LAN's DHCPv6
  server, which stock has. A LAN with `dhcpv6` disabled, `dhcpv6_na=0` or
  `ra_offlink=1` is refused in preflight, before anything is written.
- Firewall: LAN hosts may initiate connections into Yggdrasil through the
  router - one explicit stateful rule `LAN-to-Yggdrasil` (`lan -> ygg`,
  IPv6, `dest_ip 200::/7`), not a zone forwarding. `--no-lan-forward`
  (`[flags] no-lan-forward`) removes it. Zone policy, trusted rules and the
  no-NAT66 invariant are unchanged. 1.x had no LAN-to-Yggdrasil path at all.
- The trusted-to-LAN and LAN-to-Yggdrasil rules name the firewall zone the
  LAN network belongs to, not the network name (`--lan guests` in zone `lan`).
- Verification separates what the deployer asserts (prefix on the LAN, `ra`,
  `ra_default`, an admitting `ip6class`, zone, rule, reservations, odhcpd)
  from the operator's LAN settings, which it reports.
- GitHub fetches for the status module are retried three times; on the LTE
  test router a single failed TLS handshake used to skip the module.
- Tests: `tests/deploy-lan-mode.sh` became `tests/deploy-lan-overlay.sh`
  (LAN inspection and preconditions, UCI values, the rule, refused switches).

Validated on the SPb test router reset to stock OpenWrt 25.12.5 with a
dual-stack LTE uplink: fresh install kept the native prefix and ULA on the
LAN beside the routed `/64`, a NetworkManager laptop and a dhcpcd host got
`::20`/`::10` in all three prefixes, LAN-initiated traffic reached Yggdrasil
nodes with the routed-prefix source, untrusted inbound stayed rejected, and
everything survived a reboot. Also on that router: an IPv4-only PDN (Ygg +
ULA only, default via `ra_default=2`, native destinations fail fast), the
native prefix renumbering on PDN re-activation (LAN and leases followed).
An in-place 1.x migration and a `--guard` watchdog were built, validated and
then removed before release: the owner's call is reinstall-not-migrate on a
clean system, and BusyBox has no `nohup` anyway (the watchdog needed
`setsid`). Not validated: PMTU with a remote node below 1500 (Yggdrasil's own
PTB path), non-Linux clients.

## Status v6.0 - the page can reserve addresses, and knows every client the router serves

v5.5 read odhcpd's leases but could tie one to a row only through the MAC
inside a DUID-LLT/LL; a NetworkManager laptop (DUID-UUID) reserved with the
deployer's `MAC+duid:` form was named only because its canonical DNS record
existed, and a client with no DHCPv4 lease had no row at all. The row model
now takes DHCPv6 seriously, which is why this is v6.0:

- A lease is attributed to a row through the `config host` that ties its
  DUID (with IAID, normalised the way odhcpd reads it; an exact `DUID%IAID`
  section wins over a DUID-only one) to a MAC, before the DUID-LLT/LL
  fallback. The BMC with an all-zero DUID, once reserved per port, shows its
  lease as `dhcpv6`.
- A bound lease whose MAC is known creates a row for a client without a
  DHCPv4 lease (an IPv6-only host), named from the lease. A DUID-UUID client
  with neither a DHCPv4 lease nor a `config host` stays invisible; the row is
  the MAC, and that client has not shown one.
- A `config host` with an IPv4 `ip` and no `hostid` is reported reserved
  (`reserved_ipv6`) while the bound lease sits on the suffix odhcpd derives
  from it (`.235 -> ::235`). It does not protect the row.
- Pin can reserve an IPv6 suffix (`reserve_ipv6`, hex, not 0 or 1) where the
  router serves DHCPv6; it refuses a suffix any `config host` already claims,
  explicitly or implicitly. When the device holds a bound lease whose address
  the neighbour table attributes to its MAC, that lease's DUID (with IAID) is
  written beside the `hostid`, so a DUID-UUID client matches; otherwise the
  reply says the reservation applies only to a DUID-LLT/LL client. The page
  shows the field only when the row reports `dhcpv6_served`.
- Unpin removes a reservation this page's own Pin made, under the same
  confirmation as an IPv4 reservation, naming the full address; one made by
  hand or by the deployer is still refused (`reserved_ipv6`). `duid` joins
  `hostid` as a known option, so a pin that recorded the DUID is not
  "complex".

Validated on the test router: pinning the BMC's second port (all-zero DUID,
two IAIDs) with suffix 30 found its lease through the neighbour table, wrote
`duid 00030001000000000000%56ce` beside the MAC, and the row shows the lease
as `dhcpv6`, reserved, unpinnable under confirmation.

## Deployer 1.9.0 and Status v5.5 - the router can own the LAN addresses

Until now the routed `/64` reached LAN clients by SLAAC only. That reaches
every client, Android included, but the router can merely watch which
addresses the clients pick: a modern host forms a stable RFC 7217 address,
often a rotating RFC 4941 one beside it, and no router-side rule can tell
"the" address of a device that has not been talked to yet. The stated aim of
the status page - one stable address a device is reachable at - was out of
the router's hands.

`--dhcpv6` (settings file: `[flags] dhcpv6`) puts it in the router's hands.
RA stays, because it is the only carrier of the default route and the M/O
flags; the A flag goes off, and odhcpd assigns every address from the routed
prefix as it would from an ISP delegation. Reservations are native
`config host` sections with `hostid`, written by `--host NAME=MAC=HOSTID`,
`--host NAME=duid:HEX[%IAID]=HOSTID` or `--host NAME=MAC+duid:HEX=HOSTID`
(`[hosts]` in the file) - the combined form is for a client whose DUID
carries no MAC (a NetworkManager laptop sends DUID-UUID): odhcpd matches by
the DUID, the status page names the row by the MAC; with the DNS
module on, `NAME.home.arpa` resolves to the reserved address, and odhcpd's
own hosts file gives `NAME.lan` for free. The deployer refuses `hostid` 0
(dynamic in odhcpd) and 1 (the router), refuses duplicates, and checks every
new suffix against the existing sections - including the IID odhcpd derives
implicitly from an IPv4 reservation without `hostid` (`.235 -> ::235`), which
becomes a live IPv6 reservation the moment DHCPv6 is served. Existing
sections are updated in place only when plain; shared, duplicated or
option-laden ones are left alone, under the status module's DHCP lock.

The mode is opt-in: without `--dhcpv6` or `--slaac` the deployer keeps the
mode the router already runs, and a fresh router gets SLAAC, so a rerun for
any other reason never changes LAN policy. `--slaac` switches back. The
deployer takes the status module's DHCP lock before staging any change, so a
Pin/Unpin in progress stops it with nothing touched. Verification checks the
mode's exact UCI values (`ra_flags` as a set of two list entries), that
odhcpd runs and is enabled, each reservation's `hostid`, and lists the leases
bound so far. The LAN stage applies its changes with `odhcpd reload`, which
keeps the bound leases across a managed-mode rerun (a restart emptied the
router's lease record until every client renewed); a switch to SLAAC still
discards them, since it disables the DHCPv6 server.

The accepted cost is written down rather than hidden: a client without a
DHCPv6 client - Android by policy, some IoT - gets no address from the routed
prefix in managed mode. A phone that needs Yggdrasil runs its own node. A MAC
in `config host` matches only a DUID-LLT or DUID-LL client; a BMC with an
all-zero DUID needs `MAC+duid:` with `%IAID` per port - the MAC because
odhcpd keys host sections on DUID bytes and MACs, not on the IAID, and would
fold two DUID-only sections into one; a DUID must be 10-130 bytes.

Status v5.5 reads `ubus call dhcp ipv6leases` as an address source. A bound
lease is attributed to a row through the MAC inside a DUID-LLT/LL - the rule
odhcpd itself uses - and outranks anything merely observed, though not a
canonical record; it is shown first and in bold, with `ipv6_source: dhcpv6`
and `reserved_ipv6: 1` when the row's `config host` carries `hostid`. Only
bound leases count; an offer a client never took is not an address. Such a
row is protected from Unpin (`reserved_ipv6`): the `hostid` is removed in the
DHCP page first, the status page deletes no reservations. A host with an IPv4
`ip` and no `hostid` is an implicit IPv6 reservation while DHCPv6 is served;
Unpin keeps asking its static-reservation confirmation and now reloads odhcpd
after dnsmasq whenever DHCPv6 is served, so the removal reaches the server.
`hostid` is a known option, so it no longer marks a section "complex". Rows
still originate from DHCPv4 leases and `config host`; a DHCPv6-only client
has no row - a known limit, not an accident.

Validated on the test router (OpenWrt 25.12.5, odhcpd 5d7be43): managed ->
SLAAC -> managed round trip through the deployer, a Debian client holding
exactly the reserved `::10` and using it as source, `zeonux.home.arpa`
resolved and reached from a trusted node, both the status backend and the
page showing the lease. odhcpd's `hostid` parsing, MAC-from-DUID extraction
and implicit-IID derivation were read in its source and confirmed live.

## Status v5.4.1 - the Node table shows the routed subnet again

The **Routed subnet** column of the Node table showed a dash on every router,
even with the `/64` prefix present and assigned to `lan`. The page selected the
prefix with `p.class === 'ygg'`, but netifd sets a prefix's `class` to the
interface name (`ygg0`; the proto handler calls `proto_add_ipv6_prefix` without
a class), so the lookup never matched. The page now compares with the
interface it is rendering, which is also correct for an interface not named
`ygg0`. One line in `view/status/yggdrasil.js`; no backend, install or config
change. Verified on the test router against `ubus call network.interface dump`.

## Docs - waking LAN hosts from the router

Operations gains a section on Wake-on-LAN: why the router is the place to send
the magic packet from, the `etherwake` + `luci-app-wol` setup validated on the
test router on 2026-09-14 (suspend 12 s, full power-off about two minutes),
why the UDP-broadcast `wol` backend was not installed, and the host-side
conditions that decide whether a wake works at all. No code changes.

## Status v5.4 - a pinned row also remembers its routed addresses

v5.3 gave the Yggdrasil node column a memory. The routed-prefix column still had
none, so it emptied out for any device the neighbour table had forgotten — which
is every device that simply stops talking. A pinned desktop switched off during
a power cut came back showing its `0200::/8` node address and a blank
`303::/8` address, and an idle BMC that never initiates IPv6 traffic showed a
blank address the whole time even while it was online and reachable.

The routed addresses are now remembered through the same mechanism and under the
same rule: `/tmp/yggdrasil-status-lan` for a lease-backed row,
`/etc/yggdrasil-status-lan` for a `config host` row, pruned to the MACs still
emitted and rewritten only when an address actually changes. A canonical
`config domain` address is not remembered, because it is already persistent
metadata of its own.

A recalled address is reported as `ipv6_live: 0` and dimmed on the page, so it
can never be mistaken for something the router is observing right now. An
address whose prefix is not the router's current routed prefix is discarded on
the way out: after the router's Yggdrasil identity changes, everything
remembered under the old prefix is dead, and offering one as if it still worked
would be worse than showing nothing.

Memory only covers a device that was seen at least once. A device that has just
joined, or one that simply never sends anything, was still shown with an empty
address column - observed on a freshly connected server that stayed blank for
minutes while it was plainly online. The address cannot be derived from the MAC
or from the host's link-local address, because RFC 7217 mixes the prefix into
the interface identifier, so the backend now asks for it. ICMPv6 echo requests to
`ff02::1`, sourced from the router's own routed address, make every device reply
from the address it would use to reach that prefix; each address that turns up
is then confirmed with one unicast probe, because the kernel records a neighbour
when it transmits, not when it receives. Three multicast requests are sent
rather than one - on the test LAN a single request drew no replies at all, since
a device must first resolve the router's routed address. The whole exchange is
detached, capped, and runs only when a row was online while its address was
missing or recalled, so a settled LAN is never probed and an open page never
waits.

A pass that runs without a routed prefix now skips the routed memories instead
of pruning them. Found on a real reboot: netifd had not finished bringing the
Yggdrasil interface up, the backend could observe nothing and replay nothing,
and it rewrote the flash memory empty - destroying what it remembered about a
pinned device over a transient fault rather than because the row went away.

The `AGENTS.md` invariant that NDP must not create persistent history was the
proxy for a stricter rule that still holds and is now stated directly: a
memory's lifetime never exceeds the lifetime of the row it belongs to. The
`sysupgrade` limitation is unchanged and now covers both files — OpenWrt's keep
list covers `/etc/config/`, not these paths.

## Deployer 1.8.0 - one settings file

A routed deployment with peers, trusted addresses, a restored identity, DNS
records and a couple of switches is a long command line, and a long command line
is retyped - or pasted from a notes file - every time the router is redeployed.
`--config FILE` reads the same settings from one file on the router instead:
`[peers]`, `[trusted]`, `[private-key]`, `[iface]`, `[lan]`, `[dns-domain]`,
`[dns-router]`, `[dns-hosts]`, `[status-pkg]`, `[status-version]` and `[flags]`,
one value per line, `#` comments. The sections are the options by another name:
every line goes through the same `add_*` and validation path, so nothing the
command line would refuse can enter through the file, and an unknown section or
flag is an error rather than a silently ignored typo. Options apply in the order
given, so a value after `--config` adds to the file's lists and overrides its
single values. `--dry-run`, `--yes` and `--wait` describe the run, not the
node, and stay on the command line.

The key keeps its rule: a `[private-key]` section is a file, not an argument,
so it never reaches `/proc/<pid>/cmdline`; it sits between `--private-key-file`
and `YGG_PRIVATE_KEY` in precedence, and a config file that holds a key but is
readable beyond its owner draws the same warning a key file would. The Debian
installer in Tainiy-proxy gained the same `--config` on the same day, with the
subset of sections that apply there.

Testing this on the router turned up an older defect: `die()` calls
`rollback()`, which is defined further down the script, so an argument error -
a bad peer URI, now also a bad section - printed `rollback: not found` after the
real message. There is nothing to roll back at that point; `die` now calls
`rollback` only once it exists.

`tests/deploy-config-file.sh` evaluates the extracted option loop against a
full settings file and checks every section, the ordering rules, the rejection
cases, the mode warning and the key precedence, and runs the real script once
with a bad section to confirm the error is reported cleanly. Validated on the
LTE test router (OpenWrt 25.12.5, BusyBox ash): a settings file built from the
live state with all of `[peers]` `[trusted]` `[private-key]` `[iface]` `[lan]`
`[dns-domain]` `[dns-router]` `[dns-hosts]`, dry run then a full `-y` run -
identity and routed `/64` unchanged, four peers up, trusted rules and the DNS
firewall rule identical, a new `desktop.home.arpa` record resolving from a
trusted client, LuCI and SSH reachable at `router.home.arpa`; a dry run without
`--peer` reported the four existing sections as kept.

## Deployer 1.7.0 - the peer list is optional

The peer list was the one mandatory input: a run without `--peer` or
`--peers-file` stopped at argument parsing. That made every re-run repeat the
peers even when the change was elsewhere - a new trusted address, the DNS module
on an already deployed router - and it diverged from the Debian installer in
Tainiy-proxy, where peers were optional from the start.

Peers given on the command line still replace the configured set. Without any,
the existing `yggdrasil_<iface>_peer` sections are left as they are, the
pre-flight summary says how many are kept, and a router that has none gets a
warning that the node will have an address but no path into the network, with
a pointer to `public-peers`. The routed `/64` and the node address derive from
the key, not from a peer, so the later stages are unaffected.

`tests/deploy-peers-optional.sh` evaluates the extracted option loop without
peers, checks that the mandatory check is gone and that the peers stage
branches on an empty list, and confirms that peers which are given are still
validated and collected.

## Deployer 1.6.1 - release discovery can authenticate

Anonymous `api.github.com` requests are limited per source IP. A shared address
exhausts that budget through no fault of its own and release discovery then
fails for an hour, which is not something a retry can fix. This bit CI once on
`main`, and it applies equally to a router behind CGNAT.

`status_resolve_version` now sends `Authorization: Bearer $GITHUB_TOKEN` when
that variable is set, and `status_fetch` takes an optional header argument to
carry it. The header reaches only the fixed `api.github.com` lookup: a release
asset redirects to another host, so a credential on those requests would leak
off-site. `uclient-fetch` has no header option and is skipped in that branch
rather than silently dropping the header. Unset, every path behaves as before,
and `--status-version vX.Y` still avoids the lookup entirely.

The token reaches `wget` as a process argument, so the documentation says to use
it on CI or a single-user host rather than a shared router. CI passes the run's
own scoped token. No new secret, and the status module is unchanged.

## Status v5.3 - a pinned row remembers its node address across a reboot

A remembered native node address is now stored in the same storage class as the
row it belongs to. Rows backed by a `config host` — that is, pinned devices —
keep their address in `/etc/yggdrasil-status-nodes` and recover it after a
reboot, so a desktop that is switched off during a power cut still shows its
`0200::/8` address when the router comes back. Rows backed only by a DHCP lease
keep using `/tmp/yggdrasil-status-nodes` and are still forgotten with the lease.

The flash copy is pruned to the MACs that were emitted as persistent, so
unpinning a device removes its address on the next pass, and it is rewritten
only when the content actually changes, so the 15-second poll behind an open
LuCI page does not write to flash on every tick. Precedence is unchanged: a live
peer link always overrides anything remembered. The file is not configuration,
is never read as such, and the installer neither creates nor removes it.

This narrows the previous "no cache on flash" invariant to what it was actually
protecting: a row's memory must never outlive the row — and, for a row that
survives a reboot on its own, must not die before it either.

## Status v5.2 and a release-following deployer (1.6.0)

Status downloads moved to versioned GitHub Releases with verified bytes.
`--status-pkg` builds require a single-entry checksum file, missing verification
tools/checksums and mismatches refuse the optional installation, and status
workspaces are private and cleaned on exit. The embedded version/digest pin and
the raw-commit mirror introduced here were **superseded within this same
unreleased cycle** by release discovery, described below.

Existing v4/v5/v5.1 archives and checksums have been preserved as Release assets
without rebuilding. Copies in `packages/` remain unchanged for old raw URLs;
new builds go to Releases, not the source tree.

A manual workflow prepares a draft from a clean, exact main-branch revision;
it creates a fresh tag, refuses existing tags and never publishes automatically.
Download/error-path tests run under sh and BusyBox; CI verifies the real public
release download. Core network and client DNS behavior are unchanged.

### Deployer 1.6.0: follow the newest published status release

The deployer no longer carries a status version and digest, so publishing a
status module no longer requires shipping a new deployer. It asks GitHub for the
newest release, accepts the answer only as a `status-vX.Y[.Z]` tag matching a
strict pattern, and only then builds a download URL, so a release name can never
steer the path. It then fetches the `.sha256` published beside the archive in
that same release and refuses any disagreement. A checkout copy of the same
version is still usable offline but must now carry its own checksum file rather
than inheriting a digest from the script.

New `--status-version vX.Y` installs a specific release and skips discovery
entirely. `--status-pkg PATH` is unchanged. Every failure path stays fail-closed:
an unreachable release list, a malformed tag, a missing, ambiguous, mismatched or
unfetchable checksum, and a corrupt archive all skip the optional status module
rather than installing anything unverified. The raw-commit mirror is gone; it
could not exist for a version that is deliberately not committed to
`main/packages`.

**Known limit, stated deliberately.** The published checksum ships in the same
release as the archive, so it proves transport integrity, not provenance. The
previous embedded pin additionally covered substitution of a release asset after
a trusted deployer copy was obtained; that property was traded for not needing a
deployer change per release. Operators who need it should build the module
themselves and install it with `--status-pkg`.

### Status v5.2: native node addresses in the LAN clients table

The LAN table gains a `Yggdrasil node` column. When a LAN device runs its own
Yggdrasil daemon and peers with the router, the backend reads the router's peer
list, keeps the established links whose endpoint is a literal address on this
LAN, resolves that endpoint to a MAC through the neighbour table and reports the
device's native `0200::/7` address alongside its routed-prefix addresses. A
self-contained node is now distinguishable from a device that reaches Yggdrasil
only through the router.

A device that stops peering keeps its last known address, dimmed in the page,
for exactly as long as its row exists. The memory is `/tmp/yggdrasil-status-nodes`,
rewritten every pass and pruned to the MACs still emitted, so it never extends a
row's lifetime, never reaches flash and starts empty after a reboot. A fresh
observation replaces everything remembered for that MAC, so a node that changes
its identity is corrected as soon as the router sees it.

Peer fields are read by known name and re-checked by shape, falling back to
shape alone, so an upstream rename of `remote`/`address` degrades to shape
matching instead of silently emptying the column.

New `clients` fields: `ygg_node_ipv6`, `ygg_node_addresses`, `ygg_node` and
`ygg_node_live`. The address is never probed for presence and never merged into
the routed-prefix set. `yggdrasilctl` is optional: without it, or with nothing
peering and nothing remembered, the column is simply empty. Covered by two new
backend fixture groups and verified on the test router, including the
remembered path. Released as
[`status-v5.2`](https://github.com/Plasmoid77/Yggdrasil-OpenWRT/releases/tag/status-v5.2).

## v5.9 — private-key handling and factory-reset revalidation

`deploy/deploy-openwrt-yggdrasil.sh` 1.5.1. The status package is unchanged at
`yggdrasil-status-v5.1`.

### Hardened: keep the private key out of incidental exposure paths

The deployer now creates its backups and temporary files under `umask 077`,
sends `network.*.private_key` to `uci batch` on standard input instead of
putting it in `uci set` process arguments, removes `YGG_PRIVATE_KEY` from the
exported environment before spawning key-loading helpers, validates even a
preserved UCI key before building an unquoted batch line, and redacts
private-key values if preflight has to report pending UCI changes. Focused
regression tests cover these paths and run in CI.

### Verified again from a factory reset

The complete path was repeated on a Cudy WBR3000UAX v1 running OpenWrt 25.12.5:
temporary Wi-Fi bootstrap, installation of the router's LTE modem package and
its reboot, LTE uplink, Yggdrasil deployment, an identical second deployment,
and a final The second deployment retained the node address and routed `/64` and left
exactly the requested four peer sections. After the final reboot the uplink,
`ygg0`, LAN SLAAC, trusted-source SSH, TCP/UDP DNS, LuCI and its RPC backend
were all operational.

The no-restart variant was also tested, rather than inferred: after installing
the packages, netifd did not recognize the new Yggdrasil protocol handler and
the run timed out without a node address. Its rollback succeeded. The existing
conditional netifd restart is therefore required and remains unchanged.

## v5.8 — a smaller flag surface

`deploy/deploy-openwrt-yggdrasil.sh` 1.5.0.

### Removed: `--add-peers` and `--status-url`

`--add-peers` appended to the configured peers instead of replacing them. It
made the resulting peer set depend on what was already there, which is the one
property an idempotent deployment script should not have. The peer list on the
command line is now simply the peer list: existing sections are removed first,
every time.

`--status-url` pointed the status-module download at another host. `--status-pkg`
already covers the case it was meant for — an isolated router, a fork, a local
build — by taking the tarball directly, and it verifies a `.sha256` sitting next
to it. One way in is enough.

### Verified on hardware: the remaining switches

`--no-lan`, `--no-firewall` and `--no-status` were tested by perturbation rather
than by trusting their "skipping" line. `network.lan.ip6assign` was set to `60`,
`firewall.ygg_dns.dest_port` to `5353`, and the installed status module's
checksum and mtime recorded. After a full run with all three switches every one
of them was untouched; a plain run afterwards restored `64` and `53`.

`--status-pkg` installed the module from a local tarball, verified it against the
`.sha256` beside it, and never touched the network.

## v5.7 — apk only

`deploy/deploy-openwrt-yggdrasil.sh` 1.4.0.

### Removed: the opkg fallback

The script accepted an `opkg` router with a warning. That was a courtesy that
could not be honoured: on an opkg release the package names differ, the
Yggdrasil netifd protocol handler is not the same, and nothing in this design
has ever been validated there. A run would have failed later and less clearly
than a refusal at preflight. It now requires `apk` and says so:

```
apk not found — this design targets OpenWrt 25.12 or newer
```

### Verified: `--private-key-file` restores an identity on real hardware

Previously exercised only under `--dry-run`. Tested end to end: the node's
private key was saved, the whole Yggdrasil configuration deleted, and the script
re-run with `--private-key-file`. The node came back at exactly its previous
address and routed prefix, and a remote client reached it over Yggdrasil with no
change to its own configuration — no SSH config edit, no `known_hosts` entry, no
split-DNS update. The key appeared nowhere in the output: a search of the full
run for the 128 hex characters, and for their first 32, found nothing.

`--peers-file`, `--add-peers` and the four `--no-*` switches were confirmed too.

## v5.6 — deploy other proto handlers first

Documentation only.

### Documented: install protocol-handler packages before Yggdrasil

Installing a package that ships a netifd protocol handler requires a netifd
restart. Doing that while Yggdrasil is already running restarts netifd
underneath a live Yggdrasil interface, and once on the tested router the reboot
that followed left `ygg0` at `up:false pending:true`: the daemon had its peers,
but netifd never completed the protocol setup, so no prefix was published, the
LAN kept no routed address and the firewall zone had no device. The router
looked healthy while the design was unreachable from outside; `ifup ygg0`
cleared it.

It did not reproduce in fourteen further attempts — reboots with and without an
uplink, and repeated `/etc/init.d/network restart` — so it is a rare race rather
than a defect with a known trigger, and no watchdog is shipped for it. Deploying
the other handlers first avoids the situation at no cost, and that order is now
validated end to end from a factory reset: uplink, modem installer and its
reboot, a control reboot proving the modem alone is stable, Yggdrasil, then a
final reboot that came up clean on five consecutive samples.

`QUICKSTART.md` also gains the Wi-Fi station bootstrap, since a factory reset can
leave a router with no uplink at all and no way to install one.

## v5.5 — restart netifd before anything is written

`deploy/deploy-openwrt-yggdrasil.sh` 1.3.0.

### Changed: the netifd restart happens in stage 1, not mid-deployment

netifd only reads `/lib/netifd/proto/*.sh` at startup, so a handler installed
during the run is invisible to it and the interface comes up as `proto 'none'`.
The script has always detected that and restarted netifd — but it did so in
stage 2, after committing the Yggdrasil interface, which put a few seconds of
dropped interfaces in the middle of applying configuration.

It now restarts netifd at the end of stage 1, right after installing the
packages and before the first UCI write, and only when this run actually
installed something. A connection lost at that moment now leaves the router
exactly as it was found, and re-running the script continues from a clean state
instead of from a half-applied one.

The stage 2 check is kept as a fallback for the case stage 1 cannot see: a
handler installed by someone else since netifd last started, leaving this run
with nothing to install and no reason to restart.

## v5.4 — run it straight off GitHub

`deploy/deploy-openwrt-yggdrasil.sh` 1.2.1. Documentation and one cosmetic fix.

### Fixed: the banner said "sh" when the script was piped

`SELF="${0##*/}"` is the shell's own name under
`wget -qO- … | sh -s -- …`, so the banner and the usage text announced
themselves as `sh 1.2.0`. `SELF` now falls back to the real filename when `$0`
names a shell.

### Documented: fetching the script on the router

OpenWrt ships `wget` (`uclient-fetch`) with a CA bundle and no `curl`.
`QUICKSTART.md` now shows both forms — download to `/tmp` and run, which keeps
`stdin` free for the interactive trusted-address prompt and makes a re-run free,
or pipe straight into `sh -s --`, which requires `--trusted` on the command line.

It also explains the netifd restart in stage 2, and corrects an overstatement
made while writing this section. The restart is a service restart, not a reboot,
and it does **not** interrupt the run: measured on the tested router it takes
about three seconds, and an established SSH session survives it, because the LAN
address returns long before the TCP connection gives up. What fails during that
window is anything opening a *new* connection — which is what an earlier polling
loop was doing when it looked like the session had died. A first deployment can
be watched live in the terminal; `setsid` with a log is a precaution for links
where a three second gap may not be survivable, not a requirement.

## v5.3 — identity restore, and one run deploys the whole design

`deploy/deploy-openwrt-yggdrasil.sh` 1.2.0. The status package is unchanged at
`yggdrasil-status-v5.1`.

### Added: restore an existing node identity

The Yggdrasil private key is the node identity, so redeploying or moving to new
hardware without it means a new address and a new routed `/64`. The script now
takes the old key from `--private-key-file PATH` or from `YGG_PRIVATE_KEY` in
the environment, validates it as 128 hex characters, and refuses anything else.

It is deliberately **not** accepted as a command-line value. `/proc/<pid>/cmdline`
is world readable, so an argument would expose the key to every process on the
router for the length of the run, and leave it in the shell history of whoever
typed it and in the ssh command line when the script is piped in. The key is
never echoed — not in a log line, not in an error, and `--dry-run` prints
`<REDACTED 128 hex chars>`. Replacing an identity that already differs asks for
confirmation first, because it changes the router's address and its routed `/64`.

### Changed: the DNS module runs by default

`--dns` made Part III the one optional stage that was off by default, while
`--no-lan`, `--no-firewall` and `--no-status` all describe stages that run unless
told otherwise. It now follows the same convention: the stage runs, `--no-dns`
skips it. `--dns` is still accepted. A deployment that stops before DNS is not
finished, and the module boundary the design describes is about architecture,
not about what a default deployment should leave undone.

## v5.2 — the optional DNS module is deployable

`deploy/deploy-openwrt-yggdrasil.sh` 1.1.1. The status package is unchanged at
`yggdrasil-status-v5.1`; this release touches the deployment script only.

### Added: `--dns` deploys Part III

Part III (`AI_CONTEXT.md` section 10, `REFERENCE_CONFIG.md` 6-7) was documented
but had to be applied by hand. The script now has a stage for it, off unless
`--dns` is given, because the routed `/64`, SLAAC, the firewall policy and the
status page all work without it.

It writes one `config domain` record per name, opens port 53 to the trusted
`/128` addresses only, and makes dnsmasq answer the namespace itself instead of
forwarding it upstream. `--dns-host NAME=ADDR` adds records and may repeat a
name, so a host with two addresses on the routed `/64` gets both; the UCI
section id is derived from name *and* address, and existing records for a name
are dropped before rewriting, so a changed address leaves no stale answer.

### Changed: the run ends with a colour-coded verdict

The final summary was framed in the same cyan as every stage header, so a run
that finished with failed invariants looked like a run that succeeded once the
`[FAIL]` lines had scrolled away. Success is now a green frame carrying the
router's Yggdrasil address, failure a red one; the address itself is green and
bold. Colour is still emitted only on a real terminal and suppressed by
`NO_COLOR`, so redirected logs stay plain text.

### Note: `local` as a UCI list breaks dnsmasq

The obvious way to make dnsmasq authoritative for the namespace is
`list local '/home.arpa/'`. `/etc/init.d/dnsmasq` emits `option local` as a
single line and joins list values with spaces, producing `local=/lan/ /home.arpa/`
— invalid, and dnsmasq exits without a message, taking LAN name resolution with
it. The script uses `list server '/home.arpa/'` instead: `server=/domain/` with
no target is dnsmasq's equivalent of `local=/domain/`, and the init script emits
one line per list value. The stage also waits for dnsmasq to come back and fails
loudly if it does not.

## v5.1 — prefix class no longer assumed, plus an automated deployment

Validated on a Cudy WBR3000UAX v1 running OpenWrt 25.12.5 (mediatek/filogic,
`apk`), with the Yggdrasil interface named `ygg0`.

### Fixed: the routed prefix was never found unless the interface was named `ygg`

`find_lan_ygg_prefix` selected the delegated prefix with a hardcoded
`@.class="ygg"`. netifd does not take that class from the configuration: it
names a delegated prefix after the interface that provided it. The original
deployment's interface was called `ygg`, so the literal happened to match. With
the documented name `ygg0` the class is `ygg0`, the lookup returned nothing, and
every LAN client reported an empty `ipv6` / `ipv6_addresses` with no error
anywhere. The backend now matches the class of the interface it already
identified as the Yggdrasil one, and falls back to that interface's first
published prefix, so any interface name works.

The same stale value was in the documented LAN configuration: `ip6class 'ygg'`
against a `ygg0` interface silently selects no prefix. Corrected throughout, with
the rule stated rather than the value alone. Setting `ip6class` on the Yggdrasil
interface does not override the published class — verified, not assumed.

### Added: `deploy/deploy-openwrt-yggdrasil.sh`

One POSIX `sh` script that applies the whole design from a peer list and an
optional trusted `/128` list, then prints the router's Yggdrasil address and the
command to reach it. Backs up `network`/`dhcp`/`firewall` and restores them on
any failure, preserves an existing private key, never prints one, and is
idempotent. `--dry-run` previews every change.

It also handles something the manual instructions did not: netifd reads
`/lib/netifd/proto/*.sh` only at startup, so a Yggdrasil proto handler installed
during the same run is invisible to the running netifd and the interface comes
up as `proto 'none'` with `NO_DEVICE`. A reload does not fix it; the script
detects the condition and restarts netifd once.


This changelog summarizes architectural evolution, not every experimental command from development chats.

## 2026-08 — Core routed-LAN design

Established the base architecture:

- native Yggdrasil on OpenWrt;
- Yggdrasil routed `/64` advertised to `br-lan`;
- `network.lan.ip6assign='64'`;
- `network.lan.ip6class='ygg0'` (the Yggdrasil interface name);
- odhcpd RA/SLAAC;
- DHCPv6 disabled;
- extra OpenWrt ULA removed for this profile;
- dedicated `ygg` firewall zone;
- explicit trusted-source rules instead of blanket `ygg -> lan` forwarding;
- ordinary LAN clients require no local Yggdrasil daemon.

## Status prototype — runtime hints / NDP

Initial dashboard concepts relied heavily on runtime host hints and neighbor state.

Observed failure mode:

- NDP state could become `FAILED` or expire;
- LuCI runtime hints could then forget IPv6;
- device/address disappeared from dashboard even though the stable address still existed and could return after an active probe.

Decision: runtime neighbor state cannot be the authoritative persistent inventory.

## Status prototype — separate persistent inventory

Considered `/etc/config/yggdrasil-status` with persistent client records.

Decision: rejected because it duplicated state that can be represented with native OpenWrt UCI.

## Status prototype — mandatory EUI-64

Considered deriving one permanent IPv6 from MAC for every host.

Decision: rejected because clients choose SLAAC IID and many use stable/privacy addressing. Final architecture does not require EUI-64.

## Status v2 — `config host` + `config domain`

Introduced native OpenWrt persistent metadata:

- `config host` for hostname/MAC identity;
- `config domain` for canonical Ygg IPv6 and optional `home.arpa` name;
- active ARP/IPv6 probes for Online/Offline;
- no daemon, cron, DB, or runtime cache;
- LuCI polling only while page is open.

Limitation discovered later: only persistent `config host` rows were shown, so ordinary DHCP-only clients were invisible.

## Status v3 — dynamic DHCP lifetime

Changed inventory model to:

```text
active DHCPv4 lease -> dynamic row
config host         -> persistent row
merge by MAC
```

Important semantics:

- guest devices remain only as long as dnsmasq remembers their DHCP lease;
- lease expiry is natural garbage collection;
- persistent hosts remain after lease expiry;
- current Ygg/SLAAC addresses are runtime enrichment from NDP and are not persisted;
- iOS-like devices with multiple privacy addresses can show multiple IPv6 addresses.

This fixed real DHCP-only Windows and iPhone clients missing from the page.

## Status v4 — Pin / Unpin management

Added persistence management directly to `Status -> Yggdrasil`.

Compact peer fields (`State`, `Dir`, `Pr`, and `Cost`) now use minimal,
non-wrapping columns. Long URIs, addresses, and errors remain wrappable, so the
table uses wide screens efficiently without splitting short values such as
`Down` or `Out` across lines.

The LAN-client `Persistence` cell now uses fixed label and action tracks, so
all `Pin`, `Unpin`, and `Manage` buttons have equal width and align vertically
regardless of the persistence label.

### Pin

- creates a normal OpenWrt `config host`;
- requires hostname + MAC;
- optional `Reserve current IPv4` checkbox;
- IPv4 reservation is **off by default**;
- backend re-reads current DHCP lease before storing reservation.

### Unpin

- simple single-MAC host can be removed;
- if DHCP lease still exists, row falls back to Dynamic;
- static IPv4 reservation requires explicit destructive confirmation;
- `config domain` is left untouched.

### Safety guards

Automatic deletion is refused for:

- multi-MAC host sections;
- duplicate host sections referencing same MAC;
- host sections with additional/unknown DHCP options;
- pending uncommitted DHCP UCI changes.

DHCP file is backed up before mutation and restored if commit/reload fails.

### Installer safety

v4 installer:

- backs up previous status module files;
- installs `iputils-arping` if needed;
- replaces backend/ACL/menu/frontend;
- restarts only rpcd;
- validates RPC methods and client response;
- rolls back the previous module on validation failure;
- does not reload network/firewall/Yggdrasil/odhcpd.

### Development bugs fixed before v4 release

- BusyBox lowercase portability (`tr 'A-Z' 'a-z'` retained);
- shell variable-scope fragility in BusyBox ash helper code;
- IPv4 validation edge case in intermediate code;
- safe handling of anonymous/complex OpenWrt UCI host sections;
- canonical DNS metadata restricted to persistent identity so DHCP hostname collisions cannot inherit another host's record.

## v4 handoff state

v4 has been installed on the real OpenWrt 25.12.5 router and the user reports that the dynamic inventory and UI are working.

The next behavior change should be treated as v5+ and preserve the invariants in `AI_CONTEXT.md` unless requirements change explicitly.

## 2026-08 — v4 maintenance hardening

- Ygg `/64` discovery now follows the netifd interface using
  `proto=yggdrasil` and prefix `class=ygg`; it no longer assumes the first
  global `/64` on `br-lan` is the Ygg prefix.
- A shared/exclusive `flock` protects client reads and serializes Pin/Unpin
  DHCP mutations. Concurrent mutations return `busy` before touching UCI.
- Recent kernel-confirmed NUD `REACHABLE` entries short-circuit redundant
  ARP/ICMP probes. Other NUD states still fall through to an active probe.
- DNS-over-Ygg was hardened from the whole `ygg` zone to the same two trusted
  source `/128` addresses used for router/LAN access.
- The tested Linux client removed Tailscale and now uses `systemd-resolved`:
  only route-only domain `~home.arpa` uses the router's Ygg DNS address;
  ordinary Internet DNS remains on Wi-Fi.
- After an unclean shutdown exposed a boot race, the client design was fixed:
  Yggdrasil owns a fixed `ygg0`; no persistent NetworkManager TUN profile is
  kept; a Yggdrasil systemd drop-in applies and reverts route-only DNS with the
  service lifecycle. Two consecutive service restarts were validated.
- The final client interface name was changed from generic `tun0` to explicit
  `ygg0`; two further service restarts and split-DNS routing were validated.

## 2026-08 — Status v5 stable-first SLAAC inventory

Live diagnosis after clients returned to the home LAN found one routed Ygg
`/64`, but dozens of IPv6 neighbour entries for some Android MACs. These were
historical rotating privacy IIDs in the kernel NDP table, not additional
prefixes issued by OpenWrt. The v4 status poll treated every observed IID as
current and could repeatedly probe old entries.

v5 changes only status selection and probing:

- a persistent canonical `config domain` address is used alone;
- otherwise, an observed modified EUI-64 address is used alone when present;
- privacy-only clients retain all observed addresses because NDP exposes no
  reliable stable/temporary marker for them;
- unselected historical privacy IIDs are no longer displayed or probed;
- no RA, DHCPv6, firewall, Yggdrasil, or client address-generation behavior is
  changed.

The new logic passed BusyBox `ash` fixtures for canonical, EUI-64, and
privacy-only cases. On the real router it reduced the affected live rows from
14 and 31 cached addresses to one stable address each while preserving online
state and privacy-only fallback.

Follow-up verification established that the Linux laptop and one affected
Android phone are also full Yggdrasil nodes connected to OpenWrt through LAN
multicast peering. Their native node addresses remain separate from the
router-prefix SLAAC addresses handled by the LAN inventory. After v5 stopped
probing the historical privacy set, the phone's NDP entries naturally fell
from 14 to two currently observed SLAAC addresses, while the status row
continued to expose one stable address and Online state.
