# Iteration 026 — Domain-Backed Control-Plane nft Set

- **Status:** Implemented -> Review (2026-06-14)
- **Builds on:** `iter-021-netpolicy-egress-apply.md`, `iter-024-netpolicy-ingress-guard-composition.md`, `iter-025-high-risk-approval-plan-hash.md`
- **Repos:** `lattice-server`, `lattice`

## Goal

Remove the IPv4-literal-only constraint for `NetPolicy` egress apply when the
server `public_url` is an HTTPS hostname. The node should resolve that hostname
at apply time into a named nft set, then selfcheck through the same hostname.

## Scope

- Extend `netpolicy.CompileOptions` with a validated control-plane hostname.
- Render `table inet lattice_policy` with a `lattice_control4` IPv4 named set
  when `public_url` is a domain instead of an IPv4 literal.
- Keep static IPv4 rendering unchanged for existing deployments.
- Extend the `nftpolicy` apply script:
  - apply the candidate ruleset;
  - resolve the control-plane hostname on the node via system resolver;
  - fail closed if no IPv4 A result is available;
  - flush and fill `inet lattice_policy lattice_control4`;
  - run the existing control-plane selfcheck;
  - rollback on any error.
- Update server tests and docs.

## Non-Goals

- No periodic/systemd updater yet.
- No IPv6 set yet.
- No domain-valued operator policy remotes yet; this slice is specifically the
  control-plane allow required to avoid self-lockout.
- No DNS-as-authentication. DNS only populates transport allowlists; Lattice auth
  remains HTTPS + bearer/session credentials.

## Safety Invariants

- The hostname is validated server-side with a conservative ASCII DNS-name
  grammar before it is allowed into any plan/apply script.
- The hostname never enters nft syntax; nft only sees resolved IPv4 elements.
- The candidate ruleset still allows DNS egress before the named set is filled.
- If resolution fails or yields no IPv4 address, apply exits non-zero and the
  watchdog/ERR trap restores the previous ruleset.
- The `public_url` used to compile the plan is bound into the stored `nftpolicy`
  approval action. The public API projection still shows stable
  `action:"apply-ruleset"`, but queued apply scripts decode the plan-bound URL
  instead of reading whatever server config exists at approval time.

## Test Plan

- `go test ./internal/netpolicy ./internal/server -run 'TestCompile|TestNetPolicy|TestNFTPolicy' -count=1`
- `go test ./internal/server -run 'Test([A-NP-Z].*)' -count=1`
- `git diff --check` for touched repos.

## Exit Bar

`https://lattice.example.com` can be used as server `public_url` for
`/api/netpolicy/plan`. The approval plan contains a named control-plane set, the
queued apply script resolves and fills that set before selfcheck, and tests prove
HTTP domain public URLs still fail.

## Execution Log

- Extended `netpolicy.CompileOptions` with `ControlPlaneHost`, validating that
  exactly one of IPv4 or hostname is selected and rendering `lattice_control4`
  when the hostname path is used.
- Changed `netPolicyCompileOptions` so static IPv4 `public_url` values keep the
  old direct nft allow, while HTTPS hostnames are accepted after conservative
  ASCII DNS-name normalization. HTTP hostnames and non-loopback HTTP IPv4 values
  still fail closed.
- Extended `nftPolicyApplyScript` to resolve the hostname on the node, fill
  `inet lattice_policy lattice_control4`, and then run the existing
  control-plane selfcheck. Iter-027 moved this update from a shell
  `getent|awk` pipeline into an agent-native helper; any failure still triggers
  the existing ERR trap + rollback path.
- During review, found and fixed a plan/apply TOCTOU: a server `public_url`
  changed between plan and approve could have generated a script that did not
  match the reviewed plan. `nftpolicy` approvals now bind the normalized
  `public_url` in the stored action; response views hide the internal suffix.
- Updated Design 05, roadmap, product vision, development report, program
  review, and the Network Guard tutorial to distinguish this landed
  control-plane domain set from the still-pending periodic/domain-remote/IPv6
  work.

## Review Outcome

- Manual security review completed in the main thread:
  - **Shell injection:** hostname is normalized before storage, then shell-quoted
    in the task script; the hostname is never emitted into nft syntax.
  - **DNS trust:** DNS only populates a transport allowlist. HTTPS verification
    during selfcheck and Lattice credentials remain the trust decision.
  - **Self-lockout:** DNS egress is allowed before operator rules; failed DNS,
    empty A results, nft set update failure, or selfcheck failure all rollback.
  - **Plan/apply binding:** reviewed plan and queued script now use the same
    bound `public_url`.
  - **API stability:** dashboard/API approval views still expose
    `action:"apply-ruleset"`; the internal action suffix is not client-facing.

## Residuals

- No periodic refresh/updater yet. A hostname whose A record changes after a
  successful apply remains stale until the operator re-plans/re-applies.
- IPv6 is still unsupported for `nftpolicy` control-plane and operator remotes.
- Domain-valued operator policy remotes are still intentionally unsupported.
- Iter-027 removed the `getent ahostsv4` host dependency by moving
  hostname-to-nft-set mutation into `lattice-agent --update-nft-domain-set`.
