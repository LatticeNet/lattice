# design: notification abstraction and the SDK notify capability

Status: proposed 2026-09-04, awaiting operator decisions listed in section 11.
Scope: lattice-server notify plane, lattice-sdk plugin contract, console
surfaces on /platform/notifications and /platform/webhooks. No node code
changes. Anchors below were read against lattice-server integration at
0910e61 (a90 console pin) and lattice-sdk integration on 2026-09-04.

## 1. What exists and where it stops

The notify plane is three records and one fan-out.

Channels (`lattice-sdk/model/model.go:1543-1551`) are a kind plus a flat
config map, envelope-encrypted at rest and never returned. Four kinds are
built in `internal/server/server.go:4529-4560` (`buildChannel`): telegram,
bark, discord, webhook. Bark already sends the v2 JSON form with level and
group (`internal/notify/notify.go:116-179`, merged as `feat/notify-bark-post-push`),
falling back to the GET path form on 404 or 405.

Rules (`model.go:1557-1565`) map `event_types` to `channel_ids` with a title
and body template. `planNotifyDeliveries` (`server.go:4945-4990`) applies
them: with zero rules every enabled channel receives every event; with rules,
each enabled rule whose `event_types` contains the type or `*` sends to its
channels, rendering templates over `event_type`, `title`, `body`.

Inbound webhooks (`internal/server/server_notify_webhook.go`, shipped in a88)
are the one source that is already shaped correctly: the operator authors the
event type and templates, the caller supplies a bounded bag of scalar fields,
and `fireNotifyWebhook` (`server_notify_webhook.go:585-660`) hands the result
to the same planner. Each webhook keeps a 50-entry delivery ring
(`internal/store/notify_webhook.go:69-113`) with outcomes accepted,
no_route, rejected, failed, partial.

Where it stops:

- Event typing is inferred from title strings for most emitters.
  `notifyEvent` (`server.go:4912`) calls `classifyNotifyEvent`
  (`server.go:5033-5052`), which matches substrings such as "Monitor down".
  The node offline title (`server_inventory.go:833`) matches nothing and is
  typed `generic`; so is the Sub-Store sync failure (`substore_sync.go:276`)
  and the 2FA attempt limit (`server.go:2124`). A wording change silently
  changes routing. Only `service.down`, `service.recovered`
  (`server_singbox_liveness.go:136-142`) and `ssh.compromise_suspected`
  (`server_ssh_pressure.go:185`) are emitted typed.
- Plugin notifications bypass rules. `pluginHost.Send`
  (`internal/server/plugin_host.go:216-240`) builds every enabled channel and
  fans out directly with no event type, no template, no rule, no record. The
  SDK side is `HostClient.NotifySend(ctx, title, body)`
  (`lattice-sdk/plugin/host.go:627-633`), broker gate `notify:send`
  (`internal/plugin/broker.go:647-656`), runner method `notify.send`
  (`internal/plugin/system_runner.go:1686-1697`).
- No delivery history for anything but webhooks. `notifyEventTyped`
  (`server.go:4918-4938`) logs failures with `s.logger.Printf` and nothing
  else. The operator cannot answer "did the phone ring for that
  service.down" from the console.
- No severity, no subject, no dedupe. A monitor that flaps ten times sends
  ten pushes. Bark level is a channel-wide setting, so a compromise alert and
  a renewal reminder interrupt the phone the same way.
- No consumer side. A plugin cannot learn that a node went offline; an
  external system can only receive the `{title, body}` webhook payload
  (`notify.go:202-221`), with no event id, type or signature.
- One flat operator scope. `notify:send` gates every `/api/notify/*` route
  (`server.go:1114-1123`) including channel, rule and webhook
  administration; the split into an emit scope and an admin scope is an open
  trust-contract decision recorded in PROGRAM.md.

Production on 2026-09-04 has zero channels, zero rules, zero webhooks, so
every event above already fires into nothing. That is the reason to do this
design now rather than after Bark is restored: the first channel the operator
adds will receive everything, and the rules editor as it stands cannot say
what "everything" is.

## 2. Principles

1. One event path. Every source (server, node report, plugin, inbound
   webhook, schedule) produces the same `Event` and enters the same planner.
   The webhook slice already states this as its whole point; this design
   extends it to the sources that still bypass it.
2. The operator authors routing; sources author facts. A source may say what
   happened, with what severity, about which subject. It may not choose a
   channel, a template, or whether a rule matches.
3. Type namespaces are owned. Server-originated types have no prefix. A
   plugin's types are always `plugin.<plugin_id>.<name>`, assigned by the
   server, so a plugin cannot raise `ssh.compromise_suspected`. Webhook types
   are operator-authored and may not be `*`. External token-raised types live
   under `external.`. Schedule types live under `schedule.`.
4. Every delivery leaves a record the console can show, and the record is
   settled after the asynchronous send, as the webhook ring already does.
5. Plugin access is declared in the manifest, gated by the broker on every
   call, and additionally approved by the operator per event type. The
   existing chain (manifest, trust policy at load, broker `require` per call
   with an audit event, `broker.go:810-826`) stays; the grant is added on top
   of it, not instead of it.
6. Nothing in this design touches a node or the apply path. It is control
   plane state, host-call plumbing and console.

## 3. Event model

```go
// lattice-sdk/model/model.go (new)
type NotifyEvent struct {
    ID           string            `json:"id"`            // evt_<id>
    Type         string            `json:"type"`          // validateNotifyEventType grammar
    Severity     string            `json:"severity"`      // info | notice | warning | critical
    Source       NotifySource      `json:"source"`
    Subject      NotifySubject     `json:"subject,omitempty"`
    Title        string            `json:"title"`
    Body         string            `json:"body"`
    Fields       map[string]string `json:"fields,omitempty"` // bounded, template-visible
    DedupeKey    string            `json:"dedupe_key"`
    CorrelationID string           `json:"correlation_id,omitempty"` // request, task or approval id
    OccurredAt   time.Time         `json:"occurred_at"`
    ReceivedAt   time.Time         `json:"received_at"`
}

type NotifySource struct {
    Kind string `json:"kind"` // server | node | plugin | webhook | schedule | token
    ID   string `json:"id,omitempty"` // node id, plugin id, webhook id, schedule id, token id
}

type NotifySubject struct {
    Kind  string `json:"kind"` // node | line | monitor | user | plugin | webhook | none
    ID    string `json:"id,omitempty"`
    Label string `json:"label,omitempty"`
}
```

Type grammar is the existing `validateNotifyEventType` (`server.go:5129-5143`):
lowercase `[a-z0-9._:-]`, at most 64 bytes, `*` only in rules. Plugin ids
such as `latticenet.sub-store` already fit, so
`plugin.latticenet.sub-store.sync_failed` is 39 bytes and valid.

Severity is a closed set. It is the one field that maps onto every channel
in a defined way: Bark level `passive`, `active`, `timeSensitive`,
`critical` for info, notice, warning, critical; Telegram and Discord get a
severity prefix in the text; the outbound webhook carries it as a field. A
rule may override the mapping for its channels (section 5), a source may not.

Subject is what the event is about, separate from who reported it. A node
offline event has source `{server}` and subject `{node, node_xxx}`; a plugin
event about a line has source `{plugin, latticenet.vpn-core}` and subject
`{line, <line_uuid>}`. Subject is what dedupe and the console's "events for
this node" view key on.

Fields reuse the webhook limits (`server_notify_webhook.go:47-66`): 16
fields, key 64 bytes, value 512 bytes, values stripped of `{{`, `}}` and
control characters by the same sanitiser, and rendered by the same
single-pass `renderWebhookTemplate`. Templates see `{{fields.<k>}}` plus
`{{event_type}}`, `{{severity}}`, `{{source.kind}}`, `{{source.id}}`,
`{{subject.kind}}`, `{{subject.id}}`, `{{subject.label}}`, `{{title}}`,
`{{body}}`, `{{occurred_at}}`. Webhook-produced events map `data.<k>` to
`fields.<k>` and keep `{{data.<k>}}` working as an alias, so existing
webhook templates do not change.

Dedupe key defaults to `type + "|" + subject.kind + "|" + subject.id`, which
is what every emitter today would want (one monitor, one node, one line). A
source may supply its own key, bounded to 128 bytes, when the default is
wrong (a plugin batching per-user events). The key is used by the
suppression window in section 5, never by the audit trail: every event is
still recorded.

The catalogue. `GET /api/notify/catalogue` returns every type the server can
emit with its default severity, subject kind and a one-line description,
plus operator-authored webhook types and approved plugin types. The rules
editor picks from it instead of a free-text comma list. The server half is a
static table in one file (`internal/server/notify_catalogue.go`) that the
emitters reference by constant, so adding an emitter without a catalogue
entry fails a unit test.

Initial server catalogue, replacing every `classifyNotifyEvent` case and
every untyped emitter:

| type | severity | subject | emitter today |
| --- | --- | --- | --- |
| node.offline | warning | node | server_inventory.go:833 (typed generic today) |
| node.online | info | node | recordNodeOnline audit only, no notify today |
| monitor.down | warning | monitor | server.go:5176 |
| monitor.recovered | info | monitor | server.go:5170 |
| service.down | critical | node | server_singbox_liveness.go:136 |
| service.recovered | info | node | server_singbox_liveness.go:142 |
| ssh.login | notice | node | server.go:5208 |
| ssh.compromise_suspected | critical | node | server_ssh_pressure.go:185 |
| proxy.quota | notice | user | server_proxy_notify.go:249 |
| proxy.expiry | notice | user | server_proxy_notify.go:259 |
| inventory.renewal | notice | node | server_inventory.go:952 |
| auth.2fa_limit | warning | user | server.go:2124 (typed generic today) |
| substore.sync_failed | warning | plugin | substore_sync.go:276 (typed generic today) |
| notify.channel_failing | warning | none | new, section 6 |
| schedule.<name> | operator-set | none | new, section 4 |

## 4. Triggers

A trigger is anything that produces an `Event`. Five kinds, one entry point:

```go
func (s *Server) emit(ev model.NotifyEvent) // replaces emitNotify and emitNotifyTyped
```

`emit` validates the type against the source's allowed namespace, fills
`ID`, `ReceivedAt` and the default dedupe key, records the event in the
outbox (section 6), then plans and sends. The two existing hook fields
`s.emitNotify` and `s.emitNotifyTyped` (`server.go:268-273`, wired at
`server.go:582-583`) stay for one release as adapters so tests that stub them
keep passing, then go.

Server events. Each emitter call site is rewritten to construct the typed
event with its subject. This is mechanical and is where
`classifyNotifyEvent` is deleted.

Node reports. Nodes do not emit events themselves. The agent event endpoint
(`server.go:5183-5213`) already authenticates the node token and switches on
`req.Kind`; the server turns `ssh_login` and `ssh_pressure` into server
events with subject `{node, req.NodeID}`. A node cannot name an event type,
which keeps the "taken-over host sends a million entries" posture the
pressure file describes. Source kind is `node` so rules and the console can
tell "reported by the node" from "derived by the server" (offline is
derived; login is reported).

Plugin events. Host method `notify.emit` (section 7). The server prefixes the
type with `plugin.<plugin_id>.` before validation; a plugin passing an
already prefixed or a foreign type is refused with an audited deny.

Inbound webhooks. Unchanged externally. Internally `fireNotifyWebhook` builds
an `Event` with source `{webhook, hook.ID}`, severity from a new optional
per-webhook field (default notice), subject none unless the operator maps a
data field to a subject in the webhook form (optional, later). The
per-webhook delivery ring is replaced by the shared outbox filtered by
source, so the `/api/notify/webhooks/deliveries` route keeps returning the
same shape from the new store.

Schedules. A new operator-authored record:

```go
type NotifySchedule struct {
    ID            string    `json:"id"`
    Name          string    `json:"name"`
    EventType     string    `json:"event_type"`     // must start with "schedule."
    Severity      string    `json:"severity"`
    Every         string    `json:"every"`          // "15m", "1h", "24h"; or
    DailyAtUTC    string    `json:"daily_at_utc"`   // "08:00"
    TitleTemplate string    `json:"title_template"`
    BodyTemplate  string    `json:"body_template"`
    Enabled       bool      `json:"enabled"`
    LastFiredAt   time.Time `json:"last_fired_at,omitzero"`
}
```

The server's existing sweep ticker (the one that runs the offline sweep in
`server_inventory.go`) checks schedules once a minute and emits the event when
due. Templates see the same variables plus `{{fleet.nodes_online}}`,
`{{fleet.nodes_total}}`, `{{fleet.services_down}}` so a daily "Lattice alive"
push can carry a one-line summary. This is the cheap half of M0.7: the phone
learns that the control plane is alive every morning, and a missing push is
the signal. A missing push still needs a human to notice; the external
heartbeat on lattice.roobli.org remains the only cover for the control plane
itself, and that stays out of scope here.

Schedules are also the timer primitive for plugins: a plugin that wants
periodic work subscribes to `schedule.*` rather than getting its own cron.
No plugin cron in this design; yagni until a plugin needs sub-minute or
per-plugin timing, and the upgrade path is a `schedule` field in the
manifest notify block.

Token-raised events. `POST /api/notify/events` for external systems that hold
an access token with `notify:emit` (section 8). The body is a bounded
`{type, severity, subject, title, body, fields, dedupe_key}`; the type must
start with `external.` and is validated as above; fields obey webhook limits;
the per-token limiter is the webhook fire limiter's shape (10 a minute, burst
10, `server.go:530`). Source is `{token, <token_id>}`. This exists for
trusted systems the operator already runs (nezha, a cron on a node) that want
to name their own types; anything less trusted uses an inbound webhook, where
the type is fixed by the operator.

## 5. Routing rules

`NotifyRule` grows, backwards compatible (every new field is omitempty and
the zero value reproduces today's behaviour):

```go
type NotifyRule struct {
    ID            string   `json:"id"`
    Name          string   `json:"name"`
    EventTypes    []string `json:"event_types,omitempty"`   // exact, "*", or trailing-glob "ssh.*"
    MinSeverity   string   `json:"min_severity,omitempty"`  // drop events below it
    SourceKinds   []string `json:"source_kinds,omitempty"`  // e.g. ["plugin"]
    SubjectIDs    []string `json:"subject_ids,omitempty"`   // e.g. specific node ids
    ChannelIDs    []string `json:"channel_ids,omitempty"`
    TitleTemplate string   `json:"title_template,omitempty"`
    BodyTemplate  string   `json:"body_template,omitempty"`
    Severity      string   `json:"severity,omitempty"`      // override for this rule's sends
    RateLimit     *NotifyRateLimit `json:"rate_limit,omitempty"`
    Suppress      string   `json:"suppress,omitempty"`      // dedupe window, e.g. "10m"
    Enabled       bool     `json:"enabled"`
    CreatedAt     time.Time `json:"created_at"`
    UpdatedAt     time.Time `json:"updated_at"`
}

type NotifyRateLimit struct {
    PerMinute int `json:"per_minute"` // sustained
    Burst     int `json:"burst"`
}
```

Matching: a rule matches when the type matches (exact, `*`, or a
trailing-glob such as `plugin.latticenet.sub-store.*`), the severity is at or
above `min_severity`, the source kind is listed or the list is empty, and the
subject id is listed or the list is empty. All matching rules fire, as today;
there is no first-match precedence, because two rules that both want an event
is the common case (phone plus Discord).

Suppression: within `suppress` of the last send for the same
`(rule, dedupe_key)`, the delivery is recorded with outcome `suppressed` and
not sent. The window is per rule so a Discord log rule can keep everything
while the Bark rule keeps only the first of a flap.

Rate limit: per rule, the `ratelimit` package already in the server
(`server.go:518-536`). Over budget records outcome `rate_limited`. The
default when the block is absent is no limit, preserving today's behaviour;
the console suggests 30 a minute for phone channels.

Severity override: a rule may pin the severity its channels see (for
example send `ssh.login` as info to Discord but do not send it to Bark at
all). The channel derives Bark level from the effective severity unless the
channel's own `level` is set, in which case the channel wins; that keeps
today's channel-level configuration meaningful.

With zero rules the planner keeps sending every event to every enabled
channel, but the console shows a standing banner naming that state, and the
first rule the operator creates ends it. That matches the a88 webhook UX
("no rule matches this event" hint) and avoids a silent behaviour change on
upgrade.

## 6. Delivery: channels, retries, receipts

Outbox. The per-webhook ring becomes one bounded store collection:

```go
type NotifyDelivery struct {
    ID        string    `json:"id"`          // nd_<id>
    EventID   string    `json:"event_id"`
    EventType string    `json:"event_type"`
    Source    model.NotifySource `json:"source"`
    RuleID    string    `json:"rule_id,omitempty"`   // empty for the zero-rules fan-out
    Target    NotifyTarget `json:"target"`           // channel or plugin subscriber
    Outcome   string    `json:"outcome"`  // planned | sent | failed | suppressed | rate_limited | no_route | rejected
    Reason    string    `json:"reason,omitempty"`    // server-chosen strings only
    Attempts  int       `json:"attempts"`
    NextAttemptAt time.Time `json:"next_attempt_at,omitzero"`
    Title     string    `json:"title,omitempty"`
    Body      string    `json:"body,omitempty"`
    Test      bool      `json:"test,omitempty"`
    CreatedAt time.Time `json:"created_at"`
    SettledAt time.Time `json:"settled_at,omitzero"`
}

type NotifyTarget struct {
    Kind string `json:"kind"` // channel | plugin
    ID   string `json:"id"`
}
```

Bounds: 1000 deliveries globally, oldest evicted, plus the event record
itself (500 events). Events and deliveries live in the JSON state like the
webhook ring does; they are operational history, not the evidence record.
The audit stream stays the evidence record and keeps its synchronous
`notify.*` events.

Retries. A send fails transiently when the client returns a network error, a
5xx, or a 429; it fails permanently on any other 4xx (bad key, bad chat id)
and on a channel build error. Transient failures retry at 5 s, 30 s and 2 min
(three attempts total) from a single goroutine that drains
`next_attempt_at`, with the same 15 s per-send context as today. Permanent
failures settle immediately with the upstream status in `reason`. No retry
for plugin subscriber targets beyond one re-invoke (section 7), because a
plugin handler that fails twice is a plugin bug, not a network condition.

Channel health. Each channel gains `LastOKAt`, `LastError`,
`ConsecutiveFailures` in its stored record (not in config, so not encrypted
and returned by `notifyChannelView`). After three consecutive permanent
failures the server emits `notify.channel_failing` with subject
`{channel, id}`, once per hour at most. That event is routed like any other,
so a dead Bark channel can reach Discord. The console shows health in the
channel list.

Receipts. `GET /api/notify/deliveries?event_id=&source=&target=&outcome=&limit=`
returns the outbox; `GET /api/notify/events?type=&subject=&limit=` returns
events with their delivery counts. The webhook deliveries route becomes a
filter over the same store. An outbound webhook channel receives the full
envelope:

```json
{
  "id": "evt_...", "type": "service.down", "severity": "critical",
  "source": {"kind": "server"}, "subject": {"kind": "node", "id": "node_...", "label": "legend-sg"},
  "title": "...", "body": "...", "fields": {}, "dedupe_key": "...",
  "occurred_at": "...", "delivery_id": "nd_..."
}
```

with headers `X-Lattice-Event-Id`, `X-Lattice-Delivery-Id` and
`X-Lattice-Signature: sha256=<hmac>` over the body using a per-channel
secret the operator sets in the channel config (already encrypted at rest).
The legacy `{title, body}` shape is kept when the channel config sets
`format: legacy`, default for channels created before this ships.

Test sends record a delivery with `test: true`, so the console's "Send test"
is visible in the same list and the operator does not need to re-enter a
saved channel's key to see whether it still works: `POST /api/notify/test`
gains an optional `channel_id` that tests the stored channel server-side
without returning its config.

## 7. The SDK capability "notify"

Today `notify:send` is one capability with one method. This design replaces
it with a capability family and a manifest block.

### 7.1 Scopes

- `notify:emit`: the plugin may raise events under its own namespace
  `plugin.<plugin_id>.`. Risk class stays `RiskWrite` (as `notify:send` is,
  `internal/plugin/plugin.go:98`): the plugin can put words on the
  operator's phone but only through rules the operator wrote.
- `notify:subscribe`: the plugin may receive events. Risk class `RiskHost`,
  listed in `hostRiskExemptForNonSystem` alongside `http:egress`, so a signed
  third-party wasm plugin may declare it, an unsigned one may not. The reason
  it is host-risk: a subscriber to `ssh.compromise_suspected` learns node
  ids, usernames and source addresses, which is fleet data a plugin would
  otherwise need `node:read` to see.

`notify:send` remains accepted by the loader and broker as an alias of
`notify:emit` for one release cycle, mapped in one place
(`manifest.go` constant plus a broker alias table), then removed. The
sub-store plugin is the only shipped user of `notify:send` and is re-pinned
in the same slice.

### 7.2 Manifest declaration

```json
{
  "schema": "lattice.plugin.manifest.v2",
  "id": "latticenet.sub-store",
  "type": "system",
  "publisher": "latticenet",
  "capabilities": ["kv:read", "kv:write", "http:egress", "notify:emit", "notify:subscribe"],
  "notify": {
    "emits": [
      {"name": "sync_failed", "severity": "warning", "subject": "plugin",
       "description": "The automatic Sub-Store import failed"},
      {"name": "share_expiring", "severity": "notice", "subject": "user",
       "description": "A subscription share expires within 7 days"}
    ],
    "subscribes": [
      {"types": ["node.offline", "node.online", "service.down", "service.recovered"],
       "method": "on_event"},
      {"types": ["schedule.daily_summary"], "method": "on_schedule"}
    ]
  }
}
```

The `notify` block is decoded strictly like the rest of the manifest
(`DecodeManifest`, `manifest.go:81-88`). Rules:

- `emits[].name` obeys the type grammar without dots; the server-visible type
  is `plugin.<id>.<name>`. A plugin may not emit a name it did not declare.
  At most 32 declared types.
- `subscribes[].types` may name server types, `schedule.*` types, the
  plugin's own types, and other plugins' types only when the other plugin
  lists this one under a new `notify.exposes_to` list (mirrors the RPC
  directed allow-list, `design-09` section F). `*` is not accepted in a
  subscription.
- `subscribes[].method` names a runtime method the plugin's artifact answers
  under the existing stdio-json-v1 protocol. The server invokes it
  fork-per-call with the event JSON as params, the same way it invokes
  interface methods, and treats a non-zero exit or an error response as one
  failed delivery. Bridge and UI plugins cannot subscribe; subscription is a
  runtime concern.
- A manifest that declares `notify` without the matching capability, or the
  capability without the block, fails `VerifyManifest`.

### 7.3 Host methods

`notify.emit` replaces `notify.send`:

```json
{"method": "notify.emit", "params": {
  "name": "sync_failed", "severity": "warning",
  "subject": {"kind": "plugin"},
  "title": "Sub-Store auto-sync failed",
  "body": "The automatic import failed. Review the audit log and retry.",
  "fields": {"attempt": "3"},
  "dedupe_key": "sync"
}}
```

Broker: `require(ctx, "notify.emit", capNotifyEmit)`, then the grant check
(section 8), then `services.Notify.Emit(ctx, pluginID, req)`; the host
prefixes the type and calls `s.emit`. The response carries `event_id` and
the number of planned deliveries, so a plugin can log "raised, routed to 0
channels" instead of believing it alerted someone. `notify.send` keeps
working through the alias as `notify.emit` with name `message`, severity
notice, subject plugin; the server auto-registers `message` in the
catalogue for any plugin holding the legacy capability.

`HostClient` gains `NotifyEmit(ctx, NotifyEmitRequest) (NotifyEmitResult, error)`
and keeps `NotifySend` as a thin wrapper marked deprecated.

The host-side interface widens from `NotifyHost{Send}` (`broker.go:140-142`)
to `NotifyHost{Emit; Send}` with `Send` implemented by `Emit`.

`on_event` is a plugin-side method, not a host method: the server calls in.
Delivery is at-least-once with one retry after 30 s, bounded to 60 queued
events per plugin (oldest dropped and recorded as `failed` with reason
`subscriber backlog`), and rate limited to 60 invocations a minute per
plugin. The plugin sees the event envelope from section 6 minus anything
the operator marked private: channel information never reaches a plugin,
and `fields` from an inbound webhook are included only when the webhook's
`share_fields_with_plugins` flag is on (default off), because webhook fields
are caller-supplied text the operator may not want a third-party plugin to
read.

### 7.4 Audit

Every host call already lands as `plugin.host.<action>` with capability,
decision and reason (`plugin_host.go:287-300`). Emit adds `event_id` and
`event_type` to metadata; a refused emit says which of the three gates
refused (capability, catalogue, grant). Subscriber invocations are audited as
`plugin.host.notify.deliver` with delivery id and outcome.

## 8. The permission environment

Three layers, each answerable in the console.

Layer 1, manifest and trust policy (exists). The plugin declares
capabilities; the loader admits them under the trust policy
(`loader.go:186-189`, `VerifyManifest`); the broker checks the capability on
every call and audits it. This is the container boundary: what a plugin can
ask for at all.

Layer 2, per event type, operator approved (new). At activation the server
derives one `NotifyGrant` per declared emit name and per subscription type:

```go
type NotifyGrant struct {
    ID         string    `json:"id"`
    PluginID   string    `json:"plugin_id"`
    Direction  string    `json:"direction"`   // emit | subscribe
    EventType  string    `json:"event_type"`  // full type
    Status     string    `json:"status"`      // pending | approved | revoked
    Limit      *NotifyRateLimit `json:"limit,omitempty"` // per grant; default 30/min burst 10 for emit
    ApprovedBy string    `json:"approved_by,omitempty"`
    ApprovedAt time.Time `json:"approved_at,omitzero"`
    ManifestVersion string `json:"manifest_version"` // grant is void when the plugin's version changes the block
}
```

A grant is standing, not one-shot, so it is its own record rather than an
`Approval` (`model.go:1381-1409`), which is node-bound and per operation.
The console lists pending grants on the plugin's page and on
/platform/notifications under a Plugins tab; approving is
`POST /api/notify/grants/approve {id}` behind the admin scope. An emit or a
subscription for a type whose grant is not approved is refused (emit) or
skipped (subscribe) with an audited deny naming the grant, and the console
shows the count of refused emits per plugin so a plugin whose operator
forgot to approve is visible rather than silent.

Re-approval: a plugin upgrade whose manifest changes the `notify` block voids
the grants for the changed entries (compared by name and severity) and mints
new pending ones; unchanged entries keep their approval. This mirrors how an
operation approval is bound to artifact digest and request hash.

Default for the legacy alias: when the server first boots with this design,
every active plugin holding `notify:send` gets an approved grant for
`plugin.<id>.message` with an audit event `notify.grant.migrate`, so
Sub-Store keeps working across the upgrade. Every new name requires a human.

Layer 3, operator routing (exists, extended). Even an approved emit reaches a
phone only through a rule. Rules may filter on `source_kinds: ["plugin"]` or
a plugin's glob, so the operator can keep all plugin chatter on Discord and
away from Bark with one rule.

Operator scopes. The existing flat `notify:send` is split into:

- `notify:emit`: `POST /api/notify/events` only (token-raised events).
- `notify:read`: catalogue, events, deliveries, channel list without config.
- `notify:admin`: channels, rules, webhooks, schedules, grants, test.

`withAuth("notify:send", ...)` becomes `withAuth("notify:admin", ...)` on the
administration routes, with `notify:send` accepted as an alias of all three
for one release and a console banner on tokens that still carry it. This is
the trust-contract change PROGRAM.md reserves for the operator; the design
lists it as decision D4 and the migration does not depend on it (the alias
makes the split additive). `refuseConfinedFleetWrite` stays on every write.

Plugins never hold operator scopes; their `notify:emit` capability and the
operator's `notify:emit` scope share a name because they mean the same
thing at two boundaries, and the audit action prefix (`plugin.host.` versus
`notify.`) tells them apart.

## 9. Two flows

### 9.1 A node's ssh.compromise_suspected reaching the operator's Bark

```
node agent            lattice-server                                    bark.roobli.org      phone
   |                        |                                                 |               |
   | POST /api/agent/event  |                                                 |               |
   | kind=ssh_pressure      |                                                 |               |
   |----------------------->| authenticateAgentRequest (node token)           |               |
   |                        | handleSSHPressure: clamp, record window         |               |
   |                        | suspect success found                           |               |
   |                        | emit(Event{                                     |               |
   |                        |   type: ssh.compromise_suspected                |               |
   |                        |   severity: critical                            |               |
   |                        |   source: {node, node_abc}                      |               |
   |                        |   subject: {node, node_abc, "legend-sg"}        |               |
   |                        |   fields: {user, address, method, prior}        |               |
   |                        |   dedupe: type|node|node_abc })                 |               |
   |                        | store event evt_1                               |               |
   |                        | plan: rule "phone-critical"                     |               |
   |                        |   types [ssh.compromise_suspected, service.down]|               |
   |                        |   min_severity warning, suppress 10m            |               |
   |                        |   channels [bark-main]                          |               |
   |                        | suppression: no send for this key in 10m -> ok  |               |
   |                        | rate: 30/min budget ok                          |               |
   |                        | render title/body over fields                   |               |
   |                        | store delivery nd_1 planned                     |               |
   | 200 {ok}               |                                                 |               |
   |<-----------------------|                                                 |               |
   |                        | audit ssh.compromise_suspected (sync)           |               |
   |                        |                                                 |               |
   |                        | go: Bark.Send level=critical group=lattice      |               |
   |                        |   POST /push {device_key, title, body, level}   |               |
   |                        |------------------------------------------------>|               |
   |                        |                                                 | APNs critical |
   |                        |                                                 |-------------->|
   |                        | 200                                             |               |
   |                        |<------------------------------------------------|               |
   |                        | settle nd_1 sent, channel bark-main last_ok_at  |               |
   |                        | audit plugin? no. audit notify.deliver (async)  |               |
   |                        |                                                 |               |
   | (same node, 2 min later, second suspect success)                         |               |
   |----------------------->| emit evt_2, same dedupe key                     |               |
   |                        | rule suppress 10m -> nd_2 suppressed            |               |
   |                        | (visible in /api/notify/deliveries, no push)    |               |
```

If the Bark server answers 502, nd_1 is retried at 5 s, 30 s and 2 min, then
settles `failed` with reason `upstream status 502`; a third such failure in a
row raises `notify.channel_failing` for bark-main, which a second rule sends
to Discord. If no rule matches, nd_1 is written as `no_route` and the event
list shows it in red, which is the state production is in today.

### 9.2 A plugin-originated flow: Sub-Store raises sync_failed, vpn-core consumes service.down

```
sub-store runtime        broker (plugin)         lattice-server               vpn-core runtime
       |                       |                       |                             |
       | notify.emit           |                       |                             |
       |  name=sync_failed     |                       |                             |
       |  severity=warning     |                       |                             |
       |---------------------->| require(notify.emit,  |                             |
       |                       |   notify:emit) allow  |                             |
       |                       | audit plugin.host.    |                             |
       |                       |   notify.emit allow   |                             |
       |                       |---------------------->| grant lookup:               |
       |                       |                       |  plugin.latticenet.sub-store|
       |                       |                       |  .sync_failed emit approved |
       |                       |                       | limit 30/min ok             |
       |                       |                       | emit(Event{ type prefixed,  |
       |                       |                       |   source {plugin, id} })    |
       |                       |                       | plan: rule "plugins-to-     |
       |                       |                       |   discord" source_kinds     |
       |                       |                       |   [plugin] -> discord-ops   |
       |                       |                       | rule "phone-critical" does  |
       |                       |                       |   not match (warning<crit)  |
       |                       |                       | delivery nd_7 planned       |
       |                       |<----------------------| {event_id, deliveries: 1}   |
       |<----------------------|                       |                             |
       | exit 0                |                       | go: Discord.Send -> settle  |
       |                       |                       |                             |
   (later, the liveness sweep finds sing-box dead on node_x)                         |
       |                       |                       | emit service.down critical  |
       |                       |                       | subject {node, node_x}      |
       |                       |                       | plan channels: bark-main    |
       |                       |                       | plan subscribers:           |
       |                       |                       |  grant vpn-core subscribe   |
       |                       |                       |  service.down approved      |
       |                       |                       | delivery nd_8 target        |
       |                       |                       |  {plugin, latticenet.       |
       |                       |                       |   vpn-core} planned         |
       |                       |                       | fork runtime, method        |
       |                       |                       |  on_event, params=envelope  |
       |                       |                       |  (no channel info)          |
       |                       |                       |---------------------------->|
       |                       |                       |    marks the node's lines   |
       |                       |                       |    unhealthy via its own    |
       |                       |                       |    interface; may itself    |
       |                       |                       |    notify.emit              |
       |                       |                       |    lines_withdrawn (notice) |
       |                       |                       |<----------------------------|
       |                       |                       | settle nd_8 sent; audit     |
       |                       |                       |  plugin.host.notify.deliver |
```

The second half shows why subscription is host-risk and grant-gated: the
envelope carries the node id and label, and the plugin acts on it. It also
shows the loop guard: a subscriber's own emit produces a new event with a
new dedupe key and a depth counter in `CorrelationID`; the server refuses to
deliver an event to the plugin whose emit produced it and caps the chain at
three hops, so two plugins subscribed to each other's types cannot ping-pong.

## 10. Migration

Order chosen so each slice ships alone, nothing changes behaviour for an
operator who does nothing, and the SDK contract change lands once.

Slice A, typed emitters and catalogue (server only, no contract change).
Introduce `NotifyEvent` in the SDK model as a pure addition, `emit` in the
server, the catalogue file and test, rewrite every emitter call site,
delete `classifyNotifyEvent`. Rules editor reads the catalogue.
`planNotifyDeliveries` takes the event; templates gain the new variables.
Existing rules keep matching because types for the previously typed events
do not change; `node.offline`, `auth.2fa_limit` and `substore.sync_failed`
stop being `generic`, which is the one visible change and is called out in
the release note. SDK pin bump for the model addition only.

Slice B, outbox, retries, channel health, receipts. Generalise the webhook
ring into the outbox and re-point the webhook deliveries route. Add the
retry drainer, channel health fields, `GET /api/notify/events` and
`/deliveries`, the stored-channel test. Console: deliveries list on
/platform/notifications, health on the channel list, red no_route rows.

Slice C, rule extensions. Severity, min_severity, source and subject
filters, suppression, rate limit, severity override, trailing glob. Console
rule editor. Zero-rules banner.

Slice D, plugin emit through rules (SDK contract change). `notify:emit`,
manifest `notify.emits`, `notify.emit` host method, alias for `notify:send`
and `notify.send`, `pluginHost.Send` rewritten to build the legacy event and
call `emit` (this is the line that closes the bypass,
`plugin_host.go:216-240`). Grant record, derivation at activation, approve
route, migration grant for `message`. Sub-store manifest and pin updated in
the same slice under an SDK prerelease tag. Console: grants tab.

Slice E, subscribe and schedules. `notify:subscribe`, manifest
`notify.subscribes`, subscriber delivery through the runtime, loop guard,
`NotifySchedule` record and sweep hook, schedules editor. Token-raised
events route.

Decision D4 (operator scope split) can be applied at any slice boundary
because of the alias; it is not in the critical path.

What is removed at the end: `classifyNotifyEvent`, `notifyEvent`,
`emitNotify`, `emitNotifyTyped`, the per-webhook ring, `NotifyHost.Send`,
`HostMethodNotifySend` (after the alias window), free-text event types in
the rules editor.

## 11. Decisions reserved for the operator

- D1: approve the plugin type namespace rule (server prefixes
  `plugin.<id>.`) and the grant-per-type model. Alternative considered:
  trust the manifest alone, as every other capability does today. Rejected
  because an emit puts text on the phone and a subscription reads fleet
  facts; both deserve the per-type look the operator already gives per-node
  operations.
- D2: `notify:subscribe` classified host-risk with the egress-style
  exemption (signed third-party may declare). Alternative: system-only.
  Chosen exemption because the payload is bounded and the grant is per type.
- D3: the migration grant auto-approves `plugin.<id>.message` for plugins
  already holding `notify:send` at upgrade. Alternative: leave them pending
  and let Sub-Store's failure notification go silent until approved.
  Rejected: the upgrade must not remove an alert that works today.
- D4: split `notify:send` into `notify:emit`, `notify:read`,
  `notify:admin`. Additive through the alias; the operator decides when the
  alias goes.
- D5: outbox bounds (500 events, 1000 deliveries) and retry schedule
  (5 s, 30 s, 2 min). Defaults, not contract.
- D6: whether token-raised events (`POST /api/notify/events`) ship in slice
  E or wait until a concrete external system needs it. Inbound webhooks cover
  the known cases today.

## 12. Acceptance checklist

Slice A

- [ ] Every `emitNotify` call site is gone; `grep -rn "emitNotify\b\|classifyNotifyEvent" internal/server` returns only tests, then nothing.
- [ ] `GET /api/notify/catalogue` lists every type in section 3 with severity and subject kind; a unit test fails when a server emitter uses a type absent from the catalogue.
- [ ] A rule with `event_types: ["node.offline"]` receives the offline sweep event; before this slice the same rule receives nothing (regression test written first).
- [ ] Existing rules and webhook templates render identically for `event_type`, `title`, `body`, `data.<k>`.

Slice B

- [ ] `GET /api/notify/deliveries` shows one row per (event, target) with outcome; a Bark send against a server answering 502 shows attempts 3 and outcome failed with reason `upstream status 502`; a 401 shows attempts 1.
- [ ] `/api/notify/webhooks/deliveries` returns the same rows it did before, sourced from the outbox.
- [ ] A channel with three consecutive permanent failures shows `consecutive_failures: 3` in the channel view and one `notify.channel_failing` event exists.
- [ ] `POST /api/notify/test {channel_id}` sends without the caller supplying config, and `config` is absent from every response body (existing secret-free invariant test extended).

Slice C

- [ ] Two events with the same dedupe key inside a rule's `suppress` window produce one `sent` and one `suppressed` delivery.
- [ ] A rule with `min_severity: warning` does not send `ssh.login` (notice) and does send `ssh.compromise_suspected` (critical).
- [ ] Bark receives `level: critical` for a critical event on a channel with no `level` configured, and the channel's configured level when set.
- [ ] Console rule editor offers catalogue types, glob entry, severity, suppress and rate limit; the zero-rules banner appears and disappears.

Slice D

- [ ] A plugin calling `notify.emit` with an undeclared name is refused; audit shows `plugin.host.notify.emit deny` with reason naming the catalogue gate.
- [ ] A declared name with a pending grant is refused with reason naming the grant; after `POST /api/notify/grants/approve` the same call succeeds and the event type is `plugin.<id>.<name>`.
- [ ] A plugin emit reaches only channels selected by a matching rule; with a rule `source_kinds: ["plugin"]` to Discord and no other match, Bark receives nothing (this is the test that proves `pluginHost.Send` no longer fans out).
- [ ] The sub-store plugin built against the previous SDK, calling `notify.send`, still delivers through the migration grant and shows type `plugin.latticenet.sub-store.message`.
- [ ] Upgrading a plugin whose manifest renames an emit voids the old grant and mints a pending one; unchanged entries stay approved.

Slice E

- [ ] A plugin subscribed to `service.down` with an approved grant has its `on_event` invoked with the envelope, and the envelope contains no channel ids, kinds or config.
- [ ] A subscriber that exits non-zero is retried once after 30 s, then the delivery settles failed; 61 queued events for one plugin drop the oldest with reason `subscriber backlog`.
- [ ] Two plugins subscribed to each other's emits stop after three hops; audit shows the refused fourth hop.
- [ ] A schedule with `daily_at_utc: "08:00"` emits `schedule.<name>` once per day (clock-injected test) and the Bark delivery row exists.
- [ ] An inbound webhook's fields reach a subscriber only when `share_fields_with_plugins` is true.

Cross-cutting

- [ ] No route under `/api/notify/` is reachable with a confined token for writes (existing `refuseConfinedFleetWrite` tests extended to grants, schedules, events).
- [ ] `go test ./... -race -timeout 20m` in lattice-server passes; `go clean -cache -testcache` after.
- [ ] Dashboard renders /platform/notifications at 1440 and 375 with the deliveries list, grants tab and a rule with every new field, driven against a local server with one Bark channel pointed at a stub.
- [ ] PROGRAM.md notifications section and the vault note
  `设计与方案/2026_09_04_通知抽象与SDK能力设计.md` point at this document and
  record D1 to D6 once decided.
