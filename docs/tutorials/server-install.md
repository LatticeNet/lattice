# Server Install

## Local Development

```sh
cd Lattice/lattice
make test
LATTICE_ADMIN_PASSWORD='change-this-passphrase' make run-server
```

Open `http://127.0.0.1:8088` and sign in as `admin`.

## Production Shape

Run `lattice-server` behind nginx, Caddy, or Cloudflare Tunnel. Bind the server
to localhost or a WireGuard address:

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
