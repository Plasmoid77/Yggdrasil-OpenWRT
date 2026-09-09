# CHANGELOG — OpenWrt + Yggdrasil routed LAN / LuCI Status

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

The `AGENTS.md` invariant that NDP must not create persistent history was the
proxy for a stricter rule that still holds and is now stated directly: a
memory's lifetime never exceeds the lifetime of the row it belongs to. The
`sysupgrade` limitation is unchanged and now covers both files — OpenWrt's keep
list covers `/etc/config/`, not these paths.

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
