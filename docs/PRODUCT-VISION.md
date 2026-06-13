# Lattice — Product Vision & Long-Range Plan

> The north star. Point-in-time reviews live in `program-review-and-roadmap-2026-06.md`;
> decisions live in `adr-*.md`; each build cycle is logged in `iterations/`.
> **Last updated:** 2026-06-12.

## 1. North star

**Lattice is a security-first, self-hostable control plane for a fleet of distributed nodes** — monitoring, networking (WireGuard mesh, Cloudflare Tunnel, DDNS), notifications, and an extensible plugin platform — built in pure Go with **zero CGo and a deliberately tiny dependency surface**.

The bar is not "works." The bar is **惊艳 — a product that makes a self-hoster say "this is better than the SaaS I was paying for."** That means: trustworthy by construction, effortless to operate, genuinely extensible, and visually and interactively polished enough that people *want* to keep it open.

## 2. Product pillars

| Pillar | Promise | Today |
|---|---|---|
| **P1 · Trust** | Secure by default, fail-closed, auditable, nothing to misconfigure into insecurity | Strong: RBAC, rate-limit, signed plugins (fail-closed), tamper-evident audit WAL, 2FA, at-rest encryption |
| **P2 · Identity** | Password + 2FA + SSO; the front door is frictionless and enterprise-ready | Password ✅ + TOTP 2FA ✅ + OIDC/SSO backend/UI ✅; **2FA policy + WebAuthn groundwork next** |
| **P3 · Platform** | A real plugin system — install, verify, run, and extend safely; a marketplace of official + community plugins | Manifest + signing ✅, loader ✅, preflight verify ✅, host-API broker + server adapter ✅, lifecycle registry/API/UI ✅, runtime manager + runner contract ✅; **plugin artifacts don't execute yet** |
| **P4 · Scale & durability** | Survives growth and crashes; backup/restore is a non-event | JSON state + at-rest encryption + audit WAL ✅; bbolt import/export + JSON migration/rollback CLI ✅; first record-level APIs ✅; **default store still whole-file JSON** |
| **P5 · Experience (惊艳)** | A dashboard that is fast, legible, real-time, and beautiful; onboarding that takes minutes | Functional zero-dep dashboard with SSO + plugin lifecycle panels; **many endpoints still have no UI; design layer immature** |

## 3. Honest current state (2026-06-12)

Delivered and pushed: control plane + node agent + SDK + dashboard across 6 repos; security hardening; DDNS, monitoring, notifications, WireGuard mesh, CF Tunnel; plugin manifest/signing + loader + preflight verify + host-API broker/server adapter + lifecycle registry/API + dashboard panel + runtime manager + runner contract; TOTP 2FA; tamper-evident audit WAL; node-token rotation; bounded task execution; **AES-256-GCM at-rest encryption** (ADR-002); bbolt state import/export foundation with explicit JSON migration/rollback CLI and first record-level APIs for nodes, KV, and audit events. Minimal external Go deps are currently limited to the OIDC stack approved in ADR-001 (`oauth2`, `go-oidc`, transitive `go-jose`) plus bbolt for Phase C storage; still zero CGo. `go test -race` green; dashboard tests green.

The three gaps that most separate us from 惊艳, in dependency order: **identity policy polish**, **the platform actually running plugins**, and **a storage engine that scales** — plus a **dashboard worthy of the backend**.

## 4. Phased roadmap

Each phase has an exit bar. Phases ship as tested, reviewed, committed slices (the cadence in §5). UX is **not** a final afterthought — it is woven in after each backend capability lands, with one dedicated reimagining phase.

### Phase A — Identity completes the front door  *(in progress)*
- **A1 · OIDC/SSO login** ✅ (item ②): provider-agnostic auth-code + PKCE + state + nonce; Google as the first configured provider; allowlist-gated `(issuer, sub)` → local user; client secret stored via the at-rest cipher. Deps: `golang.org/x/oauth2`, `github.com/coreos/go-oidc/v3` (the first external deps, blessed by ADR-001).
- **A2 · Dashboard SSO UI** ✅: "Sign in with SSO" + admin provider config UI, including `sso_error` / `totp_challenge` redirect handling and write-only client secrets.
- A3 · Enforce-2FA policy; WebAuthn groundwork.
- **Exit:** an operator can sign in with Google, mapped to a scoped local identity, with no password; SSO config is admin-managed and secret-at-rest.

### Phase B — The platform runs plugins  *(item ③)*
- B1 · **Host-API broker** ✅: the stable, capability-gated interface a plugin calls back into (store/kv, http-egress, notify, log) — the contract the wasm tier was deferred behind (ADR-001 D2/D5).
- B2 · **Real execution** of `system`/`worker` plugins on top of the loader: lifecycle registry/API/UI ✅; runtime manager + runner contract ✅; artifact execution, concrete runner isolation, per-plugin limits, and runtime health depth still pending.
- B3 · First official plugins as reference; marketplace fetch of signed artifacts.
- **Exit:** a signed plugin installs, runs, is capability-confined, and its host calls are brokered + audited. Foundation for the user's own LatticeNet/* official plugins (sing-box/xray/sub-store).

### Phase C — Storage that scales  *(item ④, next high-leverage backend slice)*
- C1 · **Replace the whole-file JSON store with bbolt** (pure Go, preserves zero-CGo). Import/export + JSON migration/rollback CLI ✅; first record-level APIs for nodes/KV/audit ✅; broader per-bucket record writes, the at-rest encryption boundary (ADR-002) re-homed onto the default store, audit WAL head anchoring, and backup/restore still pending.
- C2 · crash-safe migration from the JSON file, JSON export/import, retention policy for high-volume audit/monitor results.
- **Exit:** writes are O(record) not O(state); a 10k-node/long-audit deployment stays responsive; crash-safe.
- **Timing note:** done after A/B so it migrates a known-stable schema; the fresh at-rest boundary is re-homed deliberately, not rushed.

### Phase D — The 惊艳 dashboard  *(P5, dedicated)*
- A coherent design system; real-time fleet view; first-run onboarding; every backend capability surfaced with care; accessibility + performance budgets.
- **Exit:** the dashboard is the reason people choose Lattice, not the part they tolerate.

### Continuous tracks (every phase)
- **Security review** of each slice (adversarial, separate pass). **Docs** (ADR for decisions, iteration log for cycles). **Tests** (`-race`, gofmt, dashboard). **Zero-CGo / minimal-dep** discipline — every new dependency justified in an ADR.

## 5. Operating cadence (how we work)

For every slice: **Plan → Execute → Review → Iterate**, each leaving a durable artifact.
1. **Plan** — write `iterations/iter-NNN-<slug>.md` (goal, scope, design, risks, test plan, exit bar) *before* code.
2. **Execute** — TDD; small, coherent commits; `-race` + gofmt + dashboard green before claiming done.
3. **Review** — independent adversarial review (workflow / subagent), never self-approval; fix must-fixes with regression tests.
4. **Iterate** — record outcome + residuals in the same iteration doc; update this vision and the ADRs; pick the next slice.

## 6. Hard constraints
- **Security first**, then functionality, then usability, then performance — but performance and failure-visibility are first-class whenever the workload is hot or a failure could be silent.
- **Pure Go, zero CGo.** Every external dependency must be justified in an ADR (so far: oauth2 + go-oidc/go-jose for OIDC; bbolt for storage when Phase C starts; wazero only if/when wasm plugins land).
- **Fail closed.** Unsafe defaults are bugs.
- **Multi-repo `go.work`**: build/test with `GOWORK` set (see `lattice-codebase-build-and-hardening` notes).

## 7. Supersedes / reconciles
- Older roadmap language that mentioned "SQLite WAL" is **superseded**: SQLite is CGo; the decided path is **bbolt** (pure Go) — Phase C.
