# MANIFEST.md — distribution contents

This archive is the complete handoff package for the current OpenWrt + Yggdrasil routed-LAN project state.

## Primary documents

- `README.md` — full human installation/architecture guide; also contains a maintainer/AI handoff section.
- `QUICKSTART.md` — compact tested installation path with verification.
- `AI_CONTEXT.md` — compact authoritative context for another AI agent or maintainer; includes data model, RPC contract, invariants, known limitations, and rewrite rules.
- `CHANGELOG.md` — architectural evolution and why older approaches were abandoned.
- `TEST_PLAN.md` — required regression matrix for a rewrite or future release.
- `REFERENCE_CONFIG.md` — compact generalized final UCI/configuration model.
- `MANIFEST.md` — this file.
- `checksums.sha256` — SHA-256 for all files in this directory tree except the checksum file itself.

## Ready-to-install package

- `packages/yggdrasil-status-v5.tar.gz` — current installable v5 LuCI status module.
- `packages/yggdrasil-status-v5.tar.gz.sha256` — current package checksum.
- `packages/yggdrasil-status-v4.tar.gz` and `.sha256` — previous v4 release.

## Linux client split DNS reference

- `client/linux/yggdrasil-split-dns` — applies/reverts route-only
  `~home.arpa` DNS after the Ygg interface exists.
- `client/linux/yggdrasil.service.d/split-dns.conf` — systemd lifecycle
  integration for the helper.

## Unpacked source

- `source/yggdrasil-status-v5/install.sh`
- `source/yggdrasil-status-v5/README.md`
- `source/yggdrasil-status-v5/root/usr/libexec/rpcd/luci.yggdrasil-status`
- `source/yggdrasil-status-v5/root/usr/share/rpcd/acl.d/yggdrasil-status.json`
- `source/yggdrasil-status-v5/root/usr/share/luci/menu.d/yggdrasil-status.json`
- `source/yggdrasil-status-v5/www/luci-static/resources/view/status/yggdrasil.js`

The unpacked source is byte-for-byte equivalent to the contents of the ready-to-install v5 archive at packaging time.

## Current implementation identity

Status package:

```text
yggdrasil-status-v5.tar.gz
SHA-256: 26063dd0d0b89599e8123a6a67350b6d2606336c2080010e6474eef4358679a4
```

## Deliberately not included

Deployment-specific router snapshots, private keys, real trusted Ygg addresses, real LAN MAC addresses, and old intermediate packages are not included in this distributable handoff bundle.

That omission is intentional:

- they are not required to understand or rewrite the design;
- old intermediate files can mislead a future agent about the final architecture;
- deployment-specific identifiers should not be baked into a generalized public guide.
