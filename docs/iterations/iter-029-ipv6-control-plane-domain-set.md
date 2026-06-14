# Iteration 029 — IPv6 Control-Plane Domain Set

- **Status:** Completed (2026-06-14)
- **Builds on:** `iter-026-netpolicy-domain-control-plane-set.md`, `iter-027-agent-native-nft-domain-set-updater.md`, `iter-028-periodic-nft-domain-set-refresh.md`
- **Repos:** `lattice-server`, `lattice-node-agent`, `lattice`

## Goal

Bring the `nftpolicy` control-plane allow path to IPv6 parity. A control-plane
`public_url` that is an IPv6 literal should compile safely, and an HTTPS
hostname should maintain both IPv4 (`lattice_control4`) and IPv6
(`lattice_control6`) nft named sets without shell DNS parsing.

## Scope

- Extend `internal/netpolicy.CompileOptions` with `ControlPlaneIPv6`.
- Compile IPv6 literal control planes as `ip6 daddr <addr> tcp dport <port>`.
- Compile domain control planes with both:
  - `set lattice_control4 { type ipv4_addr; flags interval; }`
  - `set lattice_control6 { type ipv6_addr; flags interval; }`
  - corresponding `ip daddr @lattice_control4` and
    `ip6 daddr @lattice_control6` allow lines.
- Extend `lattice-agent --update-nft-domain-set` so one invocation can update
  both the IPv4 and IPv6 sets from one resolver result using direct `nft` argv
  calls.
- Update the `nftpolicy` apply-time and periodic refresh scripts to pass
  `-set6 lattice_control6` for domain-backed control planes.

## Non-Goals

- No IPv6 operator-authored policy remotes yet.
- No domain-valued operator remotes yet.
- No non-systemd scheduler.
- No change to the approval model or plan-hash binding.

## Safety Invariants

- DNS answers are still resolved and filtered inside `lattice-agent`, never by
  shell pipelines.
- The persistent refresh script remains credential-free: no node token, no
  server bearer, no server URL.
- A hostname with only A or only AAAA records is valid; the missing family set is
  flushed and left empty. If neither family resolves, the helper fails.
- IPv6 literal `public_url` must still require HTTPS unless it is loopback.

## Test Plan

- `go test ./cmd/lattice-agent -run 'TestNFTDomainSet' -count=1`
- `go test ./internal/netpolicy ./internal/server -run 'TestCompile|TestNetPolicy|TestNFTPolicy|TestApprovePlanHash' -count=1`
- `go test ./internal/server -run 'Test([A-NP-Z].*)' -count=1`
- `git diff --check`
- `go build ./cmd/lattice-agent`
- `go build ./cmd/lattice-server`

## Exit Bar

Domain-backed `nftpolicy` plans and queued apply scripts update both
`lattice_control4` and `lattice_control6`; IPv6 literal control-plane URLs plan
successfully and render `ip6` allows; IPv4 literal behavior and secret-free task
views remain unchanged.

## Execution Log

- Extended `lattice-agent --update-nft-domain-set` with optional `-set6`.
  The helper now resolves once through Go's resolver, splits/sorts/deduplicates
  IPv4 and IPv6 answers, and updates both named sets through direct `nft` argv
  calls.
- Preserved the old IPv4-only behavior: `-set` without `-set6` still requires at
  least one A record and fails before any nft command when none exists.
- Added dual-set behavior: `-set` + `-set6` requires at least one A or AAAA
  record; a missing family flushes that family set and leaves it empty.
- Extended the server compiler with `ControlPlaneIPv6`; IPv6 literal
  `public_url` values render direct `ip6 daddr <addr>` allows.
- Extended domain-backed plans to render `lattice_control4` and
  `lattice_control6`, with corresponding `ip` and `ip6` allow lines.
- Updated `nftpolicy` apply-time and systemd timer refresh scripts to call the
  agent helper with `-set lattice_control4 -set6 lattice_control6`.
- Updated agent README, Design 05, roadmap, product vision, program review,
  development report, and the Network Guard tutorial.

## Review Outcome

- Manual review in the main thread:
  - **Credential surface:** no new token-bearing script paths; the persistent
    refresh script still contains only hostname and fixed nft set coordinates.
  - **DNS trust boundary:** DNS answers remain data for nft sets, not identity;
    HTTPS selfcheck and Lattice credentials remain the trust decision.
  - **Backward compatibility:** old IPv4-only helper mode still fails if no A
    record is present.
  - **Dual-stack tolerance:** hostname with only A or only AAAA remains valid in
    dual-set mode; the absent family set is explicitly flushed.
  - **Scope control:** operator-authored domain remotes, operator-authored IPv6
    policy remotes, and non-systemd scheduling remain out of scope.

## Residuals

- Operator-authored IPv6 policy remotes are still not compiled.
- Domain-valued operator remotes are still not compiled.
- Non-systemd periodic refresh remains a later agent-managed scheduler slice.
- Live nft/systemd execution was not exercised in this sandbox.
