# Capability designs

One numbered design per capability. Each was written to be built from directly:
data model, API, agent work, config rendering, security, phasing, and a
file-by-file checklist. Designs 01 to 08 were produced on 2026-06-13 from a
study of reference panels (remnawave, pasarguard, s-ui, 3x-ui, Sub-Store,
nezha) together with the operator's own notes; the later ones were written as
the work reached them.

Read the status table before the design files. Several designs still carry the
status line they were written with, and in four cases that line is now wrong:
design-09 and design-10 say no code has been written, design-16 says it is a
specification, and all three shipped. The table is the authority on what is
built; the design file is the authority on how it was meant to work.

Status vocabulary: **shipped** means the capability is live and relied on;
**partial** means some phases landed and named phases are still open;
**superseded** means a later design replaced the approach; **accepted** means
the design was ratified but the build is not confirmed complete here;
**proposed** means it was never built.

| # | Design | Written | Status | Evidence |
|---|---|---|---|---|
| 01 | [Proxy cores and subscriptions](design-01-proxy-cores-and-subscriptions.md) | 2026-06-13 | partial, then moved into a plugin | iter-039 to iter-055 landed the core provider; ownership since moved to `lattice-plugin-vpn-core` by design-12 and design-14 |
| 02 | [Self-hosted DNS](design-02-self-host-dns.md) | 2026-06-13 | partial | iter-033 to iter-038; a real Linux-node end-to-end run for CoreDNS apply plus Cloudflare publish is still open |
| 03 | [Log ingestion and query](design-03-log-ingestion.md) | 2026-06-13 | shipped, MVP | iter-056, bounded `logs.db` and the dashboard Logs panel |
| 04 | [Machine inventory and cost](design-04-machine-inventory-and-cost.md) | 2026-06-13 | shipped, MVP | iter-017 (`HostFacts`) and iter-018 (`MachineProfile`, renewal reminders) |
| 05 | [Network ACL and geo map](design-05-network-acl-and-map.md) | 2026-06-14 | partial | iter-019 to iter-032; bulk geo import and map overlays are open |
| 06 | [Geo-routing for a shared apex](design-06-cf-dns-geo-routing.md) | 2026-06-15 | partial | iter-057 shipped configure and preview; apply, NS delegation, and the re-render trigger are open |
| 07 | [Agent lifecycle updates](design-07-agent-lifecycle-updates.md) | 2026-06-15 | shipped, MVP | iter-058; signed release-channel resolution is open |
| 08 | [Real plugin runners](design-08-real-plugin-runners.md) | 2026-06-15 | partial by design | `noop` remains the default; an opt-in system runner exists behind `LATTICE_PLUGIN_RUNTIME_DIR` (see `../tutorials/docker-server.md`); the wasm tier stays unbuilt by doctrine |
| 09 | [vpn-core and Sub-Store plugins](design-09-vpn-core-and-substore-plugins.md) | 2026-06-15 | superseded by 12 and 14 | its own header still says no code was written; vpn-core has been a production plugin since 2026-06-29 |
| 10 | [Plugin dashboard and interface contract](design-10-plugin-dashboard-and-interface-contract.md) | 2026-06-29 | superseded | the declarative builtin-view model it specifies was replaced by signed v2 bundles with sandboxed iframe UIs (`../archive/superpowers/specs/2026-07-13-self-contained-plugin-bundles-design.md`) |
| 11 | [VPN Manage migration review](design-11-vpn-manage-plugin-migration-review.md) | 2026-07-02 | shipped | migration executed as reviewed |
| 12 | [vpn-core lines, users, usage](design-12-vpn-core-lines-users-usage.md) | 2026-06-29 | shipped and deployed | verified end to end on the production hub the same day |
| 13 | [WireGuard and NetGuard plugins](design-13-wireguard-and-netguard-plugins.md) | 2026-07-08 | partial | G1 and G2 landed iter-068 and iter-069, W1 and W2 landed iter-070; G3 reality and drift, G4 dashboard, and W1b are open |
| 14 | [Plugin-owned vpn-core control](design-14-plugin-owned-vpn-core-control.md) | 2026-07-13 | accepted, and in effect | the plugin owns its own pages in production today |
| 15 | [line_uuid, per-line users, chain recognition, Sub-Store](design-15-line-uuid-users-chain-substore.md) | 2026-07-17 | accepted, contract shipped | `../contracts/lattice-singbox-metadata-v2.schema.json` and its fixtures |
| 16 | [Sub-Store native subscription platform](design-16-substore-native-subscription-platform.md) | 2026-08-05 | shipped; status line never updated | the platform runs in `lattice-plugin-sub-store` in production; its implementation plan is archived at `../archive/plans/2026-08-05-design-16-sub1-implementation.md` with every checkbox still unticked, which is a record-keeping failure, not a build failure |
| 17 | [Managed line overlay](design-17-managed-line-overlay.md) | 2026-08-12 | partial | S1 and S2 landed server-side on 2026-08-12 |
| 18 | [Fleet line database](design-18-fleet-line-database.md) | 2026-08-12 | proposed | no later document records it landing |
| 18 | [Reviewed line-chain builder](design-18-line-chain-builder.md) | 2026-08-13 | shipped, alpha | `../tutorials/operator-guide.md` section 15 |
| 19 | [sing-box service liveness](design-19-singbox-service-liveness.md) | 2026-09-01 | accepted, not built | the process-level liveness gap it closes is an open axiom-2 item in the program log |

Two different designs carry the number 18. That was a mistake and it is left in
place because both filenames are cited elsewhere; distinguish them by their
slug, not their number. The next design takes number 20.

## Shared architecture

These hold across every design in the table.

Core server-owned providers are not third-party plugins. They hold bearer
secrets and drive the plan, approve, apply flow that the plugin broker
deliberately does not expose, which is the same reasoning that keeps `ddns` and
`notify` in core. The plugin runtime exists for extensions, not for the crown
jewels.

Reuse before inventing. `internal/ddns` is the only Cloudflare client,
`internal/notify` the only reminder and alert path, `internal/network/nft` the
only firewall renderer, `internal/outbound` the SSRF guard, and
`internal/store/crypto.go` the encryption boundary every new secret field goes
through. New code joins those rather than adding a parallel one.

The constraints are pure Go with zero CGo, an ADR for every new dependency,
fail-closed defaults, audit for everything, and a dashboard that stays under a
strict CSP.

## Cross-cutting dependencies

The node's firewall is one server-rendered `inet lattice_guard` table. Both the
DNS port from design-02 and the per-node ACLs from design-05 fold into that
same render. Since iter-019 each node has a persisted `model.NFTInputs` record
exposed by `/api/network/nft/inputs`, and anything touching the firewall
composes into that record instead of introducing a second table.

The auto-detected `HostFacts` from design-04 and the operator-owned `NodeGeo`
records feed the map in design-05. Geo data stays operator-owned; the fleet map
does not trust an agent-reported location.

High-volume stores want the record-level bbolt backend rather than whole-file
JSON rewrites. Design-03 shipped its own bounded store first, which is the
pattern to follow when the shared backend is not ready.

## Where the build order lives

Not here. The program in leverage order is `../PRODUCT-VISION.md` section 5,
and what is actually in flight is in the operator's program log at the
workspace root. The build order this file used to recommend was written in June
2026 and had gone stale in every line.
