# Lattice — Program Review, Feature Evaluation & Development Roadmap

> Date: 2026-06-12 · Scope: the six-repo `LatticeNet/*` ecosystem
> Author of this review: code audit pass over the 2026-06-12 working tree
> (server, sdk, agent, dashboard, plugin-template, and umbrella docs).
> Disposition of the reviewed change set: **strong foundation; continue with
> bbolt durability before concrete plugin artifact execution.** All modules
> build, `go vet` clean, `gofmt` clean, `go test -race` green, dashboard
> `node --test` 31/31.
>
> 2026-06-13 closeout update: bbolt import/export, JSON migration/rollback CLI,
> and record-level APIs for current state buckets, including secret-bearing
> identity/auth/DDNS/notify/OIDC records, are now documented as the current
> storage baseline.
> Runtime still defaults to encrypted JSON.
>
> 2026-06-13 network-policy update: Design 05 now has an egress-only committed
> nft apply path (iter-021): `/api/netpolicy/plan`, plan-hash approvals,
> agent-side `nft -c` + 60s rollback watchdog, unauthenticated `/api/health`
> selfcheck, and result-backed applied/failed status. At iter-021 close,
> ingress, domain-backed nft sets, IPv6, and the geo-map remained later work.
>
> 2026-06-13 map update: iter-022 shipped operator-owned `NodeGeo` CRUD and the
> dashboard Fleet Map. At iter-022 close, remaining Design 05 work was ingress,
> domain-backed nft sets, IPv6, policy-graph SVG, bulk geo import, and map
> overlays.
>
> 2026-06-14 graph update: iter-023 shipped the dashboard policy-graph SVG. At
> iter-023 close, remaining Design 05 work was ingress, domain-backed nft sets,
> IPv6, bulk geo import, and map overlays.
>
> 2026-06-14 guard update: iter-024 shipped rollback-protected Network Guard
> apply for `lattice_guard` and composes enabled ingress NetPolicy rules into
> that single input chain. Remaining Design 05 work is domain-backed nft sets,
> IPv6, compiler-vs-graph parity tests for ingress, bulk geo import, and map
> overlays.
>
> 2026-06-14 approval-safety update: iter-025 made `plan_sha256` mandatory for
> pending high-risk approvals and added dashboard-side SHA-256 calculation over
> the visible plan text. Missing hashes now fail before any apply task is queued.
>
> 2026-06-14 domain-set update: iter-026 removed the IPv4-literal-only
> `public_url` constraint for `nftpolicy` control-plane selfcheck. HTTPS
> hostnames now render a `lattice_control4` named set and the apply task
> resolves/fills it before selfcheck. Periodic refresh landed in iter-028,
> IPv6 parity landed in iter-029, and egress domain-valued policy remotes landed
> in iter-031.
>
> 2026-06-14 agent-updater update: iter-027 moved the `lattice_control4`
> apply-time mutation into `lattice-agent --update-nft-domain-set`, replacing
> shell DNS parsing with Go resolution/filtering plus direct `nft` argv calls.
>
> 2026-06-14 periodic-refresh update: iter-028 installs a systemd timer for
> domain-backed `nftpolicy` control-plane set refresh and removes stale timer
> artifacts when a later approved apply no longer uses a hostname.
>
> 2026-06-14 IPv6-control update: iter-029 adds `lattice_control6`, updates the
> agent domain-set helper to refresh IPv4 and IPv6 sets from one resolver result,
> and accepts IPv6 literal `public_url` values for `nftpolicy` control-plane
> selfcheck.
>
> 2026-06-14 operator-IPv6 update: iter-030 allows reviewed IPv6 CIDR/node
> `NetPolicy` remotes and compiles them to explicit `ip6 daddr` / `ip6 saddr`
> nft statements.
>
> 2026-06-14 operator-domain update: iter-031 allows reviewed egress domain
> `NetPolicy` remotes. The compiler renders deterministic v4/v6 nft named sets,
> approval metadata binds host/set pairs, and the node apply/refresh script
> updates them through `lattice-agent --update-nft-domain-set`. Ingress domain
> sources remain intentionally unsupported.
>
> 2026-06-14 cron-refresh update: iter-032 adds `/etc/cron.d` fallback
> scheduling for domain-backed `nftpolicy` refresh scripts on non-systemd Linux
> hosts. Systemd remains preferred when available; later no-domain applies
> remove both timer and cron artifacts.

---

## 1. What Lattice is (grounded in the code)

A **security-first server probe + monitoring + lightweight cluster control
plane**, deliberately split into six independent repos that compose through a
shared contract:

| Repo | Role | Trust position |
|------|------|----------------|
| `lattice-server` | Control plane: authN/Z, RBAC, node registry, task queue, audit, DDNS, notify, monitors, WireGuard/nft/tunnel plan→approve→apply | **Sole policy decision point** |
| `lattice-node-agent` | Minimal dial-out executor: metrics, leased task exec, monitor probes, SSH-login events | **Least-trust executor**, no inbound ports |
| `lattice-sdk` | Shared models + `proto` contract + contract tests | **Boundary / wire contract** |
| `lattice-dashboard` | Vue 3 static operator console under strict CSP | **Render-only**, no security decisions |
| `lattice-plugin-template` | Plugin author kit: manifest, capability tiers, signing, trust policy | **Author guidance + security spec** |
| `lattice` | `go.work` workspace, docs, build glue | Aggregator |

**Keep the six-repo split.** The trust boundaries are clean and mature: the
agent decides nothing, the server decides everything, the dashboard renders, the
SDK is the contract. This is the right shape to grow into; do not collapse it.

---

## 2. Security posture — what is genuinely strong

The 2026-06 change set is a real, well-built security layer, not a checkbox pass:

1. **Three-plane auth, correctly separated.** Humans use cookie session + CSRF
   (`SameSite`, `Secure` opt-in); automation uses PAT bearer; agents use the
   node token **only** in `Authorization: Bearer` — removed from request bodies
   and never in URLs/query (so it cannot leak via access logs, proxy caches, or
   captured request bodies). CSRF is required for cookie+unsafe-method, and
   correctly skipped for bearer (not CSRF-able).
2. **Least privilege, per node.** Every list endpoint (nodes, tasks, results,
   monitors, ddns, tunnels, approvals) filters by `rbac.Allows(p, scope,
   node)`. `task:read` is split from `task:run`. Token creation enforces
   `serverAllowlistSubset` — a token cannot mint a child with a broader node
   allowlist than its own (no allowlist privilege escalation). Restricted tokens
   cannot create or delete fleet-wide (`assign_all`) monitors.
3. **Defense in depth on output.** Secret-free view structs hide
   `token_hash` / `password_hash` / `cf_api_token` / webhook config (only key
   *names* are exposed). Tasks expose `script_sha256` + size, not the raw script,
   to read-only viewers. 5xx/502 messages are sanitized to generic text — proven
   by a test that asserts internal paths and secret values never reach the client
   (closes the "error message as SSRF/internal-detail oracle" vector).
4. **Dangerous ops gated by plan → approve → apply**, with: approval
   **idempotency** (an already-decided approval is never re-applied); a
   **SHA-derived, collision-checked heredoc delimiter** that closes a real shell
   breakout where crafted plan content containing the old fixed `EOF` marker could
   inject commands into the apply script; the WireGuard **private key never
   reaching the server** (placeholder substituted node-side at apply); `nft -c`
   dry-check before load.
5. **Outbound SSRF guard, actually wired.** `internal/outbound` blocks
   loopback/private/link-local/multicast/metadata (169.254.169.254)/special-use
   ranges, **re-resolves at dial time** (anti-DNS-rebinding TOCTOU), and disables
   environment proxies. It is the HTTP client behind DDNS (Cloudflare + webhook)
   and all notify channels — not dead code.
6. **Agent execution hardening.** Tasks run an allow-listed interpreter
   (`sh/bash/python3/node`) against a **script file** (not `sh -c <string>`),
   with an allow-listed env, context timeout, capped output buffers, and an
   isolated workdir. Server-side: interpreter allowlist + timeout bounds
   (1–600s) + output bounds (≤256 KiB) + script size cap (64 KiB). **Lease
   integrity**: a result is accepted only if the task is `leased`, leased *to
   this node*, with a matching non-empty `lease_id`; the lease id is then zeroed
   before storage. Reported public IPs are validated as globally routable
   (spoofed private/special IPs rejected).
7. **Observability for forensics.** Every request carries an `X-Lattice-Request-ID`;
   audit events carry a correlation id and are queryable
   (action/decision/node/actor/token/scope/correlation, bounded pagination).
   Audit-sink failures are logged, not silently dropped. File-backed stores also
   append every audit event to a hash-chained, fsync'd audit WAL with a local
   sidecar head anchor that verifies on open and via `/api/audit/verify`.
8. **Plugin trust model is now load-bearing up to the execution boundary.**
   Capability **risk tiers** (read/write/host); `wasm`/`worker` may never hold
   host-risk; host-risk requires a `system` plugin; strict manifest decode
   (`DisallowUnknownFields` + no trailing JSON); **Ed25519 signature** over a
   canonical payload that includes `version` (no silent downgrade) and the sorted
   capability set (no capability substitution); artifact `digest_sha256` binding;
   trusted-publisher policy; startup loader wired to `-plugin-dir` + trust policy;
   lifecycle registry/API/UI; runtime manager + runner contract.

**STRIDE quick read:** Spoofing — strong (bearer/session separation, signed
plugins, OIDC state/nonce/PKCE). Tampering — strong on wire/plan and detectable
for audit WAL edits plus local end-truncation; off-box head anchoring is still
needed for stronger host-compromise evidence.
Repudiation — materially improved by the WAL, still needs retention/remote
shipping. Info-disclosure — strong (view structs, sanitized errors, at-rest
encryption for reversible secrets). DoS — partial (login/API/agent rate limits,
2FA per-user limiter, output/timeout caps; no global request quota and JSON
whole-file writes remain a ceiling). Elevation — strong (allowlist subset,
per-node RBAC, capability tiers).

---

## 3. Findings from this review

### Resolved / landed by the 2026-06-12 follow-up
- **Trust-policy secure default (F-P0-2 fixed 2026-06-12)** (`internal/plugin`):
  inverted `RequireSignatureForHostRisk` → `AllowUnsignedHostRisk` so the
  zero-value `TrustPolicy{}` is fail-closed — host-risk plugins require a
  trusted-publisher Ed25519 signature unless an operator explicitly opts out
  (dev only). New tests cover the fail-closed default and the opt-out.
- **Plugin trust is now in the request/startup path (F-P0-1 fixed
  2026-06-12).** `-plugin-dir` + `-plugin-trust` startup loading verifies signed
  bundles before lifecycle registration; `/api/plugins/verify` exposes the same
  verifier to operators; rejected bundles are audited and skipped.
- **Plugin lifecycle + runtime foundation landed.** Active/disabled lifecycle
  state is persisted and shown in the dashboard. Activating a verified plugin
  arms a capability-scoped `plugin.Broker` through a bounded `plugin.Runner`
  contract. The default runner is `noop`, so no artifact code executes yet.
- **Audit-at-rest integrity improved.** File-backed stores append every audit
  event to a hash-chained, fsync'd `.audit-wal`; chain verification fails loudly
  on tampering and is exposed through `/api/audit/verify`.
- **Credential encryption at rest (F-P2-1 fixed).** AES-256-GCM envelope
  encryption now covers reversible secrets at the store boundary, including
  OIDC client secrets.
- **OIDC/SSO + dashboard UI landed.** Backend uses auth-code + PKCE + state +
  nonce and local account allowlisting. The dashboard renders provider buttons,
  handles `sso_error` / `totp_challenge`, and provides an `oidc:admin` provider
  panel with write-only secrets.
- **TOTP 2FA landed.** Enrollment, activation, login challenge, recovery codes,
  auditing, and per-user attempt limiting are implemented. Policy enforcement
  and WebAuthn remain future work.
- **Dashboard `escapeHtml` hardening** (`assets/app.js`): added backtick to the
  escape set and escaped the server-generated id in the `data-approval`
  attribute, for parity with the already-escaped `data-audit-correlation`.
  Defense-in-depth; dashboard tests are now 31/31.

### Verified and intentionally NOT changed (would have been wrong)
- *"Add `json:"-"` to `PasswordHash`/`TokenHash`."* — **Rejected.** The store
  persists whole `model.User/Token/Node` via `json.MarshalIndent(state)`; `json:"-"`
  would drop every hash on save and lock out all auth after restart. The real
  boundary is the view structs, already covered by `TestTokenListHidesHash` and
  `TestNodeListHidesTokenHash`.
- *Audit "class attribute injection" in the dashboard* — **False positive.** The
  `class` is `decision === "deny" ? "danger" : "warn"`, a ternary that emits
  literals, never raw input; the text is `escapeHtml`'d.
- *`manifest.json` publisher inconsistency* — left as is; the README intentionally
  documents the example with `publisher: "latticenet"` plus a matching
  trust-policy example. It is a skeleton you sign at build time.

### Open findings → tracked in the roadmap (not patched in isolation)
- **F-P0-3 follow-up · Audit WAL needs remote retention and restore drills.**
  The WAL now detects edit/reorder/gap/mid-truncation, a local sidecar anchor
  catches end-truncation on the same host, and the dashboard can export a
  verified off-box head record for manual custody. The server can also
  periodically POST the verified anchored head to an operator-controlled HTTPS
  webhook. Remote immutable retention, rollback alerting, and backup/restore
  drills are still open.
- **F-P1-2 · Storage will not scale.** `Save()` re-serializes the entire state
  and `rename()`s on every mutation under one global mutex → O(state) write
  amplification, no concurrency, no indices. Fine for tens of nodes; a ceiling
  beyond that. The decided replacement is bbolt, not SQLite, to preserve zero
  CGo. Bucketized import/export, JSON migration/rollback, and current-state
  record-level APIs have landed; runtime cutover and backup/restore drills are
  still pending.
- **F-P1-3 · Task execution is bounded but not OS-sandboxed.** The agent has
  interpreter allowlists, env limits, timeouts, output caps, and isolated
  workdirs. Linux agents also enforce process-group cleanup plus rlimits for CPU,
  file size, process count, address space, and data segment size. Runtime
  heartbeats now report a `task_sandbox` profile so operators can see disabled
  execution, root-refused execution, and the Linux rlimit/process-group hardened
  path in the dashboard. Linux task interpreters now also run with
  `no_new_privs`, so setuid/file-capability privilege gain is blocked. Linux
  agents can now enforce configured cgroup v2 memory, pids, and CPU caps per
  task, failing closed if the requested cgroup cannot be prepared or joined.
  The installer now supports an optional non-root systemd service identity via
  `LATTICE_AGENT_RUN_USER`, with state ownership adjusted while the token env
  file remains root-only. The server now also has a fleet kill switch
  (`LATTICE_TASK_EXEC_DISABLED=1` / `-task-exec-disabled`) that blocks new task
  queueing and agent leases while preserving already leased task-result intake.
  It still lacks hard workdir filesystem isolation and seccomp/bubblewrap.
- **F-P2-2 · Operator MFA policy is partially complete.** TOTP and an optional
  server-enforced `-require-totp` policy now exist, but passkey/WebAuthn support
  and richer admin-facing rollout/reporting workflows remain open.
- **F-P2-3 · Plugin artifact execution remains intentionally disabled.** The
  loader, lifecycle, broker, and runner contract are ready, but concrete
  system/worker/wasm runners need resource limits, cancellation, log/output caps,
  isolation, and adversarial tests before any artifact code runs.

### Closed since this review
- **F-P1-1 · Node token lifecycle.** Rotation, write-throttled
  `token_last_used_at` telemetry, and per-node `agent_source_allowlist`
  exact-IP/CIDR enforcement have all landed. The dashboard can set the
  allowlist during enrollment or later from the node detail page; proxy headers
  count only under explicit `TrustProxy`.
- **F-P2-2 partial · Enforced TOTP policy.** `LATTICE_REQUIRE_TOTP=1` /
  `-require-totp` gates interactive sessions to `/api/me`, logout, and TOTP
  enroll/activate until the account has active TOTP. Other session-backed APIs
  return `mfa_required` and record a deny audit event; bearer PAT automation is
  unaffected.
- **F-P3-1 · Node-scoped `audit:read` for restricted tokens.** `audit:read`
  calls now respect non-global token `server_allowlist` values: restricted
  tokens see only audit rows whose `node_id` is inside their allowlist, while
  unrestricted operators keep the full audit stream.

---

## 4. Feature evaluation (functionality · usability · performance)

### 4.1 Functionality — broad and coherent
Delivered and tested: node enroll/registry, leased task exec, KV, static
objects, workers, filtered/paginated/correlated audit, DDNS (Cloudflare API v4 +
webhook, SSRF-guarded), notify channels, monitors (TCP/HTTP + history) with
per-node assignment, WireGuard mesh planning, Cloudflare Tunnel planning, nft
planning, PAT management, TOTP 2FA, OIDC/SSO, signed plugin loading, lifecycle
management, host-API broker, and a no-execution runtime runner contract. This
already exceeds a pure monitor (e.g. Nezha) by adding a **control-plane +
approval layer** that Nezha has no equivalent of.

**Gaps vs. the original vision:** sing-box/xray deploy + subscription, sub-store,
nginx + domain/path one-click static sites, concrete plugin artifact execution,
ICMP monitors, WireGuard auto-keygen, and the regional-aggregator ("组长") tier
in the *server* topology (the network design has it; the control plane is still
star).

### 4.2 Usability — backend ahead of the console
The dashboard is clean, CSP-strict, and has a genuinely nice ops touch (stable
error codes + request-id "trace this request" across the audit log). It now also
surfaces SSO provider management and plugin lifecycle/runtime health. But many
backend surfaces remain API-only — **DDNS, monitors (+ latency trends), notify,
WireGuard, tunnels, PAT management, audit WAL verification, and richer runtime
drill-through have no first-class UI yet.** This is the highest-leverage
usability gap.

### 4.3 Performance — correct shape, known ceiling
Monitoring is **agent-push** (O(N), not O(N²)) — the right design, and it
matches the hub decision (metix-hk primary). The ceiling is the **whole-file
JSON store under a global mutex**: every write re-encodes all state. Acceptable
for the current ~30-node fleet; it must change before the fleet or the audit
volume grows.

---

## 5. Development roadmap

Four tracks run in parallel — **Security (S)**, **Functionality (F)**,
**Usability (U)**, **Performance/Reliability (P)** — sequenced into phases. The
ordering principle: *move hot persistence off the JSON store before widening
artifact execution, and keep every new execution path behind brokered
capabilities, deadlines, and audit.*

### Phase 0 — Security baseline closure (mostly delivered)
- **S** Plugin loader + trust policy + lifecycle + no-exec runtime contract.
  *(Delivered 2026-06-12.)*
- **S** Append-only, tamper-evident audit WAL. *(Delivered 2026-06-12; local
  sidecar head anchoring and HTTPS webhook head shipping delivered after that;
  remote retention/alerting policy pending.)*
- **S** Node-token lifecycle. *(Rotation, `token_last_used_at` telemetry, and
  optional source-IP allowlist delivered.)*
- **S** Operator MFA. *(TOTP + optional enforced TOTP policy delivered;
  WebAuthn/passkeys and richer rollout reporting pending.)*
- **Gate:** until bbolt, runner isolation, and full MFA rollout close, treat Lattice as
  **single-operator / trusted fleet behind WireGuard or CF Access** — not an
  internet-exposed multi-tenant control plane.

### Phase 1 — Make what exists durable
- **P** Replace the whole-file JSON store with **bbolt**: per-entity writes,
  indices on node/task/monitor/plugin/audit, bounded audit/monitor retention,
  JSON export/import, and a tested migration path from the current encrypted
  JSON file. *(F-P1-2; highest backend leverage. Import/export, rollback CLI,
  and current-state record-level buckets delivered; default runtime store is
  still JSON.)*
- **S/P** Move ephemeral high-churn records (OIDC auth states, TOTP challenges,
  sessions, monitor history) off whole-file rewrites.
- **S** Audit WAL remote head custody: periodically ship the anchored head hash
  so end-truncation remains detectable after host compromise. *(HTTPS webhook
  shipping and manual dashboard export exist; remote immutable retention and
  alerting remain operator/deployment work.)*

### Phase 2 — Make what exists usable
- **U** Dashboard coverage for DDNS, monitors (with latency trend sparklines),
  notify channels, WireGuard plan/approve, tunnels, PAT, audit WAL verification,
  and runtime audit drill-through — dependency-free, same strict CSP.
- **S** Task-exec sandbox on the agent: runtime task-sandbox posture reporting
  has landed; per-task cgroup v2 memory/pids/CPU caps are configurable and
  fail closed. Linux task interpreters run with `no_new_privs`. Optional
  non-root systemd units are installable through `LATTICE_AGENT_RUN_USER`. Hard
  workdir isolation and optional seccomp/bubblewrap remain. A server-side fleet
  kill switch has landed. *(F-P1-3)*

### Phase 3 — Platform expansion (the original vision), through the approval flow
- **F** sing-box/xray deploy + subscription management; sub-store; nginx +
  domain/path one-click static sites (compose existing static buckets with
  tunnel/nginx) — every one shipped as a `plan → approve → apply` plugin so the
  audit + approval guarantees extend to them for free.
- **F/S** Concrete plugin runners: start with a constrained system runner, then
  wasm (`wazero`) only after resource limits, cancellation, egress policy,
  log/output caps, and adversarial tests exist.
- **P** Regional aggregator / "组长" tier in the server topology: hierarchical
  monitoring + relay through the metix-hk hub so the control plane matches the
  network design and scales sub-linearly in cross-node probes.

### Phase 4 — Operate at scale / enterprise
- **S** mTLS for agents; in-server TLS (autocert) option; WebAuthn/passkeys and
  richer MFA rollout reporting. *(F-P2-2 remainder)*
- **P** HA control plane: replicated store + leader election, or stateless server
  + external DB; readiness/liveness; backpressure and a global request quota.
- **Ops** First-class observability: Prometheus metrics, structured logs, tracing,
  SLO/error-budget on probe freshness and apply latency.
- **Compliance** Audit retention policy, per-node `audit:read` scoping (F-P3-1),
  RBAC review tooling, SBOM + **signed release binaries** (you already sign
  plugins — extend cosign-style signing to server/agent artifacts).

### Cross-cutting engineering practices
- **CI gate per repo:** `go test -race` + `vet` + `gofmt` + `gosec`, dashboard
  `node --test`, and the SDK **proto contract test** as a required check.
- **Release discipline:** tag `lattice-sdk` first, then dependents; semver the
  proto/wire contract; compatibility tests across one minor version.
- **Threat model doc** (STRIDE) per trust boundary; keep `SECURITY-HARDENING.md`
  as the running changelog and this file as the standing plan.

---

## 6. One-line verdict
A genuinely security-first foundation with clean trust boundaries and strong,
*tested* controls. The next unit of value is **not more breadth** — it is moving
state to bbolt, then giving the console parity with the backend, then allowing
plugins to execute behind the runner contract. Build outward only after those
durability and isolation gates are closed.
