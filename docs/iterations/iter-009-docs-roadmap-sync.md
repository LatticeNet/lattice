# Iteration 009 - Documentation and Roadmap Sync

- **Date:** 2026-06-12
- **Phase:** Program hygiene / planning sync
- **Repos:** `lattice`
- **Status:** Verified

## Goal

Bring the umbrella documentation back in line with the current six-repo state
after the OIDC, 2FA, audit WAL, at-rest encryption, plugin loader, lifecycle,
host broker, dashboard, and runtime runner-contract work.

## Scope

- Update the umbrella README's current MVP and design defaults.
- Replace old SQLite storage language with the bbolt direction.
- Mark delivered identity, plugin-loader, audit-WAL, at-rest-encryption, and
  runner-contract work in the product vision and roadmap.
- Reconcile the June program review so it no longer describes plugin trust or
  audit integrity as purely future work.
- Close the stale TOTP secret-at-rest residual after ADR-002.

## Current Truth

- Six repos remain split by deployment and trust boundary:
  `lattice-server`, `lattice-node-agent`, `lattice-dashboard`, `lattice-sdk`,
  `lattice-plugin-template`, and `lattice`.
- The control plane has OIDC/SSO backend + dashboard provider UI, TOTP 2FA,
  AES-256-GCM secret encryption, and a tamper-evident audit WAL.
- The plugin platform now has signed manifest verification, startup loading,
  lifecycle registry/API/UI, a capability-scoped host broker, and a bounded
  runner contract.
- Plugin artifacts still do **not** execute. The default runner is `noop`.
- The biggest backend constraint is still whole-file JSON state writes. The
  planned replacement is bbolt, preserving pure Go and zero CGo.

## Long-Term Order

1. **Durability first:** migrate JSON state to bbolt, preserve encryption, add
   JSON export/import, and move high-churn ephemeral records off full-file
   rewrites.
2. **Usability parity:** dashboard coverage for DDNS, monitors, notify,
   WireGuard, tunnels, PATs, audit WAL verification, and runtime drill-through.
3. **Execution later:** concrete plugin runners only after capability checks,
   resource limits, cancellation, output/log caps, isolation, and adversarial
   tests are in place.
4. **Fleet hardening:** node-token last-used/source-IP policy, enforced MFA,
   WebAuthn/passkeys, agent mTLS, signed releases, and remote audit head
   anchoring.

## Verification

- Reviewed current repo status across all six Lattice repositories before
  editing.
- Checked current server code for audit WAL, plugin startup loader, trust policy,
  and runtime manager wiring before updating conclusions.
- Ran `git diff --check` on the umbrella repo after edits.

## Residuals

- This iteration is documentation-only.
- No rendered docs site exists yet, so verification is markdown/static only.
