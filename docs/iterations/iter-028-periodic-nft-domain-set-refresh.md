# Iteration 028 — Periodic nft Domain Set Refresh

- **Status:** Completed (2026-06-14)
- **Builds on:** `iter-026-netpolicy-domain-control-plane-set.md`, `iter-027-agent-native-nft-domain-set-updater.md`
- **Repos:** `lattice-server`, `lattice`

## Goal

Keep a domain-backed `nftpolicy` control-plane set fresh after the approved
apply completes. A hostname whose A record changes should not require immediate
manual re-plan just to preserve control-plane reachability.

## Scope

- Extend the existing `nftpolicy` apply script:
  - domain `public_url`: write `/etc/lattice/nftpolicy-domain-refresh.sh`;
    install `lattice-nftpolicy-domain-refresh.service` and `.timer`; enable and
    start the timer;
  - IPv4/no-domain `public_url`: disable/remove the domain refresher artifacts.
- The refresh script reuses
  `lattice-agent --update-nft-domain-set -host <bound-host> -family inet -table
  lattice_policy -set lattice_control4`.
- Keep apply-time update and selfcheck unchanged.
- Keep the existing plan-hash approval, plan-bound `public_url`, and rollback
  behavior.

## Non-Goals

- IPv6 refresh (`lattice_control6`) was out of scope for this slice; this
  residual was retired by iter-029.
- No domain-valued operator remotes.
- No new server API or store model.
- No non-systemd scheduler in this slice. Non-systemd hosts keep the
  apply-time update and get a clear log message; a portable scheduler can be a
  later agent-managed feature.

## Safety Invariants

- The persistent script contains only the plan-bound hostname and fixed nft set
  coordinates.
- The refresh script does not contain a node token or server URL.
- If a later approved apply no longer uses a hostname `public_url`, stale
  refresh artifacts are removed.
- Apply-time update and selfcheck still happen before the timer is considered a
  successful install.

## Test Plan

- `go test ./internal/netpolicy ./internal/server -run 'TestCompile|TestNetPolicy|TestNFTPolicy|TestApprovePlanHash' -count=1`
- `go test ./internal/server -run 'Test([A-NP-Z].*)' -count=1`
- `git diff --check`

## Exit Bar

A domain-backed `nftpolicy` queued task contains the agent helper plus
systemd timer installation for periodic refresh. An IPv4-backed queued task
contains cleanup for stale refresh artifacts and no domain timer install.

## Execution Log

- Extended `nftPolicyApplyScript` so domain-backed plans write a root-owned
  `/etc/lattice/nftpolicy-domain-refresh.sh` that calls the iter-027 agent
  helper against the plan-bound hostname and fixed `lattice_policy`
  `lattice_control4` set.
- Added systemd unit/timer rendering:
  `lattice-nftpolicy-domain-refresh.service` runs the refresh script as a
  oneshot; `lattice-nftpolicy-domain-refresh.timer` runs it every 60 seconds
  with `Persistent=true`.
- Stopped any existing refresh timer before rewriting the script/unit to avoid a
  timer firing while the script is being replaced.
- Timer installation now requires both `systemctl` and a running systemd runtime
  (`/run/systemd/system`) so container or non-systemd hosts skip the timer
  instead of rolling back a valid nft apply just because a stray `systemctl`
  binary exists.
- Kept the apply-time domain set update and control-plane selfcheck before
  timer install is treated as successful.
- Added cleanup for IPv4/no-domain applies: stale systemd unit/timer files and
  `/etc/lattice/nftpolicy-domain-refresh.sh` are removed so old hostnames do
  not keep refreshing after an approved topology change.
- Updated tests to assert domain queued tasks install the timer and IPv4 queued
  tasks clean stale artifacts without installing a domain updater.
- Updated Design 05, roadmap, product vision, program review, development
  report, and the Network Guard tutorial.

## Review Outcome

- Manual security review completed in the main thread:
  - **Credential surface:** the persistent refresh script contains no node token
    and no server URL; it only holds the plan-bound hostname and nft set
    coordinates.
  - **Rollback semantics:** domain set update and selfcheck still happen before
    timer install. Timer install failure on systemd hosts remains inside the
    existing ERR trap, so nft policy rolls back.
  - **Stale artifact cleanup:** later approved IPv4/no-domain applies disable
    and remove the timer/script.
  - **Race reduction:** old timer is disabled before overwriting the refresh
    script.
  - **Runtime detection:** non-systemd/container hosts with a stray `systemctl`
    binary skip timer installation instead of failing the apply.
  - **Scope control:** no IPv6, domain remotes, store model, or non-systemd
    scheduler was added in iter-028. Control-plane IPv6 was added later in
    iter-029.

## Residuals

- Non-systemd hosts still only get apply-time refresh plus a clear log message.
- Control-plane IPv6 refresh was a residual at iter-028 close and was retired
  by iter-029.
- Domain-valued operator policy remotes remain unsupported.
- Timer interval is fixed at 60 seconds in this slice; per-node/operator tuning
  can be added later if needed.
