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

### Post-update verification

Re-run the relevant layer checks:

```sh
ifstatus ygg0
yggdrasilctl getPeers
ubus call dhcp ipv6ra
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
