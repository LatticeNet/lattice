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
  and audit filtering.
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
  - OIDC providers
  - OIDC identities
  - OIDC auth states

Remaining before runtime cutover:

- Retention/index strategy for high-volume audit and monitor history.
- Audit WAL head anchoring and rollback drills against realistic state files.
- `-data-engine=bolt` or equivalent opt-in runtime switch, with JSON fallback.

## Next Development Order

Feature expansion is intentionally paused after this closeout. When development
resumes, the next work should be:

1. **C1.5 - Runtime cutover flag.** Add an explicit `-data-engine=bolt` path,
   preserve JSON default, and document migration/rollback as an operator drill.
2. **A3 - Identity policy polish.** Enforce 2FA policy, add recovery workflow
   hardening, and prepare WebAuthn/passkey dependency review.
3. **D1 - Dashboard parity.** Add first-class UI for PATs, DDNS, monitors,
   notification channels, WireGuard plans, tunnels, audit WAL verification, and
   runtime drill-through.
4. **B2 - Real plugin execution.** Only after storage and identity gates: add a
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
