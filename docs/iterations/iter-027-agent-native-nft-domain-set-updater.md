# Iteration 027 — Agent-Native nft Domain Set Updater

- **Status:** Implemented -> Review (2026-06-14)
- **Builds on:** `iter-026-netpolicy-domain-control-plane-set.md`
- **Repos:** `lattice-node-agent`, `lattice-server`, `lattice`

## Goal

Remove the shell `getent | awk` dependency from the `nftpolicy` control-plane
domain set update path. The node agent should own hostname resolution, IPv4
filtering, deterministic ordering, and nft set mutation through bounded
`exec.Command` calls.

## Scope

- Add an agent one-shot subcommand for apply scripts:
  `lattice-agent --update-nft-domain-set -host <hostname> -family inet -table <table> -set <set>`.
- Resolve the hostname with Go's resolver, filter to IPv4, deduplicate and sort.
- Validate nft family/table/set identifiers with a conservative ASCII grammar.
- Flush and fill the existing nft set using direct `nft` argv calls:
  `nft flush set ...`, then `nft add element ... "{ a, b }"`.
- Change the server `nftpolicy` apply script to call the agent helper before
  selfcheck.
- Keep the iter-026 plan/apply URL binding and rollback invariants intact.

## Non-Goals

- No periodic updater/systemd timer yet.
- No IPv6 set yet.
- No domain-valued operator policy remotes.
- No change to nft table ownership: `nftpolicy` still owns
  `table inet lattice_policy`; Network Guard still owns `lattice_guard`.

## Safety Invariants

- DNS results never pass through a shell pipeline.
- Hostname input remains server-normalized and shell-quoted when passed from
  the apply script to the agent.
- nft identifiers are validated by the agent before any command executes.
- Empty/no-IPv4 resolution fails non-zero, preserving rollback.
- The helper does not use or require a node bearer token.

## Test Plan

- `go test ./cmd/lattice-agent -run 'TestNFTDomainSet|TestSelfcheck' -count=1`
- `go test ./internal/netpolicy ./internal/server -run 'TestCompile|TestNetPolicy|TestNFTPolicy|TestApprovePlanHash' -count=1`
- `go test ./internal/server -run 'Test([A-NP-Z].*)' -count=1`
- `git diff --check`

## Exit Bar

An HTTPS hostname `public_url` still produces a domain-backed
`lattice_control4` plan, but the queued apply task now calls
`lattice-agent --update-nft-domain-set ...` instead of embedding `getent`/`awk`.
Agent unit tests prove IPv4 filtering/sorting, identifier validation, no-IPv4
failure, and nft argv construction.

## Execution Log

- Added `lattice-agent --update-nft-domain-set` one-shot mode. It exits before
  normal daemon startup, does not require `node-id`/token, and does not contact
  the server.
- Implemented agent-side hostname normalization, conservative nft
  family/table/set validation, Go resolver lookup, IPv4-only filtering,
  deduplication, deterministic numeric sort, and direct `nft` argv execution.
- Updated the server `nftpolicy` apply script to set `AGENT_BIN`, call
  `"$AGENT_BIN" --update-nft-domain-set -host <bound-host> -family inet -table
  lattice_policy -set lattice_control4`, and then run the existing
  `--selfcheck-controlplane`.
- Updated server tests so queued scripts must contain the agent helper and must
  not contain `getent`, `awk`, or the old `CONTROL4=` shell pipeline.
- Updated `lattice-node-agent/README.md` and the Design 05/roadmap/product
  documents to reflect that the apply-time updater is now agent-native while
  periodic refresh remained a follow-up. Iter-028 adds the systemd timer-backed
  refresh path.

## Review Outcome

- Manual security review completed in the main thread:
  - **Shell injection:** DNS answers are no longer interpolated into shell;
    table/set/family are validated before `nft` executes.
  - **Privilege boundary:** the helper is still invoked only by the
    approval-gated apply task path; it does not create a new inbound listener or
    require bearer credentials.
  - **Rollback semantics:** no-IPv4, resolver, flush, add, or selfcheck failure
    still exits non-zero inside the existing ERR trap/watchdog rollback shell.
  - **Determinism:** IPv4 answers are sorted and deduped, so repeated resolves
    with the same answer set produce stable nft update args.
  - **Scope control:** no periodic updater, IPv6, or domain policy remotes were
    smuggled into this slice.

## Residuals

- Iter-028 adds systemd timer-based refresh for the control-plane set. Nodes
  without systemd still need a later scheduler or re-plan/re-apply after DNS
  churn.
- IPv6 still needs a sibling `lattice_control6` path.
- `nft` itself must be installed and available on the task PATH.
- Domain-valued operator policy remotes remain unsupported.
