# Iteration 055 - Proxy config drift detection (live enforcement signal)

- **Date:** 2026-06-14
- **Repos:** `lattice-server`, `lattice-dashboard`, `lattice`
- **Builds on:** iter-043 proxycore apply, iter-044 subscriptions, iter-050
  quota/expiry notifications, iter-054 xray stats transport
- **Status:** Implemented, reviewed, verified

## Goal

Close the proxy enforcement feedback loop. Before this slice, when a user
expired, exceeded quota, or was disabled, the server stopped serving them new
subscription links and fired a notification — **but their UUID remained in the
already-applied node config**, so existing clients kept working until an operator
manually re-planned and applied. This iteration makes that drift **visible and
one-click-enforceable**, without weakening the plan→approve→apply model.

## Design — detection, not auto-apply

The renderer's `eligibleVLESSUsers` already drops disabled/expired/over-quota
users, so a fresh render of an applied profile produces a **different SHA-256**
than `AppliedSHA256` exactly when the live config is serving someone who should
no longer have access. That divergence is the drift signal.

- A scheduler pass (`evaluateProxyConfigDrift`, hooked into the existing
  `evaluateReminders` tick) re-renders every applied profile, compares the SHA,
  counts how many assigned users are now ineligible, and records the result in
  an **in-memory** `proxyDrift` map (no schema/store/crypto change; re-derived on
  restart within one tick).
- A render *failure* (most commonly an inbound left with zero eligible users) is
  itself treated as drift — the applied config still serves the now-ineligible
  users.
- On a profile's **transition** into stale, an audit event `proxy.config.drift`
  is recorded (applied/pending SHA + ineligible count). No notification spam —
  per-user quota/expiry alerts already fire in iter-050.
- The profile view gains `config_stale`, `pending_config_sha256`,
  `ineligible_users`, `drift_reason`, `drift_checked_at`.
- After a successful apply, `refreshProxyDriftFor` recomputes that one profile so
  the dashboard banner clears immediately instead of at the next tick.

**Deliberately not auto-applied.** Node mutation stays behind
plan→approve→apply (the crown-jewel model). Enforcement is one click: the
existing `Plan Apply` button (relabelled **Review & Apply** when stale) creates
the redacted, SHA-bound approval the operator approves. Opt-in *automatic*
apply for the access-reduction-only case is a deliberate, separate future slice
with its own decision doc, because auto-approving a server-generated plan is a
real departure from the approval model and deserves explicit opt-in + a
reduction-only structural diff.

## Dashboard

- Proxy profile cards show a `⚠ config out of date — N users no longer eligible;
  review & apply to enforce` banner when `config_stale` is set.
- The plan button is promoted (non-secondary, relabelled) so the enforcing
  action is obvious. Zero new dependencies; strict CSP preserved.

## Verification

```sh
GOWORK=…/lattice/go.work go vet ./...   # lattice-server
GOWORK=…/lattice/go.work go test ./...  # lattice-server — all green
npm test && npm run check               # lattice-dashboard
gofmt -l <changed files>                # empty
```

Focused coverage (`server_proxy_enforce_test.go`):

- not stale immediately after an apply; becomes stale with `ineligible_users==1`
  and a distinct `pending_config_sha256` when a user is disabled; the profile
  view surfaces it; drift clears after the enforcing apply;
- render-failure drift when an inbound's only user becomes ineligible.

## Security review notes

- Drift state is **not** authoritative security state — it never grants access.
  The authoritative control remains the rendered config + plan-hash-bound apply.
- The drift map holds only SHAs and counts, no secrets. Audited on transition.
- No new endpoint, scope, or store surface; the enforcing action reuses the
  existing scoped, approval-gated plan endpoint.

## Residuals & Next

1. **Opt-in auto-enforce** (default off) for reduction-only drift, with a
   structural diff proving the only change is user removal + its own decision doc.
2. **Design 03 — log ingestion** remains entirely unbuilt; it is the largest
   remaining feature gap (agent path tailer → bounded per-node store → query API
   → dashboard).
3. Design 04 v2 polish (audited reveal endpoint, per-currency rollups) and
   Design 05 bulk geo import remain open.
