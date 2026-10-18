# Design 31: agent binary distribution for nodes on very different networks

Status: proposed 2026-10-17. Revised the same day after an architecture review and a security review. The first revision placed the four slow nodes in mainland China, which was wrong, and its recommendation rested on that; this revision is rebuilt on the corrected evidence, and the findings of both reviews are addressed in the text and listed with their dispositions at the end. S1 (resumable download, lattice-server #204) is in production since 2026-10-17; `PROGRAM.md` records the release. S2 and S3 are built (lattice-server #205) and merged into `integration`; `PROGRAM.md` records which release carries them. The `last_fetch` record and its console readout are lattice-sdk #32, lattice-server #206 and lattice-dashboard #121. S4 to S7 are not built. "As built (S1 to S3)" lists where the code differs from D1 and D2 and what running the walk found.
Date: 2026-10-17.
Reference: lattice-server `integration` at ee57011 (the merge of #204), lattice-node-agent `integration` at 29871e8, lattice-sdk `integration` at d7dd412, lattice-dashboard `integration` at 3f7ff8c, umbrella at 420ff17. Production versions live only in `PROGRAM.md`, which also identifies the nodes this design describes by class.

## Summary

An agent update downloads one 14 MB binary inside a fixed 480 s budget, from the control plane in Hong Kong and, if that fails, from the upstream release URL. On 2026-10-17 four nodes could not finish. None of them is in mainland China: three sit on one residential network far from Asia, and one is a laptop whose own last hop is the bottleneck. Resumable downloads (S1) went live the same day and fixed three of the four within two attempts. What remains is narrower than the first revision claimed. Every slow attempt costs an operator approval. A node whose own line is the bottleneck cannot finish inside any task. The script has no way to leave a slow source for a faster one. And GitHub, the only fallback, is unreachable from mainland networks.

The recommendation, in order of value against that evidence:

1. **S2:** a summary line that records what each source delivered, and a speed cutoff that leaves a slow source early. S2 is keyed on a plan line, so it retires no open approval.
2. **S3:** compressed transfer. gzip shrinks the binary 2.6 times, which puts the slow residential nodes inside one attempt.
3. **S4:** prefetch outside the task. The agent downloads the binary for its open update in the background with no deadline, so the task itself takes seconds and the laptop finishes too.
4. **S5 and S6:** ordered sources, a small reviewed mirror registry and a global mirror on Cloudflare R2, with install on new nodes using the same sources. These are what the operator asked for. The evidence for them is weaker, but real: a non-GitHub fallback for mainland nodes, and room for the architectures the control plane cannot store.
5. **S7:** a mainland copy. It stays conditional on a measurement that would justify it, and it would come from a domestic bucket rather than a listener in the agent.

## What the operator asked

Translated from the operator's words: keep a copy in mainland China on the fleet's mainland node that China nodes can fall back to, add a Cloudflare CDN for global download and install, and make distribution work across network environments in general.

## What the evidence shows

The rollout on 2026-10-17 reached most of the fleet from the control plane in Hong Kong. Four nodes failed at the 480 s budget. Three sit on one residential ISP far from Asia. The fourth is a laptop on a home line, and another node on that same line updated in under two minutes, so the laptop's slowness is its own last hop. The fleet's one mainland node fetched the same binary from the control plane in under a minute. The first revision of this design placed the four in Chengdu, from a tag in their names that is the operator's tenant tag, not a city. Every mainland-specific claim it built on that is withdrawn here.

S1 (resumable downloads) went live the same afternoon. One of the three residential nodes then finished in 13 s on its first attempt. The other two kept 11,770,876 and 11,041,770 bytes on attempt 1, at about 23 to 25 KB/s, and finished on attempt 2. The laptop kept 302,058 bytes in 480 s, about 0.6 KB/s, and needs dozens of attempts at that rate. Earlier, a NAT node fetched at about 34 KiB/s from GitHub and the control plane alike, because its own uplink is the limit (the comment above `agentFetchBudgetSec` in lattice-server records it).

Three conclusions follow. Resume already fixed most of the incident. No node in it is helped by a mainland source. The remaining costs are the extra approvals, and the nodes whose own line makes any in-task budget too short. The operator's request for a mainland copy and a CDN still stands. This design keeps both, and says plainly how strong the evidence is for each.

## How the download works today

Read in lattice-server `internal/server/server_agent_update.go`, `server_agent_artifacts.go` and `server.go` at ee57011.

1. **Sources.** When the control plane holds the pinned digest, `withControlPlaneBinarySource` and `resolveOfficialAgentUpdatePayload` point `binary_url` at `/api/agent/agent-binary/<version>/<os>/<arch>/<sha256>` and move the policy URL or the GitHub release URL into `fallback_url`. Otherwise the plan names the upstream URL alone.
2. **The budget.** The server gives an agent update task 600 s (`approvalApplyTaskTimeoutSec`) and the download 480 s of it. The agent caps a task at ten minutes (`maxTaskTimeout` in lattice-node-agent `internal/taskexec`): agents from v0.3.10-alpha.1 clamp a larger value to 600 s, and older agents fall back to their 30 s default (c8de23e). The fallback runs with `--max-time "$FETCH_LEFT"`, whatever the first fetch left, so a control-plane fetch that trickles for 480 s leaves the fallback nothing.
3. **The credential.** The control-plane fetch presents the task lease (`X-Lattice-Task-Id`, `X-Lattice-Task-Lease`). It is HTTPS only and never follows a redirect, because curl strips only the standard `Authorization` header across hosts. `handleAgentBinary` authorizes it through `authorizeAgentBinaryRequest`, which requires a live lease, an approved agent-update approval for the same node, an exact version, digest and platform match, and `binary_source` equal to `control-plane` (`server_agent_artifacts.go:853`). The upstream fetch follows redirects and carries no lease.
4. **S1.** The binary route answers byte ranges, with the pinned SHA-256 as `ETag` and `If-Range` honoured, and its write deadline is extended to the task timeout. The script keeps the partial beside the install path as `.lattice-agent-download-<sha256>`, root-only. It continues the partial only when it is a regular file owned by the script's user, continues it across attempts and across the fallback, deletes it on a digest mismatch or on curl exit 33, and runs the candidate only after the digest check.
5. **Approvals are identified by their payload.** The approval action is the base64 of the whole payload (`agentUpdateApprovalAction`). Whenever a fresh plan computes a different payload, the planner retires every pending approval, and every approved one with no live task: `createAgentUpdateApproval` calls `rejectSupersededAgentUpdateApprovals`, gated by `agentUpdateApprovalCanAutoReject`. The auto-plan sweep (`evaluateAgentUpdatePolicies`) runs that continuously for online nodes. At decision time `requireCurrentAgentUpdateApproval` refuses an approval whose payload differs from the recomputed one, and the approvals listing applies the same check (`rejectLocallyStaleAgentUpdateApprovals`). The apply script is rendered at decision time, so a task already dispatched carries its own script. The consequence matters for every slice below. A slice that adds or changes a payload field retires every open approval that is not running, once, when it deploys; S1 did exactly that, because every new plan sets `resume_download`. A slice keyed on a plan line, the way the keepalive and update-guard steps are, leaves the payload equal and retires nothing.
6. **Failure output.** `taskFailureSummary` keeps the last 640 characters of stderr and of stdout. A successful task's output lives only in the task result.
7. **The store.** The control plane's agent artifact store is capped at 128 MiB, because it is read into memory at startup. It has already filled once, and an architecture that does not fit fetches from GitHub.

## D1. Seeing and leaving a slow source (S2)

**The summary line.** The fetch step ends every exit path with one stderr line in a fixed compact format, printed by an `EXIT` trap: `lattice-agent-fetch v1` followed by one field per fetch, `index:kind:exit:bytes:seconds` (kind `cp`, `up`, or `m.<mirror id>` from S5 on; a second-pass fetch is marked `p2`), and then the result. Four sources and a second pass fit well inside the 640 characters `taskFailureSummary` keeps. `handleAgentUpdateTaskResult` parses the last such line into the task's audit record and into a `last_fetch` field on the policy, for success and failure alike, and the console's Agent updates page shows, per node, which source delivered and at what rate. Today the only record of a slow download is a truncated error, so this is the measurement every later slice depends on.

**The cutoff.** Every fetch in the first pass runs with `--speed-limit 32768 --speed-time 30` and at most an equal share of the time left, which is the time left divided by the number of sources not yet tried. When the first pass ends incomplete with at least 20 s left, a second pass gives everything that remains, without the cutoff, to the source that added the most bytes in this attempt, retried up to three times on a transient failure with a 2 s pause. A source that added nothing is never retried. With a single source there is nothing to switch to, so it gets no cutoff, only the retry. Every fetch continues the same partial, as S1's fetches already do.

Every source gets the cutoff, the last one included. The first revision left the last source uncut, and the last source is GitHub for an official release, which some nodes cannot reach at all. Uncut, a GitHub trickle would hold the budget while the source that was actually best sat idle. The equal share bounds what any one source can take before the second pass. That matters again in S5, where a source can be a mirror that streams wrong bytes above the cutoff.

Why 32 KiB/s for 30 s:

- At the raw size of 14,037,154 bytes, a download from byte zero needs 29,244 B/s (28.6 KiB/s) to finish inside 480 s, so a source below 32 KiB/s cannot finish alone in one attempt.
- The observed paths fall on both sides with room. The residential nodes at 23 to 25 KB/s are below it. The mainland node, under a minute from Hong Kong, is above 228 KiB/s, seven times the threshold.
- The NAT node at about 34 KiB/s sits just above it. When its uplink dips, it moves to a source limited by the same uplink, and loses one reconnect and nothing it received.
- A false cut costs one connect and handshake. The bytes from the window are kept, and the second pass returns to a cut source when that source was the best one, so the threshold can afford to be quick.
- 30 s is curl's own default window. Cross-border paths stall for seconds at a time, so a window much shorter would cut a good path on one stall. At 24 KB/s the window keeps about 0.7 MB before moving on.

Once S3 lands, the finish line drops to about 11 KB/s for the compressed file. The threshold then no longer marks finishability; it separates the healthy paths from the slow ones seen so far. The summary line will show whether it needs to move, and per-line thresholds computed from what is left (architecture review L1) wait for that data.

Exit statuses decide the walk. 0 is done. 22 (an HTTP error), 28 (a timeout, the cutoff included) and any other failure move to the next source. 33 (the source ignored the range) moves on but keeps the partial, because another source can continue it; only when every source the attempt reached answered 33 is the partial deleted, which is S1's single-source rule generalized. The wget branch has no speed cutoff. It walks the same sources with today's flags, wraps each fetch in `timeout "$LEFT"` when the utility exists, and makes no second pass.

**How it ships.** S2 changes no payload field. New plans carry one more Safety line, which names the cutoff, the equal share and the second pass, and the renderer adds the new fetch step only to an approval whose plan carries that line, exactly as the keepalive step is keyed. Open approvals are therefore not retired, and they keep their old step until they are re-planned; the next release's plans get the new one. S2 also corrects the code comments the architecture review lists. The one above `agentFetchBudgetSec` still says a long task makes its node read offline, which stopped being true when 0.3.10-alpha.1 moved the heartbeat onto its own goroutine. That comment and the one in `approvalApplyTaskTimeoutSec` also describe only the older agents' fall-back to 30 s, not the newer agents' clamp. The 600 s ceiling is reason enough on its own.

**What S2 does for the nodes in the incident.** It is not yet known. If GitHub is fast from the residential network, the cutoff moves those nodes off the slow control-plane path within 30 s and they finish in one attempt. If it is not, they finish as they do now, minus a couple of reconnects. The laptop is not helped by any source. The measurement that settles this is a step for the operator or the lead to run, because it is a task on production nodes: a read-only task, approved through the usual task plan, on the two residential nodes that needed a second attempt. It times a 2 MiB ranged GET (`curl -r 0-2097151 -w '%{speed_download}'`) from the GitHub release asset, and from a public file the control plane already serves (the whole file if it is smaller). After S2 ships, its summary line takes this measurement on every update without a separate task.

## D2. Compressed transfer (S3)

Measured on the 0.3.10-alpha.6 linux/amd64 release asset (14,037,154 bytes, verified against the release's `SHA256SUMS`):

| Compressor | Bytes | Share of the original |
|---|---|---|
| gzip -9 | 5,426,900 | 38.7% |
| zstd -19 | 4,504,069 | 32.1% |
| xz -9 | 4,141,880 | 29.5% |

gzip is the one to use: every Linux node has it, and xz and zstd are not on minimal images. At 24 KB/s the gzip file takes about 226 s, so the two residential nodes that needed a second attempt finish in one; the NAT node takes about 156 s. The laptop still needs about 2.5 hours, which is S4's job.

The node-agent release workflow publishes `lattice-agent-linux-<arch>.gz`, built with `gzip -n -9` so the bytes are reproducible, with its own `SHA256SUMS` line. A plan for a version with a compressed asset pins both digests. The script fetches the `.gz` into a partial named by the compressed digest, verifies that digest before decompressing, decompresses with `gzip -dc` into the candidate, and then holds the candidate to the release digest exactly as today. Verifying before decompressing keeps unverified input away from a decompressor running as root. A release cut before the workflow change has no compressed asset, and its plans fall back to the raw one.

When a release has a compressed asset, the control-plane store keeps the `.gz` instead of the raw binary and serves it to plans that pin it, so the store holds about 2.6 times as many versions. That relieves the pressure that has already sent an architecture to GitHub.

HTTP `Content-Encoding` on the wire is not the way to do this, because ranges then apply to the encoded stream and resume becomes unreliable. S3 adds a payload field, so its deploy retires every open approval that is not running, once (How it works, item 5); the operator re-approves.

## D3. Prefetch outside the task (S4)

The architecture review proposed staging the download outside the task. This design takes it, ahead of any mirror. It is the only change that helps a node whose own line is the bottleneck, it needs no listener and no doctrine change, and it removes the 480 s coupling for every node that runs the agent which ships it.

**Mechanism.**

- The config pull gains `agent_update.prefetch` for a node with an open agent-update approval, pending or approved but not yet running: the approval id, version, platform, digest (both digests once S3 lands) and size.
- The agent fetches that file in the background, one at a time, resumable and with no deadline, from a new route, `GET /api/agent/prefetch-binary/<version>/<os>/<arch>/<sha256>`.
- The route authenticates the node with its agent credential. It authorizes only the digest named by that node's open approval, and otherwise applies the same checks as `authorizeAgentBinaryRequest`, keyed on the node credential instead of a lease. It shares the binary handler's body (integrity re-verification, ranges, the extended write deadline) and audits as `agent.binary.prefetch`.
- The agent writes the file the update script will continue: `.lattice-agent-download-<digest>`, beside the install path the script will resolve, which the agent computes by the script's own rule (its own executable for the default and legacy targets).
- It reports progress in its facts (`prefetch`: approval id, bytes, size, state), and the console shows it beside the approval. An operator can see that a node has the whole file before approving.

**Hand-off.** Tasks carry `approval_id`. When the agent leases the task for the approval it is prefetching for, it stops the fetch and closes the file before it runs the script. S1's script then finds a regular, root-owned file and continues it; when the file is complete, one ranged request answers 416, and the task goes straight to the digest check and the install. The script itself does not change.

**Why prefetch starts on a pending approval.** A digest-pinned download into a root-only file is not a change to what the node runs. Nothing executes until the approved task runs the digest and version checks. Starting only after approval would make the operator wait out the slow download after deciding, which is the cost S4 exists to remove. The auto-plan sweep cuts pending plans for every online node on each release, so prefetch also pre-positions the bytes fleet-wide; that is one fetch per node, which the control plane serves already today.

**Safe defaults.**

- The config carries digests and sizes, never URLs. The agent builds the fetch URL from its enrolled server address.
- The file name comes from the validated 64-hex digest alone.
- A free-space check refuses a prefetch that would leave the disk short, and reports the refusal; one node in this fleet has already run its disk to 99 percent.
- The agent deletes every `.lattice-agent-download-*` whose digest no open approval names. That also cleans up the partials S1 leaves behind when a policy moves on, which today are cleaned only by a next attempt that may never come.
- An agent running as a non-root user skips prefetch, because the script discards a partial it does not own.

**Limits.** Prefetch helps from the agent release that ships it onward. The update to that release still goes through the task path, where S1 to S3 apply. It fetches from the control plane only, so an artifact the control plane does not hold is not prefetched. Walking S5's sources is a later refinement. The node credential is long-lived, unlike a lease, but the route hands out only a public binary named by the node's own open approval, so the wider credential buys nothing beyond what a lease would.

## D4. Ordered sources, a reviewed registry and a global mirror on R2 (S5)

This is the CDN the operator asked for. Against the evidence its value is real but secondary:

- a non-GitHub fallback for mainland nodes, which cannot reach GitHub but can reach Cloudflare, slowly;
- a source for an architecture the control plane cannot store;
- the public source that install on new nodes needs (S6).

**Sources in the payload.**

- The payload gains `sources`: at most four entries, each with `kind` (`control-plane`, `mirror` or `upstream`), `url`, `mirror` (the registry id) and `reason`.
- The server computes the list when it plans, the plan prints it with the reasons, and the approval binds it.
- The order is fixed: mirrors preferred for this node, then the control plane when it holds the digest, then mirrors marked global, then upstream, always last. Lower-priority mirrors are dropped first to stay within four.
- The script renders one fetch line per source, unrolled, so a reader of the approved script sees which line carries the lease and which follows redirects. D1's walk, cutoff, equal share, second pass and summary line apply unchanged.
- The Safety lines are derived from the list. A plan that lists a mirror or GitHub never prints today's "the node needs no third-party egress" line, and a test pins that.

**The lease follows the server, not a label.** `agentUpdatePayloadFromApproval` validates `sources`:

- at most four entries, upstream last, kinds from the enum, and every URL passing `normalizeAgentUpdateURL`;
- at most one `control-plane` entry. When present, it must equal the URL the server computes for this version, platform and digest under its own base, which extends today's prefix check in `agentUpdateApplyScript`.

The renderer attaches the lease headers only to that exact entry. `authorizeAgentBinaryRequest` authorizes on that entry instead of on `binary_source`. A registry `base_url` on the control plane's own host is refused, and a golden test renders a mirror entry that points at the control-plane host and checks that it carries no lease.

Nothing operator-entered or node-reported reaches the script except through validation and `shellQuote`. That is a design rule here, with an injection test table over URL, version and mirror id.

**Staleness is strict.** `sources` is a payload field like any other, so any change to the list re-plans an approval that is not running. To keep that from churning, the list is derived only from stable inputs:

- the registry;
- the control plane's own held set;
- node ids and static group members, never group selectors, stored geo or whether a mirror is online now.

A slice field makes the payload struct incomparable, so the `!=` comparisons in `requireCurrentAgentUpdateApproval` and `agentUpdateApprovalLocalStaleness` become an explicit equality function. `sources` joins `agentUpdatePayloadChangeSummary`, and joins the console's `AGENT_UPDATE_STALE_FIELDS` (lattice-dashboard `approvalsModel.ts`), which already lacks `resume_download`. Like S3, S5's deploy retires every open approval that is not running, once.

**The registry is small.** An entry is `id`, `name`, `base_url`, `prefer_for` (node ids and static group ids), `global`, `priority` and `enabled`. A mirror is any HTTPS server holding binaries at `<base_url>/<version>/<os>/<arch>/<sha256>`, the control plane's own object path. Country affinity is left out. It fails for a node without a public address, which the server cannot geolocate, and a static group of mainland nodes says the same thing explicitly. There is no key pin, because every mirror this slice builds has a public certificate. `base_url` must be HTTPS, with no userinfo, query or fragment, and its host is canonicalized with `netip`. Non-canonical numeric forms, loopback, unspecified, link-local and multicast addresses, `localhost` and the control plane's host are refused. That list is hygiene, not a boundary: a fleet agent admin can already point a policy at any HTTPS URL.

**Registry changes are reviewed plans.** A mirror steers which host every listed node contacts, learns those nodes' addresses and update timing, and could deny their updates. So creating, changing or deleting an entry is an approval of kind `agent.mirrors`, gated by `requireFleetAgentAdmin`. Its plan shows the diff and every node whose order would change. Each update plan also prints how its source list differs from the node's last successful update, and the notify path alerts the first time a mirror appears in any plan.

**Mirrors are untrusted transport, and every source is HTTPS.** The node holds the bytes to the digest in the approved plan, so a mirror can deliver the right bytes or fail. No mirror receives a credential. Mirror lines do not follow redirects: curl gets no `-L`, and wget gets `--max-redirect=0`, which today's wget upstream line does not set, so a test pins it. No credential is at stake, but a redirect would let a mirror point root on every node at an address of its choosing.

Plain HTTP is rejected even with the pin. Integrity would hold, but an on-path party that changes one byte makes the finished file fail the digest, and today that failure deletes the whole partial, including what honest sources delivered. Content-rewriting middleboxes on plain HTTP are a known class of interference. Plain HTTP would also tell every observer which product and version a host fetches.

**A chunk manifest keeps a bad mirror from erasing honest progress.** The security review showed that a mirror listed first can append wrong bytes, fast enough to pass the cutoff. The digest would then fail and delete everything, and that would repeat on every re-approval. So any plan that lists a mirror also carries a chunk manifest:

- The server records the SHA-256 of every 256 KiB chunk of the pinned bytes when it imports an artifact. That is 54 chunks for the current binary, about 3.5 KB of hex in the payload, and the plan prints the manifest's own digest.
- After each fetch, the script hashes the chunks that fetch completed and truncates the partial from the first chunk that fails. A bad source loses its own bytes and at most the chunk in flight, never what came before.
- The summary line names the source or sources that wrote a failing chunk, and the console flags a mirror with chunk failures. That count never feeds the ordering, so the list's inputs stay stable.
- The second pass counts only bytes that survived the check, so a fast liar is never "the best source". D1's equal share bounds how long it can hold the budget first.
- The whole-file digest stays the authority.

An artifact the control plane does not store still needs a manifest, so S5 adds a verify-and-record import. The server fetches the release asset, checks it against `SHA256SUMS`, records the manifest, and keeps the bytes only if they fit. R2 can then serve an architecture the store has no room for.

The alternative the review listed first, a private partial for each mirror promoted only after a full digest match, was rejected. It gives up splicing across sources, and it doubles the disk a download takes on nodes that are already short.

**The R2 mirror.**

- **The bucket and the domain.** A new bucket, dedicated to the mirror, public only through a custom domain on the operator's existing Cloudflare zone; the domain is never attached to any other bucket on the account. The `r2.dev` development URL stays disabled, since Cloudflare rate-limits it and does not support it for production. A public R2 bucket does not list its contents at the domain root.
- **Caching.** A cache rule on the host name caches 200 and 206 responses with a long edge TTL and never caches 404, so a request that arrives before publication is not remembered as missing.
- **Object layout.** Objects sit at `<version>/linux/<arch>/<sha256>`, compressed assets included, with `Cache-Control: public, max-age=31536000, immutable`. Because a wrong object would then stay at the edge for a year, the runbook gains an edge-purge step for that case.
- **Publishing.** `publish-agent-mirror.sh <tag>` runs on the operator's machine as a release-ritual step:
  - it downloads the Linux assets and `SHA256SUMS` from the GitHub release;
  - it checks each asset against `SHA256SUMS`, and against the digest the control plane recorded at import when there is one;
  - it uploads through R2's S3-compatible API with a token scoped to object read and write on that one bucket, kept in a local env file outside every repository and passed through a file, never on a command line;
  - it never overwrites an existing key;
  - it re-downloads each object through the custom domain and verifies its digest.
- **What `SHA256SUMS` proves.** It shows the assets are consistent with their release, not that the release is authentic. The blast radius stays the same either way, because nodes verify against the server's pin, so a bad R2 object can only deny service. No R2 credential lives on the server.
- **Ordering and pruning.** The step runs after the GitHub release is published and before the control-plane import. Pruning is the same script with an explicit list.
- **Cost.** R2 charges for storage only: $0.015 per GB-month for standard storage, nothing for egress, and reads are Class B operations with 10 million a month free (Cloudflare's pricing page, last updated 2026-10-01). Ten releases for two architectures, compressed and raw, is under 0.4 GB, about 7 cents a year at list price. Cloudflare rounds an account's monthly usage up to whole GB-months, so the most this can add is 18 cents a year, and it adds nothing inside the 10 GB-month free tier.
- **The known limit.** Cloudflare's global network is often slow or lossy from mainland China, and its China network requires an ICP filing and a separate contract.

## D5. Install on new nodes (S6)

Both install paths reach GitHub first today. The enrollment command fetches the installer from `raw.githubusercontent.com`, and the installer downloads the binary and `SHA256SUMS` from the GitHub release. The control plane's public `/install.sh` renders the digests into the script it serves, but it too downloads from GitHub.

S6 serves the pinned installer from the control plane, as it already serves the knock client at `/tools/knock/`. The installer then takes an ordered list of base URLs and a table of expected digests per platform, both rendered by the server into the enrollment command and into `/install.sh`. It verifies against the rendered digest, because a mirror must never supply the digest it is checked against. Without a rendered table it keeps today's behaviour, so it still works stand-alone.

The install sources are the registry's global mirrors and then GitHub; the compressed asset applies here too. The control-plane binary route stays lease-only and does not accept the long-lived node token. The installer has no 480 s budget, so a new mainland machine finishes through R2, slowly, with `-C -` resume.

## D6. A mainland copy, conditional (S7)

**The evidence today.** The fleet's one mainland node fetches from the control plane in under a minute, and nothing in this incident is helped by a mainland source. S4 weakens the case further: once prefetch ships, a slow update path finishes in the background whatever the source. The case that remains is installing a new mainland machine, which S6 serves through R2 slowly but surely.

**The measurement that would justify it.** It is a step for the operator or the lead, because it runs on production nodes. When S2's summary line shows a mainland node fetching from the control plane below the cutoff, run a read-only task on that node. It times a 2 MiB ranged GET from the control plane, and from a test object in a mainland-region bucket on the cloud account the operator already holds. Build S7 when the domestic rate is above the cutoff and at least four times the control-plane rate.

**How it would be built: a domestic bucket.** S7 means option (c), a bucket in a mainland region of that account. It is registered as a `static` mirror preferred for a static group of mainland nodes, and published by the same script. It needs no code beyond S5. Before choosing, check two things: that the bucket's default HTTPS endpoint serves ranged GETs to curl without a filed domain, and that its S3-compatible API accepts the upload tool. The cost is storage and egress, small but not zero, plus a credential for that account on the operator's machine.

**Option (b) is rejected.** A static server installed on the node by a task puts software there that Lattice neither ships nor updates nor can veto.

**Option (a) is not recommended.** The first revision of this design recommended it: the agent itself serving verified artifacts on a port. It reverses design 29's recorded rejection of an HTTP or TLS endpoint on the agent, and it would loosen the doctrine's "authenticated, silent to anything unsigned" to fit. It is kept only as a contingency, in case (c) fails its two checks, and it would then need its own design revision covering all of the following:

- the NetGuard companion is required, and internet exposure is refused;
- the provider's own security group becomes an explicit operator step, and the mirror is listed only after a reachability verdict, because NetGuard cannot see a provider's group;
- the listener runs as a sandboxed unprivileged subcommand from the start;
- TLS uses a certificate with an IP SAN, rendered into the plan and passed with `--cacert`, instead of `-k` with a key pin, which can fail open on a TLS backend that does not enforce pins;
- per-address limits are bucketed by /64 for IPv6, with a minimum write rate, a daily byte budget, no keep-alives and capped headers;
- `-no-mirror` reads an environment veto the way `-no-beacon` does;
- population carries digests only, and files are named by digest alone;
- every node-reported value is validated, with the URL built on the server from a validated address and port;
- the plan text states that a NAT source address may admit other tenants behind it;
- the operator ratifies a doctrine amendment.

This revision asks for none of that.

## As built (S1 to S3)

D1 and D2 stay as they were proposed; this section lists where the shipped code differs from them and what running it found. It was read against lattice-server `integration` e5b752b, the merge of #205 (S2 and S3) on top of #204 (S1). The `last_fetch` record and the console readout came in a follow-up, lattice-sdk #32, lattice-server #206 and lattice-dashboard #121, which were open and not merged when this was written; an entry that depends on them names them. "Intended" means the code is the behaviour to keep and the text above is the stale part; "known gap" names what would close it.

### D1 (S2)

- The second pass gives what is left of the budget to the source that delivered the largest share of its own file in this attempt, not the most bytes. A compressed byte from the control plane stands for about 2.5 plain bytes from the fallback, so raw bytes would favour the slower file. The script compares the shares in integer arithmetic, and a tie keeps the earlier source. When every source fetches the same file, as on every plan without a compressed copy, this is the rule as written. Intended.
- The compressed and the plain partials are separate files. The plain binary continues `.lattice-agent-download-<sha256>` and the gzip copy `.lattice-agent-download-<compressed sha256>`, so "every fetch continues the same partial" holds only among sources of one file: on a compressed plan the control plane's gzip fetch and the plain fallback each continue their own. A partial is deleted only when every source of its file that the attempt reached answered 33. Intended.
- The summary line has a third kind, `cp.gz`, the compressed copy from the control plane, beside `cp` and `up`; `m.<mirror id>` stays reserved for S5. Seconds read `-` on a node whose `date` gives no epoch seconds, the last field is `result:<exit>:<stage>` with the stage one of `prepare`, `fetch`, `verify`, `unpack`, `install` and `done`, and the server keeps a line of at most nine fields only when every field matches a strict pattern. Intended.
- Before the first fetch, the walk checks each kept file against its pinned digest and finishes without fetching when one already holds the pinned bytes; a compressed plan, which pins both sizes, also drops a kept file of full length that fails its digest. An incomplete walk checks once more before it fails. The summary then carries no fetch field and ends `result:0:done`. Intended; it exists because of the curl 7 finding below.
- The clock only sizes shares. A fetch on a node without a clock is charged its whole share, so the walk never overruns the budget; with curl the first pass then spends all of it, and such a node gets no second pass. Intended.
- The policy keeps the parsed line as `last_fetch`: each fetch's place in the walk, kind, exit status, bytes and seconds, then the script's exit status and stage, the approval, its target version and when the control plane received the result. It is written on success, on failure and on the late-result path, field by field under the store lock, and a result from an older approval never replaces a newer approval's record, because the agent's outbox can deliver a result after a restart. A result without the line leaves the earlier record. Agent updates shows it per node: the outcome, with a failure's stage in words, then which source delivered, how much and how long, and in the node's sheet every fetch with its exit status (lattice-sdk #32, lattice-server #206, lattice-dashboard #121). Intended.

### D2 (S3)

- The compressed copy is made by the control plane when it imports a release, not by the node-agent release workflow. Import holds the release bytes to their digest, compresses them with Go's `compress/gzip` at best compression with no name and a zero modification time, so the output depends on the input alone, and checks that it decompresses, bounded, to exactly the verified binary. There is no `.gz` release asset and no `SHA256SUMS` line for one; the plan pins the digest the import computed. On the measured 0.3.10-alpha.6 asset this gives 5,552,813 bytes, 2.3 percent more than `gzip -n -9`. Intended.
- The store keeps only the gzip form of an imported release; an uploaded binary stays raw. The fallback is the uncompressed release asset, held to the binary's digest. Intended.
- A plan for a version held compressed pins `compressed_sha256`, `compressed_size` and `binary_size`, the last read from the gzip trailer. The node holds the compressed file to its digest before anything decompresses it, stops decompressing one byte past `binary_size`, refuses any other size, and then holds the result to `sha256`. Intended.
- A node where `gzip -c | gzip -dc` or `head -c` does not work skips the compressed source and walks the uncompressed fallback; a compressed plan without a fallback fails with that reason named. Intended.
- Open approvals are retired when a version is first imported compressed, by the auto-plan sweep, not when S3 deploys; a version already held raw keeps planning raw until it is imported again. Intended.
- The console's `AGENT_UPDATE_STALE_FIELDS` now names `resume_download`, `compressed_sha256`, `compressed_size` and `binary_size`, so a stale reason that lists them reads in words (lattice-dashboard #121). D4's remark that the list lacks `resume_download` no longer holds. Intended.

### What running the walk found

- **curl 7 and a complete kept file.** A ranged request that starts at the end of a complete file is answered 416. curl 8 treats that as finished and exits 0, and so does wget; curl 7, still the packaged curl on some current long-term-support distributions, exits 22. S1's step asks for exactly that range whenever it continues a kept file, so on a node with curl 7 a complete kept file, one a later step failed on or one fetched in full by a run that was then cut, fails every later attempt: the node loops through re-approvals and never installs. The walk's kept-file check finishes such a file without a ranged request. Known gap: approvals planned before #205 still render S1's step and keep the hazard until they are re-planned under the walk. D3's hand-off must not rely on the 416 either; a complete prefetched file has to be found by the same check.
- **busybox wget.** busybox's wget rejects `--https-only` and has no way to refuse a redirect, so the wget lines of S1 and earlier never ran on a node whose only fetcher is busybox wget: they failed on the option. The walk detects such a wget and fails with the reason named, because the leased line must not follow a redirect; such a node needs curl or GNU wget. busybox before 1.30 also takes `timeout -t`, so the walk wraps wget in `timeout` only when `timeout 5 true` runs. busybox's gzip, head and date serve the compressed path and the clock. Known gap: a node with busybox wget alone cannot update until curl or GNU wget is installed on it.

### Left open by #205

- The uncompressed fallback's write has no size bound beyond the time budget, so a hostile release host, or one a redirect lands on, can stream into the kept file for up to 480 s. A compressed plan pins `binary_size`, which makes a size limit on that fetch a cheap follow-up. Known gap.
- An uncompressed plan pins no size, so the full-length drop rule does not apply to it. An upstream that streams past the real length and is cut leaves an oversize kept file, which curl 7 then answers with 22 on every attempt. Denial of service only, as under S1. Known gap.
- The stored compressed digest depends on `compress/gzip` output staying the same. A stored object never changes, but a toolchain whose deflate output differs would give a re-import a new `compressed_sha256` and retire that version's open approvals once more. Known gap, accepted.

## As built (S5, S6)

D4 and D5 stay as they were proposed; this section lists where the code differs from them. It was read against the S5 and S6 branches (`feature/20261018_agent-mirrors` in lattice-sdk, lattice-server, lattice-dashboard and lattice-node-agent), which were open and not merged when this was written. "Intended" means the code is the behaviour to keep; "known gap" names what would close it.

### D4 (S5)

- **The payload keeps its old fields.** `binary_url`, `binary_source` and `fallback_url` stay, and the decoder requires `sources` to agree with them: a control-plane plan lists `binary_url` as its control-plane entry and ends with `fallback_url` when it has one, and an upstream plan ends with `binary_url`. The binary route, prefetch and approvals planned before S5 keep reading the old fields. Every plan made now carries `sources`, so S5's deploy retires every open approval planned before it, once: the pending ones, and approved ones whose task has not been dispatched. An approval whose task already ran is awaiting confirmation of that run, and neither the deploy nor a later registry change rejects it for its sources. A plan whose list names no mirror renders exactly the S2 and S3 walk. Intended.
- **Where the control-plane entry is checked.** The decoder holds the entry's path to exactly the pinned bytes on the binary route (version, digest and compressed digest); it cannot know this server's base, so the renderer and `authorizeAgentBinaryRequest`, which can, hold the whole URL to `<base>/api/agent/agent-binary/...`. The renderer refuses a plan whose entry is on another host; the route authorizes on that entry when a plan has a list and on `binary_source` otherwise. Intended.
- **Mirror entries.** A mirror URL is held to its registry pattern: it ends with the pinned version, `linux`, an architecture and the pinned digest, and its path holds only letters, digits and `. _ ~ + -` between slashes and no `.` or `..` segment, so it is inert in a shell even before `shellQuote` and a client fetches the URL the approver read. Mirror ids are `[a-z0-9][a-z0-9-]{0,30}`. A version whose characters a mirror URL cannot carry (the version pattern allows `:`) gets no mirror. Intended.
- **How a mirror fetch is bounded.** A mirror gets an equal share of what is left of the budget with curl or wget; the other sources keep D1's rule, under which wget's first source may use all that is left. wget's own timeouts reset on every read, so a wget node without a working `timeout` skips the mirrors and says so. Every mirror fetch runs in a subshell under a file-size limit one chunk past the pinned size (in 512-byte blocks as dash and busybox count; a shell that counts 1024 allows twice as much), with `XFSZ` ignored, so a mirror that streams at line rate cannot fill the disk before the chunk check runs. Security finding H1's equal share therefore holds for both fetchers. Intended.
- **The manifest.** A mirror is listed only for bytes the control plane has a chunk manifest for, and a plan carries the manifest exactly when it lists a mirror. The manifest is recorded on an upload, on an import, on a verify-and-record import that does not fit the store, and, for bytes stored before S5, from the stored copy the first time a plan needs it. The plan prints the manifest's own digest, the SHA-256 of `<chunk_size>\n<size>\n<chunks>\n`. Intended.
- **Every chunk has one writer.** The design allowed a failing chunk to name "the source or sources" that wrote it. The script instead cuts the download's unchecked tail back to the last chunk that passed whenever a source other than the one that wrote that tail continues the file, and cuts a kept file from an earlier attempt back the same way. Attribution is then exact, an honest source never builds on bytes a liar left, and the cost is under one chunk per change of source. The summary marks a fetch whose bytes failed with `:x1` after its seconds field; such a source is never chosen for the second pass, which goes further than "counts only bytes that survived"; and bytes cut back are taken off the source that wrote them before the second pass compares. A fetch that ends cleanly with the file not whole and checked is not a success, and the walk goes on. Bytes past the pinned size are cut and marked. Intended.
- **dd, cut and a sha256 tool.** The check reads chunks with `dd`, the manifest with `cut`, and hashes with `sha256sum` or `shasum`. A node where a probe of any of them fails skips the mirrors and walks the other sources without the check, rather than blaming every source for chunks it cannot hash. Intended.
- **The registry.** Entries are normalized as well as checked: `prefer_for` is deduplicated and sorted, a trailing slash and port 443 are dropped, and the host is lowercased. Beyond D4's list, a base path may hold only the safe characters above, a host must be a plain DNS name or a canonical address, and the registry holds at most 16 mirrors, each `prefer_for` at most 64 ids, priorities from 0 to 1,000,000 (smaller first) and names of at most 80 characters. Two mirrors may not share a base. Intended.
- **The agent.mirrors plan.** The approval has plugin and action `agent.mirrors` and no node. Its plan is a JSON document: the entry as the plan leaves it, the one before, the diff, the registry revision it was made against, and every Linux node whose order changes, before and after. Orders are previewed for a version the control plane holds and the release names. The decision renders the document again from live state and refuses it as stale when the bytes differ, which covers a registry that moved and a node or group change; it then writes the registry and marks the approval applied in one write. Planning needs network:plan and node:admin over the whole fleet, reading the approval needs node:admin and network:plan with no node restriction, and deciding it needs network:apply and node:admin over the whole fleet. An auto-approve rule never decides one: the plugin must be named, and even then the rule's principal holds no scopes, so the decision refuses it and the plan stays pending. The registry view needs only node:read; a principal confined to some nodes sees the order and health of those nodes and, in each entry's `prefer_for`, only those of them. Intended.
- **Diff against the last success.** A plan's Safety lines compare its order with the order of the node's most recently applied update that carried a list; before any such update exists the line says so. Intended.
- **The first-plan alert.** The first plan that lists a mirror records it in the registry, writes an `agent.mirror.first_plan` audit event and sends the notification of that type, once per mirror and host: deleting an id, or pointing it at another host, forgets the mark, so the new host alerts on its first plan. Intended.
- **Mirror health.** The registry view counts, per mirror, the nodes whose last update fetched from it and how many of those fetches wrote a failing chunk. It is display only and never feeds the order. Intended.
- **Verify-and-record import.** An import that does not fit the store answers 200 with `stored: false` and a note, after recording the digest and the manifest. A plan for an official version with such a record pins its digest from the record without fetching `SHA256SUMS`, and only records made by an import count for that; when a release's assets were replaced and imported again, the latest import counts. An upload that does not fit is still refused. Intended.
- **No compressed copy on the mirror.** D4 put compressed assets on R2 and D5 used them for installs. The compressed copy is made by the control plane at import (As built, D2), there is no `.gz` release asset, and the publish step runs before the import, so the mirror holds the release binaries only and mirror sources fetch the uncompressed file. Known gap: a compressed mirror object would need the import's digest before publishing.
- **Publishing.** `publish-agent-mirror.sh` uploads through R2's S3-compatible API with the `aws` CLI, not with wrangler. Cloudflare's REST API, which wrangler uses, rejects a token scoped to one bucket and takes only an account-wide admin token, and D4 asks for a token scoped to the one bucket. The upload is a conditional put with `If-None-Match: *`, so R2 itself refuses to overwrite a key. Credentials are read from the environment only and unexported at once, so only the `aws` call and the control-plane read receive them. The cross-check against the control plane reads its stored artifacts and says when it holds no digest, so a version recorded but not stored, or not yet imported, is checked against `SHA256SUMS` alone. Pruning reads the release's `SHA256SUMS` to name the keys, so a deleted release is pruned by hand. Intended.
- **Left open.** A plan's read paths may record a manifest for bytes stored before S5, which costs a state write and, for a compressed copy, a bounded decompression the first time; and a plan compares its order with the node's last success by scanning approvals. Both are bounded by the fleet's size. Known gap, accepted.

### D5 (S6)

- **The installer the control plane serves** is lattice-node-agent's `scripts/install.sh`, vendored into lattice-server at a recorded commit and digest that a test holds it to, and served at `/tools/agent/install.sh`. A server without a public HTTPS URL has no address to serve it at and hands out the GitHub command as before. Intended.
- **What the command carries.** The enroll and reconfigure commands set `LATTICE_AGENT_SOURCES`, an ordered list of `m=<mirror base>` and `r=<release base>` tokens (the global mirrors by priority, at most three so the list stays within four, then the release), and `LATTICE_AGENT_SHA256`, an `os/arch=<digest>` table. The table holds only what the control plane verified for the installer's version (Linux binaries it stores or imported), and rendering a command never waits on GitHub. Mirrors are listed only when the table has a digest. A platform the table lacks, macOS for one, skips the mirrors and checks the release's `SHA256SUMS` as before. Intended.
- **Splicing.** The installer has no chunk manifest. It continues one download across its sources, and when the result fails the digest it makes a second round in which each source fetches from byte zero on its own. The `/install.sh` updater does the same. Intended.
- **Time and size caps.** A release fetch has a connect timeout, leaves a source that delivers under 1 KiB/s for a minute, and has no total limit, so a new machine on a slow line finishes. A mirror is optional and the release follows it, so a mirror fetch is also cut after 600 s, and every fetch of the installer, and a mirror fetch of `/install.sh`, writes under a 131072-block file limit (64 MiB in 512-byte blocks; the binary is about 14 MiB). What a mirror delivered is kept for the next source. wget has no total limit of its own, so without a working `timeout` the installer and `/install.sh` skip the mirrors. Intended.
- **IPv6 mirrors.** The registry accepts an IPv6-literal host, which update plans use, but the installer's base pattern has no brackets, so such a global mirror is left out of the install sources. Known gap: widen the installer's pattern, or refuse IPv6 literals for global mirrors.
- **What predates S6.** busybox wget still cannot run the installer, which needs `--https-only`, and the `/install.sh` release line for wget does not refuse a plain-HTTP redirect, as before S6. Known gap.

## Alternatives

- **Raising the task timeout.** Every agent on the fleet refuses more than 600 s: newer agents clamp, and older ones fall back to 30 s. A new agent cannot help the nodes that fail to fetch it. S4 removes the need anyway, by taking the download out of the task.
- **Peer-to-peer.** Every node would become a listener, which multiplies the surface option (a) was rejected for by the size of the fleet, and it would need peer discovery and NAT traversal. A chosen peer can be as slow as the source it replaces. Rejected.
- **Proxying through vpn-core lines.** Routing agent updates through a line couples the repair path to the data plane it may be repairing. It puts a line's user credentials into a task, and it makes core distribution depend on a plugin, against design 14's ownership split. Rejected.
- **A private partial per mirror.** Rejected in D4, in favour of the chunk manifest.
- **An agent listener as the mainland mirror.** See D6.

Compression, which the first revision deferred, is now S3.

## Slices

Ordered by value against the evidence above.

| Slice | What it changes | Retires open approvals on deploy | Tests |
|---|---|---|---|
| S1, shipped | resumable binary route and script (#204) | yes, done | in #204 |
| S2, see and leave a slow source | server: the summary line and its parsing into audit and `last_fetch`, the cutoff with equal share and second pass, keyed on a plan line, and the three stale comments; console: per-node source and rate | no | below |
| S3, compressed transfer | node-agent: the release workflow publishes reproducible `.gz` assets and `SHA256SUMS` lines; server: the second digest, the compressed store copy, the verify-then-decompress step; ops: the publish step uploads `.gz` too | yes | a plan with and without a compressed asset; the gzip input is never decompressed before its digest passes |
| S4, prefetch outside the task | SDK: config and facts fields; agent: background fetch, hand-off on `approval_id`, free-space check, pruning; server: prefetch route and config; console: progress beside the approval | no | below |
| S5, ordered sources, registry, R2 | SDK: registry and order types, with the SDK pin bumped in the same slice; server: `sources`, validation, equality, the manifest and the verify-and-record import, the `agent.mirrors` plan, derived Safety lines; console: Mirrors section, order preview, stale fields; ops: bucket, domain, cache rule and token once, `publish-agent-mirror.sh`, runbook steps including purge | yes | below |
| S6, install | node-agent installer: ordered sources, rendered digests; server: serve the pinned installer, render both into enrollment and `/install.sh` | no | installer integrity script extended |
| S7, mainland copy, conditional | ops and one registry entry, if option (c) passes its checks | no | the measurement above, then one publish and a ranged GET from a mainland node |

**S2 tests.**

- An approval without the new plan line renders exactly today's script.
- The summary line is printed on every exit path, including a digest failure, a version mismatch and a missing service, and it parses.
- A script-level test runs the rendered fetch step under `sh` with curl against local test servers. It checks that:
  - a source throttled below 32 KiB/s is left within its window, and the next continues the shared partial;
  - every source, the last included, is cut;
  - the equal share stops a source that stays above the cutoff;
  - the second pass picks the source that added the most;
  - a source that ignores ranges is skipped with the partial kept.

**S4 tests.**

- The route serves only the digest of the node's own open approval, and refuses another node's digest and a digest outside any open approval.
- A prefetch survives an agent restart and resumes.
- The hand-off stops the fetch before the script runs.
- Pruning removes partials no open approval names.
- The free-space check refuses and reports.
- A non-root agent never prefetches.

**S5 tests.**

- The lease appears exactly once, on the server-computed control-plane entry, and never on a mirror entry that points at the control-plane host.
- A payload with two control-plane entries, a wrong control-plane URL, more than four entries or upstream not last is refused.
- The injection table covers URL, version and mirror id.
- wget mirror lines carry `--max-redirect=0`.
- The equality function and the change summary cover `sources`.
- Order computation is table-tested over preferred, global and upstream, static group members, duplicates and the cap.
- Registry validation refuses each class in D4, non-canonical numeric hosts included.
- A mirror serving wrong bytes after honest progress loses only its own bytes and the chunk in flight, and the next source finishes.
- A fast liar never wins the second pass.
- No plan that lists a mirror or GitHub prints the no-egress line.

## Risks

- **S2's value for the residential nodes depends on GitHub's rate from their network**, which nobody has measured yet. The measurement step in D1 settles it.
- **Prefetch writes to the node's disk before approval.** The free-space check and the pruning bound it. An operator who rejects an approval leaves at most one partial, which is pruned when no open approval names it.
- **Each payload-changing slice (S3, S5) retires open approvals once.** Deploy them when few approvals are open, and expect a round of re-approvals.
- **The cutoff constant was derived for the raw binary.** After S3, the summary data decides whether it moves.
- **A Cloudflare cache rule that cached 404 would hide a just-published object.** D4's rule caches only 200 and 206, and publishing precedes import.

## Review findings and their dispositions

Architecture review (changes requested), in its numbering.

| Finding | Disposition |
|---|---|
| C1 stuck nodes misidentified | Accepted. The evidence section is corrected, the mainland mirror is now conditional (D6), and the measurement is a step for the operator or lead (D1, D6). `PROGRAM.md` was already corrected by the lead. |
| H1 uncut last source | Accepted. Every source is cut, and the rest goes to the best source (D1). |
| H2 staleness contradicts the code | Accepted. Staleness is strict, the inputs are stable, there is an equality function, and the change summary and console fields are updated (D4, item 5 of How it works). |
| H3 option (a) reverses a recorded rejection | Accepted. (a) is demoted to a contingency with conditions, and (c) is the mainland route (D6). |
| H4 stage the download outside the task | Accepted, as S4, ahead of any mirror (D3). |
| H5 slices not ordered by value | Accepted. Compression is S3, before every mirror. |
| M1 old approvals do not render unchanged | Accepted. Item 5 of How it works states it, and each slice says whether it retires approvals. |
| M2 false Safety lines | Accepted. They are derived from the list, with a test (D4). |
| M3 the lease guard must follow the list | Accepted (D4). |
| M4 observability | Accepted. The summary line, `last_fetch` and the console column (D1). |
| M5 stale offline argument | Accepted. Dropped here and corrected in the code comments in S2. |
| M6 registry too large | Accepted. No country, kind or pin (D4). |
| L1 adaptive threshold | Mostly covered by the second pass. The adaptive threshold waits for the S2 data. |
| L2 attribution | Covered by the chunk manifest and the console flag, kept out of the ordering (D4). |
| L3 upstream not content-addressed | Noted. The tag policy guards it, and the manifest bounds the damage. |
| L4 leftover partials | Accepted. Prefetch pruning (D3). |
| L5 `-no-mirror` environment veto | Accepted within (a)'s contingency conditions (D6). |

Security review (approve with required changes), in its numbering.

| Finding | Disposition |
|---|---|
| H1 a mirror can erase honest progress and capture the budget | Accepted. The chunk manifest, the equal share, and a second pass on surviving bytes only (D1, D4). No mirror is listed without a manifest. |
| H2 node-reported values reaching a root script | Accepted as a design rule with an injection table (D4). The node-reported pin and endpoint exist only in (a)'s contingency, where the rule is restated (D6). |
| M1 `-k` with a pin can fail open | Accepted. No pins in S5, whose mirrors have public certificates; `--cacert` with an IP SAN in (a)'s contingency; `--max-redirect=0` for wget mirror lines (D4, D6). |
| M2 the lease line derived from the server | Accepted (D4). |
| M3 the registry is an instant setting | Accepted. Registry changes are `agent.mirrors` plans, plans show the diff against the last success, and an alert fires on a first appearance (D4). |
| M4 weak exposure controls on an agent mirror | Accepted within (a)'s contingency conditions; this revision does not build (a) (D6). |
| M5 R2 bucket separation and cache lifetime | Accepted. A dedicated bucket and token, the domain on no other bucket, no listing, never overwrite, an edge-purge step (D4). |
| L1 publish integrity anchor | Accepted. A check against the control plane's recorded digest, and a plain statement of what `SHA256SUMS` proves (D4). |
| L2 denylist bypass | Accepted. `netip` canonicalization, and the list called hygiene, not a boundary (D4). |
| L3 population defaults | Accepted for prefetch (D3) and within (a)'s contingency (D6). |
| L4 fleet reconnaissance in a public document | Accepted. Node names, providers, cities, counts and exact limits tied to a node are removed. Rates stay without identities, because the cutoff is derived from them; `PROGRAM.md` holds the identities. |

## Decisions for the operator

1. **Which slices to build.** The recommendation is S2, S3 and S4 now, in that order. S5 and S6 come when the global CDN and install are wanted. S7 comes only after the measurement in D6 justifies it.
2. **For S5: the custom domain name** for the R2 mirror on the existing Cloudflare zone, and approval of a new dedicated public bucket. That is a storage-only spend, about 7 cents a year and at most 18 with Cloudflare's rounding, with no egress charge.
3. **For S7, if it is ever justified:** a bucket on the existing mainland cloud account (small storage and egress charges) and a credential for it on the operator's machine.
4. **Running the measurements.** The read-only tasks in D1 and D6 are production actions for the operator or the lead.
5. **No mirror port and no doctrine change are requested.** Both would arise only if option (a) were ever chosen over (c), and that would come back as its own revision.

Everything else an agent may decide and build: the cutoff values, the summary format, the registry fields, the manifest chunk size and the tests. Switching the live image to a release that carries any slice rides the standard precheck, backup, health and rollback gates.
