# Iteration 002 — Dashboard SSO UI (Phase A2)

- **Status:** Completed locally (2026-06-12)
- **Vision link:** `PRODUCT-VISION.md` Phase A2; builds on iter-001 (OIDC backend).
- **Repo:** `lattice-dashboard` (zero-dependency vanilla ES modules, strict CSP `script-src 'self'`, `node --test`).

## 1. Goal

Make the iter-001 OIDC backend usable from the console: a **"Sign in with …"** button on the login page, graceful handling of the backend's `?sso_error=`/`?totp_challenge=` redirect params, and an **admin panel** to configure providers — all matching the existing dark design system, CSP-safe, and unit-tested.

## 2. Scope

**Login page**
- On load, `GET /api/auth/oidc` → render a button per enabled provider; clicking navigates to `/api/auth/oidc/start?provider=<id>&redirect=/`.
- Parse the landing URL: `?sso_error=<code>` → show a friendly message; `?totp_challenge=<id>` → jump to the existing TOTP step pre-seeded with that challenge (SSO user completing local 2FA). Strip these params via `history.replaceState`.

**Console (admin, scope `oidc:admin`)**
- A "Single Sign-On" panel: list providers (`GET /api/auth/oidc/providers`, secret never shown — `has_secret` badge), add/edit (issuer, client_id, client_secret [write-only], display_name, allowed_domains, scopes, enabled), delete. Panel hides itself if the API returns 403 (non-admin).

**Out of scope:** group/role-claim → scope mapping UI; provider discovery preview. (later)

## 3. Design / approach

- **Pure module `assets/sso.js`** (CSP-safe, node-testable), no DOM:
  - `ssoErrorMessage(code)` → friendly copy for each backend code (`csrf`,`expired`,`denied`,`verify_failed`,`provider_error`,`ip_mismatch`,`unavailable`,`bad_request`,`session_failed`).
  - `hasAuthRedirectParams(search)` + `readAuthRedirect(search)` → strip all one-time SSO landing params while only accepting server-shaped TOTP challenge tokens.
  - `strippedAuthSearch(search)` → query string without the two SSO params (for `replaceState`).
  - `oidcStartURL(providerId, redirect)` → encoded start URL.
  - `oidcProviderPayload(fields)` → normalized POST body (trim issuer, split comma lists, omit empty/whitespace-only `client_secret` so it is preserved).
  - `confirmOIDCDelete(provider, confirmFn)` → explicit destructive-action confirmation before deleting a provider.
- **app.js** wires DOM → calls the pure helpers; renders provider lists with `escapeHtml`; adds listeners in JS (no inline handlers, CSP-safe); navigation via `window.location.assign`.
- **index.html**: SSO block in the login section; SSO admin panel in the console side column.
- **styles.css**: `.sso-list`, `.sso-divider` ("or"), `.sso-button`, `.oidc-provider` — reuse existing tokens/classes.

## 4. Risks & mitigations
- **XSS** rendering provider/display data → all interpolation through `escapeHtml` (existing helper).
- **Secret leakage** → client_secret is an input only; never rendered back; list shows `has_secret` boolean.
- **CSP** → no inline scripts/styles/handlers; listeners attached in JS; navigation via JS.
- **403 for non-admin** → load the admin panel separately from the main `Promise.all`, swallow 403 and hide the panel (don't break `refresh()`).
- **Open redirect** → the `redirect` param is server-side `SanitizeRedirect`d (iter-001); UI only ever sends `/`.
- **2FA phishing primitive** → forged/short/malformed `totp_challenge` URL values are stripped from the URL but do not activate the TOTP step.
- **Accidental destructive action** → provider deletion requires a browser confirmation prompt.

## 5. Test plan
`assets/sso.test.mjs` (node --test): `ssoErrorMessage` known + unknown codes; `readAuthRedirect` parses valid challenge tokens and rejects forged/malformed ones; `hasAuthRedirectParams` detects raw one-time landing params for URL cleanup; `strippedAuthSearch` removes only the two params and keeps others; `oidcStartURL` encodes; `oidcProviderPayload` trims/splits/omits-empty/whitespace-secret; delete confirmation helper is deterministic and testable. `node --check assets/app.js` stays green; existing dashboard tests unaffected.

## 6. Exit bar
Login shows provider buttons; an `sso_error` shows a message; a valid `totp_challenge` resumes 2FA while a forged value does not; admin can CRUD providers with the secret write-only; provider deletion is confirmed; non-admin never sees the panel; CSP-safe; `node --test` green (existing 12 + new SSO tests), `node --check` clean; reviewed.

## 7. Execution log

- Added dashboard SSO login provider rendering through `GET /api/auth/oidc`.
- Added OIDC admin panel for provider list/create/edit/delete using the existing `oidc:admin` API.
- Added `assets/sso.js` as a DOM-free helper module and `assets/sso.test.mjs` for URL parsing, payload normalization, and destructive-action confirmation.
- Hardened A2 after review:
  - malformed `totp_challenge` values are ignored and stripped from the URL;
  - whitespace-only `client_secret` is treated as blank and does not overwrite the stored secret;
  - delete requires explicit confirmation;
  - `has_secret` badge requires strict boolean `true`;
  - provider save disables its submit button while the request is in flight.

## 8. Review outcome

- Independent adversarial review found no XSS, secret leakage, CSP, endpoint-shape, non-admin 403 isolation, or open-redirect blockers.
- Review findings fixed in this iteration:
  - **Medium:** arbitrary `?totp_challenge=fake` could show the real TOTP UI as a phishing primitive.
  - **Medium:** provider delete fired on one click without confirmation.
  - **Low/Info:** duplicate submit and non-strict `has_secret` display.
- Local security scan confirmed new SSO provider fields are escaped before `innerHTML`, `client_secret` is write-only, and no inline handlers/styles, `javascript:` URLs, or eval-like patterns were introduced.

## 9. Residuals & next

- Verification passed:
  - `npm test` in `lattice-dashboard`: 22/22 passing.
  - `npm run build` in `lattice-dashboard`: `node --check assets/app.js` passing.
  - `go test ./...` in `lattice-server`: passing.
  - `go build ./cmd/lattice-server`: binary produced; sandbox emitted a non-fatal Go module stat-cache permission warning when writing under the user module cache.
  - Local HTTP smoke against `127.0.0.1:18199`: static SSO markup, public provider list, admin login + CSRF, provider create/list, no secret in API, encrypted secret at rest, provider delete.
- Visual browser screenshot was attempted through the Node REPL browser path, but Playwright is not installed in that runtime. No new dependency was added; layout confidence comes from markup/CSS review plus HTTP smoke.
- Next recommended slices:
  - B1 host-API broker: server-side capability-scoped broker facade before plugins can touch host services.
  - B2 bbolt store: move state off JSON once API/storage tests lock current behavior.
  - A3 OIDC role/group claim mapping UI after provider CRUD is stable.
