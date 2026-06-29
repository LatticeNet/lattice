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

The default Compose file uses `ghcr.io/latticenet/lattice-server:latest`, which
is published from stable `v*` release tags. Use
`ghcr.io/latticenet/lattice-server:alpha` for the moving alpha test channel, or
pin a specific version tag/digest for production change control.

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

`LATTICE_ADMIN_PASSWORD` is read only when the initial `admin` account is
created. After `data/state.json` exists, changing the environment variable and
restarting the container does **not** rotate the password. Sign in and rotate it
through `POST /api/auth/password` instead; the change invalidates existing
sessions and requires a fresh login.

Set `LATTICE_TRUST_PROXY=1` only when the container is reachable exclusively
through a trusted reverse proxy that sets `CF-Connecting-IP` or
`X-Forwarded-For`. Do not enable it for direct exposure.

## Persistent data

The container stores all durable state under `/var/lib/lattice`, mounted from
`./data` by the compose file.

On first boot, leave `LATTICE_MASTER_KEY_FILE` unset. The server will generate
`data/master.key` automatically with `0600` permissions. Set
`LATTICE_MASTER_KEY_FILE` only when you are mounting a pre-existing key from a
secret manager or restoring from backup.

The image starts through a small root entrypoint that fixes ownership of the
mounted data directory, then drops privileges to the unprivileged `lattice`
user. This lets the root-created `./data` directory from a normal Compose
bootstrap work without running the server itself as root.

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
docker buildx build --load \
  -f lattice-server/Dockerfile \
  --build-context lattice-sdk=./lattice-sdk \
  --build-context lattice-dashboard=./lattice-dashboard \
  --build-arg DASHBOARD_COMMIT="$(cat lattice-server/dashboard.ref)" \
  -t lattice-server:local \
  ./lattice-server
```

If `docker buildx` is not installed locally, install Docker's buildx component
or rely on the GitHub Actions container workflow, which provisions buildx before
building multi-arch images.

The published server image embeds the dashboard commit pinned in
`lattice-server/dashboard.ref`. To intentionally roll a dashboard-only change
into a new server image, first merge/push `lattice-dashboard`, then update
`dashboard.ref` in `lattice-server` to that dashboard commit and push
`lattice-server`. The server container workflow will publish a new image from
the new server commit, preserving reproducible image tags.

Run it:

```sh
docker run --rm \
  -p 127.0.0.1:8088:8088 \
  -e LATTICE_ADMIN_PASSWORD='replace-with-a-long-random-password' \
  -e LATTICE_PUBLIC_URL='https://lattice.example.com' \
  -e LATTICE_PLUGIN_RUNTIME_DIR='/var/lib/lattice/plugin-runtime' \
  -v "$PWD/lattice/compose/data:/var/lib/lattice" \
  -v "$PWD/lattice/compose/plugins:/plugins:ro" \
  lattice-server:local
```

`LATTICE_PLUGIN_RUNTIME_DIR` enables the Tier-2 system runner so verified
system-plugin artifacts execute in isolated per-plugin working directories
instead of staying behind the noop runner. Leave it unset to preserve the
fail-closed default. Plugins receive only the runner's fixed safe environment by
default; set `LATTICE_PLUGIN_RUNTIME_ENV` to a comma/space-separated allowlist
only when a trusted system plugin explicitly needs selected host variables.

## GHCR image

The `lattice-server` repository publishes:

```txt
ghcr.io/latticenet/lattice-server
```

Stable releases publish:

```yaml
image: ghcr.io/latticenet/lattice-server:latest
image: ghcr.io/latticenet/lattice-server:v0.3.0
```

Alpha testing uses:

```yaml
image: ghcr.io/latticenet/lattice-server:alpha
```

Use immutable tags or digests for unattended production rollouts:

```yaml
image: ghcr.io/latticenet/lattice-server:v0.3.0
# or
image: ghcr.io/latticenet/lattice-server@sha256:<digest>
```

There is intentionally no `main` image channel. Source pushes run CI; image
publication is tag-driven.

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

## NGINX, Let's Encrypt, and Cloudflare

After `docker compose up -d`, verify the localhost service first:

```sh
curl -fsS http://127.0.0.1:8088/api/health
```

It should return:

```json
{"status":"ok"}
```

Use NGINX as a local HTTPS reverse proxy:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name lattice.example.com;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;

    server_name lattice.example.com;

    ssl_certificate /etc/letsencrypt/live/lattice.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/lattice.example.com/privkey.pem;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:8088;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
```

Then:

```sh
ln -sf /etc/nginx/sites-available/lattice.conf /etc/nginx/sites-enabled/lattice.conf
nginx -t
certbot --nginx -d lattice.example.com
systemctl reload nginx
```

If `certbot --nginx` also wrote `lattice.example.com` into
`/etc/nginx/sites-enabled/default`, NGINX will warn about a
`conflicting server name` and may ignore the Lattice proxy. Remove the duplicate
enabled site or remove the duplicate server block, then reload:

```sh
grep -R "server_name lattice.example.com" -n /etc/nginx/sites-enabled /etc/nginx/sites-available
unlink /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx
```

Cloudflare settings for an orange-clouded record:

- DNS -> Records: `A lattice <origin-ip>`, Proxy status `Proxied`.
- SSL/TLS -> Overview: `Full (strict)`.
- SSL/TLS -> Edge Certificates: `Always Use HTTPS` can be enabled.
- SSL/TLS -> Edge Certificates: `Automatic HTTPS Rewrites` can be enabled.
- Caching -> Cache Rules: bypass API caching with:

```txt
(http.host eq "lattice.example.com" and starts_with(http.request.uri.path, "/api/"))
```

The cache rule action should be `Bypass cache`. Do not use `Cache Everything`
for the dashboard until authenticated and API paths are explicitly excluded.

Validate after DNS/proxy changes:

```sh
curl -fsS --resolve lattice.example.com:443:127.0.0.1 https://lattice.example.com/api/health
curl -fsS https://lattice.example.com/api/health
curl -I https://lattice.example.com/api/health | grep -iE 'cf-cache-status|server|location'
```
