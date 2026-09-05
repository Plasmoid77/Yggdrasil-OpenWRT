# REFERENCE_CONFIG.md — generalized final configuration model

This is a compact generalized reference. Use `README.md` for installation details and rationale.

Values in angle brackets are placeholders.

---

## 1. Yggdrasil interface

Canonical documentation name:

```text
ygg0
```

Example:

```uci
config interface 'ygg0'
    option proto 'yggdrasil'
    option private_key '<PRIVATE_KEY>'
    option public_key '<PUBLIC_KEY>'
    option jumper_enable '1'
    option jumper_loglevel 'info'
    option allocate_listen_addresses '1'
    option jumper_autofill_listen_addresses '1'
    option multipath 'off'
```

Remote peer sections:

```uci
config yggdrasil_ygg0_peer
    option address '<CURRENT_PEER_URI>'
```

LAN multicast peering for full Yggdrasil nodes:

```uci
config yggdrasil_ygg0_interface
    list interface 'br-lan'
    option beacon '1'
    option listen '1'
```

---

## 2. LAN routed `/64`

Network model:

```uci
config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    list ipaddr '<LAN_IPV4/CIDR>'
    option ip6assign '64'
    list ip6class 'ygg0'
```

`ip6class` must name the class netifd publishes for the delegated prefix, and
that class is the name of the Yggdrasil interface section (`ygg0` here). An
earlier revision of this project named that section `ygg`, hence the older
`ip6class 'ygg'`. Setting `ip6class` on the Yggdrasil interface itself does not
change the published class.

This profile removes the extra generated ULA:

```text
network.globals.ula_prefix absent
```

---

## 3. SLAAC-only RA

```uci
config dhcp 'lan'
    option interface 'lan'
    option dhcpv4 'server'
    option dhcpv6 'disabled'
    option ra 'server'
    option ra_default '2'
    option ra_preference 'medium'
    option ra_slaac '1'
    list ra_flags 'none'
```

Exact DHCPv4 start/limit/leasetime are site-specific.

---

## 4. Firewall zone

```uci
config zone
    option name 'ygg'
    option input 'REJECT'
    option output 'ACCEPT'
    option forward 'DROP'
    list network 'ygg0'
```

No masquerading/NAT66.

Do not add blanket forwarding.

Trusted Ygg client to LAN:

```uci
config rule
    option name 'YGG-Trusted-to-LAN'
    option src 'ygg'
    option dest 'lan'
    option family 'ipv6'
    list proto 'all'
    list src_ip '<TRUSTED_YGG_IPV6_1>'
    list src_ip '<TRUSTED_YGG_IPV6_2>'
    option target 'ACCEPT'
```

Trusted Ygg client to router:

```uci
config rule
    option name 'YGG-Trusted-to-Router'
    option src 'ygg'
    option family 'ipv6'
    list proto 'tcp'
    list src_ip '<TRUSTED_YGG_IPV6_1>'
    list src_ip '<TRUSTED_YGG_IPV6_2>'
    option target 'ACCEPT'
```

A stricter deployment may restrict destination ports.

---

## 5. Persistent status identity

Pin without fixed IPv4:

```uci
config host 'ygg_status_aabbccddeeff'
    option name 'Laptop'
    option mac 'aa:bb:cc:dd:ee:ff'
```

Existing normal OpenWrt `config host` records are also accepted as persistent identities.

Optional fixed IPv4:

```uci
config host 'ygg_status_aabbccddeeff'
    option name 'Laptop'
    option mac 'aa:bb:cc:dd:ee:ff'
    option ip '192.168.1.143'
```

---

## 6. Optional canonical Ygg IPv6 / DNS metadata

```uci
config domain
    option name 'laptop.home.arpa'
    option ip '<STABLE_YGG_ROUTED_IPV6>'
```

This does **not** assign the SLAAC address. It is metadata + a standard dnsmasq record.

---

## 7. Optional DNS over Yggdrasil

Current tested trusted-source rule:

```uci
config rule 'ygg_dns'
    option name 'Allow-DNS-from-Trusted-Yggdrasil'
    option src 'ygg'
    option proto 'tcp udp'
    option dest_port '53'
    list src_ip '<TRUSTED_YGG_IPV6_1>'
    list src_ip '<TRUSTED_YGG_IPV6_2>'
    option target 'ACCEPT'
```

WAN DNS exposure is not part of this design.

---

## 8. Status module files

```text
/usr/libexec/rpcd/luci.yggdrasil-status
/usr/share/rpcd/acl.d/yggdrasil-status.json
/usr/share/luci/menu.d/yggdrasil-status.json
/www/luci-static/resources/view/status/yggdrasil.js
```

Dependency:

```text
iputils-arping
```

RPC object:

```text
luci.yggdrasil-status
```

Methods:

```text
clients
pin
unpin
```
