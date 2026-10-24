# Design 32: network and monitoring console, one model per concept

Status: proposed 2026-10-24. Not built.
Date: 2026-10-24.
Reference: lattice-server `integration` at bd335aa, lattice-dashboard `integration` at da8eb50, lattice-sdk `integration` at fbe4441, lattice-plugin-netguard at 1b37d1b, lattice-plugin-wireguard at 408e399. Production versions live only in `PROGRAM.md`.

## Summary

The operator reviewed the network and monitoring areas on 2026-10-24 and found them hard to read and hard to use. A code survey of both areas and a walk through the live console confirmed the complaints and found defects underneath them. The causes are structural, not cosmetic:

- Monitoring has one measurement model shown under three names (paths, probes, checks), counted four different ways, and created from the wrong tab. A check holds exactly one target in the data model, so "one source probing many targets" needs one check per target, and the only many-to-many construct, the path set, is a single fleet-wide setting that reads like a second concept.
- Topology and Paths draw the same matrix with different tools. Topology has the graph and no search; Paths has the search and no graph. Clicking an edge in Topology jumps to the Paths tab and Escape does not return. Checks to a node are drawn as pseudo-nodes, so one target appears twice in one picture.
- Networking spreads four interlocking concepts over two sidebar sections with no links between them. Node groups, Network Policy (outbound only, one document per node), NetGuard (inbound only: zones, security groups, per-node bindings) and the WireGuard mesh each change the same nodes, and no page shows what applies to a node. "Group" means two different objects. "Network Policy" reads like the firewall but is egress only.
- Three defects are dangerous enough to fix before any redesign: a port range in a policy rule silently becomes "all ports"; the legacy firewall route and the self-host DNS plan rebuild the inbound table without NetGuard's security groups; a public DNS deployment with a forward zone is an open recursive resolver and nothing refuses it.

The design makes one object per concept and one control for choosing targets:

1. **A check is the one thing you create; a path is what you see.** A check gets a source set and a target set (nodes, groups, tags or the whole fleet). The server keeps one measured monitor per (target, method) the way it already does for the path set, so history, ids and design 29's identity rules stay as they are. The path set becomes the built-in check named Fleet mesh, listed with the others.
2. **Topology absorbs Paths.** One view, graph and list modes, one search bar that filters both, the path sheet opening in place on an edge, and a node sheet that leads with the node's paths.
3. **Networking is named by direction and anchored on the node.** Inbound firewall (NetGuard), outbound policy (Network Policy), WireGuard mesh, and a per-node Network section that shows the effective result of all of them plus SSH Guard. Node groups stay a fleet-wide targeting primitive with a Used by section, not a feature folded into policy.
4. **One target selector** (nodes, groups, tags, all, with a live preview of the resolved nodes) is used by check sources and targets, policy targets and remotes, security-group bindings and mesh membership.

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

**Source and target sets.** Both are selectors (D5): explicit nodes, groups, tags, or the whole fleet, plus excluded nodes. A selector is stored, not resolved, so a node that joins a group joins the check. For a node-to-node method (tcp, icmp, beacon) the target set resolves to nodes. For an external method (http, tls, or tcp and icmp to an address) the target set is a list of addresses or URLs; each entry becomes its own target.

**Server model.** A new stored object, `CheckDefinition`, holds the selectors and the shared fields. The server expands it into managed monitors through the same `SyncManagedMonitors` the path set uses, with `ManagedBy: "check:<definition id>"` and ids `mon_chk_<definition>_<target>` for node targets or `mon_chk_<definition>_<n>` for external ones. Every expanded monitor keeps its own id and history, so design 29 D1 holds: a target leaving the set deletes that monitor and its history, as the path set does today; a method change mints new monitors. Edits to shared fields (sources, interval, timeout, expectations, alert, degraded rule) rewrite the expanded monitors in one store write. Expansion runs on save and whenever group membership, node tags or the node list change, using the same triggers that resync the path set.

**The path set becomes Fleet mesh.** The existing `LatencyProbeConfig` is shown as the built-in check named Fleet mesh, in the same list and opened by the same editor, with its region-based target rule kept as a target-set option ("by region"). Its stored form and its `mon_lat*` ids do not change, so its history survives. A later slice may migrate it into a `CheckDefinition`; nothing in this design depends on that.

**Single checks stay.** An existing operator check is a definition with one source set and one target. The console lists it the same way. Nothing is migrated on deploy.

**Path identity in URLs.** Fleet mesh paths keep `<source>~<target node>`. Paths of every other check use `<source>~@<monitor id>`, which already resolves, so two checks probing the same pair never collide. When two checks measure the same pair, the graph draws one edge (D2) and its sheet lists each check.

**The editor.** One "New check" flow, reachable from the Network view header and the Checks list:

```
What        [ TCP ][ ICMP ][ Beacon ][ HTTP ][ TLS ]
From        [ selector: nodes · groups · tags · whole fleet ]   resolves to 3 nodes
To          [ selector ]                                        resolves to 12 nodes
            preview: 36 paths, 2 targets serve nothing TCP can dial  (show)
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
| [ search: state:down source:cd-hs-sh ...                         ] 4 of 31     |
| [ Graph | List ]   Sources: cd-hs-sh, gomami-hkg (+)   Show: paths chains beats |
+--------------------------------------------------------------------------------+
|  sources              targets by region                     | path sheet       |
|  ( cd-hs-sh ) ----- 30 ms ------> ( gomami-hkg )   Asia      | cd-hs-sh to      |
|              \----- 172 ms -----> ( fra-2 )        Europe    | gomami-hkg       |
|              \- - - unknown - - > ( xiaoxin )      America   | up · 30 ms p50   |
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

Inbound and outbound pages each say in their header what the other owns ("Inbound is the NetGuard firewall"). The policy form loses its ingress direction, since no plan can apply it; existing ingress rules are listed as inactive with a one-line explanation and a link to the firewall.

**Navigation.** The Networking section groups the pages by layer, in this order: Overview (new, D4), Inbound firewall, Outbound policy, WireGuard mesh, then naming services (Self-host DNS, DDNS, Geo-routing) and access (Tunnels, SSH Guard). NetGuard and WireGuard keep their plugin pages, but their nav entries move from Extensions into Networking because their engines are core.

**Node groups stay under Fleet and become the hub.** Groups are used by checks, policy, security-group bindings, mesh membership and agent update batches; folding them into policy would hide them from every other use. Instead the group sheet gets a Used by section listing every check, outbound policy, security-group binding and mesh rule that names the group, each a link. Deleting a group in use is already refused with 409; the refusal names the users.

**Targeting.** Every target field uses the selector (D5):

- **Outbound policy:** the target may be one node, several nodes or a group. A group target writes the existing `GroupNetPolicy`; several nodes write one `NetPolicy` per node in one plan batch. The remote kind gains group, which the model already supports. The group-pair matrix stays as a view, reachable from the policy page and from a group's Used by.
- **Security groups:** a security group may bind to a node group as well as to single nodes. The server expands group bindings into per-node bindings at compile time, as `GroupNetPolicy` already does for policy, and the group remote in guard rules is expanded to member addresses instead of being rejected. The domain remote is removed from the guard editor: a name is not a trustworthy source identity.
- **WireGuard mesh:** membership by selector is the planned W1 store work (design 13); until it exists the mesh page shows that every ready node is a member and why.

**The policy form.** It says, above the rules, that an enabled outbound policy drops every outbound connection the rules do not allow, and names what the fixed allows cover (established, loopback, the control plane, DNS). Ports accept single ports and ranges; a range is stored as the model's list only if the model gains ranges, otherwise the form rejects it with a sentence. The form and the matrix dialog share one component and one title pattern.

## D4. The node's effective network

A Network section on the node page, and a summary of it in the node sheet, answers "what applies to this node":

```
Inbound    NetGuard: enforced · zones: public, wireguard · security groups: ssh, web (via node group web)
           extra ports: DNS 53 (self-host DNS), beacon 47000 udp (from 3 sources)
Outbound   policy "metix-egress" (group policy) · default drop · 6 allow rules
Access     SSH Guard: knock required
Mesh       WireGuard 10.66.0.12 · 31 peers
Groups     web, asia, metix
           [ Open in firewall ]  [ Open policy ]  [ Show applied rules ]
```

The server serves it from one read endpoint that composes the binding, the derived bindings from node groups, the beacon and DNS contributions, the node's policy or group policy, SSH Guard state and the mesh facts, with the applied table digests and drift state the console already reads. "Show applied rules" shows the rendered nftables for the three tables side by side, from the same compilers the plans use, labelled by owner.

## D5. The target selector

One component and one stored shape for every target field:

```
{ "nodes": ["gomami-hkg"], "groups": ["asia"], "tags": ["exit"], "all": false, "exclude": ["xiaoxin"] }
```

The control is the Path set source picker the live walk singled out to keep (searchable, multi-select, grouped by region), with tabs or chips for nodes, groups and tags, a whole-fleet toggle, and a live line under it: "resolves to 12 nodes" with the list one click away. Resolution uses the group resolver the server already has; the SDK doc for group selectors is corrected to say that set criteria combine with AND, which is what the server does.

## D6. Nodes list

The list layout gains a Network column: receive and send rates, with the cumulative counters in the tooltip, sortable, aligned right, through the same metric-cell helper the CPU column uses, so offline and never-reported nodes read the same way. `sort:rx` and `sort:tx` mark the column. The data already arrives with the five-second list poll. Card and list both mark the metrics of an offline node as stale (the age, and the values in the muted tone) instead of showing them as live. A monthly per-node transfer total does not exist; showing one needs a stored interface total, which is out of scope here.

## D7. Defects fixed first

These ship before any redesign slice, each with a test that fails before the fix:

- A policy port token that is not a port or a valid range is an error, never an empty list.
- The legacy `/api/network/nft/plan` refuses a node that has a NetGuard binding, and the self-host DNS plan contributes its ports to the NetGuard compile on such a node instead of rebuilding `lattice_guard` from the legacy inputs, the way the beacon companion already does.
- `validateDeployment` refuses `exposure: public` with a `forward` zone unless the deployment names allowed client networks, which the renderer emits as an ACL.
- The guard editor stops offering remotes the compiler rejects, until D3's group expansion ships.
- The policy page's claim that Lattice writes no other nftables when the NetGuard plugin is absent is corrected.
- The group selector doc matches the server.

## D8. DNS in Lattice

The operator's DNS plan (vault, `C006_RoobLi_selfhost-dns`) is an encrypted forwarding resolver for their own devices: dnsproxy in Los Angeles plus one East Asia node, DoH and DoT, client-side split, with GeoDNS and anycast deferred. Lattice's self-host DNS renders plain CoreDNS only and can merely observe a dnsproxy host. The Lattice parts, in order:

1. A DNS check method: query a name through a DoH, DoT or plain endpoint from chosen sources, decode the answer, compare it with an expected set, and record latency. This is the seven-day acceptance probe the plan asks for, run from fleet vantage points including mainland ones, and it uses D1 as is.
2. The existing dnsproxy hosts recorded as external deployments, so their listeners, guard ports and certificate expiry are visible and monitored.
3. A dnsproxy engine for self-host DNS (pinned binary, rendered config, DoH and DoT listeners, ports through the NetGuard compile, certificates by DNS-01 against the operator's Cloudflare zone), when the East Asia node is chosen. Until then, GeoRouting stays marked experimental, since the plan defers authoritative GeoDNS.

## Alternatives

**Merge node groups into Network Policy.** Rejected. Groups are already used outside networking and will be used by checks and update batches; a policy-owned group would need a second copy for every other use. Used by plus one selector gives the same discoverability without the trap.

**Several named path sets instead of check definitions.** Rejected. The path set's ids are keyed by target and method, its series join assumes one set, and its URL keys would collide when two sets probe the same pair. A definition with `mon_chk_` ids and monitor-keyed paths reuses the same sync machinery without those collisions.

**Console fan-out: one POST per target.** Rejected as the model. It is not atomic, cannot follow group membership, and leaves N unrelated checks to edit one by one. It is acceptable only as a stopgap.

**Keep Paths and Topology as separate tabs with cross-links.** Rejected. They draw the same response; two views of one thing with different tools is the confusion the operator reported.

## Slices

| Slice | Contents | Repos | Retires approvals |
|---|---|---|---|
| S0 | D7 defects; D6 Nodes list column and stale metrics | server, dashboard | no |
| S1 | D2 Network view: merge, search in both modes, in-place path sheet, node sheet lens, focusable edges, one vocabulary, one count source; checks to nodes drawn as edges | dashboard | no |
| S2 | D1 check definitions: SDK type, store, expansion through `SyncManagedMonitors`, dry-run preview, CRUD; editor with selectors; Fleet mesh listed as a check | sdk, server, dashboard | no |
| S3 | D3 and D5 networking: names, nav, selector component, policy targets and group remote, policy form warnings, group Used by; D4 node network read endpoint and section | sdk, server, dashboard, both plugin UIs | no |
| S4 | D3 security-group bindings to node groups and group remote expansion in NetGuard | server, netguard plugin | NetGuard applies once, through a plan |
| S5 | D8 DNS check method and external deployments | sdk, server, node-agent, dashboard | no |

S0 and S1 need no model change and ship first. S2 and S3 are independent of each other. S4 depends on S3's selector. S5 depends on S2.

## Tests

- S0: a policy with `8000-8010` either stores the range or fails with a sentence, never an empty port list; a legacy nft plan on a node with a binding answers 409; a DNS plan on such a node renders the binding's security groups plus the DNS ports; a public forward deployment without allowed networks is refused; the Nodes list sorts by `rx`.
- S1: `?view=paths&path=a~b` lands on the Network view with that sheet open; Escape returns focus to the edge; the graph and the list show the same count for the same query; a check to a node renders one edge between two real nodes.
- S2: a definition with two sources and three targets yields three monitors with six paths; adding a node to a target group adds a monitor on the next sync; removing a target deletes only its monitor; the dry run equals what the save produces; Fleet mesh ids and history are unchanged across the deploy.
- S3: a group-target policy writes one `GroupNetPolicy` and plans every member; a security group bound to a node group applies to a node that joins it after the plan is recomputed; the node network endpoint lists every owner of every table.

## Risks

- Expansion on membership change can delete history when a node leaves a group. That is the path set's behaviour today and is what the operator expects from "the group is the target"; the editor states it next to the target field.
- S4 changes what NetGuard compiles for nodes in bound groups; it rides the normal plan and approval, and the plan diff names each node that changes.
- Renaming pages moves the operator's habits. Old routes redirect, and the first visit after the rename shows the old name next to the new one.
