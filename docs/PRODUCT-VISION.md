# Lattice: product vision and north star

> The doctrine. Point-in-time reviews live in `program-review-and-roadmap-2026-06.md`
> and dated entries in `roadmap.md`; decisions live in `adr-*.md`; each build cycle is
> logged in `iterations/`; capability designs live in `designs/`. The developer
> handbook (build, test, tag, release) is `handbook.md`.
>
> **Last updated:** 2026-08-31. This version supersedes the 2026-06-15 vision;
> the full positioning analysis behind it was reviewed and ratified by the
> operator on 2026-08-31. Git history preserves the old text.

## 1. What Lattice is

**Lattice is a sovereign control plane: it amplifies one operator's judgment
safely across all of their infrastructure.**

The work can be done by hand in the console or delegated to AI agents through
plans; either way the judgment stays with the operator. Every privileged change
is a reviewed plan whose approval hashes what the operator was actually shown.
Execution is bound to that exact plan, artifact digest, and target set. A
hash-chained audit log records what actually happened. Nodes run an
outbound-only agent that holds its own last-line policy, so neither a
compromised control plane nor a misbehaving automation can quietly own the
fleet.

This identity was not invented; it was noticed. The project is built and
operated almost entirely by AI agents under one human's review, and every
mechanism that makes Lattice unusual (typed plan bindings, capability
admission, audit chaining, node-side vetoes, honest state) exists because the
executor could not be blindly trusted. That is the general problem of the agent
era, and Lattice is a working answer to it at personal-fleet scale.

### The four axioms

Every slice, screen, and API is judged against these:

1. **Nothing changes a machine without a plan.** Any state-mutating operation
   is a reviewable plan; approval hash-binds the reviewed content, the artifact
   digest, and the target set.
2. **Unknown is said out loud.** The system never renders green it cannot
   prove. `unknown / fresh / stale`, `never reported / offline / online`, and
   drift states are first-class; every green light links to its evidence.
3. **No single point can destroy the fleet.** Not a compromised control plane,
   not a runaway agent, not one bad approval. The node keeps the last veto:
   exec, root, and terminal are node-side flags; applies carry watchdogs and
   rollback; capability gates confine what may even be asked of a node.
4. **Hands and agents are equal operators.** Every capability has two
   first-class entrances: a complete human path in the console, and a plan
   surface an agent can drive. Both share the same approvals, admission checks,
   and evidence. A feature that only an agent can operate, or that an agent
   cannot safely operate, is unfinished.

### What Lattice is not

- Not a multi-tenant SaaS. One operator, one control plane, one fleet:
  single-sovereignty is the identity, not a missing feature.
- Not an observability platform. Monitoring exists to serve sovereignty
  (detect, prove, alert), not to compete with Netdata.
- Not a mesh vendor or a proxy panel. WireGuard, sing-box, and Sub-Store are
  domain payloads managed through the trust chain, not the product itself.
- Not a feature race. Cloudflare is the craft benchmark for coherence and
  interaction quality; its business shape and its hold-everything trust model
  are explicitly not the goal. The parts to surpass are sovereignty and
  evidence.

## 2. North star: unattended weeks

The opposite of the current pain is not prettier screens; it is a fleet that is
quiet without being opaque. The north star is a measurable state called the
**unattended week**: seven consecutive days in which the operator never opens
an SSH session to any node, the fleet keeps evolving (agent updates, hardening,
line changes, subscription serving), every change rides plan-approve-apply,
every anomaly reaches the operator's phone within minutes, and the week ends
with an agent-written fleet report in which every claim links to a correlation
id.

Three sovereignty questions define acceptance:

1. **Do I know what is happening?** Honesty everywhere: process-level
   liveness, service health, real usage data, tri-state freshness. A service
   that crashed 220,000 times must never render "ok" because its config file
   still parses.
2. **Can anything change without me?** Admission registries filled, plan
   bindings everywhere, agents able to produce only plans, never facts.
3. **If I leave for a week, does it get better or worse?** Risk-tiered
   auto-approval with daily caps, cross-alive notification paths, rollback to
   last known good.

Tracked anchors: minutes of manual intervention per week; share of changes
that rode plan-approve-apply; detection latency for real failures; and the
most humbling one, "what does production run" must be answerable from exactly
one machine-readable place.

## 3. Product pillars

| Pillar | Promise | State (2026-08-31) |
|---|---|---|
| **Trust chain** | Plan, approve, apply with typed bindings; signed capability-scoped plugins; tamper-evident audit | Strong and real: four-point signature verification, plan-hash approvals, audit WAL with anchoring, 1M+ audit entries in production |
| **State honesty** | Unknown over green; every light links to evidence | Partial: netguard reality and trust posture are the model; node liveness is still a boolean sweep, service liveness and usage are open gaps |
| **Dual operation** | Hands and agents as equal operators (axiom 4) | Console is ahead; the agent surface is implicit (REST + tokens) and not yet a designed plan-only interface |
| **Platform** | Signed plugins with brokered capabilities and sandboxed UIs | Four production plugins; wasm tier deliberately not enabled; marketplace remains read-only by design |
| **Durability and meta-loop** | The control plane manages its own operations: deploy records, version truth, credential lifecycle, backups | Weakest pillar: version truth currently lives in five places; site drifted three weeks; release ceremony is manual toil |
| **Experience** | Cloudflare-grade coherence: URL state, object interlinking, command palette, density, instant response | Rebuilt through August and visibly better; navigation latency, state vocabulary, and cross-screen grammar still below the bar |

## 4. Honest current state (2026-08-31)

Production: `alpha-0.2.2a77` (server and dashboard pinned together), 33 nodes
across 8+ countries, 4 plugins active, node-agent stable line at v0.3.8,
sing-box fleet of 23 nodes and ~138 lines, audit chain beyond one million
entries. Roughly 40 production releases shipped in the last two weeks, built
and operated by agents under operator review.

What is genuinely rare (verified against source, not aspiration): the typed
plan-approve-execute binding; the outbound-only agent with node-side capability
flags; the signed plugin chain verified at install, load, read, and execute;
the hash-chained audit WAL with off-box anchoring; and the honesty discipline
where it has been applied.

What is honestly open, in leverage order: liveness and usage honesty (axiom 2
is not yet everywhere); capability admission registries are live but empty;
notification delivery is single-pathed; the meta-loop (deploy records, version
truth, credential rotation, website) still runs on human memory outside the
product; the agent surface is not yet a designed, plan-only interface; and the
console's interaction grammar is not yet uniform.

## 5. The program

Do, in leverage order:

1. **Close loops before opening surfaces.** Process-level liveness, real
   usage, cross-alive notifications, admission registries filled, rollback to
   last known good. A feature is done when its loop is relied on daily and its
   evidence is visible in the product, not when its form submits.
2. **Lattice manages Lattice.** Deploy records as first-class objects; the
   website version matrix rebuilt from `/api/version`; token and knock-sequence
   rotation as approvals. This kills the five-answers problem permanently.
3. **Agents as first-class operators.** A plan-only interface surface for
   agents, confined by admission and scopes; approval on the phone (Astra's
   reason to exist: review and approve a plan in under a minute from anywhere);
   risk-tiered auto-approval with daily caps for routine changes.
4. **Coherence grammar as a checklist, not inspiration.** Every slice ships
   with: state in the URL, objects interlinked, failures leaving a trace,
   keyboard reachable, holding up at 1440 and 375. Grammar precedes screens.
5. **Tell the story when it is earned.** The reference implementation is the
   marketing: one operator, 33 nodes, agent-operated, full evidence chain.
   Write the method up when the unattended week is real.

Do not:

1. No fifth plugin until the four are excellent.
2. No multi-tenant SaaS; finish or close the half-open multi-operator surface.
3. No wasm runner while nothing needs it; no surface completeness for its own
   sake (publishing consolidates or freezes).
4. No competing with Netdata on observability or Tailscale on mesh.
5. No manual release ceremonies forever: batch them or automate them into the
   product.

## 6. Operating cadence

Unchanged and still binding: every slice moves plan, execute, review, iterate,
each leaving a durable artifact (`iterations/iter-NNN`), with independent
adversarial review and no self-approval. The contributor standard lives in
`development-workflow.md`; the concrete build/test/tag/release mechanics live
in `handbook.md`.

## 7. Hard constraints

- Security first, then honesty, then usability, then performance; performance
  is first-class on hot paths and interactive surfaces.
- Pure Go, zero CGo; every new dependency justified in an ADR.
- Fail closed. Unsafe defaults are bugs.
- Alpha train discipline: `alpha-0.2.2aN` for test deployments; stable-looking
  tags require an explicit operator decision; `latest` never selects a
  prerelease.
- Multi-repo `go.work`; integration is the working branch; merges are local
  `--no-ff` followed by direct push.
