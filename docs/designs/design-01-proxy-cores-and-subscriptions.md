# Design 01 — Proxy-Core Orchestration & Subscription Management

> Status: foundation in progress · Author: framework design pass · Date: 2026-06-13 · Updated: 2026-06-14
> Scope: lattice-server (core providers) + lattice-node-agent (executor) + lattice-sdk (model) + lattice-dashboard (later phase)
> Constraints honored: pure Go, zero CGo, tiny dep surface, security-first, fail-closed, plan→approve→apply for node changes.

This is the flagship feature: Lattice becomes the **central control plane for a fleet of nodes each running a proxy core (sing-box and/or xray)**, with **user/inbound modeling and subscription generation/serving** — a self-hosted remnawave/3x-ui replacement that reuses Lattice's existing trust, networking, DDNS, notify, and audit machinery instead of bolting on a new daemon.

---

## 1. Goal & scope

### What it does (v-complete vision)
- The operator defines, **centrally**, a set of **inbounds** (protocol + transport + TLS + port) and **users/clients** (UUID/password + traffic limits + expiry).
- The server renders a **per-node proxy-core config** (sing-box `config.json` and/or xray `config.json`) from that central model + a per-node profile (which inbounds run where, which cert/SNI, which listen IP).
- A node-agent **deploys and reloads** its proxy core through the existing **plan → approve → apply** flow (config is rendered server-side, operator approves the diff, the agent writes the config and reloads the core).
- The server **generates and serves subscriptions**: per-user links (`vless://`, `vmess://`, `trojan://`, `hysteria2://`, `ss://`) aggregated across the nodes that user is provisioned on, served as plaintext, base64, sing-box JSON, and Clash/Clash.Meta YAML at a tokenized URL.
- Traffic accounting and online/expiry state flow back from agents via the existing metrics/event path and gate subscription output (expired/over-quota users disappear from their subscription and, in v2, are disabled in the rendered config).
- It **coexists** with monitoring, DDNS (proxy node hostnames auto-published to `*.dns.roobli.org`), notify (expiry/quota/node-down alerts), nft (per-node access rules), and the WireGuard mesh (cores can bind to mesh IPs).

### Explicit non-goals for v1
- **No xray in MVP.** sing-box only (single JSON config model, actively maintained, broad protocol coverage). xray is a v2 second renderer behind the same abstraction.
- **No real-time traffic enforcement loop.** v1 accounting is *poll-and-report* (agent reads core stats API periodically); hard cut-off at the core happens in v2, not on the data-path millisecond.
- **No reseller/multi-tenant billing, no payment, no ticketing.** Single-operator fleet. (remnawave's HWID/device-limit, billing, and tenant hierarchy are out.)
- **No node-side admin UI / no second web panel.** Lattice's dashboard is the only console. Nodes run a headless core + the existing agent.
- **No automatic certificate issuance in v1.** Certs are referenced by node-local path (operator provisions via existing CF Tunnel / their own ACME). ACME-via-core is v2+.
- **No plugin packaging in v1.** This ships as a **core server-owned provider** (see §2), not a third-party plugin.
- **No inbound control connection to nodes.** Unchanged Lattice invariant: the agent only dials out and polls.

---

## 2. System fit

| Lattice layer | Role in this feature |
|---|---|
| **Server (policy)** | Sole owner of the proxy model (inbounds, users, node profiles, subscription tokens). Renders every per-node config. Renders every subscription. Owns all secrets. Emits all audit events. Nodes are told *what* to run, never trusted to decide. |
| **Agent (executor)** | Least-trust. Polls `/api/agent/tasks`, receives an **apply task** carrying the rendered core config, writes it, validates it (`sing-box check`), reloads the core, reports exit/stdout. Reads core stats and reports usage via a new agent event. Never sees other nodes' configs or the central user DB. |
| **plan → approve → apply** | The deployment path, identical to nft/WireGuard/cftunnel. `POST /api/proxy/nodes/{id}/plan` renders the config and creates a `model.Approval{Plugin:"proxycore"}`; `POST /api/network/approve` (existing handler) with `queue_apply` + required `plan_sha256` queues the apply task. **Reuse the existing approve endpoint and `applyScriptFor` switch — add one `case "proxycore"`.** |
| **store** | New collections on `State` (inbounds, proxy users, node profiles, subscriptions, usage snapshots). Secret fields routed through `internal/store/crypto.go` (§3). |
| **RBAC** | New scopes `proxy:read` / `proxy:admin` (mutations) reuse `network:plan`/`network:apply` for the deploy step, exactly as WireGuard does. Per-node allowlist (`ServerAllowlist`) already gates which nodes an operator can touch. |
| **notify** | Reuse `internal/notify` fan-out for: user expiry (T-7/T-1/expired), quota threshold (80%/100%), and core-down (core process unhealthy) — same dispatcher as monitor/SSH alerts. |
| **ddns** | Reuse `internal/ddns`: a proxy node's hostname (`gmami-jp1.dns.roobli.org`) is just a DDNS-bound name; subscription links use that hostname so links survive IP changes. No new DNS code. |
| **nft** | Reuse `internal/network/nft` for the operator's per-node access rules ("deny node X reaching dmit:1234") and to restrict the core's listen exposure. Orthogonal subsystem; this design only *references* it. |
| **monitor** | Reuse to health-check each core's inbound port (a `tcp` monitor on the inbound `host:port`), feeding the same up/down alerting. |
| **outbound (SSRF guard)** | Any server→external fetch (none required in v1; subscriptions are served, not fetched) uses `internal/outbound`. The subscription *aggregator* is internal-only. |

### CORE-provider vs plugin — decision: **CORE server-owned provider.** 

Rationale, opinionated:
1. **It owns secrets and policy.** Subscription tokens, user UUIDs/passwords, and the per-user traffic ledger are exactly the class of state Lattice already encrypts at the store boundary (like DDNS tokens, OIDC client secrets). A third-party plugin getting `kv:read` over that is a strictly worse trust posture.
2. **It *is* the plan→approve→apply flow.** That flow lives in core server packages (`internal/network`, `internal/wireguard`, `internal/cftunnel`). The plugin host-API broker deliberately does **not** expose "render an apply task and queue it to an agent" — and it shouldn't; that's the crown-jewel capability. ddns and notify are core providers for the same reason; proxy orchestration is the same shape, one tier more sensitive.
3. **The plugin runtime can't run artifacts yet** (PRODUCT-VISION P3/Phase B: "plugin artifacts don't execute yet"). Building the flagship feature on an unfinished runtime would block it on Phase B.
4. **It still leaves room for plugins.** Per-protocol *link formatters* or *subscription format adapters* are good candidates for later `worker`-tier plugins (pure template rendering, the bootstrap worker runtime already does safe template + KV interpolation). The *orchestration core* is server-owned; *cosmetic format extensions* can be pluggable later. The architecture doc's plugin list even reserves "sing-box, xray, Sub-Store supervision" as `system` (trusted built-in) plugins — confirming these are built-ins, not community wasm.

The new server code lives in **`internal/proxycore/`** (rendering, models helpers, subscription encoders) with HTTP handlers in **`internal/server/server_proxy.go`** (server.go is 3519 lines — new handlers go in a dedicated file, mirroring `server_oidc.go`).

---

## 3. Data model

All structs go in `lattice-sdk/model/model.go` (shared wire model). New `State` map collections go in `internal/store/store.go`. Secret-at-rest fields are listed in §3.4 and **must** be added to `internal/store/crypto.go` + `stateHasEnvelope`.

**Landed in iter-039:** the shared SDK structs/constants, secret-free proto
view contracts, JSON-store collections/CRUD, record-level bbolt buckets/CRUD,
and at-rest encryption for `RealityPrivateKey`, `UUID`, `Password`, and
`SubToken`.

**Landed in iter-040:** the first server-side sing-box renderer for
`vless`+TCP+REALITY. It emits a canonical secret-bearing config artifact with a
SHA-256 and fail-closed structural validation, omits disabled/expired/over-quota
users, rejects unsupported transport/protocol combinations, and is covered by
table-driven tests. Iter-041 through iter-047 have since landed HTTP CRUD,
reviewed plan/apply, public subscriptions, the first dashboard workflow,
baseline usage reporting, and sing-box JSON plus Clash/Mihomo YAML subscription
formats for the supported VLESS+REALITY+TCP path. Direct core stats collectors
and xray remain pending.

**Landed in iter-041:** scoped JSON CRUD/read APIs for central inbounds, central
users, and per-node profiles. The JSON views mirror the proto view contract:
global inbounds/users require unrestricted `proxy:read`/`proxy:admin`, profiles
are node-allowlist filtered, and views expose only `has_*` booleans for
credential material. Plan/apply, dashboard UI, usage reporting, and public
subscriptions were intentionally deferred to later slices and have now landed
incrementally through the iter-047 subscription-format slice.

**Landed in iter-042:** `POST /api/proxy/nodes/{node_id}/plan` creates a
pending `Plugin:"proxycore"` approval from the current profile/inbounds/users.
The review plan contains a redacted sing-box config, while the stored approval
action binds the SHA-256 of the real rendered config. Approval re-renders and
rejects stale plans. `queue_apply:true` deliberately fails closed until the
apply slice lands.

### 3.1 Inbounds (central, node-agnostic template)

```go
const (
    ProxyCoreSingbox = "sing-box"
    ProxyCoreXray    = "xray" // v2

    InboundVLESS    = "vless"
    InboundVMess    = "vmess"
    InboundTrojan   = "trojan"
    InboundShadowsocks = "shadowsocks"
    InboundHysteria2   = "hysteria2"
)

// ProxyInbound is a protocol/transport template, independent of which node runs
// it. It carries NO per-user secrets — clients are joined in at render time.
type ProxyInbound struct {
    ID        string `json:"id"`
    Name      string `json:"name"`           // operator label, e.g. "vless-reality-443"
    Core      string `json:"core"`           // sing-box | xray
    Protocol  string `json:"protocol"`       // vless | vmess | trojan | shadowsocks | hysteria2
    Listen    string `json:"listen,omitempty"` // bind addr, default "::" ; may be a mesh IP
    Port      int    `json:"port"`

    Transport string `json:"transport,omitempty"` // tcp | ws | grpc | http2 | quic
    Path      string `json:"path,omitempty"`      // ws/grpc path
    Host      string `json:"host,omitempty"`       // ws/http Host header / SNI for links

    Security  string `json:"security,omitempty"`  // none | tls | reality
    SNI       string `json:"sni,omitempty"`
    ALPN      []string `json:"alpn,omitempty"`
    Fingerprint string `json:"fingerprint,omitempty"` // uTLS fp for reality links

    // TLS material is referenced by node-local path, never uploaded (mirrors
    // TunnelProfile.CredentialsFile). Empty => core uses reality or plaintext.
    CertPath  string `json:"cert_path,omitempty"`
    KeyPath   string `json:"key_path,omitempty"`

    // REALITY (secret-at-rest): server private key stays on the server; the
    // public key + short IDs are embedded in user links.
    RealityPrivateKey string   `json:"reality_private_key,omitempty"` // SECRET
    RealityPublicKey  string   `json:"reality_public_key,omitempty"`
    RealityShortIDs   []string `json:"reality_short_ids,omitempty"`
    RealityDest       string   `json:"reality_dest,omitempty"` // steal-oneself target, e.g. "www.microsoft.com:443"

    // Shadowsocks method (cipher); per-user password lives on ProxyUser.
    SSMethod  string `json:"ss_method,omitempty"`

    Enabled   bool      `json:"enabled"`
    CreatedAt time.Time `json:"created_at"`
    UpdatedAt time.Time `json:"updated_at"`
}
```

### 3.2 Users / clients (central, one identity reused across nodes)

```go
// ProxyUser is one subscriber identity. The same user is multiplexed onto many
// node profiles; their credential is stable so a single subscription URL spans
// the fleet. Traffic/expiry are server-authoritative gates on subscription
// output (and, v2, on rendered config inclusion).
type ProxyUser struct {
    ID       string `json:"id"`
    Name     string `json:"name"`     // label, e.g. "alice"
    Enabled  bool   `json:"enabled"`

    // Credential material (SECRET). UUID drives vless/vmess; Password drives
    // trojan/ss/hy2. Server generates on create; never regenerated implicitly.
    UUID     string `json:"uuid,omitempty"`     // SECRET
    Password string `json:"password,omitempty"` // SECRET

    // Subscription access token (SECRET) — the unguessable path segment.
    SubToken string `json:"sub_token,omitempty"` // SECRET, 32-byte base64url

    // Provisioning: which inbounds (by ID) this user is allowed on. Empty => all
    // enabled inbounds. Node membership is derived (an inbound runs on a node
    // via ProxyNodeProfile), so users are inbound-scoped, not node-scoped.
    InboundIDs []string `json:"inbound_ids,omitempty"`

    // Limits — server-authoritative.
    TrafficLimitBytes int64     `json:"traffic_limit_bytes,omitempty"` // 0 = unlimited
    ExpiresAt         time.Time `json:"expires_at,omitempty"`          // zero = no expiry

    // Usage rollup (server-maintained from agent reports; see ProxyUsageSnapshot).
    UsedBytes   int64     `json:"used_bytes"`
    LastSeenAt  time.Time `json:"last_seen_at,omitempty"`
    Status      string    `json:"status"` // active | expired | over_quota | disabled

    CreatedAt time.Time `json:"created_at"`
    UpdatedAt time.Time `json:"updated_at"`
}
```

### 3.3 Per-node profile (what runs where)

```go
// ProxyNodeProfile binds inbounds to a node and pins node-specific render facts.
// One per node. This is the unit a plan/apply targets.
type ProxyNodeProfile struct {
    ID         string   `json:"id"`
    NodeID     string   `json:"node_id"`
    Core       string   `json:"core"`            // sing-box (v1)
    InboundIDs []string `json:"inbound_ids"`      // which central inbounds this node serves
    Hostname   string   `json:"hostname,omitempty"` // public name for links, e.g. gmami-jp1.dns.roobli.org
    ListenIP   string   `json:"listen_ip,omitempty"` // override inbound.Listen on this node

    // Where the agent writes/reads on the node.
    ConfigPath string `json:"config_path,omitempty"` // default /etc/sing-box/config.json
    StatsAPI   string `json:"stats_api,omitempty"`   // local clash-api/stats addr, e.g. 127.0.0.1:9090

    // Rollout status (server-maintained).
    AppliedSHA256 string    `json:"applied_sha256,omitempty"` // last config hash confirmed applied
    LastApplyAt   time.Time `json:"last_apply_at,omitempty"`
    LastError     string    `json:"last_error,omitempty"`
    CreatedAt     time.Time `json:"created_at"`
    UpdatedAt     time.Time `json:"updated_at"`
}
```

### 3.4 Usage reporting

```go
// ProxyUsageSnapshot is one accounting report from a node: cumulative bytes per
// (user, inbound) since the core last started. The server diffs against the
// previous snapshot to advance ProxyUser.UsedBytes monotonically (handling core
// restarts by resetting the baseline when a counter regresses).
type ProxyUsageSnapshot struct {
    NodeID    string             `json:"node_id"`
    At        time.Time          `json:"at"`
    CoreUptimeSec uint64         `json:"core_uptime_sec"`
    // map[userID] -> bytes (up+down) reported by the core stats API.
    UserBytes map[string]int64   `json:"user_bytes"`
}
```

### Store collections (add to `State`)
```go
ProxyInbounds  map[string]model.ProxyInbound      `json:"proxy_inbounds"`
ProxyUsers     map[string]model.ProxyUser         `json:"proxy_users"`
ProxyProfiles  map[string]model.ProxyNodeProfile  `json:"proxy_profiles"`
// last snapshot per node, for monotonic diffing (capped/ephemeral):
ProxyUsage     map[string]model.ProxyUsageSnapshot `json:"proxy_usage"`
```
Plus CRUD methods mirroring the DDNS/Monitor pattern: `UpsertProxyInbound`, `ProxyInbound(id)`, `ProxyInbounds()`, `ProxyUsersForInbound`, `ProxyProfileForNode(nodeID)`, etc.

### Secret-at-rest fields (route through `internal/store/crypto.go` + extend `stateHasEnvelope`)
- `ProxyInbound.RealityPrivateKey`
- `ProxyUser.UUID`, `ProxyUser.Password`, `ProxyUser.SubToken`

Rationale: UUID/password/sub-token are reversible bearer credentials (leak = account takeover / free transit / subscription theft), exactly the encrypted class already documented in crypto.go (DDNS token, OIDC secret, notify config). List/GET APIs **must** strip these (return only `has_uuid: true`, masked, or the derived link) like the DDNS/notify list APIs already do.

Iter-039 encrypts `SubToken` at rest. Iter-044 deliberately chose a
constant-time full scan over decrypted `ProxyUser.SubToken` for the first public
`/sub/{token}` endpoint instead of a persisted token index, so raw subscription
tokens are not map keys and no new secret-bearing lookup field is introduced.
The admin upsert path now rejects duplicate `sub_token` values; if legacy dirty
state ever contains duplicates, the public endpoint fails closed with `404`.

---

## 4. Server API

New handlers in `internal/server/server_proxy.go`, registered in the existing mux. Scopes: `proxy:read` (GET), `proxy:admin` (mutations), reuse `network:plan`/`network:apply` for deploy. All list/GET responses use **view structs** that strip secret fields (mirroring `toApprovalView`, DDNS/notify list shaping).

### Landed bootstrap JSON routes (iter-041)

These follow the current Lattice convention used by DDNS/DNS/NetPolicy:
collection `GET`/`POST` plus explicit `POST .../delete`.

| Method | Path | Scope | Request → Response |
|---|---|---|---|
| GET | `/api/proxy/inbounds` | `proxy:read` + unrestricted server allowlist | → `{inbounds: []ProxyInboundView}` (no reality private key) |
| POST | `/api/proxy/inbounds` | `proxy:admin` + unrestricted server allowlist | full MVP `ProxyInbound` upsert → `ProxyInboundView`; write-only `reality_private_key` is preserved on update; automatic keypair generation is pending |
| POST | `/api/proxy/inbounds/delete` | `proxy:admin` + unrestricted server allowlist | `{id, force?}` → `{ok:true}`; rejects referenced inbounds unless `force` |
| GET | `/api/proxy/users` | `proxy:read` + unrestricted server allowlist | → `{users: []ProxyUserView}` (no UUID/password/token) |
| POST | `/api/proxy/users` | `proxy:admin` + unrestricted server allowlist | full `ProxyUser` upsert → `ProxyUserView`; UUID/sub-token are generated when absent and preserved on update |
| POST | `/api/proxy/users/rotate-sub-token` | `proxy:admin` + unrestricted server allowlist | `{id}` → `{user, subscription_url, token_sha256}`; returns the raw URL/path only in this explicit response and invalidates the old token |
| POST | `/api/proxy/users/delete` | `proxy:admin` + unrestricted server allowlist | `{id}` → `{ok:true}` |
| GET | `/api/proxy/profiles` | `proxy:read` + node allowlist | → `{profiles: []ProxyNodeProfileView}` filtered to visible nodes |
| POST | `/api/proxy/profiles` | `proxy:admin` + node allowlist | full node profile upsert → view |
| POST | `/api/proxy/profiles/delete` | `proxy:admin` + node allowlist | `{node_id}` → `{ok:true}` |
| POST | `/api/proxy/nodes/{node_id}/plan` | `network:plan` on node + unrestricted `proxy:read` | `{}` → `ApprovalView`; plan text redacts secrets and action binds real config SHA |
| GET | `/api/proxy/usage` | `proxy:read` + unrestricted server allowlist | → `{snapshots, users}`; secret-free usage rollup for dashboard accounting |

### Deployment/subscription routes

| Method | Path | Scope | Request → Response |
|---|---|---|---|
| POST | `/api/network/approvals/approve` | `network:apply` on node | Existing handler; for `proxycore`, approval requires `plan_sha256`, re-renders the current desired config, rejects stale SHA, and `queue_apply:true` creates the validated sing-box apply task |
| **GET** | `/sub/{token}` | **public (token-auth)** | -> subscription body (format negotiated, see §6); iter-044 supports `format=base64` default and `format=plain`; iter-047 adds `format=sing-box`, `format=clash`, and `format=clash-meta` (`clash.meta` / `clashmeta` aliases); rate-limited via a dedicated `internal/ratelimit` bucket; never requires a session |

Agent-facing (bearer node-token auth, like existing `/api/agent/*`):
| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/agent/proxy-usage` | node token | agent reports `ProxyUsageSnapshot` |

The plan endpoint is the only new "dangerous" surface; it produces a diffable plan and **never** mutates the node. Approve/apply is the unchanged shared path. The `/sub/{token}` endpoint is the one public, unauthenticated-by-session route — it is guarded by an unguessable per-user token, constant-time scanned, rate-limited before credential lookup, and emits `proxy.subscription.fetch` audit events without raw token material.

**Implementation note after iter-041:** the bootstrap JSON API uses the existing
project convention (`POST .../delete`) rather than path-param `DELETE` routes:
`/api/proxy/inbounds/delete`, `/api/proxy/users/delete`, and
`/api/proxy/profiles/delete`. The first CRUD slice is intentionally MVP-limited:
it accepts only `sing-box` + `vless` + TCP + REALITY until more renderers are
implemented. It preserves write-only secrets on update but does **not** generate
REALITY keypairs yet; key generation remains in the planned `reality.go` slice.

**Implementation note after iter-043:** the plan endpoint is secret-free for
reviewers. It does **not** put the real rendered config into `Approval.Plan`; it
stores only a redacted review plan and the real config hash. `queue_apply:true`
is now enabled because `model.Task.Script` is encrypted at rest in both JSON and
bbolt stores. The queued task still carries the real sing-box config to the
owning node, so future task/artifact fields must not bypass `internal/store/crypto.go`.

**Implementation note after iter-046:** `/api/agent/proxy-usage` is landed as a
low-trust accounting endpoint. The server forces `node_id` from the
authenticated request, filters counters to users eligible for that node's
profile, treats the first snapshot as a baseline, diffs later snapshots
monotonically, handles `core_uptime_sec` decreases as resets, and serializes
the read-diff-update sequence with a dedicated mutex. `/api/proxy/usage`
returns only secret-free counters/status.

**Implementation note after iter-047:** `/sub/{token}` now derives every public
format from a shared `VLESSRealityEndpoint` projection rather than from
secret-bearing control-plane structs. Besides plain/base64 URI bodies, it emits
sing-box client JSON (`application/json`) and Clash/Mihomo YAML (`text/yaml`)
for the supported VLESS+REALITY+TCP shape. The API now accepts a constrained
`fingerprint` value on `ProxyInbound` because the subscription formatter
consumes it as client uTLS metadata.

---

## 5. Agent responsibilities

The agent does **not** gain inbound ports or new trust. Iter-046 adds the first
proxy accounting bridge (`internal/proxyusage`) and keeps core-specific stats
polling behind the same `ProxyUsageSnapshot` contract for later slices.

### Apply-task contract (reuses existing task plumbing)
The server's `applyScriptFor(approval)` has `case "proxycore"`. The rendered task is an ordinary `model.Task{Interpreter:"sh"}` the agent already knows how to run sandboxed. The script:
```sh
set -e
umask 077
command -v sing-box >/dev/null
TARGET=/etc/sing-box/config.json
CANDIDATE="${TARGET}.lattice-new"
BACKUP="${TARGET}.lattice-prev"
mkdir -p "$(dirname "$TARGET")"
cat > '/etc/sing-box/config.json.lattice-new' <<'LATTICE_SB_EOF'
<rendered config.json>
LATTICE_SB_EOF
sing-box check -c "$CANDIDATE"          # fail-closed: bad config never goes live
if [ -e "$TARGET" ]; then
  cp -p "$TARGET" "$BACKUP"
fi
mv -f "$CANDIDATE" "$TARGET"
systemctl reload sing-box 2>/dev/null \
  || systemctl restart sing-box
```
If systemd is unavailable, the actual script attempts `service sing-box reload`
and then `service sing-box restart`; if no supported service manager can
activate the checked config, the task exits non-zero. This mirrors the
cftunnel/wireguard shape where possible: heredoc-write + validate + reload, all
via the sandboxed `sh` interpreter with the existing
rlimits/process-group-kill/output-cap. **No new interpreter is added to the
allowlist.** The agent reports stdout/stderr/exit through the existing
`TaskResult` path; on non-zero exit before the atomic move the old config stays
live, and on service-manager failure the actual script restores the previous
target file, tries to restart the previous config, and does not mark the profile
applied.

> Secrets in the plan/apply split: the approval plan is redacted and safe for review screenshots. The queued task script **does** contain user UUIDs/passwords and REALITY private keys (the core needs them). This is acceptable because (a) it only reaches the one node that serves those users, over the same HTTPS bearer channel that already carries every task, (b) `Task.Script` is encrypted at rest, and (c) it is the minimum that node must know to function. Unlike WireGuard's private key (node-owned and substituted locally), proxy client secrets are server-issued and inherently must land on the serving node.

### Usage reporting

**Landed baseline (iter-046):**
- `lattice-agent -proxy-usage-file /path/to/usage.json` (or
  `LATTICE_PROXY_USAGE_FILE`) reads a local JSON `ProxyUsageSnapshot` each loop
  and POSTs it to `/api/agent/proxy-usage`.
- The agent overrides `node_id` with its configured node id, defaults `at` when
  absent, rejects empty user ids, rejects negative counters, and caps the file
  at 1 MiB.
- The file bridge is intended for sidecar collectors or operator experiments;
  the server owns monotonic diffing, eligibility filtering, quota status, and
  audit.

**Next collector slice:**
- Reads the core's local stats API (`ProxyNodeProfile.StatsAPI`, default
  `127.0.0.1:9090` Clash API for sing-box, or xray's gRPC stats in v2), every N
  seconds.
- Maps core-reported per-user counters to `userID` and POSTs a
  `ProxyUsageSnapshot` to `/api/agent/proxy-usage`.
- Purely local read; no inbound exposure. If the stats API is unreachable, it
  should report an explicit health/error signal rather than silently suppressing
  accounting.

### Health
A `tcp` `Monitor` on each inbound `host:port` (created automatically when a profile is applied, or by the operator) reuses the existing monitor/alert pipeline for "core down" detection — no new health code path.

---

## 6. Config rendering / external integration

### Artifacts generated (server-side, in `internal/proxycore`)
1. **sing-box `config.json`** per node: built from `ProxyNodeProfile.InboundIDs` → resolve `ProxyInbound`s → attach the `ProxyUser`s provisioned on each inbound (UUID for vless/vmess, password for trojan/ss/hy2; reality keys for reality inbounds). Output is typed Go structs marshaled with `encoding/json` — **no string templating of JSON** (injection-safe by construction; node-influenced metadata never reaches the renderer because inbounds/users are operator-defined server-side). Validate the marshaled tree against a minimal internal schema before it becomes a plan. Iter-040 implements the first narrow path: sing-box `vless` over TCP with REALITY using `listen`/`listen_port`, VLESS `users[].uuid`, and TLS `reality` fields per the official sing-box docs.
2. **Per-user subscription links** (the `/sub/{token}` body):
   - `vless://uuid@host:port?type=ws&security=reality&pbk=...&sid=...&sni=...&fp=chrome#node-label`
   - `vmess://<base64(json)>`, `trojan://pass@host:port?...#label`, `hysteria2://pass@host:port?...#label`, `ss://<base64(method:pass)>@host:port#label`
   - One link **per (user × inbound × node that runs that inbound)**; `host` = `ProxyNodeProfile.Hostname` (the DDNS name) so links survive IP changes.
   - Formats served by `?format=`:
     - **plain** (newline-joined URIs), **base64** (whole body base64, the de-facto default many clients expect) — landed in iter-044.
     - **sing-box** (minimal client `outbounds` JSON for sing-box clients) — landed in iter-047 for VLESS+REALITY+TCP.
     - **clash** / **clash.meta** / **clash-meta** (Mihomo/Clash `proxies:` YAML list) — landed in iter-047 with a hand-rolled fixed-shape writer to avoid a YAML dependency.
     - `User-Agent` sniffing remains pending; explicit `?format=` is the stable contract for now.
   - Subscription headers: `Subscription-Userinfo: upload=…; download=…; total=…; expire=…` (Unix ts) so clients show quota/expiry — this is the single most loved remnawave/v2board UX touch.
3. **DDNS**: proxy node hostnames are ordinary `DDNSProfile`s (reuse `internal/ddns`, Cloudflare provider, `*.dns.roobli.org`). No new DNS code; the design only *requires* that a node intended for subscriptions has a DDNS profile (surface a warning in the plan if `Hostname` resolves to no bound profile).
4. **nft** (optional, operator-driven): the operator's per-node access rules ("deny gmami-jp1 → dmit:1234") remain pure `internal/network/nft` plan→apply, independent of this feature. The renderer may *emit a suggested* nft snippet to restrict the core's listen set, but does not own nft.

### Validation & reload
- Server-side: JSON marshal + internal structural checks (port range, unique ports per node, known protocol/transport/security enums, reality requires a keypair, ss requires a method) before a plan is ever created — **fail-closed at plan time**.
- Node-side: `sing-box check` before atomic swap; reload via `systemctl reload`/`restart`; old config preserved on failure.
- Reload is graceful for sing-box (`reload` re-reads without dropping established conns where possible); a restart is the fallback.

---

## 7. Security

**Authz.** Every mutation requires `proxy:admin`; reads require `proxy:read`; deploy requires `network:plan`+`network:apply` and is gated by the per-node `ServerAllowlist` (an operator scoped to `gmami-jp1` cannot plan/apply on `dmit-eb`). The public `/sub/{token}` route requires a 256-bit unguessable token, constant-time compared, **rate-limited** via `internal/ratelimit`, and has **no session/cookie path** (it can't be CSRF'd into an admin action).

**Fail-closed.** Bad config never goes live (`sing-box check` + atomic swap). Plan-time structural validation rejects malformed inbounds. A user past `ExpiresAt` or over `TrafficLimitBytes` is **omitted from subscription output immediately** (server-authoritative, no node round-trip); v2 additionally drops them from the rendered config on the next apply. Unknown protocol/transport/security enums are rejected, not silently passed through.

**Secret handling.** UUID/password/sub-token/reality-private-key are encrypted at rest (§3.4) and stripped from every list/GET. The iter-044 `/sub/{token}` route uses a constant-time full scan and hashed-token audit metadata; it does not persist raw sub-tokens as lookup keys. Iter-045 adds `POST /api/proxy/users/rotate-sub-token`: it bumps the credential, invalidates the old subscription URL immediately, and returns the new URL/path only in the explicit rotate response (`LATTICE_PUBLIC_URL` when configured, otherwise relative `/sub/{token}`). The one place secrets necessarily travel is the rendered node config — sent only to the owning node over the existing authenticated channel.

**Blast radius / compromised node.** A node only ever holds: its own rendered config (its inbounds + the subset of users provisioned to it) and its own node token. It does **not** hold the central user DB, other nodes' configs, subscription tokens, or reality private keys for inbounds it doesn't run. A compromised node can: serve/sniff transit for *its own* users (inherent to being an exit), lie about usage for users eligible on its own profile, and attempt to return a bad task result (bounded by existing output caps). Iter-046 mitigates usage abuse with profile eligibility filtering, first-snapshot baselining, negative-counter rejection, monotonic diffing, reset handling, and serialized apply; nevertheless usage remains low-trust accounting data and quota enforcement is best-effort. It **cannot** mint users, report usage for unrelated profile-only users, read other nodes' secrets, or pivot to the control plane (it only dials out; no inbound from server).

**Audit events** (hash-chained WAL, via `recordPrincipalAudit`): `proxy.inbound.{create,update,delete}`, `proxy.user.{create,update,delete}`, `proxy.user.rotate_sub_token`, `proxy.profile.update`, `proxy.plan` (with node + plan sha256), `network.proxycore.approve` (shared approve handler), `proxy.apply.applied` / `proxy.apply.failed` (task-result reconciliation), `proxy.subscription.fetch` (token id hash + source IP, for abuse detection), `proxy.usage.report`. Expiry/quota/core-down notifications fan out via `internal/notify`.

---

## 8. Phasing

### MVP (smallest shippable slice) — *sing-box, vless+reality, single inbound type, baseline usage*
- Model: `ProxyInbound`, `ProxyUser`, `ProxyNodeProfile` (+ store collections, crypto wiring).
- One protocol path end-to-end: **vless + reality + tcp** (the operator's most-wanted, no cert needed).
- Server: inbounds/users/profiles CRUD; `internal/proxycore` renderer (sing-box JSON) for vless/reality; `POST /api/proxy/nodes/{id}/plan` → `Approval{Plugin:"proxycore"}`; approve→apply queues the sing-box validation/atomic-swap task after config-SHA revalidation.
- Agent: nothing new beyond running the apply task (it already can). `sing-box check` in the script.
- Subscription: `/sub/{token}` serving **plain + base64** of vless links, with `Subscription-Userinfo` header. **Landed in iter-044.** sing-box client JSON and Clash/Mihomo YAML for VLESS+REALITY+TCP landed in iter-047. Usage reflects `ProxyUser.UsedBytes`; baseline node reporting through `/api/agent/proxy-usage` landed in iter-046.
- Usage: agent `-proxy-usage-file` bridge, server monotonic diffing, `/api/proxy/usage`, and dashboard usage/last-seen display. **Landed in iter-046.**
- DDNS: document that the node needs a DDNS profile; warn in plan if missing.
- **Exit bar:** operator creates an inbound + user + profile, plans `gmami-jp1`, approves, the agent applies, sing-box serves vless/reality, the user's `/sub` link imports into a client and connects. `-race` + gofmt green, adversarial security review of the new surface passed, audit events present.

### v2 — *direct collectors, more protocols, enforcement, xray*
- Direct sing-box stats collector and xray stats collector behind the already-landed `ProxyUsageSnapshot` contract; quota/expiry **notify** alerts.
- More protocols: vmess, trojan, shadowsocks, hysteria2; cert-path TLS inbounds; ws/grpc transports.
- Additional subscription depth: UA sniffing, import-helper UX, cache keyed by
  token + fleet config hash, and formats for new protocols as they land.
- Enforcement: expired/over-quota users dropped from rendered config on next apply (and a scheduled re-apply, or an agent-side disable hook).
- **xray** second renderer behind the same `Core` abstraction + `xray test -c`.
- **Exit bar:** usage visible in dashboard, alerts fire, over-quota users lose access on next reconcile, both cores supported, all formats import cleanly in their target clients.

### Later — *polish & scale*
- Auto-reconcile loop (server detects drift between desired profile hash and `AppliedSHA256`, offers/queues a re-apply).
- ACME/cert automation per node; per-user device/IP-limit (remnawave HWID-lite) if the operator wants it.
- nezha-style **global map** view of proxy nodes (reuse node metrics + DDNS hostnames).
- Subscription-format adapters as `worker`-tier plugins once Phase B runtime ships.
- Move proxy collections to bbolt record-level APIs when Phase C cutover lands (the model is already store-isolated).

---

## 9. Risks & open questions

1. **Usage trust.** Per-user byte counters come from a node that may be compromised. Decision: usage is **advisory for display + soft-gating**; expiry (time-based) is hard and server-authoritative; quota enforcement is best-effort with monotonic diffing + sanity caps. Open: do we want a hard kill on quota (requires trusting node counters) vs. only expiry being hard?
2. **Reality key custody.** Server holds reality private keys (needed to render config). Acceptable (same class as DDNS tokens) but it does mean server compromise exposes them. Open: per-inbound rotation cadence?
3. **Subscription scale / caching.** `/sub/{token}` renders on every hit; a popular fleet could see frequent polls. Mitigation: cheap render (no node round-trip, pure server-side), `internal/ratelimit`, and a short in-memory cache keyed by (token, fleet-config-hash). Open: cache TTL vs. freshness after a user edit.
4. **Config schema drift.** sing-box config schema evolves across versions. Mitigation: pin a supported core version range, validate node-side with the node's own `sing-box check` (authoritative for that node's binary), and keep the renderer's schema minimal. Open: version negotiation — agent reports `sing-box version`?
5. **YAML dependency avoided.** iter-047 uses a fixed-shape hand-written
   Clash/Mihomo YAML emitter with quoted scalars, so no YAML dependency or ADR
   was needed. Future protocol/format expansion should keep this dependency
   posture unless the structure stops being fixed.
6. **Atomic multi-node rollout.** Editing a shared inbound changes many nodes' desired config at once. v1 is per-node plan/approve (explicit, safe, tedious). Open: a "plan all affected nodes" batch that produces N approvals — desirable but more blast radius per click.

---

## 10. Borrow vs. avoid (from the research briefs)

**Borrow from remnawave (operator's lean):**
- **Central user identity reused across nodes** with one subscription URL spanning the fleet — the core UX win; our `ProxyUser` is node-agnostic for exactly this reason.
- **Multi-format subscription + `Subscription-Userinfo` header** (upload/download/total/expire) so clients show quota/expiry natively. This is the single most-loved touch; ship it in MVP (expiry) and complete it in v2 (usage).
- **Token-based public subscription endpoint** (`/sub/{token}`), unguessable, rotatable — we mirror it with a 256-bit token + constant-time compare + rate-limit.
- **Server-renders-config / node-runs-core split.** remnawave's panel renders, the node just executes — identical to our server-policy/agent-executor split, which is why this fits Lattice with almost no new trust.

**Borrow from s-ui / 3x-ui:**
- **Inbound-as-template + clients joined at render** (their inbound/client settings model) — clean separation we adopt (`ProxyInbound` carries no per-user secret).
- **`sing-box check` / `xray test` pre-reload validation** as the fail-closed gate — we put it in the apply script.
- **Clash/sing-box/v2ray subscription emitters** as a guide for our format adapters.

**Avoid:**
- **3x-ui's per-node embedded web panel + its own DB on every node.** That's a second control plane per node, the opposite of Lattice's single-policy-point + least-trust agent. We keep nodes headless (core + existing agent).
- **remnawave's heavier stack assumptions** (its own DB engine, message bus, separate node daemon with an inbound API). Lattice already has the bus equivalent (poll + tasks), the store, and the agent — we reuse them; no new daemon, no inbound-to-node API.
- **Sub-Store's general subscription-transform engine** as a server dependency. Overkill for v1; our emitters are fixed-format and pure Go. (If the operator later wants arbitrary transforms, that's a `worker`/`system` plugin, per the architecture doc's plugin list — not core.)
- **Reseller/tenant/billing hierarchies** (remnawave) — out of scope for a single-operator fleet; would explode the model and the audit surface.

---

## 11. Dev guide (ordered, file-by-file)

Follow `development-workflow.md`: plan → design (this doc) → build (TDD) → verify (`-race`, gofmt, dashboard) → review (independent, adversarial) → commit (conventional). Build/test with `GOWORK` set (multi-repo `go.work`). Each numbered block is a small, coherent commit.

1. **Plan artifact** — `iterations/iter-NNN-proxy-mvp.md` (goal/scope/design ref/risks/test plan/exit bar) before code, per the operating cadence.

2. **SDK model** — `lattice-sdk/model/model.go`: add the consts + `ProxyInbound`, `ProxyUser`, `ProxyNodeProfile`, `ProxyUsageSnapshot`. Update `proto_contract_test.go`. `go test ./...` (sdk). *Commit: `feat(sdk): proxy-core model (inbounds, users, node profiles, usage)`.*

3. **Store** — `internal/store/store.go`: add the four `State` collections + `emptyState()` init + CRUD methods (mirror DDNS/Monitor). `internal/store/crypto.go`: encrypt `ProxyInbound.RealityPrivateKey`, `ProxyUser.UUID/Password/SubToken`; extend `stateHasEnvelope`. Tests: round-trip encrypt/decrypt, lost-key guard, bbolt import/export, and record-level proxy collections. **Landed in iter-039.** The opaque subscription-token lookup key is deferred to the `/sub/{token}` endpoint slice because no public subscription lookup exists yet.

4. **Renderer** — new `internal/proxycore/`:
   - `singbox.go`: `RenderSingBoxConfigJSON(profile, inbounds, users, opts) (SingBoxArtifact, error)` → canonical JSON + SHA-256 + target path + warnings; MVP path vless+reality+tcp; structural validation. **Landed in iter-040.**
   - `links.go`: `VLESSRealityLinks(user, profiles, inbounds, opts)`, `VLESSRealityEndpoints`, `PlainSubscription`, `Base64Subscription`, `SingBoxClientSubscription`, `ClashMetaSubscription`, and `SubscriptionUserinfo`. Plain/base64 landed in iter-044; sing-box JSON and Clash/Mihomo YAML landed in iter-047 for applied sing-box VLESS+REALITY+TCP profiles only. Skipped/unapplied profiles return warnings and no links rather than exposing stale nodes.
   - `reality.go`: X25519 keypair gen (pure Go `crypto/ecdh`), short-ID gen.
   - Table-driven tests for each, including a golden sing-box config that `sing-box check` accepts (gated behind a build tag / skipped if binary absent). Iter-040 covers renderer shape/validation/hash/leak checks; iter-044 covers VLESS link shape, plain/base64 bodies, inactive users, unsafe host/public-key rejection, and secret leak checks; iter-047 covers sing-box JSON, Clash/Mihomo YAML, content types, safe `fingerprint` persistence, unsafe fingerprint rejection, and no secret leaks in added formats. Optional `sing-box check` integration remains pending.

5. **Server handlers** — new `internal/server/server_proxy.go`: inbounds/users/profiles CRUD (+ view structs that strip secrets) landed in iter-041; redacted reviewed `/api/proxy/nodes/{id}/plan` landed in iter-042; secret-safe queue/apply landed in iter-043; public `/sub/{token}` with dedicated rate limiting, constant-time token scan, duplicate-token fail-closed behavior, no-store responses, `Subscription-Userinfo`, and secret-safe audit landed in iter-044; explicit audited subscription-token rotation landed in iter-045; `/api/agent/proxy-usage` and `/api/proxy/usage` with monotonic rollup landed in iter-046; `format=sing-box`, `format=clash`, and `format=clash-meta` landed in iter-047. Remaining handler work: direct core collector health/error surfaces, usage notifications, and xray-specific routes only if the common model is insufficient. Register routes in the existing mux. Add `proxy:read`/`proxy:admin` to the scope set.

6. **Approve→apply wiring** — `internal/server/server.go`: the fail-closed `case "proxycore"` has been replaced by real apply. The script heredocs the real config, runs `sing-box check -c`, atomically swaps, reloads/restarts, and reconciles status from task results. No new agent interpreter. Tests cover rendered script shape, control-plane script redaction, task-script encryption at rest, and applied status. **Landed in iter-043.**

7. **Agent usage** — `lattice-node-agent/internal/proxyusage` + `cmd/lattice-agent/main.go` file bridge landed in iter-046 (`-proxy-usage-file` / `LATTICE_PROXY_USAGE_FILE`). Next: add a direct sing-box collector behind the same `ProxyUsageSnapshot` contract, then quota/expiry `notify` hooks. Keep server-side monotonic diffing authoritative; collectors only provide cumulative counters.

8. **Dashboard (Phase D / incremental)** — zero-dep vanilla JS under strict CSP: inbounds/users/profiles panels and rotate/copy subscription URL workflow landed in iter-045; usage/last-seen/profile snapshot display landed in iter-046. Remaining dashboard work: focused proxy plan diff/approve UI (currently uses the existing Approvals panel), import helpers that surface `format=plain|base64|sing-box|clash-meta`, direct collector health/error display, and visual polish.

9. **Verify** — `GOWORK=… go test -race ./...` across server/agent/sdk; gofmt; dashboard smoke; a manual end-to-end on one node (plan→approve→apply→connect→import sub). Record evidence in the iteration doc.

10. **Review** — independent adversarial pass (security-reviewer / verifier, never self-approve): focus on the public `/sub` route, secret stripping in views, plan_sha256 binding, blast radius of a compromised node, audit completeness. Fix must-fixes with regression tests.

11. **Docs & commit** — ADR if any new dependency is introduced (aim for none); update `PRODUCT-VISION.md` (this is a new pillar-spanning capability) and the iteration log; conventional commits throughout; push only when asked.
