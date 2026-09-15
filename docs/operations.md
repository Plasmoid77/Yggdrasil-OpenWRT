# Operations

Use this guide for diagnosis, updates, recovery and removal. Recorded device
observations below are historical results from the original deployment.
Do not treat them as a fresh validation of another router.

## Startup precautions

### Protocol-handler order

If the router still needs a package that ships its own netifd protocol handler —
an LTE modem (`luci-proto-xmm`, `luci-proto-qmi`, `luci-proto-mbim`), a tunnel
protocol, anything under `/lib/netifd/proto/` — **install that first, let it
finish its own reboot, and confirm it comes back on its own. Deploy Yggdrasil
after that.**

The reason is the netifd restart described below. Installing a protocol handler
requires one, and doing it while Yggdrasil is already running means restarting
netifd underneath a live Yggdrasil interface. Once, on the tested router, that
sequence left `ygg0` at `up:false pending:true` after the following reboot: the
daemon had its peers, but netifd never completed the protocol setup, so no
prefix was published, the LAN kept no routed address, and the firewall zone had
no device — the router looked healthy while the whole design was unreachable
from outside. `ifup ygg0` cleared it in one shot.

It happened once and did not reproduce in fourteen further attempts (reboots
with and without an uplink, and repeated `/etc/init.d/network restart`), so it
is a rare race rather than a defect with a known trigger. Installing other handlers first is the tested precaution, not proof that
all future boot races are impossible.

Validated end to end on a factory-reset router: uplink, then the modem
installer and its reboot, then a control reboot to prove the modem alone is
stable, then Yggdrasil, then a final reboot — `ygg0` came up `up:true
pending:false` with its prefix on five consecutive samples.

If the router has no uplink at all after a reset, the modem installer cannot
run either. Join a Wi-Fi network as a station to bootstrap it — `wpad` is in the
base image, so this needs no packages:

```sh
uci set network.wwan=interface
uci set network.wwan.proto='dhcp'
uci set wireless.radio0.disabled='0'
uci set wireless.sta=wifi-iface
uci set wireless.sta.device='radio0'
uci set wireless.sta.network='wwan'
uci set wireless.sta.mode='sta'
uci set wireless.sta.ssid='<SSID>'
uci set wireless.sta.encryption='psk2'
uci set wireless.sta.key='<PASSPHRASE>'
uci add_list firewall.@zone[1].network='wwan'   # the 'wan' zone
uci commit; /etc/init.d/network reload; wifi reload
```

### netifd restart

netifd reads `/lib/netifd/proto/*.sh` only at startup, so a Yggdrasil protocol
handler installed during the same run is invisible to the running daemon and the
interface would come up as `proto 'none'` with `NO_DEVICE`. A reload does not fix
it; only a restart does.

The script does that itself, in stage 1, **immediately after installing the
packages and before it writes a single UCI value**. That ordering is deliberate:
the restart drops every interface for a few seconds, and doing it while nothing
has been changed yet means a connection lost at that moment leaves the router
exactly as it was found. Re-running the script then simply continues — there is
no half-applied state to clean up.

This is a service restart, not a reboot. Whether an SSH connection survives depends on the management path. Measured on
the tested router it takes about three seconds, and an established SSH session
survives it: SSH runs over the LAN IPv4 address, which comes back long before TCP
gives up. What fails during that window is anything opening a *new* connection.

Over a link where a three second gap might not be survivable, detach the run and
read the log afterwards:

```sh
setsid sh deploy-openwrt-yggdrasil.sh --peer ... --trusted ... -y \
    </dev/null >deploy.log 2>&1 &
```


## Troubleshooting notes from the real deployment

These points are included because they came from actual failures during development rather than hypothetical edge cases.

### `FAILED` NDP does not prove the client's IPv6 disappeared

A neighbour entry such as:

```text
3xx:.... dev br-lan FAILED
```

means the router could not currently resolve/reach that neighbour. It does **not** prove the address was removed from the client.

During testing, stable client addresses became reachable again after the device returned and NDP was refreshed.

Use active tests and client state before concluding that SLAAC itself changed the address.

### `STALE` can be a healthy device

`STALE` is a neighbour-cache state, not an Offline verdict.

A printer in `STALE` state remained completely usable. This is one reason the final dashboard performs active probes.

### Historical SLAAC addresses can accumulate in NDP

A client may legitimately have stable plus temporary/privacy addresses. The
router advertises a prefix; the client chooses its IID(s).

The original v4 status page displayed every Ygg address associated with a MAC
in `ip -6 neigh`. On a long-running router this included many historical
privacy IIDs. Polling also probed those entries, which could keep the NDP set
busy even after a client had stopped using the addresses.

The current v5-family implementation uses stable-first selection: a canonical `config domain` wins; otherwise an
observed modified EUI-64 wins; privacy-only clients retain all observed
addresses. Nothing is persisted, and no address is assigned to or removed from
the client.

This also applies to LAN devices that run their own Yggdrasil daemon. Such a
device separately owns a native `2xx:` node address, which belongs in the peer
table, and a router-prefix `3xx:` SLAAC address, which belongs in the LAN table.
IPv6 forwarding used by a local Yggdrasil client may add the NDP `router` flag;
that flag does not create another identity and is ignored by the inventory
merge.

For a DHCP-only client, the device row itself still disappears when the DHCP
lease expires.

In managed mode (`--dhcpv6`) the accumulation problem does not arise for
DHCPv6 clients: the router itself handed out the address, the table shows the
bound lease first (bold, `ipv6_source: dhcpv6`) and any lingering SLAAC
address after it. Right after a switch from SLAAC both are expected until the
SLAAC address's own lifetime ends on the client.

### A client shows no routed address in managed mode

Three causes, in order of likelihood:

1. It has no DHCPv6 client. Android has none by policy; some IoT and smart-TV
   stacks neither. Such a device keeps IPv4 and link-local IPv6 only. If it
   must be reachable over Yggdrasil, it runs its own Yggdrasil node.
2. It has not asked yet. A lease is obtained on connect, renew or reboot; the
   RA change alone does not trigger one. `ubus call dhcp ipv6leases` lists
   what is bound; `logread -e odhcpd` shows the exchange.
3. Its reservation does not match. A MAC in `config host` only matches a
   DUID-LLT or DUID-LL client, and the DUID type is the client stack's
   choice: on the test LAN dhcpcd sent DUID-LLT, a NetworkManager laptop sent
   DUID-UUID (type 4, `0004...`) and took a dynamic lease despite its MAC
   being known. Read the DUID from `ubus call dhcp ipv6leases` and reserve
   by `--host NAME=MAC+duid:<HEX>=<HOSTID>` (the MAC keeps the status row
   named), or by
   `--host NAME=duid:<HEX>[%<IAID>]=<HOSTID>` instead. A DUID of
   `00030001000000000000` (type 3, all-zero MAC) is a firmware defect seen on
   a BMC; it can only be matched by DUID, and two ports sharing it need
   `%IAID` to tell them apart.
4. Two of its interfaces are on the LAN. One DUID, two IAIDs, one
   reservation: the address goes to whichever interface asks first and the
   other logs `DAD failed` for it at every renewal (seen with a laptop on
   cable and Wi-Fi at once). Reserve each interface by `%IAID`, as described
   in the installation guide.

### BusyBox lowercase bug found during final backend testing

An earlier backend used:

```sh
tr '[:upper:]' '[:lower:]'
```

On the tested router this did not lowercase hostnames as expected in the actual execution path. That prevented:

```text
MyDevice
```

from matching:

```text
mydevice.home.arpa
```

The tested final backend therefore uses:

```sh
tr 'A-Z' 'a-z'
```

See also [BusyBox and UCI pitfalls](development.md#busybox-and-uci-pitfalls).

Do not "clean up" that line back to the earlier form without testing it on the target BusyBox/OpenWrt environment.

### DNS timeout over Ygg may be firewall, not dnsmasq

During development, local `home.arpa` records already worked and `dnsmasq` was listening, but direct DNS queries over Yggdrasil timed out.

The missing piece was an INPUT firewall rule for TCP/UDP 53 from the `ygg` zone.

Always distinguish:

```text
DNS record exists?
DNS listener exists?
firewall permits Ygg -> router:53?
```

### Do not use runtime host hints as an inventory repair tool

If rows disappear because the backend was changed to use `getHostHints` as its inventory database, the fix is not to continuously "wake" NDP with pings. Restore the explicit lifetime model instead:

```text
active DHCP lease -> dynamic row
config host       -> persistent row
neighbour state   -> runtime IPv6 enrichment only
```

---

## Updating and maintenance

### Preserve the Yggdrasil identity

Before an upgrade, back up the network configuration and private key securely.

For example:

```sh
uci export network > /root/network-before-ygg-update.conf
```

Do not regenerate the Yggdrasil keypair during an ordinary update unless you intentionally want a new node identity and routed subnet.

### Back up the optional status module

If Part II is installed:

```sh
tar -czf /root/yggdrasil-status-backup.tar.gz \
        /usr/libexec/rpcd/luci.yggdrasil-status \
        /usr/share/rpcd/acl.d/yggdrasil-status.json \
        /usr/share/luci/menu.d/yggdrasil-status.json \
        /www/luci-static/resources/view/status/yggdrasil.js

uci export dhcp > /root/dhcp-before-ygg-status-update.conf
```

The DHCP backup matters because persistent Pin/Unpin state is stored as normal `config host` records rather than in a private status database.

### Update deliberately

For the packages you actually installed:

```sh
apk update
apk upgrade yggdrasil luci-proto-yggdrasil yggdrasil-jumper
```

Do not assume every future package keeps the exact same UCI options.

### Switching the LAN to router-managed addressing

Managed mode (`--dhcpv6`) is opt-in; a rerun without `--dhcpv6`/`--slaac`
keeps whatever mode the router runs. Migrating a router that was deployed
with SLAAC:

1. Keep a second management path open (Yggdrasil to the router plus LAN, or
   a serial console). The LAN stage reloads odhcpd (bound leases survive);
   the router's own addresses and the `ygg` zone do not change.
2. Rerun the deployer with the **complete** argument set of the original
   deployment plus `--dhcpv6` and the `--host` reservations you want. The
   deployer rewrites trusted rules, jumper and multicast sections from its
   arguments on every run, so an omitted `--trusted` closes the zone. A
   settings file (`--config`) is the way to keep that set complete. Drop a
   `--dns-host` line for a name you now reserve with `--host`: the deployer
   refuses the pair, because the old hand-written answer would otherwise
   survive beside the reserved one.
3. Read the preflight report: it lists every existing `config host` whose
   IPv4 `ip` implies an IPv6 IID (`.235 -> ::235`) and refuses a `--host`
   that would collide with one.
4. Verify: the run's Stage 8 checks the mode's UCI values, each
   reservation's `hostid` and lists bound leases. Then make one client ask
   (reconnect it) and confirm its address in `ubus call dhcp ipv6leases`,
   in the status table and by reaching it from a trusted node.
5. Expect a transition: SLAAC addresses already formed stay valid on the
   clients until their lifetime ends (odhcpd's default cap is 90 min; the
   client decides); nothing forces them off. Devices without a DHCPv6 client
   lose their routed address when theirs expires.
6. Reboot the router once and re-check `ubus call dhcp ipv6leases` and the
   prefix on `br-lan`: the known `ygg0` pending race (startup precautions
   above) would leave odhcpd with nothing to serve.

Back to SLAAC: the same rerun with `--slaac`. It restores the `dhcp.<lan>`
values and, with the DNS module on (`--no-dns` skips the DNS stage entirely),
removes the deployer-owned `ygg_rsv_*` DNS records - they are rebuilt from
the `--host` lines on every run, `--slaac` accepts none, so no name is left
pointing at an address nobody holds. `hostid` options stay in place: inert
without DHCPv6, live again on the next `--dhcpv6` run. The deployer never
removes a `hostid`; omitting a `--host` line on a `--dhcpv6` rerun drops its
name and keeps its `hostid`. To retire a reservation for good:
`uci delete dhcp.<section>.hostid; uci commit dhcp; /etc/init.d/odhcpd reload`.

### Post-update verification

Re-run the relevant layer checks:

```sh
ifstatus ygg0
yggdrasilctl getPeers
ubus call dhcp ipv6ra
ubus call dhcp ipv6leases      # managed mode: the addresses the router handed out
fw4 print
```

If Part II is installed:

```sh
ubus -v list luci.yggdrasil-status
ubus call luci.yggdrasil-status clients
```

Confirm that `clients`, `pin` and `unpin` are all present before relying on the management buttons in LuCI.

If Part III is installed:

```sh
nslookup <HOST>.home.arpa <ROUTER_YGG_IPV6>
```

Then test actual remote access to a permitted LAN service.

## Waking LAN hosts over the mesh

The router is the one LAN device that is always on and always reachable over
Yggdrasil, which makes it the natural place to wake everything else from.
A home server that is powered off or asleep has no mesh address to reach, but
its MAC is on the status page, and a magic packet from the router brings it
back without anyone touching the box.

The approach used on the test router, 2026-09-14:

```sh
apk add etherwake luci-app-wol
rm -rf /tmp/luci-indexcache* /tmp/luci-modulecache   # LuCI caches its menu at login
/etc/init.d/rpcd reload
```

`etherwake` writes the magic packet as a raw Ethernet frame on the chosen
interface, so it needs no IP route to the sleeping host and no broadcast
address; the router is a member of `br-lan`, which is all it takes:

```sh
etherwake -i br-lan 6c:92:bf:2f:aa:28
```

`luci-app-wol` puts the same call under *Services -> Wake on LAN* (interface
`br-lan`, hosts offered from the DHCP leases, or a MAC typed in). The page
mentions an alternative backend, the `wol` package, which sends the packet as
UDP to a broadcast address instead; it is only useful when the router is not
on the target's segment, so it is not installed here.

Measured on the test host (Debian 13, Intel NIC with `Wake-on: g`, BIOS
wake-on-LAN enabled): back from suspend 12 s after the packet, back from a
full power-off about two minutes including boot. Two things on the host side
decide whether this works, and neither is the router's business: `ethtool
<nic>` must show `Wake-on: g` (the driver default on common Intel adapters),
and the BIOS must keep the adapter powered in S5. A host that goes to sleep
on its own is a separate problem - on that server a desktop install's power
management suspended it an hour after boot, and the fix was
`/etc/systemd/sleep.conf.d/server.conf` with `AllowSuspend=no`, not a wake
timer.

---

## Removing the setup

Removal is modular too.

### Remove only Part III DNS-over-Ygg access

Delete the `ygg_dns` firewall rule and, if no longer wanted, the `home.arpa` local-zone directive and `config domain` records used purely for DNS.

Then:

```sh
uci commit firewall
uci commit dhcp
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
```

If Part II still uses the same `config domain` records as canonical addresses, keep those records.

### Remove only Part II status UI

```sh
rm -f /usr/libexec/rpcd/luci.yggdrasil-status
rm -f /usr/share/rpcd/acl.d/yggdrasil-status.json
rm -f /usr/share/luci/menu.d/yggdrasil-status.json
rm -f /www/luci-static/resources/view/status/yggdrasil.js
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
```

You may then remove `iputils-arping` if nothing else needs it.

Inventory `config host` entries may be kept because they are normal OpenWrt device/DHCP configuration. Removing the LuCI module itself does not delete them. If you do not want dashboard-created pins to remain, use `Unpin` before removing the module or remove the corresponding `config host` records manually.

Be careful with static reservations: deleting a `config host` that contains `option ip` also removes that DHCP reservation. `config domain` canonical IPv6 / DNS records are separate and are not removed automatically.

### Remove the core Yggdrasil LAN setup

Because removing the core can destroy remote management reachability, do this only with an alternate management path available.

Remove the explicit Yggdrasil firewall rules and zone, restore the LAN IPv6 policy you actually want, and only then remove Yggdrasil packages.

Example package removal after configuration cleanup:

```sh
apk del yggdrasil-jumper luci-proto-yggdrasil yggdrasil
```

Do not blindly delete IPv6 settings without deciding what prefix/RA design replaces the Yggdrasil profile.

---


## Rollback boundaries

Git rollback restores tracked repository files, not router configuration,
installed packages, private keys, DNS client settings or network state. A
status-only update and a whole-network deploy have different rollback scopes.

The network deployer backs up network/DHCP/firewall configuration and attempts
restoration through its fatal-error path. Optional status failure is a warning;
failed final invariants do not automatically roll back the whole run. Read the
reported backup location and the failing checks before relying on the router.
Do not blindly restore over unrelated changes made after that backup.

The status installer backs up its four installed files and attempts restoration
on its validation-failure path. This does not undo package-manager changes or
prove every possible partial file-copy failure is transactional. Keep an
alternate management session for recovery.

For a repository-only maintenance PR, do not run either installer merely to
apply the documentation or host-side tests. Revert the PR through Git when
necessary; separately undo a deployment only if one actually occurred.
