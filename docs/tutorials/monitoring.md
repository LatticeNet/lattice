# Monitoring paths

Monitoring in the console answers three questions: what is broken now, how
your nodes reach each other, and how that reach has fluctuated over the last
days. The unit is a **path**: one source probing one target with one method.
A **check** owns one or more paths (one per source), and the **path set** is
one rule, sources times targets, that the control plane turns into generated
checks for you.

This page is the operator's guide to that surface. The mechanism behind it
(storage tiers, the beacon's wire rules, the degraded evaluator, scopes per
route) is in the Monitoring section of
[`../architecture.md`](../architecture.md#monitoring), and the reasoning is in
[design 29](../designs/design-29-monitoring-paths.md).

## Before you start

**Scopes.** Reading anything here needs `monitor:read`, and you see a path
only when you may read both its source and its target node. Creating or
editing a check needs `monitor:admin`, admin on every source it names and
`monitor:read` on a target node. Saving the path set, and reading or saving
the history retention, need a session or token with no node allowlist
(`monitor:admin` to save), because both cover the whole fleet. Beacon plans need more; see
[Enable a beacon](#enable-a-beacon).

**Agents.** A source runs only the methods its agent reports. The source
picker in every editor lists them per node (for example `http icmp tcp`).
An agent that reports none predates method reporting and runs TCP and HTTP
only; a path that asks it for more reads unknown with "agent too old", never
down. The beacon also needs, on the target, an agent that carries the beacon
responder; otherwise the node's Beacon card says its agent does not run a
beacon yet, and "Agent too old" once a beacon is enabled. Update
agents through the normal approved update path
([`agent-updates.md`](./agent-updates.md)).

**Trust assumptions.** A check's target and URL are visible to everyone who
may read the check, so a token never belongs in a URL; put it in a secret
header (see [HTTP](#http)). Results and history live on the control plane's
hot store; agents hold results in memory only until they are posted. Nothing
on this page changes a node's network exposure except a beacon plan, and a
beacon plan changes nothing until someone approves it.

## Read the Overview

Monitoring opens on **Overview** (the layers are Overview, Paths, Checks,
Topology and Incidents, kept in `?view=`). The window control in the header
("1h" to "14d", kept in `?window=`) applies to every layer that reads
history.

The proof line under the header says when the console last read the server
("observed 12 s ago"), how many paths there are, how many sources report
when there is more than one, and the counts that need you: down (red),
degraded (amber), unknown and paused (muted). Each count is a link into Paths
filtered to that state. Amber means degraded everywhere a path state is
drawn; unknown is never green and never amber.

**Needs attention** lists what to look at, worst first: paths down, grouped
by target and then by source; the same for degraded; sources whose agent is
offline; unknown paths grouped by reason; and paused paths last. It shows
five items, then "Show all". Each item's "Show" button opens Paths with the
filter that selects exactly its paths, and opens the path's sheet when the
item covers one path.

A down or degraded item carries a verdict line, which says where the cause
most likely sits:

- "Likely cause: the target" when at least two sources report on the target
  and every one of them finds it bad.
- "Likely cause: {source}'s network" when one source is bad to at least three
  targets and to more than half of the targets it reports on, while another
  source reaches at least one of them.
- "Likely cause: this path" for anything else, with the other sources that do
  reach the target as evidence.

With a single source no verdict can be placed, and the list says so once
above the items ("Only {source} reports on these paths, so their causes
cannot be placed. A second source in the path set would place them."). A
verdict is a label with its evidence: it changes no state, opens no incident
and sends nothing.

**Reach** shows one bar per source: the share of its paths that are up,
degraded, down, unknown (hatched) and paused. The source name opens Paths
filtered to that source, and each count opens it filtered to that source and
state. Reach counts paths of the path set; your own checks are in Paths.

## Read the Paths matrix

**Paths** is the matrix: targets as rows grouped by region, sources as
columns ("FROM cd-hs-sh"). Your own checks sit in a second table, "Your
checks", below the path set's. Each cell shows the window's p50 in the
foreground ink; a loss figure under it when the window lost anything ("<1%",
"12%"); a red rail and tint when down; an amber rail and tint when degraded;
and a hatch with the short reason ("ICMP filtered", "no key yet") when
unknown or paused. Hover or focus a cell for the full sentence and what the
source dials. Below 768 px the matrix becomes a list grouped by target.

The filter field (kept in `?paths.q=`) takes the console's list syntax:
`state:down`, `state:degraded`, `state:unknown`, `source:cd-hs-sh`,
`target:tyo`, `region:europe`, `country:jp`, `method:icmp`, `reason:`
followed by a code or words of its sentence, and numeric comparisons such as
`p50>200`, `loss>1%` or `jitter>=5`. Combine terms with spaces, `OR` and a
leading `-` to negate, and sort with `sort:-loss`. Rows and columns without a
match are hidden.

Selecting a cell opens the **path sheet**. Its URL (`?path=`) is a stable
link to that path: `<source>~<target node>` for a generated path,
`<source>~@<check id>` for one of your checks.

## Read a path chart

The path sheet carries the state, the evidence, the chart and the latest
runs.

**State.** The badge reads up, degraded, down or unknown, with "last run 40 s
ago" beside it. Under it: the reason sentence for unknown, the newest error
for down, and for degraded the evidence ("Loss 4.2% over the last hour (12 of
290 probes), above its trigger of 2% (7-day loss 0.4%).", "Degraded since
14:02."). A clearing path says when it reads up again unless the condition
returns. Where a next step exists the sheet names it: "Update agents" for an
old agent, the target's Beacon card for a beacon reason, a TCP check for a
target that filters ICMP.

**Stats row.** For the window (or a range you selected on the chart): p50,
p95, jitter (the mean jump between consecutive successful runs), loss,
availability (runs heard, less their loss, over runs expected) and runs
("281 of 288").
p50 and loss carry their change against the period before. Once the path's
baseline is ready a "Degraded above" row states both triggers.

**The chart.** One time axis, two lanes.

- The upper lane is latency. The band runs from each bucket's minimum to its
  p95, in the path's state tone at low opacity; the line is the p50 in the
  foreground ink, so it reads in every state. At steps of five minutes or
  less, where buckets are wide enough, faint ticks mark each bucket's min and
  max.
- The lower, short lane is loss per bucket as bars, scaled to 100 percent.
  A bucket with no loss draws nothing.
- A **gap** is a bucket where runs were expected and none arrived. It is
  hatched across both lanes, labelled "no data" where it is wide enough, and
  never interpolated. The crosshair says what an empty bucket held: no runs
  arrived, nothing was expected because the path was paused, or the runs
  measured nothing, with the reason.
- Once the path has 24 hours of baseline, two dashed **guides** cross the
  latency lane, labelled once at the right edge: "7-day median 64 ms" and
  "degraded above 128 ms". The scale always includes the trigger. There is
  no loss guide; the loss trigger is in the stats row. Until the baseline is
  ready a note says how much history the path has so far.
- A dashed vertical line marks a **method switch** ("TCP → ICMP"), because a
  generated path keeps one line across methods.
- "Compare with the previous period" in the chart header (off by default,
  kept in `?compare=1`) overlays the p50 of the window just before as a thin
  dotted line, and adds "previous p50" to the crosshair.

Point at the chart, or focus it and use Left and Right (Home and End jump to
the ends), to read one bucket: time span, min, p50, p95, max, jitter, loss,
echoes or requests lost of sent, runs of expected, method. Drag to select a
range and zoom; double-click, Escape or "Reset zoom" returns. On a phone the
sheet is full screen, and the bucket's values sit in a fixed row above the
chart so your finger does not cover them. "Buckets as a table" below the
chart shows the same figures as rows.

The step adapts to the window: one minute over an hour, five minutes over 6
or 24 hours, ten over 3 days, fifteen over 7 days, and thirty minutes or one
hour over 14 days depending on retention. A window longer than the
five-minute history reads hourly buckets.

**Latest runs** lists up to 20 runs from this source: time, RTT, ok or fail,
packets sent and lost with each RTT, and the error. "Pause path" (or "Resume
path") stops this one path and keeps its history; "Open check" or "Edit path
set" leads to its configuration; "Source node" and "Target node" open the
nodes.

## Add and edit checks

**Checks** lists every check: "Your checks", then "Path set" with its
generated checks, which are read-only here. A row reads up, down on N of M,
degraded on N of M, not measured with the reason, or paused. Under the list,
a strip shows how long five-minute history is kept and how much the store
uses (see [Set retention](#set-retention)).

"Add check" opens the editor, in this order:

1. **What to measure**: Beacon, TCP, ICMP, HTTP or TLS (see
   [Pick a method](#pick-a-method)).
2. **From where**: "Every node" (nodes enrolled later included) or "Chosen
   nodes". The picker shows, per node, the methods its agent runs and whether
   it is online. A chosen source that cannot run the method is flagged, and
   its path reads unknown with the reason until it can. TLS runs on the
   control plane and takes no node.
3. **To where**: "A node" or "An address" for TCP and ICMP, a node only for
   Beacon, an address or URL for HTTP and TLS. A node target is resolved for
   the method and followed when it moves: ICMP to its public IPv4, TCP to a
   public TCP line port (never SSH or a knock port), Beacon to its beacon's
   advertised endpoint. "What each source will dial" previews the resolved
   endpoint per chosen source, and the editor refuses a node that cannot be
   resolved for the method ("no public TCP line", "no beacon enabled") with
   the reason. An address must be public; private, loopback, link-local,
   metadata and similar ranges, and `localhost`, are refused.
4. **What counts as up**: per method, below.
5. **How often**: interval from 10 s (default 30 s, 3600 s for TLS) and a
   timeout shorter than the interval and at most 60 s. For ICMP and Beacon
   the editor shows how long a run takes; a run must end before the next one
   starts, and a save is refused when, from one source, the ICMP checks to
   one address or the Beacon checks to one beacon, path set included, would
   send more than two packets a second.
6. **When it fails**: the alert policy (see
   [Degraded alerts](#turn-on-degraded-alerts-and-tune-thresholds)).
7. **Name**: leave it empty to use the suggestion.

**Editing.** "Edit" on a check changes its name, timing, packets,
expectations, headers, alert policy, thresholds and sources. Changing the
method, the target or the target node asks "Start a new check?": the new
check starts with an empty history and the current one is paused with its
history, so one series never mixes two methods. Each source in the editor has
a "paused" box; a paused source keeps its history and stops running the check
until you resume it. A save carries the version you read; if someone saved in
between, the editor reloads and asks you to make the change again. Every save
is audited.

**Deleting** a check deletes its history. Generated checks cannot be edited
or deleted; pause their paths through the path set.

## Edit the path set

"Path set" (on the Checks layer) edits the one rule that generates checks
between your nodes.

- **Sources**: the nodes that probe. "Method per source" shows what each
  source will use and lets you pin it: "Path set (method)", TCP, ICMP, Beacon
  or Auto. A pinned source never falls back; pinned to a method it cannot
  use, its paths read unknown with the reason.
- **Method**: TCP, ICMP, Beacon or Auto. Auto picks, per source and target,
  the beacon when the target's beacon admits this source and is listening;
  else ICMP when the source runs it, the target has a public IPv4 and ICMP has
  not read filtered for that pair within the last day; else TCP to a line
  port. A path keeps its history across a switch.
- **Targets**: "Probe every node outside mainland China" decides by the
  node's country (CN is mainland; HK, MO and TW are outside it). Per node you
  can override with "Always" or "Never"; a node with no country is probed only
  when set to "Always". A source never probes itself.
- **How often**: interval 10 to 3600 s (default 60 s), timeout 1 to 30 s.
- **When it fails**: off by default, so the path set pages nothing until you
  choose. See [Degraded alerts](#turn-on-degraded-alerts-and-tune-thresholds).
- **Probing** On or Paused, and **Paused paths**, the pairs you paused with
  "Resume" on each.

The footer previews the result ("3 sources, 24 targets, 72 paths after
saving", with how many would read unknown). The control plane re-plans right
after a save, and again every two minutes as the fleet changes.

## Pick a method

| Method | Measures | Needs | Notes |
|---|---|---|---|
| Beacon | the network path to the node itself | an enabled beacon on the target, approved for this source; agents on both ends that support it | works for every node whatever it serves, and through NAT with a mapped endpoint |
| ICMP | ping, answered by the target's kernel | the source's kernel must allow unprivileged ping sockets; a public IPv4 on the target | some providers filter it; nothing new listens on the target |
| TCP | time to connect to a port | a public TCP line on a node target, or any public `host:port` | what the path set has always used |
| HTTP | a GET and its status | a public URL | the answer's status, not its body |
| TLS | certificate expiry | a public `host:port` | dialled by the control plane, not by a node |

### Beacon

Beacon sends 1 to 10 signed requests per run (default 5), 200 ms apart; the
run is up when at least one signed "ok" reply comes back within the timeout,
and loss is the share without one. A signed refusal (stale clock, old key,
rate limited) makes the run read unknown with that reason. A Beacon check always names a node; the
editor refuses a target without an enabled beacon and links to its node page
to enable one. See [Enable a beacon](#enable-a-beacon).

### ICMP

ICMP sends 1 to 10 echoes per run (default 5), 200 ms apart, each carrying
random bytes, and counts a reply only when its payload and address match one
it sent. The agent needs no raw-socket privilege: it uses the kernel's
unprivileged ping sockets, which the kernel allows only to groups inside
`net.ipv4.ping_group_range`. When the source's group is outside it, the
source's paths read "ICMP not permitted" and the source picker says so.
Lattice does not change that setting. To allow it, include the agent's group
id in the range through your host configuration (check the current value
with `sysctl net.ipv4.ping_group_range` and the group with
`id -g lattice-agent` on a node installed with a run user); the agent
notices within ten minutes without a restart. Otherwise use TCP or Beacon for
that source.

A path whose every echo was lost and that has never had a reply reads
unknown "ICMP filtered", not down, because the target or a provider may drop
ICMP. Once a path has had a reply, all-loss runs count as failures and page
as any other failure.

### TCP

TCP measures the time to open a connection. A node target dials a public
TCP line port the node already serves; a node with no TCP line cannot be a
TCP target and reads "nothing to dial".

### HTTP

HTTP sends a GET and judges the status against "Expected statuses", a comma
list of codes and ranges ("200-299,301"); empty means `200-399`. Redirects
are never followed: a 3xx is the answer, so list it if you expect it. The
latency is the time to the response; the body is never read or stored.

"Request headers" takes up to eight headers. Tick "Secret" for a header that
carries a credential. A secret header:

- requires an https URL, and the certificate is always verified;
- is bound to the origin it was saved with ("Secret values go only to
  {origin}, over HTTPS, and never follow a redirect");
- is never shown again: the editor shows "set" with "Replace" or "Keep
  current", and an edit that leaves it alone keeps it;
- goes only to the agents assigned the check, and is never written to an
  audit record.

A new URL is a new check, which starts without the secrets; enter them
again. An agent that predates method reporting is never handed a check with
headers or a non-default status set.

### TLS

TLS reads the certificate of `host:port` from the control plane and fails
when it expires within "Warn under (days)" (default 14). Its path's source is
the control plane. TLS is never judged degraded.

## Enable a beacon

The beacon is a UDP responder inside the node's agent that answers only
requests the control plane signed for it. It is the one inbound socket an
agent may open, it is off on every node until you enable it, and enabling it
is a plan someone must approve.

**What it opens.** One UDP port on one address of the node: by default a
port the control plane picked at random for that node in 40000 to 59999, on
the node's primary interface address (its private address behind NAT). The
responder replies to nothing unsigned, never sends a reply larger than the
request, and limits each source to 20 requests a second. Under NetGuard only
the approved sources' addresses reach the port, and the port's traffic is
kept out of connection tracking; without NetGuard anyone can send it packets,
and the Beacon card says "open to the internet".

**Steps.**

1. Open the target node's page. The **Beacon** card reads "Off" and names the
   port it would open, or says one will be picked at random from 40000 to
   59999 when no plan was ever made for the node.
2. "Enable" opens the plan sheet. "Where it listens": the UDP port (any
   1024 to 65535; keep the random one unless you have a reason) and the bind
   address. "Where sources send": the address and port sources send to,
   which differs from the listen port only when a NAT maps another outside
   port to it. The endpoint must be one of the node's own addresses.
3. "What the plan will ask" summarises the port, the endpoint, the sources
   that will hold a key, the NetGuard rule or the internet exposure, and the
   limits. "Create plan" files it; nothing changes on the node yet.
4. Review the plan: before and after settings, sources with their ids and the
   addresses NetGuard admits, the exposure, findings and the plan's SHA-256.
   A port that sing-box, sshd, a knock sequence or WireGuard uses blocks the
   plan; a mapped endpoint, no sources yet and a node NetGuard does not
   manage are warnings.
5. Approve it in **Approvals** ("Review in Approvals"). With a NetGuard rule,
   use "Approve and queue" so the rule's apply task runs; the control plane
   refuses a plain approval of such a plan. It renders the plan again at the
   decision and refuses it as stale if anything it covers changed; plan again
   then.

Filing the plan needs `monitor:admin`, `node:admin` and `network:plan` on the
node, `netguard:admin` too when NetGuard manages it, and read access to every
source it names; approving needs `network:apply` as well.

**After approval.** Under NetGuard the beacon stays closed until the rule's
apply task succeeds; meanwhile its paths read "firewall pending", and if the
apply fails the card says so and the beacon stays closed. Then the agent binds
the port and the card reads "Listening on {bind}:{port}". One approved source
runs a short reachability check and the card reports "Reached from
{source}", every request lost (a firewall or provider drops UDP to the port),
or refused (nothing listened). Path set sources on Auto move to the beacon on
the next re-plan.

**Later changes.** "Change" files a plan to move the port, bind address or
endpoint, and is how new sources are admitted: a source that starts using the
beacon after the plan reads "firewall pending" (or "awaiting plan" without
NetGuard) and holds no key until a change plan that includes it is approved.
"Rotate keys" moves the node to new keys at once (an audited action, no
plan); sources pick them up within about a minute. Removing a source rotates
the keys by itself. "Turn off" files a plan that closes the port and deletes
the node's key.

**The node's veto.** An agent started with `-no-beacon`, or with
`LATTICE_NO_BEACON=1` in its environment file (the installer keeps it across
reconfiguration), never opens the beacon socket, whatever any plan says. The
card then reads "Refused by the node" and paths to it read "beacon refused".
The node can still run Beacon checks against other nodes, since that only
sends. Remove the flag and restart the agent to lift the veto.

## Set retention

The strip under the Checks list reads "Five-minute history kept 7 days" with
the size on disk and the projected size; "Change" opens **History
retention**.

| History | Resolution | Kept |
|---|---|---|
| Raw runs | every run | 1440 per path |
| Five-minute | 5 minutes | 3 to 14 days, default 7 (this setting) |
| Hourly | 1 hour | 35 days |

The sheet shows the bytes the history uses now and a projection at the days
you pick, and warns when more than 300 paths run at intervals under 30
seconds. Saving takes effect at once, and lowering it starts the pruning
sweep immediately; otherwise the sweep runs every hour and trims every path,
paused ones included. Lowering retention frees space for reuse inside the
store, but the file on disk does not shrink. The 14-day window appears only
when five-minute history is kept 14 days; with less, longer windows read the
hourly history.

## Turn on degraded alerts and tune thresholds

A path is **degraded** when it is lossier or slower than its own last week.
The control plane judges it every minute, whatever the console shows, and
only once the path has 24 hours of history:

- **Loss**: over the last hour, with at least 30 probes, loss above both
  2 percent and twice the path's 7-day loss.
- **Latency**: over the last 15 minutes, with at least 5 successful runs, the
  median above both twice the 7-day median and the 7-day median plus 30 ms.

A path enters degraded after two evaluations in a row find either condition
and leaves once the condition has been absent for ten minutes, so a single
lost probe does not flap. Down and unknown always win over degraded. TLS is
never judged. The 7-day baseline follows the path, so a degradation that
lasts for days slowly becomes its usual level and the path reads up again;
the path sheet says so.

**Alert policy.** "When it fails" in the check editor offers:

- "Do not alert": nothing pages. Down and degraded still show.
- "Alert, and announce the recovery, when a source fails": `monitor.down`
  after the chosen number of failed runs in a row (default 2, at most 20),
  `monitor.recovered` on the next success.
- "Alert when a source fails, and when a path is degraded": the same, plus
  `path.degraded` and `path.recovered`. Not offered on TLS.

The path set sheet offers the same three policies for every generated path:
"Do not alert", "Alert when a generated path fails" and "Alert when a
generated path fails, and when it is degraded".

A new check defaults to the down alert. The path set defaults to "Do not
alert", so generated paths page nothing until you pick a policy there. The
run count also decides when a path reads down, whatever the policy.

**Thresholds.** "Degraded when" under the alert step (every method but TLS)
states the rule in one sentence and offers its four numbers: "Loss above"
(percent, 0.5 to 50, default 2), "and above" (times the 7-day loss, 1.2 to
10, default 2), "Median above" (times the 7-day median, 1.2 to 10, default
2) and "and at least" (ms over the 7-day median, 5 to 1000, default 30).
"Reset to defaults" restores them. A check's thresholds apply to its own
paths; the path set's apply to every generated path. Degraded shows on the
page whatever the policy; the policy decides only whether it pages.

**What pages.** On the degraded policy a generated path sends "Path
degraded: {source} to {target}" and a path of your check "Path degraded:
{check} on {source}", with the evidence and the time it started, and "Path
recovered" when it leaves. A path that became degraded while it was
down or unknown stays quiet for that episode, because you were already told
about the outage. Paths that measure nothing, ICMP and Beacon paths that have
never had a reply, and paused paths never page. Messages that fall due
together are joined into one ("3 paths degraded"); a reopening within half an
hour of a recovery counts as a flap, and from the third flap the path sends
at most one message an hour; these are
warnings, so quiet hours hold them and nothing escalates. When you pause the
path, disable the check, remove the source or turn degraded alerts off, the
incident closes without reporting a recovery; if its open was sent, a notice
that says why ("Path paused: ...", "Degraded alerts off for ...") goes out
instead. Incidents appear in the **Incidents** layer as "{source} to
{target} degraded" (or "{check} on {source} degraded"), linked to the path.

## What unknown means

Unknown means no current measurement where one was expected. The cell shows
the short label; the path sheet shows the sentence and, where one exists,
the next step.

| Label | Code | Meaning | What to do |
|---|---|---|---|
| agent offline | `agent_offline` | the source's agent is offline, deleted or disabled | look at the source node |
| paused | `source_paused` | you paused this path or source | resume it from the path sheet, the check or the path set |
| nothing to dial | `not_probeable` | the target cannot be resolved for this method (no public TCP line, no public IPv4, or a beacon endpoint that is no longer the node's) | pick another method, or plan a beacon change |
| no data | `no_data` | a result was expected and none arrived within three intervals or two minutes | check the source agent's queue and clock |
| agent too old | `agent_too_old` | the source's agent does not run this method | update the agent, or use a method it runs |
| ICMP not permitted | `icmp_not_permitted` | the source's kernel refuses unprivileged ping sockets for the agent's group | see [ICMP](#icmp) |
| address refused | `destination_refused` | the source refused the address (private, local, metadata), or a secret header's rule forbade the request | use a public target; keep secret headers on their https origin |
| ICMP filtered | `icmp_filtered` | every echo lost on a path that has never had a reply | use TCP or Beacon for this target |
| no beacon | `beacon_not_enabled` | the target has no enabled beacon | enable one on the target's page |
| firewall pending | `firewall_pending` | NetGuard on the target does not admit this source yet | approve a beacon change plan on the target |
| awaiting plan | `beacon_source_pending` | without NetGuard, the target's plan does not include this source yet | approve a change plan on the target |
| beacon refused | `refused_by_node` | the target's agent runs with `-no-beacon` | lift the veto on the node, or use another method |
| not listening | `beacon_not_listening` | nothing answers on the beacon port: the agent cannot bind it, closed it for a cooldown after a flood, or has no responder | read the target's Beacon card |
| UDP filtered | `beacon_filtered` | every request lost on a path that has never had a reply | check firewalls and provider rules for UDP to the port |
| clock skew | `beacon_stale` | the target refused the requests as stale: the clocks differ by more than a minute | fix time sync on the source or target |
| old key | `beacon_unknown_epoch` | the source used a key the target no longer accepts | none; the source picks up the new key within a minute |
| rate limited | `beacon_rate_limited` | the source sent more than 20 requests a second to the target | lower the packets or raise the interval of checks to that target |
| no key yet | `beacon_no_key` | the source holds no key for the target yet | none; it arrives with the next configuration pull |

A degraded path carries one of three reasons instead: "loss over usual"
(`degraded_loss`), "slower than usual" (`degraded_latency`) or "lossy and
slow" (`degraded_loss_latency`).

## API examples

The console uses these routes; a scoped, short-lived personal access token
works the same way. Set `LATTICE_PAT` to such a token in your shell, never in
a file you share, and revoke it when you are done.

Read the matrix for a window and list what is not up:

```sh
curl -fsS -H "Authorization: Bearer $LATTICE_PAT" \
  'https://lattice.example.com/api/monitors/paths?window=24h' \
  | jq '.paths[] | select(.state != "up") | {source, target_node, method, state, reason}'
```

Read one generated path's week, with the previous week for comparison:

```sh
curl -fsS -H "Authorization: Bearer $LATTICE_PAT" \
  'https://lattice.example.com/api/monitors/series?source=hk-edge&target_node=tyo-3&window=7d&compare=previous'
```

Create an ICMP check from one source to a node:

```sh
curl -fsS -X POST -H "Authorization: Bearer $LATTICE_PAT" \
  -H 'Content-Type: application/json' \
  -d '{"name":"ICMP to tyo-3","type":"icmp","target_node":"tyo-3","node_ids":["hk-edge"],"interval_sec":60,"timeout_sec":5,"packets":5,"alert":"down"}' \
  https://lattice.example.com/api/monitors
```

Read the history setting, then save a new one with the `version` it
returned (a stale version answers 409):

```sh
curl -fsS -H "Authorization: Bearer $LATTICE_PAT" \
  https://lattice.example.com/api/monitors/settings
curl -fsS -X POST -H "Authorization: Bearer $LATTICE_PAT" \
  -H 'Content-Type: application/json' \
  -d '{"fine_retention_days":10,"version":3}' \
  https://lattice.example.com/api/monitors/settings/update
```

File a beacon plan for a node (it still needs approval in Approvals), and
read the beacon's state:

```sh
curl -fsS -X POST -H "Authorization: Bearer $LATTICE_PAT" \
  -H 'Content-Type: application/json' \
  -d '{"node_id":"tyo-3","action":"enable"}' \
  https://lattice.example.com/api/nodes/beacon/plan
curl -fsS -H "Authorization: Bearer $LATTICE_PAT" \
  'https://lattice.example.com/api/nodes/beacon?node_id=tyo-3'
```

## Rollback and cleanup

- A check: pause it or a source to stop runs and keep the history; delete it
  to remove the history too.
- The path set: set "Probing" to Paused to stop every generated probe and
  keep its history, or pause single paths.
- Retention: raising it again keeps whatever has not been pruned yet;
  lowering it prunes at once and cannot be undone.
- A beacon: "Turn off" files a plan that closes the port and deletes the
  node's key; under NetGuard the companion rule goes with it on apply. For an
  immediate stop on one node without the control plane, start its agent with
  `-no-beacon`.
- Degraded alerts: choose "Do not alert" or the down alert; open
  `path.degraded` incidents close, with a notice saying alerts are off where
  the open was sent.

## Limitations

- The beacon is IPv4 only, and its endpoint is an IPv4 literal; host names
  and IPv6 are refused.
- With one source, verdicts cannot place a cause. A second path set source
  in another network makes "the target" and "this source's network" possible.
- The degraded baseline is the path's own week, so a slow change over many
  days is not caught, and a new path or a method switch waits 24 hours before
  it is judged.
- The history file never shrinks on disk; size the retention for the paths
  you expect to keep.
- Without NetGuard on the target, the beacon port accepts datagrams from
  anyone; the responder's checks are its only protection.
