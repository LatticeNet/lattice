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
- Send errors carry the channel credential and are not redacted anywhere.
  Every channel builds an endpoint that embeds its own secret: Telegram is
  `<base>/bot<token>/sendMessage` (`notify.go:107`), Discord posts the raw
  webhook URL (`notify.go:194`), the generic webhook posts its URL
  (`notify.go:215`), and the Bark fallback path is `<base>/<device_key>/...`
  (`notify.go:172`). `client.Do` returns a `*url.Error` whose `Error()`
  embeds that full URL, and `doRequestStatus` folds up to 2048 bytes of the
  upstream response body into its own error (`notify.go:80-81`). Two
  consequences today: `notifyEventTyped` writes the string to the server log,
  and `pluginHost.Send` joins it into the error it returns
  (`plugin_host.go:232-238`), which the broker passes through
  (`broker.go:647-656`) and the runner hands to the plugin verbatim as
  `systemHostResponse{OK:false, Error: err.Error()}`
  (`system_runner.go:1504-1507`). A plugin holding `notify:send` can
  therefore read the operator's bot token by provoking one failed send. This
  design closes that at the boundary (section 6) and the closure is a
  slice-B acceptance item, not a later cleanup.
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

The plugin namespace can outgrow that ceiling, so the composite is bounded
where the manifest is verified, not where the event is emitted.
`validPluginID` admits ids up to 128 bytes
(`internal/plugin/plugin.go:444-447`) while the type caps at 64, and the
composite is `len("plugin.") + len(id) + 1 + len(name)`. An id of 45 bytes,
well inside what `validPluginID` allows, plus the 14-byte name
`share_expiring` gives a 67-byte type that the grammar refuses. Checking
that only at emit time is the wrong boundary: the manifest would verify, the
console would show a pending grant, the operator would approve it, and every
`notify.emit` would then be refused by type validation with a message naming
neither the plugin nor the ceiling, while the rules editor could not even
reference the type. Section 7.2 puts the check in the manifest rules so it
fails at load with the ceiling in the message.

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

Paired transitions are exempt, and this is load-bearing rather than a
refinement. The default dedupe key is type plus subject, so `service.down`
and `service.recovered` are different keys and a window opened by one does
not close on the other. The emitters are already transition-guarded
(`notifyMonitorTransition`, `server.go:5157-5176`; the `notifyDown` and
`notifyRecovered` flags at `server_singbox_liveness.go:136-142`), so a
second `down` inside the window is a genuine state change, not a repeat.
Without an exemption a 10 minute suppress on a phone rule produces this:
sing-box drops at 12:00 and pushes "service down", recovers at 12:02 and
pushes "service recovered", drops again at 12:05 and is suppressed, recovers
at 12:08 and is suppressed. Between 12:05 and 12:12 the service is down and
the last message on the operator's phone says it recovered. The deliveries
list holds the truth and the alert channel is actively misleading, which is
worse than no alert.

The rule: the catalogue marks a type as a transition type and names its
pair (`service.down` with `service.recovered`, `monitor.down` with
`monitor.recovered`, `node.offline` with `node.online`). A transition type
is never suppressed, and firing either half clears any suppression window
held on the same `(rule, subject)` for the other half. Suppression stays in
force for repeating types that carry no state flip, which is what it was
written for: quota, expiry, renewal, `ssh.login`, plugin chatter. A rule may
not opt a transition type back into suppression; an operator who wants less
noise from a flapping service uses the rate limit, which drops sends without
inverting the last known state.

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

Storage. Events and deliveries go on the record-level bolt path, not in the
JSON state, and this is a requirement of the design rather than an
implementation detail. `Store.persistState` re-encrypts the whole state,
marshals it indented, atomically writes and fsyncs it on every mutation
(`store/store.go:1029-1062`), so a domain that lives in the JSON state pays
a full state rewrite per write. The store has been moving hot, high-churn
domains off that path for exactly this reason: audit, sessions, proxy users
and profiles, usage, node status events, subscription shares and snapshots,
KV and static are all cleared in `jsonPersistStateFrom`, each with a comment
naming the cost (`store/store.go:1064-1098`).

The webhook ring gets away with the JSON state because an accepted webhook
fire is capped at 10 a minute per webhook (`server.go:528-530`).
Server-originated events have no such cap, and the write amplification is
worse than one per event: every delivery is written at least twice (planned,
then settled) and again per retry attempt. One offline sweep marking 30
nodes (`server_inventory.go:833`) against three enabled channels and one
matching rule is 30 event writes plus 90 planned writes plus 90 settle
writes, each a full encrypt, marshal, write and fsync of the entire state
file under the store mutex, with agent polls and console reads queued behind
it, and the retry drainer repeating the burst at 5 s, 30 s and 2 min. That
is not acceptable on the hot path of every fleet event.

So: a `notify_events` bucket and a `notify_deliveries` bucket on the
record-level path, both cleared in `jsonPersistStateFrom` alongside the
existing exclusions, with the same per-record read and write shape the
audit stream uses. The settle path updates one record rather than rewriting
the state. Slice B carries the migration of the existing per-webhook ring
into the delivery bucket, and the slice does not land until a benchmark
shows the 30-node sweep costs a bounded number of record writes and zero
full-state writes.

Bounds and retention. 1000 deliveries and 500 events globally, oldest
evicted, with a per-source floor: eviction never takes a source's most
recent 50 deliveries while any other source has more than 50. Without that
floor the design would quietly weaken a guarantee that exists today.
`maxNotifyWebhookDeliveries = 50` is per webhook (`store/notify_webhook.go:108-113`),
so each webhook has its own guaranteed window of 50 attempts; under a bare
global cap that becomes "whatever survived eviction by every other source",
and a once-a-day backup webhook would show an empty history after a fleet
incident produced a few hundred `node.offline` and `service.down`
deliveries, which is precisely the question the ring exists to answer. The
floor keeps the old guarantee as a floor and the global cap as a ceiling;
the operator-visible statement is "at least the last 50 attempts per source,
up to 1000 in total".

These are operational history, not the evidence record. The audit stream
stays the evidence record and keeps its synchronous `notify.*` events.

Retries. A send fails transiently when the client returns a network error, a
5xx, or a 429; it fails permanently on any other 4xx (bad key, bad chat id)
and on a channel build error. Transient failures retry at 5 s, 30 s and 2 min
(three attempts total) from a single goroutine that drains
`next_attempt_at`, with the same 15 s per-send context as today. Permanent
failures settle immediately with the upstream status in `reason`. No retry
for plugin subscriber targets beyond one re-invoke (section 7), because a
plugin handler that fails twice is a plugin bug, not a network condition.

Channel health. Each channel gains `LastOKAt`, `LastFailureKind`,
`LastStatusCode` and `ConsecutiveFailures` in its stored record (not in
config, so not encrypted and returned by `notifyChannelView`).

The stored failure is a server-classified enum plus a status code, never the
transport error string. This is a hard rule, not a preference. As section 1
records, every channel error embeds the channel credential in a URL and may
embed 2048 bytes of upstream response body. `NotifyChannel.Config` is the
one notify record that passes through `crypto.go` (`store/store.go:86-91`,
`store/crypto.go:141-149`), so a `LastError` field placed beside it would be
written to the state file in cleartext, into every backup of it, and then
returned by `notifyChannelView`, a projection whose whole point is to be
secret-free. The existing secret-free invariant test would not catch it: it
asserts that `config` is absent from the response, not that no other field
carries a secret. The upstream body half is separately disqualifying,
because it is remote-controlled text landing in an operator console field;
the webhook design already reserves its `Reason` for "fixed strings chosen
by this server, so that a hostile caller cannot write into the console
through it" (`store/notify_webhook.go:86-89`), and the same reservation
applies here and to the outbox `Reason`.

Concretely, `LastFailureKind` is one of `network`, `timeout`,
`upstream_4xx`, `upstream_5xx`, `rate_limited`, `config_invalid`,
`unknown`, chosen by the same classifier that decides transient versus
permanent for retries, and `LastStatusCode` is the HTTP status when there is
one and zero otherwise. Those two answer "why is this channel red" without
carrying a secret or a remote string, and the console composes the sentence
itself. The transport error is logged at debug level on the server and never
persisted, never returned by an API, and never returned to a plugin: the
same redaction applies to the error `notify.emit` hands back across the host
boundary, which today leaks the token (section 1). A single
`redactSendError(err) (kind string, status int)` helper is the only place
allowed to look at the raw error, and a unit test feeds it a `*url.Error`
built from a Telegram endpoint with a fake token and asserts the token
appears in nothing it returns.

After three consecutive permanent failures the server emits
`notify.channel_failing` with subject `{channel, id}`, once per hour at
most. That event is routed like any other, so a dead Bark channel can reach
Discord. The console shows health in the channel list.

Receipts. `GET /api/notify/deliveries?event_id=&source=&target=&outcome=&limit=`
returns the outbox; `GET /api/notify/events?type=&subject=&limit=` returns
events with their delivery counts. The webhook deliveries route becomes a
filter over the same store.

Both new routes are confinement-guarded on the read side, not only on the
write side. The server already refuses a node-restricted principal on the
notify read surface: `refuseConfinedWebhookRead`
(`server_notify_webhook.go:118-146`) guards both the webhook list
(`server_notify_webhook.go:156`) and the webhook deliveries route
(`server_notify_webhook.go:307`), on the stated grounds that delivery
history exposes the rendered message content and the external caller
addresses and that a webhook has no node field to filter on. This design
generalises that history into a fleet-wide store and would otherwise drop
the guard, which is a straight regression: a node-confined token holding
`notify:read` could ask `GET /api/notify/events?limit=200` and get
`ssh.compromise_suspected` and `ssh.login` events for every node in the
fleet, with subject labels, usernames and source addresses in `fields`,
plus the rendered body of every webhook delivery. Re-pointing
`/api/notify/webhooks/deliveries` at the same store would also leave a
guarded route and an unguarded route serving the same rows.

So `refuseConfinedWebhookRead` is renamed `refuseConfinedNotifyRead`, its
doc comment is rewritten to speak about notify history rather than webhooks
specifically, and it is applied to `GET /api/notify/events`, `GET
/api/notify/deliveries`, the channel list and the catalogue, in addition to
the two routes it already guards. The same rule holds during the
`notify:send` alias window, when a confined token may still reach these
routes under the old scope name. Events and deliveries are fleet-wide
objects with no node to confine them to, exactly as a webhook is; a filtered
per-node view is a separate design if the operator ever wants one, and it
would have to filter on `subject` rather than being bolted onto this route. An outbound webhook channel receives the full
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
- The composite type is bounded at manifest verification, not at emit.
  `VerifyManifest` refuses a manifest when
  `len("plugin.") + len(id) + 1 + len(name)` exceeds the 64 bytes
  `validateNotifyEventType` allows, for any declared emit name, with a
  message naming the offending name, the computed length and the ceiling
  (for example `notify.emits[1].name: type
  plugin.<id>.share_expiring is 67 bytes, the ceiling is 64; the plugin id
  leaves 12 bytes for a name`). The same check runs on
  `subscribes[].types` entries that name the plugin's own namespace. This is
  a load-time refusal so that no unemittable grant is ever minted.
- `subscribes[].types` may name server types, `schedule.*` types, the
  plugin's own types, and other plugins' types only when the other plugin
  lists this one under a new `notify.exposes_to` list (mirrors the RPC
  directed allow-list, `design-09` section F). `*` is not accepted in a
  subscription.
- `subscribes[].method` names a runtime method the plugin's artifact answers
  under the runtime protocol it already speaks. Delivery goes through
  `RuntimeManager.InvokeConstrained` like every other call into a plugin,
  under a new action `notify.deliver`; the details of the budget and the
  failure accounting are in section 7.3, because getting them wrong breaks
  operator-initiated calls to the same plugin. Bridge and UI plugins cannot
  subscribe; subscription is a runtime concern.
- A manifest that declares `notify` without the matching capability, or the
  capability without the block, fails `VerifyManifest`.
- The `notify` block is covered by the signature. `SigningPayload`
  (`internal/plugin/plugin.go:328`) is an explicit field-by-field
  construction and the repo's convention is that every manifest field is in
  it: the `Dependencies` block carries the comment "Covered by the v2
  signing payload like every other field" (`plugin.go:49-52`). Adding
  `Notify` to both `Manifest` structs without adding it to `SigningPayload`
  produces a green test suite, because the coverage test is a hand-written
  mutation map (`internal/plugin/manifest_v2_test.go:259-301`), and the
  result would be a signed plugin whose notify block anyone with write
  access to the installed manifest, or a tampering mirror between publisher
  and install, can rewrite. That matters more here than for other blocks
  because the layer-2 grants are derived from this block's contents and
  voided on manifest change: outside the signature, the control that feeds
  them is forgeable. An attacker could append
  `subscribes: [{"types": ["ssh.compromise_suspected", "ssh.login"], ...}]`
  to a plugin that already declares `notify:subscribe`, `VerifyManifest`
  would still pass, and the operator would see what looks like a normal
  pending grant. So the implementation must add the block to
  `SigningPayload` in the same commit that adds the field, and add a
  `"notify"` entry to the mutation map in
  `TestSigningPayloadV2CoversTypedManifest` that changes a declared emit
  name and a subscribed type. This is a slice D acceptance item.

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

How it calls in has to be stated, because the runtime is not fork-per-call
and its two guards are shared with operator-initiated work. Runtime
invocation goes through `RuntimeManager.InvokeConstrained` with action
`call` and a `{service, method, payload}` body plus a budget derived from
the interface method contract (`server_plugin_invoke.go:430-449`). The
system runner keeps a persistent stdio-json-v2 worker pool sized
`Size: 1, MaxOverflow: 1` per generation (`internal/plugin/system_runner.go:40-46`)
and opens a circuit breaker after 5 consecutive failures that only an
operator disable and re-enable resets (`system_runner.go:48-51`). A
subscription names a bare method with no service, so it has no interface
contract and therefore no `InvokeBudgetSpec`. Left unspecified, a buggy
subscriber to `service.down` that exits non-zero five times during one
incident would trip the plugin's breaker, and the operator opening that
plugin's console view during the same incident would get "plugin circuit
breaker open" on every read with no recovery but a disable and re-enable.
Separately, a burst of deliveries would occupy the single pooled worker and
queue operator-initiated calls behind event traffic.

The design therefore fixes three things:

- Action. A subscriber delivery is `InvokeConstrained(ctx, pluginID,
  "notify.deliver", body, ...)` with body `{event, delivery_id, method}`,
  a distinct action from `call` so the audit, the metrics and the runner can
  tell event traffic from operator traffic.
- Budget. A fixed `InvokeBudgetSpec` for `notify.deliver`, not derived from
  any contract, with the conservative end of the defaults: `TimeoutMS`
  5000, `StdoutBytes` 256 KiB, `StderrBytes` 64 KiB, `HostCalls` 4. A
  subscriber handles an event; it does not run a workflow. A plugin that
  needs more work per event enqueues a task and returns.
- Failure accounting. A failed delivery is recorded on the delivery and on
  a per-plugin subscriber failure counter that feeds a `notify.grant`
  auto-suspend after 20 consecutive failures. It does not charge the runner
  crash counter that opens the shared circuit breaker, because that counter
  exists to protect the operator from a plugin that cannot start, not to
  punish a handler that returns an error. A delivery that fails because the
  worker could not start does charge it, as any invocation does.
- Fairness. Deliveries take at most one of the pool's two slots at a time
  per plugin, so an operator call is never starved by event traffic.

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
    ManifestDigest string `json:"manifest_digest"` // sha256 of SigningPayload at approval time
    BundleDigest   string `json:"bundle_digest"`   // Bundle.DigestSHA256 at approval time
    ManifestVersion string `json:"manifest_version,omitempty"` // display only, never compared
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
new pending ones; unchanged entries keep their approval.

The grant binds to content, not to a version string, and the distinction is
the whole point of the layer. An operation approval is bound to the artifact
digest and the request hash; a grant bound to `ManifestVersion` would be
weaker than the thing it is modelled on, because a version string is
publisher-chosen and this program reuses version strings routinely (the
sub-store `0.13.0-alpha` lane rebuilds under one version repeatedly).
Version equality does not imply block equality: a plugin re-published as
`0.13.0-alpha` with `sync_failed` promoted from warning to critical and a
new `subscribes` entry for `ssh.login` would compare equal, keep every
grant approved, and start putting critical-level pushes on the operator's
phone and reading `ssh.login` while no pending grant ever appears in the
console.

So a grant records the sha256 of `SigningPayload(manifest)` and the
`Bundle.DigestSHA256`, both already available and both covered by the
signature once the `notify` block is in the payload (section 7.2). A grant
whose stored manifest digest differs from the installed manifest's is not
honoured; the comparison that decides which grants survive is over the
decoded entries (name, severity, subject for an emit; the type set for a
subscription), and every surviving grant is re-stamped with the new digests
at that point. `ManifestVersion` is kept as a display field on the console
so the operator sees which version approved what, and it is never used in a
comparison.

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
makes the split additive). `refuseConfinedFleetWrite` stays on every write
and `refuseConfinedNotifyRead` on every fleet-wide read.

The split is not a server-route change. `notify:send` is hard-coded in four
more places and the slice is not done until all of them move together:

- `rbac.KnownScopes` (`internal/rbac/rbac.go:102-156`) is the authoritative
  allowlist the user-management API validates assignments against, and it
  contains only `notify:send`. Until the three new names are added there,
  none of them can be granted to anyone, so a token minted with
  `notify:admin` is rejected outright at assignment. This is the first
  change in the slice, not the last.
- The dashboard gates the whole Notifications and Webhooks navigation on
  `notify:send` (`lattice-dashboard/src/router/nav.ts:137,142`), so a token
  carrying only the new scopes would log in and find both entries missing
  from the sidebar: the surface the scope was created to administer would be
  unreachable. The views gate their controls the same way and
  `lattice-dashboard/src/lib/scopes.ts:202,266` documents the old scope in
  operator-facing text that becomes wrong.
- The Astra iOS client requests `notify:send` in its token scope set
  (`Astra/AstraApp/App/AccountView.swift:270`), so it keeps working only
  while the alias stands and must be updated before the alias is removed.

`ValidScope` already accepts a domain wildcard whose prefix matches a known
scope (`rbac.go:161-177`), so `notify:*` becomes grantable the moment the
three scopes are in `KnownScopes`. That is a cheaper migration lever than
the alias for an operator who wants one token that keeps working across the
split: mint `notify:*` rather than relying on the alias, and the alias
window can then be short. The alias stays for tokens already in the field.

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
settles `failed` with reason `upstream status 502`, a string the server
composes: the URL that carried the device key and any body the Bark server
returned stay inside the process, and the bark-main record gains
`last_failure_kind: upstream_5xx`, `last_status_code: 502` and nothing else.
A third such failure in a row raises `notify.channel_failing` for bark-main,
which a second rule sends to Discord. If no rule matches, nd_1 is written as
`no_route` and the event list shows it in red, which is the state production
is in today.

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
manifest `notify.emits`, the block added to `SigningPayload` and to the
mutation map, `notify.emit` host method, alias for `notify:send` and
`notify.send`, `pluginHost.Send` rewritten to build the legacy event and
call `emit` (this is the line that closes the bypass,
`plugin_host.go:216-240`), and the send-error redaction from section 6 so
the host boundary stops handing the plugin the channel credential. Grant
record with digest binding, derivation at activation, approve route,
migration grant for `message`. Console: grants tab.

Release ordering inside the slice is forced by the strict decoder and must
be followed rather than inferred. `DecodeManifest` uses `decodeStrict` with
unknown fields disallowed (`lattice-sdk/plugin/manifest.go:81-87`, mirrored
server-side), so a manifest carrying a `notify` block is not ignored by a
server that predates the field: it fails to decode and the plugin fails to
load with `decode manifest: unknown field "notify"`. The manifest is also
signed field-by-field, so shipping the block means re-signing the bundle
with the released `pluginsign`, which changes the bundle digest and the
signature and makes the rollback path a re-sign of the old manifest. The
order is therefore:

1. Release the server carrying the `notify` field and the new
   `SigningPayload`, and let it reach the control plane.
2. Publish `pluginsign` from that release, per the standing rule that a
   plugin is signed with an already-released tool.
3. Re-sign the sub-store bundle with the `notify` block, set `MinServer` on
   the new manifest to the version from step 1 so a downgrade refuses with a
   version number instead of an unknown-field decode error, and re-pin.

The sub-store manifest and pin therefore land in the same slice but not in
the same release as the server change, and the release note says so.

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
  alias goes. What the operator is approving is a five-repository change,
  not a route rename: `rbac.KnownScopes`, the server routes, the dashboard
  navigation and scope documentation, and the Astra token scope set. The
  cheap lever for existing tokens is the `notify:*` domain wildcard
  `ValidScope` already accepts, which works as soon as the scopes are known
  and lets the alias window be short.
- D5: outbox bounds (500 events, 1000 deliveries), the per-source floor of
  50 deliveries, and the retry schedule (5 s, 30 s, 2 min). Defaults, not
  contract, and none of them measured against a running fleet yet. The floor
  is the one number with a compatibility meaning: it preserves the guarantee
  `maxNotifyWebhookDeliveries` gives today, so lowering it is a visible
  regression for webhook debugging while raising the global cap is not.
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
- [ ] `/api/notify/webhooks/deliveries` returns the same shape from the outbox, filtered by source. The retention guarantee is restated, not claimed unchanged: with 1200 deliveries from other sources in the outbox, a webhook that fired 50 times still shows all 50 rows (the per-source floor), and the console states "at least the last 50 attempts per source" where it used to say nothing.
- [ ] A channel with three consecutive permanent failures shows `consecutive_failures: 3` and a `last_failure_kind` in the channel view, and one `notify.channel_failing` event exists.
- [ ] Secret redaction, tested directly rather than by absence: `redactSendError` is fed a `*url.Error` wrapping a Telegram endpoint built with a fake bot token, and the token substring appears in neither the returned kind nor the status; a fleet-wide grep of the state file after a forced Telegram, Discord, Bark and generic-webhook failure finds no channel credential and no upstream response body; the same failure returned through `notify.emit` to a plugin carries only the kind and status.
- [ ] Storage is on the record-level bolt path: `notify_events` and `notify_deliveries` are cleared in `jsonPersistStateFrom` beside the existing exclusions, and a test that drives an offline sweep marking 30 nodes against three channels and one rule asserts `testPersistCalls` does not grow with the number of events.
- [ ] `POST /api/notify/test {channel_id}` sends without the caller supplying config, and `config` is absent from every response body (existing secret-free invariant test extended).

Slice C

- [ ] Two events with the same dedupe key inside a rule's `suppress` window produce one `sent` and one `suppressed` delivery.
- [ ] Paired transitions are never suppressed: a rule with `suppress: 10m` receiving service.down at 12:00, service.recovered at 12:02, service.down at 12:05 and service.recovered at 12:08 sends all four, and the last message reflects the live state. The same holds for monitor.down/recovered and node.offline/online.
- [ ] A rule with `min_severity: warning` does not send `ssh.login` (notice) and does send `ssh.compromise_suspected` (critical).
- [ ] Bark receives `level: critical` for a critical event on a channel with no `level` configured, and the channel's configured level when set.
- [ ] Console rule editor offers catalogue types, glob entry, severity, suppress and rate limit; the zero-rules banner appears and disappears.

Slice D

- [ ] A plugin calling `notify.emit` with an undeclared name is refused; audit shows `plugin.host.notify.emit deny` with reason naming the catalogue gate.
- [ ] A declared name with a pending grant is refused with reason naming the grant; after `POST /api/notify/grants/approve` the same call succeeds and the event type is `plugin.<id>.<name>`.
- [ ] A plugin emit reaches only channels selected by a matching rule; with a rule `source_kinds: ["plugin"]` to Discord and no other match, Bark receives nothing (this is the test that proves `pluginHost.Send` no longer fans out).
- [ ] The sub-store plugin built against the previous SDK, calling `notify.send`, still delivers through the migration grant and shows type `plugin.latticenet.sub-store.message`.
- [ ] Upgrading a plugin whose manifest renames an emit voids the old grant and mints a pending one; unchanged entries stay approved.
- [ ] The `notify` block is inside the signature: `TestSigningPayloadV2CoversTypedManifest` gains a `notify` mutation entry that changes a declared emit name and a subscribed type, and it fails when `SigningPayload` is reverted to skip the block. A manifest with an appended `subscribes` entry and the original signature fails `VerifyManifest`.
- [ ] Re-publishing under an unchanged version string with a changed notify block voids the affected grants: the same `0.13.0-alpha` with `sync_failed` moved from warning to critical and a new subscribed type mints pending grants and does not deliver until approved.
- [ ] A manifest whose `plugin.<id>.<name>` composite exceeds 64 bytes is refused by `VerifyManifest` with the name, the computed length and the ceiling in the message, and no grant is minted for it.
- [ ] The scope split lands in all five places or not at all: `rbac.KnownScopes` contains `notify:emit`, `notify:read` and `notify:admin` (a user-management assignment of `notify:admin` succeeds); `notify:*` is grantable through `ValidScope`; the dashboard sidebar shows Notifications and Webhooks for a token holding only `notify:read` plus `notify:admin`; `lib/scopes.ts` documents the three scopes; the Astra token scope set is updated. Tested with a token that carries none of the alias.
- [ ] Release ordering is honoured: the server carrying the `notify` field ships first, the sub-store bundle is re-signed with a `pluginsign` from that release, `MinServer` is set on the new manifest, and installing that bundle on the previous server image refuses with the version rather than `unknown field "notify"`.

Slice E

- [ ] A plugin subscribed to `service.down` with an approved grant has its `on_event` invoked with the envelope, and the envelope contains no channel ids, kinds or config.
- [ ] A subscriber that exits non-zero is retried once after 30 s, then the delivery settles failed; 61 queued events for one plugin drop the oldest with reason `subscriber backlog`.
- [ ] Ten consecutive failed deliveries do not open the runner circuit breaker: an operator-initiated call to the same plugin succeeds immediately afterwards, and `ErrCircuitOpen` appears nowhere in the audit. Twenty consecutive failures auto-suspend the grant instead, with an audited reason.
- [ ] A delivery is invoked as action `notify.deliver` under the fixed budget, not as `call` under a derived one: a subscriber that sleeps past the 5 s timeout is cut off, and a burst of 60 deliveries does not delay an operator call to the same plugin past one delivery's budget.
- [ ] Two plugins subscribed to each other's emits stop after three hops; audit shows the refused fourth hop.
- [ ] A schedule with `daily_at_utc: "08:00"` emits `schedule.<name>` once per day (clock-injected test) and the Bark delivery row exists.
- [ ] An inbound webhook's fields reach a subscriber only when `share_fields_with_plugins` is true.

Cross-cutting

- [ ] No route under `/api/notify/` is reachable with a confined token for writes (existing `refuseConfinedFleetWrite` tests extended to grants, schedules, events).
- [ ] No fleet-wide notify history is readable with a confined token either: a node-confined token holding `notify:read` gets 403 from `GET /api/notify/events`, `GET /api/notify/deliveries`, the channel list, the catalogue and both webhook routes, with an audited deny; the same holds for a confined token holding only the `notify:send` alias. A table-driven test enumerates every route registered under `/api/notify/` and fails when a new one is added without a confinement decision.
- [ ] `go test ./... -race -timeout 20m` in lattice-server passes; `go clean -cache -testcache` after.
- [ ] Dashboard renders /platform/notifications at 1440 and 375 with the deliveries list, grants tab and a rule with every new field, driven against a local server with one Bark channel pointed at a stub.
- [ ] PROGRAM.md notifications section and the vault note
  `设计与方案/2026_09_04_通知抽象与SDK能力设计.md` point at this document and
  record D1 to D6 once decided.
