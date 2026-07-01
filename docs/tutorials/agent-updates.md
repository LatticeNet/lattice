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

Root is normally required to replace `/opt/lattice/lattice-agent` and restart a
system service. If the agent runs as a non-root user, choose an install path and
service strategy that user can actually mutate.

On the server:

- the operator has `node:admin` and `network:plan` for planning;
- the approver has `network:apply`;
- official-release mode is preferred: leave Binary URL and SHA-256 empty so the
  server resolves `LatticeNet/lattice-node-agent` for the node OS/arch;
- custom artifact mode is still available when the HTTPS artifact URL and
  SHA-256 digest are known.

Official Linux agent release artifacts are:

```txt
lattice-agent-linux-amd64
lattice-agent-linux-arm64
SHA256SUMS
```

For custom artifact mode, use the matching row in `SHA256SUMS` for the policy
digest. Official-release mode resolves that digest on the server at plan time.

## Manual update

1. Open **Agent Updates**.
2. Click `Update` on a node row, or type `node_id`.
3. Fill:
   - target version, e.g. `latest` or `0.2.8`;
   - leave Binary URL empty for the official `lattice-node-agent` release;
   - leave SHA-256 empty for the official release;
   - install path, default `/opt/lattice/lattice-agent`;
   - service name, default `lattice-agent.service`.
4. Save policy.
5. Click `Plan Update`.
6. Review the generated `agentupdate` approval. It should show the exact
   version, URL, SHA, path, and service.
7. Approve with `queue_apply`.

For forked or emergency binaries, provide Binary URL and SHA-256 together. The
URL must be HTTPS and the digest must match the artifact. Do not use custom
artifacts for normal upgrades; they bypass the official release affordances and
are harder to audit.

If you edit the policy after creating a plan, discard the old approval and
create a new one. The server rejects stale approvals whose bound tuple no longer
matches the current policy. The approvals inbox also performs a local cleanup
pass for historical stale `agentupdate` approvals, so an old pending plan may
appear as `rejected` after a refresh instead of waiting for an approve attempt to
fail.

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
fresh reviewed plan. Editing or deleting a policy closes pending update
approvals for that node, and if the node already reports the current target
before an approval is applied, the scheduler closes the pending no-op approval as
rejected instead of keeping stale update work in the inbox.

This gives you a Nezha-like centralized update entry while preserving Lattice's
review gate for privileged host changes.

## Rollback

The update script creates a timestamped backup:

```txt
/opt/lattice/lattice-agent.bak.YYYYMMDDHHMMSS
```

Manual rollback on the node:

```sh
systemctl stop lattice-agent.service
cp -p /opt/lattice/lattice-agent.bak.YYYYMMDDHHMMSS /opt/lattice/lattice-agent
chmod 0755 /opt/lattice/lattice-agent
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

## Release resolution boundary

Do not let nodes fetch arbitrary release metadata. `latest` and official
release resolution stay server-side:

1. resolve the trusted release repository;
2. map the node OS/arch to the expected artifact;
3. fetch `SHA256SUMS`;
4. embed the concrete URL + SHA + version in the approval plan;
5. create pending approvals as today.
