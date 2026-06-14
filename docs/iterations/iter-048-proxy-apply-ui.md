# Iteration 048 - Focused Proxy Apply UI

- **Date:** 2026-06-14
- **Repos:** `lattice-dashboard`, `lattice`
- **Builds on:** iter-042 reviewed proxy plans, iter-043 secret-safe proxy apply, iter-045 proxy dashboard, iter-047 subscription formats
- **Status:** Implemented, reviewed, verified, committed as a dashboard-only slice

## Goal

Move the proxy-core apply review from the generic Approvals panel into the
Proxy Core operator flow. The operator should be able to create a node profile,
click `Plan Apply`, review the pending `proxycore/apply-config` plan in the
same panel, and queue the apply without context-switching.

This is intentionally **not** a new apply path. It is a focused UI over the
existing reviewed approval API.

## Scope

- Add a `Proxy Core -> Apply Review` section in the dashboard.
- Display only pending approvals where:
  - `plugin == "proxycore"`
  - `action == "apply-config"`
  - `status == "pending"`
  - both `id` and `node_id` are present
- Sort pending proxy apply reviews newest-first by `created_at`.
- Queue apply through the existing `POST /api/network/approvals/approve`
  endpoint using `approvalPayload`, which computes `sha256(plan)` in the
  browser and sends `queue_apply:true`.
- Re-filter the approval set at click time so DOM tampering cannot turn the
  focused proxy button into a shortcut for approving unrelated pending
  `nft`, `selfdns`, or future plugin approvals.
- Add the inbound `fingerprint` form field so the iter-047 subscription-format
  support is visible in the dashboard. The server still validates the allowed
  fingerprint token and rejects unsafe values.

## Out of Scope

- No new server endpoint.
- No change to proxy plan/apply semantics.
- No direct sing-box or xray stats collector.
- No usage notifications.
- No import-helper UI for `format=plain|base64|sing-box|clash-meta`.
- Xray rendering was out of scope for this UI slice. **Resolved in iter-053**
  for the shared VLESS+REALITY+TCP shape.
- No large dashboard redesign.

## Security Review

- **Authorization remains server-side.** The dashboard only posts to the
  existing `network:apply` route. The server still requires node scope,
  pending status, `plan_sha256` for high-risk plugins, and for `proxycore`
  re-renders the current desired config before queuing the task.
- **No approval bypass.** The new button calls `approvalPayload` with an
  approval selected from `proxyCoreApprovalQueue(state.approvals)`, not from
  the full approval list. A tampered `data-proxy-approval` cannot approve a
  non-proxy approval from this focused flow.
- **Plan integrity is unchanged.** The browser hashes the exact plan text it
  displays. The server compares that hash to the stored plan and rejects stale
  or swapped plans.
- **XSS reviewed.** All rendered approval fields, including the multi-line plan
  body, go through the existing `escapeHtml` helper. Event handlers are attached
  in JavaScript; no inline handlers were added, preserving the strict-CSP style.
- **Secret exposure remains bounded.** The panel renders the already-redacted
  `ApprovalView.Plan`. Real proxy credentials are still only in the encrypted
  task script produced by the server after approval.
- **CSRF unchanged.** The existing `api()` helper attaches `X-Lattice-CSRF` for
  state-changing requests.

## Verification

From `lattice-dashboard`:

```sh
node --check assets/app.js
npm test
npm run build
git diff --check
```

Result: dashboard syntax check passed, dashboard test suite passed with 75
tests, `npm run build` passed, and whitespace check passed.

Server compatibility smoke:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go build -o /private/tmp/lattice-server-ui048 ./cmd/lattice-server
```

Result: server build exited 0. The Go tool printed a non-fatal module
stat-cache warning when it tried to access `/Users/cdcd/go/pkg/mod/cache`.

Browser/local HTTP smoke could not be completed in the current sandbox:
starting the local server on `127.0.0.1:8099` failed with
`listen tcp 127.0.0.1:8099: bind: operation not permitted`. This is an
environment limitation, not an application assertion.

## Files Changed

`lattice-dashboard`:

- `index.html` - adds the inbound `fingerprint` input and `Apply Review`
  section.
- `assets/app.js` - renders proxy apply reviews and queues the selected
  approval through the existing approval API.
- `assets/proxy.js` - adds `fingerprint` payload support and the
  `proxyCoreApprovalQueue` pure helper.
- `assets/proxy.test.mjs` - covers `fingerprint` normalization and proxy apply
  review filtering/sorting.
- `assets/styles.css` - gives the apply review section full width and bounds
  long plan output.

`lattice`:

- This iteration note plus roadmap/design/architecture references updated so
  the long-lived docs no longer list focused proxy apply UI as pending.

## Residuals & Next

1. The node-agent loopback HTTP/V2Ray-stats collector foundation landed in
   iter-049 behind the existing `ProxyUsageSnapshot` contract. True sing-box/xray
   API transport remains future work.
2. Quota/expiry/usage-threshold notifications landed in iter-050 through
   `internal/notify`.
3. Import-helper UX for public subscription formats (`plain`, `base64`,
   `sing-box`, `clash-meta`) landed in iter-051. Only later consider safe
   User-Agent negotiation.
4. Add the xray renderer and `xray test -c` apply path behind the same
   server-owned model.
5. Run real browser smoke in a normal local environment where binding
   localhost is permitted.
