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

No fresh-router installation, IPv4-only deployment, sysupgrade or BLG migration
was performed. Pin/Unpin was exercised with native UCI in an isolated fixture,
not by changing a real client's DHCP record or observing a DHCP renewal.
Stub service recovery does not establish how every possible real service
failure behaves. A successful reboot verifies this router and configuration,
not the complete manual deployment matrix in the development guide.
