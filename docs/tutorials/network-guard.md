# Network Guard

Lattice treats nftables as a privileged core provider. All firewall mutations
must go through `plan -> approve -> apply`; agents never author policy.

The operator creates a plan from the dashboard:

- Public TCP ports, for example `80,443`.
- WireGuard TCP ports, for example `22,9100`.
- WireGuard UDP ports, for example `51820`.
- WireGuard CIDR, default `10.66.0.0/24`.

The baseline Network Guard plan stores the generated `inet lattice_guard`
ruleset as an approval. Approval now queues an agent-side guard apply task:

- write `/etc/lattice/guard.nft.new`;
- validate with `nft -c -f`;
- snapshot the current ruleset to `/etc/lattice/guard.rollback.nft`;
- arm a 60s watchdog rollback;
- commit with `nft -f`;
- run `lattice-agent --selfcheck-controlplane -server <public-url>` when the
  server public URL is configured;
- move the candidate to `/etc/lattice/guard.nft` after validation succeeds.

If `public_url` is unset, the guard apply still validates, snapshots, and commits
the nft ruleset, but it cannot perform the control-plane selfcheck. Production
deployments should set `LATTICE_PUBLIC_URL` / `-public-url`.

Ingress NetPolicy composition:

- Save ingress rules in the Network Policy panel.
- Save or load the target node's Network Guard inputs.
- Create a Network Guard plan for the same node. The server folds enabled
  ingress rules into the same `lattice_guard` input chain before broad public
  or WireGuard service allows.
- A caller with `network:plan` must also have `netpolicy:read` on that node when
  ingress policy exists; otherwise Lattice rejects the plan rather than silently
  omitting access-control rules.

Per-node Network Policy has a narrower committed apply MVP:

- Save egress rules in the dashboard Network Policy panel.
- Click `Plan Apply` to call `/api/netpolicy/plan`.
- Review the generated `nftpolicy` approval. Pending high-risk approvals require
  `plan_sha256`, computed by the dashboard from the visible plan text.
- Approve with queue apply. The agent writes the candidate ruleset, validates
  `nft -c`, snapshots rollback state, arms a 60s watchdog, applies the dedicated
  `inet lattice_policy` output table, then runs
  `lattice-agent --selfcheck-controlplane -server <public-url>`.
- If you edit the saved policy after planning, Lattice clears the current plan
  hash. Re-plan before approving; stale approvals and stale task results cannot
  mark the edited policy as applied.

Current limitations: `POST /api/netpolicy/plan` remains **egress-only** and
ingress enforcement is composed via Network Guard's `lattice_guard` plan
instead. The server `PublicURL` may be an IPv4 literal, IPv6 literal, or an
HTTPS hostname: IPv4 renders a direct control-plane allow; HTTPS hostnames render
`lattice_control4` and `lattice_control6`, which the node apply task fills
through `lattice-agent --update-nft-domain-set` before selfcheck. IPv6 literal
control-plane URLs render a direct `ip6 daddr` allow. On systemd hosts,
domain-backed applies also install `lattice-nftpolicy-domain-refresh.timer` to
refresh those sets every minute. Domain-valued policy remotes,
operator-authored IPv6 policy remotes, and non-systemd scheduling remain later
design slices so trust semantics stay explicit.

Recommended host firewall layers:

- `netdev ingress` for very early stateless filtering on high-risk public nodes.
- `inet input` default drop with explicit public and WireGuard service ports.
- WireGuard peers as `/32` identities; avoid broad `AllowedIPs` on peers.
- Cloudflare origin allowlists only for HTTP origins that actually sit behind CF.
