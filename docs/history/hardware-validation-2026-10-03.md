# Hardware validation — 2026-10-03

## Tested revision and platform

Local SPb router: Cudy WBR3000UAX v1, OpenWrt 25.12.5, kernel 6.12.94,
apk, existing dual-stack Fibocom FM350 uplink. The starting installation was
deployer 3.0.0 / status v7.0; the tested result is deployer 3.0.1 /
status v7.0.1. This is an upgrade and idempotent rerun on a working router.

Runtime source: commit `383ce8187f979d71150b71bc8e0c2f0d9b1aaab9`
([PR #33](https://github.com/Plasmoid77/Yggdrasil-OpenWRT/pull/33)).
Test portability corrections:
`e3e620cfd429035e160edbd5cdfb5a19557365b4`
([PR #34](https://github.com/Plasmoid77/Yggdrasil-OpenWRT/pull/34));
these do not change the release payload or deployer.

[Status v7.0.1](https://github.com/Plasmoid77/Yggdrasil-OpenWRT/releases/tag/status-v7.0.1)
was built by the release workflow from the runtime source commit above.
Candidate and published archive bytes matched:

```text
yggdrasil-status-v7.0.1.tar.gz
SHA256 872e004e9324e3f031f2b857551fc271b8823f8ddd0d092c448649347f61fe9d
```

Private configuration/key backups stayed outside Git. The host's AmneziaVPN
remained enabled, using a phone hotspot independent of the router. The wired
LAN and Ygg SSH provided management access. Core reruns had a detached timed
recovery watchdog; acceptance was recorded only after checking the result.

## Observed results

| Operation | Verified result |
| --- | --- |
| Status-only upgrade | Installed backend/frontend matched tracked source. Network, DHCP and firewall file hashes and netifd/dnsmasq/odhcpd/Ygg process IDs stayed unchanged. |
| Router BusyBox fixtures | 32 sandbox groups passed: deployment safety, compressed-prefix matching, status writes and inventory. Fixtures use synthetic UCI/service boundaries. |
| Native UCI integration | Installed RPC backend with the router's actual UCI, OpenWrt configuration callbacks and jshn passed Pin, repeat Pin, Unpin, IPv4 reservation and confirmation, successful rollback and `rollback_failed` with retained backup. Config, change, override and lock directories were isolated; init scripts were stubs. A config domain record was preserved and live config hashes/service PIDs stayed unchanged. |
| Authenticated LuCI | A temporary read-only session loaded the actual page. Blocking only its clients RPC poll showed the stale-data warning and retained table row counts. Resuming polls cleared the warning. The session and browser cookies were destroyed afterward. |
| Deployer 3.0.1 with candidate | 28 OK / 0 FAIL. Network, DHCP and firewall files stayed byte-for-byte unchanged; private/public identity, ULA, LAN DHCPv6/RA settings and host IDs matched the pre-run snapshot. |
| Controlled reboot | Uptime reset; LAN and Ygg SSH returned. Configuration hashes and identity/RA/reservation invariants matched. IPv4, native IPv6 and Ygg probes succeeded; generated internal DNS resolved correctly and clients RPC returned valid inventory. |
| Published-latest rerun | Normal deployer invocation discovered v7.0.1 on GitHub, verified the downloaded checksum and installed it. 28 OK / 0 FAIL; critical config and identity/RA/reservation invariants remained unchanged. `restore.conf` records `status_src newest`, rather than the temporary local candidate. |
| Host and GitHub checks | Full `sh tools/check.sh` passed with required lint tools; runtime/test PR checks, main checks and release workflow passed. Frozen archive checksums were preserved. |

## Limits

The SPb checks did not cover a fresh-router installation, IPv4-only deployment,
sysupgrade or the BLG reconstruction described below. Pin/Unpin was exercised with native UCI in an isolated fixture,
not by changing a real client's DHCP record or observing a DHCP renewal.
Stub service recovery does not establish how every possible real service
failure behaves. A successful reboot verifies this router and configuration,
not the complete manual deployment matrix in the development guide.

## BLG legacy LAN reconstruction and upgrade

The remote BLG router is also a Cudy WBR3000UAX v1 running OpenWrt 25.12.5.
Its existing feed packages were Yggdrasil 0.5.12-r1, luci-proto-yggdrasil
1.1.1-r1 and yggdrasil-jumper 0.3.1-r1. Its legacy LAN had `ip6assign 64`,
`ip6class ygg0`, DHCPv6 server mode, `ra_slaac 0`, managed/other RA flags and
no ULA. There were four configured peers, two trusted sources and no native
host/domain records. No saved deployer or restore hook was present.

This was an explicit operator reconstruction on a working router, not an
automatic migration feature or a firmware upgrade. Management was through
Ygg only; the host's VPN uplink remained independent through the phone.
Private keys, peer settings, trusted sources and full recovery snapshots
stayed on the router in a protected directory, outside Git.

Before mutation, isolated native-UCI rehearsal on SPb verified the exact LAN
preparation and rejection of a repeated preparation, with live configuration
hashes unchanged. BusyBox guard rehearsals covered acceptance before timeout,
termination of an owned worker group, stale PID recovery without signalling
an unrelated process, serialization of acceptance against recovery, and a
boot watchdog that never signals a pre-boot PID. Initial independent plan
review found recovery defects; those were corrected before these rehearsals
and before BLG mutation.

Each installation phase had an integrity-checked snapshot, a detached
600-second recovery watchdog and temporary boot recovery after 180 seconds.
Acceptance occurred only after separate live checks. Reboot recovery was
armed with the original working pre-upgrade snapshot. The temporary boot
hook was removed after successful verification and all guardians exited;
protected backups and complete node settings were retained.

| Operation | Verified result |
| --- | --- |
| Core upgrade with `--no-lan` | Deployer 3.0.1 / published status v7.0.1 completed with 16 OK / 0 FAIL. Legacy LAN settings were preserved. The node key, node address, routed prefix, exact peer settings and both trusted sources matched the original baseline. Non-project network/firewall configuration was preserved. |
| Explicit LAN preparation and full deployment | Created a random ULA `/48`, removed the old sole `ip6class ygg0` restriction and enabled SLAAC. DHCPv6 server mode, `ip6assign 64`, RA flags and default were retained. Full deployment completed with 23 OK / 0 FAIL; netifd assigned both ULA and routed Ygg prefixes to LAN. Identity, peers and trusted sources still matched. |
| Installed components | All four status payload files matched tracked release source. The saved deployer matched the tested 3.0.1 file; cold-boot, peer, DNS and restore hooks were present. `restore.conf` records the pinned public `status_src v7.0.1`. |
| Live services and reachability | Router IPv4 and Ygg probes, independent Ygg SSH/ICMP and local internal DNS succeeded. `router.blg.internal` resolved to the node address through the router over both UDP and TCP from the trusted remote host. Clients RPC returned valid inventory: six rows before reboot. |
| Controlled reboot | The kernel boot ID changed and Ygg SSH returned. Network, DHCP and firewall hashes matched the final pre-reboot snapshot. Identity, peers, trusted access, ULA/SLAAC, LAN prefix assignments, payload and hooks passed again. IPv4/Ygg probes and external UDP/TCP internal DNS succeeded; clients RPC returned three rows. |

The row counts above are observed inventory snapshots, not proof of client
renewal or stability across a reboot. No physical BLG LAN client was used to
verify newly acquired SLAAC/DHCPv6 addresses or end-to-end LAN forwarding.
Native IPv6 uplink connectivity, firmware sysupgrade and a fresh installation
were not tested on BLG. The emergency full live rollback was not triggered;
the isolated guard rehearsals do not prove every service recovery scenario.
No real client reservation was changed.
