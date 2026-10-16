# Design 30: plugin process isolation, a uid boundary between the server and the code it runs

Status: proposed 2026-10-16 for the operator's decision; closes `PROGRAM.md` KI-22. No code is written. This is a read-only design produced from the `integration` checkouts below; the facts in "What a plugin child can reach today" were verified in source before anything else in the document was decided. Slices S1 to S3 below; none built.
Date: 2026-10-16.
Reference: lattice-server `integration` at 3231a08 (production is `alpha-0.2.2a125`, the a126 switch staged), lattice-sdk `integration` at 042370c, lattice-plugin-vpn-core at 9e7b61f (0.11.0-alpha.7), lattice-plugin-sub-store at f868982 (0.17.0-alpha.2), lattice-plugin-netguard at 1b37d1b (0.2.0-alpha.6), lattice-plugin-wireguard at bc45ce7 (0.2.0-alpha.6), umbrella at 223cedf, production compose `.claude/ops/compose-a126.yml`.

## Summary

lattice-server runs system plugins as its own operating-system identity. The runner calls `exec.Command` on the staged artifact with `SysProcAttr{Setpgid: true}` and nothing else (`lattice-server/internal/plugin/system_runner.go:1166` for a one-shot v1 invocation, `system_transport.go:415` for a pooled stdio-json-v2 worker). The child inherits the server's uid (`lattice`, the account the container's entrypoint drops to), its mount namespace, its network namespace, and its supplementary groups, one of which is `65532`, the probe's group. A compromised or malicious signed plugin is therefore the server as far as the operating system is concerned: it can read `master.key` and the whole state tree, open the lattice-probe socket directly and skip the `vpn:probe` scope check, the per-operator limits and the audit, and reach the server's own loopback API. The signature chain proves who built the artifact; it does not confine what the artifact does once it runs.

This design puts an operating-system boundary under the signature: plugin children run as a dedicated unprivileged uid that owns none of the server's files and is not in the probe's group. The host-call path (a plugin's only legitimate way to reach the fleet) is a set of inherited pipes and survives the uid change untouched, so the four production plugins keep working with no change to their code. The boundary is enforced by the kernel's own discretionary access control, needs no new dependency, and is pure Go. It does not fix everything: the child still shares the server's network and PID namespaces, and the loopback API stays reachable though unauthenticated. Those residuals are named, and the cheaper follow-on that narrows them is scoped as a later slice.

## What the operator asked

KI-22, recorded 2026-10-09 after a122, and the closing note in design 27's security section: plugin processes run as the server's uid with its mount namespace and group `65532`, so a plugin can open `/run/lattice-probe/probe.sock` directly and bypass the probe's server-side gate. The KI says this "adds no reach" because the plugin already reads everything that uid reads and the probe's own address policy and in-flight ceiling still apply, and asks for the fix to be "plugin process isolation (own uid or a mount namespace without the socket directory)." This design is that fix, and it widens the frame the KI drew: the probe socket is one of several things the shared uid exposes, and the isolation that closes the socket closes most of the rest at the same time.

## What a plugin child can reach today

Read from the checkouts above and the production compose on 2026-10-16.

1. **How the child is started.** `runInvocation` (v1, `system_runner.go:1166`) and `startSystemWorkerObserved` (v2, `system_transport.go:415`) both build `exec.Command(path)`, set `cmd.Dir` to the plugin's `0700` working directory under `LATTICE_PLUGIN_RUNTIME_DIR`, set `cmd.Env` from `childEnv()`, set `cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}`, and pass one extra file descriptor (fd 3, the host-response pipe) plus stdin, stdout and stderr. `Setpgid` is the only attribute. There is no `Credential`, no `Unshareflags`, no `Chroot`, no `Pdeathsig`.
2. **What uid it runs as.** The image's `docker-entrypoint.sh` runs the server through `su-exec lattice`, so the server process is uid `lattice` (uid 100 in the alpine image) with an empty capability set and the supplementary group `lattice-probe` (gid 65532). A forked child inherits all of it. The compose file gives the `lattice-server` container no `user:`, no `cap_drop`, and no `security_opt`, so the container starts as root with Docker's default capability and seccomp profile and the entrypoint does the drop.
3. **The environment it gets.** `childEnv()` (`system_runner.go:1806`) forwards only the variables named in `EnvAllowlist` and always adds a fixed `PATH`. In production `EnvAllowlist` is empty (`server.go:844`, confirmed by the comment and by `LATTICE_PLUGIN_RUNTIME_ENV` being unset in the compose file), so no host environment, no secret and no `LATTICE_*` setting leaks into the child. This part is already tight.
4. **The probe socket.** `/run/lattice-probe/probe.sock` is mode `0660` owned `65532:65532` on a tmpfs the compose file creates mode `0770` owned `65532:65532`. The server reaches it because uid `lattice` carries supplementary group `65532`. A plugin child carries the same group, so a direct `net.Dial("unix", ...)` from the child succeeds and the request never passes through `vpncore_probe.go`, which is where `probeScope = "vpn:probe"`, `probeMaxRunsInFlight`, `probeMaxRunsPerHour` and the `vncore.probe` audit record live. The probe's own SSRF policy and its 32-run engine ceiling still apply, so this is not arbitrary outbound; it is unaudited, unmetered, unauthorized probing.
5. **The state tree.** `/var/lib/lattice` is the `./data` bind mount, owned `lattice:lattice`. Every sensitive file in it is mode `0600` owned by `lattice`: `master.key` (the at-rest key that decrypts every stored credential, `secret.go:281`), `state.json` and `state-hot.db` (`store.go`, `bolt_state.go`, mode `0600`), the audit WAL (`audit/wal.go:162`, append `0600`), `logs.db`, `metrics.db` and `trace.db` (`0600`), and the plugin bundle cache and runtime dirs (`0700`). Because the child is uid `lattice`, discretionary access control grants it read and write on all of them. Reading `master.key` plus `state-hot.db`/`state.json` is full credential disclosure. Writing the audit WAL is tampering, bounded only by the hash chain and the off-box anchoring that would make the tamper detectable after the fact, not prevent it.
6. **The plugin tree.** `/plugins` is mounted read-only, so a child cannot swap a bundle or edit `.trust.json`, but it can read every other plugin's artifact and the trust policy.
7. **The network namespace.** The child shares the server's netns. The server listens on `0.0.0.0:8088` inside the container (published only to the host's `127.0.0.1:8088`), so the child can reach the full server API over loopback. It holds no admin cookie or token, so it cannot drive authenticated endpoints, but any unauthenticated surface is reachable. The probe is on its own `probe` bridge network that the server container is not joined to, so the socket, not the network, is the probe's only exposure today.
8. **The PID namespace.** The child shares the server's PID namespace and runs as the same uid, so it can `kill` the server process or any sibling plugin. `Setpgid` only isolates signal delivery for teardown; it is not a privilege boundary.
9. **No docker socket.** The compose file mounts no `/var/run/docker.sock` into the server container (volumes are `./data`, `./plugins:ro` and the `probe-run` tmpfs only). There is no container-escape-to-host path through a mounted daemon socket, which removes the worst case from the table.

The precise exposure, then: a plugin that stops speaking the protocol and instead uses the Go runtime it already is can read the master key and all state, forge or probe the fleet through the probe socket without a trace in the audit log, and signal the control plane. The signature says the artifact is the one the operator approved; nothing stops that artifact from doing any of this.

## Options

Four mechanisms can put a boundary between the server and its plugin children. Costs are specific to this codebase (`os/exec` with `SysProcAttr`, pure Go, zero CGo, an ADR for any new dependency) and this compose (non-root entrypoint via `su-exec`, Docker default caps and seccomp, no `no-new-privileges` on the server container).

| Option | Mechanism | What it closes | Container cost | Verdict |
|---|---|---|---|---|
| (a) dedicated uid | `SysProcAttr.Credential` drops each child to uid 65533, not in group 65532, owning none of the state | probe socket (DAC), `master.key` and all state (DAC), cross-uid `kill` of the server | keep `CAP_SETUID`/`CAP_SETGID` as ambient caps on the `lattice` process across the drop; chown each plugin workdir to the plugin uid | chosen |
| (b) mount namespace or chroot | `Unshareflags: CLONE_NEWNS` or `SysProcAttr.Chroot` to a tree without the socket or the state | probe socket and state by making them absent from the child's view | `unshare(CLONE_NEWNS)` needs `CAP_SYS_ADMIN`; `chroot` needs `CAP_SYS_CHROOT`; a user namespace to avoid `CAP_SYS_ADMIN` is blocked by Docker's default seccomp unless a custom profile allows `unshare`/`clone` with `CLONE_NEWUSER` | rejected as the primary, kept as defense in depth |
| (c) move the socket, authenticate the channel | socket leaves the server container's view; server reaches the probe over TCP on the `probe` network with a per-boot token held only in server memory | probe socket only | server joins the `probe` network; probe gains a token check; a new TCP listener | rejected as insufficient alone; folded in as a probe-side hardening |
| (d) Landlock or seccomp in the child | the child self-restricts filesystem, socket and network access before real work | whatever the filter names, if the child applies it | needs a sandboxing library or raw syscalls; only binds plugins that choose to apply it | rejected as a boundary; usable only as SDK-side defense in depth |

### (a) a dedicated plugin uid, enforced by the host

The server forks each plugin child with `SysProcAttr.Credential{Uid: 65533, Gid: 65533, NoSetGroups: true}` (the Go standard library issues `setgroups`, `setgid`, `setuid` between fork and exec, `syscall/exec_linux.go`). The child is then uid 65533, a new `lattice-plugin` account that is not in group 65532 and owns nothing under `/var/lib/lattice`. Discretionary access control now denies it the probe socket (`0660 65532:65532`, no world bits), `master.key` and every `0600 lattice` file, and it cannot signal the server across the uid boundary without `CAP_KILL`, which it does not have. The host-call pipes (stdin, stdout, stderr, fd 3) are inherited open descriptors and survive `setuid` and `execve`, so the plugin protocol is unaffected and no plugin code changes.

The cost is real and bounded. A process can only `setuid` to an unrelated uid if it holds `CAP_SETUID` (and `CAP_SETGID` for the group), so the `lattice` process must keep those two capabilities. Docker's default bounding set already contains both; the only change is to preserve them as ambient capabilities when the entrypoint drops from root to `lattice`, by replacing `su-exec lattice` with `setpriv --reuid lattice --regid lattice --init-groups --ambient-caps +setuid,+setgid` (util-linux `setpriv` is packaged for alpine 3.22). The server container has no `no-new-privileges`, so ambient capabilities can be set. The server thus holds two capabilities whose only use is to downgrade its children; a server already compromised is already lost, so granting it the means to confine the code it runs is a sound trade and is stated as such. Second, the staged artifact and its `0700` working directory are owned by `lattice`, so the runner must `chown` them to the plugin uid (mode `0500`, read and execute) after staging, so `execve` by the child succeeds while the server's own data stays `0600 lattice`. That is one `chown` per generation in code the runner already owns.

What (a) does not fix: the child still shares the server's network namespace, so the loopback API on `127.0.0.1:8088` stays reachable (unauthenticated only, and the probe stays off the server's network); and it shares the PID namespace, so the child can still observe process metadata under `/proc` even though it can no longer signal across uids. These are the residuals, narrowed by the optional follow-on below.

### (b) mount namespace or chroot

Making the socket and the state simply absent from the child's filesystem view is conceptually the cleanest confinement, and the KI names it. In this container it is the expensive one. `unshare(CLONE_NEWNS)` requires `CAP_SYS_ADMIN` in the current user namespace, a broad capability the server does not want; `chroot` requires `CAP_SYS_CHROOT`, narrower but still a capability to retain across the drop, and a chroot tree to populate and maintain with the artifact and its `PATH` binaries. Avoiding `CAP_SYS_ADMIN` by unsharing a user namespace first is blocked by Docker's default seccomp profile, which denies `unshare` and `clone` with `CLONE_NEWUSER` to a process without `CAP_SYS_ADMIN` (verified against moby's current `profiles/seccomp/default.json`: the `unshare` group and the `CLONE_NEWUSER` `clone` paths are gated on `CAP_SYS_ADMIN`). So (b) needs either a broad capability or a custom seccomp profile layered onto the container, against a doctrine of fail-closed minimalism. It is kept as a defense-in-depth layer that composes with (a) later, not as the first boundary.

### (c) move the socket out, authenticate the channel

This closes exactly the one hole the KI's title names and nothing else. The probe socket moves to a volume the server container does not mount; the server joins the `probe` network and calls the probe over TCP with a bearer token minted once per boot and held only in server memory, which the probe checks. A plugin child, sharing the netns, could reach the port but cannot produce the token (it lives in the server's address space, not the child's environment or any file). It leaves `master.key`, the state tree, the audit WAL and the loopback API exactly as exposed as today, so as the answer to KI-22 it is a partial fix wearing the KI's own words. It is worth doing as probe-side hardening regardless, because a token on the probe channel is good practice, but it is not the isolation boundary.

### (d) Landlock or seccomp applied in the child

Landlock could, in principle, deny the child the state directory and (from ABI 9, `LANDLOCK_ACCESS_FS_RESOLVE_UNIX`) connecting to the probe socket by path; ABI 4 could deny the loopback TCP connect. But ABI 9 is a 2026 patch series not present in the production kernel, Go has no standard-library Landlock and would need a vetted dependency (an ADR, against the zero-CGo and minimal-dependency rules it can satisfy, but still a new attack surface in the host), and most fundamentally the host cannot run arbitrary code between fork and exec through `os/exec`, so the restriction would have to be applied by the plugin itself as its first action in the SDK runtime. A malicious plugin simply would not apply it. That makes (d) a hardening the honest SDK can adopt, never a boundary the host enforces. It is noted for the SDK, not chosen.

## Decision

Take (a): plugin children run as a dedicated unprivileged uid, enforced by the host with the kernel's own access control, with the two capabilities the drop requires preserved on the server process and the plugin workdir chowned to the plugin uid. Fold (c) into the probe as a token on the probe channel, so that even a future change that re-exposes the socket does not re-open the bypass. Keep (b) and (d) as named defense-in-depth layers for later, not as the gate.

The reasons, against the alternatives: (a) is the only option that is host-enforced (not plugin-cooperative), pure Go with no new dependency (`SysProcAttr.Credential` is standard library), fail-closed (a child that cannot drop does not start), and closes the largest share of the exposure in one change (probe socket, master key, all state, cross-uid signalling) rather than the socket alone. (b) buys little more than (a) for a broad capability or a custom seccomp profile. (c) alone leaves the credential store exposed. (d) is not a boundary. (a) fits axiom 3 directly: "capability gates confine what may even be asked" of the system, now extended from the node and the broker down to the operating-system identity of the code the control plane runs, and it strengthens the Platform pillar's promise of "brokered capabilities" with an isolation the broker could not previously assume.

What the decision explicitly does not fix, restated so it is not mistaken for complete: the shared network namespace (the loopback API stays reachable, authenticated endpoints still need a credential the child lacks, the probe stays off the server's network) and the shared PID namespace (`/proc` metadata is still visible, though signalling across uids is gone). Narrowing these is the optional S3 below.

## The change

### Runner (`lattice-server/internal/plugin`)

Add `PluginCredential *syscall.Credential` (or a plain `PluginUID`/`PluginGID` pair resolved to a `Credential`) to `SystemRunnerOptions`. When set, `runInvocation` and `startSystemWorkerObserved` set `cmd.SysProcAttr.Credential` alongside the existing `Setpgid`. When unset, behaviour is exactly as today, so the server image can ship before the compose turns it on and can roll back by turning it off. After staging the artifact (`Prepare`, around `system_runner.go:331`), `chown` the working directory and the `artifact` file to the plugin uid and set mode `0500`, so the dropped child can `exec` it while the server's own `0600` data is untouched. The host-response pipe, stdin, stdout and stderr are already passed as inherited descriptors and need no change; add a test that proves they still carry a host call after the drop.

### SDK (`lattice-sdk`)

No change required for the boundary. The host-call client reads fd 3 from `LATTICE_HOST_RESPONSE_FD` (`plugin/host.go:204`) and that descriptor is inherited across the drop. The SDK is the natural home for the optional (d) self-sandbox later, behind a runtime flag, but that is not part of closing KI-22.

### Image (`lattice-server/Dockerfile`, `docker-entrypoint.sh`)

Create the `lattice-plugin` account (uid and gid 65533, no login, no membership in `lattice-probe`) beside the existing `lattice` and `lattice-probe` accounts in the final stage. Add `setpriv` (util-linux) to the installed packages. Replace `exec su-exec lattice "$@"` with `exec setpriv --reuid lattice --regid lattice --init-groups --ambient-caps +setuid,+setgid "$@"`, so the server runs as `lattice` with `CAP_SETUID` and `CAP_SETGID` ambient and nothing else. The server's own data ownership is unchanged; the plugin uid owns only what the runner chowns to it per generation.

### Compose (`.claude/ops/compose-aNNN.yml`)

Set `LATTICE_PLUGIN_UID: "65533"` (and gid) on the `lattice-server` service to turn the drop on. The default Docker capability set already contains `CAP_SETUID` and `CAP_SETGID`, so no `cap_add` is needed; if a later hardening pass adds `cap_drop: [ALL]` with an explicit add-list (worth doing), the list must then include `SETUID` and `SETGID`. Do not set `no-new-privileges` on the server container while it relies on ambient capabilities. The probe service is unchanged by (a); (c) adds the probe-channel token in a separate probe release.

### Plugins

None. Verified: the four production plugins do no direct filesystem, network or process I/O from their runtime binaries (`path/filepath` appears only for in-memory path handling; sub-store's `net`, `os/exec` and `syscall` imports are confined to its `tools/` and `_test.go` files, not the plugin entrypoint), and reach the host only through the SDK's inherited pipes. The dedicated uid takes away nothing they use.

## Migration and rollback

Ship in order. First the server image with the runner option and the entrypoint change, with `LATTICE_PLUGIN_UID` unset, so the running behaviour is identical to today and the image is provably safe in precheck. Then a compose switch that sets `LATTICE_PLUGIN_UID`, which is the step that turns the boundary on. Rollback at any point is the standard image or compose rollback already in `switch-aNNN.sh`: unsetting the env returns to shared-uid children on the same image, and rolling the image back removes the entrypoint change. The probe-channel token (c) ships as its own probe release and compose change, independent of (a), and rolls back the same way.

## Verification

### Tests

- A runner test that starts a plugin child with the credential set and asserts the child's reported uid is 65533, not the server's.
- A runner test that a plugin child cannot open the probe socket: stage a tiny test artifact that attempts `net.Dial("unix", "/run/lattice-probe/probe.sock")` (or a stand-in socket owned by a foreign gid `0660`) and assert the dial fails with permission denied; the same test with the credential unset must succeed, so the test proves the boundary and not merely a missing socket.
- A runner test that a plugin child cannot read a `0600` file owned by the server uid (a stand-in for `master.key`) and can read and exec its own `0500` artifact.
- A runner test that a host call still completes after the drop (fd 3 round-trip), so the protocol is proven unbroken.
- Keep the existing process-group teardown tests green; cross-uid `kill` of the group is still done by the server, which holds the pgid and the uid relationship, not by the child.

### Production precheck

Add a precheck step to `.claude/ops/precheck.sh` that, inside the running candidate container (which already boots with `--network none` against a copy of production data), loads the real plugin set and asserts: the four plugins load with `0 rejected` (already checked); a probe call driven through vpn-core's broker path still returns (the legitimate path); and a direct open of `/run/lattice-probe/probe.sock` and of `/var/lib/lattice/master.key` from a plugin child fails. The last assertion needs a small diagnostic plugin or a server self-check endpoint that forks a child and reports what it could open; building that probe is part of S2.

## Verify on hkg before implementation (read-only)

Run these on the production host to confirm the facts the design rests on, changing nothing:

- `docker exec lattice-server id` and `docker exec lattice-server sh -c 'grep Cap /proc/self/status'`: confirm the server runs as uid `lattice` with group 65532 and read its current `CapEff`, `CapBnd` and `CapAmb` (the design expects an empty effective set today and `SETUID`/`SETGID` present in the bounding set).
- `docker inspect lattice-server --format '{{.HostConfig.CapAdd}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}'`: confirm no caps dropped, no `no-new-privileges`.
- `docker exec lattice-server sh -c 'ls -ln /run/lattice-probe /var/lib/lattice'`: confirm the socket is `0660 65532:65532` and the state files are `0600 lattice`.
- `docker inspect lattice-server --format '{{json .Mounts}}'`: confirm no docker socket is mounted.
- `docker exec lattice-server sh -c 'grep Seccomp /proc/self/status'` and the daemon's seccomp mode: confirm the default profile is in force (relevant to option b, not to the chosen a).
- For option b's feasibility only, if it is ever revisited: `uname -r` and `cat /proc/sys/kernel/unprivileged_userns_clone` on the host to see whether unprivileged user namespaces are available in the production kernel, and `apk info -e util-linux setpriv` inside a candidate image build to confirm `setpriv` is available for the entrypoint change.

## Slices

- **S1. The uid boundary.** Runner credential option, the per-generation chown, the image account and entrypoint change, and the runner tests above. Server release with the option off by default. This is the whole of KI-22's fix bar turning it on.
- **S2. Turn it on and prove it.** Compose switch setting `LATTICE_PLUGIN_UID`, the precheck step and the diagnostic child that proves a plugin cannot reach the socket or the key on the live candidate. This is the slice that closes KI-22.
- **S3 (optional). Narrow the residuals.** The probe-channel token (option c) as a probe release; and, if the shared network namespace is judged worth closing, either a separate network namespace for plugin children (cost: `CAP_NET_ADMIN` or a userns, the same seccomp consideration as option b) or binding the server's API to a socket the plugin uid cannot reach. Scoped but not scheduled.

## Risks

- **Ambient capabilities are subtle.** If the entrypoint change does not set the ambient set correctly, either the server keeps `SETUID`/`SETGID` effective for its whole life (wider than intended) or the child drop fails and no plugin starts (fail-closed, caught in precheck). The precheck boot with the real plugin set is the gate; S1 ships with the option off precisely so this is proven before it matters.
- **Chown races.** The runner must chown the staged artifact after writing it and before exec, and must not chown the shared runtime root, only the per-plugin generation directory. The existing `0700`-then-stage sequence already isolates per-plugin directories, so the chown is confined to one generation path.
- **It is not total isolation.** The shared network and PID namespaces remain, named above and scoped to S3. Calling KI-22 closed after S2 means the credential store, the probe socket and the audit WAL are out of a plugin's reach; it does not mean a plugin is fully sandboxed. The status line and `PROGRAM.md` should say exactly that.
- **A future `no-new-privileges` or `cap_drop: [ALL]` hardening pass must account for this.** Both are desirable in their own right, and both will break the plugin drop unless `SETUID` and `SETGID` are kept and ambient capabilities are left usable. The compose comment and this design record the dependency so the two changes are not made in ignorance of each other.

## Decisions for the operator

Only one choice here is the operator's rather than the agent's: whether to accept the server process holding `CAP_SETUID` and `CAP_SETGID` for the purpose of downgrading its children, which is the price of a host-enforced boundary short of a user namespace. Everything else (the uid number, the chown, the entrypoint mechanism, the test and precheck shape) an agent may decide and build. Switching the live image or plugin set to the version that turns this on is a production switch and rides the standard precheck, backup, health and rollback gates already granted for the open backlog.
