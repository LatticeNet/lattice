# Iteration log

One file per slice: what was built, what it changed, how it was verified. The
log runs from `iter-001-oidc-sso.md` (2026-06-12) to
`iter-071-netguard-wireguard-plugin-repos.md` (2026-07-09). Numbering is
contiguous except for `iter-065`, which was never written.

This log is closed. It stopped being appended to after iter-071, while the work
did not: the plugin bundle v2 architecture, the native subscription platform,
managed line overlays, SSH Guard, connection trace, and capability gates all
landed after it. If you read this directory as the project's history you will
conclude that development stopped in July, which is wrong.

Where the record continued, in order:

1. `../designs/` for the capability designs from design-14 onward, each with
   its own acceptance and status. `../designs/README.md` carries the status
   table.
2. `../archive/superpowers/` and `../archive/plans/` for the two build cycles
   that used a separate planning tool instead of an iteration file.
3. The operator's program log at the workspace root, which has been the single
   active program and state file since 2026-09-01. It carries the known issues,
   the production truth, and the dated lane entries.

`development-workflow.md` still asks every slice to leave a durable artifact.
That requirement did not lapse; only this directory did. A new slice should
either add an `iter-NNN` file here or leave its record in the program log, and
should say which.
