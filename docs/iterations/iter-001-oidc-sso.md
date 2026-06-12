# Iteration 001 — OIDC / SSO login (Phase A1, roadmap item ②)

- **Status:** ✅ Complete (2026-06-12) — implemented, adversarially reviewed (FIX-FIRST → 5 fixes), workspace green. Backend only; dashboard SSO UI is Phase A2.
- **Vision link:** `PRODUCT-VISION.md` Phase A; decision basis `adr-001-plugin-foundation-oidc-2fa.md` D7–D9.
- **Cadence:** this doc is the durable artifact for Plan → Execute → Review → Iterate.

## 1. Goal

An operator can sign in with an external IdP (Google first, any OIDC issuer by config), mapped to a scoped **local** user — no password — via a secure auth-code flow. SSO config is admin-managed; the client secret is encrypted at rest (reuses ADR-002).

## 2. Design (decided in ADR-001)

- **Flow:** OAuth2 **auth-code + PKCE (S256) + `state` + `nonce`**. Provider-agnostic via OIDC discovery; Google is one configured provider.
- **Libraries:** `golang.org/x/oauth2` v0.36.0 + `github.com/coreos/go-oidc/v3` v3.18.0 (transitive `go-jose/v4`). **First external deps of lattice-server** — blessed by ADR-001 D8 ("JWT/JWKS validation is the part you must not hand-roll"). 3 modules total; documented in this iteration + ADR-001.
- **Identity mapping (D9, no auto-provision):**
  1. Verify ID token (go-oidc verifier: JWKS signature, issuer, audience=client_id, expiry, `nonce`).
  2. If an `OIDCIdentity{issuer,sub}` link exists → log in its user (stable-`sub` path).
  3. Else first login: require `email_verified=true` **and** email domain ∈ provider `allowed_domains` (if set) **and** a pre-existing local user whose `username == verified email`. Bind `sub`→user (TOFU within the allowlist). Otherwise **deny** (admin must pre-create the user).
  - `email` is display/binding-only; `sub` is the durable key.

## 3. Surface

**SDK model (`lattice-sdk/model`)**
- `OIDCProvider{ ID, DisplayName, Issuer, ClientID, ClientSecret, Scopes[], AllowedDomains[], Enabled, CreatedAt, UpdatedAt }` — `ClientSecret` is a secret-at-rest field.
- `OIDCIdentity{ Issuer, Subject, UserID, Email, CreatedAt }` — the durable link.

**Ephemeral auth state (`internal/auth`, like `TOTPChallenge`)**
- `OIDCAuthState{ State, Nonce, CodeVerifier, ProviderID, ClientIP, RedirectAfter, CreatedAt, ExpiresAt }` — single-use, short-lived (10 min), IP-bound, consumed on callback.

**Store (`internal/store`)**
- `OIDCProviders`, `OIDCIdentities` (key `issuer\x00sub`), `OIDCAuthStates` (key `state`) + CRUD; prune expired auth states on write.
- Extend `crypto.go`: encrypt/decrypt `OIDCProvider.ClientSecret`; extend `stateHasEnvelope`. (Directly answers ADR-002's "new secret field must route through the boundary.")

**`internal/oidc` (new)**
- Provider cache (discovery is network + cached). `Authenticator`: build `AuthCodeURL`, `Exchange`+verify, return verified claims. PKCE/state/nonce generation via `oauth2.GenerateVerifier` / crypto-rand.

**Server handlers**
- `GET /api/auth/oidc` (public) — enabled providers `[{id, display_name}]` for the login page.
- `GET /api/auth/oidc/{id}/start` (public) — make+store auth state, 302 to provider.
- `GET /api/auth/oidc/{id}/callback` (public) — validate+consume state, exchange (PKCE), verify ID token + nonce, map identity, `issueSession`, 302 to dashboard.
- `GET/POST /api/auth/oidc/providers`, `POST /api/auth/oidc/providers/delete` (scope **`oidc:admin`**) — config CRUD; responses hide `client_secret`.

**Wiring (`cmd`)** — `-public-url` / `LATTICE_PUBLIC_URL` to build the redirect URL.

**RBAC** — new scope `oidc:admin` (admin `*` covers it).

## 4. Risks & mitigations
- **Network at runtime** (discovery/JWKS/token) — provider cache; clear errors; callback failures redirect to login with an error code, never 500-leak.
- **Open redirect** via `RedirectAfter` — only allow same-origin relative paths.
- **CSRF/replay** — `state` single-use + IP-bound + TTL; `nonce` checked against ID token; PKCE binds the code to this client.
- **Secret leak** — `client_secret` encrypted at rest; never returned by any GET.
- **Testing without Google** — httptest **mock IdP** (discovery + JWKS + token, RS256-signed ID token) drives a real start→callback→session e2e; unit tests for state/PKCE/mapping/config-encryption.

## 5. Test plan
- `internal/auth`: OIDCAuthState gen/expiry/consume.
- `internal/store`: provider/identity/state CRUD; `client_secret` encrypted on disk + round-trips; expired-state pruning.
- `internal/oidc`: identity mapping decision table (link hit; first-login allow; denied: unverified email / disallowed domain / no local user); open-redirect sanitizer.
- `internal/server`: **mock-IdP e2e** — start sets state + 302; callback exchanges, verifies, binds sub, issues session cookie; tamper cases (bad state, wrong nonce, unknown sub+no allowlist) rejected. Admin CRUD hides secret.
- All `go test -race`, gofmt clean, dashboard 12/12 unaffected.

## 6. Out of scope (next iterations)
- Dashboard "Sign in with SSO" button + provider-config UI (Phase A2).
- Enforce-2FA-after-SSO, WebAuthn, group/role-claim → scope mapping (A3).

## 7. Exit bar
Mock-IdP e2e proves password-less SSO login end-to-end; identity mapping is allowlist-gated and no-auto-provision; client secret is secret-at-rest; adversarial review passed with must-fixes fixed; workspace green.

---

## 8. Execution log

Delivered (lattice-server + lattice-sdk):
- **Deps** (first external for lattice-server): `golang.org/x/oauth2 v0.36.0`, `github.com/coreos/go-oidc/v3 v3.18.0` (+ transitive `go-jose/v4 v4.1.4`). Verified via a throwaway spike before committing to the design; `go mod tidy` clean.
- **Model** (`lattice-sdk/model`): `OIDCProvider` (ClientSecret is a secret-at-rest field), `OIDCIdentity`.
- **Auth state** (`internal/auth/oidc_state.go`): `OIDCAuthState` + constructor (random state/nonce, caller-supplied PKCE verifier, TTL/Expired).
- **Store** (`internal/store/oidc.go`): provider CRUD (+ enabled filter), identity link (keyed `issuer\x00sub`), auth-state put/consume (single-use, prune-expired, cap 4096). `crypto.go` extended to encrypt/decrypt `OIDCProvider.ClientSecret` + `stateHasEnvelope`.
- **Core** (`internal/oidc/`): `Manager` (discovery cache, `AuthCodeURL` with S256+nonce, `Exchange` = code→tokens→verify ID token→nonce check→claims); `ResolveIdentity` (pure mapping); `SanitizeRedirect`; `GenerateCodeVerifier`.
- **Handlers** (`internal/server/server_oidc.go`): `GET /api/auth/oidc` (public list), `/api/auth/oidc/start`, `/api/auth/oidc/callback`, admin `GET/POST /api/auth/oidc/providers` + `/delete` (scope `oidc:admin`). One callback URL; provider bound via stored state. Login surface rate-limited. `issueSession` refactored to share `startSession` with the OIDC redirect path. **SSO honors local 2FA** (TOTP-enabled user → totp_challenge redirect, no silent bypass).
- **Wiring** (`cmd`): `-public-url` / `LATTICE_PUBLIC_URL`.

Tests (all `-race`): `internal/oidc` mapping decision-table + redirect/domain; `internal/auth` state; `internal/store` provider/identity/state CRUD + client-secret-encrypted-at-rest; `internal/server` **mock-IdP e2e** (hand-rolled RS256 IdP: discovery+JWKS+token) proving start→callback→session, plus nonce-mismatch, unprovisioned-deny, unknown-state, unknown-provider, list-hides-secret, admin-secret-write-only, and SSO-honors-TOTP. Workspace `build/vet/test -race` green; gofmt clean; dashboard 12/12.

## 9. Review outcome

3-lens adversarial review (protocol / identity / integration) + synthesis → **FIX-FIRST**. Verified-clean by the reviewers: PKCE(S256) replay, nonce, ID-token signature/issuer/audience/expiry (go-oidc, no Skip flags), single-use state, provider mix-up, open-redirect, `email_verified`/empty-sub/empty-email handling, bind-before-2FA ordering (no silent bypass), and denial info-leak posture. **5 of 6 findings fixed before commit, each with a regression test:**

- **H1 (High) — links keyed on attacker-influenceable `issuer`.** Re-keyed `OIDCIdentity` on the vetted **ProviderID** (`model` + `store.oidcIdentityKey`); enforced **issuer uniqueness** across providers in the admin upsert. A second provider sharing an issuer can no longer reuse another's links. (tests: store link-key, server e2e link lookup)
- **M1 (Medium) — login-CSRF / forced-login (only IP-bound).** Added a per-flow **browser-binding cookie** (`lattice_oidc_bind`, HttpOnly, Secure, SameSite=Lax, OIDC-path-scoped); only its SHA-256 is stored; the callback constant-time-compares it before proceeding. IP check kept as defense-in-depth. (tests: `TestOIDCCallbackRequiresBindingCookie` — missing + forged)
- **M2 (Medium) — email/username case asymmetry (lockout + coexistence).** `UserByUsername` is now case-insensitive (`EqualFold`); SSO's lowercased email resolves a mixed-case-provisioned account.
- **M3 (Medium) — existing-link path skipped re-authorization.** `ResolveIdentity` now re-evaluates the provider domain policy (verified email + allowed domain) on **every** login, so tightening the allowlist / an email going unverified is retroactive for linked subjects. (tests: 2 new re-check cases)
- **L1 (Low) — no network timeout.** Discovery/JWKS/token-exchange run through a 10s-bounded `*http.Client` via `oidc.ClientContext`.

## 10. Residuals & next

- **M4 (Medium, accepted residual) — SSO availability DoS.** A distributed attacker rotating IPs could fill the global in-flight auth-state cap (4096), and every `/start` rewrites the whole state file under the store lock. Bounded by the per-IP login limiter (5/min) and a 10-min TTL; identical pattern to the existing `TOTPChallenges`. **Deferred to Phase C (bbolt)**, which reworks persistence — add a per-IP in-flight cap + move ephemeral auth-states off the full-file-rewrite path then.
- **Admin-set-issuer SSRF + stale discovery cache** (Info): admin-trusted; optional hardening (host allowlist / RFC1918 block on the discovery client; evict-cache-on-upsert) noted for a later pass.
- **Next iterations:** A2 dashboard "Sign in with SSO" + provider-config UI (handles `sso_error` / `totp_challenge` redirect params); then Phase B (host-API broker, item ③).
