# design-19: sing-box service liveness

Status: accepted 2026-09-01. Goal-mandate M0 P1.4. Implementation slices:
SDK runtime block, agent probe, server derivation plus subscription filter
plus notifications, vpn-core UI split.

## The incident class

A node's sing-box crash-looped 220,000 times while every line on it showed
"ok", and a hysteria2 endpoint dead for six days kept rendering into served
subscriptions. Both had the same mechanism: every status on the proxy path
answers a question about configuration, never about the service.

Verified anchors (2026-09-01):

- `lattice-server/internal/server/lines.go:270-278`: discovered-line status
  is `inv.Status`, which means "the discovery command ran", so intact config
  files stamp every line "ok" regardless of the process.
- The managed branch derives from `AppliedSHA256`/`LastError`: "did the last
  push apply", not "is it running".
- `lattice-server/internal/proxycore/links.go:132-194`: subscription
  rendering filters on expiry, core, applied-config, last-error, hostname.
  No liveness signal of any kind reaches it.
- The agent already enumerates trusted sing-box processes
  (`singboxdiscover/discover.go:857-927`) but uses the result only to locate
  config files; process presence is never reported.
- Trace-side core-restart detection (tracesource.go generation counter)
  never escapes the trace pipeline, and a core that dies before serving its
  Clash API produces silence, so it cannot carry this feature.
- Inventories live only in the in-memory mirror `s.singboxInv`; a multi-day
  outage cannot survive a server restart, so there is no durable record to
  report after the fact.

## Axioms applied

Axiom 2 is the whole feature: "config exists" and "service is running" are
different facts and the UI must say which one it knows. The green light must
link to evidence (probe output, timestamps, audit trail). Axiom 3 shapes the
probe: read-only collection, no mutation, bounded output, following the
netguard reality pattern (`guardreality/collect.go`: injectable runner,
typed model, durable snapshot, named drift state).

## Design

**Agent probe** (`lattice-node-agent/internal/singboxlive`, new package,
guardreality-shaped). Read-only, injectable runner, bounded output. Collects:

- trusted process presence, PID, and best-effort start time, reusing the
  root-owned `/proc` selector already in `singboxdiscover` (exported, not
  duplicated);
- `systemctl show sing-box -p ActiveState,SubState,NRestarts` (the restart
  counter is what makes a crash loop visible between probes; detection must
  not depend on catching the process mid-death);
- bound listeners from `ss -tulpnH` filtered to the sing-box process,
  reusing `guardreality.ParseSSListeners`.

The result rides the existing inventory POST (`reportSingBoxInventory`,
every poll tick, default 10s) rather than a new endpoint: liveness stays
atomic with the line list derived from it, and no second auth or rate-limit
path appears. Probe failure is itself data (`ProbeError`), never a lie.

**SDK** (`lattice-sdk/model`): `SingBoxRuntime{Running bool, PID int,
StartedAt, ActiveState, SubState string, RestartCount int, ProbedAt,
ProbeError string}` as `Runtime *SingBoxRuntime` on `SingBoxInventory`;
`PortBound *bool` and `PortBoundBy string` on `SingBoxNode`. Pointer types
so an old agent's absent fields decode as unknown, not as false.

**Server**: ingest persists a compact per-node liveness snapshot durably
(the netguard reality precedent), including the previous derived state and
its transition time, so outages survive server restarts and can be reported
after the fact. Line derivation splits the field: `Status` keeps meaning
config state; new `ServiceState string` (`running | down | restarting |
unknown`) and `ServiceCheckedAt` are derived from the runtime block plus the
line's own `PortBound`. Mapping: no runtime block or probe error means
unknown; unit active and port bound means running; unit inactive/failed or
process absent means down; `activating`/`auto-restart` or a rising restart
counter between consecutive probes means restarting.

**Notifications**: typed kinds `service.down` and `service.recovered`
declared beside the emitter and fired through `notifyEventTyped` on
node-level state transitions only, with a 90-second hold-down (the
`nodeOfflineThreshold` precedent) so a crash loop produces one notification,
not 220,000. Each transition also writes an audit event (`Decision:
observe`) so the state change has a linkable evidence record. The existing
untyped node-offline notification is deliberately NOT retyped in this wave:
operators may hold NotifyRules that enumerate event types, and silently
reclassifying their lifeline notification could drop it. Retyping it is a
separate slice with a rule-migration step.

**Subscriptions** (`proxycore/links.go`): one new filter after the
last-error check, omitting a profile whose node-level service state is
`down` and appending the reason to the existing `warnings` slice. Fail open
everywhere else: `unknown` must never empty a subscription (a probe outage
is not a fleet outage), and `restarting` keeps serving with a warning
rather than flapping the rendered set. The liveness map threads through
`SubscriptionOptions`.

**vpn-core UI**: `service_state` on the `Line` interface; `lineStatus` stops
returning healthy for "config ok, service down" (that default-healthy return
is the dashboard half of the incident); `STATUS_ORDER` folds the new state;
the lines table shows service state as its own column separate from config
status. Ships as a plugin release (signing ceremony with the operator).

## Compatibility

Old agent to new server: absent runtime decodes as unknown; UI says unknown;
subscriptions unchanged. New agent to old server: unknown JSON fields are
ignored on ingest. No migration; the liveness bucket is new. The SDK change
is additive; server and agent pin the new SDK in the same slices that use it.

## Security pass

The probe is read-only and reuses the existing trust rules for process
identification (root-owned proc entries, root-owned binary in system paths);
it introduces no new agent capability and no new endpoint. Reported fields
are normalized and bounded on ingest exactly like guard reality. The
subscription filter can only remove endpoints, never add; its fail-open rule
means a spoofed "unknown" cannot hide a node from the operator (the UI shows
unknown loudly) and a spoofed "down" from a compromised agent can at worst
omit that same node's endpoints from subscriptions, which is the existing
blast radius of a node lying about itself. Notification debounce state is
server-side and per node, bounded by fleet size.

## Acceptance gates

- Agent: probe unit tests with a fake runner (process present/absent, unit
  states, listener matching, bounded output).
- Server: ingest persists and survives restart; derivation table covers
  running/down/restarting/unknown including the old-agent payload; the
  subscription filter omits a down node with a warning and keeps unknown;
  notification fires exactly once per transition with the hold-down, with
  an audit event.
- Live replay of the incident: stop sing-box on one node while its config
  stays intact; within one poll cycle the line shows down while config
  status stays ok, subscriptions omit the node, and one service.down
  notification arrives; start it again and service.recovered arrives.
