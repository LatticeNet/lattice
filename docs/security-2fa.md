# TOTP Two-Factor Authentication — Threat Model & Status

> Delivered 2026-06-12 (P0 of ADR-001). Stdlib-only (no new dependency).
> Reviewed adversarially; the findings below are tracked with their disposition.

## What ships

- **TOTP (RFC 6238)** second factor: `internal/auth/totp.go`, HMAC-SHA1, 6 digits,
  30s step, ±1 skew window. Verified against the RFC 6238 Appendix B test vectors.
  Code comparison is constant-time (`crypto/subtle`).
- **Enrollment** (`POST /api/2fa/totp/enroll`): mints a base32 secret + an
  `otpauth://` URI + 10 single-use recovery codes (shown **once**). 2FA stays
  **inactive** until a code is verified via `…/activate`, preventing lock-out from
  a mis-scanned secret.
- **Login gate**: a 2FA user's password step issues a short-lived (5 min),
  **single-use, IP-bound** challenge instead of a session; the session is granted
  only after `POST /api/login/totp` validates a TOTP **or** recovery code. There is
  no bypass — `issueSession` is unreachable for a 2FA user without the second
  factor.
- **Recovery codes**: 80-bit random, stored as SHA-256 (fast hash is sufficient at
  that entropy), **single-use**, consumed **atomically** under the store lock.
- **Management is session-only**: a PAT (bearer) is forbidden (403) from
  enroll/activate/disable, so an API token cannot strip a human's second factor.
- Every transition is audited (`2fa.enroll/activate/disable`,
  `login.totp_required`, `login.totp`, `login.totp.recovery_used`).

## Online brute-force resistance (the headline property)

The acceptance window is 3 codes in 10^6 (current ±1 step), i.e. P(one guess) =
3×10⁻⁶. Throttling is **two-layered and keyed on the *user*, not the source IP**,
so rotating IPs (a botnet/proxy pool) cannot widen the budget:

1. **Per-challenge cap** — a challenge is burned after `maxTOTPChallengeAttempts`
   (5) failed codes.
2. **Per-user failure limiter** — `totpLimiter` (Burst 5, refill 5/hour) keyed on
   `totp:<user-id>`, consumed **only on failure**. When exhausted, further
   attempts return 429, the active challenge is burned, and a notification fires.

Before this design, throttling was per-IP only: a distributed attacker holding the
password could reach ~99.99% success in a single 5-minute round at ~100k IPs.
After: total failing guesses per user ≈ 5 + 5/hour **regardless of IP count**, so a
distributed attack collapses to the same budget as a single IP, and every lockout
raises an operator alert.

## Residual risks (tracked, not yet closed)

- **R1 (was H2) — `clientIP` proxy-header handling.** When `-trust-proxy` is set,
  `clientIP` takes the left-most `X-Forwarded-For`, which a client can prepend. The
  per-user 2FA limiter neutralises the *TOTP-specific* exploit (budget is per user,
  not per IP), but the general fix — honour XFF only from a trusted-proxy CIDR and
  take the right-most untrusted hop — is a broader change to all rate limiting and
  is deferred. Mitigation today: only enable `-trust-proxy` behind a proxy that
  strips/normalises XFF (e.g. Cloudflare's `CF-Connecting-IP`).
- **R2 (was M3) — TOTP replay within the ~90s window.** A valid code is accepted
  for its step ±1 (~90s); the server does not yet record the last-consumed step per
  user. Exploiting it requires observing a live code *and* the password within the
  window. Fix (planned): persist `LastTOTPStep` and reject steps ≤ last accepted.
- **R3 — secret at rest — CLOSED 2026-06-12.** `totp_secret` is still part of the
  server state model, but ADR-002 routes it through the AES-256-GCM envelope
  encryption boundary before persistence. It is never serialised to any API
  response (only the one-time enroll body).
- **R4 — enforcement is per-user/optional.** 2FA is not yet mandatory for
  high-privilege scopes (`network:apply`, `node:admin`, `token:admin`). Operator
  decision in ADR-001 §8.

## Successor

TOTP is phishable. **WebAuthn/passkeys** (phishing- and brute-immune) is the P2
successor in ADR-001 and is the next *justified* dependency conversation.
