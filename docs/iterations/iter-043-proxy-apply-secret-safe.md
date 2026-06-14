# Iteration 043 — Secret-Safe Proxy-Core Apply

- **Status:** Implemented and verified locally (2026-06-14)
- **Design:** [`designs/design-01-proxy-cores-and-subscriptions.md`](../designs/design-01-proxy-cores-and-subscriptions.md)
- **Builds on:** [`iter-042-proxy-reviewed-plan.md`](./iter-042-proxy-reviewed-plan.md)
- **Repos:** `lattice-server`, `lattice`

## Goal

Turn the reviewed proxy-core plan from iter-042 into a real apply path without
weakening the secret boundary:

- Enable `queue_apply:true` for `Plugin:"proxycore"`.
- Render the real sing-box config only into the node-owned task script.
- Encrypt persisted `model.Task.Script` in JSON and bbolt stores before any
  secret-bearing proxy apply task can be queued.
- Reconcile task results back into `ProxyNodeProfile.AppliedSHA256`,
  `LastApplyAt`, `LastError`, and the approval status.

## Security Decisions

- **Approval remains secret-free.** `Approval.Plan` still contains only the
  redacted review plan from iter-042. It never stores REALITY private keys,
  VLESS UUIDs, passwords, or subscription tokens.
- **Task scripts are now encrypted at rest.** `model.Task.Script` is a
  reversible credential boundary because apply scripts may carry rendered
  service configs. The JSON store encrypts it through `encryptedState`; bbolt
  encrypts/decrypts each task record at the record-level APIs.
- **Config SHA is the apply authority.** The stored action remains
  `apply-config:<sha256(real config)>`. Approval and queued apply re-render the
  current desired config and reject stale plans before creating a task.
- **No new node trust or interpreter.** The agent still receives a normal
  `model.Task{Interpreter:"sh"}` over its existing authenticated poll channel.
  No inbound node API or new interpreter is added.
- **Node-side apply is fail-closed.** The script writes a same-directory
  candidate file, runs `sing-box check -c`, atomically swaps only after
  validation, then reloads or restarts `sing-box`. If activation fails after
  the swap, the script restores the previous target file and tries to restart
  the previous config before returning failure.

## Apply Script Contract

The server-generated script:

1. Requires `sing-box` to exist on the node.
2. Writes the renderer-owned JSON config to `${config_path}.lattice-new` with
   `umask 077`.
3. Runs `sing-box check -c "$CANDIDATE"`.
4. Backs up the existing target, if any.
5. Moves the candidate to the configured target path only after validation.
6. Attempts `systemctl reload sing-box`, then `systemctl restart sing-box`; if
   systemd is unavailable it tries `service sing-box reload/restart`.
7. Restores the previous target and tries to restart the previous config when
   activation fails after the atomic swap.
8. Fails the task when no supported service manager can activate the checked
   config, so `AppliedSHA256` is not advanced for a config that may not be live.
9. Deletes the candidate and backup on success/failure as appropriate.

The script contains real node-scoped proxy credentials. It must be visible only
to the owning node through the existing agent task lease path; control-plane task
views continue to expose only script hash and byte size.

## Routes / Behavior

| Flow | Result |
|---|---|
| `POST /api/proxy/nodes/{node_id}/plan` | unchanged from iter-042: returns a redacted `ApprovalView` and stores the real config SHA in the action |
| `POST /api/network/approvals/approve` with `queue_apply:true` | for `proxycore`, creates a queued task after plan-hash and current-config checks |
| `GET /api/agent/tasks?node_id=...` | returns the real script only to the authenticated owning node |
| `POST /api/agent/task-result` | marks proxy profile applied/failed and writes `proxy.apply.applied` / `proxy.apply.failed` audit events |

## Tests Added / Updated

- JSON encrypted-at-rest tests now seed a task with a sensitive script and prove
  it does not appear in the state file, survives reopen, participates in
  lost-key protection, and migrates from plaintext legacy state on the next
  save.
- bbolt import/export tests prove task scripts are encrypted in the bucketized
  state and decrypt on export.
- bbolt record-level lifecycle tests prove `CreateTask`, `Tasks`, `LeaseTasks`,
  `AddTaskResult`, and reopen all keep task scripts encrypted on disk while
  returning plaintext to the correct in-memory/API boundary.
- Proxy plan/apply test now verifies:
  - review plan remains secret-free;
  - queued task script contains the real sing-box config and validation/atomic
    swap commands;
  - control-plane task list does not serialize `script`;
  - agent lease/result marks the profile and approval applied;
  - `proxy.apply.applied` audit carries the applied config hash.

## Verification

Run from `lattice-server`:

```sh
GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test ./internal/store ./internal/proxycore -count=1

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test ./internal/server -run 'TestProxy|TestApprove|TestAgentTask|TestApplyScript|TestTask' -count=1

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go test -race ./internal/server -run 'TestProxy' -count=1

GOWORK=/Users/cdcd/roobli/RTFS_justTaste/Probe-Dashboards/Lattice/lattice/go.work \
GOCACHE=/private/tmp/lattice-gocache \
go build ./cmd/lattice-server
```

Results:

- store/proxycore suites: pass
- server proxy/approval/task targeted suite: pass
- proxy server race suite: pass
- server build: pass

Known environment notes:

- Full `go test ./internal/server` is not a valid signal in the current sandbox
  because OIDC tests use `httptest.NewServer` and local TCP listen is denied
  (`bind: operation not permitted`). The proxy/approval/task tests above avoid
  that listener path.
- The Go tool may still print a non-fatal module stat-cache warning when it
  attempts to write under `/Users/cdcd/go/pkg/mod`; the command exit code is 0.

## Residual Risks / Next Work

1. There is no dashboard proxy apply UI yet; the API is ready, but operators
   still need the generic approval UI or API calls.
2. No automatic drift reconciler exists. If shared inbounds/users change after
   a node was applied, the profile's `AppliedSHA256` will diverge from the next
   rendered config; a later slice should surface and optionally queue re-apply.
3. `/sub/{token}` is still pending as of this iteration. It must add an opaque
   token lookup or constant-time scan with rate limiting before exposing
   subscription URLs. **Resolved in iter-044** with a constant-time full scan,
   dedicated public limiter, and raw-token-free audit metadata.
4. Usage accounting is still pending. Add `/api/agent/proxy-usage`, monotonic
   diffs, quota/expiry alerts, and dashboard rollups after the subscription MVP.
