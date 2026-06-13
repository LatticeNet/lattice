# Storage Migration Drills

Lattice still runs on the encrypted JSON state file by default. The bbolt path
is available for migration testing and rollback drills, not as the default
runtime store yet.

## Safety rules

- Stop `lattice-server` before migrating. The current JSON store rewrites the
  whole file, so an online copy can race with server writes.
- Back up `state.json`, `state.json.audit-wal`, and `master.key` together.
  Losing `master.key` makes encrypted secrets unrecoverable.
- Use explicit paths. The migration CLI requires both `-json` and `-bolt`.
- Do not use `-overwrite` until the target file is backed up and the command has
  already succeeded once without it.
- Keep JSON as the runtime source until a later release adds an explicit
  `-data-engine=bolt` startup switch.

## JSON to bbolt

```sh
systemctl stop lattice-server

cp -a /var/lib/lattice/state.json /var/lib/lattice/state.json.bak
cp -a /var/lib/lattice/state.json.audit-wal /var/lib/lattice/state.json.audit-wal.bak
cp -a /var/lib/lattice/master.key /var/lib/lattice/master.key.bak

lattice-server migrate json-to-bolt \
  -json /var/lib/lattice/state.json \
  -bolt /var/lib/lattice/state.db
```

If your key file is not `/var/lib/lattice/master.key`, pass it explicitly:

```sh
lattice-server migrate json-to-bolt \
  -json /var/lib/lattice/state.json \
  -bolt /var/lib/lattice/state.db \
  -master-key-file /etc/lattice/master.key
```

The command fails if `state.db` already exists. Re-run with `-overwrite` only
after backing up the existing target.

## bbolt to JSON rollback export

```sh
lattice-server migrate bolt-to-json \
  -bolt /var/lib/lattice/state.db \
  -json /var/lib/lattice/state.rollback.json
```

The exported JSON is still encrypted at rest. It should not contain plaintext
TOTP secrets, DDNS tokens, notification credentials, or OIDC client secrets.

## What this does not do yet

- It does not change server startup. `lattice-server` still opens
  `/var/lib/lattice/state.json`.
- It does not migrate or anchor the audit WAL into bbolt.
- It does not route runtime traffic to record-level bbolt writes. Foundation
  APIs currently exist for nodes, KV, audit, static objects, Worker scripts,
  plugin lifecycle records, approvals, tasks, task results, monitors, monitor
  results, and tunnels; secret-bearing buckets are still pending.
- It does not remove the need for backup/restore testing before production
  storage cutover.
