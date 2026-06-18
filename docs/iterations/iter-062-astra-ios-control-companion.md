# Iteration 062 - Astra iOS Control Companion

## Scope

- **Repos:** [`Astra`](https://github.com/LatticeNet/Astra), `lattice`
- **Source branch:** `main` in `LatticeNet/Astra`
- **Goal:** Publish and record the Astra expansion from a read-only monitoring
  prototype into a phone-first Lattice companion app, while keeping signing,
  TestFlight, and live-device QA as explicit follow-up release work.

## Delivered

- `Sources/AstraCore/`
  - `LatticeModels.swift` mirrors mobile-relevant `lattice-sdk/model.go` and
    server view structures: tokens, machine profiles, monitors/results,
    notification channels/rules, audit events, tasks, log sources/lines,
    identity, version, and node geo.
  - `LatticeAPI.swift` adds a typed `LatticeClient` for identity/version,
    nodes, node token/enrollment/geo operations, PAT management, machine
    inventory CRUD/renewal, monitors/results, notifications, audit search and
    verification, tasks/results, and logs.
  - `LatticeNetwork.swift` adds typed Network & security models and endpoints
    for approvals, NetPolicy list/graph, nft baseline inputs, tunnels, and
    SHA-256-bound approval of reviewed plans.
  - `LatticeAnalytics.swift` derives fleet summaries, metric history buffers,
    inventory cost/renewal summaries, monitor uptime/latency stats, currency,
    relative time, and uptime formatting.
- `AstraApp/App/`
  - Five-tab phone UI: Overview, Nodes, Monitors, Inventory, and More.
  - Overview includes fleet health, stat tiles, Fleet Map, attention nodes, and
    recent alerts.
  - Nodes adds search/filter, detail trends, host facts, networking, geo,
    enable/disable, token rotation, and enrollment QR entry points.
  - Monitors adds uptime/latency views, recent probes, create, and delete.
  - Inventory adds cost/renewal summaries plus create/edit/renew/delete.
  - More groups Activity, Network & security, Notifications, Logs, Tasks,
    Account/PATs, Settings, and About. Network & security shows pending
    approvals, NetPolicy rules, reachability, nft inputs, and tunnels; its only
    write path is a confirmation-gated approve action that sends the reviewed
    plan's SHA-256.
  - `DesignSystem.swift` centralizes cards, rings, status pills, stat tiles,
    and Swift Charts sparklines.

## Product Boundary

Astra is a companion app, not the canonical dashboard replacement. The mobile
surface intentionally focuses on personal fleet operations and quick response.
Heavy mutation planes remain Web-first until their mobile review flows are
designed:

- NetPolicy authoring/planning, proxy/subscription apply, DNS publishing,
  storage/static hosting, plugin execution, OIDC provider admin, and 2FA
  enrollment. Astra can observe network state and approve already-reviewed
  plans, but it does not generate or apply new plans directly.
- Terminal is not listed as an Astra feature in this iteration.
- Live-service iPhone QA, Bark behavior, background refresh behavior, signing,
  and distribution still require device-side validation.

## Verification

Verification:

```sh
swift run AstraCoreCheck
```

Passed with nine regression groups, including the expanded API client and
analytics checks.

```sh
xcodebuild -project Astra.xcodeproj -scheme Astra \
  -sdk iphonesimulator -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Built successfully with Xcode 26.5 for Simulator arm64/x86_64 under Swift 6
strict concurrency after adding the required `Sendable` conformance.

The remote CI workflow runs the same two checks on `macos-latest`:

```txt
.github/workflows/ci.yml
```

## Release Status

- Public source repository: `https://github.com/LatticeNet/Astra`
- CI: `AstraCoreCheck` plus unsigned iOS Simulator build.
- No TestFlight or signed release artifact exists yet.
- The next release step is device-side validation: signing, iPhone install,
  live Lattice API behavior, Bark, and background refresh.
