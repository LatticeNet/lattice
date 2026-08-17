# Design 18 — reviewed line-chain builder

Status: alpha implementation contract (E3 revision 9)

## Outcome

An operator can review and approve one redacted plan that connects one healthy
source sing-box line to one applied managed VLESS+REALITY+TCP target line. One
durable task mutates only the source/consumer node. Scheduled discovery, not the
approval itself, proves the resulting topology edge.

V1 supports set/replace and remove. It rejects adopted targets with incomplete
private descriptors, other protocols, same-node chains, ambiguous identity
joins, and cyclic declared graphs before an executable task is leased.

## Public plugin contract

The vpn-core plugin exposes these methods on
`latticenet.vpn-core/lines`:

| Method | Effect | Scope | Purpose |
| --- | --- | --- | --- |
| `chains` | read | `vpncore:read` | Secret-free desired, attempt, and reconciliation state |
| `plan_chain` | plan | `vpncore:admin` | Review a set/replace candidate |
| `plan_remove_chain` | plan | `vpncore:admin` | Review removal of the committed source edge |

The internal approval bindings intentionally use service `network/lines` and
methods `chain_set_apply` / `chain_remove_apply`. External plugin RPC names must
never be persisted as execution authority.

Statuses are exactly `planned`, `applying`, `applied_unobserved`, `converged`,
`drifted`, and `failed`. A failed replace/remove retains the old committed edge
while showing the failed attempt separately.

## Safety boundary

- Plans and reads use revision-consistent projections and make no synchronous
  node, SSH, HTTP, or sing-box calls.
- Approval targets exactly the consumer node and creates exactly one E3-linked
  task per approved attempt.
- Credentials appear only in the targeted lease artifact. They are absent from
  plan previews, plugin reads, audits, journals, generic KV, and reveal-script.
- The agent applies the fragment and source sidecar as one crash-recoverable
  transaction. Mixed pairs suppress readiness, inventory, capability
  advertisement, polling, and result publication.
- Exact durable result replay is accepted; conflicting replay is rejected.
- The issued wire authority binds the semantic sidecar patch digest (`PatchSHA256`)
  and server-issued artifact digest (`ArtifactSHA256`); output file digests are
  agent-journal evidence only and are never used as server approval authority.
- Durable execution begins with the exact leased task and protocol before the
  script runs. Recovery and resolve complete the durable result before cleanup;
  acknowledgement removes the pending outbox entry only after the server has
  accepted the exact result replay.
- A post-lease dependency change does not revoke frozen execution authority;
  an exact success is acknowledged once and committed as drifted.

## Compatibility and release handoff

The implementation matrix is server `alpha-0.2.1a38` with semantic floor
`0.2.2-alpha.19`, node-agent `0.3.4-alpha.1`, and vpn-core
`0.8.0-alpha.9`. Prereleases require explicit selection; `latest` remains the
latest stable node-agent only.

The vpn-core implementation lane produces a deterministic unsigned bundle. An
authorized release lane verifies the full two-architecture binary plus UI
bundle digest and signs only the final canonical manifest. Implementation does
not sign, tag, publish, deploy, or mutate the fleet.

## Acceptance trace

1. Inventories report managed target A and healthy source B.
2. Plan B → A and inspect the redacted approval.
3. Approve and lease exactly once to capable B.
4. B atomically publishes its route fragment and source sidecar.
5. B uploads one durable exact result.
6. Normal scheduled discovery proves outbound and declared downstream identity.
7. Ordinary metadata sync preserves the committed declaration.
8. A reviewed remove performs the inverse one-task transaction; discovery proves
   the fragment and edge are absent.

## Canonical E3 evidence

The acceptance path is the official sing-box 1.13.18 lifecycle script with a
strict runtime root and no simulated traffic, inventory, process restart, or
task result. It proves crash recovery, exact result replay and acknowledgement,
byte-identical retry authority, ordinary metadata preservation, and remove
convergence. The canonical run must report the server and agent revisions used,
the exact sing-box version, focused/race/vet results, and a clean runtime-root
process scan before integration approval.
