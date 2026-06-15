# Agent Install

1. Start the server.
2. Sign in to the dashboard.
3. Create an enrollment token in the Nodes panel.
4. Run the printed command on the node.

Example:

```sh
cd Lattice/lattice-node-agent
lattice-agent \
  -server https://lattice.example.com \
  -node-id dmit-eb-wee \
  -token '<node-token>' \
  -wg-ip 10.66.0.2 \
  -allow-exec=false
```

Check the installed binary:

```sh
lattice-agent -version
```

Task execution is off by default. Enable it only for nodes where remote script
execution is acceptable:

```sh
lattice-agent ... -allow-exec=true
```

Agent self-update through the server also uses the task channel. If the update
replaces `/usr/local/bin/lattice-agent` and restarts `lattice-agent.service`, the
service normally needs both:

```sh
lattice-agent ... -allow-exec=true -allow-root-exec=true
```

See [Agent updates](./agent-updates.md).

Execution limits:

- Interpreter allowlist: `sh`, `bash`, `python3`, `node`.
- Default timeout: 30 seconds.
- Maximum timeout: 10 minutes.
- Maximum captured stdout/stderr: 256 KiB.
- Minimal environment and temporary working directory.
