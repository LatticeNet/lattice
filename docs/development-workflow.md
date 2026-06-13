# Lattice Development Workflow

Lattice is security-first infrastructure software. New work must move through a
deliberate design and review path before implementation, especially when it
touches auth, storage, plugins, networking, agents, or any operation that can
execute code on a node.

## Core Rule

Do not start by coding. Start by making the feature safe and coherent enough to
code.

The standard flow is:

1. **Discuss the feature**
2. **Design the framework**
3. **Evaluate reasonableness and security**
4. **Check compatibility and migration impact**
5. **Define acceptance gates**
6. **Implement**
7. **Verify**
8. **Record**
9. **Review**
10. **Commit and push**

Skipping steps is allowed only for trivial documentation or typo fixes. Security
or compatibility questions are never trivial.

## 1. Discuss the Feature

Before implementation, write down:

- the user problem and operator workflow;
- which repository owns the change;
- which trust boundary is affected: server, agent, dashboard, SDK, plugin, or
  operator documentation;
- whether the feature is core, official-plugin, or future marketplace material;
- what a safe failure looks like;
- what must remain backwards-compatible.

If the feature involves remote execution, firewall/network configuration,
credential storage, plugin execution, OAuth/SSO, sessions, or data migration,
open an iteration document before code.

## 2. Design the Framework

The design should choose the smallest stable boundary that can support future
growth:

- **Server** owns policy, auth, RBAC, storage, approvals, and audit.
- **Agent** executes bounded node-local work and should stay outbound-only.
- **Dashboard** renders server decisions and must not make security decisions.
- **SDK** owns shared domain and wire-contract types.
- **Plugin template** documents extension contracts and trust expectations.

For APIs, prefer a stable JSON bootstrap path today, but design with eventual
protobuf/ConnectRPC compatibility in mind:

- use explicit request/response structs;
- keep error codes stable;
- avoid leaking internal errors or local paths;
- keep secret fields write-only in public/admin views;
- add versioning or migration notes when changing persistent models.

For plugins, design capability boundaries first:

- declare the capability name and risk tier;
- define which host API method enforces it;
- define audit events for allow/deny;
- define timeout, output, rate, and cancellation limits;
- require signed manifests for host-risk behavior.

## 3. Evaluate Security and Reasonableness

Every non-trivial design needs a short risk pass:

- **Spoofing:** can an actor impersonate another user, node, plugin, or IdP?
- **Tampering:** can input alter a plan, task, firewall rule, config, or stored
  secret outside the intended path?
- **Repudiation:** is there an audit record with actor, token, node, action,
  decision, and correlation id?
- **Information disclosure:** does any API, log, disk file, or dashboard expose
  secrets, scripts, paths, tokens, or internal errors?
- **Denial of service:** are there caps, deadlines, rate limits, pagination, and
  bounded memory/output?
- **Elevation of privilege:** does RBAC and server allowlist enforcement happen
  against the real target resource?

Unsafe defaults are bugs. Prefer fail-closed behavior even when it is less
convenient.

## 4. Check Compatibility

Compatibility is part of the design, not cleanup after the fact.

Before coding, decide:

- whether existing JSON state can still load;
- whether old bbolt buckets or legacy plaintext records need fallback reads;
- whether SDK models need semver handling;
- whether dashboard clients can tolerate absent fields;
- whether agent/server versions can be mixed for one release;
- whether a migration or rollback path exists.

Special cases can break compatibility, but they must be explicitly justified in
an ADR or iteration document.

## 5. Define Acceptance Gates

Each iteration document should include:

- goal and non-goals;
- affected repositories;
- design summary;
- security notes;
- compatibility notes;
- tests to add or update;
- commands that must pass;
- residual risks and next work.

For code changes, default verification is:

```sh
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test ./... -count=1
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go vet ./...
GOCACHE=/tmp/lattice-review-go-build GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work go test -race ./... -count=1
```

For dashboard changes:

```sh
cd ../lattice-dashboard
npm test
node --check assets/app.js
```

For visual/UI changes, verify with a browser against the running server before
claiming completion.

## 6. Implement

Implementation rules:

- keep diffs scoped to the iteration;
- prefer existing helpers and package boundaries;
- add tests with the behavior, not after the behavior;
- avoid new dependencies unless an ADR justifies them;
- keep secret-bearing fields at the store or view boundary;
- avoid broad refactors while adding a feature;
- make failure modes legible through errors, logs, and audit events.

Dangerous operations must preserve `plan -> diff -> approve -> apply`.

## 7. Verify

Verification must match the blast radius:

- storage/auth/network/plugin changes require `go test -race`;
- storage encryption changes require plaintext-leak and wrong-key tests;
- API changes require authz and stable error tests;
- dashboard changes require unit checks and browser smoke testing;
- migration changes require forward and rollback tests.

Do not treat a narrow unit test as evidence for a broad production claim.

## 8. Record

After implementation:

- update the iteration document with the real verification result;
- update `PRODUCT-VISION.md` and `roadmap.md` when project state changes;
- update `architecture.md` when boundaries or invariants change;
- update tutorials when operator behavior changes;
- write residual risks honestly.

The docs are part of the product. If an operator could misunderstand the state
of a feature from the docs, the feature is not done.

## 9. Review

Before commit, review in this order:

1. Diff review for scope and accidental changes.
2. Security review for trust boundaries and fail-closed behavior.
3. Compatibility review for state, API, SDK, and agent/server version skew.
4. Test adequacy review: do tests prove the claim, or only exercise a happy path?

For security-sensitive work, prefer an independent reviewer/subagent pass. Fix
must-fix findings before commit.

## 10. Commit and Push

Use the Lore commit protocol. The first line says why the change exists, not
what files changed. Include the useful trailers:

```txt
Constraint: <external constraint>
Rejected: <alternative> | <reason>
Confidence: <low|medium|high>
Scope-risk: <narrow|moderate|broad>
Directive: <future warning>
Tested: <commands/evidence>
Not-tested: <known gap>
```

Push only after:

- worktree status is understood;
- staged diff is clean;
- verification evidence is recorded;
- docs reflect the actual state.

## Stop Rules

Pause implementation and return to design if:

- the feature needs new remote execution powers;
- a secret would move to a new storage or logging boundary;
- compatibility requires a migration;
- a new dependency is needed;
- a dashboard workflow can trigger a destructive operation;
- tests cannot prove the intended security property.

When in doubt, design the safety boundary first.
