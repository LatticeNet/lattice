# Iteration 056 - Log ingestion MVP (Design 03)

- **Date:** 2026-06-15
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice-node-agent`, `lattice-dashboard`, `lattice`
- **Design:** [design-03-log-ingestion](../designs/design-03-log-ingestion.md) (§8 MVP)
- **Status:** Implemented, reviewed, verified

## Goal

Deliver the smallest shippable slice of Design 03: an operator names a file path
on a node, the assigned agent tails it and ships new lines, the server persists
them into a dedicated bounded store, and the operator queries them by
node/source/time/substring from the dashboard — Lattice's first **fleet log
collection** capability. This was the only entirely-unbuilt design; everything
else (proxy, DNS, inventory, ACL/map) was already at MVP-or-beyond.

## What landed (the six build steps)

1. **SDK contracts** (`lattice-sdk`): `LogSource`, `LogLine`, `LogBatch`.
2. **Bounded log store** (`lattice-server/internal/logstore`): a **separate bbolt
   database (`logs.db`)** — never the JSON state store, so log volume never
   triggers a full-state rewrite. Per-source monotonic sequence, one chunk per
   ingest batch (optionally sealed as a unit via `secret.Cipher` when a master
   key is set), newest-first cursor query (time/substring filters), per-source
   **byte-cap eviction** of oldest chunks, `Stats`, `PurgeSource`. `-race` tested.
   Zero new dependencies — bbolt was already approved for Phase C.
3. **State records** (`internal/store`): `LogSources` map + Upsert/Get/List/
   ForNode/Delete (mirrors `Monitor`); `log_sources` bbolt bucket wired into
   import/export so migration preserves source definitions.
4. **Server API** (`internal/server/server_logs.go`): operator endpoints
   (`log:read`/`log:admin`) for source CRUD, query, and stats; agent endpoints
   for assignment (`/api/agent/log-sources`) and batch ingest (`/api/agent/logs`).
   `LogStore` injected via `Options` (nil ⇒ 503); `main` opens `logs.db` beside
   the state file with the same cipher.
5. **Agent tailer** (`lattice-node-agent`): `internal/logtail` follower core +
   `cmd/lattice-agent/logtail.go` reconciler (clone of `monitorManager`), wired
   into the poll loop. New flag `-log-state-dir`.
6. **Dashboard** (`lattice-dashboard`): a self-revealing Logs panel — source
   list + add-source form (with the secrets warning) + query view with
   `next_before_seq` "load older" pagination.

## Security posture

- **Server = sole policy point.** It owns `LogSource` records, RBAC
  (`log:read`/`log:admin`, node-visibility filtered like monitors), the store,
  and the query API. The agent holds no policy — it only dials out.
- **Fail-closed path validation** at source create *and* implicitly bounded by
  ingest: absolute, `filepath.Clean`, no `..` segment, no globs/control chars,
  deny `/proc`,`/sys`,`/dev`, allow `/var/log/` by default (widen with
  `LATTICE_LOG_PATH_ALLOW`). This caps the blast radius of "tail any file" so a
  node-token thief cannot tail `/etc/shadow`.
- **Cross-node ingest is rejected** — a batch's source must exist and belong to
  the authenticated node (fail-closed), so a compromised node cannot read or
  spoof another node's logs.
- **Back-pressure is first-class.** Per-source lines/sec budget → `429 +
  Retry-After` (`log.ingest.throttled` audit); the agent holds position. The
  ingest decode cap (16 MiB) bounds a legal max batch; create rejects
  `max_line_bytes*max_batch_lines` over 8 MiB. Disk is independently bounded by
  the per-source byte cap. Agent buffer overflow drops oldest and counts
  `Dropped` — loss is **visible, never silent**.
- **Secrets-at-rest.** Logs may contain secrets; when a master key is set the
  whole `logs.db` chunk is envelope-sealed, and the UI warns loudly when it
  isn't. `LogSource` itself carries no secrets. Read is `log:read`-gated.
- **Read-only on the node.** The tailer never writes to or rotates the file.
- **No plan→approve→apply for reads.** Per design §2, tailing a named file is a
  read dispatched by assignment (like Monitors), not a node mutation; the
  apply-flow stays reserved for node-side artifact writes (none here).

## Verification

```sh
GOWORK=…/lattice/go.work go vet ./...               # server + agent
GOWORK=…/lattice/go.work go test -race ./...         # logstore, store, server, logtail, agent — all green
npm test && npm run check                            # dashboard 83/83, node --check clean
gofmt -l <changed files>                             # empty
```

Coverage highlights: logstore append/query/pagination/byte-cap-eviction/cipher
roundtrip/purge; path-validation table; CRUD+ingest+query+stats end-to-end;
cross-node + unknown-source ingest rejection; 429 over-burst; disabled-store
503; decode-cap arithmetic; tailer append/rotation(rename)/copytruncate/resume/
truncation/force-emit; dashboard payload + query-string + RFC3339 helpers.

## Residuals & Next (Design 03 v2+)

1. **Encryption-at-rest default + sweeper:** age cap + global-cap background
   sweeper with eviction audit/notify; surface encrypted-at-rest status in the UI.
2. **"Source silent" / "ingest dropping" notify** via `internal/notify`
   (transition logic mirroring `notifyMonitorTransition`).
3. **Operability:** gzip on the wire; journald source kind; a secondary
   `time:<source>` index if range scans get hot; CLI `compact`.
4. **Node-level merged query** (concat+time-merge across a node's sources),
   dashboard source-edit-in-place, and optional parse-on-ingest (severity/fields).
5. **Real Linux-node E2E** against a rotating `/var/log/nginx/error.log`.
