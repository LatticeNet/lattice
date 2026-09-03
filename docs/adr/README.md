# Architecture decision records

One file per decision that was expensive to make and would be expensive to
revisit. Each records the alternatives that were rejected and the reason, so a
later reader can tell a considered choice from an accident.

| ADR | Decision | Accepted | Status |
|---|---|---|---|
| [001](./adr-001-plugin-foundation-oidc-2fa.md) | Plugin foundation, OIDC and 2FA: the plugin trust model, and the wasm tier deferred rather than built | 2026-06-12 | Current. The wasm deferral still matches doctrine. |
| [002](./adr-002-encryption-at-rest.md) | Credential encryption at rest: stdlib AES-256-GCM envelope encryption at the store boundary, zero new dependencies | 2026-06-12 | Current. |
| [003](./adr-003-proxy-stats-transport.md) | Proxy usage stats transport: reject `grpc-go`, read xray counters through the on-node `xray api statsquery` CLI | 2026-06-14 | Current for xray. Superseded by ADR-004 for sing-box. |
| [004](./adr-004-singbox-stats-grpc.md) | sing-box per-user stats through a vendored gRPC client | 2026-07-19 | Current. Supersedes ADR-003's sing-box claim. |

ADR-003 says sing-box per-user statistics are already covered by the existing
loopback HTTP source and need no new transport. That turned out to be wrong:
the Clash API on the adopted nodes reports live connections and global traffic
only, with no per-user counters, which is why ADR-004 adds the gRPC client.
ADR-003's reasoning about xray is unaffected and still holds. Read the two
together rather than either alone.

ADR-004 lived in `docs/designs/` until 2026-09-03. It was moved here so that
all four decisions sit in one place; the design directory holds capability
designs, not decisions.
