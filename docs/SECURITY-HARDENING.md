# Security Hardening Pass — 2026-06-11

This pass made security the top priority across `lattice-server` and
`lattice-node-agent`. Every change ships with tests and the whole workspace
passes `go test -race`. Findings are grouped by severity. Each entry lists the
issue, the fix, and where it lives.

## Critical / High — authorization & authentication

| # | Issue | Fix | Location |
|---|-------|-----|----------|
| 1 | **Privilege bug:** creating a task required `static:write` instead of `task:run`, so a correctly-scoped task token could not create tasks while a static token could. | Removed the wrong inner scope check; the route's `task:run` is authoritative. | `internal/server/server.go` `handleTasks` |
| 2 | **Privilege escalation:** `POST /api/static` only required `static:read` (route scope), so any read-only static token could **write** static objects. | Added an explicit `static:write` check on POST. | `internal/server/server.go` `handleStatic` |
| 3 | **Auth DoS:** bearer auth iterated **every** stored token running a 210k-iteration PBKDF2 per token, per request — O(N) CPU amplification. | PAT credential is now `"<id>.<secret>"`; the server looks the record up by id (O(1)) and runs a single verify. | `internal/auth/auth.go` (`FormatToken`/`SplitToken`), `internal/server/server.go` `principalFromRequest` |
| 4 | **Credential leakage:** agent task-poll accepted the node token in the URL query (`?token=`), landing it in access logs and proxy caches. | Token is read only from the `Authorization` header. | `internal/server/server.go` `handleAgentTasks`, agent already sends the header |
| 5 | **User/token enumeration via timing:** unknown username/token returned before doing any hash work. | Added `auth.DummyVerify` to equalize CPU on the not-found paths (login + bearer). | `internal/auth/auth.go`, `internal/server/server.go` |
| 6 | **Token-creation escalation:** none existed yet, but adding PAT creation risks granting scopes beyond the creator's. | New PAT endpoints enforce that requested scopes are a subset of the creator's; secrets are shown once and never re-exposed (list returns a hash-free projection). | `internal/server/server.go` `handleTokens`/`handleRevokeToken` |

## High — availability & abuse

| # | Issue | Fix | Location |
|---|-------|-----|----------|
| 7 | **No rate limiting:** login was brute-forceable; agent and API endpoints were floodable. | New per-IP token-bucket limiter. Login 5/min (burst 5), agent 10/s (burst 40), API 30/s (burst 60). Idle buckets evicted; key cap bounds memory. | `internal/ratelimit/`, wired in `withAuth`/`withAgentLimit`/`handleLogin` |
| 8 | **Rate-limit key spoofing:** trusting `X-Forwarded-For` blindly lets clients forge the key. | `clientIP` uses `RemoteAddr` by default; proxy headers (`CF-Connecting-IP`, `X-Forwarded-For`) are honored only when `-trust-proxy` is set. | `internal/server/server.go`, `cmd/lattice-server` |
| 9 | **Sessions in memory only:** lost on restart; unbounded growth under churn. | Sessions persist in the store (survive restart, support server-side revocation), expired entries pruned on write, capped at 4096 with oldest-eviction. | `internal/store/store.go`, `internal/server/server.go` |

## Medium — injection & input validation

| # | Issue | Fix | Location |
|---|-------|-----|----------|
| 10 | **nft injection:** `WireGuardCIDR` was interpolated into the ruleset unvalidated; `InterfaceName` was computed but never used. | CIDR is parsed and re-emitted canonically (IPv4-only); interface name is validated against an `IFNAMSIZ`-bounded charset and now scopes the public-port rule via `iifname`. | `internal/network/nft.go` |
| 11 | **Storage key collision:** KV/static keys compose `bucket+"/"+key`; a `/` in either half lets one record masquerade as another. | `validateStorageName` rejects empty, over-long, slash-bearing, and control-character names for KV bucket+key and static bucket. | `internal/server/server.go` |
| 12 | **Worker capability bypass:** any `worker:route` worker could read any KV via `{{kv:...}}` regardless of `kv:read`. | KV interpolation is gated on the worker declaring `kv:read`; otherwise references resolve to empty. | `internal/worker/worker.go` |

## Medium — transport, headers, observability

| # | Issue | Fix | Location |
|---|-------|-----|----------|
| 13 | **No TLS option / no server timeouts.** | `-tls-cert`/`-tls-key` enable HTTPS; `http.Server` now sets read/write/idle/header timeouts; a warning prints when serving plain HTTP without secure cookies. | `cmd/lattice-server/main.go` |
| 14 | **Missing HSTS; weak CSP.** | HSTS emitted when secure cookies are on; CSP tightened with `base-uri 'none'`, `frame-ancestors 'none'`, `object-src 'none'`, `form-action 'self'`. | `internal/server/server.go` `securityHeaders` |
| 15 | **Silent audit drops:** `_ = audit.Record(...)` discarded errors; logout was not audited. | All audit writes go through `recordAudit`, which logs failures; logout now emits an audit event. | `internal/server/server.go` |
| 16 | **State in world-writable /tmp by default.** | Default data path moved to the per-user config dir. | `cmd/lattice-server/main.go` |

## Agent & metrics

| # | Issue | Fix | Location |
|---|-------|-----|----------|
| 17 | **Hang risk:** agent used `http.DefaultClient`/`http.Post` with no timeout — a black-holed server wedges the poll loop. | Shared `http.Client` with a 30s timeout for every request. | `lattice-node-agent/cmd/lattice-agent/main.go` |
| 18 | **Bogus metric:** `CPUPercent` reported `runtime.NumGoroutine()`. | Real busy-percent computed from `/proc/stat` deltas between collections; pure `cpuBusy` helper is unit-tested. | `lattice-node-agent/internal/metrics/metrics.go` |

## New capabilities delivered

- **PAT lifecycle:** `POST/GET /api/tokens`, `POST /api/tokens/revoke` (scope `token:admin`), scoped + revocable, secret shown once.
- **Multi-channel notifications:** dependency-free `internal/notify` (Telegram, Bark, Discord, generic webhook) with a fan-out dispatcher; admin-gated `POST /api/notify/test` (scope `notify:send`).
- **Credential encryption at rest (resolves F-P2-1):** stdlib AES-256-GCM envelope encryption of the reversible secrets in the state file — `User.TOTPSecret`, `DDNSProfile.CFAPIToken`/`WebhookHeaders`, `NotifyChannel.Config[*]` — at the store persistence boundary; in-memory state stays plaintext so handlers are unchanged. Master key resolves from `LATTICE_MASTER_KEY` / `-master-key-file` / auto-generated `<dataDir>/master.key` (`0600`); fail-closed on wrong/lost key; transparent migration of legacy plaintext. Zero new deps. `internal/secret/`, `internal/store/crypto.go`. Design + adversarial review in `docs/adr-002-encryption-at-rest.md`.
- **OIDC / SSO login (Phase A1, ADR-001 D7–D9):** provider-agnostic OAuth2 auth-code + PKCE(S256) + state + nonce; one callback URL with the provider bound via stored state; ID-token verified by go-oidc (signature/issuer/audience/expiry). Identity mapping is allowlist-gated with no auto-provision (durable link keyed on the vetted **ProviderID**; first login requires verified email + allowed domain + a pre-existing local user). Client secret is secret-at-rest + write-only via the admin API (scope `oidc:admin`). **Login-CSRF defense** via an HttpOnly/SameSite=Lax browser-binding cookie; SSO honors local 2FA (no silent bypass); timeout-bounded IdP calls. **First external deps** (`golang.org/x/oauth2`, `github.com/coreos/go-oidc/v3`, transitive `go-jose/v4`), justified by ADR-001 D8. `internal/oidc/`, `internal/server/server_oidc.go`, `-public-url`. Design + adversarial review (FIX-FIRST, 5 fixes) in `docs/iterations/iter-001-oidc-sso.md`.
- **Enforced operator TOTP policy (F-P2-2 partial):** `lattice-server`
  supports `LATTICE_REQUIRE_TOTP=1` / `-require-totp`, which constrains
  interactive password/SSO sessions to `/api/me`, logout, and TOTP
  enroll/activate until the user has active TOTP. Non-setup APIs fail with the
  stable `mfa_required` code and a deny audit event. Bearer PATs remain scoped
  automation credentials and are not treated as interactive sessions.
- **Node-token lifecycle hardening:** node token rotation clears stale last-used
  telemetry; successful bearer auth records write-throttled
  `token_last_used_at`; optional per-node `agent_source_allowlist` accepts
  exact IPs/CIDRs only and evaluates proxy headers only under explicit
  `TrustProxy`.
- **Audit WAL end-truncation hardening:** file-backed stores now keep
  `state.json.audit-anchor` beside `state.json.audit-wal`. The anchor is updated
  with a crash-recoverable pending/committed protocol and is checked on server
  open plus `/api/audit/verify`, so deleting records from the end of the WAL no
  longer verifies silently. The dashboard Audit panel can export a verified
  off-box head record for manual custody, and the server can periodically POST
  the verified anchored head to an HTTPS webhook using the guarded outbound HTTP
  client. Remote immutable retention, rollback alerting, and restore drills
  remain separate production-hardening work.
- **Task execution posture visibility:** node agents now report a
  `task_sandbox` runtime profile in metrics heartbeats. Operators can see
  disabled execution, root-refused execution, Linux rlimit/process-group
  hardening, and any root/non-Linux warning from the node detail page. This does
  not replace OS-level isolation: non-root service units, cgroup policy, and
  seccomp/AppArmor/bubblewrap-style isolation remain production-hardening work.

## Test coverage added

`internal/ratelimit` (burst/refill/isolation/eviction/concurrency), `internal/auth`
(token split/format, hash round-trip, dummy verify), `internal/network` (CIDR +
interface validation, canonicalization, injection rejection), `internal/notify`
(per-channel delivery, error propagation, dispatcher isolation), `internal/server`
(scope fix, slash rejection, session-survives-restart, logout invalidation, full
PAT lifecycle, hash never listed, login rate limiting), `metrics` (cpuBusy table).

## CI

Per-repo workflows (`gofmt`, `go vet`, `go test -race -cover`, `gosec`,
`govulncheck`) plus an integration workflow in the meta repo that reconstructs
the `go.work` workspace and runs `make test`/`make build`. Dashboard runs
`node --check`.

## Deployment guidance (unchanged but reinforced)

- Bind the control plane to a WireGuard/private address; expose only via a
  hardened reverse proxy or Cloudflare Tunnel.
- Run with `-secure-cookies` (enables HSTS) behind TLS, and `-trust-proxy` only
  when a trusted proxy sets the client-IP header.
- Enable `-require-totp` / `LATTICE_REQUIRE_TOTP=1` for internet-adjacent or
  multi-operator deployments. Roll out by confirming at least one administrator
  can complete TOTP enrollment from the Security page before relying on the
  policy for all operators.
- Run agents non-root; keep `-allow-exec=false` unless the node accepts the risk.
- Set a strong `LATTICE_ADMIN_PASSWORD`; rotate PATs with least-privilege scopes
  and per-server allowlists.
