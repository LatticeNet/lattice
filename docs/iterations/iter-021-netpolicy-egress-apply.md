# Iteration 021 — NetPolicy Egress Apply MVP

- **Status:** Completed (2026-06-13)
- **Design link:** `docs/designs/design-05-network-acl-and-map.md`
- **Builds on:** `iter-020-netpolicy-state-and-graph.md`
- **Repos:** `lattice-server`, `lattice-node-agent`, `lattice`, optionally `lattice-dashboard`

## Goal

Turn the stored `NetPolicy` intent from iter-020 into the first real
rollback-protected host apply path for **egress** rules. The target operator
workflow is: save "node A denies egress to node B tcp/1234" -> create a plan ->
review hash-bound approval -> queue apply -> agent validates/commits nft with a
dead-man rollback -> server records applied/failed status.

## Scope

- Add `internal/netpolicy` compiler for egress-only policy:
  - deterministic `table inet lattice_policy` output;
  - `output` hook with `ct established,related`, loopback, compiler-injected
    control-plane/DNS allow, operator rules, final `counter drop`;
  - node refs resolved to canonical IPv4 addresses from `WireGuardIP` and
    `PublicIP` where available;
  - CIDR/IP refs parsed and re-emitted canonically;
  - comments/rule IDs sanitized by the existing normalizer.
- Add `POST /api/netpolicy/plan`:
  - requires `netpolicy:admin` on target node;
  - rejects disabled/missing policies and ingress rules for this MVP;
  - stores pending `Approval{Plugin:"nftpolicy", Action:"apply-ruleset"}`;
  - sets `NetPolicy.LastPlanSHA` to the compiled ruleset hash.
- Add `applyScriptFor("nftpolicy")`:
  - write candidate to `/etc/lattice/policy.nft.new`;
  - `nft -c -f` before commit;
  - snapshot current ruleset;
  - arm 60s rollback watchdog;
  - commit with `nft -f`;
  - run `lattice-agent --selfcheck-controlplane -server <public-url>`;
  - disarm watchdog only after the selfcheck succeeds.
- Add agent `--selfcheck-controlplane` mode:
  - no token exposure to shell tasks;
  - GET `-server/api/health` with normal transport checks and timeout;
  - exits 0 only on HTTP 200.
- Consume `nftpolicy` task results:
  - update `NetPolicy.LastAppliedAt` / `LastError`;
  - mark approval `applied` on success;
  - audit `network.policy.applied` / `network.policy.failed`.

## Explicit Non-Scope

- No ingress compile/apply. Design 05 already flags `lattice_guard` input-hook
  double-drop risk; ingress must wait for a composition test/merge design.
- No geo-map.
- No dashboard apply button unless the existing approval list is enough. The API
  path is sufficient for this MVP.
- No IPv6 policy.
- No automatic reapply on peer IP changes.

## Security Notes

- This is the first committed nft path, so rollback/selfcheck are non-optional.
- The apply script must not embed node bearer tokens. The selfcheck verifies
  control-plane reachability via public `/api/health`; authenticated selfcheck
  can be redesigned later without leaking secrets to task shell env.
- The compiler must inject control-plane and DNS egress before operator rules.
- A policy containing unsupported ingress rules fails at plan time, not apply
  time.

## Verification Plan

- Server unit tests:
  - compiler output includes control-plane/DNS allow before operator rules;
  - deny node->node:port output is stable and contains canonical IP/ports;
  - ingress policies are rejected by plan;
  - plan records approval and `LastPlanSHA`;
  - approval queue script contains rollback/selfcheck and no bearer token;
  - agent task result updates `NetPolicy` and approval status.
- Agent tests:
  - selfcheck hits `/api/health` and returns success/failure correctly;
  - normal agent startup still requires node id/token.
- Run `go test` / `go test -race` on impacted packages, `go vet`, and
  `git diff --check`.

## Exit Bar

An operator can plan and queue a rollback-protected egress `nftpolicy` apply.
The generated task commits only after validation, selfchecks control-plane
reachability before disarming rollback, and reports applied/failed status back
to `NetPolicy`.

## Implementation Log

- Added a deterministic `internal/netpolicy.CompileEgressRuleset` renderer in
  `lattice-server` for one dedicated `table inet lattice_policy` output chain.
  It injects `established,related`, loopback, control-plane IPv4, and DNS egress
  allows before operator rules, then appends default drop.
- Added `POST /api/netpolicy/plan`, guarded by `netpolicy:admin` on the target
  node. It compiles the stored policy into a pending `Approval{Plugin:
  "nftpolicy", Action:"apply-ruleset"}`, stores `LastPlanSHA`, and audits
  `network.policy.plan`.
- Kept ingress deliberately unsupported at plan time. Any policy containing an
  ingress rule returns `400` until the later single-table composition work lands.
- Required `-public-url` / `LATTICE_PUBLIC_URL` to use an IPv4 literal for this
  first committed apply path. DNS/DDNS-derived control-plane allowlists are
  deferred; the compiler does not pretend nft can safely trust a domain name.
- Added `model.Task.ApprovalID` as server-side linkage from queued apply task to
  its approval. The agent task view still omits this control-plane field.
- Added an `nftpolicy` apply script:
  - writes `/etc/lattice/policy.nft.new`;
  - validates with `nft -c -f`;
  - snapshots `nft list ruleset` to `/etc/lattice/policy.rollback.nft`;
  - arms a 60s rollback watchdog;
  - commits the candidate nft batch;
  - runs `lattice-agent --selfcheck-controlplane -server <public-url>`;
  - disarms the watchdog only after selfcheck succeeds.
- Added `lattice-agent --selfcheck-controlplane`, which performs a one-shot,
  unauthenticated `GET /api/health` and exits. No node bearer token is injected
  into the shell task.
- Consumed `nftpolicy` task results server-side: success marks approval
  `applied`, writes `NetPolicy.LastAppliedAt`, clears `LastError`, and audits
  `network.policy.applied`; failure writes `LastError` and audits
  `network.policy.failed`.
- Added stale-plan protection: changing a stored policy clears its current
  `LastPlanSHA`; approval requires the approval plan hash to match the current
  policy; task results for stale queued plans do not mark the current policy
  applied.
- Added a dashboard `Plan Apply` button to saved NetPolicy cards. It creates the
  pending approval; execution still requires the existing approval queue button.

## Review Outcome

- Local code review focused on trust boundaries:
  - **Token exposure:** apply script contains no bearer/token handling; selfcheck
    is unauthenticated and limited to public `/api/health`.
  - **Rollback:** watchdog cleanup was tightened after review so normal failure
    paths roll back immediately and do not leave a second rollback process
    waiting in the background.
  - **State linkage:** `ApprovalID` is persisted on server `Task` state but not
    exposed in `agentTaskView`, so the agent remains an executor rather than a
    policy participant.
  - **Plan freshness:** a real stale-plan risk was fixed during review. Old
    approvals cannot be queued after policy edits, and old queued task results
    cannot set `LastAppliedAt` for the edited policy.
  - **Forward safety:** domain `public_url` is rejected for apply in this MVP
    instead of compiling a stale DNS answer into nft.
- No critical/high issues remain in this slice. The known residuals below are
  intentional scope boundaries, not accidental omissions.

## Residuals / Next

- Ingress policy is still design-only. It must be folded into the existing
  `lattice_guard` input render, not installed as an independent input chain.
- PublicURL hostname/DNS support is deferred. A safe implementation needs an
  explicit DNS/DDNS-to-nft named-set updater with TTL/timeout semantics and clear
  fail-closed behavior.
- IPv6 policy is not compiled yet.
- The geo-map is still pending.
- Full `go test ./internal/server` remains blocked in this sandbox by existing
  OIDC `httptest.NewServer` port binding (`operation not permitted`), so this
  iteration used targeted server tests plus package-level tests/vet.
