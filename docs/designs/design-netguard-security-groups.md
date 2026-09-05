# NetGuard security groups: per-node rules, discovery, and source restrictions

Status: design. Read-only lane, no code in this change.
Date: 2026-09-05.
Reference: lattice-server internal/netguard and internal/network as read here, lattice-sdk model/model.go, lattice-plugin-netguard 0.1.0-alpha.15, chassis spec docs/design-plugin-chassis.md section 6.2.

## 1. What the operator asked for, and what already exists

The request is a cloud-provider security group per node: NetGuard should recognise the ports sing-box and frp are listening on and offer them as configuration, one click brings the discovered set in as editable rules, and each rule can restrict its source to specific addresses instead of the whole internet. Fleet groups and the canary rollout stay as they are.

Most of the model this needs is already built. `model.GuardRule` (lattice-sdk/model/model.go:695) is an ordered rule with action, direction, protocol, port ranges, a remote and a disabled flag. `model.NodeGuardBinding` (model.go:726) already carries `Overrides []GuardRule` alongside `GroupIDs`, and the compiler already evaluates overrides before groups (internal/netguard/compile.go:85). A CIDR remote already compiles (compile.go:221) and the renderer already splits a source list into `ip saddr` and `ip6 saddr` lines (internal/network/nft.go:311). Listeners with owning process names already arrive on every reality snapshot from `ss -tulpnH` (lattice-node-agent/internal/guardreality/collect.go:138), and sing-box inbounds already arrive as `model.SingBoxInventory` (model.go:1140).

So this is not a new subsystem. It is four things: a source list instead of a single CIDR, an origin marker so discovery can diff rather than duplicate, a proposal builder that turns observed listeners into draft rules, and two correctness fixes in the compiler and the lint that per-node deny rules make reachable. The rest is UI.

The two fixes are not optional and they are the reason this document is longer than the feature. Section 9 states them as the strongest case against shipping the feature as asked.

## 2. The model

### 2.1 There is no new object

A node's security group is `NodeGuardBinding.Overrides`. It is already an ordered `[]GuardRule`, already persisted with optimistic concurrency through `Version` (model.go:732), already validated on write by compiling it in isolation (internal/server/server_netguard.go:726 calling `validateGuardRules` at :555), and already compiled ahead of attached groups. Adding a parallel `NodeSecurityGroup` type would duplicate every one of those behaviours for no gain. The UI calls the list "node rules"; the wire keeps `overrides`.

The composition, which the compiler implements today at compile.go:69 through :98 and which the UI must print rather than leave the operator to infer, is four layers evaluated in this order:

1. Trusted zones from `Binding.ZoneIDs`, each an unconditional accept for that zone's interfaces and CIDRs (compile.go:69-82, `trustedZoneRules` at :293). The public zone is refused here (compile.go:74), so trusting cannot silently mean trusting the internet.
2. Node rules, `Binding.Overrides`, in list order.
3. Fleet groups, in `Binding.GroupIDs` order, each group's rules in its own list order.
4. The scaffold's broad allows.

First match wins, because the rendered chain is a linear nftables input chain. Above all four sits a fixed scaffold the operator cannot edit: `ct state established,related accept`, `iif lo accept`, and the two ICMP control accepts (nft.go:99-105). Below all four sits `counter drop` under a `policy drop` chain (nft.go:98, :123). The default policy is deny for every inbound packet that no rule accepted, and that is not configurable.

### 2.2 Fields to add

Three additions to the SDK, all additive, all decoding as absent on an older agent or an older stored record.

`NetEndpoint` gains a source list. Today `CIDR string` (model.go:536) holds one prefix and `ruleSource` returns a one-element slice (compile.go:224), while the renderer's `NFTInputRule.SourceCIDRs` has always been a slice and already sorts, deduplicates and family-splits it (nft.go:202, :311). The list is a model gap, not a renderer gap.

```go
// NetEndpoint
CIDR  string   `json:"cidr,omitempty"`   // unchanged; one prefix or a bare address
CIDRs []string `json:"cidrs,omitempty"`  // additional sources, unioned with CIDR
```

`ruleSource` unions `CIDR` and `CIDRs` and hands the result to `SourceCIDRs`. Keeping the singular field means the 24 converted baselines and every stored group decode unchanged, and `normalizeSourceCIDR` (nft.go:234) already accepts both a bare address and a prefix, so "a single IP" needs no new kind.

`GuardRule` gains an origin.

```go
// GuardRuleOrigin records where a rule came from, so a later re-discovery can
// diff against what it proposed last time instead of proposing it again.
type GuardRuleOrigin struct {
    // Kind is manual | discovered | imported.
    Kind string `json:"kind"`
    // Service is the discovered service family: singbox | frp | nginx | listener.
    Service string `json:"service,omitempty"`
    // Ref is the stable identity within that service: a sing-box inbound tag,
    // a process name, or the port for a bare listener. It is the diff key.
    Ref string `json:"ref,omitempty"`
    // DiscoveredAt is when the proposal that produced this rule was built.
    DiscoveredAt time.Time `json:"discovered_at,omitempty"`
}

// GuardRule
Origin *GuardRuleOrigin `json:"origin,omitempty"`
```

A nil origin reads as manual, which is what every rule stored today is. The compiler ignores the field entirely; it exists for the diff in section 3 and for the UI's origin column.

There is deliberately no `enabled` field. `GuardRule.Disabled` already exists (model.go:704) and the compiler already skips disabled rules (compile.go:92). The UI renders a toggle whose on state means `disabled: false`; adding a second inverted flag would be two sources of truth for one bit.

There is deliberately no `tcp+udp` protocol value. The compiler's protocol switch (compile.go:124) and the renderer's (nft.go:187) both accept tcp, udp and any, where any cannot carry ports (compile.go:143). Adding a fourth constant means touching both and every consumer that switches on protocol. Instead the add-rule form offers "TCP and UDP" and the authoring layer expands it at write time into two rules that share an `Origin.Ref`, adjacent in the list. The operator sees one row with both protocols on it; the wire and the compiler see what they already understand. The cost is that deleting one half leaves the other, which the UI prevents by treating a shared-ref pair as one row.

### 2.3 What "managed" means, unchanged

`Binding.Managed` is the switch between observing and enforcing. `Compile` refuses an unmanaged binding outright with `ErrNodeUnmanaged` (compile.go:56), so no plan, no approval and no ruleset can exist for an observe-only node. Turning management off touches nothing on the node: the applied table stays until a new plan replaces it, which is exactly what the delete-binding handler's comment states (server_netguard.go:747-754). Node rules can be authored, saved and previewed on an unmanaged binding; they simply do not compile into anything until the operator flips managed and plans.

This matters for the rollout. All 24 existing bindings are observe-only, so the whole authoring surface in this design is reachable and reviewable on the live fleet before a single packet is affected.

### 2.4 Precedence has a bug, and the fix is part of this design

The layer order in 2.1 is what the compiler intends. It is not what it renders. `fastPathBucket` (compile.go:174) diverts any allow rule whose remote is the public or wireguard builtin zone into `plan.PublicTCP`, `PublicUDP`, `WireGuardTCP` or `WireGuardUDP`, and `GenerateNFTPlan` emits those four lists *after* every `InputRule` (nft.go:106-122). The fast path exists for a good reason, stated at compile.go:147: it is what makes a converted legacy baseline render byte-identically to the ruleset it replaced.

But it inverts precedence as soon as denies exist. A node rule "allow tcp/8080 from public" takes the fast path and renders last. A fleet group rule "deny tcp/8080 from any" is not an allow, so it stays an `InputRule` and renders first. The node rule was supposed to win and the fleet rule wins instead. Today this is invisible because nothing in production authors denies. This design is precisely the feature that makes operators author them.

The fix is one condition, and it keeps the property the fast path was built for. `Compile` walks the effective ordered list once before lowering; if it contains no enabled deny, the fast path stays on and byte-parity holds. If it contains any enabled deny, the fast path is off for that node and every rule lowers to a typed `InputRule`, so the rendered order is exactly the authored order. All 24 legacy baselines are allow-only (`LegacyBaseline` emits only `NetRuleAllow`, convert.go:86-95), so adoption parity is untouched. A node that has never had a deny renders the same bytes before and after this change, which the existing parity test can assert.

## 3. Discovery

### 3.1 Sources, in the order they are trusted

The proposal is built on the server from evidence the fleet already sends. Nothing new is collected in this design, and that is a deliberate choice argued below.

The primary source is the reality snapshot's listeners. `ss -tulpnH` is parsed at guardreality/collect.go:212, yielding protocol, port, bind address and the owning process as `name(pid)`. The captured production snapshot in the test fixture at internal/netguard/lint_production_snapshot_test.go:23-38 shows what this actually looks like on this fleet: `frps(612)` on tcp/7000, tcp/7443 and tcp/7500, `realm(620)` on tcp/3433, `dnsproxy(610)` on tcp/53 and tcp/2053, two sshd instances. So frp is already discoverable by process name, with its real bound ports, on every node whose agent runs as root.

The second source is `model.SingBoxInventory` (model.go:1140), which the server already holds per node in `s.singboxInv` (internal/server/server.go:381) and which each `SingBoxNode` entry annotates with `Protocol`, `Port` and `ListenHost` (model.go:1065-1106). This is what turns a bare port number into a typed inbound. The observed fleet-wide inbound ranges captured for this design are small and contiguous: 31001-31012 on six nodes, 41001-41012 on two, 17891-17894 on one, and a long tail of one and two port entries. `PortRanges` (convert.go:27) already compresses a port list into exactly those inclusive ranges, so a bank of twelve inbounds becomes one reviewable rule, not twelve.

Protocol comes from the inbound type, not from guessing: vless and trojan are TCP, hysteria2 and tuic are UDP, shadowsocks is both and expands to the two-rule pair from 2.2. Where the inventory and the listeners disagree about whether a port is bound, the listener wins and the proposal says so, because `SingBoxNode.PortBound` is explicitly a tri-state for this reason (model.go:1104).

nginx and anything else appears through the listener source only, as `origin.service = "listener"` with the process name as the ref.

### 3.2 Why there is no frps.toml reader and no `nginx -T` in this design

The brief names frps `bindPort` from frps.toml and nginx listens from `nginx -T` as sources. Neither exists anywhere in the tree today: a grep for frps, frpc or nginx across the Go sources finds them only in test fixtures and unrelated handlers. Adding them means a new privileged agent collector, a new SDK type, a new agent capability to gate on, and a rollout to 33 nodes, to learn something `ss` already reports for both services with the port they are actually bound to.

The honest gap is real and worth stating rather than hiding. Reading config files would find a service that is configured but not currently running, and would not need root to attribute a port to a process. `ss -tulpnH` gives the process name only when the agent runs as root; the netguard lint already carries this caveat in the message it prints when it cannot identify a shell daemon (internal/netguard/lint.go:236). On a node where process attribution is unavailable, discovery still proposes the port, it just labels it "unattributed listener" instead of "sing-box inbound".

The position: ship discovery on listeners plus the sing-box inventory, and revisit config readers only if the fleet produces a case where a stopped service needed a rule before it started. If that case arrives, the shape is a `guardservices` package next to `guardreality` following the same discipline, and `GuardRuleOrigin.Service` already has room for it without a model change.

### 3.3 The proposal

A new read-only server function, `netguard.Propose`, sits beside `Suggest` in the same package and takes the same shape of input: no store, no HTTP, no executor.

```go
type ProposeInput struct {
    Binding  model.NodeGuardBinding
    Groups   []model.SecurityGroup
    Zones    map[string]model.GuardZone
    Reality  model.GuardNodeReality
    SingBox  *model.SingBoxInventory // nil when the node reports none
    Now      time.Time
}

// ProposedRule is a draft rule plus why it was drafted and what it would change.
type ProposedRule struct {
    Rule   model.GuardRule `json:"rule"`
    // State is new | present | changed | vanished.
    State  string          `json:"state"`
    // Existing is the node rule this one diffs against, when State is
    // present, changed or vanished.
    Existing *model.GuardRule `json:"existing,omitempty"`
    Evidence []model.GuardListener `json:"evidence,omitempty"`
    Reason   string                `json:"reason"`
}
```

Every proposed rule is an ingress allow with `remote.kind = "any"`, because a port that is currently reachable stays reachable: bringing in a discovery must never be the step that cuts a service. Narrowing the source is the operator's next, separate, visible edit. Each carries `Origin{Kind: "discovered", Service, Ref, DiscoveredAt}`.

Loopback-bound listeners are excluded, matching `Suggest` (suggest.go:90) and the scaffold's unconditional `iif lo accept`. Listeners already covered by an enabled allow in the effective rule set are returned with `state: "present"` rather than dropped, so the panel can show the full picture rather than only the deltas.

The diff key is `(origin.service, origin.ref, protocol)`. On re-discovery: a proposal whose key matches an existing node rule with the same ports is `present`; same key with different ports is `changed` and carries the existing rule so the UI can show 31001-31012 becoming 31001-31016; a key with no proposal behind it any more is `vanished`.

A vanished rule is never auto-removed. It is surfaced in the bring-in panel as "sing-box inbound `vless-in` no longer listens; this rule now opens a port nothing serves", with a one-click disable that sets `disabled: true` rather than deleting, and a delete that requires the same confirm as any other rule removal. Auto-removal would mean a sing-box restart window silently narrowing a firewall, which is a worse failure than a stale open port that the exposure lens already flags. The existing `SuggestionAllowWithoutListener` (suggest.go:14) already computes the same fact from the other direction and keeps working unchanged.

### 3.4 Bring-in

"Bring in" is a client-side composition, not a new write endpoint. The UI calls `propose`, the operator ticks the rules they want, and the plugin sends the resulting list through the existing `upsert_binding` with the node's current `Version`. Every guarantee the binding path already has applies without modification: rule validation by trial compile (server_netguard.go:726), optimistic concurrency (:733), the audit event (:740), and the intent-change detection that clears `LastPlanSHA` and forces a re-plan (`serverAuthoritativeGuardBinding` at :799, `guardBindingIntentEqual` at :820).

That last one is load-bearing and free: bringing in ten rules invalidates any pending plan, so the operator cannot approve a ruleset that predates the rules they just added.

## 4. Rendering

### 4.1 Mapping onto the existing renderer

Nothing in this design emits nft syntax. `Compile` lowers into `network.NFTPlan` and `network.GenerateNFTPlan` stays the single renderer, which is the structural guarantee stated at compile.go:14-24 and which is why no competing default-drop chain can appear.

An allow with a CIDR source list becomes one `NFTInputRule` with `SourceCIDRs` populated. `renderInputRule` (nft.go:281) emits one line per address family, so `ip saddr { 203.0.113.0/24, 198.51.100.7 }` and `ip6 saddr 2001:db8::/32` come out as two lines from one rule, both carrying the same comment. A deny becomes the same shape with `NFTActionDrop` (compile.go:200). Ports render as an explicit list through `joinPorts` (nft.go:366); `ExpandPortRanges` caps expansion at `MaxExpandedPortsPerRule = 1024` and fails closed with a named error (compile.go:31, :332). The widest observed sing-box range is twelve ports, so the cap is not near.

### 4.2 nftables 1.0.6

Fifteen fleet nodes run 1.0.6, where `destroy table` does not parse. The renderer already handles this with `add table` then `delete table` then the definition (nft.go:93-95), and the reason is written down at nft.go:87-92 with the exact failure: `nft -c 'destroy table inet X'` returns "syntax error, unexpected table, expecting string" and the apply script's `nft -c -f` then refuses the whole plan before anything changes. There is a regression test pinning the prefix at internal/network/nft_test.go:184.

Everything this design adds is 1.0.6 grammar: anonymous sets in `saddr` and `dport`, `iifname`, `meta l4proto`, quoted comments. No named sets, no intervals flag on a rule-level set, no `destroy`. Named sets for source CIDRs were considered and rejected: an anonymous set is one line an operator can read in the plan diff, a named set is a second object to keep in sync across a table replacement for no correctness gain at the list lengths this fleet will author. If a rule ever needs hundreds of sources, that is the moment to add a named set, not before.

One validation gap to close while here: `Comment` is only trimmed (nft.go:206) and `ruleComment` falls back to the rule id (compile.go:207). nftables bounds a comment at 128 bytes, so a long operator comment produces a plan that passes the server and fails `nft -c -f` on the node, which is the worst place to find out. Bound it at 120 runes at validation time with a clear message.

### 4.3 IPv4 and IPv6 parity

Source matching has parity: `inputSourceExprs` (nft.go:311) splits by family and emits both lines. Port and interface matching are family-agnostic. The one asymmetry is structural and predates this design: the wireguard zone fast path renders `ip saddr @wg_peers4`, and that set is `type ipv4_addr` (nft.go:96), so a wireguard-zone rule matches IPv4 only. It is correct for a v4 mesh and should be stated in the UI rather than silently assumed. A rule needing v6 overlay sources writes a CIDR remote, which does have parity.

The knock table has the same asymmetry for the same reason, documented at sshguard/artifacts.go:239-241: knockd opens the v4 set only.

### 4.4 The control sets that stay fixed

Four things in the rendered chain are not operator-editable and this design does not make them so.

`ct state established,related accept` and `iif lo accept` are the first two rules of the chain (nft.go:99-100), emitted before any operator rule can be reached. This is what makes the node agent's outbound traffic structurally safe: the chain is an input hook, an outbound connection's replies are established, and no rule ordering an operator can author gets in front of the ct accept. It is also what makes applying from inside an SSH session survivable, which is the same reasoning the knock ruleset writes down at sshguard/artifacts.go:134-137.

The two ICMP accepts (nft.go:104-105) carry the fixed type sets `ScaffoldICMPv4Types` and `ScaffoldICMPv6Types` (nft.go:66-67). The compiler refuses icmp and icmpv6 rules with an error that explains why (compile.go:126-131): an operator rule that could deny neighbour discovery is a node an operator can silently take off the v6 network. That refusal stays.

## 5. The lockout lint

This is where per-node deny rules earn their cost.

### 5.1 The existing lint is deny-blind

`acceptsAnyPort` (internal/netguard/lint.go:248) decides whether a plan leaves the operator a way in. It scans `PublicTCP` and `WireGuardTCP` for a management port, then walks `InputRules` and skips anything that is not an accept (lint.go:256). It never considers that a drop earlier in the chain shadows an accept later in it.

Today that is sound, because nothing authors denies and the only drops in a rendered plan come from rule shapes production does not use. Under this design it becomes a hole with a straight line to a permanent lockout: a node rule "deny tcp/22 from any" renders as an `InputRule` drop at position one, the group's management allow renders in `PublicTCP` at the end, `acceptsAnyPort` sees 22 in `PublicTCP` and returns true, the lint passes, the plan applies, and the node is gone. The file's own header comment (lint.go:16-25) is explicit that this lint is the only protection against that class and that the node-side watchdog cannot cover it, because `lattice-agent --selfcheck-controlplane` is an outbound connection that a default-drop input chain does not affect.

The fix is to make `acceptsAnyPort` simulate first-match instead of scanning for accepts. Walk the rendered plan in emission order, which is `InputRules` then the four broad lists; for each management port, the first rule that matches it decides. A drop that matches decides "no". A rule with a source restriction that does not cover every source is treated as not decisive for the port and the walk continues, keeping the deliberate generosity the current comment defends (lint.go:245-247): the lint should fire on "no way in", not on "fewer ways in than before".

### 5.2 The knock gate, from both sides

SSH Guard already checks this direction. `FindingOverriddenByGuard` (sshguard/lint.go:28, fired at :165) blocks an SSH Guard plan when the node's lattice_guard chain is policy drop and does not accept a port the profile gates, with the mechanism spelled out at lint.go:22-27: an accept verdict in one chain does not let a packet skip a later chain at a higher priority in the same hook. The knock chain hooks input at priority -10 (sshguard/sshguard.go:99) with policy accept (artifacts.go:210); lattice_guard hooks input at priority 0 with policy drop (nft.go:98). Knock runs first and admits, guard runs second and drops, and the operator sees a knock that reports success and a connection that never opens.

The reverse check does not exist, and this design creates the need for it. A NetGuard deny on a knock-gated port, or a NetGuard plan that simply stops accepting one, produces the identical failure from the other end. Two new findings:

`FindingDeniesKnockGate`, severity block. Fires when the node has a live SSH Guard profile and the plan's first-match walk decides "drop" for a port that profile gates. Message names the port, names the profile, and says the knock will report success and the connection will not open.

`FindingDropsKnockGate`, severity block. Fires when the node has a live SSH Guard profile and no rule in the plan accepts a gated port at all. Same failure, reached by omission rather than by an explicit deny.

Both need the node's gated ports, which the server already assembles for the other direction at internal/server/server_sshguard.go:119-133. The same assembly runs in reverse; no new state.

### 5.3 The control-plane host

The brief names the control-plane host's 80 and 443 as ports a plan must never drop. This is only in scope when the control-plane host is itself a managed node in the fleet. `s.publicURL` is already read by the lint path (server_netguard.go:322, :959) to decide `FindingUnverifiedApply`. Extend that: when the node being planned resolves to the same host as `publicURL`, require the first-match walk to decide accept for tcp/80 and tcp/443, and block otherwise with a message that says the plan would cut the console and every agent's control path at once.

### 5.4 Management sources

`FindingManagementPortAssumed` (lint.go:38) already warns when the lockout check had no reported reality and fell back to tcp/22, and `managementPorts` (lint.go:164) learns the real port from listeners owned by a shell daemon, which the production fixture proves works on a node running sshd on 2222 (lint_production_snapshot_test.go:52-87). That stays as is.

What is new is that a source-restricted management allow can pass the lint while being useless. "allow tcp/22 from 203.0.113.0/24" satisfies "some rule accepts 22" but locks out an operator arriving from anywhere else. The first-match walk from 5.1 already treats a source-restricted rule as not decisive, so it keeps walking; if nothing unrestricted accepts the port, the plan blocks. That is the right default, and the escape hatch is the one that already exists: `accept_lockout_risk` on the plan request (server_netguard.go:927), which audits a `netguard.lockout_risk.accepted` event (:1004).

Making the operator's own management CIDRs first-class was considered and rejected for this iteration. SSH Guard already owns that concept as `MgmtSources` and renders it into the knock table's `mgmt` and `mgmt6` sets (artifacts.go:198-207). Duplicating it in NetGuard means two places to keep a management source list current, and the first time they disagree the operator is locked out by the one they forgot. NetGuard reads SSH Guard's gated ports for 5.2; it should read the same profile's management sources for this, not grow its own.

## 6. The flow

The flow is unchanged from SSH Guard's semantics and from what NetGuard does today. This design adds no new stage.

A node starts observe-only. The operator authors node rules and brings in discovered ones; every save validates by trial compile and is audited, and nothing reaches the node. The review endpoint (server_netguard.go:200) returns the rendered ruleset, the lint findings, the reality snapshot, the suggestions and the drift state on a read, which is what lets the operator see a lockout risk before creating an approval rather than after (:61-64). `netGuardPreview` (:312) and the plan path (:947-961) must stay identical, as the comment at :308-311 requires; the first-match walk and the new findings go in `netguard.Lint`, which both call, so they cannot diverge.

Turning management on is a binding upsert with `managed: true`. Still nothing on the node.

Plan compiles, lints, and refuses on any blocking finding unless `accept_lockout_risk` is set (:962). It records a pending approval with `Plugin: "nft"` and `Action: "apply-ruleset:netguard-v1"` (:974-983), stamps `LastPlanSHA` on the binding, and returns the approval and the findings. The dry run is the node-side `nft -c -f` inside the existing apply script; the plan rides that path with no new apply branch, which is stated at :915-919.

Approval re-checks freshness twice: `requireCurrentNetGuardApproval` (:1014) refuses if the binding changed or if recompiling current intent yields a different SHA, and the task-result path re-checks the same thing before committing (:1075-1084). Apply validates, snapshots, arms a 60 second dead-man watchdog, commits, and runs the control-plane selfcheck. Rollback on failure is the watchdog. `handleNetGuardTaskResult` (:1056) records the applied table hash from the agent's `lattice netguard: managed_sha=` line (:1144) into `Binding.AppliedTableSHA`, which is what makes the drift comparison at :331 possible on every later read.

The one thing to align with SSH Guard rather than copy: SSH Guard splits arm and confirm into two approvals with a confirm window between them (sshguard/sshguard.go:123-131, window bounds at :105-111, default 900 seconds). NetGuard has the watchdog but no confirm approval. The reasoning that justifies SSH Guard's split applies here exactly: a change to who can reach the node needs a human to prove they can still reach it. But this design does not add it, for one reason worth stating: SSH Guard's revert is a systemd transient timer that outlives the task runner, and NetGuard's rollback is the apply script's own watchdog inside a single task. Adding a confirm stage means a second approval, a persistent revert unit, and a boot-time restore, which is a change to the apply path and therefore a separate iteration with its own canary. Until then the operator-visible statement is honest: NetGuard's protection is a 60 second watchdog and a pre-plan lint, not a confirm window, and section 8's rollout order compensates by putting a human on the console for each canary step.

What the operator sees at each step: the node page prints "observing, nothing enforced" with the rule list editable; after managed, "managed, not yet applied, plan required"; after plan, the approval with the rendered diff and every finding, blocking ones in red with the accept-risk checkbox next to them; after apply, "applied at HH:MM:SS, in sync" or the drift pill with both hashes; on failure, `Binding.LastError` verbatim.

## 7. UI on the plugin chassis

The page is the node detail inside the existing Exposure lens, which section 6.2 of the chassis spec already places below the table as an in-place expansion rather than a side panel. The chassis's header, proof line, stat strip, lens tabs and table card are unchanged; this adds one block inside the node detail.

At 1440:

```
+----------------------------------------------------------------------------------------------+
| < Fleet    VIRCS-ATT-VDS                          [managed] [in sync]     [ Review & plan ]   |
| node_ob46mh4ltshdpkhc · 203.0.113.9 · nft 1.0.6 · observed 08:49:05, 3m ago                   |
+----------------------------------------------------------------------------------------------+
| Default policy: drop every inbound packet no rule below accepts.                               |
| Always accepted first, not editable: established/related · loopback · icmp and icmpv6 control. |
+----------------------------------------------------------------------------------------------+
|                                                                                                |
|  Node rules                                          [ Bring in discovered (6) ] [ + Add rule ] |
|  Evaluated after trusted zones, before the 2 fleet groups below. First match wins.              |
|                                                                                                |
|  #  ON  ACTION  PROTO  PORTS        SOURCE              ORIGIN            COMMENT         •••  |
|  ────────────────────────────────────────────────────────────────────────────────────────────  |
|  1  [x]  deny    tcp    25          anywhere            manual            no outbound smtp  ⋮  |
|  2  [x]  allow   tcp    22          10.7.0.0/24         manual            ssh from mesh     ⋮  |
|                                     +2 more                                                    |
|  3  [x]  allow   tcp    31001-31012 anywhere            sing-box vless-in                   ⋮  |
|  4  [x]  allow   udp    31001-31012 anywhere            sing-box hy2-in                     ⋮  |
|  5  [ ]  allow   tcp    7000,7443   anywhere            frp frps          disabled 08-19    ⋮  |
|  ────────────────────────────────────────────────────────────────────────────────────────────  |
|  ! Rule 1 denies tcp/25 before fleet group "mail-relay" allows it. The node rule wins.          |
|                                                                                                |
+----------------------------------------------------------------------------------------------+
|  Fleet groups        [ lattice-core v7 ]  [ mail-relay v3 ]                    [ Manage ]      |
|  Trusted zones       [ wireguard ]                                             [ Manage ]      |
+----------------------------------------------------------------------------------------------+
|                                                                                                |
|  Discovered on this node                                              [ Bring in selected (4) ]|
|  From 21 listening sockets and 2 sing-box inbounds, observed 08:49:05.                         |
|                                                                                                |
|  [x] new      tcp 3433          realm(620)              -> allow from anywhere                 |
|  [x] changed  tcp 31001-31016   sing-box vless-in       rule 3 has 31001-31012                 |
|  [ ] present  tcp 22            sshd(645)               already allowed by rule 2              |
|  [x] new      udp 51820         wg(0)                   -> allow from anywhere                 |
|  [x] vanished tcp 7000,7443     frp frps                rule 5 opens a port nothing serves     |
|                                                                                                |
+----------------------------------------------------------------------------------------------+
|                                                                                                |
|  Enforcement                                                                                   |
|  ( ) Observe only. NetGuard watches this node and changes nothing.                             |
|  (o) Managed. NetGuard owns table inet lattice_guard on this node.                             |
|                                                                                                |
|  ! blocked  No rule accepts tcp/22 from every source. The only rule that opens it is           |
|             restricted to 10.7.0.0/24, so an operator arriving from anywhere else is cut.      |
|             [ ] I accept the lockout risk                                                      |
|  ! blocked  SSH Guard gates tcp/58394 on this node and rule 1 denies it. Knocking would         |
|             report success and the connection would never open.                                |
|  ! warn     The server has no public URL, so the node cannot selfcheck after committing.       |
|                                                                                                |
|  Dry run: nft -c -f passed on 2026-09-05 09:12:44 (nftables 1.0.6).                            |
|                                                                                                |
|  +--------------------------------------------------+-------------------------------------+   |
|  | applied 2026-08-19 08:31                          | this plan                           |   |
|  | ct state established,related accept               | ct state established,related accept |   |
|  | iif lo accept                                     | iif lo accept                       |   |
|  |                                                   | + tcp dport 25 drop comment "no ou… |   |
|  | iifname "eth0" tcp dport { 22 } accept            | ip saddr 10.7.0.0/24 tcp dport { 22…|   |
|  +--------------------------------------------------+-------------------------------------+   |
|                                                                                                |
|                                        [ Review & create approval ]                            |
+----------------------------------------------------------------------------------------------+
```

At 375 the same blocks stack in the same order with three changes. The rule table stops being a table: each rule becomes a card whose first line is the sentence `exposure.ts` already generates (`ruleSentence`, exposure.ts:592), with origin and comment as a muted second line and the enable toggle and overflow menu on the right. The discovered list keeps its checkboxes and drops the evidence column into the second line. The plan diff becomes one column, showing the new ruleset with added lines marked, and a "show applied" disclosure, because a side-by-side at 375 is unreadable and a horizontal scroller inside a vertical page is worse.

Fleet groups and zones stay where they are, on their own lens tabs, and appear on the node page only as the read-only chips shown above with a link out. Editing a fleet group from inside a node page would let an operator change 33 nodes while looking at one, which is the mistake the two-level model exists to prevent. The chip carries a tooltip with the group's `allowsPreview` sentences (exposure.ts:603) so the operator can see what the layer below contributes without leaving.

Three interaction rules, from the frontend standard rather than invented here. The enable toggle applies on release with the row showing a pending state until the upsert returns, and reverts in place on conflict with the version-conflict message; it never optimistically lies. Reordering rules is drag with a keyboard equivalent on the overflow menu, and the reorder is one upsert, not one per position. The "bring in" button is disabled with a stated reason, never silently absent, when the session lacks `netguard:admin`.

## 8. API surface

One new method, one changed response, no breaking changes.

### 8.1 New: `propose`

REST `GET /api/netguard/propose?node_id=...`, scope `netguard:read`, registered next to the review route (server.go:1259). Plugin method `propose`, effect read, scopes `["netguard:read"]`, added to the manifest's interface list and to the `pluginRPC.Register` method list (server_network_plugins.go:137-147) and dispatched through `invokePluginQuery` exactly as `review` is (:213).

Request, plugin side: `{"node_id": "node_ob46..."}`.

Response:

```json
{
  "proposal": {
    "node_id": "node_ob46mh4ltshdpkhc",
    "observed_at": "2026-08-19T08:49:05.630450121Z",
    "snapshot_status": "fresh",
    "sources": {
      "listeners": 21,
      "singbox_inbounds": 2,
      "process_attribution": true
    },
    "rules": [
      {
        "state": "new",
        "reason": "realm(620) listens on tcp/3433 and no enabled rule allows it",
        "evidence": [
          {"protocol": "tcp", "port": 3433, "address": "0.0.0.0", "process": "realm(620)"}
        ],
        "rule": {
          "id": "",
          "action": "allow",
          "direction": "ingress",
          "protocol": "tcp",
          "ports": [{"from": 3433, "to": 3433}],
          "remote": {"kind": "any"},
          "comment": "realm",
          "origin": {
            "kind": "discovered",
            "service": "listener",
            "ref": "realm",
            "discovered_at": "2026-09-05T09:10:00Z"
          }
        }
      },
      {
        "state": "changed",
        "reason": "sing-box inbound vless-in now listens on 31001-31016",
        "existing": { "id": "r-3", "ports": [{"from": 31001, "to": 31012}], "…": "…" },
        "rule": { "…": "…" }
      }
    ]
  }
}
```

`state` is one of new, present, changed, vanished. `rule.id` is empty on a new proposal; the client assigns one on accept, as the group editor already does. `process_attribution` false tells the UI to label origins as unattributed rather than pretending.

### 8.2 Changed: `review`

`netGuardReview` (server_netguard.go:55) gains two fields, both additive.

```json
{
  "review": {
    "…": "existing fields unchanged",
    "precedence": [
      {"layer": "trusted_zones", "source": "binding.zone_ids", "count": 1},
      {"layer": "node_rules",    "source": "binding.overrides", "count": 5},
      {"layer": "fleet_groups",  "source": "sg-lattice-core",   "count": 4},
      {"layer": "fleet_groups",  "source": "sg-mail-relay",     "count": 3}
    ],
    "shadowed": [
      {
        "rule_id": "sg-mail-relay:r-2",
        "shadowed_by": "r-1",
        "detail": "node rule r-1 denies tcp/25 from anywhere before this allow is reached"
      }
    ]
  }
}
```

`precedence` is what the UI prints as the layer strip; computing it client-side would mean reimplementing `Compile`'s ordering in TypeScript and letting the two drift. `shadowed` is the same walk that 5.1's first-match simulation performs, reported for every rule rather than only the management ports, which is what makes the "the node rule wins" line under the table honest instead of a guess.

### 8.3 Changed: SDK model

`NetEndpoint.CIDRs []string`, `GuardRule.Origin *GuardRuleOrigin`, and the new `GuardRuleOrigin` type, all as in 2.2. The proto contract test at lattice-sdk/model/proto_contract_test.go will need the new fields registered.

### 8.4 Unchanged

`upsert_binding`, `plan`, `adopt`, `reality`, `overview`, `upsert_group`, `delete_group`, `upsert_zone`, `delete_zone` keep their current request and response shapes. Bringing rules in is an `upsert_binding` with a longer `overrides` array. This is the point of putting node rules in the binding rather than in a new object.

## 9. The strongest case against this design

### 9.1 Per-node rule sprawl defeats fleet groups

This is the real risk and it is not hypothetical. Give 33 nodes an editable per-node rule list with a one-click import and within a quarter the fleet has 33 divergent firewalls, nine groups nobody attaches any more, and no way to answer "which nodes allow 3433" without reading every binding. The whole reason `SecurityGroup` is a reusable object attachable to any number of nodes (model.go:707-710) is that this failure mode is the default outcome of per-node authoring.

The counter-argument is that the operator's actual fleet already refutes the uniformity premise. The observed sing-box ranges are 31 distinct port sets across 33 nodes; only 31001-31012 appears on more than two machines. A fleet group cannot express "each node opens its own inbound bank" without either one group per node, which is what the legacy baseline conversion already produces (`LegacyGroupPrefix`, convert.go:18), or a group so wide it opens every node's ports on every node. Per-node rules are the honest shape for genuinely per-node facts.

The resolution is to make the layer boundary visible and slightly inconvenient rather than to withhold the capability. Three concrete measures. The node page prints the precedence strip from 8.2 above the rule list, so a node rule is always seen in the context of the groups under it. When a proposal's rules are identical to an existing fleet group's rules, the bring-in panel offers "attach group X" ahead of "add 4 node rules", which is a one-line comparison against `SecurityGroups()` and turns the common case back into the shared object. And the fleet Exposure lens gains a column counting node rules per node, so sprawl is a number on the main table rather than something discovered during an incident. If that number climbs past a threshold the operator sets, the honest answer is a group, and the panel says so.

What is deliberately not done: no automatic promotion of repeated node rules into a group. A firewall change that happens because software noticed a pattern is exactly the class of surprise this system is built to avoid.

### 9.2 Deny rules interacting with the knock gate

Covered in 5.2, and it is the sharper of the two objections because it fails silently. SSH Guard's protection depends on lattice_guard accepting the ports it gates, the two tables sit on the same hook at priorities -10 and 0, and an accept in the first does not let a packet skip the second. Today NetGuard cannot break this because it cannot express a deny that production uses. This design ships the deny.

It is resolved by the two new blocking findings, and by the ordering that they need: the reverse check must land before per-node denies are authorable on any node that has a live SSH Guard profile. That is a sequencing constraint on the implementation, not a caveat in a document. Concretely, the server should refuse to save a `deny` in `Binding.Overrides` for a node with a live gating profile until `FindingDeniesKnockGate` exists, which is a three-line guard in `validateGuardRules` that gets deleted when the finding lands.

### 9.3 The deny-blind lint is a live hole, not a new one

Worth separating from 9.2 because it needs no SSH Guard profile to bite. `acceptsAnyPort` (lint.go:248) scans for accepts and ignores preceding drops, so the moment any deny is authorable, a plan that drops the management port can pass the only check that stands between the fleet and a permanent lockout. The file's own comment says nothing downstream will catch it (lint.go:23-25) and the production fixture exists because this exact class already cost the fleet a node once.

Resolution: the first-match walk in 5.1 ships before any deny is authorable, with its own tests, on the same commit as the model change. It is the one part of this design that is not a feature and cannot be deferred behind a flag.

### 9.4 Discovery proposes an allow, which can only widen

Every proposed rule is an allow from any source, so accepting a whole proposal can only ever open ports, never close them. An operator who clicks bring-in on a node with 21 listeners has just written a firewall that allows 21 services from the internet, which is close to no firewall while looking like configuration.

This is the correct trade against the alternative, which is a proposal that also removes rules and therefore can cut a running service on a click. But it needs to be said on screen rather than assumed: the bring-in panel prints the count of ports the selection would open to the internet, in the destructive tone, next to the button. `computeExposure` (exposure.ts:485) already computes exactly this number for the fleet table, and `isPublicCidr` (exposure.ts:203) already knows which sources reach from outside, so this is a display of an existing calculation rather than new logic.

## 10. Test plan

Unit, in `internal/netguard`. Precedence: a node deny and a group allow on the same port render with the deny first, and the byte-parity test for an all-allow binding still passes, proving the fast-path condition from 2.4 is scoped correctly. Source lists: a rule with `CIDR` and `CIDRs` set unions them, sorts them, and family-splits into two rendered lines. Lint: the shadowed-management-port case blocks where it previously passed, driven by the same captured production snapshot (lint_production_snapshot_test.go:23) extended with a deny; a source-restricted management allow blocks; an unrestricted one passes; the knock-gate findings fire against a fixture profile gating 58394 and stay silent when the profile is hardening-only. Propose: the observed sing-box ranges become the expected compressed rules through `PortRanges`; a listener already covered returns `present`; a port that moved returns `changed` with the existing rule attached; a disappeared inbound returns `vanished` and never removes anything. Comment bounding rejects at 121 runes.

Server, in `internal/server`. `upsert_binding` with an origin-carrying rule round-trips through the store and the trial compile. `propose` returns 404 for a node the principal cannot read, and refuses rather than filters when a rule names an unreadable remote node, matching the reasoning at server_netguard.go:443-457. Review's new `precedence` and `shadowed` fields match what the compiler actually ordered, asserted against the rendered ruleset rather than against a hand-written expectation. The preview and plan paths produce identical findings for identical input, which is the invariant at server_netguard.go:308-311.

Plugin, in `ui/src`. `exposure.ts` classification is unchanged by the new fields, which the existing suite should prove without edits. New tests for the proposal diff view and for the shared-ref TCP-and-UDP pair behaving as one row.

Node, on real hardware. `nft -c -f` on the rendered plan for each canary, captured verbatim into the rollout notes.

## 11. Rollout

Step one is the two correctness fixes with no feature attached: the first-match lint walk and the fast-path condition, released and applied to nothing. Nothing changes on any node, because no binding is managed. What could go wrong is a false block on a plan that used to pass, which is caught by re-running the review endpoint across all 33 nodes and diffing the findings against the current set; any node that newly blocks is either a real hole or a lint bug, and both are worth knowing before a plan exists.

Step two is the model and API, still with no node managed. Risk is a decode regression on the 24 stored bindings and 9 groups; caught by reading `overview` and `review` for every node after deploy and comparing the rendered ruleset SHA against the pre-deploy value for each. Any change is a bug, because additive fields cannot alter a compiled ruleset.

Step three is the canary, VIRCS-ATT-VDS. Bring in its discovered rules, review, dry run, plan, approve, apply, with an operator on a second shell that is not going through the port being changed. Confirm the applied hash matches and the drift pill reads in sync. What could go wrong is the lockout the whole lint exists to prevent; caught by the pre-plan block, and if it is missed, by the 60 second watchdog, and if that is missed, by the second shell. Do not proceed until the node has survived a reboot with the table intact.

Step four is Aaitr-Frontier-VDS, chosen because it runs nftables 1.0.6. This is the step that proves the grammar, so the dry run output is read in full rather than checked for exit zero. What could go wrong is a construct that 1.0.7 parses and 1.0.6 does not, which is exactly the `destroy table` failure the renderer already works around (nft.go:87-92); caught by `nft -c -f` before anything is committed.

Step five is batches of five, ordered by how little the node matters, with a full working day between batches and the exposure lens checked for new unexplained ports after each. Nodes with a live SSH Guard profile go last, and only after the knock-gate findings from 5.2 have fired at least once in anger on a test profile, because that is the interaction with no independent second check behind it.

---

## Ten-line summary

1. **No new object.** A node's security group is `NodeGuardBinding.Overrides`, already an ordered `[]GuardRule` with versioning, validation-by-trial-compile, and audit. Precedence is already trusted zones → node rules → fleet groups → broad allows; this design makes it visible, not new.
2. **Three additive SDK fields:** `NetEndpoint.CIDRs []string` (source list; the renderer already family-splits it at `nft.go:311`), `GuardRule.Origin *GuardRuleOrigin{kind,service,ref,discovered_at}` for diffing re-discovery, and the `GuardRuleOrigin` type. No `enabled` (use existing `Disabled`), no `tcp+udp` protocol (the form expands to a two-rule pair sharing an `Origin.Ref`).
3. **Compiler fix, mandatory:** `fastPathBucket` (`compile.go:174`) diverts public-zone allows into port lists that render *after* all `InputRules` (`nft.go:106-122`), inverting precedence so a fleet deny beats a node allow. Fix: disable the fast path when the effective list contains any enabled deny. All 24 legacy baselines are allow-only, so adoption byte-parity holds.
4. **Lint fix, mandatory and shipped first:** `acceptsAnyPort` (`lint.go:248`) skips non-accepts and ignores preceding drops, so a `deny tcp/22` renders before a `PublicTCP` allow and the lint still passes. Replace the scan with a first-match walk in emission order. This is the only check between a plan and a permanent lockout (`lint.go:16-25`).
5. **Two new blocking findings** for the knock gate: `FindingDeniesKnockGate` and `FindingDropsKnockGate`. SSH Guard already checks the other direction (`sshguard/lint.go:165`); knock hooks input at -10 policy accept, lattice_guard at 0 policy drop, so an accept in one does not skip the other. Sequencing constraint: refuse saving a deny on a gated node until these exist.
6. **Discovery uses evidence already collected:** `ss -tulpnH` listeners with process names (`guardreality/collect.go:212`, proven by the production fixture showing `frps(612)` on 7000/7443/7500 at `lint_production_snapshot_test.go:34`) plus `SingBoxInventory` for typed inbounds (vless/trojan TCP, hysteria2 UDP, shadowsocks both). **No frps.toml or `nginx -T` reader** — that is a new privileged agent collector for what `ss` already reports; the residual gap (stopped services, non-root attribution) is stated rather than hidden.
7. **One new API method,** `GET /api/netguard/propose?node_id=` plus plugin method `propose` (read, `netguard:read`), returning rules tagged `new|present|changed|vanished` with evidence. Bring-in is client-side composition through the existing `upsert_binding`, which inherits validation, optimistic concurrency, audit, and automatic plan invalidation for free.
8. **`review` gains `precedence` and `shadowed`** so the UI prints the layer strip and "the node rule wins" from the server's own ordering walk rather than reimplementing `Compile` in TypeScript. Everything else is unchanged.
9. **Vanished listeners are never auto-removed** — only surfaced with a one-click disable. Every proposed rule is `allow` from `any`, so bring-in can only widen; the panel prints the count of ports it would open to the internet, reusing `computeExposure`/`isPublicCidr`.
10. **Rollout:** lint+compiler fixes with nothing managed → model/API with SHA-diff verification on all 33 nodes → VIRCS-ATT-VDS canary with a second shell → Aaitr-Frontier-VDS for the 1.0.6 grammar (`destroy table` is the known 1.0.7-only trap) → batches of five, SSH Guard nodes last. Migration is a no-op: the 24 observe-only bindings and 9 fleet groups decode unchanged, absent `origin` reads as manual.

**Strongest case against, and resolution:** per-node sprawl defeating fleet groups (resolved by making the layer boundary visible, offering "attach group X" when a proposal matches an existing group, and counting node rules on the fleet table — explicitly *not* by auto-promoting patterns into groups); and denies interacting with the knock gate plus the deny-blind lint (resolved by shipping items 4 and 5 before any deny is authorable).
