# Iteration 053 - Xray Renderer and Apply Path

- **Date:** 2026-06-14
- **Repos:** `lattice-server`, `lattice-dashboard`, `lattice`
- **Builds on:** iter-039 proxy model foundation, iter-040 sing-box renderer,
  iter-043 proxycore apply, iter-052 collector health
- **Status:** Implemented, reviewed, verified

## Goal

Move proxy-core orchestration from sing-box-only deployment to a two-core MVP:
operators can create `xray` VLESS+REALITY+TCP inbounds/profiles, review a
redacted xray config, queue the same plan-hash-bound proxycore apply task, and
serve the same fleet-wide VLESS subscription links for applied xray nodes.

This slice deliberately does **not** add xray stats gRPC or `grpc-go`. Runtime
usage collection remains the existing file/loopback HTTP/V2Ray-stats bridge
until the true API transport is pinned in a separate ADR.

## Scope

- Add a dependency-free xray renderer in `internal/proxycore`:
  - `RenderXrayConfigJSON`;
  - VLESS over TCP;
  - REALITY settings (`dest`, `serverNames`, `privateKey`, `shortIds`,
    `maxTimeDiff`);
  - deterministic JSON + SHA-256 artifact binding;
  - same eligible-user filtering as sing-box.
- Generalize the renderer artifact contract so server plan/apply can choose the
  core at runtime while keeping the old sing-box call sites compatible.
- Update server proxy planning:
  - profile/inbound normalization accepts only `sing-box` or `xray`;
  - a profile can only reference inbounds with the same core;
  - xray plans render a redacted xray config with client `id` and `privateKey`
    hidden;
  - queued apply writes the candidate config, runs `xray test -c`, atomically
    swaps the file, and reloads/restarts the `xray` service with the existing
    rollback trap.
- Update subscriptions:
  - applied xray VLESS+REALITY+TCP profiles produce normal `vless://` links;
  - sing-box JSON and Clash/Mihomo client subscription formats continue to be
    derived from the core-agnostic endpoint projection.
- Update dashboard:
  - inbound/profile forms expose a `core` selector (`sing-box`, `xray`);
  - edit/reset/submit preserve the selected core;
  - the config-path hint now names both default paths.

## Security Decisions

- **No new dependency and no inbound node API.** Xray deployment is just another
  server-rendered artifact flowing through the existing outbound agent task
  channel.
- **No generic config editor.** Operators still edit the typed Lattice intent
  model; raw xray JSON is never accepted from the dashboard.
- **Same plan-hash binding.** The approval action binds the real secret-bearing
  artifact SHA-256, while the review plan displays a redacted config.
- **Fail-closed core matching.** A profile cannot bind an inbound rendered for
  another core; mixed-core profiles are rejected before plan/apply.
- **Stats-compatible client identity.** Xray VLESS `email` is rendered from the
  stable `ProxyUser.ID`, not the display name, so later V2Ray/Xray stats reports
  (`user>>>id>>>traffic`) can map back to server-owned users.
- **Validation before swap.** The node script runs `xray test -c "$CANDIDATE"`
  before replacing the target file, mirroring the existing `sing-box check`
  path.

## Verification

From `lattice-server`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-server \
go test ./...

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache-server \
go vet ./...
```

From `lattice-dashboard`:

```sh
npm test
npm run check
```

Diff hygiene:

```sh
git diff --check
```

Focused tests cover:

- xray VLESS+REALITY+TCP render shape, config hash, profile overrides, and
  unsupported/mismatched inputs;
- redacted xray approval plans hiding `privateKey` and VLESS client `id`;
- xray apply scripts using `xray test -c`, xray service reload/restart, atomic
  candidate swap, and rollback cleanup;
- applied xray profiles appearing in the same VLESS subscription output;
- dashboard payload helpers preserving selected `xray` core.

## Residuals & Next

1. Pin and implement true sing-box/xray API transports for usage collection.
   If xray stats gRPC introduces `grpc-go`, write an ADR first.
2. Add optional xray binary install/version pinning, equivalent to the
   self-host DNS CoreDNS install pattern.
3. Add live over-quota/expired reconcile so disabled users are removed from
   node configs through a reviewed apply, not only hidden from subscriptions.
4. Add browser-level dashboard smoke once the local sandbox permits background
   localhost listeners.
