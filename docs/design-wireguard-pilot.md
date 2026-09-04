# Design: WireGuard pilot (two hubs, one new wg0)

> Status: proposal, nothing applied. Date: 2026-09-04.
> Grounded on production alpha-0.2.2a90 (server commit 0910e61, which is
> lattice-server `origin/integration` HEAD at the time of writing), read-only
> GETs against `/api/version`, `/api/nodes`, `/api/netguard/reality`
> (one detail call per node), `/api/netguard/nodes`, `/api/netguard/zones`,
> `/api/netguard/groups`, `/api/network/nft/inputs` and `/api/network/approvals`
> (all 1275 rows, paged) at 2026-09-04 14:26Z to 14:52Z, plus the code in
> lattice-server, lattice-node-agent and lattice-plugin-wireguard 0.1.0-alpha.13.
> Related: `designs/design-13-wireguard-and-netguard-plugins.md`,
> `iterations/iter-070-wireguard-topology-and-apply-safety.md`.

## 1. The ask and the boundary

The operator allowed WireGuard to be configured "without affecting existing
use". This document turns that into the smallest pilot that proves the product
path end to end: two hub-capable nodes get a WireGuard identity, each is planned
through the plugin, approved, and applied under a rollback, and the two
establish a handshake on a brand-new `wg0`. Nothing else changes: sing-box is
not restarted or reloaded, no existing peer is reconfigured (there is none: no
node carries a `wg*` interface today), no NetGuard plan is filed, no NAT node
joins, and no knock node or the DoH host is touched.

Two things this document corrects in older records. First, design-13 section 3
still lists "WireGuard apply has no rollback/watchdog" as gap 1; iter-070 closed
that on 2026-07-09 and the chain is in production (`wireguardApplyScript`,
`internal/server/server.go:6699`, watchdog at `:6758`). The pilot builds on that
chain rather than rebuilding it, but section 6 shows the chain has never
executed on a node and, as written, cannot: it aborts on the first line that
matters under the shell the agent actually uses. Fixing that is the gate on the
whole pilot, not a nicety.
Second, the understand-phase rule "no hub on a NetGuard-bound node" was written
when the store held one binding; since 2026-09-04 14:2xZ all 24 in-scope nodes
carry an observe-only binding (`managed=false`, no `lattice_guard` table anywhere
in the fleet reality feed), so read literally the rule leaves zero candidates.
Section 3 reads "bound" as "managed or carrying an applied guard", and lists
that reading as an operator decision.

## 2. Evidence base

| Source | What it said (2026-09-04, 14:26Z fleet sweep and a 14:45 to 14:52Z re-read) |
|---|---|
| `/api/version` | server `alpha-0.2.2a90`, commit `0910e61aff6d`, dashboard `f7d52fc43d1a` |
| `/api/nodes` | 33 nodes, 33 online (the OpenJobs tmp node is back), `wireguard_ip` empty on 33 of 33, `wireguard_public_key` absent on 33 of 33 |
| `/api/netguard/nodes` | 24 rows, every one `managed=false` with `last_applied_at` zero, so no node is under live guard control |
| `/api/netguard/reality`, one call per node at 14:50Z | 32 snapshots fresh, 1 unknown (mac-air, the only node that never reports interfaces) |
| Per-node reality | no `wg*` interface on any node; no address inside 10.66.0.0/24 on any node; `inet lattice_knock` on 7 nodes; no `lattice_guard` anywhere |
| `/api/netguard/zones` | builtin `wireguard` zone has no interfaces and no cidrs stored; the cidr is filled at resolve time from the code default |
| `/api/network/nft/inputs` | one record, dmit-eb-wee, `wireguard_cidr` 10.66.0.0/24 (its port lists were rewritten from reality at 07:50Z by the NetGuard lane; the cidr was not touched) |
| `/api/network/approvals`, all 1275 rows | every approval the control plane has ever held is `agentupdate`, `singbox-linemeta` or `sshguard`. Zero `nft`, `netguard`, `nftpolicy`, `selfdns`, `proxycore` or `wireguard`, so no apply script in that family has ever run on a node |
| Server code | `approvalDecisionExtraScope` returns `""` for wireguard (`server.go:7579-7620`, asserted by `server_approval_scope_test.go:35`); `approvalApplyTaskTimeoutSec` has no wireguard case, so the apply task runs with `defaultTaskTimeoutSec = 30` (`server.go:433, 6109-6141`) against `applyWatchdogWindowSec = 60` (`server.go:6688`); the apply, both nft scripts and the proxy-core script use `trap ... ERR` (`server.go:6636, 6669, 6730`, `server_proxy.go:1098`) while approval tasks run with `Interpreter: "sh"` (`server.go:7262`) and the agent maps that to `/bin/sh` (`taskexec.go:22`) |
| Agent code | WG identity enters only through `-wg-ip`, `-wg-pubkey`, `-wg-endpoint`, `-wg-port` or `LATTICE_WG_IP`, `LATTICE_WG_PUBKEY`, `LATTICE_WG_ENDPOINT`, `LATTICE_WG_PORT` (`cmd/lattice-agent/main.go:258-262`); task scripts run with `PATH=/usr/bin:/bin:/usr/local/bin` and a minimal environment (`internal/taskexec/taskexec.go:417`) |
| Plugin | `latticenet.wireguard` 0.1.0-alpha.13, methods `overview` (wireguard:read) and `plan` (wireguard:admin + network:plan), both backed by core; the sidecar answers describe/health/plan only |

## 3. Hub candidates

### 3.1 The filter

Start from the 18 nodes whose `public_ip` sits on a local interface (the other
15 are NAT, home LAN, laptop or AWS-with-elastic-IP and can only ever be
spokes). Remove the 7 knock nodes, identified by the `inet lattice_knock`
table in their reality feed: dmit-1, dmit-3, dmit-eb-wee, gomami-hkg,
node_gdawc2fnz6mhfath (DMIT-4), node_xwgxl2etfoguca7r (DMIT-2), qqpw-hawaii.
Remove the DoH host node_ob46mh4ltshdpkhc ([cd]-DMIT-pro-malibu). Ten remain:

| Node | Name | Public iface | Kernel / distro | nftables | Foreign tables | Why not a knock node | Notes against it |
|---|---|---|---|---|---|---|---|
| node_pk6zjl4rf6cpmzgz | [Metix]-VIRCS-ATT-VDS | eth0 12.22.163.232/23 | 6.12.90+deb13, Debian 13 | 1.1.3 | none | no `lattice_knock`, sshd on 22 only | named by the DNS lane as its parallel-DNS demo host (one writer per node) |
| legend-sg | [cd]-LegendVPS-SG-EVO | eth0 77.93.91.41/24 (+ v6 /48) | 6.1.0-50-cloud, Debian 12 | 1.0.6 | inet filter, ip/ip6 filter, mangle, nat | no `lattice_knock`, sshd on 22 only | iptables-nft tables (tailscaled shape); `inet filter` policy unknown from the API |
| node_rqv4sg6nzqds23ko | [Metix]-Aaitr-Frontier-VDS | ens17 47.178.47.100/26 | 6.1.0-10, Debian 12 | 1.0.6 | none | no `lattice_knock`, sshd 22 | mac-air reports the same public IP 47.178.47.100, so this VDS fronts a home LAN's egress |
| node_wd5mbqqoptkid47m | [Metix]-Aaitr-ATT-VDS | ens17 108.202.51.182/26 | 6.1.0-10, Debian 12 | 1.0.6 | none | no `lattice_knock`, sshd 22 | homeserver reports the same public IP 108.202.51.182 (same shape as above); 11 unexplained UDP high ports in the audit |
| aaitr-att | [cd]-Aaitr-ATT-VDS | ens17 108.195.128.236/26 | 6.1.0-10, Debian 12 | 1.0.6 | inet filter, ip/ip6 filter, nat | no `lattice_knock`; sshd on 3434 but by a hand-made `inet filter`, not the product | hand-made firewall of unknown policy; tailscale0 present |
| gomami-jpn | [Metix]-gomami-jp-pulse-mini | eth0 103.112.1.30/24 | 6.12.90+deb13, Debian 13 | 1.1.3 | none | no `lattice_knock`, sshd 22 | 26 sing-box inbounds plus 3proxy 1088; one of the 7 nodes with a pending singbox-linemeta approval |
| node_5cuasrdombvftahf | [cd]-gomami-jpn-pulse-nano | eth0 151.244.134.20 | 6.12.74+deb13, Debian 13 | 1.1.3 | ip/ip6 filter, mangle, nat, raw | no `lattice_knock`, sshd 22 | Docker, frps, nginx 80/443 (nezha), tailscale0: the busiest cd node |
| node_x4h72ktobmldwddm | [Metix]-qqpw-cd3-VDS | eth0 72.253.152.48 | 6.1.0-45-cloud, Debian 12 | 1.0.6 | inet dns_hijack_local, inet filter | no `lattice_knock`, sshd 22 | carries the DNS-hijack table the DNS lane owns |
| node_ybl6wwyq6zcjpdpw | [Metix]-qqpw-cd2-VDS | eth0 72.253.152.126 | 6.1.0-45-cloud, Debian 12 | 1.0.6 | inet dns_hijack_local, inet filter | no `lattice_knock`, sshd 22 | same as cd3 |
| node_4ol55vwphys3rgdt | [cd]-Akkocloud-UK-London-KVM | eth0 38.59.226.89/22 | 6.1.0-44-cloud, Debian 12 | absent | none | no `lattice_knock`; sshd on 3434 without any nft table | no nft at all (NetGuard blind), 1 vCPU 1 GiB, uptime 9 h at observation |

Every kernel in the table is 5.6 or newer, so the in-tree `wireguard` module
exists; `wireguard-tools` presence is unknown from the API on every node and is
a preflight item (section 8, step 1).

### 3.2 Hub A: node_pk6zjl4rf6cpmzgz, [Metix]-VIRCS-ATT-VDS

Evidence: public interface `eth0` carrying 12.22.163.232/23 and a link-local v6
only; kernel 6.12.90+deb13 on Debian 13; nftables v1.1.3; `foreign_tables` is
empty, so nothing on the host can silently drop inbound UDP 51820; sshd on
port 22 and no `lattice_knock` table, so it is not a knock node; 4 cores, 8 GiB,
uptime 29 days, agent 0.3.9-alpha.8, `allow_root_exec` true, sandbox
`linux-rlimit-process-group`; reality snapshot fresh at 14:46:07Z; observe-only
binding present, `managed=false`. Listeners: sshd tcp/22, sing-box tcp/34656
and udp/34657 (a discovered line), sing-box stats on 127.0.0.1:8080, and three
sing-box UDP sockets on 0.0.0.0 (40884, 48722, 53144) that match no line. The
14:26Z snapshot listed a different six (42216, 44423, 45209, 48455, 53656,
59999), and a set that turns over between snapshots is outbound QUIC rather
than an inbound service. Neither set contains 51820.
No other node reports 12.22.163.232 as its public IP, so unlike the two Aaitr
VDS nodes there is no evidence that it fronts a home LAN.

Against it: the DNS lane proposed the same node for the parallel CoreDNS demo,
and the one-writer-per-node guardrail means the operator has to sequence the
two; and the `HOME` tag says the box sits behind the operator's own AT&T line,
so inbound UDP 51820 depends on that router, which Lattice cannot see.

### 3.3 Hub B: legend-sg, [cd]-LegendVPS-SG-EVO

Evidence: public interface `eth0` carrying 77.93.91.41/24 and a routed
2a14:7dc0:102:10a5::2f/48; kernel 6.1.0-50-cloud on Debian 12; nftables v1.0.6
(the version 16 fleet nodes run, so the pilot exercises the majority kernel and
nft pairing); sshd on 22 only and no `lattice_knock`; `tailscale0` up with
100.86.92.48/32, which is the second management path the guardrails ask for;
2 cores, 2 GiB, uptime 28 days; snapshot fresh at 14:25:47Z; observe-only
binding, `managed=false`. Listeners: sshd tcp/22, sing-box tcp/17891 and
udp/17892 (one line), stats on 127.0.0.1:8080 and :9090, tailscaled udp/41641
and two tailscaled TCP sockets on Tailscale addresses. Singapore against
Fremont gives the handshake a real cross-Pacific path, and the node is a `cd`
node, so the second hub carries no Metix customer traffic.

Against it: the reality feed lists `inet filter` and the `ip`/`ip6` filter,
mangle and nat tables. The `ip`/`ip6` set is the shape tailscaled leaves
(`ts-input`, `ts-forward` chains); `inet filter` is the shape of Debian's stock
`/etc/nftables.conf`, whose input chain is policy accept. The API reports only
table names, so the input policy must be read once before the apply (step 1).

### 3.4 Alternate

node_rqv4sg6nzqds23ko ([Metix]-Aaitr-Frontier-VDS) is the cleanest host on
paper (Debian 12, no foreign tables, one sing-box line), but mac-air reports
the same public IP, which says the VDS is the egress for a home LAN; a routing
mistake on it reaches the operator's own desk. It is the fallback if the
operator rejects either hub above, with that caveat stated.

## 4. Mesh CIDR: keep 10.66.0.0/24

Decision: keep 10.66.0.0/24. Hub A takes 10.66.0.1/24, hub B takes 10.66.0.2/24;
future spokes start at 10.66.0.16.

For: the scan of every interface address on 33 nodes finds no address in
10.66.0.0/24, and no route can be checked from the API but the known overlays
(Tailscale 100.64.0.0/10, Docker bridges 172.17-172.31) do not overlap it. The
range is assumed in four places on integration HEAD, and moving it means
changing all of them in one release plus rewriting the dmit-eb-wee `NFTInputs`
record:

| Site | What it does |
|---|---|
| `internal/network/nft.go:138` | `NormalizeNFTPlan` fills `WireGuardCIDR` with 10.66.0.0/24 when a raw nft plan has none |
| `internal/netguard/convert.go:21` | `defaultWireGuardCIDR` used when converting a legacy `NFTInputs` record into a NetGuard group |
| `internal/server/server_netguard.go:422` and `:561` | `resolveNodeZonesFrom` gives the builtin `wireguard` zone that cidr per node, and the builtin zone table declares it |
| `internal/wireguard/wireguard.go:77` and `internal/wireguard/topology.go:54` | `ensureCIDR(address, 24)` pins the interface address to a /24, so the prefix length is also hard-coded |

Against keeping it: the two `HOME` nodes and the two Aaitr VDS gateways sit in
front of LANs whose addressing Lattice does not see; if any of them uses
10.66.0.x, the `wg0` route on that node would shadow it. The operator confirms
this in decision D2; nothing else argues for a move, and the pilot gains nothing
from one.

## 5. Bootstrap path

The product has no way to give a node a WireGuard identity: no key generation,
no `wireguard-tools` install, no pubkey report (design-13 section 5.7 and the
iter-070 "not yet done" list). Three paths exist.

Path A, operator by hand over SSH: `wg genkey` into `/etc/wireguard/lattice.key`
(0600), four `LATTICE_WG_*` lines in the agent env file, restart the agent.
Fastest, but AGENTS.md forbids SSH shortcuts around the product, and the
change leaves no audit row, no task output and no plan hash.

Path B, design-13 section 5.7 built first: a reviewed bootstrap task
(preflight, package install, key generation, pubkey report into the store) as
a product feature. This is the right end state, and it is the path every later
spoke should use. Building it before ever running WireGuard on this fleet means
designing the preflight matrix and the persistence unit without a single
observed run; it also blocks the pilot on a server release with new store
collections and a new approval kind.

Path C, recommended: the same bootstrap as path A, executed as reviewed generic
tasks through `POST /api/tasks` (`task:run`, interpreter `sh`, root exec is
enabled on both hubs). Tasks are audited, sandboxed, and their output is stored,
which is what the SSH ban protects; the 2026-09-04 ledger already used this
runner for the read-only `nft -c` dry runs. The private key never leaves the
node, and the only value that travels back is the public key. The identity still
lives in the agent env file rather than the store, so path C is a stopgap with a
named ceiling: two hubs, no spokes, and the pilot's preflight output becomes the
input for building path B. Two details make the task correct:

- the env file path is not fixed: `/opt/lattice/lattice-agent.env` is canonical
  and legacy nodes use `/opt/lattice/node-agent/agent.env`; the script reads it
  from `systemctl cat lattice-agent` the way `scripts/install.sh:150` does;
- a task cannot restart the agent it runs under (the restart kills its own
  process group and the task never reports); the restart goes through
  `systemd-run --on-active=5 --unit=lattice-agent-restart-once /usr/bin/systemctl restart lattice-agent`,
  the same detached-unit trick SSH Guard uses for its revert timer;
- `modprobe` lives in `/usr/sbin`, outside the task PATH, so the preflight
  calls `/usr/sbin/modprobe -n wireguard` by absolute path; `wg`, `wg-quick`
  and `ip` are under `/usr/bin` on Debian 12 and 13 and resolve.

## 6. The rollback the apply needs before any node is touched

### 6.1 What exists (iter-070, in a90)

`wireguardApplyScript` validates the candidate with `wg-quick strip`, snapshots
`wg0.conf` to `wg0.rollback.conf`, arms a detached `setsid` watchdog that sleeps
`applyWatchdogWindowSec` (60 s) and then restores the snapshot (or tears `wg0`
down when there was none), commits via `wg syncconf` when only peers changed or
`wg-quick down`/`up` otherwise, runs `lattice-agent --selfcheck-controlplane`,
refuses success if the watchdog fired, and disarms. The key file must exist or
the script exits before touching anything.

That is the design. It has never run: of the 1275 approvals the control plane
has ever held, none is `wireguard`, `nft`, `netguard`, `nftpolicy`, `selfdns` or
`proxycore`, so no script in this family has reached an agent. Section 6.2
defect 2 is what happens the first time one does.

### 6.2 Three defects verified in the code, all fixed before the first apply

1. `trap ... ERR` under `sh`, which stops the apply dead. This is the blocking
   one. Approval applies are queued with `Interpreter: "sh"`
   (`server.go:7262`), the agent maps `sh` to `/bin/sh` verbatim
   (`lattice-node-agent/internal/taskexec/taskexec.go:22`), and `/bin/sh` is
   dash on Debian 12 and 13, which is every candidate hub. dash has no `ERR`
   trap. `trap` is a POSIX special built-in, so the failure is not ignored: run
   under `set -e`, which is line 1 of every one of these scripts, dash prints
   `trap: ERR: bad trap` and exits 1 at that line. Measured, not inferred: a
   five-line script with `set -e`, two function definitions, `trap 'a; b' ERR`
   and an `echo` never reaches the `echo` under dash and exits 1; with `set +e`
   it prints the warning and continues. In `wireguardApplyScript` the trap sits
   after the candidate is written and validated and after the snapshot is
   taken, but before `start_watchdog` and before the `mv` that commits, so the
   first apply on a hub would end as a failed task that leaves
   `/etc/wireguard/wg0.conf.new` (carrying the substituted private key, mode
   0600 from the script's `umask 077`) and no `wg0` at all. That is fail-closed
   and no node is harmed, but the WireGuard apply path cannot succeed as
   shipped. The same line exists in both nft generators (`server.go:6636`,
   `:6669`) and in the proxy-core script (`server_proxy.go:1098`). Of the four
   paths that undo a host change, SSH Guard is the only one that got it right,
   and `internal/sshguard/apply.go:134-138` states the reason in a comment
   nobody carried across; the agent-update and linemeta scripts use EXIT traps
   (`server_agent_update.go:1392`, `linemeta.go:244`) for cleanup, which is why
   they work. iter-070's verification
   did check every generated script with `sh -n`, which parses and cannot see a
   runtime error in a built-in. Fix: the SSH Guard shape, an EXIT trap guarded
   by a success marker (`trap on_exit EXIT INT TERM HUP`), applied to the
   wireguard script and, in the same pass, to the two nft scripts and the proxy
   one. Test: a table over every apply-script generator asserting no rendered
   script contains `trap` with `ERR`, plus the existing order assertions.
   Rejected alternative: queue the apply with `Interpreter: "bash"`, which the
   agent allowlist accepts (`taskexec.go:23`) and which does honour `ERR`. It
   is one line, but it makes correctness depend on bash being present on every
   target and leaves the same latent bug in the other three scripts. Fix the
   trap, not the shell.
2. Task deadline shorter than the watchdog. `approvalApplyTaskTimeoutSec` has
   cases for agentupdate, sshguard and `nft`, `nftpolicy`, `selfdns`, and
   returns `defaultTaskTimeoutSec` (30) for wireguard. Defect 1 hides this
   today; once the script runs, the agent's `process-group-kill` ends the apply
   at 30 s while the `setsid` watchdog survives and rolls the node back at 60 s,
   so a slow but healthy apply is reported failed and then undone. Fix: add
   `"wireguard"` to the `networkApplyTaskTimeoutSec` (90) case, and a test
   asserting every plugin whose script arms a watchdog has a deadline above
   `applyWatchdogWindowSec`.
3. Decision scope asymmetry. Authoring a wireguard plan needs
   `wireguard:admin` plus `network:plan`; deciding it needs only
   `network:apply` because `approvalDecisionExtraScope` returns `""` for the
   plugin. Not a rollback defect, but the guardrail list requires it shipped
   before any wireguard approval exists. Fix: `case "wireguard": return
   "wireguard:admin"` and flip `server_approval_scope_test.go:35`.

### 6.3 The revert timer

The 60 s watchdog answers one question: is the control plane still reachable
after the commit. On a new `wg0` on a hub whose management path never rides the
tunnel, that check passes even when the tunnel is dead, and the watchdog
disarms. For a pilot whose purpose is to prove the tunnel works, the rollback
has to be bound to evidence that it works, and it has to outlive the task so a
person can look. SSH Guard already solved the same problem, so the wireguard
apply gets the same shape, as a stage on the existing `wireguard` /
`apply-config` approval:

- arm stage: before the first change, write `/var/lib/lattice/wireguard/revert.sh`
  (restore `wg0.rollback.conf` and `wg-quick down`/`up`, or `wg-quick down wg0`
  and remove `wg0.conf` when there was no prior config; never touch keys), then
  `systemd-run --on-active=<confirm_window_sec> --unit=lattice-wireguard-revert /bin/sh "$REVERT"`,
  and refuse to continue unless `systemctl list-timers lattice-wireguard-revert`
  shows it. The in-script 60 s watchdog stays as the fast backstop for a shell
  that dies without its trap; the transient unit is the one that survives task
  cgroup teardown and agent restarts. Window: 900 s default, 120 s floor,
  3600 s cap, the SSH Guard constants;
- confirm stage: a second approval on the same node. Its script refuses when no
  timer is pending, then demands evidence: `wg show wg0 latest-handshakes` must
  list at least one peer with a non-zero epoch inside the last 180 s. Only then
  it stops the timer, verifies it is gone, and enables `wg-quick@wg0` for boot
  persistence. Persistence lives at confirm and nowhere else, so a reboot
  inside the window loses the interface instead of losing the revert, the same
  direction SSH Guard chose;
- expiry: the timer fires, `wg0` returns to its previous state, and the node's
  next reality snapshot shows no `wg0`; the approval board reads that the same
  way the SSH Guard board reads an expired arm.

Cost: one server slice (approval stage on the wireguard plugin, two scripts, a
timer-armed lint on the apply, board copy) plus a plugin release if the page
shows the confirm deadline. It rides the same release as the three fixes above.
The honest counter-case: for two hubs whose management never rides `wg0`, a
failed apply costs a dead interface and a stray /24 route, not a lockout, and
the operator may accept the three fixes plus a manual revert task as enough for
the pilot. That is decision D4; this document recommends building the timer,
because the pilot's whole output is "the product path works", and a rollback
that has to be typed by hand is not the product path.

## 7. Operator decisions required

| Id | Decision | Recommendation |
|---|---|---|
| D1 | Hubs: node_pk6zjl4rf6cpmzgz plus legend-sg, alternate node_rqv4sg6nzqds23ko | as listed; and whether the DNS lane's VIRCS demo runs before or after this pilot (one writer per node) |
| D2 | Mesh CIDR 10.66.0.0/24, hubs .1 and .2, listen port 51820 on both | keep; confirm no LAN behind a HOME node uses 10.66.0.0/24; confirm the AT&T home router forwards or does not filter inbound UDP 51820 to VIRCS |
| D3 | Bootstrap path A, B or C | C (reviewed tasks through `/api/tasks`), with B built afterwards from the pilot's preflight output |
| D4 | Rollback set before the first apply: the three fixes only, or the three fixes plus the revert timer and confirm stage | fixes plus timer; window 900 s |
| D5 | The observe-only bindings do not count as "NetGuard-bound" for hub selection | accept; the alternative is no hub at all until the bindings are deleted |
| D6 | Nod for read-only preflight tasks on the two hubs (section 8, step 1) | required by AGENTS.md before any command runs on a node |
| D7 | Server release carrying section 6 (a91 candidate): stop-and-switch is the operator's | reserved |
| D8 | Each apply approval (two arms, two confirms) is a production switch | reserved; the lane stops at "ready for your nod" with the plan hash |
| D9 | Scope of the pilot: no spoke, no hub-and-spoke exposure yet | agree; `handleWireGuardPlan` calls `BuildMesh` (`server.go:6304`) and a mesh of two is the hub pair; `BuildTopology` (`topology.go:33`) is wired to the plan endpoint before the first NAT spoke, as its own slice |

## 8. Step list

Every step names the command, the approval it needs, and the check that says it
worked. Steps 0 to 2 touch no node. Nothing below runs until D1 to D6 are
answered.

| Step | Command | Approval | Check |
|---|---|---|---|
| 0. Server slice | worktree `lattice-server/.wt-x/wireguard-apply-safety` from `origin/integration`; replace the four `trap ... ERR` sites (wireguard `server.go:6730`, nft `:6636` and `:6669`, proxy-core `server_proxy.go:1098`) with the SSH Guard EXIT-trap shape, change `approvalApplyTaskTimeoutSec` and `approvalDecisionExtraScope`, add the revert/confirm stage; `go test ./internal/server/ ./internal/wireguard/ -race -timeout 20m`, then `go clean -cache -testcache` | PR review (code-reviewer and security-reviewer, approvals and scopes are touched); merge to integration is the operator's | a table test over every apply-script generator asserts no rendered script contains an `ERR` trap; `server_approval_scope_test.go` asserts `wireguard:admin`; a new test asserts deadline > `applyWatchdogWindowSec` for every watchdog-bearing plugin; every generated script still passes `sh -n` |
| 0b. Release | tag the a91 candidate, x86_64 precheck on a production data copy, rollback script staged, stop window under 90 s | D7 | `/api/version` reports a91; `/api/nodes` shows no node flipped offline across the switch |
| 1. Preflight, read-only, both hubs | `POST /api/tasks` interpreter `sh`, timeout 60: `uname -r; ls -l /bin/sh; /usr/sbin/modprobe -n wireguard && echo module-ok; command -v wg wg-quick setsid systemd-run; ip -4 route; ip -4 addr show dev eth0; /usr/sbin/nft list table inet filter 2>/dev/null; systemctl cat lattice-agent \| sed -n 's/^EnvironmentFile=-\{0,1\}//p'; ss -lun \| grep -c ':51820 ' \|\| true` | D6 (operator nod), `task:run` | `module-ok` on both; `/bin/sh` resolves to dash, which is the premise of defect 1 in section 6.2 (if it resolves to bash on either hub, say so and re-read that section for that node); `wg` absent is expected and drives step 2; no listener on 51820; no route inside 10.66.0.0/24; on legend-sg the `inet filter` input chain is policy accept, otherwise stop and report |
| 2. Bootstrap hub A, then hub B | `POST /api/tasks` interpreter `sh`, timeout 300: `apt-get install -y wireguard-tools`; `umask 077; mkdir -p /etc/wireguard; [ -f /etc/wireguard/lattice.key ] \|\| wg genkey > /etc/wireguard/lattice.key; wg pubkey < /etc/wireguard/lattice.key`; append `LATTICE_WG_IP=10.66.0.1` (B: `.2`), `LATTICE_WG_PUBKEY=<printed pubkey>`, `LATTICE_WG_ENDPOINT=<public_ip>:51820`, `LATTICE_WG_PORT=51820` to the env file found in step 1; `systemd-run --on-active=5 --unit=lattice-agent-restart-once /usr/bin/systemctl restart lattice-agent` | D3, one task per hub, operator nod each | task output shows the pubkey (44 chars, base64); within 30 s `/api/nodes` shows `wireguard_ip` and `wireguard_public_key` for the node; the plugin overview lists it as mesh-ready; `online` never drops (the restart is under the 90 s liveness threshold) |
| 3. Plan hub A | plugin page, or `POST /api/network/wireguard/plan {"node_id":"node_pk6zjl4rf6cpmzgz","listen_port":51820}` | `wireguard:admin` + `network:plan` (authoring) | approval `plugin=wireguard action=apply-config` pending; plan text is `[Interface] Address = 10.66.0.1/24, ListenPort = 51820, PrivateKey = placeholder` and one `[Peer]` with hub B's pubkey, `AllowedIPs = 10.66.0.2/32`, `Endpoint = 77.93.91.41:51820`, `PersistentKeepalive = 25`; `plan_sha256` recorded |
| 4. Arm hub A | approve the approval | D8; `network:apply` + `wireguard:admin` after step 0; an open SSH session to hub A and the provider or home console confirmed reachable first | task ends "applied via restart" with the revert timer armed; next reality snapshot lists `wg0` with 10.66.0.1/24; `systemctl list-timers lattice-wireguard-revert` in the task output |
| 5. Plan and arm hub B | same as 3 and 4 with `node_id` `legend-sg` | D8; open SSH plus the Tailscale path (100.86.92.48) | `wg0` with 10.66.0.2/24 in reality; peer is hub A with `Endpoint = 12.22.163.232:51820` |
| 6. Handshake evidence | read-only task on each hub: `wg show wg0 latest-handshakes; wg show wg0 transfer; ping -c 3 -W 2 10.66.0.2` (A) and `... 10.66.0.1` (B) | operator nod, `task:run` | non-zero handshake epoch on both sides, three replies each way; sing-box line count on `/api/proxy/discovered` still 138 and both nodes' lines unchanged |
| 7. Confirm both hubs | approve the confirm stage on each node (inside the 900 s window) | D8 | timer gone, `wg-quick@wg0` enabled, approval shows confirmed; if the window expires instead, reality shows no `wg0` and the approval reads expired |
| 8. Soak 24 h | read-only: `/api/nodes`, `/api/netguard/reality` per hub each hour | none | `online` unchanged, `wg0` present in every fresh snapshot, no new listener except udp/51820, no task or approval on either hub other than the ones above |
| 9. Record | PROGRAM.md production truth and lane entry; vault ledger 2026-09-0x; design-13 section 3 gap 1 marked closed with the pointer to `server.go:6699` | none | documents match `/api/version` and `/api/nodes` |

Revert at any step after 2: an approved task `wg-quick down wg0 2>/dev/null; rm -f /etc/wireguard/wg0.conf /etc/wireguard/wg0.rollback.conf; systemctl disable wg-quick@wg0 2>/dev/null`, then remove the four `LATTICE_WG_*` lines and restart the agent the same detached way; `/api/nodes` shows `wireguard_ip` empty again. Keys stay on the node (0600, root) unless the operator asks for their removal.

One asymmetry makes that revert only half-clean, and it is worth knowing before
it surprises someone. `handleAgentHello` assigns `n.WireGuardIP = req.WireGuardIP`
unconditionally (`server.go:7698`) while the public key, endpoint and port are
written only when non-empty (`:7699-7707`). So dropping the env lines does clear
the mesh address on the next hello, which is what makes the node fall out of
every future plan (`BuildMesh` skips a node missing either field), but the stale
public key and endpoint stay in the store with nothing showing they are dead.
The same asymmetry means an agent reinstall that forgets `LATTICE_WG_IP` silently
removes a hub from the mesh at its next restart. Clearing the key belongs in the
same server slice as section 6, as part of giving identity a home other than an
env file.

## 9. Out of scope and known unknowns

Not in this pilot: any spoke, hub-and-spoke through the plan endpoint,
NetGuard accepts for udp/51820 (no node is managed, so no guard blocks it; once
a hub gets a managed guard its group must list `udp 51820` on the public zone,
and the builtin `wireguard` zone's `ip saddr @wg_peers4` accepts still render
without `iifname`, the lint blind spot the NetGuard lane owns), route
advertisement, external peers, and any change to sing-box.

Unknown from the API and settled only by step 1: `wireguard-tools` presence,
`setsid` and `systemd-run` presence (both are util-linux and systemd on Debian,
expected present), the `inet filter` input policy on legend-sg, and whether the
home router in front of VIRCS passes inbound UDP 51820. If the last one fails,
the handshake still forms because legend-sg can reach VIRCS's public address
only if that port is open; with it closed, VIRCS dials out and the tunnel forms
from A to B, which the pilot reports as "B-initiated only" rather than treating
as success.
