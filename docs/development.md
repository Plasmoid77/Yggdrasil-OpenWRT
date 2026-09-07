# Development and release discipline

## Host-side checks

Requires Python 3.9+, Git, BusyBox, ShellCheck, jq and Node.js on the development
host. These are not new router dependencies. On a Debian/Ubuntu host:

```sh
sudo apt-get install git python3 busybox shellcheck jq nodejs
sh tools/check.sh
```

The same command runs in CI. Stage new/renamed source files before packaging
because the tools deliberately use `git ls-files`, not an unrestricted copy of
the working directory. Untracked private snapshots, editor files and build
outputs must never be included in distributions.

A constrained host without ShellCheck may run
`SKIP_SHELLCHECK=1 sh tools/check.sh`; it explicitly reports a partial check.
Do not call that a full pass or merge without the complete CI check.

## Automated coverage and remaining manual work

| Check | Runs automatically |
| --- | --- |
| Shell syntax under host sh and BusyBox ash; ShellCheck | All tracked router/test shell entry points |
| JSON and LuCI JavaScript syntax | ACL/menu and frontend |
| Secret handling | Existing deployer stdin, environment, validation, redaction and umask regressions |
| Inventory fixtures | DHCP expiry including unlimited leases; MAC deduplication and persistent lease-free rows; canonical/EUI-64/privacy selection; foreign prefix/MAC filtering; canonical identity guard |
| Presence fixtures | REACHABLE shortcut, ARP success, IPv6 success, failure |
| Mutation guards | Pin existing/expired/pending/busy; Unpin duplicate/shared/complex/static-confirmation/pending/busy |
| Documentation | Local Markdown links and heading fragments, shared Claude instructions |
| Packaging | Exact tracked payload bytes, permissions, provenance, manifest, determinism, unsafe labels, no overwrite, exclusion of untracked files |
| Frozen downloads | Existing archive SHA-256 files |

Fixtures execute actual extracted backend functions with controlled OpenWrt
I/O boundaries. They do not emulate the complete UCI/netifd/rpcd stack.
Successful Pin/Unpin writes, actual service reload/rollback, LuCI dialogs,
firewall behavior, protocol registration and reboot recovery remain manual
integration tests below. Passing syntax or fixtures is not a hardware test.

## Packaging without changing public downloads

Build from a Git checkout with a **new** label (not an existing frozen v4/v5/v5.1
label). The source directory is versionless; the distribution label identifies
the archive, while the legacy installer banner still says v5.

```sh
python3 tools/package.py "dev-$(git rev-parse --short HEAD)" --output dist
cd dist
sha256sum -c *.tar.gz.sha256
```

A package contains exactly the tracked status source plus `BUILD_INFO.json`
(commit, source dirty flag and distribution label) and `MANIFEST.sha256`.
The source files are copied without content rewriting. Executable modes come
from Git. Tar owner/group are normalized; timestamps use SOURCE_DATE_EPOCH
(default 0); gzip has no host filename/timestamp. Repeatability is tested for
the same checkout and toolchain. No claim is made about arbitrary compression
library versions producing identical bytes.

Output creation refuses an existing archive or checksum. Never overwrite an
old release to make it match newer source. A dirty build is a development
artifact, not proof of a released commit. Newly generated artifacts go to
ignored `dist/`; archives already under `packages/` stay byte-for-byte frozen.

The deployer still downloads `main/packages` and has a v5 fallback. This PR
does not migrate those URLs or claim a fresh router validation. Before moving
them to GitHub Releases: publish unchanged historical assets with their
checksums, choose a pinned release/commit download strategy, test fresh install,
local `--status-pkg`, fallback/error behavior and upgrades on hardware, then
change the downloader in a separate reviewed release. Merely creating a
Release does not make old raw URLs safe to delete.

## Version identities

Historical changelog headings (for example v5.9), deployer VERSION (1.5.1) and
status distribution (v5.1) name different things. Do not renumber old history.
The current source directory has no version suffix; Git identifies revisions.
Repository maintenance is recorded by its PR/commits, not an invented release number.

## Regression matrix

Run the following matrix before releasing a modified status module. Entries
not listed as automated above are required manual/synthetic integration checks,
not assertions that CI has executed them. Retained scenarios are intentionally
more extensive than the initial host fixture coverage.

## Static validation

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
9. `tests/deploy-secret-handling.sh` passes
```

Do not embed full source listings in README. The packaging tests compare every
tracked payload file to the archive and validate checksums, modes and
repeatability.

---

## Read-only client inventory fixtures

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

### Case E — stable EUI-64 plus privacy addresses

Fixture:

```text
one DHCP lease
same MAC has multiple Ygg /64 IPv6 neighbors
one neighbor is the modified EUI-64 derived from the MAC
neighbor may carry the NDP router flag because the client is a full Ygg node
```

Expected:

```text
one row
only the observed modified EUI-64 shown
no automatic persistence of those addresses
router flag does not change MAC identity or create another row
```

### Case F — privacy-only multiple SLAAC addresses

Fixture:

```text
one DHCP lease
same MAC has multiple Ygg /64 IPv6 neighbors
none is the modified EUI-64 derived from the MAC
```

Expected:

```text
one row
all unique observed Ygg addresses shown
no automatic persistence of those addresses
```

### Case G — canonical + observed address

Fixture:

```text
persistent host
matching config domain canonical IPv6
one or more observed addresses
```

Expected:

```text
canonical_ipv6 populated
canonical is the only displayed/probed IPv6 address
```

### Case H — dynamic hostname collision with canonical record

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

## Presence tests

### IPv4 ARP success

Expected `online=1` without needing IPv6 ping.

### IPv4 ARP failure + IPv6 ping success

Expected `online=1`.

### Both fail

Expected `online=0`.

A recent NUD `REACHABLE` result is the intentional shortcut: expect Online
without spawning a new ARP/IPv6 probe. With `STALE`, `DELAY`, `PROBE`, `FAILED`
or no entry, expect fallback to probes, not a direct presence verdict.

---

## Pin tests

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

## Unpin tests

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

## Rollback tests

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

## LuCI tests

Verify:

```text
Node table renders
Peers table renders
LAN clients renders
15-second polling only while page open
Online green
Offline red
privacy-only multiple IPv6 addresses render as multiple lines
observed modified EUI-64 suppresses other privacy IIDs
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

## Real-router smoke test

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

For a client whose NDP set contains a modified EUI-64 plus historical privacy
IIDs, the RPC response and LuCI row must contain only the EUI-64. A
privacy-only fixture must still retain multiple observed addresses.

---

## Core-network regression check

A status-only release must not alter:

```text
network config
Ygg interface identity/private key
RA/SLAAC configuration
DHCPv6 setting
firewall rules
Ygg peers
LAN multicast peering with any full-node clients
Jumper settings
DNS firewall module
```

If any of those change, this is no longer a status-only release and requires a separate network migration plan.

Also test a LAN bridge containing another global `/64`. Runtime IPv6
enrichment must continue selecting the prefix delegated by the netifd
Yggdrasil interface, whatever class netifd derived from that interface's name.
Cover an interface NOT named `ygg` (for example `ygg0`): a backend that
hardcodes `class="ygg"` silently reports no client IPv6 addresses at all.

## BusyBox and UCI pitfalls

Do not accidentally reintroduce these during rewrite.

### BusyBox lowercase portability

This failed on the real OpenWrt/BusyBox environment:

```sh
tr '[:upper:]' '[:lower:]'
```

The final backend uses:

```sh
tr 'A-Z' 'a-z'
```

This was necessary for matching names such as mixed-case hostnames to lowercase `home.arpa` records.

### BusyBox ash variable scope issue

During v4 development, a helper-function arrangement allowed a variable such as `mac` to be overwritten because `ash` shell functions share dynamically scoped variables unless carefully localized.

The code was simplified to remove that fragile path.

When rewriting shell code:

- use distinctive local variable prefixes;
- declare locals in every helper;
- do not assume lexical scoping.

### IPv4 validation test bug

An intermediate `awk` form could incorrectly report success due to how exit status was handled. Current `valid_ipv4()` was corrected and should be covered by tests.

### Anonymous UCI sections

OpenWrt `config host` sections may be anonymous and addressed as `@host[n]` during enumeration. Code must operate on the actual section identifier/selector it receives from OpenWrt helpers and must not assume every section has a friendly explicit name.

### Dynamic hostname must not inherit canonical DNS metadata

DHCP hostnames are client-controlled. Attaching `config domain` solely by hostname to a dynamic client would allow accidental/colliding canonical metadata.

Current code only attaches canonical `config domain` records when a matching persistent `config host` exists.

---


## Documentation ownership and preservation map

| Previous location | Current home |
| --- | --- |
| README overview and final-state summaries | Short README and architecture module map |
| README installation and QUICKSTART | Installation; verbose startup/boot notes in operations |
| README full backend/ACL/menu/JS listings | Actual source files only; no second executable copy |
| README device model, Auto-IP, AI_CONTEXT contracts/limitations | Architecture |
| README rationale, discarded approaches and attribution | Architecture decisions/sources; complete chronological changelog retained |
| REFERENCE_CONFIG | Architecture expected-configuration section |
| README troubleshooting, maintenance, removal | Operations |
| TEST_PLAN, AI_CONTEXT release/pitfall sections | This development guide |
| AI_CONTEXT working constraints | AGENTS; CLAUDE imports it |
| SLAAC_ADDRESS_FIX | Unabridged incident under docs/history, links adjusted |
| MANIFEST and repository-wide checksums | Git tree for source; generated package provenance/manifest; unchanged historical checksums retained with archives |

Published root-level QUICKSTART, AI_CONTEXT and REFERENCE_CONFIG paths remain
short pointers during the transition. Historical code comments/links can find
their replacement without giving agents multiple complete contracts to read.

Do not move old release notes into the current behavior contract wholesale.
Preserve explanations and evidence, but investigate contradictions (such as the
old universal ban on REACHABLE) rather than mechanically reproducing them.

## Review and rollback

Keep runtime and documentation-only changes separate from network redesign.
A changed RPC contract requires backend/frontend/ACL, installer validation and
fixtures to agree. A status-only release must preserve every core-network
invariant listed above. For substantial behavior work, implement and test
read-only inventory first, then address enrichment/presence, then mutations
and rollback, then UI dialogs.

Review the diff, run host checks, then perform the explicitly scoped manual
matrix on a test router with backups and another management path. Record the
actual firmware, commit/archive digest and observed result, rather than
copying an earlier hardware claim. A Git revert restores repository files;
it does not restore a router that has already been reconfigured.
