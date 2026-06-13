# Iteration 019 — Shared nft Input Persistence

- **Status:** Implemented and verified (2026-06-13)
- **Design links:** `docs/designs/README.md`, `design-02-self-host-dns.md`,
  `design-05-network-acl-and-map.md`
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Create the small shared state layer both self-host DNS and per-node ACL need:
each node now has one authoritative baseline nft input record. Future providers
compose into that record before rendering the single `inet lattice_guard` table,
instead of creating competing nft tables or independent one-shot plans.

This is intentionally not the full Design 05 ACL compiler and not the DNS
deployment feature. It is the prerequisite that lets those features share one
firewall source of truth.

## Scope Landed

- `lattice-sdk`
  - Added `model.NFTInputs` with node id, interface, WireGuard CIDR, public
    TCP/UDP ports, and WireGuard TCP/UDP ports.
  - Added proto-facing `NFTInputsView`.

- `lattice-server`
  - Added `PublicUDP` support to `internal/network.NFTPlan`.
  - Added `network.NormalizeNFTPlan` to apply defaults, canonicalize the
    WireGuard CIDR, validate interface names and ports, and sort/dedupe port
    lists.
  - Added JSON state + bbolt bucket/record-level storage for `NFTInputs`
    (keyed by `NodeID`).
  - Added API:
    - `GET /api/network/nft/inputs` (`network:plan`, per-node filtered)
    - `POST /api/network/nft/inputs` (`network:plan`, upsert)
    - `POST /api/network/nft/inputs/delete` (`network:plan`, delete)
  - Updated `POST /api/network/nft/plan`: if the request body includes nft
    inputs it keeps backward-compatible one-shot behavior; otherwise it renders
    from the persisted node inputs, falling back to the safe default baseline.

- `lattice-dashboard`
  - Updated Network Guard with interface, WireGuard CIDR, public UDP, saved
    input list, edit/delete actions, and a save-then-plan workflow.
  - Added pure `assets/nft.js` helper tests for port parsing and payload
    normalization.

## Security Notes

- `NFTInputs` are not secret and are stored plaintext for review/diffability.
- Mutations require `network:plan`; actual host changes still require the
  existing approval path and `network:apply`.
- Node allowlists are enforced against the real `node_id` on list/upsert/delete.
- Values are normalized before storage so attacker-controlled strings cannot be
  interpolated into nft syntax. Rendering still validates again before creating
  an approval.
- The current nft apply branch still performs `nft -c` validation only; the
  future Design 05 committed apply path must add the documented dead-man
  rollback before it ever runs `nft -f`.

## Verification Evidence

- SDK: `go test ./... -count=1`, `go vet ./...`
- Server: `go test ./internal/network ./internal/store ./internal/server -count=1`,
  then `go test ./... -count=1`, `go vet ./...`, `go test -race ./... -count=1`
- Dashboard: `node --check assets/app.js`, `node --check assets/nft.js`,
  `node --test assets/*.test.mjs`
- HTTP smoke: enroll a node, save nft inputs including public UDP, create a plan
  with only `node_id`, and confirm the approval plan comes from the stored
  canonical state.

All checks above passed during the iteration. The smoke result confirmed:
`saved=gmami-jp1:ens3:10.66.0.0/24:53`, `plan_contains_udp=True`,
`plan_contains_cidr=True`, `plugin=nft`, `status=pending`.

## Review Focus

- Does every route enforce node-scoped `network:plan`?
- Does stored state canonicalize rather than preserving ambiguous operator
  input?
- Does bbolt import/export and record-level access include the new bucket?
- Does the dashboard avoid making security decisions and simply submits the
  server-normalized inputs?

## Residuals / Next

- Full Design 05 ACL policy (`NetPolicy`, graph, map, committed nft apply with
  rollback) remains next.
- Self-host DNS still needs `DNSDeployment`, CoreDNS rendering, DDNS publishing,
  and composition of DNS ports into the stored `NFTInputs`.
- The dashboard's Network Guard is functional but still utilitarian; the later
  Design 05 map pass should redesign the whole network surface.
