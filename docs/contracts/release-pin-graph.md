# Release pin graph — current state (refreshed 2026-07-27)

> TASK-0010 slice 1 (operator ruling 2026-07-26 §1b). Every cross-repo pin as it exists today,
> each claim with its source of truth (repo + file). Gaps are named explicitly — they are the
> requirements list that slices 2 and 3 then closed (schema+CI in `lattice-plugin-index`; the
> `rules/01 §8.5` amendment). Refreshed after the 2026-07-27 signing wave so it describes
> reality, not the morning of the 26th. Nothing in this document changes behavior.

## 1. The graph — who pins whom, and where

| Consumer → dependency | Pin mechanism | Value today | Source of truth |
|---|---|---|---|
| lattice-server → lattice-sdk | `sdk.ref` SHA file + go.mod pseudo-version | `4a318f24…` / `v0.2.18-0.20260722123932-4a318f246d23` | `lattice-server:sdk.ref`, `lattice-server:go.mod` (integration `c9c6710`) |
| lattice-server → lattice-dashboard | `dashboard.ref` SHA file (image embeds the built dashboard) | `8e6c206…` (reconciled tip — was `a927c6c`, see G2) | `lattice-server:dashboard.ref` (integration `c9c6710`) |
| lattice-node-agent → lattice-sdk | go.mod pseudo-version | `v0.2.18-…-4a318f246d23` (same commit as server's) | `lattice-node-agent:go.mod` (integration `03f730a`) |
| ghcr image ← lattice-server | tag-triggered build: pushing `alpha-X.Y.ZaN` IS the release trigger; the image embeds both refs above | latest: **`alpha-0.2.2a4`**, deployed and verified | `lattice-server:.github/workflows/container.yml`, git tags |
| plugin-index → each plugin | `plugins.json`: per-plugin `channels` (stable/alpha) + `releases[]` carrying `manifest_url`, `artifact_url`, `artifact_sha256`, `signature_ed25519`; publisher ed25519 key pinned at index level | schema `lattice.plugin.index.v1`, `status: "draft"`, generated 2026-07-22 | `lattice-plugin-index:plugins.json` |
| each plugin (internal) | manifest `version` = `ui/package.json` = Go const, moved together; artifact digest ↔ manifest signature | e.g. sub-store `0.4.0-alpha.1` | each plugin repo: `manifest.json`, `ui/package.json`, `system-go` const; `tools/bump.sh` |
| dashboard → server | none at build time; runtime API compatibility only. Post-deploy check: About page must show matching versions | — | workspace release law (root AGENTS.md) |
| plugins → server | **NOTHING** — see gap G1 | — | — |
| Astra → sing-box fork / server | not machine-resolvable from `Package.swift` — see gap G4 | — | — |
| fleet nodes → sing-box fork binary | deployed binary; version recorded in no repo file — see gap G4 | — | — |

## 2. Version state — SNAPSHOT at 2026-07-27T15:48Z (second signing wave)

> This table is a **dated snapshot, not a live view**, and it will be wrong the next time
> anything is signed — it went stale twice while being written. The living form of exactly
> this data is `train.json` (`lattice.release.train.v1`, `lattice-plugin-index`), which is
> generated per train and CI-validated. Read this section as history; read a train file for
> truth.

| Repo | Stable | Line at snapshot | Signed bundle digest |
|---|---|---|---|
| lattice-server | `v0.2.1` | image train `alpha-0.2.2a4` (deployed); integration `c9c6710` | — |
| lattice-sdk | `v0.2.9` | integration tip `00943f6e` (the plugin SDK module merge); `c3f2973` — the reconciliation merge — is its ancestor | — |
| lattice-dashboard | — | `v0.2.2-alpha.7`; integration `8e6c206`+ (reconciled union) | — |
| lattice-node-agent | — | `v0.3.3-alpha.2` | — |
| plugin vpn-core | index `stable: 0.7.2` | `0.8.0-alpha.7` | `89e4d484…` |
| plugin sub-store | — | `0.4.0-alpha.1` (embedded-engine line) | `e0524e35…` |
| plugin wireguard | — | `0.1.0-alpha.9` | `decba2ac…` |
| plugin netguard | — | `0.1.0-alpha.9` | `ac7e1d66…` |
| plugin template | — | `0.2.1-alpha.6` | `0a806be8…` |

Every plugin digest above is the SIGNED value at its integration tip, independently confirmed
by that repo's CI double-pack byte-compare gate. Two signing waves reached this state on
2026-07-27: the embedded-engine/SDK wave, then the bridge-migration wave.

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
tag pushes are operator-only. **The promotion protocol is no longer pending**: `rules/01 §8.5`
carries the coordinated-train amendment (changelog row #3, co-signed 2026-07-27) — a train is a
standalone `vX.Y.Z` defined by its CI-validated `train.json`, promoted in one operator act, and
a plain train may contain no prerelease component.
