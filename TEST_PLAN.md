# TEST_PLAN.md — Yggdrasil Status module

Run this matrix before releasing a rewritten or modified status module.

The intent is to catch semantic regressions, not only syntax errors.

---

## 1. Static validation

Required:

```text
1. backend passes `sh -n`
2. backend passes BusyBox `sh -n` when available
3. ACL JSON parses
4. menu JSON parses
5. frontend passes JavaScript syntax check (`node --check` or equivalent)
6. install.sh passes `sh -n`
7. archive passes gzip/tar integrity check
8. checksum file matches archive
```

Also compare embedded code in README against packaged source if README contains full source listings.

---

## 2. Read-only client inventory fixtures

### Case A — DHCP-only dynamic client

Fixture:

```text
active DHCP lease
no config host
one runtime Ygg IPv6 neighbor
```

Expected:

```text
row exists
persistent=0
IPv4 from lease
runtime IPv6 shown
Persistence=Dynamic
```

### Case B — expired DHCP-only guest

Fixture:

```text
expired lease
no config host
possibly stale neighbor entry
```

Expected:

```text
no row
```

Important: NDP alone must not extend dynamic lifetime.

### Case C — persistent host with active lease

Fixture:

```text
active lease
matching config host
```

Expected:

```text
one row only
merged by MAC
persistent=1
hostname prefers config host metadata
```

### Case D — persistent host without lease

Expected:

```text
row remains
persistent=1
lease_expiry empty
usually Offline unless static IPv4/canonical IPv6 still answers
```

### Case E — iOS-like multiple SLAAC addresses

Fixture:

```text
one DHCP lease
same MAC has multiple Ygg /64 IPv6 neighbors
```

Expected:

```text
one row
all unique observed Ygg addresses shown
no automatic persistence of those addresses
```

### Case F — canonical + observed address

Fixture:

```text
persistent host
matching config domain canonical IPv6
one or more observed addresses
```

Expected:

```text
canonical_ipv6 populated
canonical appears first/bold in UI
observed addresses also shown
duplicates removed
```

### Case G — dynamic hostname collision with canonical record

Fixture:

```text
DHCP-only client claims same hostname as an existing config domain
no matching persistent config host for that MAC
```

Expected:

```text
client does NOT inherit canonical_ipv6 or DNS alias
```

---

## 3. Presence tests

### IPv4 ARP success

Expected `online=1` without needing IPv6 ping.

### IPv4 ARP failure + IPv6 ping success

Expected `online=1`.

### Both fail

Expected `online=0`.

Do not map NUD `STALE` or `REACHABLE` directly to online state.

---

## 4. Pin tests

### Pin without IPv4 reservation

Input:

```text
active DHCP-only client
valid hostname
reserve_ipv4=false
```

Expected UCI:

```uci
config host 'ygg_status_<normalized_mac_without_colons>'
    option name '<hostname>'
    option mac '<mac>'
```

Expected after refresh:

```text
same row
persistent=1
managed_pin=1
static_ipv4=0
Persistence=Pin/Pinned state
```

### Pin with IPv4 reservation

Expected:

- backend re-reads current lease;
- ignores stale browser IPv4;
- stores current lease IPv4;
- `static_ipv4=1` after refresh.

### Pin after lease expired

Expected:

```text
no_active_lease
no UCI mutation
```

### Invalid hostname/MAC

Expected validation error and no UCI mutation.

### Existing persistent host

Expected:

```text
already_persistent
no duplicate host section
```

### Existing uncommitted DHCP UCI changes

Expected:

```text
pending_uci_changes
no mutation
```

### Concurrent Pin/Unpin mutation

Hold `/var/lock/yggdrasil-status-dhcp.lock`, then issue a valid Pin or Unpin
request.

Expected:

```text
busy
no UCI mutation
```

---

## 5. Unpin tests

### Simple managed pin, lease still active

Expected:

```text
config host removed
row remains as Dynamic
```

### Simple persistent host, no lease

Expected:

```text
config host removed
row disappears
```

### Static IPv4 reservation, first attempt

Expected:

```text
static_confirmation_required
host not deleted
```

### Static IPv4 reservation, explicit confirmation

Expected:

```text
host section deleted
reserved IPv4 removed with it
config domain untouched
```

### Multi-MAC host

Expected:

```text
shared_host
no deletion
```

### Duplicate MAC in multiple host sections

Expected:

```text
ambiguous_host
no deletion
```

### Complex host with extra DHCP options

Expected:

```text
complex_host
no deletion
```

### Already dynamic

Expected:

```text
already_dynamic
```

---

## 6. Rollback tests

Simulate or stub failure of:

```text
uci commit dhcp
dnsmasq reload
```

Expected:

- previous `/etc/config/dhcp` restored;
- UCI state reverted/reloaded;
- failure returned;
- no partial host section remains.

Installer rollback test:

- make RPC validation fail after files are copied;
- verify previous backend/ACL/menu/frontend are restored from `/root/yggdrasil-status-backup-*`.

---

## 7. LuCI tests

Verify:

```text
Node table renders
Peers table renders
LAN clients renders
15-second polling only while page open
Online green
Offline red
multiple IPv6 addresses render as multiple lines
canonical IPv6 bold
Dynamic shows Pin
Pinned shows Unpin
Persistent shows Unpin
Static shows Manage/confirmation path
Protected host shows Manage and no destructive button
Pin dialog defaults Reserve current IPv4 to unchecked
backend errors display as notifications/dialog errors
```

---

## 8. Real-router smoke test

After local validation, install only the status module and verify without restarting core networking.

Recommended checks:

```sh
ubus -v list luci.yggdrasil-status
ubus call luci.yggdrasil-status clients
cat /tmp/dhcp.leases
ip -6 neigh show dev br-lan
uci show dhcp | grep '=host' -A4
```

Then check in LuCI:

```text
Status -> Yggdrasil
```

At least one DHCP-only client should appear without a manual `config host` if such a client is currently leased.

---

## 9. Core-network regression check

A status-only release must not alter:

```text
network config
Ygg interface identity/private key
RA/SLAAC configuration
DHCPv6 setting
firewall rules
Ygg peers
Jumper settings
DNS firewall module
```

If any of those change, this is no longer a status-only release and requires a separate network migration plan.

Also test a LAN bridge containing another global `/64`. Runtime IPv6
enrichment must continue selecting the prefix delegated by the netifd
Yggdrasil interface with `class=ygg`.
