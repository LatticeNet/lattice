# Iteration 038 — Self-host DNS Pinned CoreDNS Binary

- **Date:** 2026-06-14
- **Status:** Complete
- **Design reference:** `docs/designs/design-02-self-host-dns.md`
- **Repos:** `lattice-server`, `lattice`

## Goal

Close the CoreDNS binary provenance/install gap without turning Lattice into an
arbitrary remote downloader. A self-host DNS apply may install CoreDNS only when
the server operator has configured a pinned direct executable URL and SHA-256,
and the exact metadata has been reviewed in the approval plan.

## Scope

- Add `selfdns.CoreDNSBinarySource`:
  - `Version`
  - HTTPS direct executable `URL`
  - 64-hex `SHA256`
- Validate binary metadata:
  - all-or-none fields;
  - HTTPS only;
  - no URL userinfo, fragments, whitespace, or control characters;
  - safe version characters;
  - fixed install path `/usr/local/bin/coredns`.
- Add `RenderApprovalPlanWithOptions` so the reviewed plan includes:
  - CoreDNS version;
  - URL;
  - SHA-256;
  - install path.
- Extend `ParseApprovalPlan` / `ApplyScriptFromPlan` so the agent applies only
  the reviewed binary metadata:
  - verify existing `/usr/local/bin/coredns` by SHA-256;
  - otherwise download with `curl` or `wget`;
  - verify SHA-256 before install;
  - run CoreDNS validation through the chosen binary path;
  - write a systemd unit with `ExecStart=/usr/local/bin/coredns ...`.
- Add server config surface:
  - `LATTICE_COREDNS_BINARY_VERSION` / `-coredns-binary-version`
  - `LATTICE_COREDNS_BINARY_URL` / `-coredns-binary-url`
  - `LATTICE_COREDNS_BINARY_SHA256` / `-coredns-binary-sha256`
- Keep the old fail-closed behavior when no pinned source is configured:
  `command -v coredns` must succeed on the node.

## Explicit Non-goals

- No official CoreDNS release catalog or automatic "latest" lookup.
- No tarball extraction in the apply script. The URL must point directly to an
  executable binary. Operators may stage/mirror an official release artifact
  after verifying it externally.
- No dashboard field for binary URL/SHA. This is deployment policy, not routine
  operator input.
- No real node install test in this sandbox.

## Security Notes

- The binary source is copied into the approval plan and protected by the same
  `plan_sha256` binding as the Corefile and nft ruleset.
- The agent never receives mutable server config at apply time; it parses the
  reviewed plan.
- Only HTTPS URLs are accepted, and the binary is installed only after SHA-256
  verification.
- The install path is fixed to `/usr/local/bin/coredns`; plans with another path
  are rejected.

## Verification

- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test -count=1 ./internal/selfdns`
- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test -count=1 ./internal/server -run 'TestDNS'`
- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go test -count=1 ./internal/store`
- `GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work GOCACHE=/private/tmp/lattice-gocache go build ./cmd/lattice-server`

## Review Outcome

- The plan-bound installer avoids a time-of-check/time-of-use gap between plan
  review and apply.
- Keeping the URL/SHA in server startup config avoids making the dashboard/API an
  arbitrary download control surface.
- The direct-executable constraint is conservative. Supporting official
  `.tgz` assets should be a separate reviewed slice with safe extraction tests.

## Residuals

- Real Linux-node E2E is still required for CoreDNS + nft apply + Cloudflare
  publish together.
- A future release-management slice can add a server-embedded CoreDNS version
  allowlist or a safe tarball extractor for official release assets.
