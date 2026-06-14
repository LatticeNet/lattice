# Lattice Development Report - 2026-06-13

This report closes the current multi-repo development pass and records the
state future sessions should treat as the baseline. The canonical product plan
remains `PRODUCT-VISION.md`; this file is the point-in-time engineering status
for the six-repo LatticeNet workspace.

## Repository Boundaries

| Repo | Role | Current boundary |
|---|---|---|
| `lattice` | Workspace, docs, build glue | No runtime ownership; holds the product plan, roadmap, ADRs, tutorials, and iteration logs. |
| `lattice-sdk` | Shared domain/wire contract | Owns models and proto-facing contracts used by server and agent. |
| `lattice-server` | Policy decision point | Owns auth, RBAC, node registry, task queue, audit, plugin trust, storage, and all dangerous-operation approvals. |
| `lattice-node-agent` | Least-trust executor | Dials out only; reports metrics, runs bounded tasks only when explicitly allowed, and performs node-local probes/apply steps. |
| `lattice-dashboard` | Static console | Strict-CSP, dependency-light browser UI; renders server decisions and does not make security decisions. |
| `lattice-plugin-template` | Plugin author kit | Documents manifest, signing, capabilities, and trust policy for future official/community plugins. |

These boundaries should stay separate. Collapsing server, agent, and dashboard
would make deployment, release, and threat-boundary review harder.

## Delivered Baseline

The current pushed baseline includes:

- Password login, CSRF protection, TOTP 2FA, OIDC/SSO backend, SSO dashboard UI,
  PAT scopes, server allowlists, and node-token rotation.
- Tamper-evident audit WAL plus AES-256-GCM envelope encryption for reversible
  secrets at the store boundary.
- Node enrollment, metrics, bounded task execution, task result upload,
  monitor probes, DDNS, notifications, WireGuard/nft/tunnel planning, approvals,
  audit filtering, and low-trust HostFacts inventory telemetry from agent
  collection through dashboard display.
- Server-only MachineProfile inventory/cost/renewal metadata with encrypted
  console/detail links, renewal reminder evaluation, and a Machines dashboard
  panel. MachineProfile data never goes to agents.
- Shared per-node `NFTInputs` persistence for the Network Guard: canonical
  interface/WireGuard CIDR/public TCP+UDP/WireGuard TCP+UDP inputs, rendered
  into the single `inet lattice_guard` plan and reused by future DNS/ACL work.
- Design 05 NetPolicy foundation: shared SDK contract (`NetEndpoint`,
  `NetRule`, `NetPolicy`, `NodeGeo`), JSON + bbolt state, strict server-side
  validation, `netpolicy:read`/`netpolicy:admin` APIs, reachability graph, and a
  dashboard policy panel.
- Design 05 egress apply path (iter-021): stored `NetPolicy` can now be compiled
  by `/api/netpolicy/plan` into a pending `nftpolicy` approval, queued through
  the existing approval path, applied by the node agent with `nft -c`, a 60s
  dead-man rollback watchdog, and unauthenticated `/api/health` selfcheck, then
  recorded back to `NetPolicy.LastAppliedAt` / `LastError`. This MVP is
  **egress-only** and requires an IPv4-literal server `PublicURL`.
- Design 05 map slice (iter-022): operator-owned `NodeGeo` can be updated,
  listed, and cleared through `GET/POST /api/nodes/geo` with `node:read` /
  `node:admin` plus per-node allowlists; `/api/nodes` exposes `geo`; dashboard
  `Fleet Map` renders dependency-free inline-SVG pins and provides an edit/clear
  form. Geo is display-only and never feeds authorization or nft compilation.
- Design 05 graph visualization slice (iter-023): dashboard Network Policy now
  renders the server-derived reachability graph as dependency-free inline SVG
  with allow/deny edges, online/offline nodes, tooltips, external rule summary,
  and the existing textual fallback. The client still performs no policy
  evaluation.
- Design 05 ingress guard composition (iter-024, 2026-06-14): Network Guard
  `nft` approvals now commit the full `lattice_guard` ruleset with `nft -c`,
  rollback snapshot, 60s watchdog, and optional control-plane selfcheck. Enabled
  ingress `NetPolicy` rules are compiled into typed input rules and folded into
  the same `lattice_guard` chain before broad public/WireGuard allows; callers
  need both `network:plan` and `netpolicy:read` when ingress policy exists.
- Signed plugin manifest verification, fail-closed trust policy, startup loader,
  `/api/plugins/verify`, lifecycle registry/API/UI, host-API broker, server host
  services adapter, runtime manager, and a no-op runner contract.
- bbolt storage foundation: bucketized import/export, JSON -> bbolt migration,
  bbolt -> JSON rollback export, and record-level APIs for nodes, KV, audit,
  static objects, Worker scripts, plugin lifecycle records, approvals, tasks,
  task results, monitors, monitor results, tunnels, and secret-bearing
  identity/auth/DDNS/notify/OIDC records.

The default runtime store is still the encrypted JSON state file. That is
intentional until record-level coverage, backup/restore drills, and runtime
cutover tests are complete.

## Security Gates That Must Stay Closed

- Agents remain outbound-only; do not require inbound leaf-node ports.
- Dangerous actions stay `plan -> diff -> approve -> apply`.
- Plugin artifacts still do not execute. Runtime code must receive only a
  capability-scoped broker, never raw server handles.
- Host-risk plugins require trusted signatures by default.
- Reversible secrets must stay encrypted at rest; any new secret-bearing field
  needs field-specific encryption and wrong-key tests before use.
- `lattice-server` must not switch to bbolt by default without an explicit
  runtime flag, migration drill, rollback test, and operator documentation.
- Management APIs should be deployed on WireGuard/private addresses or behind a
  hardened reverse proxy; DDNS is discovery, not authorization.

## Storage Status

Delivered bbolt pieces:

- Full state import/export between encrypted JSON and bbolt.
- Reversible migration commands:
  - `lattice-server migrate json-to-bolt`
  - `lattice-server migrate bolt-to-json`
- Record-level coverage for current state buckets:
  - nodes
  - KV
  - audit events
  - static objects
  - Worker scripts
  - plugin lifecycle records
  - approvals
  - tasks
  - task results
  - monitors
  - monitor results
  - tunnels
  - users
  - tokens
  - sessions
  - TOTP challenges
  - DDNS profiles
  - notification channels
  - machine profiles
  - nft inputs
  - net policies
  - OIDC providers
  - OIDC identities
  - OIDC auth states

Remaining before runtime cutover:

- Retention/index strategy for high-volume audit and monitor history.
- Audit WAL head anchoring and rollback drills against realistic state files.
- `-data-engine=bolt` or equivalent opt-in runtime switch, with JSON fallback.

## Next Development Order

Development resumed with iter-017 (`HostFacts` inventory MVP), iter-018
(`MachineProfile` cost/renewal MVP), iter-019 (shared nft input persistence),
iter-020 (`NetPolicy` state + graph foundation), iter-021 (egress-only
NetPolicy nft apply with rollback/selfcheck), iter-022 (`NodeGeo` + Fleet Map
MVP), iter-023 (policy graph SVG), and iter-024 (Network Guard rollback apply +
ingress guard composition). The next work should now be:

1. **Design 05 - domain-set composition + visualization polish.**
   Continue from iter-024: add a safe DNS/DDNS-backed nft named-set updater for
   domain public URLs, add IPv6 policy, then add bulk geo import and map
   latency/renewal overlays. Also add compiler-vs-graph parity tests now that
   ingress has a committed render path.
2. **Design 02 - Self-host DNS.** Add `DNSDeployment`, CoreDNS rendering,
   Cloudflare publish via existing DDNS provider, and composition of DNS ports
   into the stored `NFTInputs`.
3. **C1.5 - Runtime cutover flag.** Add an explicit `-data-engine=bolt` path,
   preserve JSON default, and document migration/rollback as an operator drill.
4. **A3 - Identity policy polish.** Enforce 2FA policy, add recovery workflow
   hardening, and prepare WebAuthn/passkey dependency review.
5. **D1 - Dashboard parity.** Add first-class UI for PATs, DDNS, monitors,
   notification channels, WireGuard plans, tunnels, audit WAL verification, and
   runtime drill-through.
6. **B2 - Real plugin execution.** Only after storage and identity gates: add a
   constrained system runner with deadlines, cancellation, process isolation,
   per-plugin rate limits, output/log caps, and adversarial tests.

## Verification Discipline

For code slices, the minimum closeout remains:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./... -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go vet ./...
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test -race ./... -count=1
cd ../lattice-dashboard && npm test
```

For docs-only closeout, require `git diff --check`, status review for all six
repos, and an explicit statement that runtime code was not changed.

## Current Residual Risk

The foundation is strong for a trusted, self-hosted fleet behind private
networking, but it is not yet a public multi-tenant control plane. The blockers
are storage cutover, plugin runner isolation, enforced MFA policy, dashboard
coverage for dangerous workflows, and stronger fleet-wide rate/backpressure
controls.
