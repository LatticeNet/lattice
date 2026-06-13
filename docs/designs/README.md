# Lattice — Feature Design Index (forward build plan)

These are **framework designs + development guides** for the next major capabilities, produced 2026-06-13 from research of reference panels (remnawave, pasarguard, s-ui, 3x-ui, Sub-Store, nezha) + the operator's own notes, and grounded in Lattice's current architecture. Each doc is buildable directly: data model → API → agent work → config rendering → security → phasing → file-by-file checklist.

**Status:** mostly designed, with Design 04's MVP now implemented. Design 04 Half A (`HostFacts` inventory telemetry) shipped in iter-017 and Half B (`MachineProfile` cost/renewal + reminder MVP) shipped in iter-018; the remaining designs are still design-ready but unbuilt. Each new build slice becomes a numbered `iterations/iter-NNN-*.md` (per `development-workflow.md`: plan → design → build → verify → review → commit).

## The five designs

| # | Design | What it delivers | Core decision |
|---|--------|------------------|---------------|
| 01 | [Proxy cores & subscriptions](design-01-proxy-cores-and-subscriptions.md) | Centralized sing-box (v1) / xray (v2) management across the node fleet + fleet-wide subscriptions | **CORE provider** `internal/proxycore`; server-rendered config validated node-side (`sing-box check` + atomic swap); node-agnostic `ProxyUser` → one `/sub/{token}` spans the fleet (remnawave model); secrets encrypted at rest |
| 02 | [Self-hosted DNS](design-02-self-host-dns.md) | One-click private DNS on a chosen node + CF subdomain (gmami-jp1.dns.roobli.org) auto-updated via DDNS + nft-confined | CORE `internal/selfdns`; **pure-Go CoreDNS** (digest-pinned) via plan→approve→apply; reuses `internal/ddns` (CF) + `internal/network/nft` |
| 03 | [Log ingestion & query](design-03-log-ingestion.md) | Tail an operator-specified log path on a node → queryable store for debugging | Agent tails + ships deltas; **NOT on the JSON store** — a dedicated bounded append-only per-node log store (relates to the bbolt foundation); query API + dashboard |
| 04 | [Machine inventory & cost](design-04-machine-inventory-and-cost.md) | Auto-detect CPU/mem/uptime/arch; operator-set cloud vendor/links/cost/renewal + renewal reminders | `HostFacts` auto-detect/report/display **landed iter-017**; server-only `MachineProfile` + renewal reminder MVP **landed iter-018** |
| 05 | [Network ACL & geo-map](design-05-network-acl-and-map.md) | Per-node nft access rules (deny node→dmit:1234), policy/reachability viz, nezha-style global map | CORE `internal/netpolicy` nft compiler, **fail-closed with a 60s agent dead-man rollback** (no self-lockout); zero-dep inline-SVG map under strict CSP |

## Shared architecture (all five honor)

- **CORE server-owned providers, not third-party plugins** — they own bearer secrets and drive the plan→approve→apply crown-jewel flow the plugin broker deliberately doesn't expose (same rationale as `ddns`/`notify`). The plugin runtime stays for community extensions.
- **Reuse, don't reinvent:** `internal/ddns` (the only CF client — used by 02 + 04 links), `internal/notify` (reminders/alerts — 04), `internal/network/nft` (02 + 05), `internal/outbound` (SSRF guard), `internal/store/crypto.go` (every new secret field), the agent poll + `applyScriptFor` apply path, `model.Node`.
- **Constraints:** pure Go, zero CGo, every new dep needs an ADR; security-first, fail-closed, audit everything; dashboard stays zero-dep vanilla JS under strict CSP.

## Cross-cutting dependencies (resolve before/together)

1. **The single nft table.** The node's firewall is one server-rendered `inet lattice_guard` table. Both **02 (DNS port)** and **05 (per-node ACL)** must fold into that *same* render, not add second tables. **Pre-build action (gates 02 §6 and 05):** confirm where each node's authoritative nft inputs live; if they aren't persisted per node, add a small store collection so DNS + base firewall + ACL compose deterministically. Do this once, shared by 02 and 05.
2. **HostFacts → geo-map.** 04's auto-detected `HostFacts` (arch, specs) and geo feed 05's map; build 04's facts before 05's map.
3. **bbolt foundation.** 03 (logs) and any high-volume store want the record-level bbolt backend wired (Phase C in PRODUCT-VISION) — 03 can ship its own bounded store first, but note the dependency.

## Recommended build order (rationale)

1. **The shared nft-input persistence** (small, gates 02 + 05) → then **05 network ACL + map** (high operator value; map reuses 04's facts).
2. **02 Self-host DNS** — builds on the same nft work + existing ddns; self-contained.
3. **01 Proxy cores & subscriptions** — the flagship and largest; sequence after the smaller wins so the platform (store/agent/apply) is battle-tested. Ship MVP = vless+reality + expiry-only subs first.
4. **03 Log ingestion** — pairs with the bbolt cutover (Phase C); do once a real store backend is wired, or ship the bounded standalone store as an interim.
5. **Design 04 v2 polish** — audited reveal endpoint, per-currency rollups, facts-changed signal, and richer dashboard grouping.

(Order is a recommendation; each is independently shippable. Re-confirm against the live roadmap when starting.)
