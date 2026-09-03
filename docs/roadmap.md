# Roadmap

> **2026-08-31 positioning ratified, program reset.** The full analysis and its
> ratification are recorded in the operator's vault; the resulting doctrine is
> [`PRODUCT-VISION.md`](./PRODUCT-VISION.md) (this date's version supersedes
> 2026-06-15). One sentence: Lattice is a sovereign control plane that
> amplifies one operator's judgment safely across all of their infrastructure,
> with hands and agents as equal operators. North star: the **unattended
> week**. The near-term program, in leverage order: close the honesty loops
> (process-level liveness, real usage, cross-alive notifications, admission
> registries filled, rollback to known-good); pull the meta-loop into the
> product (deploy records as objects, version truth from `/api/version`,
> credential rotation as approvals); design the plan-only agent surface and
> revive Astra as the approval device; enforce the coherence grammar checklist
> on every console slice (state in URL, objects interlinked, failures leave a
> trace, keyboard reachable, 1440 and 375). Explicit stops: no fifth plugin,
> no multi-tenant SaaS, no wasm runner yet, no observability or mesh feature
> races, no permanent manual release ceremony. Known production defects at
> ratification time (dashboard navigation stalls without feedback, multi-day
> stuck Running tasks, fleet status vocabulary drift, routine linemeta
> approvals piling up unapproved) are tracked in `handbook.md`'s known-issues
> section and fixed before new surface work.
>
> **2026-06-11 security hardening pass** delivered the items marked *(Delivered)*
> below plus a broad set of fixes (authz bugs, rate limiting, O(1) PAT auth,
> session persistence, nft/storage input validation, TLS/HSTS, real CPU metrics,
> agent timeouts). See [`SECURITY-HARDENING.md`](./SECURITY-HARDENING.md).
>
> **2026-06-12 follow-up:** OIDC/SSO backend + dashboard UI, TOTP 2FA, at-rest
> encryption, tamper-evident audit WAL, signed plugin loader, lifecycle UI, host
> API broker, and runtime runner contract are now landed. The durable storage
> direction is **bbolt**, not SQLite, to preserve the pure-Go / zero-CGo rule;
> bucketized bbolt import/export, JSON migration/rollback CLI, and record-level
> bbolt APIs for current state buckets have landed, but JSON is still the
> default server store.
>
> **2026-06-13 closeout:** the then-current six-repo baseline and next development
> order are captured in [`archive/development-report-2026-06-13.md`](./archive/development-report-2026-06-13.md).
>
> **2026-06-17 operator UX + diagnostics:** the dashboard SSO New Provider flow
> now links to the public SSO guide and explains each OIDC field, redirect URI,
> and IdP expectation inline. `lattice-agent v0.2.1` adds server-controlled
> debug policy: operators can enable per-node local debug logging, optionally
> collect those debug lines into managed server Logs, or keep diagnostics local
> only. The SDK contract, server APIs, dashboard controls, public docs, and
> GHCR `latest`/`alpha` images are aligned on this release.
>
> **2026-06-17 Fleet Map v2:** `/map` now uses a CSP-safe world SVG with
> operator-grade placement, region rollups, source tracking (`operator` versus
> `auto`), and a server-side GeoIP resolver. The server defaults to the no-token
> `ipwho.is` HTTPS provider for Nezha-like auto-location; set
> `LATTICE_GEOIP_LOOKUP_URL=off` to prevent external lookup, or point it at an
> internal HTTPS provider.
>
> **2026-06-17 Browser Terminal MVP:** Operations now has a real `/terminal`
> screen backed by server-side in-memory Terminal sessions and an opt-in
> `lattice-agent` PTY runner. It requires `terminal:open`, records open/close
> audit events, preserves the no-inbound-agent model, and is enabled per node
> with `LATTICE_AGENT_ALLOW_TERMINAL=1`. Live I/O is bounded in process memory:
> four active sessions per node, 10-minute pending expiry, four-hour idle expiry,
> and 30-minute closed transcript pruning. The 2026-06-18 polish replaced the
> text-command panel with an xterm-backed shell workspace, adds direct Nodes
> page entrypoints, and makes operator close requests immediately mark the
> session closed while still delivering the close signal to the agent.
>
> **2026-06-18 Astra iOS v2 repository publication:** `LatticeNet/Astra` is now
> the public source repository for the phone-first Lattice companion app. The v2
> app upgrades the old read-only node monitor into Overview, Nodes, Monitors,
> Inventory, and More tabs. The Swift core models Lattice server/SDK views,
> adds a broad typed `LatticeClient`, and derives fleet/inventory/monitor
> analytics. The follow-up Network & security slice adds mobile read views for
> approvals, NetPolicy, reachability, nft inputs, and tunnels, plus
> SHA-256-bound approval of already-reviewed plans; policy authoring and
> planning remain Web dashboard responsibilities. Verification passed with
> `swift run AstraCoreCheck`, an iOS Simulator `xcodebuild`, and GitHub Actions
> CI. Signing, TestFlight, live-service iPhone QA, Bark, and background refresh
> validation remain device-side release steps. See [`iterations/iter-062-astra-ios-control-companion.md`](./iterations/iter-062-astra-ios-control-companion.md).
>
> **2026-06-13 audit + designs:** a full-codebase security/stability audit was
> run and remediated ([`iterations/iter-016-audit-remediation.md`](./iterations/iter-016-audit-remediation.md)):
> ~25 fixes incl. state-file fsync durability, WireGuard `/32` host routes,
> per-plugin KV namespacing, TOTP replay protection, session-epoch invalidation,
> trust-proxy CIDR allowlist, constant-time CSRF/recovery-code. The next major
> capabilities are now fully designed in [`designs/`](./designs/README.md)
> (proxy cores + subscriptions, self-host DNS, log ingestion, machine inventory +
> cost, per-node nft ACL + geo-map). Machine-inventory HostFacts landed in
> iter-017, MachineProfile cost/renewal reminder MVP landed in iter-018, and
> shared per-node nft input persistence landed in iter-019. Design 05's
> `NetPolicy` state/API/reachability graph/dashboard foundation landed in
> iter-020; egress-only nft compiler/plan/apply with dead-man rollback and
> agent control-plane selfcheck landed in iter-021; operator `NodeGeo` CRUD and
> the dependency-free dashboard Fleet Map landed in iter-022; dashboard
> policy-graph SVG landed in iter-023; Network Guard now commits
> `lattice_guard` with rollback/selfcheck and composes enabled ingress policy
> into the single input chain in iter-024. Control-plane domain-backed nft sets
> now have IPv4/IPv6 refresh, and operator IPv6 policy remotes compile through
> the reviewed policy path. Egress domain-valued operator remotes now compile
> through node-filled nft named sets. Domain refresh now has systemd and cron.d
> scheduler paths. Self-host DNS now has a durable `DNSDeployment`
> model/store/API/dashboard foundation with encrypted Cloudflare token storage,
> CoreDNS/nft plan generation, rollback-protected apply, and status
> reconciliation, Cloudflare publication, automatic publication on node IP
> changes, separate service-apply vs hostname-publish status fields, and
> optional pinned CoreDNS executable install with SHA-256 verification. Proxy
> core/subscription work has started: iter-039 landed the SDK model/proto/store
> foundation with encrypted proxy credentials, and iter-040 landed the first
> fail-closed sing-box `vless`+TCP+REALITY config renderer. Iter-041 landed
> scoped proxy inbounds/users/profiles CRUD with secret-free JSON views.
> Iter-042 landed the redacted reviewed proxy plan endpoint and real-config SHA
> binding. Iter-043 enabled secret-safe reviewed queue/apply. Iter-044 landed
> the public plain/base64 `/sub/{token}` subscription MVP with hashed-token
> audit and duplicate-token fail-closed behavior. Iter-045 landed the dashboard
> proxy management panel plus explicit audited subscription URL rotation/copy.
> Iter-046 landed the first proxy usage reporting baseline: node-token
> `/api/agent/proxy-usage`, server-side monotonic rollup, an agent file bridge,
> and dashboard usage/last-seen display. Iter-047 landed `format=sing-box`,
> `format=clash`, and `format=clash-meta` subscription output for
> VLESS+REALITY+TCP, with a shared secret-free endpoint projection and no new
> dependency. Iter-048 landed the focused dashboard proxy apply review flow, so
> proxy operators can review pending `proxycore/apply-config` plans and queue
> apply from the Proxy Core panel without using the generic Approvals panel.
> Iter-049 landed the node-agent loopback HTTP/V2Ray-stats proxy usage
> collector foundation with no new Go dependencies.
> Iter-050 landed server-owned proxy quota/expiry notifications through the
> existing `internal/notify` channel fan-out.
> Iter-051 landed dashboard subscription import helpers for base64/plain/
> sing-box/Clash.Meta, shown only after explicit token rotation.
> Iter-052 landed proxy collector health/error surfacing from agent through
> server profile state to the dashboard.
> Iter-053 landed xray VLESS+REALITY+TCP rendering and reviewed `xray test -c`
> apply, reusing the same subscription and approval model.
> Iter-054 landed the dependency-free xray stats transport — the agent runs the
> on-node `xray api statsquery` (ADR-003, no `grpc-go`) — plus two low-severity
> collector hardening fixes (HTTP redirect refusal, `config_path` `..` rejection).
> Iter-055 landed proxy config-drift detection: the scheduler flags when an
> applied node config still serves now-ineligible users and the dashboard offers
> a one-click Review & Apply enforce path (plan→approve→apply preserved; no
> auto-apply). Opt-in auto-enforce for reduction-only drift remains pending.
> Iter-056 landed log ingestion/query MVP with dedicated bounded `logs.db`;
> iter-057 landed Geo-Routing configure+preview; iter-058 landed
> server-controlled node-agent update policies with manual plan and auto-plan
> pending approvals. Iter-060 reviewed release readiness: Pages workflow
> recovery, SDK `v0.2.0` contract hygiene, agent-update script hardening,
> target-bound agent release binaries, plugin marketplace/storage
> documentation, and restricted-environment test stability. Geo-Routing apply/NS
> publish, log ingestion v2, and signed agent release-channel discovery remain
> pending. Server-controlled node-agent diagnostics landed after iter-060:
> `/api/nodes/debug` owns the policy, agents poll `/api/agent/config`, and
> collected debug batches flow into managed `agent-debug://<node_id>` log
> sources when central collection is enabled.
> The public ecosystem surface now has a server Docker/GHCR path, the
> `latticenet.github.io` Pages site, and a `lattice-plugin-index` static
> marketplace-index foundation. Plugin artifact execution remains gated by
> [`designs/design-08-real-plugin-runners.md`](./designs/design-08-real-plugin-runners.md).
> Bulk geo import and map overlays remain pending.

## Where the rest of the plan lives

This file is the dated log of program-level turns: what changed direction, and
when. It does not carry a feature backlog.

- The program in leverage order, and what is deliberately not being built:
  [`PRODUCT-VISION.md`](./PRODUCT-VISION.md) sections 5 and 1.
- Per-capability design status: [`designs/README.md`](./designs/README.md).
- Live work in flight, known issues, and production truth: the operator's
  program log at the workspace root (`PROGRAM.md`), which is the only place
  that states current version numbers.
- The June 2026 feature backlog this file used to carry:
  [`archive/roadmap-backlog-2026-06.md`](./archive/roadmap-backlog-2026-06.md).
