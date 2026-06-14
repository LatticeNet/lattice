# Design 02 — One-Click Self-Hosted DNS Deployment

> Status: **proposed**; shared `NFTInputs` prerequisite landed in iter-019 · Author: design pass 2026-06-13 · Build target: the operator builds against this directly.
> Companion to: `architecture.md` (DDNS, Cloudflare Tunnel, WireGuard, Storage, Safety Model), `PRODUCT-VISION.md` (pillars P1 Trust / P4 Durability), `development-workflow.md` (Plan→Execute→Review→Iterate).

This document specifies a **CORE server-owned provider** (in the same class as `internal/ddns`, `internal/cftunnel`, `internal/wireguard`, `internal/network`) that lets an operator deploy a private DNS resolver/authoritative server onto a chosen node with a single approval, pair it with per-node nftables access rules, and publish a Cloudflare subdomain (e.g. `gmami-jp1.dns.roobli.org`) that DDNS keeps pointed at that node's public IP. It reuses the existing `plan → approve → apply` machinery verbatim; it adds no new external Go dependency and no CGo.

---

## 1. Goal & scope

### 1.1 What it does (v1)
- An operator picks a node, picks a DNS engine (**CoreDNS** is the v1 default — single static pure-Go binary, no CGo, trivial config), sets a listen port and bind protocols (UDP/TCP/DoT later), and supplies the upstream/zone policy.
- The server renders a complete DNS-engine config plus the agent install/run plan, records it as a **pending approval** for the bound node, and on approval+`queue_apply` dispatches a bounded apply task the agent pulls and executes (install binary if missing → write config → validate → reload).
- The server **auto-creates/maintains a Cloudflare DNS record** for the deployment's public hostname (e.g. `gmami-jp1.dns.roobli.org` → node A/AAAA) by **reusing the `internal/ddns` Cloudflare provider** and binding it to the node's IP-change trigger, so the hostname tracks the node forever with zero further clicks.
- The server **renders the matching nftables open/restrict rule** for the DNS port and folds it into the node's existing `internal/network` nft plan, so opening the resolver is one coordinated, audited change — never a hand-edited firewall.
- Status (installed/running/last-reload/last-error, resolved hostname, last published IP) is reported back and surfaced per node.

### 1.2 Explicit non-goals (v1)
- **No anycast / geo-routing of the apex** `dns.roobli.org` across many nodes. v1 publishes one **per-node** subdomain. Cloudflare geo-steering / load-balancing of a shared apex is **v2** (§8) and depends on a CF Load Balancer subscription we will not assume.
- **No recursive open resolver to the public internet by default.** Default posture is **fail-closed**: the resolver answers only from the WireGuard mesh CIDR (and loopback); public exposure is an explicit opt-in that widens the nft rule and is loudly audited.
- **No authoritative hosting of `roobli.org` itself.** v1 serves *private* zones (split-horizon internal names, mesh service discovery, ad-block/upstream-forward). The apex stays on Cloudflare. Authoritative public hosting is out of scope.
- **No DNSSEC signing, no DoH server, no per-client ACL policy language** in v1 (CoreDNS `acl`/`dnssec` plugins are a later phase).
- **No engine zoo.** v1 ships exactly one engine (CoreDNS). The model is engine-tagged so a second engine (e.g. `dnsmasq`, `knot-resolver`) can be added later, but adding engines is not a v1 deliverable.
- **No agent-initiated DNS changes.** The agent never edits the firewall or DNS config on its own; everything flows through plan→approve→apply. (Consistent with the least-trust agent.)

---

## 2. System fit

| Lattice layer | Role for this feature |
|---|---|
| **Server (sole policy point)** | Owns the `DNSDeployment` records, renders config + nft rule + the apply script, owns the Cloudflare API token, decides the hostname, enforces RBAC, writes audit. The agent is told *exactly* what to write and run. |
| **Agent (least-trust executor)** | Pulls the bounded apply task via the existing `GET /api/agent/tasks` poll, runs it in the sandbox (`sh` interpreter, rlimits, process-group kill, root-refusal handled as today), returns stdout/stderr/exit code via the normal task-result path. Reports DNS engine presence/version via a small extension to `model.Node` facts. It receives **no inbound connection** and **no DNS secrets**. |
| **plan → approve → apply** | **Reused unchanged.** A DNS deploy is just another `model.Approval{Plugin:"selfdns", Action:"apply-config", Plan:<rendered config bundle>}`. `handleApprove` already queues the apply task; we extend exactly one function — `applyScriptFor` — with a `case "selfdns"`. `plan_sha256` binding works for free (the reviewer sees the literal config + nft diff). |
| **Store** | One new collection `DNSDeployments map[string]model.DNSDeployment` alongside `Tunnels`/`DDNS`, with the same `Upsert/Get/List/Delete/ForNode` accessor quintet. The CF API token is a **secret-at-rest** field routed through `internal/store/crypto.go`. |
| **RBAC** | New scope pair `dns:admin` (CRUD + plan) and reuse of `network:apply` for the approval gate, plus the per-node allowlist already enforced by `requireNodeScope`. |
| **internal/ddns** | **Reused as-is** for Cloudflare record automation. A `DNSDeployment` *owns* (or references) a Cloudflare DDNS binding for its hostname; the existing `maybeTriggerDDNS` IP-change path keeps the record current. No new CF client. |
| **internal/network (nft)** | **Reused/extended.** The DNS port is injected into the node's persisted `NFTInputs` as a restricted (WireGuard-only) or public dport, then rendered into the one `inet lattice_guard` table. The resolver opening and the firewall rule are one approval, not two. |
| **internal/notify** | **Reused** for "DNS deploy applied / failed / hostname published" alerts via the existing fan-out dispatcher. |
| **internal/audit** | Every plan/approve/apply/record-publish/firewall-open emits a hash-chained audit event. |
| **internal/outbound** | All Cloudflare calls already go through the SSRF-guarded client inside `internal/ddns`. Nothing new. |

### 2.1 CORE-provider vs plugin — decision: **CORE provider.**
This is server-owned infrastructure that (a) mutates the host firewall, (b) holds a Cloudflare API token, (c) renders privileged install/run plans, and (d) is tightly coupled to three existing core subsystems (ddns, nft, approvals). The plugin tiers in `architecture.md` are for *extension* code with brokered capabilities; the plugin runtime does not even execute artifacts yet (Phase B incomplete). Putting DNS deployment behind the broker would mean re-exposing nft-rendering and CF-token handling as plugin capabilities — strictly more attack surface for zero benefit. It belongs next to `cftunnel` and `wireguard` as a trusted built-in. **A future *third-party* "alternative DNS engine" could be a plugin, but the deployment orchestrator is core.**

---

## 3. Data model

All structs go in `lattice-sdk/model/model.go` (shared wire model). New constants grouped with the existing provider/status const blocks.

```go
// --- constants (add near DDNSProvider* / MonitorType* blocks) ---

const (
    // DNS engines. v1 ships only CoreDNS; the field is engine-tagged so a second
    // engine can be added later without a schema change.
    DNSEngineCoreDNS = "coredns"

    // Exposure posture. Default is mesh-only (fail-closed); public is an explicit,
    // loudly-audited widening of the firewall rule.
    DNSExposureMesh   = "mesh"   // answer only from the WireGuard CIDR + loopback
    DNSExposurePublic = "public" // also answer on the public interface (opt-in)

    // Zone modes for a served block.
    DNSZoneForward = "forward" // forward this suffix to an upstream resolver
    DNSZoneStatic  = "static"  // serve static A/AAAA/CNAME records authoritatively
    DNSZoneBlock   = "block"   // return NXDOMAIN/0.0.0.0 (ad-block / sinkhole)

    // Deployment lifecycle status (server-observed).
    DNSStatusPending   = "pending"   // created, never applied
    DNSStatusApplying  = "applying"  // apply task queued/leased
    DNSStatusRunning   = "running"   // last apply succeeded, engine reloaded
    DNSStatusFailed    = "failed"    // last apply or validate failed
    DNSStatusDisabled  = "disabled"  // operator-disabled; nft rule withdrawn on next plan
)

// DNSZone is one served block of the resolver config.
type DNSZone struct {
    Suffix   string   `json:"suffix"`             // "mesh.roobli.internal." or "." for default
    Mode     string   `json:"mode"`               // forward | static | block
    Upstreams []string `json:"upstreams,omitempty"` // for forward: "1.1.1.1", "tls://1.1.1.1" (validated)
    Records  []DNSRecord `json:"records,omitempty"` // for static
}

// DNSRecord is a static record served authoritatively for a static zone.
type DNSRecord struct {
    Name  string `json:"name"`  // "gw.mesh.roobli.internal." (FQDN within the zone)
    Type  string `json:"type"`  // A | AAAA | CNAME
    Value string `json:"value"` // IP or target host
    TTL   int    `json:"ttl,omitempty"`
}

// DNSDeployment describes a self-hosted DNS server deployed on one node. It is the
// peer of model.TunnelProfile: the server stores topology + policy + the CF token;
// the node never receives the token and never decides its own firewall.
type DNSDeployment struct {
    ID      string `json:"id"`
    Name    string `json:"name"`
    NodeID  string `json:"node_id"`
    Engine  string `json:"engine"`   // coredns

    // Listener.
    ListenPort int    `json:"listen_port"`          // default 53
    EnableUDP  bool   `json:"enable_udp"`           // default true
    EnableTCP  bool   `json:"enable_tcp"`           // default true
    Exposure   string `json:"exposure"`             // mesh | public (default mesh)

    // Served policy.
    Zones []DNSZone `json:"zones"`

    // Cloudflare hostname automation. The server publishes Hostname -> node IP via
    // the existing internal/ddns Cloudflare provider and keeps it current on
    // IP-change. CFAPIToken is SECRET-AT-REST (see §3.1). If a DDNSProfile id is
    // supplied instead, reuse that profile's token/zone rather than storing a new one.
    Hostname     string `json:"hostname,omitempty"`      // "gmami-jp1.dns.roobli.org"
    PublishIPv4  bool   `json:"publish_ipv4"`            // default true
    PublishIPv6  bool   `json:"publish_ipv6"`            // default false
    RecordTTL    int    `json:"record_ttl,omitempty"`    // default 60
    CFAPIToken   string `json:"cf_api_token,omitempty"`  // SECRET; omitted from all read views
    DDNSProfileID string `json:"ddns_profile_id,omitempty"` // optional: reuse an existing CF DDNS profile

    // Status (server-written after apply / publish).
    Status        string    `json:"status"`
    EngineVersion string    `json:"engine_version,omitempty"` // reported by agent facts
    LastIPv4      string    `json:"last_ipv4,omitempty"`      // last published record value
    LastIPv6      string    `json:"last_ipv6,omitempty"`
    LastAppliedAt time.Time `json:"last_applied_at,omitempty"`
    LastError     string    `json:"last_error,omitempty"`
    Disabled      bool      `json:"disabled,omitempty"`
    CreatedAt     time.Time `json:"created_at"`
    UpdatedAt     time.Time `json:"updated_at"`
}
```

Agent fact extension (tiny, optional, additive) — let the node report whether the engine is present so the dashboard can show drift:

```go
// add to model.Node (kept optional; reported via /api/agent/hello like the WG fields)
CoreDNSVersion string `json:"coredns_version,omitempty"`
```

### 3.1 Secret-at-rest wiring
`DNSDeployment.CFAPIToken` is the **only** secret field and must be encrypted at the store boundary exactly like `DDNSProfile.CFAPIToken`. Concretely, in `internal/store/crypto.go`:
- Add a `dnsDeployments` loop to both `encryptedState` and `decryptState`.
- Add `encryptDNSDeploymentRecord` / `decryptDNSDeploymentRecord` mirroring `encrypt/decryptDDNSRecord` (single field: `CFAPIToken`).
- Extend `stateHasEnvelope` to check `d.CFAPIToken` so the lost-master-key guard stays accurate.
- Update the file-top "Encrypted fields" comment.
- When `DDNSProfileID` is used instead of an inline token, store **no** token on the deployment (the secret lives only on the referenced `DDNSProfile`). Prefer this path operationally; the inline token exists for standalone use.

Read views (`toDNSView`) must drop `CFAPIToken` entirely — same rule the DDNS/Tunnel/Notify list APIs already follow ("returns only key names, never secret values").

---

## 4. Server API

New handlers live in **`internal/server/server_dns.go`** (server.go is large; the OIDC area already set the precedent of `server_oidc.go`). Routes registered in `server.go`'s mux block next to the tunnel routes.

| Method | Path | Scope | Body → Response |
|---|---|---|---|
| `GET` | `/api/dns/deployments` | `dns:admin` | → `[]dnsView` (node-allowlist filtered, token stripped) |
| `POST` | `/api/dns/deployments` | `dns:admin` | `DNSDeployment` (create/update; validates engine+zones+port+hostname) → `dnsView` |
| `POST` | `/api/dns/deployments/delete` | `dns:admin` | `{id}` → `{ok:true}` (also withdraws nft rule + optionally CF record on next plan) |
| `POST` | `/api/dns/plan` | `dns:admin` | `{id}` → `model.Approval` (renders config+nft bundle, records pending approval) |
| `POST` | `/api/dns/publish` | `dns:admin` | `{id}` → `{ok, ipv4, ipv6}` (synchronously push the CF record now, like `/api/ddns/run`) |

Reused, **not** re-implemented:
- **Approval/apply:** the operator approves through the existing `POST /api/network/approve` with `{approval_id, queue_apply:true, plan_sha256:<hash>}`. No new approve endpoint.
- **Agent task pull / result:** existing `GET /api/agent/tasks` + task-result path.
- **CF record on IP change:** existing `maybeTriggerDDNS` (extended to also walk `DNSDeploymentsForNode`).

Request/response shapes:
- **Create** validates eagerly by calling the renderer (like `handleTunnels` calls `cftunnel.GenerateConfig`): bad zone suffix, bad upstream, port out of range, or unknown engine → `400` before persistence.
- **Plan** response is a `model.Approval` whose `Plan` is the **human-reviewable bundle**: the rendered engine config, the nft rule fragment, and a one-line summary of the CF hostname action. The reviewer hashes exactly this text for `plan_sha256`.
- **dnsView** = the deployment minus `CFAPIToken`, plus a derived `resolved_hostname` and `firewall_summary` for the UI.

`handleDNSPlan` skeleton (mirrors `handleTunnelPlan` + folds nft):

```go
func (s *Server) handleDNSPlan(w http.ResponseWriter, r *http.Request, p principal) {
    // method guard …
    var req struct{ ID string `json:"id"` }
    if !decodeClientJSON(w, r, &req) { return }
    dep, ok := s.store.DNSDeployment(req.ID)
    if !ok { writeError(w, http.StatusNotFound, errors.New("dns deployment not found")); return }
    if !s.requireNodeScope(w, p, "dns:admin", dep.NodeID) { return }

    cfg, err := selfdns.GenerateConfig(dep)          // engine config (CoreDNS Corefile)
    if err != nil { writeError(w, http.StatusBadRequest, err); return }
    nftFrag, err := selfdns.GenerateNFTFragment(dep) // dport rule, mesh-only or public
    if err != nil { writeError(w, http.StatusBadRequest, err); return }

    plan := selfdns.RenderApprovalPlan(dep, cfg, nftFrag) // single reviewable text blob
    approval := model.Approval{
        ID: id.New("approval"), NodeID: dep.NodeID,
        Plugin: "selfdns", Action: "apply-config",
        Plan: plan, Status: model.ApprovalPending,
        ActorID: p.ActorID, CreatedAt: time.Now().UTC(),
    }
    if err := s.store.UpsertApproval(approval); err != nil { writeError(w, 500, err); return }
    s.recordPrincipalAudit(p, model.AuditEvent{ID: id.New("audit"), NodeID: dep.NodeID,
        Action: "dns.plan", Scope: "dns:admin",
        Metadata: map[string]string{"approval_id": approval.ID, "dns_id": dep.ID, "exposure": dep.Exposure}})
    writeJSON(w, http.StatusOK, approval)
}
```

The apply branch (the *only* edit to `server.go`'s `applyScriptFor`):

```go
case "selfdns":
    // approval.Plan is the reviewable bundle; the agent needs the engine config and
    // the nft fragment as separate artifacts. We carry them in the plan with stable
    // sentinel markers that RenderApprovalPlan emitted; the apply script extracts by
    // marker. (Simpler alternative: keep Plan == Corefile only, and stash the nft
    // fragment in approval.Metadata — see §6 for the chosen encoding.)
    return selfdns.ApplyScript(approval) // see §6
```

---

## 5. Agent responsibilities

The agent does **only** what every other apply task already does — no new agent code path, no new endpoint, no inbound port. The DNS apply is a bounded `sh` task pulled from `GET /api/agent/tasks` and run through `internal/taskexec` (rlimits, process-group kill, interpreter allowlist — `sh` is already allowed; root-refusal applies as today, and binding port 53 legitimately needs privilege, see §7).

**Apply-task contract** (what the server-rendered script guarantees):
1. **Idempotent install:** if the engine binary is absent at the pinned path, fetch the pinned-version static binary and verify its SHA-256 against a server-embedded digest **before** executing it; otherwise skip. (Fail-closed: digest mismatch aborts with non-zero exit.)
2. **Atomic config write:** write the Corefile to a `.new` temp, validate (`coredns -conf <file> -plugins` style dry check, or `coredns -validate` where available), then `mv` into place — never leave a half-written config.
3. **Reload, not restart-if-avoidable:** `systemctl reload coredns || systemctl restart coredns`, falling back to a "config written; start manually" message on a host without the unit (mirrors the cftunnel branch's tolerant reload).
4. **Bounded:** `TimeoutSec` (30–60s; install may need the higher bound), `OutputLimit` 64 KiB, exactly like the nft/tunnel apply tasks.
5. **Report:** the agent returns exit code + stdout/stderr via the normal task-result path. **Exit 0 ⇒ server marks `DNSStatusRunning`; non-zero ⇒ `DNSStatusFailed` with `LastError` = trimmed stderr.** The server reconciles this in the task-result handler by correlating the task back to the approval/deployment (carry `dns_id` in task metadata or approval linkage).

**Fact reporting:** the agent may include `coredns_version` in its `/api/agent/hello` payload (run `coredns -version` if the binary exists). This drives a "engine present / version drift" indicator and lets the server skip re-install. Purely additive; absence means "unknown".

The agent **never**: holds the CF token, opens the firewall by itself, decides exposure, or talks DNS to the server. nft commitment vs. validation: today the nft branch only runs `nft -c` (check). For DNS the firewall rule must actually be **committed** to open the port — so the selfdns apply script runs the *committed* nft load for the merged ruleset (the full node ruleset, regenerated server-side to include the DNS dport), consistent with "the apply mode should require a separate explicit apply" note in the Safety Model. This is the one place we move from check to commit; it is gated behind `network:apply` approval and a `plan_sha256` of the exact merged ruleset.

---

## 6. Config rendering / external integration

New package **`lattice-server/internal/selfdns/`** — peer of `cftunnel`, dependency-free, hand-rendered + strictly validated, pure Go. Files: `selfdns.go` (render+validate), `apply.go` (script builder), `selfdns_test.go`.

### 6.1 Artifacts generated

**(a) CoreDNS Corefile** — `GenerateConfig(dep) (string, error)`. Validation is the security boundary (same discipline as `cftunnel.GenerateConfig` / `nft.GenerateNFTPlan`): every interpolated value passes a regex/parse gate so attacker-controlled zone names or upstreams cannot break out of the config grammar.
- Listener line bound to port (`:53` or `<mesh-ip>:<port>`); for `mesh` exposure bind to the WireGuard interface IP only — defense in depth on top of nft.
- Per zone: `forward` → `forward . <upstreams>` with each upstream parsed as `ip[:port]` or `tls://ip`; `static` → `hosts`/`file` block with each record's `Name/Type/Value` parsed (IPs via `net.ParseIP`, hosts via the hostname regex); `block` → `template`/`hosts` returning NXDOMAIN.
- Always include `errors` + `log` + `cache` + `loop` plugins; never enable recursion to the world unless `exposure==public`.
- Reject: suffixes failing a DNS-name regex, upstreams that aren't parseable IPs or `tls://` forms, ports outside 1–65535, record values failing `net.ParseIP`/hostname checks, and any value containing `\n`/`\r`/`{`/`}` (config-injection guard).

**(b) nft fragment** — `GenerateNFTFragment(dep)`; in practice this is **folded into the node's full `network.NFTPlan`** rather than emitted standalone, so the committed ruleset stays a single coherent table (the existing nft renderer drops anything not in the plan). Mapping:
- `exposure==mesh`: add the DNS port to `WireGuardUDP` and/or `WireGuardTCP` (answered only from `@wg_peers4`). This is the default and the safe path.
- `exposure==public`: add the DNS port to `PublicUDP` and optionally
  `PublicTCP` on the node's persisted `NFTInputs` (iter-019 added public UDP
  support specifically so DNS/53 can be represented).
- The server composes the node's persisted nft inputs + the DNS ports →
  `network.GenerateNFTPlan` → the committed ruleset that the apply script loads
  with `nft -f` (commit), preceded by `nft -c -f` (validate) as a guard.

**(c) Cloudflare DNS record** — **reuse `internal/ddns` end to end, no new code:**
- On `POST /api/dns/publish` and on the create path, build a `model.DDNSProfile` view from the deployment (`Provider: cloudflare`, `Domains: [Hostname]`, `CFAPIToken` from the deployment or the referenced `DDNSProfileID`, `EnableIPv4/6` from `PublishIPv4/6`, `TTL: RecordTTL`) and call `ddns.NewProvider` + `ddns.Apply(ctx, prov, profile, node.PublicIP, node.PublicIPv6)`. This is exactly `runDDNSWithAudit`.
- For *continuous* tracking, extend `maybeTriggerDDNS(nodeID, …)` to also iterate `s.store.DNSDeploymentsForNode(nodeID)` and publish each deployment's hostname when the node IP changes — so the subdomain follows the node with zero clicks, same as a DDNS profile. Record `LastIPv4/LastIPv6/LastAppliedAt` on the deployment.
- Records are created **un-proxied** (grey-cloud) — the CF client already forces `Proxied:false` — because we want the raw node IP for DNS, not Cloudflare's proxy.

### 6.2 Apply-script encoding (chosen)
Keep `approval.Plan` = the **human-reviewable bundle** (Corefile + the merged nft ruleset + a CF action summary), because `plan_sha256` must cover *everything the reviewer approved*, including the firewall change. The apply script (`selfdns.ApplyScript`) is built from the **same** dep+renderer at approve time (not parsed back out of Plan text): it `heredoc`-writes the Corefile and the nft ruleset (reusing the existing `heredocWrite`/`heredocDelimiter` helpers), validates, commits nft, validates Corefile, reloads. Because both Plan and ApplyScript derive deterministically from the approved deployment + node state, they stay consistent, and the `plan_sha256` guard still defends against a plan-swap between review and approve.

### 6.3 Validation & reload summary
- Corefile: dry-validate before swap; abort on failure (config untouched).
- nft: `nft -c -f` (check) then `nft -f` (commit); the table is `inet lattice_guard` so a bad load can't silently coexist with the old one.
- Engine binary: SHA-256 pin verified pre-exec.
- Reload tolerant of missing systemd unit.

---

## 7. Security

**Authz & blast radius.**
- CRUD/plan require `dns:admin`; the apply gate requires `network:apply`; both are additionally constrained by the **per-node allowlist** via `requireNodeScope`. A token scoped to node X cannot deploy DNS to node Y.
- The destructive step (open firewall + run a resolver) is **two-person-shaped**: `dns:admin` plans, `network:apply` approves, with required `plan_sha256` binding for the pending apply approval. Reuse, not new code.

**Fail-closed defaults.**
- `Exposure` defaults to `mesh` — the resolver answers only from the WireGuard CIDR; the nft rule restricts to `@wg_peers4`; CoreDNS also binds to the mesh IP. Public exposure is opt-in and audited with a distinct `dns.exposure.public` reason so it stands out in the log.
- No recursion to the public internet unless `public`. An unconfigured/empty zone set renders a deny-all resolver, not an open one.
- Digest mismatch on the engine binary, Corefile validation failure, or nft check failure all abort with non-zero exit → server marks `DNSStatusFailed`, no partial open.

**Secret handling.**
- `CFAPIToken` is the only secret; encrypted at rest via `internal/store/crypto.go` (§3.1), never returned in any view, never sent to the agent. Prefer `DDNSProfileID` reuse so the token lives in exactly one place.
- The token never appears in `approval.Plan`, the apply script, task stdout, or audit metadata. CF calls happen **server-side** through the SSRF-guarded `internal/outbound` client already used by `internal/ddns`.

**What a compromised node could do.**
- It already runs the agent and can resolve DNS for itself. The new capability adds: it could serve **wrong answers to the mesh** (if it's the deployed resolver and other nodes point at it). Mitigation: this is opt-in topology the operator controls; mesh-only exposure bounds the audience to trusted peers; the resolver answers are not a trust anchor for auth (Lattice auth is bearer tokens over HTTPS, not DNS). It **cannot** mint a public record (no token on the node) and **cannot** widen its own firewall (nft is server-rendered and approval-gated).
- A compromised node returning bad answers for the apex would still be defeated by TLS cert validation on any HTTPS the operator uses; DNS is not the security boundary.

**Privilege note.** Binding port 53 and committing nft need root on the node. The agent's root-refusal sandbox is for *task scripts*; firewall/DNS apply is exactly the privileged class the plan→approve→apply flow exists to gate (the wireguard branch already runs `wg-quick`, the tunnel branch writes `/etc/cloudflared`). The apply task runs with the agent's existing privileged-apply path (same as wireguard/cftunnel), **not** the unprivileged exec path. Document this clearly so the operator runs the agent with the capability to apply, and audit every apply.

**Audit events** (all hash-chained): `dns.create`, `dns.delete`, `dns.plan`, `dns.exposure.public` (distinct, on any public plan), `network.selfdns.approve` (via the shared approve handler's `network.<plugin>.approve`), `dns.publish` (CF record set, with hostname + record type, never the token), `dns.apply.result` (exit code, deployment id). Failures are audited with the trimmed error.

---

## 8. Phasing

Each phase ships as a tested, reviewed, committed slice (the §5 cadence in PRODUCT-VISION).

**MVP (smallest shippable slice) — mesh-only forwarder + manual publish.**
- `model.DNSDeployment` (+ const block, + `Node.CoreDNSVersion`) in the SDK; store collection + accessors; crypto wiring for `CFAPIToken`.
- `internal/selfdns`: CoreDNS Corefile render for **forward** zones only; nft fold for **mesh** exposure (uses existing `WireGuardUDP/TCP`, no nft model change yet).
- `server_dns.go`: list/create/delete/plan; reuse the existing approve+apply; `applyScriptFor` `case "selfdns"`.
- `POST /api/dns/publish` reusing `ddns.Apply` for a one-shot CF record set; **manual** publish only (no auto IP-change hook yet).
- **Exit bar:** operator creates a CoreDNS forwarder on `gmami-jp1`, mesh-only, port 53/udp+tcp restricted to the WG CIDR, approves the plan (with the nft port opened in the same approval), the agent installs+runs CoreDNS, `gmami-jp1.dns.roobli.org` resolves to the node via a manual publish, all steps audited; `go test -race ./...` + gofmt green; adversarial review passed.

**v2 — continuous publish + static/block zones + public exposure.**
- Extend `maybeTriggerDDNS` to walk `DNSDeploymentsForNode` (hostname follows node IP automatically).
- Add `static` (authoritative A/AAAA/CNAME) and `block` (sinkhole) zone modes to the renderer.
- Add `PublicUDP []int` to `network.NFTPlan` and the `public` exposure path; `dns.exposure.public` audit + notify alert on every public deploy.
- Dashboard panel (zero-dep vanilla JS, strict CSP): deployment list, create form, plan diff (Corefile + nft + CF action), approve button, status/health, "publish now".
- **Exit bar:** a node's DNS subdomain self-heals across IP changes; an operator can serve a private split-horizon zone and a sinkhole; public exposure is possible but loud; UI surfaces it end-to-end with E2E verification.

**Later — apex steering, DoT/DoH, DNSSEC, second engine, per-client ACL.**
- CF geo-routing / load-balancing of `dns.roobli.org` across multiple per-node deployments (depends on a CF LB plan; design the steering policy as a separate doc).
- CoreDNS `tls`/`acl`/`dnssec` plugins; a second engine behind the engine tag if a real need appears (ADR required if it adds a dependency).
- **Exit bar (per item):** each is its own tested/reviewed slice with its own exit bar; none regresses the fail-closed default.

---

## 9. Risks & open questions

- **Binary provenance.** v1 pins a CoreDNS version + SHA-256 and verifies before exec. Open: do we embed the digest in the server binary (simplest, requires a release bump to upgrade CoreDNS) or make it an operator-set field per deployment (flexible, more rope)? **Recommendation: server-embedded digest map keyed by version; operator picks a version from the allowed set.** Revisit if it becomes a maintenance drag.
- **nft single-table coupling.** The node's full ruleset is server-rendered into one `inet lattice_guard` table; the DNS port must be folded into the *same* render, not a second table, or the existing renderer would drop it. This means the DNS plan needs the node's *current* nft inputs. Open: where do those inputs live authoritatively today (are they persisted per node, or recomputed)? **Action: confirm the nft input source before building §6.1(b); if nft inputs aren't persisted per node, persist them (small store addition) so DNS and base firewall compose deterministically.** This is the single most important pre-build clarification.
- **Port 53 + systemd-resolved.** Many distros run `systemd-resolved` on `127.0.0.53:53`, which can conflict. v1 binds the resolver to the **mesh IP**, sidestepping the loopback stub; document that public exposure on a resolved host needs the stub disabled. Surface a clear error from the apply script rather than a silent bind failure.
- **CF record type vs proxy.** Records are grey-cloud (un-proxied) by design; confirm the operator's `dns.roobli.org` delegation expectations match (the apex stays Cloudflare-managed; only the per-node label is a grey-cloud A/AAAA).
- **Reconciliation of apply result → deployment status.** The task-result handler must correlate a finished apply task back to its deployment to set `running/failed`. Open: carry `dns_id` in task metadata vs. approval linkage. **Recommendation: stamp `dns_id` into the task (a small `Task.Metadata` or a typed link) at queue time** — cleaner than parsing scripts.
- **Engine choice durability.** CoreDNS is pure-Go and static-linkable, which fits zero-CGo perfectly. If a future engine needs CGo, it's disqualified or must be an out-of-tree plugin — note this in the engine-tag ADR.

---

## 10. Borrow vs avoid (from the reference panels)

The research brief on self-hosted DNS came back **"Complete"** with no reference panels attached to this design pass; the borrow/avoid below is therefore distilled from the **in-repo reference implementations** that already solved the analogous problems, which is the stronger source for a Lattice-native design:

**Borrow:**
- **From `internal/cftunnel`:** the *render-validated-config-then-heredoc-write-then-tolerant-reload* shape, including the catch-all-rule discipline and the strict hostname/service regexes. Our Corefile renderer copies this validation posture line-for-line. The "credentials stay node-local, server stores only topology" stance maps directly onto "CF token stays server-side, node gets only config".
- **From `internal/network/nft`:** parse-and-re-emit-canonical (e.g. `net.ParseCIDR` → `.String()`) so interpolated values can't carry injected syntax; the `@wg_peers4` set restricting services to the mesh is exactly our mesh-exposure default. Reuse the same table so there's one coherent firewall.
- **From `internal/ddns`:** the entire CF record path — `NewProvider`/`Apply`/`SetRecord` (idempotent no-op when already correct), the longest-zone-suffix match, un-proxied records, the SSRF-guarded outbound client, and `maybeTriggerDDNS` for IP-follow. **Do not write a second CF client.**
- **From the approve flow:** `model.Approval{Plugin,Action,Plan}` + `applyScriptFor` + `plan_sha256` binding + `queue_apply`. A new node capability is one `case` in `applyScriptFor` and one renderer package — nothing more.
- **From `internal/store/crypto.go`:** the per-record encrypt/decrypt boundary + `stateHasEnvelope` guard for the one secret field.

**Avoid:**
- **Avoid a new external DNS library / libdns / a CGo-linked resolver.** It violates the zero-CGo, tiny-dependency-surface constraint and would need an ADR with no upside (CoreDNS-as-a-binary + the std-lib CF client already cover it).
- **Avoid making this a plugin.** The plugin runtime doesn't execute artifacts yet, and brokering nft-render + CF-token would enlarge attack surface (§2.1).
- **Avoid emitting a *second* nft table** for the DNS port — it would be dropped by the single-table renderer and could drift from the base firewall.
- **Avoid putting the CF token anywhere near the agent, the approval plan, or task output.** All CF mutation is server-side.
- **Avoid a public-by-default resolver.** Open recursive resolvers are abuse magnets (DNS amplification); fail-closed to mesh-only.
- **Avoid parsing the apply script back out of `approval.Plan`.** Re-render deterministically from the approved deployment so Plan and ApplyScript can't diverge.

---

## 11. Dev guide — ordered build checklist

Consistent with `development-workflow.md` (research/reuse → plan → TDD → review → commit). Build/test with `GOWORK` set (multi-repo `go.work`); `go test -race ./...` + gofmt + dashboard green per slice; independent adversarial review before commit. **This checklist is the MVP slice (§8); v2/later items are called out.**

**Step 0 — Plan artifact.** Write `lattice/docs/iterations/iter-NNN-self-host-dns.md` (goal, scope, design ref = this doc, risks, test plan, exit bar) before code. Resolve the §9 nft-input-source question first (it gates §6.1(b)).

**Step 1 — SDK model (`lattice-sdk/model/model.go`).**
1. Add the `DNSEngine*`/`DNSExposure*`/`DNSZone*`/`DNSStatus*` const blocks.
2. Add `DNSZone`, `DNSRecord`, `DNSDeployment` structs (with json tags above).
3. Add `Node.CoreDNSVersion string` (optional fact).
4. Update `proto_contract_test.go` expectations if it enumerates types.
5. `gofmt`; `go test ./...` in the SDK module.

**Step 2 — Store collection (`internal/store/store.go`).**
1. Add `DNSDeployments map[string]model.DNSDeployment` to `State` (json tag `dns_deployments`); init in the constructor and the nil-guard block.
2. Add accessors mirroring DDNS/Tunnel: `UpsertDNSDeployment`, `DNSDeployment(id)`, `DNSDeployments()`, `DNSDeploymentsForNode(nodeID)`, `DeleteDNSDeployment(id)`.
3. **TDD:** table-driven store tests for round-trip + per-node filter.

**Step 3 — Secret-at-rest (`internal/store/crypto.go`).**
1. Add the `dnsDeployments` loop to `encryptedState` + `decryptState`.
2. Add `encrypt/decryptDNSDeploymentRecord` (single field `CFAPIToken`, copy the DDNS helper).
3. Extend `stateHasEnvelope` with `d.CFAPIToken`; update the header comment's "Encrypted fields" list.
4. **TDD:** extend `crypto_test.go` — token encrypts at rest, decrypts on load, lost-key guard trips. Mirror for the bbolt path if the per-record helpers are exercised there.

**Step 4 — Renderer package (`internal/selfdns/`).**
1. `selfdns.go`: `GenerateConfig(model.DNSDeployment) (string, error)` (Corefile, forward zones for MVP) with the regex/parse validation gates from §6.1; `GenerateNFTFragment` / the helper that maps the DNS port into `network.NFTPlan` inputs for mesh exposure; `RenderApprovalPlan(dep, cfg, mergedNft) string`.
2. `apply.go`: `ApplyScript(model.Approval) string` (digest-verified install → atomic Corefile write+validate → `nft -c` then `nft -f` commit → reload), reusing `heredocWrite`/`heredocDelimiter` (move those helpers to a shared spot or duplicate minimally).
3. **TDD first (`selfdns_test.go`):** golden Corefile for a forward zone; injection inputs (newline/brace/bad upstream/bad port/bad suffix) all rejected; mesh exposure maps to WG sets, never public; plan render is stable/deterministic.

**Step 5 — nft input composition.** Use the persisted `model.NFTInputs`
introduced in iter-019. For mesh exposure, append the DNS port to
`WireGuardUDP` / `WireGuardTCP`; for public exposure, append it to `PublicUDP`
and optionally `PublicTCP`, then render the single merged `lattice_guard`
ruleset. Do not create a second nft table.

**Step 6 — Server handlers (`internal/server/server_dns.go`).**
1. `handleDNSDeployments` (GET/POST), `handleDeleteDNSDeployment`, `handleDNSPlan`, `handleDNSPublish`, `toDNSView` (strips token).
2. Register routes in `server.go`'s mux next to `/api/tunnels*` with scopes `dns:admin`; ensure `dns:admin` is a known scope in `internal/rbac`.
3. Add `case "selfdns"` to `applyScriptFor` (delegates to `selfdns.ApplyScript`).
4. Extend `maybeTriggerDDNS` to also publish `DNSDeploymentsForNode` (v2 continuous publish) — for MVP, wire `handleDNSPublish` to `ddns.NewProvider`+`ddns.Apply` for one-shot publish, recording `LastIPv4/6/LastAppliedAt/LastError` and an audit event.
4. Stamp `dns_id` into the queued apply task (metadata/link) and reconcile status in the task-result handler (`running`/`failed`).
5. **TDD (`server_dns_test.go`):** create validates+hides token; plan records a pending approval with the right `Plugin`; approve+`queue_apply` queues a task whose script contains the Corefile + nft commit; `plan_sha256` mismatch is rejected; publish calls the (mocked) CF provider and records the IP; node-allowlist denial for a wrong-node token.

**Step 7 — Agent fact (optional, `lattice-node-agent`).** Report `coredns_version` in the hello payload when the binary exists. No other agent change (apply runs through the existing privileged-apply task path).

**Step 8 — Verify.** `GOWORK=… go test -race ./...` across server/sdk/agent; gofmt; `go vet`; manual end-to-end on a test node (or a documented dry-run) proving: plan diff is reviewable, approval opens the port + runs CoreDNS, hostname resolves, status flips to `running`.

**Step 9 — Review.** Independent adversarial pass (security-reviewer / verifier, separate context): focus on config-injection in the renderer, the check-then-commit nft transition, token non-leakage (views/plan/script/audit/logs), and fail-closed exposure default. Fix must-fixes with regression tests.

**Step 10 — Docs + commit.** Add a "Self-Hosted DNS" section to `architecture.md` (peer of the DDNS/Tunnel/WireGuard sections); record the version-digest decision in an ADR if a CoreDNS dependency/version policy is introduced; update the iteration doc with outcome + residuals; conventional-commit slices (`feat: self-hosted DNS deployment (mesh forwarder MVP)`), branch off default, push only when asked.
