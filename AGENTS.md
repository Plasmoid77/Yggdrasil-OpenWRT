# Working on Yggdrasil-OpenWRT

This repository provides a routed Yggdrasil LAN profile, an optional LuCI
inventory, and optional native dnsmasq/split-DNS integration. Keep these module
boundaries intact. Do not turn a maintenance task into a network redesign.

## Read only the context needed for the task

- Start with [README](README.md) for scope and supported platform.
- Deployment: `deploy/deploy-openwrt-yggdrasil.sh` and
  [installation](docs/installation.md).
- Inventory, Pin/Unpin or RPC: `source/yggdrasil-status/` and the data model,
  RPC contract and safety rules in [architecture](docs/architecture.md).
- Recovery or Linux DNS: `client/linux/` and [operations](docs/operations.md).
- Tests, packaging, compatibility pitfalls: [development](docs/development.md),
  `tests/` and `tools/`.
- Read changelog/incident history only when investigating the relevant change.

`CLAUDE.md` imports this file. Do not maintain another copy of these rules.
`AI_CONTEXT.md`, `QUICKSTART.md` and `REFERENCE_CONFIG.md` are transition
pointers for older links/comments, not competing sources of truth.

## Invariants and change boundaries

1. Preserve Ygg identity/private keys, SLAAC-only LAN policy and trusted `/128`
   access. No NAT66 or blanket forwarding. Keep native-node and routed-LAN
   addresses distinct. Do not rename a working remote management interface.
2. Active DHCPv4 leases create dynamic rows; native `config host` creates
   persistence; merge by MAC. NDP only enriches addresses and must not extend
   row lifetime or create persistent history. A remembered Yggdrasil node
   address is bounded by the same rule: tmpfs only, pruned to existing rows,
   never extending a row's lifetime and never reaching flash.
3. Prefer canonical IPv6, then an **observed** modified EUI-64, then all unique
   observed privacy addresses. Do not invent EUI-64 reachability or force it
   on clients. Only persistent identities may inherit canonical DNS metadata.
4. Presence uses a recent kernel `REACHABLE` shortcut, otherwise ARP/IPv6
   probes. Other NUD states do not decide presence. Do not remove the shortcut
   by following old prose that claimed every lookup must send a new probe.
5. Pin defaults to no IPv4 reservation. Static reservation deletion requires
   confirmation; shared, duplicate and complex host records are protected.
   Refuse pending DHCP UCI changes; preserve locking and rollback.
   Pin/Unpin must not silently modify/delete `config domain`.
6. Status-only installation must not restart networking, firewall, Yggdrasil
   or odhcpd. Assume the maintainer may connect through Yggdrasil.
7. Target BusyBox ash/OpenWrt. Keep the deployer self-contained; do not add
   runtime Python/Node, a database, daemon, cron or a custom DNS resolver.
8. Never expose private keys in process arguments, diagnostics, fixtures or
   commits. Use synthetic identities in tests. Hardware operations need
   explicit scope, backups and another management path.

## Verification and delivery

Run `sh tools/check.sh`. It checks syntax, lint, links, existing secret tests,
backend fixtures and deterministic packaging; it does not access a router.
Missing required tools fail the check. A documented explicit lint skip is a
partial local check, never equivalent to full CI success.

For behavior changes, add a regression test first. Reconcile code, contracts
and tests by investigating intent; do not blindly assume one cannot be wrong.
Update only the canonical affected guide, not every document. Keep package
README self-contained, but put the full contract in architecture.

Use small reversible commits and PRs. Preserve frozen archives and their
checksums; do not overwrite a released version or break public download paths.
A source rename must update CI, tests and live links without modifying archive
contents. Distinguish code changes, packaging changes and hardware validation
in the final report. Never claim a router test you did not run.

When giving terminal instructions, use one contiguous copy/paste block for a
single sequential operation. Keep unrelated Android DNS and modem setup out
of this project's implementation.
