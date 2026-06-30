# Iteration 066 - Tasks fan-out, agent launch profiles, and vpn-core operator UX

**Date:** 2026-06-30  
**Repos:** `lattice-sdk`, `lattice-server`, `lattice-dashboard`, `lattice-node-agent`, `lattice`, `lattice-plugin-index`

## Why this slice exists

Three operator workflows exposed the same underlying problem: the dashboard had
good primitives, but too much critical state was either hidden until failure or
compressed into one coarse row.

1. `/tasks` accepted many targets, but the server leased the task as one global
   unit. The first node to lease it moved the whole task to `leased`, preventing
   the remaining targets from receiving it. The first result then marked the
   whole task `finished` or `failed`, even if dozens of targets never ran.
2. Nodes often need task execution, root task execution, terminal mode, sing-box
   discovery, and usage collectors configured at enrollment time. Those flags
   were easy to forget; the failure only surfaced later as errors such as
   `agent task execution disabled; restart with -allow-exec=true to enable`.
3. vpn-core users are identities. In day-to-day operations a user should receive
   a complete credential set once and then use that identity across lines, not
   manually add one protocol at a time.

## Task fan-out model

`model.Task` now carries optional per-target lease metadata:

- `target_leases`: map of node id to the lease id and start time issued to that
  node.
- `rerun_of_task_id`: ancestry pointer for rerun tasks.
- `rerun_of_node_id`: set when the rerun is scoped to one failed target.

The legacy `lease_id` and `leased_by` fields remain for compatibility with
existing agent payloads and old task records. When an agent polls, the server
returns the same task shape with `lease_id` set to that node's lease id.

For a task with `N` targets, `LeaseTasks(nodeID)` can lease the task to each
target exactly once. Partial results keep the task `leased`; the task becomes
`finished` only when every unique target has a successful latest result, and
`failed` only when every target has a result and at least one latest result
failed. This avoids the old "first result wins" behavior.

## Rerun behavior

Whole-task rerun remains:

```http
POST /api/tasks/rerun
{ "id": "task_..." }
```

Single-node rerun is now first-class:

```http
POST /api/tasks/rerun-node
{ "id": "task_...", "node_id": "node_..." }
```

The rerun task is a new queued task with the same server-side script body, one
target when `rerun-node` is used, `rerun_of_task_id` pointing at the root task,
and `rerun_of_node_id` pointing at the target node for node-scoped reruns. The
original task is not mutated.

## `/tasks` dashboard redesign

The tasks page now supports:

- search by node id, name, role, tag, country, region, or city;
- tag and region filters;
- batch "select visible", "select online", and "clear visible";
- compact target chips instead of unbounded comma-separated target text;
- per-root-task history grouping;
- per-target latest status, result, attempt count, and failed-node rerun action;
- expandable stdout/stderr/error for every node attempt.

The page no longer implies that a multi-target task has a single result.

## Agent launch profile

`model.Node` now includes optional `agent_launch`, an operator-authored desired
startup profile. This is not a runtime attestation; it records what command the
dashboard generated and what the operator intends the service to run with.

`POST /api/nodes/enroll-token` accepts `agent_launch` and returns generated
commands with the matching environment variables embedded. `POST
/api/nodes/reconfigure-command` stores the desired profile and returns a command
that sources the existing `/opt/lattice/lattice-agent.env` on the node, then
reruns the installer with the new env flags. The server never returns the node
token again.

`lattice-node-agent/scripts/install.sh` now persists:

- `LATTICE_AGENT_ALLOW_EXEC`
- `LATTICE_AGENT_ALLOW_ROOT_EXEC`
- `LATTICE_NO_EXEC`
- `LATTICE_AGENT_ALLOW_TERMINAL`
- `LATTICE_TERMINAL_TRANSPORT`
- `LATTICE_SSH_ALERTS`
- `LATTICE_SINGBOX_DISCOVER`
- `LATTICE_SINGBOX_BIN`
- `LATTICE_PROXY_USAGE_FILE`
- `LATTICE_PROXY_USAGE_URL`
- `LATTICE_PROXY_USAGE_XRAY_API`
- `LATTICE_PROXY_USAGE_XRAY_BIN`
- `LATTICE_PROXY_USAGE_XRAY_PATTERN`

Without this installer change, the dashboard could generate a correct command
but the service would not retain the VPN/task-related flags across restarts.

## vpn-core user credential defaults

The VPN Users create dialog now starts with a full credential set:

- `vless`
- `vmess`
- `trojan`
- `shadowsocks`
- `hysteria2`
- `tuic`
- `anytls`

Blank UUID/password fields are intentionally submitted blank so the server can
generate secrets. Edit remains conservative: credentials are not sent unless the
operator explicitly opts into "replace credentials", preventing accidental
secret loss.

## Operational note for sing-box probe failures

If a node shows:

```text
agent task execution disabled; restart with -allow-exec=true to enable
```

the problem is the node-agent launch profile, not the sing-box parser. Generate
a reconfigure command on the node detail page with `allow_exec=true`; add
`allow_root_exec=true` when the service runs as root and must mutate host config;
enable `singbox_discover=true` when the node should report discovered lines every
loop. Do not re-enroll the same machine as a new node unless a new identity is
explicitly desired.
