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

Task execution is off by default. Enable it only for nodes where remote script
execution is acceptable:

```sh
lattice-agent ... -allow-exec=true
```

Execution limits:

- Interpreter allowlist: `sh`, `bash`, `python3`, `node`.
- Default timeout: 30 seconds.
- Maximum timeout: 10 minutes.
- Maximum captured stdout/stderr: 256 KiB.
- Minimal environment and temporary working directory.
