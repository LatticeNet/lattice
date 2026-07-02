# Agent Install

1. Start the server.
2. Sign in to the dashboard.
3. Create an enrollment token in the Nodes panel.
4. Copy the generated install script or one-time node token before leaving the
   page.
5. Run the generated script on the node.

The node token is a server-generated per-node bearer token. It is not an
operator password, GitHub token, or Cloudflare token. The server stores only a
hash of it, so the plain token is shown once during enrollment or token
rotation. If it is lost, rotate or re-enroll the node and update the node's
`/opt/lattice/lattice-agent.env`.

The dashboard install script downloads the Linux `amd64` or `arm64` release
artifact, verifies `SHA256SUMS`, installs `/opt/lattice/lattice-agent`, writes
`/opt/lattice/lattice-agent.env`, and enables `lattice-agent.service`.

Example:

```sh
VERSION=v0.2.8
ARCH=amd64
curl -fsSL --proto '=https' --tlsv1.2 -O "https://github.com/LatticeNet/lattice-node-agent/releases/download/${VERSION}/lattice-agent-linux-${ARCH}"
curl -fsSL --proto '=https' --tlsv1.2 -O "https://github.com/LatticeNet/lattice-node-agent/releases/download/${VERSION}/SHA256SUMS"
grep "lattice-agent-linux-${ARCH}$" SHA256SUMS | sha256sum -c -
install -d -m 0755 /opt/lattice
install -m 0755 "lattice-agent-linux-${ARCH}" /opt/lattice/lattice-agent

/opt/lattice/lattice-agent \
  -server https://lattice.example.com \
  -node-id dmit-eb-wee \
  -token '<node-token>' \
  -wg-ip 10.66.0.2 \
  -allow-exec=false
```

Check the installed binary:

```sh
/opt/lattice/lattice-agent -version
```

Task execution is off by default. Enable it only for nodes where remote script
execution is acceptable:

```sh
/opt/lattice/lattice-agent ... -allow-exec=true
```

Agent self-update through the server also uses the task channel. If the update
replaces `/opt/lattice/lattice-agent` and restarts `lattice-agent.service`, the
service normally needs both:

```sh
/opt/lattice/lattice-agent ... -allow-exec=true -allow-root-exec=true
```

See [Agent updates](./agent-updates.md).

For least-privilege Linux systemd installs, run the installer with:

```sh
LATTICE_AGENT_RUN_USER=lattice-agent \
LATTICE_AGENT_RUN_GROUP=lattice-agent \
sh scripts/install.sh
```

The installer creates the service account when needed, writes `User=` and
`Group=` into the unit, leaves the token env file readable only by root, and
assigns the state directory to the service user. Use this profile for
monitoring, inventory, terminal, and non-privileged tasks. Host mutation and
self-update tasks normally need a root-capable service profile or a separate
privileged helper.

Execution limits:

- Interpreter allowlist: `sh`, `bash`, `python3`, `node`.
- Default timeout: 30 seconds.
- Maximum timeout: 10 minutes.
- Maximum captured stdout/stderr: 256 KiB.
- Minimal environment and temporary working directory. `HOME`, `TMPDIR`, and
  `XDG_RUNTIME_DIR` are bound to the task-private workdir. Set
  `LATTICE_TASK_WORK_ROOT=/opt/lattice/state/tasks` to place those per-task
  directories under a dedicated absolute root; unsafe roots fail closed before
  the script runs.
- Linux `no_new_privs` guard: task interpreters cannot gain privilege through
  setuid or file-capability executables.
- Linux `umask 077`: task-created files default to owner-only access.
- Optional Linux cgroup v2 caps: set `LATTICE_TASK_CGROUP_ROOT=auto` for a
  delegated systemd service cgroup, or use an absolute delegated cgroup root.
  Defaults are `memory.max=536870912`, `pids.max=64`, and
  `cpu.max="100000 100000"`. If configured cgroup setup fails, the task fails
  before running.
