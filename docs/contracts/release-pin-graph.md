# Release pin graph — current state (2026-07-26)

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

## 2. Version state today (observed 2026-07-26, sources: git tags + manifests)

| Repo | Stable | Prerelease / dev line |
|---|---|---|
| lattice-server | `v0.2.1` | image train `alpha-0.2.2a2`; `integration` @ `86422a1`; binary version injected at build (source default `"dev"`) |
| lattice-sdk | `v0.2.9` (stable-tags-only lane) | consumers pin pseudo-version @ `4a318f24` |
| lattice-dashboard | — (no stable tag observed) | `v0.2.2-alpha.6` (= `package.json`) |
| lattice-node-agent | — | `v0.3.3-alpha.2` |
| plugin vpn-core | index `stable: 0.7.2` | manifest `0.8.0-alpha.5` |
| plugin netguard / wireguard | — | `0.1.0-alpha.7` each |
| plugin sub-store | — | `0.3.2-alpha.4` |
| plugin template | — | `0.2.1-alpha.3` on `main`; `0.2.1-alpha.4` signed on the open `feat/execute-reference` PR |

## 3. Gaps blocking a coordinated train (requirements for slices 2–3)

- **G1 — no plugin→server minimum-version declaration.** Compatibility is implicit: a manifest
  loads or is rejected by the running server's validator. The ruling requires this resolvable
  from the release. Candidate homes: a signed manifest field (schema change, re-sign wave) or
  a plugin-index per-release field (no re-sign; index is regenerated anyway). Decide in slice 2.
- **G2 — `dashboard.ref` currently points at a line missing a security fix.** `a927c6c`
  (dashboard `main`) lacks dashboard#9 (frame-reload boundary), which lives on `integration`
  (`a40af9a`). The pending integration↔main reconciliation produces the union; the ref must
  move to the merged tip before the next image tag is cut.
- **G3 — no single artifact resolves the whole train.** Today the answer to "what versions make
  up a deployment" is assembled from six places in this table. The release manifest (slice 2)
  is that artifact.
- **G4 — Astra and the sing-box fork are unpinned in writing.** The iOS client's fork pin and
  the fleet's deployed sing-box version are tribal knowledge. Record both; the train cannot
  promote what it cannot name.
- **G5 — plugin-index is hand-generated.** `status: "draft"`, `generated_at` hand-run. Train
  discipline needs index regeneration + validation as a release step (ties into TASK-0006's
  gate).
- **G6 — server version constant.** The binary reports an injected build version (`"dev"`
  default in source); slice 2 must verify the injection path so the About-page check is
  load-bearing rather than cosmetic.

## 4. Standing law this document leans on (unchanged here)

Three tag lanes per `rules/01 §8.5` (image train `alpha-X.Y.ZaN` · prerelease semver
`vX.Y.Z-alpha.N`, never GitHub Latest · stable semver `vX.Y.Z` on explicit operator decision);
release order `sdk → server / dashboard / node-agent → docs site → plugins → plugin-index`;
tag pushes are operator-only. The promotion protocol amendment is slice 3.
