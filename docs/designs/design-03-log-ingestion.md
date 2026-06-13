# Design 03 — System Log Ingestion & Query

> Status: proposed (framework design + dev guide). Pure Go, zero CGo.
> Builds against the Phase-C bbolt foundation (`internal/store/bolt_state.go`).
> Author target: the operator builds against this directly.

The operator wants to name a log file on a node (e.g. `/var/log/nginx/error.log`),
have its lines streamed up to the server, persisted into a queryable store, and
queried by node / path / time / substring from the dashboard for debugging. This
is a **fleet log collection** capability, not a SIEM. The design is deliberately
the smallest thing that fits Lattice's poll-only agent, single-policy server,
fail-closed posture, and tiny-dependency budget — and it explicitly refuses to
put log volume in the whole-file JSON store.

---

## 1. Goal & scope

**Goal.** Let an operator declare a *log source* (node + absolute file path) on
the server; the assigned node agent tails that file, ships line deltas to the
server in batches over the existing HTTPS bearer channel; the server persists
them into a dedicated, bounded, append-only per-node log store; and the operator
queries them (filter by node, source/path, time window, substring) from a
dashboard panel.

**In scope (the capability):**
- Server-owned **LogSource** records (node + path + enable + caps), CRUD + assign.
- Agent **tailer**: reconcile assigned sources, tail with rotation handling,
  ship batched deltas, checkpoint its position.
- Server **ingest** endpoint with per-node back-pressure and rate limits.
- A **dedicated log store** (its own bbolt file, time-ordered keys, retention +
  byte-cap eviction) — *not* the JSON state file.
- A **query API** (node/source/time/substring/limit) + **dashboard log panel**.
- Audit events for source create/enable/disable/delete and ingest anomalies.

**Non-goals (v1) — say no on purpose:**
- ❌ No server-side regex/full-text index, no log *parsing* into structured
  fields, no severity extraction. v1 stores raw lines; query is substring +
  time + source. (Parsing/severity is v2; FTS is "later" if ever.)
- ❌ No log-driven alerting / monitor transitions in v1 (notify reuse is v2).
- ❌ No journald/systemd-unit ingestion, no Windows event log, no container
  stdout. v1 is **a file path you name**. (journald is a v2 source kind.)
- ❌ No plan→approve→apply for *reading* a log (rationale in §2). Apply-flow is
  only used if/when we let the operator make the agent *write* a logrotate/agent
  config artifact — deferred.
- ❌ No multi-line stitching / no compression on the wire in v1 (gzip is a cheap
  v2 add). No exactly-once: at-least-once with dedupe-by-offset.
- ❌ No querying *across* nodes in one ranked result set beyond simple
  concat+time-merge; no cross-node aggregation/topN.

---

## 2. System fit

| Lattice axis | How log ingestion maps |
|---|---|
| **Server = sole policy point** | Server owns `LogSource` records, decides which node tails what, enforces RBAC + ingest rate limits, owns the log store and the query API. The agent holds *no* policy. |
| **Agent = least-trust poller** | Agent only **dials out**. It GETs its assigned sources (`/api/agent/log-sources`), tails the named files read-only, and POSTs batches (`/api/agent/logs`). No inbound port, no new trust. |
| **plan → approve → apply** | **Intentionally not used for the read path.** That flow exists to gate *node mutation* (nft rules, wg-quick, writing `/etc/cloudflared/config.yml`). Tailing a file the operator named is a *read*, dispatched by assignment exactly like **Monitors** (`/api/agent/monitors` → run → `/api/agent/monitor-result`). Monitors are the correct precedent, not WireGuard. The apply-flow is reserved for the *future* case where we generate a node-side artifact (e.g. an agent-managed logrotate fragment) — see §6/§8. |
| **Store** | A **separate bbolt database file** (`logs.db`), opened alongside — never inside — the JSON state file. This is the first real consumer of the Phase-C bbolt foundation. High-volume, append-only, time-keyed, byte-capped, with retention. Putting logs in `State` would turn every metrics tick into a full-state JSON rewrite (`store.go` persists the *whole* `State`) — categorically wrong. |
| **RBAC** | New scopes `log:read` / `log:admin`, enforced through the existing `withAuth(scope, …)` + `requireNodeScope` + per-node allowlist machinery (`rbac.Allows` with `*`/prefix wildcards). Query results are filtered to nodes the principal may see, mirroring `monitorVisibleToPrincipal`. |
| **Rate limiting** | Ingest rides `withAgentLimit` (existing agent limiter) plus a dedicated per-node byte/lines budget (§7). |
| **notify** | Not wired in v1. v2: a "source went silent / ingest dropped" alert fans out through `internal/notify` exactly like `notifyMonitorTransition`. |
| **outbound / SSRF** | N/A — agent dials the server only; no operator-supplied URLs. |
| **Audit (hash-chained WAL)** | Source lifecycle + ingest-drop/back-pressure events are recorded via `recordPrincipalAudit` / the agent-event path, same as `ssh.login`. |

### CORE provider vs plugin — decision

**Core server-owned provider.** Same call as `ddns` and `notify`: it (a) needs a
new privileged agent capability (read arbitrary files on the node), (b) owns a
new persistent store and a new RBAC scope, (c) touches the agent's trusted poll
loop, and (d) must be auditable by construction. The plugin host-API broker
exposes `log:write` for *plugin-authored* logs into KV-ish surfaces — that is the
wrong primitive and the wrong trust tier for "read this node's syslog." A
third-party plugin must never be handed "tail any path on the box." **Build it as
`internal/logingest` (server) + an agent tailer in `lattice-node-agent`,
exactly parallel to monitors.**

---

## 3. Data model

### 3.1 SDK model additions (`lattice-sdk/model/model.go`)

```go
// LogSource declares a file on a node whose appended lines are tailed by the
// assigned agent and shipped to the server. It is assignment-driven like Monitor:
// exactly one node owns a source (a path is node-local), identified by NodeID.
type LogSource struct {
	ID        string `json:"id"`
	Name      string `json:"name"`            // operator label, e.g. "nginx-error"
	NodeID    string `json:"node_id"`         // the single node that tails this path
	Path      string `json:"path"`            // absolute path on the node, validated
	Enabled   bool   `json:"enabled"`         // disabled => agent stops tailing
	// Caps (server-set defaults; bound agent + ingest):
	MaxLineBytes  int       `json:"max_line_bytes"`  // truncate longer lines (default 16384)
	MaxBatchLines int       `json:"max_batch_lines"` // agent batch cap (default 500)
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// LogLine is one ingested line as persisted/queried. Not secret-at-rest by
// default (see note). Offset is the byte offset *after* this line in the source
// file at capture time; it is the agent checkpoint + server dedupe key.
type LogLine struct {
	SourceID string    `json:"source_id"`
	NodeID   string    `json:"node_id"`
	Path     string    `json:"path"`
	Seq      uint64    `json:"seq"`      // server-assigned monotonic per-source ingest seq
	Offset   uint64    `json:"offset"`   // agent: byte offset after this line (rotation-scoped)
	At       time.Time `json:"at"`       // agent capture time (UTC)
	Line     string    `json:"line"`     // raw line, max_line_bytes-truncated, no trailing \n
	Truncated bool     `json:"truncated,omitempty"`
}

// LogBatch is the agent → server ingest envelope (one source per batch).
type LogBatch struct {
	SourceID  string    `json:"source_id"`
	Path      string    `json:"path"`      // echoed for server cross-check vs source record
	RotID     string    `json:"rot_id"`    // opaque per-file-incarnation id (inode/ctime hash)
	FirstOff  uint64    `json:"first_off"` // offset before the first line in this batch
	LastOff   uint64    `json:"last_off"`  // offset after the last line (== agent checkpoint)
	Dropped   uint64    `json:"dropped"`   // lines the agent itself dropped (backpressure) since last batch
	Lines     []string  `json:"lines"`     // raw lines, ordered, no trailing \n
	CapturedAt time.Time `json:"captured_at"`
}
```

**Secret-at-rest?** Log *content* is **not** routed through
`internal/store/crypto.go` field encryption in v1, for two reasons: (1) crypto.go
encrypts *named fields of small records* in the JSON store; the log store is a
separate bbolt file with its own at-rest story; (2) per-line GCM sealing of
high-volume data is a perf and key-rotation hazard. **Instead:** the log store
honors the same master-key gate — if a master key is configured
(`secret.EnvMasterKey`), the whole `logs.db` is opened with **value-level
envelope encryption per record batch** via `secret.Cipher` (one seal per stored
chunk, §3.3), not per line. If no master key, logs are stored plaintext exactly
as the JSON store is plaintext without a key. `LogSource` carries no secrets, so
its records need no field encryption. *Document loudly:* logs may contain
secrets (tokens in URLs, stack traces); operators who care must configure the
master key — and we surface that in the source-create UI.

### 3.2 JSON state collection (small, safe to keep in `State`)

Only the **source definitions** live in the JSON state file — they are few,
small, and rarely written, exactly like `Monitors`:

```go
// internal/store State struct — one new map:
LogSources map[string]model.LogSource `json:"log_sources"`
```

Plus matching bbolt bucket `boltBucketLogSources = []byte("log_sources")` wired
into `boltStateBuckets`, `ImportState`/`ExportState`, with record APIs
`UpsertLogSource`, `LogSource(id)`, `LogSources()`, `LogSourcesForNode(nodeID)`,
`DeleteLogSource(id)` — copy the `Monitor` methods verbatim.

### 3.3 The log store (separate bbolt file — the heart of this design)

A new package `internal/logstore` owning its own `*bbolt.DB` at `logs.db`
(sibling of `state.json`/`state.db`). **Never** part of `State`; never
JSON-rewritten.

**Bucket layout — one sub-bucket per source, time-ordered keys:**

```
root
└── src:<sourceID>            (bbolt sub-bucket, created on first ingest)
    ├── key = big-endian uint64 Seq   → value = encoded chunk (see below)
    └── _meta key "head"              → {firstSeq, lastSeq, bytes, lines, rotID, lastOff, updatedAt}
```

- **Append is O(record):** ingest assigns the next `Seq` from `_meta`, puts the
  chunk under `be64(Seq)`. bbolt append at the tail of a uint64-keyed bucket is
  cheap and ordered. **No whole-store rewrite, ever.**
- **Chunking:** to keep key count and GCM-seal count sane, the server packs one
  *ingest batch* (after truncation/validation) into **one stored chunk** =
  length-prefixed concatenation of its `LogLine`s (or gob/JSON of `[]LogLine`),
  optionally `secret.Cipher`-sealed as a unit. One `Seq` per batch, not per line.
  Query decodes a chunk back into lines. This bounds keys to ~batches/node, not
  lines.
- **Time index:** `At` is inside each chunk; `_meta.firstSeq/lastSeq` + the fact
  that Seq is monotonic-in-ingest-time lets time-range queries seek by scanning
  from the tail backward (newest-first, the common debugging case) and stop once
  `chunk.maxAt < since`. Good enough for v1; a secondary `time:<source>` index
  bucket (`be64(unixNano) → Seq`) is a v2 option if range scans get hot.

**Retention & bounded size (fail-closed against disk blowup) — three caps, the
strictest wins:**
1. **Per-source byte cap** `maxSourceBytes` (default 64 MiB). On ingest, if
   `_meta.bytes` would exceed it, evict oldest chunks (`Delete(be64(firstSeq))`,
   advance `firstSeq`) until under cap. O(evicted), bounded.
2. **Per-source age cap** `maxSourceAge` (default 14 days). A background sweeper
   (one goroutine, ticks every few minutes) drops chunks whose `maxAt < now-age`.
3. **Global store byte cap** `maxStoreBytes` (default 4 GiB). If the DB file size
   (bbolt `Stats`/`Tx.Size`) exceeds it, the sweeper evicts oldest-across-sources
   round-robin and raises an audit + (v2) notify event. **This is the last line
   of defense; ingest never grows the store unbounded.**

All caps are constants with env overrides, mirroring `maxMonitorResults = 500`.
**bbolt note:** deleting keys frees pages back to the DB free list but does not
shrink the file; that's fine (space is reused). Provide an offline `compact`
(bbolt `Compact`) in the CLI for operators who want the file to shrink.

---

## 4. Server API

New handlers live in **`internal/server/server_logs.go`** (server.go is already
~3.5k lines — do not add there). Routes registered in `routes()` next to the
monitor block.

### Operator endpoints

| Method | Path | Scope | Body / Query | Response |
|---|---|---|---|---|
| `GET` | `/api/logs/sources` | `log:read` | — | `[]LogSource` (filtered to visible nodes) |
| `POST` | `/api/logs/sources` | `log:admin` | `{name,node_id,path,enabled?,max_line_bytes?,max_batch_lines?}` | `LogSource` |
| `POST` | `/api/logs/sources/delete` | `log:admin` | `{id}` | `{ok:true}` (also purges `src:<id>` bucket) |
| `GET` | `/api/logs/query` | `log:read` | `node_id`, `source_id`, `since`, `until` (RFC3339), `q` (substring), `limit` (≤1000, default 200), `order` (`desc` default) | `{lines:[]LogLine, truncated:bool, next_before_seq?}` |
| `GET` | `/api/logs/stats` | `log:read` | `source_id?` | per-source `{lines,bytes,first_at,last_at,last_ingest_at,rot_id}` |

- `POST /api/logs/sources` validates `path` (must be absolute, no `..`, not a
  glob; see §6) and `requireNodeScope(p,"log:admin",node_id)`. Records a
  `log.source.create` audit event. Enabling/disabling is a POST with the same
  shape (upsert) — `log.source.enable` / `.disable` audit.
- `GET /api/logs/query` enforces visibility per node (a principal with a node
  allowlist sees only those nodes' sources, like `monitorVisibleToPrincipal`).
  `q` is a plain `strings.Contains` (case-insensitive option) applied
  server-side after chunk decode — **no regex** in v1 (ReDoS-free by
  construction). Pagination is cursor-style via `next_before_seq` (the smallest
  `Seq` returned); the client passes it back as `until_seq` to page older.
- All responses use the standard `writeJSON` / `writeError` + `model.APIError`
  envelope.

### Agent endpoints (no operator scope — node-token auth, `withAgentLimit`)

| Method | Path | Auth | Body / Query | Response |
|---|---|---|---|---|
| `GET` | `/api/agent/log-sources?node_id=` | node token | — | `[]LogSource` enabled for this node |
| `POST` | `/api/agent/logs` | node token | `{ ...agentAuthRequest, batch: LogBatch }` | `{ok:true, accepted:N, next_off:uint64}` |

- `/api/agent/log-sources` mirrors `handleAgentMonitors`: authenticate node by
  `node_id` + bearer, return enabled sources for that node.
- `/api/agent/logs` mirrors `handleAgentMonitorResult`: `authenticateAgentRequest`,
  cross-check `batch.SourceID` belongs to `req.NodeID` (fail-closed if not),
  validate/truncate lines to `MaxLineBytes`, enforce the ingest rate budget
  (§7), pack into a chunk, `logstore.Append(...)`, return `next_off = batch.LastOff`
  so the agent can confirm its checkpoint. On back-pressure return `429` with
  `Retry-After` (the agent then holds its position and retries).

---

## 5. Agent responsibilities

A new file `lattice-node-agent/cmd/lattice-agent/logtail.go` (+ a small
`internal/logtail` package for the tailer core, unit-testable). It plugs into the
existing poll loop next to `monitors.reconcile(...)`:

```
for {
    reportMetrics; runTasks; reconcile monitors
    if assigned, err := fetchLogSources(cfg); err == nil { logTailer.reconcile(assigned) }
    <-ticker.C
}
```

**logTailer** is a `monitorManager`-shaped reconciler: one goroutine per assigned
`LogSource`, started/stopped/restarted as the assignment changes (key on
`source.ID`; restart if `Path` changes).

Each per-source goroutine:
1. **Open & seek.** Open `Path` read-only. Compute `RotID` from `inode + ctime`
   (via `os.Stat` / `syscall.Stat_t` — pure Go, no CGo). On first start, seek to
   **end** (`-n 0` semantics: we collect *new* lines, not history — matches the
   ssh-alerts `tail -n 0 -F` precedent). Persist a tiny local checkpoint file
   (`<state-dir>/logtail/<sourceID>.json` = `{rotID,off}`) so a restart resumes
   without re-shipping or losing position.
2. **Tail.** Read appended bytes; split on `\n`; truncate each line to
   `MaxLineBytes`. Accumulate up to `MaxBatchLines` or a short flush timer
   (e.g. 1s), whichever first → one `LogBatch`.
3. **Rotation handling.** If `os.Stat` shows the inode/ctime changed (logrotate
   moved/recreated the file) or size shrank below our offset, treat it as a new
   incarnation: finish the old file's tail, compute a new `RotID`, reset offset
   to 0, continue. The `RotID` change tells the server the offset namespace
   reset (so its dedupe is rotation-scoped).
4. **Ship.** POST `/api/agent/logs`. On `200`, advance + persist checkpoint to
   `batch.LastOff`. On `429`/5xx, **hold position**, apply backoff, and locally
   **bound the in-memory buffer** — if the buffer would exceed a cap, drop oldest
   and increment `batch.Dropped` (reported on next success, so loss is *visible*,
   not silent). Read-only on the file always; we never write to or rotate it.
5. **Permissions.** Reading `/var/log/*` typically needs root or the right group;
   document that the agent is usually run with sufficient read access (same
   reality as ssh-alerts). If open fails, log once and back off — fail-closed,
   never crash the poll loop.

**Apply-task contract:** none for v1 (read-only, assignment-driven). If/when a
node-side artifact is introduced (logrotate fragment), it follows the standard
`approval → queue_apply → Task{Interpreter:"sh", Script: applyScriptFor(...)}`
contract exactly as WireGuard/Tunnel do (§2, §8 v3).

**Status reporting:** the agent reports liveness implicitly (batches arriving)
and explicitly via `batch.Dropped` + `RotID`. The server's `_meta.lastOff /
lastIngestAt` is the authoritative "are we receiving from this source" signal,
surfaced in `/api/logs/stats`. A source with no batch in N intervals is shown as
"silent" in the UI (and is the v2 notify trigger).

---

## 6. Config rendering / external integration

**v1 generates no node-side artifacts.** The agent reads an existing file the
operator named; there is nothing to render, no nft, no CF DNS, no reload. This is
the correct minimal surface and is why v1 skips the apply-flow.

**Path validation (server-side, fail-closed)** is the only "rendering"-like
concern, and it is a *gate*, not a generator:
- Must be **absolute** (`filepath.IsAbs`), cleaned (`filepath.Clean`), **no `..`
  components**, **no globs/wildcards**, not a directory hint.
- Reject obviously dangerous targets by policy: a server-side **denylist prefix**
  (`/proc`, `/sys`, `/dev`) and an optional operator-configured **allowlist of
  prefixes** per node (default: allow `/var/log/`; everything else requires the
  operator to opt the prefix in). This caps blast radius of "tail any file" (§7).
- The agent **re-validates** the path it receives (defense in depth) and refuses
  anything failing the same rules even if the server sent it.

**v2/v3 integration (where the apply-flow *would* return):**
- A node-managed **logrotate fragment** or an **agent-owned config** describing
  sources could be rendered server-side and deployed via `plan→approve→apply`
  (write file, validate, no reload needed) — same pattern as
  `/etc/cloudflared/config.yml`. Only build this if operators want the agent to
  *manage* rotation rather than just observe it.

---

## 7. Security

**Authz / scopes.** `log:read` (query, list, stats) and `log:admin` (create /
enable / disable / delete sources). Both flow through `withAuth` +
`requireNodeScope` + per-node allowlist; query results are node-visibility
filtered. Agent endpoints are node-token-only via `withAgentLimit` +
`authenticateAgentRequest`, never operator-scoped.

**Fail-closed defaults.** Sources are created **disabled-capable** and validated
before any agent acts. Path validation denylist + `/var/log/` default-allowlist.
Unknown/invalid path → reject. Master-key-absent → logs stored plaintext but the
UI warns; this is a *visible* downgrade, not a silent one. Ingest over budget →
`429`, never an unbounded write. Decode/seal failure on a chunk → that chunk is
skipped and an audit event raised, query degrades visibly (`truncated:true`),
never panics.

**Secret handling.** Logs frequently contain secrets. v1 posture: (a) loud UI
warning at source creation; (b) whole-`logs.db` value-level envelope encryption
when a master key is configured (one seal per chunk via `secret.Cipher`); (c)
query API returns only to `log:read` principals filtered by node visibility; (d)
`LogSource` itself carries no secret fields. We do **not** attempt automatic
secret redaction in v1 (false-confidence); a redaction-pattern hook is a v2
opt-in.

**Blast radius — what a compromised node can do.** The agent already runs code
on the node; log ingestion adds the ability to **read files it's pointed at and
exfil them to the server** (which the operator already trusts) — *but only files
the server assigned*, gated by the path denylist/allowlist. A compromised node
**cannot**: choose its own paths (server assigns), read another node's logs
(node-token scoped), write/delete the source file (read-only), or escalate
scope. A compromised node *can* lie about content (inject fake lines) or flood
ingest — both bounded by the rate budget and made visible by `Dropped`/`_meta`.
The path allowlist is what stops a node-token thief from tailing `/etc/shadow`:
**ship with `/var/log/` allowlisted and `/proc`,`/sys`,`/dev` denied.**

**Back-pressure / rate limits (first-class).**
- **Agent-side:** bounded in-memory buffer; overflow drops oldest and counts
  `Dropped` (visible). Batch cap `MaxBatchLines`, flush timer ≤1s.
- **Wire:** `withAgentLimit` (existing) + ingest body cap (reuse the 1 MiB
  `decodeJSON` cap; a batch of 500×16KiB lines ≈ 8 MiB → so cap
  `MaxBatchLines×MaxLineBytes ≤ ingest body limit`, e.g. default 500×16KiB but
  raise the ingest decode cap for this route to 16 MiB, or lower line/batch caps;
  **pick caps so a max batch fits the decode limit** — call it out in tests).
- **Server-side per-source budget:** a token-bucket of bytes/sec and lines/sec
  per `SourceID` (e.g. 1 MiB/s, 5k lines/s defaults). Over budget → `429 +
  Retry-After`, audit `log.ingest.throttled`. Store-level: the three retention
  caps (§3.3) guarantee bounded disk regardless of agent behavior.

**Audit events** (hash-chained WAL): `log.source.create`, `log.source.enable`,
`log.source.disable`, `log.source.delete`, `log.ingest.throttled` (per-node,
sampled), `log.store.evict.global` (global cap hit), `log.chunk.decode_error`.
Source CRUD uses `recordPrincipalAudit`; ingest anomalies use the agent path.

---

## 8. Phasing

Each phase ships as a tested, reviewed, committed slice (the §5 cadence of
PRODUCT-VISION).

**MVP (smallest shippable slice) — "name a path, see its lines."**
- SDK: `LogSource`, `LogLine`, `LogBatch`.
- `internal/logstore` (separate bbolt `logs.db`): `Append(sourceID, []LogLine)`,
  `Query(filter)`, `Stats`, per-source **byte cap** eviction only (skip age +
  global sweeper for MVP), plaintext storage (master-key sealing in v2).
- State: `LogSources` map + bbolt `log_sources` bucket + record APIs.
- Server `server_logs.go`: sources CRUD (`log:admin`), query+stats (`log:read`),
  `/api/agent/log-sources`, `/api/agent/logs` with path validation
  (absolute/no-`..`/`/var/log/` allowlist + `/proc,/sys,/dev` deny) and a basic
  per-source line/sec budget → `429`.
- Agent: `internal/logtail` + `logtail.go`, reconciler, tail-from-end, rotation
  by inode/ctime, batch+ship, local checkpoint, `Dropped` accounting.
- Dashboard: a Logs panel — source list + add-source form (with the secret
  warning) + a query view (node/source/time/substring, newest-first, "load
  older").
- Tests: `-race`; store eviction; path-validation table; ingest auth/cross-node
  rejection; agent rotation + checkpoint resume; query filter + pagination.
- **Exit bar:** operator adds `/var/log/nginx/error.log` on `gmami-jp1`, the
  agent ships new lines, operator queries by node+substring+time window from the
  dashboard; a 100 MB/day source stays bounded by the byte cap; restart of agent
  resumes without dup/loss beyond one batch; zero growth of `state.json`.

**v2 — durability, secrecy, retention, operability.**
- Master-key value-level envelope encryption of `logs.db` chunks via
  `secret.Cipher`; UI shows encrypted-at-rest status.
- Age cap + global-cap background sweeper + audit/notify on global eviction.
- `internal/notify` reuse: "source silent" + "ingest dropping" alerts
  (transition logic mirroring `notifyMonitorTransition`).
- Optional gzip on the wire; journald source kind (`tail`→`journalctl -f`
  selector, reusing the ssh-alerts source pattern).
- Secondary `time:<source>` index bucket if range scans get hot; CLI `compact`.
- **Exit bar:** logs encrypted at rest when a key is set; a 30-day-old line is
  gone; a silent source pages the operator; store never exceeds the global cap.

**Later — parsing, search, scale.**
- Optional server-side parse-on-ingest into structured fields (severity, ts,
  k=v) behind an opt-in; substring → indexed search only if volume demands it.
- The apply-flow returns *only* if operators want agent-managed logrotate/config
  artifacts (render → approve → write/validate).
- Per-source sampling/budgets surfaced as operator knobs; multi-node merged
  query views.

---

## 9. Risks & open questions

- **Volume realism.** A chatty source (debug logging, a crash loop) can produce
  millions of lines. The byte/age/global caps make *disk* safe, but query over a
  64 MiB source is a tail-scan; if that's slow, the v2 `time:` index is needed
  sooner. **Mitigation:** newest-first default + cursor pagination keeps the
  common case (look at recent errors) fast; cap `limit ≤ 1000`.
- **Secrets in logs.** Real risk; we mitigate with encryption-at-rest + scoped
  read + warning, but cannot prevent an operator from tailing a file full of
  tokens. Redaction is explicitly deferred — **document the residual risk.**
- **Rotation edge cases.** `copytruncate` logrotate keeps the inode but zeroes
  the file → detect via size-shrink-below-offset, not just inode change. Covered,
  but needs a dedicated test. Compressed rotated files (`.gz`) are *not*
  followed (we only tail the live file) — acceptable, document it.
- **Clock skew.** `At` is agent capture time; a skewed node mis-times lines.
  Server could stamp `IngestedAt` too; v1 trusts `At` for ordering within a
  source (Seq is the real order). Open: expose both in query?
- **bbolt single-writer.** bbolt allows one write tx at a time; with many sources
  ingesting concurrently, appends serialize. At fleet scale this is fine
  (batched, infrequent), but it's the scaling ceiling — **measure before
  assuming.** Open: one DB vs per-node DB files? (Per-node files trade more FDs
  for write parallelism — defer until measured.)
- **Decode-cap vs batch-cap arithmetic** must be enforced by a test so a legal
  max batch always fits the ingest body limit (§7). Easy to get wrong.
- **Open:** do we ever need to ship *historical* lines (seek to start) for a
  newly added source, or is tail-from-end always right? v1 says tail-from-end;
  revisit if operators ask "where were the logs before I added the source?"

---

## 10. Borrow vs avoid (from the reference panels / prior art)

- **Borrow from Lattice Monitors (the closest in-repo precedent):** the
  assignment-driven, agent-polled, per-item-goroutine reconciler
  (`monitorManager.reconcile/run`), the capped-history store
  (`maxMonitorResults`), and the transition-only notify gate
  (`notifyMonitorTransition`). Log ingestion is "monitors, but the agent ships
  deltas instead of a single probe result." **This is the spine of the design.**
- **Borrow from ssh-alerts:** the `tail -n 0 -F` / `journalctl -f` follow model
  and the "restart the source if it ends" loop (`watchSSHLogins`). We do this
  natively in Go (own the offset/rotation/checkpoint) rather than shelling out,
  because we need byte-offset checkpoints and rotation semantics `tail` won't
  give us — but the *posture* (read-only, fail-closed, never crash the loop) is
  taken straight from it.
- **Borrow from Filebeat/Vector/Promtail (industry tailers):** the
  **checkpoint/registry of file position keyed by (inode, offset)**, rotation
  detection by inode change *and* truncation, batch-with-flush-timer, and
  at-least-once-with-backoff. These are the battle-tested ideas; we take the
  *semantics*, not the dependencies (all are heavyweight, not pure-Go-tiny).
- **Borrow from Loki's stance:** **don't full-text-index logs you can
  time+label-filter.** Loki's insight — index labels (here: node + source +
  time), grep the rest — justifies v1's "substring scan over a bounded window,
  no inverted index." Resist the urge to build search.
- **Avoid:** a SIEM. No parsing pipeline, no per-line GCM, no inverted index, no
  cross-node aggregation, no streaming push to the agent (it polls — never invert
  the connection direction). Avoid putting any of this in the JSON `State`.
  Avoid regex query in v1 (ReDoS). Avoid silent drops — every drop is counted and
  surfaced. Avoid new heavy dependencies: bbolt is already approved (Phase C);
  this adds **zero new deps** (no Filebeat, no fsnotify needed — periodic
  `os.Stat` + read suffices for a polling agent; if real-time is wanted later,
  `fsnotify` would need an ADR).

---

## 11. Dev guide — ordered, file-by-file build checklist

Follow `development-workflow.md`: **plan → design (this doc) → build (TDD) →
verify (`-race`, gofmt, dashboard) → review (separate adversarial pass) →
commit**. Build/test with `GOWORK` set (multi-repo `go.work`). One coherent
commit per numbered step where practical.

**Step 0 — Plan artifact.** Create `iterations/iter-NNN-log-ingestion.md` (goal,
scope, exit bar from §8 MVP). Add an ADR only if a new dep is proposed — v1 adds
**none** (bbolt already blessed).

**Step 1 — SDK model (`lattice-sdk/model/model.go`).**
1. Add `LogSource`, `LogLine`, `LogBatch` (§3.1) with json tags. No behavior.
2. `go build ./...` in the SDK module.

**Step 2 — Log store package (`lattice-server/internal/logstore/`).** *TDD first.*
1. `logstore.go`: `Open(path string, cipher secret.Cipher) (*Store, error)` over
   its own `*bbolt.DB`; `Append(sourceID string, lines []model.LogLine) (uint64, error)`
   (returns new head Seq), `Query(Filter) (Result, error)`, `Stats(sourceID) (Meta, bool)`,
   `PurgeSource(sourceID) error`, `Close()`. Implement byte-cap eviction in
   `Append` (MVP). Chunk = encode `[]LogLine`; seal as a unit if `cipher.Enabled()`.
2. `logstore_test.go`: append+query roundtrip; byte-cap evicts oldest; query
   filters by time/substring/limit; pagination cursor; cipher on/off roundtrip.
   `go test -race ./internal/logstore/`.

**Step 3 — State + bbolt source records.**
1. `internal/store/store.go`: add `LogSources map[string]model.LogSource` to
   `State`; init in the constructor; add `UpsertLogSource/LogSource/LogSources/
   LogSourcesForNode/DeleteLogSource` (copy the `Monitor` methods).
2. `internal/store/bolt_state.go`: add `boltBucketLogSources`, register in
   `boltStateBuckets`, wire `ImportState`/`ExportState`, mirror the record APIs.
3. Tests: extend the existing store + bolt migration tests with a LogSource
   roundtrip. `go test -race ./internal/store/`.

**Step 4 — Server handlers (`internal/server/server_logs.go`).** *New file.*
1. Path validation helper (absolute/clean/no-`..`/denylist/allowlist) + its
   table test (`server_logs_test.go`).
2. Operator handlers: `handleLogSources` (GET/POST), `handleDeleteLogSource`,
   `handleLogQuery`, `handleLogStats` — with `requireNodeScope` + visibility
   filtering + `recordPrincipalAudit`.
3. Agent handlers: `handleAgentLogSources`, `handleAgentLogs` (auth, cross-node
   check, truncate, per-source budget → `429`, `logstore.Append`).
4. Register routes in `routes()` (server.go) next to the monitor block; add
   `log:read`/`log:admin` to any scope listing/UI used by the token UI.
5. Construct the `logstore.Store` in server setup (open `logs.db` beside the
   state file; pass the same `secret.Cipher`); start the v2 sweeper later.
6. Tests: auth/scope matrix; cross-node ingest rejection; query visibility
   filter; ingest budget `429`; body-cap vs batch-cap arithmetic.
   `go test -race ./internal/server/`.

**Step 5 — Agent tailer (`lattice-node-agent`).** *TDD the core.*
1. `internal/logtail/logtail.go`: a `Tailer` that, given an `io.ReaderAt`/file +
   a checkpoint, yields batches; rotation/truncation detection; line truncation.
   Unit-test against temp files (append, rotate via rename+recreate, copytruncate
   via truncate-in-place, resume from checkpoint).
2. `cmd/lattice-agent/logtail.go`: `logTailer` reconciler (clone of
   `monitorManager`), `fetchLogSources`, per-source goroutine, local checkpoint
   file under the agent state dir, `Dropped` buffer accounting, POST to
   `/api/agent/logs` with backoff on `429`/5xx.
3. Wire `logTailer.reconcile(...)` into `main`'s poll loop next to monitors.
4. Tests: `go test -race ./internal/logtail/`; manual end-to-end against a local
   server.

**Step 6 — Dashboard (`lattice-dashboard`, zero-dep vanilla JS, strict CSP).**
1. A Logs nav panel: source list (name/node/path/enabled/last-ingest from
   `/api/logs/stats`), add-source form **with the secrets-in-logs warning**, and
   a query view (node + source selectors, time range, substring box, newest-first
   list, "load older" using the `next_before_seq` cursor).
2. No inline scripts (CSP `script-src 'self'`); fetch via the existing API client
   pattern. Verify end-to-end in a browser (per harness UI rule — not by
   inspection).

**Step 7 — Verify.** `gofmt`/`goimports` clean; `go vet`; `go test -race ./...`
across affected modules with `GOWORK` set; dashboard loads + the flow works
end-to-end; confirm `state.json`/`state.db` did **not** grow with log volume and
`logs.db` honored the byte cap.

**Step 8 — Review (separate adversarial pass).** Run a `security-review` /
`code-reviewer` lane focused on: path-validation bypass (`..`, symlinks,
allowlist holes), cross-node ingest, decode-cap vs batch arithmetic, eviction
correctness under concurrency, secret-at-rest gating, and no-silent-drops. Fix
must-fixes with regression tests.

**Step 9 — Commit & iterate.** Conventional commits (`feat: log ingestion …`),
small coherent commits per step, update the iteration doc with outcome +
residuals, update PRODUCT-VISION/ADRs if a decision changed. Do not push unless
the operator asks.
