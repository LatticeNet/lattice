# Design 17 - Managed line overlay on adopted nodes (fleet rollout + account binding)

> Status: S1+S2 implemented 2026-08-12 (lattice-server `managedline.go`), from
> the operator directive "每个节点新增一个 lattice 维护的 inbound,并支持绑定账号"
> (option B: build the managed-line capability, with extreme performance and
> efficiency). S2 channel decided with evidence below.
> Builds on: design-12 (lines/users read model, plan→approve→apply),
> design-15 (D3 dual-track user writes, D6 deferral), the 2026-08-11 fleet
> inventory (ops-archive, operator-private).

## 1. Intent

Give every fleet node one additional inbound whose definition Lattice owns —
rendered by the control plane, applied atomically, reconciled after apply —
and bind the operator's account to it, so a single credential works on every
node. The 140 existing adopted lines must keep working byte-for-byte; nothing
about them is re-rendered, converted, or restarted for its own sake.

This is the operator's goal restated as architecture: "managed" describes who
owns the line's definition, not how the bytes reach the box.

## 2. Decision registry

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | The managed line on an adopted node is an **overlay**, not a conversion. The line's definition is server-rendered and server-owned; application uses the adopted track's proven mechanics (atomic fragment write + `sing-box check` + rollback + restart). Nodes are NOT converted to whole-config managed. | design-15 D3's constraint stands: the fleet runs 233boy file-per-line layouts, and whole-config render of a mixed fleet requires the multi-protocol renderer that D6 defers. An overlay delivers "lattice-maintained inbound on every node" with zero risk to existing lines. Full whole-config management stays D6-deferred and unaffected. |
| D2 | Exactly one managed inbound per node, shape locked to **VLESS+REALITY+TCP**. | The only shape the managed renderer and the trust model prove today (design-15 §9, proxycore/singbox.go contract). REALITY-first is also the fleet's own security posture (2026-07-08 netsec design). Multi-protocol managed shapes are a later slice, one protocol at a time, each with its own review. |
| D3 | Port is **planned, not auto-allocated**: a fleet-consistent candidate (24443) checked per node against the inventory's live port map; conflicts take the next free port. The chosen port is pinned in the approval's typed columns. | Silent allocation is how fleets get colliding ports discovered at 2am. The inventory makes the choice evidence-based; the approval columns make it reviewable before anything mutates. |
| D4 | Account binding reuses the operator's existing `ProxyUser` (cdcd) and its existing VLESS credential; the per-line user name follows design-15 §5 (`u_<sha256(user_id|line_uuid)[:16]>`). One account at first; the model admits more without a schema change. | A second credential for the same person is operational noise. Rotation stays available through the existing §5 rotate path. |
| D5 | One fleet rollout = **one approval event** covering N per-node plans, using the event-grouping shipped 2026-08-10. Per-node isolation: one node's failure rolls back that node and never blocks the batch. | The operator reviews one card, not 24. Fleet upgrades already proved the batch shape. |
| D6 | REALITY camouflage (dest/SNI) follows each node's existing reality lines — read from the inventory, not invented. | The fleet's camouflage domains are deliberate (operator-maintained); a managed line that suddenly uses a novel domain is a fingerprint anomaly. |
| D7 | Post-apply, the line is rediscovered and carries `line_uuid`; the overlay is flagged `managed` in the read model, and drift between the rendered definition and the on-box fragment is surfaced, never silently overwritten. | design-12/15 reconciliation rules apply unchanged; the overlay is not a second-class line. |

## 3. Why not the naive D6 reading

"Build managed lines" reads as "render the whole node config." On this fleet
that means reproducing 140 operator-tuned lines across six protocols through a
renderer that today speaks exactly one — a long project whose only reward is
risk. The overlay gets the operator's actual outcome (a lattice-owned,
account-bound inbound on every node) with the apply path that already exists,
and it does not foreclose anything: a node can be converted to whole-config
managed later, protocol by protocol, and the overlay lines migrate with it.

## 4. Performance contract ("极致性能")

- All rendering is pure Go (proxycore). No JavaScript engine is anywhere near
  this path; a fleet render is milliseconds.
- Per-node apply tasks run under the approvals batch runner's bounded
  concurrency (4); a 24-node rollout is ~6 waves, each wave one
  check+reload per node.
- The plan is compiled once per node and pinned by SHA in the approval;
  apply replays the pinned bytes, never a re-render.
- Client-facing cost of the new lines flows through the snapshot + render
  cache (2026-08-11 serve-path work): subscription polls for the fleet
  subscription do not re-run the pipeline per poll.

## 5. Slices

| # | Slice | Notes |
|---|-------|-------|
| S1 | Server rollout compiler: `POST /api/network/lines/managed-rollout` builds per-node plans (shape, port from the inventory map, REALITY material, binding) and files them as one approval batch. Validation refuses nodes whose port map is unknown. | The endpoint is a compiler, not a mutator: nothing applies without the operator's approval click. |
| S2 | Apply mechanics for an inbound fragment on an adopted node. **Decided 2026-08-12: server-rendered sh script over the existing task pipeline** — the channel every adopted-track mutation already uses (`server_singbox_manage.go`, `lineusers.go`). New agent verb rejected (a fleet-wide agent rollout would gate the first line); the §9.3 plugin-operation channel rejected (it executes PLUGIN-compiled plans; the rollout is server-compiled from the projection). Contract implemented in-script: write fragment → `sing-box check` → restart → verify active → rollback on any failure, audit each step. | The one genuinely new machinery piece; the atomicity contract is fixed, the channel is the choice. |
| S3 | Read-model + UI: the overlay line appears in Networking → Lines with a `managed` badge and the bound account; the rollout action lives on the Lines view with per-node apply status (pending/applied/failed/rolled-back). Designed per the operator's design-intelligence skill (Product path): one dominant action, honest per-node states, destructive rollback visible. | The UI is where "lattice 维护" becomes legible. |
| S4 | Account binding via the existing users-admin `plan_add` per managed line; cdcd only in v1. | Existing machinery, no new path. |

## 6. Explicitly not here (still D6-deferred)

Multi-protocol managed rendering (trojan / hysteria2 / tuic / anytls as managed
shapes), quota/expiry auto-disable enforcement, generic plugin event bus /
cron, the sing-box fork with relaxed unknown-field parsing. Each keeps its own
review when its turn comes.
