# Iteration 005 — Server HostServices Adapter (Phase B1)

- **Status:** Completed locally (2026-06-12)
- **Vision link:** `PRODUCT-VISION.md` Phase B1; follows iter-004 host-API broker contract.
- **Repo:** `lattice-server`

## 1. Goal

Wire the broker contract to real server-owned host services without adding plugin execution. This moves the plugin platform from an abstract capability facade to a concrete, audited adapter backed by the store, notification dispatcher, guarded outbound HTTP, logger, and audit sink.

## 2. Scope

- Add `Server.pluginHostServices()` returning `plugin.HostServices`.
- Implement KV host calls against the store using `bucket/key` references.
- Implement notification host calls using enabled notification channels.
- Implement HTTP egress using `internal/outbound.NewClient`.
- Implement plugin log calls through the server logger.
- Persist broker capability allow/deny events as `plugin.host.*` audit events with plugin id, capability, decision, reason, and correlation id.
- Keep plugin installation, activation, execution, routing, and lifecycle state out of scope.

## 3. Design / approach

- The adapter lives in `lattice-server/internal/server/plugin_host.go`, not in `internal/plugin`, so the plugin package remains a dependency-free contract package.
- KV keys use the existing `bucket/key` convention from worker templates and reuse `validateStorageName` for both halves.
- HTTP egress is handled by the same guarded outbound client used by webhooks, preserving DNS rebinding, redirect, private-IP, link-local, and metadata-address protection.
- Plugin HTTP request and response bodies are capped at 256 KiB.
- The adapter honors an existing context deadline; otherwise notification fanout gets a bounded default timeout.
- Host-call audit correlation is carried through `requestIDContextKey` so a future runtime can attach request/operation ids.

## 4. Risks & mitigations

- **Runtime bypass**: future execution code could call store/notify/http directly. Mitigation: docs and commit directive require runtime code to consume `plugin.Broker` + `Server.pluginHostServices()`.
- **HTTP egress abuse**: a plugin with `http:egress` could hit internal networks without guards. Mitigation: outbound client enforces URL and dial-target guard; tests cover loopback rejection.
- **Resource pressure**: plugin HTTP bodies could become memory pressure. Mitigation: request and response body caps at 256 KiB.
- **Audit gaps**: host capability decisions could occur without persistent evidence. Mitigation: broker events are persisted as `plugin.host.*` audit events.
- **Notification ambiguity**: no enabled channels is a no-op. This is acceptable for now; later runtime UX should surface "no delivery targets" as a plugin health warning.

## 5. Test plan

- `TestPluginHostServicesBrokeredKVAndAudit`: brokered KV write/read works through the server adapter, denied writes do not mutate KV, and allow/deny capability audits persist with correlation id.
- `TestPluginHostServicesHTTPUsesOutboundGuard`: loopback HTTP egress is blocked by the outbound guard while the broker allow event is audited.
- `TestPluginHostServicesHTTPRejectsOversizedRequestBodyBeforeDial`: oversized HTTP request bodies fail before outbound guard/dial.
- Existing plugin broker, plugin verifier, loader, server package, and full module tests remain green.

## 6. Exit bar

The server can construct real `plugin.HostServices` for a verified plugin broker, with KV, notification, HTTP, log, and audit surfaces wired to server-owned implementations and protected by the broker capability checks.

## 7. Execution log

- Added `internal/server/plugin_host.go`.
- Added server HostServices tests with RED -> GREEN cycles.
- Added guarded HTTP body caps.
- Reused existing store, notification channel builders, outbound guard, logger, and audit sink.
- Updated server README and architecture/product vision docs.

## 8. Review outcome

Local review focused on privilege boundaries:

- Adapter methods are not exposed through HTTP routes.
- Plugins still cannot execute; there is no lifecycle state change.
- KV validates `bucket/key` names before touching the store.
- HTTP egress uses the same guarded client as operator webhooks.
- Host capability audits include plugin id and correlation id.
- Denied broker calls do not reach host services; this remains covered by iter-004 broker tests.

## 9. Residuals & next

- Build plugin lifecycle state (`verified -> installed -> active -> disabled`) before execution.
- Add a real plugin runtime entrypoint that can only receive a `plugin.Broker`, not raw services.
- Add per-plugin rate limits for host calls, especially `http:egress`, `notify:send`, and `log:write`.
- Decide how plugin logs should be stored/queryable without polluting security audit with arbitrary plugin text.
- Add separate delivery/outcome events later where needed; `plugin.host.*` currently records broker authorization decisions, not external HTTP or notification delivery success.
