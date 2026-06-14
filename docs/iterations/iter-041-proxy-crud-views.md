# Iteration 041 — Proxy-Core CRUD and Secret-Free Views

- **Status:** Implemented and verified locally (2026-06-14)
- **Design:** [`designs/design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
- **Repos:** `lattice-server`, `lattice`

## Goal

Expose the first proxy-core control-plane API slice while preserving the
security boundary established in iter-039 and iter-040:

- CRUD for central proxy inbounds.
- CRUD for central proxy users.
- CRUD for per-node proxy render profiles.
- JSON read views that match the existing proto view contract and never expose
  bearer credentials or rendered configs.

This is still **not** the end-to-end proxy panel. `/api/proxy/nodes/{id}/plan`,
`applyScriptFor("proxycore")`, `/sub/{token}`, dashboard UI, usage accounting,
and xray remain pending.

## Routes

All routes use the existing session/PAT auth, request limiter, strict JSON
decoder for client bodies, and CSRF enforcement for interactive session writes.

| Route | Method | Scope | Notes |
|---|---:|---|---|
| `/api/proxy/inbounds` | GET | `proxy:read` | Global object; requires unrestricted server allowlist. |
| `/api/proxy/inbounds` | POST | `proxy:admin` | Create/update MVP inbounds. Global object; requires unrestricted server allowlist. |
| `/api/proxy/inbounds/delete` | POST | `proxy:admin` | Rejects referenced inbounds unless `force:true`. |
| `/api/proxy/users` | GET | `proxy:read` | Global object; requires unrestricted server allowlist. |
| `/api/proxy/users` | POST | `proxy:admin` | Create/update central users; generates UUID/sub token when absent. |
| `/api/proxy/users/delete` | POST | `proxy:admin` | Deletes a user identity. |
| `/api/proxy/profiles` | GET | `proxy:read` | Per-node list filtered by `ServerAllowlist`. |
| `/api/proxy/profiles` | POST | `proxy:admin` + node allowlist | Create/update one node profile. |
| `/api/proxy/profiles/delete` | POST | `proxy:admin` + node allowlist | Delete one node profile by `node_id`. |

## Security decisions

- **Global objects require global authority.** `ProxyInbound` and `ProxyUser`
  are fleet-wide policy/credential objects, not node-scoped resources. A PAT
  with `ServerAllowlist:["node-a"]` can manage `node-a` profiles but cannot list
  or mutate global inbounds/users.
- **Profiles are node-scoped.** Profile list output is filtered by
  `ServerAllowlist`; writes/deletes require `proxy:admin` for the target node.
- **Secret-free views only.**
  - `ProxyInboundView` exposes `has_reality_private_key`, never
    `reality_private_key`.
  - `ProxyUserView` exposes `has_uuid`, `has_password`, and `has_sub_token`,
    never `uuid`, `password`, or `sub_token`.
  - Render artifacts from iter-040 are not exposed by any CRUD route.
- **MVP-limited input.** The API accepts only the renderer-supported shape:
  `sing-box`, `vless`, TCP, REALITY. xray, WS/gRPC/HTTP transports,
  certificate TLS, fingerprints, and Shadowsocks method fields remain future
  slices.
- **Write-only secret preservation.** Updating an inbound without
  `reality_private_key` preserves the stored private key. Updating a user
  without credential fields preserves stored credentials.
- **Server-generated user credentials.** New proxy users receive a UUID v4 and
  a 256-bit subscription token when the caller does not supply them.

## Verification

Run from `lattice-server`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -count=1 ./internal/server -run 'TestProxy|TestDNSDeployment|TestNetPolicyAllowlist|TestDDNSRequiresScope'

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -count=1 ./internal/proxycore ./internal/store

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -race -count=1 ./internal/server -run 'TestProxy'

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go build ./cmd/lattice-server
```

Results:

- server targeted tests: pass
- proxycore/store tests: pass
- proxy server race test: pass
- server build: pass

Known environment note: the Go tool still prints a non-fatal stat-cache warning
when it attempts to write under `/Users/cdcd/go/pkg/mod/cache`; the command
exit code is 0.

## Tests added

- Create/list inbound and user views hide secrets.
- Inbound update preserves write-only `reality_private_key`.
- Restricted PAT cannot read global inbounds/users.
- Restricted PAT can manage/list only allowed node profiles.
- Deleting an inbound referenced by a profile returns conflict unless forced.
- Unsupported MVP input (for example WS transport) is rejected.
- `host:port` fields reject service-name ports such as `:https`; only numeric
  ports are accepted for deterministic config rendering.

## Next work

1. Implement `/api/proxy/nodes/{id}/plan` using the iter-040 renderer and the
   iter-041 CRUD data.
2. Bind the exact rendered config hash into a `Plugin:"proxycore"` approval.
3. Add `applyScriptFor("proxycore")` with `sing-box check`, atomic swap,
   reload/restart fallback, and status reconciliation.
4. Add subscription link generation only after the plan/apply path is safe.
