<!-- Adopted 2026-06-12 after verifying every codebase claim against source:
     User.TOTPEnabled exists (model.go:22); auth/store primitives present;
     handleLogin seam at server.go:412 (VerifySecret 436 -> NewSession 440);
     CSP includes `img-src 'self' data:` (server.go:2366).
     Implementation refinement: P0 2FA enrollment ships the otpauth:// URI +
     base32 secret for manual entry (100% CSP-safe, zero-dep). The server-rendered
     data-URI QR PNG (a hand-rolled, zero-dep QR encoder) is a documented P1
     usability follow-up, not a P0 blocker. -->

# ADR-001: Lattice Control-Plane Plugin Foundation, Core/Plugin Boundary, OIDC Login, and 2FA

- **Status:** Accepted (decision-grade)
- **Date:** 2026-06-12
- **Authors:** Lead architect (synthesis of 6 research briefs)
- **Audience:** Security-first engineer; "think deeply and make the decisions"
- **Project priors:** Security first → functionality → usability → performance. **ZERO external Go deps today** (`go 1.26`, only `github.com/LatticeNet/lattice-sdk`). Every new dependency must be explicitly justified or rejected.
- **Verified against code:** `lattice-server/internal/plugin/plugin.go`, `internal/auth/auth.go`, `internal/server/server.go`, `internal/ddns/ddns.go`, `internal/notify/notify.go`, `internal/store/store.go`, `lattice-sdk/model/model.go`, `cmd/lattice-server/main.go`.

---

## 1. Decision summary

| # | Decision area | Call made | Why (one line) |
|---|---|---|---|
| D1 | Plugin runtime tiers | Ship **system + worker** now; **wasm tier deferred** behind a stable host-API contract | Tiers/capabilities already modeled in `plugin.go`; wasm cost not yet justified |
| D2 | WASM runtime (when wasm lands) | **wazero** (pure-Go, zero CGO, zero transitive deps), gated behind build tag `lattice_wasm` | Only runtime that preserves the static/CGO-free posture; first justified dep |
| D3 | P0 plugin milestone | Make `internal/plugin` **load-bearing**: a `Loader` wired to `VerifyInstallManifest` + operator `TrustPolicy` from config | Verification primitives exist but nothing calls them at install time |
| D4 | Marketplace trust | **Offline ed25519 signature verification** against operator-configured `trusted_publishers`; registry is a CDN of signed artifacts, never a trust root | Reuses `SigningPayload`/`VerifyManifest`; fail-closed for host-risk |
| D5 | Core vs plugin rule | **Engine = core, providers = plugin.** Security, identity, store, RBAC, scheduler, host-API broker are CORE and never pluginizable | Keeps the trust base small; plugins extend, never replace, the kernel |
| D6 | Refactor existing providers | **Later (P2), not now.** Freeze ddns/notify/monitor behind the existing `NewProvider`/`Channel` factories; pluginize only after the loader + host-API are proven | `NewProvider` switch is already the seam; premature pluginization adds risk before value |
| D7 | OIDC login | **Auth-code + PKCE (S256) + state + nonce**, provider-agnostic via discovery; Google is just one configured provider | One code path for Google and generic OIDC; PKCE+nonce closes the standard holes |
| D8 | OIDC dependency | Adopt **`golang.org/x/oauth2`** + **`github.com/coreos/go-oidc/v3`**; do NOT hand-roll JWKS/JWT validation | JWT/JWKS validation is the part you must not get wrong; these are the canonical, minimal-surface libs |
| D9 | Identity mapping | **Allowlist-gated, no auto-provisioning by default.** Match `(issuer, sub)` → local `User`; email is display-only | `sub` is the only stable identifier; email is mutable/spoofable across IdPs |
| D10 | 2FA | **TOTP-first** (RFC 6238), recovery codes, WebAuthn deferred; insert a 2FA gate in `handleLogin` | `model.User.TOTPEnabled` already exists; smallest secure step |
| D11 | 2FA dependency | **Hand-roll ~80 LOC TOTP** on stdlib `crypto/hmac`+`crypto/sha1`; reject `pquerna/otp` | TOTP is trivially correct in stdlib; a dep here is not justified. (WebAuthn later WILL justify a dep.) |
| D12 | Dashboard QR under CSP | **No QR/JS lib.** Server renders the QR as an inline `data:` PNG (already allowed: `img-src 'self' data:`) + shows the secret for manual entry | Strict CSP (`script-src 'self'`) forbids a client QR lib; server-side PNG sidesteps it |

**Net new dependencies authorized by this ADR:** `x/oauth2`, `go-oidc/v3` (D8), and `wazero` only when the wasm tier is actually built (D2). TOTP and the plugin loader add **zero** dependencies.

---

## 2. Plugin framework foundation

### 2.1 Runtime tiers

The manifest model in `internal/plugin/plugin.go` already encodes three tiers and a capability-risk lattice. We keep the model, stage the delivery.

| Tier | `Manifest.Type` | Trust / isolation | Allowed risk classes | Status |
|---|---|---|---|---|
| **System** | `TypeSystem` | In-process Go, full host trust; **must** be signed by a trusted publisher for host-risk caps | `read`, `write`, **`host`** | Ship in P1 (loader gates it) |
| **Worker** | `TypeWorker` | Sandboxed compute, restricted cap set (`kv:read`, `static:read`, `worker:route`) | `read`, `write` (subset) | Ship in P1 |
| **WASM** | `TypeWasm` | wazero sandbox, no host trust, capability-brokered host calls only | `read`, `write` (no `host`) | **Deferred** to P2 behind host-API freeze |

`ValidateManifest` already enforces the key invariant: **`host`-risk capabilities require `TypeSystem`**, and worker plugins are restricted to `workerCapabilities`. That invariant is the backbone of the boundary — do not weaken it.

### 2.2 The wazero choice (and why not now)

**Decision:** When the wasm tier lands, use **wazero** (`github.com/tetratelabs/wazero`).

**Dependency justification (the bar every dep must clear here):**
- **Zero CGO, zero transitive dependencies.** wazero is pure Go with no external deps of its own — it preserves Lattice's static-binary, CGO-free posture. Any CGO-based runtime (wasmtime/wasmer bindings) is rejected outright: it breaks cross-compilation and the static-link guarantee.
- **Security:** deny-by-default host imports. A guest can only call host functions we explicitly export, which maps 1:1 onto the capability-binding table below.
- **Why deferred:** there is no value in a sandbox until the **host-API contract is frozen**. Building wasm before the host API is stable means re-cutting the ABI repeatedly. So wazero is authorized but gated behind build tag `//go:build lattice_wasm` and only compiled when wasm plugins exist. Until then it is not in `go.mod`.

**Rejected alternatives:** Go `plugin` package (`.so`) — version-lock hell, no sandbox, no Windows, rejected. Subprocess+RPC for everything — heavier than needed for system/worker tiers that are already trusted-or-restricted.

### 2.3 Host-API capability-binding table

Every capability string in `capabilityRisk` binds to exactly one host-API surface and risk class. The broker (CORE) is the only thing that holds real handles; plugins receive a capability-scoped facade.

| Capability | Risk | Host API bound | Available to |
|---|---|---|---|
| `audit:read` | read | `Audit.Query()` (read-only) | system, worker(no) |
| `kv:read` | read | `KV.Get/List()` | system, worker |
| `monitor:read` | read | `Monitor.Results()` | system |
| `node:read` | read | `Nodes.List/Get()` | system |
| `static:read` | read | `Static.Read()` | system, worker |
| `task:read` | read | `Tasks.Results()` | system |
| `kv:write` | write | `KV.Put/Delete()` | system |
| `notify:send` | write | `Notify.Send()` (broker-rate-limited) | system |
| `worker:route` | write | `Worker.Route()` | system, worker |
| `ddns:admin` | **host** | `DDNS.Apply()` + outbound HTTP via SSRF guard | **system only, signed** |
| `monitor:admin` | **host** | `Monitor.Configure()` | system only, signed |
| `network:plan` | **host** | `Network.Plan()` (dry-run) | system only, signed |
| `network:apply` | **host** | `Network.Apply()` (mutating, approval-gated) | system only, signed |
| `node:admin` | **host** | `Nodes.Enroll/Mutate()` | system only, signed |
| `static:write` | **host** | `Static.Write()` | system only, signed |
| `task:run` | **host** | `Tasks.Dispatch()` | system only, signed |
| `tunnel:admin` | **host** | `Tunnel.Apply()` | system only, signed |

Rule enforced at load: any manifest containing a `host`-risk capability that is not `TypeSystem` is rejected by `ValidateManifest`; any `host`-risk system plugin without a trusted-publisher ed25519 signature is rejected by `VerifyManifest` unless `AllowUnsignedHostRisk` (dev-only, fail-open opt-out) is set.

### 2.4 Plugin lifecycle state machine

```
                 install bundle (manifest.json + artifact)
                              |
                              v
                      +---------------+
                      |   DISCOVERED  |
                      +-------+-------+
                              | VerifyInstallManifest(manifest, artifact, policy)
              digest/sig FAIL |  \  OK
              +---------------+   \
              v                    v
        +-----------+        +-----------+
        | REJECTED  |        | VERIFIED  |
        +-----------+        +-----+-----+
        (quarantine,               | capability grant by TrustPolicy
         audit, never load)        v
                             +-----------+
                             | INSTALLED |  (on disk, untrusted-until-loaded)
                             +-----+-----+
                                   | Loader.Load()  -> bind host APIs by capability
                                   v
              +-------> +-----------+ ---- runtime error / panic (isolated) ---+
              |         |  ACTIVE   |                                          |
   operator   |         +-----+-----+                                          v
   re-enable  |               | Disable()                              +-----------+
              |               v                                        |  FAILED   |
              +-------- +-----------+ <--- operator disable ----------- +-----+-----+
                        | DISABLED  |                                         |
                        +-----+-----+ <--------------------------------------+
                              | Uninstall()
                              v
                        +-----------+
                        |  REMOVED  |  (artifact deleted, grant revoked, audit)
                        +-----------+
```

Invariants: `DISCOVERED → VERIFIED` is the **only** edge that grants trust, and it runs `VerifyInstallManifest`. `FAILED` never silently restarts a `host`-risk plugin — operator action required. Every transition emits an `model.AuditEvent`.

### 2.5 Signed install + marketplace / offline verification

- **Artifact = `{manifest.json, artifact-blob}`.** `manifest.DigestSHA256` pins the blob; `manifest.SignatureEd25519` signs the canonical `SigningPayload` (already implemented, sorts capabilities, version-tagged `lattice-plugin-manifest-v1`).
- **Trust root is the operator, not the marketplace.** The registry/marketplace is a dumb CDN. Trust comes solely from `TrustPolicy.TrustedPublishers` loaded from operator config. A compromised marketplace cannot ship a host-risk plugin because it cannot forge a trusted publisher's ed25519 signature.
- **Offline verification:** `VerifyInstallManifest` requires no network. Air-gapped installs work by copying the bundle + having the publisher key in config. This is a feature, keep it.
- **Fail-closed default:** host-risk plugins require a valid trusted-publisher signature. `AllowUnsignedHostRisk=true` is dev-only and must be logged loudly at startup.

### 2.6 P0 milestone — make `internal/plugin` load-bearing

Today `VerifyInstallManifest`, `VerifyManifest`, `ParseTrustPolicyJSON`, and `TrustPolicy` exist but **nothing calls them**. P0 closes that gap with the minimum viable loader:

1. **New file `internal/plugin/loader.go`** — `type Loader struct { policy TrustPolicy; dir string; store *store.Store; broker *hostapi.Broker }` with `Load(ctx) ([]Loaded, error)` that, per bundle under `dir`:
   - reads `manifest.json` + artifact, calls `VerifyInstallManifest(manifestBytes, artifact, l.policy)`,
   - on success binds a capability-scoped host facade and records `plugin.installed`/`plugin.activated` audit events,
   - on failure quarantines + records `plugin.rejected` and continues (one bad plugin never blocks boot).
2. **Operator trust policy from config:** load `trusted_publishers` + `allow_unsigned_host_risk` via `ParseTrustPolicyJSON` from `LATTICE_PLUGIN_TRUST` (file path) / `-plugin-trust` flag in `cmd/lattice-server/main.go`, threaded into `server.Options`.
3. **Wire into `server.New`:** construct the `Loader` from `Options.PluginDir` + parsed policy, call `Load` at startup, register active plugins' routes/hooks through the broker.
4. **Exit criteria:** an unsigned host-risk plugin fails to load and is audited; a signed one from a trusted publisher loads and binds only its declared capabilities; boot survives a corrupt bundle.

This is the gate before any marketplace work — **loader before registry.**

---

## 3. Core-vs-plugin matrix

### 3.1 The rule

**Engine is CORE; providers are PLUGINS.** A subsystem is CORE iff it is part of the trust base, the data model, or the host-API broker. Everything that is "one of N interchangeable implementations behind a stable interface" is a candidate PLUGIN. Plugins **extend** the kernel through brokered capabilities; they never **replace** identity, storage, RBAC, or the broker itself.

### 3.2 Matrix

| Subsystem | CORE / PLUGIN | Rationale |
|---|---|---|
| Auth: sessions, password hash, PAT, `DummyVerify` | **CORE** | Trust base; timing-safe primitives must not be swappable |
| OIDC/OAuth login | **CORE** (engine) with **provider configs** | Token validation is core; each IdP is config, not code |
| 2FA / TOTP verification | **CORE** | Login-path security; never delegated to a plugin |
| Session store, state persistence (`store.go`) | **CORE** | Single source of truth; data-model owner |
| RBAC scope evaluation (`rbac.Allows`) | **CORE** | Authorization decisions are non-delegable |
| Rate limiting (`ratelimit`) | **CORE** | DoS/brute-force defense |
| Audit log | **CORE** | Tamper-evidence + every plugin transition writes here |
| Host-API broker / capability binding | **CORE** | The thing that makes plugins safe cannot be a plugin |
| Plugin loader + verification | **CORE** | Bootstraps the trust chain |
| **DDNS engine** (`Apply`, retry, SSRF guard) | **CORE** | Orchestration + outbound guard stay in kernel |
| DDNS providers (Cloudflare, Webhook, future) | **PLUGIN-eligible** | Pure `NewProvider` switch arms; classic plugin shape |
| **Notify dispatcher** (`Dispatcher.Send`, fan-out isolation) | **CORE** | Fan-out + rate-limit policy is kernel |
| Notify channels (Telegram, webhook, future) | **PLUGIN-eligible** | `Channel` interface implementers |
| **Monitor engine** (scheduling, result ingest) | **CORE** | Scheduler + agent protocol are kernel |
| Monitor check types | **PLUGIN-eligible** | Interchangeable probes |
| Network plan/apply, WireGuard, tunnels | **CORE** | Host-risk, approval-gated, mutating infra |
| Static hosting, KV, worker routing | **CORE engine** + worker-tier plugins for compute | Storage is core; user compute is sandboxed |
| Dashboard (static SPA) | **CORE asset** | Served under strict CSP from `WebFS` |

### 3.3 Refactor existing providers now or later?

**Later — P2, and only after the loader + host-API broker are proven.** The `NewProvider`/`Channel` factories in `internal/ddns/ddns.go` and `internal/notify/notify.go` are *already* the extension seam, and they currently carry security-critical context (the `GuardOutbound` SSRF guard is injected by the engine, not the provider). Pluginizing them prematurely means re-homing that guard across a capability boundary before the broker exists — a security regression for no user benefit. **Decision:** freeze the interfaces now, document them as the future plugin ABI, and convert the first provider to a real (signed, brokered) plugin only as the *proof case* in P2. Engine-owned concerns (retry, SSRF guard, fan-out isolation, rate limiting) stay in CORE permanently.

---

## 4. OIDC login design

### 4.1 Flow — Authorization Code + PKCE

```
Browser            lattice-server                         IdP (Google / generic OIDC)
  |  GET /api/auth/oidc/{provider}/start                       |
  |------------------------------>|  gen state(32B), nonce(32B),|
  |                               |  PKCE verifier+S256 challenge|
  |                               |  store in short-lived signed |
  |                               |  cookie (oidc_tx, 10 min)    |
  |   302 -> IdP authorize?...    |                              |
  |<------------------------------|                              |
  |  authenticate at IdP -------------------------------------->|
  |   302 -> /api/auth/oidc/{provider}/callback?code&state      |
  |------------------------------>|  verify state == cookie      |
  |                               |  exchange code+verifier ---->|
  |                               |  <---- id_token + access     |
  |                               |  verify id_token: iss, aud,  |
  |                               |  exp, nonce, sig via JWKS     |
  |                               |  map (iss,sub) -> User        |
  |                               |  allowlist check             |
  |                               |  [2FA gate if TOTPEnabled]   |
  |   Set-Cookie lattice_session  |  issue session (reuse path)  |
  |<------------------------------|                              |
```

Mandatory checks: **state** (CSRF on the redirect), **nonce** (replay binding into `id_token`), **PKCE S256** (code interception), and full `id_token` validation (`iss`, `aud`==client_id, `exp`, signature via discovery JWKS). The `oidc_tx` cookie is `HttpOnly`, `SameSite=Lax` (must survive the IdP redirect — Strict would drop it), `Secure` when `secureCookies`.

### 4.2 Provider-agnostic via discovery

One code path. Each provider supplies `issuer` only; the server fetches `{issuer}/.well-known/openid-configuration` to learn authorize/token/JWKS endpoints. Google is *not special* — it is a provider whose issuer is `https://accounts.google.com`. JWKS is cached and refreshed per the library's key-rotation handling.

### 4.3 Dependency decision — adopt, do not hand-roll

**Adopt `golang.org/x/oauth2` + `github.com/coreos/go-oidc/v3`. Reject hand-rolling.**

| Concern | Hand-roll | Library |
|---|---|---|
| Authorize URL / code exchange | ~easy | `x/oauth2` (trivial, well-audited) |
| **JWKS fetch + key rotation + JWT sig/claims validation** | **dangerous** — alg-confusion, `none`-alg, kid handling, clock skew | `go-oidc` (canonical, minimal surface) |
| Discovery doc parsing | medium | `go-oidc` |

Justification against the zero-dep prior: ID-token validation is exactly the class of crypto-protocol code where a hand-rolled bug is a full auth bypass. `go-oidc/v3` pulls `gopkg.in/go-jose` — a small, focused, widely-deployed JOSE implementation. This is a **justified** dependency; it buys correctness on the one part we cannot afford to get wrong. PKCE/state/nonce generation stays ours (already have `auth.NewRandomToken`).

### 4.4 Identity → account mapping & allowlist

- **Match key: `(issuer, sub)`**, stored on the local `User`. `sub` is the only IdP-stable identifier; **email is display-only** and never an auth key (mutable, re-assignable, cross-IdP collisions).
- **No auto-provisioning by default.** Login succeeds only if a `User` is pre-linked, or the verified email/domain is on the operator allowlist *and* `oidc.auto_provision=true`. Default is allowlist-only.
- Allowlist supports exact emails and `@domain.com` suffixes (require `email_verified=true`).
- First successful OIDC login for an allowlisted-but-unlinked identity creates the link `(iss,sub)→User` and audits `oidc.link`.

### 4.5 Endpoint shapes

| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/auth/oidc/providers` | none | List enabled providers (display name + id) for login UI buttons |
| GET | `/api/auth/oidc/{provider}/start` | none | Set `oidc_tx`, 302 to IdP |
| GET | `/api/auth/oidc/{provider}/callback` | `oidc_tx` cookie | Validate, map, issue `lattice_session` (or 2FA challenge) |

These mount alongside the existing `mux.HandleFunc` block in `server.go` (~line 124). Login rate limiter (`loginLimiter`, 5/min) applies to `/start` keyed by client IP.

### 4.6 Config schema

```jsonc
// LATTICE_OIDC_CONFIG (file) -> server.Options.OIDC
{
  "providers": [{
    "id": "google",
    "display_name": "Google",
    "issuer": "https://accounts.google.com",
    "client_id": "…apps.googleusercontent.com",
    "client_secret": "…",            // secret-bearing: 0600 file, never logged
    "scopes": ["openid","email","profile"],
    "redirect_url": "https://lattice.example/api/auth/oidc/google/callback"
  }],
  "allowlist": ["alice@example.com", "@corp.example.com"],
  "auto_provision": false,
  "default_scopes": ["node:read"]    // RBAC scopes granted to provisioned users
}
```

New flag/env in `main.go`: `-oidc-config` / `LATTICE_OIDC_CONFIG`, threaded into `server.Options.OIDC`.

### 4.7 Session issuance

Reuse the existing path verbatim: `auth.NewSession(user.ID, 12*time.Hour)` → `store.PutSession` → `lattice_session` cookie (`HttpOnly`, `SameSite=Strict`, `Secure=secureCookies`). OIDC must **not** invent a second session type. The CSRF token in the JSON response is unchanged.

### 4.8 Threat list

- **State/CSRF** → `state` param bound to `oidc_tx`. **Replay** → `nonce` in `id_token`. **Code interception** → PKCE S256.
- **alg=none / alg-confusion** → `go-oidc` enforces expected algs against JWKS. **aud confusion** → strict `aud==client_id`.
- **Open redirect** → `redirect_url` is server-configured, never client-supplied. **IdP-mix-up** → issuer pinned per provider.
- **Account takeover via email** → email never an auth key; `(iss,sub)` only.
- **Secret leakage** → `client_secret` from 0600 file, scrubbed from logs/errors. **Token-exchange SSRF** → discovery/JWKS/token URLs derive from the pinned issuer host only.

---

## 5. 2FA design

### 5.1 TOTP-first

RFC 6238 TOTP (SHA-1, 6 digits, 30s step, ±1 window for clock skew). WebAuthn is the documented next step but out of scope for P1. `model.User.TOTPEnabled` already exists — this design fills it in.

### 5.2 Dependency decision — hand-roll TOTP

**Hand-roll ~80 LOC on stdlib; reject `pquerna/otp`.** TOTP is `HMAC-SHA1(secret, counter)` + dynamic truncation — a textbook, fully-specified algorithm with stdlib `crypto/hmac`, `crypto/sha1`, `encoding/base32`. A dependency here is **not justified** against the zero-dep prior; the entire surface is verifiable by RFC 6238 test vectors. (Contrast D8: OIDC's JWT validation genuinely warrants a lib; TOTP does not.) **WebAuthn, when it lands, WILL justify a dependency** — that's the next dep conversation, not this one. New file: `internal/auth/totp.go` with `GenerateSecret() (string, error)`, `Validate(secret, code string, t time.Time) bool` (constant-time compare via `hmac.Equal`, checks window `{-1,0,+1}`).

### 5.3 Login state machine

```
        POST /api/login (user+pass)            POST /api/auth/oidc/.../callback
                  |                                          |
                  v   VerifySecret OK                        v  id_token OK + mapped
            +-----------+                              +-----------+
            | PWD_OK    |------------------------------|  OIDC_OK  |
            +-----+-----+                              +-----+-----+
                  |  user.TOTPEnabled?                       |
        no +------+------+ yes                               | (TOTPEnabled?)
           v             v                                   |
   +-------------+  +--------------+ <------------------------+
   |  SESSION    |  | TOTP_PENDING |
   |  ISSUED     |  +------+-------+
   +-------------+         | POST /api/login/totp {code | recovery_code}
                          /  \
              valid code /    \ invalid (rate-limited, audited)
                        v      v
                 +-----------+  +--------------+
                 |  SESSION  |  | reject 401   |
                 |  ISSUED   |  +--------------+
                 +-----------+
```

**Insertion point (exact):** in `handleLogin` (server.go ~line 437), between the successful `auth.VerifySecret` and `auth.NewSession`. If `user.TOTPEnabled`, do **not** issue `lattice_session`. Instead issue a short-lived (`5 min`) `totp_pending` server-side challenge (stored, single-use, bound to user + client IP) and return `{"totp_required": true}`. The OIDC callback funnels into the same gate.

### 5.4 Recovery codes

10 single-use codes generated at enrollment, shown **once**, stored as pbkdf2 hashes (reuse `auth.HashSecret`) in `User.RecoveryCodeHashes`. Accepting a recovery code at `/api/login/totp` consumes (deletes) that hash and audits `totp.recovery_used`. When ≤2 remain, surface a regenerate prompt.

### 5.5 Dashboard UX under strict CSP

CSP is `script-src 'self'; img-src 'self' data:` (server.go ~line 2366). Therefore **no client-side QR library** is possible and none is needed:
- Enrollment endpoint returns the `otpauth://` URI, the base32 secret (for manual entry), **and a server-rendered QR as an inline `data:image/png;base64,…`** — permitted by `img-src ... data:`. QR PNG encoding is done server-side (small, no dep needed; a compact stdlib-only QR encoder is acceptable, or render the secret prominently for manual entry as the guaranteed-CSP-safe fallback).
- Verify-on-enroll: user must submit one valid code before `TOTPEnabled` flips true (prevents lockout from a mis-scanned secret).

### 5.6 Data-model additions

On `model.User` (extends existing `TOTPEnabled bool`):
```go
TOTPSecret         string   `json:"totp_secret,omitempty"`          // base32; encrypted-at-rest if/when KMS exists
RecoveryCodeHashes []string `json:"recovery_code_hashes,omitempty"` // pbkdf2 via auth.HashSecret
```
New server-side `TOTPChallenge` (in store, like `Session`): `{ID, UserID, ClientIP, ExpiresAt, Used bool}`.

### 5.7 Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/2fa/totp/enroll` | session | Generate secret, return `otpauth://` + data-URI QR + recovery codes |
| POST | `/api/2fa/totp/activate` | session | Verify first code, set `TOTPEnabled=true` |
| POST | `/api/login/totp` | `totp_pending` challenge | Submit TOTP **or** recovery code, issue session |
| POST | `/api/2fa/totp/disable` | session + valid code | Disable, wipe secret + recovery hashes |

### 5.8 Threats

- **Brute force of 6-digit code** → reuse `loginLimiter` (5/min) keyed on challenge+IP; lock the challenge after N failures.
- **Replay** → ±1 window only; optionally remember last-used counter per user to reject reuse within window.
- **Phishing** → TOTP is phishable; documented as the reason WebAuthn is the roadmap successor.
- **Secret at rest** → `totp_secret` in state file; document that the state file is the crown jewel and must be 0600 (already the `defaultDataPath` posture).
- **Recovery-code theft** → hashed, single-use, audited on use.
- **Pending-challenge fixation** → challenge is single-use, IP-bound, 5-min TTL, server-generated.

---

## 6. Data-model & config additions

### `lattice-sdk/model/model.go` — `User`
```go
type User struct {
    ID                 string    `json:"id"`
    Username           string    `json:"username"`
    PasswordHash       string    `json:"password_hash"`
    Scopes             []string  `json:"scopes"`
    TOTPEnabled        bool      `json:"totp_enabled"`                    // EXISTS
    TOTPSecret         string    `json:"totp_secret,omitempty"`          // NEW
    RecoveryCodeHashes []string  `json:"recovery_code_hashes,omitempty"` // NEW
    OIDCIdentities     []OIDCIdentity `json:"oidc_identities,omitempty"` // NEW
    CreatedAt          time.Time `json:"created_at"`
}

type OIDCIdentity struct { // NEW
    Issuer  string `json:"issuer"`   // pinned per provider
    Subject string `json:"subject"`  // the (iss,sub) auth key
    Email   string `json:"email,omitempty"` // display only
}
```

### `internal/auth` — `Session` (unchanged) + new `TOTPChallenge`
```go
type TOTPChallenge struct { // store-backed, parallels Session
    ID        string
    UserID    string
    ClientIP  string
    CreatedAt time.Time
    ExpiresAt time.Time   // ~5 min
    Used      bool
}
```

### `internal/store/store.go` — new methods (mirror existing `PutSession`/`Session`/`DeleteSession`)
`PutTOTPChallenge`, `TOTPChallenge(id)`, `ConsumeTOTPChallenge(id)`; `LinkOIDCIdentity(userID, OIDCIdentity)`, `UserByOIDC(iss, sub)`.

### `internal/server/server.go` — `Options` additions
```go
OIDC      *oidc.Config    // parsed from -oidc-config
PluginDir string          // root for plugin bundles
PluginTrust plugin.TrustPolicy // from ParseTrustPolicyJSON
```

### `cmd/lattice-server/main.go` — new flags/env (alongside existing block)
| Flag | Env | Meaning |
|---|---|---|
| `-oidc-config` | `LATTICE_OIDC_CONFIG` | OIDC providers + allowlist file |
| `-plugin-dir` | `LATTICE_PLUGIN_DIR` | Plugin bundle root |
| `-plugin-trust` | `LATTICE_PLUGIN_TRUST` | `trusted_publishers` JSON for `ParseTrustPolicyJSON` |

**Seam map (where each thing plugs in):**
- 2FA gate → `handleLogin`, between `VerifySecret` and `NewSession` (server.go ~437).
- OIDC routes → `mux.HandleFunc` block (server.go ~124).
- Session issuance → reuse `auth.NewSession`/`PutSession`/cookie (server.go ~443–457).
- Plugin loader → `server.New` startup, new `internal/plugin/loader.go`, consuming `VerifyInstallManifest` + `ParseTrustPolicyJSON` (plugin.go, already present).
- Provider ABI freeze → `ddns.NewProvider` (ddns.go ~41), `notify.Channel`/`NewDispatcher` (notify.go ~28/45).

---

## 7. Sequenced implementation plan

Ordering principle: **security baseline before exposure; plugin loader before marketplace.**

### P0 — Security baseline + plugin trust chain (no new external deps)
1. **TOTP core** `internal/auth/totp.go` + RFC 6238 test vectors. `[core][security]`
2. **2FA login gate** in `handleLogin` + `TOTPChallenge` store + `/api/login/totp`, `/api/2fa/totp/*`. `[core][security]`
3. **2FA dashboard UX**: server-rendered data-URI QR + manual secret + recovery codes, CSP-safe. `[core][usability]`
4. **Plugin loader** `internal/plugin/loader.go` wired to `VerifyInstallManifest` + `ParseTrustPolicyJSON`; `-plugin-trust`/`-plugin-dir` flags; fail-closed host-risk; per-plugin audit. `[core][security]`
5. **Data-model + store migrations** for the fields in §6. `[core][functionality]`

### P1 — Federated login + active plugins (deps: `x/oauth2`, `go-oidc/v3` — justified D8)
6. **OIDC engine** (discovery, PKCE, state, nonce, JWKS validation) + 3 endpoints. `[core][security]`
7. **Identity mapping + allowlist** (`(iss,sub)`, no auto-provision default). `[core][security]`
8. **Google + generic OIDC config**, login-UI provider buttons. `[core][usability]`
9. **System + worker plugin tiers go live** through the host-API broker + capability binding table (§2.3). `[plugin][functionality]`
10. **Host-API broker** as the single handle-holder; capability-scoped facades. `[core][security]`

### P2 — Marketplace + provider pluginization + scale (dep: `wazero` only if wasm built — D2)
11. **Marketplace/registry** as signed-artifact CDN; offline verification UX. `[plugin][functionality]`
12. **First real provider plugin** (convert one DDNS or notify provider as the proof case; keep engine/SSRF-guard in core). `[plugin][functionality]`
13. **WASM tier (wazero)** behind `lattice_wasm` build tag, once host API is frozen. `[plugin][security]`
14. **WebAuthn 2FA** (the next *justified* dependency conversation). `[core][security]`
15. **Loader/broker performance pass** (lazy load, per-plugin resource caps). `[plugin][performance]`

---

## 8. Residual risk & open questions for the operator

**Residual risks**
- **State file is the crown jewel.** It now holds password hashes, TOTP secrets, and OIDC links. Compromise = full takeover. Mitigation today: 0600 + private/WireGuard bind. **Open:** do we add envelope encryption / KMS for `totp_secret` and `client_secret` before P1 ships?
- **TOTP is phishable.** Accepted for P1; WebAuthn (P2) is the real fix.
- **System-tier plugins are in-process and fully trusted once signed.** A signed-but-malicious publisher key is game over. Mitigation: minimal trusted-publisher set, host-risk fail-closed, audit. **Open:** key-rotation/revocation policy for `trusted_publishers`?
- **`AllowUnsignedHostRisk` is a foot-gun.** It exists for dev. **Open:** should startup *refuse to boot* in production mode (e.g., when `secureCookies` is set) if it's true?
- **OIDC libs add transitive surface** (`go-oidc` → `go-jose`). Justified, but it is the first non-SDK dependency — it must be pinned and reviewed.

**Operator decisions needed**
1. OIDC **auto-provisioning**: default off (allowlist-only) — confirm, or enable domain-based auto-provision with `default_scopes`?
2. **2FA enforcement**: optional per-user (proposed) vs. mandatory for `network:apply`/`node:admin` scopes?
3. **Trusted publishers**: who are they, and where do their ed25519 public keys come from at install time?
4. **wasm timeline**: do any near-term plugins actually need untrusted sandboxing, or do system+worker tiers cover the roadmap (keeping `wazero` out of `go.mod` longer)?
5. **Encryption-at-rest** for secrets in the state file: P1 blocker or P2 follow-up?
