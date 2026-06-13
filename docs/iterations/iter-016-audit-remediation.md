# Iteration 016 — Security/Stability Audit Remediation

- **Status:** Plan → Execute (2026-06-13)
- **Source:** deep 8-subsystem adversarial audit (2026-06-13), 15 verified High/Medium findings + ~30 Low/Info + 2 firsthand (gofmt CI breaker, crypto over-engineering). See §Registry.
- **Goal:** Fix every finding that carries real risk; document the rest with rationale; defer large features/refactors to their own iterations. Each FIX lands with a test where behavior changes; workspace stays green (`build/vet/test -race`, gofmt, dashboard) and CI passes.
- **Cadence (development-workflow.md):** plan (this doc) → fix in batches → verify → review → commit/push, docs updated.

## Decision legend
- **FIX** — corrected in this iteration with a regression test where behavior changes.
- **DOC** — behavior is acceptable; documented (no/again minimal code), or a known-limitation note added.
- **DEFER** — real but a feature/large refactor; gets its own iteration (listed in §Deferred), tracked in roadmap.

## Registry & decisions

### Stability / durability
| # | Sev | Decision | Item | Location |
|---|-----|----------|------|----------|
| S1 | High | **FIX** | `Save()` no fsync → crash can zero/lose entire state (default+only backend). fsync temp + parent dir; one `syncedAtomicWrite` helper; apply to migration write too. | `store.go:206-229`, `migration.go:216-226` |
| S2 | — | **FIX** | gofmt: `runtime.go` unformatted → CI red (`ci.yml:27`). | `internal/plugin/runtime.go` |
| S3 | Low | **FIX** | migration temp-file Remove+recreate race; use `O_EXCL`/keep handle. | `migration.go:144-161` |
| S4 | Low | **FIX** | `RuntimeManager.Stop` error path doesn't detach broker/runner (host access stays armed after failed disable). | `runtime.go:167-184` |
| S5 | Low | **FIX** | dashboard `refresh()` lacks `Array.isArray` guards → one bad list breaks the whole console. | `app.js:429-453` |

### Security
| # | Sev | Decision | Item | Location |
|---|-----|----------|------|----------|
| C1 | High | **FIX** | WireGuard AllowedIPs widening → mesh impersonation. Force `/32`·`/128` host routes in BuildMesh + reject non-host CIDR at ingest. | `wireguard.go:171`, `server.go:3036` |
| C2 | High | **FIX** | Plugin `kv:read/write` unscoped to shared operator KV (confused deputy). Namespace bucket by pluginID in the broker; forbid plugin-supplied bucket. | `broker.go:157-177`, `plugin_host.go:40-59` |
| C3 | Med | **FIX** | Node-enrollment escapes server-allowlist confinement (restricted `node:admin` mints unrestricted nodes). Enforce allowlist on `req.NodeID`. | `server.go:1137` |
| C4 | Med | **FIX** | TOTP code replayable within step window (no last-step). Add `User.LastTOTPStep`, reject step ≤ stored. | `auth/totp.go:53`, `server.go:885` |
| C5 | Med | **FIX** | Broker SSRF by convention only. Guard `req.URL` structurally in the broker before delegating. | `broker.go:190` |
| C6 | Low→Med | **FIX** | `http:egress` is RiskWrite → unsigned wasm plugin can egress. Promote to RiskHost (signature required). | `plugin.go:54` |
| C7 | Low | **FIX** | CSRF compared with non-constant-time `!=`. Use `subtle.ConstantTimeCompare`. | `server.go:603` |
| C8 | Low | **FIX** | Recovery-code outer path not constant-time (membership/timing leak). Fixed-count CT compares. | `store.go:862-889` |
| C9 | Low | **FIX** | 4xx echoes raw decoder/validation strings. Generic "invalid request body" for decoder 400s; keep request_id. | `server.go:3274`, `:3167` |
| C10 | Low | **FIX** | `decodeJSON` lacks DisallowUnknownFields/trailing-value/depth guard. Unify with `decodeLimitedJSON`. | `server.go:3164` |
| C11 | Low/Med | **FIX** | `trust-proxy` honors `CF-Connecting-IP`/XFF with no trusted-proxy CIDR allowlist → IP spoof defeats IP-binding+rate-limit. Add `-trusted-proxy-cidrs`; only honor headers when RemoteAddr ∈ set. | `server.go:3131` |
| C12 | Low | **FIX** | No session invalidation on 2FA-disable/password/scope change. Add `User.SecurityEpoch`; stamp into sessions; reject stale; bump on those events. | `server.go:801`, 2FA/password flows |
| C13 | Low | **FIX** | Password login per-IP only (no per-account brake). Per-user failure backoff mirroring TOTP limiter. | `server.go:761-794` |
| C14 | Low | **FIX** | OIDC→TOTP continuation drops the per-flow binding; challenge id in URL. Carry via HttpOnly cookie + bind to the flow. | `server_oidc.go:216-228` |
| C15 | Low | **FIX** | Approve step not bound to reviewed plan hash (TOCTOU). Require client to echo `sha256(plan)`; reject on mismatch. | `server.go:2709-2758` |
| C16 | Low | **FIX** | DDNS webhook headers can set Host/Authorization/Content-Length unrestricted. Map `Host:`→`req.Host`; reject hop-by-hop/Content-Length. | `ddns/webhook.go:45-55` |
| C17 | Info | **FIX** | `broker.Log` plugin-controlled level/message/fields unbounded/unsanitized. Cap sizes/count; sanitize level+fields. | `broker.go:206-220` |
| C18 | Info | **FIX** | sshwatch regex not line-anchored (forge `ssh_login`). Anchor to message start. | `agent sshwatch.go:24` |
| C19 | Low | **FIX** | Agent default `http://` + README → node token in cleartext if pointed remote. Refuse/warn non-loopback http. | `agent main.go:58` |
| C20 | Low | **FIX** | Empty Session.ID/OIDCAuthState.State collapses to constant opaque key → silent collision. Reject empty identity on encrypt/import. | `crypto.go:62,112,467` |

### Design / robustness
| # | Sev | Decision | Item | Location |
|---|-----|----------|------|----------|
| D1 | Info | **FIX** | `decryptState` mutates maps while ranging (fragile). Build fresh maps for all collections. | `crypto.go:136-186` |
| D2 | Low | **FIX** | Dead `!c.Enabled()` guards in `decrypt*Record` (unreachable from JSON path). Document as the bbolt fail-closed point + keep (bbolt calls them) — verify + comment. | `crypto.go:275-441` |
| D3 | Med | **FIX** | bbolt prunes O(n) with per-record AES-GCM decrypt just to read non-secret timestamps. Prune/evict via bucket key + plaintext ts; don't decrypt. | `bolt_state.go:1167,1238,1631,1770` |
| D4 | Info | **FIX** | `handleTunnels/Monitors/Approvals` return raw model structs. Add secret-free view types (defense-in-depth vs future fields). | `server.go:2501,1789,2488` |
| D5 | Low | **FIX** | dashboard `exit_code` interpolated without escapeHtml. Wrap it. | `app.js:480` |
| D6 | Med | **FIX** | Agent `RLIMIT_AS=512MiB` breaks node/python3 (virtual reservations). Drop/raise AS; keep RLIMIT_DATA; document cgroup as the real guard. | `taskexec.go:35` |
| D7 | Med | **DOC** | `RLIMIT_NPROC` is per-uid system-wide, not per-task. Document the semantic; PID-ns/cgroup isolation is DEFER (D-iter). | `taskexec_linux.go:73` |
| D8 | Info | **DOC** | `handleWorkerRun` runs any worker by id (workers are global). Multi-tenant scoping not a current goal — document; revisit if delegation is needed. | `server.go:1682` |
| D9 | Info | **DOC** | notify Telegram/Bark `base_url` override sends token to operator-chosen host. Operator-trusted; document. | `notify.go:88` |
| D10 | Info | **DOC** | cftunnel hostname regex rejects single-label/wildcard. Wildcard ingress not yet supported — document. | `cftunnel.go:18` |
| D11 | Low | **DOC** | Agent interpreter resolved via PATH at task time; ENOENT is per-task. Add a startup notice (light) + document; full capability-advertisement is DEFER. | `taskexec.go:91` |
| D12 | Low | **FIX-lite** | Dual bbolt store is dead-but-live (drift risk). Add a build/doc marker that it is experimental and unreviewed-against-JSON until cutover. | `bolt_state.go:73` |

### Deferred (own iterations — feature/large refactor; tracked in roadmap)
| # | Item | Why deferred |
|---|------|--------------|
| F1 | `backup`/`restore` command + drill (Phase C cutover gate) | new feature; gates bbolt runtime |
| F2 | Minimal zero-dep `/metrics` (store-save duration, RL denials, ingest) | observability feature; should precede bbolt cutover |
| F3 | `server.go` split into `server_<area>.go` | large mechanical refactor; do as its own low-risk pass |
| F4 | Real task isolation: PID namespace + cgroup v2 (`pids.max`/`memory.max`) | replaces rlimit approach; substantial agent work |
| F5 | At-rest master-key `rotate-key` tool + default key outside data dir | key-management feature |
| F6 | Bearer-ID storage-key redesign (hash instead of encrypt session/challenge/state) | behavior + migration change; current code is correct, just complex (mitigated by C20/D1) |

## Acceptance gates
- Every FIX with behavior change has a `-race` test (Go) or `node --test` (dashboard).
- `gofmt -l` empty; `go vet` clean; `go build/test -race ./...` green across all modules; dashboard tests green; CI gofmt gate passes.
- Independent review pass (subagent/workflow) on the security-critical fixes before push; must-fixes from review resolved.
- This doc's execution log + each affected doc (SECURITY-HARDENING, program-review F-list, roadmap, ADR notes) updated.

## Execution log

**Batch 1 — landed & verified (commit set 1).** Parallelized across 5 lanes (store/crypto by lead; node-agent, dashboard, network, plugin, server-core by subagents — non-overlapping files), every diff reviewed, full `GOWORK` workspace green: build + vet + `test -race` (23 Go packages, 0 races), gofmt clean, dashboard 31/31.

Done:
- **Stability:** S1 (fsync `Save()` + migration via `syncedAtomicWrite`/`writeSyncedFile`/`syncDir`), S2 (gofmt runtime.go), S3 (migration temp-race + durability), S4 (RuntimeManager.Stop detaches broker/runner on error), S5 (dashboard `Array.isArray` guards).
- **Security:** C1 (WireGuard `/32`·`/128` host routes + skip-unparseable), C2 (plugin KV namespaced to `plugin:<id>`, `/`-smuggling rejected), C3 (enroll confinement `principalHasNodeRestriction`), C4 (TOTP `ValidateTOTPStep` + compare-and-set `LastTOTPStep` under lock), C5 (broker structural egress guard), C6 (`http:egress`→RiskHost, signed-plugin exemption), C7 (CSRF `subtle.ConstantTimeCompare`), C8 (recovery-code fixed-count CT), C11 (trust-proxy CIDR allowlist), C12 (session `Epoch`/`SecurityEpoch` invalidation), C13 (per-account login backoff), C16 (DDNS webhook Host→`req.Host`, drop Content-Length), C17 (broker.Log caps/sanitize), C18 (sshwatch anchor), C19 (agent refuse non-loopback http), C20 (empty-id opaque-key guards).
- **Design/robustness:** D1 (decryptState fresh maps), D2 (per-record guard doc), D6 (RLIMIT_AS 8 GiB; keep RLIMIT_DATA), D7 (RLIMIT_NPROC per-uid doc), D11 (interpreter startup probe), D12 (bbolt EXPERIMENTAL marker + Phase-C gates).

**Batch 2 — remaining Low/Info (commit set 2, in progress):** C9 (generic 4xx decoder error), C14 (OIDC→TOTP cookie binding), C15 (approve plan-hash), D4 (tunnel/monitor/approval view types). C10 (decodeJSON DisallowUnknownFields) re-classified **DOC/DEFER**: stricter decoding risks breaking handlers that tolerate extra fields; needs a per-handler audit — deferred to a dedicated pass rather than a blanket change.

## Review outcome
Each security-critical fix reviewed against source by the lead (C1/C2/C3/C4/C6/C7/C12/C13 read and confirmed correct: constant-time compares, compare-and-set under lock, fail-closed epoch check, namespace escape rejected). Subagents ran the `-race` suite per lane; the lead ran the full workspace verify. No regressions. Deferred items recorded in §Deferred / Batch 2.
