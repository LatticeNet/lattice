# Iteration 061 - Dashboard Vue Phase 2 Core

## Scope

- **Repos:** `lattice-dashboard`, `lattice-server`, `lattice`
- **Goal:** Replace the highest-value Phase 2 placeholders with real
  API-backed operator screens in the canonical Vue dashboard and roll that
  dashboard into the server image pin.

## Delivered

- `lattice-dashboard`
  - `Fleet -> Nodes`: node list, live metrics, host facts detail dialog,
    enrollment token creation, token rotation, and enable/disable controls.
  - `Fleet -> Map`: CSP-safe local SVG projection backed by `/api/nodes/geo`,
    plus operator-owned node geo update/clear controls.
  - `Operations -> Approvals`: approval inbox, plan review, browser-side
    `sha256(plan)` calculation, approve-only, and approve-and-queue flow.
  - `Operations -> Tasks`: task list, result grouping, target selection,
    allowlisted interpreter selection, and task queue form.
  - `Operations -> Audit`: audit search filters, event rendering, metadata
    view, and audit-chain verification.
- `lattice-server`
  - Advanced `dashboard.ref` to the dashboard commit containing these screens.
- `lattice`
  - This iteration record.

## Verification

From `lattice-dashboard`:

```sh
pnpm build
```

Browser smoke:

- Vite preview served the production build locally.
- Playwright loaded `/nodes`, `/map`, `/approvals`, `/tasks`, and `/audit`
  with mocked same-origin API responses.
- Smoke covered node enrollment, map location save, approval
  `sha256(plan)` binding with `queue_apply=true`, task queue, and audit verify.

## Remaining Phase 2 Work

- `Fleet -> Monitoring`: create/delete monitors, result history, and failure
  triage surfaces.
- `Fleet -> Inventory`: machine inventory/cost/renewal surfaces once the Vue
  inventory contracts are mapped.
- Broader live-server E2E against a deployed `lattice-server` instance with real
  cookies/CSRF instead of mocked browser responses.
