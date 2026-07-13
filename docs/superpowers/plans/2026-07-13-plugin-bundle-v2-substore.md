# Plugin Bundle V2 and Sub-Store Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a signed self-contained plugin bundle format, sandboxed Extensions UI host, and the first fully independent Sub-Store plugin without dashboard builtin UI or core REST fallback.

**Architecture:** The server verifies and extracts a deterministic v2 archive, serves active plugin assets through an authenticated route, and brokers sandbox UI calls through the existing audited plugin gateway. The dashboard mounts a generic opaque-origin iframe and has no Sub-Store component mapping. Sub-Store owns its Vue UI and runtime `call` implementation in its repository.

**Tech Stack:** Go 1.26, Vue 3, TypeScript, Vite, Node test runner, Ed25519/SHA-256, deterministic `tar.gz`, sandboxed iframe, `postMessage`, and existing Lattice RPC/RBAC/audit infrastructure.

---

## Delivery Boundary

This plan implements the reusable host contract and one complete plugin pilot.
NetGuard, WireGuard, and VPN Core remain on their current v1 production path
until separate parity plans migrate their engines. No new builtin view is added.

## File Map

### `lattice-server`

- Create `internal/plugin/manifest_v2.go` and tests for v2 contracts.
- Create `internal/plugin/bundle_v2.go` and tests for bounded extraction.
- Modify `internal/plugin/plugin.go`, `contributions.go`, `loader.go`, and
  `system_runner.go` for v1/v2 compatibility.
- Create `internal/server/server_plugin_assets.go` and tests for active-only
  authenticated asset serving.
- Modify `internal/server/server_plugin_invoke.go` for safe UI metadata and typed
  method scopes/effects.
- Modify `internal/server/server.go` and `cmd/lattice-server/main.go` for bundle
  cache configuration and routing.

### `lattice-dashboard`

- Create `PluginFrameHost.vue`, `pluginBridgeModel.ts`, and bridge tests.
- Modify `PluginView.vue`, `usePluginContributions.ts`, and API types for sandbox
  views while preserving v1 plugins.
- Remove only the Sub-Store builtin mapping, page, fallback, and legacy redirect
  after the v2 pilot reaches parity.

### Plugin repositories

- `lattice-plugin-template`: add the reference Vue UI, bridge client,
  deterministic packer, CI, and Bundle v2 manifest.
- `lattice-plugin-sub-store`: own its full UI and runtime call behavior.
- `lattice-plugin-index`: add v2 metadata and stable/alpha channels.

## Task 1: Manifest V2 and Typed Interface Contract

**Files:**
- Create: `lattice-server/internal/plugin/manifest_v2.go`
- Create: `lattice-server/internal/plugin/manifest_v2_test.go`
- Modify: `lattice-server/internal/plugin/plugin.go`
- Modify: `lattice-server/internal/plugin/contributions.go`

- [ ] **Step 1: Write failing v2 manifest tests**

Add a valid fixture:

```go
Manifest{
    Schema:       ManifestSchemaV2,
    ID:           "latticenet.example",
    Name:         "Example",
    Type:         TypeSystem,
    Version:      "0.2.1-alpha.1",
    Publisher:    "latticenet",
    Capabilities: []string{"kv:read"},
    Bundle: &BundleSpec{Format: BundleFormatTarGzip, DigestSHA256: strings.Repeat("a", 64)},
    Runtime: &RuntimeSpec{
        Protocol: "stdio-json-v1",
        Entrypoints: map[string]string{"linux/amd64": "bin/linux-amd64/plugin"},
    },
    UIRuntime: &UIRuntimeSpec{Mode: "sandbox", Entrypoint: "ui/index.html", BridgeVersion: "1"},
    Compatibility: &CompatibilitySpec{Server: ">=0.2.1", DashboardHost: ">=1", RuntimeProtocol: ">=1"},
}
```

Reject legacy entrypoint/digest fields, missing platform entrypoints,
absolute/traversing paths, builtin views, unknown effects, write methods without
method scopes, and sandbox UI without `ui_runtime`. Verify every v2 field mutates
`SigningPayload` while existing v1 fixtures retain byte parity.

- [ ] **Step 2: Run the focused test and observe failure**

```bash
go test ./internal/plugin -run 'TestManifestV2|TestSigningPayloadV2' -count=1
```

Expected: compile failure because v2 types and fields do not exist.

- [ ] **Step 3: Implement typed fields and compatibility decoding**

Define:

```go
const (
    ManifestSchemaV2    = "lattice.plugin.manifest.v2"
    BundleFormatTarGzip = "tar+gzip"
)

type BundleSpec struct {
    Format       string `json:"format"`
    DigestSHA256 string `json:"digest_sha256"`
}

type RuntimeSpec struct {
    Protocol    string            `json:"protocol"`
    Entrypoints map[string]string `json:"entrypoints"`
}

type UIRuntimeSpec struct {
    Mode          string `json:"mode"`
    Entrypoint    string `json:"entrypoint"`
    BridgeVersion string `json:"bridge_version"`
}

type InterfaceMethod struct {
    Name   string   `json:"name"`
    Effect string   `json:"effect"`
    Scopes []string `json:"scopes,omitempty"`
}
```

Add `CompatibilitySpec` and a custom `InterfaceMethods` decoder accepting v1
strings and v2 objects. V1 strings normalize to `Effect: "read"` with service
scope fallback. V2 requires method scopes for `write` and `plan`. Branch signing
by schema; omit only the signature from the v2 typed payload.

- [ ] **Step 4: Run plugin package tests**

```bash
go test -race ./internal/plugin
```

Expected: existing v1 and new v2 tests pass.

- [ ] **Step 5: Commit the manifest contract**

Use a Lore commit recording v1 signature parity, method-level scopes, and v2
builtin rejection.

## Task 2: Safe Bundle Extraction and Runtime Selection

**Files:**
- Create: `lattice-server/internal/plugin/bundle_v2.go`
- Create: `lattice-server/internal/plugin/bundle_v2_test.go`
- Modify: `lattice-server/internal/plugin/loader.go`
- Modify: `lattice-server/internal/plugin/system_runner.go`
- Modify: `lattice-server/internal/plugin/system_runner_test.go`

- [ ] **Step 1: Write archive attack tests**

Build in-memory tar.gz fixtures and reject:

```text
../escape
/absolute
a/../../escape
a\windows
duplicate normalized paths
symlink or hardlink
device or FIFO
more than 2048 files
one file above 32 MiB
total expansion above 256 MiB
path deeper than 16 components
```

Prove the compressed digest is checked before gzip parsing by supplying invalid
gzip bytes with a wrong digest and expecting `digest mismatch`.

- [ ] **Step 2: Run focused tests and observe failure**

```bash
go test ./internal/plugin -run 'TestExtractBundleV2|TestLoaderV2|TestSystemRunnerV2' -count=1
```

Expected: compile failure because bundle extraction does not exist.

- [ ] **Step 3: Implement bounded extraction**

```go
type BundleLimits struct {
    MaxCompressedBytes int64
    MaxExpandedBytes   int64
    MaxFileBytes       int64
    MaxFiles           int
    MaxPathBytes       int
    MaxDepth           int
}
```

`ExtractBundleV2` streams through gzip/tar readers, rejects non-regular entries,
writes a fresh staging directory, fsyncs, and atomically renames to:

```text
<cache>/<plugin-id>/<version>/<artifact-digest>/
```

Return root, selected runtime path, UI root/entry, inventory, and digest. Never
join an unvalidated request path to the filesystem.

- [ ] **Step 4: Teach Loader and SystemRunner both formats**

Add cache/platform options to `Loader`. V1 keeps fixed `artifact`; v2 requires a
cache, extracts the archive, selects `GOOS/GOARCH`, and records staged paths.
`SystemRunner.Start` re-verifies archive digest and runtime file metadata.

- [ ] **Step 5: Run race tests and commit**

```bash
go test -race ./internal/plugin
```

Expected: all loader/runner tests pass with no extraction residue. Commit with
Lore trailers listing archive limits and prohibited entry types.

## Task 3: Active-Only Plugin Asset Server

**Files:**
- Create: `lattice-server/internal/server/server_plugin_assets.go`
- Create: `lattice-server/internal/server/server_plugin_assets_test.go`
- Modify: `lattice-server/internal/server/server.go`
- Modify: `lattice-server/cmd/lattice-server/main.go`
- Modify: `lattice-server/internal/server/server_security_test.go`

- [ ] **Step 1: Write failing asset security tests**

Cover authenticated active HTML, inactive/disabled/stale digest `404`, unknown
file and traversal `404`, non-GET `405`, exact MIME, `nosniff`, hashed-asset
cache, no-cache HTML, route CSP with `connect-src 'none'` and
`frame-ancestors 'self'`, and unchanged dashboard `X-Frame-Options: DENY`.

- [ ] **Step 2: Run focused tests and observe failure**

```bash
go test ./internal/server -run 'TestPluginAsset|TestSecurityHeaders' -count=1
```

Expected: asset route is not registered.

- [ ] **Step 3: Implement handler and cache configuration**

Register:

```go
mux.HandleFunc("/api/plugins/assets/", s.withAuth("", s.handlePluginAsset))
```

Resolve plugin/digest against loaded metadata, require `active`, validate path
against inventory, and use `http.ServeContent`. Override X-Frame-Options to
`SAMEORIGIN` only for signed HTML. Add `PluginBundleCacheDir` and
`LATTICE_PLUGIN_BUNDLE_CACHE_DIR`; never write into plugin source directories.

- [ ] **Step 4: Run server tests and commit**

```bash
go test -race ./internal/server ./internal/plugin
```

Expected: tests pass and global static headers are unchanged. Commit with a
directive forbidding mutable static storage for plugin assets.

## Task 4: Typed Gateway Metadata and Effect Enforcement

**Files:**
- Modify: `lattice-server/internal/server/server_plugin_invoke.go`
- Modify: `lattice-server/internal/server/server_plugin_invoke_test.go`
- Modify: `lattice-server/internal/server/server.go`

- [ ] **Step 1: Write failing contribution and call tests**

Assert active v2 contributions expose only derived asset digest, safe UI runtime,
nav/views/interfaces, and no filesystem/signature data. Test independent read and
write scopes, inactive/undeclared denial, and no v2 in-core RPC fallback.

- [ ] **Step 2: Run and observe failure**

```bash
go test ./internal/server -run 'TestPluginContributionsV2|TestPluginCallV2' -count=1
```

- [ ] **Step 3: Implement safe metadata and v2 dispatch**

```go
type pluginUIRuntimeView struct {
    Mode          string `json:"mode"`
    EntryURL      string `json:"entry_url"`
    BridgeVersion string `json:"bridge_version"`
    AssetDigest   string `json:"asset_digest"`
}
```

Derive URL from validated server values. Resolve scopes from exact v2 methods;
service fallback is v1-only. Route v2 services directly to runtime `call` and
retain in-core-first behavior only for v1.

- [ ] **Step 4: Run and commit**

```bash
go test -race ./internal/server ./internal/plugin
```

Record the no-in-core-fallback v2 invariant in the Lore directive.

## Task 5: Dashboard Sandbox Bridge

**Files:**
- Create: `lattice-dashboard/src/views/platform/pluginBridgeModel.ts`
- Create: `lattice-dashboard/src/views/platform/__tests__/pluginBridgeModel.test.ts`
- Create: `lattice-dashboard/src/views/platform/PluginFrameHost.vue`
- Modify: `lattice-dashboard/src/views/platform/PluginView.vue`
- Modify: `lattice-dashboard/src/composables/usePluginContributions.ts`
- Modify: `lattice-dashboard/src/lib/api/types.ts`

- [ ] **Step 1: Write failing bridge tests**

Use limits:

```ts
const limits = {
  maxPayloadBytes: 256 * 1024,
  maxResultBytes: 1024 * 1024,
  maxInflight: 8,
  timeoutMs: 15_000,
  callsPerMinute: 120,
};
```

Reject wrong source/nonce, duplicate request IDs, undeclared methods, oversized
payload, ninth concurrent call, exceeded rate, late result after dispose, and
calls after inactive transition. Cancellation releases one slot exactly once.

- [ ] **Step 2: Run and observe failure**

```bash
./node_modules/.bin/tsx --test src/views/platform/__tests__/pluginBridgeModel.test.ts
```

Expected: module-not-found failure.

- [ ] **Step 3: Implement pure bridge model and frame host**

Export strict message parsers, UTF-8 JSON byte measurement, request registry,
rate accounting, cancellation, and terminal `dispose()`. Generate a nonce with
`crypto.getRandomValues`; mount exactly:

```html
<iframe sandbox="allow-scripts" referrerpolicy="no-referrer"></iframe>
```

Validate `event.source` plus nonce before calling `api.plugins.call` with an
AbortSignal. Send structured results only. Dispose on route change, plugin
disappearance, and unmount.

- [ ] **Step 4: Route sandbox views with v1 compatibility**

Add `sandbox` to allowed kinds. Use `PluginFrameHost` for v2 and retain existing
declarative/builtin rendering for unmigrated plugins. Remove only
`proxy.substore` during the pilot.

- [ ] **Step 5: Verify and commit**

```bash
./node_modules/.bin/tsx --test src/views/platform/__tests__/pluginBridgeModel.test.ts
./node_modules/.bin/vue-tsc --build
./node_modules/.bin/vite build
```

Record that `allow-same-origin` and direct plugin fetch are prohibited.

## Task 6: Bundle V2 Plugin Template

**Files:**
- Create: `lattice-plugin-template/ui/{package.json,package-lock.json,index.html,vite.config.ts}`
- Create: `lattice-plugin-template/ui/src/{bridge.ts,bridge.test.ts,main.ts,App.vue,styles.css}`
- Create: `lattice-plugin-template/tools/pluginpack/{go.mod,main.go,main_test.go}`
- Modify: `lattice-plugin-template/{manifest.json,README.md,SECURITY.md}`
- Modify/Create: `lattice-plugin-template/.github/workflows/ci.yml`

- [ ] **Step 1: Write packer and bridge tests first**

The packer creates the same input twice with different mtimes and asserts
identical bytes/digest, sorted paths, epoch times, normalized ownership, and
modes. Bridge tests cover nonce propagation, IDs, result/error routing,
cancellation, timeout, and dispose.

- [ ] **Step 2: Run and observe failure**

```bash
go test ./tools/pluginpack/...
npm --prefix ui test
```

- [ ] **Step 3: Implement packer and starter UI**

Use Go standard library tar/gzip/SHA-256. Use Vue 3, Vite, and Lucide; bundle all
runtime dependencies. The bridge uses only `window.parent.postMessage` and never
calls fetch, storage, cookies, or top navigation.

- [ ] **Step 4: Update manifest and CI**

Set `0.2.1-alpha.1` and v2 runtime/UI/compatibility. CI runs Go race tests, UI
test/typecheck/build, packages twice, compares digests, scans output for external
URLs/inline code, and verifies manifest/runtime/UI version parity.

- [ ] **Step 5: Verify and commit**

```bash
go test -race ./system-go/...
go test -race ./tools/pluginpack/...
npm --prefix ui ci
npm --prefix ui test
npm --prefix ui run build
```

Do not tag until the host and pilot are green.

## Task 7: Self-Contained Sub-Store Plugin

**Files:**
- Create: `lattice-plugin-sub-store/ui/{package.json,package-lock.json,index.html,vite.config.ts}`
- Create: `lattice-plugin-sub-store/ui/src/{bridge.ts,main.ts,App.vue,styles.css,subStoreModel.ts,subStoreModel.test.ts}`
- Create: `lattice-plugin-sub-store/tools/pluginpack/*`
- Modify: `lattice-plugin-sub-store/system-go/{main.go,main_test.go}`
- Modify: `lattice-plugin-sub-store/{manifest.json,README.md}`
- Create: `lattice-plugin-sub-store/.github/workflows/ci.yml`

- [ ] **Step 1: Lock runtime and UI behavior with tests**

Broker fakes prove `status` performs only guarded HTTP, `import` performs the
declared vpn-core RPC then bounded HTTP upsert, invalid URLs fail before calls,
broker errors contain no secrets, and undeclared `run` is rejected. UI tests
cover URL validation, status/import summaries, loading exclusion, and redaction.

- [ ] **Step 2: Run and observe failures**

```bash
go test ./system-go/... -count=1
npm --prefix ui test
```

- [ ] **Step 3: Refactor runtime for testable host calls**

Inject a `hostCaller`, remove `run`, cap links and responses, preserve strict URL
validation, and keep credentials out of errors. `status` and `import` remain the
only declared methods.

- [ ] **Step 4: Port the complete page into the plugin**

Own header, backend URL/collection fields, status, import action, and all
loading/error/empty/result states. Use bridge calls only; no legacy
`/api/substore/*` or direct network request.

- [ ] **Step 5: Convert, package, and verify**

Set `0.3.2-alpha.1`, v2 sandbox view, method scopes, runtime entrypoints, and
compatibility. Build amd64/arm64 binaries and UI into one deterministic artifact.

```bash
go test -race ./system-go/...
go test -race ./tools/pluginpack/...
npm --prefix ui ci
npm --prefix ui test
npm --prefix ui run build
```

- [ ] **Step 6: Commit Sub-Store alpha source**

Record removal of the REST fallback and undeclared alias.

## Task 8: Remove Core Sub-Store UI and REST Fallback

**Files:**
- Delete: `lattice-dashboard/src/views/proxy/SubStoreView.vue`
- Modify: `lattice-dashboard/src/views/platform/PluginView.vue`
- Modify: `lattice-dashboard/src/router/index.ts`
- Modify: dashboard contribution/navigation tests
- Modify/Delete: Sub-Store-specific `lattice-server` REST handlers and tests

- [ ] **Step 1: Write absence and uninstall regressions**

Prove no Sub-Store nav/API call exists when absent or disabled, direct legacy
`/proxy/substore` does not redirect, and old `/api/substore/*` returns 404 after
the runtime path is available.

- [ ] **Step 2: Run and observe legacy behavior**

Expected: tests locate the builtin component, redirect, and REST handlers.

- [ ] **Step 3: Delete only Sub-Store-specific core code**

Remove mapping, page, redirect, API wrapper, handlers, and fallback tests. Keep
generic plugin RPC/HTTP broker and vpn-core export because they are contracts.

- [ ] **Step 4: Verify and commit**

```bash
go test -race ./internal/plugin ./internal/server
./node_modules/.bin/tsx --test src/composables/__tests__/*.test.ts src/layout/__tests__/*.test.ts src/views/platform/__tests__/*.test.ts
./node_modules/.bin/vue-tsc --build
./node_modules/.bin/vite build
```

Directive: native code must not regain a Sub-Store import, route, or fallback.

## Task 9: Plugin Index V2 Alpha Channels

**Files:**
- Modify: `lattice-plugin-index/plugins.json`
- Modify: `lattice-plugin-index/scripts/{validate-index.mjs,test-validator.mjs}`
- Modify: `lattice-plugin-index/docs/{FORMAT.md,SECURITY.md}`
- Modify: `lattice-plugin-index/package.json`

- [ ] **Step 1: Write failing alpha-channel tests**

Use:

```json
{"channels":{"stable":"0.3.1","alpha":"0.3.2-alpha.1"}}
```

Reject prerelease stable, missing channel release, v2 release without bundle
format/compatibility, and conflicts. Legacy `latest` must equal stable.

- [ ] **Step 2: Run and observe failure**

```bash
npm test
```

- [ ] **Step 3: Implement validation and update Sub-Store entry**

Keep stable resolution unchanged and alpha explicit opt-in. Set package version
`0.2.1-alpha.1`; keep Sub-Store stable `0.3.1` and alpha
`0.3.2-alpha.1` without moving latest.

- [ ] **Step 4: Verify and commit**

```bash
npm test
npm run validate
```

## Task 10: Integrated Verification, Alpha Release, and Canary Deploy

**Files:**
- Modify: `lattice-server/dashboard.ref`
- Modify: production compose only after image success and backup
- Create: prerelease assets/tags through reviewed workflows or `gh`

- [ ] **Step 1: Run all local verification from clean trees**

```bash
go test -race ./...
go vet ./...
go build ./cmd/lattice-server ./cmd/pluginsign
npm test
npm run type-check
npm run build
```

Run template, Sub-Store, and Index commands from Tasks 6, 7, and 9.

- [ ] **Step 2: Perform adversarial review**

Review archive extraction, signature coverage, iframe CSP/sandbox, source/nonce,
inactive races, scopes, secrets, and fallback removal. Fix high/critical findings
and rerun affected suites.

- [ ] **Step 3: Publish prereleases without moving Latest**

```text
lattice-dashboard v0.2.2-alpha.2
lattice-plugin-template v0.2.1-alpha.1
lattice-plugin-index v0.2.1-alpha.1
lattice-plugin-sub-store v0.3.2-alpha.1
```

All use prerelease=true and make_latest=false. Verify downloaded manifest,
digest, signature, platform entries, UI assets, and compatibility.

- [ ] **Step 4: Build pinned server alpha**

Pin exact dashboard commit, tag `alpha-0.2.1a31`, wait for CI/container success,
inspect multiarch manifest, and verify embedded version metadata.

- [ ] **Step 5: Back up and deploy canary**

Back up compose, state, bundles, cache, and Sub-Store namespace. Install the v2
bundle, deploy a31, then transition Sub-Store
`verified -> installed -> active` after loader/compatibility/migration checks.

- [ ] **Step 6: Run production E2E**

Verify base UI while disabled, active Extensions nav, sandbox/CSP, status/import,
RBAC denial, disable during call, logical uninstall, reinstall with state, no
native polling, health/version/loader, and desktop/mobile screenshots plus
console/network evidence.

- [ ] **Step 7: Roll back and record checkpoint**

Restore prior image/bundles without purging data, verify base health, then restore
alpha only when rollback evidence is complete. Record commits, tags, bundle and
image digests, dashboard ref, compatibility, tests, production checks, and the
remaining three plugin migration plans.
