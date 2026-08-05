# Release pin graph — mechanism and gap snapshot at 2026-07-27T14:53Z

> TASK-0010 slice 1 (operator ruling 2026-07-26 §1b). This page records the pin mechanisms,
> observed values, and open gaps at the timestamp above; it is not a live/latest view. Each
> observation names its repo source. Later train artifacts are versioned records for one selected
> train, not a replacement for live fleet or latest-release discovery. Nothing here changes
> behavior.

## 1. The graph — who pins whom, and where

| Consumer → dependency | Pin mechanism | Value at snapshot | Source of truth |
|---|---|---|---|
| lattice-server → lattice-sdk | `sdk.ref` SHA file + go.mod pseudo-version | `4a318f24…` / `v0.2.18-0.20260722123932-4a318f246d23` | `lattice-server:sdk.ref`, `lattice-server:go.mod` (integration `c9c6710`) |
| lattice-server → lattice-dashboard | `dashboard.ref` SHA file (image embeds the built dashboard) | `8e6c206…` (reconciled tip — was `a927c6c`, see G2) | `lattice-server:dashboard.ref` (integration `c9c6710`) |
| lattice-node-agent → lattice-sdk | go.mod pseudo-version | `v0.2.18-…-4a318f246d23` (same commit as server's) | `lattice-node-agent:go.mod` (integration `03f730a`) |
| ghcr image ← lattice-server | tag-triggered build: pushing `alpha-X.Y.ZaN` IS the release trigger; the image embeds both refs above | **`alpha-0.2.2a4`**, operator-recorded as deployed and verified by the snapshot | build trigger: `lattice-server:.github/workflows/container.yml` + git tags; deployment observation: `lattice-olympus:messages/archive/20260727-1012Z-zeus-deploy-verified.md` |
| plugin-index → each plugin | `plugins.json`: per-plugin `channels` (stable/alpha) + `releases[]` carrying `manifest_url`, `artifact_url`, `artifact_sha256`, `signature_ed25519`; publisher ed25519 key pinned at index level | schema `lattice.plugin.index.v1`, `status: "draft"`, generated 2026-07-22 | `lattice-plugin-index:plugins.json` |
| each plugin (internal) | manifest `version` = `ui/package.json` = Go const, moved together; artifact digest ↔ manifest signature | e.g. sub-store `0.4.0-alpha.1` | each plugin repo: `manifest.json`, `ui/package.json`, `system-go` const; `tools/bump.sh` |
| dashboard → server | none at build time; runtime API compatibility only. Post-deploy check: About page must show matching versions | — | workspace release law (root AGENTS.md) |
| plugins → server | required signed `compatibility.server` metadata + optional signed top-level `min_server` train floor | all five declare `compatibility.server`; all five omit `min_server`, so no train floor is selected/signed — see G1 | each plugin's `manifest.json`; `lattice-server:internal/plugin/plugin.go`, `internal/plugin/manifest_v2.go` |
| Astra → sing-box fork / server | not machine-resolvable from `Package.swift` — see gap G4 | — | — |
| fleet nodes → sing-box fork binary | deployed binary; version recorded in no repo file — see gap G4 | — | — |

## 2. Version state at the snapshot (second signing wave)

> This table will be wrong after the next signing or tag. A versioned path such as
> `train/v0.3.0-alpha.1.json` (added after this snapshot) records one explicitly selected train;
> the associated validator proves document structure, tag lanes, and local cross-field
> invariants. It does **not** prove
> that remote tags resolve to the listed commits, repo pin files match, signed digests are true,
> or that the train is latest/deployed. Those cross-repo checks remain work.

| Repo | Stable | Line at snapshot | Signed bundle digest |
|---|---|---|---|
| lattice-server | `v0.2.1` | image train `alpha-0.2.2a4` (deployed); integration `c9c6710` | — |
| lattice-sdk | `v0.2.17` | integration tip `00943f6e` (the plugin SDK module merge); `c3f2973` — the reconciliation merge — is its ancestor | — |
| lattice-dashboard | — | `v0.2.2-alpha.7`; integration `8e6c206` (reconciled union) | — |
| lattice-node-agent | `v0.2.9` | `v0.3.3-alpha.2` | — |
| plugin vpn-core | index `stable: 0.7.2` | `0.8.0-alpha.7` | `89e4d484…` |
| plugin sub-store | — | `0.4.0-alpha.1` (embedded-engine line) | `e0524e35…` |
| plugin wireguard | — | `0.1.0-alpha.9` | `decba2ac…` |
| plugin netguard | — | `0.1.0-alpha.9` | `ac7e1d66…` |
| plugin template | — | `0.2.1-alpha.6` | `0a806be8…` |

Every plugin digest above is the SIGNED value at its integration tip, independently confirmed
by that repo's CI double-pack byte-compare gate. Two signing waves reached this state on
2026-07-27: the embedded-engine/SDK wave, then the bridge-migration wave.

## 3. Gaps at the snapshot

- **G1 — plugin→server minimum version: METADATA AND MECHANISM PRESENT, FLOOR ABSENT.** Every
  signed v2 manifest carries required `compatibility.server` metadata. Separately, `min_server`
  is the optional signed train-floor field (server#22, merged; index mirrors, never owns —
  rules/01 §8.5). The server validator requires the compatibility metadata to be bounded and
  non-empty; that is not evidence of a selected `min_server` floor. All five signed manifests
  omitted `min_server` at the snapshot, and the later first train therefore mirrors none. Closing
  G1 requires assigning and signing real floors first; train assembly cannot invent them.
- **G2 — CLOSED.** At the snapshot, `dashboard.ref` pointed at the reconciled tip `8e6c206`,
  verified in production via the image label `dashboard-revision` on `alpha-0.2.2a4`. The gap
  was caught by that label after `alpha-0.2.2a3` shipped the pre-reconciliation ref — the label is
  therefore load-bearing evidence, not decoration.
- **G3 — FORMAT IN REVIEW, NOT SHIPPED.** At the snapshot, `lattice.release.train.v1` (schema,
  zero-dependency validator, CI wiring) existed only on open `lattice-plugin-index#3`. The later
  first candidate is a versioned `train/v0.3.0-alpha.1.json`, not a live `train.json` alias.
- **G4 — OPEN.** Astra's fork pin and the fleet's deployed sing-box version were unrecorded.
- **G5 — OPEN, WITH STRUCTURAL VALIDATION IN REVIEW.** The index was hand-generated. PR #3's
  train validator checked JSON structure, tag lanes, and local cross-field rules; it did not
  generate the index or cross-check remote tag→commit, pin-file, or signed-digest truth.
- **G6 — SHARPENED.** The validator reports `server_version` from module metadata when run as
  `go run …@<version>` (e.g. `v0.2.2-0.20260727095611-c9c671079ab6`) but reports `dev` when
  run from a plain local build — so the plugin CI gate, which pins a released module version,
  DOES name a real server, while a hand-built binary does not. Train assembly must take the
  version from the pinned module reference, not from a local build.

**A property present at the snapshot**: every plugin repo's CI configuration runs the
released-server manifest validator on `main`, `integration`, and PRs. A rejection therefore
produces a failing check on those paths; branch policy and human review still decide whether a
failure can be merged.

## 4. Standing law at the snapshot, and the later implementation

Three tag lanes per `rules/01 §8.5` (image train `alpha-X.Y.ZaN` · prerelease semver
`vX.Y.Z-alpha.N`, never GitHub Latest · stable semver `vX.Y.Z` on explicit operator decision);
release order `sdk → server / dashboard / node-agent → docs site → plugins → plugin-index`;
tag pushes are operator-only. The coordinated-train amendment had landed in `rules/01 §8.5`
(changelog row #3, co-signed 2026-07-27). At the snapshot, that law specified a standalone
`vX.Y.Z` train defined by a CI-validated `train.json`, promoted in one operator act, with no
prerelease component inside a plain train.

The later PR implements candidates as versioned files such as
`train/v0.3.0-alpha.1.json`. Its present validator proves only structure, tag lanes, and local
cross-field invariants; cross-repo tag, pin, and digest truth remains unverified as recorded in
G5. The later implementation detail does not retroactively rewrite what the snapshot-era law
said.

---

## Changes since this snapshot

The section above stays frozen at `2026-07-27T14:53Z` on purpose — it is an auditable record of
what was true then, and rewriting its rows would destroy the only property that makes it useful.
What follows is an append-only delta, newest first. Each entry names what moved and why, so a
reader comparing the frozen table against reality is not left guessing whether it is stale or wrong.

### 2026-08-05

- **lattice-node-agent stable `v0.2.9` → `v0.3.3`.** The frozen row is not merely stale, it sat on
  top of a defect: the fleet was running an **untagged `0.3.0` build**. No `v0.3.0`, `v0.3.1` or
  `v0.3.2` tag or release ever existed — `0.3.0` was prepared, the stable lane was then rewound to
  `v0.2.9`, and the 0.3 line continued only as `v0.3.3-alpha.N`. Because the server's
  `target_version=latest` resolves to the newest **stable** release, every hourly policy evaluation
  planned `0.3.0 → 0.2.9`, hit the downgrade refusal, and logged it once per node. `v0.3.3` promotes
  the exact tree already tagged `v0.3.3-alpha.2`.
- **lattice-sdk stable `v0.2.18` is now on `main`.** The tag pointed at `00943f6e`, which `main` did
  not contain — a stable tag living outside the branch §8.5 says stable is cut from. `main` was
  fast-forwarded to it. Note the consumers are unchanged and still pin the *pseudo-version*
  `v0.2.18-0.20260722123932-4a318f246d23`, which is an ancestor of the tag: the published stable SDK
  is therefore **ahead of** what server and node-agent build against. That gap is real and open.
- **lattice-server image `alpha-0.2.2a4` → `alpha-0.2.2a5`** (deployed), built from integration
  `d6399ac` = frozen `1e61030` plus `dashboard.ref → 04c4046`.
- **plugin-index alpha channels** now mirror the deployed bundles: netguard/wireguard
  `0.1.0-alpha.9`, vpn-core `0.8.0-alpha.7`, sub-store `0.4.0-alpha.2`.
