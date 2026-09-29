# Design 22: layered surfaces, and telling the operator what runs out

Written 2026-09-29 against production `alpha-0.2.2a97` (vpn-core `0.8.0`,
Sub-Store `0.13.0`). Status: accepted by the operator's request of the same
day ("帮我好好设计一下，该分层就分层"), build in progress. It extends the
September program (`../DESIGN-PROGRAM-2026-09.md`), which stays the authority
on tokens, the proof line, and interaction habits. This file changes
structure, not the chassis.

## 1. Why this exists

The operator reported that Sub-Store, vpn-core Lines, vpn-core Usage and
Evidence still work poorly, and asked whether expiry notifications were ever
built. Production read on 2026-09-29 answers both:

| Surface | What production shows | What the operator needs |
|---|---|---|
| Renewal reminders | the engine exists (per machine offsets, an `inventory.renewal` event routed to Bark by the rule "Recovered and routine"), but `reminders_enabled` is false on all 34 machines; 25 have a renewal date and 20 renew within 30 days, the first on 2026-10-06 | reminders on by default, one message per day instead of one per machine, and one place that lists everything that runs out |
| Sub-Store | 23 records: 5 sources (4 pasted, 1 provider link), 2 combinations, 16 client files, and 1 share; every list row reads "not published" and "n/a" | the pipeline from source to client, and which link a client actually fetches |
| Lines | 136 lines on 24 nodes, every row "ok" and "running", node rows with four empty columns, no traffic anywhere | where traffic flows, whether each route works, and what needs a hand |
| Usage | 568 GB counted over 7 days, 313 GB of it egress (exit plus direct lines) and 255 GB entering through relay hubs; 1 of 134 lines attributed to a user; the page leads with two identity panels that production cannot fill and has no time axis | traffic over time, per exit, against each machine's allowance |
| Evidence | 0 connection records (trace policy off on all 34 nodes), one raw log source whose node last reported 2026-08-27; two nested tab rows, a six-field filter form and two search boxes above an empty table | turn collection on for the window being debugged, then ask one question |

Wireframe figures below are production values from 2026-09-29; the ones
marked "illustrative" or with an asterisk are invented to show the shape.

The common failure is flatness: every surface puts its whole object set,
every control and every explanation on one plane, so nothing tells the
operator where to look first. The fix is a fixed layering, applied the same
way everywhere.

## 2. The layering rule

Every product area has up to four layers. Cloudflare's console is the
reference for the shape (account home, product overview, collections,
object, settings); the content is ours.

```
L0 Overview    what is wrong, what changed, what runs out, one picture
L1 Collection  the objects, dense, filterable, grouped the way the operator thinks
L2 Object      one object: identity, state, proof, relations, actions
L3 Settings    defaults and policies that change rarely
```

Rules that make the layering hold:

1. **L0 is the default route of an area** and fits one desktop screen. It
   opens with an attention list (only when non-empty; each item is a claim,
   the row that proves it, and the action that clears it), then at most four
   numbers that move, then the area's one picture. No L0 is a wall of equal
   tiles.
2. **Layers are routes, not stacked panels.** An area has one tab row for its
   layers (`Overview · <Collection> · Settings`), mirrored in the URL
   (`?view=`). There is never a second tab row inside the first.
3. **L1 columns hold values at the level they belong.** A group row (node,
   bank, stage) shows aggregates that span; it never leaves member columns
   blank. Status that is identical on every row moves to the header as a
   count and leaves the row.
4. **One row, one affordance.** Clicking a row opens the object in a side
   panel (L2 peek) with "Open page"; secondary actions live in one row menu.
   No row carries Open, a menu, and a chevron at once.
5. **L2 is addressable.** A side panel is `?open=<id>`, a full object page is
   its own route; refresh and share land on the same object.
6. **L3 is out of the daily path** and says what it governs.
7. **375px:** the layer tabs become a segmented control that scrolls
   sideways; L0 stacks (attention, numbers in two columns, picture); L1
   tables keep columns with the first one sticky; side panels become full
   height sheets.

The proof line (`observed 43s ago · 25 collectors · via usage reports`)
stays the signature element on every layer.

## 3. Expiring: one list of what runs out, and reminders that fire

### Objects

| Kind | Source of truth | Due field | Already notifies |
|---|---|---|---|
| Machine renewal | inventory `MachineProfile` | `next_renewal`, `auto_roll` | yes, per machine opt-in (off everywhere) |
| VPN user expiry and quota | proxy users | `expires_at`, `quota_bytes` | yes (`proxy.expiry`, `proxy.quota`) |
| TLS certificate | tls monitors | `cert_not_after` | yes, as a monitor transition |
| Subscription share | host shares | `expires_at` | no |
| Provider subscription | Sub-Store record `userinfo` (`expire`, `total`, `upload`, `download`) | `expire`, traffic ratio | no (phase 2, see section 4) |

### Behaviour changes (server)

1. **Default on.** A machine with a renewal date is reminded unless the
   operator turned it off. New profiles default `reminders_enabled` to true.
   A one-time migration (guarded by a stored marker, audited as
   `inventory.reminders.default_on` with the machine ids) turns it on for
   every existing profile that has a `next_renewal`. Profiles keep their own
   offsets; a profile with none gets `14, 7, 3, 1, 0`.
2. **Digest.** One evaluation run sends one message. Several machines firing
   together become `Lattice: 4 renewals due` with one line each
   (`10-20  openjobs-vpn-dmit-1  7d  USD 5.00`), the soonest first, and a
   total. A single fire keeps today's title.
3. **Auto-roll wording.** For `auto_roll` machines the reminder says the date
   will roll and the charge to expect (`auto-renews 10-20, USD 5.00`); they
   never produce "overdue" because the date advances itself.
4. **Overdue repeats.** A manual machine past its date is reminded once a day
   for seven days, then stops; marking it renewed ends the run.
5. **Read model.** `GET /api/expiring?within=60d` returns one sorted list
   across machine renewals, VPN users, shares and TLS monitors:
   `{kind, id, title, due_at, days, state (upcoming|due|overdue|auto),
   cost_cents, currency, href}` plus totals per currency. `inventory:read`
   rows need that scope; rows the session cannot read are omitted and counted
   (`hidden: N`), never silently dropped.

### Console

- Home gets an **Upcoming** panel: the next 30 days from `/api/expiring`,
  grouped by week, with the cost total, and a link to the full list.
- Inventory's renewal grouping stays; each machine row shows whether its
  reminder is on, and the editor explains the default.
- Notifications gains a line under each rule that routes `inventory.renewal`
  saying how many machines it covers and when the next one fires.

## 4. Sub-Store: the pipeline is the page

### Object model

| Object | Operator's word | Relations |
|---|---|---|
| Source | subscription (`sub`): provider link, pasted nodes, this fleet, a relay path | feeds combinations and files |
| Combination | combination (`collection`) | members are sources, by name or tag |
| File | client file (`file`): a config for one client app and person, `for-cdcd-loon` | renders a source or combination for one target |
| Share | share (host) | publishes one record at one URL |

Production is exactly this chain: four pasted sources and one provider link,
two combinations, sixteen files named for a person and a client
(`for-openjobs-shenzhen-loon`), and one share. Today the four kinds sit in
separate tabs and nothing shows which file a phone fetches or what a source
feeds.

### Layers

```
+------------------------------------------------------------------------------+
| Sub-Store                                               [Search] [New v]      |
| observed 12s ago · engine ok · 23 records · 1 share live                      |
| [Overview] [Sources 5] [Combinations 2] [Files 16] [Shares 1] [Settings]       |
+------------------------------------------------------------------------------+
| ATTENTION                                                                     |
|  建材市场 provider expires in 6 days · 82% used (illustrative)  [Open]        |
|  15 files are not published, so no client can fetch them        [Review]      |
+------------------------------------------------------------------------------+
| SOURCES            COMBINATIONS          FILES                   SHARES       |
| [建材市场 166>25 !]─┐                                                          |
| [cdcd-self-host 23]─┼─[merge-cd-openjobs 101]─┬─[for-cdcd-loon]──[/s/cdcd]    |
| [openjobs-host 78]──┘                        ├─[for-cdcd-stash]    (none)     |
| [openjobs-host-trojan 26]─[merge-openjobs 78]─┴─[for-openjobs-...] (none)     |
| ... 16 files, grouped by person when names share a prefix                    |
+------------------------------------------------------------------------------+
```

- **L0 Overview.** The picture is the lineage map: four columns (sources,
  combinations, files, shares), one compact chip per record (name, nodes in
  and out, a state dot), edges for every dependency the records declare.
  Selecting a chip highlights its upstream and downstream path and dims the
  rest; the side panel opens on it. Files group by the prefix before the
  client name when three or more share it (`for-openjobs-*`). Attention
  items: provider expiry within 14 days or traffic above 80 percent, fetch
  failures, files with a missing member, combinations nothing uses, files not
  published, shares expiring.
- **L1 collections**, one table each, columns that mean something for that
  kind:
  - Sources: name, kind, nodes in to out, steps, provider traffic bar and
    expiry (provider links only; "n/a" is never printed, the cell is empty
    with a reason on hover), last fetch, used by.
  - Combinations: name, members, nodes, used by.
  - Files: name, client target, renders (source or combination), published
    (share path, or a Publish action that opens the host share form
    prefilled), last render.
  - Shares: path, record, format, expiry, enabled.
  The `migrated` and `imported` markers become a filter facet, not a chip on
  every row. The row opens the side panel; the menu carries duplicate,
  export, delete.
- **L2 record page** (`/plugins/latticenet.sub-store/sub-store?record=<id>`):
  header with name, kind, lineage breadcrumb (feeds 2 combinations, 5 files),
  proof line; tabs Nodes (the compare panel from the September program:
  source against result with the per-step delta strip), Steps (the operation
  chain), Source (provider URL masked after the host, revealed for sixty
  seconds), Output (files only: what the client receives), Publishing.
- **L3 Settings** unchanged in content.

Provider traffic and expiry come from the stored `userinfo` header. The
`subscription.list` method returns it parsed (`upload`, `download`, `total`,
`expire`) so the list and the overview never call `get` per row. Phase 2
contributes provider expiry to `/api/expiring` and to notifications.

## 5. Lines: routes, traffic, attention

### Layers

```
+------------------------------------------------------------------------------+
| Lines  VPN CORE PLUGIN                                   [Refresh] [Roll out]  |
| observed 40s ago · 24 nodes report · 136 lines · 25 collectors ok              |
| [Overview] [Lines 136] [Topology] [Attention 2]                                |
+------------------------------------------------------------------------------+
| ATTENTION  2 lines report no outbound target            [Show]                 |
+------------------------------------------------------------------------------+
| 313 GB egress 7d  +12%* | 24 egress nodes · relay hubs | 136 lines, 0 managed  |
+------------------------------------------------------------------------------+
| ROUTE MAP (7d traffic)                                                        |
|  RELAY HUBS                         EXITS                                     |
|  [DMIT-1]  ════ 12 lines ═══════▶  [qqpw-cd2-VDS]    33.5 GB                  |
|  [hk-turin-mini] ═══ 24 ════════▶  [VIRCS-ATT-VDS]   97.6 GB                  |
|  [mkcloud-hr-iplc] ── 4 ────────▶  [DMIT-eb-wee] ─▶ [nat-us… off-fleet]       |
|  (stroke width = bytes, colour = worst line state on the edge)                |
+------------------------------------------------------------------------------+
| NODES   by traffic                                                            |
| node                 role        lines  7d egress   trend      service         |
| [Metix]-VIRCS-ATT…   exit        2      97.6 GB     ▂▃▅▆▅▇▆   running 2/2      |
| [Metix]-DMIT-1       relay hub   13     15.2 GB     ▁▂▂▃▂▂▃   running 13/13    |
+------------------------------------------------------------------------------+
```

- **L0 Overview.** Attention first. Three numbers: egress for the period with
  change against the previous one, the route shape (exits, relay hubs), and
  lines with how many are managed (a plain count, not a warning colour:
  discovered is a legitimate state). The picture is the route map: relay
  hubs on the left, exits on the right, one edge per node pair, stroke width
  by bytes over the period, colour by the worst line state on the edge,
  off-fleet endpoints dashed. Below it the node table sorted by traffic,
  with a seven-day sparkline and service as `running 13/13`.
- **L1 Lines.** One table, grouped by node by default (group-by: none, node,
  bank, exit). Group rows span their member columns with aggregates (`13
  lines · 12 relay · bank of 12 vless to 7 exits · 15.2 GB`), so no column is
  empty on a group row. Line columns: line, role, protocol and port, target
  (the exit a relay dials, by node name), users, 7d traffic, state. Status
  identical on every row ("ok", "running") is not repeated per row; the
  header says `136 running · 0 config errors`, rows show state only when it
  differs. Search flattens to matching lines. The per-row Evidence button
  moves into the row menu and the side panel.
- **L2 line panel** (`?open=<line_hash_id>`): identity (tag, node, protocol,
  port, SNI), the chain it belongs to drawn as a path (entry, relay, exit,
  each with state), users, a daily traffic chart for the period, Evidence
  links (Connections and Raw log prefilled with node and line), and the
  existing actions (reattach, sync metadata, reveal credential behind its
  gate).
- **Topology** keeps the September rules and becomes the full-size route map.
- **Settings** is Node Profiles, which stays its own nav entry.

## 6. Usage: time first, identity when it exists

### Layers

```
+------------------------------------------------------------------------------+
| Usage  VPN CORE PLUGIN                    [Today] [7 days] [30 days] [All]     |
| observed 40s ago · 25 of 25 collectors ok · 1 of 134 lines attributed          |
| [Overview] [By node] [By line] [By user]                                       |
+------------------------------------------------------------------------------+
| 313 GB left the fleet in 7 days   +12%* vs previous 7 days                     |
| 255 GB of it entered through relay hubs, counted once here                    |
| ┌ daily egress, stacked by exit (top 6 + others) ──────────────────────────┐   |
| │ ▇▇ ▆▆ ▇▇ ██ ▅▅ ▆▆ ▇▇                                                      │   |
| └ 09-23 ... 09-29 ──────────────────────────────────────────────────────────┘   |
+------------------------------------------------------------------------------+
| TOP EXITS                                                                     |
| node                egress   share  trend    allowance                         |
| [Metix]-VIRCS-ATT   97.6 GB  31%    ▃▅▆▇     — (set in Inventory)              |
+------------------------------------------------------------------------------+
```

- **Headline figure is egress:** bytes on exit, direct and shared lines
  (a shared line is a chain target that also serves direct users), counted
  once at the node where they leave the fleet, which is what a provider
  bills. Entry bytes on relay hubs
  are the same traffic counted a second time; the page says so in one
  sentence instead of a "double counted" tile.
- **The picture is the daily series:** stacked bars per day, top six exits
  plus "others", with a toggle to stack by role. It needs one server field:
  `usage.query` returns `series: [{day, node_id, role, bytes}]` summed from
  the daily rows the server already keeps (`usage_day_node`).
- **Top exits** shows egress, share, trend, and the machine's transfer
  allowance when Inventory has one (phase 2 adds `transfer_quota_bytes` and a
  reset day to the machine profile, with a forecast to the end of the cycle
  and a notification at 80 and 100 percent).
- **Measurement quality moves to the proof line** (collectors reporting,
  lines attributed); the "estimated" and "unattributed" registers stay on
  the rows they qualify.
- **By user** keeps quota bars and expiry. When fewer than a tenth of the
  bytes carry an identity, it opens with that fact and the action that fixes
  it (bind users to lines, in Users), instead of an empty panel.

## 7. Evidence: collect first, then ask one question

### Layers

```
+------------------------------------------------------------------------------+
| Evidence   Logs and connection trace from the nodes                            |
| trace store 0 records · encrypted · 2 GiB cap · 0 of 34 nodes collecting       |
| [Overview] [Explore] [Collection]                                              |
+------------------------------------------------------------------------------+
| Nothing is being collected                                                    |
| Connection records exist only where collection is on. Start a capture for     |
| the nodes you are debugging; it stops by itself.                              |
|   nodes [ DMIT-1 x ] [ + ]   for [ 1 hour v ]          [Start capture]         |
+------------------------------------------------------------------------------+
| NODES           trace         raw log                  held                   |
| DMIT-1          off           none                     0                      |
| legend-sg       off           sing-box, last 08-27     82 lines (stale)        |
+------------------------------------------------------------------------------+
```

- **L0 Overview** leads with coverage, because nothing else on the page means
  anything without it: the store line, a per-node table (trace on or off,
  raw log sources with their last ingest, records held, stale marked), and
  the one primary action, a time-boxed capture on chosen nodes. When records
  exist it adds the last hour's connection count, failure count by close
  reason, and the top destinations.
- **L1 Explore** is one toolbar: a time range, a lens switch (Connections,
  Raw log) and one query field with tokens (`node:`, `user:`, `line:`,
  `dest:`, `reason:`, `stalled`). The chip groups (close reason, user kind)
  move into a Filters popover whose choices appear as tokens in the field.
  There is one search box, not two, and the implementation notes about
  cursor paging leave the page. Results are the table; a row opens the side
  panel with the hop path and raw lines (`?conn=<id>`). Every filter stays in
  the address bar.
- **L3 Collection** is the per-node policy table and the capture session
  history.

## 8. Delivery

| Slice | Repos | Ships as | Gate |
|---|---|---|---|
| A. Expiring and reminders (section 3), usage `series` (section 6) | server, dashboard | server image `alpha-0.2.2a98` | CI, review, precheck, switch under the standing deploy mandate |
| B. Evidence (section 7) | dashboard | same image | CI, design review at 1440 and 375 |
| C. Lines and Usage (sections 5, 6) | vpn-core | `0.9.0-alpha.1` prerelease | CI, design review, then the operator's signing ceremony and plugin switch |
| D. Sub-Store (section 4) | sub-store | `0.14.0-alpha.1` prerelease | as C |
| Phase 2 | server, sub-store | later | provider expiry in `/api/expiring`, machine transfer allowance |

C and D need the operator: plugin signing and switching the plugin set are
two of the four reserved decisions. The UIs degrade when the server fields
they want are absent (no `series`: the chart is replaced by the per-exit
totals it would have stacked), so plugin and server can ship in either order.

## 9. Acceptance

- Every area opens on L0 and fits one 1440 by 900 screen before the fold
  with production-shaped data; no view has two tab rows.
- No L1 table shows a column that is blank on every row of a group level.
- A reminder fires for a machine created with defaults and a renewal date
  inside its offsets, and several fires in one run arrive as one message.
- `/api/expiring` lists machine renewals, VPN users, shares and TLS monitors
  in date order, and counts the rows a scope hides.
- Usage's headline equals the sum of exit, direct and shared line bytes
  for the period.
- Evidence with zero records shows coverage and the capture action, not a
  filter form above an empty table.
- Each surface is rendered and driven at 1440 and 375, light and dark, with
  the empty, failing and dense fixtures, and reviewed by the design reviewer.
