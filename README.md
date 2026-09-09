# Lattice

Lattice is a sovereign control plane for a personal fleet: it amplifies one
operator's judgment safely across all of their infrastructure. The work can be
done by hand in the console or delegated to AI agents through plans; either
way, every privileged change is a reviewed plan whose approval hashes what the
operator was actually shown, execution is bound to that exact plan and
artifact, nodes run an outbound-only agent that keeps its own last-line
policy, and a hash-chained audit log records what actually happened. Where the
system does not know, it says unknown.

This is the umbrella repository: ecosystem overview, doctrine and roadmap,
developer handbook, compose files, and tutorials. The code is intentionally
split into independent repositories so server, node-agent, dashboard, SDK,
plugins, and companions can be released and secured separately.

The doctrine (positioning, axioms, north star, program) is
[`docs/PRODUCT-VISION.md`](./docs/PRODUCT-VISION.md). The public site is
<https://latticenet.github.io>.

## Ecosystem Repositories

Core:

- [`lattice-sdk`](https://github.com/LatticeNet/lattice-sdk) - shared Go models and the plugin protocol contract.
- [`lattice-server`](https://github.com/LatticeNet/lattice-server) - the control plane: state, approvals, audit, plugin host.
- [`lattice-node-agent`](https://github.com/LatticeNet/lattice-node-agent) - outbound-only host agent with node-side capability flags.
- [`lattice-dashboard`](https://github.com/LatticeNet/lattice-dashboard) - strict-CSP Vue operator console, bundled into the server image via `dashboard.ref`.

Plugins (signed, capability-scoped, sandboxed UIs):

- [`lattice-plugin-vpn-core`](https://github.com/LatticeNet/lattice-plugin-vpn-core) - sing-box proxy lines, users, and usage.
- [`lattice-plugin-sub-store`](https://github.com/LatticeNet/lattice-plugin-sub-store) - native subscription platform: store, fetch, process, publish.
- [`lattice-plugin-netguard`](https://github.com/LatticeNet/lattice-plugin-netguard) - nftables security groups with reviewed apply and reality reporting.
- [`lattice-plugin-wireguard`](https://github.com/LatticeNet/lattice-plugin-wireguard) - WireGuard networks and device peers, planned before applied.
- [`lattice-plugin-bridge`](https://github.com/LatticeNet/lattice-plugin-bridge) - the sandboxed postMessage channel between plugin UIs and the host.
- [`lattice-plugin-template`](https://github.com/LatticeNet/lattice-plugin-template) - starter kit and packaging tools for plugin authors.
- [`lattice-plugin-index`](https://github.com/LatticeNet/lattice-plugin-index) - signed, read-only plugin catalogue. Not a live install channel by design.

Companions:

- [`Astra`](https://github.com/LatticeNet/Astra) - iOS companion for phone-first review and approval.
- [`latticenet.github.io`](https://github.com/LatticeNet/latticenet.github.io) - public website and documentation.
- [`.github`](https://github.com/LatticeNet/.github) - organization profile.

## What It Does Today

Fleet enrollment, metrics, inventory, and monitoring over an outbound-only
agent; plan-approve-apply for everything that mutates a node (nftables
firewall, WireGuard, self-host DNS with geo-routing, DDNS, SSH Guard hardening
with port knocking, agent updates, proxy-core line management); a native
subscription platform; per-node capability gates; browser terminal; log
ingestion; KV, static, and worker publishing surfaces; TOTP/OIDC/passkey
sign-in with scoped PATs; and a tamper-evident audit chain past one million
entries in the reference deployment.

The honest current state, including what is deliberately not enabled, is kept
in [`docs/PRODUCT-VISION.md`](./docs/PRODUCT-VISION.md) section 4 and on the
public site's status matrix, both of which are checked against reality rather
than aspiration.

## Quick Start

Docker server deployment:

```sh
cd Lattice/lattice/compose
cp .env.example .env
$EDITOR .env
docker compose up -d
```

See [Docker server deployment](./docs/tutorials/docker-server.md). The
recommended production shape is containerized `lattice-server` plus a
systemd-managed host `lattice-node-agent`.

Local binary development:

```sh
cd Lattice/lattice
make test
make build
LATTICE_ADMIN_PASSWORD='change-this-passphrase' make run-server
```

Open <http://127.0.0.1:8088>. The default username is `admin`. If
`LATTICE_ADMIN_PASSWORD` is not set on the first run, the server prints a random
bootstrap password to stdout.

Enroll a node from the dashboard, then run:

```sh
cd Lattice/lattice-node-agent
go run ./cmd/lattice-agent \
  -server http://127.0.0.1:8088 \
  -node-id demo-node \
  -token '<enrollment-token>' \
  -allow-exec=false
```

Task execution is disabled by default on the agent. Start with
`-allow-exec=true` only on machines where you accept the risk.
For fleet-wide incident response, start `lattice-server` with
`LATTICE_TASK_EXEC_DISABLED=1` / `-task-exec-disabled`; the server will reject
new task queueing and return no leases to agents while still accepting results
from tasks that were already leased.
Linux agents can also enforce optional per-task cgroup v2 caps for resident
memory, pids, and CPU by setting `LATTICE_TASK_CGROUP_ROOT=auto` (or an
absolute delegated cgroup root). Cgroup caps are off by default and fail closed
when configured but unavailable, so tasks do not silently run without the
requested OS-level limit.
Linux task interpreters also run with `no_new_privs`, blocking setuid or
file-capability privilege gain from task scripts.
Set `LATTICE_TASK_WORK_ROOT=/opt/lattice/state/tasks` to place task-private
working directories under an operator-controlled root. Each task gets its own
removed-after-run directory, and the agent binds `HOME`, `TMPDIR`, and
`XDG_RUNTIME_DIR` to it. On Linux, task scripts also inherit `umask 077`.
This reduces temp-file leakage but is not a full mount namespace or filesystem
sandbox.
For least-privilege Linux systemd installs, set
`LATTICE_AGENT_RUN_USER=lattice-agent` before running the agent installer; use a
root-capable service profile only for host mutation or self-update tasks.

## Design Defaults

- Agents dial out; inbound node ports are not required.
- Dangerous operations follow `plan -> diff -> approve -> apply`.
- Plugins must pass signed-manifest verification before lifecycle registration. Active plugins receive only a capability-scoped broker through the runtime runner contract; artifact execution is still disabled by default.
- Management APIs should live on WireGuard/private addresses or behind a hardened reverse proxy.

## Operator Docs

- [Tutorial index](./docs/tutorials/README.md)
- [Operator guide](./docs/tutorials/operator-guide.md)
- [Server install](./docs/tutorials/server-install.md)
- [Agent install](./docs/tutorials/agent-install.md)
- [Agent updates](./docs/tutorials/agent-updates.md)
- [Storage migration drills](./docs/tutorials/storage-migration.md)
- [Plugins](./docs/tutorials/plugins.md)
- [Network guard](./docs/tutorials/network-guard.md)

## Contributor Docs

- [Documentation map: what is where and where to start](./docs/README.md)
- [Product vision and north star](./docs/PRODUCT-VISION.md)
- [Developer handbook: build, test, tag, release](./docs/handbook.md)
- [Development workflow](./docs/development-workflow.md)
- [Roadmap log](./docs/roadmap.md)

## Shared Contract Releases

`lattice-server` and `lattice-node-agent` intentionally consume shared models
from `lattice-sdk`. When SDK contracts change, cut a new `lattice-sdk` tag
first and then update the dependent `go.mod` files. Between milestones the
server and node-agent may pin a Go pseudo-version of the SDK commit they were
built against; the newest `v*` tag is what downstream consumers depend on, and
the public site verifies its displayed SDK version against the tag list at
build time. Local multi-repo development can use `go.work`, but standalone
builds should not depend on an untagged SDK `main`.

Workspace CI pins each sibling checkout to an exact commit in
`.github/workflows/ci.yml`. Update those refs and `go.work.sum` together when
advancing the integration set, then run `make test`, `make build`, and
`make test-check-clean` followed by `make check-clean` in the five-repository
sibling layout. The regression covers clean, dirty, missing, and non-repository
checkouts both separately and in one aggregate scan. CI keeps the real
clean-tree gate as its final step, where it fails if any checkout cannot be
inspected or has changes: a successful Go command that rewrites a tracked sum
is not a reproducible green build.
