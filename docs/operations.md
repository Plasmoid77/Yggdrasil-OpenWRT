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
netifd underneath a live Yggdrasil interface.

### The cold-boot race and the hotplug guard

The stock handler `/lib/netifd/proto/yggdrasil.sh` starts the daemon and sends
its link-up update to netifd immediately. When the daemon creates the `ygg0`
TUN device a moment later — typical on a cold boot with a busy CPU — netifd
cannot claim a device that does not exist yet and answers with an error, which
the log shows as:

```text
netifd: ygg0 (…): Command failed: ubus call network.interface notify_proto { … "ifname": "ygg0", "link-up": true … } (Unknown error)
```

The handler does not retry. The daemon runs with its peers, but netifd leaves
the interface at `up:false pending:true` forever: no address or prefix in
`ifstatus`, no device in the `ygg` firewall zone, so every Yggdrasil packet —
trusted node included — hits the zone-less `handle_reject` and gets a TCP RST
or ICMPv6 port-unreachable *from the router's own node address*. The router
looks healthy from the LAN while the whole design is unreachable from outside.
Restarting the interface clears it in one shot. It hit the tested router once
during 1.x development, did not reproduce in fourteen further reboots, and hit
again after an unattended reboot on 2026-09-21 while the owner was away.

The package is not touched — a fix inside `/lib/netifd/proto/yggdrasil.sh`
would be undone silently by the next `apk upgrade`, and the project does not
send changes upstream. The deployer instead writes a hotplug script of its
own, `/etc/hotplug.d/net/50-yggdrasil-pending`: when procd reports the `ygg0`
device appearing (`ACTION=add`), it notes the device's ifindex, waits ten
seconds in the background — a healthy setup finishes in three — and, if the
interface is still `pending` and the device is still the same one, restarts it
with `ubus call network.interface.ygg0 down` and `up` (not `ifup`, which
first reloads the whole network configuration). A device recreated meanwhile
means somebody already restarted it, and the script does nothing. If the
daemon never starts there is no device, no event and no loop. Each restart
plays the same race again, which a warmed-up system wins; this is recovery by
retry, not a guarantee, and it stops after five restarts per boot (a counter
in `/tmp`, gone at the next boot) rather than bounce the daemon forever. Verified on the router with a deliberately induced
failure: update sent before the daemon → `Unknown error` → ten seconds later
`yggdrasil-hotplug: ygg0 still pending … restarting the interface` → `is now
up` one second after. And on the second of two validation cold reboots the
real race happened by itself (`Unknown error` at boot+2 s, TUN created the
same second, just after the update) and the guard recovered it 17 s later —
under boot load the ten-second timer and the hotplug queue took longer, which
is fine.

Diagnosis in one line when the router answers pings but rejects everything
over Yggdrasil:

```sh
ifstatus ygg0 | jsonfilter -e '@.up' -e '@.pending'; nft list chain inet fw4 input | grep -c ygg0
```

`true false 1` is healthy. `false true 0` is this race; `logread | grep
yggdrasil-hotplug` shows whether the guard has acted.

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

For a DHCPv6 client the table shows the bound lease first (bold,
`ipv6_source: dhcpv6`) and its SLAAC addresses after it: with the stock hybrid
both exist at once, and the reservation names the lease address, not the ones
the client formed itself.

### A client shows no reserved address

Three causes, in order of likelihood:

1. It has no DHCPv6 client. Android has none by policy; some IoT and smart-TV
   stacks neither. Such a device takes SLAAC addresses from the routed prefix
   like from any other and is reachable on those, but a reservation cannot
   name them.
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
   `MAC+duid:<HEX>%IAID` each - the MAC, because odhcpd keys host sections
   on DUID bytes and MACs and would fold two DUID-only sections into one;
   the IAID, to tell the ports apart.
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

The missing piece was an INPUT firewall rule for TCP/UDP 53 from the `ygg` zone
(since deployer 2.0.4 that is `YGG-Trusted-to-Router`, which admits UDP).

Always distinguish:

```text
DNS record exists?
DNS listener exists?
firewall permits Ygg -> router:53?
```

### IPv4-only sites can stall for a second: carrier DNS64 (known limitation)

Observed on MegaFon LTE (2026-09-22/23). The carrier's IPv6 resolvers do DNS64:
for an IPv4-only name they synthesise a `64:ff9b::/96` AAAA (TTL 10 s); its IPv4
resolvers do not. dnsmasq forwards to all four, which answer equally fast, so
its choice drifts and the synthesised answers come in episodes.

A LAN client then sources `64:ff9b::` traffic from its routed Yggdrasil address:
RFC 6724 rule 8 prefers it because `0303:` shares more leading bits with
`0064:` than `2a03:` does. The router has no Internet route for that source and
answers ICMPv6 unreachable, but `net.ipv6.icmp.ratelimit` (1000 ms) drops some
of those errors, so a connection waits for its first SYN retransmit (~1 s).
Happy Eyeballs hides most of it; IPv4 is unaffected. The carrier's NAT64 itself
works from the native source. An IPv4-only PDN produces the same pattern for
dual-stack destinations, because the router still announces itself as the IPv6
default router (`ra_default=2`); expected from the mechanism, not measured.

Accepted as is (owner decision, 2026-09-23): every DNS-side fix tested in an
isolated dnsmasq had a worse failure mode — `strictorder` hangs all DNS when
the first resolver is dead; `ignore-address` plus `all-servers` is bypassed over
TCP and hangs AAAA lookups when the IPv4 resolvers are down; an IPv4-only
resolver file leaves no DNS at all, including the router's own peer hostnames.

Diagnose with `dig AAAA <IPv4-only name> @192.168.1.1` (a `64:ff9b::` answer)
and, on a client, `ip -6 route get 64:ff9b::<x>` (the source is the `303:`
address). The client-side cure is an address-selection label for `200::/7`
(`ip addrlabel` or `gai.conf`), so overlay addresses are only preferred for
overlay destinations.

### Reserved `::HOSTID` addresses return only at the client's next DHCPv6 renew

Seen after a router reboot and after a clean reinstall (2026-09-23). A DHCPv6 client (zeonux,
`dhcpcd`) confirms its previous lease right after the router comes up. At that moment `ygg0`
and the LTE uplink are not up yet, so only the ULA is on-link: odhcpd answers **Not On Link**,
the client takes a lease with just `fd…::10` and drops `303:…::10` and the native `::10`. Its
SLAAC addresses in the routed and native prefixes appear by themselves within a minute or two,
and odhcpd's lease already lists all three reserved addresses, but the client installs them
only at its next Renew (T1, about 20 minutes here). Nothing is misconfigured; `zeonux.home.arpa`
is just unreachable in that window. To shorten it, renew on the client (`dhcpcd -N <if>`;
`dhcpcd -n` only confirms and does not add addresses) or reconnect it. Note also that every
PDN re-activation gives the LAN a new native prefix, so native reservations change with it.

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

The hotplug guard against the cold-boot race lives in
`/etc/hotplug.d/net/50-yggdrasil-pending`, outside any package, and survives
upgrades; it is rewritten by a deployer rerun only if its text changed.

### Moving a 1.x router to 2.0

Reinstall: reset to stock, bring the uplink back, run 2.0 with the same
settings file minus the `dhcpv6`/`slaac` flags and with the old private key
(`--private-key-file`). The node address, the routed /64, reservations and
trusted access come back from those inputs; there is no in-place migration.
The deployer never removes a `hostid`; omitting a `--host` line on a rerun
drops its name and keeps its `hostid`. To retire a reservation for good:
`uci delete dhcp.<section>.hostid; uci commit dhcp; /etc/init.d/odhcpd reload`.

### LAN hosts and Yggdrasil

By default LAN hosts can initiate connections into Yggdrasil through the
router (`LAN-to-Yggdrasil` rule, IPv6 to `200::/7`). Turn it off with a rerun
plus `--no-lan-forward` (or `no-lan-forward` in `[flags]`, so a later rerun
does not turn it back on); flows already established end on their own. A LAN
host that runs its own Yggdrasil node is unaffected either way: its own
`200::/7` route wins over the router's default route. A client with privacy
extensions uses a temporary routed-prefix address as source toward Yggdrasil,
not its reserved one - remote allow-lists on the reserved address match
inbound traffic to the host, not the host's outbound connections.

### Post-update verification

Re-run the relevant layer checks:

```sh
ifstatus ygg0
yggdrasilctl getPeers
ubus call dhcp ipv6ra
ubus call dhcp ipv6leases      # the stateful addresses the router handed out (one per prefix)
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

Delete the `home.arpa` local-zone directive and the `config domain` records used purely for DNS. There is no DNS rule of its own to delete since deployer 2.0.4: trusted nodes reach port 53 through `YGG-Trusted-to-Router`, which also serves SSH and LuCI (an `ygg_dns` rule left by an older run can simply be deleted).

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

Also delete the deployer's hotplug guard, `/etc/hotplug.d/net/50-yggdrasil-pending`.

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
