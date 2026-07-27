# Release pin graph — current state (refreshed 2026-07-27)

> TASK-0010 slice 1 (operator ruling 2026-07-26 §1b). Every cross-repo pin as it exists today,
> each claim with its source of truth (repo + file). Gaps are named explicitly — they are the
> requirements list for the release-manifest format (slice 2) and the `rules/01 §8.5`
> promotion amendment (slice 3). Nothing in this document changes behavior.

## 1. The graph — who pins whom, and where

| Consumer → dependency | Pin mechanism | Value today | Source of truth |
|---|---|---|---|
| lattice-server → lattice-sdk | `sdk.ref` SHA file + go.mod pseudo-version | `4a318f24…` / `v0.2.18-0.20260722123932-4a318f246d23` | `lattice-server:sdk.ref`, `lattice-server:go.mod` (integration `86422a1`) |
| lattice-server → lattice-dashboard | `dashboard.ref` SHA file (image embeds the built dashboard) | `a927c6c…` | `lattice-server:dashboard.ref` (integration `86422a1`) |
| lattice-node-agent → lattice-sdk | go.mod pseudo-version | `v0.2.18-…-4a318f246d23` (same commit as server's) | `lattice-node-agent:go.mod` (integration `03f730a`) |
| ghcr image ← lattice-server | tag-triggered build: pushing `alpha-X.Y.ZaN` IS the release trigger; the image embeds both refs above | latest observed: `alpha-0.2.2a2` | `lattice-server:.github/workflows/container.yml`, git tags |
| plugin-index → each plugin | `plugins.json`: per-plugin `channels` (stable/alpha) + `releases[]` carrying `manifest_url`, `artifact_url`, `artifact_sha256`, `signature_ed25519`; publisher ed25519 key pinned at index level | schema `lattice.plugin.index.v1`, `status: "draft"`, generated 2026-07-22 | `lattice-plugin-index:plugins.json` |
| each plugin (internal) | manifest `version` = `ui/package.json` = Go const, moved together; artifact digest ↔ manifest signature | e.g. sub-store `0.3.2-alpha.4` | each plugin repo: `manifest.json`, `ui/package.json`, `system-go` const; `tools/bump.sh` |
| dashboard → server | none at build time; runtime API compatibility only. Post-deploy check: About page must show matching versions | — | workspace release law (root AGENTS.md) |
| plugins → server | **NOTHING** — see gap G1 | — | — |
| Astra → sing-box fork / server | not machine-resolvable from `Package.swift` — see gap G4 | — | — |
| fleet nodes → sing-box fork binary | deployed binary; version recorded in no repo file — see gap G4 | — | — |

## 2. Version state (refreshed 2026-07-27 after the first signing wave + two image trains)

| Repo | Stable | Current line | Signed bundle digest |
|---|---|---|---|
| lattice-server | `v0.2.1` | image train **`alpha-0.2.2a4`** (deployed); integration `c9c6710` | — |
| lattice-sdk | `v0.2.9` | integration `c3f2973`; carries the plugin SDK module (`00943f6e`) | — |
| lattice-dashboard | — | `v0.2.2-alpha.6`; integration `8e6c206` (reconciled union) | — |
| lattice-node-agent | — | `v0.3.3-alpha.2` | — |
| plugin vpn-core | index `stable: 0.7.2` | **0.8.0-alpha.6** | `d2e681a6…` |
| plugin sub-store | — | **0.4.0-alpha.1** (embedded-engine line) | `e0524e35…` |
| plugin wireguard | — | **0.1.0-alpha.8** | `34eb6c07…` |
| plugin netguard | — | **0.1.0-alpha.8** | `c00334a8…` |
| plugin template | — | **0.2.1-alpha.5** | `c4bfe8be…` |

Every plugin digest above is the SIGNED value at its integration tip, independently confirmed
by that repo's CI (the double-pack byte-compare gate) after the wave.

## 3. Gaps — status after 2026-07-27

- **G1 — plugin→server minimum version: MECHANISM SHIPPED, NOT YET USED.** `min_server` is a
  signed, additive manifest field (server#22, merged; index mirrors, never owns —
  rules/01 §8.5). All five manifests currently declare it ABSENT, deliberately: the honest
  floor is "a server containing the budget/backing work", which no released version string
  named at signing time. First train assembly is when it gets real values.
- **G2 — CLOSED.** `dashboard.ref` now points at the reconciled tip `8e6c206`; verified in
  production via the image label `dashboard-revision` on `alpha-0.2.2a4`. The gap was caught
  BY that label after `alpha-0.2.2a3` shipped the pre-reconciliation ref — the label is
  therefore load-bearing evidence, not decoration.
- **G3 — FORMAT SHIPPED.** `lattice.release.train.v1` (schema + zero-dependency validator +
  CI) lives in `lattice-plugin-index`; a real `train.json` gets written at the first
  coordinated cut.
- **G4 — OPEN.** Astra's fork pin and the fleet's deployed sing-box version are still
  unrecorded. Unchanged today.
- **G5 — PARTIALLY CLOSED.** The index is still hand-generated, but train manifests are now
  CI-validated on every push/PR; index regeneration itself remains a manual release step.
- **G6 — SHARPENED.** The validator reports `server_version` from module metadata when run as
  `go run …@<version>` (e.g. `v0.2.2-0.20260727095611-c9c671079ab6`) but reports `dev` when
  run from a plain local build — so the plugin CI gate, which pins a released module version,
  DOES name a real server, while a hand-built binary does not. Train assembly must take the
  version from the pinned module reference, not from a local build.

**Also now true (not a gap, a property to preserve)**: every plugin repo's CI runs the
released-server manifest validator on `main`, `integration`, and PRs, so a manifest that the
released server would reject cannot reach a merge unnoticed.

## 4. Standing law this document leans on (unchanged here)

Three tag lanes per `rules/01 §8.5` (image train `alpha-X.Y.ZaN` · prerelease semver
`vX.Y.Z-alpha.N`, never GitHub Latest · stable semver `vX.Y.Z` on explicit operator decision);
release order `sdk → server / dashboard / node-agent → docs site → plugins → plugin-index`;
tag pushes are operator-only. The promotion protocol amendment is slice 3.
