# Lattice documentation

Start with [`PRODUCT-VISION.md`](./PRODUCT-VISION.md). It says what Lattice is,
the four axioms every slice is judged against, the north star, and what is
deliberately not being built. Everything else in this tree is downstream of it.

If you are here to build or ship something, read
[`handbook.md`](./handbook.md) next: it is the mechanics for every component,
from a local build to a signed plugin bundle.

This tree separates the durable from the dated. A document that states how the
system is shaped belongs in the first two areas and is expected to stay true. A
document that states what was true on a particular day belongs in the last two
and carries its date.

## What the product is, and why

- [`PRODUCT-VISION.md`](./PRODUCT-VISION.md): doctrine. Positioning, the four
  axioms, the north star, the honest current state, the program, and the hard
  constraints.
- [`architecture.md`](./architecture.md): how the pieces fit. Control plane,
  node agent, dashboard, SDK, plugin host, storage, audit.
- [`adr/`](./adr/): the decisions, one file each, with the alternatives that
  were rejected and why. Read [`adr/README.md`](./adr/README.md) first; ADR-004
  overturns half of ADR-003 and the index says so.

## How it is built and released

- [`handbook.md`](./handbook.md): build, test, tag, release, pin, debug, and
  report, per component. This is the file to reach for when a command is
  needed.
- [`development-workflow.md`](./development-workflow.md): how a slice moves
  from discussion to design to review to merge, and what each step must leave
  behind.
- [`SECURITY-HARDENING.md`](./SECURITY-HARDENING.md): the security posture and
  the hardening pass that established it.
- [`security-2fa.md`](./security-2fa.md): the TOTP threat model.
- [`contracts/`](./contracts/): the machine-checkable contracts. The sing-box
  metadata schema and its valid and invalid fixtures are consumed by tests in
  `lattice-node-agent`, so these files are code dependencies, not prose.
  [`contracts/release-pin-graph.md`](./contracts/release-pin-graph.md)
  explains how the components pin each other.
- [`tutorials/`](./tutorials/): operator how-to, from server install to the
  operator guide. [`tutorials/operator-guide.md`](./tutorials/operator-guide.md)
  is the broadest one.

## What is planned

- [`designs/`](./designs/): one design per capability, numbered.
  [`designs/README.md`](./designs/README.md) is a status table saying, for each
  design, whether it shipped, shipped in part, or was never built. Read the
  table before the designs; several design files still carry a status line from
  the day they were written.
- [`roadmap.md`](./roadmap.md): the dated log of program-level turns. It records
  when the direction changed and why. It is not a feature backlog.

## What happened, and when

- [`iterations/`](./iterations/): the per-slice build log, iter-001 to iter-071,
  covering 2026-06-12 to 2026-07-09. It is closed. See
  [`iterations/README.md`](./iterations/README.md) for where the record
  continues.
- [`archive/`](./archive/): documents that were true once and are not now. Every
  entry has a one-line reason in [`archive/README.md`](./archive/README.md).
  Nothing here governs current work; it is kept because it holds evidence and
  because code comments still refer to some of it by filename.

## Where version numbers live

Nowhere in this tree. Production versions are stated in exactly one place, the
production truth section of the operator's program log at the workspace root,
verified against `https://lattice.roobli.org/api/version`. Version strings that
appear in tutorials and runbooks are worked examples of a pattern, never claims
about what is deployed. Scattered stale version claims are a documented failure
mode of this project, so if you find one, replace it with the mechanism that
resolves it rather than with a fresher number.

## Writing rules for this tree

English, no emoji, no em or en dashes, no attribution trailers. Explain the
mechanism before the constant: if a reader is expected to paste a value, that
value needs a build-time check somewhere, and if it cannot have one, point at
the authority instead of restating it. The operator's Chinese long-form notes
and dated fleet records live in the vault, not here.
