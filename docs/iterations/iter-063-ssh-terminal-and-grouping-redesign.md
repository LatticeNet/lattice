# iter-063 — SSH Terminal & Grouping Redesign

**Date:** 2026-06-19
**Scope:** `lattice-server`, `lattice-node-agent`, `lattice-dashboard`, ops (nginx/Cloudflare)
**Status:** Design / blueprint (pre-implementation)
**Reference systems studied:** nezha (`nezha/`), with comparative notes vs NodeGet / NodeLite.

This iteration redesigns two features the operator flagged as weak:

1. **SSH terminal** — unstable, laggy, "far from a real terminal."
2. **Grouping** — "more like a tag"; the `/network/policy` page presents poorly.

The design is grounded in a full read of both Lattice and nezha source (file:line evidence below), and was adversarially reviewed for feasibility, security regression, and over-engineering. Where this document diverges from the first-pass design, the reason is called out under **Reconciliation**.

---

## Part 0 — Root-cause summary (why the current code feels bad)

### 0.1 Terminal: a double HTTP-polling store-and-forward relay

There is **no streaming channel anywhere in Lattice**. The agent is a pure outbound HTTP-poll client (`net/http` only; no gorilla/grpc in either `go.mod`). The terminal is a *triple-hop polling relay* through an in-memory ring buffer:

```
browser ──poll GET /events?cursor──▶ server terminalBroker (in-mem ring) ◀──poll GET /inputs?cursor── agent ──▶ real PTY (creack/pty)
browser ──POST /input──────────────▶          (220ms)          (250ms input / 750ms discovery)        ptmx
```

- Browser polls `GET /api/terminal/sessions/{id}/events?cursor=N` every **220 ms** (`XtermSession.vue:10`).
- Agent polls `GET /api/agent/terminal/sessions/{id}/inputs?cursor=N` every **250 ms** and discovery every **750 ms** (`lattice-node-agent/cmd/lattice-agent/terminal.go:22-23`).
- Output is `POST .../events` fire-and-forget, one POST per 4 KiB read.

Two structural defects result (both in `server_terminal.go`):

- **Latency:** every keystroke crosses two independent poll intervals. Realistic interactive round-trip ≈ **0.8–1.3 s on top of network RTT** — the polling relay, not the PTY, is the dominant latency source.
- **Silent output loss:** server `events` is a bounded ring (600 events / 512 KiB, `terminalMaxEventCount`/`terminalMaxSessionBytes`). If the PTY outruns the browser's poll between two fetches (`cat largefile`, `yes`, a verbose build), `trimTerminalEvents` evicts the oldest events **before the browser ever requested them**. There is no gap detection, no backpressure, no replay — the cursor jumps forward and the terminal shows a hole. This is the class of bug behind the historic "魔鬼输入" runaway.

**Good news the investigation surfaced:** the agent **already runs a genuine interactive PTY** via `github.com/creack/pty v1.1.24` (`terminal.go:95,101` — `pty.StartWithSize` on a persistent `/bin/sh`, live `pty.Setsize` resize, `cmd.Wait` lifecycle). The PTY layer is correct and reusable. **The problem is purely the transport** between browser↔server↔agent.

### 0.2 Grouping: not a tag — *weaker* than a tag

- **Server:** there is **no `Group` entity** — no struct, no ID, no table, no endpoint. `Node.Tags []string` and `Node.Role string` (`lattice-sdk/model/model.go:62-63`) are **write-once-at-enroll, echoed-in-view, never read by any selection / policy / RBAC / aggregation logic.** The only two sites that touch them are the enroll write (`server.go:1575-1626`) and the view echo (`server.go:1544-1552`). A tag at least filters; these do nothing.
- **NetPolicy** is a real per-node L3/L4 nftables compiler, but the unit is always **one `TargetNodeID`**, and rule remotes are `node | cidr | domain | any` — there is **no group ref kind**. "Allow from these 10 nodes" = 10 hand-authored rows. RBAC confines by exact node ID or `*` only (`rbac/rbac.go:19-24`) — no group scope.
- **Dashboard:** grouping is ephemeral, client-side, view-only bucketing (`lib/fleet.ts groupNodes`, by region/country/role/status/tag) — reimplemented **three divergent ways** (`fleet.ts`, `MapView.vue regions`, `PolicyView.vue layout`). No "Groups" nav entry, no persistence, no CRUD. Tags are set once at enroll via free-text and **cannot be edited afterward** (no API, no UI). The default `region` grouping silently dumps everything into "Unknown 🌐" until geo is resolved on a *different* page.
- **`/network/policy` (PolicyView.vue, 1205 lines):** a flat 7-column per-node `DataTable` that promotes debug fields (plan SHA, last-applied, last-error) to primary columns, plus a decorative continent-clustered SVG that is **not navigational** (8-char node-name truncation, 9px edge labels, fixed 860×660 viewBox that overlaps past ~12 nodes). The two tabs share no state. Empty states have no CTA. Rule order is semantically significant but there's no reorder. This is why it reads as "garbage": it answers "where are my nodes geographically," not the operator's actual question — **"who can reach whom."**

nezha is the proven counter-model on both axes (details in Parts A/B).

---

## Part A — SSH Terminal Redesign

### A.1 Target architecture — **Option A: agent-dialed per-session WebSocket**

```
┌─────────┐  WebSocket (binary)   ┌───────────────┐  WebSocket (binary)  ┌──────────────┐  io.Copy  ┌─────┐
│ browser │◄─────────────────────►│ lattice-server │◄────────────────────►│ lattice-agent│◄─────────►│ PTY │
│ xterm.js│  /api/terminal/.../    │  terminalHub   │ /api/agent/terminal/ │ terminalRunner│  ptmx R/W │ sh  │
└─────────┘  attach (cookie+RBAC) └───────────────┘  stream (node token, └──────────────┘           └─────┘
                                    pure io.Copy bridge   agent DIALS OUT)    creack/pty
```

**The load-bearing decision (driven by L1):** Lattice's agent is outbound-only and holds no persistent server connection. We therefore do **not** clone nezha's server-push gRPC bridge. Instead:

- **Browser ↔ server: WebSocket.** xterm.js attaches over `wss://…/api/terminal/sessions/{id}/attach`. Cookie/session auth + the existing RBAC gate run at upgrade time.
- **Server ↔ agent: agent-dialed WebSocket, one per session.** When the agent's *existing* 750 ms discovery poll sees a pending session, instead of starting HTTP relay loops it **dials `wss://server/api/agent/terminal/stream?node_id=&session_id=`** with `Authorization: Bearer <nodeToken>`. The server upgrades and bridges it to the waiting browser socket.
- **Server is a near-dumb byte pump:** two `io.Copy` goroutines splice the two WebSocket connections (both wrapped as `io.ReadWriteCloser`). No parsing, near-zero CPU, automatic TCP/PTY backpressure.

This preserves the critical security property **"agents never accept inbound connections"** (they sit behind NAT/firewalls), reuses node-token bearer auth verbatim, and is shippable in dual-mode without a lockstep deploy.

| Option considered | Verdict |
|---|---|
| **A. Agent dials outbound WS per session** (triggered by existing discovery poll) | ✅ **Recommended.** Terminal-local, respects outbound-only posture, reuses all auth, ships in days. ≤750 ms to *open* a session is irrelevant; keystrokes are real-time once live. |
| B. Persistent agent control-stream (nezha-style), server pushes sessions down it | ⚠️ Correct 12-month end-state, but a control-plane project (agent lifecycle, reconnection, auth-over-socket for *all* features). Over-scoped for this fix. Adopt later if live-tasks/push-config also need it. |
| C. Keep polling, tighten intervals | ❌ Still polling, still laggy, still loses output. Rejected. |

### A.2 Wire protocol — **in-band opcode** (server relays transparently)

> **Corrected after Phase-1 implementation review.** The server `bridge` is a *transparent* `io.Copy` pair, and `websocketx.Conn.Read` returns only the frame **payload** — the WS text/binary opcode is **not** preserved across the relay (`Write` always emits a binary frame). Therefore control signals (resize) must travel **in-band**, not as a distinct WS frame type. This is nezha's model and is required for the dumb-relay design to work. An earlier draft used a "text frame = resize" scheme; that cannot survive a transparent relay and is superseded by the contract below.

- **browser → agent** (binary WS frames): `[1-byte opcode][payload]`.
  - `0x00` = stdin keystrokes — payload written verbatim to the PTY (`ptmx.Write`).
  - `0x01` = resize — payload is JSON `{"cols":N,"rows":M}` → `pty.Setsize`.
  - The agent switches on `data[0]`.
- **agent → browser** (binary WS frames): **raw PTY output bytes, no opcode prefix** — the browser writes them straight to xterm (`terminal.write`).
- **server**: `io.Copy` both directions, never inspects or reframes — the opcode rides inside the copied bytes. This is why `websocketx.Conn` is a plain transparent byte pipe (payload-only reads, binary-only writes).

Asymmetric on purpose: only the browser→agent leg multiplexes stdin + resize, so only it carries the opcode; output is a pure byte stream. Keepalive pings use WS control frames via `WriteControl` (gorilla-concurrency-safe), orthogonal to this in-band data framing.

This mirrors nezha's blueprint: browser uses `@xterm/xterm` + `@xterm/addon-fit`; output is `terminal.write(Uint8Array)`; input is sent raw on `terminal.onData`; resize is a debounced control frame. nezha's `io.Copy`-pair bridge (`service/rpc/io_stream.go:387-400`) and process-group-kill cleanup (`agent/pkg/pty/pty.go:79-93`) are the patterns we port.

### A.3 Server changes (`lattice-server`)

1. **New dep:** `github.com/gorilla/websocket` (works with the existing stdlib `http.ServeMux` via `Upgrader.Upgrade(w, r, nil)`).
2. **NEW `internal/websocketx/safe_conn.go`** — port nezha's `pkg/websocketx/safe_conn.go`: an `io.ReadWriteCloser` over the WS with a **write mutex** (gorilla forbids concurrent writers — this is the single most important correctness detail) and zero-length keepalive-frame skipping.
3. **NEW `internal/server/server_terminal_stream.go`** — `terminalHub`:
   - `pending map[string]*pendingBridge` keyed by session ID.
   - Browser attaches first → creates `pendingBridge`, waits on `agentCh` (30 s timeout). Agent dials in → `bridgeAgent` finds the waiter and runs the `io.Copy` pair. If the agent never shows (offline) → timeout → close browser WS with code `1013 try-again` → UI shows "node offline."
   - `bridge(b, a)` is ~15 lines: two `io.Copy` goroutines, buffered `errc` (cap 2 so neither goroutine leaks), `defer Close()` both. First side to EOF/error tears down both.
4. **MODIFY `server_terminal.go`** — add `case "attach"` to `handleTerminalSessionPath` *after* the existing RBAC gate (`:439`); add `handleAgentTerminalStream` (node-token auth identical to `handleAgentTerminalSessions` at `:520-524`, then `sess.NodeID != nodeID` ownership check, then upgrade + `hub.bridgeAgent`). Add `markOpen`/`markClosed` helpers replacing the `agentUpdate(status=…)` path.
5. **MODIFY `server.go`** — register `/api/agent/terminal/stream` (in the `withAgentLimit` group near `:659`); construct `terminalHub` next to `newTerminalBroker()`.
6. **`terminalBroker` is repurposed, not deleted.** It keeps owning session **metadata, lifecycle, RBAC subject, audit identity, per-node caps, TTL pruning**. It loses only the **byte-buffering** role (`events`/`inputs` slices, `eventsAfter`/`inputsAfter`/`addInput` data path, `trimTerminalEvents`) — bytes now flow through live sockets. Delete those in Phase 4.

### A.4 Security — explicit preservation map (critique HIGH item)

A stream that bypassed `terminalBroker.addInput`/`agentUpdate` would silently drop byte caps, accounting, and the close-audit. Every control re-attaches as follows:

| Control | Today | After |
|---|---|---|
| RBAC per-node | `requireNodeScope(p,"terminal:open",NodeID)` + `rbac.Allows` list filter (`server_terminal.go:374,380,400,439`) | Same gate, run once at the browser WS **upgrade**. No new auth surface. |
| Session-hijack (nezha GHSA class) | session bound to ActorID/TokenID | Browser attach requires RBAC on the node; agent bridge requires `sess.NodeID == nodeID`. A leaked session UUID alone is useless. |
| Node-token auth | `authenticateNode` on agent routes | Same function gates the agent WS upgrade (token in `Authorization` header, **not** query — avoids access-log leakage). |
| Per-node session cap (4) | `terminalMaxActiveSessionsPerNode` in `create` | Unchanged — session still created via existing `POST /api/terminal/sessions`. |
| Input size cap (16 KiB) | per-POST check | `conn.SetReadLimit(terminalMaxInputBytes)` on the agent-bound copy; oversized frame → close. |
| Output flood | ring trim (the lossy bug) | becomes a **byte/sec guard**: counter on the relay; sustained flood beyond a ceiling → close `1009`. Natural backpressure otherwise (slow browser → `io.Copy` blocks → agent read blocks → `ptmx.Read` blocks → kernel PTY buffer → shell `write()` blocks = correct Unix flow control). |
| Audit | `terminal.open` / `terminal.close` / `terminal.agent.close` | **Keep all**, add `terminal.attach`. Identity from `principal`/node-token exactly as before. |
| Rate limit | `apiLimiter` 30/s browser, `agentLimiter` 10/s agent (`withAgentLimit`) | Unchanged on the REST create/close + the agent stream upgrade. The hot path (bytes) no longer consumes request budget at all — a strict improvement. |

### A.5 Agent changes (`lattice-node-agent`)

1. **New dep:** `github.com/gorilla/websocket`. Keep `creack/pty`.
2. **NEW `cmd/lattice-agent/websocketx.go`** — same `io.ReadWriteCloser` + write-mutex adapter.
3. **MODIFY `cmd/lattice-agent/terminal.go`** — rewrite only the transport in `terminalRunner.run`:
   - **Keep:** `terminalManager`, discovery `poll` (`:49-72`), shell normalization, `pty.StartWithSize`, `pty.Setsize`, the `active` dedup map.
   - **Replace:** the output-POST goroutine (`:111-130`), the 250 ms input poll (`:135,162-193`), `postEvents`/`pollInputs` — with one WS dial + two copy loops:
     - `io.Copy(conn, ptmx)` — PTY → WS (output), 32 KiB chunks (up from 4 KiB; fewer syscalls).
     - `pumpInput(conn, ptmx)` — WS → PTY; reads each frame's payload and switches on the in-band opcode `data[0]`: `0x00` → `ptmx.Write(data[1:])`, `0x01` → JSON-decode `data[1:]` → `pty.Setsize`. PTY output is written back via `conn.Write(ptyBytes)` (raw, no opcode).
   - No more cursor/Seq replay machinery (the stream is ordered and lossless → removes the entire repeated-keystroke bug class).
4. **Process-group kill on close (reliability upgrade).** Adopt nezha's `pty.Close` (`pty.go:79-93`): `Setpgid` at start; on teardown `syscall.Kill(-pgid, SIGKILL)` **guarded against pgid ≤ 0** (never signal the agent's own group — the `Kill(-0)` footgun); port nezha's `pty_kill_test.go`. Today's ctx-kill can orphan grandchildren (`vim`, `top`).
5. **Discovery stays HTTP** (Option A) — only what the per-session goroutine *does* changes. 750 ms discovery cost is unchanged and off the hot path.
6. **Half-open detection:** server sends `PingMessage` every 10 s (keeps the conn hot through CF's ~100 s idle timeout); agent `SetPongHandler`; missed pong → `io.Copy` errors → clean teardown + `markClosed` audit.
7. **Guardrails kept:** `AllowTerminal` flag + root-refusal (`main.go:93-95`). Document that the PTY runs as the agent user — *not* a sandbox (same residual-risk posture as `taskexec`).

### A.6 Dashboard changes (`lattice-dashboard`)

Rewrite `src/components/terminal/XtermSession.vue` transport; **keep** the xterm config block, dark theme, copy/paste handler (Cmd/Ctrl+Shift+C/V with Ctrl+C reserved for SIGINT), FitAddon/ResizeObserver — all good.

- Delete the poll machinery (`POLL_MS` constants, the single-flight poll loop, `pollGen`, `cursor`, input-flush batching).
- Hand-wire the socket (do **not** use `@xterm/addon-attach` — it gives no resize/reconnect control):
  - `ws.binaryType = "arraybuffer"`; `ws.onmessage` → `terminal.write(new Uint8Array(ev.data))` for binary; ignore text echoes.
  - `terminal.onData(d => ws.send(d))` — input sent the instant xterm emits it (no 35 ms buffer = the native-feel win).
  - `sendResize()` → binary frame `[0x01] + JSON({cols,rows})` (debounced via existing `RESIZE_DEBOUNCE_MS`); keystrokes from `terminal.onData(d)` → binary frame `[0x00] + d`. Output frames arrive raw → `terminal.write(new Uint8Array(ev.data))`.
  - Reconnect with exponential backoff 500 ms→8 s on unclean close.
  - **Do not** pause the socket on hidden tabs (a backgrounded terminal should keep receiving output — native behavior); keep visibility only to refocus.
- **API client** (`src/lib/api/index.ts`): add `terminal.streamURL(id)` (builds `wss://` from current origin so the session cookie rides the handshake); **remove** `terminal.events`/`input`/`resize`. Keep `create`/`close` (REST).
- **Multi-tab** (`TerminalView.vue`): each tab = one session = one socket; derive open/closed from WS `onclose`; keep inactive tabs mounted+hidden so sockets stay live. Per-node cap (4) already bounds this. Optionally raise xterm `scrollback` to 10000 (no more ring replay).

### A.7 Ops — Cloudflare + nginx (critique CRITICAL; production is client→CF→HK origin)

No proxy config exists in-repo today; ship it as part of this work.

```nginx
location /api/terminal/ {            # browser attach
    proxy_pass http://lattice_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 300s; proxy_send_timeout 300s;
    proxy_buffering off;
}
location = /api/agent/terminal/stream { ... same ... }   # agent dial-in
```

- CF: confirm host is proxied (orange cloud); CF supports WebSocket automatically — verify **no "Cache Everything" page rule** hits these paths. The existing ops note already mandates 300 s timeouts + Upgrade headers for terminal WS proxying.
- Set `Upgrader.CheckOrigin` to same-origin (check the CF-forwarded host since CF terminates TLS).
- **Phase-0 gate:** `wscat -c wss://lattice.roobli.org/...` must round-trip through CF+nginx before any client code shifts.

### A.8 Migration — phased, dual-mode, production-safe

The terminal *works today* (polling), so every phase keeps it working until WS is proven.

- **Phase 0 — Infra prep (no code).** Verify CF+nginx WS end-to-end with a throwaway echo endpoint.
- **Phase 1 — Server hub, dark-launched.** Add gorilla, `websocketx`, `terminalHub`, `handleAgentTerminalStream`, the `attach` case. Old poll routes stay live → zero production risk. Verify: `go test -race` with two `net.Pipe` conns through `bridge`.
- **Phase 2 — Agent dual-mode behind a flag.** WS dial in `terminalRunner.run`, gated by an agent config field `TerminalTransport` (`"poll"` default | `"stream"`) delivered via the existing `fetchAgentConfig` push. Flip one canary node; attach with `wscat`; confirm bidirectional bytes + process-group kill via `ps`.
- **Phase 3 — Dashboard WS with poll fallback.** Ship WS `XtermSession.vue` with feature-detect: try WS, and if upgrade fails within 3 s fall back to the poll component for that session. Roll out behind a localStorage flag, then default-on. Verify: real browser through CF + Playwright/gstack — type `ls`, resize, `cat largefile`, Ctrl+C, reconnect after `nginx -s reload`.
- **Phase 4 — Cleanup.** Once stream is default for ≥1 release with no incidents: delete poll routes, broker byte-buffers, old Vue poll code, the `poll` branch. Tag a revert point.

**Backward compat:** old agent (poll) + new server works; new agent + old dashboard works (still polls until told otherwise). Agents update independently — no lockstep deploy.

### A.9 Risks

| Risk | Mitigation |
|---|---|
| CF/nginx WS proxying | Phase-0 gate; 300 s timeouts; 10 s server ping keeps conn hot through CF idle. |
| Reconnection | Browser backoff 500 ms→8 s. A reconnect re-attaches afresh; agent-flushed scrollback is gone (matches ssh). Optional later: server keeps a small last-N-KiB replay cache per session. |
| Half-open | Ping/pong both legs + read deadlines → `io.Copy` errors → teardown + audit. |
| Agent offline | Browser waits on `agentCh` 30 s → close `1013` → "node offline." Session pruned by existing `terminalPendingTTL`. |
| Output flood | Natural backpressure chain + byte/sec guard → `1009`. |
| gorilla concurrent-write panic | `websocketx.Conn` write mutex serializes data + ping writers. **Must port verbatim.** |
| Goroutine/conn leaks | buffered `errc` (cap 2), `defer Close()` both; hub reaper tied to `pruneLocked`. |

---

## Part B — Grouping Redesign

### B.1 The model nezha proves (and where we beat it)

nezha treats a group as a **first-class entity** with a **dedicated M2M junction table** — `ServerGroup{ID,Name,owner,timestamps}` (`model/server_group.go`) + `ServerGroupServer{ServerGroupId,ServerId}` with a unique composite index (`model/server_group_server.go`). The `Server` struct has **no** group/tag field — membership lives only in the junction. The read API returns each group **with its resolved member IDs inline** (`ServerGroupResponseItem`), which is exactly what lets the dashboard render group tabs/sections with per-group counts in one fetch. `listServerGroup` bakes in visibility scoping: strip non-visible nodes, **drop groups that become empty for a viewer** (so you don't leak the existence of hidden groups), PAT-whitelist redaction.

nezha's gaps we can beat: **no group ordering** (`DisplayIndex` missing on `ServerGroup`), **no per-group aggregates from the API**, **no group-level alert rules**.

### B.2 Data model — Group as first-class (with the critique's simplifications)

Add to `lattice-sdk/model/model.go`:

```go
type Group struct {
    ID          string    `json:"id"`           // "grp_<ulid>"
    Name        string    `json:"name"`         // unique, display
    Slug        string    `json:"slug"`         // url/nft-safe, unique, immutable
    Description string    `json:"description,omitempty"`
    Color       string    `json:"color"`        // token name ("sky","violet"…), never raw hex (CSP)
    Icon        string    `json:"icon,omitempty"`
    ParentID    string    `json:"parent_id,omitempty"` // single parent; "" = root
    Order       int       `json:"order"`        // sort weight (the primitive nezha lacks)
    Members     []string  `json:"members"`      // explicit node IDs — the CANONICAL membership
    Selector    *GroupSelector `json:"selector,omitempty"` // DISPLAY-ONLY smart filter (see Reconciliation)
    System      bool      `json:"system,omitempty"`   // built-in "Ungrouped"; limited edits
    CreatedAt   time.Time `json:"created_at"`
    UpdatedAt   time.Time `json:"updated_at"`
}

// GroupSelector = read-only "smart group" for dashboard filtering. NOT a policy input.
type GroupSelector struct {
    MatchTagsAny   []string `json:"match_tags_any,omitempty"`
    MatchRoles     []string `json:"match_roles,omitempty"`
    MatchCountry   []string `json:"match_country,omitempty"`
    MatchContinent []string `json:"match_continent,omitempty"`
}
```

`Node` gains one server-computed, read-only convenience field; `Tags`/`Role` stay as facts:

```go
GroupIDs []string `json:"group_ids,omitempty"` // resolved memberships, server-computed, never client-authored
```

**Membership for policy is EXPLICIT (`Members`).** This is the single source of truth. Selectors exist only to *suggest/filter* on the dashboard and to seed groups during migration — they never silently change a firewall (see Reconciliation R2).

### B.3 Group-scoped policy that compiles to the **unchanged** per-node engine

The hard constraint: `CompileEgressPlan`/`CompileIngressInputRules` resolve every ref to concrete node IPs and emit one nft batch per target node. Groups must be a **server-side authoring/expansion layer** — the compiler signature does not change.

```go
type GroupNetPolicy struct {
    ID           string         `json:"id"`             // "gnp_<ulid>"
    ScopeGroupID string         `json:"scope_group_id"` // applies to members of this group
    Rules        []GroupNetRule `json:"rules"`          // remote.kind may be "group" | node | cidr | domain | any
    Enabled      bool           `json:"enabled"`
    Priority     int            `json:"priority"`       // lower wins when a node is in 2+ groups
    CreatedAt, UpdatedAt time.Time
}
const NetRefGroup = "group" // new NetEndpoint kind; NetEndpoint gains GroupID string
```

`internal/netpolicy/expand.go` (NEW): `ExpandGroupPolicy` turns a group-scoped policy into **one `model.NetPolicy` per member node**, fanning out a `NetRefGroup` remote to one node-ref rule per remote member. The existing compiler never sees a group ref. A node's effective policy = union of applicable group policies, deterministically ordered by `(Priority, policyID, ruleIndex)`.

**Plan-staleness fix (critique CRITICAL #2).** `sameNetPolicyIntent` (`server_netpolicy.go:253`) diffs only `Enabled`+`Rules` via `reflect.DeepEqual`; `LastPlanSHA` is computed at `:138`. A group rule whose member IPs change would otherwise leave an approved plan **silently stale**. Fix:
- Expansion resolves groups to concrete endpoints **before** hashing.
- The **resolved member set (or its hash) is folded into `LastPlanSHA`**.
- Membership change → affected per-node policies marked **dirty** (`LastError = "group membership changed; re-plan required"`) and require explicit re-plan/approval. Membership re-eval **never** auto-applies nft.
- Add the compiler-vs-graph parity test that `iter-023` flagged as pending.

### B.4 Server changes (`lattice-server`)

- **Store** (`internal/store/store.go`): add `Groups map[string]model.Group` and `GroupPolicies map[string]model.GroupNetPolicy`, mirroring the `NetPolicies` pattern + `cloneNode`-style deep-copy. CRUD: `UpsertGroup`/`Group`/`Groups`/`DeleteGroup` (reject delete if it has children or is referenced by a policy; offer explicit reparent-to-root), `UpsertGroupPolicy`/…/`DeleteGroupPolicy`.
- **`internal/groups/resolve.go`** (NEW, pure/table-driven testable): `ResolveMembers(g, allNodes)` = `explicit Members ∪ selector matches`, `ResolveAll(groups, nodes) map[groupID][]nodeID`, `GroupIDsForNode`. Cycle-guard `ParentID`, cap nesting depth (~5).
- **Endpoints** (register near `server.go:643`):
  - `GET/POST /api/groups` (`group:read`/`group:admin`), `POST /api/groups/delete`, `POST /api/groups/reorder`, `POST /api/groups/members` (explicit add/remove), `POST /api/groups/preview` (selector dry-run → resolved node list), `GET /api/groups?include=rollup` (per-group `{total,online,disabled,cpu_avg,mem,net}` — beats nezha, which makes the client compute this).
  - `GET/POST /api/group-policies` (`netpolicy:read`/`admin`), `POST /api/group-policies/plan` (expands → per-node compile → **one Approval per node** via the existing `nftpolicy` path; returns `{affected:N, plans:[{node_id,approval_id,plan_sha}]}`), `POST /api/group-policies/delete`.
  - `GET /api/netpolicy/matrix?direction=egress|ingress` — group×group adjacency (collapses resolved node edges to their groups), powering the new PolicyView.
- **Visibility scoping** (port nezha's `listServerGroup`): strip non-visible nodes per viewer, **drop groups that become empty** (don't leak hidden-group names), respect owner/admin/PAT scope. Reuse nezha's test matrix as a spec.
- **RBAC:** add `group:read`/`group:admin` scopes (resource = group ID for per-group delegation). Keep orthogonal from `netpolicy:admin`: "team leads organize, network admins authorize."
- **Migration** (idempotent, `state.SchemaVersion` bump): create one **selector-backed display group** per distinct `Role` and per popular `Tag`; create a `System` "Ungrouped" group (resolves to nodes matched by nothing). **Leave `Tags`/`Role` intact.** Zero firewall change until an operator authors a `GroupNetPolicy`.

### B.5 Agent changes — **none**

The agent never learns about groups. Group expansion happens entirely server-side *before* compilation; the agent receives the same per-node nft batch (via the existing rollback-protected Approval/`-update-nft-domain-set` path) it gets today. **No agent code change, no version gate, no data-plane rollout risk.** (The model already documents the invariant: "the agent does not receive [NetPolicy] directly.")

### B.6 Dashboard — the heart of the ask

**Primitives available** (`L6`): `Card`, `Badge` (7 variants), `DataTable`, `Select` **+ unused `SelectGroup`/`SelectLabel`**, `Tabs`, `Dialog/DialogScrollContent`, `Checkbox`, `EmptyState`, `StatusDot`, `NodeCard`, `ConfirmDialog`, `PlanReviewDialog`, plus the clean reusable `fleet.ts groupNodes` engine and class-based color tokens (`REGION_COLORS`). **Missing** and therefore explicitly net-new work (critique HIGH #5): a **multi-select node picker** and a **draggable group tree**. These are scoped as build items, not hand-waved.

**B.6a — Groups as primary navigation.**
- New nav item (Fleet section): `{ name:"groups", title:"Groups", path:"/groups", icon:FolderTree, scopes:["group:read"] }`.
- `lib/fleet.ts`: add a first-class `groupBy:"group"` mode returning the existing `NodeGroup[]` shape (so `NodesView.vue`'s collapsible sections work unchanged). Make `"group"` the **default** grouping; region/role/tag become ad-hoc lenses. **Collapse the 3 divergent grouping impls** (MapView, PolicyView, fleet.ts) onto this one engine (critique HIGH #8 — the IA problem is cross-view consistency).
- `NodesView` group headers gain the group color dot + icon + `online/total` rollup badge (from `?include=rollup`). Add a post-enroll **tag/role editor** + **"Add to group"** action (today membership is write-once — a real gap).

**B.6b — Rebuild `/network/policy` as a reachability matrix.** Diff against the existing 1205-line `PolicyView.vue` (critique HIGH #4 — it is *not* greenfield): demote the per-node table and SVG to secondary tabs; add a **Matrix** default tab.

```
PolicyView.vue
└─ PageHeader (title, FreshnessLabel, [Refresh] [+ New group policy])
└─ Tabs: [ Matrix • Policies • Topology ]
   └─ Matrix (default)
      └─ Card "Reachability matrix"  — rows = source groups, cols = dest groups
         ┌──────────────────────────────────────────────┐
         │          ┃ edge   db    web   mon   (DEST)     │
         │ (SOURCE) ┃ ●AS3  ●EU2  ●NA5  ●all              │
         │ ─────────╂──────┬─────┬─────┬─────             │
         │  edge    ┃  —   │✓:443│ ✗   │✓:any             │
         │  db      ┃ ✗    │●self│✓ tcp│ —                │
         │  web     ┃✓:5432│✓:6379│ —  │✓ icmp            │
         │  mon     ┃✓:9100│✓:9100│✓..│●self              │
         └──────────────────────────────────────────────┘
         glyphs: ✓ allow · ✗ deny · ◐ mixed · — none · ●self
         color : success / destructive / amber(mixed) / muted
```
- Click a cell → `PolicyCellEditor` (DialogScrollContent) pre-scoped to `source→dest`, reusing the existing `RuleDraft` editor logic with `remote.kind="group"` pre-filled. Save → `POST /api/group-policies`; `[Plan]` → `/api/group-policies/plan` → **"this affects N nodes"** summary → existing `PlanReviewDialog`.
- **Empty states with CTA:** zero groups → "Group your fleet first" (→ `/groups`); groups but no policy → "every cell defaults to your fleet baseline" + `[+ New group policy]`. Never a blank grid.
- Nested groups → indented headers with disclosure caret; collapsing a parent aggregates child cells (◐ if children differ).
- Scale: a 50-group fleet = 2500 cells → virtualize, collapse-by-parent by default, matrix API returns aggregates only.
- New components: `components/networking/{PolicyMatrix,PolicyMatrixCell,PolicyCellEditor}.vue` + shared `GroupChip.vue`.

**B.6c — Group CRUD (`src/views/fleet/GroupsView.vue`).** Two-pane: left = draggable nested `GroupTree` (drag-handle · color dot · icon · name · `online/total` badge; drag to reorder/nest → batched `POST /api/groups/reorder`; "Ungrouped" pinned, not draggable; keyboard fallback move-up/down/indent for a11y); right = selected-group detail (editable name, token color swatches, lucide icon picker, description; explicit-member `NodePicker` with search + bulk multi-select; if a display selector is set, a **live preview** "matches 7 nodes" via `/api/groups/preview`; resolved-member table; `[Delete]` blocked-with-reason if it has children or is policy-referenced).

**API client additions** (`lib/api/index.ts` + `types.ts`): `groups.{list,upsert,delete,reorder,members,preview}` and `groupPolicy.{list,upsert,plan,delete,matrix}`; TS mirrors `Group`, `GroupSelector`, `GroupNetPolicyView`, `NetPolicyMatrix`; `NetEndpointKind` gains `"group"`.

### B.7 Migration — phased, shippable, agent untouched

- **Phase 0 — Model + store + resolve.** Structs, `NetRefGroup`, store maps + CRUD, `internal/groups/resolve.go` + table tests, schema bump + idempotent backfill (roles/tags → display groups, system "Ungrouped"). `Node.GroupIDs` read-only. Firewall untouched. Verify: `go test -race`, boot against a copy of prod bolt state, reconcile node counts.
- **Phase 1 — Group CRUD + nav.** `/api/groups*`, RBAC scopes, `GroupsView.vue`, nav item, `fleet.ts groupBy:"group"` default + rollups in `NodesView`. Net-new `NodePicker` + `GroupTree` land here.
- **Phase 2 — Group-scoped policy (additive).** `GroupNetPolicy` store, `expand.go`, `/api/group-policies*` + `/api/netpolicy/matrix`. Golden test: `ExpandGroupPolicy` + `CompileEgressPlan` is byte-identical to hand-authored per-node policy for the same intent; plan SHAs deterministic and member-set-sensitive.
- **Phase 3 — PolicyView rebuild.** Matrix default; Policies/Topology demoted. Verify on empty / single / nested / dense (16+ node, 5+ group) fleets; cell→editor→plan→approval round-trip.
- **Phase 4 — Cleanup.** Optional one-click "convert tag-derived display group → managed static group." Keep `Tags`/`Role` as facts indefinitely.

Each phase is independently shippable; **no phase changes agent code** → data plane never at rollout risk.

### B.8 Risks

| Risk | Mitigation |
|---|---|
| **Plan staleness** (the security hole) | Resolve groups→IPs before hashing; fold member set into `LastPlanSHA`; membership change marks dirty + requires explicit re-plan (never auto-apply). |
| Multi-group conflicts (allow vs deny) | Deterministic precedence `(Priority, policyID, ruleIndex)`; surface ◐ mixed in the matrix and show the effective rule + origin in the per-node expanded view. Never silently pick. |
| Dual source of truth (Tags vs Group) | **`Members` is canonical for policy; selectors are display-only.** Tags remain facts/selector inputs. No reconciliation race. |
| Group expands to zero nodes | Warn in the matrix; skip emitting — never widen to "any." |
| Slug/nft-set naming | `Slug` immutable+unique+nft-safe; group identity never reaches an nft set name (expansion resolves to node IPs; keep the `domainSetForHost` SHA discipline). |
| Advisory facts for authz | Safe: selectors choose *display/scope* only; the compiler resolves to concrete node IPs and authorization stays per-node default-drop. A spoofed tag can mis-scope intent but cannot bypass nft. |
| Net-new UI components | `NodePicker` (multi-select) + `GroupTree` (DnD) are explicitly scoped build items, not assumed primitives. |

---

## Reconciliation (where this diverges from the first-pass design, and why)

- **R1 — SSH transport = Option A, not nezha's gRPC bridge.** nezha's bridge terminates on a persistent server→agent push stream that Lattice does not have (L1: agent is outbound-only HTTP poll). Cloning it would be a control-plane project. Option A (agent dials an outbound per-session WS) gets native streaming for the terminal alone while preserving "agents never accept inbound."
- **R2 — Grouping: explicit membership is canonical; dynamic selectors are display-only.** The adversarial review flagged (a) dual-source-of-truth risk and (b) a plan-staleness security hole if selector-driven membership silently changed firewalls, and judged rule-based membership over-engineered for a 30-node fleet. Resolution: **selectors filter the dashboard and seed migration; only explicit `Members` drives policy**, and any membership change folds into `LastPlanSHA` + forces re-plan. This keeps the enforcement engine, RBAC, and approval flow unchanged.
- **R3 — "Minimal" terminal change is honest about scope.** There is no existing socket lifecycle / reconnect / auth-over-stream to reuse, so the gorilla adapter + per-session dial + process-group kill is real (well-bounded) work — not a one-line swap. The PTY layer itself *is* reusable as-is.
- **R4 — PolicyView is a rebuild-in-place, not greenfield.** The existing 1205-line view (table + dialog + SVG) is demoted to secondary tabs under a new Matrix default — we diff against it, we don't ignore it.

---

## Prioritized roadmap (suggested order)

1. **SSH Phase 0–1** (infra gate + dark-launched server hub) — unblocks everything, zero production risk.
2. **SSH Phase 2–3** (agent dual-mode + dashboard WS w/ fallback) — delivers the native terminal the operator asked for; the single highest-impact UX win.
3. **Grouping Phase 0–1** (model/store/resolve + CRUD + nav + display grouping) — makes "group" real and fixes the cross-view inconsistency; no firewall risk.
4. **Grouping Phase 2–3** (group policy + Matrix PolicyView) — fixes the "/network/policy looks like garbage" complaint with a who-can-reach-whom matrix.
5. **Both Phase 4** (cleanup) after each has soaked ≥1 release.

SSH and grouping are independent and can proceed in parallel by different lanes; within each, phases are strictly ordered and individually reversible.

---

## Deployment & release checklist (operator-gated — NOT done autonomously)

These require production access / `git push` / a prod deploy and are intentionally left for an operator.

**SDK release (required before CI/prod server build).** Local dev already builds via `GOWORK=…/go.work.tmp` against the local SDK; CI (no go.work) needs the tag.
1. Merge `lattice-sdk` branch `feat/groups-and-stream-model` → main; tag **`v0.2.4`**; push the tag.
2. In `lattice-server/go.mod`: bump `require github.com/LatticeNet/lattice-sdk v0.2.4`; run `go mod tidy` (also reclassifies `gorilla/websocket` from `// indirect` to direct). The agent repo needs **no** SDK bump (SSH Phase 2 added no SDK types; the transport flag is an agent CLI/env flag).

**nginx (origin) — add WS upgrade** for the streaming terminal on `/api/terminal/` (browser attach) and `= /api/agent/terminal/stream` (agent dial). Exact block in §A.7: `proxy_http_version 1.1` + `Upgrade`/`Connection "upgrade"` + `proxy_read_timeout 300s` + `proxy_buffering off`. Then `nginx -t && nginx -s reload`.

**Cloudflare:** confirm the host is proxied (WS auto-supported); ensure no "Cache Everything" rule hits `/api/terminal/*`. Verify: `wscat -c wss://lattice.roobli.org/api/terminal/sessions/<id>/attach`.

**SSH canary (dual-mode, reversible):**
1. Deploy the new server image — the hub is dark-launched; old poll routes still serve (zero behavior change).
2. Flip ONE node's agent to `-terminal-transport=stream` (env `LATTICE_TERMINAL_TRANSPORT=stream`); restart it. Others stay `poll`.
3. Deploy the dashboard; enable the **Streaming** toggle and open a terminal to the canary node. Verify: type, resize, `cat largefile`, Ctrl+C, reconnect across `nginx -s reload`; confirm no orphan shells (`ps`) after close.
4. Roll `stream` to more nodes once the canary is stable ≥1 day.

**Grouping rollout (no agent/data-plane risk):** deploy server + dashboard; on the Groups page click "Generate from tags" (idempotent) to seed display groups from existing roles/tags; author group policies in the new `/network/policy` **Matrix**, then Plan → review affected/conflicts/orphaned → approve per node (existing approval flow). Group policy never overwrites a manual per-node policy (clobber-guard).

**Phase 4 (deferred — do NOT run yet):** delete poll terminal routes/broker byte-buffers + the poll Vue path only after `stream` is default for ≥1 release with no incidents — running it now would break the live poll terminal.

## Evidence index (primary source files)

**Lattice — terminal:** `lattice-node-agent/cmd/lattice-agent/terminal.go` (PTY + poll), `.../main.go:37,207-269` (outbound HTTP client, poll loop), `lattice-server/internal/server/server_terminal.go` (broker, caps, RBAC, audit), `server.go:586-587,659-660` (routes), `lattice-dashboard/src/components/terminal/XtermSession.vue`, `.../views/operations/TerminalView.vue`.
**Lattice — grouping:** `lattice-sdk/model/model.go:58-79` (Node.Tags/Role), `:331-385` (NetPolicy/NetEndpoint), `lattice-server/internal/netpolicy/{netpolicy.go,compile.go}`, `.../server/server_netpolicy.go:138,253` (LastPlanSHA, sameNetPolicyIntent), `internal/rbac/rbac.go`, `lattice-dashboard/src/lib/fleet.ts`, `.../views/networking/PolicyView.vue`, `.../views/fleet/{NodesView,MapView}.vue`.
**nezha — terminal:** `nezha/cmd/dashboard/controller/{terminal.go,ws.go,permissions.go}`, `service/rpc/{io_stream.go,nezha.go}`, `pkg/{websocketx/safe_conn.go,grpcx/io_stream_wrapper.go}`, `agent/cmd/agent/main.go:1240-1318`, `agent/pkg/pty/{pty.go,pty_kill_test.go}`, `admin-frontend/src/components/terminal.tsx`.
**nezha — grouping:** `nezha/model/{server_group.go,server_group_server.go,server_group_api.go,common.go}`, `cmd/dashboard/controller/{server_group.go,controller.go}`, `server_group_visibility_test.go`, `admin-frontend/src/{routes/server-group.tsx,components/{server-group,group-tab}.tsx}`.
