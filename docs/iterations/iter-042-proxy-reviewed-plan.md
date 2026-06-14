# Iteration 042 — Proxy-Core Reviewed Plan Endpoint

- **Status:** Implemented and verified locally (2026-06-14)
- **Design:** [`designs/design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
- **Repos:** `lattice-server`, `lattice`

## Goal

Turn the iter-040 sing-box renderer and iter-041 CRUD state into the first
reviewable deployment surface:

- `POST /api/proxy/nodes/{node_id}/plan`
- `Approval{Plugin:"proxycore"}` with a human-readable, **secret-free** plan.
- Exact rendered config SHA-256 bound into the stored approval action.
- Approval-time drift detection before any future apply can be queued.

This iteration was intentionally **review-only** when it landed.
`queue_apply:true` for `proxycore` failed closed until the apply script and
secret-at-rest story for queued tasks were implemented. That follow-up landed in
[`iter-043-proxy-apply-secret-safe.md`](./iter-043-proxy-apply-secret-safe.md).

## Route

| Route | Method | Scope | Notes |
|---|---:|---|---|
| `/api/proxy/nodes/{node_id}/plan` | POST | `network:plan` on node + unrestricted `proxy:read` | Body must be `{}`. Renders current desired sing-box config, stores a pending `proxycore` approval with a redacted review plan, and returns `ApprovalView`. |

## Security decisions

- **No secret-bearing approval plan.** The stored/displayed `Approval.Plan`
  contains a redacted sing-box config: `private_key`, `uuid`, and future
  `password` fields become `"<redacted>"`.
- **Real config hash is still bound.** The approval action stores
  `apply-config:<sha256(real rendered config)>`. `ApprovalView.Action` displays
  only `apply-config`.
- **Approve-time TOCTOU check.** `handleApprove` re-renders the current
  proxycore config and rejects the approval if the SHA no longer matches the
  approval action. Editing an inbound/user/profile after planning requires a
  new plan.
- **Apply remained fail-closed in this slice.** At iter-042 time,
  `queue_apply:true` returned conflict and created no task. Iter-043 enabled
  apply only after encrypting persisted task scripts and adding status
  reconciliation.
- **Authz is stricter than ordinary node planning.** The caller needs
  `network:plan` for the node and unrestricted `proxy:read`, because planning
  resolves fleet-global inbounds/users even though the plan text is redacted.

## Verification

Run from `lattice-server`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -count=1 ./internal/server -run 'TestProxy|TestApprovePlanHashBinding|TestApplyScriptForUsesPlanSafeHeredocDelimiters'

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -count=1 ./internal/proxycore ./internal/store

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -race -count=1 ./internal/server -run 'TestProxy'

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go build ./cmd/lattice-server
```

Results:

- proxy CRUD + plan tests: pass
- high-risk approval hash regression: pass
- apply heredoc safety regression: pass
- proxycore/store tests: pass
- proxy server race test: pass
- server build: pass

Known environment note: the Go tool still prints a non-fatal stat-cache warning
when it attempts to write under `/Users/cdcd/go/pkg/mod/cache`; the build exit
code is 0.

## Tests added at the time

- Proxy plan creates a `proxycore` approval with redacted config text.
- Plan text does not contain REALITY private key, user UUID, password, or
  subscription token.
- Stored action binds the real config SHA while the view action stays stable.
- `queue_apply:true` failed closed and created no task in iter-042. This
  assertion was intentionally replaced by iter-043's successful queue/apply
  regression after task-script encryption landed.
- Node-allowlisted PAT cannot plan proxycore without unrestricted proxy read.
- A changed config after planning makes approval fail with conflict.

## Next work

1. ✅ Completed in iter-043: encrypted `Task.Script` at rest for JSON and bbolt.
2. ✅ Completed in iter-043: real `proxycore` apply script with `sing-box check`,
   atomic swap, reload/restart activation, and task-result status reconciliation.
3. ✅ Completed in iter-048: focused dashboard proxy apply review/queue UI.
4. ✅ Completed in iter-044: `/sub/{token}` after opaque token lookup and rate
   limiting were designed.
