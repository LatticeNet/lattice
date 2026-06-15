# Server Install

## Local Development

```sh
cd Lattice/lattice
make test
LATTICE_ADMIN_PASSWORD='change-this-passphrase' make run-server
```

Open `http://127.0.0.1:8088` and sign in as `admin`.

For the full first-run sequence (2FA, nodes, updates, DNS, proxy, logs, plugins),
start with [Operator guide](./operator-guide.md).

## Production Shape

Run `lattice-server` behind nginx, Caddy, or Cloudflare Tunnel. For the easiest
server-only deployment, use [Docker server deployment](./docker-server.md).
For a direct binary install, bind the server to localhost or a WireGuard address:

```sh
cd Lattice/lattice-server
LATTICE_LISTEN=127.0.0.1:8088 \
LATTICE_DATA=/var/lib/lattice/state.json \
LATTICE_WEB_ROOT=/opt/lattice/dashboard \
LATTICE_ADMIN_PASSWORD='long-random-passphrase' \
/usr/local/bin/lattice-server
```

Recommended perimeter:

- Public internet: only 443.
- Server process: localhost or WireGuard IP.
- Agent traffic: outbound HTTPS from nodes to the server.
- Admin traffic: Cloudflare Access, WireGuard, or both.

Back up these files together:

- `state.json`
- `state.json.audit-wal`
- `logs.db`
- `master.key`

The master key protects stored credentials and optionally log chunks; losing it
makes encrypted values unrecoverable.
