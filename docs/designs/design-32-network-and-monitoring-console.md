# Design 32: network and monitoring console, one model per concept

Status: accepted 2026-10-24 after an architecture review. S0, S1, S2a, S2b and S3a are built and shipped (see "As built"); S3b, S4 and S5 are not started.
Date: 2026-10-24.
Reference: lattice-server `integration` at bd335aa, lattice-dashboard `integration` at da8eb50, lattice-sdk `integration` at fbe4441, lattice-plugin-netguard at 1b37d1b, lattice-plugin-wireguard at 408e399. Production versions live only in `PROGRAM.md`.

## Summary

The operator reviewed the network and monitoring areas on 2026-10-24 and found them hard to read and hard to use. A code survey of both areas and a walk through the live console confirmed the complaints and found defects underneath them. The causes are structural, not cosmetic:

- Monitoring has one measurement model shown under three names (paths, probes, checks), counted four different ways, and created from the wrong tab. A check holds exactly one target in the data model, so "one source probing many targets" needs one check per target, and the only many-to-many construct, the path set, is a single fleet-wide setting that reads like a second concept.
- Topology and Paths draw the same matrix with different tools. Topology has the graph and no search; Paths has the search and no graph. Clicking an edge in Topology jumps to the Paths tab and Escape does not return. Checks to a node are drawn as pseudo-nodes, so one target appears twice in one picture.
- Networking spreads four interlocking concepts over two sidebar sections with no links between them. Node groups, Network Policy (outbound only, one document per node), NetGuard (inbound only: zones, security groups, per-node bindings) and the WireGuard mesh each change the same nodes, and no page shows what applies to a node. "Group" means two different objects. "Network Policy" reads like the firewall but is egress only.
- Three defects are dangerous enough to fix before any redesign: a port range in a policy rule silently becomes "all ports"; the legacy firewall route and the self-host DNS plan rebuild the inbound table without NetGuard's security groups, at plan and at approve; a public DNS deployment with a forward zone is an open recursive resolver and nothing refuses it.

The design makes one object per concept and one control for choosing targets:

1. **A check is the one thing you create; a path is what you see.** A check gets a source set and a target set (nodes, groups, tags or the whole fleet). The server keeps one measured monitor per (target, method) the way it already does for the path set, so history and design 29's identity rules hold; a target that leaves the set is paused with its history, never deleted. The path set becomes the built-in check named Fleet mesh, listed with the others.
2. **Topology absorbs Paths.** One view, graph and list modes, one search bar that filters both, the path sheet opening in place on an edge, and a node sheet that leads with the node's paths.
3. **Networking is named by direction and anchored on the node.** Inbound firewall (NetGuard), outbound policy (Network Policy), WireGuard mesh, and a per-node Network section that shows the effective result of all of them plus SSH Guard. Node groups stay a fleet-wide targeting primitive with a Used by section, not a feature folded into policy.
4. **One target selector** (nodes, groups, the whole fleet, exclusions, with a live preview of the resolved nodes) is used by check sources and targets, policy targets and remotes, security-group bindings and mesh membership.

## What the operator asked

Paraphrased from the 2026-10-24 review: the Nodes list cannot show traffic; Groups and Network Policy feel like one feature split in two; a new policy cannot target a group, one node or several nodes; groups, policy, NetGuard and WireGuard are intertwined and the console does not show how; Paths should merge into Topology with search kept, an edge opening the path sheet the operator likes, and a node opening a node sheet; checks and paths look like two concepts, paths cannot be created, one source probing many targets needs one check per target, and a TCP check takes only one target node; the network area needs clear layers, professional naming and interaction that does not blur crossing concepts. Separately, what the best DNS arrangement for the fleet is; that answer lives in the vault and its Lattice parts are D8 here.

## Evidence

Three code surveys and one live walk, all on 2026-10-24 at the references above. The findings that decide the design:

- `model.Monitor` has one `Type`, one `Target` and one optional `TargetNode`; its sources are `AssignAll` or `NodeIDs` (lattice-sdk model/model.go:1731-1802). The single TCP target is a model limit, not a form limit.
- The path set is one `LatencyProbeConfig` (model/latency.go:62-102). The server expands it into managed monitors, one per (target, method), with ids `mon_lat_`, `mon_lati_`, `mon_latb_` plus the target, `ManagedBy: "latency"`, through `SyncManagedMonitors(managedBy, desired)` (internal/store/latency_probes.go:89-130), which already takes the owner as an argument.
- Paths are keyed in URLs as `<source>~<target node>` for generated checks and `<source>~@<monitor id>` for operator checks (lattice-dashboard pathsModel.ts:158-167).
- Topology's node click opens the fleet node sheet on `?peek=`, which shows no paths (TopologyLayer.vue:465-473); the per-node paths card exists only on the node page (NodeDetailView.vue:1903).
- `NetPolicy` has a single `TargetNodeID` and compiles egress only into `inet lattice_policy` with policy drop; an ingress rule fails the plan with "egress-only MVP" (internal/netpolicy/compile.go:76-118). `GroupNetPolicy` expands per member and is authored only from the matrix cells (internal/netpolicy/expand.go:22-60).
- NetGuard writes `inet lattice_guard` on the input hook through one renderer fed by four composers: NetGuard, the legacy `/api/network/nft/plan`, the self-host DNS plan and the beacon plan. The legacy and DNS composers ignore `NodeGuardBinding` (internal/server/server_nft.go:170, server.go:7354, server_dns.go:232-262).
- NetGuard bindings are per node; the security-group editor offers group and domain remotes that the compiler always rejects (internal/netguard/compile.go:314-317).
- WireGuard is one implicit full mesh over every node with a public key and a `wireguard_ip` (internal/wireguard/wireguard.go:64-95); the network, membership and external-peer types exist in the SDK and nothing stores them.
- The policy form's `parsePorts` drops any token that is not an integer, so `8000-8010` becomes `[]`, which the model reads as all ports (lattice-dashboard PolicyView.vue:555-564).
- `validateDeployment` accepts `exposure: public` with a `forward` zone (internal/selfdns/selfdns.go:645-670).
- The live walk counted 31, 28, 24 and 19 for the same set of paths across four views, and found four words for "not measured".

## D1. Checks and paths

**The object model.** A check is a definition: a method, a source set, a target set, a schedule, expectations and alerting. A path is one (source, target) pair a check measures; it is derived, never authored. The console says "check" for the definition and "path" for the pair everywhere, and drops "probe" as a noun.

**Source and target sets.** Both are selectors (D5): explicit nodes, groups or the whole fleet, plus excluded nodes. A selector is stored, not resolved, so a node that joins a group joins the check. For a node-to-node method (tcp, icmp, beacon) the target set resolves to nodes. For an external method (http, tls, or tcp and icmp to an address) the target set is a list of addresses or URLs; each entry becomes its own target.

**Server model.** A new stored object, `CheckDefinition`, holds the selectors and the shared fields. The server expands it into managed monitors through the same `SyncManagedMonitors` the path set uses, with `ManagedBy: "check:<definition id>"`. Expansion runs on save and whenever group membership, node tags or the node list change, using the same triggers that resync the path set.

**Monitor identity.** An expanded monitor's id is `mon_chk_<definition>_<h>`, where `h` is a short stable hash of the method and the normalized target (the node id, or the canonical address or URL). Removing one entry from a target list therefore never hands another entry its history, and a method change produces a new id, which is design 29 D1 (one series, one target). Ids are opaque: no code parses them, and the definition and target are read from the monitor's fields.

**A target that leaves the set pauses, it is not deleted.** This is what the path set already does: a target that leaves its set keeps its monitors, paused, with their history (lattice-server `internal/server/latency_probes.go:718-733`); only a node removed from the fleet loses its monitors. Definitions follow the same rule, so a group or tag change that flaps cannot destroy data. History is deleted only when the operator deletes the definition or chooses "forget paused targets" on it, both of which name the monitors and their run counts before confirming, because deleting data is the operator's decision.

**Edits reach the expanded monitors.** Edits to shared fields (sources, interval, timeout, expectations, headers, alert, alert-after, degraded rule) rewrite every expanded monitor in one store write. This requires a store fix: `managedMonitorEqual` (`internal/store/latency_probes.go:211-217`) compares only some fields, so today an edit that changes only the alert, alert-after, degraded rule, expected statuses, headers, secrets origin or paused nodes writes nothing. It must compare every field except timestamps and version. The path set benefits from the same fix.

**One owner classification.** The server reads a non-empty `ManagedBy` as "path set or beacon" in about ten places, so a definition monitor would inherit all of them: `pathEntries` skips every managed monitor (`monitor_paths.go:709`), `monitorPolicyWith` and `monitorAlertOf` force alerting off for every owner other than operator and path set (`monitor_degraded.go:83-85`, `server_views.go:269-271`), visibility uses the generated-path rule (`monitor_paths.go:543`, `:636`), node targets are not resolved when a monitor is handed to an agent (`server.go:5785`, `monitor_checks.go:112`), and beacon source approval counts only operator checks (`beacon.go:358`). Before S2, one classifier names the owner (operator, path set, beacon reach, definition) and every `ManagedBy == ""` or `!= ""` site goes through it. That lands as a refactor commit with no behaviour change. Definition monitors then behave as operator checks everywhere (matrix rows, paging, visibility, beacon sources) except that editing or deleting one directly is refused with a pointer to its definition (`server.go:5625`, `monitor_update.go:160`). Node targets of a definition resolve their address through the path set planner's port rule and sticky endpoint choice (`latency_probes.go:736-740`), shared as a function, not copied.

**Who may store a selector.** Expansion runs as the system, so a stored selector would let a restricted operator's group target grow to nodes they cannot read; the path set refuses restricted tokens for the same reason (`latency_probes.go:1262`). A group or whole-fleet selector on a definition therefore requires an unrestricted principal; a restricted principal may name explicit nodes it can read. A definition with secret headers must name explicit source nodes, because design 29 D1 keeps secrets out of generated checks and a group source would send them to any node that joins.

**Sync.** Definitions resync where the path set does: on save, on the existing two-minute sweep (`latency_probes.go:88`), and after a beacon approval, plus a call from group edits and node removal so a membership change shows within seconds rather than at the next sweep. One sweep writes every changed definition in one store save under one lock, reusing the sweep's endpoint picks, because the writes, not the comparisons, are the cost. Each sweep is audited the way `monitor.latency.sync` is (`latency_probes.go:959-975`), with the same bounded id lists.

**Budgets and beacon.** The per-source packet budget (`MonitorPacketsPerSecondMax`, two packets a second to one address) is checked on save today and nowhere else (`latency_probes.go:1288`, `server.go:5547`), so a group that grows can push a source over it. The sweep pauses the pairs over budget with that reason, and the dry run shows them. A beacon definition cannot follow a group freely: every new source needs the target's `node.beacon` plan approved again (design 29 D3 as built), so its new pairs read `beacon_source_pending` in the matrix and the preview until that plan is approved.

**Alerts.** Two checks measuring one pair are two alerts; that is deliberate, since they test different things. The incident names its check, and the pair's sheet lists both.

**The path set becomes Fleet mesh.** The existing `LatencyProbeConfig` is listed as the built-in check named Fleet mesh, in the same list as every definition, and keeps its own editor: rebuilding its automatic method, per-source pins, disabled pairs and ICMP fallback (`latency_probes.go:758-800`) inside the definition editor is work with no operator gain until it is migrated. Its stored form and its `mon_lat*` ids do not change, so its history survives. A later slice may migrate it into a `CheckDefinition`; nothing in this design depends on that.

**Single checks stay.** An existing operator check is a definition with one source set and one target. The console lists it the same way. Nothing is migrated on deploy.

**Path identity in URLs.** Fleet mesh paths keep `<source>~<target node>`. Paths of every other check use `<source>~@<monitor id>`, which already resolves, so two checks probing the same pair never collide. The matrix contract keeps `PathCell.Managed` meaning "Fleet mesh" only: the console keys a managed cell with a target node as `<source>~<target>` (lattice-dashboard `pathsModel.ts:564-578`) and the series route resolves that key through path-set prefixes only (`monitor_paths.go:233-242`), so a definition cell marked managed would collide with Fleet mesh. When two checks measure the same pair, the graph draws one edge (D2) and its sheet lists each check.

**The editor.** One "New check" flow, reachable from the Network view header and the Checks list:

```
What        [ TCP ][ ICMP ][ Beacon ][ HTTP ][ TLS ]
From        [ selector: nodes · groups · whole fleet ]          resolves to 3 nodes
To          [ selector ]                                        resolves to 12 nodes
            preview: 36 paths, 2 targets serve nothing TCP can dial,
                     1 pair over the packet budget  (show)
Expect      packets, statuses, headers, cert threshold (by method)
How often   interval, timeout, packet budget
On failure  alert policy, alert after, degraded rule
Name
                                         Still needed: a target   [ Create check ]
```

The preview is computed by the server from the stored selectors (a dry-run endpoint), so it shows exactly what will be measured, including the per-target reasons a pair would read unknown. It replaces "one check per target" and "TCP takes one node".

**One status vocabulary.** Every view uses up, degraded, down, paused and unknown, and unknown always carries its reason as a sentence ("nothing this method can dial on the target", "source cannot run ICMP", "no result yet"). "No path", "not probed" and "nothing heard" are removed. Every count on the page is derived from the one matrix response, so the proof line, the overview and the Network view agree.

## D2. One Network view (Topology absorbs Paths)

**Layers.** Monitoring keeps Overview, Network (today's Topology, renamed), Checks and Incidents. `?view=paths` redirects to `?view=network&as=list` and `?view=topology` to `?view=network`, keeping every other parameter, so old links and bookmarks keep working, `?path=` included.

**One search bar for both modes.** The Paths query grammar moves up to the view: source, target, state, reason, region, country, method, check, latency and loss fields, plus free text. In list mode it filters rows, as today. In graph mode matching edges and their end nodes stay at full strength and the rest fade to the muted tone, with the shown/total count in the bar. Sorting becomes a real control in list mode (worst first by default) instead of a grammar term with no effect.

**Graph mode.**

```
1440
+--------------------------------------------------------------------------------+
| Monitoring   Overview  Network  Checks  Incidents        1h 6h 24h 3d 7d        |
| 31 paths: 19 up · 1 degraded · 2 down · 9 unknown        [ New check ]          |
| [ search: state:down source:node-a ...                           ] 4 of 31     |
| [ Graph | List ]   Sources: node-a, node-b (+)         Show: paths chains beats |
+--------------------------------------------------------------------------------+
|  sources              targets by region                     | path sheet       |
|  ( node-a ) ------- 30 ms ------> ( node-b )       Asia      | node-a to        |
|            \------- 172 ms -----> ( node-c )       Europe    | node-b           |
|            \- - - - unknown - - > ( node-d )       America   | up · 30 ms p50   |
|                                                              | chart, runs      |
+--------------------------------------------------------------------------------+
```

Edges are colored by state tone only (design 29 D13); the label is p50, or the state word when it is not up. Every check to a node target is an edge between real nodes; the pseudo-node boxes for checks are removed. A check to an external address keeps a terminal node labelled with the address, drawn once per address. Edges are focusable and reachable by keyboard in source, then target, order, with the same label as their hover.

**Edge opens the path sheet in place.** Clicking or pressing Enter on an edge sets `?path=` on the Network view and opens today's path sheet over it. Escape or the close button removes `?path=` and returns focus to the edge. The tab title follows the sheet and resets on close. "Edit check" inside the sheet opens the check editor as a second sheet; cancelling returns to the path sheet, not to the list.

**Node opens the node sheet with a monitoring lens.** Opened from the Network view, the node sheet leads with this node's paths, outbound and inbound, worst first, each opening its path sheet. Below that come status, groups, the node's network summary (D4) and the existing node facts. Opened anywhere else, the node sheet keeps its current order.

**List mode is today's Paths table, enriched.** Region-grouped rows, p50, p95, jitter, loss, availability, last run, method and check name, with the sort control and the same row-to-sheet behaviour. Below 768 px it becomes the grouped list it already becomes.

**Mobile.** Below 768 px the view opens in list mode; the graph is one tap away and pans and zooms with standard gestures. Sheets become full-height and close with the system back gesture.

## D3. Networking information architecture

**Names by what they do.**

| Today | Becomes | Why |
|---|---|---|
| Network Policy | Outbound policy | it compiles egress only, into `lattice_policy` with default drop |
| NetGuard Firewall | Inbound firewall (NetGuard) | it compiles ingress only, into `lattice_guard` |
| NetGuard "Groups" | Security groups | they are rule bundles, not node groups |
| WireGuard networks | WireGuard mesh | there is one implicit mesh, no stored networks |
| Groups (fleet) | Node groups | the fleet-wide targeting primitive |

Inbound and outbound pages each say in their header what the other owns ("Inbound is the NetGuard firewall"). The policy form loses its ingress direction for new rules. Existing ingress rules are kept, each with a remove action, and labelled by what is true on the node, not as simply inactive: the policy's own plan never applies them, but `composeNFTIngressPolicy` (`server_nft.go:170-193`) folds them into `lattice_guard` through the legacy firewall route and the DNS plan on a node NetGuard does not manage, so they may be live there. The label says, per node, "applies through the legacy firewall route on this node" or "ignored: NetGuard manages inbound on this node", and points to the firewall.

**Navigation.** The Networking section groups the pages by layer, in this order: Overview (new, D4), Inbound firewall, Outbound policy, WireGuard mesh, then naming services (Self-host DNS, DDNS, Geo-routing) and access (Tunnels, SSH Guard). NetGuard and WireGuard keep their plugin pages, but their nav entries move from Extensions into Networking because their engines are core.

**Node groups stay under Fleet and become the hub.** Groups are used by checks, policy, security-group bindings, mesh membership and agent update batches; folding them into policy would hide them from every other use. Instead the group sheet gets a Used by section listing every check, outbound policy, security-group binding and mesh rule that names the group, each a link. Deleting a group in use is already refused with 409; the refusal names the users.

**Targeting.** Every target field uses the selector (D5):

- **Outbound policy:** the target may be one node, several nodes or a group, and all three are one object. `NetPolicy` is one document per node whose id is the node id (`internal/netpolicy/expand.go:41-48`), and the group plan skips any node with a manual policy (`server_group_policy.go:303-306`), so writing one `NetPolicy` per selected node would be the console fan-out this design rejects for checks: N documents to edit one by one, each blocking every later group policy. Instead `GroupNetPolicy` gains a D5 selector scope, additively, with `scope_group_id` kept as an alias for a one-group selector. Single-node, several-node and group targets then expand and merge by priority the way group policies already do (`expand.go:23-29`). Existing manual policies stay as they are and gain a "convert" action. The remote kind gains group, which the model already supports. The group-pair matrix stays as a view, reachable from the policy page and from a group's Used by.
- **Security groups:** a security group may bind to a node group as well as to single nodes, and the group remote in guard rules is expanded to member addresses instead of being rejected. The domain remote is removed from the guard editor: a name is not a trustworthy source identity. Four rules are fixed up front:
  - A group binding never adopts a node. Approve-time freshness needs a stored per-node binding (`server_netguard.go:1033-1039`) and compile refuses unmanaged nodes, so a member NetGuard has not adopted reads "group binding inactive: node not managed".
  - Derived security groups are added in one place, `store.NetGuardCompileSnapshot`, so every compile path sees them: the operator path, the system path, the beacon closure and the preview (`server_netguard.go:459-510`, `beacon_plan.go:205`). The beacon approve re-render is correct only because the system path includes them.
  - Order is defined: compile applies overrides, then groups in binding order (`internal/netguard/compile.go:123-128`), and one deny rule turns off the fast path, so position changes behaviour. Derived groups come after the node's own groups, in the node group's name order, and the preview shows the resulting order.
  - Planning is batched. NetGuard plans one node at a time today (`server_netguard.go:935-1027`); a group binding change gets a batch plan shaped like `handleGroupPolicyPlan`, whose diff names each node that changes.
- **WireGuard mesh:** membership by selector is the planned W1 store work (design 13); until it exists the mesh page shows that every ready node is a member and why.

**The policy form.** It says, above the rules, that an enabled outbound policy drops every outbound connection the rules do not allow, and names what the fixed allows cover (established, loopback, the control plane, DNS). Ports accept single ports; the model has no range form, so a range is refused with a sentence (D7) until the model gains one. The form and the matrix dialog share one component and one title pattern.

## D4. The node's effective network

A Network section on the node page, and a summary of it in the node sheet, answers "what applies to this node":

```
Inbound    NetGuard: enforced · zones: public, wireguard · security groups: ssh, web (via node group web)
           extra ports: DNS 53 (self-host DNS), beacon 47000 udp (from 3 sources)
Outbound   policy "egress-web" (group policy, priority 10) · default drop · 6 allow rules
Access     SSH Guard: knock required
Mesh       WireGuard 10.66.0.12 · 31 peers
Groups     web, asia
           [ Open in firewall ]  [ Open policy ]  [ Show applied rules ]
```

The server serves it from one read endpoint that composes the binding, the derived bindings from node groups (once S4 lands), the beacon and DNS contributions, every outbound policy that reaches the node in priority order, including orphans (group-derived policies still in force after the node left the scope, `server_group_policy.go:368-376`), SSH Guard state and the mesh facts, with the applied table digests and drift state the console already reads.

The endpoint uses only the side-effect-free layer, because the plan handlers write state (`server_group_policy.go:345`, `server_netguard.go:1002`): `netGuardPreview` (`server_netguard.go:313-330`), `ExpandGroupPolicies`, `NormalizePolicy`, `CompileEgressPlan` and `currentGroupDerivedPolicyPlanSHA`. Scope is refused, not filtered, as the existing scoped resolvers do. "Show rules" has two labelled columns per table: what would compile now, and what was last applied, with "re-plan pending" when they differ. It names the last writer of `lattice_guard` (legacy firewall route, self-host DNS, NetGuard or beacon) from the last applied approval, so a table another composer rebuilt is visible.

## D5. The target selector

One component and one stored shape for every target field:

```
{ "nodes": ["node-a"], "groups": ["asia"], "all": false, "exclude": ["node-b"] }
```

Tags are not a separate criterion. A node group's own selector already matches tags, ANDs across criteria and ORs within one (`internal/groups/resolve.go:92-121`); a second tag rule beside it would give one word two meanings, which is the confusion this design removes. Selecting by tag means making a group whose selector is that tag.

The control is the Path set source picker the live walk singled out to keep (searchable, multi-select, grouped by region), with chips for nodes and groups, a whole-fleet toggle, and a live line under it: "resolves to 12 nodes" with the list one click away. Resolution uses the group resolver the server already has; the SDK doc for group selectors is corrected to say that set criteria combine with AND, which is what the server does.

## D6. Nodes list

The list layout gains a Network column: receive and send rates, with the cumulative counters in the tooltip, sortable, aligned right, through the same metric-cell helper the CPU column uses, so offline and never-reported nodes read the same way. `sort:rx` and `sort:tx` mark the column. The data already arrives with the five-second list poll. Card and list both mark the metrics of an offline node as stale (the age, and the values in the muted tone) instead of showing them as live. A monthly per-node transfer total does not exist; showing one needs a stored interface total, which is out of scope here.

## D7. Defects fixed first

These ship before any redesign slice, each with a test that fails before the fix:

- A policy port token that is not a single port is an error, never an empty list. The model stores single ports only, so a range is refused with a sentence.
- On a node with a managed NetGuard binding (the test `beacon_plan.go:176-177` uses; an observe-only binding does not count, because NetGuard refuses unmanaged nodes), the legacy `/api/network/nft/plan` and `apply-ruleset` routes are refused at plan time and at approve time. Approve re-checks only `nftpolicy` and NetGuard approvals today (`server.go:8902-8911`), so a pending or auto-approved legacy approval would still overwrite `lattice_guard`. Once S4 lands, coverage through a node-group binding counts too.
- On the same nodes the self-host DNS plan renders and applies CoreDNS only and never writes `guard.nft`; its apply script writes that file itself and never updates the binding (`internal/selfdns/selfdns.go:372-379`), so composing it the beacon way would need a binding-version check, an approve re-render and a completion hook, and would still leave NetGuard reporting drift. Instead it lints the node's current NetGuard compile for its listener ports and blocks with "open udp/53 and tcp/53 in a security group on this node first". NetGuard stays the only writer of `lattice_guard` on managed nodes, at the cost of two plans for ports that rarely change. The DNS approval is refused at approve time on the same terms as the legacy route.
- `validateDeployment` refuses `exposure: public` with a `forward` zone, on save and on plan. A stored deployment that already has that shape stays readable and carries a visible flag. Naming allowed client networks, rendered as a CoreDNS ACL, is a new SDK field and belongs to D8.
- The guard editor stops offering remotes the compiler rejects, until D3's group expansion ships.
- The policy page's claim that Lattice writes no other nftables when the NetGuard plugin is absent is corrected.
- The group selector doc matches the server.

## D8. DNS in Lattice

The operator's DNS plan (kept in their private notes) is an encrypted forwarding resolver for their own devices: one existing dnsproxy host plus a second in another region on a different network, DoH and DoT, client-side split, with GeoDNS and anycast deferred. Lattice's self-host DNS renders plain CoreDNS only and can merely observe a dnsproxy host. The Lattice parts, in order:

1. A DNS check method: query a name through a DoH, DoT or plain endpoint from chosen sources, decode the answer, compare it with an expected set, and record latency. This is the seven-day acceptance probe the plan asks for, run from several fleet vantage points at once, and it uses D1 as is.
2. The existing dnsproxy hosts recorded as external deployments, so their listeners, guard ports and certificate expiry are visible and monitored. With them, a deployment may name allowed client networks, rendered as a CoreDNS ACL, which is what lets a public forwarding deployment exist without being an open resolver.
3. A dnsproxy engine for self-host DNS (pinned binary, rendered config, DoH and DoT listeners, ports through the NetGuard compile, certificates by DNS-01 against the operator's Cloudflare zone), when the East Asia node is chosen. Until then, GeoRouting stays marked experimental, since the plan defers authoritative GeoDNS.

## Alternatives

**Merge node groups into Network Policy.** Rejected. Groups are already used outside networking and will be used by checks and update batches; a policy-owned group would need a second copy for every other use. Used by plus one selector gives the same discoverability without the trap.

**Several named path sets instead of check definitions.** Rejected. The path set's ids are keyed by target and method, its series join assumes one set, and its URL keys would collide when two sets probe the same pair. A definition with hashed `mon_chk_` ids and monitor-keyed paths reuses the same sync machinery without those collisions.

**Console fan-out: one POST per target.** Rejected as the model. It is not atomic, cannot follow group membership, and leaves N unrelated checks to edit one by one. It is acceptable only as a stopgap.

**Keep Paths and Topology as separate tabs with cross-links.** Rejected. They draw the same response; two views of one thing with different tools is the confusion the operator reported.

## Slices

| Slice | Contents | Repos | Retires approvals |
|---|---|---|---|
| S0 | D7 defects (port tokens, legacy and DNS refusal at plan and approve on managed nodes, DNS port lint, public forward refused, guard editor remotes, docs); D6 Nodes list column and stale metrics | server, dashboard, netguard plugin UI, sdk docs | no |
| S1 | D2 Network view: merge, search in both modes, in-place path sheet, node sheet lens, focusable edges, one vocabulary, one count source; checks to nodes drawn as edges | dashboard | no |
| S2a | D1 groundwork: one owner classifier routed through every `ManagedBy` site (refactor, no behaviour change); `managedMonitorEqual` compares every field | server | no |
| S2b | D1 check definitions: SDK type, store, expansion through `SyncManagedMonitors` with hashed ids and pause on leave, selector scope rule, batched sync, sweep-time packet budget, beacon pending, dry-run preview, CRUD, forget paused targets, audit; editor with selectors; Fleet mesh listed as a check | sdk, server, dashboard | no |
| S3a | D3 and D5 outbound and naming: `GroupNetPolicy` selector scope, policy targets and group remote, convert for manual policies, names, nav, selector component, policy form warnings, group Used by | sdk, server, dashboard, both plugin UIs | no |
| S3b | D4 node network read endpoint and section | server, dashboard | no |
| S4 | D3 security-group bindings to node groups (no adoption, derived in the compile snapshot, defined order, batch plan), group remote expansion, D7 coverage through group bindings, D4 shows derived bindings | server, netguard plugin | NetGuard applies once, through a plan |
| S5 | D8 DNS check method, external deployments, allowed client networks | sdk, server, node-agent, dashboard | no |

S0 and S1 need no model change and ship first. S2a ships before S2b and can ship any time. S2b and S3a are independent of each other. S3b follows S3a so it can list selector-scoped policies. S4 needs only node group ids, so it can follow S0; it must extend D4 and the D7 refusal in the same slice. S5 depends on S2b.

## As built

S0, S1 and S2a shipped first, S2b and S3a together a release later; the program log at the workspace root names the releases. The NetGuard and WireGuard page names from D3 shipped as signed plugin releases. Where the build differs from the sections above:

- S2b and S3a were built in parallel and share one selector: the SDK `TargetSelector`, the server's `groups.ResolveTargets`, and the console's `SelectorPicker`, each a single copy after the two slices merged.
- The picker never lets a node be both named and excluded, while the server lets an exclusion win. Saving a check definition therefore stores its selectors in a canonical form that resolves to the same nodes, so editing a definition made through the API in the console cannot start measuring a node its exclusion kept out.
- The scope rule in D5 reverses an earlier server decision: a token confined to some nodes could define a group policy for a group it fully reached at write time. A group or fleet target, a group remote, and editing or deleting a policy that has either now need an unrestricted principal, because a group can grow with no write to carry a reach check. Stored policies keep working and are not migrated; the console says why their edit controls are off.
- A group delete is refused while an outbound policy or a check definition names it, through one refusal in both state stores. The refusal and the group's Used by name only what the caller may read and count the rest. Used by lists policies and checks; security-group bindings (S4) and mesh membership rules arrive when those slices store group references.
- A group deleted under a definition built before the refusal resolves to no nodes: its monitors pause, and the sweep continues.
- Left on purpose: a refused check save does not yet point at the field at fault; a version conflict on save closes the editor and reloads, as the single-check editor does; a group row in the policy matrix does not show its exclusions; Used by is not polled while a sheet is open.

## Tests

- S0: a policy with `8000-8010` fails with a sentence and never stores an empty port list; a legacy nft plan on a node with a managed binding answers 409, and so does approving a legacy or DNS approval created before the binding; an observe-only node is not refused; a DNS plan on a managed node renders no `guard.nft` and is blocked while its listener ports are closed in the NetGuard compile; a public forward deployment is refused on save and plan, and a stored one still loads with its flag; the Nodes list sorts by `rx`.
- S1: `?view=paths&path=a~b` lands on the Network view with that sheet open; Escape returns focus to the edge; the graph and the list show the same count for the same query; a check to a node renders one edge between two real nodes.
- S2a: the existing suites pass unchanged; an edit that changes only a path set monitor's alert policy writes it.
- S2b: a definition with two sources and three targets yields three monitors with six paths, shown in the matrix and paging like operator checks; adding a node to a target group adds a monitor within one sync; a node leaving the group pauses its monitor and keeps its runs; removing the second of three external targets leaves the third's id and history untouched; a method change yields new ids; editing a definition monitor directly is refused; a restricted principal cannot save a group selector; secret headers with a group source are refused; a group that grows past the packet budget pauses the excess pairs with that reason; the dry run equals what the save produces; Fleet mesh ids and history are unchanged across the deploy.
- S3a: a group-target policy and a three-node policy are each one `GroupNetPolicy` and plan every member; a stored `scope_group_id` policy reads as a one-group selector; converting a manual policy keeps its rules.
- S3b: the node network endpoint lists every owner of every table, every contributing policy in priority order and orphans, writes nothing, and refuses a node outside the caller's scope.
- S4: a security group bound to a node group applies to a managed node that joins it after the batch plan; an unmanaged member reads inactive and is not adopted; the beacon approve re-render includes derived groups; the legacy route is refused on a node covered only through a group binding.

## Risks

- Paused targets accumulate when group membership churns. They are cheap (no runs, no agent work), the definition shows how many it holds, and "forget paused targets" removes them with the operator's confirmation.
- The DNS lint makes a managed node need two plans (NetGuard ports, then DNS) where one used to do. Listener ports rarely change, and the lint names the exact ports to open.
- S4 changes what NetGuard compiles for nodes in bound groups; it rides the normal plan and approval, and the batch plan diff names each node that changes.
- Renaming pages moves the operator's habits. Old routes redirect, and the first visit after the rename shows the old name next to the new one.

## Review

An architecture review on 2026-10-24 approved D2, D6 and D8 and changed the rest. It found that the server treats any managed monitor as path set or beacon in about ten places, that the managed sync ignores edits to several shared fields, that the path set pauses rather than deletes targets that leave, that index-based ids would mix series, that stored selectors bypass the scope check, that the D7 refusals missed the approval path and observe-only nodes, that ingress rules can still be live through the legacy composers, that a beacon-style DNS companion was a feature rather than a fix, and that per-node policy copies would collide with group policies. Each finding is folded into the section it changes.
