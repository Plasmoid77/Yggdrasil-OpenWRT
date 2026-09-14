# Plan record: managed (stateful DHCPv6) LAN addressing (2026-09-14)

Historical design record for deployer 1.9.0 / status v5.5. Current behaviour
is defined in [architecture](../architecture.md); this file is evidence of
how the decisions were reached and reviewed, not a specification.

Repo: ~/Projects/Yggdrasil-OpenWRT, branch `dhcpv6-managed-lan` (from main 1c05fe3).
Revision 2, 2026-09-14, after two independent reviews (Codex gpt-5.6-sol and
gpt-6-astra, both xhigh). Where they disagreed (Q1) the astra recommendation
was taken; everything else below is the intersection of both reviews plus
source-verified odhcpd facts.

## Goal (owner's intent, 2026-09-14)

The router alone owns LAN addressing inside the routed Yggdrasil /64: it
assigns, knows, reserves and names client addresses. Clients are passive;
nothing is configured on hosts. The LuCI status table shows the one stable
address a device is reachable at. Ordinary (ISP) IPv6 is not used at all on
these routers; the Yggdrasil /64 is the only global IPv6.

Accepted cost: Android (and any client without a DHCPv6 client) gets no
address from the Yggdrasil prefix. Owner's position: a phone that needs
Yggdrasil runs its own Yggdrasil client and is a full node (2xx: address).

Honest limits of the promise (from the reviews):
- "every client" = every client with a DHCPv6 client whose DUID is DUID-LLT
  or DUID-LL (MAC-matchable) *or* that is reserved by explicit DUID[%IAID].
- "one address" = one address per IA_NA as odhcpd assigns it; a client may
  request more, and a still-valid SLAAC address lingers after migration until
  its own lifetime ends.
- "named" = odhcpd writes `<hostname>.lan` only for leases carrying a valid
  hostname; the deployer's derived `home.arpa` record covers reserved hosts.

## Evidence

Live experiment on the test router (OpenWrt 25.12.5, odhcpd `5d7be43`),
2026-09-14:
- odhcpd serves stateful DHCPv6 from the netifd-delegated Yggdrasil prefix
  (`ipv6-prefix-assignment` on `lan`, local-address `...::1`) like any PD.
- `config host` with `name` + `mac` + `hostid=10` reserved `303:...::10` for a
  Debian host (dhcpcd, DUID-LLT containing the MAC).
- With `ra_slaac=0` the host came up with exactly one global address, the
  reserved one, and uses it as source for outgoing traffic.
- odhcpd writes `/tmp/hosts/odhcpd.hosts.lan`; dnsmasq resolves
  `<host>.lan` to the DHCPv6 address with no extra config.
- Reachability from a trusted Yggdrasil /128 through the `ygg` zone unchanged.
- A `config host` with `ip=192.168.1.235` and **no** `hostid` produced
  `303:...::235` — the implicit suffix. Verified live and in source.
- A BMC with DUID `00030001000000000000` (zero MAC) on two ports (IAID
  11111/22222) got dynamic leases; a MAC-keyed `config host` cannot match it.
- Android phone: no address, as expected.

Verified in odhcpd source `5d7be43` (the version OpenWrt 25.12.5 pins):
- `config.c:702-715`: `hostid` is parsed with `strtoull(..., 16)` (up to 64
  bits); when absent, it is derived from the IPv4 last octet as decimal digits
  read as hex nibbles (`.235 -> 0x235`).
- `dhcpv6-ia.c:986-990`: the MAC used for `config host` matching is taken only
  from a 14-byte DUID-LLT (type 1) or a 10-byte DUID-LL (type 3); any other
  DUID yields `ff:ff:ff:ff:ff:ff` and never matches by MAC.
- `dhcpv6-ia.c:1047-1049`: explicit `duid`(+IAID) match takes precedence over
  the MAC match.
- `dhcpv6-ia.c:1217`, `assign_na():431`: `hostid` 0 means "allocate
  dynamically", so 0 is not a valid reservation.

## Current state to change

- Deployer `deploy/deploy-openwrt-yggdrasil.sh` v1.8.0, LAN stage (~927):
  `dhcpv6=disabled`, `ra=server`, `ra_slaac=1`, `ra_flags=none`,
  `ra_default=2`, `ra_preference=medium`; `check` asserts DHCPv6=disabled and
  RA SLAAC=1; `ra_flags`, `ra_default`, `ra_preference` are not checked.
- The LAN stage reloads `network` and restarts `odhcpd`; dnsmasq restarts only
  in the optional DNS stage (`--dns`).
- A rerun without `--trusted` removes the generated trusted rules (~981) and
  rewrites jumper/multicast sections (~723, ~782).
- Docs state "SLAAC rather than stateful DHCPv6" with a weak rationale
  (architecture.md:49, :440; README.md:42; installation.md:15; AGENTS.md:25;
  development.md regression matrix).
- Status module: rows come from `/tmp/dhcp.leases` (DHCPv4) and `config host`
  only (`emit_dynamic_leases`, ~1042); `build_known_ipv6` (~871) prefers
  `config domain` canonical, else an observed EUI-64 (which then suppresses
  every other address), else all NDP-observed addresses; remembered addresses
  in `/etc|/tmp/yggdrasil-status-lan` are replayed. `ipv6leases` is never read.
  Unpin refuses any `config host` with options beyond `name`/`mac`/`ip`
  (~167), so a `hostid` makes the record "complex".

## Decisions (revision 2)

D1. RA stays; only the A flag goes away. Managed-mode UCI on `dhcp.<lan>`:
      dhcpv6=server, ra=server, ra_slaac=0,
      ra_flags = list 'managed-config' + list 'other-config'  (uci_del, then
      two uci_add_list calls, matching the existing `none` pattern),
      ra_default=2, ra_preference=medium.
    Reverting to SLAAC replaces the list with a single `none`.
    `network.<lan>.ip6assign=64`, `ip6class=<runtime YGG_CLASS>` unchanged.
    The stage also asserts that `dhcpv6_na` is unset or 1 and `ra_offlink` is
    unset or 0 on `dhcp.<lan>` (refuse with a clear message otherwise; the
    deployer does not silently override operator settings it never wrote).

D2. Opt-in, deployer 1.9.0. New paired switches `--dhcpv6` / `--slaac`
    (config file: `[flags] dhcpv6` / `slaac`); last one wins, like the other
    paired flags. Default stays SLAAC-only, so an ordinary rerun changes
    nothing. Flipping the default is deferred until the status module reads
    leases and the migration procedure has been exercised on both routers.
    `--host` (D3) requires managed mode; with `--slaac` or `--no-lan` it is a
    usage error, not a silent no-op.

D3. Reservations in the deployer:
      --host NAME=MAC=HOSTID
      --host NAME=duid:HEX[%IAID]=HOSTID
    and a `[hosts]` config-file section with the same lines. Rules:
    - HOSTID: 1..16 hex digits, value != 0 (dynamic in odhcpd), != 1 (the
      router's own LAN address), unique among all `--host` lines and among
      existing `config host` sections (explicit `hostid` or the implicit
      `ip`-derived one).
    - NAME: bare hostname, unique among `--host` lines.
    - The reserved address is computed as prefix (64 bits) + HOSTID
      zero-extended to 64 bits, rendered through the same 4-hextet formatting
      for any width (no string concatenation).
    - Writes one `config host` with `name`, `mac` or `duid`, `hostid`. An
      existing section for the same MAC/DUID: update `name`/`hostid` in place
      only if it is a plain section (options within name/mac/duid/ip/hostid,
      single MAC, not duplicated); otherwise refuse and name the section.
    - Mutation happens under the same lock file the status module uses for
      `config host` edits, and refuses when `uci changes dhcp` is non-empty.
    - The IPv4 side is untouched: `ip` is neither set nor removed. Existing
      `config host` with `ip` and no `hostid` are listed in the deployer's
      report as "implicit IPv6 reservation ::<octet>", never modified.
    - Derived DNS: when the DNS module is on, a `config domain` record
      `NAME.<dns-domain> -> <reserved address>` is written and tagged as
      deployer-owned (marker option, same mechanism `--dns-host` records use
      or a new `option ygg_managed 1` if none exists). Deployer-owned records
      whose NAME is no longer supplied are removed on rerun; foreign records
      are never touched. Without `--dns` the `.lan` name from odhcpd's hosts
      file is what exists, and the report says so.

D4. `check` per mode. Managed: dhcpv6=server, ra=server, ra_slaac=0,
    ra_flags contains both managed-config and other-config (membership, not
    order), ra_default=2, ra_preference=medium, odhcpd enabled+running, and
    within `--wait` seconds `ubus call dhcp ipv6leases` shows the LAN device
    with at least one bound IA_NA when any `--host` was given (otherwise the
    device entry existing is enough). SLAAC mode: today's checks plus
    ra_flags = none.

D5. Migration is a documented procedure (operations.md), not automation:
    backup, second management path, rerun with the full original argument set
    plus `--dhcpv6` (the deployer already replaces trusted rules and
    jumper/multicast sections from its arguments — omitting `--trusted`
    removes access), verify a lease and inbound reachability, then expect
    existing SLAAC addresses to linger until their valid lifetime ends (odhcpd
    default cap 90 min, client-specific; measured, not assumed), then a
    control reboot (known `ygg0` pending race). Rollback = `--slaac` with the
    same arguments; it does not remove `hostid` options or derived domain
    records, and the doc says so.

D6. Documentation: architecture.md decision-table row rewritten with the real
    reasoning: router-owned addressing gives a stable inbound address without
    host configuration; RFC 7217/4941 addresses are observable via NDP but
    not derivable or stable, so no router-side rule can pick "the" address;
    Android excluded by design; DUID-LLT/LL requirement for MAC matching;
    implicit `ip`-derived hostid. README, installation (both modes, the
    `--host` syntax), operations (D5 procedure, `ubus call dhcp ipv6leases`,
    Android note, BMC/zero-DUID note), development.md regression matrix
    (invariant becomes "LAN addressing mode exactly as configured"), AGENTS.md
    line 25, CHANGELOG.

D7. Tests: new `tests/deploy-lan-mode.sh`, registered in `tools/check.sh`
    (both `sh` and BusyBox `ash` runs like the others). Cases: default =
    SLAAC values unchanged; `--dhcpv6` writes managed values with two list
    entries; `--dhcpv6 --slaac` and the reverse (last wins); `[flags]`
    equivalents; `--host` parsing (valid MAC form, valid duid form with and
    without %IAID, bad MAC, hostid 0/1/17-digits/duplicate, duplicate NAME,
    `--host` with `--slaac`/`--no-lan` rejected); implicit-reservation
    collision detection against a fixture `config host` with `ip`; old config
    files without the new section still parse. Extend
    `tests/deploy-config-file.sh` helper list for the new functions.

D8. Status module, narrow scope, same branch (status v5.5):
    - New source `ubus call dhcp ipv6leases`: for each bound IA_NA, derive the
      MAC from a DUID-LLT/DUID-LL DUID; attribute the address to the row with
      that MAC. No hostname-based matching.
    - Address selection order becomes: `config domain` canonical > DHCPv6
      lease address > observed EUI-64 > observed NDP set > remembered set.
      A lease address is reported with a `source: "dhcpv6"` marker and
      `reserved: 1` when a `config host` for that MAC carries `hostid` (or an
      `ip` with the implicit suffix equal to the lease).
    - Remembered SLAAC addresses under the same prefix are dropped for a row
      once a lease address exists for it.
    - Rows still originate from DHCPv4 leases and `config host`; a DHCPv6-only
      client has no row. Documented as a known limit.
    - Unpin's "complex host" rule is extended so that a section whose only
      extra option is `hostid` remains unpinnable (the deployer and Pin both
      write it).
    Out of scope (phase 2): IPv6 Pin dialog (hostid), rows for DHCPv6-only
    clients, DUID-keyed rows.

D9. Release coordination: the deployer follows the newest status release. The
    1.9.0 deployer must work with status v5.4.1 (it does: managed mode only
    adds a lease address the module already sees via NDP), and status v5.5
    must work with a 1.8.x-deployed SLAAC router (no leases -> unchanged
    behaviour). Both stated in the CHANGELOG.

## Deliverables (this branch)

1. Deployer 1.9.0: D1-D5, help text, config-file format, report lines.
2. Status module v5.5: D8 backend changes, frontend marker for lease/reserved.
3. Docs per D6; plan file removed from the tree before merge (its content
   lives in architecture.md and CHANGELOG).
4. Tests per D7 passing under `tools/check.sh`.
5. Validation on the test router (already in managed state, one reserved
   host): `--slaac` rerun -> legacy state verified; `--dhcpv6 --host ...`
   rerun -> managed state verified, reserved address, `.lan` and `home.arpa`
   names, inbound reachability from a trusted /128, control reboot.

## Implementation review (2026-09-14, Codex gpt-6-astra, effort high)

Twelve findings on the first three commits, all confirmed against the code
and fixed in the branch before the pull request:

1. A rerun without a mode switch reset a managed router to SLAAC -> the
   default became `keep`: `resolve_lan_mode` reads `dhcp.<lan>.dhcpv6` in
   preflight, a fresh router gets SLAAC.
2. The DHCP lock was taken after changes were staged -> taken first, with a
   fresh pending-changes check, before any `uci set`.
3. `--dns-host NAME` beside `--host NAME` left two answers -> refused.
4. Two IAIDs of an all-zero DUID were one "client" -> `mac_in_key` returns
   nothing for an all-zero MAC.
5. A section reserved by a DUID-LLT/LL was not matched by a `--host` MAC
   line (and vice versa; DUID lists ignored) -> `section_is_client`.
6. `hostid='0x20'` and `%000a` escaped the duplicate checks -> normalised.
7. `ygg_host_<name>` existing as a non-host section was converted ->
   `uci get` on the id, any type refuses.
8. Hostnames odhcpd rejects (leading/trailing `-`, >63) passed -> refused.
9. Unbound DHCPv6 offers were shown as addresses -> `flags` must contain
   `bound`.
10. Unpin of an implicit (`ip`-derived) IPv6 reservation never reached
    odhcpd -> `commit_and_reload_dhcp` reloads odhcpd whenever DHCPv6 is
    served; the confirmation text says so.
11. Verification accepted a running but disabled odhcpd and queried leases
    only with `--host` -> `odhcpd enabled` check, leases listed in every
    managed run.
12. Docs told users to remove `hostid` "through the deployer", which has no
    such operation, and claimed unconditional DNS cleanup -> rewritten.

The plan itself is kept here as the design record; current behaviour is
defined by the architecture guide.
