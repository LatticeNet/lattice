# Lattice Repository Instructions

This repository coordinates the Lattice server, dashboard, SDK, node-agent, and
plugins. During the current exploration phase, treat all work as alpha unless
the user explicitly approves a stable release.

Start at [`docs/README.md`](./docs/README.md): it maps the documentation tree
and says which file answers which question. The doctrine is
[`docs/PRODUCT-VISION.md`](./docs/PRODUCT-VISION.md) and the mechanics are
[`docs/handbook.md`](./docs/handbook.md). The rules below are the release
discipline that overrides convenience.

## Version And Release Discipline

- Server and dashboard deploy as one image on a single alpha train. Increment
  only the trailing number; never fork a new train without an operator
  decision. This file states the rule, not the number: the current train and
  the deployed tag live in the production truth section of the operator's
  program log at the workspace root, verified against `/api/version`. Do not
  restate a version here, in a design, or in a tutorial.
- Do not publish stable-looking SDK, node-agent, plugin, or docs releases for
  exploration work. Use prerelease semver tags such as `v0.3.3-alpha.1`,
  `v0.3.3-beta.1`, or `v0.3.3-rc.1`.
- Stable-looking `vX.Y.Z` tags require an explicit stable-release decision from
  the user. Passing CI is not enough.
- GitHub prerelease assets must be marked prerelease and must not become GitHub
  `Latest`. Use `--prerelease --latest=false` or patch
  `make_latest=false`.
- Server `target_version=latest` means latest stable node-agent only:
  non-draft, non-prerelease `v*`. Alpha/beta/rc node-agent versions are opt-in
  by exact version string and reviewed plan.
- Dashboard/server may expose alpha/beta/rc candidates and experimental feature
  channels, but they must be explicit user opt-ins with visible channel labels
  and review text. Do not auto-select prereleases because a dashboard supports
  them or because GitHub marks one as newest.
- Node-agent release artifacts must embed machine-readable server/dashboard
  compatibility metadata. Planning UI should surface that metadata before a
  user approves a test-channel rollout.
- If server/dashboard work consumes new SDK fields, update the SDK dependency
  pin in the same slice. Prefer Go pseudo-versions or prerelease SDK tags during
  alpha; do not mint stable SDK tags for test-only contract changes.
- Node-agent releases must keep `lattice-agent -version` as the exact update
  target and expose compatibility metadata separately through `-compat-json`.
  Update that compatibility floor when protocol assumptions change.
- Server container builds must pin the bundled dashboard ref via `dashboard.ref`.
  Before deployment, the About page should show matching server/dashboard alpha
  versions and the expected dashboard ref.

## Release Report Checklist

Every release/deploy report must include:

- server image tag and server commit
- dashboard commit/ref bundled into the server image
- SDK pin if changed
- node-agent release channel if changed
- verification commands and their result
- whether any prior bad stable-looking release was marked prerelease/non-latest
