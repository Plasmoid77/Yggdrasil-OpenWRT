# OpenWrt Yggdrasil routed LAN — Quickstart

This is the short installation path for the tested design documented in
[README.md](README.md). Read the full guide before adapting the topology,
supporting multiple LANs, or changing firewall policy.

## Result

```text
Yggdrasil routed /64 -> OpenWrt -> br-lan -> RA/SLAAC -> ordinary LAN clients
```

LAN devices receive routed Yggdrasil IPv6 without running Yggdrasil. DHCPv6
and NAT66 are not used. Remote access is limited to trusted Ygg `/128`s.

Optional modules provide a LuCI inventory, `home.arpa` names, and route-only
Linux split DNS.

## Automated path

`deploy/deploy-openwrt-yggdrasil.sh` performs every step below on a live router.
Run it in a root shell **on the router**. OpenWrt ships `wget`
(`uclient-fetch`) with a CA bundle and no `curl`:

```sh
wget -O deploy-openwrt-yggdrasil.sh \
  https://raw.githubusercontent.com/Plasmoid77/Yggdrasil-OpenWRT/main/deploy/deploy-openwrt-yggdrasil.sh
sh deploy-openwrt-yggdrasil.sh \
  --peer tls://<host>:<port> \
  --peer wss://<host>:<port> \
  --trusted <TRUSTED_YGG_IPV6>
```

A root login starts in `/root`, which lives on the overlay and survives a
reboot. `/tmp` is a tmpfs: nothing prunes it on a timer, but it costs RAM and is
empty again after a restart.

Piping works too, but then `stdin` is the pipe: the script cannot ask for the
trusted addresses interactively, so `--trusted` becomes mandatory, and there is
no local copy to check a checksum against.

```sh
wget -qO- https://raw.githubusercontent.com/Plasmoid77/Yggdrasil-OpenWRT/main/deploy/deploy-openwrt-yggdrasil.sh \
  | sh -s -- --peer tls://<host>:<port> --trusted <TRUSTED_YGG_IPV6>
```

`-q` silences the progress output that would otherwise be mixed into the script,
and `-O -` writes the download to standard output instead of a file.

### About the netifd restart in stage 2

netifd reads `/lib/netifd/proto/*.sh` only at startup, so a Yggdrasil protocol
handler installed during the same run is invisible to the running daemon and the
interface comes up as `proto 'none'` with `NO_DEVICE`. A reload does not fix it;
the script detects the condition and restarts netifd once.

**This is a service restart, not a reboot, and it does not interrupt the run.**
Measured on the tested router: it takes about three seconds, and an established
SSH session survives it — the LAN address is back long before the TCP connection
gives up. What fails during that window is anything opening a *new* connection.
So a first deployment can be watched live in the terminal like any other run.

Over a link where a three second gap might not be survivable, detach it instead
and read the log afterwards:

```sh
setsid sh deploy-openwrt-yggdrasil.sh --peer ... --trusted ... -y \
    </dev/null >deploy.log 2>&1 &
```

One run covers all three parts, section 5 included: it writes
`router.home.arpa` for the router, `--dns-host NAME=ADDR` for anything else, and
opens port 53 to the trusted addresses only. `--no-dns` skips that part, the way
`--no-lan`, `--no-firewall` and `--no-status` skip theirs. Only the client side
of section 6 stays manual — the script runs on the router and cannot reach the
client.

To keep an existing Yggdrasil address on a redeployment or on new hardware, hand
the old private key over in a file rather than on the command line, which is
world readable through `/proc/<pid>/cmdline`:

```sh
ssh root@<router> 'cat > /tmp/ygg.key && chmod 600 /tmp/ygg.key' < old-private.key
ssh root@<router> sh -s -- --peer ... --private-key-file /tmp/ygg.key \
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
before touching them, restores them if any stage fails, and finishes by printing
the router's Yggdrasil address and the command to reach it.

The rest of this document is the manual equivalent, and remains the reference for
what the script does and why.

## Requirements

- OpenWrt 25.12+ with `apk`, firewall4, odhcpd, dnsmasq, rpcd and LuCI;
- root shell access and backups of network, DHCP and firewall configuration;
- current Yggdrasil peers;
- a remote Ygg client with a stable node address.

Replace every value in angle brackets.

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

This intentionally removes the extra OpenWrt ULA and enables SLAAC-only RA:

```sh
uci set network.lan.ip6assign='64'
uci -q delete network.lan.ip6class
uci add_list network.lan.ip6class='ygg0'   # = the Yggdrasil interface name
uci -q delete network.globals.ula_prefix

uci set dhcp.lan.dhcpv6='disabled'
uci set dhcp.lan.ra='server'
uci set dhcp.lan.ra_slaac='1'
uci -q delete dhcp.lan.ra_flags
uci add_list dhcp.lan.ra_flags='none'
uci set dhcp.lan.ra_default='2'
uci set dhcp.lan.ra_preference='medium'

uci commit network
uci commit dhcp
/etc/init.d/network reload
/etc/init.d/odhcpd restart
```

```sh
ip -6 addr show dev br-lan
ip -6 neigh show dev br-lan
```

A normal LAN client should now have a routed `3xx:...` address.

## 3. Apply the firewall policy

The named sections below are intended for a fresh installation. No blanket
forwarding or NAT66 is created.

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
uci set firewall.ygg_trusted_router.proto='tcp'
uci set firewall.ygg_trusted_router.target='ACCEPT'
uci -q delete firewall.ygg_trusted_router.src_ip
uci add_list firewall.ygg_trusted_router.src_ip='<TRUSTED_YGG_IPV6_1>'
uci add_list firewall.ygg_trusted_router.src_ip='<TRUSTED_YGG_IPV6_2>'

uci commit firewall
/etc/init.d/firewall restart
```

Before closing the current management path, establish a new SSH session from a
trusted Ygg client to the router node address.

## 4. Install the optional LuCI status module

```sh
wget -O /tmp/yggdrasil-status-v5.tar.gz \
  https://raw.githubusercontent.com/Plasmoid77/Yggdrasil-OpenWRT/main/packages/yggdrasil-status-v5.tar.gz
wget -O /tmp/yggdrasil-status-v5.tar.gz.sha256 \
  https://raw.githubusercontent.com/Plasmoid77/Yggdrasil-OpenWRT/main/packages/yggdrasil-status-v5.tar.gz.sha256

cd /tmp
sha256sum -c yggdrasil-status-v5.tar.gz.sha256
tar -xzf yggdrasil-status-v5.tar.gz
/tmp/yggdrasil-status-v5/install.sh
```

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

Permit DNS only from the same trusted sources:

```sh
uci set firewall.ygg_dns='rule'
uci set firewall.ygg_dns.name='Allow-DNS-from-Trusted-Yggdrasil'
uci set firewall.ygg_dns.src='ygg'
uci set firewall.ygg_dns.proto='tcp udp'
uci set firewall.ygg_dns.dest_port='53'
uci set firewall.ygg_dns.target='ACCEPT'
uci -q delete firewall.ygg_dns.src_ip
uci add_list firewall.ygg_dns.src_ip='<TRUSTED_YGG_IPV6_1>'
uci add_list firewall.ygg_dns.src_ip='<TRUSTED_YGG_IPV6_2>'
uci commit firewall
/etc/init.d/firewall restart
```

```sh
dig +short AAAA mydevice.home.arpa @<ROUTER_YGG_IPV6>
dig +tcp +short AAAA mydevice.home.arpa @<ROUTER_YGG_IPV6>
```

## 6. Optional Linux split DNS

Only `home.arpa` should use OpenWrt DNS. Internet DNS must remain on the normal
Wi-Fi/Ethernet resolver.

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
openai.com       -> normal Wi-Fi/Ethernet link
ygg0             -> DNS Domain: ~home.arpa, Default Route: no
```

## Final verification

```sh
ifstatus ygg0
ip -6 addr show dev br-lan
uci -q get network.lan.ip6class
uci -q get dhcp.lan.dhcpv6
uci -q get dhcp.lan.ra
uci -q get dhcp.lan.ra_slaac
ubus -v list luci.yggdrasil-status
ubus call luci.yggdrasil-status clients
```

Expected invariants:

```text
LAN ip6class = ygg0
DHCPv6       = disabled
RA           = server
RA SLAAC     = 1
Ygg zone     = input REJECT / output ACCEPT / forward DROP
no NAT66
no blanket ygg -> lan forwarding
```

For rationale, troubleshooting, updates and removal, continue with
[README.md](README.md).
