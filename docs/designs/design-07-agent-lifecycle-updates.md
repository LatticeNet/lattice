# Design 07 - Agent lifecycle and server-controlled updates

## Goal

Lattice nodes should not require a manual reinstall every time
`lattice-agent` changes. Operators need two modes controlled from the server:

- **manual update:** select a node, review the exact binary URL/SHA/version, and
  approve one update task;
- **auto-plan:** configure a node's target version once; when the node reports a
  different `agent_version`, the server creates a pending approval automatically.

Auto-plan deliberately stops at **pending approval**. Updating the agent binary
is a privileged host mutation, so execution still goes through
`plan -> approve(plan_sha256) -> queue task -> agent result -> audit`.
The server suppresses duplicates while an equivalent `pending` or `approved`
update approval is still open; failed task results close the approval and allow a
fresh plan.

## Security model

The update artifact is identified by:

- `target_version`
- HTTPS-only `binary_url` (no userinfo, no fragment)
- 64-character SHA-256 digest
- install path ending in `/lattice-agent`
- systemd service name

The server never accepts "latest" as an executable instruction. A future release
channel resolver may discover releases, but it must resolve them into the same
immutable tuple before creating a plan.

The node-side script:

1. downloads with `curl --proto '=https' --tlsv1.2` or `wget --https-only`;
2. verifies SHA-256 before chmod/install;
3. verifies the candidate `-version` output equals `target_version`;
4. writes a timestamped backup of the current binary;
5. installs atomically via `install ... "$TARGET.new"` then `mv`;
6. delays systemd restart by a few seconds so the current agent can post the
   task result before it is stopped.

When the policy uses the default or legacy install path, the apply script adopts
the currently running `lattice-agent` executable path if it can read
`/proc/$PPID/exe`; likewise the default service name can adopt the current
systemd unit from cgroup metadata. This keeps legacy/manual installations
updatable without silently replacing a binary that the running service does not
execute. The reviewed approval plan calls out this effective-target behavior so
operators do not confuse the policy's default path with the runtime path.

Execution still requires the node-agent process to run with `-allow-exec`; if
the service runs as root, `-allow-root-exec` is also required. This matches the
existing high-risk task boundary for nft, DNS, proxy-core apply, and other host
mutation providers.

## Data model

`model.AgentUpdatePolicy` is keyed by `node_id` and carries no secrets:

- `enabled`
- `auto_plan`
- `target_version`
- `binary_url`
- `sha256`
- `install_path`
- `service_name`
- last planned/applied version/time
- last error

It is persisted in JSON state and in the bbolt import/export bucket
`agent_updates`.

## API

- `GET /api/nodes/agent-updates`
  - returns policies visible to `node:read`.
- `POST /api/nodes/agent-updates`
  - requires `node:admin` on the node;
  - creates/updates the policy.
- `POST /api/nodes/agent-updates/delete`
  - requires `node:admin` on the node.
- `POST /api/nodes/agent-updates/plan`
  - requires both `node:admin` and `network:plan`;
  - creates a pending `agentupdate` approval if the policy is enabled and the
    node is not already at the target version;
  - refuses to duplicate an equivalent `pending` or `approved` update approval.

Approval uses the existing `/api/network/approvals/approve` endpoint with
`queue_apply:true` and `plan_sha256`. `agentupdate` approvals require a plan
hash like nft/selfdns/proxycore.

Approving an `agentupdate` plan also checks that the stored policy still matches
the approval's bound URL/SHA/version/path/service tuple. If the operator edited
the policy after planning, the server rejects the old approval and requires a
fresh plan.

`GET /api/network/approvals` also performs a local-only cleanup pass for pending
`agentupdate` approvals. It rejects historical approvals that are already
locally impossible to approve safely: invalid bound payloads, missing/disabled
policies, missing nodes, invalid local policy fields, changed explicit artifact
pins, or locally detectable official-version/install/service drift. It does not
resolve `latest` or fetch release metadata during inbox rendering; the approve
path remains the authoritative network-resolving safety gate.

## Dashboard

The dashboard adds an **Agent Updates** panel:

- node table has an `Update` action;
- policy form captures version, URL, SHA, install path, service name, enabled,
  and auto-plan;
- `Plan Update` creates a reviewed approval;
- policy cards show `current`, `update available`, `disabled`, and last error.

## Current implementation status

Implemented in iter-058:

- server-side policy model/store/bbolt bucket;
- manual plan API;
- auto-plan scheduler hook;
- reviewed update script generation;
- current-policy approval check before queueing;
- local inbox cleanup for historical stale pending approvals;
- dashboard policy panel;
- agent `-version` target-version check;
- tests for policy validation, manual queue, auto-plan duplicate suppression,
  failed-result replan behavior, and dashboard payload helpers.

Not implemented yet:

- signed release metadata / channel resolver;
- multi-node bulk policy editor;
- rollback trigger from dashboard;
- post-restart confirmation that the restarted agent reported the new version;
- automatic approval/apply. This remains intentionally out of scope.
