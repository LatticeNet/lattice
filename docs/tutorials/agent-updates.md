# Agent Updates

Lattice supports server-controlled `lattice-agent` updates without reinstalling
the node from scratch. The feature is intentionally conservative: the server can
create update plans, but binary replacement still requires a reviewed approval.

## Prerequisites

On the node:

- `lattice-agent` runs as a service;
- task execution is enabled when updates are desired:

```sh
LATTICE_AGENT_ALLOW_EXEC=1
LATTICE_AGENT_ALLOW_ROOT_EXEC=1
```

Root is normally required to replace `/usr/local/bin/lattice-agent` and restart a
system service. If the agent runs as a non-root user, choose an install path and
service strategy that user can actually mutate.

On the server:

- the operator has `node:admin` and `network:plan` for planning;
- the approver has `network:apply`;
- the artifact URL is HTTPS and the SHA-256 digest is known.

## Manual update

1. Open **Agent Updates**.
2. Click `Update` on a node row, or type `node_id`.
3. Fill:
   - target version, e.g. `0.2.0`;
   - binary URL, e.g.
     `https://github.com/LatticeNet/lattice-node-agent/releases/download/v0.2.0/lattice-agent-linux-amd64`;
   - SHA-256 digest;
   - install path, default `/usr/local/bin/lattice-agent`;
   - service name, default `lattice-agent.service`.
4. Save policy.
5. Click `Plan Update`.
6. Review the generated `agentupdate` approval. It should show the exact
   version, URL, SHA, path, and service.
7. Approve with `queue_apply`.

If you edit the policy after creating a plan, discard the old approval and
create a new one. The server rejects stale approvals whose bound tuple no longer
matches the current policy.

The queued task:

- downloads over HTTPS;
- verifies SHA-256;
- requires the candidate's `-version` output to equal the target version;
- backs up the old binary;
- installs atomically;
- schedules a delayed systemd restart so the current agent can report success.

## Auto-plan

Enable `Auto-plan when version differs` on the policy.

On the scheduler tick, the server compares:

```txt
node.agent_version != policy.target_version
```

If they differ and there is no equivalent open approval (`pending` or
`approved`), the server creates a new pending `agentupdate` approval. It does not
approve or apply automatically. A failed update task closes the old approval and
stores the failure reason on the policy, so the next scheduler tick can create a
fresh reviewed plan.

This gives you a Nezha-like centralized update entry while preserving Lattice's
review gate for privileged host changes.

## Rollback

The update script creates a timestamped backup:

```txt
/usr/local/bin/lattice-agent.bak.YYYYMMDDHHMMSS
```

Manual rollback on the node:

```sh
systemctl stop lattice-agent.service
cp -p /usr/local/bin/lattice-agent.bak.YYYYMMDDHHMMSS /usr/local/bin/lattice-agent
chmod 0755 /usr/local/bin/lattice-agent
systemctl start lattice-agent.service
```

Then confirm the node heartbeat and `agent_version` in the dashboard.

## Failure modes

- **Download timeout:** the update task has a 300s timeout. Use a closer mirror
  or pre-stage artifacts if nodes are bandwidth-limited.
- **SHA mismatch:** the task fails and does not replace the binary. Re-check the
  artifact and digest.
- **Candidate does not run or reports the wrong version:** the task fails before
  install. Check that the artifact was built for the same target version in the
  policy.
- **No systemd:** the binary is installed, but restart is manual.
- **No `-allow-exec` / root guard:** the agent refuses the task before running
  the script. This is expected safe default behavior.

## Future release-channel support

Do not implement "latest" by letting nodes fetch arbitrary release metadata.
Future channel support should be server-side and signed:

1. fetch or receive release manifest;
2. verify signature;
3. resolve channel (`stable`, `canary`) into URL + SHA + version;
4. store/update `AgentUpdatePolicy`;
5. create pending approvals as today.
