# iter-064: SSH Terminal Excellence

## Executive summary

Lattice's web terminal disappoints for one structural reason: **poll is still the production default, and the better-engineered stream path was never promoted or hardened.** Poll imposes a 250 ms input floor, ~750 ms session discovery, silent ring eviction with no gap marker, and a blocking POST-per-read that caps throughput at ~170 KiB/s on the HK link. The stream path already flows raw PTY bytes at network RTT (~24 ms) end-to-end — but it ships with latent bugs that make it unsafe as a default: no per-write deadline (a stalled Cloudflare write blocks PTY draining), a kill-on-first-WS-drop teardown that SIGKILLs the shell on a 1 s blip, no reconnect protocol, a DOM-only renderer, and `allowProposedApi:false` (wrong CJK/emoji widths). iter-064 hardens stream, makes the PTY survive WS drops with offset-based replay, upgrades the frontend to WebGL + unicode11, moves transport selection into server-pushed `AgentConfig` so we flip poll→stream per node without redeploy (canary→fleet with instant rollback), then deletes poll. Poll stays live the entire time; the live terminal is never down. Multi-viewer, ACK windowing, addon-serialize, SSH-to-arbitrary-host, and full session recording are deferred as gold-plating.

---

## 1. Why the terminal still disappoints

The audits are unambiguous, and every claim was spot-checked against the live code: the disappointment is **not** an architectural dead end. The stream transport already exists, is correctly engineered in its core (dial-before-spawn, opcode framing, process-group kill, `writeMu` serialization), and flows bytes at RTT. The problem is **governance, not capability**:

- **Poll is the frozen default.** `main.go:180-183` picks the transport at startup and `applyAgentConfig` (`main.go:413-437`) *ignores* `TerminalTransport`. There is no runtime lever, so the lossy/laggy path is what every operator actually gets.
- **Stream was dark-launched and never hardened.** It carries the bugs that would have been found in a soak: no per-write deadline (`wsConn.Write`), kill-on-first-disconnect teardown (`terminal.go:307-321`), unconditional `markClosed` after attach (`server_terminal.go:584-585`), no server-side keepalive, DOM renderer, `allowProposedApi:false` (`XtermSession.vue:75`), and a multiline-paste-to-PTY footgun.

So the fix is a disciplined promotion: **harden the stream path, give it reconnection and a renderer worthy of fleet ops, build a per-node rollout lever, then canary it to default and delete poll.** Poll is the root cause of the latency/loss complaints; stream is the foundation we keep.

---

## 2. Gap matrix

| Dimension | Lattice poll | Lattice stream (current) | nezha | kuboard | TARGET |
|---|---|---|---|---|---|
| **Interactive latency (keystroke echo)** | Structural floor: 250 ms input ticker (median +125 ms) + echo rides slow output POST + 750 ms discovery. Far above 16 ms. | Bytes flow immediately over WS; latency ≈ RTT (HK ~24 ms). Already good. | WS both directions, RTT-bound; AttachAddon text frames coerced to data. | WS both directions, RTT-bound, channel-prefixed frames. | **Stream default ⇒ RTT-bound (~24 ms). Poll floor eliminated.** |
| **Output loss / backpressure** | CRITICAL: ring evicts at 600 events / 512 KB with **no gap marker**; cursor past trimmed region silently skips. Per-event truncated at 32 KB. Blocking POST-per-4KiB ⇒ ~170 KiB/s. | No loss (raw byte relay) but `io.CopyBuffer` has no per-write deadline; stalled WS write blocks PTY draining unbounded. | Raw byte relay via `io.CopyBuffer`, 1 MB `sync.Pool` buffers; no ring loss. | Direct apiserver/SSH stream relay, no server ring. | **Raw byte relay end-to-end + per-write deadline (agent leg) + TCP backpressure (browser leg, not teardown). No ring, no silent loss.** |
| **Reconnection / PTY persistence** | Sessions in-memory map; agent restart ⇒ fresh shell, zero replay. | CRITICAL: any WS drop fires `outDone/inDone` ⇒ full teardown incl. SIGKILL. 1 s CF blip destroys shell. No redial. | No per-session resume (single-attach, ephemeral); base channel auto-reconnects w/ backoff. | No resume; reopen = fresh shell (inherent to k8s exec). | **Decouple WS-drop from PTY-kill: only `ctx.Done`/shell-exit kills PTY. Agent redials w/ backoff; server keeps session detached-but-open within TTL; offset-based replay on reattach.** |
| **Resize** | Lagged up to 250 ms, no clamp/coalesce, redraw churn on drag. | Immediate, clamped to 1000, via `pty.Setsize`. Good. | Resize on channel byte 1, JSON `{Cols,Rows}`, frontend debounce 1500 ms. | Resize on channel 4, JSON `{Width,Height}`. | **Stream resize (immediate, clamped). Frontend debounce 160 ms via ResizeObserver+FitAddon. Re-apply size + SIGWINCH on reattach.** |
| **Scrollback / replay** | Ring is the only buffer; reattach replays only survivors (truncated after sizable output). | None — fresh blank screen on reconnect. | None server-side; client keeps xterm scrollback until dispose. | None (no session id to reattach). | **Agent-side authoritative ring (~256 KB–1 MB), offset-based replay on *fresh* reattach + clean-screen resync; xterm 10k scrollback client-side. Skip addon-serialize v1.** |
| **Copy-paste** | Hand-rolled `navigator.clipboard`, no bracketed-paste, multiline paste auto-executes (footgun), bare Ctrl+V not intercepted, silent failure on insecure context. | Same (shared component). | xterm defaults + AttachAddon. | xterm defaults. | **xterm-native bracketed paste (DECSET 2004); multiline-confirm only as fallback when bracketed paste is off; surface insecure-context error as toast. Keep Cmd/Ctrl+Shift+C/V. OSC52 gated.** |
| **Multi-viewer / detach-reattach** | Single shared cursor; two browsers corrupt each other and fight over stdin/resize. Reattach = cursor reset, truncated scrollback. | Strictly 1:1 hub rendezvous; second attach supersedes first (`existing.close`). | Single-attach, ownership-authorized. | Single-attach. | **Clean detach-reattach to kept-alive PTY (single active viewer). Supersede becomes explicit "take-over" w/ control-frame warning to the losing tab. Multi-viewer DEFERRED (gold-plating).** |
| **Renderer performance** | DOM renderer only (FitAddon sole addon); chokes on fast/large output. | Same DOM renderer; worse — raw bytes arrive unthrottled. | xterm v6 + AttachAddon + FitAddon (DOM). | xterm + fit (DOM). | **WebGL primary (detected once at init) + `onContextLoss`→recreate+`refresh(0,rows-1)`, Canvas fallback, DOM last resort. Beats both reference projects.** |
| **Full-screen apps (vim/htop/tmux)** | No process-group setup; orphaned children. `allowProposedApi:false` ⇒ wrong CJK/emoji widths corrupt alignment. | Process-group + group-SIGKILL correct (`terminal_pgkill_unix`). Still `allowProposedApi:false`. | creack/pty + process-group kill; `TERM=xterm`. | Real PTY via apiserver/SSH. | **Process-group kill on ALL paths + `allowProposedApi:true` + addon-unicode11 (`activeVersion='11'`, loaded before first write). SIGWINCH redraw nudge on reattach.** |
| **Auth / audit** | Node-token + RBAC `terminal:open` + dual NodeID ownership. open/close/attach audited; input/output bytes NOT audited. | Same auth (`markOpen` ownership). Stream bytes never enter audit. | Dual-sided authz, per-user/server caps, WAF BlockIP on auth fail. | Cluster RBAC via serviceaccount. | **Preserve node-token+RBAC+dual-ownership. Re-validate RBAC + ownership on every (re)attach. Audit any out-of-band signal action (if 0x02 kept). asciinema-style recording DEFERRED (gated Phase 5).** |
| **Mobile / touch** | Desktop-only: no soft-key toolbar (Esc/Tab/Ctrl/arrows), copy/paste needs modifiers, fixed min-height grid. | Same. | Fullscreen support; no documented soft-key toolbar. | Desktop-oriented. | **Soft-key toolbar + touch layout in a later UX phase. Verify Canvas fallback reachable on mobile GPUs. Low priority vs latency/loss.** |
| **Observability** | BytesIn/Out per session; no metrics on poll cadence, eviction, reconnect. | `markOpen/markClosed` status only; no bridge metrics. | Per-user/server caps observable. | n/a. | **From Phase 0/1: teardown-reason enum, active sessions, redial count, replay-bytes, write-deadline-timeouts, bytes-dropped (must be 0), backpressure events; shared `sessionId` greppable across all 3 hops. Status badge driven by socket state.** |

---

## 3. Target architecture

### 3.1 Wire protocol (final, binary WebSocket end-to-end)

Builds directly on the existing stream opcodes. Two channels, discriminated by **WebSocket frame type — never by an in-band byte on the data stream.**

**Data plane (agent → browser): raw PTY bytes, BINARY frame, no framing.** Written verbatim to xterm via `term.write(Uint8Array)` to preserve xterm's stream-aware UTF-8 decode of split CJK/emoji. Server relays verbatim — no base64, no re-encode (Go strings are already UTF-8 `[]byte`).

**Input plane (browser → agent): 1-byte opcode prefix, BINARY frame:**
- `0x00` = stdin (payload written verbatim to PTY)
- `0x01` = resize (JSON `{cols,rows}`)
- `0x02` = signal *(conditional — see Decision 7; if kept, server-mediated + audited)*
- `0x03` = client-ACK *(only if ACK windowing is later enabled — Decision 6)*
- `0x04` = reattach handshake (JSON `{session_id, last_offset}`) — sent on reconnect

**Control plane (agent → browser): separate BINARY frame with a distinct opcode prefix.**

> **[Critic fix — constraints/medium, ux-ops/high "0x10 collides with raw-byte contract" and "won't render"]** The blueprint conflated "first-byte-tagged" with "separate text frame." Resolution: control frames are a **separate BINARY frame whose first byte is a control opcode ≥ `0x80`** (out of the data plane entirely; the data plane has *no* opcode byte). We do **not** overload text frames and do **not** rely on JS string-vs-ArrayBuffer typing as the demux. Concretely:
> - `0x80` = exit `{code}` → UI renders a dim inline banner `process exited (code N)`.
> - `0x81` = session-closed `{reason}` → `session closed: idle timeout | max duration | taken over`.
> - `0x82` = take-over notice → losing tab shows `session taken over by another window`.
>
> **Demux rule:** browser distinguishes data vs control by inspecting the first byte of each binary frame **only on the agent→browser leg**, where the data plane is defined as raw bytes that are tagged with a leading length-free sentinel. To avoid any ambiguity with raw PTY output that happens to begin with a high byte, the agent emits **all** agent→browser frames with a 1-byte channel tag: `0x00` = data (rest is raw PTY bytes), `0x80+` = control. This is a one-byte cost per frame and removes the entire "DLE corrupts the stream" class of bug.

> **[Critic fix — constraints/medium "frame-type downgrade is a real bug"]** Today `websocketx.Conn.Write` forces `BinaryMessage` on the `b←a` leg, so any text control frame from the agent would be silently downgraded and corrupt the data stream. Because we standardize on **binary frames with a 1-byte channel tag** (above), there is no text-frame path to downgrade and no bug to trip. The server bridge stays a pure byte relay and never inspects the tag.

Today `XtermSession.vue onmessage` does `if (typeof ev.data === 'string') return;`. **[Critic fix — ux-ops/high]** Phase 2 replaces that discard with a binary-frame demux that reads the channel tag, writes `0x00` payloads to xterm, and renders `0x80+` control frames as inline banners. There is an explicit e2e check: type `exit`, confirm the UI shows the code rather than a silent disappearance (the kuboard `StreamClose=255` lesson).

### 3.2 Flow control / backpressure (deadlock-free)

> **[Critic fix — constraints/high "deadline cannot be added in bridge()", ux-ops/high "deadline-teardown regresses slow clients"]** This is the single most reworked area.

**Where the deadline lives.** `bridge()` is a bare `io.Copy(a,b)/io.Copy(b,a)` pair; `io.Copy` has no deadline hook. The only correct place is inside the shared `websocketx.Conn.Write` (server, `safe_conn.go:40`) and `wsConn.Write` (agent). This is documented as a **type-contract change**, not a bridge change, with a known blast radius: a fired deadline returns an error that tears down both legs via the single `<-errc`.

**Asymmetric policy (the key correctness decision):**
- **Agent → browser leg (output):** a *short-ish* write deadline detects a genuinely dead/half-open browser connection. But a fired deadline must **not** be the primary slow-client mechanism.
- **Slow-but-alive browser (mobile, backgrounded tab during `cat bigfile`):** the single-server bridge is one goroutine per direction. When the browser write blocks, the goroutine stops reading the agent leg, which applies **natural TCP backpressure to the agent**, which fills its OS socket buffer, which makes *its* PTY read block — pausing the producer. **This is the correct mechanism and it requires no teardown.** We do **not** kill the session on the first browser write-deadline miss.
- **Liveness is decided by ping/pong, not by the data-path deadline.** A truly dead browser is detected by the server-driven ping on the browser leg (§3.5), not by a slow `cat`. The write deadline is set generously (`WriteWait ≥ pong wait`, e.g. 30 s) so it fires only on real stalls, and even then the resulting teardown is **caught by the Phase-1 redial/keep-PTY-alive loop** rather than killing the shell.

> **[Critic fix — constraints/high "sequence Phase 1 with the deadline"]** The write-deadline change (Phase 0) and the keep-PTY-alive/redial change (Phase 1) ship such that no deadline-induced teardown can SIGKILL a shell. If schedule forces them apart, Phase 0 ships the deadline **only on the agent leg** (where teardown is recoverable by the agent's own session loop) and defers the browser-leg deadline to Phase 1.

**Metrics distinguish the two cases** (§3.7): `backpressure_events` (slow consumer, healthy) vs `deadconn_teardowns` (ping/pong failure). This makes the ACK-windowing soak decision data-driven instead of being masked by teardowns.

**Conditional Phase: full VS Code-style ACK windowing** (`HighWatermark=100000`, `Low=5000`, `CharCountAckSize=5000`, browser sends `0x03` every 5000 chars, agent tracks unacked and `pty.pause/resume`) is added **only if soak shows sustained backpressure / browser-tab OOM**. With WebGL + bounded relay this is likely unnecessary. Explicitly staged, not default — avoid gold-plating.

### 3.3 Reconnection state machine (atomic, three-tier)

> **[Critic fix — ux-ops/critical "reconnect is the critical gap; all three tiers must ship in ONE phase"]** Reconnect is **one atomic Phase-1 deliverable** spanning agent + server + browser. Agent-side alone is necessary but not sufficient — without the server detach window and the browser reattach handshake, reconnect paints a blank or doubled screen, *worse* than today's poll.

**Browser FSM:**
```
CONNECTING ──open──> OPEN
   │                  │
   │              (WS error)
   │                  ▼
   └──1013──> FAILED  REATTACHING ──exp backoff 500ms→8s +jitter──┐
                       │  └────────────── re-dial, send 0x04 ─────┘
                       ▼
   (1000/explicit) ──> CLOSED
```
- The xterm `Terminal` instance is **kept alive** across `REATTACHING` (never disposed) — the browser already does this.
- On reconnect the browser sends `0x04 {session_id, last_offset}` where `last_offset` is the monotonic byte count it has already rendered. This distinguishes **REATTACHING-same-browser** (kept its xterm buffer; agent replays only `bytes > last_offset`, usually zero) from **fresh attach** (`last_offset = 0`; agent sends clean-screen resync then full ring).

**Server side:** replace unconditional `markClosed`-after-attach (`server_terminal.go:584-585`) with **detached-but-open** state + a detach TTL (Decision 2). The reaper does not GC a detached-open session until the window expires. RBAC `terminal:open` + dual NodeID ownership are **re-validated on every (re)attach**, not just at open (Decision 4 / ux-ops security fix).

**Agent side:** `runStream` becomes an **outer session loop** that owns the PTY + process group + ring. WS in/out errors (anything that is not `ctx.Done` or PTY EOF) stop the copy but **keep the PTY and ring alive**, then redial `/api/agent/terminal/stream` with backoff, carrying the in-process `session_id`.

> **[Critic fix — constraints/high "discovery returns only Pending sessions"]** Agent discovery (`pendingForAgent`, `server_terminal.go:129-143`) only returns `TerminalPending` sessions; once `markOpen` runs the session vanishes from discovery. The redial loop therefore **must not** rely on re-discovery — it holds `session_id` in-process and re-dials the stream endpoint directly (which does `get()` + NodeID check + `markOpen` with no status restriction). This makes "do NOT `markClosed` on transient drop" a **hard prerequisite, not polish**: if `markClosed` fires, `markOpen` early-returns on `Closed/Failed` (`server_terminal.go:275-277`), the redial no-ops, and the agent redials a dead session forever. The detached-but-open state closes this race.

### 3.4 Session model (detach/reattach + multi-viewer)

- **Server-authoritative session** (`terminalBroker`) keyed by an unguessable id, bound to `NodeID + ActorID`.
- **PTY lifetime is decoupled from any single WS.** It survives browser-tab close and transient agent WS drop within a detach TTL. It is killed only on: explicit `close` opcode, shell exit, idle TTL, max-duration TTL, or detach-grace expiry.

> **[Critic fix — ux-ops/medium "detach window resource & security exposure"]** Three caps are specified explicitly (Decision 2):
> 1. **Idle TTL = no-output AND no-input** (not merely no-viewer), plus an absolute **max-duration** cap.
> 2. **Short detach grace** (e.g. 30–60 s with no viewer) after which an output-producing-but-viewerless session (e.g. `tail -f`) is still reaped, bounding leaks across 30 nodes.
> 3. **RBAC + ownership re-check on every reattach** so a session whose actor lost authorization while detached cannot be resumed.

- **Single active viewer for v1.** The hub's supersede-on-new-attach (`existing.close`) becomes explicit **take-over**: the losing tab gets a `0x82` control frame (`session taken over by another window`) rather than a silent close. Multi-viewer / read-only observer is **DEFERRED** (needs a fan-out hub + single authoritative writer + presence — large server change for a feature 30-node ops rarely needs).
- **Agent holds the authoritative ring** (~256 KB–1 MB) and a **monotonic byte offset** per session.

### 3.5 Replay semantics (gap-free, no double-render, no escape-sequence corruption)

> **[Critic fix — constraints/medium + ux-ops/high "ring head replay corrupts / double-renders"]** "Replay the ring head" as written is a bug. Precise definition:

- The agent tracks a **monotonic byte counter** for everything written to the PTY-output stream. The ring stores `(start_offset, bytes)`.
- **Same-browser reconnect** (`0x04 last_offset = N`, N ≥ ring start): replay only `bytes > N`. Usually zero — the client kept its xterm buffer. **No double render.**
- **Fresh attach** (`last_offset = 0`, or N < ring start because the ring evicted past it): the agent first emits a **clean-screen resync** (`\x1bc` RIS, or at minimum `\x1b[2J\x1b[H`) so the browser starts from a known-clean state, then replays the **retained ring from a safe boundary**.
- **Escape-sequence safety:** the ring's retained window always begins at a recorded **safe boundary** (the agent only advances the replay-start pointer to offsets known not to fall mid-ANSI/mid-UTF-8 — in practice, the offset after the last fully-flushed write). Replaying from an arbitrary mid-CSI byte is thereby prevented.
- **Full-screen apps (vim/htop/tmux):** byte replay cannot reconstruct alternate-screen TUI state. On fresh reattach the agent additionally **delivers SIGWINCH to the foreground process group** (after applying the browser's current size, §3.6) to trigger the app's own full repaint. The verification bar: "screen is identical (not doubled, not blank) after reattach."

### 3.6 PTY correctness

- Reuse `creack/pty` `StartWithSize`, `TERM=xterm-256color`.
- **Process-group isolation + group-SIGKILL on ALL paths** (currently stream-only) via `terminalSetPGID`/`terminalKillProcessGroup` with the `Kill(-0)` safety guard.
- Resize via `pty.Setsize`, clamped to 1000.

> **[Critic fix — ux-ops/medium "no resize-on-reattach"]** On reattach, **enforce ordering**: apply the browser's current `cols/rows` (`pty.Setsize`) **and** deliver SIGWINCH to the foreground process group **before** replay completes, so a TUI redrawn after a window resize/phone rotation during the drop paints at the correct geometry. e2e: open htop wide, drop WS, shrink window, reattach → htop reflows.

- Shell validated against the existing server-side `normalizeTerminalShell` allowlist.

### 3.7 Frontend xterm addon stack + component abstraction

**Addon stack:**
- `@xterm/addon-fit` (have it).
- **`@xterm/addon-webgl` (primary)** — WebGL2 **detected once at init**; on `onContextLoss` → recreate addon **and** `terminal.refresh(0, terminal.rows-1)` to repaint from the retained buffer so a flood loses no visible frames. **[Critic fix — ux-ops/low]**
- **`@xterm/addon-canvas` (fallback)** when WebGL2 unavailable; **verified reachable on real mobile GPUs**, not just WebGL-disabled desktop.
- **DOM** last resort.
- `@xterm/addon-unicode11` + `terminal.unicode.activeVersion='11'` + `allowProposedApi:true`, **loaded before the first write** so early CJK output is not mismeasured. **[Critic fix — ux-ops/low]**
- `@xterm/addon-web-links` (sanitized handler), `@xterm/addon-search` (find over 10k scrollback).
- **SKIP v1:** `addon-serialize` (the agent ring replaces it), `addon-clipboard`/OSC52 (gate behind policy flag), `addon-ligatures`.

**Copy-paste.** **[Critic fix — ux-ops/medium]** Use xterm-native paste handling: when the remote app has requested **bracketed paste (DECSET 2004)**, `onData` already wraps the paste in `\x1b[200~ … \x1b[201~` so readline treats it as literal input and does not auto-execute. The **multiline-confirm prompt is only a fallback** when bracketed paste is off. Surface the insecure-context (`navigator.clipboard` undefined over http) failure as a toast. Keep Cmd/Ctrl+Shift+C/V; do not intercept bare Ctrl+V when bracketed paste is off.

**Component abstraction.** Refactor `XtermSession.vue` into:
- **`useTerminalSession`** — transport-agnostic; owns the xterm `Terminal` + addon stack + lifecycle; exposes `write()/onData()/fit()/dispose()`.
- **`useTerminalTransport`** — single stream implementation; owns the WS FSM, opcode framing, reconnect, and the `0x04` replay handshake.

This collapses the scattered `isStream` branching into one clean stream path and makes a future multi-tab manager trivial (instantiate N composables).

### 3.8 Server bridge design

- Keep the documented boundary: **`terminalBroker`** = lifecycle/RBAC/audit/caps source of truth; **`terminalHub`** = transient rendezvous.
- Keep `io.Copy` splice + `websocketx.Conn` `writeMu`. **Add per-write deadline (in the shared `Conn.Write`, §3.2)** and **server-driven ping/pong on both legs**.

> **[Critic fix — constraints/medium "server has no keepalive", ux-ops/low "browser-leg half-open"]** Today only the agent and browser ping; the server is passive (no read deadline, no pong handler, bare `io.Copy`). Add to `websocketx.Conn`: `SetReadDeadline` + `SetPongHandler` + a ping goroutine using the existing `writeMu`. Run an **independent ping on the BROWSER leg** (10 s ping / 30 s pong deadline) so a mobile-suspend / dead tab is detected within ~1 ping cycle even on an idle shell with no output, feeding the detach-window timer accurately.

> **[Critic fix — constraints/low "300s proxy/CF idle on detached sessions"]** The **agent-leg ping ticker runs for the whole session lifetime, including detached windows** (when no browser is bridged), at an interval comfortably under the nginx 300 s `proxy_read_timeout` (e.g. 60 s with margin) so a detached-but-alive session is not reaped by the proxy and degraded into reconnect storms.

- Replace lazy prune-in-locked-reads with a **background reaper goroutine** for idle/closed/detach-expired GC (and it must skip detached-open sessions inside their window).
- Single-process in-memory is acceptable for the 30-node single-server deployment (metix-hk primary). Horizontal scaling / persistent store is explicitly **out of scope**.

---

## 4. Decisions & rationale

**D1 — Make stream the default and deprecate poll?**
Options: keep poll default (status quo) · make stream default via server-pushed `AgentConfig` with poll as one-release fallback, then delete · hard cut to stream now.
**Recommended:** stream default via `AgentConfig` per-node lever, poll as runtime-selectable fallback for exactly one release, then delete `runPoll/pollInputs/postEvents/postStatus` + the broker rings. Poll is the root cause; stream is the better path and exists end-to-end; a hard cut across 30 live nodes is unsafe. The decisive lever is moving `TerminalTransport` into `AgentConfig` (`applyAgentConfig` currently ignores it) so we flip per-node without redeploy.

**D2 — Reconnection replay: client serialize vs agent ring vs both?**
Options: no replay (nezha/kuboard parity) · client addon-serialize · agent-side authoritative ring · both.
**Recommended:** **agent-side authoritative ring (~256 KB–1 MB) + keep-PTY-alive-on-WS-drop, offset-based, with the §3.5 resync/SIGWINCH semantics. Skip addon-serialize v1.** The agent is the natural owner (outbound, holds the PTY). addon-serialize is client-only, lost on hard reload, and duplicates the ring.

**D3 — In-app multi-tab / multi-session manager?**
Options: single session per view · in-app tab strip · tab strip + multi-viewer.
**Recommended:** **tab strip in a later phase (Phase 5, optional); defer multi-viewer entirely.** Tab strip is a pure frontend-composable change once the session/transport is solid (no protocol impact). Multi-viewer needs a fan-out hub + single writer + presence — gold-plating for 30-node ops.

**D4 — Agent-PTY-only or SSH-into-arbitrary-host?**
Options: agent-PTY only · agent-side SSH client · server-side SSH client.
**Recommended:** **stay agent-PTY-only.** The agent already runs a real PTY on the node it manages; SSH-to-arbitrary-host means credential storage, host-key management, and a new trust boundary — a different product and a security-surface expansion. Out of scope.

**D5 — Renderer?**
Options: keep DOM · Canvas only · WebGL primary + Canvas fallback + DOM last resort.
**Recommended:** **WebGL primary** (`onContextLoss` → recreate + `refresh`), **Canvas fallback**, **DOM last resort**; WebGL2 detected once at init; Canvas verified on mobile. Pure client-side, transport-independent, table-stakes for fleet ops output.

**D6 — Flow control / backpressure?**
Options: none · server bounded buffer + TCP backpressure · full ACK windowing · both staged.
**Recommended:** **Phase 1 — per-write deadline in the shared `Conn.Write` (agent leg) + TCP backpressure via the one-goroutine-per-direction bridge for slow-but-alive browsers (no teardown); liveness via ping/pong.** Defer full VS Code ACK windowing unless soak shows sustained backpressure / browser OOM. Metrics separate "backpressure events" from "dead-conn teardowns" so the decision is data-driven.

**D7 — Out-of-band signal opcode (`0x02`)?**
Options: keep `0x02` server-mediated + audited · drop it (rely on in-band Ctrl-C).
**Recommended:** **lean toward dropping `0x02` for v1.** **[Critic fix — constraints/low ×2]** Ctrl-C is already delivered in-band via stdin and the line discipline turns it into SIGINT for the foreground job; `0x02` duplicates this for the common case and only helps kill a job that disabled Ctrl-C / put the tty in raw mode. If kept, it must (a) use `tcgetpgrp(pts)`-based foreground-pgrp signaling with a fallback, and (b) be **server-mediated so it can be audited** — a pure-relay signal is invisible to audit, which the pure-relay design precludes. Keeping signals in-band adds **no new audit surface**, so the default recommendation is to drop `0x02`.

---

## 5. Phased implementation plan

Every phase is incremental, non-breaking while poll remains the live default, and reversible. `go test -race ./...` is the gate in Go repos; `pnpm build && pnpm lint` + gstack/Playwright e2e in the dashboard.

### Phase 0 — Stream hardening + core observability
*Repos: lattice-node-agent, lattice-server*
**Goal:** fix latent stream bugs and add the metrics needed to fly the canary, before any promotion.
- `lattice-node-agent/cmd/lattice-agent/websocketx.go`: add `SetWriteDeadline(now+WriteWait)` inside `wsConn.Write` (documented type-contract change); standardize agent→browser frames on **binary + 1-byte channel tag** (§3.1) so control frames cannot corrupt the data stream.
- `lattice-server/internal/server/websocketx/safe_conn.go`: add `SetWriteDeadline` inside `Conn.Write` (type-contract change, §3.2); add `SetReadDeadline` + `SetPongHandler` + ping goroutine using `writeMu`.
- `lattice-server/internal/server/server_terminal_stream.go`: wire server-driven ping/pong on **both** legs (agent leg ticker runs for session lifetime); the bridge stays a pure relay.
- `lattice-node-agent/cmd/lattice-agent/terminal.go`: build dial/poll HTTP via `NewRequestWithContext` so ctx cancellation isn't ignored for up to 30 s; add agent-side idle + max-duration caps.
- **Observability (pulled forward from the original Phase 5):** teardown-reason enum (`browser-leg-error / agent-leg-error / write-deadline-timeout / ctx-done / normal-exit`) logged with `sessionId`; counters for active sessions, redial count, replay-bytes, write-deadline-timeouts, bytes-dropped (must be 0), backpressure-events vs dead-conn-teardowns; a single `sessionId` logged identically in agent, server, and browser console. **[Critic fix — ux-ops/high "observability needed from Phase 1"]**
**Verification:** `go test -race ./...`; run agent `-terminal-transport stream`, attach, run `yes`, kill CF/nginx mid-stream → clean teardown, not a 30 s hang; confirm idle TTL closes an abandoned shell; new test: a blocked browser write does not block agent→PTY read indefinitely; half-open leg (drop, no close frame) tears down within ~1 ping cycle.
**Breaking / rollback:** non-breaking — stream still opt-in, poll still default. Pure hardening of a dark-launched path. Revert commits; no data/contract change.

### Phase 1 — PTY-survives-WS-drop + agent redial + offset-based replay (ATOMIC, three-tier)
*Repos: lattice-node-agent, lattice-server, lattice-dashboard*
**Goal:** stop WS blips from SIGKILLing the shell; reconnect repaints cleanly. **All three tiers ship together** — agent-side alone would regress UX below poll.
- `lattice-node-agent/.../terminal.go`: restructure `runStream` into an outer session loop owning PTY+pgroup+ring; on WS in/out error (not `ctx.Done`/PTY EOF) keep PTY alive, redial with backoff carrying `session_id`, re-splice; per-session output ring (~256 KB–1 MB) with a **monotonic offset + safe replay boundary** (§3.5); on reattach apply size + SIGWINCH then replay `bytes > last_offset` (or clean-screen resync + full retained ring on fresh attach).
- `lattice-server/.../server_terminal_stream.go`: allow the agent leg to re-rendezvous with a **detached-but-open** session within the detach window; do NOT `markClosed` on a transient first-bridge end.
- `lattice-server/.../server_terminal.go`: replace unconditional `markClosed`-after-attach (584-585) with a **detached-but-open** broker state + detach TTL; reaper skips detached-open within the window; **re-validate RBAC + dual ownership on every (re)attach**; emit `0x82` take-over to the superseded viewer.
- `lattice-dashboard/.../XtermSession.vue` (transport layer): extend FSM with `REATTACHING`; send `0x04 {session_id, last_offset}` on reconnect; keep Terminal alive across reconnect; add browser-leg ping participation.
**Verification:** `go test -race ./...`; new tests — redial+replay, offset dedup, broker detach window (drop→stay→reattach-in-window = same PTY; drop→window-expires = closed+PTY killed); e2e — open vim/htop, kill nginx 2 s, confirm shell+app survive and screen is **identical (not doubled, not blank)** on reattach; resize-during-drop → reflow on reattach.
**Breaking / rollback:** non-breaking — still behind the stream opt-in; poll untouched. Revert → stream returns to kill-on-drop (still functional).

### Phase 2 — Frontend xterm upgrade (renderer + unicode + addons + reconnect UX + control frames)
*Repo: lattice-dashboard*
**Goal:** bring the browser to nezha/kuboard quality, transport-independent.
- `package.json`: add `@xterm/addon-webgl`, `@xterm/addon-canvas`, `@xterm/addon-unicode11`, `@xterm/addon-web-links`, `@xterm/addon-search`.
- `XtermSession.vue`: `allowProposedApi:true`; WebGL (detect-once, `onContextLoss`→recreate+`refresh(0,rows-1)`) → Canvas → DOM; unicode11 `activeVersion='11'` loaded before first write; web-links; search; **replace the string-frame discard with a binary control-frame demux** rendering `0x80`/`0x81`/`0x82` as inline banners; bracketed-paste-native copy/paste with multiline-confirm fallback; surface clipboard insecure-context error; visible "reconnecting in N s" + manual reconnect button; drive status badge from socket state.
- `src/views/operations/TerminalView.vue`: fix status vocabulary mismatch (`'active'` vs `pending|open|closed|failed`, lines 259/295).
**Verification:** `pnpm build && pnpm lint`; gstack/Playwright — htop in CJK locale (correct width), large output (no frame drops via WebGL), URL clickable, search works, multiline paste prompts only when bracketed paste off, `exit` shows the code; Canvas fallback verified on a real mobile browser.
**Breaking / rollback:** non-breaking — works for both transports; renderer fallback chain means no hard WebGL2 dependency. Revert `package.json` + component.

### Phase 3 — Runtime/per-node transport control via AgentConfig (the rollout lever)
*Repos: lattice-sdk, lattice-server, lattice-node-agent*
**Goal:** flip poll→stream per node without redeploy.
- `lattice-sdk/model`: add `TerminalTransport` (and optional `AllowTerminal`) to `AgentConfig`.
- `lattice-server`: include per-node `TerminalTransport` in the served `AgentConfig`; admin control to set it per node/group; **stamp the chosen transport on the session record at OPEN time** so browser and agent legs agree for the session's whole life regardless of a mid-session config flip. **[Critic fix — ux-ops/medium "transport flip race"]**
- `lattice-node-agent/.../main.go` (`applyAgentConfig`, 413-437): honor remote `TerminalTransport`; **capture it by value into the `terminalRunner` at session creation under the same mutex `applyAgentConfig` uses to write `cfg`; never read `cfg.TerminalTransport` from the per-session goroutine after start.** Existing in-flight sessions unaffected.
**Verification:** `go test -race ./...`, incl. a `-race` test flipping config concurrently with session open; manual — flip one node to stream from the server, confirm new sessions use stream while a second node stays poll; flip back instantly.
**Breaking / rollback:** non-breaking — default stays poll until explicitly flipped; startup flag remains an override. Server sets transport back to poll fleet-wide instantly (no redeploy).

### Phase 4 — Canary then fleet: stream becomes default
*Repos: lattice-server, lattice-dashboard, lattice-node-agent*
**Goal:** promote stream via the Phase-3 lever: canary 1–2 nodes → all 30 → set stream as the new default.
- `lattice-server`: change default `AgentConfig.TerminalTransport` to stream (after soak).
- `lattice-dashboard/.../TerminalView.vue`: default the Streaming toggle on / remove the opt-in.
- `lattice-node-agent/.../main.go:180-183`: change normalized default to stream.
**Verification:** soak the Phase-0/1 metrics — redial count, teardown-reason mix, zero dropped-bytes, backpressure vs dead-conn split; dogfood interactive latency vs old poll on metix-hk; gstack e2e full flow.
**Breaking / rollback:** incremental and reversible per-node via the Phase-3 lever — flip individual nodes back to poll instantly. Live terminal never down (both transports coexist during rollout).

### Phase 5 — Delete poll + optional polish
*Repos: lattice-node-agent, lattice-server, lattice-dashboard*
**Goal:** remove the lossy/laggy poll path once stream has soaked fleet-wide.
- `lattice-node-agent/.../terminal.go`: delete `runPoll`, `pollInputs`, `postEvents`, `postStatus`, `inputCursor`, `terminalPollInterval/InputInterval/ReadChunk`.
- `lattice-server/.../server_terminal.go`: delete `events`/`inputs` rings, `trimTerminalEvents`, `eventsAfter/inputsAfter`, `addInput`, and the `/events`,`/input`,`/resize`,`/close` browser routes + agent `inputs`/`events` routes (the silent-eviction bug source).
- `lattice-dashboard/.../XtermSession.vue`: delete the poll branch; finalize the `useTerminalSession` + `useTerminalTransport` split; **(optional)** tab strip in `TerminalView.vue` (D3).
- **(optional, gated)** `lattice-server`: asciinema-style session recording to store/WAL for forensic audit (D-audit; deferred here deliberately).
**Verification:** `go test -race ./...`; `pnpm build`; full e2e; confirm no references to deleted routes; audit log still records open/close/attach (and signal, if `0x02` was kept).
**Breaking / rollback:** breaking ONLY for the poll wire contract, which has no remaining clients after Phase 4. Gate behind a release where all 30 agents report stream-capable. This is the point of no return for poll — keep the Phase-4 revert window open before merging.

---

## 6. What we keep from iter-063 vs replace

**REUSE AS-IS (the well-engineered stream path is the foundation, not a rewrite):**
1. **Agent stream transport core** — `runStream`'s dial-before-spawn ordering (so a failed dial never orphans a shell); opcode framing `0x00` stdin / `0x01` resize; process-group setup + group-SIGKILL teardown (`terminalSetPGID`/`terminalKillProcessGroup`, `terminal_pgkill_unix.go`) with the `Kill(-0)` guard; deterministic teardown ordering.
2. **Both websocketx adapters** — server `internal/websocketx/safe_conn.go` and agent `wsConn`: the `writeMu` serialization is the load-bearing correctness piece (and now anticipated the keepalive/ping writer we add). Keep it.
3. **Server bridge skeleton** — `terminalBroker` (lifecycle/RBAC/audit source of truth) + `terminalHub` (transient rendezvous) boundary; the leak-free unbuffered-`agentCh` rendezvous; the `io.Copy` splice; dual-ownership auth (`authenticateNode` + `sess.NodeID==nodeID`); `CheckOrigin` same-origin; per-node/global caps.
4. **Frontend stream plumbing** — `wsGen` generation-based socket invalidation, binary opcode framing, `arraybuffer` `binaryType`, exponential backoff (500 ms→8 s), close-code handling (1000/1013), debounced resize via ResizeObserver+FitAddon, lifecycle hygiene (disposed flag, re-key per session).
5. **Keepalive design** — 10 s client ping / 30 s pong read deadline (extended to a server-driven ping on both legs in Phase 0).

**REPLACE / RETIRE:**
1. **The entire poll path** once stream soaks — `runPoll`, `pollInputs`, `postEvents/postStatus`, agent `inputCursor`; server `events`/`inputs` rings, `trimTerminalEvents`, `eventsAfter/inputsAfter`, `addInput`, the `/events` GET and `/input`,`/resize`,`/close` browser routes + agent `inputs`/`events` routes. This is the lossy/laggy default and the silent-eviction bug.
2. **Startup-frozen transport selection** (`main.go:180-183`) → `TerminalTransport` in `AgentConfig` + `applyAgentConfig`, captured-by-value per session.
3. **Kill-on-first-disconnect** (`terminal.go:307-321`) → redial loop + keep-PTY-alive.
4. **Unconditional `markClosed` after attach** (`server_terminal.go:584-585`) → detached-but-open semantics + detach TTL.
5. **Frontend `allowProposedApi:false` + DOM renderer** → `allowProposedApi:true` + unicode11 + WebGL/Canvas/DOM chain.
6. **Agent→browser string-frame control + the `Conn.Write` binary downgrade** → binary frames with a 1-byte channel tag (control opcodes ≥ `0x80`).

---

## 7. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Write-deadline change in shared `Conn.Write` tears down both legs (larger blast radius than implied) | Generous `WriteWait` (≥ pong wait) so it fires only on genuine stalls; slow-but-alive browser handled by TCP backpressure, not teardown; Phase 0 deadline-teardown caught by Phase 1 redial loop. Test: blocked browser write never blocks agent→PTY read. |
| `markClosed` race strands a live PTY (redial no-ops) | Detached-but-open broker state is a hard prerequisite in Phase 1; reaper skips detached-open within window; broker-level tests for both reattach-in-window and window-expiry. |
| Replay double-renders or corrupts mid-escape-sequence | Offset-based replay (`bytes > last_offset`); clean-screen resync on fresh attach; safe replay boundary; SIGWINCH redraw nudge for TUIs. |
| Control frame corrupts raw-byte data stream | All agent→browser frames are binary with a 1-byte channel tag; no text-frame downgrade path; demux by tag, never by an in-band data byte. |
| Detached sessions leak resources / `tail -f` never idles | Idle TTL on no-output-AND-no-input + absolute max-duration + short detach grace that reaps viewerless output-producers; metric: detached session count + age histogram. |
| Detached session resumed after RBAC revoked | Re-validate RBAC `terminal:open` + dual ownership on every (re)attach. |
| Proxy/CF reaps detached agent leg at 300 s | Server-driven agent-leg ping runs the whole session lifetime at <300 s (e.g. 60 s margin). |
| Config flip races the per-session goroutine | Capture `TerminalTransport` by value under `applyAgentConfig`'s mutex; stamp transport on the session at OPEN time; `-race` test flips config concurrently with open. |
| WebGL context loss drops frames mid-flood / mobile GPU | Recreate addon + `refresh(0, rows-1)` from retained buffer; WebGL2 detected once at init; Canvas fallback verified on real mobile. |
| Canary flown blind | Observability pulled into Phase 0/1; teardown-reason enum + counters + shared `sessionId` across all 3 hops before the Phase-4 flip. |
| Take-over silently kills a working tab | Explicit `0x82` take-over control frame to the losing tab. |

### Test plan

- **Unit / `-race` (Phase 0–3):** write-deadline does not block opposite leg; broker detach window (reattach-in-window = same PTY; expiry = closed + PTY killed); offset dedup (no double bytes); config-flip-concurrent-with-open; half-open leg teardown within ~1 ping cycle.
- **Flood test:** `cat bigfile` / `yes` over WebGL — no frame drops, no browser OOM; backpressure pauses the producer (agent PTY read blocks) without teardown; on a deliberately throttled (mobile-like) client, confirm the session is **not** killed and metrics record a backpressure event, not a dead-conn teardown.
- **Full-screen TUI test:** open vim, htop, and tmux; verify CJK/emoji column alignment (unicode11); kill nginx 2 s; confirm the app survives and the screen is **identical, not doubled, not blank** on reattach; resize the window during the drop and confirm reflow via SIGWINCH.
- **Reconnect test:** drop and restore the WS repeatedly with backoff; verify the "reconnecting in N s" UI, manual reconnect, status badge from socket state; verify `exit` renders `process exited (code N)` and idle/max-duration kills render their reason banner.
- **Security test:** revoke RBAC while a session is detached, then reattach → denied; confirm dual NodeID ownership re-checked on reattach; if `0x02` is kept, confirm the signal action is audited.
- **E2E (gstack/Playwright):** full open→interact→drop→reattach→close flow on metix-hk; CJK locale; clickable links; search over 10k scrollback; mobile Canvas fallback reachable.

---

## 8. Notes on critic issues judged invalid or already covered

- **"0x10 conflates first-byte-tagged with separate text frame"** — valid and folded in: control is a separate **binary** frame with a high-bit opcode and a universal 1-byte channel tag; no in-band byte on the data plane. No part of this was dismissed.
- **"Signal opcode (`0x02`) duplicates in-band Ctrl-C"** — accepted; the recommendation (D7) is now to **drop `0x02` by default**, since in-band stdin already covers the common case and a relayed signal cannot be audited. Kept only as an explicitly-scoped, server-mediated, audited option.
- No critic issue was found to be invalid; all 19 (1 critical, 7 high, 7 medium, 4 low across the two lenses) are addressed in the architecture, phasing, or test plan above.

## 9. Implementation status (as-built, 2026-06-24)

Phases 0–3 implemented and verified locally (build + vet + `-race` tests green); poll remains the production default throughout. Decisions applied: stream-default-via-lever cutover (D1); detach 45s / idle 30m / max-life 8h (D2); `0x02` signal opcode dropped (D7); agent-side offset ring replay, skip addon-serialize (D4); WebGL→DOM renderer — **addon-canvas omitted because it is not xterm-6 compatible** (peers on `^5`), DOM is the universal fallback (D5); per-write deadline + TCP backpressure, ACK windowing deferred (D6); tab-strip/recording deferred (D8).

**Server (`lattice-server`)** — `websocketx/safe_conn.go`: `SetWriteWait` per-write deadline. `server_terminal_stream.go`: ping/pong keepalive + write deadlines on both bridge legs (`keepAliveLeg`); `attachBrowser` returns `bridged` + `onBridge` hook. `server_terminal.go`: `detachedAt`/`bridged` session state; `markDetached`/`clearDetached`/`reap`; `pruneLocked` rewrite (detach grace + bridged-exempt idle + max-life); `startTerminalReaper` (5s) wired in `New()`; attach handler does detach-not-close + closed-session short-circuit (clean 1000). Tests: `TestTerminalBrokerDetachGraceReaped`, `TestTerminalBrokerBridgedExemptFromIdle`.

**Agent (`lattice-node-agent`)** — `terminal.go` slimmed to poll + shared dispatcher; new `terminal_stream.go`: `outputRing` + `streamSink` (offset replay), restructured `runStream` (long-lived PTY reader + redial w/ backoff + idle/max watchdog), `serveStreamConn`, `pumpInput` (+`0x04` resume), `finishStream`, transport-override atomic. `websocketx.go`: `SetWriteWait`. `main.go`: `applyAgentConfig` honors server transport override. Tests: `terminal_stream_test.go` (ring eviction, exact-tail replay, gap notice, detach).

**Dashboard (`lattice-dashboard`)** — added `@xterm/addon-webgl@0.19`, `addon-unicode11@0.9`, `addon-web-links@0.12`, `addon-search@0.16`. `XtermSession.vue`: WebGL renderer (DOM fallback, context-loss recovery), `allowProposedApi:true`+unicode11, web-links, find bar, `bytesRendered` offset + `0x04` resume on (re)open, bracketed-paste/multiline guard, clipboard-error surfacing, reconnect overlay (countdown + manual reconnect). `TerminalView.vue`: status-vocabulary fix (`active`→`open`).

**SDK (`lattice-sdk`)** — `AgentConfig.TerminalTransport` + `Node.TerminalTransport`; lever endpoint `POST /api/nodes/terminal-transport` (`node:admin`). Production rollout requires an SDK tag bump + agent `go.mod` bump (standalone agent CI); local builds use the workspace.

**Wire protocol delta from §4:** the agent→browser control frame (`0x10` exit) was **not** implemented for v1 — the server relay concatenates frames so reliable agent→browser framing needs a protocol-aware bridge (out of scope). Process-exit is instead surfaced via the agent's explicit `status=closed` POST + the server's closed-session short-circuit (clean WS 1000). Only the browser→agent opcodes (`0x00`/`0x01`/`0x04`) are on the wire.

**Remaining:** Phase 4 (canary→fleet flip→stream default) and Phase 5 (delete poll) per the plan.
