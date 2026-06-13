# Iteration 015 - bbolt Secret-Bearing Bucket Coverage

- **Date:** 2026-06-13
- **Phase:** C1 storage foundation
- **Repos:** `lattice-server`, `lattice`
- **Status:** Verified secret-bearing bucket record APIs / default store not switched

## Goal

Close the largest remaining bbolt record-level gap before runtime cutover:
secret-bearing and identity/auth buckets. The bbolt foundation now needs to
write these records one-at-a-time without leaking reversible credentials to disk
and without weakening the existing encrypted JSON store.

## Scope

- Extract per-record encryption helpers from the full-state encryption boundary.
- Extend the encrypted-at-rest set:
  - `User.TOTPSecret`
  - `Session.ID`
  - `Session.CSRFToken`
  - `TOTPChallenge.ID`
  - `DDNSProfile.CFAPIToken`
  - `DDNSProfile.WebhookHeaders`
  - `NotifyChannel.Config[*]`
  - `OIDCProvider.ClientSecret`
  - `OIDCAuthState.State`
  - `OIDCAuthState.CodeVerifier`
- Store active-session, TOTP-challenge, and OIDC-auth-state bbolt/JSON map keys
  under SHA-256 opaque keys when encryption is enabled, while still accepting
  legacy plaintext keys on read/delete.
- Add bbolt record-level APIs for:
  - users and recovery-code consumption
  - PAT token records
  - sessions
  - TOTP challenges
  - DDNS profiles
  - notification channels
  - OIDC providers
  - OIDC identities
  - OIDC auth states
- Preserve current JSON-store behavior:
  - session/TOTP/OIDC auth state expiry sweeps and caps
  - OIDC auth states are single-use
  - recovery codes are single-use and constant-time compared
  - DDNS, notify, and OIDC provider list ordering
  - missing OIDC provider delete returns an error

## Non-Goals

- Do not switch server startup to bbolt.
- Do not add a runtime `-data-engine=bolt` flag yet.
- Do not anchor the audit WAL into bbolt.
- Do not change public API handlers to consume `BoltStateStore`.

## Security Notes

- `OIDCAuthState.CodeVerifier` was not previously in the full-state encryption
  list. This slice adds it because it is PKCE verifier material for an in-flight
  OAuth2 login.
- `Session.ID`, `TOTPChallenge.ID`, and `OIDCAuthState.State` are also bearer or
  bearer-adjacent material. When encryption is enabled, their persisted map keys
  become SHA-256 opaque keys and their value fields are encrypted.
- Legacy plaintext files remain loadable with a configured cipher because
  `secret.Cipher.Decrypt` passes non-envelope plaintext through; the next save
  migrates them to encrypted/opaque-key form.
- Opening encrypted auth-flow data with a disabled or wrong cipher fails closed.

## Verification Plan

- JSON store tests:
  - active session ID/CSRF, TOTP challenge ID, OIDC state, and PKCE verifier do
    not appear in `state.json`.
  - reopen with the correct key recovers and consumes those records.
  - wrong key fails open.
- bbolt tests:
  - record-level writes do not leak TOTP, session, TOTP challenge, DDNS, notify,
    OIDC provider, OIDC auth-state, or PKCE verifier material.
  - all secret-bearing records decrypt through their bbolt APIs.
  - recovery code, TOTP challenge, OIDC auth state, delete, and reopen semantics
    are preserved.
  - wrong key fails both record-level reads and full export.

Commands:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./internal/store -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./... -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go vet ./...
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test -race ./... -count=1
```

## Verification Result

All planned checks passed:

- `go test ./internal/store -count=1`
- `go test ./... -count=1`
- `go vet ./...`
- `go test -race ./... -count=1`
- `git diff --check` in both `lattice-server` and `lattice`

The race suite completed with `internal/server` as the long pole (`93.788s`)
and no race failures.

## Residuals

- Runtime still defaults to encrypted JSON.
- A bbolt runtime flag remains pending.
- Audit WAL head anchoring and backup/restore drills remain pending.
- Release notes should call out that encrypted JSON state now obscures active
  auth-flow keys when a master key is configured.
