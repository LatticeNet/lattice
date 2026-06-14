# Network Guard

Lattice treats nftables as a privileged core provider. All firewall mutations
must go through `plan -> approve -> apply`; agents never author policy.

The operator creates a plan from the dashboard:

- Public TCP ports, for example `80,443`.
- WireGuard TCP ports, for example `22,9100`.
- WireGuard UDP ports, for example `51820`.
- WireGuard CIDR, default `10.66.0.0/24`.

The baseline Network Guard plan stores the generated `inet lattice_guard`
ruleset as an approval. Approval currently queues an agent-side `nft -c -f`
validation task for that baseline path, which prevents accidental immediate
input-firewall changes during local development.

Per-node Network Policy has a narrower committed apply MVP:

- Save egress rules in the dashboard Network Policy panel.
- Click `Plan Apply` to call `/api/netpolicy/plan`.
- Review the generated `nftpolicy` approval. The plan is hash-bound by the
  approval endpoint when the client supplies `plan_sha256`.
- Approve with queue apply. The agent writes the candidate ruleset, validates
  `nft -c`, snapshots rollback state, arms a 60s watchdog, applies the dedicated
  `inet lattice_policy` output table, then runs
  `lattice-agent --selfcheck-controlplane -server <public-url>`.
- If you edit the saved policy after planning, Lattice clears the current plan
  hash. Re-plan before approving; stale approvals and stale task results cannot
  mark the edited policy as applied.

Current limitations: NetPolicy apply is **egress-only**, requires an IPv4-literal
server `PublicURL`, and does not compile ingress/IPv6/domain-backed nft sets yet.
Those remain later design slices so the input hook and DDNS trust semantics are
handled deliberately.

Recommended host firewall layers:

- `netdev ingress` for very early stateless filtering on high-risk public nodes.
- `inet input` default drop with explicit public and WireGuard service ports.
- WireGuard peers as `/32` identities; avoid broad `AllowedIPs` on peers.
- Cloudflare origin allowlists only for HTTP origins that actually sit behind CF.
