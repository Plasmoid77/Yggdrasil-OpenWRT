# CHANGELOG — OpenWrt + Yggdrasil routed LAN / LuCI Status

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
