# Iteration 045 — Proxy Dashboard + Subscription Token Workflow

- **Status:** Implemented / verified (2026-06-14)
- **Design:** [`designs/design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
- **Builds on:** [`iter-044-proxy-subscriptions-mvp.md`](./iter-044-proxy-subscriptions-mvp.md)
- **Repos:** `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Make the proxy-core MVP usable from the dashboard without weakening the
secret-free control-plane boundary:

- Operators can view and edit proxy inbounds, users, and node profiles.
- Operators can rotate a user's subscription token and copy the resulting
  subscription URL from an explicit, audited action.
- Existing list/read APIs remain secret-free: UUID/password/sub-token are never
  rendered in ordinary dashboard lists.

## Scope

In scope:

- `POST /api/proxy/users/rotate-sub-token` requiring `proxy:admin` and an
  unrestricted server allowlist.
- One-time response containing the raw subscription URL after rotation only.
- Dashboard panels for proxy inbounds, users, and node profiles.
- Dashboard copy flow for the rotated subscription URL.
- Unit tests for dashboard payload helpers and server tests for rotate/audit
  behavior.
- Documentation updates for the new operator workflow.

Out of scope:

- Usage reporting and quota counters from sing-box stats.
- Clash YAML / sing-box client JSON subscription formats.
- xray renderer.
- Full visual redesign of the dashboard.

## Security Decisions

- The dashboard never receives raw subscription tokens from list or ordinary
  save operations.
- Rotation is explicit, `POST` + CSRF protected, scoped by `proxy:admin`, and
  audited with old/new token SHA-256 hashes only.
- The response returns the full URL once so the operator can deliver it to a
  user. The token is not stored in browser state after refresh.
- A proxy user may keep an existing manually supplied token on edit, but the UI
  does not expose that field. Rotation is the normal dashboard path.

## Test Plan

Run from `lattice-server`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -count=1 ./internal/server -run 'TestProxy'
```

Run from `lattice-dashboard`:

```sh
node --test assets/*.test.mjs
node --check assets/app.js
node --check assets/proxy.js
```

## Exit Bar

- A rotated subscription token invalidates the old URL and makes the new URL
  fetchable.
- Audit records token rotation without raw token material.
- Dashboard can create/edit proxy inbounds/users/profiles and rotate/copy a
  subscription URL.
- Ordinary dashboard refresh does not retain or display raw subscription tokens.
- Long-lived docs reflect that dashboard proxy management and token rotation
  are now partially landed, while usage/formats/xray remain pending.

## Execution Log

- Added `POST /api/proxy/users/rotate-sub-token` in `lattice-server`.
  The handler requires `proxy:admin`, decodes an explicit `{id}` body, rotates
  the stored subscription token, returns the full subscription URL only in this
  one response, and audits old/new token SHA-256 hashes without raw token
  material.
- Added a regression test proving that rotation invalidates the old `/sub`
  token, makes the new URL fetchable, preserves secret-free `/api/proxy/users`
  lists, and records hash-only audit metadata.
- Added dashboard proxy helpers in `assets/proxy.js` plus unit tests for
  inbound/user/profile payload normalization and rotation confirmation copy.
- Added a dashboard `Proxy Core` panel with sections for inbounds, users, and
  node profiles. The panel supports create/edit/delete, profile plan creation,
  explicit user subscription URL rotation, and copy-to-clipboard.
- Kept credential boundaries visible in the UI: REALITY private key is
  write-only, user UUID/password/sub-token are never rendered, and the rotated
  subscription URL is only shown after the explicit rotate action.

## Review Outcome

- **Security:** No raw subscription token is added to list/read APIs or audit
  metadata. The one intentional raw-token path is the rotate response, which is
  state-changing, CSRF-protected, `proxy:admin` scoped, and operator initiated.
- **Authz:** The route uses the same global proxy scope requirement as other
  central proxy-user mutations. Public subscription fetch remains sessionless
  and token-authenticated.
- **XSS/CSP:** Dashboard rendering uses existing `escapeHtml` interpolation and
  JS-attached event listeners; no inline handlers or third-party dependencies
  were introduced.
- **Usability correction during review:** inbound/user IDs are visible optional
  form fields rather than hidden fields, because node profiles need stable,
  operator-addressable inbound IDs.
- **Safety correction during review:** destructive dashboard delete actions for
  proxy inbounds, users, and profiles now require explicit browser
  confirmation.
- **Host-header hardening during review:** when `LATTICE_PUBLIC_URL` is absent,
  token rotation returns a relative `/sub/{token}` path instead of deriving an
  absolute URL from request `Host`.
- **Verification:** targeted server proxy tests and the full dashboard JS test
  suite pass. Local HTTP/browser smoke could not be run in the sandbox because
  binding `127.0.0.1:8099` was denied; the server build still completed.

## Residual Risks / Next

- Dashboard plan creation queues the existing approval object, but the operator
  still completes apply through the existing Approvals panel. A later UI pass
  should add a focused proxy plan diff/approve flow.
- Subscription output remains MVP plain/base64 VLESS+REALITY. Usage reporting,
  Clash/sing-box client formats, xray renderer, and import-link UX remain
  future slices.
- Rotation returns a full URL derived from `LATTICE_PUBLIC_URL` when configured;
  deployments should set that value behind reverse proxies. Without it, the API
  returns a relative `/sub/{token}` path rather than reflecting request `Host`.
- No browser visual QA was possible in this sandbox due local bind restrictions.
