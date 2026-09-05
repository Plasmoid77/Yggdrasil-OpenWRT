# Yggdrasil Status v5 - Stable SLAAC Inventory + Pin / Unpin

This package updates only the optional `Status -> Yggdrasil` LuCI module.

Inventory lifetime:

```text
active DHCPv4 lease -> dynamic row until lease expiry
config host         -> persistent row
ip -6 neigh         -> runtime SLAAC enrichment only
config domain       -> optional canonical Ygg IPv6 / DNS metadata for a persistent host
```

IPv6 selection is stable-first:

```text
canonical config domain -> show only the canonical address
observed modified EUI-64 -> show only that stable SLAAC address
privacy-only client      -> show all observed addresses
```

This prevents old privacy IIDs in the kernel NDP table from flooding the UI or
being kept alive by repeated presence probes. It does not assign, remove or
otherwise change addresses on LAN clients; SLAAC address generation remains a
client decision.

Management from the Yggdrasil status page:

```text
Dynamic     [Pin]
Pinned      [Unpin]
Persistent  [Unpin]
Static      [Manage]
Protected   [Manage]
```

`Pin` creates a normal OpenWrt `config host` containing hostname + MAC. `Reserve current IPv4` is optional and **off by default**. When enabled, the backend re-reads the current active DHCP lease and stores that IPv4 as the reservation; it does not trust a stale browser value.

`Unpin` removes a simple matching single-MAC `config host`. If its DHCP lease is still active, the device immediately falls back to a dynamic row and remains visible until that lease expires.

Safety behavior:

- A static DHCP reservation is never removed silently. The UI uses `Manage` and requires an explicit destructive confirmation before deleting the host section and its reserved IPv4.
- A `config host` containing multiple MAC addresses is never deleted from this page.
- A MAC present in multiple `config host` sections is never deleted from this page.
- A `config host` containing additional/unknown DHCP options is never deleted from this page; edit it through standard `Network -> DHCP and DNS` instead.
- Existing normal OpenWrt host records are distinguished from rows created by the Pin button.
- `config domain` records are never deleted by Pin or Unpin.
- Canonical `config domain` metadata is attached in the dashboard only to a persistent host identity, preventing a DHCP-only client with a colliding hostname from inheriting another device's canonical record.
- Pin/Unpin refuses to run while the `dhcp` UCI package has uncommitted changes.
- `/etc/config/dhcp` is backed up before every mutation and restored if the UCI commit or `dnsmasq reload` fails.
- Pin validates MAC and hostname server-side. A requested IPv4 reservation is taken only from a currently active lease and is validated server-side.
- Pin/Unpin mutations are serialized with `flock`; a concurrent mutation returns `busy` without touching UCI.
- Ygg prefix discovery follows netifd `proto=yggdrasil` and the prefix class netifd derived from that interface's name, so another global LAN `/64` is not mistaken for the routed Ygg prefix and any interface name works.
- Canonical and observed modified EUI-64 addresses take precedence over rotating privacy IIDs. Privacy-only clients still retain multiple observed addresses.
- A recent kernel NUD `REACHABLE` result avoids a redundant active probe; all other neighbor states still fall through to ARP/IPv6 probing.

The installer backs up the existing status-module files, installs `iputils-arping` if needed, validates the backend, restarts only `rpcd`, checks that `clients`, `pin` and `unpin` are registered, and rolls the module files back automatically if post-install validation fails.

It does **not** reload the network, restart the firewall, restart Yggdrasil or restart odhcpd.

Run on OpenWrt as root:

```sh
tar -xzf /tmp/yggdrasil-status-v5.tar.gz -C /tmp
/tmp/yggdrasil-status-v5/install.sh
```
