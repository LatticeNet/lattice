# iter-068 — NetGuard foundation (design-13 G1)

> Status: implemented · Date: 2026-07-09
> Design: `designs/design-13-wireguard-and-netguard-plugins.md` §4, §7, §9 (G1)
> Repos: lattice-sdk (`feat/netguard-foundation`), lattice-server
> (`feat/netguard-foundation`)

## Goal

First shippable slice of the design-13 NetGuard track: the security-group
data model, store collections with optimistic concurrency, RBAC/capability
scope registration, and **read-only** views that render every existing legacy
`NFTInputs` baseline in the new shape. Zero apply-path changes; zero store
mutation from the converted views.

## Scope (exact)

**lattice-sdk `model/model.go`**
- New constants: `NetRefZone`, `GuardProtoICMP/ICMPv6`, builtin zone ids
  (`GuardZonePublic/Loopback/WireGuard/Tailscale`).
- `NetEndpoint` gains additive `ZoneID` (set when `Kind == "zone"`).
- New types: `GuardPortRange`, `GuardZone`, `GuardRule`, `SecurityGroup`
  (with `Version`), `NodeGuardBinding` (with `Version`, `Managed`, apply-state
  and `AppliedTableSHA` drift-anchor fields), `GuardListener`,
  `GuardInterface`, `GuardNodeReality` (G3 wire contract frozen now).

**lattice-server**
- `internal/rbac`: `netguard:read` / `netguard:admin` in `KnownScopes`.
- `internal/plugin`: `netguard:read` → RiskRead, `netguard:admin` → RiskHost
  in `capabilityRisk` (same move iter-020 made for `netpolicy:*`).
- `internal/store`: `SecurityGroups` / `GuardZones` / `GuardBindings` state
  collections (nil-guarded for pre-design-13 state files), CRUD, and
  `ErrGuardVersionConflict` optimistic-concurrency on security-group and
  binding upserts — closing the silent-clobber gap `NFTInputs` upserts have.
- New `internal/netguard` package: `PortRanges` (sorted/deduped/compressed
  inclusive ranges, out-of-range dropped fail-closed) and `LegacyBaseline`
  (NFTInputs → node-private `sg-legacy-<node>` group + observe-only binding +
  resolved builtin zones). Semantics preserved exactly: legacy WireGuard
  ports become zone-remote rules, never trusted zones; `Managed=false`.
- `internal/server/server_netguard.go`: read-only `GET /api/netguard/groups`,
  `/api/netguard/zones`, `/api/netguard/nodes` behind `netguard:read` with
  per-node allowlist filtering. Stored records supersede legacy views;
  legacy conversion happens on read and persists nothing.

## Deliberately out of scope (next slices)

- G2: compiler + byte-parity gate vs `network.GenerateNFTPlan`, plan linting,
  `Approval.Plugin="netguard"`, write APIs (adopt/upsert via
  `netguard:admin`).
- G3: `--report-guard-reality`, suggestions, drift.
- Dashboard views, plugin manifest packaging (G4+).

## Verification

- `GOWORK=<sdk+server worktrees> go build ./...` clean; `gofmt -l` clean.
- `go test -race ./internal/netguard ./internal/store ./internal/rbac
  ./internal/plugin` green.
- `go test -race -count=1 ./internal/server/...` green (includes the new
  `server_netguard_test.go`: legacy view correctness incl. the dmit-eb-wee
  9009-9013 range-compression fixture, stored-supersedes-legacy, no-write
  assertion, version-conflict paths).
- SDK: `go test ./...` green.

## Exit bar check (design-13 G1)

- [x] Converted view of every existing `NFTInputs` visible via
  `/api/netguard/nodes` and `/api/netguard/groups`.
- [x] Zero apply-path changes (no `applyScriptFor`, approval, or agent edits).
- [x] Read endpoints enforce `netguard:read` + per-node allowlists.
- [x] Version-conflict regression tests for groups and bindings.
