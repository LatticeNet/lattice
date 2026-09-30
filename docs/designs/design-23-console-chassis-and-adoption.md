# Design 23: one chassis for every page

Written 2026-09-30 against production `alpha-0.2.2a100` (vpn-core
`0.9.0-alpha.1`, Sub-Store `0.14.0-alpha.1`, NetGuard `0.1.0`, WireGuard
`0.1.0`). Status: accepted by the operator's request of the same day
("整个网站的交互逻辑，还有插件的 ui 可以再继续优化吗 ... 对于数据、信息都能
有更好的呈现方式，还有交互的逻辑都符合用户的体验"), build in progress.

Design 22 fixed four surfaces (Sub-Store, Lines, Usage, Evidence) and the
operator liked them. This design takes the same rules to the other thirty
console pages and the three plugin screens design 22 did not touch. Design
22 section 2 (the layering rule) stays the authority; this file adds the
shared components that make the rule cheap to follow, the page-by-page
application, and the server reads the pages need.

## 1. Why this exists

Four read-only audits on 2026-09-30 walked every console route and plugin
screen at 1440 and 375 with production-shaped data. Production that day:
34 nodes (32 online), 1,351 approvals (0 pending), 1,771 tasks (243
failed, 1 stalled), more than 200,000 audit events (1,021 node flips in 23
days), 22 DDNS profiles, 33 agent-update policies, 134 VPN identities (1
attributed), and zero monitors, DNS deployments, tunnels, network policies,
webhooks and tokens.

The findings share one cause: every page solved the same problems on its
own.

| Meaning | Ways it is done today |
|---|---|
| Freshness | a "Live" pill on 22 views with one fixed 8 s threshold (it flickers amber on pages polling every 12 s and turns red on pages that never poll); the design-22 proof line on 6 |
| Opening one object | a sticky side column (Approvals), a centred dialog held in a local ref (Tasks), inline JSON plus a dialog (Audit), a full page with no peek (Nodes), an editor (Map, Groups), a side sheet on `?conn=` (Evidence); only the last survives a reload |
| Filtering | `AND(plugin:x)` expressions, `action=task.*` prefixes, `key:value` tokens, chips, selects |
| Headline numbers | four components; home shows nine |
| Row actions | a row click plus two to four buttons, hover-only icons invisible on touch, chevrons, menus |
| Destructive actions | no confirm (Publishing host bindings and storage tokens), a plain confirm, a typed name, and deletes that leave config running on the node (Network Policy, Self-host DNS, Tunnels) |
| 375 px tables | cards by default, which the layering rule forbids |

Some findings are plain defects and ship first (section 6, wave 1): home's
"Tasks unknown" (the tile reads all 1,771 tasks every 10 s and each tick
cancels the previous request, so a reply slower than the interval never
lands); Audit printing a partial scan count as the total; Map overflowing
to 1,414 px at 375; "118msms" on Monitoring; and the two one-click deletes
on Publishing. The edge also served JSON, JavaScript and CSS uncompressed
(`gzip_types` was left at nginx's default); that was fixed on hkg the same
day and cut the task list from 847 KB to 149 KB on the wire.

## 2. Decisions

- **The sidebar stays the area navigation.** Cloudflare puts an area tab
  row above its products; moving thirty sidebar entries into tab rows would
  move navigation under the operator, which the interaction bar forbids.
  Each sidebar page is a collection with its own head (proof line,
  attention, at most four numbers). Pages that hold several object kinds
  (Approvals, Tasks, Audit, Publishing, Evidence, Access) get one layer tab
  row on `?view=`. The one navigation change is folding Users, Access
  Tokens and SSO into one Access page; each holds zero to two rows.
- **The proof line replaces the "Live" pill everywhere.** A 10 s poll is
  not live, and "observed 12s ago · 34 nodes report" says what the page
  actually knows. A failed read never shows zeros.
- **Tables scroll at 375 with the first column sticky.** Cards stay opt-in
  for lists whose rows are read one at a time (approval events, attention
  items), never for rows that are compared.
- **One query grammar.** `key:value` tokens whose keys equal the URL keys
  and the HTTP parameters (Evidence already works this way), so a URL maps
  to one API call. The `AND(...)` expression dialect retires in wave 2.
  An old link whose expression uses only supported fields is translated
  once; anything else lands on the default view with a notice naming what
  was dropped.
- **Destructive actions are classed by what breaks** (section 3.8), not by
  the page that hosts them.
- **Plugins follow the same rules through their chassis.** NetGuard and
  WireGuard use the plugin-bridge chassis (`Pc*` components); vpn-core
  still has its own kit and moves onto the chassis in wave 3.

Trade-offs accepted: changing the table's narrow default touches 44 tables
at once, so wave 1 re-renders every harness at 375 before it merges;
retiring the expression dialect costs a syntax some pages advertise, and
the token grammar covers every field those expressions reach.

## 3. The chassis

Each component lives in `lattice-dashboard/src/components/common/` unless
noted, has unit tests for its model, and is the only way a page may render
its meaning once wave 2 lands.

### 3.1 ProofLine

Generalised from `components/fleet/UpcomingProof.vue` and the Terminal,
SSH Guard and Evidence proof lines.

```ts
type ProofState = "loading" | "observed" | "refreshing" | "stale" | "failed" | "idle";
interface ProofSegment { key: string; text: string; tone?: "default" | "muted" | "warning" | "destructive"; to?: RouteLocationRaw }
props: { state: ProofState; observedAt?: number | null; segments: ProofSegment[]; pollMs?: number; error?: string | null }
```

| State | Renders |
|---|---|
| loading | "reading ..." and no segments |
| observed | "observed 12s ago · 34 nodes · 2 offline" |
| refreshing | the observed line with a quiet spinner, never a blank |
| stale | "last good 3m ago · refresh failed: <reason>" with the last segments muted |
| failed | "not read: <reason>" with a retry, and no segment that states a count |
| idle | the observed line without an age; used when the page does not poll |

A page becomes stale at 1.5 times its poll interval. `useProof(query)` maps
a `useAsyncData` result to these states so pages do not compute them.
Until a page adopts ProofLine, `FreshnessLabel` takes the same threshold
from the query's interval and hides when the page does not poll (wave 1).

### 3.2 AttentionList

```ts
interface AttentionItem { key: string; tone: "danger" | "warning" | "info"; claim: string; proof?: string; action?: { label: string; to?: RouteLocationRaw; run?: () => void } }
props: { items: AttentionItem[]; max?: number /* 5 */ }
```

Renders nothing when empty. Each item is the claim, the row that proves it,
and the action that clears it. Beyond `max`, "Show all N". Information
items are listed but never counted in a badge or a headline number
(design 22, as built). Home, every page head and the plugins use it.

### 3.3 MetricStrip

The existing component, capped: a page head shows at most four numbers, and
only numbers that move. Totals that only grow (all-time failed tasks,
"Total 1311") and static configuration (trust posture tiles) leave the
strip; they belong in the proof line or in Settings. `StatCard` and the Map
tiles are deleted.

### 3.4 LayerTabs and useLayer

`useLayer(allowed, fallback)` is `useRouteTab` on the `view` parameter.
`LayerTabs` is the underline tab row Evidence uses, one per page, scrolling
sideways at 375. Segmented pills stay for modes inside a layer (a table's
group-by, Usage's stack toggle). Pages that use `?tab=` today move to
`?view=` and read `?tab=` once for old links. Nodes' card or list switch
moves from `?view=` to `?layout=`.

### 3.5 ObjectSheet and useRouteOpen

Lifted from `views/platform/EvidenceConnPanel.vue`.

```ts
useRouteOpen(param = "open"): { openId: Ref<string | null>; open(id: string, opener?: HTMLElement): void; close(): void }
ObjectSheet props: { open: boolean; title: string; subtitle?: string; pageTo?: RouteLocationRaw; state?: "ready" | "loading" | "gone" | "stale"; readOnly?: boolean }
```

A row click opens the sheet on `?open=<id>` (history replace). Escape and
the close button return focus to the row that opened it. "Open page"
appears when the object has its own route. At 1440 the sheet is 36 to
44 rem wide beside the collection; below 768 px it is a full-height sheet,
which fixes the Approvals phone defect (a tapped row selected an object
rendered 5,000 px below). `gone` says the object no longer exists and
offers the collection. Tasks' old `/tasks?id=` link resolves to
`?open=`.

### 3.6 RowMenu

On reka-ui `DropdownMenu` (the console has no wrapper yet). The trigger is
a ghost icon button labelled "Actions for <name>", always visible (no
hover-only controls). Items carry `label`, `icon`, `disabled` with an
inline `reason` (touch has no tooltip), and `danger`. Danger items sit
last, after a separator. A row has one click target (the sheet) and one
menu; no row carries a chevron, a Details button and inline icons.

### 3.7 DataTable

- No toolbar (search, expression field, help line) when the table has zero
  rows and no active filter. The empty state carries the create action; the
  header does not repeat it.
- `narrowLayout` defaults to `"scroll"`: columns stay, the first column is
  sticky and capped at 38 vw (Evidence's `pin-start`), row actions pin to
  the end. `"cards"` is opt-in.
- `rowClick` plus `activeRowId` highlight the open row; the focus ring is
  drawn inside the row (`focus-row`).
- Group rows show aggregates that span the group (design 22 rule 3).

### 3.8 ConfirmDialog and the destructive classes

`ConfirmDialog` gains `impact?: string[]` (what stops working, one line
each) and `typedConfirm?: string` (the name the operator types).

| Class | Examples | Treatment |
|---|---|---|
| Reversible | disable a node or plugin, pause a policy | default button style, no dialog or a plain one; never filled red |
| Irreversible inside Lattice | delete a draft, delete a cost profile | destructive, `impact` lines |
| Breaks something outside Lattice | delete a host binding (a live URL goes offline), revoke a storage token (clients break), delete a share, run DDNS now (writes public DNS), send all reminders now (Bark pushes) | destructive, `impact` lines, `typedConfirm`; sends and runs show a preview of what goes out |
| Leaves config on a node | delete a network policy, a DNS deployment, a tunnel | wave 3: the delete first files a removal plan and deletes the record after it applies; until then the dialog names the node and what keeps running, with `typedConfirm` |

### 3.9 QueryBar

Lifted from the `EvidenceExplore.vue` toolbar and its tokenizer (quoting,
escapes, name-before-lists-load wait). A range control (presets plus custom
since and until), a token field whose keys are the URL and HTTP keys, node
names resolved to ids through a resolver prop, a Filters popover whose
checkboxes write the token they show, and Apply. The model moves to
`src/lib/queryTokens.ts`. Wave 1 moves Evidence onto it to prove the
extraction; wave 2 moves Approvals history, Tasks and Audit.

### 3.10 Smaller rules

- Breadcrumbs link (Section / Collection / Object); an H1 never repeats the
  section.
- Page gutter `p-4 sm:p-6` everywhere (SSH Guard uses `p-3`, Capability
  Gates has none).
- Every two-column page grid starts at `grid-cols-1 min-w-0`, so a long
  list can never size the track (the Map defect).
- Node identity is always the node's name through one `NodeLabel`, never a
  raw `node_...` id (Approvals targets, Audit rows).
- Outcomes use a toast; field errors stay inline. Plugins get a bridge
  toast in wave 3 (today they print banners at the page top, off screen
  when acting on row 80).
- A page that holds operator-only data (users, tokens, SSO) does not poll.

## 4. The console, page by page

Wireframe numbers are production values from 2026-09-30 unless marked with an
asterisk (illustrative).

### 4.1 Home

```
Attention  DMIT-4 offline 6d [Open] · 1 task stalled 6d [Tasks] · 2 DDNS failing [DDNS]
32/34 online | 0 approvals waiting | 5 tasks failed in 24h* | 0 due in 7 days
Due in 7 days (at most 5 rows)                 Fleet at a glance (map thumbnail)
observed 4s ago · 34 nodes · via agent reports
```

The tasks figure comes from `/api/tasks/counts` (section 5). Flapping
nodes are an attention item; disabled nodes are not. Trust posture moves to
Settings. Recent activity shows changes, not node flips.

### 4.2 Fleet

- **Nodes.** Head: "34 nodes · 2 offline · 1 degraded · 4 agent versions".
  Search, status and group-by (owner tag by default) live in the URL.
  Columns that hold one value on every row ("online", the same capability
  string on 25 rows) leave for the head; Last seen, agent version and CPU
  show by default. A row opens the node sheet (status, why it is offline,
  running tasks, lines, SSH Guard, "Open page"); Terminal, Rotate and
  Disable move to the row menu. Enroll moves from an inline card to the
  header.
- **Node page.** Layers `Overview · Activity · Settings`. Overview leads
  with state (status, reason, what runs on it, what waits on it); Settings
  holds identity, IP discovery, launch profile, geo, auto-update,
  diagnostics and the danger zone last, with one save pattern. The sticky
  header shrinks to one line (name, status, Terminal); it takes 41% of a
  phone screen today.
- **Machines (Inventory).** A grouped table replaces the wall of 34 cards:
  group by billing (default), provider or region, with group rows carrying
  monthly cost per currency. The head states each currency ("CNY 3,426/mo ·
  USD 354/mo") instead of converting only what it has a rate for. "Run all
  reminders" becomes "Preview reminders" with the send behind it. A
  machine opens in the sheet; the editor opens from there.
- **Map.** The grid fix ships in wave 1. Markers cluster with counts and a
  click opens the node sheet; editing a location moves to the node's
  Settings. The phone hint about trackpads goes.
- **Monitoring.** With zero monitors: one sentence and two actions (watch
  an HTTP endpoint, watch a TLS certificate, which feeds Upcoming).
  Otherwise the list, the sheet, and Create in a sheet. A passing probe at
  120 ms is not amber.
- **Groups.** Each group row shows member health; the editor opens in a
  sheet; the selection is in the URL.

### 4.3 Operations

- **Approvals.** Layers `Needs you · History · Stuck`, defaulting to Needs
  you when it has items and History otherwise (production has 0 pending,
  so today the default is an empty inbox). History is one server query
  through the QueryBar (`node`, `plugin`, `actor`, `since` already exist on
  the API) instead of walking 200-row slices. A row opens the plan in the
  sheet: diff, hash, decision, and the task that applied it. The decision
  row orders Approve, then Approve and queue, then Reject last.
- **Tasks.** Layers `Runs · New task`, opening on Runs (the composer takes
  the first screen today). Each run row shows the script's first line, the
  targets with a pass count, and the failure reason ("exit 127: curl: not
  found"). The sheet lists per-node results with failed nodes expanded to
  stderr. Rerun sits in the row menu; Delete is the last menu item. The
  head counts failed in 24 hours, not failed ever.
- **Audit.** Layers `Changes · All events · Integrity`. Changes excludes
  node online and offline flips and observe events (server parameter,
  section 5) and opens on the last 24 hours. The proof line states what was
  scanned ("412 of 412 scanned", or "at least 50,000, scan stopped at 200,000"). A
  row opens the event in the sheet with its correlation trace
  inline; metadata JSON leaves the row. Paging stops polling when the
  operator is past page 1. Verify chain moves to Integrity with its last
  result in the proof line.
- **Terminal.** Keep it; write the node and session to the URL and link the
  "audited" segment to Audit.

### 4.4 Networking

- **DDNS.** Head: "22 profiles · 19 current · 2 failing · 1 stale". A
  profile is stale when its last run is older than twice its interval (the
  API returns `interval_seconds`; the page never showed it). Attention
  lists failing profiles with the error, stale ones, and profiles on
  offline nodes. Group by node, with the node's status on the group row.
  "Run now" writes public DNS, so it has its own icon and a confirm; the
  play icon keeps meaning "create a plan" elsewhere.
- **Network Policy.** The group matrix is the overview picture and a cell
  click writes a rule. The Graph tab goes; a node's edges show in its sheet
  when edges exist. Full node names (all 13 `[Metix]-` nodes read the same
  at 8 characters). The page says NetGuard also writes nftables and links
  to it.
- **Self-host DNS, Tunnels, Geo-Routing.** Real empty states with a
  checklist computed from live state ("0 of 1 prerequisites ready: no node
  runs self-host DNS"). Rows get the row menu. Geo's demo row stops reading
  green "configured" beside "last applied: never".
- **SSH Guard.** Light touch: one chip strip that scrolls sideways instead
  of five wrapped lines at 375; the green badge says what it means
  ("password login off") when the same row shows an amber port.

### 4.5 Platform

- **Plugins.** One list for every reader (name, version, runtime state,
  pages it contributes, whether a newer version exists); the permission
  split into two tabs goes. A row opens capabilities, digest and
  transitions in the sheet. Verify manifest moves to a secondary action;
  Disable is not red.
- **Publishing.** Layers `Overview · Routes · Tokens · Buckets`. Overview's
  attention names anonymous routes and shares that expire. The three
  always-open create forms move into sheets behind one "Publish" menu. The
  normal "Serving" state is quiet; "Anonymous" is the loud one. Shares
  stops being a page inside the page and uses the sheet. Host binding
  delete and token revoke use the outside-breaking class (wave 1).
- **Agent Updates.** Head: "34 nodes · 29 current · 5 behind" from
  `Node.agent_version`, with the one node that has no policy named in
  attention. A version bar replaces the four equal tiles. "Plan behind
  nodes (5)" files one plan per behind node after a confirm that lists
  them.
- **Store, Webhooks.** Store uses Tabs like Publishing; Webhooks' selection
  moves to `?open=`.

### 4.6 Settings

Users, Access Tokens and SSO become one Access page with layers `Users ·
Tokens · SSO`; old routes redirect. None of them polls. Rows use the row
menu (Revoke and Delete stop sitting side by side). Security and 2FA stays
its own page because the MFA guard redirects there. Capability Gates gets
the page gutter.

## 5. Server reads

| Read | Change | Why |
|---|---|---|
| `GET /api/tasks/counts` | new: `queued`, `running`, `stalled`, `failed_24h`, `finished_24h`, `total`, `generated_at` | home and Tasks stop reading 1,771 rows to count them |
| `GET /api/tasks` | add `status` (comma list), `since`, `node_id`, `origin` filters beside the existing `limit` and `offset`; response shape unchanged | Tasks lists one page of what the operator asked for |
| `GET /api/task-results` | honour `limit` under `omit_output`; add a `task_id` comma list | the results poll stops returning every result |
| `GET /api/audit` | add `exclude_action` (comma list of prefixes, at most 16) | the Changes layer hides node flips on the server, so paging and counts stay true |
| dashboard types | surface the `scanned` and `complete` fields the audit response already carries | Audit stops calling a partial count the total |

Everything else the pages need exists: approval history filters,
`interval_seconds` on DDNS, `agent_version` on nodes. Removal plans for
policies, DNS deployments and tunnels are wave 3.

## 6. The plugins

- **vpn-core Users** (134 identities, a 10,370 px page today). Head: "134
  identities · 122 enabled · usage attributed for 1". Attention: identities
  that expire within 30 days, and identities with no binding (the
  credential authenticates nowhere). A searchable, sortable table with
  group-by (group, status); expiry and group get columns, and columns that
  are blank on every row collapse into the head. A row opens the identity in
  the side panel (credentials, bindings through a searchable picker instead
  of a 136-option select, per-node usage). Edit, Rotate, Bindings and Delete
  move to one row menu. An expiry can be cleared. Outcome notices appear
  next to the row that was acted on, until the bridge toast exists. At 375
  the first column is sticky, not the actions column.
- **vpn-core Node Profiles.** Exceptions sort first; values identical on
  all 25 rows leave for the head ("25 nodes · 25 collectors ok · 0
  managed"). Configure opens the side panel. The save ends today in a
  command the operator must run on the node by hand; if the host API lets
  the plugin file an approval, the save files one, otherwise that stays a
  wave 3 item.
- **NetGuard.** A new Overview layer: attention for ports open with no rule
  and for drifted nodes, then enforced, unexplained, drift and observe-only
  as the four numbers, then an exposure picture. Nodes is the exposure
  table with a row click to the side panel (the expanded row grows to 1,700
  px today). "Adopt baseline" gets a confirm that previews the ruleset the
  next apply installs. "Ignore" says it lasts for this session.
- **WireGuard.** Overview opens with why the mesh cannot form ("0 of 34
  ready: 34 report no WireGuard interface") and the action that changes it,
  then one readiness bar instead of four tiles. The fleet table groups by
  what each node lacks and drops columns blank on every row. The proof line
  counts agents online and mesh-ready separately, and a failed read shows no
  counts. Mesh becomes a compact list. The key-safety notice moves into the
  Plan dialog, and a disabled Plan says why inline.

## 7. Delivery

| Wave | Contents | Repos | Ships as |
|---|---|---|---|
| 1 | the chassis (section 3), the wave-1 defects and safety fixes (section 1), Evidence on the QueryBar, the server reads (section 5) | dashboard, server | `alpha-0.2.2a101` |
| 1 | vpn-core Users and Profiles; NetGuard Overview; WireGuard readiness | vpn-core, netguard, wireguard | `0.10.0-alpha.1`, `0.2.0-alpha.1`, `0.2.0-alpha.1`, signed under the operator's 2026-09-30 authorization, prereleases, never Latest |
| 2 | every console page onto the chassis (section 4): home and Fleet; Operations; Networking, Platform and Settings | dashboard | `alpha-0.2.2a102` |
| 3 | removal plans before deletes; the bridge toast; object search in the command palette; vpn-core onto the plugin chassis | server, dashboard, plugin-bridge, vpn-core | later |

Wave 2 starts when the wave 1 chassis is on `integration`, so its three
lanes read the components instead of inventing them. Each lane passes
code review, a design review at 1440 and 375 in light and dark with the
empty, failing and dense fixtures, and CI; each release passes the
isolated precheck.

## 8. Acceptance

- No page renders a "Live" pill; every page shows a proof line, and a failed
  read shows no count.
- Every collection opens objects one way (a sheet on `?open=`, or the
  object's page), and a reload lands on the same object.
- No row carries more than one click target and one menu; no control
  appears only on hover.
- Every destructive action belongs to a class in section 3.8 and gets that
  treatment; none of the outside-breaking class fires on one click.
- No page head shows more than four numbers, and none of them only grows.
- At 375 no page scrolls sideways, and every compared table keeps its
  columns with the first one sticky.
- Home shows the task counts from the counts read, never "unknown" while the
  read succeeds.
- Audit's proof line states whether the scan completed.
- Every changed page is rendered at 1440 and 375, light and dark, with
  production-shaped fixtures, and reviewed by the design reviewer.
