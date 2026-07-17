# Design 15 - line_uuid identity, per-line user management, chain recognition, Sub-Store deep integration

> Status: accepted for alpha implementation on 2026-07-17.
> Builds on: design-09, design-12, design-14, adr-001.
> Decision record for the 2026-07-17 operator review ("vpn-core deep
> optimization + Sub-Store integration + fine-grained user management +
> chain-proxy identification").

## 1. Intent

Give every proxy line a stable, control-plane-assigned identity (`line_uuid`)
that survives re-discovery, IP changes, and cross-machine relay topologies;
make per-line user CRUD a real, audited write path onto already-deployed
sing-box nodes; upgrade relay-graph edges from inferred (host,port) matching to
declared `line_uuid` joins; and deepen the Sub-Store companion with preview,
an opt-in persisted endpoint, and change-triggered auto-sync — without merging
the two plugins and without patching the sing-box core.

## 2. Decision registry

| # | Decision | Rationale |
|---|----------|-----------|
| D1 | `line_uuid` is a control-plane-assigned UUIDv4 per line. The `line_hash_id ↔ line_uuid` mapping is persisted in the server BoltDB bucket `vpnmeta/lineuuid`. `line_hash_id` remains the topology fingerprint (recomputable from connection shape); `line_uuid` is the durable identity for joins, metadata, and per-user stat attribution. | Hash identity changes when connection shape changes (new port, retagged); operator intent ("this is the same line") must survive that. |
| D2 | Line metadata lives in the sidecar file `/etc/sing-box/lattice-metadata.json` (schema `lattice.singbox-metadata.v2`). The schema reserves `reserved.in_config_key: "_lattice"` with frozen field names/semantics so a future sing-box fork may dual-write in-config without a contract change. Stock sing-box is never given unknown keys. | Verified 2026-07-17 against upstream source: `option/options.go:38` (`DisallowUnknownFields`) and the badjson inbound/outbound path reject unknown fields at every level in v1.11.15, v1.13.14, and v1.14.0-alpha. The 2026-07 `_lattice`-in-`inbounds[0]` crash loop (lr00rl/sing-box#1) was this exact failure. A fork that relaxes strict parsing is a future, explicitly-scoped decision — not this design. |
| D3 | Per-line user write path is dual-track, adopted-first. Adopted (233boy-script) nodes: agent task runs `sb user add/del` (atomic jq write + `sing-box check` + rollback + restart). Managed nodes: server renders `users[]` into the full config and reloads. Both tracks go through plan→approve→apply with §9.3 typed approval columns. Every rendered/scripted user carries a unique `name` (see §5). | The fleet is already deployed with the 233boy fork; whole-file render would fight the on-box file-per-line layout. sing-box has no hot user API except SSM (Shadowsocks-only), so restart-after-check is the honest adopted path. |
| D4 | Sub-Store stays a separate companion plugin. Deepening = three additions: `preview`, opt-in persisted endpoint via the §9.4 encrypted secret store, and an in-core debounced auto-sync trigger on vpn-core mutations. No generic plugin event bus in this design. | Producer/publisher split (design-12 locked #4) still holds; Sub-Store keeps every native feature; the companion remains a thin pusher. A generic event bus is recorded in appendix C as future work, not built speculatively. |
| D5 | "Merge Sub-Store into vpn-core" is explicitly rejected (operator decision 2026-07-17, superseding the exploration question). | AGPL/GPL boundary on reimplementing Sub-Store (design-09 D9); the companion has zero durable state so merging buys little; two plugins keep the trust and release planes separate. |
| D6 | Deferred, recorded, not built here: multi-protocol managed rendering beyond VLESS+REALITY+TCP; quota/expiry auto-disable enforcement; generic plugin event bus / cron capability; sing-box fork with relaxed unknown-field parsing. | Each is an independent slice with its own review; none blocks D1–D4. |

## 3. `line_uuid` model

- Assignment: server allocates a UUIDv4 the first time a line becomes known —
  for managed lines at render time, for discovered lines at first inventory
  ingestion. Allocation is idempotent per `line_hash_id`
  (`ensureLineUUID`).
- Persistence: BoltDB bucket `vpnmeta/lineuuid`, key `line_hash_id`, value
  `line_uuid`. The reverse lookup (`line_uuid → line_hash_id`) is derived by
  scan at read time (fleet line counts are small; revisit if proven hot).
- Re-binding: when a line's connection shape changes (new port/tag), the old
  `line_hash_id` dies and a new one appears; operators may re-attach the old
  `line_uuid` to the new hash via the Lines UI (an audited `lines-admin`
  mutation). Until re-attached, the line shows a fresh `line_uuid`.
- Read model: `Line` gains `line_uuid` and `downstream_line_uuid`; both are
  secret-free and safe to show in the plugin UI and inter-plugin RPC.

## 4. Sidecar metadata contract v2

Canonical schema: `docs/contracts/lattice-singbox-metadata-v2.schema.json`
with valid/invalid fixtures beside it. Shape:

```json
{
  "schema": "lattice.singbox-metadata.v2",
  "node_id": "...", "node_uuid": "...",
  "updated_at": "RFC3339", "writer": "lattice-server|sb",
  "inbounds": [
    {"tag": "vless-31001", "line_uuid": "<uuid4>", "line_hash_id": "line_...",
     "chain": {"downstream_line_uuid": "<uuid4|null>", "downstream_node": "qqpw"}}
  ],
  "reserved": {"in_config_key": "_lattice",
    "fields": {"line_uuid": "string", "node_uuid": "string", "line_hash_id": "string"}}
}
```

Rules:

1. Writers are the Lattice server (via reviewed agent task `singbox.meta.apply`,
   atomic write + sibling backup) and the on-box `sb meta --json` fallback
   (same schema; last-writer-wins on `updated_at`, server render always
   converges on next apply). `writer` records provenance.
2. v1 sidecars (flat `{managed, plugin, line_hash_id, node_id, comment,
   updated_at}`) upgrade on read: missing `line_uuid` is allocated by the
   server and written back on the next apply cycle; unknown top-level keys are
   preserved.
3. The file is never consumed by sing-box (`-C` loads `*.json` only… the
   sidecar therefore must not be named `*.json` inside the `-C` directory;
   `/etc/sing-box/lattice-metadata.json` lives next to, not inside, `conf/`).
4. `reserved` is documentation-only in v2: no writer emits `_lattice` into
   sing-box config, no reader requires it. It freezes field names so a future
   fork dual-writes identical semantics.

## 5. Per-line user management

User `name` rule (single server implementation `userLineName(userID,
lineUUID)`):

```
name = "u_" + lowerhex(sha256(user_id + "|" + line_uuid))[:16]
```

Globally unique per (user, line), PII-free, recomputable on both sides of the
wire, and usable as the join key for sing-box `auth_user`, route rules, and
`user>>><name>>>>traffic>>>` stats counters alike.

Write path (both tracks are `users-admin` methods, scope `proxy:admin`):

| Method | Payload | Effect |
|--------|---------|--------|
| `apply_add` | `{user_id, line_hash_id}` | plan→approve→task: adopted → `sb user add <line> <json>`; managed → re-render users[] + reload |
| `apply_update` | `{user_id, line_hash_id}` | same, replacing the user's on-line credential block |
| `apply_remove` | `{user_id, line_hash_id}` | adopted → `sb user del <line> <name>`; managed → re-render without the user |
| `rotate` | `{user_id, protocol}` | regenerate one protocol credential; one-time reveal; write-only storage invariant preserved |

Post-apply the server triggers rediscovery (`sb --json list`) and reconciles
the read model. The UI wording stays honest: "queue on-node action, then
rediscover" — never "saved". Annotation-vs-runtime drift (expected user set
vs discovered `users[]`) is surfaced as drift, never silently overwritten.

Deploy-script fork (lr00rl/sing-box) contract changes, versioned with this
design: `sb user add` writes `name` (previously omitted — without it VLESS
users fall back to array index and stats attribution breaks); `sb user del`
accepts a name; new `sb meta --json` regenerates the v2 sidecar from on-box
state.

## 6. Chain recognition

Edge derivation in `buildLineGroups`, first match wins:

1. **Declared**: sidecar `inbounds[].chain.downstream_line_uuid` — exact join
   across machines, immune to NAT, DNS names, and shared ports.
2. **Inferred** (fallback, existing behavior): outbound (host, port) matched
   against the fleet-wide listen index.

Edges carry `via: declared|inferred` so the UI can distinguish orchestrated
chains from discovered ones. Managed renders that create relay outbounds also
emit the `chain` block into the sidecar, converting operator-built 233boy
topologies (hk hub 31001–31012 vless / 41001–41012 trojan fan-out) into
declared edges on the next apply.

Depends on the agent primary-path enrichment (`sb --json list` joined with
per-file inspect by inbound tag) plus sidecar reading — both land in the same
agent slice.

## 7. Sub-Store deep integration (no merge)

1. `preview` (effect=read, `proxy:read`): pulls vpn-core `nodes.export` and the
   remote sub's current content; returns counts (added/removed/unchanged) and
   node names. Full links only for `proxy:admin` callers.
2. Persisted endpoint (opt-in): `base_url` may be
   `secret://latticenet.sub-store/endpoint`, resolved by the server from the
   §9.4 encrypted secret store at invoke time (system-only scope, audited,
   outside `rbac.KnownScopes`). UI offers "save endpoint (encrypted)"; without
   it, per-session entry is unchanged.
3. Auto-sync: an in-core trigger fires after any committed vpn-core
   users/credentials/lines mutation, debounced 30s; if a saved endpoint exists
   and the toggle is on, the server invokes `import` as the system actor with
   full audit; failures go to `notify:send` and the UI status badge.
4. Error surface: broker `http.operator.do`/`http.do` errors include a bounded
   (≤4 KiB, redacted) response-body excerpt so Sub-Store backend errors reach
   the operator.

## 8. Per-user traffic accounting

Nodes run the sing-box experimental V2Ray stats API (config fragment via the
reviewed apply path); the agent collector reads
`user>>><name>>>>traffic>>>uplink/downlink`. The server reverses `name` via the
§5 rule into `(user_id, line_uuid)` and records
`UsageRow(ts, node, line, user, up, down)`. Discovered users without a `name`
render as "stats unavailable" — never as zero bytes. This phase adds alerting
only; auto-disable on quota/expiry is D6-deferred.

## 9. Security invariants (unchanged, restated)

- sing-box runtime config is the only source of truth; Lattice annotations lose
  every conflict and the UI must surface drift.
- Credentials are write-only (`has_*` read model); rotation reveals once.
- Every host mutation is a reviewed, typed-column-bound task plan; fail-closed.
- Step-up 2FA gates credential export; the iframe never sees session secrets.
- The Sub-Store backend stays loopback/private; the companion never exposes it.

## 10. Slice checklist

| Slice | Repo(s) | Content |
|-------|---------|---------|
| S0 | lattice | this doc + contract schema + fixtures |
| S1 | sdk | `SingBoxInventory` inbound: `line_uuid`, `downstream_line_uuid` (omitempty) |
| S2 | server | `linemeta.go` (bucket, allocate, sidecar render), `Line` fields, `singbox.meta.apply` task |
| S3 | node-agent | sidecar read + primary-path enrichment completion |
| S4 | server + vpn-core plugin + script fork | user write path dual-track, `rotate`, UI drawers |
| S5 | server + vpn-core plugin | declared-edge join, chain view |
| S6 | sub-store plugin + server + index | preview, secret:// endpoint, auto-sync, error surface |
| S7 | server + node-agent + script fork | stats fragment, collector, name reversal, degradation |
| S8 | assorted | lines index cache, plugin bump tool, bridge origin pinning, scope rename `vpncore:*`/`substore:*` |

## Appendix A — future sing-box fork notes

Relaxing strict parsing requires touching both `option/options.go`
(`DisallowUnknownFields`) and the badjson merge path used for polymorphic
inbound/outbound decode, or registering `_lattice` as a known ignored key.
Fleet-wide fork rollout, upstream merge cadence, and digest divergence from
official releases are the real costs; sidecar v2 carries everything the fork
would, so the fork needs an independent justification.

## Appendix B — validation fixtures

`docs/contracts/fixtures/`: `v2-valid-full.json`, `v2-valid-minimal.json`,
`v1-legacy-upgrade.json`, `invalid-missing-schema.json`,
`invalid-bad-line-uuid.json`. Implementations (server Go, `sb` jq) must round-
trip the valid set and reject the invalid set; the schema is the arbiter.

## Appendix C — future plugin-platform memos (not scheduled)

Generic `event:publish/subscribe` bus; plugin cron capability; wasm runner;
operator-target secret references generalized beyond Sub-Store.
