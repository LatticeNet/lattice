# iter-069 — NetGuard compiler, byte-parity gate, write path (design-13 G2)

> Status: implemented · Date: 2026-07-09
> Design: `designs/design-13-wireguard-and-netguard-plugins.md` §4.4, §4.6, §7.1
> Repos: lattice-server (`feat/netguard-foundation`)
> Builds on: iter-068

## Goal

Make the design-13 security-group model authoritative and usable end to end —
compile it, lint it, plan from it — while proving it reproduces today's
firewall exactly and without adding a new apply branch.

## The central design call: lower, don't rewrite

The compiler does **not** emit nft syntax. It lowers zones, trusted zones,
per-node overrides, and attached security groups into the existing
`network.NFTPlan`, and `network.GenerateNFTPlan` remains the single renderer of
`table inet lattice_guard`. Two consequences, both deliberate:

- **Byte-parity with the legacy path is structural, not incidental.** Rules in
  the exact legacy broad-allow shape (ingress allow, tcp/udp, ≥1 port, remote =
  public or wireguard builtin zone) take a fast path into the plan's
  `Public*`/`WireGuard*` port lists. Everything else becomes a typed
  `network.NFTInputRule`, which the renderer emits *before* those broad allows —
  the ordering that lets a targeted deny override an otherwise-open port.
- **No competing default-drop hook can appear**, which is the invariant
  iter-019/iter-024 established and design-05 §9.3 resolved.

## Scope

**`internal/network/nft.go`**
- `NFTInputRule.Interface` (additive): renders `iifname "<name>"`, charset-validated
  by the existing `ifaceNameRe`. This is what makes a trusted overlay zone
  expressible — the tailscale0 lockout fix.

**`internal/netguard/compile.go`**
- `Compile` / `CompileRuleset` lowering with `ErrNodeUnmanaged` (converted
  legacy views are observe-only until adopted).
- Composition order: trusted-zone accepts → node overrides → group rules in
  binding order → broad allows → `counter drop`.
- Node remotes resolve to that node's own addresses only; group remotes are
  refused (they must be expanded first); domain remotes are egress-only.
- Refusing to trust the `public` zone wholesale.
- `ExpandPortRanges` with `MaxExpandedPortsPerRule = 1024`: ranges round-trip
  through the explicit port lists the current renderer emits, and a range wide
  enough to make a ruleset unreviewable fails closed instead of exploding it.
  Native `from-to` nft emission is a later renderer upgrade (design-13 L2).
- Fail-closed on icmp/icmpv6, `rate_limit`, `log`, and egress direction — all
  declared in the model, none renderable yet.

**`internal/netguard/lint.go`**
- `lockout_risk_ssh` (**blocking**): a default-drop plan with no path to tcp/22
  from anywhere is refused *before* it can reach a node. Satisfied by a
  management-port allow, an any-protocol accept, or a trusted overlay zone.
  This turns the dmit-eb-wee failure class from a post-apply watchdog rollback
  into a pre-plan refusal.
- `unverified_apply` (warn): no `public_url`, so the node cannot selfcheck the
  control plane after committing. Loud, no longer silent (gap 5).

**`internal/server/server_netguard.go`**
- `POST /api/netguard/groups`, `/groups/delete`, `/zones`, `/zones/delete`
  (`netguard:admin`), `/bindings`, `/nodes/adopt`, `/plan` (per-node scopes).
- Rules are compiled at **write** time, so an unrenderable rule never reaches
  the store and a later plan cannot fail on stored garbage.
- Referential integrity: an attached group or a trusted zone cannot be deleted;
  the `sg-legacy-*` id space is reserved; the loopback zone is not editable.
- Optimistic concurrency surfaces as `409`.
- `resolveNodeZones` makes zones fleet-scoped by name but node-resolved by
  fact: "public" means *this* node's interface, "wireguard" *this* node's CIDR.

**Plan carries `Approval.Plugin == "nft"`.** The plan text is the same
`lattice_guard` ruleset, so it rides the existing rollback-protected apply
script (validate → snapshot → watchdog → commit → selfcheck) unchanged. G2 is
therefore end-to-end usable with **zero apply-path change**.

## Verification

- `go build`, `gofmt -l`, `go vet` clean (GOWORK=off, pinned SDK).
- `go test -race ./...` green, full server suite included.
- **Parity gate has teeth (mutation-checked).** `TestLegacyBaselineRendersByteIdentically`
  covers 8 fixtures including the real dmit-eb-wee baseline. Disabling the
  fast path makes it fail; restoring it makes it pass. It is red-if-removed.
- Other new tests: trusted-zone accept renders `iifname "tailscale0" accept`
  *before* broad allows; a targeted deny renders before the allow it must beat;
  node remotes resolve to both addresses and unknown nodes are rejected, never
  silently widened; overrides precede group rules; nine fail-closed shapes;
  lockout lint blocks and is cleared by an allow *or* a trusted zone;
  adopt → plan HTTP flow, re-adopt conflict, plan-before-adopt refusal,
  write-time validation, stale-version 409, reserved-id squat, in-use
  group/zone delete conflicts.

## Exit bar check (design-13 G2)

- [x] Converted fixture parity test green, byte-for-byte.
- [x] Lockout lint has a red-if-removed test.
- [x] `netguard:admin` write path with referential integrity + optimistic
  concurrency.
- [x] Plan produces a reviewable approval on the existing apply path.

## Deliberately still out of scope

Reality reporting / drift / suggestions (G3), dashboard views (G4), bootstrap
(G5), NAT + rate-limit + logging renderers (G6), raw-snippet escape hatch (G7),
and the signed plugin manifest packaging.
