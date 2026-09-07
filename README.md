# Yggdrasil on OpenWrt

Make an OpenWrt router a Yggdrasil gateway for ordinary IPv6-capable LAN
clients. They receive addresses from the router's routed `/64` through
RA/SLAAC and do **not** need to run Yggdrasil themselves.

```text
Yggdrasil peers -> OpenWrt -> routed /64 -> LAN clients
                     |                       no Ygg daemon needed
                     +-- optional LuCI inventory
                     +-- optional home.arpa DNS
```

## Start here

**[Installation](docs/installation.md)** covers the automated installer,
manual setup, verification and the optional Linux split-DNS client.

The supported profile targets **OpenWrt 25.12+ with apk**, netifd, odhcpd,
dnsmasq and firewall4; the status module also needs rpcd and LuCI. The recorded
hardware baseline is OpenWrt 25.12.5, not a claim that every router has been
tested. See [validation and limitations](docs/development.md).

Before deployment, have working Internet access, a correct clock, a backup
and an alternate management path. The installer changes LAN IPv6 policy,
removes the generated ULA in this profile, and may restart netifd after
package installation. Do not run it merely to update documentation or LuCI.

## Components

| Component | Purpose | Implementation |
| --- | --- | --- |
| Core | Routed Ygg `/64`, SLAAC and trusted-source firewall policy | [Standalone router deployer](deploy/deploy-openwrt-yggdrasil.sh) |
| Status | DHCP-lifetime inventory, persistent pins and safe Pin/Unpin | [LuCI/rpcd source](source/yggdrasil-status/) |
| DNS | Optional names and trusted DNS access over Ygg | Native dnsmasq configuration in the deployer |
| Linux client | Route only `home.arpa` to the router | [Client helper and systemd drop-in](client/linux/) |

Core routing works without status or DNS. The automated **default** deploy
includes both; `--no-status` and `--no-dns` opt out. Architectural optionality
is not the same thing as the default installation profile.

The design has no NAT66, stateful DHCPv6, custom inventory database, background
inventory daemon or blanket `ygg -> lan` forwarding. Remote access is limited
to explicitly trusted source addresses; reachability does not imply trust.

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
URLs, not the destination for new builds. The deployer pins a release and its
SHA-256; development and release-candidate archives are built from source.

Guide and implementation by Plasmoid (Neuroslopped).
[Sources and acknowledgements](docs/architecture.md#sources-and-acknowledgements).
License: [GPL-3.0-or-later](LICENSE).
