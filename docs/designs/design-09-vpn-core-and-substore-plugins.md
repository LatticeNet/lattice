# Design 09 — vpn-core plugin (sing-box deploy/CRUD/subscriptions) + Sub-Store companion plugin

## Status

Draft for review. Supersedes nothing; extends design-01 (proxy cores) and
design-08 (real plugin runners). No code written yet.

This document is the framework/system design for a large change requested by the
operator:

1. Turn the existing **Proxy** domain (Inbounds, Users, Node Profiles,
   Subscriptions, Usage) into an officially-maintained **plugin** — the
   "vpn-core" plugin.
2. Make it *actually deploy* sing-box on a chosen machine and do real node/user
   CRUD by driving the operator's own **233boy sing-box** script remotely
   (extending that script with a non-interactive `--json` interface).
3. Add a second first-party plugin: a **Sub-Store companion** that preserves all
   Sub-Store features but can import node connection info directly from vpn-core
   through a new **inter-plugin interface**, and can serve subscription output
   from a separate domain or a Cloudflare Worker.

## TL;DR (recommendation)

"Make Proxy a plugin" is, today, a re-architecture — not a lift-and-shift —
because (a) the plugin runtime only runs `noopRunner` (no artifact ever
executes), (b) there is **no inter-plugin RPC**, and (c) the proxy domain is the
single most core-coupled subsystem (shared encrypted store, hardcoded
`plan→approve→apply` switches in `server.go`, shared RBAC/scheduler/notify).

So the recommended path is **value-first and phased, engine-stays-in-core** (the
exact model ADR-001 D5/D6 already prescribes):

- **Phase A** — extend the 233boy script with a stable `--json` machine
  interface + a subscription aggregator (in the operator's own `sing-box` repo).
- **Phase B** — close the proxy domain's real gap: **auto-provision sing-box**
  (install binary + systemd unit + REALITY keygen) over the *existing*
  agent task pipeline. This is the single highest-leverage win and needs no
  plugin runtime at all.
- **Phase C** — build the **Tier-2 system runner** (the missing foundation
  piece) with vpn-core as its first "proof case", and define the **inter-plugin
  RPC** at the broker layer.
- **Phase D** — ship the **Sub-Store companion** plugin **internal-only**
  (supervise + import vpn-core nodes + view config in the dashboard). **Public
  subscription delivery (CF Worker / separate domain / gist) is deferred**
  (operator decision 2026-06-28) — the first cut exposes no public
  links/downloads; the delivery + its security model are revisited later.
- **Phase E** — migrate proxy *data ownership* from core into the plugin once
  plugin state-encryption + RPC are proven; retire the hardcoded core switches.

Each phase is independently shippable and never breaks the live proxy feature.
The operator gets real sing-box auto-deploy (Phase B) long before the full
core→plugin migration (Phase E) completes.

---

## A. Goals and non-goals

### Goals

- A first-party **vpn-core** plugin that owns the lifecycle of sing-box on fleet
  nodes: provision → add/remove/edit inbounds & users → export
  links/subscriptions → collect usage.
- Real on-box deployment driven by the **233boy sing-box** script, via a
  stable `--json` interface, over Lattice's existing agent task transport (no
  SSH, no new inbound path to nodes).
- A first-party **Sub-Store companion** plugin that wraps the operator's
  existing Sub-Store backend, adds an auth gateway, and imports nodes from
  vpn-core through a new inter-plugin interface.
- A **broker-level inter-plugin RPC** contract (discovery, capability-gated,
  audited, versioned) — invented from scratch (none exists today).
- Subscription handling: **internal-only in the first cut** (dashboard view +
  private access). Public edge delivery (CF Worker / separate domain / gist) is
  **deferred** pending the operator's security decision.
- Zero regression: the shipped proxy domain keeps working throughout.

### Non-goals

- No open community marketplace execution (design-08 non-goal stands).
- No unsigned host-risk plugin execution in production.
- No wasm runtime (deferred per design-08 / ADR D2).
- No "rip Proxy out of core in one commit" — explicitly rejected (see §I).
- First protocol cut is **sing-box only** (xray stays as the existing core
  renderer; not extended). Operator confirmed sing-box priority.

---

## B. Current state (grounded in code, not aspiration)

### B.1 Plugin foundation — built vs. missing

Built (per `internal/plugin/*`, design-08, ADR-001):

- Strict manifest validation + ed25519 digest/signature verification
  (`plugin.go`).
- Boot loader from `LATTICE_PLUGIN_DIR` (`<id>/manifest.json` + `<id>/artifact`),
  one bad bundle is audited & skipped (`loader.go`).
- Lifecycle registry + `POST /api/plugins/lifecycle` (`plugin:admin`),
  `POST /api/plugins/verify` (`plugin:verify`), control-plane UI
  (`PluginsView.vue`).
- Capability risk lattice (read/write/host) with deny-by-default; host-risk caps
  require a trusted-publisher signature unless `AllowUnsignedHostRisk`.
- Capability-scoped **Broker** with five wired host services: **KV** (pinned to
  bucket `plugin:<id>`), **Notify**, **HTTP** (guarded outbound, SSRF guard,
  256 KiB caps), **Log**, **Audit** (record-only).

Missing (the gaps this design must fill):

- **No real runner.** Only `noopRunner` executes; `system`/`worker`/`wasm`
  runners are unimplemented. "active" means *broker armed*, not *code running*.
- **Most capabilities are uncallable.** `task:run`, `network:plan`,
  `network:apply`, `node:read`, `static:*`, `worker:route` are
  grantable/verifiable but have **no Broker method / HostServices field**.
- **No plugin HTTP routing or plugin-served UI.** `worker:route` has no mount
  path; plugins cannot inject dashboard views.
- **No inter-plugin IPC of any kind.** Must be invented.
- **No remote install flow.** `lattice-plugin-index/plugins.json` is an empty
  draft; install is local-disk only.

### B.2 Proxy domain — a real, working, deeply-coupled deployer

Entities (`lattice-sdk/model/model.go`, `internal/store/`):

| Entity | Role | Secrets (encrypted at rest) |
|---|---|---|
| `ProxyInbound` (`pin…`) | node-agnostic protocol template | `RealityPrivateKey` |
| `ProxyUser` (`puser…`) | subscriber identity (cross-node) | `UUID`, `Password`, `SubToken` |
| `ProxyNodeProfile` (`==NodeID`) | per-node apply unit; `AppliedSHA256` | — |
| `ProxyUsageSnapshot` (per node) | last usage accounting snapshot | — |
| *Subscription* | **derived**, not stored — `SubToken` IS the credential | — |

Apply path is **real** (not bookkeeping):
`POST /api/proxy/nodes/{id}/plan` → `proxycore.RenderSingBoxConfigJSON` →
pending `Approval{Plugin:'proxycore', Action:'apply-config:<sha>'}` →
`POST /api/network/approvals/approve?queue_apply=true` → builds a
`model.Task{Interpreter:'sh', Script:<real config>, Targets:[node]}` (encrypted)
→ agent polls `GET /api/agent/tasks` → runs sandboxed `sh`:
`command -v sing-box || exit 1`, write `config.json.lattice-new`,
`sing-box check -c`, backup to `.lattice-prev`, atomic `mv`,
`systemctl reload||restart sing-box`, trap restores prev on any error.
Result → `handleProxyCoreTaskResult` sets `AppliedSHA256`. Drift
(`server_proxy_enforce.go`) is read-only; never self-heals.

Subscriptions: served at **public** `GET /sub/{token}` (token-auth only,
rate-limited), formats `base64|plain|sing-box|clash` via `?format=`. **Only
VLESS+REALITY+TCP is actually emitted** (vmess/trojan/ss/hy2 modeled but
unimplemented). Link host = `ProxyNodeProfile.Hostname` (DDNS) so links survive
IP changes.

Usage: opt-in, off by default. Agent bridges `-proxy-usage-file` /
`-proxy-usage-url` (loopback) / `-proxy-usage-xray-api` (xray CLI) → POST
`/api/agent/proxy-usage`. **No native sing-box stats collector exists.** Expiry
is hard/server-authoritative; quota is best-effort (no data-path cutoff).

**The gap (critical):** nothing installs sing-box. The apply script
hard-requires `command -v sing-box` and exits 1 if absent; nothing creates the
`sing-box` systemd unit it reloads; no REALITY keygen (`reality_private_key`
must be supplied by the operator). Once a node is *manually* provisioned, the
existing plan→apply path manages config fine — but provisioning is a manual,
undocumented prerequisite.

Coupling: 4 collections are fields on `store.State`; secrets encrypted inline in
the core `encryptState` path; `proxy:read/admin` in core RBAC; apply wired by
**hardcoded switch cases** in `server.go` (`applyScriptFor`, approve handler,
task-result dispatch); plus shared scheduler tick, ratelimit, notify, audit, and
the shared SDK wire model. design-01 kept it core deliberately "because the
plugin runtime can't run artifacts yet."

### B.3 233boy sing-box script — the missing installer/CRUD engine

Path: `…/Probe-Dashboards/sing-box` (the operator's own fork of 233boy's
script). `install.sh` + `sing-box.sh` → `src/{init,core,help,import,systemd,
caddy,dns,download,log,bbr}.sh`; symlinked to `/usr/local/bin/{sing-box,sb}`.

- **Installs** sing-box (binary + jq + systemd/openrc unit) and lays out
  `/etc/sing-box/`. `install.sh` is flag-driven (`-a addr`, `-f file`, `-l`,
  `-p proxy`, `-v ver`) and ends by creating the first REALITY node.
- **Config layout:** `/etc/sing-box/config.json` (log/dns/ntp/outbounds) +
  `/etc/sing-box/conf/*.json` (**one inbound per file**, filename = node
  identity). Service runs `sing-box run -c config.json -C conf/` (merges all).
- **Protocols:** VLESS-REALITY (default), VLESS-H2-REALITY, VMess
  TCP/WS/HTTP/QUIC (+TLS variants), VLESS/Trojan WS/H2/HTTPUpgrade-TLS, Trojan,
  TUIC, Hysteria2, AnyTLS, Shadowsocks/SS2022, Direct/Socks. Generates
  ports/uuids/keys; handles TLS/Caddy/ACME and REALITY keypairs.
- **Already scriptable** given exact args: `add|gen|no-auto-tls`,
  `change` + shortcuts (`id/host/port/path/passwd/key/method/sni/full/…`),
  `del|ddel`, `info`, `url`, `qr`, `dns <arg>`, `log <level>`, `import`,
  `update`, `status/start/stop/restart/test`, `ip/get-port/ss2022/pbk`. Node
  list primitive = `get file [filter]` over `conf/*.json`.
- **Needs a TTY** for: bare `sb` (menu), `uninstall/reinstall`, *ambiguous*
  name filters (`ask get_config_file`), `*-TLS`/anytls host-test confirm,
  IP-autodetect failure. **Hazard:** `ask()` spins forever on closed stdin
  rather than failing.
- **"Users" are not separate objects** — each inbound embeds exactly one user;
  "add user" ≈ "add node". No queryable user list beyond the conf files.
- **No subscription aggregator** — `url`/`qr` print one node's link; nothing
  base64-concatenates all node links.

### B.4 Sub-Store — backend-only, no auth, fs-bound

- Node.js Express backend (frontend is the separate hosted SPA at
  `sub-store.vercel.app`). Storage = flat JSON files (`sub-store.json` +
  `root.json`) under `/opt/app/data`. **Not a DB.**
- Rich REST API: `/api/subs` (POST = create one; **PUT = replace whole array**),
  `/api/collections`, `/api/files`, `/api/artifacts`, `/api/sync/artifacts`
  (push to GitHub Gist), `POST /api/proxy/parse` (stateless conversion),
  client-facing `GET /download/:name/:target` and token-gated
  `GET /share/sub|col/:name/:target?token=`.
- Producers: `clash/meta/surge/loon/singbox/v2ray/quanx/stash/…`; target chosen
  by `/:target` path, `?target=`, or UA sniffing.
- **AUTH: none on the management API.** Protected only by network binding +
  secret backend path + reverse proxy. A companion MUST front it.
- **Import hook:** `POST /api/subs {name, source:'local', content:'<links>'}`
  (content accepts newline share-links / base64 / clash yaml) or `PUT /api/subs`
  to bulk-replace. This is exactly how vpn-core feeds it.
- **CF Worker:** not natively portable (fs persistence, node cron/child_process).
  Two viable edge paths: (a) Worker/separate-domain **reverse-proxy + cache in
  front of `/download` + `/share`** (token + optional age encryption make these
  safe to expose), or (b) **gist-artifact** sync → Worker serves the public gist
  raw URL.

---

## C. Target architecture

```
                         ┌────────────────────────────── lattice-server (CORE) ──────────────────────────────┐
                         │                                                                                     │
  operator ──HTTPS──▶ Dashboard (Vue)                                                                          │
                         │   PluginsView + NEW vpn-core / sub-store admin views (core-served)                  │
                         │                                                                                     │
                         │   CORE engines (STAY in core): Approval/Task state machine, plan→approve→apply,     │
                         │     RBAC, encrypted store, scheduler, notify, audit, SSRF guard, agent task queue   │
                         │                                                                                     │
                         │   Plugin RuntimeManager ── Broker (capability-scoped, audited) ──┐                  │
                         │      host svcs: KV · Notify · HTTP · Log · Audit                  │                  │
                         │      NEW host svcs: Task(plan/apply) · RPC(inter-plugin) ─────────┤                  │
                         │                                                                   ▼                  │
                         │   ┌─────────── system runner (NEW, Tier-2) ───────────┐   ┌── plugin RPC registry ──┐
                         │   │  vpn-core plugin (artifact, subprocess, stdio/gRPC)│   │  vpn-core.nodes.export  │
                         │   │   • desired-state diff → converge plan             │◀──┤  (called by sub-store)  │
                         │   │   • renders agent apply-script calling `sb --json` │   └─────────────────────────┘
                         │   │  sub-store plugin (artifact)                       │                  │
                         │   │   • supervises/own-gateways Sub-Store backend      │                  │
                         │   └────────────────────────────────────────────────────┘                  │
                         └─────────────────┬───────────────────────────────────────────────┬────────┘
                                           │ apply Task (encrypted, sh)                      │ outbound HTTP (brokered)
                                           ▼                                                 ▼
                            ┌── fleet node (lattice-node-agent) ──┐         ┌── Sub-Store backend (Node, on a node) ──┐
                            │  polls GET /api/agent/tasks         │         │  /api/subs (import) · /download · /share │
                            │  runs `sb install / add / del /     │         │  data: /opt/app/data (flat JSON)         │
                            │      list / sub --json`             │         └─────────────────────┬───────────────────┘
                            │  → /etc/sing-box/conf/*.json        │                               │ /download · /share
                            │  → systemctl reload sing-box        │                               ▼
                            │  posts /api/agent/proxy-usage       │                ┌── CF Worker / separate domain ──┐
                            └─────────────────────────────────────┘                │  cache + token gate (edge)      │
                                                                                    └── end clients (Clash/sing-box) ─┘
```

Two subscription systems coexist intentionally:

- **Native** `GET /sub/{token}` (existing, lightweight, REALITY-only) — unchanged.
- **Advanced** Sub-Store `/download` + `/share` (rules, multi-format, filtering)
  — fed by vpn-core. **First cut: private/internal + dashboard view only**;
  public edge fronting (CF Worker / domain / gist) is deferred (§G.4).

---

## D. Decision register

Legend: ✅ recommended · 🔶 **needs operator decision** · ⛔ rejected.

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | vpn-core repo placement | (a) new repo `lattice-plugin-vpn-core`; (b) dir under plugin-index; (c) keep in core only | ✅ **(a)** new first-party repo mirroring `lattice-plugin-template/system-go`, listed in `lattice-plugin-index`. Core keeps the engine. |
| D2 | Plugin runtime tier | system / worker / wasm | ✅ **system** for both (design-08 names "sing-box/xray manager" + "Sub-Store supervisor" as *the* system-runner cases). |
| D3 | Deploy transport | agent task pipeline / SSH from plugin | ✅ **agent task pipeline** (plan→approve→apply→`sh`). No SSH, no new inbound to nodes; reuses the security invariant. |
| D4 | Config-management model | (A) Lattice renders full `config.json` (current); (B) 233boy-driven on-box convergence via `sb --json` | ✅ **(B) CONFIRMED (2026-06-28)** — leverage 233boy's mature multi-protocol + TLS/REALITY-keygen + installer; Lattice holds desired state and computes an add/del/change diff. (A) remains the fallback for the existing REALITY path during migration. |
| D5 | sing-box `--json` interface | extend operator's own `sing-box` repo / wrap externally | ✅ **extend the repo** (operator asked for this). Spec in §E.2. |
| D6 | Inter-plugin RPC mechanism | new broker host-service + capability + registry / core-mediated HTTP | ✅ **broker RPC** (`plugin:call` cap + server-owned registry), with a **core-mediated interim** in Phase D before the runner ships. Spec in §F. |
| D7 | Subscription delivery | (a) CF Worker; (b) separate domain via nginx; (c) gist-artifact edge; **(d) deferred / internal-only** | ✅ **(d) DEFERRED (2026-06-28)** — first cut is internal-only (dashboard view + private access), no public links/downloads; the security scheme + edge choice are revisited later. (a)/(b)/(c) kept in §G.4 for when it's picked up. |
| D8 | Proxy core→plugin migration | big-bang / phased engine-stays-core | ⛔ big-bang. ✅ **phased** (ADR D5/D6). Data ownership migrates last (Phase E). |
| D9 | Scope/sequencing now | full extraction first / value-first (deploy + sub-store) first | ✅ **value-first CONFIRMED (2026-06-28)**: Phases A–D deliver real sing-box auto-deploy + Sub-Store + RPC; Phase E (data migration) is optional/last. |

All three operator-owned forks are now decided (2026-06-28): **D4 =
233boy-driven (`sb --json`)**, **D9 = value-first phased**, **D7 = deferred /
internal-only first**. Everything else is dictated by the existing foundation.

---

## E. The vpn-core plugin

### E.1 Plugin shape

- Repo: `lattice-plugin-vpn-core`, layout from `lattice-plugin-template/system-go`.
- Manifest (`type:"system"`, publisher `latticenet`, signed for prod):

```json
{
  "id": "latticenet.vpn-core",
  "name": "Lattice vpn-core (sing-box)",
  "type": "system",
  "version": "0.1.0",
  "publisher": "latticenet",
  "entrypoint": "system-go/lattice-plugin-vpn-core",
  "capabilities": ["node:read", "proxy:admin", "network:plan", "network:apply", "task:run", "kv:read", "kv:write", "notify:send", "rpc:expose"]
}
```

> Several of these capabilities have **no Broker method today** (§B.1). Phase C
> adds the `Task` (plan/apply/queue) and `RPC` host services that make
> `network:plan` / `network:apply` / `task:run` / `rpc:expose` callable. Until
> then vpn-core logic runs **in core** behind the same module boundary (so the
> later extraction is a move, not a rewrite).

### E.2 The 233boy `--json` contract (operator's `sing-box` repo)

Design goal: a **stable, machine-readable, never-blocks-on-TTY** surface that
reuses the existing `get file` / `get info` / `info` pipeline. Implemented by a
global flag, not by threading flags through interactive code.

1. Add `--json) is_json_out=1; shift;;` to `core.sh` `pass_args()` (alongside the
   existing `--addr` handling) so it is stripped and globally visible. (Name it
   `is_json_out` — `is_json*` names already exist.)
2. New top-of-dispatch verbs (before legacy human cases):
   - `sb list --json` → array of `{name, protocol, port, address, uuid|password,
     network, tls, sni, public_key, host, path, share_url}` for every
     `conf/*.json` (subshell `is_dont_show_info=1; get info "$f"; info`).
   - `sb info <name> --json` → one node object.
   - `sb add <proto> [k=v…] --json` → the created node object (reuses `gen`/`add`
     tail; `--addr` required to skip IP-autodetect TTY).
   - `sb del <name> --json` / `sb ddel <names…> --json` → `{deleted:[…]}`.
   - `sb change <name> <opt> <val> --json` → updated node object.
   - `sb sub [--base64] --json` → aggregated subscription
     (`printf '%s\n' "${urls[@]}" | base64 -w0`) — the missing aggregator.
   - `sb provision --json` → `{installed, version, service_active}` (wraps
     `install.sh` idempotently; this is what Phase B calls).
3. **Robustness guards** (so a headless caller never hangs): under
   `is_json_out`, at `get file`'s `ask get_config_file` branch emit a structured
   error + `exit 2`; short-circuit host-test / `ask_custom_addr` / pauses;
   require `--addr`. Suppress all human chrome (colors/ads/QR/banners) in
   `info()` and `footer_msg()`.
4. Errors: always `{"ok":false,"error":"<code>","message":"…"}` on stderr-or-
   stdout with non-zero exit; success `{"ok":true,…}`.
5. Distribution: bump `is_sh_ver` in `sing-box.sh`; installed machines pick it up
   via `sb update sh` (the release workflow `git archive`s HEAD). The agent can
   run `sb update sh` as part of provisioning to guarantee the interface version.

This is additive and backward-compatible — the interactive menu is untouched.

### E.3 Deployment path (desired-state → convergence)

Lattice stays **declarative** (operator edits inbounds/users/profiles in the
dashboard); the agent converges the box imperatively via `sb --json`:

1. **Provision** (closes the §B.2 gap): plan→approve→apply a `provision` task →
   agent runs `sb provision --json` (installs binary + systemd unit; runs
   `sb pbk` for REALITY keypair if the inbound lacks one). Records installed
   version on the `ProxyNodeProfile`.
2. **Converge**: server computes the diff between desired (profile's inbound/user
   set) and actual (`sb list --json` read back via a read task or the usage
   channel), renders an **idempotent apply script** of `sb add/del/change --json`
   calls (arg-vector, never string-interpolated secrets into a shell — secrets
   passed via a heredoc'd args file consumed by `sb`), and runs it through the
   *existing* approve→apply→agent pipeline with the *existing* trap-rollback.
3. **Export**: `sb sub --json` / `sb list --json` feed both the native
   `/sub/{token}` and (via RPC) the Sub-Store companion.
4. **Usage**: add a native sing-box stats collector to the agent
   (`-proxy-usage-singbox-api`, mirroring the xray-cli bridge) reading sing-box's
   V2Ray-stats endpoint, posting the existing `ProxyUsageSnapshot`.

Model (A) (server renders `config.json`) stays available for the
already-shipped VLESS-REALITY path so Phase B can ship before the `--json`
interface lands — the two converge in Phase C.

### E.4 Data & migration

Phase B–D: proxy data stays in `store.State` (core), encrypted as today;
vpn-core logic is a core module with a clean interface. Phase E: introduce a
**plugin-scoped encrypted KV/state** (the foundation lacks plugin
encryption-at-rest — a prerequisite, ADR §8), migrate the 4 collections behind
the plugin's data interface, and replace the hardcoded `server.go` switches with
a registered provider hook. Subscriptions stay derived from `SubToken`.

---

## F. Inter-plugin interface contract (new)

None exists (`interPluginIPC: NONE`). Invent it at the **broker layer** — the
ADR-recommended place to freeze the host-API before runners ship.

- **Capabilities:** `rpc:expose` (callee registers a service) and `rpc:call`
  (caller invokes). Both `host`-risk → require trusted-publisher signature in
  prod. Add to `capabilityRisk` in `plugin.go`.
- **Host service:** new `HostServices.RPC` + `Broker.RPCCall(ctx, service,
  method, reqJSON) → respJSON`, gated by `require("rpc:call")`, audited via the
  existing `RecordHostCall` (`plugin.host.rpc.call`).
- **Registry:** server-owned `map[serviceID]→{pluginID, handler, version,
  methods}`. A plugin with `rpc:expose` registers `serviceID =
  "<pluginID>/<service>"` (e.g. `latticenet.vpn-core/nodes`). Discovery via a
  brokered `RPC.List()` returning service descriptors.
- **Authorization:** operator must grant a directed edge "sub-store **may call**
  vpn-core" (an allowlist in trust policy / a `rpc.grants` config), enforced at
  `RPCCall`. Confused-deputy defense mirrors the KV `plugin:<id>` pinning.
- **Versioning:** descriptor carries `service@vN`; calls specify the major;
  unknown service/method → structured `ErrRpcNoService`/`ErrRpcNoMethod`.
- **Shape:** request/response are JSON with the broker's existing byte caps;
  synchronous request/response only (no streaming in v1).

vpn-core exposes:

```
service latticenet.vpn-core/nodes @v1
  method export(filter?:{node_ids?,group?,enabled_only?}) ->
        { nodes:[{name, protocol, share_url, host, port, tags[]}], generated_at }
  method subscription(user_token?) -> { base64, plain, count }
```

The Sub-Store companion calls `nodes.export` and pushes the result into
Sub-Store (§G.2).

**Interim (Phase D, before the runner exists):** since both are first-party and
data lives in core, the sub-store companion can call a **core HTTP endpoint**
(`GET /api/proxy/export` with `proxy:read`) that returns the same shape. The RPC
contract above is the durable form; the HTTP endpoint is the bridge so Sub-Store
integration ships without waiting on the system runner.

---

## G. The Sub-Store companion plugin

### G.1 Shape & responsibilities

- Repo `lattice-plugin-sub-store`, `type:"system"`, capabilities
  `["http:egress","kv:read","kv:write","rpc:call","notify:send"]`.
- It does **not** reimplement Sub-Store. It **supervises/integrates** the
  operator's existing `xream/sub-store` container and adds the three missing
  pieces: (1) an **auth gateway** (Sub-Store's management API has none), (2)
  **import-from-vpn-core**, (3) **edge delivery** wiring.
- Deployment of the Sub-Store backend itself reuses the agent task pipeline
  (run/ensure the `docker run … xream/sub-store` unit on a chosen node), exactly
  like vpn-core provisions sing-box — "Sub-Store supervisor" is design-08's named
  case.

### G.2 Import-from-vpn-core flow

1. Companion calls `vpn-core/nodes.export` (RPC; interim: core
   `/api/proxy/export`).
2. Maps nodes → share-links → `PUT /api/subs` (bulk-replace a managed
   subscription, e.g. `lattice-vpn-core`, `source:'local', content:'<links>'`),
   or `POST /api/subs` per logical group. Optionally creates a `collection`
   grouping them with the operator's rule `process[]` operators.
3. Triggered on vpn-core change (notify/event) and on a schedule. Idempotent
   (PUT replaces), so re-runs converge.
4. The operator's existing rules/filters in Sub-Store keep applying — we only
   own the *source*, not the *rules*.

### G.3 Auth gateway

The companion exposes Sub-Store's API **only** through itself (bind Sub-Store to
loopback / a private network; the agent + companion are the only callers). The
public surface is just the output routes via the edge (§G.4). This fixes the
"anyone on the port owns the DB" problem without modifying Sub-Store.

### G.4 Subscription delivery — DEFERRED (internal-only first)

**Operator decision 2026-06-28:** the first cut exposes **no public
subscription links/downloads**. Sub-Store output is reachable only from the
private network + viewable in the dashboard; the public-delivery design and its
security model are revisited later. The options below are retained for that
later decision and are **not built in Phases A–E** unless re-scoped.

First-cut posture (internal-only):

- Sub-Store backend bound to loopback / private net; only the agent + companion
  call it. The dashboard renders the produced subscription (read-only preview
  via the companion, e.g. proxying `GET /download/:name/:target` server-side for
  display) so the operator can *see* and copy config, but no public URL exists.
- No CF Worker, no separate domain, no gist sync wired.

Later options (when picked up — Sub-Store cannot run on a Worker, it is fs-bound,
so deliver its **output** at the edge, not the whole backend):

- **CF Worker / separate domain reverse-proxy + cache** in front of
  `GET /download/:name/:target` and token-gated `GET /share/sub|col/:name/:target`
  only. The Worker terminates the public domain, caches by
  `(name,target,token)` with a short TTL, and forwards to the private Sub-Store
  backend. Sub-Store's **share tokens + optional age encryption** already make
  these routes safe to expose. The management API never leaves the private net.
- Alt **gist-artifact edge**: companion triggers `GET /api/sync/artifacts`
  (Sub-Store pushes produced outputs to a GitHub Gist with a public raw URL);
  the Worker serves the gist — fully off-box, no live backend on the request
  path. Good for pure read scale; staler.
- The operator picks the public hostname; Lattice stores it on the companion
  config and surfaces the final subscription URLs in the dashboard.

---

## H. Dashboard UX

The plugin foundation has **no plugin-served UI** (and adding one is large), so
both plugins surface as **core-served Vue views** under the existing Proxy
section, plus the existing `PluginsView` for lifecycle:

- **Proxy → Inbounds/Users/Profiles/Usage**: keep current views; add a
  **Deploy** action on a node profile (provision sing-box → status badge:
  *not-installed / installing / active / drift*), and a protocol picker widened
  to what `sb --json` supports.
- **Proxy → Subscriptions**: show both the native `/sub/{token}` URL and the
  Sub-Store-backed advanced subscription (with the chosen edge domain), copy/QR.
- **Platform → Plugins**: vpn-core + sub-store appear with lifecycle controls
  (install/verify/enable/disable) and runtime health, via the existing
  `/api/plugins/*`.
- A small **Sub-Store** admin card: backend reachability, last import time, node
  count pushed, edge URL, "re-import now".

(If/when design-08's "future route/static APIs" land, these can migrate to
plugin-served pages — out of scope here.)

---

## I. Migration & rollout (phased, non-breaking)

| Phase | Deliverable | Touches | Ships without |
|---|---|---|---|
| **A** | `sb --json` interface + `sb sub` aggregator + TTY guards | operator's `sing-box` repo only | any Lattice change |
| **B** | sing-box **auto-provision** (install + unit + REALITY keygen) + native sing-box usage collector | core proxy module + agent | plugin runtime, RPC |
| **C** | **Tier-2 system runner** (design-08) + `Task`/`RPC` broker host-services + vpn-core as proof case | `internal/plugin`, `internal/server` | data migration |
| **D** | **Sub-Store companion** (supervise + import via interim core `/api/proxy/export` + **internal-only** dashboard view; **no public edge**) | new repo + core export endpoint | full broker RPC, public delivery |
| **E** | migrate proxy **data ownership** into the plugin (plugin encrypted state), replace hardcoded `server.go` switches, cut over RPC | `internal/store`, `internal/server`, plugin | — |

Checkpoints per phase: `GOWORK=off go -C lattice-server build/test ./...` +
`go test -race ./internal/plugin ./internal/server` (design-08 gate) +
`pnpm build` (dashboard) + the operator's manual smoke on a canary node
(gomami-hkg precedent). No phase deploys to prod without explicit approval.

Highest value lands at **Phase B** (real auto-deploy) — independent of the whole
plugin-runtime track.

---

## J. Security model

- **No new node ingress.** All on-box action flows agent-polled task → sandboxed
  `sh` → `sb`/`docker`, with the existing trap-rollback. Reuses the
  plan→approve→apply audit + approval gate (design-08: host mutation never
  bypasses approvals).
- **Secrets** (UUID/password/REALITY key/SubToken) stay encrypted at rest in the
  core store; apply scripts carry them only inside the already-encrypted
  `model.Task.Script`; `sb` receives secrets via an args file, never
  string-interpolated into a shell command line (avoids `ps`/history leak).
- **`sb --json` headless hardening** (§E.2 step 3) prevents a stuck agent task
  from hanging on a TTY prompt (current `ask()` spins on closed stdin).
- **Plugin capabilities** are signed + deny-by-default; `network:apply`,
  `task:run`, `rpc:call/expose` are host-risk → trusted-publisher signature
  required in prod (`AllowUnsignedHostRisk=false`).
- **Inter-plugin RPC** is capability-gated, directed-allowlist authorized,
  audited, and byte-capped; no shared KV namespace (confused-deputy defense
  preserved).
- **Sub-Store** is moved behind a private bind + companion gateway; only
  token/age-protected `/download`+`/share` reach the public edge. The
  plaintext `gistToken` in Sub-Store settings never leaves the private net.
- **Subscription tokens** keep the existing rotate path; edge caching respects
  `no-store` semantics for native `/sub/{token}` and short-TTL only for
  token-scoped Sub-Store output.

---

## K. Risks & open questions

1. **Two config brains** (Model B): 233boy's `conf/*.json` vs Lattice desired
   state can drift if someone edits the box directly. Mitigation: `sb list
   --json` read-back + drift surfacing; treat Lattice as authoritative,
   reconcile on apply.
2. **System runner is net-new and security-sensitive** (design-08 §test plan has
   10 gates). It is the long pole; Phases A/B/D-interim deliberately avoid
   depending on it.
3. **Plugin encrypted state** doesn't exist (ADR §8 names the state file the
   "crown jewel"). Phase E is blocked on building it — hence kept last.
4. **sing-box stats API** shape (V2Ray-stats over which transport) must be
   verified against the operator's sing-box version before the native collector.
5. **AnyTLS/Caddy nodes need a real domain + ACME** — provisioning must surface
   when a node lacks DNS (ties into the existing DDNS/georouting domains).
6. **CF Worker caching correctness** for per-user tokens — must key cache by
   token and keep TTL short to avoid serving stale/cross-user output.
7. **Operator decisions (2026-06-28):** D4 = 233boy-driven (`sb --json`),
   D9 = value-first phased, D7 = **deferred** (internal-only first; public
   delivery + its security model TBD). See §D. The one still-open item is the
   eventual public-delivery security scheme (revisit before any §G.4 edge work).

---

## Appendix — key source references

- Foundation: `internal/plugin/{plugin,loader,broker,runtime}.go`,
  `internal/server/plugin_host.go`, `PluginsView.vue`, `design-08`, `adr-001`,
  `lattice-plugin-template/`, `lattice-plugin-index/`.
- Proxy: `model.go` (Proxy* 534–674), `internal/store/{store,crypto,bolt_state}.go`,
  `internal/server/server_proxy*.go` (+ `server.go` switches 3749/4221/4247/4514),
  `internal/proxycore/{singbox,xray,links}.go`, agent `internal/proxyusage/`,
  `design-01`, iters 039–055.
- 233boy script: `…/sing-box/{install.sh,sing-box.sh,src/*.sh}`.
- Sub-Store: `…/Sub-Store/backend/src/{main.js,restful/*,core/proxy-utils/*,
  vendor/{express,open-api}.js,utils/{database,gist}.js,constants.js}`.
