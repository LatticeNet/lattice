# Tutorials

This directory holds operator- and contributor-facing guides for the Lattice
ecosystem. Keep tutorials practical: each one should say what the operator is
trying to accomplish, the safety assumptions, the exact commands or API flow,
and what is still not production-ready.

## Operator Guides

- [Server install](./server-install.md)
- [Agent install](./agent-install.md)
- [Storage migration drills](./storage-migration.md)
- [Network guard](./network-guard.md)
- [Static and KV](./static-and-kv.md)
- [Plugins](./plugins.md)
- [Reference projects](./reference-projects.md)

## Contributor Guides

- [Development workflow](../development-workflow.md)

## Tutorial Standard

Every tutorial should include:

- prerequisites and trust assumptions;
- commands or API examples that can be copied directly;
- security notes for credentials, network exposure, and destructive operations;
- rollback or cleanup instructions when state changes;
- current limitations and links to the relevant roadmap/iteration document.

Do not describe a feature as production-ready unless the implementation,
verification, migration path, and security review all support that claim.
