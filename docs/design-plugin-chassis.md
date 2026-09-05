# Plugin chassis: the shared page skeleton for plugin frames

Status: design, read-only lane. No code in this change.
Date: 2026-09-04.
Reference build: console c097c5b (a91 live), plugin bridge 5f9900b, vpn-core UI as on integration 1111c88 (identical `ui/src` to the local checkout read here), Sub-Store dd03faf (0.13.0-alpha.32), NetGuard 4bba35d, WireGuard 476c92a.

## 1. What this is for

The operator's complaint, in their words, is that the four plugin pages differ in more than colour: radius, stacking, collapse and expand behaviour, how records fold under a group, the header, tabs with counts, filter chips, a grouped table that expands differently. The reference is the vpn-core Lines page. This document writes down the skeleton that Lines has, part by part, names the bridge tokens each part reads, and then maps Sub-Store, NetGuard and WireGuard onto it. A separate short section specifies the console's own Nodes table, whose sticky Node column leaks the scrolling cells beneath it.

The skeleton is the thing being standardised. Where Lines's current pixel values conflict with the token contract the console publishes (section 2), the contract wins and the conflict is stated, because the contract is the only thing all four frames can read at runtime.

## 2. Sources read

- vpn-core Lines: `lattice-plugin-vpn-core/ui/src/App.vue` (template lines 1179 to 1432: page header, proof line, summary strip, toolbar, fleet panel, node rows, bank rows, line rows, empty states, pagination, attention list) and `ui/src/styles.css` (all 578 lines). Screenshot 45.
- Bridge token contract: `lattice-plugin-bridge/src/bridge.ts` `HOST_TOKEN_NAMES` (42 names) and `applyTheme`; `lattice-dashboard/src/views/platform/pluginTokenContract.ts` (the same 42 names, published side) and `src/style/app.css` (the values: radius 3/4/6/8, `--row-h` 40 and 32, spacing 4 to 48 with no 20, body 14, mono 12, two durations, one curve, two shadows, three status fills with matching ink steps).
- Sub-Store: `ui/src/Shell.vue` (page header, underline tab bar with counts, search button), `screens/SubscriptionsScreen.vue` (section heading, heading actions, `LtToolbar` with kind and tag chips and a sort select, `LtBatchBar`, the `rec-scroll` grid with `rec-group` rowgroups and `rec` rows), `tokens.css`, `styles.css` (tabs, chips, record grid, 760 and 480 breakpoints), `components/lt/*`. Screenshot 44.
- NetGuard: `ui/src/App.vue` template (masthead, proof line, notices, lens switch with counts, exposure toolbar, groups and zones tables, editors), `components/ExposureTable.vue`, `components/StatusPill.vue`, `styles.css`.
- WireGuard: `ui/src/App.vue` template (page header with plugin label, security band, summary strip, topology panel, config layout, node panel, two modals), `styles.css`.
- Console Nodes table: `lattice-dashboard/src/components/common/NodeTable.vue`, `src/views/fleet/nodesTableModel.ts` (`nameTrackMin`, the column catalogue), `src/lib/fleet.ts` (`splitNamePrefix`). Screenshot 43. The live node list, read with one GET on `/api/nodes` (33 nodes), for the width measurement in section 8.

## 3. The token contract every part reads

The bridge writes exactly these 42 custom properties onto the plugin's `<html>` and drops any other name. A plugin declares the same names on its own `:root` as fallbacks and never a second scale. Plugin-local names are allowed only for derivations the console has no name for (soft fills, ink mixes, a scrim, z-index levels, the type steps between body and heading), and they must be built from published values.

| Group | Names | Value the console publishes |
| --- | --- | --- |
| Surfaces and ink | `--background` `--foreground` `--card` `--card-foreground` `--muted` `--muted-foreground` `--accent` `--accent-foreground` `--border` `--primary` `--primary-foreground` `--destructive` `--destructive-foreground` `--ring` | theme and palette dependent |
| Status fills | `--success` `--warning` `--info` and their `-foreground` pairs | fills, sized for something to sit on them |
| Status ink | `--success-text` `--warning-text` `--info-text` | the readable step for coloured text; in dark the fill and the ink are one value |
| Radius | `--radius-sm` 3px, `--radius-md` 4px, `--radius-lg` 6px, `--radius-xl` 8px, `--radius` 4px | |
| Row rhythm | `--row-h` 40px, `--row-h-compact` 32px | |
| Spacing | `--space-1` 4, `--space-2` 8, `--space-3` 12, `--space-4` 16, `--space-5` 24, `--space-6` 32, `--space-7` 48 | no 20 |
| Type | `--font-mono`, `--text-body` 14px, `--text-mono` 12px | the sans stack is inherited |
| Elevation | `--shadow-overlay`, `--shadow-raised` | only surfaces that float |
| Motion | `--duration-fast` 100ms, `--duration-base` 200ms, `--ease-out` cubic-bezier(0.19, 1, 0.22, 1) | |

Plugin-local derivations the chassis defines once (names are the chassis's, prefixed `--pc-`):

- `--pc-text-xs` 12px, `--pc-text-sm` 13px, `--pc-text-lg` 16px, `--pc-text-xl` 20px, `--pc-text-label` 11px. Body is `--text-body`; ids, paths and digits are `--text-mono`.
- `--pc-ok-soft`, `--pc-warn-soft`, `--pc-danger-soft`, `--pc-info-soft`, `--pc-neutral-soft`: `color-mix(in oklab, <fill> 12%, var(--card) 88%)`, neutral at 7% of `--foreground`. Their border partners at 40% of the fill into `--border`.
- `--pc-accent-ink`: `color-mix(in oklab, var(--primary) 55%, var(--foreground) 45%)` in light, 80/20 in dark. `--pc-danger-ink` likewise at 75/25 and 85/15. These exist because `--primary` written as text on its own soft fill reads 2.9:1.
- `--pc-hover`: `color-mix(in oklab, var(--foreground) 3%, transparent)`; `--pc-hover-solid` the same mixed into `--card`, for cells that sit over other cells.
- `--pc-scrim` black at 24% (45% dark), `--pc-scrim-strong` 34% (60% dark).
- `--pc-z-inline` 10, `--pc-z-panel` 20, `--pc-z-modal` 30.
- `--pc-dur` and `--pc-dur-base` alias the two durations so a reduced-motion query can zero them; a stylesheet cannot override the host's inline property directly.
- `--pc-measure` 62ch for descriptions and empty-state prose.

Lines today declares `--sp-*`, `--radius` 6px, `--text-sm` 12px and hex status tones of its own. Sub-Store is already on the published names. The chassis is on the published names; Lines adopts them when it moves onto the chassis.

## 4. The skeleton, as it exists on Lines

Reading order on the page, top to bottom. Every part is a block that stacks with `--space-4` between it and the next, except the proof line, which hangs directly under the header.

### 4.1 Page frame

`main.workspace`: fluid width, padding `--space-5` top, `clamp(var(--space-4), 2.2vw, var(--space-6))` sides, `--space-7` bottom. The frame is a viewport (the host sizes it to fill the console's main region), so the document is the only vertical scroller and no block caps its own height. Sub-Store's `.workspace` and NetGuard's are the same shape already.

### 4.2 Page header

```
+----+  Title  [PLUGIN BADGE]                                   [ (o) Refresh ]
|icon|  One-line description in muted body text.
+----+
observed at 23:21:14 · 25 nodes report · liveness: 138 running
```

- Grid `auto minmax(0, 1fr) auto`, `align-items: center`, gap `--space-3`, bottom padding `--space-5`, hairline `1px solid var(--border)` underneath.
- Icon mark: 36x36, `1px solid var(--border)`, radius `--radius-md`, `--card` surface, icon 19px in `--primary`. Sub-Store's is 34, NetGuard's 32; the chassis fixes 36.
- Title row: `h1` at `--pc-text-xl`, weight 650, line-height 1.25, `letter-spacing: -0.01em`; beside it the plugin badge: uppercase 10px (`--pc-text-label` minus one), weight 650, pill radius 999, info tone (`--info-text` ink on `--pc-info-soft` with its border). Text is `<name> plugin`: "VPN Core plugin", "Sub-Store plugin", "NetGuard plugin", "WireGuard plugin". Sub-Store has no badge today; NetGuard has none; both gain one.
- Description: one line, `--pc-text-sm`, `--muted-foreground`, max-width `--pc-measure`, `--space-1` above.
- Right slot: the page-level secondary action, which on every plugin page is Refresh (`button.secondary` with a 15px icon, spinner while refreshing, disabled while loading). Nothing else goes here.
- Proof line: mono (`--font-mono`), `--pc-text-label`, `--muted-foreground`, tabular numerals, segments separated by " · ", pulled up by `--space-3` so it sits in the header's bottom padding. It states the absolute time of the last read ("observed at HH:MM:SS"), the count of reporting objects, and one liveness or drift sentence. `aria-live="polite"`. No timer runs in the frame; the label is true for as long as the tab is open (vpn-core `refreshPolicy.test.ts`). NetGuard has this line already and its content stays; WireGuard and Sub-Store gain it.

### 4.3 Notices

Between the header and the stat strip. One component, four tones: danger (default, `role="alert"`), success (`aria-live="polite"`), warning, info. Flex, icon 17px, `1px` border in the tone's border, radius `--radius-md`, padding `--space-3`, `--pc-text-sm`, line-height 1.5. A bold first line for the title, then the message. Trailing controls: an optional compact secondary "Try again" and an icon-only dismiss (22px). WireGuard's security band is this component in the info tone with a 19px icon and a `code` fragment; it does not need its own class.

### 4.4 Stat strip and stat card

```
+---------------+---------------+---------------+---------------+---------------+
| Lines         | Lattice-mana… | Roles         | Nodes         | Service       |
| 138           | 0             | 101 relay · 3…| 25            | 138 running   |
| none reporti… | 138 discover… | 1 with no ou… | 0 of 25 carr… | every line r… |
+---------------+---------------+---------------+---------------+---------------+
```

- One bordered card, not five: `1px solid var(--border)`, radius `--radius-xl`, `--card`; tiles separated by vertical hairlines inside it. Grid `repeat(var(--stat-count, 4), minmax(0, 1fr))`. Margin `--space-5` above and below.
- Tile: column flex, gap `--space-1`, padding `--space-4`. Label `--pc-text-xs` 600 muted; value 20px weight 660 tabular, one line, ellipsis (the value may be a phrase, "101 relay · 36 exit"); footnote `--pc-text-label` muted. Below 720px the value wraps and drops to 17px.
- Tone on the tile, not the label: `data-tone="warning|error|neutral"` colours the value with `--warning-text`, `--destructive`, `--muted-foreground`. Nothing else on the tile is coloured.
- Four to five tiles. A page with fewer than three facts worth a tile has no strip.

### 4.5 Toolbar

```
[ Fleet | Topology | Attention (2) ]  [ Search node, line, endpoint…    ]  3 of 25 match          [ + Roll out managed lines ]
```

Flex, wrap, `align-items: center`, gap `--space-3`, margin-bottom `--space-4`. Slots in order:

1. Lens tabs. An inline pill group: container `1px solid var(--border)`, radius `--radius-lg`, `--card`, padding 2px. Each tab is a `role="tab"` button, min-height 28px, padding 4px `--space-3`, radius `--radius-md`, `--pc-text-sm` 600, muted; the selected tab has `--muted` fill and an inset 1px `--border` ring, foreground ink. Hover only changes ink. Optional leading 14px icon. Optional count: 18px high pill, min-width 18, radius 9, `--pc-text-label`, tabular, `--muted` fill; `data-tone="error"` paints `--destructive` with its foreground, `warning` paints `--warning` with `--warning-foreground`. A count is a fact about the tab's content (items, findings), and it is absent, never "0", until the list has been read. The tablist answers ArrowLeft and ArrowRight (Sub-Store's `onTabKeydown` is the reference); only the selected tab is in the Tab order.
2. Search. `input[type=search]`, min-height 34px, `1px solid var(--border)`, radius `--radius-md`, padding 7px `--space-3`, max-width 420px, placeholder that lists what it matches. Focus: border `--ring` and a 3px ring at 22% of `--ring`. A search opens every matching group (4.8).
3. Match note, only while searching: "3 of 25 nodes match", `--pc-text-xs` muted.
4. Spacer, `flex: 1 1 auto`.
5. Secondary actions, zero to two, `button.secondary`.
6. One primary action, `button.primary`: `--primary` fill, `--primary-foreground` ink, min-height 34px, radius `--radius-md`, `--pc-text-sm` 650, a 15px leading icon. The verb that creates or rolls out the page's main object. If the session may not do it the button is absent (not disabled) and the reason appears as a permission note in slot 3.

The toolbar row has no filter chips. A page that needs a persistent filter (a sort, a tag) puts a compact select in slot 3, and a page that needs many-valued filtering gets one "Filters" secondary button that opens a popover. Chips are a data vocabulary (4.7), not a filter control. Sub-Store's chip row is the one thing on any page that departs from the skeleton at first glance and it goes.

### 4.6 The table card

```
+------------------------------------------------------------------------------+
| Fleet                                                        [25 nodes · 138 lines]
| Every node that reports an inbound, with its lines folded underneath.        |
+------------------------------------------------------------------------------+
| NODE / LINE          ROLE      ENDPOINT     …   CONFIG    SERVICE    ACTIONS |
+------------------------------------------------------------------------------+
| > [cd]-Aaitr-ATT-VDS   1 line · 1 exit           ● ok     (running)  [Evidence]|
|   aaitr-att                                                                  |
| > [cd]-DMIT-eb-wee     3 lines · 1 relay · 2 exit ● ok    (running)  [Evidence]|
|   dmit-eb-wee                                                                |
| v [Metix]-DMIT-1       13 lines · 12 relay · 1 exit · bank of 12 vless → 7 nodes
|   dmit-1                                                                     |
|     > 12 vless relays   (bank)  203.0.113.4   …     ● ok     (running)       |
|       ports 24443 to 24454                                                   |
|     vless-exit-1        (exit)  :443 203.0.… …      ● ok     (running)  [Details][⇢]|
|     vless / 1f3a9c…                                                          |
+------------------------------------------------------------------------------+
| Nodes 1 to 25 of 33                                 [Previous] Page 1 of 2 [Next] |
+------------------------------------------------------------------------------+
```

Card: `1px solid var(--border)`, radius `--radius-xl`, `--card`, `overflow: clip` (not hidden, which would make a scroll container and catch the sticky header). Margin-bottom `--space-4`.

Panel header: min-height 52px, flex, space-between, padding `--space-3 --space-4`, hairline below. `h2` at `--pc-text-body` (14px) 650; description `--pc-text-sm` muted on the next line, max `--pc-measure`. Right: a count badge (4.7) stating the panel's population, "25 nodes · 138 lines".

Scroll wrap: `overflow-x: auto; overflow-y: visible`. The document scrolls vertically; the wrap only scrolls sideways when the columns are wider than the frame. `table { width: 100%; min-width: 720px; border-collapse: separate; border-spacing: 0; font-size: var(--text-body) }`. A fleet table sets its own min-width (Lines: 1080px) so eleven columns fit a 1440 frame without a sideways scroll.

Header row: `th` sticky at top 0, z-index 2, height 32px, padding 0 `--space-3`, `--pc-text-label` (11px) uppercase 600, letter-spacing 0.04em, muted, surface `color-mix(in oklab, var(--muted) 48%, var(--card))`, bottom hairline drawn as `box-shadow: inset 0 -1px 0 var(--border)` so it travels with the sticky header. Numeric columns right-aligned. Sortable headers are a borderless button with a 9px sort mark at 55% opacity, full at `aria-sort`.

Rows: `td` height `--row-h` (40px), padding 0 `--space-3`, `vertical-align: middle`, hairline `1px solid color-mix(in oklab, var(--border) 60%, transparent)` below, none on the last row. No zebra. Hover `--pc-hover` on every cell, `transition: background-color var(--pc-dur) var(--pc-ease)`. Selected row (where selection exists) `color-mix(in oklab, var(--primary) 8%, transparent)`. Lines today pads 12px vertically and paints 50px rows; it drops to 40 because the console's `data-grid`, Sub-Store's `rec` and the published `--row-h` are all 40 and the two-line name cell fits (20px name line over 16px id line). At `data-density="compact"` the row is 32px and the id line is hidden (the console's `density-secondary` rule).

Cells that carry two lines: `strong` at `--text-body` 620 for the name, `small` at `--text-mono` in `--font-mono` muted for the id, `margin-top: 2px`, `max-width` 250 to 380px, single line, ellipsis, `title` carrying the full value. Any cell that can overflow truncates and carries a title; a wrapped value breaks the row rhythm and is not allowed inside a table.

Column budget (Lines): the name column `min-width: 240px`; mono cells max 260px; the outbound cell max 300px. Actions column sticky at the right edge (`position: sticky; right: 0; z-index: 1`), `--card` surface, `box-shadow: -1px 0 0 var(--border)`; the corner header cell z-index 3 with the header surface. Below 720px the actions cell is static and scrolls with the row (two sticky columns would leave nothing to scroll into).

Row action: `button.secondary.compact`, min-height 28px, padding `--space-1 --space-2`, `--pc-text-xs` 650, `1px solid var(--border)`, radius `--radius-md`, `--card`, a 13px icon, right-aligned. One text button per row; a second action is a 30px bordered icon button beside it (`.row-actions`, gap `--space-1`). Row actions are always visible; the console's hover-reveal is not used in frames, where the row is also a keyboard target.

### 4.7 Chips and badges: one vocabulary

Three roles and one count. Everything on every page that is a small rounded label is one of these four; nothing else is allowed.

| Role | What it names | Shape | Ink and fill |
| --- | --- | --- | --- |
| kind | what a record is: bank, combination, file, built in, lattice-managed | pill radius 999, `1px solid var(--border)`, padding 2px 7px, 10px 650, optional 12px icon | `--muted-foreground` on `--card`; `data-tone="info"` for a managed or derived kind (`--info-text` on `--pc-info-soft`) |
| tag | operator-applied labels: tags, owners, groups | pill radius 999, no border, padding 0 `--space-2`, 12px, line-height 18px | `--muted-foreground` on `--pc-neutral-soft`; overflow folds to one "+N" tag with the full list in the title |
| state | a verdict word: running, down, drift, expired, not published | two forms, see below | tone from `data-tone`: healthy `--success-text`, warning `--warning-text`, error `--destructive` (dark: mixed 88% to white), info `--info-text`, neutral `--muted-foreground` |
| count | a population: 5, 2, 25 nodes · 138 lines | pill radius 999, min 18px, padding 0 5px, 11px tabular | `--muted` fill; error and warning tones as in 4.5 |

State has two forms and a column uses one of them throughout:

- dot: a 7px `currentColor` disc then the word, 12px 600, no fill, no border. For a column whose values are mostly healthy (Config on Lines, Online on Nodes): the quiet form, so 25 green rows are not 25 pieces of emphasis.
- pill: the word on the tone's soft fill with the tone's border, 10px 650, padding 2px 7px, radius 999. For a column that carries a service or lifecycle word (Service on Lines, Drift on NetGuard, Published on Sub-Store).

A `title` on every state carries the evidence ("checked 23:21:14", the drift reason). Colour is never the only carrier; the word is always printed.

### 4.8 Collapse and expand

What folds under what: a group row owns the rows beneath it, and a record row may own a detail beneath it. Two levels at most, plus a bank inside a group on Lines (node > bank > line), which is the ceiling. Each level indents the name cell by 22px (chevron width plus gap); a third level by 44px.

Group row (Lines `.node-row`): every cell painted `color-mix(in oklab, var(--muted) 34%, var(--card))`, so the group reads as a shelf. First cell: a borderless `button.toggle` holding a 14px chevron-right and the bold name, `aria-expanded`, `aria-controls` pointing at the first child row's id; under it the muted mono id. The remaining cells are a summary sentence spanning the columns ("13 lines · 12 relay · 1 exit · bank of 12 vless → 7 nodes"), then the group's own verdict cells and its own action. A group row is a row: it has the row height, the hover and the hairline; it is not a heading with a rule beside it (Sub-Store's `rec-group-head` and the console's group divider both become this).

Bank row (Lines `.bank-row`): a nested group, painted `color-mix(in oklab, var(--pc-info-soft) 55%, var(--card))`, kind chip "bank".

Child row (Lines `.line-row`): plain `--card`, indented name cell, full cells. Children are printed only while the parent is open (`v-if`, not `v-show`): 25 groups with 138 children stay a page rather than a scroll.

Chevron: `ChevronRight` 14px, muted; `transform: rotate(90deg)` when open, `transition: transform var(--pc-dur) var(--pc-ease)`; reduced motion removes the transition. No height animation: table rows cannot animate height without a wrapper per row, Lines does not, and the row appearing on the next frame is the honest behaviour of a table. A row that opens a detail panel (not children) paints its own cells `color-mix(in oklab, var(--muted) 40%, transparent)` and drops its bottom hairline so the detail reads as attached (Lines `.usage-row[data-open]`).

State: a `Set` of open keys per level; toggling one key never touches another. The document query may open a state on load (`?expand=<id>`, `?bank=<key>`, `?lens=<name>`), so a link can carry the state being discussed. A search opens every matching group, because the operator asked for children, not for groups; clearing the search restores the operator's own set. Default: closed. A page whose groups usually hold one child may open all groups by default when the total row count is below 25.

Keyboard: the toggle is a real button, so Enter and Space toggle it. Inside the table ArrowRight opens and ArrowLeft closes the focused toggle; ArrowDown and ArrowUp move between toggles. Escape closes the top of the overlay stack and nothing else (Sub-Store's `overlayStack` is the reference). Focus never moves on toggle.

### 4.9 Empty, loading and error

- First load: a skeleton, not a spinner. The stat strip's four tiles as bars, then a table card holding eight skeleton rows on a four-track grid (`minmax(0,2fr) 1fr 1fr 1fr`), bars 10px high radius 3 at 18% of `--muted-foreground`, pulsing 1.4s only under `prefers-reduced-motion: no-preference`. `role="status"` with an aria-label naming what is loading. The skeleton reserves `--row-h` per row so the page does not resize when data lands.
- Background refresh: the proof line appends "· refreshing", the Refresh button shows the spinner, the table stays. Never blank a table that has data.
- Stale: a write succeeded and its reload failed, or the newest read failed after a good one. The rows stay and a warning notice says "The topology below is the last good read, not the current one" with the error.
- Empty, no data: inside the table card, 200px min-height, centred, 26px icon, a bold sentence naming the state ("No lines are visible yet"), a paragraph of at most `--pc-measure`, and where causes are known an ordered list of them. Actions row centred below.
- Empty, no match: the same block with "No line matches that search", the searched term in mono, and a "Clear the search" secondary button.
- Permission wall: the same block, stating which method the session lacks in mono ("`lines.chains`") and what still works.
- Error with nothing loaded: a danger notice above with the message and "Try again", and the empty block reading "Nothing could be loaded. This is not an empty fleet, it is an unanswered question."
- Handshake never arrived: Sub-Store's `StandaloneNotice` and WireGuard's "The console has not answered" are the same state; the chassis has one block for it with a "Reload the page" action.

### 4.10 Overlays

Fixed and centred on the frame's viewport, `--pc-z-modal`, scrim `--pc-scrim-strong`, padding `--space-4`. Modal: `min(660px, 100%)` (small 440, large 880), max-height `calc(100vh - 2 * var(--space-6))`, `overflow-y: auto`, `overscroll-behavior: contain`, `1px solid var(--border)`, radius `--radius-xl`, `--card`, `--shadow-overlay`. Header and footer flex with `--space-4` padding and hairlines; `h2` at `--pc-text-lg`. Focus moves to the dialog on open and returns to the opener on close; Tab is trapped; the overlay registers with the stack so one Escape closes one thing.

Side panel (Sub-Store `LtPanel`, "sheet"): the same rules, docked right, 440px for a record form and 960px for an output document, under `--pc-z-panel` and `--pc-scrim`. A row-scoped form or view opens as a side panel; a question opens as a modal; evidence that compares against the table opens in place under the row (4.8). NetGuard's `NodeDetail` block below the table is the third kind and moves in place.

Batch bar (Sub-Store `LtBatchBar`): floats over the foot of the table card at `--pc-z-inline`, 46px, names the count it will act on, and the page keeps a bar's worth of room under its last row.

### 4.11 375 behaviour

The frame is 375px wide with no sidebar. Breakpoints: 720px and 620px as on Lines, plus 480px for the tab row.

- Header: grid drops to `auto minmax(0,1fr)`; the Refresh button spans the full width below on its own row. The proof line wraps by segment.
- Stat strip: two tiles per row at 720 and below (hairlines on the right of odd tiles and under every row but the last); one per row at 620 and below. Values wrap and drop to 17px.
- Toolbar: column flex, `align-items: stretch`. The tab group scrolls sideways within its own box (`overflow-x: auto`, no wrap) and at 480 drops tab icons. Search is full width. The primary action is full width below the search. Secondary actions sit in one row of equal-width buttons.
- Table card at 720 and below: the table keeps its columns and scrolls sideways inside the card; the name column pins left (`position: sticky; left: 0; z-index: 1`, opaque `--card` with `box-shadow: 1px 0 0 var(--border)`), narrowed to `min-width: 168px; max-width: 200px`; the actions column unpins. Under the name a `.narrow-status` line appears with the row's verdicts (the dot state and the state pill) so the red state is readable without a sideways scroll. This is Lines's behaviour and it stays the default because it keeps every column reachable.
- Table card at 480 and below (the phone case): the row becomes a stacked block. Line 1: chevron, name (bold), status dot at the name baseline, the row's primary action as a 32px bordered icon button at the right edge. Line 2: muted mono id. Line 3: the state pills. Every other column folds into a two-column label and value list (`--pc-text-xs` label, value) that prints only when the row is expanded; the labels are the column headers. Group rows keep their summary sentence on line 2 in place of an id. The header row is hidden (`sr-only`), and the column that was sticky no longer needs to be. Secondary row actions move to the end of the expanded body, right-aligned.
- Overlays: modal and side panel take the full width less `--space-2`; footer buttons flex to equal widths; body padding drops to `--space-3`.

## 5. Components the chassis lane must build

One package, `@latticenet/plugin-chassis`, beside the bridge: Vue 3 single-file components, one stylesheet declaring the fallbacks and the `--pc-` derivations, no colour of its own. All four plugin UIs are Vue 3 on `@lucide/vue`, so a component package costs no new runtime; the alternative, a CSS-only sheet with a class contract, would let each plugin keep re-authoring the toggle, the tablist keyboard model and the overlay stack, which is where the four pages drifted apart in the first place. The behaviour lives in components; the look lives in one sheet.

| Component | Section | Notes |
| --- | --- | --- |
| `PcWorkspace` | 4.1 | the page frame |
| `PcPageHeader` | 4.2 | icon, title, plugin badge, description, right slot |
| `PcProofLine` | 4.2 | segments, `aria-live` |
| `PcNotice` | 4.3 | danger, success, warning, info; retry and dismiss slots |
| `PcStatStrip`, `PcStatCard` | 4.4 | `--stat-count`, tone on the tile |
| `PcToolbar` | 4.5 | ordered slots: tabs, search, note, secondary, primary |
| `PcLensTabs`, `PcLensTab` | 4.5 | tablist keyboard model, count with tone |
| `PcSearchField` | 4.5 | |
| `PcButton` | 4.5, 4.6 | primary, secondary, danger, compact; `PcIconButton` plain and bordered |
| `PcPanel`, `PcPanelHeader` | 4.6 | the table card and any bordered block |
| `PcTable`, `PcTh`, `PcTd` | 4.6 | sticky header, sortable header, numeric, mono, sticky actions |
| `PcGroupRow`, `PcBankRow`, `PcRow` | 4.8 | the three row levels; `PcRowToggle` with the chevron |
| `PcNameCell` | 4.6 | name, muted mono id, optional dot, narrow status line |
| `PcStateDot`, `PcStatePill` | 4.7 | the two state forms |
| `PcKindChip`, `PcTagChip`, `PcTagList` | 4.7 | tag overflow "+N" |
| `PcCount` | 4.7 | |
| `PcRowActions`, `PcActionsCell` | 4.6 | |
| `PcPagination` | 4.6 | the card footer |
| `PcSkeleton` | 4.9 | strip and rows |
| `PcEmptyState` | 4.9 | empty, no match, permission, error, handshake |
| `PcStackedRow` | 4.11 | the 480 form of a row |
| `PcModal`, `PcSidePanel`, `PcConfirmDialog` | 4.10 | on one `useOverlayStack` |
| `PcBatchBar` | 4.10 | |
| `PcSelectCell` | 6.1 | optional leading selection column |
| `useExpandSet`, `useOverlayStack`, `useDocumentQueryState` | 4.8, 4.10 | the behaviour |

Sub-Store's `Lt*` set is the closest existing implementation (badge, button, toolbar, panel, batch bar, empty state, skeleton, confirm dialog) and is the starting point for the package; Lines's markup is the reference for the table and rows.

## 6. Mapping the consumer pages

### 6.1 Sub-Store

Today: a page header without badge or Refresh; an underline tab bar with counts and a search button on the right; per tab a section heading with its own actions; a toolbar of filter chips (kind, tags) and a sort select; a batch bar; a grid of rows under collapsible group headings with a caret, a count and a rule; 4px radius everywhere; a side panel and modals. The skeleton it becomes:

- Header: Store icon, "Sub-Store", badge "Sub-Store plugin", the existing description, Refresh on the right (reloads the record catalogue and the share list). Proof line: "observed at HH:MM:SS · 7 records · 16 files · 1 share live".
- Stat strip, five tiles: Records "7" with "0 of 256 budget left" as footnote; Published "0 of 7" (warning tone while zero and records exist); Files "16"; Shares "1 live"; Last fetch "n/a" or the newest fetch time.
- Toolbar: lens tabs Subscriptions (7), Files (16), Shares (1), Settings (no count); search "Filter by name, id, remark" (one search across the visible tab; Cmd+K still opens the command palette, and the palette's entry becomes a bordered icon button in the secondary slot); the sort select as a compact select in slot 3; secondary "New combination"; primary "New subscription". On Files the primary is "New file" and there is no secondary; on Shares the primary is "Open in Networking"; on Settings the toolbar has only the tabs. The kind chips go: the two kind groups below carry the same partition and their counts. The tag chips go: tags print on the rows (tag chips) and the search matches them; a tag filter, if wanted, is one compact select "Tag" in slot 3.
- Table card "Records", description "One row per record, folded under its kind. A combination is a set of subscriptions merged into one output." Count badge "7 records · 16 files" on Subscriptions.
- Optional leading selection column (`PcSelectCell`, 18px, header checkbox with indeterminate) since batch delete exists; the batch bar floats over the card foot.
- Columns: Record | Source | Nodes | Operations | Published | Last fetch | Actions. Group rows: "Subscriptions" (count 5) and "Combinations" (count 2), painted as group rows (4.8), summary sentence "5 records · 2 published". Records fold under their kind group; the row's chevron opens the record's operations chain under it as child rows (one per operation: name, kept/dropped counts in mono, an "off" kind chip when disabled), which is what `rec-chain` shows today.
- Row: name cell with a kind icon (Library or Layers) before the bold name, tag chips after it (folded to "+N"), muted mono id under; Source in `--pc-text-sm` muted ("Pasted nodes", "Provider link"); Nodes mono right-aligned ("28 → 28"); Operations mono right; Published as a state pill ("not published" neutral, "published" healthy, "expired" warning); Last fetch mono muted; Actions: `Open` compact secondary button plus a bordered icon button for the record menu.
- Files tab: the same card with columns File | Source subscription | Nodes | Published | Last fetch | Actions and no groups. Shares tab: Share | Record | Client | State | Expires | Actions, with a "Copy link" icon action. Settings: no table; a `PcPanel` holding the form grid.
- Editors stay full-screen inside the tab panel with the breadcrumb; the preview and target sheets stay side panels.

### 6.2 NetGuard

Today: a masthead without badge, the proof line, notices, a pill lens switch with counts, an exposure toolbar with a search and a page note, an exposure table with a sticky node column and a row that opens a detail block below the table, a findings list, groups and zones tables with their own heading blocks and a primary button each. It is already close to the skeleton; the differences are radius (4/6 against the chassis's 4/8 on the card), the missing stat strip and badge, the detail block, and the group and zone heading blocks.

- Header: Shield icon, "NetGuard", badge "NetGuard plugin", the existing description, Refresh. Proof line unchanged.
- Stat strip, five tiles from the proof line's counts: Nodes; Managed; Observe only (neutral tone); Drift (error tone when non-zero); Stale (warning when non-zero). The proof line keeps the observed time and drops the counts, which the tiles now carry.
- Toolbar: tabs Exposure (findings count, error tone), Groups (count), Zones (count); search "Search by node, group, zone, port or process" (on Exposure), match note; primary "New group" on Groups, "New zone" on Zones, none on Exposure.
- Exposure card "Exposure", description "What each node actually has open, against what you declared." Columns: Node | Exposure | Managed by | Drift | Seen | Actions. Node cell: bold name, muted mono id, snapshot status as the dot form (ok, stale warning, unknown neutral) at the name baseline. Drift as the state pill (in sync healthy, drift error, observe only neutral). The row's chevron opens the node's detail in place under the row (the current `NodeDetail`: binding, groups, zones, ruleset review, with "Edit binding" and "Plan apply" as the child block's action row), so the table stays on screen beside the detail. Findings for that node fold under the same detail. The page-wide findings list becomes a second `PcPanel` "Findings" under the table, in the attention-list form (severity dot, claim, evidence, action), which is Lines's Attention panel.
- Groups card: group rows are the security groups (bold name, mono id, "allows …" summary sentence, "used by N nodes" and source version in their cells, Edit and Delete as bordered icon actions); the rules fold under the group as child rows (action as a kind chip, the rule sentence in mono, comment in `small`). Zones card: flat rows (Zone | Interfaces | CIDRs | Kind | Used by | Actions); built-in zones carry the kind chip "built in" and no actions.
- Editors and the apply dialog stay modals; the delete question stays a confirm dialog.

### 6.3 WireGuard

Today: a Lines-style header with badge, the security band, a four-tile strip, a topology panel with a mesh grid of peer buttons, a two-column config layout for the selected node, a node panel with a sortable table, and two modals. It is on Lines's stylesheet nearly verbatim, so its distance from the chassis is the same as Lines's own: token names, 6px radius, 12px body, 50px rows.

- Header unchanged in shape; the security band becomes `PcNotice` in the info tone. Proof line: "observed at HH:MM:SS · 25 nodes · 14 mesh-ready · 3 online".
- Stat strip unchanged in content: Ready nodes, Online mesh, Public endpoints, Partial setup.
- Toolbar: tabs Fleet (node count) and Mesh (ready count); search "Search node, address, endpoint or key" on Fleet; no primary action (Plan is per row and the page has no page-level verb; Refresh is in the header).
- Fleet card "Fleet nodes", the existing description. Columns: Node | Address | Public key | Endpoint | Configuration | Agent | Actions. Node cell: bold name, muted mono id, the online state as the dot form at the name baseline. Configuration as the state pill (ready healthy, partial warning, none neutral) with the readiness gap in `small`. Agent: last seen in mono. Actions: `Plan` compact secondary button, disabled with the gap as its title when the node is not ready. The row's chevron opens the node in place: the interface facts list (reported address, AllowedIPs, listen port, redacted key, endpoint, last seen, key source) and the visible peers as child rows (Peer | AllowedIPs | Endpoint), which replaces the two-column config layout. No groups by default; the chassis allows a flat table.
- Mesh tab: the topology panel as a `PcPanel` with the readiness grid inside; selecting a peer switches to Fleet with that node expanded (`?expand=<node_id>`).
- The plan and approval modals stay modals (small and large).

## 7. What Lines itself changes

Lines is the reference for shape and behaviour, not for the values it happens to paint today. Moving onto the chassis it adopts the published names (`--space-*`, `--radius-md` 4 on controls, `--radius-xl` 8 on cards, `--text-body` 14, `--text-mono` 12, `--row-h` 40), gains the ArrowLeft and ArrowRight tablist model and the in-table arrow keys, and gets the 480 stacked row. Nothing in its anatomy moves.

## 8. The console Nodes table

Screenshot 43 shows the defect: with the table scrolled sideways, the Status column's text and dot ("ne●" of "Online") show through on the left of every Node cell. The cause is in `NodeTable.vue`: the row is a CSS grid with `gap-3` (12px) and `px-3` (12px) padding, the selection cell and the name cell are each sticky with their own `bg-background`, and the 12px gap between them, the 12px row padding before the checkbox, and the `sm:left-15` offset of the name cell are all transparent, so whatever scrolls under paints through. The header paints `bg-card` while the cells paint `bg-background`, two different surfaces in one column; and the row hover is a `color-mix` into `--background` while the header never changes, so the sticky column and the header disagree again on hover.

Specification:

- The sticky region is one opaque block per row from x=0 to the Node column's right edge: the selection checkbox and the name cell are rendered inside one grid cell that is `position: sticky; left: 0`, carrying the row's left padding inside it (`padding-left: 12px`) so no transparent strip exists to its left. Its background is `var(--card)` on the row and `var(--card)` on the header, the same surface, opaque, never a `color-mix` into transparent. Hover paints the sticky cell `color-mix(in oklab, var(--foreground) 3%, var(--card))` (the opaque form of the row hover). The selected row paints the sticky cell `color-mix(in oklab, var(--primary) 8%, var(--card))`.
- z-index: sticky cells 10, the sticky header cell 20, the rest of the row 0. The card's `overflow-x: auto` wrapper is the containing scroller and nothing else in the row is positioned.
- Right edge: `box-shadow: inset -1px 0 0 var(--border)` on the sticky cell and on its header cell, so the pinned column ends in a hairline whatever passes under it.
- Owner (the bracketed name prefix, `splitNamePrefix`) moves out of the Node cell into its own "Owner" column immediately after Node, rendered as a tag chip, sortable, 112px wide (the widest owner, "OpenJobs-Data", measures 103px at 14px medium and 81px at the chip's 11px, plus 10px chip padding and 12px cell padding; 112 matches the Status column). Grouping by owner remains a group-by option and does not change the column.
- Node cell content: status dot (8px) aligned to the name's baseline (`align-items: baseline` on the flex row with the dot given `align-self: center` on its own 20px line box, or a `translateY(-1px)` at 14px; the current `items-center` on a two-line cell floats the dot between the two lines), then a 20px line for the name at 14px weight 500, and a 16px line for the id at `--text-mono` 12px mono muted. Both lines truncate with the full value in the title; at compact density the id line is hidden.
- Node column width: measured, not estimated. `nameTrackMin` currently estimates 8.3px per character and admits it ("An estimate, not a measurement"). The column takes the width of the longest name body on the page plus the fixed chrome, measured once per data load with `CanvasRenderingContext2D.measureText` on an offscreen canvas in the page's computed body font ("500 14px" of the body stack), and re-measured on `document.fonts.ready`. If the CSP refuses a canvas context the fallback is the existing estimate. The result is clamped to `[180, 440]` as today.

Measured widths used here (33 live nodes, names read from `/api/nodes`, owner prefix stripped, SF Pro at 14px, weight 500, via PIL on the system `SFNS.ttf`; the console's own comment records Chrome on macOS drawing the same string at 187px):

| Name body | Width, 14px medium |
| --- | --- |
| Akkocloud-UK-London-KVM | 180px (PIL), 187px (Chrome, recorded in `nodesTableModel.ts`) |
| gomami-jpn-pulse-nano | 152px |
| Aaitr-jp-softbank-NAT | 149px |
| gomami-hk-turin-mini | 137px |
| gomami-jp-pulse-mini | 137px |
| LegendVPS-SG-EVO | 132px |

The longest id, `node_4ol55vwphys3rgdt`, measures 147px at 12px SF Mono and sits under the name without truncating.

Node column width on this fleet, taking the Chrome figure: 12px row padding + 8px dot + 8px gap + 187px name + 12px cell padding + 1px hairline = 228px; with the selection checkbox in the same sticky cell add 16px + 12px gap = 256px. The chassis rounds to the 4px grid: 228px without selection, 256px with. The old estimate for the same fleet produced 239px with the prefix badge inside the cell (the comment in `NodeTable.vue` names that number), so moving the owner out and measuring the body saves 11px at the widest and removes the guess.

Below `sm` (640px) the table scrolls freely and nothing is sticky, as today: a 256px pinned cell on a 375px frame leaves 119px for every other column.
