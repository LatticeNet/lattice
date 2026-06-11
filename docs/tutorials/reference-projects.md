# Reference Project Notes

Lattice intentionally learns from the three local probe projects without merging
their codebases.

## NodeGet

Adopted ideas:

- Rich dashboard.
- Batch task execution and result collection.
- KV, static buckets, Worker-style extension points.
- Detailed server board and audit-style logs.

Avoided in V1:

- One broad admin surface where high-risk powers are easy to combine.
- Arbitrary JS capabilities without explicit host boundaries.

## Nezha

Adopted ideas:

- Scopes and server allowlists.
- Strong audit trail.
- Long-running agent control plane.
- Scheduled tasks as structured jobs instead of raw shells.

Avoided in V1:

- Directly exposing terminal/file/MCP-like powers before the permission model is
  fully hardened and tested.

## NodeLite

Adopted ideas:

- Conservative default behavior.
- Small agent responsibility.
- Readable deployment model.
- Performance tests as a first-class project habit.

Avoided in V1:

- A purely read-only product surface. Lattice needs controlled operations and
  extension points from the start.

