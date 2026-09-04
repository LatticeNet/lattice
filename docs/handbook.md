# Lattice developer handbook

The mechanics: how to build, test, tag, release, pin, debug, and report, for
every component and for both kinds of contributor, human and agent. The
doctrine lives in [PRODUCT-VISION.md](./PRODUCT-VISION.md); the design and
review process lives in
[development-workflow.md](./development-workflow.md); this file is the how.
Every command here was verified against the workflows and scripts it names.

## 1. The map

| Repo | What it is | Working branch | How it ships |
|---|---|---|---|
| `lattice` | Umbrella: doctrine, designs, iterations, handbook, `go.work`, Makefile | `integration` (default branch `main` tracks it) | docs only |
| `lattice-sdk` | Shared Go models and the plugin protocol contract | `integration` | git tag `vX.Y.Z`, consumed by go.mod |
| `lattice-server` | Control plane server, plugin host, signer tooling | `integration` | container image `ghcr.io/latticenet/lattice-server:alpha-0.2.2aN` on tag push |
| `lattice-dashboard` | Vue 3 operator console | `integration` | never ships alone; baked into the server image via `dashboard.ref` |
| `lattice-node-agent` | Outbound-only host agent | `integration` | GitHub release with binaries on tag `v*` |
| `lattice-plugin-{vpn-core,sub-store,netguard,wireguard}` | The four official plugins | `integration` | manual signed-bundle ceremony (section 6.3) |
| `lattice-plugin-bridge` | npm package `@latticenet/plugin-bridge` | `integration` | publish workflow on tag `v*` (prerelease under dist-tag `alpha`) |
| `lattice-plugin-index` | Signed, read-only plugin catalogue (`plugins.json`) | `main` | data merged to the branch; index is still `status: draft` |
| `lattice-plugin-template` | Plugin starter kit and `pluginpack` | `integration` | tagged examples |
| `latticenet.github.io` | Public site and docs (VitePress) | `main` | GitHub Pages on push |
| `Astra` | iOS companion | `main` | manual device-side steps; no tags yet |

## 2. Branch discipline

Branch from `origin/integration`, open a PR to `integration`, wait for CI,
then a maintainer merges locally with `merge --no-ff` and pushes directly.
GitHub-side merge commits are disallowed. Never commit to `integration`
directly. The umbrella `main` is only ever fast-forwarded to `integration`.

## 3. Building and testing each component

Toolchain: server, node-agent, and sdk pin `toolchain go1.26.6` in go.mod.
Plugin release builds are pinned to `golang:1.26.4-bookworm` and
`node:22-bookworm` containers because the bundle digest must reproduce
byte for byte; do not bump a plugin's Go pin casually, that changes every
digest. The dashboard uses pnpm (corepack, `packageManager: pnpm@10.33.0`);
plugin UIs use npm. Do not mix them up, and never run prettier in the
dashboard or plugin UI repos (no config exists; it reflows everything).

Umbrella (drives sdk, server, node-agent, plugin-template via `go.work`):

```sh
make test            # go test across the workspace
make build
make check-clean     # sibling checkouts must be porcelain-clean
make run-server      # local server with LATTICE_WEB_ROOT=../lattice-dashboard
make run-agent
```

Server:

```sh
gofmt -l .                                   # CI stops here if non-empty
sh scripts/check-docker-defaults.sh
go vet ./...
go test -race -cover -timeout 25m ./...
```

The `-timeout 25m` is load-bearing: `internal/server` exceeds the ten-minute
default under `-race` and the aggregate timeout dump looks like a deadlock.
Judge races by `grep -c 'DATA RACE'`, not by the exit code alone.

Dashboard:

```sh
pnpm install --frozen-lockfile
pnpm type-check          # vue-tsc --build
pnpm test:navigation     # node:test over the model/router test files
pnpm build
pnpm dev                 # proxies /api to a locally running server
```

There is no mock host for the dashboard: `pnpm dev` expects a real local
server (`make run-server` in the umbrella repo).

Node agent:

```sh
gofmt -l .
sh scripts/check-release-workflow.sh     # guards the release workflow itself
sh scripts/test-install-integrity.sh     # guards the install script
go vet ./...
go test -race -cover ./...
```

SDK: `gofmt -l . && go vet ./... && go test -race -cover ./...`

Plugins (backend and packer):

```sh
cd system-go && go test -race ./...          # sub-store needs -timeout 25m
cd ../tools/pluginpack && go test -race ./...
node --test tools/substore-core/build.test.mjs   # sub-store only
```

Plugin UIs (npm; `GITHUB_TOKEN` must be set to fetch `@latticenet` packages
from GitHub Packages):

```sh
cd ui && npm ci && npm test && npm run typecheck && npm run build && npm run verify:build
```

`verify:build` runs the CSP scanner (`scripts/scan-build.mjs`); a build that
fails it will be rejected by the host sandbox, so treat it as a gate, not a
lint. For UI work without a server, sub-store has the full fake-host harness:
`npm run dev` opens `/dev.html` against `ui/dev/fakeHost.ts` with fixtures and
a deliberately delayed handshake (it has caught real production bugs).
vpn-core and wireguard carry `ui/dev/host.ts` fixtures but no dev script;
netguard and the template have none yet.

Site: `npm ci && npm test` (content checks plus VitePress build), and
`npm run check:pins` verifies the version matrix against live GitHub releases.
Astra: `swift run AstraCoreCheck`, then an unsigned simulator build.

## 4. Versions and tags

| Repo | Convention | Example |
|---|---|---|
| lattice-server | `alpha-0.2.2aN`, one train, only the trailing number moves | `alpha-0.2.2a77` |
| lattice-dashboard | `v0.2.2-alpha.N` tags exist, but the shipping pin is `dashboard.ref` | ref `874d37c1` |
| lattice-node-agent | semver, prerelease suffixes `-alpha.N` / `-beta.N` / `-rc.N` | `v0.3.8` |
| lattice-sdk | plain `vX.Y.Z`; the tag is the release | `v0.2.23` |
| plugins, bridge, index, template | `vX.Y.Z-alpha.N` prereleases | `v0.13.0-alpha.27` |

Rules that do not bend:

- Alpha is the default state of everything during exploration. A green build
  is never, by itself, the decision to ship a stable version.
- Stable-looking `vX.Y.Z` tags require an explicit operator decision, with:
  CI green including race suites; no open known-issue against that component
  at severity worth blocking; compatibility metadata updated (agent floors,
  SDK pins); docs and site updated in the same wave.
- GitHub prereleases always carry `--prerelease --latest=false`. `Latest`
  points at the newest stable only, and server-side `target_version=latest`
  resolves stable only; prerelease rollouts need an explicit version string
  in a reviewed plan.
- Every artifact that reaches production has a pushed tag and a published
  release first. Hand-installed bundles without tags are how production once
  ran three plugin versions that existed nowhere in source control. Do not
  add a fourth.
- The node agent embeds its compatibility floors at release time and exposes
  them via `lattice-agent -compat-json`; update the floors when protocol
  assumptions change.

## 5. The dependency pin graph

Who pins whom, and where. The full snapshot lives in
[contracts/release-pin-graph.md](./contracts/release-pin-graph.md)
(mechanisms current; the values in that snapshot are historical).

- Server to SDK: two pins that must agree, `go.mod` (`require ...lattice-sdk
  vX.Y.Z`) and `sdk.ref` (a full SHA). The container build lays a Go
  workspace over the `sdk.ref` checkout, so inside the image `sdk.ref` wins;
  `refs_test.go` fails when the two drift.
- Server to dashboard: `dashboard.ref` (a full SHA on dashboard
  `integration`). The image build checks the dashboard out at that ref and
  bakes the built assets in; deployment is complete only when About shows the
  matching server and dashboard pair.
- Node agent to SDK: `go.mod`.
- Plugin CI to server: `LATTICE_CHECK_REF` in each plugin `ci.yml`, a Go
  pseudo-version of a released server commit, used to run
  `lattice-plugin-manifest-check`. The pseudo-version is authoritative; the
  inline comments beside it have a history of going stale. When a plugin
  needs a capability the pinned validator does not know, release the server
  first, then move the pin.
- Plugin internal lockstep: `manifest.json` version, `ui/package.json`
  version, and the Go version constant move together via `tools/bump.sh`.
- Plugin index: each `plugins.json` release entry is rebuilt from the
  downloaded GitHub release assets (manifest URL, artifact URL, sha256,
  signature), never string-edited from the previous entry.

## 6. Release ceremonies

### 6.1 Server image

Verify `dashboard.ref` is the dashboard commit you mean to ship and
`sdk.ref` agrees with `go.mod`; push an annotated `alpha-0.2.2aN` tag; the
container workflow builds the multi-arch image in about 12 to 14 minutes;
deploy; confirm About shows the pair; update the operator program log and the
site matrix in the same sitting.

### 6.2 Node agent

Push a `v*` tag. The release workflow validates the tag shape, builds the
four-way matrix, smoke-checks `-version` and `-compat-json`, attests
provenance, and publishes the release with prerelease flags when the tag has
a prerelease suffix.

### 6.3 Plugins (signed-bundle ceremony)

The operative runbook is the operator's `RELEASE-RUNBOOK.md` section 4.3; the
tool-enforced constraints are:

1. Server first: the manifest checker of the pinned server must know every
   capability you declare; release the server, then move `LATTICE_CHECK_REF`.
2. Rebuild from the merged commit with `git archive` into the pinned
   containers (`node:22-bookworm` for the UI, `golang:1.26.4-bookworm` for
   the binaries), pack with `pluginpack`, and require the digest to equal the
   CI digest and the manifest digest exactly. Never reconcile a mismatch with
   `-update-digest`; a mismatch means the toolchain or tree is wrong.
3. Sign with `pluginsign` from the released server tag that production runs,
   never a local checkout. The 32-byte Ed25519 seed lives outside every repo
   (`~/.config/lattice/plugin-signing/`, mode 0600) and stays with the human
   operator. The resulting diff touches `signature_ed25519` and nothing else.
4. Tag, then `gh release create` with `--verify-tag --prerelease
   --latest=false` carrying exactly two assets: `manifest.json` and the
   artifact. Re-download and verify the sha256 before touching production.
5. Update `plugins.json` from the downloaded assets, then install on the host
   per runbook section 5.2: stage outside `plugins/`, back up, swap
   atomically, restart, and accept only `plugin loader: 4 loaded, 0
   rejected`.

Signing, publishing, and production installs stay with the human operator.
Agents prepare everything up to the seed and stop.

### 6.3.1 The reopen-on-change contract (plugin repos)

A signed release commit at a plugin repo's integration tip freezes the tree:
manifest version, the Go `pluginVersion` constant, `ui/package.json`, the
bundle digest, and the signature all agree, and CI proves it. The FIRST code
change after that must reopen development in the same commit, or CI fails by
design:

1. `sh tools/bump.sh <next-version>` (syncs manifest, package.json, and the
   Go constant).
2. Blank `signature_ed25519` in the manifest: a populated signature on a tree
   you just changed means you are about to sign something you did not build.
3. Put the CI-canonical bundle digest into `bundle.digest_sha256` and into
   `SIGNING-HANDOFF.md` (exactly one digest there; the version-contract tests
   enforce all of this). The digest cannot be left empty: the released-server
   manifest check refuses that too.

On the digest: CI is the authority. A darwin build does not reproduce it, and
neither does an arm64 Linux container; the practical loop is to push, read
the canonical digest from the failed "package twice and compare bytes" step,
adopt it, and push again. Subsequent commits that change built content repeat
step 3 only.

### 6.4 Site

After any release wave: update `docs/.vitepress/data/versions.ts`, run
`npm run check:pins`, push. The Pages build runs the pin check with the
workflow token, so a stale `verify`-marked pin fails the deploy rather than
quietly misinforming readers.

## 7. Self-help before reporting

- Server race suite "deadlocks": you forgot `-timeout 25m`. Grep for
  `DATA RACE` before believing a timeout dump.
- Plugin UI `npm ci` returns 401: `GITHUB_TOKEN` is missing; `@latticenet`
  packages come from GitHub Packages.
- `pluginpack` digest differs from CI: wrong container, dirty tree, or a
  darwin build (darwin does not reproduce CI digests). Stop; do not
  `-update-digest`.
- Manifest check fails on a new capability: your `LATTICE_CHECK_REF` server
  predates it; the fix is a server release, not a looser check.
- Dashboard UI bugs: reproduce with `pnpm dev` against `make run-server`;
  router and model regressions usually surface in `pnpm test:navigation`.
- Plugin UI without infrastructure: use the sub-store fake host as the
  reference harness.
- Production state questions: `/api/version`, About, the audit log, and the
  loader line in `docker compose logs` answer most of them with evidence.

## 8. Reporting and contributing

Questions, proposals, and open-ended discussion go to GitHub Discussions on
`LatticeNet/lattice`: that is the project forum. Defects go to Issues on the
repo that owns the code, carrying the version or tag, a minimal repro,
expected versus actual, and evidence (correlation id, audit entry, loader
line, screenshot). If you can fix it, the PR flow is section 2; commits
follow [development-workflow.md](./development-workflow.md) section 10 (the
first line says why, trailers carry constraints and test evidence). Suspected
vulnerabilities go through GitHub private security advisories on the affected
repo, never public issues.

## 9. Known issues snapshot (2026-09-01)

The live ledger is the operator's program log; this snapshot exists so
contributors do not rediscover known problems: navigation away from the
approvals and tasks views can stall for seconds without feedback; tasks can
stick in Running after multi-day agent gaps; node status vocabulary differs
between Overview and the Nodes list; some views render full 64-hex digests as
link text; routine metadata approvals lack risk-tiered auto-approval; three
production plugin builds (vpn-core 0.8.0-alpha.15, netguard 0.1.0-alpha.14,
wireguard 0.1.0-alpha.13) predate their tags and releases, pending a
re-tagging ceremony; the plugin index is still `draft` and behind the
deployed versions.
