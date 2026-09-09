# Lattice surface redesign program (2026-09)

Gate 1 brief for the surfaces the operator named on 2026-09-01. Nothing in this
file is code; it is the system, the object models, the wireframes and the state
contracts that the code has to satisfy, plus the acceptance evidence each slice
owes before it is called done. It sits next to the workspace-root `PROGRAM.md`, which stays the
ledger of what shipped; this file is the design contract for the M5 wave.

Every section is written from first-hand study of the production surfaces,
the source, and the plugins' dev harnesses on 2026-09-02. Two research lanes
(`substore-study`, `surface-audit`) were started for the same ground and had
not reported by the time the sections were written; if their reports land,
they are folded in as corrections, not as a second opinion.

## 0. Scope and lane

Surfaces, in the operator's order of weight:

1. Sub-Store companion (`/plugins/latticenet.sub-store/sub-store`): the heaviest
   ask, redesigned against the official Sub-Store front end, not patched.
2. vpn-core Lines (`/plugins/latticenet.vpn-core/lines`): nested scroll,
   topology that refuses to draw, and a grooming pass over every sing-box node.
3. SSH Guard (`/network/ssh-guard`): UI plus missing features (coverage,
   per-node evidence, batch arming, rotation).
4. Terminal (`/terminal`): redesign with a security review.
5. NetGuard firewall (`/plugins/latticenet.netguard/firewall`): cognitive load.
6. Logs and Trace (`/platform/logs`, `/platform/trace`): judged as one feature
   or two, and where they live.
7. Nodes filter for sing-box managed nodes (host, `/nodes`).

Design-intelligence lane: Product path for the whole program, Deep gate for
Terminal and SSH Guard (they execute on hosts and carry credentials) and for the
Sub-Store subscription URLs (they embed provider tokens). The Deep additions are
the responsibility gate items recorded per surface below, not extra ceremony.

Person and context: one operator (and the agents acting for them) running 33
nodes across five providers and three continents, in the console for hours a
day, usually on a wide desktop, sometimes from a phone to check a red state.
Behavioral level dominates; visceral decoration decays by week two.

## 1. Shared system (chassis, evidence, accent)

Within one product, consistency wins over novelty, so the chassis is the token
system that already exists in `lattice-dashboard/src/style/app.css`:

- Surfaces: OKLCH slate-indigo set (`--background`, `--card`, `--muted`,
  hairline `--border`), light and dark via `.dark`, brand palette applied by the
  theme store. Production runs the teal brand; the tokens stay abstract.
- Geometry: radius 3/4/6/8, rows 40px (32px compact), content max 1600px,
  narrow 1024px. One plane; shadows only on popover and dialog.
- Type roles: system UI sans for body (no Inter identity face); the mono stack
  (`--font-mono`) is the second role and carries identifiers, endpoints,
  digests, counts and eyebrow labels, always with tabular numerals. Display
  weight comes from size and tracking, not from a third face.
- Semantic color is the only saturated color on a page: `--success`,
  `--warning`, `--destructive`, `--info`; the brand accent marks selection and
  the one primary action per view.

Evidence layer (the product's native object): the thing Lattice manipulates is
a claim about a host, with its source and its time. Every redesigned surface
shows rows as claims, never as bare values: what was observed, by which agent
version, when, and through which path (inventory post, probe, log tail).

Accent (the signature element, one per product): the proof line. A single
mono strip under a panel title or beside a row that reads like
`observed 43s ago · agent 0.3.8 · via inventory` or `plan a1f3… · approved by
cdcd · applied 2026-09-02 03:52Z`. It is the visual form of "every change is a
plan you saw, hash-bound, and proven". It replaces badges that only say "ok".

Interaction rules carried by every slice:

- One scroll per document. A plugin document is the scroller inside its host
  frame; no block inside it gets a viewport-height `max-height`. Long sets are
  paged to what fits a screen, with a sticky column header.
- The primary action of a view sits in the toolbar, once, top right; row
  actions live in the row. Destructive actions confirm with object, scope and
  consequence named, and the confirm dialog never uses a bare "OK".
- Filters live in the address bar (Trace already does this; the rest follow).
- 375px: tables keep their columns and scroll horizontally inside the table
  only, first column sticky; summary strips wrap to two columns; toolbars
  wrap, the primary action stays visible.
- Every async action follows trigger, immediate acknowledgement, honest
  progress, explicit outcome, recovery. Partial failure lists the failed
  members; the surface never looks green when a sub-operation failed.
- Agents and humans are equal operators: every action a button fires has a
  documented method with the same refusal semantics, and the UI states which
  method it will call in the confirm dialog (`lines.plan_chain`), so an agent
  reading the screen can do the same thing.

### 1.x Direction added 2026-09-02: original teal palette, Cloudflare-derived interaction language

The operator added two references: the Claude palette for colour, and
Cloudflare's design tokens for everything else, to be learned from rather
than copied ("不要太死板"). The dashboard chassis already carried half of
this (a tight radius scale with a note about console versus marketing,
40/32px row rhythm, content measures taken from Cloudflare's console). What
changes and what is kept:

**Colour (kept: teal on cool slate).** The Claude palette was tried first
(warm neutrals, terracotta accent) and the operator reverted it the same
day: the orange came in with the Cloudflare tokens, and the original teal
accent on cool slate keeps the site consistent, most visibly on the home
view and inside the Sub-Store plugin. The dashboard therefore ships the
pre-chassis values again as the default (`DEFAULT_COLOR = "teal"`, theme
colours #1b1b29 dark and #ffffff light), and the `claude` entry stays in
the palette system as an optional choice only. Semantic tones (success,
warning, danger, info) are unchanged: they carry meaning, not identity.
Plugins keep consuming host tokens and never hardcode a hue. The one
colour-adjacent change that survived the revert is the dark-mode
`--destructive-foreground` (oklch(0.16 0.02 15)) so destructive buttons
keep AA contrast on the danger surface.

**Rhythm and shape (Cloudflare, adapted).** 4px base, steps 4 8 12 16 24
32 48; radius stays the console scale (3/4/6/8) and `--radius` moves from
6px to 4px so buttons and inputs read as controls, not pills; badges may be
pills. Surfaces are flat: a hairline border and a surface-tone step separate
things; the only shadows are the overlay and raised tokens, and the overlay
shadow is tinted with the accent at 6% the way Cloudflare's card shadow is,
not neutral black. Row height 40px, compact 32px, as before.

**Type.** No new faces (the system stack stays; FT Kunst Grotesk is not
ours to ship). What is borrowed is the tension: display and page titles get
-0.02em tracking, section headings -0.01em, body stays 14px, mono stays for
identifiers at 12px with 1.5 line height. Numbers are tabular.

**Motion.** Two durations and one curve, as tokens: `--duration-fast`
100ms for hover, focus and pressed states; `--duration-base` 200ms for
expand, collapse, sheet and tab changes; `--ease-out` cubic-bezier(0.19, 1,
0.22, 1) (expo-out: fast start, settled end, the Cloudflare curve). No
infinite loops, no motion without a job (feedback, state change,
hierarchy), every animation interruptible, `prefers-reduced-motion` drops
durations to zero. Tailwind's default transition duration and curve are set
to these so existing utilities inherit them.

**Interaction habits to borrow.** Dense rows with row actions revealed on
hover and focus-within but always reachable by touch; one verb per action
across the product (Delete is Delete everywhere); the primary action solid,
the secondary outlined, never two primaries in one view; focus ring 2px
accent with 2px offset; hairline dividers over cards; the proof line stays
the signature element. Apple-design rules on gestures still apply
(interruptible, reversible, immediate response).

**What not to copy.** Cloudflare's 1px radius everywhere (too sharp for
badge-heavy tables), its 1.15 body line height (too tight for CJK), its
2000ms slow duration (nothing here is celebratory), and its marketing
white-on-orange buttons (fails AA; ours is the darker step).

The skill pack the operator pointed at (`design-intelligence`,
`apple-design`, `animate`, `improve-animations`, `pick-ui-library`,
`prototype`, `humanizer`) is the method; the landing-page anti-slop skill
is out of scope for a console by its own section 13, and only its
consistency locks (one accent, one radius system, one verb per action,
no em dashes, motion motivated) carry over.

## 2. vpn-core Lines

### Facts from production (2026-09-02, alpha-0.2.2a79, vpn-core 0.8.0-alpha.16)

Pulled through the host call gate with the session's CSRF token, 25 groups,
138 lines:

| Fact | Value |
|---|---|
| Lines Lattice manages | 0 of 138 (everything is discovery-only) |
| Nodes carrying a managed line | 0 of 25 |
| Lines with an outbound to another endpoint | 101 |
| Service state reported | `unknown` on all 138 (fleet agents are 0.3.8; the probe ships in 0.3.9-alpha.1) |
| Config verdict | `ok` on all 138 |
| Nodes with sing-box discovery on (runtime) | 25 of 33; 24 by launch flag |

Relay structure: six hub nodes ([Metix]-DMIT-1/2/3/4, gomami-hk-turin-mini,
gomami-jp-pulse-mini) each carry an identical bank of twelve VLESS relay lines
(ports 31001 to 31012) that dial six exits, each exit twice (vless and hy2):
qqpw-cd2-VDS, qqpw-cd3-VDS, Aaitr-ATT-VDS, Aaitr-Frontier-VDS, VIRCS-ATT-VDS by
IP, and the two NAT exits (Aaitr-Frontier-NAT, Aaitr-jp-softbank-NAT) by
`aproxy.top` names with forwarded ports. The two gomami minis carry a second,
Trojan copy of the bank (41001 to 41012). On the `[cd]` side, mkcloud-hr-iplc
fans out to four named endpoints (`*.roobli.org`), one of which is DMIT-eb-wee,
which itself forwards to Aaitr-Frontier-NAT: the only two-hop chain in the
fleet.

Why the topology panel prints "No topology to draw": the layout it computes is
2 ranks by 8 rows, 524 by 442 user units, and `isGraphLegible` rejects any
drawing taller than a fixed 420, while the width budget it measured was 1995.
A 22px miss against a ceiling that ignores the horizontal room is the whole
bug. The second problem is that a per-line drawing is the wrong object: 101
edges out of 138 lines all describe about twenty node-to-node relationships.

Why the page has three scrollers: `.table-wrap` carries
`max-height: calc(100dvh - 32px); overflow: auto`, added as a compositor
workaround when a 111-row table made the document 8800px tall and painting
stalled. The fix was applied to the box, not to the row count. With the page
size at 50 the table still overflows a screen, so the cap engages on both the
fleet table and the topology table.

### Grooming findings for the sing-box fleet

These are the states the redesigned page has to make visible without the
operator digging; they are also the work list after the UI lands.

1. Nothing is managed. Every line is discovered. The rollout path exists
   ("Roll out managed lines") and has never been used on this fleet; the chain
   planner therefore has zero eligible targets and says so in a paragraph.
2. Service liveness is blind: 138 `unknown`. The pilot of agent 0.3.9-alpha.1
   on malibu and gomami-hkg is the unblocker; until then the "Not reporting a
   problem" tile is a config verdict, and the copy must say so.
3. Two exits are unresolvable by endpoint: the NAT exits are dialed by
   `aproxy.top` names with forwarded ports, so no fleet line matches
   `host:port`. The graph needs host-only matching (node public IP or a known
   name) with the port marked unverified, and off-fleet endpoints drawn as
   their own boxes rather than dropped.
4. `[Metix]-gomami-jp-pulse-mini` line `VLESS-REALITY-52971` has an empty
   outbound reference and no server: an inbound with no route. Attention item.
5. `[cd]-xuezhang-ca-NAT` reports runtime discovery on while its launch flag is
   off: intent and runtime disagree; the node filter has to show both.
6. `[cd]-huoshan-shanghai` runs `/usr/local/bin/sb` where every other node runs
   `sb` from PATH; harmless, but the profile page should print the binary.
7. `[cd]-Akkocloud-UK-London-KVM` geolocates to US/Santa Clara. Name or geo is
   wrong; surfaced on the node, not here.
8. Eight online nodes do not run sing-box (mac-air, xiaoxin, homeserver, three
   TiDB, scripts) and one is offline on agent 0.3.6 (`[OpenJobs-Data]-tmp`).
9. Found by the pilot, 2026-09-02: the `sb` manager installs sing-box at
   `/etc/sing-box/bin/sing-box` owned by uid 1001 while systemd runs it as
   root. The trust selector refuses it, so liveness reads `unknown` on every
   sing-box node, and a non-root account owns the program root executes.
   The Attention lens now prints the probe's own account ("refused sing-box
   candidate … owned by uid 1001, not root") on the fleet-wide liveness
   claim; the fix is fleet grooming (root-owned binary in a trusted
   directory on 25 nodes) or a trust-rule change that is the operator's call.

### Object model

| Object | What the operator calls it | States | Contains / relates |
|---|---|---|---|
| Node | node | online, offline, sing-box on/off, discovery drift | lines, profile |
| Line | line (an inbound) | managed / discovered; config ok / error; service running / down / restarting / unknown; role: exit, relay, orphan | node, users, outbound target |
| Target | where a line dials | on-fleet line, on-fleet node (port unverified), off-fleet endpoint | line |
| Chain | a planned relay link | proposed, committed, verified, drifted, failed, removed | source line, target line, approval |
| Bank | a set of relay lines on one node with identical targets | complete, partial | node |

"Bank" is new vocabulary and it is what the operator already has: six hubs
with the same twelve outbounds. Grouping by bank is what turns 101 rows into
seven statements.

### Information architecture

The Lines view becomes three lenses over one dataset, switched by a segmented
control in the toolbar and mirrored in the URL (`?lens=fleet|topology|attention`):

```
+------------------------------------------------------------------------------+
| Lines  VPN CORE PLUGIN                                     [Refresh] [Roll out]|
| observed 43s ago · 25 nodes report · agent 0.3.8 · liveness: not reported    |
+------------------------------------------------------------------------------+
| 138 lines | 0 managed | 101 relay · 37 exit · 1 orphan | 25/33 nodes sing-box |
+------------------------------------------------------------------------------+
| [Fleet] [Topology] [Attention 4]     search: node, line, endpoint   [Filters] |
+------------------------------------------------------------------------------+
| FLEET (grouped by node, 25 groups, expand shows lines)                        |
|  v [Metix]-gomami-hk-turin-mini   26 lines · 2 exits · 2 banks   ok · unknown |
|      bank 31001-31012  vless x12  -> 6 exits          ok                      |
|      bank 41001-41012  trojan x12 -> 6 exits          ok                      |
|      VLESS-REALITY-8468  exit  direct                  ok   [Details]         |
|      Trojan-8469         exit  direct                  ok   [Details]         |
|  > [Metix]-DMIT-1                  13 lines · 1 exit · 1 bank    ok · unknown |
|  > [cd]-mkcloud-hr-iplc            5 lines · 1 exit · 4 relays   ok · unknown |
|  ...                                                                          |
|  Page 1 of 1 · 25 nodes                                                       |
+------------------------------------------------------------------------------+
```

Fleet lens rules: rows are nodes, not lines; a node row shows counts, roles,
config verdict and service verdict; expanding shows its lines with banks
collapsed into one row each (expandable again). Page size is 25 node rows,
which is the whole fleet today and one screen on a desktop. The line-level
table the current page shows survives inside the expansion and inside search
results (searching an endpoint or port flattens to matching lines).

```
+------------------------------------------------------------------------------+
| TOPOLOGY   node to node · 8 relay nodes · 9 exits · 2 off-fleet endpoints     |
| legend: verified  committed  observed  discovered ---  off-fleet [ ]          |
|                                                                               |
|  [DMIT-1]  ----x12---->  [qqpw-cd2-VDS]                                       |
|  [DMIT-2]  ----x12---->  [qqpw-cd3-VDS]                                       |
|  [DMIT-3]  ----x12---->  [Aaitr-ATT-VDS]                                      |
|  [DMIT-4]  ----x12---->  [Aaitr-Frontier-VDS]                                 |
|  [hk-turin-mini] -x24->  [VIRCS-ATT-VDS]                                      |
|  [jp-pulse-mini] -x24->  [ nat-us-28tz.aproxy.top ] (Aaitr-Frontier-NAT?)     |
|  [mkcloud-hr-iplc] -x4-> [DMIT-eb-wee] --x1--> [ nat-us-28tz.aproxy.top ]     |
|                      \-> [xuezhang-jp-NAT] [xuezhang-ca-NAT] [Aaitr-ATT-VDS]   |
|                                                                               |
| selected edge: DMIT-1 -> qqpw-cd2-VDS · 2 lines · discovered · click to list  |
+------------------------------------------------------------------------------+
| CANONICAL TABLE (per line, filtered by the selection above)                   |
```

Topology lens rules: nodes are boxes, edges are aggregated per node pair with a
line count and the strongest evidence kind as the stroke; off-fleet endpoints
are boxes with a dashed border and the unmatched name; a node whose IP matches
but whose port does not is drawn as the node with a "port unverified" mark.
Rank layout left to right as today, but a rank wraps into sub-columns when it
would exceed eight rows, and the drawing is never refused: if the wrapped
layout is wider than the panel it scales down to no less than 0.75 and beyond
that the panel scrolls horizontally, which is the one place a nested scroll is
allowed because a figure is not a list. Clicking a node or edge filters the
canonical table below; the table is unchanged in content and loses its
inner scroll (paged at 25).

Attention lens: the findings above as a list of claims with the row that
proves each one and the action that clears it (roll out, sync metadata,
reattach, open node). Count in the segmented control is the badge the
operator looks at first.

### State contract

| Operation | Acknowledge | Progress | Outcome | Recovery |
|---|---|---|---|---|
| Refresh | button spins, proof line says "refreshing" | none needed (<2s) | proof line updates the observed time | error banner keeps the last good data visible and says its age |
| Plan chain | button spins, form locks | "filing approval" | toast with approval id and a link | refusal text verbatim, form stays filled |
| Roll out | dialog stays open, list of nodes shows per-node pending | per node | per node approved / refused | refused nodes listed with reasons, retry per node |
| Sync metadata | row spinner | none | row proof line updates | row error text, retry |

Empty and degraded states that must render: no lines at all; lines but no
identity (`no_identity`); flat fleet (`no_relay`); off-fleet upstreams only;
read-only session (planning controls disabled with the sentence that says so);
liveness absent (tile reads "not reported by this agent version").

### Node filter (host, Nodes view)

Add `singbox` to the agent capability token set in `nodeFilterExpressions.ts`
and to the quick-filter chips in `NodesView.vue`, matching
`agent_runtime.singbox_discover` (runtime truth). The chip label is "sing-box".
When launch and runtime disagree the node badge reads "sing-box (drift)" and
the tooltip prints both flags. A second token `singbox-drift` makes the drift
filterable. Both are expression tokens, so agents get them for free through the
existing filter grammar.

## 3. Logs and Trace: one feature, and not Sub-Store's

Judgment: Logs and Trace are the same evidence at two levels of structure. Logs
is the raw sing-box line tail per source (today one source, `singbox://
legend-sg`, 82 lines held). Trace is the connection records assembled from the
same sing-box output plus the Clash API, with filters in the address bar and
collection policies per node. They belong together, and neither belongs in the
Sub-Store plugin: Sub-Store's object is a subscription (a document the operator
publishes), while Logs and Trace are observations about running services. Their
domain is vpn-core (they explain vpn-core's lines), but their storage and
ingestion are host concerns (the host tails, the host keeps policies), so they
stay in the host as one area.

IA change: one route, `/platform/evidence`, with two lenses, Connections
(today's Trace) and Raw log (today's Logs), sharing one filter set (node, line,
time window, session) so switching lenses keeps the question. Cross-links: a
line row in vpn-core gets "Connections" and "Raw log" actions that deep-link
with the node and line prefilled; a connection row links back to its line. The
existing routes redirect. Trace's empty state today ("No connections in this
window") comes from every collection policy being off; the empty state must
say that and link to the policy tab, distinguishing "nothing matched" from
"nothing is being collected".

## 4. Sub-Store companion

### Facts (production 2026-09-02, plugin 0.13.x lane; harness on the same tree)

Production holds 7 of a 256-record cap: five subscriptions (cdcd-self-host and
its .bak-20260820 copy, openjobs-host, openjobs-host-trojan, 建材市场) and two
combinations (merge-cd-openjobs, merge-openjobs). Every record is tagged
`migrated`, every one reads "Never refreshed", and the page banner says
"Nothing here is reachable until you publish a share for it, in the dashboard
under Networking": nothing on this plugin is served to any client today.

What the companion already has, checked in the harness and in the source
(`ui/src/screens/SubscriptionsScreen.vue` 1744 lines, `FilesScreen.vue` 1472,
`SettingsScreen.vue` 376, `client.ts` bindings): a record list with kind and
tag filters and three sorts; an editor with Display, Content and Operations
tabs; four sources (this fleet's nodes from vpn-core, a converged relay path,
a provider link, pasted nodes); an output format; the common settings (junk
nodes, UDP, cert, TFO, VMess AEAD) and a node-operation chain whose operators
match the official processors one for one (region, type, regex and script
filters; flags, sort, rename, quick settings, resolve domain, handle
duplicates, append subscription, script); a "Nodes this produces" preview;
Files (configurations, script-built, plain text) with an editor and a "what a
client receives" document view; Settings with defaults, migration from a
standalone Sub-Store, and export/restore. Publishing lives in the host
(Subscription Shares under Networking) by design, and the plugin can read the
share list (`shares.list`).

What the official front end has that the companion does not: the compare
table (`CompareTable.vue`, 1029 lines: original nodes against processed
nodes, side by side, with per-node detail), Sync (upload artifacts to a gist
or git so a client fetches a static file), Archives, a processing Logs view,
and share management next to the record. It is also built mobile-first.

### Where the companion fails the operator

1. The list hides the one state that matters: whether a record is published.
   The banner says none are, but no row says so, and no row offers the
   action. The `shares.list` call exists and is unused by the list.
2. "Never refreshed" is printed on pasted and fleet-sourced records, where
   refresh is not a thing; the column reads as a fault on every row.
3. The list is a card list: five rows fill a screen, the seven records need a
   scroll, and the counts an operator scans for (nodes in, nodes out, steps,
   published, expiry, traffic) are not columns.
4. Preview of an unsaved draft is gated by source: pasted content and the
   stored record preview on the read scope, but a draft that names a
   provider link or the fleet needs `substore:admin`, because naming a source
   is naming a host for the control plane to read. Right, and explained in
   the pane; the gap is that the pane offers no path for a read-only
   operator beyond "save first", and saving is the write they lack too.
5. The preview already says "kept 41 of 52", lists the dropped nodes and
   marks a stale last-good result; what it cannot say is which operation did
   what, because the engine runs the chain as a whole (`preview` returns one
   node set plus the dropped set). The official compare table shows the
   change per operation. The engine already accepts a partial run stopped
   after any step (the per-step eye in the chain uses it), so a delta strip
   is a UI change: run the preview once per enabled step on request and
   print what each step kept.
6. Provider links carry provider tokens in the URL (`SubscriptionRecord.url`).
   The Content tab prints the URL in full in a text field; the list does not,
   which is right, but the editor and any share view must mask the query
   string by default and reveal on request (Deep gate item).

### Object model

| Object | Operator's word | States | Relations |
|---|---|---|---|
| Subscription | subscription | source kind (fleet, path, link, pasted); fetch ok / failed / never; published / unpublished; enabled steps | steps, share, tags |
| Combination | combination | members resolved / missing; published / unpublished | subscriptions by name or tag, share |
| Step (operation) | operation | enabled / disabled; touched N nodes on last preview | subscription or combination |
| Share | share | enabled / disabled / expired; default format | one record, host-owned |
| File | file | kind (configuration, script, plain text); source record | share |
| Preview | preview | fresh / stale; truncated | record, draft |

### Information architecture

Top level stays three lenses (Subscriptions, Files, Settings) plus one
addition, Shares, which is the record list from the client's side: every
published URL, its record, format, expiry and enabled state, with "Open in
Networking" for changes. The Subscriptions lens becomes a table:

```
+------------------------------------------------------------------------------+
| Sub-Store                                          [Search ⌘K] [New ▾]        |
| observed 43s ago · 7 records · 0 published · engine ok                        |
+------------------------------------------------------------------------------+
| [Subscriptions 7] [Files 3] [Shares 0] [Settings]                              |
+------------------------------------------------------------------------------+
| filter: name, tag  | kind: all subs combos | tags: cdcd openjobs self  | sort |
+------------------------------------------------------------------------------+
| RECORD                 SOURCE        NODES    STEPS  PUBLISHED   LAST FETCH    |
| openjobs-host  paid    provider link 48 → 31  3      —  [Publish] 3h ago ok    |
| cdcd-self-host self    this fleet    138 → 12 3      /s/cdcd  ok  live         |
| 建材市场  backup       pasted        22 → 22  0      —  [Publish] n/a          |
| ▸ merge-cd-openjobs    2 members     43 → 43  2      —  [Publish] n/a          |
+------------------------------------------------------------------------------+
```

Rules: one row per record at 40px; NODES is "in → out" from the last preview
or fetch, with "?" when never run; PUBLISHED is the share slug (link to the
Shares lens) or a Publish action that navigates to the host's share form
prefilled (the route already exists); LAST FETCH applies to provider links
only and says "n/a" otherwise; kind, tag and sort stay as chips; the row
expands inline to the step list with per-step node deltas, so the chain is
readable without opening the editor. The proof line under the title says when
the list was observed and whether the engine answered.

Editor: the three tabs stay; "Nodes this produces" becomes the compare
panel: two columns (source, result), a per-step delta strip ("Region filter
kept 31 of 48", "Rename touched 31"), the dropped nodes listed with the step
that dropped them, and the same panel usable on an unsaved draft for pasted
and fleet sources without admin (the source is already in hand); provider
links keep the admin gate and say why.

Responsibility: provider URLs masked after the host (`https://host/…?…`)
in every read view, revealed by a click that lasts sixty seconds; never
printed into a toast, a share row, or a preview error.

375px: the table keeps its columns and scrolls sideways with the record
column sticky; the editor tabs become a segmented control; the compare panel
stacks under the form.

## 5. SSH Guard

### Facts (dashboard `SshGuardView.vue` 835 lines, `sshGuardModel.ts` 313, server `/api/sshguard/plan` and `/confirm`, both `sshguard:admin`)

The guard is a two-step plan per node: arm (move sshd to a port, keep or drop
the legacy port, restrict management sources, enable knock, optional
out-of-band fallback, confirm window 120s to 900s) and confirm within the
window, or the node reverts. The view already carries the state machine
(idle, armPending, armApproved, awaitingConfirm, confirmPending,
confirmApproved, confirmed, armFailed), an urgent card for nodes whose revert
timer is running, a plan form with a node picker and enrolment scope, the
findings the server raises against a plan (blocking ones need an explicit
acceptance), and a fleet list with coverage counts (done, in flight, open), a
scope filter (all, enrolled, undecided, excluded) and bulk enrol and exclude.
Production on 2026-09-02: 12 of 33 confirmed, three rows reading "Last arm did
not go through".

What is missing against the ask: per-node evidence (the agent posts
guard-reality snapshots to `/api/agent/guard-reality`, the server serves them
at `/api/netguard/reality`, and the SSH Guard page reads none of it: what
sshd listens on now and when that was observed are available today; whether
password auth is off and whether the knock is armed are not in the snapshot);
batch arm (bulk actions cover scope only, and an arm is one plan per node
with one form); rotation (the knock sequence and the management sources have
no "replace with new, verify, retire old" flow; KI-9 is being done by hand).

### Information architecture

The page is a coverage board first, a fleet table second, and a plan sheet
third; the form leaves the page body.

```
+------------------------------------------------------------------------------+
| SSH Guard                                    [Arm selected] [Rotate knock ▾]  |
| observed 43s ago · 33 nodes · 12 confirmed · 3 failed arms · 2 reverting     |
+------------------------------------------------------------------------------+
| ⏱ 2 nodes revert in 07:41 and 03:12 unless confirmed   [Confirm both]        |
+------------------------------------------------------------------------------+
| [All 33] [Confirmed 12] [In flight 2] [Open 16] [Failed 3] [Excluded 0]      |
+------------------------------------------------------------------------------+
| NODE            STAGE        SSHD NOW        PASSWORD  KNOCK   OBSERVED  ACT  |
| [cd]-Aaitr-ATT  confirmed    :58394 only     off       armed   41s ago   ⋯    |
| [Metix]-DMIT-1  arm failed   :22 + :58394    on        —       2m ago    Arm  |
| [cd]-homeserver open         :22             on        —       12s ago   Arm  |
+------------------------------------------------------------------------------+
```

SSHD NOW and OBSERVED come from the guard-reality snapshot the server already
serves at `/api/netguard/reality` (listeners carry the process name and
port, so "sshd on :58394" and "collected 41s ago" are a read away; the
NetGuard plugin consumes the same feed). PASSWORD and KNOCK are not in the
snapshot: the agent's guard-reality report has to carry sshd facts
(PasswordAuthentication, the knock state) before those columns can be
truthful, which is the agent half of this slice and ships as a prerelease
like the liveness probe did. STAGE is the existing state machine. "Arm failed" rows print the refusal or the failed
task's last line inline, not "did not go through".

Batch arm: selecting rows enables "Arm selected", which opens the plan sheet
once with the shared policy (port, sources, knock, window) and files one plan
per node; the sheet lists the nodes with per-node findings and lets the
operator drop one before filing; the outcome list names each node's approval.
The Approvals page already groups plans into events, so the batch reads as
one event there.

Rotation: "Rotate knock" on selected nodes files, per node, an arm whose plan
carries the new sequence and keeps the old one honoured until confirm; the
confirm retires the old sequence. The order of the fleet is the operator's
(non-critical first, the control-plane host last); the sheet shows that order
and refuses to include the control-plane host in the first batch. This needs
the plan request to accept a knock rotation (server half).

Responsibility (Deep gate): the sheet names the node set, the port change and
the consequence ("if you do not confirm within 15 minutes each node reverts on
its own"); the knock sequence is shown once, masked afterwards, and never
written to a toast; a failed member never hides behind a green batch.

## 6. Terminal

### Facts (dashboard `TerminalView.vue` 744 lines, `api.terminal` create/list/close, agent PTY over stream or poll)

The page is a three-part layout: a node card list with search on the left
(each card: name, id, online badge, public IP, active session count), a
Connection panel under it (shell, selected node with agent version, transport
auto-selected from the node's runtime, Connect, resume latest session), and the
terminal pane on the right, empty until a session is attached. Sessions are
audited PTYs opened through the agent; closing asks for confirmation and
kills what runs inside. Baseline at 1440: 33 cards fill the left column, the
right pane is empty, the Connect control is below the fold, and the first
card is selected by default so a click on Connect opens a shell on a node the
operator did not choose.

### Information architecture

The session pane is the dominant element; choosing a node is a command, not a
wall of cards.

```
+------------------------------------------------------------------------------+
| Terminal                          [node ▾ [cd]-DMIT-pro-malibu  ⌘K] [Connect] |
| stream · bash · agent 0.3.9-alpha.2 · 0 active on this node · audited        |
+------------------------------------------------------------------------------+
| ┌ term_d23lpfmz4xd · [cd]-DMIT-pro-malibu · /bin/bash · 00:04:12 ──── ✕ ┐    |
| │ root@dmit-proxy-us:/#                                                 │    |
| │                                                                       │    |
| └───────────────────────────────────────────────────────────────────────┘    |
| Sessions: 1 live on this node, 0 elsewhere · recent: gomami-hkg 2h ago       |
+------------------------------------------------------------------------------+
```

Rules: the node is chosen in a combobox with search (the palette already
exists), never pre-selected; Connect is disabled until a node is chosen and
its transport resolved; the proof line under the title says which transport,
which agent version and how many sessions are live before anything opens;
the pane holds tabs for live sessions on any node; closing stays a confirm
with the consequence named. 375px: the combobox and Connect stack, the pane
takes the full width and height, the on-screen keyboard is accounted for.

Security review items, to be checked in code before the build (Deep gate):
session creation must bind to the node id the operator saw at click time (no
race with a list refresh); the PTY stream must carry a per-session token that
is never in the page URL; idle sessions must time out server-side and say so
in the pane; paste into the terminal must be shown before it is sent when it
contains a newline (bracketed paste); the audit record must name the actor,
the node and the session id, and the page must show the operator that it does;
an agent acting through the same surface gets the same audit line.

## 7. NetGuard firewall

### Facts (plugin `ui/src/App.vue` 753 lines, `posture.ts`, `netguardModel.ts`)

Three tabs: Fleet, Groups, Zones. Fleet is a posture table per node with a
coverage verdict (managed, observe only, legacy, unbound), a snapshot
freshness (fresh, stale, unknown), a drift verdict (in sync, drift, unknown
with a stated reason), search, sort and an attention rank. Groups is the
security-group table (rules with port ranges and remotes by node, CIDR,
domain or group). Zones is the trusted-zone table. The reality model
(listeners, interfaces, lint findings, suggestions by port, a review) exists
in the model and feeds the drift and the suggestions.

Where the load comes from: three vocabularies on one page (coverage,
snapshot, drift) that the operator has to hold together to know whether a
node is safe; a rules table that shows rules, not what they let through on a
given node; and no answer to the first question an operator has on this
page, which is "what is exposed right now, on which node".

### Information architecture

Posture first, as a single sentence per node; the structure second; the
change third.

```
+------------------------------------------------------------------------------+
| NetGuard                                             [Review changes 0]       |
| observed 41s ago · 33 nodes · 25 managed · 4 observe only · 2 drift · 2 stale |
+------------------------------------------------------------------------------+
| [Exposure] [Groups 6] [Zones 3]                                               |
+------------------------------------------------------------------------------+
| NODE            OPEN TO THE INTERNET          MANAGED BY        DRIFT  SEEN   |
| [Metix]-DMIT-1  22, 31001-31012, 32426        relay-hub, ssh    in sync 41s   |
| [cd]-homeserver 22, 80, 443, 5432 (!)         legacy rules      unknown 12s   |
| [cd]-mac-air    nothing managed               —                 —      2m     |
+------------------------------------------------------------------------------+
| ▸ [cd]-homeserver: 5432 is open to the internet and no group allows it;      |
|   suggestion: bind postgres to the WireGuard zone.  [Add to group] [Ignore]  |
+------------------------------------------------------------------------------+
```

Rules: OPEN TO THE INTERNET is computed from the reality snapshot's listeners
minus the zones and groups that already confine them; anything left is red
and expands into the suggestion the model already produces. The three
vocabularies collapse to two columns, DRIFT and SEEN, and coverage becomes
the MANAGED BY column (the group names, "legacy rules", or nothing). Groups
and Zones keep their tables but gain a "used by N nodes" column and a
per-rule "allows" preview. The apply flow becomes one Review changes sheet:
diff per node, one approval per node, the outcome list per node.

375px: the exposure column wraps, the suggestion rows stack.

## 8. Delivery order and acceptance

Slices ship independently, each through the normal branch, PR, CI, local
merge and pin discipline in `PROGRAM.md`. State on 2026-09-02, 11:50Z: every
slice in this brief is reviewed, merged and in production.

1. vpn-core Lines: 0.8.0-alpha.18 installed (alpha.17 plus the
   verification residuals; two design reviews and a verification pass).
2. Host: a84 deployed with the teal-on-slate palette the operator asked
   to keep (the terracotta that came with the Cloudflare tokens was
   reverted; 4px controls, motion tokens and the dark-mode danger text
   stayed), the Evidence area, the Terminal pane (reviewed: focus, header,
   naming and 375 fixes applied), the SSH Guard coverage board (reviewed:
   expired windows, sheet errors, reason expansion, chip words applied)
   and the managed log sources. a80 and a82 are burnt tags.
3. Sub-Store: 0.13.0-alpha.29 installed (table, inline chain, Shares lens,
   URL masking, compare panel, one scroller, vocabulary; reviewed, with
   the ellipsis, phone tab bar, sheet hierarchy, error state, action
   naming, compare layout and table-role fixes applied).
4. SSH Guard: board live with the fleet's real listeners and failure
   reasons; the sshd facts (password, root login, ports) now arrive from
   agent 0.3.9-alpha.5 through server a83+ and wait for the board to read
   the per-node `sshd` block (follow-up); knock rotation stays a server
   follow-up.
5. Terminal: live, with the server-side ownership and audit fixes and the
   agent-side process-group kill and environment allowlist.
6. NetGuard firewall: 0.1.0-alpha.15 installed (exposure lens, findings
   with undo, viewport frame model; reviewed and fixed).

Agent 0.3.9-alpha.5 runs on 31 of 33 nodes; guard reality is fresh on 31.
The Mac node waits for the operator's sudo step; one node is offline.

Gate 2 evidence per slice: rendered at 1440 and 375 in the dev harness with
realistic content (the production shape above, not lorem), every state in the
state contract exercised, console clean, then a `design-reviewer` pass in the
browser. Production verification after deploy uses the click-then-capture
workaround, because the sandboxed plugin frame does not composite into a tab
capture until it receives an input event.

## 9. Platform and plugin boundary (2026-09-07)

### Why this section exists

The operator walked `/network/subscription-shares`, `/platform/store` and
`/platform/evidence` and asked the question that decides information
architecture here: what is platform, what is plugin, and would each page still
make sense with no plugin installed. The 2026-09-03 placement rule was right as
a rule (secrets, tokens, public routes and the audit trail are always platform;
anything two plugins need is a platform primitive; domain knowledge about one
payload stays with its plugin; name the non-console caller before shipping a
platform surface) and was mis-applied once. Subscription Shares stayed a
standalone Networking destination on two true facts, that proxy-user shares
have no plugin behind them and that a subscription is Sub-Store's knowledge,
neither of which justifies a top-level entry. The tab fails the plugin-absent
test: with Sub-Store uninstalled, "Subscription Shares" under Networking has
nothing left to explain itself with, and the operator's own reading of it
("功能和理解上都不合理") is the correct verdict.

### The rule, sharpened

1. A platform page takes the fleet or a plane as its subject and answers a
   cross-domain question: what is published where and who may read it
   (Publishing), what bytes are held (Store), what the nodes did (Evidence),
   what changed and who approved it (Approvals, Audit).
2. A plugin page takes one domain's objects as its subject: subscriptions,
   lines and identities, firewall groups, peers.
3. When a domain object needs a platform primitive (a public URL, a bucket, an
   evidence trail), the object stays on the plugin page and the primitive's
   record lives on the platform page. The plugin reaches the platform page
   through the bridge's parameterised-route allowlist, prefilled for that
   object; the token never enters the sandbox. The platform record names its
   origin, links back to the plugin page when the plugin is installed, and says
   "renderer not installed" when it is not.
4. No platform destination exists for one plugin's convenience. If only one
   plugin would ever put something there, it belongs on that plugin's page.

### Acid tests, run on every Console entry before it ships

- Plugin absent: with zero plugins installed every Console destination renders
  and every sentence on it is still true. Plugin-origin records show their
  state honestly; creating a new record for a missing origin is unavailable
  and says why.
- Scope-limited operator: the entry is scope-gated and the always-global scopes
  are named on the picker (shipped in a93).
- Non-console caller: a platform surface names who writes to it besides the
  console. Verified against the manifests on 2026-09-07: KV is written by the
  Sub-Store plugin (`kv:read`, `kv:write`) and by nothing else; Static has no
  non-console writer and exists for files the operator publishes; shares are
  written by the console (proxy users) and by Sub-Store's deep link. The guide
  in Decision B states exactly this, never an implied ecosystem.

### Classification of the current nav

| Entry | Class | Plugin-absent test |
|---|---|---|
| Overview, Nodes, Groups, Map, Inventory, Monitoring | platform | pass |
| Approvals, Tasks, Terminal, Audit | platform | pass |
| Network Policy, Self-host DNS, Geo-Routing, DDNS, Tunnels, SSH Guard | platform (core engines) | pass |
| Subscription Shares | REMOVE | fail: a plugin's object as a top-level destination |
| Plugins, Publishing, Store, Notifications, Webhooks, Agent Updates | platform | pass, with Decision B's guide |
| Evidence | platform | pass on ownership, fails on honesty today (Decision C) |
| Settings | platform | pass |
| Extensions workspace | plugin | pass by construction: gated on installation |

Two engines share a domain with a plugin (NetPolicy with NetGuard, the core
proxy subsystem with vpn-core). That is the intended pattern, core owns the
engine and the data, the plugin owns the domain UI, and it is consistent with
rule 3. It is recorded here so the next reader does not mistake it for a leak.

### Decision A: Subscription Shares folds into Publishing

- The Networking entry is deleted. `/network/subscription-shares` redirects to
  `/platform/publishing?origin=share` with `create` and `for` preserved, so
  Sub-Store's existing deep link keeps working with no plugin release.
- Publishing absorbs everything the 882-line view carried: create (target
  picker offering proxy users, and Sub-Store subscriptions when that plugin is
  installed and readable), expiry edit, rotate, revoke, refresh, and copy of
  the per-client URL. The server's `reserved` flag stops meaning "manage
  elsewhere" and keeps its literal meaning: the route is owned by its share
  and cannot be moved or deleted as a route; the share itself is managed on
  this page.
- Publishing gets an origin lens in the URL (`origin=all|kv|static|share`).
- Plugin-absent: a share whose renderer plugin is missing shows "renderer not
  installed" on its row and refresh is disabled with that reason; a new
  Sub-Store share cannot be created, the picker says why; proxy-user shares
  are unaffected because they are server-native.
- Bridge allowlist: add `/platform/publishing` with `origin`, `create`, `for`.
  Keep the old path's entry until Sub-Store is re-pointed in a later plugin
  release, then remove both it and the redirect.
- Tests: the redirect carries its query; publishing model tests cover the share
  actions and the plugin-absent states; the isolation test pinning "no
  plugin-domain view in the host" stays green, because a share is a platform
  record.

### Decision B: Store and Publishing get a guide, not a primer

Both pages open with a guide when the plane is empty and collapse it to one
line otherwise, with the collapsed state remembered per browser. In this
order: what this is (one sentence); how Store and Publishing relate (Store
holds bytes; Publishing gives bytes a URL and an access mode; a share is a
Publishing record whose bytes are rendered on request rather than stored); who
writes here today, exactly the caller list above; and the canonical
walkthrough in four steps that link to the exact controls (create a bucket in
Store, put an object, bind a host and path to it in Publishing, fetch it with
the shown URL and token). Register per §1: data-dense, verbs first, no
marketing, and every sentence true against the code.

### Decision C: Evidence stays platform, and says what it depends on

Ownership holds from the 09-03 ruling: logstore and tracestore are host
stores; plugins contribute links, never writes, because a plugin writing raw
evidence into a shared store is a forgery surface. The plugin-absent test
passes: Raw log is generic, and Connections is assembled from the sing-box
lines the agent tails, which exist whenever a node runs sing-box, plugin or
not. What fails today is honesty, not placement: trace policies are off on
every node (KI-10), so the Connections lens is empty and nothing says why.

- The Connections empty state names its dependency ("connection records are
  assembled only where a node's trace policy is enabled; N of M nodes have
  one") and links to the per-node control. The Raw log lens lists which
  sources exist and which nodes feed them.
- Connections rows link to the vpn-core line and identity when that plugin is
  installed, and show plain identifiers otherwise. vpn-core already deep-links
  into Evidence (allowlist entry `lens`, `node_id`, `line_uuid`, `user_id`).
- The nav keeps "Evidence", the doctrine's word (§1), and gains the
  description "Logs and connection trace from the nodes" so the abstract label
  reads at a glance.

### Delivery

Three host-side slices, no plugin release needed:

- S1 Publishing absorbs shares; redirect; nav entry removed; allowlist; tests.
- S2 Store and Publishing guides.
- S3 Evidence empty states, description line, plugin-aware links.

Gate 2 as §8. Ships as a console re-pin (a94) after the operator's nod. Plugin
follow-up, later: re-point Sub-Store's share deep link to
`/platform/publishing`, then remove the redirect and the old allowlist entry.
That follow-up shipped: Sub-Store `0.13.0-alpha.35` is live; dashboard PR#62
(integration `9f7c036`) dropped the redirect; server `alpha-0.2.2a95` (switched
2026-09-08 05:13Z) pins that console.

### Status (2026-09-07)

All three slices merged as dashboard PR#61 (integration `4c42c1e`) after two
code reviews and a browser-driven design review with re-check at 1440 and 375
in both languages against a server with no plugins installed, and deployed as
`alpha-0.2.2a94` (switched 2026-09-07 12:21Z). Two amendments
the review forced, now part of this decision:

- Decision A's target picker is real, not free text: proxy users come from
  `GET /api/proxy/users` (server-native `ProxyUser`, the render substrate; not
  vpn-core's `VpnUser`), and a share whose user is known to be missing reads
  `unresolved` on every lens, never `live` or `Serving`. With the list unknown,
  nothing is marked. The server refuses creating such a share (lattice-server
  PR#114). The routes table labels origin `plugin` as "Share".
- Decision C's dependency block renders above the filter card whenever nothing
  is being collected, so the answer to "why is this empty" is the first thing
  on the page; filters lead only when they are the cause.

Deferred items and the process note are in `PROGRAM.md`, lane log 2026-09-07
08:30Z to 11:30Z.

### Follow-up (2026-09-08)

Sub-Store `0.13.0-alpha.35` is live and posts share navigation to
`/platform/publishing?origin=share`. Dashboard PR#62 (integration `9f7c036`)
dropped the `/network/subscription-shares` redirect and the old allowlist
entry. Server `alpha-0.2.2a95` (commit `6980e21`, switched 2026-09-08 05:13Z)
pins that console. A plugin-present look on production: Publishing's share
lens renders `/cd-self` as `live` from `latticenet.sub-store` with
client-format controls and no renderer-missing marker; Evidence Connections
names the filter as the cause of the empty table and still reports 0 of 33
nodes collecting (KI-10). Sub-Store's visible buttons still say "Open in
Networking"; the route they post is already Publishing.
