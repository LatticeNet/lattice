# Iteration 003 — Plugin Verify API (Phase B preflight)

- **Status:** Completed locally (2026-06-12)
- **Vision link:** `PRODUCT-VISION.md` Phase B; prepares the host-API broker and marketplace flow.
- **Repo:** `lattice-server`

## 1. Goal

Expose the existing plugin manifest trust model through a real control-plane API so operators, dashboards, and future plugin stores can validate a candidate plugin before installation. This makes signed-plugin security operational instead of leaving it as only a loader/library concern.

## 2. Scope

- Add `POST /api/plugins/verify` protected by `plugin:verify`.
- Accept a manifest JSON object plus `artifact_base64`.
- Apply the server's configured `PluginTrust` policy, including fail-closed host-risk signature enforcement.
- Return a safe preflight response: `trusted`, manifest projection, `artifact_sha256`, and per-capability risk labels.
- Do **not** persist, install, register, or execute the plugin artifact.
- Audit allow/deny decisions under `plugin.verify`.

Out of scope: plugin upload storage, install/enable lifecycle, host-API broker, plugin execution, marketplace fetching, dashboard UI.

## 3. Design / approach

- Reuse `plugin.VerifyInstallManifest`, not a separate parser, so the API and startup loader share strict manifest decoding, digest verification, and Ed25519 trust policy behavior.
- Keep trust policy server-side only. Clients cannot loosen `AllowUnsignedHostRisk` or supply trusted publisher keys in the request.
- Use a dedicated `plugin:verify` scope instead of `audit:read` or `plugin:*` so preflight validation can be delegated narrowly.
- Bound the full HTTP request body (`4 MiB`) and reject unknown top-level JSON fields.
- Strip `signature_ed25519` from the response. The signature is not secret, but callers do not need it echoed and large signatures should not become UI state.
- Sort capability risk summaries for deterministic UI/tests.

## 4. Risks & mitigations

- **Installation confusion**: verify could be mistaken for install. Mitigation: endpoint only returns a response and tests assert `/api/plugins` remains empty.
- **Trust policy bypass**: request could try to self-certify trust. Mitigation: request body has no policy field; server uses `Options.PluginTrust`.
- **Large upload pressure**: base64 artifact could become a DoS vector. Mitigation: strict HTTP request-body cap and preflight-only semantics; large artifact workflows should use a later streaming/install design.
- **Scope creep**: plugin verification should not grant execution. Mitigation: no store writes, no plugin registry mutation, no host API binding.
- **Audit gaps**: denied plugin verification should be visible. Mitigation: allow and deny paths record `plugin.verify` audit events.

## 5. Test plan

- `TestPluginVerifyEndpointAcceptsTrustedSignedHostRiskManifest`: trusted publisher signature verifies, response strips signature, returns hash and risk labels, and does not install.
- `TestPluginVerifyEndpointRejectsUnsignedHostRiskAndDoesNotInstall`: zero-value trust policy rejects unsigned host-risk manifest and does not install.
- `TestPluginVerifyEndpointRequiresPluginVerifyScope`: `audit:read` PAT is denied, `plugin:verify` PAT is allowed.
- `TestPluginVerifyEndpointRejectsOversizedRequestEvenWithValidJSONPrefix`: total request size is enforced even when a valid JSON object appears before oversized padding.
- Existing plugin loader tests continue to cover startup registration and rejected bundle audit behavior.

## 6. Exit bar

The server has a scoped, audited, fail-closed plugin preflight API that reuses the same trust verifier as startup loading, returns deterministic risk metadata, and leaves the plugin registry untouched.

## 7. Execution log

- Added server-held `pluginTrust` so API preflight and startup loader share the configured operator policy.
- Added `/api/plugins/verify` route under `plugin:verify`.
- Added strict request-size-capped JSON decoding for this upload-shaped endpoint.
- Added response projection with signature stripped and per-capability risk labels.
- Added deny/allow audit events for `plugin.verify`.
- Documented the endpoint in `lattice-server/README.md`.

## 8. Review outcome

Local review focused on trust boundaries:

- Client cannot submit trust-policy overrides.
- Verification uses existing strict manifest verifier.
- Success response does not expose artifact bytes or echo signature.
- Failure responses do not include secrets; digest mismatch can expose a hash only.
- No code path writes to the store or mutates `s.plugins`.
- New scope is narrower than `audit:read`; PAT scope tests cover this boundary.

## 9. Residuals & next

- This is still a preflight API, not an installer.
- The next Phase B slice should be the host-API broker: capability-scoped interfaces for KV/static/notify/log/http-egress before any plugin execution path exists.
- Later install/fetch design should avoid large JSON base64 uploads for real plugin artifacts; use streaming upload or signed marketplace fetch with the same verifier.
