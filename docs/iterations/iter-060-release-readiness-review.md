# Iteration 060 - Release Readiness Review

- **Status:** Implemented locally; remote push pending network/GitHub auth availability (2026-06-15)
- **Scope:** GitHub Pages workflow, SDK contract release hygiene, agent update safety review, plugin marketplace docs, test stability.

## Goals

Prepare the public LatticeNet ecosystem for continued maintenance:

- keep the GitHub Pages site deployable;
- ensure server/agent builds do not depend on an untagged SDK contract;
- review the new server-controlled agent update path with security first;
- document plugin storage and marketplace boundaries accurately;
- keep local tests stable in restricted environments.

## Changes

### GitHub Pages

The `latticenet.github.io` workflow no longer enables `actions/setup-node`
`cache: npm` without a lockfile. It now runs:

```sh
npm install --no-audit --no-fund
npm run docs:build
```

This is a restore-service fix for the current site repository. When npm network
access is available, generate and commit `package-lock.json`, then switch the
workflow to `npm ci` and re-enable cache.

### SDK contract versioning

`lattice-sdk` has a local `v0.2.0` tag for the current shared contract set:

- HostFacts and machine inventory;
- nft baseline inputs and NetPolicy graph;
- self-host DNS intent;
- proxy-core/subscription contracts;
- log ingestion contracts;
- GeoRouting;
- agent update policy.

`lattice-server` and `lattice-node-agent` now target `github.com/LatticeNet/lattice-sdk v0.2.0`.
The workspace has an explicit versioned replace:

```txt
replace github.com/LatticeNet/lattice-sdk v0.2.0 => ../lattice-sdk
```

This keeps local multi-repo development offline-safe while preserving standalone
module semantics once the SDK tag is pushed.

The `lattice-server` and `lattice-node-agent` CI workflows now add the same
versioned replace after checking out `lattice-sdk`, and the server Dockerfile
does the same after BuildKit loads the named SDK context. CI and container
builds therefore use the reviewed sibling checkout instead of depending on Go
proxy freshness.

### Agent update safety

The server-controlled agent update path was reviewed around the high-risk
execution boundary:

- policy requires `node:admin`;
- manual planning requires same-node `network:plan`;
- applying still goes through the existing approval path and `network:apply`;
- update binary URL is HTTPS-only, no userinfo, no fragment;
- SHA-256 digest is pinned and verified on-node before install;
- install path must be absolute, must not contain unsafe characters or `..`,
  and must end with `/lattice-agent`;
- stale approvals are rejected when the policy tuple changes;
- task result closes the approval as applied/rejected and records audit.

One hardening change was made: the generated script no longer uses nested
`sh -c` command strings for the fallback delayed restart path. It now runs a
background subshell with `systemctl restart "$SERVICE"` directly, reducing shell
injection risk if service-name validation changes in the future.

### Plugin marketplace docs

The plugin tutorial and website now state explicitly:

- plugin bundle bytes live under `LATTICE_PLUGIN_DIR`;
- server state stores lifecycle metadata, not artifact bytes;
- plugin data should use `plugin:<id>` KV namespaces;
- the recommended Docker plugin mount is read-only;
- `lattice-plugin-index` is a static signed-index foundation, not remote install
  or artifact execution;
- dashboard marketplace display must not bypass signature, capability, lifecycle,
  or runner sandbox checks.

### Test stability

The node-agent proxy usage redirect test now creates its listener explicitly and
skips only that redirect test when a sandbox forbids local TCP listeners. This
keeps normal CI coverage while avoiding false failures in restricted local
review environments.

## Verification

Commands run locally with a repository-local Go build cache:

```sh
GOCACHE=$PWD/.cache/go-build go test ./...                         # lattice-sdk
GOWORK=$PWD/go.work GOCACHE=$PWD/.cache/go-build go test ./...      # lattice-server
GOWORK=$PWD/go.work GOCACHE=$PWD/.cache/go-build go test ./...      # lattice-node-agent
npm test                                                            # lattice-dashboard
npm test                                                            # lattice-plugin-index
```

Results:

- `lattice-sdk`: pass
- `lattice-server`: pass
- `lattice-node-agent`: pass
- `lattice-dashboard`: pass, 88 tests
- `lattice-plugin-index`: pass

## Pending Remote Operations

The local environment could not resolve `github.com`/`api.github.com` during
this iteration, and `gh auth status` still reported the default account token as
invalid. Required follow-up once network/auth is healthy:

1. Push `lattice-sdk` tag `v0.2.0`.
2. Push dependent commits in `lattice-server`, `lattice-node-agent`, `lattice`,
   `lattice-plugin-index`, and `latticenet.github.io`.
3. Re-run GitHub Actions for the Pages site and container workflow.
4. When npm registry access is available, add `package-lock.json` to
   `latticenet.github.io` and switch the Pages workflow to `npm ci` with cache.

## Review Notes

No new remote install path or plugin artifact execution should be added before
runner sandboxing is designed and tested. Keep the next public milestone focused
on reliable packaging, signed release artifacts, and clear operator upgrade
flows before expanding marketplace automation.
