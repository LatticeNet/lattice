# Network Guard

Lattice treats nftables as a privileged system plugin.

The operator creates a plan from the dashboard:

- Public TCP ports, for example `80,443`.
- WireGuard TCP ports, for example `22,9100`.
- WireGuard UDP ports, for example `51820`.
- WireGuard CIDR, default `10.66.0.0/24`.

The server stores the generated ruleset as an approval. Approval currently queues
an agent-side `nft -c -f` validation task. This prevents accidental immediate
firewall changes during local development.

Recommended host firewall layers:

- `netdev ingress` for very early stateless filtering on high-risk public nodes.
- `inet input` default drop with explicit public and WireGuard service ports.
- WireGuard peers as `/32` identities; avoid broad `AllowedIPs` on peers.
- Cloudflare origin allowlists only for HTTP origins that actually sit behind CF.

