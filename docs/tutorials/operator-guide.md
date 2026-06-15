# Lattice Operator Guide

This is the practical end-to-end guide for a small private fleet. It assumes the
security posture Lattice is built around:

- public internet exposes only the ports you deliberately publish;
- the control plane is behind HTTPS and preferably also WireGuard or Cloudflare
  Access;
- node agents dial out to the server;
- host mutations use `plan -> approve -> apply`;
- high-risk node execution is disabled unless explicitly needed.

## 1. Build or install binaries

From the workspace:

```sh
cd Lattice/lattice
make test
```

Build individual binaries:

```sh
cd ../lattice-server
GOWORK=../lattice/go.work go build -o /usr/local/bin/lattice-server ./cmd/lattice-server

cd ../lattice-node-agent
GOWORK=../lattice/go.work go build -o /usr/local/bin/lattice-agent ./cmd/lattice-agent
```

Verify the agent binary supports the update smoke check:

```sh
lattice-agent -version
```

## 2. Deploy the server

Recommended public path: Docker/Compose for `lattice-server`, systemd binary for
`lattice-node-agent`. See [Docker server deployment](./docker-server.md) for the
container path.

Recommended filesystem layout:

```txt
/opt/lattice/dashboard     # lattice-dashboard static files
/var/lib/lattice/state.json
/var/lib/lattice/logs.db
/var/lib/lattice/master.key
```

Start the server on localhost or a private/WireGuard address:

```sh
LATTICE_LISTEN=127.0.0.1:8088 \
LATTICE_DATA=/var/lib/lattice/state.json \
LATTICE_WEB_ROOT=/opt/lattice/dashboard \
LATTICE_ADMIN_PASSWORD='replace-with-long-random-password' \
LATTICE_PUBLIC_URL='https://lattice.example.com' \
/usr/local/bin/lattice-server
```

Production perimeter:

- NGINX/Caddy/Cloudflare Tunnel terminates HTTPS on `443`.
- `lattice-server` listens on `127.0.0.1` or a WireGuard address.
- Set `-secure-cookies` when TLS is terminated at the server, or ensure the
  trusted reverse proxy is the only public entry.
- Back up `state.json`, `state.json.audit-wal`, `logs.db`, and `master.key`
  together. Losing `master.key` makes encrypted secrets unrecoverable.

## 3. First login and 2FA

1. Open the dashboard.
2. Sign in as `admin` with `LATTICE_ADMIN_PASSWORD`.
3. Enable TOTP in the account panel.
4. Store recovery codes offline.

If using SSO/OIDC, configure providers only after the first local admin path is
working. OIDC users are still server-provisioned accounts; the IdP is not a
blanket authorization source.

## 4. Add a node

In the dashboard Nodes panel:

1. enter `node id` and `name`;
2. click `Enroll`;
3. run the printed command on the node.

Minimal agent command:

```sh
lattice-agent \
  -server https://lattice.example.com \
  -node-id gmami-jp1 \
  -token '<node-token>'
```

Recommended service flags for an operations node:

```sh
lattice-agent \
  -server https://lattice.example.com \
  -node-id gmami-jp1 \
  -token '<node-token>' \
  -wg-ip 10.66.0.11/32 \
  -ssh-alerts \
  -log-state-dir /var/lib/lattice-agent/logtail \
  -allow-exec=true \
  -allow-root-exec=true
```

Use `-allow-exec=false` on nodes that should only report metrics and run
monitors. Use `LATTICE_NO_EXEC=1` as a kill switch.

## 5. Remove or disable a node

Preferred sequence:

1. Disable the node token or rotate it from the server.
2. Stop the node service:
   `systemctl disable --now lattice-agent.service`.
3. Remove related DNS/proxy/netpolicy/log sources.
4. Keep historical audit/task/log records for traceability.

Do not delete audit evidence just to make the dashboard cleaner.

## 6. Update node agents

Use the Agent Updates panel:

1. Select a node from the Nodes table or type its id.
2. Fill target version, HTTPS binary URL, SHA-256 digest, install path, and
   service name.
3. Save policy.
4. Click `Plan Update`.
5. Review the generated `agentupdate` approval.
6. Approve with queue apply.

For auto-plan, enable `Auto-plan when version differs`. The server creates a
pending approval on the scheduler tick when the node reports a different
`agent_version`, as long as no equivalent `pending` or `approved` update is still
open; it does not auto-approve or auto-apply.

See [Agent updates](./agent-updates.md).

## 7. Configure network guard and per-node ACL

Use Network Guard for the base host firewall:

- public TCP/UDP ports;
- WireGuard TCP/UDP ports;
- interface and CIDR;
- control-plane selfcheck via `LATTICE_PUBLIC_URL`.

Use Network Policy for per-node egress/ingress intent:

- egress rules apply through `table inet lattice_policy`;
- ingress rules compose into Network Guard's single `lattice_guard` input chain;
- domain remotes compile to nft named sets refreshed by the agent.

Review every nft plan. The apply path validates with `nft -c`, snapshots the
previous ruleset, arms a rollback watchdog, applies, and selfchecks.

See [Network guard](./network-guard.md).

## 8. Configure self-host DNS and geo-routing

Use DNS Deployments for a chosen authoritative node:

1. create a deployment with domains and records;
2. plan CoreDNS + nft;
3. approve and apply;
4. publish Cloudflare records when using a CF-backed profile.

Use Geo Routing for shared apexes such as `dns.roobli.org`:

1. add operator-owned node locations in the Fleet Map;
2. create a Geo-Routing record with participating nodes and DNS nodes;
3. preview the generated CoreDNS zone.

As of iter-058, Geo-Routing apply and NS delegation publication are the next
slice; preview is implemented.

## 9. Configure proxy cores and subscriptions

Proxy Core supports centralized users and node profiles:

1. create inbounds (`sing-box` or `xray`; MVP is VLESS + TCP + REALITY);
2. create users with expiry/quota;
3. bind node profiles to inbounds;
4. review and apply proxy config;
5. rotate a user's subscription token and copy the desired format.

Usage collection:

- sing-box can be reported through a loopback HTTP JSON source;
- xray uses the node-local `xray api statsquery` collector.

Config drift detection flags applied configs that still serve now-ineligible
users. Use the Proxy panel's Review & Apply path to enforce.

## 10. Configure logs

Log ingestion is bounded and node-assigned:

1. create a source with node id, absolute path, line cap, and batch cap;
2. ensure the agent can read that file;
3. set `-log-state-dir` for persistent checkpoints;
4. query in the Logs panel.

Security notes:

- logs may contain secrets; keep `master.key` enabled and backed up;
- allowed paths default to `/var/log/`; widen only with
  `LATTICE_LOG_PATH_ALLOW`;
- `/proc`, `/sys`, and `/dev` are denied.

## 11. Configure machine inventory and reminders

Agents report CPU, memory, uptime, architecture, OS, and kernel facts. Operators
can add cloud vendor, region, console links, cost, renewal cycle, renewal date,
and reminders in the Machines panel.

Use this for operational planning, not authorization.

## 12. Plugins

Plugins are metadata-gated and capability-scoped. Current runtime default is
`noop`: active plugins arm a broker and report health but do not execute
artifact code yet.

Use the plugin template repo for new bundles. Host-risk/system plugins require a
trusted signature policy; unsigned host-risk plugins are fail-closed unless the
operator explicitly opts into risk.

See [Plugins](./plugins.md).

## 13. Verification checklist

After any host-mutating change:

- approval plan hash was required and accepted;
- task result is visible and successful;
- audit contains the plan/approve/result sequence;
- node heartbeat still reaches the server;
- dashboard shows expected status;
- rollback file exists for nft/proxy/DNS paths where applicable.

When in doubt, re-plan. Do not re-use stale approvals after changing intent.
