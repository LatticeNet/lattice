# Iteration 059 - Public ecosystem foundation

- **Date:** 2026-06-15
- **Repos:** `lattice`, `lattice-server`, `.github`, local new repos
  `latticenet.github.io` and `lattice-plugin-index`
- **Status:** Implemented locally; existing repos committed/pushed; new remote
  repo creation requires refreshed GitHub CLI auth.

## Goal

Turn Lattice from a set of working repos into an easier public project surface:

1. Docker/Compose server deployment.
2. GitHub Pages website scaffold.
3. Static plugin marketplace index foundation.
4. Real plugin runner design gates.

## What landed

### Docker server

- `lattice-server/Dockerfile`
  - BuildKit named contexts for `lattice-sdk` and `lattice-dashboard`.
  - Multi-arch aware `TARGETOS/TARGETARCH`.
  - Non-root final image.
  - Dashboard embedded at `/app/dashboard`.
  - Data and plugin volumes at `/var/lib/lattice` and `/plugins`.
- `lattice-server/.github/workflows/container.yml`
  - GHCR build/push on main/tags.
  - PRs build without push.
- `lattice/compose/docker-compose.yml`
  - localhost-only bind by default.
  - persistent `data` and read-only `plugins` mount.
  - healthcheck through `/api/health`.
- `lattice/docs/tutorials/docker-server.md`
  - documents Docker as server path and systemd as node-agent path.

### GitHub Pages site

Local repo scaffold:

```txt
Lattice/latticenet.github.io
```

Includes:

- VitePress config;
- Pages workflow;
- homepage;
- guide/security/plugins/ecosystem pages;
- docs that link back to canonical `lattice/docs`.

### Plugin index

Local repo scaffold:

```txt
Lattice/lattice-plugin-index
```

Includes:

- `plugins.json` empty draft index;
- example index;
- dependency-free validator;
- CI workflow;
- format and security docs.

No fake official signatures were created. The index is a foundation until a
real long-lived signing key exists.

### Real plugin runner design

Added `designs/design-08-real-plugin-runners.md`:

- worker template runner first;
- constrained system runner second;
- wasm runner only after ADR;
- marketplace install separate from activation;
- host-risk plugins still require trusted signatures;
- tests required before leaving noop default.

## Verification

Expected checks:

```sh
go test ./...
go vet ./...
npm run check
node scripts/validate-index.mjs plugins.json
node scripts/validate-index.mjs examples/plugins.example.json
docker build ...
```

Local npm registry access was unavailable in the sandbox when generating a
VitePress lockfile (`registry.npmjs.org` DNS failure). The Pages workflow uses
`npm install` so GitHub Actions can resolve dependencies in its networked
environment.

## Remote creation blocker

`gh auth status` reported an invalid token for the logged-in account. Existing
repos can still be pushed over git SSH, but creating new GitHub repositories
(`LatticeNet/latticenet.github.io`, `LatticeNet/lattice-plugin-index`) requires
refreshing GitHub CLI auth.

After re-auth:

```sh
gh repo create LatticeNet/latticenet.github.io --public --source Lattice/latticenet.github.io --remote origin --push
gh repo create LatticeNet/lattice-plugin-index --public --source Lattice/lattice-plugin-index --remote origin --push
```

Then enable GitHub Pages for `latticenet.github.io` using the repository's Pages
workflow.

## Residuals

- Docker image CI must be observed after push.
- Real GitHub Pages deployment requires the new repo to exist.
- Plugin index remote install is not implemented.
- Plugin runner artifact execution remains intentionally disabled.
