# Lattice — Feature Design Index (forward build plan)

These are **framework designs + development guides** for the next major capabilities, produced 2026-06-13 from research of reference panels (remnawave, pasarguard, s-ui, 3x-ui, Sub-Store, nezha) + the operator's own notes, and grounded in Lattice's current architecture. Each doc is buildable directly: data model → API → agent work → config rendering → security → phasing → file-by-file checklist.

**Status:** mostly designed, with Design 04's MVP implemented and Design 05's
safe control-plane foundation now entering real apply plus first map UI. Design 04 Half A
(`HostFacts` inventory telemetry) shipped in iter-017, Half B (`MachineProfile`
cost/renewal + reminder MVP) shipped in iter-018, shared per-node `NFTInputs`
state shipped in iter-019, `NetPolicy` state + reachability graph + dashboard
panel shipped in iter-020, and egress-only `NetPolicy` nft plan/apply with
dead-man rollback + unauthenticated agent selfcheck shipped in iter-021. Iter-022
adds operator-owned `NodeGeo` CRUD and a dependency-free inline-SVG fleet map;
iter-023 upgrades the server-derived policy graph to an inline SVG; iter-024
turns Network Guard into a rollback-protected apply path and folds enabled
ingress policy into the single `lattice_guard` input render.
Iter-026 removes the IPv4-literal-only constraint for control-plane
`public_url` by using a node-filled `lattice_control4` named set for HTTPS
hostnames; iter-027 moves that set update into an agent-native helper instead
of shell DNS parsing; iter-028 installs a systemd timer for periodic refresh of
that control-plane set; iter-029 adds IPv6 control-plane parity with
`lattice_control6` plus IPv6 literal `public_url` support; iter-030 adds
operator-authored IPv6 CIDR/node remotes for egress and ingress composition.
Iter-031 adds domain-valued operator remotes for the egress compiler/apply path
using node-filled nft named sets; iter-032 adds a cron.d fallback for non-systemd
domain-set refresh. Iter-033 starts Design 02 by landing the `DNSDeployment`
intent model, encrypted credential storage, scoped CRUD API, proto view, and
dashboard panel; iter-034 adds dependency-free CoreDNS rendering plus
initial `/api/dns/plan`; iter-035 enables rollback-protected selfdns apply and
DNSDeployment status reconciliation; iter-036 adds `/api/dns/publish` plus
automatic Cloudflare publication on node IP changes; iter-037 splits service
apply status from hostname publication status; iter-038 adds optional pinned
CoreDNS executable install with SHA-256 verification. Iter-039 starts Design 01
by landing proxy-core SDK models/constants, redacted proto views,
JSON-store/bbolt persistence, and at-rest encryption for proxy credentials;
iter-040 adds the first fail-closed sing-box `vless`+TCP+REALITY renderer with
canonical config hashes; iter-041 adds scoped proxy inbounds/users/profiles CRUD
with secret-free JSON views; iter-042 adds the redacted reviewed proxy plan
endpoint and current-config SHA binding; iter-043 encrypts queued task scripts
at rest and enables reviewed proxycore queue/apply with sing-box validation,
atomic swap, and task-result status reconciliation; iter-044 adds the public
`/sub/{token}` MVP with plain/base64 VLESS+REALITY links, `Subscription-Userinfo`,
constant-time token scan, duplicate-token fail-closed handling, and audit;
iter-045 adds the dashboard proxy management panel and explicit subscription
URL rotation/copy workflow; iter-046 adds the first low-trust proxy usage
reporting baseline with server-side monotonic rollup, an agent file bridge, and
dashboard usage/last-seen display; iter-047 adds sing-box client JSON and
Clash/Mihomo YAML subscription formats for the supported VLESS+REALITY+TCP
path; iter-048 adds the focused dashboard proxy apply review flow; iter-049
adds the node-agent loopback HTTP/V2Ray-stats proxy usage collector foundation;
iter-050 adds server-owned proxy quota/expiry notifications through
`internal/notify`; iter-051 adds dashboard subscription import helpers for
base64/plain/sing-box/Clash.Meta without adding a token reveal API; iter-052
adds agent-reported proxy collector health/error surfacing without letting error
reports mutate the accounting baseline; iter-053 adds the xray
VLESS+REALITY+TCP renderer, reviewed `xray test -c` apply path, and dashboard
core selection; iter-054 lands the dependency-free xray stats transport (the
agent runs the on-node `xray api statsquery` per ADR-003 — no `grpc-go`) plus two
low-severity collector hardening fixes (HTTP redirect refusal, `config_path` `..`
rejection); iter-055 adds proxy config-drift detection — the scheduler flags when
an applied node config still serves now-ineligible users and surfaces a one-click
**Review & Apply** enforce path (plan→approve→apply preserved; no auto-apply).
Remaining Design 05 work is bulk geo import and map overlays. Design 03 (log
ingestion) MVP shipped in iter-056: a dedicated bounded bbolt `logs.db`,
fail-closed path validation, agent tailer, per-source ingest budget, and a
dashboard Logs panel — v2 adds encryption-default/sweeper, silent-source notify,
and journald. Each
new build slice becomes a numbered `iterations/iter-NNN-*.md` (per
`development-workflow.md`: plan → design → build → verify → review → commit).

## The designs

| # | Design | What it delivers | Core decision |
|---|--------|------------------|---------------|
| 01 | [Proxy cores & subscriptions](design-01-proxy-cores-and-subscriptions.md) | Centralized sing-box/xray management across the node fleet + fleet-wide subscriptions | **CORE provider** `internal/proxycore`; SDK model/proto/store/encryption foundation landed iter-039; sing-box `vless+reality+tcp` renderer landed iter-040; scoped CRUD/read views landed iter-041; redacted reviewed plan endpoint landed iter-042; secret-safe queue/apply landed iter-043; plain/base64 `/sub/{token}` landed iter-044; dashboard CRUD + explicit subscription URL rotation/copy landed iter-045; usage reporting baseline landed iter-046; sing-box JSON + Clash/Mihomo YAML subscriptions landed iter-047; focused proxy apply UI landed iter-048; loopback HTTP/V2Ray-stats collector foundation landed iter-049; quota/expiry notifications landed iter-050; subscription import helpers landed iter-051; collector health/error surfacing landed iter-052; xray VLESS+REALITY+TCP renderer/apply landed iter-053; dependency-free xray stats transport (`xray api statsquery`, ADR-003) landed iter-054; config-drift detection + one-click reviewed enforce landed iter-055; next is opt-in auto-enforce for reduction-only drift; node-agnostic `ProxyUser` -> one subscription spans the fleet (remnawave model); secrets encrypted at rest |
| 02 | [Self-hosted DNS](design-02-self-host-dns.md) | One-click private DNS on a chosen node + CF subdomain (gmami-jp1.dns.roobli.org) auto-updated via DDNS + nft-confined | CORE `internal/selfdns`; `DNSDeployment` model/API/dashboard foundation landed iter-033; CoreDNS render + `/api/dns/plan` landed iter-034; rollback-protected apply/status landed iter-035; Cloudflare publish landed iter-036; apply/publish status split landed iter-037; pinned CoreDNS install landed iter-038; reuses `internal/ddns` (CF) + shared `NFTInputs` |
| 03 | [Log ingestion & query](design-03-log-ingestion.md) | Tail an operator-specified log path on a node → queryable store for debugging | **MVP shipped iter-056**: dedicated bounded bbolt `logs.db` (NOT the JSON store), `internal/logstore` + `internal/logtail` agent tailer, scoped CRUD/query/stats + agent ingest with path validation, per-source byte-cap + lines/sec budget, dashboard Logs panel; next is encryption-default + age/global sweeper + silent-source notify |
| 04 | [Machine inventory & cost](design-04-machine-inventory-and-cost.md) | Auto-detect CPU/mem/uptime/arch; operator-set cloud vendor/links/cost/renewal + renewal reminders | `HostFacts` auto-detect/report/display **landed iter-017**; server-only `MachineProfile` + renewal reminder MVP **landed iter-018** |
| 05 | [Network ACL & geo-map](design-05-network-acl-and-map.md) | Per-node nft access rules (deny node→dmit:1234), policy/reachability viz, nezha-style global map | CORE `internal/netpolicy`; `NetPolicy` validation/store/API/graph/dashboard foundation landed iter-020; egress-only nft compiler + `/api/netpolicy/plan` + **60s agent dead-man rollback** apply path landed iter-021; `NodeGeo` CRUD + inline-SVG fleet map landed iter-022; policy graph SVG landed iter-023; Network Guard rollback apply + ingress guard composition landed iter-024; control-plane HTTPS-domain named set landed iter-026; agent-native domain-set updater landed iter-027; systemd periodic refresh landed iter-028; IPv6 control-plane parity landed iter-029; operator IPv6 remotes landed iter-030; egress domain remotes landed iter-031; cron.d refresh fallback landed iter-032 |
| 06 | [Geo-routing dns.roobli.org](design-06-cf-dns-geo-routing.md) | Resolve a shared apex (`dns.roobli.org`) to the nearest healthy node by client location | **Decision (operator): Path B — free, self-hosted GeoDNS** (CF Load Balancing rejected on cost: paid add-on, country-geo needs Business plan). Lattice renders a geo-aware CoreDNS zone (haversine nearest-healthy node per continent from operator-owned `NodeGeo`, `geoip`+`view`) shipped via the Design 02 apply path, and delegates the subdomain NS into the CF parent zone with the existing DNS-edit token. Zero new Go deps; GeoLite2 is an operator-provisioned runtime file. *(Designed; build starting.)* |

## Shared architecture (all five honor)

- **CORE server-owned providers, not third-party plugins** — they own bearer secrets and drive the plan→approve→apply crown-jewel flow the plugin broker deliberately doesn't expose (same rationale as `ddns`/`notify`). The plugin runtime stays for community extensions.
- **Reuse, don't reinvent:** `internal/ddns` (the only CF client — used by 02 + 04 links), `internal/notify` (reminders/alerts — 04), `internal/network/nft` (02 + 05), `internal/outbound` (SSRF guard), `internal/store/crypto.go` (every new secret field), the agent poll + `applyScriptFor` apply path, `model.Node`.
- **Constraints:** pure Go, zero CGo, every new dep needs an ADR; security-first, fail-closed, audit everything; dashboard stays zero-dep vanilla JS under strict CSP.

## Cross-cutting dependencies (resolve before/together)

1. **The single nft table.** The node's firewall is one server-rendered `inet lattice_guard` table. Both **02 (DNS port)** and **05 (per-node ACL)** must fold into that *same* render, not add second tables. **Resolved in iter-019:** each node now has persisted `model.NFTInputs`, exposed by `/api/network/nft/inputs`, and the existing nft plan route renders from that state when the request carries only `node_id`. DNS and ACL must compose into this record rather than inventing another firewall source.
2. **HostFacts → geo-map.** 04's auto-detected `HostFacts` (arch, specs) and
   operator-owned `NodeGeo` feed 05's map. The first map MVP is landed; future
   work should add bulk geo import and overlays rather than agent-trusting live
   geo-IP.
3. **bbolt foundation.** 03 (logs) and any high-volume store want the record-level bbolt backend wired (Phase C in PRODUCT-VISION) — 03 can ship its own bounded store first, but note the dependency.

## Recommended build order (rationale)

1. **05 network ACL map polish** — continue from iter-032:
   ingress composition is now folded into `lattice_guard`, and control-plane
   HTTPS-domain `public_url` now uses agent-filled `lattice_control4` /
   `lattice_control6` sets with systemd or cron.d periodic refresh.
   Operator-authored IPv6 CIDR/node remotes and egress domain-valued remotes now
   compile through the same reviewed path. Next add bulk geo import and map
   latency/renewal overlays.
2. **02 Self-host DNS** — continue from iter-038. Next run a real Linux-node
   E2E for CoreDNS + nft apply + Cloudflare publish. The status model now
   separates service apply state from hostname publication state, and optional
   pinned CoreDNS install is plan-bound by URL + SHA-256.
3. **01 Proxy cores & subscriptions** — the flagship and largest. The
   persistence/proto foundation, first sing-box renderer, scoped CRUD/read
   views, reviewed redacted plan endpoint, secret-safe queue/apply, and first
   plain/base64 subscription endpoint are now landed. Iter-045 added the
   dashboard proxy panel plus audited rotate/copy subscription URL flow;
   iter-046 added usage reporting baseline and dashboard usage display;
   iter-047 added sing-box JSON and Clash/Mihomo YAML subscription output;
   iter-048 added focused proxy apply review in the dashboard; iter-049 added a
   loopback HTTP/V2Ray-stats collector foundation in the node-agent; iter-050
   added server-owned quota/expiry notifications; iter-051 added copy-ready
   subscription import helpers in the dashboard; iter-052 added collector
   health/error surfacing; iter-053 added xray rendering/apply for the same
   VLESS+REALITY+TCP MVP; iter-054 added the dependency-free xray stats transport
   (`xray api statsquery`, ADR-003 — no `grpc-go`); iter-055 added config-drift
   detection that flags applied configs still serving now-ineligible users plus a
   one-click **Review & Apply** enforce path (no auto-apply). Next: opt-in
   auto-enforce for reduction-only drift, then **Design 03 (log ingestion)** —
   the largest remaining unbuilt feature.
4. **03 Log ingestion** — **MVP shipped (iter-056)** with its own bounded bbolt
   `logs.db` (the bounded standalone store the design anticipated). Next: v2
   encryption-default + age/global sweeper, silent-source notify, journald, and
   a real Linux-node rotation E2E.
5. **Design 04 v2 polish** — audited reveal endpoint, per-currency rollups,
   facts-changed signal, and richer dashboard grouping.

(Order is a recommendation; each is independently shippable. Re-confirm against the live roadmap when starting.)
