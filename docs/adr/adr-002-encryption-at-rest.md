<!-- Adopted 2026-06-12. Implemented and verified against source:
     internal/secret/secret.go (+_test), internal/store/crypto.go (+_test),
     internal/store/store.go (Open/OpenWithCipher/Save), cmd/lattice-server/main.go.
     Full workspace build+vet+test -race green; adversarial 3-lens security review
     run, 3 must-fix findings fixed with regression tests before adoption. -->

# ADR-002: Credential Encryption at Rest

- **Status:** Accepted (implemented)
- **Date:** 2026-06-12
- **Project priors:** Security first → functionality → usability → performance. **ZERO external Go deps** preserved (stdlib `crypto/aes`+`crypto/cipher` only).
- **Verified against code:** `lattice-server/internal/secret/`, `internal/store/crypto.go`, `internal/store/store.go`, `cmd/lattice-server/main.go`, `lattice-sdk/model/model.go`.

---

## 1. Context

The server persists its entire state as a single JSON file (`store.Save` → atomic `0600` write). That file holds reversible credentials in cleartext: TOTP shared secrets, Cloudflare API tokens, and notification channel configs (bot tokens, SMTP passwords, webhook secrets). A leaked backup, snapshot, or stray copy of the state file therefore leaks usable credentials.

**Threat model:** disk-at-rest exposure of the state file (leaked backup/snapshot/tarball). **Out of scope:** an attacker with live process memory or the master key, and (for v1) an attacker with *write* access to the on-disk file.

## 2. Decision summary

| # | Decision | Call | Why |
|---|---|---|---|
| D1 | Primitive | **AES-256-GCM** (AEAD), stdlib only | Confidentiality + integrity in one primitive; zero new deps |
| D2 | Granularity | **Field-level envelope** at the store persistence boundary | In-memory state stays plaintext → every handler/provider is unchanged |
| D3 | What is encrypted | Only **reversible** secrets: `User.TOTPSecret`, `DDNSProfile.CFAPIToken`, `DDNSProfile.WebhookHeaders`, `NotifyChannel.Config[*]` | One-way hashes (`PasswordHash`, `*CodeHashes`, `TokenHash`) are already safe at rest |
| D4 | Nonce | **Fresh 96-bit random nonce per encryption**, prepended | GCM nonces must never repeat under a key; random is safe far below the birthday bound for this volume |
| D5 | Envelope format | `lat$1$` + base64url(nonce ‖ ciphertext ‖ tag); **strict structural detection** (prefix + decodable + ≥ nonce+tag) | Versioned, self-identifying, migration-friendly |
| D6 | No in-band idempotency | `Encrypt` **always** produces fresh ciphertext; it never inspects input for an existing envelope | A "looks already encrypted?" heuristic collides with operator secrets; the store invariant (in-memory = always plaintext) makes idempotency unnecessary |
| D7 | Key resolution | `LATTICE_MASTER_KEY` (inline; `off`/`0`/… disables) **>** key file (`-master-key-file` / `LATTICE_MASTER_KEY_FILE`) **>** auto-generated `<dataDir>/master.key` (`0600`) | Secure by default with no operator burden; KMS/secret-manager injection supported |
| D8 | Failure posture | **Fail closed.** Wrong key / corrupt envelope → `Open` errors and the server refuses to start; disabled cipher on already-encrypted state → error, never silent corruption | Better to not start than to serve corrupt or downgraded credentials |
| D9 | Migration | Transparent. Legacy plaintext values (not envelopes) pass through on load and are encrypted on the next save | No migration script; old deployments self-upgrade |

**Net new dependencies:** none.

## 3. Mechanism

- **Load** (`store.Open`/`OpenWithCipher`): `json.Unmarshal` → `decryptState` decrypts the D3 fields in place → in-memory state is fully plaintext.
- **Save** (`store.Save`): `encryptedState` builds a shallow copy with the secret-bearing maps deep-copied and encrypted, then marshals the copy. Live in-memory state is never mutated, so concurrent readers and all handlers see plaintext.
- **Key** (`secret.Resolve`): resolves per D7; auto-generates a `0600` key file with `O_EXCL` (race-safe) under a `0700` data dir. The data dir is created `0700` by both the key path and `store.Save` (they must agree).

## 4. Security review outcome (2026-06-12)

A 3-lens adversarial review (crypto-correctness / coverage / failure-modes) plus synthesis returned **FIX-FIRST**; all three must-fix findings were fixed with regression tests before this ADR was accepted:

1. **(High)** `parseKey` trimmed whitespace before the raw-32-byte fallback, rejecting ~4.6% of raw keys whose boundary byte was an ASCII-whitespace value (non-deterministic boot failure). Fixed: check untrimmed length first; deterministic regression test added.
2. **(Medium)** `store.Save` created the data dir `0o755` vs `0o700` elsewhere; first-creator wins, widening the at-rest/backup surface. Fixed: both paths now `0o700`; perm test added.
3. **(Medium)** Envelope detection was a bare `HasPrefix`, so operator plaintext starting with `lat$1$` could be stored in cleartext or brick startup. Fixed: strict structural detection + removal of in-band idempotency (D6); collision regression tests added.

## 5. Accepted residuals & follow-ups (non-blocking)

- **Migration residual:** a *legacy plaintext* value that is exactly the prefix followed by a genuinely valid base64url body of ≥ nonce+tag bytes is structurally indistinguishable from ciphertext and would fail-closed on first load. Organically near-impossible (real tokens do not start with `lat$1$`). Fully eliminated only by a structural JSON tag (string→object) — a **v2** option, deferred to avoid a cross-repo model change.
- **Key-next-to-data:** the auto-generated key lives beside the ciphertext, so a single directory backup captures both. Mitigated by a loud "back this up / use an external key" startup log and env/file overrides for operators who want separation. Consider defaulting the key outside the data dir in a follow-up.
- **No AAD binding:** envelopes are not bound to record/field identity, so a *write-capable* on-disk attacker could relocate a valid envelope between fields. Out of the v1 read-at-rest threat model; add record-ID+field-name AAD if that model expands.
- **No fsync on save:** pre-existing atomic-rename-without-fsync; power-loss can tear the file. Encryption raises blast radius (no plaintext fallback), so fsync(tmp)+fsync(dir) is a worthwhile follow-up.
- **Key rotation:** wrong/lost-key is fail-closed but there is no re-encryption tool yet; rotation = decrypt-with-old then save-with-new. Tooling deferred.
