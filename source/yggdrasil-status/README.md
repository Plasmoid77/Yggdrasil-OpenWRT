# Yggdrasil Status

Standalone optional LuCI `Status -> Yggdrasil` module for OpenWrt. It does not
implement or replace the core Yggdrasil routed-LAN configuration.

## Install

Extract a verified distribution and run `sh ./install.sh` **from its extracted
directory on the OpenWrt router**, as root. The same command works from this
source directory in a checkout. Do not run the installer on a workstation.

The installer replaces the rpcd backend, ACL, menu and LuCI view. It backs up
the old module files, installs iputils-arping if missing, checks the backend,
restarts rpcd and checks the RPC methods/result. On its validation-failure
path it restores the prior module files. It does not restart networking,
firewall, Yggdrasil or odhcpd. Preserve an alternate management path.

## Behavior

Active DHCPv4 leases create dynamic rows until expiry; native `config host`
provides persistent identity. Sources merge by MAC. NDP provides runtime IPv6
only: canonical `config domain` wins, otherwise an observed modified EUI-64
wins, otherwise all observed privacy addresses remain eligible. No client
addresses are assigned or removed and no runtime history is persisted.

A LAN device running its own Yggdrasil daemon also shows its native `0200::/8`
node address, taken from the router's peer table and attributed by MAC through
the neighbour table, in a separate column from its routed-prefix LAN addresses.
A device that stops peering keeps its last known address, dimmed, for exactly as
long as its row exists; a fresh observation replaces it. The memory is a tmpfs
file pruned to existing rows, so nothing reaches flash and a reboot starts
empty. The address is never probed for presence.

Canonical metadata attaches only to persistent identities. Recent kernel
`REACHABLE` results avoid redundant probes; otherwise ARP/IPv6 probes determine
Online/Offline. The page polls clients every 15 seconds while open.

Pin defaults to hostname + MAC, without an IPv4 reservation. A requested
reservation comes from a fresh active lease, never a browser-supplied address.
Unpin requires explicit confirmation for static reservations and refuses
shared, duplicate or complex host sections. Pin/Unpin preserves domain records,
refuses pending DHCP edits and uses locking plus configuration backup/rollback.

The current backend handles one logical `lan` and `home.arpa`; multi-LAN or
custom status suffixes are not automatically inherited from deployer options.

## Versions and full documentation

The editable source path has no version suffix. Frozen distributions retain
their original labels and checksums. A newly built archive includes exact
payload hashes and Git provenance; the legacy installer banner still says v5
and is not a distribution identity.

For the full RPC contract, architecture, safety matrix and operations guide,
start at the [project repository](https://github.com/Plasmoid77/Yggdrasil-OpenWRT).
