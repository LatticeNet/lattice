# Archive

Documents that were correct when written and are not a guide to the system now.
Nothing here governs current work. They are kept rather than deleted because
they hold evidence, because they record why a decision went the way it did, and
because code comments and older iteration notes still cite some of them by
filename.

Each entry says why it was archived. If you are looking for what is true today,
go back to [`../README.md`](../README.md).

Archived 2026-09-03 during the documentation reorganisation.

- `program-review-and-roadmap-2026-06.md` (2026-06-12, addenda to 2026-06-14):
  point-in-time program review and security audit. Archived because it reviews
  a six-repository ecosystem that has since grown past twelve repositories, and
  its roadmap half is superseded by `../PRODUCT-VISION.md` section 5. Accurate
  as history.
- `development-report-2026-06-13.md` (2026-06-13): the baseline development
  snapshot taken at the same time. Archived for the same reason: it describes a
  scope the project has outgrown.
- `roadmap-backlog-2026-06.md` (2026-06-11 to 2026-06-15): the feature backlog
  that `../roadmap.md` carried until 2026-09-03. Archived because it was never
  revised after iteration 060 and now contradicts the shipped system, most
  visibly where it says plugin artifact execution remains disabled while four
  signed plugins run in production. Its delivered and pending annotations are
  the reason to keep it.
- `plans/2026-08-05-design-16-sub1-implementation.md` (2026-08-05): the
  task-by-task implementation plan for the first sub-project of design-16.
  Archived because it is a worklist, not a record: all 63 of its checkboxes are
  still unticked while the native subscription platform it specifies is live in
  `lattice-plugin-sub-store`. Read it as the specification that work was built
  from, not as a status.
- `superpowers/specs/2026-07-13-self-contained-plugin-bundles-design.md`
  (2026-07-13): the design for signed, deterministic v2 plugin bundles with
  sandboxed iframe UIs and a versioned postMessage bridge. Archived because it
  shipped: `lattice-plugin-bridge` and the four production plugins are this
  design. Kept as the rationale for the architecture that replaced the
  dashboard-builtin component model.
- `superpowers/plans/2026-07-13-plugin-bundle-v2-substore.md` (2026-07-13): the
  Sub-Store pilot plan for the spec above. Archived because its rollout steps
  target pins from an earlier alpha train that no longer exist in production.

The `superpowers/` directory name is the tool that produced those two files. It
is preserved so that references to those paths in older sessions still resolve.
