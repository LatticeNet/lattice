# Docker Server Deployment

Lattice supports a containerized **server** deployment. This is the recommended
easy path for the control plane because the server does not need host privileges:
it owns auth, state, dashboard serving, plugin verification, task queue, and
audit.

`lattice-node-agent` should normally remain a systemd-managed host binary. The
agent reads host facts/logs and may apply reviewed host mutations such as nft,
CoreDNS, sing-box/xray config, or agent self-updates. Running that safely inside
Docker usually requires host mounts or privileged mode, which weakens the
boundary Docker was meant to provide.

## Quick start with Compose

```sh
cd Lattice/lattice/compose
cp .env.example .env
$EDITOR .env
mkdir -p data plugins
docker compose up -d
```

The compose file binds the server to localhost only:

```txt
127.0.0.1:8088 -> container:8088
```

Expose it with NGINX, Caddy, Cloudflare Tunnel, or a WireGuard-only reverse
proxy. Public internet should reach only HTTPS `443`, not the raw server port.

## Required environment

Set at minimum:

```env
LATTICE_ADMIN_PASSWORD=replace-with-a-long-random-password
LATTICE_PUBLIC_URL=https://lattice.example.com
LATTICE_SECURE_COOKIES=1
```

Set `LATTICE_TRUST_PROXY=1` only when the container is reachable exclusively
through a trusted reverse proxy that sets `CF-Connecting-IP` or
`X-Forwarded-For`. Do not enable it for direct exposure.

## Persistent data

The container stores all durable state under `/var/lib/lattice`, mounted from
`./data` by the compose file.

Back up these together:

- `data/state.json`
- `data/state.json.audit-wal`
- `data/logs.db`
- `data/master.key`

`master.key` protects stored secrets. Losing it makes encrypted values
unrecoverable.

## Plugins

The compose file mounts:

```txt
./plugins -> /plugins:ro
```

Each plugin bundle currently has this local layout:

```txt
plugins/
  example.plugin/
    manifest.json
    artifact
```

The server verifies every bundle at startup against the configured trust policy.
Lifecycle state is stored in `state.json`; the bundle bytes remain in
`LATTICE_PLUGIN_DIR`.

## Building the image locally

`lattice-server`, `lattice-sdk`, and `lattice-dashboard` are separate
repositories. The Dockerfile therefore uses BuildKit named contexts:

```sh
cd Lattice
DOCKER_BUILDKIT=1 docker build \
  -f lattice-server/Dockerfile \
  --build-context lattice-sdk=./lattice-sdk \
  --build-context lattice-dashboard=./lattice-dashboard \
  -t lattice-server:local \
  ./lattice-server
```

Run it:

```sh
docker run --rm \
  -p 127.0.0.1:8088:8088 \
  -e LATTICE_ADMIN_PASSWORD='replace-with-a-long-random-password' \
  -e LATTICE_PUBLIC_URL='https://lattice.example.com' \
  -v "$PWD/lattice/compose/data:/var/lib/lattice" \
  -v "$PWD/lattice/compose/plugins:/plugins:ro" \
  lattice-server:local
```

## GHCR image

The `lattice-server` repository publishes:

```txt
ghcr.io/latticenet/lattice-server
```

Use immutable tags or digests for production:

```yaml
image: ghcr.io/latticenet/lattice-server:v0.2.0
# or
image: ghcr.io/latticenet/lattice-server@sha256:<digest>
```

Avoid `latest` for unattended production upgrades.

## Recommended production shape

```txt
Internet
  -> Cloudflare / NGINX / Caddy on 443
  -> 127.0.0.1:8088 lattice-server container

Nodes
  -> outbound HTTPS to Lattice server
  -> systemd lattice-agent on the host
```

The server container should not need:

- `--privileged`
- host network
- Docker socket
- `/` host mounts

If a future feature appears to require any of those for `lattice-server`, treat
that as a design smell and move the host mutation to `lattice-node-agent`.
