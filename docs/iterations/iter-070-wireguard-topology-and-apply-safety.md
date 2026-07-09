# iter-070 — WireGuard topology model + apply safety parity (design-13 W1, W2)

> Status: implemented · Date: 2026-07-09
> Design: `designs/design-13-wireguard-and-netguard-plugins.md` §5.3, §5.6 (D9)
> Repos: lattice-sdk, lattice-server (`feat/netguard-foundation`)

## W2 — the headline safety gap, closed

Before this iteration, `wireguard` was the **only** host-mutating apply path
with no dead-man protection. Both nft paths validated, snapshotted, armed a
60-second detached watchdog, committed, ran a control-plane selfcheck, and
refused to report success if the watchdog had fired. WireGuard did:

```sh
mv wg0.conf.new wg0.conf
wg-quick down wg0 || true
wg-quick up wg0
```

A bad `wg0.conf` on a node whose management path rides the tunnel stranded it
with nothing to restore the previous config. `wireguardApplyScript` now has the
full chain:

1. `wg-quick strip "$CANDIDATE" > /dev/null` — parse before the kernel sees it
   (the wg-quick analogue of `nft -c`).
2. Snapshot the live `wg0.conf` to `wg0.rollback.conf`.
3. Arm a detached (`setsid`) watchdog whose rollback restores the snapshot and
   re-establishes the interface — or tears it down when there was no prior
   config.
4. Commit.
5. `lattice-agent --selfcheck-controlplane` (loudly skipped, never silently,
   when `public_url` is unset — the watchdog is then the only remaining net).
6. `assert_watchdog_clean` → disarm.

**`wg syncconf` fast path.** Peer-only changes reload without flapping
established tunnels. It is chosen only when the candidate's `[Interface]` block
is byte-identical to the active one, because `syncconf` cannot apply
interface-level changes (address, listen port, MTU); those still take the full
`down`/`up`, under the watchdog.

**Shared watchdog window.** The literal `60` is now
`applyWatchdogWindowSec`, used by both the nft and wireguard generators so the
paths cannot drift apart (gap 6). The nft generator's rendered output is
unchanged.

The nft watchdog itself was **not** touched — it is a tested, security-critical
path, so wireguard got a structurally identical but wg-specific rollback rather
than a risky refactor of a working crown-jewel.

## W1 — networks as objects, behind a render-parity gate

**lattice-sdk**: `WGNetwork` (mesh | hub-and-spoke | custom, with listen port,
keepalive, MTU, DNS), `WGMembership` (role, server-allocated address, per-member
overrides, hub `ExtraAllowedIPs`), `WGExternalPeer` (non-node devices), plus
topology/role constants.

**`internal/wireguard/topology.go`**: `BuildTopology` generalizes `BuildMesh`
while preserving every security invariant verbatim —

- a peer's own address is always pinned to a host route (`/32`, `/128`), so a
  member reporting `10.66.0.5/16` still cannot intercept peers' traffic;
- additive routes come **only** from a hub's reviewed `ExtraAllowedIPs`; a
  spoke's self-declared `0.0.0.0/0` is ignored;
- the private key never enters the package.

`MeshFromNodes` is the migration bridge from the implicit fleet mesh encoded in
`Node.WireGuard*`. `custom` topology fails closed with `ErrCustomTopology`
rather than silently degrading to mesh (which would quietly widen a
deliberately restricted topology).

`Interface` gained `MTU` and `DNS`, rendered only when set, and `AllowedIPs`
validation now accepts multi-value lists (a hub advertising routes) with every
element parsed as a CIDR.

## Verification

- SDK: `gofmt -l` clean, `go test ./...` green.
- Server: `go build`, `gofmt -l`, `go vet` clean; `go test -race ./...` green.
- **Migration gate**: `TestMeshTopologyMatchesBuildMesh` runs every node of a
  four-node fixture through both `BuildMesh` and `BuildTopology(mesh)` and
  asserts identical interfaces, identical peer slices, and identical *rendered
  configs*. The existing `BuildMesh` tests still pass unchanged.
- W2 tests: apply script contains validate → snapshot → arm → commit →
  selfcheck → assert → disarm, **in that order** (measured on the executable
  tail, not the function definitions); syncconf gated on an unchanged
  `[Interface]` block; skip-selfcheck is loud and still arms the watchdog;
  `applyWatchdogWindowSec` shared by both paths; and every generated apply
  script (nft + wireguard, with and without a public URL) passes `sh -n` — a
  check that catches quoting errors in the watchdog's nested `sh -c` bodies
  that string assertions cannot.
- Topology tests: hub/spoke edges, no spoke↔spoke, spoke cannot advertise
  routes, wide prefix pinned to `/32`, custom fails closed, unknown mode and
  non-member rejected, MTU/DNS render only when set and are validated.

## Not yet done (W1 remainder)

`WGNetwork`/`WGMembership` store collections, CRUD API, `wg show all dump`
discovery + adoption view, and the topology SVG are the next slice. Hub
masquerade/forward rules surface as NetGuard suggestions (design-13 §6), not as
implicit mutations. External-peer one-time config/QR issuance is W4.
