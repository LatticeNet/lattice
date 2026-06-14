# Iteration 040 — Proxy-Core sing-box Renderer

- **Status:** Implemented and verified locally (2026-06-14)
- **Design:** [`designs/design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
- **Repos:** `lattice-server`, `lattice`

## Goal

Start Design 01's executable foundation by adding a server-side, fail-closed
sing-box renderer for the first supported proxy-core shape:

- core: `sing-box`
- protocol: `vless`
- transport: TCP
- security: REALITY

This is intentionally **not** the full proxy feature. It does not expose CRUD
HTTP APIs, public subscriptions, dashboard controls, or node apply scripts yet.
It produces a reviewed config artifact that later plan/apply work can bind by
SHA-256.

## External schema references

The renderer follows sing-box's current official config shape:

- VLESS inbound uses `users[].uuid`.
- Shared listen fields use `listen` and `listen_port`.
- REALITY is configured under inbound TLS, with `reality.enabled`,
  `handshake.server`, `handshake.server_port`, `private_key`, and `short_id`.

Primary docs used:

- <https://sing-box.sagernet.org/configuration/inbound/vless/>
- <https://sing-box.sagernet.org/configuration/shared/listen/>
- <https://sing-box.sagernet.org/configuration/shared/tls/>

## What changed

### `lattice-server`

- Added `internal/proxycore/singbox.go`.
- Added `RenderSingBoxConfigJSON(profile, inbounds, users, opts)`.
- Added `RenderSingBoxConfig(...)` for in-memory structural generation.
- Added `SingBoxArtifact` containing:
  - rendered JSON,
  - canonical config SHA-256,
  - target config path,
  - non-fatal warnings for omitted users.
- Added table-driven tests in `internal/proxycore/singbox_test.go`.

## Security decisions

- **No string-templated JSON.** The renderer builds typed Go structs and uses
  `encoding/json`, so operator labels cannot break JSON syntax.
- **Fail-closed enum handling.** Any non-MVP core/protocol/transport/security
  is rejected instead of silently passed through.
- **No silent transport ignores.** TCP MVP rejects `path`/`host`, because those
  fields belong to future WS/gRPC/HTTP transports.
- **Reality requirements are explicit.** The renderer requires a private key,
  at least one non-empty even-length hex short ID, and a valid
  `host:port` handshake target.
- **Listen address must be an IP.** Hostnames are not accepted for local bind
  addresses; DDNS hostnames belong in subscriptions later, not in `listen`.
- **Eligible users only.** Disabled, expired, over-quota, and unknown-status
  users are omitted from the rendered config with warnings.
- **Duplicate UUIDs fail.** A duplicated VLESS UUID across eligible users is a
  hard error.
- **Secret scope is narrow but real.** The artifact contains the VLESS UUIDs
  and REALITY private key needed by the target node. It must only travel through
  the reviewed future `proxycore` plan/apply path to the owning node. It does
  not include subscription tokens or proxy passwords for the VLESS MVP path.

## Verification

Run from `lattice-server`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -count=1 ./internal/proxycore
```

Result: pass.

The test suite covers:

- successful VLESS+REALITY config shape,
- canonical SHA-256 calculation,
- default and profile-overridden config path/listen address,
- no subscription-token/password leakage into the VLESS config,
- disabled/expired/over-quota user omission warnings,
- rejection of unsupported core/protocol/transport/security combinations,
- rejection of ignored `path`/`host` fields in the TCP MVP,
- rejection of bad listens, bad UUIDs, empty short IDs, unsafe ALPN values,
  duplicate ports, and duplicate UUIDs.

## Local review notes

No public network surface was added in this iteration. The main risk is future
misuse of `SingBoxArtifact.ConfigJSON`; callers must treat it as a
secret-bearing, node-scoped artifact and must not serialize it into list/read
views or audit messages. Future plan/apply code must bind the exact artifact
hash into the approval.

## Next work

1. Add proxy read/admin HTTP APIs with secret-free view structs.
2. Add `/api/proxy/nodes/{id}/plan` that resolves profile + inbounds + users,
   calls this renderer, and creates a `Plugin:"proxycore"` approval bound to
   `ConfigSHA256`.
3. Add the `applyScriptFor("proxycore")` branch with heredoc write,
   `sing-box check`, atomic swap, reload/restart fallback, and status
   reconciliation.
4. Only after plan/apply is safe, add `/sub/{token}` with an opaque token index
   or constant-time scan plus rate limiting; never persist raw subscription
   tokens as map keys.

