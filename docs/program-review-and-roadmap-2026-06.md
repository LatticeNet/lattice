# Lattice — Program Review, Feature Evaluation & Development Roadmap

> Date: 2026-06-12 · Scope: the six-repo `LatticeNet/*` ecosystem
> Author of this review: code audit pass over the 2026-06-12 working tree
> (server +2.4k LOC, sdk, agent, dashboard, plugin-template manual changes).
> Disposition of the reviewed change set: **strong — merge after the small
> dashboard hardening already applied.** All modules build, `go vet` clean,
> `gofmt` clean, `go test -race` green (server 67% / network 95% / rbac 87% /
> wireguard 84% / cftunnel 82% / ratelimit 85%), dashboard `node --test` 12/12.

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
| `lattice-dashboard` | Dependency-free vanilla-JS console under strict CSP | **Render-only**, no security decisions |
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
   Audit-sink failures are logged, not silently dropped. Login is rate-limited.
   TLS is sane (HSTS, `-secure-cookies`), proxy header trust gated behind
   `-trust-proxy`.
8. **Plugin trust model (library).** Capability **risk tiers** (read/write/host);
   `wasm`/`worker` may never hold host-risk; host-risk requires a `system`
   plugin; strict manifest decode (`DisallowUnknownFields` + no trailing JSON);
   **Ed25519 signature** over a canonical payload that includes `version`
   (no silent downgrade) and the sorted capability set (no capability
   substitution); artifact `digest_sha256` binding; trusted-publisher policy.

**STRIDE quick read:** Spoofing — strong (bearer/session separation, signed
plugins). Tampering — strong on wire/plan, **weak on audit-at-rest** (see 4.2).
Repudiation — partial (audit exists but is not tamper-evident). Info-disclosure —
strong (view structs, sanitized errors). DoS — partial (login rate-limit,
output/timeout caps; no global request quota). Elevation — strong (allowlist
subset, per-node RBAC, capability tiers).

---

## 3. Findings from this review

### Applied in this pass
- **Trust-policy secure default (F-P0-2 fixed 2026-06-12)** (`internal/plugin`):
  inverted `RequireSignatureForHostRisk` → `AllowUnsignedHostRisk` so the
  zero-value `TrustPolicy{}` is fail-closed — host-risk plugins require a
  trusted-publisher Ed25519 signature unless an operator explicitly opts out
  (dev only). New tests cover the fail-closed default and the opt-out; READMEs
  updated. (Loader wiring — F-P0-1 — still pending; this makes it secure *when*
  wired.)
- **Dashboard `escapeHtml` hardening** (`assets/app.js`): added backtick to the
  escape set and escaped the server-generated id in the `data-approval`
  attribute, for parity with the already-escaped `data-audit-correlation`.
  Defense-in-depth; tests still 12/12.

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
- **F-P0-1 · Plugin trust apparatus is not load-bearing.** `internal/plugin`
  (Ed25519 + capability tiers) is verified library code but is imported by
  nothing outside tests; there is no plugin loader/runtime. The security model
  exists on paper, not in the request path.
- **F-P0-2 · Fail-open trust default — FIXED 2026-06-12.** `TrustPolicy{}`
  previously accepted unsigned host-risk plugins. Inverted to a secure-by-default
  field (`AllowUnsignedHostRisk`, zero value = signature required); `plugin_test.go`
  and both READMEs updated; fail-closed-default + opt-out tests added. The control
  is now secure *when* the loader wires it (F-P0-1).
- **F-P0-3 · Audit-at-rest is not tamper-evident or crash-durable.** Audit lives
  in memory and is rewritten as part of a whole-file JSON dump; a compromised or
  crashing server can lose or rewrite history. Repudiation + integrity gap.
- **F-P1-1 · Node token lifecycle is thin.** No rotation, no last-used, no
  per-node agent source-IP allowlist; long-lived bearer secrets.
- **F-P1-2 · Storage will not scale.** `Save()` re-serializes the entire state
  and `rename()`s on every mutation under one global mutex → O(state) write
  amplification, no concurrency, no indices. Fine for tens of nodes; a ceiling
  beyond that.
- **F-P1-3 · Task execution is unsandboxed.** The agent often runs as root (nft,
  wg-quick); task exec has env/timeout/output limits but no non-root unit, no
  cgroup CPU/mem cap, no seccomp/bubblewrap, no kill switch. RCE-by-design that
  needs isolation before any semi-trusted task author.
- **F-P2-1 · Secrets at rest are plaintext** in the JSON state
  (`cf_api_token`, webhook/notify config). Hashes are hashed; these are not.
  **RESOLVED 2026-06-12** — AES-256-GCM envelope encryption at the store
  boundary (`internal/secret/`, `internal/store/crypto.go`); see
  `adr-002-encryption-at-rest.md`.
- **F-P2-2 · No operator MFA; single bootstrap admin password.**
- **F-P3-1 · `audit:read` is global**, not node-scoped for restricted tokens.

---

## 4. Feature evaluation (functionality · usability · performance)

### 4.1 Functionality — broad and coherent
Delivered and tested: node enroll/registry, leased task exec, KV, static
objects, workers, filtered/paginated/correlated audit, DDNS (Cloudflare API v4 +
webhook, SSRF-guarded), notify channels, monitors (TCP/HTTP + history) with
per-node assignment, WireGuard mesh planning, Cloudflare Tunnel planning, nft
planning, PAT management. This already exceeds a pure monitor (e.g. Nezha) by
adding a **control-plane + approval layer** that Nezha has no equivalent of.

**Gaps vs. the original vision:** sing-box/xray deploy + subscription, sub-store,
nginx + domain/path one-click static sites, a real plugin runtime, ICMP
monitors, WireGuard auto-keygen, and the regional-aggregator ("组长") tier in the
*server* topology (the network design has it; the control plane is still star).

### 4.2 Usability — backend ahead of the console
The dashboard is clean, CSP-strict, and has a genuinely nice ops touch (stable
error codes + request-id "trace this request" across the audit log). But it only
surfaces nodes/tasks/results/approvals/kv/workers/audit — **DDNS, monitors (+
latency trends), notify, WireGuard, tunnels, and PAT management have no UI yet.**
This is the highest-leverage usability gap.

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
ordering principle: *close the security baseline before widening exposure or
adding a plugin runtime.*

### Phase 0 — Close the security baseline (before any production exposure)
- **S** Wire the plugin loader to `VerifyInstallManifest`; load operator trust
  policy from config. *(F-P0-1; F-P0-2 secure default already applied.)*
- **S** Append-only, tamper-evident audit sink: hash-chained records to a local
  WAL/SQLite, with an optional async remote shipper (webhook/S3); keep the
  in-memory view as a cache. *(F-P0-3)*
- **S** Node-token lifecycle: rotation endpoint, revocation list, `last_used_at`,
  optional per-node agent source-IP allowlist. *(F-P1-1)*
- **Gate:** until Phase 0 closes, treat Lattice as **single-operator / trusted
  fleet behind WireGuard or CF Access** — not an internet-exposed multi-tenant
  control plane.

### Phase 1 — Make what exists usable and durable
- **U** Dashboard coverage for DDNS, monitors (with latency trend sparklines),
  notify channels, WireGuard plan/approve, tunnels, PAT, and audit trace —
  dependency-free, same strict CSP. *(highest usability ROI)*
- **P** Replace the whole-file JSON store with an embedded transactional engine
  (SQLite or bbolt): per-entity writes, indices on node/task/monitor, bounded
  audit retention; keep a JSON export for portability. *(F-P1-2)*
- **S** Task-exec sandbox on the agent: dedicated non-root unit, hard workdir
  isolation, cgroup CPU/mem caps, optional seccomp/bubblewrap, and a kill switch.
  *(F-P1-3)*
- **S** Encrypt secrets at rest (envelope-encrypt `cf_api_token`/notify config
  with a server key; or integrate age/Vault). *(F-P2-1)*

### Phase 2 — Platform expansion (the original vision), through the approval flow
- **F** sing-box/xray deploy + subscription management; sub-store; nginx +
  domain/path one-click static sites (compose existing static buckets with
  tunnel/nginx) — every one shipped as a `plan → approve → apply` plugin so the
  audit + approval guarantees extend to them for free.
- **F/S** Real plugin runtime: wasm host (e.g. `wazero`) and/or restricted worker
  (`goja`) that *enforces* the capability tiers and signed-install at load time
  — this is what makes `internal/plugin` load-bearing.
- **P** Regional aggregator / "组长" tier in the server topology: hierarchical
  monitoring + relay through the metix-hk hub so the control plane matches the
  network design and scales sub-linearly in cross-node probes.

### Phase 3 — Operate at scale / enterprise
- **S** mTLS for agents; in-server TLS (autocert) option; operator MFA
  (TOTP/WebAuthn). *(F-P2-2)*
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
*tested* controls. The next unit of value is **not more breadth** — it is making
the plugin trust model load-bearing, making audit tamper-evident, and giving the
console parity with the backend. Build outward (Phase 2) only after the Phase 0
security baseline is closed.
