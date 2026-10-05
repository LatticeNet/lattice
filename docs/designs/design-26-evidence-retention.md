# Design 26: evidence retention, selective collection and an encrypted archive

Status: accepted, not built. Written 2026-10-04 as a read-only design; the operator accepted all ten decisions in section 14 as recommended on 2026-10-05. It is also the log-storage decision that `PROGRAM.md` KI-10 waits on ("Trace policies all off pending the log-storage decision").
Date: 2026-10-04.
Reference: lattice-server `integration` at 1843d69, lattice-node-agent `integration` at 89b7cbc, lattice-dashboard `integration` at 137bd73, lattice-sdk at the server's pin (29dacb5). The connection-trace design these stores came from is archived at the workspace root as `_archive/2026-08/SINGBOX-TRACE-DESIGN.md`; code comments still cite it. The control plane's own history is a separate store, `metrics.db`, proposed in the open lattice-server#159; this design shares its tier vocabulary and the host's disk budget with it, and nothing else.

## Summary

The operator asked, on `/platform/evidence?range=all&node_id=legend-sg&source=singbox-3a0732451aa2205b&view=overview`, whether Evidence supports long-term monitoring or selective node monitoring, and how a whole cluster's data can be stored when it "needs a big database".

Today Evidence is a short-horizon tool. Connection records live 14 days and capture lines 7 days, all inside a fixed 2 GiB cap on `trace.db`; raw sing-box lines have a per-source byte cap and no time limit; the only longer-lived structure, a 90-day table of five-minute rollups, is written and never read by any endpoint. Selection exists per node (a policy with a level and a line budget) and per capture (nodes, users, lines, destinations, at most two hours), but switching a node on silently does nothing unless that node's Clash API address was set through the raw API, and the console can neither set it nor show that it is missing. All 34 nodes are off, so there is nothing to keep.

The data is not big. Measured on the real store code, a connection record costs about 0.8 KB on the control plane and about 0.1 KB compressed. At a central estimate of 2 connections per second across the fleet, full detail is 135 MB a day locally and 19 MB a day compressed. The binding constraint is hkg's disk, not money and not database capability. So the design keeps a small, budgeted hot tier on hkg, aggregates early into long-lived rollups that carry counts and no destinations, samples clean connections in the hot tier (never failures), and, as an option, writes every record hourly to Cloudflare R2, encrypted on hkg before it leaves. A query that reaches past the local horizon says so and offers to fetch the archived hours. No managed database is needed; R2 holds ciphertext only, for cents a month.

## 1. The two questions, answered from the code

### 1.1 What is collected, and how it is switched on

The node agent reads sing-box's loopback Clash API, never a log file. `lattice-node-agent/cmd/lattice-agent/tracesource.go` subscribes to `/logs` at a level, polls `/connections` every 5 s (`traceConnectionsPoll`), assembles one record per connection in `internal/sessionasm`, and ships records and lines through `internal/traceship`. The subscription level is the maximum of the node policy and every running capture (`internal/tracepolicy/tracepolicy.go`, `Build`), which is why a capture never restarts sing-box.

There are two switches.

The node policy is `model.TracePolicy{Enabled, Level, BudgetLinesPerSec, ClashAPIAddr, SecretPath}` (lattice-sdk `model/trace.go:66`), stored on the node and set by `POST /api/trace/policy` (`internal/server/server_trace.go:530`) with scope `log:admin` on that node and an audit event `trace.policy.set`. The default level is `debug`, and that is a correctness requirement: sing-box logs every close line at debug or trace, none at info (`server_trace.go:56-67`). Enabling a node turns on two streams at once and they cannot be separated: every connection record, and every raw line the floor keeps, which goes to a server-minted virtual log source `singbox://<node>` (`ensureSingBoxLogSource`, `server_trace.go:959`). The `source=singbox-3a0732451aa2205b` in the operator's link is exactly that source for `legend-sg`: the id is the first 8 bytes of `sha256("singbox|legend-sg")`.

A capture is a `TraceSession` with a filter (node ids, user ids, line uuids, destination patterns), a level and a TTL of at most 2 hours (`traceSessionMaxTTL`, `server_trace.go:32`), enforced on the server and again on the agent (`expireSessionsLocally`). At most 16 run at once and 8 per node. A capture turns the collector on for its nodes even where the policy is off (`tracepolicy.Set.Enabled`).

Raw file sources are the third kind of selection. `POST /api/logs/sources` adds a file under an allowed prefix (default `/var/log/`) on one node, with its own enabled flag; the agent tails it (`logtail.go`).

Three facts matter for the operator's question.

- The collector needs `ClashAPIAddr`. `applyConfig` stops the pipeline when it is empty (`tracesource.go:258`). Only the raw API sets it (`server_trace.go:600`); the console's policy form sends `enabled`, `level` and `budget_lines_per_sec` and never this field (`EvidenceCollection.vue:130`), and nothing reports the collector's state back. A node switched on without it shows "on" and records nothing, and a capture started on it from the Overview records nothing either. Every node in production is adopted (vpn-core is discover-only), so the Clash API is also a node-side change: `sb api on` in the sing-box script (`sing-box/src/core.sh:3116`), which restarts sing-box once.
- The line budget (default 500 lines per second) drops lines before they are parsed (`tracesource.go:428`). A dropped line can be a connection's opening or closing line, so overload produces partial and `unknown` records rather than fewer complete ones. It is truncation, not sampling.
- There is no sampling anywhere. A node is either all of its connections or none.

### 1.2 Where it is stored, and for how long

Connection records, capture lines and rollups live in `trace.db`, SQLite through the pure-Go `modernc.org/sqlite`, beside the state file (`internal/tracestore`). Raw lines live in `logs.db`, bbolt, one bucket per source (`internal/logstore`). Both are opened in `cmd/lattice-server/main.go:184-215` with the master-key cipher. In `trace.db` only `close_error`, `message` and `raw` are sealed; `dst_host`, user names and every other indexed column are plaintext. `logs.db` seals each chunk whole.

| Store | What | Retention today | Configurable |
|---|---|---|---|
| `trace.db` `conn_records` | one row per connection | 14 days, and the 2 GiB cap, oldest first | no; `main.go` passes `tracestore.Options{}` |
| `trace.db` `trace_lines` | lines a capture tagged | 7 days | no |
| `trace.db` `rollups_5m` | counts, bytes, close reasons per user x line x node x 5 min | 90 days; never evicted by the cap | no |
| `logs.db` per source | raw lines, including `singbox://` | 64 MiB per source, no time limit | `LATTICE_LOG_MAX_SOURCE_BYTES` |

Retention runs hourly (`startTraceRetention`, `server_trace.go:907`): it applies the three TTLs, then, when over the cap, evicts records and then capture lines, oldest first. It never evicts rollups (`retain.go:101-137`), so at high cardinality the rollups slowly squeeze the record horizon. bbolt reuses freed pages but never shrinks its file, so `logs.db` stays at its high-water mark.

### 1.3 How it is read

`GET /api/trace/connections` pages records newest first across nodes with filters for node, user, line, session, destination substring, close reason, user kind and stalled (`server_trace.go:151`). `GET /api/trace/lines` tails a capture. `GET /api/logs/query` reads one raw source at a time by substring and sequence cursor. Markers, hops and stats round it out. The console's Explore layer offers ranges up to 7 days plus `all` and custom (`connTraceModel.ts:32`); `all` means everything still in `trace.db`.

No endpoint reads `rollups_5m`. `tracestore.Store.Rollups` exists (`query.go:307`) and nothing in `internal/server` calls it. The Overview's last-hour summary is computed from records.

### 1.4 The answer

Long-term monitoring: no. The longest detail is 14 days under a 2 GiB cap that a busy fleet fills in days (section 2), the only long series is unreadable, nothing is archived, no retention is configurable for `trace.db`, and with all 34 policies off (KI-10; the 2026-09-29 audit counted 0 records) nothing is collected to keep.

Selective node monitoring: partly. Per-node policies and per-capture filters exist and work once a node is ready. What is missing is the readiness itself (Clash API address and state), a way to choose streams separately (records without raw lines), sampling instead of truncation, a per-node horizon the operator can see, and any longer horizon than two hours for a capture or 14 days for records.

## 2. How big the data is

### 2.1 Measured costs per item

Measured on 2026-10-04 with throwaway tests driving the real `tracestore` and `logstore` write paths at 1843d69 (not committed; synthetic records shaped like production: `u_` user names, 36-character line uuids, rule text, a close error on 60 percent of records).

| Item | Cost |
|---|---|
| connection record in `trace.db`, six indexes plus the session index | 740 B plaintext, 782 B with the cipher on (200,000 records) |
| `rollups_5m` row | about 375 B (from two runs that differed only in rollup count) |
| raw sing-box line in `logs.db` | 255 B stored, 342 B sealed, about 400 B of file |
| lines per connection | 8.4 in the real v1.13.14 fixtures (101 lines, 12 connections, `internal/singboxlog/testdata/v1.13.14`) |
| record, archive form: NDJSON, gzip -9 | 63 B (100,000 records in one file) |
| record, archive form: SQLite without indexes, gzip -9 | 86 B |

Synthetic data repeats destinations and compresses better than real traffic, and small hourly files compress worse than one large file. This design plans with 0.8 KB per hot record and 110 B per archived record.

### 2.2 Volume

Nobody has measured connection rates on this fleet; the trace design's V3 measurement was never run. The only volume figure is egress, 313 GB over 7 days (2026-09-29 audit), with about 136 lines on 25 sing-box nodes. Three scenarios, counted fleet-wide and including relay hops (a two-hop chain records twice):

| Scenario | Connections per second | Records per day |
|---|---|---|
| L | 0.5 | 43,200 |
| C (central) | 2 | 172,800 |
| H | 10 | 864,000 |

| Cost if every node were on, today's shape | L | C | H |
|---|---|---|---|
| hot records per day | 34 MB | 135 MB | 676 MB |
| 14 days of records (today's TTL) | 473 MB | 1.89 GB | 9.46 GB |
| days of records the 2 GiB cap holds | 63 | 15.9 | 3.2 |
| raw sing-box lines per day (8.4 lines, 400 B) | 145 MB | 581 MB | 2.90 GB |
| 90 days of `rollups_5m` (20, 60, 200 active user x line x node per bucket) | 194 MB | 583 MB | 1.94 GB |

Two conclusions follow. Raw lines always on cost about four times the records they assemble into, and are the first thing to stop doing by default. And today's 90-day five-minute rollup is the wrong shape for long-term trends: at H it alone exceeds the cap, at C it takes over a quarter of it, and nobody can read it.

### 2.3 The host

hkg has 2 vCPU and 3.9 GB of RAM; the server process uses about 930 MB. The data directory is 2.5 GB today: `state-hot.db` 1.5 GB, the audit WAL 810 MB, `state.json` 16 MB, and `logs.db` and `trace.db` near empty. The lane brief records 9.7 GB free of 99 GB, which lattice-server#159 repeats; `PROGRAM.md` records 63 GB free after the a116 backup prune at 16:27Z. I could not check which is current and did not touch hkg. This design sizes against the tighter figure. Today's latent ceiling, if all 34 nodes were switched on, is `trace.db` 2 GiB plus 34 x 64 MiB of raw sources plus bbolt overhead, about 4.5 GB, with no way to read anything older than the cap allows.

### 2.4 Does this need a bigger database?

No. The fleet's evidence at C is 135 MB a day of full detail, a volume one embedded SQLite file handles comfortably for a week, and 19 MB a day compressed. A bigger engine solves a problem this fleet does not have, and each candidate adds one it does not have now.

- Cloudflare D1 would hold evidence in plaintext in a third party, against the doctrine's line that Cloudflare's "hold-everything trust model" is not the goal (`PRODUCT-VISION.md`, what Lattice is not). On the Workers Free plan it caps writes at 100,000 rows a day, below scenario C before counting index rows (each index write counts as a row written); on the paid plan storage past 5 GB is $0.75 per GB-month, fifty times R2. Every query from hkg would be a REST call across the internet. Pricing checked against developers.cloudflare.com on 2026-10-04.
- AWS RDS: the smallest instance in Hong Kong, `db.t4g.micro` in ap-east-1, is $0.028 an hour on demand, about $20 a month before storage, plus a second trust holder and a network hop per query (pricing tool, 2026-10-04).
- A sidecar engine (ClickHouse, Loki, VictoriaLogs) is a second long-running process with its own port, upgrades and backups on a 2 vCPU host, which lattice-server#159 already rejected for the control plane's metrics on the same grounds.

What Cloudflare is good for here is cheap, durable, egress-free object storage for ciphertext: R2 at $0.015 per GB-month, 10 GB free, Class A operations $4.50 per million with 1 million free, Class B $0.36 per million with 10 million free, no egress fee (developers.cloudflare.com/r2/pricing, last updated 2026-10-01). The offsite backups already use R2 (`RELEASE-RUNBOOK.md` 5.3), so the 10 GB free tier may already be spent; the costs below assume it is.

## 3. The decision in one paragraph

Collection is opted into per node and per stream, and a node that cannot collect says why. The hot tier on hkg is a byte budget with a target horizon (7 days), filled with every failure and a sampled share of clean connections, the share chosen by the server so the horizon holds. Every record, sampled or not, feeds exact rollups first; the rollups carry counts, bytes and close reasons, no destinations, and keep trends for 90 days hourly and 400 days daily. If the operator turns the archive on, every record of an opted-in node is also written to an hourly part, encrypted on hkg to two recipients, and uploaded to a dedicated R2 bucket within the hour. A query that reaches past local detail returns what is local, says how much more is archived, and fetches it only when asked.

## 4. Selection: per node, per stream

### 4.1 Streams

A node has four evidence streams, switched separately.

1. Connection records. Off by default. On means the collector runs at `debug` and ships every assembled record.
2. Raw sing-box lines (`singbox://<node>`). Off by default, including when records are on. On takes a level and a TTL. Captures keep tagging their own lines exactly as today, whatever this switch says.
3. File sources. Unchanged objects (`LogSource`), now bound by the same shared raw budget and a TTL.
4. Capture lines. Unchanged, time-boxed, up to 2 hours.

The model change is additive: `TracePolicy` gains `Raw *RawLinePolicy{Enabled bool, Level TraceLevel, TTL duration}` and `SampleRate *float64` (a pin, section 5). `Enabled` keeps meaning "records on". The agent ships raw lines only when `Raw.Enabled`. Since every production policy is off, no stored policy changes meaning; a policy that was on before the migration gets `Raw.Enabled = true` so it keeps today's behaviour.

### 4.2 Readiness, said out loud

The agent discovers the Clash API itself. When `ClashAPIAddr` is empty it reads `experimental.clash_api.external_controller` from `/etc/sing-box/config.json`, which `resolveClashSecret` already parses for the secret, and accepts it only if it is a loopback address (the same rule as `validateLoopbackHostPort`). An explicit policy address still wins.

Each batch carries a `CollectorStatus{State, Level, Since, LinesPerSec, ShedConnections, Unparsed}`, where `State` is one of `off`, `ready`, `no_clash_api`, `secret_unreadable`, `stream_failing` or `agent_too_old` (the last inferred by the server from the agent version). The agent also posts its status on every state change, even with nothing to ship. The server keeps the latest per node and the console prints it beside the switch. A node whose records are on and whose state is not `ready` is an attention row, not a quiet "on".

Setting up the Clash API on an adopted node stays a plan: a task running `sb api on` and verifying the listener, approved like any node change, restarting sing-box once. The console offers it from the readiness cell.

### 4.3 Shed connections, not lines

The agent's budget becomes a CPU guard measured in parsed lines (default raised to 5,000 per second) and it sheds whole connections: once the current second is over budget, a log id seen for the first time is marked shed for its lifetime and its lines are skipped, while connections already being assembled keep every line. The loss is reported as `ShedConnections`, a count of connections not observed, and it never produces a partial record. Storage is not this budget's job any more; section 5 owns it.

## 5. Sampling in the hot tier

Sampling moves to the server, at insert time, and touches only `conn_records`.

The agent ships every record. At C that is about 150 MB a day of JSON across the whole fleet, about 1.7 KB/s into hkg, well inside the existing per-node ingest limiter (5,000 items per second). The server then:

1. folds the record into the rollups, so every tier is exact (section 6);
2. appends it to the archive part when the archive is on (section 7);
3. inserts it into `conn_records` only if it is kept.

A record is kept when any of these holds: its close reason is not a clean one (clean means `eof`, `canceled`, `udp_idle`), it was stalled, it carries a capture's session id, or `h(node_id, core_generation, log_id, started_at) < p`, a keyed hash over the primary key mapped to [0, 1). The hash is deterministic, so a connection's open snapshots and its final record get the same answer; a final record that turns out to be a failure is inserted even if its open snapshots were not.

`p` is chosen by a governor, hourly. It projects each opted-in node's daily volume from the last 24 hours, subtracts the rollup footprint and 10 percent headroom from the `trace.db` budget, and picks the largest `p` at which 7 days of kept records fit. Because cost is linear in volume, one rate for every unpinned node gives every node the same horizon; a pinned node (`SampleRate` set) keeps its rate and the others share what is left. The floor is 1 percent. When failures alone exceed the budget, `p` sits at the floor, the horizon shrinks, and the proof line says "detail back to 3 days (budget)". Each change is an audit event `trace.sampling.adjusted` with the old and new rate.

What this gives at the default 1 GiB budget, assuming 10 percent of connections are not clean:

| | L | C | H |
|---|---|---|---|
| rollup footprint (section 6) | 48 MB | 141 MB | 440 MB |
| 7 days of records at 100 percent | 236 MB | 946 MB | 4.73 GB |
| clean-connection rate that holds 7 days | 100 percent | 86 percent | 1.2 percent (24 percent at a 2 GiB budget) |

Eviction stays as it is for the case the governor cannot prevent (a burst inside one hour): oldest records first, and the horizon in the proof line moves.

## 6. Retention tiers

Rollups are computed from every record before sampling and never evicted by the byte cap. They carry connection counts, bytes with the existing `bytes_known_count`, and close reasons. They never carry destinations; a destination older than local detail is only in the archive. The tier names match lattice-server#159 so the console speaks one vocabulary for both histories.

| Tier | Key | Kept | L | C | H |
|---|---|---|---|---|---|
| detail, `conn_records` | one connection | 7 days target, budget-bound | 236 MB | 826 MB | 527 MB, sampled |
| 5 min, `rollups_5m` (exists) | user x line x node | 14 days (was 90) | 30 MB | 91 MB | 302 MB |
| 1 h, `rollups_1h` (new) | line x node | 90 days | 13 MB | 32 MB | 78 MB |
| 1 d, `rollups_1d` (new) | user x line x node | 400 days | 4.5 MB | 18 MB | 60 MB |

Assumptions: 20, 60 and 200 active user x line x node triples per 5-minute bucket; 20, 50 and 120 active line x node pairs per hour; 30, 120 and 400 triples per day; 375 B per user-keyed row and 300 B per line-keyed row. The hourly tier drops the user because hourly per-user rows past two weeks answer no question the daily tier cannot, and per-user and per-node bytes already live for 400 days in the usage subsystem's day rollups (`usage_day_user` and `usage_day_node`, `internal/store/usage_days.go`, `UsageDayRetentionDays`). Coarser tiers are rolled up from finer ones in the transaction that closes a bucket, as in `metricsdb`.

### 6.1 The local budget

| Budget | Default | Today |
|---|---|---|
| `trace.db` (detail plus rollups) | 1 GiB | 2 GiB, records only |
| raw lines in `logs.db`, shared by every raw and file source | 512 MiB, raw sing-box TTL 3 days, file sources 7 days | 64 MiB per source, no TTL, 34 sing-box sources possible |
| archive staging (section 7) | 256 MiB | none |
| restore cache (section 8) | 256 MiB, entries expire 24 hours after last use | none |
| worst case on disk | 2 GiB of budgets, about 2.1 GiB of file with bbolt overhead on the raw pool | about 4.5 GB |

A shared raw budget of 512 MiB holds about 23 node-days of raw sing-box lines at C, so raw lines on three average nodes keep about a week each. The `logs.db` file stays at its high-water mark, about 17 percent above stored bytes (measured 400 against 342 B a line), and the console says so. All four budgets become settings with these defaults, readable by `log:read` and changeable by a full administrator.

### 6.2 What stays local, always

Rollups of every tier, the archive manifest (section 7.5), keys, policies, the governor's state, and capture lines until their TTL. Raw sing-box lines are never archived in this design: they are bulk, they are the assembly input rather than the evidence, and the record already summarises them. File sources may opt into the archive one by one (an SSH `auth.log` for design 20 is the obvious case); the default is off.

## 7. The archive

Optional, off by default, and the only part of this design that sends anything off hkg.

### 7.1 Unit and cadence

One part per node per UTC hour: every final record (`Open = false`) of an opted-in node, in arrival order, a header line (node, hour, record count, oldest and newest `started_at`) followed by one `model.ConnRecord` JSON object per line, gzip, then age. A record lands in the part of the hour it arrived in, so a long connection started at 09:50 and closed at 11:10 is in the 11:00 part; the header range is what lets a restore find it. Capture lines go into one part per capture when it ends. Object keys are `records/<hn>/<yyyy-mm-dd>/<hh>.ndjson.gz.age` and `captures/<session_id>.ndjson.gz.age`, where `hn` is an HMAC of the node id under the archive key, so a bucket listing reveals dates, counts and sizes and never node names. NDJSON rather than SQLite because a part is written as records arrive, it is about a quarter smaller (63 against 86 B measured), and new `ConnRecord` fields decode as absent in old parts.

A part is closed one hour after its hour ends, so the attribution retry (`server_trace_attr.go`, every 5 minutes over 24 hours) has a chance to resolve `unresolved` users first. Whatever is still unresolved is archived as it is and re-attributed when it is restored.

Hourly rather than daily for durability: today evidence lives only on hkg until the next deploy snapshot; with hourly parts, losing hkg loses at most about two hours of it. The operation count is small: 34 nodes x 24 x 30 is 24,480 PUTs a month against a free tier of one million.

### 7.2 Encryption

Encrypted on hkg, as it is written, before anything touches the network. The staging file is age output from its first byte, so a part waiting for upload is never plaintext on disk.

Each part is encrypted to two age X25519 recipients:

- the control plane's archive identity, generated when the archive is first enabled, its private key sealed with the master key through `internal/store/crypto.go`, so the server can restore on demand;
- the operator's offline recipient, the same age public key `offsite-backup.sh` already encrypts to (its private key is on the operator's Mac and in the password manager, never on hkg), so archived evidence survives the loss of hkg and its master key and can be read with `age -d` and `zcat`.

Rotating the archive identity creates a new one for new parts and keeps the old ones sealed, so old parts stay readable. Removing the server recipient turns the archive operator-only (open decision 7).

Using age adds `filippo.io/age`, pure Go, as a dependency, and the doctrine wants an ADR for every new one (proposed ADR-005). The alternative, an in-house format on `crypto/ecdh`, `crypto/hkdf` and `chacha20poly1305`, would be a second, unreviewed version of the same construction. Compression is stdlib gzip; zstd would be smaller and faster but is another dependency for a few megabytes a day (`yagni:` ceiling: revisit if a part ever exceeds 50 MB).

### 7.3 Credentials and transport

A dedicated bucket (proposed name `lattice-evidence`) with a bucket-scoped Object Read and Write token, separate from `lattice-backups`, so the evidence credential cannot touch backups and the reverse. The operator enters the token once in the console, as a full administrator with a fresh second factor; it is sealed like every other secret and never shown again. It does not go through any session, matching how `r2-credentials-set.sh` handles the backup token.

The client is a minimal S3 SigV4 client in a new `internal/objstore` (PUT, GET, HEAD, DELETE, ListObjectsV2), on the stdlib, tested against the published SigV4 vectors, and dialled through `internal/outbound` with the endpoint pinned to `<account>.r2.cloudflarestorage.com`. `offsite-backup.sh` proves the same calls with `curl --aws-sigv4`. The AWS SDK is not worth its dependency tree for five calls.

### 7.4 Failure, never silent

After each PUT the writer HEADs the object, checks its size and the SHA-256 it computed, writes a manifest row, and only then deletes the staging file. If R2 is unreachable, parts accumulate in staging; at 256 MiB that is about 14 days at C. The archive state turns `failing` with the last error and since when, a notification fires once per episode through `internal/notify`, and when staging is full the oldest part is dropped with an audit event `evidence.archive.dropped` naming its node and hour. Hot-tier eviction does not wait for the archive: the hot tier is a budget, the archive is a copy.

### 7.5 The manifest

A local table in `trace.db`: `archive_parts(node_id, hour, kind, object_key, bytes, records, started_min, started_max, sha256, recipients, uploaded_at)`. It is what makes queries cheap (section 8) and deletion exact. If it is lost, a bucket listing rebuilds it: each `hn` prefix maps back through the HMAC of the known node ids, and a ranged GET of each part's first chunk, decrypted, yields its header.

### 7.6 Retention and deletion

Default 400 days, matching the daily tier. The server deletes expired parts (DELETE is free), and a bucket lifecycle rule at retention plus 30 days is the backstop if hkg is gone. Deleting a node deletes its local evidence and every archived part under its `hn` prefix, and the node deletion summary counts them. No bucket lock by default: a lock would protect evidence from a compromised control plane but would also stop the operator deleting data on request (open decision 8).

### 7.7 Cost

Every record of opted-in nodes, 110 B each, no free tier:

| | L | C | H |
|---|---|---|---|
| per day | 4.8 MB | 19 MB | 95 MB |
| 400 days | 1.9 GB | 7.6 GB | 38 GB |
| per month at steady state | $0.03 | $0.11 | $0.57 |
| 5 years | 8.7 GB, $0.13 a month | 35 GB, $0.52 a month | 173 GB, $2.60 a month |

Operations stay inside the free tier. Infrequent Access storage would save a third of the storage line but charges for retrieval and has no free tier; not worth it at these sizes.

## 8. Queries across local and archived data

Every read answers from local data and says where local data ends. Nothing reads R2 unless an operator or an agent asks it to.

The local horizon is per node: the oldest record still held for it. `GET /api/trace/connections` gains a `horizon` object: `local_from` per requested node, `archive_from` and `archive_to` from the manifest, and, when the window reaches past `local_from`, `archive_gap{parts, bytes, from, to}`. The page also carries each node's sampling rate over the window, and the console says "all failures and 86 percent of clean connections" above a sampled list, so a sample is never read as the whole; the counts in the trends above it are exact.

Trend reads come from the rollups and never need the archive: a new `GET /api/trace/rollups?since&until&node_id&line_uuid&user_id&group_by=node|line|user|reason` picks the tier from the window (up to 7 days: 5 min; up to 90 days: 1 h; beyond: 1 d) and answers columnar series. This is also the first reader the existing five-minute rollups have ever had.

Fetching archived detail is a restore job: `POST /api/evidence/restores {node_ids, since, until}`. The server lists the parts whose `started_min` to `started_max` range overlaps the window, refuses more than 31 days times the selected nodes or more than the restore cache, downloads, checks each SHA-256, decrypts, re-attributes, and loads the records into a temporary SQLite store under `evidence-cache/` (0600, same schema and indexes, so `tracestore.QueryRecords` runs on it unchanged). `GET /api/evidence/restores/{id}` reports parts and bytes done; `DELETE` cancels or drops it. A restored range expires 24 hours after its last use, oldest first under the cache budget.

While a restore is loaded, the connections query reads the hot store and every loaded restore that overlaps the window and merges them newest first on the existing keyset `(started_at, node_id, core_generation, log_id)`; the cursor gains the source it stopped in. Where the hot store and a restore hold the same record (failures inside both), the hot copy wins.

Restores are reads: scope `log:read` on every node they touch, an audit event `evidence.restore` with the window and the bytes fetched. An agent uses the same endpoints within the same limits (axiom 4).

## 9. Console

Evidence keeps the three layers design 22 gave it (Overview, Explore, Collection) and the chassis from design 23. This section is the Gate 1 plan for the parts that change.

### 9.1 Tasks and objects

The operator comes with four questions: is this node being watched and how far back can I see; watch these nodes from now on and what will it cost on hkg; what happened on this node on a day three months ago; is the store and the archive healthy. Objects: node coverage (streams, readiness, rate, horizon), the tiers, the archive and its parts, a restore, the budgets.

### 9.2 Layout

Overview at 1440:

```
Evidence                                                                [Refresh]
observed 12 s ago · detail back to 27 Sep (7 d) · archive since 2 Nov 2025 · trends 400 d · 0.8 of 1 GiB · 6 of 34 nodes recording
[Overview] [Explore] [Collection]
+ Trends --------------------------------------------- [24h|7d|30d|90d|1y] [node: all v] +
| connections per hour  (line, --primary, min to max band)                                |
| failures by close reason  (stacked, existing chart palette)                             |
+-----------------------------------------------------------------------------------------+
NODE            RECORDING              HORIZON over the chosen range              HELD
legend-sg       records, all           [ aaaaaaaaaaaaaaaaaaaaaaaaa|ddddddd ]       41 k
dmit-1          records, auto 86%      [ aaaaaaaaaaaaaaaaaaaaaaaaa|ddddddd ]      212 k
gomami-hkg      not ready: no Clash API  [Set up]  [ ........................... ]   -
xuezhang-jp     off                    [ ttttttttttttttttttttttttt|ttttttt ]   trends only
```

The horizon strip is one row-height bar per node over the range the trend chart shows: `d` local detail in `--primary`, `a` archived in `--primary` at low opacity with a hairline `--border`, `t` trends only in `--muted`, blank where nothing was collected. The tick is the node's local horizon. Hover or focus names each segment and its dates; the strip is a link into Explore for that node and that span.

Explore, at the boundary of local detail:

```
| 27 Sep 00:04:11  legend-sg  u_3f..  api.openai.com:443   eof   12.1 s |
+------------------------------------------------------------------------+
| Older detail for this window is archived: 3 nodes, 26 hourly parts,     |
| about 14 MB. Trends above already cover it.     [Fetch archived detail] |
+------------------------------------------------------------------------+
```

During a fetch the band reads "fetching 9 of 26 parts, 4.8 of 14 MB" with Cancel; afterwards the rows continue below it and the band shows "archived detail loaded until 14:20 tomorrow" with Drop. The range picker gains 30d, 90d and 1y; `all` keeps meaning all local detail and shows the band when the archive holds more.

Collection gains a recording table and a retention panel:

```
[ ] 3 selected     Records [on v]   Raw lines [off v]   Archive [on v]       [Apply to 3]
NODE          READY                 RECORDS          RAW LINES       FILES   ARCHIVE
legend-sg     ready                 on, all (pin)    off             1       on
dmit-1        ready                 on, auto 86%     debug, 3 d      0       on
gomami-hkg    no Clash API [Set up] -                -               2       -
This change: +23 MB a day before sampling. Horizon stays 7 d at 81% of clean connections. Archive +3 MB a day, about $0.01 a month.

Local budget 1 GiB · detail 7 d target · 5 min 14 d · 1 h 90 d · 1 day 400 d          [Edit]
Archive   lattice-evidence · last part 10:00Z, uploaded 10:03Z · 8.1 GB · about $0.12 a month
          recipients: control plane ab12...ef · operator age1qz...7k        [Pause] [Plan a change]
```

At 375 the coverage table becomes two lines per node: name and horizon strip, then the recording state as one sentence. The recording table becomes a list with a sheet per node; bulk apply sits in a sticky footer. Rows are 40 px (`--row-h`); the strip is 32 px (`--row-h-compact`) inside the row; every control keeps a 44 px touch target.

### 9.3 Palette, type, signature

Existing tokens only. `--primary` for local detail, the selected range and the series a chart is about; `--muted` and `--muted-foreground` for trends-only spans and secondary text; `--warning-text` for sampling below 50 percent, a budget over 80 percent and a horizon shorter than its target; `--destructive` for a node that is on but not ready and an archive that is failing; `--info-text` for a restore in progress. The chart palette is the one design 22 section 10 recorded. Type: the UI face for labels and sentences, `--font-mono` for node ids, object keys, sizes, rates and every date in the proof line.

The signature element is the proof line, extended with the horizon: what the page last heard, how far back detail goes, since when the archive holds parts, how long trends go back, how full the budget is, and how many nodes record. It is the one sentence that answers the operator's first question without scrolling.

### 9.4 States

Loading: skeleton rows, proof line `loading`. Nothing collected: the existing Overview copy, now offering "Record connections on these nodes" beside the capture. On but not ready: the node row in `--destructive` with the named reason and the set-up action. Sampling active: the rate in the recording cell, with the reason in its title. Budget pressure: the proof line names the shortened horizon. Archive not configured: the panel explains what it would cost and offers "Plan the archive". Archive healthy, uploading, paused, failing (last error, since when, staging used). Restore estimating, fetching, loaded with its expiry, failed with the part that failed, cancelled. Permission denied: `log:read` missing shows the existing quiet panel; `log:admin` missing shows every switch disabled with the scope named; archive configuration without full administrator shows the panel read-only. Long content: node names truncate with a title on desktop and wrap on phones; a 1-year strip over 400 days of parts stays one bar.

### 9.5 Defaults I marked and revised

Reading the plan back against the operator's words ("long-term monitoring", "selective node monitoring", "a big database"):

1. A grid of storage cards with donuts was the first sketch. It became one proof-line sentence and a retention line, because sizes are context for the operator's question, not the answer to it.
2. A single "long-term mode" switch for the fleet was a generic default. The operator asked for selective monitoring, so the unit is node by stream, with bulk apply.
3. A separate Archive page with an object browser was a generic default. Archived detail now appears where the operator already asks questions, at the boundary in Explore, with one explicit fetch.
4. The change preview showed dollars first. hkg's disk is the constraint and the dollars are cents, so the preview leads with megabytes a day and the horizon, and ends with the monthly cost.
5. Fetching archived hours automatically on scroll was rejected: it touches R2 and costs time, so it is an explicit, cancellable action that states its size.

## 10. API and model changes, by repository

lattice-sdk: `TracePolicy.Raw`, `TracePolicy.SampleRate`, `CollectorStatus` on `TraceAgentConfig` and `TraceBatch`, `RecordPage.Horizon`, rollup and restore types.

lattice-node-agent: Clash API discovery from the config (section 4.2); collector status; raw lines gated on `Raw.Enabled`; connection shedding replacing line truncation (section 4.3). No sampling and no archive code on the node.

lattice-server: `tracestore` sampling at insert with the keyed hash, `rollups_1h` and `rollups_1d` with roll-up on bucket close and a migration to schema version 2, `archive_parts`, per-tier retention, the governor; settings for the four budgets replacing the fixed `Options{}`; `logstore` shared budget and per-source TTL; new `internal/objstore` (SigV4) and `internal/evidencearchive` (part writer, uploader, verifier, restorer, keys); endpoints `GET /api/trace/rollups`, `GET|POST /api/evidence/settings`, `GET /api/evidence/archive`, the archive plan kind, `POST|GET|DELETE /api/evidence/restores`; `horizon` on the connections page; node deletion purging archived parts; ADR-005 for `filippo.io/age`.

lattice-dashboard: proof line horizon, trends card on the rollups endpoint, horizon strip, Explore boundary band and restore flow, Collection recording table with readiness and cost preview, retention and archive panel. New model tests join `pnpm test:navigation`.

## 11. Security and privacy

Evidence is the most personal data Lattice holds: who connected where, and when. The design draws the line in three places.

Opt-in per node is the privacy boundary, and the default for every new node is off. Long-term tiers carry counts and no destinations, so the 400-day record says how much and how often, never where. Destinations older than the local horizon exist only in the archive, which is off by default and encrypted before it leaves hkg; Cloudflare holds ciphertext, object sizes and hour stamps under HMAC'd node prefixes.

The archive token is bucket-scoped and separate from the backup token. Turning the archive on, changing its recipients and turning it off are plans: an agent may propose one, the operator approves it, and the approval binds the bucket, endpoint, recipient fingerprints and retention (axiom 1 applied to a data boundary rather than a machine). Collection policy changes stay audit-only, following the existing `AgentDebugPolicy` precedent (open decision 9).

A compromised hkg reads the hot tier, as it can today, and in the recommended mode can read the archive too, because the server holds an archive identity. Operator-only mode removes that at the price of on-demand restore (open decision 7). Neither mode protects the archive from deletion by a compromised hkg; only a bucket lock does (open decision 8). The plaintext `dst_host` column in `trace.db` is unchanged by this design and remains the S6 item from the trace design (HMAC tokenisation).

## 12. The strongest case against

Disk is cheap; resize hkg's volume and keep today's shape with bigger caps. This is a real alternative and it is a spending decision reserved for the operator. It does not fix the shape, though: raw lines cost four times the records, the 90-day five-minute rollup grows past any cap at H and is unreadable, nothing is offsite, and a node can still be "on" and silent. The fixes in sections 4 to 6 are worth doing at any disk size; only the archive is optional.

The archive is complexity for data nobody reads. Possibly. That is why it is off by default, why trends need no archive, and why its second purpose, evidence surviving the loss of hkg within the hour, is stated separately so the operator can weigh it on its own.

Server-side sampling ships data only to discard it. At C the whole fleet sends about 1.7 KB/s; shipping everything keeps rollups exact without a second counting path on the node, and lets the archive hold every record while the hot tier holds a sample. If ingest ever matters, agent-side tallies plus agent sampling are the upgrade path.

Always-on per-user connection logs are surveillance-shaped. They are, for anyone who can read them. The defaults (off per node, 7 days of detail, no destinations in long tiers, archive off) keep the long record to counts unless the operator chooses otherwise, node by node.

## 13. Delivery

Each slice ships alone and leaves the system honest.

- R0, measurement, no code. Turn records on for the busiest node for 24 hours after its Clash API is set up, and read connections per day, lines per second, sing-box CPU and memory before and after (the trace design's V3). Replace the L, C, H assumptions in sections 2, 5 and 7 with the measured rate. Needs the operator's choice of node.
- R1, readiness and honesty. Agent discovery and collector status, readiness in Collection and Overview, raw lines split from records, connection shedding, the rollups read endpoint, settings for the budgets with today's values. Acceptance: a node switched on without a Clash API shows `no_clash_api` within one poll; a node with records on and raw off ships zero raw lines.
- R2, sampling and the governor, rollup tiers, the shared raw budget with TTLs, the new defaults. Acceptance: with a synthetic load at three times the budget, 7 days of failures stay, the proof line names the rate, and rollup totals equal the records shipped.
- R3, the archive writer: staging, encryption to both recipients, upload, verification, manifest, retention, deletion, the archive plan kind, ADR-005. Acceptance: a part decrypts with the operator's identity on another machine; R2 down for an hour turns the state `failing` and recovers without loss.
- R4, restores and the console flow. Acceptance: a node's archived day loads, pages and merges with local records in the correct order, and expires on schedule.

Server slices run the full checks in the handbook, including `-race` on `internal/server` and `internal/store`. Console slices run the rendered pass at 1440 and 375 in both themes and zh-CN.

## 14. Decisions (operator, 2026-10-05)

The operator accepted every recommendation below on 2026-10-05. The alternatives are kept so a later change of mind starts from the same trade-off.

1. A few nodes record first, records only; raw lines stay capture-only. (Alternative: raw lines on with records.)
2. The local budget is 1 GiB for `trace.db` and 2 GiB worst case for all evidence. hkg had 63 GB free on 2026-10-05 after the backup cleanup, so no volume resize. (Alternatives: less, or a paid resize.)
3. The detail horizon is 7 days. (Alternative: 14 days, at about twice the sampling pressure.)
4. Sampling is the automatic governor with per-node pins. (Alternative: fixed rates the operator sets.)
5. Long tiers keep per-user daily counts for 400 days; per-user detail ends at 14 days. (Alternatives: 5 years, or no user in any tier past 14 days.)
6. The archive is turned on once nodes record, in its own bucket (not `lattice-backups`), with 400 days' retention, about $0.11 a month at C. (Alternative: 5 years, about $0.52 a month at C.)
7. The control plane and the operator can both read the archive (two recipients; restores on demand). (Alternative: the operator only, read offline with `age -d`.)
8. No bucket lock; deletion on request stays possible. (Alternative: a lock for the retention period.)
9. Turning records on for a node is an audit event, not an approval, as captures are today; the archive is the plan. (Alternative: an approval.)
10. `filippo.io/age` comes in through ADR-005. (Alternative: an in-house format.)

R0 still needs the nodes: the first ones are chosen from measured traffic when R0 starts, and named in `PROGRAM.md`.
