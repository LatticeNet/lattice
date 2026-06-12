# Iteration 008 - Plugin Runtime Manager Skeleton

- **Date:** 2026-06-12
- **Phase:** B2 runtime foundation
- **Repos:** `lattice-server`, `lattice-dashboard`, `lattice`
- **Status:** Verified

## Goal

Connect plugin lifecycle `active` / `disabled` states to an explicit runtime
health layer without executing plugin artifacts. This gives future system/wasm
runners a safe server-owned entrypoint and gives operators a truthful runtime
signal in the dashboard.

## Scope

- Add `plugin.RuntimeManager` in `lattice-server/internal/plugin`.
- `Start` validates a verified `plugin.Loaded`, creates a capability-scoped
  broker, and records runtime state as `armed`.
- `Stop` clears the broker handle and records runtime state as `stopped`.
- Existing `active` plugins are armed again on server startup when the bundle is
  still verified and loaded.
- `/api/plugins/lifecycle` includes a public `runtime` health view.
- The dashboard plugin panel displays `runtime: armed|stopped|failed`.

## Non-Goals

- No subprocess execution.
- No wasm loading.
- No artifact invocation.
- No long-running worker loop.
- No plugin-owned direct access to store, notify, HTTP, or logs.

## Design

The runtime manager keeps an in-memory map:

```txt
plugin_id -> { broker, runtime_status }
```

The `broker` is not returned by any API and is never stored on disk. It is the
only handle a future concrete runner should receive for host calls.

Runtime states:

- `armed` - the verified plugin has a broker and is ready for a future concrete
  runner, but artifact execution is not enabled in this build.
- `stopped` - the in-memory runtime handle has been cleared.
- `failed` - reserved for failed arming/execution paths.

Lifecycle integration:

- `installed -> active` first passes the store transition, then arms the runtime
  broker. If arming fails, the server stops the runtime, moves the lifecycle
  back to `disabled`, records a denied `plugin.runtime` audit event, and returns
  an error.
- `active -> disabled` passes the store transition and stops the runtime broker.
- Startup re-arms stored `active` plugins only after loader verification. Missing
  bundles remain unavailable and are not armed.

## Security Notes

- `active` is **not** process health. It means the lifecycle requested runtime
  activation; `runtime.state` is the current in-memory runtime health.
- Runtime status omits `bundle_path` and the broker.
- The server remains the source of truth for authorization: dashboard action
  visibility is only an affordance.
- Future concrete runners must depend on `RuntimeManager` and `plugin.Broker`.
  They must not receive raw store, notification, outbound HTTP, or logger
  handles.

## Verification

Targeted tests added:

- `internal/plugin/runtime_test.go`
  - arms a loaded plugin without exposing bundle path.
  - rejects invalid loaded manifests.
  - proves snapshot copy semantics and stopped state.
- `internal/server/server_plugins_test.go`
  - activation returns `runtime.state=armed`.
  - disabling returns `runtime.state=stopped`.
  - existing active plugin is armed during startup only after loader verification.
  - runtime state changes emit `plugin.runtime` audit events for armed and
    stopped states.
- `lattice-dashboard/assets/plugin-lifecycle.test.mjs`
  - renders runtime labels for `armed`, `stopped`, and `failed`.

Commands run:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/plugin -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/server -run 'TestPlugin' -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./... -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go vet ./...
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test -race ./... -count=1
npm test
npm run build
```

All passed. The race run needed local port binding for existing `httptest`
suites.

## Residuals

- Concrete system/wasm runners are still pending.
- Runtime rate limits, output/log caps, cancellation, and health depth are still
  pending.
- Dashboard still has no runtime audit drill-through.
- The bbolt migration should eventually persist lifecycle state and leave
  runtime state process-local.
