# Iteration 051 - Proxy Subscription Import Helpers

- **Date:** 2026-06-14
- **Repos:** `lattice-dashboard`, `lattice`
- **Builds on:** iter-044 public subscription endpoint, iter-047 multi-format
  subscription output, iter-045 audited subscription-token rotation
- **Status:** Implemented, reviewed, verified

## Goal

Make the existing multi-format subscription endpoint usable from the dashboard
without widening token exposure. After an operator explicitly rotates a proxy
user subscription token, the dashboard should present copy-ready import targets
for the supported client formats:

- default/base64 `/sub/{token}`;
- plain `vless://` links via `format=plain`;
- sing-box client JSON via `format=sing-box`;
- Clash.Meta/Mihomo YAML via `format=clash-meta`.

## Scope

- Add pure dashboard helpers in `assets/proxy.js`:
  - `proxySubscriptionFormats`;
  - `proxySubscriptionImportTargets(rawURL)`.
- Derive format URLs client-side from the one-time URL/path returned by
  `/api/proxy/users/rotate-sub-token`.
- Render a compact "Subscription imports" panel after rotation, with one
  read-only URL and one copy button per format.
- Preserve the existing explicit rotate confirmation and audited server-side
  token rotation flow.
- Keep the dashboard zero-dependency and CSP-safe: no inline handlers, no
  external libraries, and all rendered URL/label text escaped.

## Security Decisions

- **No subscription-token reveal API.** The dashboard still cannot retrieve an
  existing raw subscription URL from list/read APIs. Import helpers are shown
  only after the explicit rotate response returns a fresh bearer URL/path.
- **Client-side derivation only.** The helper appends/removes the public
  `format` query parameter; it never asks the server for extra secret material.
- **No auto-open links.** The UI only copies read-only URLs. It does not create
  clickable anchors that could accidentally fetch or leak the bearer token.
- **Malformed URL fail-closed.** If the server ever returns a malformed
  subscription URL, the helper returns no import targets instead of crashing the
  whole dashboard render path.

## Verification

From `lattice-dashboard`:

```sh
npm test
npm run check
git diff --check
```

Result: dashboard test suite passed (76 tests), `assets/app.js` syntax check
passed, and whitespace checks passed.

Focused tests cover:

- relative subscription paths keep non-format query parameters;
- `base64` remains the canonical default URL without a `format` parameter;
- `plain`, `sing-box`, and `clash-meta` URLs set the expected `format`;
- absolute public URLs are preserved;
- malformed URLs fail closed to an empty target list.

## Residuals & Next

1. Add true sing-box/xray API transport after pinning the stats API and writing
   an ADR if `grpc-go` is introduced.
2. Collector health/error state landed in iter-052.
3. Add xray renderer and `xray test -c` apply path.
4. Add an auto-reconcile/apply policy so over-quota/expired users can be
   removed from live node configs without a manual re-apply.
5. Consider UA-aware subscription landing pages later. That would be a separate
   public UX surface and must not replace the current explicit copy-only helper.
