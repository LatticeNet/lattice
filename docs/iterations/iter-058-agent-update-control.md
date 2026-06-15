# Iteration 058 - Server-controlled node-agent updates

- **Date:** 2026-06-15
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice-node-agent`, `lattice-dashboard`, `lattice`
- **Design:** [design-07-agent-lifecycle-updates](../designs/design-07-agent-lifecycle-updates.md)
- **Status:** Implemented, reviewed, verified

## Goal

Add a safe update entry for `lattice-agent` similar in operator experience to
mature agent-based systems: the server controls the target version and the node
does not need a full reinstall. The design must preserve Lattice's high-risk
operation rule: no background binary mutation without a reviewable plan and
approval.

## What landed

1. **SDK contract:** `model.AgentUpdatePolicy` captures per-node target version,
   HTTPS artifact URL, SHA-256, install path, service name, auto-plan flag, and
   last planned/applied/error state.
2. **Persistence:** JSON store plus bbolt import/export bucket
   `agent_updates`.
3. **Server API:**
   - `GET/POST /api/nodes/agent-updates`
   - `POST /api/nodes/agent-updates/delete`
   - `POST /api/nodes/agent-updates/plan`
4. **Approval integration:** `agentupdate` approvals require `plan_sha256`.
   Approval with `queue_apply:true` creates a longer-running bounded task
   (300s) for download/verify/install. Approval also rejects stale plans if the
   current policy's version/URL/SHA/path/service tuple changed after planning.
5. **Update script:** HTTPS download, pinned SHA-256 verification, candidate
   `-version` smoke check, timestamped backup, atomic replacement, and delayed
   systemd restart so the current agent can post the task result.
6. **Auto-plan:** the scheduler creates a pending approval when an enabled
   auto-plan policy's target version differs from the node's reported
   `agent_version` and no equivalent `pending`/`approved` update is open. It
   does not auto-approve or auto-apply.
7. **Dashboard:** Agent Updates panel with policy CRUD and manual Plan Update.
8. **Agent:** `lattice-agent -version` prints the built-in version and exits.

## Review findings fixed

- `georouting.Render` now validates `GeoIPDBPath` internally instead of relying
  only on the server handler. This prevents future direct renderer callers from
  writing unsafe paths into CoreDNS config.
- Agent update tasks get a 300s timeout instead of the generic 30s task timeout.
- Auto-plan duplicate suppression now treats both `pending` and `approved`
  approvals as open work. Failed task results close the approval as `rejected`
  and retain the bounded error on the policy, which allows a fresh reviewed plan.
- `agentupdate` approvals now require the policy to still match the reviewed
  tuple before queueing, matching the currentness checks used by proxy/nft paths.

## Verification

```sh
GOWORK=.../lattice/go.work go test ./internal/server ./internal/georouting ./internal/store
GOWORK=.../lattice/go.work go test ./cmd/lattice-agent ./internal/logtail ./internal/proxyusage ./internal/taskexec
npm test
```

Targeted coverage:

- policy rejects non-HTTPS artifact URLs;
- manual plan creates a secret-free `agentupdate` approval;
- approval queues a script containing HTTPS download, SHA pin, `-version` smoke,
  delayed restart, and 300s timeout;
- auto-plan does not duplicate an equivalent pending or approved approval;
- failed update task results reject the old approval and allow a future re-plan;
- stale approvals are rejected if the policy changed after planning;
- dashboard helper normalizes SHA and status labels.

## Residuals

- Release-channel discovery is intentionally not built. Future work should add a
  signed release manifest resolver that resolves `stable`/`canary` into the same
  immutable URL+SHA tuple.
- The current update result marks the approval applied when the install script
  succeeds; a later heartbeat should add a post-restart confirmation state once
  the new process reports the target `agent_version`.
- Log ingestion MVP still has a known offset-semantic limitation: if the agent
  crashes after one sub-batch succeeds but before the pending buffer fully
  flushes, some already-accepted lines may be re-sent after restart. Fix by
  returning per-line offsets from `internal/logtail` and checkpointing per
  accepted sub-batch.
