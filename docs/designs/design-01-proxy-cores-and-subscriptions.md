# Design 01 — Proxy-Core Orchestration & Subscription Management

> Status: proposed · Author: framework design pass · Date: 2026-06-13
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

Rationale: UUID/password/sub-token are reversible bearer credentials (leak = account takeover / free transit / subscription theft), exactly the encrypted class already documented in crypto.go (DDNS token, OIDC secret, notify config). List/GET APIs **must** strip these (return only `has_uuid: true`, masked, or the derived link) like the DDNS/notify list APIs already do. Subscription tokens are additionally stored as an **opaque SHA-256 lookup key** when encryption is enabled (same trick as session/TOTP IDs in crypto.go) so the served URL token is never the stored map key.

---

## 4. Server API

New handlers in `internal/server/server_proxy.go`, registered in the existing mux. Scopes: `proxy:read` (GET), `proxy:admin` (mutations), reuse `network:plan`/`network:apply` for deploy. All list/GET responses use **view structs** that strip secret fields (mirroring `toApprovalView`, DDNS/notify list shaping).

| Method | Path | Scope | Request → Response |
|---|---|---|---|
| GET | `/api/proxy/inbounds` | `proxy:read` | → `[]ProxyInboundView` (no reality private key) |
| POST | `/api/proxy/inbounds` | `proxy:admin` | `ProxyInbound` (server generates reality keypair if `security=reality` & empty) → `ProxyInboundView` |
| PUT | `/api/proxy/inbounds/{id}` | `proxy:admin` | partial → view |
| DELETE | `/api/proxy/inbounds/{id}` | `proxy:admin` | → 204 (rejected if referenced by an enabled profile unless `force`) |
| GET | `/api/proxy/users` | `proxy:read` | → `[]ProxyUserView` (no UUID/password/token; includes `used_bytes`, `status`, link count) |
| POST | `/api/proxy/users` | `proxy:admin` | `{name, inbound_ids, traffic_limit_bytes, expires_at}` → view incl. **one-time** sub URL |
| PUT | `/api/proxy/users/{id}` | `proxy:admin` | limits/enable/inbounds → view |
| POST | `/api/proxy/users/{id}/rotate` | `proxy:admin` | rotates UUID/password and/or sub-token → new sub URL |
| DELETE | `/api/proxy/users/{id}` | `proxy:admin` | → 204 |
| GET | `/api/proxy/profiles` | `proxy:read` | → `[]ProxyNodeProfileView` |
| PUT | `/api/proxy/profiles/{node_id}` | `proxy:admin` | `{core, inbound_ids, hostname, listen_ip, config_path, stats_api}` → view |
| POST | `/api/proxy/nodes/{node_id}/plan` | `network:plan` | `{plan_sha256?}` → `{approval_id, plan, sha256}` (renders config, creates `Approval{Plugin:"proxycore"}`) |
| — | `/api/network/approve` | `network:apply` | **existing handler**; `{approval_id, queue_apply, plan_sha256}` queues the apply task |
| GET | `/api/proxy/usage` | `proxy:read` | → per-user/per-node usage rollup for the dashboard |
| **GET** | `/sub/{token}` | **public (token-auth)** | → subscription body (format negotiated, see §6); rate-limited via existing `internal/ratelimit`; never requires a session |

Agent-facing (bearer node-token auth, like existing `/api/agent/*`):
| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/agent/proxy-usage` | node token | agent reports `ProxyUsageSnapshot` |

The plan endpoint is the only new "dangerous" surface; it produces a diffable plan and **never** mutates the node. Approve/apply is the unchanged shared path. The `/sub/{token}` endpoint is the one public, unauthenticated-by-session route — it is guarded by an unguessable per-user token, constant-time compared, rate-limited, and emits an audit/usage event on hit.

---

## 5. Agent responsibilities

The agent gains a small **proxy module** (`internal/proxycore/` in lattice-node-agent) and **one new reporting goroutine**. It does **not** gain inbound ports or new trust.

### Apply-task contract (reuses existing task plumbing)
The server's `applyScriptFor(approval)` gets `case "proxycore"`. The rendered task is an ordinary `model.Task{Interpreter:"sh"}` the agent already knows how to run sandboxed. The script:
```sh
set -e
umask 077
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json.new <<'LATTICE_SB_EOF'
<rendered config.json>
LATTICE_SB_EOF
sing-box check -c /etc/sing-box/config.json.new          # fail-closed: bad config never goes live
mv /etc/sing-box/config.json.new /etc/sing-box/config.json
systemctl reload sing-box 2>/dev/null \
  || systemctl restart sing-box 2>/dev/null \
  || echo 'config written; start sing-box manually'
```
This mirrors the cftunnel/wireguard cases exactly: heredoc-write + validate + reload, all via the sandboxed `sh` interpreter with the existing rlimits/process-group-kill/output-cap. **No new interpreter is added to the allowlist.** The agent reports stdout/stderr/exit through the existing `TaskResult` path; on non-zero exit the old config stays live (atomic `mv` only after `check` passes) — fail-closed.

> Secrets in the plan: the rendered `config.json` **does** contain user UUIDs/passwords (the core needs them). This is acceptable because (a) it only ever reaches the one node that serves those users, over the same HTTPS bearer channel that already carries every task, and (b) it is the minimum that node must know to function. Unlike WireGuard's private key (which is node-owned and substituted locally), proxy client secrets are server-issued and inherently must land on the serving node. The approval **diff shown to the operator** can optionally mask client secrets to keep review screenshots safe, while the queued task carries the real values (the `plan_sha256` binds the *masked-or-real* canonical text consistently — pick one and hash that).

### Usage reporting goroutine
- Reads the core's local stats API (`ProxyNodeProfile.StatsAPI`, default `127.0.0.1:9090` clash-api for sing-box, or xray's gRPC stats in v2), every N seconds.
- Maps core-reported per-user counters to `userID` and POSTs a `ProxyUsageSnapshot` to `/api/agent/proxy-usage`.
- Purely local read; no inbound exposure. If the stats API is unreachable, it reports an empty snapshot with an error string (visible, not silent).

### Health
A `tcp` `Monitor` on each inbound `host:port` (created automatically when a profile is applied, or by the operator) reuses the existing monitor/alert pipeline for "core down" detection — no new health code path.

---

## 6. Config rendering / external integration

### Artifacts generated (server-side, in `internal/proxycore`)
1. **sing-box `config.json`** per node: built from `ProxyNodeProfile.InboundIDs` → resolve `ProxyInbound`s → attach the `ProxyUser`s provisioned on each inbound (UUID for vless/vmess, password for trojan/ss/hy2; reality keys for reality inbounds). Output is a `map[string]any` marshaled with `encoding/json` — **no string templating of JSON** (injection-safe by construction; node-influenced metadata never reaches the renderer because inbounds/users are operator-defined server-side). Validate the marshaled tree against a minimal internal schema before it becomes a plan.
2. **Per-user subscription links** (the `/sub/{token}` body):
   - `vless://uuid@host:port?type=ws&security=reality&pbk=...&sid=...&sni=...&fp=chrome#node-label`
   - `vmess://<base64(json)>`, `trojan://pass@host:port?...#label`, `hysteria2://pass@host:port?...#label`, `ss://<base64(method:pass)>@host:port#label`
   - One link **per (user × inbound × node that runs that inbound)**; `host` = `ProxyNodeProfile.Hostname` (the DDNS name) so links survive IP changes.
   - Formats served (content-negotiated by `?format=` or `User-Agent` sniffing, remnawave-style):
     - **plain** (newline-joined URIs), **base64** (whole body base64 — the de-facto default many clients expect),
     - **sing-box** (full `outbounds` JSON for sing-box clients),
     - **clash** / **clash.meta** (YAML `proxies:` list) — pure Go YAML emit via hand-rolled writer or the already-tiny dependency surface; prefer hand-rolled to avoid a new dep, since the structure is fixed.
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

**Secret handling.** UUID/password/sub-token/reality-private-key are encrypted at rest (§3.4) and stripped from every list/GET. Sub-tokens are stored under opaque SHA-256 keys. Rotation (`/rotate`) bumps the credential and **invalidates old subscription URLs** (and old links) at once. The one place secrets necessarily travel is the rendered node config — sent only to the owning node over the existing authenticated channel.

**Blast radius / compromised node.** A node only ever holds: its own rendered config (its inbounds + the subset of users provisioned to it) and its own node token. It does **not** hold the central user DB, other nodes' configs, subscription tokens, or reality private keys for inbounds it doesn't run. A compromised node can: serve/sniff transit for *its own* users (inherent to being an exit), lie about usage (mitigation: monotonic diffing + sanity caps + the server treats usage as advisory for accounting, authoritative gating stays server-side on expiry/quota-estimate), and attempt to return a bad task result (bounded by existing output caps). It **cannot** mint users, read other nodes' secrets, or pivot to the control plane (it only dials out; no inbound from server).

**Audit events** (hash-chained WAL, via `recordPrincipalAudit`): `proxy.inbound.{create,update,delete}`, `proxy.user.{create,update,rotate,delete}`, `proxy.profile.update`, `proxy.plan` (with node + plan sha256), `proxy.approve`/`proxy.apply` (via the shared approve handler, `Plugin:"proxycore"`), `proxy.subscription.fetch` (token id hash + source IP, for abuse detection), `proxy.usage.report`. Expiry/quota/core-down notifications fan out via `internal/notify`.

---

## 8. Phasing

### MVP (smallest shippable slice) — *sing-box, vless+reality, single inbound type, manual usage*
- Model: `ProxyInbound`, `ProxyUser`, `ProxyNodeProfile` (+ store collections, crypto wiring).
- One protocol path end-to-end: **vless + reality + tcp** (the operator's most-wanted, no cert needed).
- Server: inbounds/users/profiles CRUD; `internal/proxycore` renderer (sing-box JSON) for vless/reality; `POST /api/proxy/nodes/{id}/plan` → `Approval{Plugin:"proxycore"}`; reuse approve→apply with `case "proxycore"` in `applyScriptFor`.
- Agent: nothing new beyond running the apply task (it already can). `sing-box check` in the script.
- Subscription: `/sub/{token}` serving **plain + base64** of vless links, with `Subscription-Userinfo` header (expiry only; usage shows 0).
- DDNS: document that the node needs a DDNS profile; warn in plan if missing.
- **Exit bar:** operator creates an inbound + user + profile, plans `gmami-jp1`, approves, the agent applies, sing-box serves vless/reality, the user's `/sub` link imports into a client and connects. `-race` + gofmt green, adversarial security review of the new surface passed, audit events present.

### v2 — *accounting, more protocols, enforcement, xray*
- Agent usage goroutine + `/api/agent/proxy-usage` + monotonic diff → `ProxyUser.UsedBytes`/`Status`; quota/expiry **notify** alerts.
- More protocols: vmess, trojan, shadowsocks, hysteria2; cert-path TLS inbounds; ws/grpc transports.
- Subscription formats: sing-box JSON + clash/clash.meta YAML; UA sniffing.
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
5. **New external dep?** clash/clash.meta YAML output: prefer **hand-rolled emit** (fixed structure) to avoid a YAML dependency and the ADR it would need. Open: confirm hand-rolled is acceptable vs. a vetted tiny YAML writer (would need an ADR per the zero-dep rule).
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

3. **Store** — `internal/store/store.go`: add the four `State` collections + `emptyState()` init + CRUD methods (mirror DDNS/Monitor). `internal/store/crypto.go`: encrypt `ProxyInbound.RealityPrivateKey`, `ProxyUser.UUID/Password/SubToken`; add opaque SHA-256 storage key for sub-tokens; extend `stateHasEnvelope`. Tests: round-trip encrypt/decrypt, lost-key guard, sub-token opaque-key collision guard. *Commit: `feat(store): persist + encrypt proxy collections`.*

4. **Renderer** — new `internal/proxycore/`:
   - `singbox.go`: `RenderConfig(profile, inbounds, users) (map[string]any, error)` → JSON; MVP path vless+reality+tcp; structural validation.
   - `links.go`: `UserLinks(user, profile, inbounds) []string` (vless first); `Subscription(user, format) ([]byte, http.Header)`.
   - `reality.go`: X25519 keypair gen (pure Go `crypto/ecdh`), short-ID gen.
   - Table-driven tests for each, including a golden sing-box config that `sing-box check` accepts (gated behind a build tag / skipped if binary absent).
   *Commit: `feat(proxycore): sing-box renderer + vless/reality links + subscription encoders`.*

5. **Server handlers** — new `internal/server/server_proxy.go`: inbounds/users/profiles CRUD (+ view structs that strip secrets), `/api/proxy/nodes/{id}/plan` (creates `Approval{Plugin:"proxycore"}`), `/sub/{token}` (public, rate-limited, constant-time token compare), `/api/proxy/usage`. Register routes in the existing mux. Add `proxy:read`/`proxy:admin` to the scope set. *Commit: `feat(server): proxy CRUD, plan, subscription endpoint`.*

6. **Approve→apply wiring** — `internal/server/server.go`: add `case "proxycore"` to `applyScriptFor` (heredoc config + `sing-box check` + atomic swap + reload). No new agent interpreter. Test the rendered script shape. *Commit: `feat(server): proxycore apply task in plan→approve→apply`.*

7. **Agent usage (v2 slice, can defer)** — `lattice-node-agent/internal/proxycore/usage.go` + a poll goroutine in `cmd/lattice-agent/main.go`; server `/api/agent/proxy-usage` handler + monotonic diff into `ProxyUser.UsedBytes`/`Status`; quota/expiry `notify` hooks. *Commit: `feat(agent,server): proxy usage reporting + quota/expiry alerts`.*

8. **Dashboard (Phase D / incremental)** — zero-dep vanilla JS under strict CSP: inbounds/users/profiles panels, plan-diff/approve UI (reuse the existing approval UI), copy-subscription-URL, usage/expiry display. *Commit: `feat(dashboard): proxy management panels`.*

9. **Verify** — `GOWORK=… go test -race ./...` across server/agent/sdk; gofmt; dashboard smoke; a manual end-to-end on one node (plan→approve→apply→connect→import sub). Record evidence in the iteration doc.

10. **Review** — independent adversarial pass (security-reviewer / verifier, never self-approve): focus on the public `/sub` route, secret stripping in views, plan_sha256 binding, blast radius of a compromised node, audit completeness. Fix must-fixes with regression tests.

11. **Docs & commit** — ADR if any new dependency is introduced (aim for none); update `PRODUCT-VISION.md` (this is a new pillar-spanning capability) and the iteration log; conventional commits throughout; push only when asked.
