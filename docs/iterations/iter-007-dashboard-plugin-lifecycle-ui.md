# Iteration 007 - Dashboard Plugin Lifecycle UI

- **Date:** 2026-06-12
- **Phase:** B2 dashboard follow-through
- **Repos:** `lattice-dashboard`, `lattice`
- **Status:** Verified

## Goal

Surface the plugin lifecycle registry from iteration 006 in the dashboard so an
operator can inspect verified plugin state and perform safe status transitions
without using curl.

## Scope

- Add a hidden-by-default Plugins panel for users with `plugin:admin`.
- Fetch `GET /api/plugins/lifecycle` separately from the main console refresh so
  non-admin 403 responses hide only the plugin panel.
- Render status, availability, type, version, capabilities, short artifact
  digest, and updated time.
- Allow only transitions returned by the local helper's mirror of the server
  state machine:

```txt
verified -> installed -> active -> disabled -> active
                      \-> disabled
```

- Confirm every status change before POSTing.
- POST `{id, status}` to `/api/plugins/lifecycle`; no plugin execution is
  triggered by this UI.

## Security Notes

- UI action rules intentionally mirror the server, but the server remains the
  source of truth. A forged dashboard request still must pass `plugin:admin`,
  CSRF for cookie sessions, bundle availability checks, and store transition
  validation.
- The dashboard renders only the public API view. It never sees or displays
  `bundle_path`.
- Missing/unavailable bundles show as `available:false`; install/activate
  buttons are not rendered for them.
- Capability display defensively accepts only string capabilities and
  de-duplicates them before rendering.
- Every interpolated field goes through the existing `escapeHtml` path.
- The confirmation copy explicitly says lifecycle changes do not execute plugin
  code in the current build, reducing operator overconfidence.

## Verification

Commands:

```sh
npm run check
npm test
```

Both passed. Dashboard tests now cover 30 cases, including plugin lifecycle
status labels, transition action rules, availability handling, capability
normalization, digest shortening, payload trimming, and transition confirmation.

Smoke test:

- Built `lattice-server` with the local `go.work` context.
- Served `lattice-dashboard` through the server.
- Confirmed `/` contains `plugins-panel` / `plugins-list`.
- Confirmed `/assets/plugin-lifecycle.js` is served.
- Logged in as admin and confirmed `/api/plugins/lifecycle` returns `[]` on an
  empty plugin registry.

Browser note: the in-app Browser runtime returned unavailable for this session,
so there is no screenshot-level verification artifact. The UI change was still
checked through syntax, unit tests, and local server smoke.

## Residuals

- A richer plugin dashboard can add filter/search, audit drill-through, and
  runtime health once plugin execution exists.
- This panel is still plain vanilla JS; the later dashboard reimagining phase
  should revisit layout density and interaction polish across all admin panels.
