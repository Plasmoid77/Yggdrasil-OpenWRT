# Installation

This is the current automatic and manual installation path. Read
[architecture](architecture.md) before adapting topology or firewall policy.
The recorded hardware results are historical evidence, not tests performed by
this documentation revision. Commands run on the router unless marked as
Linux-client commands; run only with backups and another management path.

## Result

```text
Yggdrasil routed /64 -> OpenWrt -> br-lan (beside native IPv6 and the ULA) -> RA/DHCPv6 -> LAN clients
```

LAN devices receive routed Yggdrasil IPv6 without running Yggdrasil. The
routed `/64` is added beside the prefixes the LAN already has - the native
one when the uplink has IPv6, the stock ULA - and the router's stock RA/DHCPv6
configuration is kept: clients form SLAAC addresses and, when they run a
DHCPv6 client, also take a stateful address per prefix that `--host` can
reserve. Native IPv6 keeps working as before; on an IPv4-only uplink the LAN
gets Yggdrasil + ULA. LAN hosts may initiate connections into Yggdrasil
through the router (`--no-lan-forward` turns that off). NAT66 is not used.
Remote access is limited to trusted Ygg `/128`s. See
[architecture](architecture.md) for the reasoning.

Optional modules provide a LuCI inventory, `home.arpa` names, and route-only
Linux split DNS.

## Automated path

`deploy/deploy-openwrt-yggdrasil.sh` configures the router-side stages below; client-side split DNS remains manual.
Run it in a root shell **on the router**. OpenWrt ships `wget`
(`uclient-fetch`) with a CA bundle and no `curl`:

```sh
wget -O deploy-openwrt-yggdrasil.sh \
  https://raw.githubusercontent.com/Plasmoid77/Yggdrasil-OpenWRT/main/deploy/deploy-openwrt-yggdrasil.sh
sh deploy-openwrt-yggdrasil.sh -y \
  --peer tls://<host>:<port> \
  --peer wss://<host>:<port> \
  --trusted <TRUSTED_YGG_IPV6>
```

`-y` skips the confirmation prompt. Drop it to be asked once before anything is
applied, and to be asked for the trusted addresses if `--trusted` was omitted.

Peers given with `--peer`/`--peers-file` replace the configured set. Without
any, the existing `yggdrasil_ygg0_peer` sections are kept, so a re-run for
another stage — a new `--trusted` address, the DNS module — does not need the
peers repeated. On a router that has none the script warns that the node gets
an address but stays isolated until peers are added. Pick current entries from
[`yggdrasil-network/public-peers`](https://github.com/yggdrasil-network/public-peers).

A root login starts in `/root`, which lives on the overlay and survives a
reboot. `/tmp` is a tmpfs: nothing prunes it on a timer, but it costs RAM and is
empty again after a restart.

Piping works too, but then `stdin` is the pipe: the script cannot ask for the
trusted addresses interactively, so pass `--trusted` explicitly for remote access, and there is
no local copy to check a checksum against.

```sh
wget -qO- https://raw.githubusercontent.com/Plasmoid77/Yggdrasil-OpenWRT/main/deploy/deploy-openwrt-yggdrasil.sh \
  | sh -s -- --peer tls://<host>:<port> --trusted <TRUSTED_YGG_IPV6>
```

`-q` suppresses download progress output,
and `-O -` writes the download to standard output instead of a file.

### One settings file instead of a long command line

Everything that describes the node can be kept in one file on the router and
passed with `--config FILE`. One value per line under a `[section]` header; `#`
starts a comment, blank lines are ignored, an unknown section or flag is an
error. Each line goes through the same validation as the option it stands for.

```ini
[peers]                 # as --peer
tls://<host>:<port>
wss://<host>/<path>

[trusted]               # as --trusted
<TRUSTED_YGG_IPV6>

[private-key]           # as --private-key-file: the 128 hex characters
<PRIVATE_KEY>

[iface]                 # as --iface        (default ygg0)
ygg0
[lan]                   # as --lan          (default lan)
lan

[dns-domain]            # as --dns-domain   (default home.arpa)
home.arpa
[dns-router]            # as --dns-router   (default router)
router
[dns-hosts]             # as --dns-host, NAME=ADDR
nas=<YGG_IPV6>

[hosts]                 # as --host: DHCPv6 reservations (the LAN's stock DHCPv6 server)
nas=<MAC>=10            # <every LAN prefix>::10 for the client with this MAC
laptop=<MAC>+duid:<HEX>=20  # DUID for odhcpd, MAC for the status page
bmc=duid:<HEX>%<IAID>=21  # by DUID (and IAID) alone

[status-version]        # as --status-version
v5.4
[status-pkg]            # as --status-pkg
/root/yggdrasil-status.tar.gz

[flags]                 # the switches, one per line
no-jumper
no-dns
no-lan-forward          # LAN hosts may not initiate connections into Yggdrasil
# dhcpv6 / slaac        # 1.x only: 2.0 refuses them, delete the line
```

```sh
scp ygg.conf root@<router>:/root/ygg.conf
ssh root@<router> 'chmod 600 /root/ygg.conf; sh deploy-openwrt-yggdrasil.sh -y --config /root/ygg.conf'
```

Options are applied in the order given: a `--peer`, `--trusted` or `--dns-host`
after `--config` is added to the file's list, a later single value such as
`--iface` wins, and `--config` may be repeated. `-n`/`--dry-run`, `-y`/`--yes`
and `--wait` describe the run rather than the node and stay on the command line.
When the file holds the key, keep it mode 600 — the script warns if it is
readable beyond its owner. Key precedence is `--private-key-file`, then the
file's `[private-key]`, then `YGG_PRIVATE_KEY`; no option takes the key as a
value, because `/proc/<pid>/cmdline` is world readable.

### Startup and management safety

Install unrelated netifd protocol-handler packages first and let their own
reboots finish. Yggdrasil deployment may need a netifd restart to register its
protocol. The script performs it before configuration writes when possible.
Read [startup precautions and recovery](operations.md#startup-precautions)
for the recorded rare pending-interface race, Wi-Fi bootstrap and detached
execution. Do not assume every SSH path survives the restart.

One run covers all three parts, section 5 included: it publishes
`router.<zone>` for the router, `<name>.<zone>` for every `--host` reservation
and `--dns-host NAME=ADDR` for anything else, and opens port 53 to the trusted
addresses only. The zone is `--dns-domain` (default `home.arpa`; one per site,
e.g. `spb.home.arpa`, or a name under `.internal`). The names are generated
from the node's current address and routed /64 into `/tmp/hosts` on every
ifup of the Ygg interface, so they follow a node key changed later in LuCI; a
Linux client's split DNS still names the router's address and needs updating
after such a change. `--no-dns` skips that part, the way
`--no-lan`, `--no-firewall` and `--no-status` skip theirs. Only the client side
of section 6 stays manual — the script runs on the router and cannot reach the
client.

To keep an existing Yggdrasil address on a redeployment or on new hardware, hand
the old private key over in a file rather than on the command line, which is
world readable through `/proc/<pid>/cmdline`:

```sh
ssh root@<router> 'umask 077; cat > /tmp/ygg.key' < old-private.key
ssh root@<router> sh -s -- --peer ... --trusted ... -y \
    --private-key-file /tmp/ygg.key \
    < deploy/deploy-openwrt-yggdrasil.sh
ssh root@<router> 'rm -f /tmp/ygg.key'
```

The key is the 128 hex characters of `option private_key` from the old router's
`/etc/config/network`. `YGG_PRIVATE_KEY` in the environment works too. Without
either, an existing key in the configuration is preserved and a missing one is
generated.

Without `--trusted` it asks for the allowed Yggdrasil addresses interactively;
with `-y` it runs unattended. `--dry-run` prints every change and applies none.
It preserves an existing private key, backs up `network`, `dhcp` and `firewall`
before configuration writes and attempts restoration on fatal configuration
errors. Optional status failures are warnings; final verification failures
return nonzero without automatically undoing the configuration. Package
installation is not rolled back. It finishes by printing
the router's Yggdrasil address and the command to reach it.

### A router deployed with 1.x

Reinstall rather than migrate: reset the router to stock (`firstboot`),
bring its uplink back, then run 2.0 with the same peers, trusted addresses
and `--host` reservations and the old identity via `--private-key-file`
(the node address and the routed /64 follow the key). Delete `dhcpv6` /
`slaac` from `[flags]` - the script refuses them. There is no in-place
migration.

The rest of this document is the manual equivalent, and remains the reference for
what the script does and why.

### Package source and integrity

The automated installer follows the **newest published status release**. It asks
GitHub for that release, accepts the answer only when it is a `status-vX.Y` tag
in the expected shape, then downloads that release's archive together with the
`.sha256` published beside it and refuses anything whose bytes disagree. A local
checkout copy of the same version is preferred when it carries its own checksum
file. `--status-version vX.Y` installs a specific release instead of the newest.

The published checksum protects against a truncated or corrupted download. It
travels in the same release as the archive, so it is **not** a defence against a
compromised release; use `--status-pkg` with your own verified build when that
distinction matters. If no verified copy is available the optional status stage
is skipped with a warning; the routing stages remain independent.

Release discovery calls `api.github.com`, which limits anonymous requests per
source IP. A shared address — a CI runner, or a router behind CGNAT — can
exhaust that budget through no fault of its own, and discovery then fails until
the window resets. `--status-version vX.Y` keeps working, because it skips the
lookup entirely. Setting `GITHUB_TOKEN` in the environment raises the limit; it
is attached only to that one fixed lookup and never to a release download, which
redirects to a different host. The token reaches `wget` as a process argument
and is visible in `/proc/<pid>/cmdline` while the request runs, so use it on CI
or a single-user host rather than a shared router.

For offline or custom builds, use `--status-pkg PATH` and provide the generated
single-entry `PATH.sha256` beside it. Both must be readable. Missing, malformed
or mismatched checksums now refuse the status installation; older deployers
could proceed without one. See [development](development.md#development-packaging)
for building that pair. Do not create a checksum for an untrusted download merely
to silence a verification failure.

## Requirements

- OpenWrt 25.12+ with `apk`, firewall4, odhcpd, dnsmasq, rpcd and LuCI;
- working Internet access and a correct system clock for HTTPS package downloads;
- root shell access and backups of network, DHCP and firewall configuration;
- current Yggdrasil peers;
- a remote Ygg client with a stable node address.

Replace every value in angle brackets.

## Manual installation

This path is an alternative to the automatic deploy, not a second pass to run
after it. Installing a new protocol handler may require a network restart
before netifd recognizes it; a reload alone was insufficient in the recorded
test. Use an alternate management path. Existing unrelated configuration must
be preserved; the firewall examples below are for a fresh installation.

## 1. Install Yggdrasil

```sh
apk update
apk add yggdrasil luci-proto-yggdrasil

# Optional direct-path optimisation used by the tested deployment:
apk add yggdrasil-jumper
```

In LuCI, open **Network → Interfaces → Add new interface**:

```text
Name:     ygg0
Protocol: Yggdrasil
```

Generate a key pair and add current peers from
[`yggdrasil-network/public-peers`](https://github.com/yggdrasil-network/public-peers).
Preserve the private key: it determines the node address and routed `/64`.

The tested Jumper profile enables:

```text
jumper_enable=1
jumper_loglevel=info
allocate_listen_addresses=1
jumper_autofill_listen_addresses=1
multipath=off
```

Verify:

```sh
ifstatus ygg0
ubus call network.interface.ygg0 status
```

The result must include a node address from `200::/7` and a delegated `/64`.
netifd labels that prefix with the name of the interface that provided it, so
with the interface named `ygg0` the prefix class is `ygg0`. Confirm it before
the next step, because the LAN has to ask for that exact class:

```sh
ifstatus ygg0 | jsonfilter -e '@["ipv6-prefix"][*].class'
```

## 2. Advertise the routed `/64` on LAN

The routed prefix joins the prefixes the LAN already advertises; the stock
RA/DHCPv6 configuration (`dhcpv6=server`, `ra_slaac=1`, M+O flags) and the
stock ULA stay. Two settings are needed: RA on, and a default route announced
even when the router has no native IPv6 uplink, so a client can answer a
Yggdrasil source on an IPv4-only site. The LAN's `ip6assign` (stock `60`) is
fine: netifd falls back to `/64` when the request does not fit. Do **not**
add an `ip6class` list - that is what 1.x did to keep native IPv6 off the LAN;
if one exists for other reasons, add the Yggdrasil class to it.

```sh
uci -q get network.lan.ip6assign >/dev/null || uci set network.lan.ip6assign='64'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_default='2'

uci commit network
uci commit dhcp
/etc/init.d/network reload
/etc/init.d/odhcpd reload                    # keeps the bound leases
ifstatus lan | jsonfilter -e '@["ipv6-prefix-assignment"][*].address'   # must list the 3xx: prefix
```

A reservation is a native `config host` with `hostid` (the hex IID; never 0,
which means dynamic, and not 1, the router). Match by MAC works only for
clients whose DUID embeds it (DUID-LLT, type 1, or DUID-LL, type 3); the
type is the client stack's choice, not the OS's - on the test LAN a Debian
host running dhcpcd sent DUID-LLT and a NetworkManager laptop sent DUID-UUID
(type 4), which carries no MAC. Let such a client take a dynamic lease once,
read its DUID from `ubus call dhcp ipv6leases`, and reserve by DUID,
optionally `%IAID` in hex. Give the MAC as well (`MAC+duid:HEX`): odhcpd
matches the lease by the DUID, while the status page and its canonical
`home.arpa` record find the row by the MAC - without it the device shows up
as a dynamic row with an observed address rather than as the named,
reserved host:

```sh
uci add dhcp host
uci set dhcp.@host[-1].name='nas'
uci set dhcp.@host[-1].mac='<MAC>'
uci set dhcp.@host[-1].duid='<HEX>'         # only needed when the DUID carries no MAC
uci set dhcp.@host[-1].hostid='10'          # -> <prefix>::10
uci set dhcp.@host[-1].leasetime='2m'       # renews within a minute: a late or new prefix follows fast
uci commit dhcp
/etc/init.d/odhcpd reload                    # keeps the bound leases
/etc/init.d/dnsmasq restart                  # config host also feeds DHCPv4
```

A DUID is 10 to 130 bytes (20-260 hex digits); odhcpd ignores clients outside
that range, so a shorter value can never match. And odhcpd keys its host
sections on the DUID bytes and the MACs, not on the IAID: two sections with
the same DUID, no MAC and different `%IAID` are one section to it, and the
second reservation silently disappears - give each interface its MAC as well.

Mind two odhcpd facts before adding reservations by hand. A `config host`
that has an IPv4 `ip` but no `hostid` already reserves an IPv6 IID - the last
IPv4 octet's digits read as hex (`192.168.1.235 -> ::235`) - the moment DHCPv6
is served, so an existing IPv4 reservation is an IPv6 one too and two sections
can collide. And a client only gets a lease when it asks (reconnect, renew,
reboot); the RA change alone does not move it, and a SLAAC address it already
holds stays valid until its own lifetime ends. The deployer performs the
collision check and reports implicit reservations; by hand, check
`uci show dhcp | grep -E 'hostid|\.ip='` first. Verify with
`ubus call dhcp ipv6leases`.

One host with two interfaces on the same LAN (a laptop on cable and Wi-Fi at
once) presents one DUID with two IAIDs. A reservation by DUID alone then
follows whichever interface asks first, and the other interface's DAD fails
on the same address every renewal. Reserve each interface by `%IAID`:
`ubus call dhcp ipv6leases` prints the `iaid` as a signed decimal, so
`printf '%x' $((IAID & 0xffffffff))` gives the hex the option wants, e.g.
`thinkpad=<MAC-eth>+duid:<HEX>%206de1ca=20` and
`thinkpad-wifi=<MAC-wlan>+duid:<HEX>%d259864f=21`. The MACs are what keep
the two sections distinct for odhcpd (see above); the deployer refuses two
`duid:`-only lines that differ by IAID alone. Verified on the test LAN with a
laptop on cable and Wi-Fi: each interface holds its own reserved address.

```sh
ip -6 addr show dev br-lan
ip -6 neigh show dev br-lan
```

A normal LAN client should now have a routed `3xx:...` address.

## 3. Apply the firewall policy

The named sections below are intended for a fresh installation. No NAT66 is
created; the only forwarding from the LAN is the explicit rule to `200::/7`.

```sh
uci set firewall.ygg='zone'
uci set firewall.ygg.name='ygg'
uci set firewall.ygg.input='REJECT'
uci set firewall.ygg.output='ACCEPT'
uci set firewall.ygg.forward='DROP'
uci -q delete firewall.ygg.network
uci add_list firewall.ygg.network='ygg0'

uci set firewall.ygg_trusted_lan='rule'
uci set firewall.ygg_trusted_lan.name='YGG-Trusted-to-LAN'
uci set firewall.ygg_trusted_lan.src='ygg'
uci set firewall.ygg_trusted_lan.dest='lan'
uci set firewall.ygg_trusted_lan.family='ipv6'
uci set firewall.ygg_trusted_lan.proto='all'
uci set firewall.ygg_trusted_lan.target='ACCEPT'
uci -q delete firewall.ygg_trusted_lan.src_ip
uci add_list firewall.ygg_trusted_lan.src_ip='<TRUSTED_YGG_IPV6_1>'
uci add_list firewall.ygg_trusted_lan.src_ip='<TRUSTED_YGG_IPV6_2>'

uci set firewall.ygg_trusted_router='rule'
uci set firewall.ygg_trusted_router.name='YGG-Trusted-to-Router'
uci set firewall.ygg_trusted_router.src='ygg'
uci set firewall.ygg_trusted_router.family='ipv6'
uci set firewall.ygg_trusted_router.proto='tcp udp icmp'
uci set firewall.ygg_trusted_router.target='ACCEPT'
uci -q delete firewall.ygg_trusted_router.src_ip
uci add_list firewall.ygg_trusted_router.src_ip='<TRUSTED_YGG_IPV6_1>'
uci add_list firewall.ygg_trusted_router.src_ip='<TRUSTED_YGG_IPV6_2>'

# LAN hosts may initiate connections into Yggdrasil (omit for --no-lan-forward)
uci set firewall.ygg_lan_out='rule'
uci set firewall.ygg_lan_out.name='LAN-to-Yggdrasil'
uci set firewall.ygg_lan_out.src='lan'
uci set firewall.ygg_lan_out.dest='ygg'
uci set firewall.ygg_lan_out.family='ipv6'
uci set firewall.ygg_lan_out.proto='all'
uci set firewall.ygg_lan_out.dest_ip='200::/7'
uci set firewall.ygg_lan_out.target='ACCEPT'

uci commit firewall
/etc/init.d/firewall restart
```

The trusted-router rule (TCP, UDP, ICMP) intentionally has no destination-port
restriction. It is not limited to SSH/LuCI; it also carries DNS. Keep that
policy unless explicitly choosing a separate hardening change.

Before closing the current management path, establish a new SSH session from a
trusted Ygg client to the router node address.

## 4. Install the optional LuCI status module

This follows the newest published release, exactly like the automated
installer. A release archive embeds the commit it was built from, so its digest
cannot be known before that commit exists; pinning one here would have to be
edited after every release and would silently rot the day someone forgot.

```sh
(
  set -e
  repo='Plasmoid77/Yggdrasil-OpenWRT'
  work="$(mktemp -d /tmp/ygg-status-install.XXXXXX)"
  trap 'rm -rf "$work"' EXIT
  cd "$work"

  wget -qO release.json "https://api.github.com/repos/$repo/releases/latest"
  tag="$(jsonfilter -i release.json -e '@.tag_name')"
  case "$tag" in
    status-v[0-9]*) ;;
    *) echo "unexpected release tag: $tag" >&2; exit 1 ;;
  esac
  ver="${tag#status-}"
  base="https://github.com/$repo/releases/download/$tag"

  wget -O "yggdrasil-status-$ver.tar.gz" "$base/yggdrasil-status-$ver.tar.gz"
  wget -O checksum "$base/yggdrasil-status-$ver.tar.gz.sha256"
  sha256sum -c checksum

  tar -xzf "yggdrasil-status-$ver.tar.gz"
  sh "yggdrasil-status-$ver/install.sh"
)
```

The checksum travels in the same release as the archive, so it catches a
truncated or corrupted download but is not a defence against a compromised
release — the same trade-off as the automated installer above. To get an
independent check, build the package yourself from a reviewed revision and
compare, or use `--status-pkg` with that build.

Open **Status → Yggdrasil**. Active DHCPv4 clients should appear without
manual enrollment. The IPv6 column prefers a canonical or observed stable
EUI-64 address, while privacy-only clients may show multiple addresses. Pin
defaults to no IPv4 reservation.

## 5. Add optional `home.arpa` DNS

```sh
uci set dhcp.ygg_router='domain'
uci set dhcp.ygg_router.name='router.home.arpa'
uci set dhcp.ygg_router.ip='<ROUTER_YGG_IPV6>'

uci set dhcp.ygg_mydevice='domain'
uci set dhcp.ygg_mydevice.name='mydevice.home.arpa'
uci set dhcp.ygg_mydevice.ip='<DEVICE_CANONICAL_YGG_IPV6>'

uci -q del_list dhcp.@dnsmasq[0].server='/home.arpa/'
uci add_list dhcp.@dnsmasq[0].server='/home.arpa/'
uci commit dhcp
/etc/init.d/dnsmasq restart
```

No separate firewall rule is needed: `YGG-Trusted-to-Router` already admits
TCP and UDP from the trusted sources, so port 53 is reachable for them and for
no one else.

```sh
dig +short AAAA mydevice.home.arpa @<ROUTER_YGG_IPV6>
dig +tcp +short AAAA mydevice.home.arpa @<ROUTER_YGG_IPV6>
```

## 6. Optional Linux split DNS

Only the routers' zones (`home.arpa` by default) should use OpenWrt DNS.
Internet DNS must remain on the normal Wi-Fi/Ethernet or VPN resolver.

Clone this repository on the Linux client:

```sh
git clone https://github.com/Plasmoid77/Yggdrasil-OpenWRT.git
cd Yggdrasil-OpenWRT
```

Set Yggdrasil's interface name in `/etc/yggdrasil.conf`, and do not create a
persistent NetworkManager TUN profile:

```yaml
IfName: ygg0
```

This changes the Linux client's resolver integration. Preserve its current
`/etc/resolv.conf` and verify compatibility with its existing network manager;
do not apply the symlink change blindly on a differently managed distribution.
The tested integration is for a client using systemd-resolved.

Install the supplied lifecycle integration:

```sh
sudo systemctl enable --now systemd-resolved
sudo ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

sudo install -D -m 0755 client/linux/yggdrasil-split-dns \
  /usr/local/libexec/yggdrasil-split-dns
ROUTER_YGG_IPV6='<ACTUAL_ROUTER_YGG_IPV6>'
sudo sed -i "s|<ROUTER_YGG_IPV6>|$ROUTER_YGG_IPV6|" \
  /usr/local/libexec/yggdrasil-split-dns

sudo install -D -m 0644 client/linux/yggdrasil.service.d/split-dns.conf \
  /etc/systemd/system/yggdrasil.service.d/split-dns.conf
sudo systemctl daemon-reload
sudo systemctl restart yggdrasil
```

Verify routing, not only the returned addresses:

```sh
resolvectl status ygg0
resolvectl query router.home.arpa
resolvectl query openai.com
```

Expected:

```text
router.home.arpa -> link: ygg0
openai.com       -> normal Wi-Fi/Ethernet link (or the VPN's)
ygg0             -> DNS Domain: ~home.arpa, Default Route: no
```

A router with another zone (`--dns-domain spb.internal`): set
`zones='spb.internal'` in `/usr/local/libexec/yggdrasil-split-dns`.
systemd-resolved (v261 checked) keeps `home.arpa` and `internal` out of DNSSEC
validation by itself. Only the zones go to the router (`ygg0` is not a default
route), so every other name keeps working when the router is down.

A VPN client that sets its DNS through systemd-resolved (AmneziaVPN, `~.` on
its own link) does not interfere: the more specific zone on `ygg0` wins. But
AmneziaVPN (4.8.19 checked) snapshots the links' routing domains when it
connects and restores that snapshot when it disconnects or reconnects. Change
`zones` or `router_dns` with the VPN disconnected: disconnect, run
`sudo /usr/local/libexec/yggdrasil-split-dns apply`, check `resolvectl domain
ygg0`, then connect. Changed while it is connected (or connected again before
the apply finished), the old zone comes back at its next reconnect. (A global
`resolved.conf` setting would be immune, but a global server also receives
every name outside the routing domains when no VPN claims `~.`, which makes
all DNS depend on the router.)

### Several routers: a local dnsmasq

systemd-resolved sends a link's queries to that link's current server; it
cannot send one zone to one server and another zone to another server on the
same link (`ygg0`). A router asked for a zone that is not its own answers
NXDOMAIN, and resolved does not try the next server. Each router answers only
its own zone (no forwarding between routers, so none depends on another);
the per-zone choice is made on the client by a dnsmasq that forwards only
those zones:

```sh
sudo install -D -m 0644 client/linux/dnsmasq-ygg-zones.conf /etc/dnsmasq.d/ygg-zones.conf
sudoedit /etc/dnsmasq.d/ygg-zones.conf       # one server=/<zone>/<router Ygg address> per router
grep -q '^conf-dir=/etc/dnsmasq.d/,\*.conf' /etc/dnsmasq.conf \
  || echo 'conf-dir=/etc/dnsmasq.d/,*.conf' | sudo tee -a /etc/dnsmasq.conf
sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq               # also after every later edit: it rereads its config only on restart
sudo sed -i "s|^router_dns=.*|router_dns='127.0.0.2'|; s|^zones=.*|zones='home.arpa internal'|" \
  /usr/local/libexec/yggdrasil-split-dns
sudo /usr/local/libexec/yggdrasil-split-dns apply
```

It listens on 127.0.0.2 only (`bind-interfaces`), next to systemd-resolved's
127.0.0.53 and any libvirt instance, and has no upstream: names outside the
zones are never sent to it. A router that is unreachable only makes its own
zone time out. Checked on a laptop with systemd 261, dnsmasq 2.93 and
AmneziaVPN up: `home.arpa` answered by the SPb router through the local
dnsmasq, an unreachable second zone timing out alone, `example.com` through
the VPN.

## Final verification

```sh
ifstatus ygg0
ifstatus lan | jsonfilter -e '@["ipv6-prefix-assignment"][*].address'
ip -6 addr show dev br-lan
uci -q get network.lan.ip6class                   # empty, or a list that contains ygg0
uci -q get dhcp.lan.ra
uci -q get dhcp.lan.ra_default
uci -q get firewall.ygg_lan_out.dest_ip
ubus -v list luci.yggdrasil-status
ubus call luci.yggdrasil-status clients
ubus call dhcp ipv6leases
```

Expected invariants:

```text
LAN prefixes  = the 3xx: routed /64 beside the LAN's own (native and/or ULA)
RA            = server, RA default = 2
LAN ip6class  = absent, or admits ygg0
Ygg zone      = input REJECT / output ACCEPT / forward DROP
LAN-to-Yggdrasil rule dest_ip = 200::/7 (absent with --no-lan-forward)
no NAT66, no unsolicited ygg -> lan traffic beyond the trusted /128s
```

The LAN's `dhcpv6`, `ra_slaac`, `ra_flags` and `ula_prefix` are yours; on a
stock router they read `server`, `1`, `managed-config other-config` and an
`fd..::/48`.

For rationale see [architecture](architecture.md); for troubleshooting, updates
and removal see [operations](operations.md).
