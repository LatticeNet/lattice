# Iteration 004 — Host-API Broker Contract (Phase B1)

- **Status:** Completed locally (2026-06-12)
- **Vision link:** `PRODUCT-VISION.md` Phase B1; follows iter-003 plugin preflight verification.
- **Repo:** `lattice-server`

## 1. Goal

Make the plugin host boundary real before any plugin execution path exists. A verified plugin must not receive raw server handles; it receives a broker facade that checks the plugin's declared capabilities on every host call and emits host-call allow/deny events.

## 2. Scope

- Add `internal/plugin.Broker`, constructed from a verified `plugin.Loaded` entry.
- Add explicit host-service interfaces for KV, notification fanout, outbound HTTP, plugin logs, and host-call audit events.
- Gate each call on a capability:
  - `kv:read` -> `KVGet`
  - `kv:write` -> `KVPut`
  - `notify:send` -> `Notify`
  - `http:egress` -> `HTTPDo`
  - `log:write` -> `Log`
- Add `http:egress` and `log:write` to the manifest capability lattice as write-risk capabilities, available to wasm/system tiers but not worker-tier by default.
- Keep execution, install/activation lifecycle, and server wiring out of scope.

## 3. Design / approach

- The broker stays in `internal/plugin` because it depends on verified plugin metadata but does not depend on `server`, `store`, or network packages.
- `HostServices` is dependency-injected. The real server remains responsible for implementing KV, notification, guarded HTTP, logs, and audit sinks.
- Authorization is per call, not only at broker creation. This keeps the future execution/runtime path from caching a raw service handle and bypassing capability checks.
- `ErrCapabilityDenied` wraps a concrete `CapabilityError` so callers can use `errors.Is` while logs/audits still include exact plugin id and capability.
- Request/response byte slices and string maps are copied at the broker boundary to avoid accidental mutable aliasing between plugin and host implementations.

## 4. Risks & mitigations

- **False sense of safety**: a broker contract is not a sandbox. Mitigation: document that install/execution/lifecycle are still separate work.
- **Capability drift**: new capability strings could skip the ADR table. Mitigation: update ADR-001 capability-binding table and tutorials in this slice.
- **Raw-handle bypass**: future runtime code could call services directly. Mitigation: broker is the only exported contract for plugin host calls; execution wiring must depend on this facade.
- **HTTP egress risk**: `http:egress` could become SSRF if implemented naively. Mitigation: broker docs require the injected HTTP host to enforce the existing outbound guard before dialing.

## 5. Test plan

- `TestValidateManifestAcceptsBrokerCapabilitiesForWasm`: `http:egress` and `log:write` are recognized write-risk capabilities for wasm/system use.
- `TestBrokerDeniesHostCallsWithoutDeclaredCapabilityAndAudits`: a read-only plugin can read KV, but write/notify/http/log calls are denied and audited without reaching host services.
- `TestBrokerAllowsOnlyDeclaredHostAPIs`: declared write/egress/log capabilities reach exactly their injected services; undeclared `kv:read` still fails.
- `TestBrokerRejectsCapabilitySetThatDoesNotMatchManifest`: broker construction fails if `Loaded.Capabilities` does not match the verified manifest capabilities.
- `TestBrokerRejectsInvalidLoadedManifest`: broker construction defensively reruns manifest validation and rejects invalid loaded metadata.
- Existing manifest, loader, and plugin verification tests remain green.

## 6. Exit bar

The repository has a compile-tested, unit-tested host-API broker contract with explicit capability gates and audit hooks, but no plugin execution side effects.

## 7. Execution log

- Added `internal/plugin/broker.go`.
- Added host-service interfaces and DTOs: KV, notify, HTTP, log, audit event.
- Added `ErrCapabilityDenied` / `CapabilityError` / `ErrHostServiceUnavailable`.
- Added `http:egress` and `log:write` to the capability lattice.
- Added broker tests with a RED -> GREEN cycle.
- Tightened broker construction so loaded capabilities must match manifest capabilities exactly.
- Tightened broker construction so loaded manifests must still pass `ValidateManifest`.
- Updated server README, architecture, ADR-001, product vision, and plugin tutorial docs.

## 8. Review outcome

Local review focused on the trust boundary:

- Broker is created from verified `Loaded` metadata, not a caller-supplied arbitrary scope list.
- Broker reruns manifest validation as defense in depth before binding host services.
- Broker rejects inconsistent `Loaded` values where granted capabilities drift from manifest capabilities.
- Each host call checks the matching capability before service dispatch.
- Denied calls do not reach host services.
- Allow and deny decisions can be sent to an audit sink.
- The broker does not install, activate, run, or schedule plugins.
- HTTP egress remains abstract and must be backed by the server-owned SSRF guard.

## 9. Residuals & next

- Server-owned KV/notify/outbound/log/audit implementations are wired in iter-005.
- Build plugin lifecycle state (`verified -> installed -> active -> disabled`) before execution.
- Add per-plugin rate limits and output/log caps before exposing `Log` or `HTTPDo` to real runtime code.
- Decide whether `log:write` should be available to worker-tier plugins once worker routing moves onto this broker.
