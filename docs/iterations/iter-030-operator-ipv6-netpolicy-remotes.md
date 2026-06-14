# Iteration 030 — Operator IPv6 NetPolicy Remotes

- **Status:** Completed (2026-06-14)
- **Builds on:** `iter-029-ipv6-control-plane-domain-set.md`
- **Repos:** `lattice-server`, `lattice`

## Goal

Let operators express reviewed IPv6 policy remotes in `NetPolicy` without
opening the door to domain-valued remotes. IPv6 CIDRs and node `PublicIPv6`
facts should compile to explicit `ip6` nft statements while retaining the same
plan -> approve -> apply flow and graph model.

## Scope

- Normalize `NetEndpoint{kind:"cidr"}` as either IPv4 or IPv6.
- Compile egress IPv6 CIDR remotes as `ip6 daddr`.
- Compile node remotes with both available address families:
  - IPv4 addresses -> `ip daddr ...`
  - IPv6 addresses -> `ip6 daddr ...`
- Fold ingress IPv6 sources into Network Guard's single `lattice_guard` input
  render as `ip6 saddr` statements.
- Keep existing IPv4 output byte-stable where possible.

## Non-Goals

- No domain-valued operator remotes.
- No DNS-backed operator remote refresh.
- No IPv6 WireGuard peer set for baseline `WireGuardCIDR`; that remains IPv4 in
  `NFTInputs`.
- No dashboard form changes in this slice; the API already accepts CIDR strings.

## Safety Invariants

- All IPv6 values must be parsed and canonicalized before they reach nft text.
- Mixed-family node remotes render as separate nft statements, never as an
  impossible `ip` + `ip6` conjunction.
- Existing IPv4 behavior, plan-hash approval, and task secret-free views remain
  unchanged.

## Test Plan

- `go test ./internal/network ./internal/netpolicy ./internal/server -run 'TestGenerateNFT|TestNormalize|TestCompile|TestNetPolicy|TestNFTPolicy|TestApprovePlanHash' -count=1`
- `go test ./internal/server -run 'Test([A-NP-Z].*)' -count=1`
- `git diff --check`
- `go build ./cmd/lattice-server`

## Exit Bar

IPv6 CIDR and node remotes compile to reviewed `ip6` nft rules for egress and
ingress composition; unsafe strings still fail validation; domain-valued remotes
remain unsupported and documented as the next network-policy slice.

## Execution Log

- Changed `NetPolicy` CIDR normalization from IPv4-only to IPv4/IPv6
  canonicalization.
- Updated egress compilation so IPv6 CIDRs render as `ip6 daddr` and node
  remotes with mixed address families render as separate IPv4/IPv6 statements.
- Updated ingress composition so `CompileIngressInputRules` can pass IPv6
  sources into Network Guard.
- Updated `internal/network.GenerateNFTPlan` to split input rule sources by
  family and render `ip saddr` and `ip6 saddr` statements under the same
  `lattice_guard` input chain.
- Added tests for IPv6 CIDR normalization, IPv6 egress CIDR/node remotes,
  IPv6-only node remotes, and IPv6 input rules.
- Updated Design 05, roadmap, product vision, program review, development
  report, and Network Guard tutorial.

## Review Outcome

- Manual review in the main thread:
  - **Injection boundary:** IPv6 strings are parsed/canonicalized before nft
    rendering; raw operator strings still cannot reach nft syntax.
  - **Family correctness:** mixed-family node remotes render as separate
    statements, avoiding impossible `ip` and `ip6` conjunctions.
  - **Hook ownership:** ingress IPv6 still folds into `lattice_guard`; no second
    input hook or competing firewall table was introduced.
  - **Scope control:** domain-valued remotes and DNS-backed operator remote
    refresh remain out of scope.

## Residuals

- Domain-valued operator remotes remain unsupported.
- No DNS-backed refresh for operator remotes.
- Network Guard baseline WireGuard peer set is still IPv4-only.
- Live nft execution on a real node was not exercised in this sandbox.
