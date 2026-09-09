# Design 16 — Sub-Store as a native Lattice subscription platform

> Status: **shipped.** The native subscription platform runs in
> `lattice-plugin-sub-store` in production. The line below is the status this
> document was written with and was never updated; the implementation plan it
> points at is archived at
> `../archive/plans/2026-08-05-design-16-sub1-implementation.md` with its
> checkboxes still unticked, which is a record-keeping gap rather than
> unfinished work. `README.md` in this directory carries the status table.
>
> Original status: design, sub-project 1 specified.
> Supersedes the scope decision in `lattice-olympus:plan/design-substore-embed.md §7` open
> question 2 ("conversion + subscription management only"), which answered *conversion only*.
> The operator's goal is now explicit: **shut the standalone Sub-Store down** and have Lattice be
> the only place third-party provider subscriptions and self-hosted nodes are managed and served.

## 1. Goal and acceptance

The acceptance test is not feature parity on paper. It is one sentence:

> The operator can stop their standalone Sub-Store instance, and every client that used to
> subscribe to it keeps working against Lattice.

That framing decides the order of work below: distribution and migration outrank breadth of
operators, because a feature-complete converter nobody can subscribe to changes nothing.

## 2. Decomposition

`Sub-Store`'s backend exposes 21 route modules. That is several independent subsystems, not one
change. It is split into six sub-projects; **this document specifies sub-project 1 only**.

| # | Sub-project | Why this cut |
|---|---|---|
| **1** | **Subscription store + public distribution** | The foundation, and the only part that touches the core server. Defines the data model and the boundary between core-owned public surface and plugin-owned content. |
| 2 | Remote fetch and scheduled sync | Provider fetch, custom UA, traffic-info parsing, refresh scheduling. |
| 3 | Processing pipeline completion | Full upstream operator set, preview, sort, node-info. |
| 4 | Migration from an existing Sub-Store | One-shot import. Without it the operator cannot honestly switch off the old instance. |
| 5 | Operations surface | Settings, logs, backup/restore. |
| 6 | Artifact sync | Artifacts, files, modules. |

## 3. Verified constraints

Every claim below was read out of the tree, not remembered. They shape the design, so they are
recorded with their source.

| Fact | Source |
|---|---|
| `/sub/<token>` exists and is **unauthenticated**, rate-limited, and audited | `lattice-server:internal/server/server.go` route table; `server_proxy.go:152` |
| Path parsing rejects any token containing `/`, so a two-segment form is currently a clean 404 | `server_proxy.go:283` |
| Subscription token regex already admits hyphenated lowercase words | `server_proxy.go:36` — `^[A-Za-z0-9_-]{32,256}$` |
| `worker:route` is **not** an HTTP runtime — it is `{{path}}` / `{{kv:…}}` string interpolation behind an authenticated operator endpoint | `internal/worker/worker.go:29`; route registered `withAuth("worker:deploy")` |
| Plugin capability vocabulary already includes `http:egress` (broker-guarded), `kv:read/write`, `secret:read/write`, `static:read/write`, `task:run` | `internal/plugin/plugin.go` capability map |
| Proxy-user credentials **and the subscription bearer token** are already sealed at rest | `internal/store/crypto.go:35` |
| With the bolt hot store enabled, `state.json` excludes only `Audit / Sessions / ProxyUsers / ProxyProfiles / ProxyUsage` | `internal/store/store.go:548-559` |
| `kv` and `static` are **not** excluded — every plugin KV write and static object enters the single full-rewrite `state.json` | same, by absence |
| `Broker.KVPut` enforces capability and key shape but **no value size limit** | `internal/plugin/broker.go:306` |
| The embedded engine runs on QuickJS-over-wazero and parses a 1.24 MB IIFE per call | `lattice-plugin-sub-store:system-go/go.mod` (`fastschema/qjs`, `tetratelabs/wazero`); `tools/substore-core/pin.json` |

Two of these are pre-existing defects rather than design inputs. They are recorded in §10 and get
their own tasks; this design does not depend on either being fixed first.

## 4. URL shape and access token

The single-segment form is **removed**, not kept alongside. There is exactly one shape:

```
/sub/<share-slug>/<token>
```

This is affordable because the deployment currently has zero proxy users, zero proxy profiles and
zero proxy inbounds — no live subscription breaks. Keeping two shapes would buy nothing and cost a
permanent branch in the path parser.

**The first segment is a label, not a secret.** It appears in reverse-proxy access logs, client
configuration screenshots, and any intermediate proxy's logs. Security rests entirely on the
second segment. Charset `^[a-z0-9][a-z0-9-]{0,62}$`.

**The second segment is the only secret.** Generated server-side by `auth.NewRandomToken(32)` —
the same 256-bit primitive the existing subscription token uses. A word-list ("memorable") format
was considered and rejected: the two-segment shape already gives the human-readable part, so the
token has no reason to trade entropy for pronounceability.

Lookup: resolve by token; then require the slug to match the share's current slug; on mismatch
return **404**, identical to an unknown token, so the response never distinguishes "valid token,
wrong slug" from "no such token". Renaming a share therefore invalidates existing client URLs —
the UI must say so before it renames, and should offer to keep the previous slug as an alias for a
grace period.

Audit records the slug and `token_sha256`, never the token. Rotation records
`old_token_sha256` / `new_token_sha256`. This mirrors the existing proxy-user audit exactly.

## 5. Shares and the subscription-source abstraction

A token resolves to a **share**, and a share names a **source**:

```
SubscriptionShare
  slug            label in the URL's first segment
  token           the only secret; sealed at rest
  source          core.proxy_user  → existing VLESS-Reality rendering
                  plugin           → { plugin_id, subscription_id }
  default_format  used when the client sends no ?format=
  enabled, created_at, rotated_at, expires_at?
```

A plugin subscription source is therefore not a special case in the router; it is one
implementation of a source interface. The division of labour is a straight line:

| Core owns, always | Plugin owns, only this |
|---|---|
| Routing, token lookup, slug comparison | Given `subscription_id`, `format`, client UA — produce content |
| Rate limiting (the existing subscription limiter) | |
| Audit (slug + `token_sha256`, never the token) | |
| Content-Type negotiation, `Subscription-Userinfo` | (passes through the provider's traffic figures) |
| Output cache and its TTL | |

The plugin side adds one manifest-declared method with `effect: read` and its own budget —
structurally identical to the thirteen methods it already declares. No new runtime shape is
introduced.

The new host capability is deliberately narrow. It reads as one sentence: *this plugin may produce
content for a subscription endpoint the core owns.* It grants no route, no port, no listener, and
no access to the token. A general `http:serve` capability was considered and rejected: it would
hand the unauthenticated public surface — token checking, rate limiting, audit, response headers —
to plugin code, which is the exact shape the plugin-boundary review rejected before.

## 6. Storage

Four classes of data with different durability needs, placed against the constraints in §3.

| Data | Home | Rationale |
|---|---|---|
| `SubscriptionShare` | bolt hot store, alongside `ProxyUsers` | Read on every fetch; record-level writes; the sealing path for tokens already exists in that domain |
| Subscription / collection definitions | plugin KV, under an explicit size cap the plugin enforces on itself | Definitions are small (hundreds of bytes to a few KB each); tens of them are affordable inside `state.json` |
| **Last successful remote snapshot** | **the core, in the bolt hot store**, keyed by `(plugin_id, subscription_id)` and treated as an opaque blob | **Durable, not a cache.** When a provider goes down or rotates its URL, this snapshot is the only thing that keeps clients served — upstream's `ignore-failed-remote-sub` behaviour. Losing it means subscriptions go dark. The home took two wrong answers before this one, both recorded here rather than quietly replaced: **bolt via the plugin** is impossible because a plugin cannot reach bolt, and **the plugin's working directory** is impossible because `SystemRunner.Stop` deletes it by design (`system_runner.go:251`, "removes its runtime dir"). A plugin has no durable storage that is not the state file, so the core owns the snapshot and the plugin stays stateless: it fetches on request and hands the bytes back, and it is given them again on the next render. |
| Converted output | in-memory LRU + TTL | Derivable at any time from snapshot + operator chain; disposable by definition |

The consequence worth stating: **the subscription fetch hot path never touches `state.json`.**
Share lookup reads bolt, a cache hit is served from memory, and only a miss forks the plugin.

Cache key is `(share_id, format, ua_class)` with a configurable TTL, default 300 seconds. `ua_class`
is a **bounded** classification of the client User-Agent — the recognized client families and one
`other` bucket — never the raw header. Keying on the raw User-Agent would let any caller mint
unlimited distinct cache entries by varying a string they control, turning the cache into a memory
amplifier; and the classification is all the conversion actually depends on. The cache exists to
stop a wazero VM boot and a 1.24 MB parse on every client poll.

The plugin caps its own KV writes rather than relying on the core to reject oversized values. That
keeps this design independent of the `KVPut` fix in §10.

## 7. Upgrade compatibility and migration

The operator's requirement is that updates never damage data. That makes the following first-class
constraints, not implementation notes:

- Every persisted record carries `schema_version`.
- Migrations are **additive only**, per the release law in `lattice-olympus:rules/01 §8`.
- **Unknown fields survive a round trip.** A server that reads a record written by a newer version
  must re-serialize it without dropping the fields it did not recognize. Without this, a single
  downgrade or rollback silently destroys data — the failure mode is invisible until someone looks
  for a setting that is simply gone.
- The **export/import format is defined now**, in this sub-project, not deferred to sub-project 4.
  A format designed after the fact gets shaped by whatever the implementation happened to store;
  designing it up front forces the data model to be expressible independently of its storage.

## 8. Failure semantics

The dangerous failure here is not an error — it is a success with no content.

**A subscription response must never be an empty body with HTTP 200.** A proxy client that
receives an empty but successful subscription deletes every node it had. Any internal failure —
plugin unavailable, budget exceeded, snapshot missing, conversion error — returns a non-2xx status
so the client keeps its previous configuration. This is stated as a rule because every individual
error path is tempting to "handle gracefully" by returning what was produced so far.

- Provider fetch fails, snapshot exists → serve the snapshot, mark the subscription stale in the
  UI, audit the fallback. The client stays working.
- Provider fetch fails, no snapshot → non-2xx. Never an empty 200.
- One member of a collection fails, others succeed → serve the successful members, report the
  failed one in the UI (upstream's `ignore-failed-remote-sub` behaviour).
- Plugin call exceeds its declared budget → fail loudly. The existing runtime aborts rather than
  truncating, and that semantic is preserved: a truncated subscription is a silently wrong one.
- Unknown token, or valid token with mismatched slug → 404, indistinguishable.

## 8b. Probe resistance

The operator's requirement, stated after the first implementation: a request that
cannot be served should look like the endpoint does not exist.

This is not a presentation preference, it is the threat model. A response that
distinguishes "valid token, nothing to serve" from "no such token" has told a
prober the one fact the token exists to keep. The first implementation leaked
that five ways: a JSON error body carrying a request id (identifies the
software), a 429 from the rate limiter (identifies a specially-limited path), a
405 on the wrong method, a 400 on a bad format **after** the token was resolved
(directly reveals a valid token), and a 502 on an empty render (reveals a valid
token with empty content).

**Every non-servable request now returns one response**, with no Lattice
fingerprint: no error body, no request-id header, no content type unless
configured. The default is a bare 404, which a reverse proxy can replace with its
own error page via `proxy_intercept_errors`, making `/sub/<anything>` and a path
that never existed byte-identical. It is configurable so an operator can match
whatever their front proxy actually returns.

Two consequences of the ordering matter and are enforced by test:

- **Format is validated before the token is resolved.** Validating it afterwards
  meant a valid token with a bad format answered differently from an invalid one,
  which is the sharpest leak of the five.
- **Rate limiting refuses in the same voice.** The limit still applies; it just
  does not announce itself.

**Truth is relocated, not discarded.** Every rejection is still audited with its
real reason and its share id, so the operator can diagnose exactly what a prober
cannot learn. That split — silence on the wire, completeness in the log — is what
makes this safe to run.

### What this deliberately does not do

**The server does not proxy to a decoy site.** Forwarding an unauthenticated
request to an operator-configured upstream would make the endpoint a
request-forwarding surface, and the disguise would still be imperfect: headers,
TLS characteristics and timing would differ from the site being imitated. The
masquerade belongs at the reverse proxy, which already terminates TLS and serves
the rest of the origin, and which can do it in three lines. Lattice's job is to
be silent; the edge's job is to be someone else.

### The limit worth stating

**Timing is still distinguishable.** A valid token forks a plugin and boots a
JavaScript VM — hundreds of milliseconds to seconds — while a rejection returns
immediately. A prober measuring response time can separate the two regardless of
what the bytes say. Equalising it would mean delaying every rejection by the
worst-case render time, which is a real cost for an imperfect result, so it is
recorded here rather than papered over. The cache narrows the gap for repeated
valid requests but does not close it for the first one.

### Where masquerade does not apply

The authenticated operator API tells the truth. A share that publishes nothing
returns an empty URL and says so; a refresh that failed reports the failure. An
operator who cannot see why their own subscription stopped working cannot run
this system, and the API is already behind authentication, so there is nothing to
hide from its caller.

## 9. Testing

- Path/lookup: unknown token, valid token + wrong slug, disabled share, expired share — all 404;
  the wrong-slug case asserted to be byte-identical to the unknown-token case.
- **Empty output is refused**: a source returning zero entries must produce a non-2xx, asserted
  directly, because this is the failure that silently wipes client configurations.
- Snapshot fallback: with the provider unreachable, the last snapshot is served and the fallback is
  audited; with no snapshot, the response is non-2xx.
- Cache: a second fetch within the TTL serves from cache and does **not** fork the plugin —
  asserted by call count, not by timing.
- Schema round trip: a record carrying unknown future fields survives read-modify-write with those
  fields intact.
- Export/import round trip: export → import into an empty store → byte-identical export.
- Audit: no test fixture and no log line ever contains a raw token.

## 10. Out of scope, and known gaps

Not in this sub-project: remote fetch and scheduling (2), the full operator set (3), migration
tooling (4), settings/logs/backup (5), artifact sync (6).

Two pre-existing defects were found while verifying the constraints above. Both get their own
tasks; neither blocks this design:

1. **`Broker.KVPut` has no value size limit.** Any signed plugin holding `kv:write` can grow
   `state.json` without bound, and that file is rewritten in full and fsynced on every state write.
   This threatens all persistence, not just this feature.
2. **`kv` and `static` are absent from the bolt hot-store exclusion list**, so both still ride the
   full-rewrite path even though bolt buckets exist for them. Whether that is intentional or an
   oversight needs a decision before either is used for bulk data.
