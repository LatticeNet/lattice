# Iteration 006 - Plugin Lifecycle Registry

- **Date:** 2026-06-12
- **Phase:** B2 foundation
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice`
- **Status:** Verified

## Goal

Add a safe plugin lifecycle layer between the signed bundle loader and future
runtime execution. Operators need to see which plugins are verified, installed,
active, or disabled, but this slice must not start executing plugin code.

## Scope

- Add shared SDK model fields for plugin installation state.
- Persist verified plugin installations in the server store.
- Preserve existing lifecycle state across server restart.
- Add a `plugin:admin` API to list lifecycle state and transition status.
- Audit status changes.
- Keep local bundle paths private.

## Design

Lifecycle state is metadata-only and intentionally small:

```txt
verified -> installed -> active -> disabled -> active
                      \-> disabled
```

Server startup records only bundles that pass signature/digest validation. A
rejected bundle is audited and skipped, so it cannot enter the lifecycle store.
If a plugin already has a lifecycle record, its current status is preserved
instead of being reset to `verified`.

`GET /api/plugins/lifecycle` returns a public view with identity, capabilities,
artifact digest, availability, status, and timestamps. `bundle_path` remains
store-private and is not emitted by the API.

`POST /api/plugins/lifecycle` accepts `{id, status}` and delegates transition
validation to the store. It records `plugin.status` audit events and does not
invoke the host broker, spawn a process, load wasm, or run worker code.
Moving to `installed` or `active` also requires the plugin bundle to be present
in the current verified loader set; stale records for missing bundles can be
disabled, not activated.

## Security Notes

- Scope is `plugin:admin`, not a plugin capability. Plugins cannot manage their
  own lifecycle through the broker.
- Invalid transitions fail closed.
- `verified -> active` is rejected so review/install remains an explicit step.
- `active/disabled -> verified` is rejected so operators cannot erase runtime
  history by downgrading state.
- Missing bundles are reported as `available:false` and cannot be installed or
  activated.
- API output excludes local filesystem paths.
- Server restart does not re-enable disabled plugins.

## Verification

Targeted tests added:

- `internal/store/plugin_lifecycle_test.go`
  - validates transition rules and timestamp persistence.
  - rejects skipping install.
  - proves returned capability slices are copied and sorted.
- `internal/server/server_plugins_test.go`
  - proves the loader records only verified bundles.
  - proves rejected bundles are not lifecycle installations.
  - proves the lifecycle API hides `bundle_path`, rejects invalid transitions,
    marks missing bundles unavailable, rejects activation of unavailable
    bundles, persists valid transitions, and audits status changes.

Commands run during the slice:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -run 'TestPluginLifecycle|TestPluginInstallations' -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/server -run 'TestPluginLoaderWiredIntoServer|TestPluginLifecycleAPIListsAndTransitionsWithoutExecution' -count=1
```

Both targeted test commands passed.

Final verification:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./... -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go vet ./...
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test -race ./... -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./... -count=1
```

The first three commands ran in `lattice-server`; the last command ran in
`lattice-sdk`. All passed. The race run needed local port binding for existing
`httptest` suites.

## Review Outcome

Self-review found one pre-merge security issue: stale lifecycle records for
bundles no longer present in the verified loader set could be moved to
`installed`/`active`. The fix adds an `available` API field and rejects
install/activation unless the plugin is currently loaded. Regression coverage is
in `TestPluginLifecycleCannotActivateUnavailableBundle`.

No critical/high residual code-review or security-review findings remain in
this slice.

## Residuals

- Dashboard UI for plugin lifecycle is still pending.
- The lifecycle API is not runtime execution. A future slice must add isolated
  runtime start/stop semantics, per-plugin limits, broker-bound host calls, and
  runtime health reporting.
- Storage is still the JSON store; Phase C will move this lifecycle bucket to
  bbolt with migration.
