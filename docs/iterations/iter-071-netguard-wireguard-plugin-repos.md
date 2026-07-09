# iter-071 — netguard + wireguard plugin repos (design-13 packaging)

> Status: implemented (alpha, unsigned) · Date: 2026-07-09
> Design: `designs/design-13-wireguard-and-netguard-plugins.md` §2, §10.8
> Repos: **new** `lattice-plugin-netguard`, `lattice-plugin-wireguard`

## What shipped

Two first-party system-plugin repos, modelled directly on
`lattice-plugin-vpn-core`:

```
manifest.json
system-go/{go.mod,main.go,main_test.go}
README.md  LICENSE  .gitignore
```

- `latticenet.netguard` `0.1.0-alpha.1` — capabilities `node:read`,
  `network:plan`, `network:apply`, `task:run`.
- `latticenet.wireguard` `0.1.0-alpha.1` — same capability set.

Both implement the system-plugin stdio contract (`describe` / `health` /
`plan`) and nothing else. `apply` and `call` fail closed. Verified live:

```
$ echo '{"action":"describe"}' | ./lattice-plugin-netguard
{"ok":true,"message":"netguard capability surface","result":{...}}
$ echo '{"action":"apply"}' | ./lattice-plugin-netguard
{"ok":false,"error":"unsupported action \"apply\""}
```

Zero dependencies, pure Go, no CGO. `gofmt`, `go vet`, `go test` green in both.
Plan rendering is deterministic (sorted payload keys), asserted by test, so a
plan hash is stable.

## Unsigned, on purpose

Neither manifest carries `digest_sha256` or `signature_ed25519`. The
trusted-publisher ed25519 seed is **operator-held and never committed**. A
host-risk plugin without a valid trusted-publisher signature is refused by the
loader unless `allow_unsigned_host_risk` (dev only) is set — that is the
intended fail-closed behavior, and it must not be worked around. Signing is a
release step:

```sh
go run ./cmd/pluginsign -manifest .../manifest.json \
  -artifact .../system-go/lattice-plugin-netguard \
  -seed /path/to/latticenet-seed.bin -update-digest -write
```

`pluginsign` reuses the server's own `plugin.SigningPayload`, so the signed
bytes match the verifier byte-for-byte, and it self-verifies before writing.

Alpha releases must be cut as prereleases (`v0.1.0-alpha.N`) and must not
become GitHub `Latest`.

## Security finding: the plugin gateway cannot express per-node authorization

netguard's manifest originally declared `groups.list` / `zones.list` /
`nodes.list` under `netguard:read`. That was removed before the first release
after tracing the authorization path:

- `POST /api/plugins/call` checks an interface's declared scopes with
  `rbac.Allows(principal, scope, "")`.
- `rbac.Allows` (rbac.go:12-24) returns `true` as soon as the node id is empty,
  **even when the principal carries a non-empty `ServerAllowlist`**.
- `plugin.RPCHandler` is `func(ctx, method string, request []byte) ([]byte, error)`
  — no principal — so an in-core handler cannot re-apply the per-node allowlist
  that the REST handlers enforce.

Net: a PAT restricted to node A could have read the whole fleet's firewall
posture through the gateway. This is the same class design-11 worked around for
Sub-Store by refusing restricted principals outright.

**Decision:** both plugins ship with **no `interfaces`**. Every netguard read
and mutation stays on `/api/netguard/*`, which filters per node correctly. A
regression test in each repo asserts the manifest stays free of unauthorizable
interfaces, with the reasoning inline so a future contributor cannot re-add
them by accident.

**Open (design-13 §10.8):** extend `RPCHandler` with a principal (or an
authorization callback) before any node-scoped plugin interface is declared.
Until then the rule is: **gateway interfaces must be fleet-global.**

## Not yet done

- Signing + prerelease tags + `lattice-plugin-index` entries.
- `ui` contributions (`netguard.*` / `wireguard.*` builtin component keys),
  which require the dashboard pages *and* double registration in the server's
  `contributions.go` allow-list — that is the G4 slice.
- The wireguard plugin has no read model to expose because `WGNetwork` /
  `WGMembership` store + API is the W1b slice.
