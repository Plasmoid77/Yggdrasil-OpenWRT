# Yggdrasil on OpenWrt

Make an OpenWrt router a Yggdrasil gateway for ordinary IPv6-capable LAN
clients. The router's routed `/64` is added to the LAN **beside** the IPv6 it
already has - native prefix, stock ULA - on the stock RA/DHCPv6
configuration: clients form SLAAC addresses from it, DHCPv6 clients also get a
stateful address the router can reserve by `--host`, and they do **not** need
to run Yggdrasil themselves. Native IPv6 keeps working; LAN hosts can reach
Yggdrasil through the router, Yggdrasil reaches the LAN only from trusted nodes.

```text
Yggdrasil peers -> OpenWrt -> routed /64 -> LAN clients
                     |                       no Ygg daemon needed
                     +-- optional LuCI inventory
                     +-- optional private DNS (home.arpa / site.internal)
```

## Start here

**[Installation](docs/installation.md)** covers the automated installer,
manual setup, verification and the optional Linux split-DNS client.

The supported profile targets **OpenWrt 25.12+ with apk**, netifd, odhcpd,
dnsmasq and firewall4; the status module also needs rpcd and LuCI. The recorded
hardware baseline is OpenWrt 25.12.5, not a claim that every router has been
tested. See [validation and limitations](docs/development.md#automated-coverage-and-remaining-manual-work).

Before deployment, have working Internet access, a correct clock, a backup
and an alternate management path. The installer adds the routed `/64` to the
LAN beside its native prefix and ULA (both stay), makes the router the LAN's
RA server and default router, and may restart netifd after package
installation. Do not run it merely to update documentation or LuCI.

## Components

| Component | Purpose | Implementation |
| --- | --- | --- |
| Core | Routed Ygg `/64` overlaid on the LAN's own IPv6, DHCPv6 reservations, trusted-source firewall policy, LAN-to-Yggdrasil egress | [Standalone router deployer](deploy/deploy-openwrt-yggdrasil.sh) |
| Status | DHCP-lifetime inventory, persistent pins and safe Pin/Unpin | [LuCI/rpcd source](source/yggdrasil-status/) |
| DNS | Optional names and trusted DNS access over Ygg | Native dnsmasq configuration in the deployer |
| Linux client | Route only the routers' zones (`home.arpa` by default, or e.g. `spb.internal`) to the router | [Client helper and systemd drop-in](client/linux/) |

Core routing works without status or DNS. The automated **default** deploy
includes both; `--no-status` and `--no-dns` opt out. Architectural optionality
is not the same thing as the default installation profile.

The design has no NAT66, custom inventory database, background inventory
daemon or unsolicited `ygg -> lan` forwarding. The deployer preserves the
LAN's DHCPv6 mode, SLAAC flags and ULA; it sets `ra=server` and `ra_default=2`
so routed replies work without a native uplink. A 1.x router is reinstalled,
not migrated automatically. Remote access is limited to explicitly
trusted source addresses; reachability does not imply trust.

## Private DNS zones

The deployer enables DNS by default and serves `home.arpa` unless
`--dns-domain` selects another zone. Give independent sites distinct names,
for example `--dns-domain spb.internal` and `--dns-domain blg.internal`.
`.internal` is [reserved by ICANN for private use](https://www.icann.org/en/board-activities-and-meetings/materials/approved-resolutions-special-meeting-of-the-icann-board-29-07-2024-en#section2.a);
it does not provide public DNS resolution.

With `spb.internal`, generated names include `router.spb.internal` for the
router's Ygg node address and `<host>.spb.internal` for a `--host` reservation
under the routed LAN prefix. `--dns-host NAME=ADDR` adds an explicit address.
Only trusted Ygg sources can query the router remotely.

Choosing a zone on the router does not configure a remote client's resolver.
Use split DNS to send only `spb.internal` queries to that router and keep
Internet DNS on the normal connection or VPN. For several routers, the
Linux example uses a local dnsmasq to send each zone to its own router;
the routers do not forward each other's zones. Persist the zone and host
definitions in the deployer's settings file: an ordinary rerun that omits
`--dns-domain` returns to `home.arpa`.

See [choosing a zone](docs/installation.md#choose-a-private-dns-zone),
[Linux split DNS](docs/installation.md#6-optional-linux-split-dns) and
[DNS diagnosis](docs/operations.md#check-the-configured-zone-and-client-resolver).

## Reservations, status and recovery

`--host` reserves an IPv6 suffix through native odhcpd, in every LAN prefix;
it does not reserve an IPv4 address. Use a DUID for clients whose DUID does
not carry their MAC, and include the MAC when the status page should identify
the device. DHCPv6-capable clients can use the reservation; SLAAC-only clients
continue using SLAAC. See [reservation setup](docs/installation.md).

LuCI pins are normal `config host` records. Pin defaults to name + MAC;
address reservations are optional, and Unpin protects existing reservations.
The page reports current DHCP-backed clients and persistent hosts, not a
permanent device history. See [the inventory contract](docs/architecture.md#inventory-data-model).

Publishing a status release does not upgrade an installed router. Follow
[updates](docs/operations.md#update-deliberately) for status-only installation
or a full deployer rerun. The uplink recovery hook restores missing components
from saved choices; local custom archives cannot be downloaded again
automatically. Keep the complete deployment settings and a separate backup.

## Documentation

| Question | Read |
| --- | --- |
| How do I install and verify it? | [Installation](docs/installation.md) |
| How does it work, and why these decisions? | [Architecture and contracts](docs/architecture.md) |
| How do I diagnose, update, recover or remove it? | [Operations](docs/operations.md) |
| How do I test, package and contribute safely? | [Development](docs/development.md) |
| What changed? | [Changelog](CHANGELOG.md) |
| What should a coding agent read? | [Agent instructions](AGENTS.md) |

The [SLAAC incident report](docs/history/slaac-address-fix.md) is retained as
historical evidence. Current behavior is defined in the architecture guide,
not by historical release notes. Old root-level guide names are short
transition pointers, not additional specifications.

## Working on the repository

Run host-side checks from a checkout:

```sh
sh tools/check.sh
```

Host requirements and the distinction between synthetic tests and router
validation are in [Development](docs/development.md). Do not run the router
installer on a development workstation.

`source/` is the editable implementation. GitHub Releases distribute versioned
status packages. `packages/` is a frozen compatibility cache for existing raw
URLs, not the destination for new builds. The deployer installs the newest
published release and checks it against the SHA-256 published beside it;
development and release-candidate archives are built from source.

Guide and implementation by Plasmoid (Neuroslopped).
[Sources and acknowledgements](docs/architecture.md#sources-and-acknowledgements).
License: [GPL-3.0-or-later](LICENSE).
