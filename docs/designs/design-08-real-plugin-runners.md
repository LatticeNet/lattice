# Design 08 - Real plugin runners

## Status

Design and development guide. Artifact execution remains disabled by default.

## Goal

Move from the current `noop` runtime to concrete plugin runners without breaking
Lattice's security model.

The current foundation already exists:

- strict manifest validation;
- digest/signature verification;
- startup loader from `LATTICE_PLUGIN_DIR`;
- lifecycle registry/API/dashboard;
- capability-scoped broker;
- audited host API calls;
- runtime manager + `Runner` interface.

This design defines the safe path to actual execution.

## Non-goals

- No open community marketplace execution in the first runner release.
- No unsigned host-risk plugin execution in production.
- No direct server handles exposed to plugins.
- No Docker socket, host root, or arbitrary filesystem access from server
  plugins.

## Runner tiers

### Tier 0 - noop runner (current)

State: implemented.

The server arms a broker and records runtime health, but does not execute
artifact code.

### Tier 1 - worker runner

Purpose: low-risk dashboard/route extensions.

Allowed plugin types:

- `worker`

Allowed capabilities:

- `worker:route`
- `kv:read`
- `static:read`

Execution model:

- server-owned interpreter;
- no filesystem access;
- no process execution;
- no environment variables;
- no arbitrary network;
- request/response body caps;
- per-plugin CPU/time budget;
- deterministic template/route execution first, JS later only if sandboxed.

Recommended first implementation:

```txt
template runner -> no JS -> no network -> brokered KV/static reads only
```

### Tier 2 - system runner

Purpose: first-party or operator-audited host operation plugins.

Allowed plugin types:

- `system`

Execution model:

- subprocess with arg-vector execution, never shell interpolation;
- artifact path fixed to verified bundle artifact;
- working directory confined to a per-plugin runtime dir;
- environment allowlist only;
- stdout/stderr caps;
- startup timeout and heartbeat;
- stop timeout with kill after grace;
- OS resource limits where supported;
- host mutation still goes through `plan -> approve -> apply` and node-agent
  tasks, not direct server-side host mutation.

System runner is for official plugins such as:

- sing-box/xray manager;
- Sub-Store supervisor;
- notification adapters;
- read/write integrations that produce plans.

It is not a shortcut around approvals.

### Tier 3 - wasm runner

Purpose: third-party sandboxed extensions.

Allowed plugin types:

- `wasm`

Execution model:

- pure Go wasm runtime if adopted;
- fuel/step limits;
- memory cap;
- no WASI filesystem by default;
- no process/network syscalls;
- host API imports only through the broker;
- deterministic request/response caps.

Dependency note: adding a wasm runtime must get an ADR because Lattice keeps a
small dependency surface.

## Host API contract

Plugins never receive raw server, store, HTTP client, filesystem, or task queue
handles. They receive a broker with declared capabilities:

- KV get/put under `plugin:<pluginID>`;
- guarded outbound HTTP;
- notifications;
- logs;
- future route/static APIs.

Every broker call records allow/deny events.

## Runtime state

Extend `RuntimeStatus` only with secret-free fields:

- `state`
- `runner`
- `message`
- `pid` (system runner only, optional)
- `started_at`
- `stopped_at`
- `updated_at`
- `last_error`
- `restart_count`

Never expose:

- bundle path;
- environment;
- command line containing secrets;
- broker internals;
- local sockets.

## Failure behavior

- A plugin start failure sets runtime state `failed`.
- Disabling a plugin detaches its broker even if `Stop` fails.
- A crashing plugin must not crash `lattice-server`.
- Repeated crashes should trip a circuit breaker and require operator action.
- Host API denial must be visible in audit, not silently ignored.

## Test plan

Before enabling any non-noop runner:

1. manifest mismatch cannot start;
2. undeclared capability cannot call host API;
3. disabled plugin detaches broker;
4. crash does not kill server;
5. stdout/stderr caps hold;
6. timeout kills or marks failed;
7. environment only includes allowlisted keys;
8. path traversal in bundle metadata cannot change executable path;
9. worker runner cannot access filesystem/network/process;
10. system runner cannot bypass plan/approval for host mutation.

Run with:

```sh
go test -race ./internal/plugin ./internal/server
```

## Recommended implementation order

1. Add runner config flags but keep default `noop`.
2. Implement worker template runner first.
3. Add dashboard runtime detail view.
4. Implement system runner for one official plugin only.
5. Add crash circuit breaker.
6. Add signed plugin index display.
7. Add install flow from index.
8. Consider wasm runner after ADR.

## Release gate

Do not call plugin execution production-ready until:

- runner-specific tests are present;
- race tests pass;
- dashboard shows runtime failures clearly;
- marketplace install is still separated from activation;
- host-risk capabilities require trusted signatures;
- docs tell operators how to disable a plugin and recover.
