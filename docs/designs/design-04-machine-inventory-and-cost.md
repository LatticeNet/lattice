# Design 04 — Machine Inventory + Cost / Renewal Management

> Status: design (pre-implementation). Author target: the operator builds against this directly.
> Scope owner: `lattice-server` (core provider) + `lattice-node-agent` (fact collection) + `lattice-sdk/model` + `lattice-dashboard`.
> Constraints inherited: pure Go, **zero CGo**, tiny dep surface (new external dep ⇒ ADR), security-first, fail-closed, audit everything.

This feature has **two halves with very different trust models**, and the design keeps them separate on purpose:

- **Half A — auto-detected static facts** (CPU cores, RAM total, arch, OS/platform, kernel, boot time): *node-reported*, low-trust, advisory. The agent already reports `model.Metrics`; we extend the hello/metrics envelope with a `host` block. No new privileges, no apply flow.
- **Half B — cost / vendor / renewal** (price, currency, cycle, next renewal date, console/detail links, reminders): *operator-authored server-side metadata*, never touched by the agent, never sent to a node. This is pure control-plane state plus a server-side reminder scheduler reusing `internal/notify`.

The mental model: **Half A describes the machine; Half B describes the contract you signed for it.** A compromised node can lie about Half A and can never see or influence Half B.

---

## 1. Goal & scope

### Goal
Give the operator a single fleet view that answers, per machine:
1. *What is this box?* — cores, RAM, arch (arm64/amd64), OS/platform, kernel, uptime/boot time, hostname, virtualization hint. **Auto-detected**, no manual entry.
2. *Where did it come from and what does it cost?* — cloud vendor, a console/connection link, a location/detail link, price + currency, renewal cycle (monthly/quarterly/semiannual/annual/custom-days), and the **next renewal date**. **Operator-entered.**
3. *When do I need to act?* — fire renewal-reminder notifications N days before the next renewal date (configurable), through the existing notify channels (Telegram/Bark/Discord/webhook), and let the operator mark a cycle "renewed" so the date rolls forward.

This directly serves the operator's stated needs: per-machine vendor/cost/renewal tracking with reminders, node naming like `gmami-jp1`, and a richer fleet/map surface (the map itself is Design-05 territory; this design supplies the **facts** the map renders).

### Non-goals for v1 (explicit)
- **No automated billing integration / vendor API scraping.** Cost data is operator-entered. No screen-scraping cloud consoles, no provider billing APIs. (Listed as a v3+ open question only.)
- **No currency conversion / FX.** Each machine stores its own `currency` string; the dashboard sums per-currency, it does not convert. (Avoids an FX rate dependency + ADR.)
- **No auto-renew actions.** Lattice never *performs* a renewal (no payment, no vendor calls). It *reminds*; the human renews and clicks "renewed."
- **No per-fact apply/plan flow.** Auto-detected facts are advisory telemetry, not a node mutation. (Cost metadata is server-only, also no apply.) This feature **does not use plan→approve→apply** — see §2 for why that is correct, and contrast with the *separate* per-node nft access-rule feature which does.
- **No historical cost time-series / spend analytics.** v1 stores the current contract only. Spend history is a later phase.
- **No hard dependency on bbolt.** Lives in the existing JSON `State` like every other collection; migrates for free when Phase C cuts over.

---

## 2. System fit

| Lattice concept | How this feature uses it |
|---|---|
| **Server = sole policy point** | All cost/renewal/vendor metadata lives only in server `State`. The reminder scheduler is a server goroutine. The agent is never told anything about cost. |
| **Agent = least-trust executor that polls** | Agent *adds* read-only host-fact collection to its existing hello/metrics POSTs. No new inbound surface, no new privileges, no new task type. |
| **plan → approve → apply** | **Deliberately NOT used.** That flow exists to gate *node mutations* an operator must review before they hit a box. Auto-detected facts mutate nothing on the node; cost metadata mutates nothing anywhere but the server DB. Forcing an approval here would be ceremony with no blast radius to gate. (The operator's separate request — per-node nft deny rules — *does* belong in plan→approve→apply and is out of scope here; it reuses `internal/network/nft`.) |
| **Store (single encrypted JSON `State`)** | One new collection `MachineProfiles map[string]model.MachineProfile`. Host facts attach to the existing `model.Node` (no new collection needed for Half A). |
| **`internal/store/crypto.go` at-rest boundary** | Cost data is sensitive-ish (vendor account hints) but the genuinely secret fields are the **console/connection links and any embedded credentials/tokens in them**. Those route through the crypto boundary (§3, §7). Plain numbers (price, cycle) are not encrypted. |
| **RBAC (scopes + per-node allowlist)** | New scopes `inventory:read` / `inventory:admin`, enforced per-node via the existing `rbac.Allows(principal, scope, nodeID)` + `requireNodeScope` helpers — identical to how DDNS gates by `node_id`. Host facts piggyback on `node:read`. |
| **`internal/notify` + fan-out dispatcher** | Renewal reminders are `notify.Message`s fanned out to every enabled channel via the existing `notifyAll`-style goroutine pattern. **Zero new notification code** beyond composing the message. |
| **Audit (hash-chained WAL)** | Every cost mutation, every "mark renewed," and every reminder fire is an audit event (`inventory.*`, `inventory.reminder`). |

### CORE-provider vs plugin — decision: **CORE server-owned provider.**
Rationale, in the same spirit as DDNS/notify being core:
- It reads and writes **first-class server state** (`model.Node`, a new `model.MachineProfile`) and the **audit WAL** — exactly the handles the plugin broker deliberately does *not* expose (broker surfaces are kv/notify/http-egress/log only).
- It drives the **notify fan-out** and a **server lifecycle goroutine** (the scheduler). Plugins don't get to register background schedulers.
- It extends the **agent wire protocol** (`agentAuthRequest`/metrics envelope) — a protocol change is core SDK work, not a plugin concern.
- There is no third-party-extensibility story here; this is fleet bookkeeping the control plane owns.

A plugin could *later* consume this (e.g. a "cost report to Slack weekly" plugin calling `notify:send`), but the inventory/cost capability itself is core, alongside ddns and monitor.

---

## 3. Data model

All additions go in `lattice-sdk/model/model.go` (shared wire model) so server, agent, and dashboard agree. New scopes are server-side strings.

### 3.1 Half A — host facts on `model.Node`
Add a `HostFacts` block to `model.Node` (kept distinct from the live, fast-changing `Metrics`). These are *static-ish*: they change only on reboot/resize, so they ride the `hello` and occasionally on `metrics`, and the server stores the last-reported snapshot.

```go
// HostFacts are auto-detected, slow-changing machine facts reported by the agent.
// They are advisory (node-reported, low-trust): never use them for an authorization
// decision. Distinct from model.Metrics, which is the fast-changing live sample.
type HostFacts struct {
	Hostname     string    `json:"hostname,omitempty"`
	OS           string    `json:"os,omitempty"`            // runtime.GOOS: "linux", ...
	Platform     string    `json:"platform,omitempty"`      // distro id, e.g. "debian", "alpine" (from /etc/os-release ID)
	PlatformVer  string    `json:"platform_version,omitempty"` // os-release VERSION_ID
	KernelVer    string    `json:"kernel_version,omitempty"` // uname -r equivalent via syscall.Uname
	Arch         string    `json:"arch,omitempty"`          // runtime.GOARCH: "amd64", "arm64", ...
	CPUCores     int       `json:"cpu_cores,omitempty"`     // logical cores (runtime.NumCPU / nproc)
	CPUModel     string    `json:"cpu_model,omitempty"`     // /proc/cpuinfo "model name" (first), best-effort
	MemoryTotal  uint64    `json:"memory_total,omitempty"`  // bytes; mirrors Metrics.MemoryTotal but pinned here
	SwapTotal    uint64    `json:"swap_total,omitempty"`    // bytes
	Virtualization string  `json:"virtualization,omitempty"` // best-effort hint: "kvm","vmware","lxc","docker","none","unknown"
	BootTime     time.Time `json:"boot_time,omitempty"`     // derived: now - uptime, UTC
	ReportedAt   time.Time `json:"reported_at,omitempty"`   // when the agent collected this
}
```

Add one field to `model.Node`:
```go
type Node struct {
	// ... existing fields ...
	Metrics   Metrics   `json:"metrics"`
	HostFacts HostFacts `json:"host_facts"` // NEW: last-reported static facts
	CreatedAt time.Time `json:"created_at"`
}
```
No new store collection for Half A — it lives inside the existing `Nodes` map, updated through the existing `UpsertNode` / `UpdateMetrics` paths.

### 3.2 Half B — `model.MachineProfile` (new collection)
One profile per node (1:1, keyed by `NodeID` is the natural choice; but to allow a profile to exist *before* a node enrolls and to survive node deletion for record-keeping, key it by its own `ID` and reference `NodeID`). 1:1 is enforced at the handler (reject a second profile for the same node).

```go
const (
	RenewalCycleMonthly    = "monthly"
	RenewalCycleQuarterly  = "quarterly"
	RenewalCycleSemiannual = "semiannual"
	RenewalCycleAnnual     = "annual"
	RenewalCycleCustomDays = "custom_days" // uses CycleDays
)

// MachineProfile is operator-authored inventory + cost/renewal metadata for a
// node. It is server-only control-plane state: it is NEVER sent to an agent and
// NEVER influences a node-side decision. Secret-bearing link fields are encrypted
// at rest via internal/store/crypto.go.
type MachineProfile struct {
	ID     string `json:"id"`
	NodeID string `json:"node_id"`           // bound node; 1:1
	Label  string `json:"label,omitempty"`   // operator display label, defaults to node name

	// Vendor / provenance
	Vendor      string `json:"vendor,omitempty"`       // free text, e.g. "BandwagonHost", "DMIT", "Vultr"
	ConsoleURL  string `json:"console_url,omitempty"`  // SECRET-AT-REST: connection/console link (may embed tokens)
	DetailURL   string `json:"detail_url,omitempty"`   // SECRET-AT-REST: machine location/detail link
	Region      string `json:"region,omitempty"`       // free text, e.g. "JP-Tokyo"
	Notes       string `json:"notes,omitempty"`        // operator notes (not secret-encrypted; keep secrets out)

	// Cost
	PriceCents  int64  `json:"price_cents,omitempty"`  // integer minor units; avoids float money bugs
	Currency    string `json:"currency,omitempty"`     // ISO 4217 string, e.g. "USD","CNY","EUR" (no conversion done)

	// Renewal
	RenewalCycle string    `json:"renewal_cycle,omitempty"` // one of the RenewalCycle* consts
	CycleDays    int       `json:"cycle_days,omitempty"`    // only when RenewalCycleCustomDays
	NextRenewal  time.Time `json:"next_renewal,omitempty"`  // date (UTC, day-granularity) the contract next renews
	AutoRoll     bool      `json:"auto_roll"`               // when an operator marks renewed, advance NextRenewal by one cycle

	// Reminder policy
	RemindDaysBefore []int     `json:"remind_days_before,omitempty"` // e.g. [14,7,1]; fire a reminder at each offset
	RemindersEnabled bool      `json:"reminders_enabled"`
	LastRemindedKey  string    `json:"last_reminded_key,omitempty"`  // idempotency cursor (see §6.3); not operator-set

	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}
```

**Money is stored as integer minor units (`PriceCents int64`)** — never a float. The dashboard formats with the currency.

### 3.3 Secret-at-rest fields (route through `internal/store/crypto.go`)
Encrypt **`ConsoleURL`** and **`DetailURL`**. They frequently embed one-time login tokens, signed console URLs, or account-identifying query params; treating them as cleartext in the state file would defeat the at-rest boundary. Everything else in `MachineProfile` (price, cycle, vendor name, notes) is non-secret and stays plaintext for diffability.

To wire this, follow the existing DDNS/notify recipe exactly:
1. Add a `MachineProfiles map[string]model.MachineProfile` field to `store.State` (with a `json:"machine_profiles"` tag).
2. In `crypto.go`: add `encryptMachineProfileRecord` / `decryptMachineProfileRecord` (encrypt `ConsoleURL`, `DetailURL`), call them in both `encryptedState` and `decryptState` ranges, and extend **`stateHasEnvelope`** to check `secret.IsEnvelope(mp.ConsoleURL) || secret.IsEnvelope(mp.DetailURL)`. The header comment in `crypto.go` explicitly instructs: *"When adding a new persisted credential, encrypt it here AND extend stateHasEnvelope."* Honor that or the lost-key guard goes stale.
3. The bbolt path calls the same per-record helpers (already the pattern), so no extra work there.

`HostFacts` are **not** encrypted — they are non-secret machine descriptors and need to be diffable/queryable.

---

## 4. Server API

New handlers go in a new file **`internal/server/server_inventory.go`** (server.go is large; this matches the existing `server_oidc.go` split convention). Routes are registered in `server.go`'s mux block alongside the others.

New RBAC scopes: **`inventory:read`**, **`inventory:admin`**. Per-node enforcement reuses `requireNodeScope(w, p, scope, nodeID)` and `rbac.Allows(p.Principal, scope, nodeID)` exactly as DDNS does — a token scoped to specific nodes only sees/edits those machines' profiles.

| Method | Path | Scope | Request | Response |
|---|---|---|---|---|
| `GET` | `/api/machines` | `inventory:read` | — | `[]machineView` — joins each node's `HostFacts` + its `MachineProfile` (cost view), filtered to nodes the principal may read. Secret link fields are **redacted to a boolean `has_console_url`/`has_detail_url`**, never the value. |
| `POST` | `/api/machines` | `inventory:admin` | `model.MachineProfile` (no ID) | created `machineView`. Validates: `node_id` exists, no existing profile for that node (1:1), `currency` non-empty if `price_cents>0`, `renewal_cycle` is a known const, `cycle_days>0` iff custom, `remind_days_before` are non-negative. Computes `NextRenewal` if omitted? No — require it explicitly to avoid guessing. |
| `POST` | `/api/machines/update` | `inventory:admin` | `model.MachineProfile` (with ID) | updated `machineView`. Same validation. Secret link fields are **write-only**: an empty string means "leave unchanged"; a sentinel like `""`+explicit `clear_console_url:true` clears it (mirrors OIDC client-secret write-only handling). |
| `POST` | `/api/machines/delete` | `inventory:admin` | `{id}` | `{ok:true}` |
| `POST` | `/api/machines/renew` | `inventory:admin` | `{id, next_renewal?}` | updated `machineView`. Marks the current cycle renewed: sets `NextRenewal` to the supplied date, or if absent and `AutoRoll`, advances by one cycle from the old `NextRenewal`; resets `LastRemindedKey`. Emits `inventory.renew` audit. |
| `POST` | `/api/machines/reminders/run` | `inventory:admin` | `{id?}` | `{fired:[...]}` — manual trigger of the reminder evaluation (for one profile or all). Mirrors `/api/ddns/run` giving inline outcome; useful for testing channels. |

There is **no agent-facing endpoint** for Half B. Half A needs no new endpoint either — it extends the existing `agentAuthRequest` envelope on `/api/agent/hello` and `/api/agent/metrics` (§5).

`machineView` (response DTO, built by a `toMachineView` like `toDDNSView`):
```go
type machineView struct {
	ID            string             `json:"id"`
	NodeID        string             `json:"node_id"`
	NodeName      string             `json:"node_name"`
	Label         string             `json:"label,omitempty"`
	Online        bool               `json:"online"`
	HostFacts     model.HostFacts    `json:"host_facts"`
	Vendor        string             `json:"vendor,omitempty"`
	Region        string             `json:"region,omitempty"`
	HasConsoleURL bool               `json:"has_console_url"`
	HasDetailURL  bool               `json:"has_detail_url"`
	Notes         string             `json:"notes,omitempty"`
	PriceCents    int64              `json:"price_cents,omitempty"`
	Currency      string             `json:"currency,omitempty"`
	RenewalCycle  string             `json:"renewal_cycle,omitempty"`
	CycleDays     int                `json:"cycle_days,omitempty"`
	NextRenewal   time.Time          `json:"next_renewal,omitempty"`
	DaysUntil     int                `json:"days_until_renewal"` // computed; negative = overdue
	AutoRoll      bool               `json:"auto_roll"`
	RemindDaysBefore []int           `json:"remind_days_before,omitempty"`
	RemindersEnabled bool            `json:"reminders_enabled"`
	UpdatedAt     time.Time          `json:"updated_at"`
}
```
The console/detail URLs are **never** in any list/read response. A dedicated `POST /api/machines/reveal {id, field}` (scope `inventory:admin`, audited as `inventory.reveal`) returns one decrypted link for an explicit operator click — same posture as never returning notify/DDNS secrets in the list, but allowing a deliberate, audited reveal so the link stays usable. (If you prefer maximum simplicity for MVP, omit reveal and let the operator keep links in a password manager; see §8.)

---

## 5. Agent responsibilities

The agent gains **one** new responsibility: collect static host facts and include them in the hello/metrics envelope. No new task type, no new endpoint, no apply contract — host facts are pure read-only telemetry.

### 5.1 New package `internal/hostfacts` in `lattice-node-agent`
A sibling of `internal/metrics`, same dependency-free, `/proc`+syscall approach (the existing `metrics.go` already reads `/proc/meminfo`, `/proc/uptime`, `runtime`, and `syscall.Statfs` — reuse that style).

```go
package hostfacts

// Collect returns slow-changing machine facts. Pure stdlib + /proc + syscall.Uname.
// Best-effort: any field that can't be read is left zero — never fatal.
func Collect() model.HostFacts
```
Sources (all zero-CGo, Linux-first, degrade gracefully elsewhere):
- `Hostname` → `os.Hostname()`
- `OS` → `runtime.GOOS`; `Arch` → `runtime.GOARCH`
- `CPUCores` → `runtime.NumCPU()`
- `CPUModel` → first `model name` line of `/proc/cpuinfo` (best-effort)
- `MemoryTotal`/`SwapTotal` → `/proc/meminfo` (`MemTotal`, `SwapTotal` ×1024)
- `KernelVer` → `syscall.Uname` `Release` (Linux; empty elsewhere — build-tag the uname bit like taskexec splits `_linux.go`/`_other.go`)
- `Platform`/`PlatformVer` → parse `/etc/os-release` `ID` / `VERSION_ID`
- `Virtualization` → best-effort: presence of `/proc/vz`, `/.dockerenv`, `systemd-detect-virt` output if on PATH, or `hypervisor` flag in `/proc/cpuinfo`; default `"unknown"`. Keep it cheap and non-fatal.
- `BootTime` → `now - uptime` using the existing `readUptime()` value (export it or recompute)

### 5.2 Reporting
- On **`hello`** (startup): include the full `host_facts` block. Facts are most useful immediately and rarely change.
- On **`metrics`** (periodic poll): include `host_facts` too, but the agent **may** send it only every Nth tick (e.g. once an hour) to keep the envelope small — facts are slow-changing. Simplest correct MVP: send every time; the payload is tiny. Optimize later.

Wire it into `main.go` exactly like the existing metadata map: extend the `postAgentJSON(cfg, "/api/agent/hello", map[string]any{...})` payload with `"host_facts": hostfacts.Collect()`, and the `reportMetrics` map likewise.

### 5.3 Server-side ingestion
Extend `agentAuthRequest` with `HostFacts model.HostFacts \`json:"host_facts"\``. In `handleAgentHello` and `handleAgentMetrics`, after authenticating the node, set `n.HostFacts = req.HostFacts` (stamp `ReportedAt`/`BootTime` server-side from `now` if the agent left them zero), then `UpsertNode`. **Validate/clamp** before storing (§7): cap string lengths, reject absurd values, never trust them for authz.

### 5.4 Apply-task contract
**None.** This feature intentionally has no agent apply task. If a future sub-feature wanted the agent to *act* (it doesn't here), it would route through the existing `plan→approve→apply` task queue — but inventory/cost never mutates a node.

---

## 6. Config rendering / external integration

Half A renders nothing on the node. Half B's only "external integration" is **outbound notifications** (already built) and an **internal scheduler**. There are no config files, no nft rules, no CF DNS records emitted by this feature.

### 6.1 The reminder scheduler (server goroutine)
A single server-owned ticker goroutine, started in the server constructor next to the other background workers (the DDNS retry path and notify dispatch already establish the `go func(){...}` + `context.WithTimeout` idiom). Pattern:

```go
// startRenewalScheduler runs one evaluation pass on a coarse interval (default
// hourly). Reminders are date-granular, so sub-hour precision is unnecessary and
// hourly keeps wakeups negligible even at 10k nodes.
func (s *Server) startRenewalScheduler(ctx context.Context) {
	t := time.NewTicker(s.reminderInterval) // default 1h; configurable
	go func() {
		s.evaluateReminders(time.Now().UTC()) // run once at boot
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				s.evaluateReminders(time.Now().UTC())
			}
		}
	}()
}
```

### 6.2 `evaluateReminders(now)`
For each `MachineProfile` where `RemindersEnabled && !NextRenewal.IsZero()`:
1. `days := daysUntil(now, NextRenewal)` (calendar-day difference, both truncated to UTC date).
2. For each configured offset `d` in `RemindDaysBefore` (sorted desc), if `days <= d` and this offset for this renewal date hasn't fired yet (see idempotency cursor §6.3), fire one reminder and advance the cursor.
3. Also fire an **overdue** reminder when `days < 0` and overdue hasn't been signaled for this renewal date.

Each fire builds a `notify.Message` and uses the **existing** fan-out goroutine (the same code path `notifyAll`/the `go func(){ ...NewDispatcher(built...).Send... }` block at server.go:2208) — no new notify code:
```
Title: "Lattice renewal due in 7d: gmami-jp1"
Body:  "gmami-jp1 (BandwagonHost, JP-Tokyo) renews 2026-07-01 — $9.90/yr. Mark renewed in the dashboard."
```
Then record an `inventory.reminder` audit event with `{machine_id, node_id, offset_days, next_renewal}`.

### 6.3 Idempotency (don't spam)
Reminders must fire **once per (renewal-date, offset)**, surviving server restarts (state is persisted) and the hourly re-evaluation. Use `LastRemindedKey` as a monotonic cursor string:
```
key = NextRenewal.Format("2006-01-02") + ":" + strconv.Itoa(offsetFired)
```
Store the *smallest offset already fired for the current `NextRenewal`* (offsets fire largest→smallest as the date approaches). A reminder fires only if its offset `<` the last-fired offset for the same date (or none fired yet for this date). When the operator marks the cycle renewed and `NextRenewal` advances, the date component changes and the cursor naturally resets. This is the same "highest-step-wins, single-use" idea the codebase already uses for TOTP replay protection (`User.LastTOTPStep`) — a known, trusted pattern here.

### 6.4 Renewal date roll-forward
On `/api/machines/renew` with `AutoRoll`, advance `NextRenewal` by the cycle:
- monthly → `AddDate(0,1,0)`, quarterly → `AddDate(0,3,0)`, semiannual → `AddDate(0,6,0)`, annual → `AddDate(1,0,0)`, custom → `AddDate(0,0,CycleDays)`.
Anchor on the existing `NextRenewal` (not `now`) so a slightly-late "renewed" click doesn't drift the billing date. Clamp month-end overflow with Go's standard `AddDate` normalization (acceptable; document it).

---

## 7. Security

**Threat framing:** the two halves have asymmetric trust.

### Half A (node-reported facts) — treat as hostile input
- **Never authorize on host facts.** They are advisory display data. No code path may branch on `HostFacts` for access control, task targeting, or anything privileged. (Comment says so on the struct.)
- **Clamp on ingest.** A compromised/malicious agent can send arbitrary `host_facts`. On ingest: cap each string field to a fixed length (e.g. 256 bytes), reject control chars, clamp `CPUCores`/memory to sane ceilings, ignore implausible `BootTime`. The dashboard must HTML-escape them (the strict-CSP vanilla-JS dashboard already does `textContent`, not `innerHTML` — keep that).
- **Blast radius:** worst case a compromised node displays wrong specs in the fleet view. No privilege, no spend, no other node affected.

### Half B (cost metadata) — server-only, operator-authored
- **Authz:** all mutations require `inventory:admin`, all reads `inventory:read`, both **per-node-scoped** via `requireNodeScope`/`rbac.Allows`. A token allowlisted to `gmami-jp1` cannot read `dmit-eb`'s cost or console link.
- **Secret handling:** `ConsoleURL`/`DetailURL` are **encrypted at rest** (§3.3), **never returned** in list/read responses (only `has_*` booleans), and only revealed through an explicit, audited `inventory:admin` `reveal` call (or omitted entirely in MVP). This mirrors the codebase's hard rule that DDNS tokens, notify config, and OIDC client secrets are never serialized back.
- **Fail-closed:** if the master key is absent but encrypted console links exist, startup aborts (the existing `stateHasEnvelope`/`lostMasterKeyError` guard — which is exactly why §3.3 step 2 is mandatory). Unknown `renewal_cycle` → reject the write. Missing `currency` with a price → reject.
- **The agent never receives Half B.** There is no endpoint that hands cost/console data to a node, so a fully compromised node learns nothing about billing or console URLs.
- **Reminder SSRF:** reminders reuse `internal/notify`, whose webhook/Discord channels already go through the `internal/outbound` SSRF-guarded client. No new outbound surface is introduced; this feature only *composes a message*, it doesn't dial anything new.
- **Audit events (all hash-chained WAL):** `inventory.create`, `inventory.update`, `inventory.delete`, `inventory.renew`, `inventory.reveal`, `inventory.reminder` (one per fire, with offset + next_renewal), plus the standard scope/decision fields. Host-fact ingest is high-volume and need not be individually audited (it's part of the normal metrics path), but a *change* in core specs (e.g. cores/RAM doubled — possible VM resize or impersonation) is a good candidate for a low-rate `inventory.facts_changed` audit/notify in v2.

---

## 8. Phasing

Each phase is a shippable, tested, reviewed, committed slice (per the operating cadence: plan → execute(TDD,-race,gofmt) → review → iterate).

### MVP (smallest shippable slice) — "see the fleet + get reminded"
**Half A minimal + Half B core + reminders, no reveal.**
- SDK: `HostFacts`, add to `Node`; `MachineProfile` (+cycle consts).
- Agent: `internal/hostfacts.Collect()` (hostname/os/arch/cores/mem/kernel/boot; virtualization = "unknown" is fine), wire into hello+metrics.
- Server: store collection + crypto wiring (console/detail encrypted) + `stateHasEnvelope` extension; `server_inventory.go` with `GET/POST/update/delete/renew`; ingest host facts in hello/metrics with clamping; reminder scheduler + `evaluateReminders` + idempotency cursor; `inventory.*` audit.
- Dashboard: a **Machines** panel (table): node name, online dot, arch/cores/RAM, vendor, price+currency, next renewal + `days_until` (color: red overdue, amber ≤7d), and an edit form. Console/detail shown as `has_*` badges only (no reveal yet — link lives in operator's password manager).
- **Exit bar:** an operator can add cost/renewal data to `gmami-jp1`, the dashboard shows auto-detected specs, and a reminder fires through an existing Telegram/Bark channel N days before renewal, exactly once per offset; `go test -race ./...` + gofmt + dashboard green; independent security review of the crypto-field wiring + host-fact clamping.

### v2 — "polish + reveal + safety signals"
- `POST /api/machines/reveal` (audited single-link decrypt) + write-only update semantics for links.
- `Virtualization` best-effort detection; `CPUModel`.
- `inventory.facts_changed` low-rate audit/notify when core specs change between reports (cheap drift/impersonation signal).
- Dashboard: per-currency cost totals (no FX), grouping by vendor/region, "Mark renewed" button calling `/renew`, overdue filter.
- Configurable `reminderInterval` and global default `RemindDaysBefore`.
- **Exit bar:** reveal is audited and rate-aware; cost rollups are correct per-currency; renew-and-roll works end-to-end.

### Later (v3+)
- Spend history / time-series (a new append-capped collection like monitor results) and a monthly cost trend.
- Feed `HostFacts`+`Region` into the **nezha-style global map** (Design-05) — this design is the data source; the map renders it.
- Optional: per-machine tags driving the separate per-node nft access-rule feature (out of scope here, plan→approve→apply).
- (Open) read-only vendor billing-API ingestion behind an ADR per provider.

---

## 9. Risks & open questions

1. **Reveal vs. don't-store-links.** Storing console URLs (even encrypted) puts credential-bearing links in the state file. Mitigation: encrypted-at-rest + never-in-list + audited reveal. *Open:* is the convenience worth it, or should MVP store only a non-secret vendor name + region and keep links in a password manager? Recommendation: MVP stores links **encrypted but no reveal endpoint** (badge only); add reveal in v2 once the audit/rate story is reviewed.
2. **Host-fact trust.** A compromised node can spoof specs. Accepted: facts are advisory, clamped, never authz. *Open:* should a sudden core/RAM change raise an alert? → v2 `facts_changed`.
3. **Idempotency across restart + clock skew.** Date-granular reminders + the persisted `LastRemindedKey` cursor handle restarts. *Open:* server timezone — store/compute everything in UTC, display in the operator's locale on the dashboard; document that "days before" is UTC-date arithmetic.
4. **1:1 node↔profile.** Enforced at handler. *Open:* a machine that hosts multiple billed services? Out of scope — one box, one contract in v1.
5. **Currency without FX.** Per-currency sums only. Accepted non-goal; avoids an FX dependency/ADR.
6. **Month-end roll-forward drift** (`AddDate` normalizes Jan-31 + 1mo → Mar-03 in non-leap). Document; anchor on `NextRenewal` not `now`; operators can hand-correct via `/renew {next_renewal}`.
7. **Scheduler at scale.** Hourly full scan of profiles is O(nodes) per hour — trivial at 10k. No index needed in v1.

---

## 10. What to borrow vs avoid from the reference panels

From the **nezha** research (machine facts + map reference):
- **Borrow — the host-fact set.** nezha's per-machine card shows platform/OS, arch, CPU model + cores, total memory/swap, boot time/uptime, and a virtualization hint. Mirror that exact set in `HostFacts` — it's the proven "what is this box" vocabulary self-hosters expect, and it's all cheap to read from `/proc`+`uname` with zero CGo.
- **Borrow — facts ride the agent report, server stores the snapshot.** nezha's agent pushes static info on connect and refreshes periodically; we already have hello (connect) + metrics (periodic), so we slot facts into both with hello carrying the authoritative first snapshot. This is the minimal-surface path.
- **Borrow — the map consumes facts + a location field.** nezha derives map placement from geo/region. We add a free-text `Region` now and leave the map (geo lookup, rendering) to Design-05; this design just guarantees the field exists. Avoid bundling a GeoIP database (CGo/`mmdb` dep + ADR) into this slice.
- **Avoid — nezha's agent-trusts-itself posture for anything privileged.** nezha treats agent-reported data as ground truth for display, which is fine; but Lattice's bar is higher: we explicitly forbid authz on facts and clamp them on ingest. Keep nezha's *display* model, reject its *trust* model anywhere a decision is made.
- **Avoid — nezha's billing/expiry fields living on the agent-reported object.** Some nezha forks staple "expire date / price" onto the same server-config-but-node-adjacent record. We **separate** Half B into a server-only `MachineProfile` so cost/console data is structurally unreachable from the node path. That separation is the single most important "avoid" — it's what makes a compromised node blind to billing.

From **Lattice's own subsystems** (the strongest reference panel):
- **Borrow DDNS wholesale as the template:** CRUD handler shape, `node_id`-scoped RBAC via `requireNodeScope`, secret-field-never-returned, eager validation on POST, `toXView` DTO, and the at-rest crypto wiring + `stateHasEnvelope` extension. Inventory is "DDNS for money."
- **Borrow notify's fan-out + the existing `go func(){…Dispatcher.Send…}` goroutine** for reminders — do not write a second notification path.
- **Borrow TOTP's `LastTOTPStep` single-use cursor idea** for reminder idempotency.
- **Avoid inventing a plan/approve/apply flow here** (it has no node blast radius) and **avoid making this a plugin** (it needs core store + audit + scheduler handles the broker doesn't grant).

---

## 11. Dev guide — ordered build checklist

Follow the project cadence: write the iteration doc first, then TDD each slice, `-race`+gofmt+dashboard green before "done," independent review, then commit. Build with `GOWORK` set (multi-repo `go.work`).

**Step 0 — Plan.** Write `lattice/docs/iterations/iter-NNN-machine-inventory-and-cost.md` (goal, scope = MVP from §8, risks from §9, test plan, exit bar). Add an ADR only if you end up reaching for a new dependency (you should not — everything here is stdlib + existing packages).

**Step 1 — SDK model (`lattice-sdk/model/model.go`).**
- Add `HostFacts` struct; add `HostFacts` field to `Node`.
- Add `MachineProfile` struct + `RenewalCycle*` consts.
- Update `proto_contract_test.go` expectations for the new fields.
- `go test ./...` in `lattice-sdk`.

**Step 2 — Store collection (`lattice-server/internal/store/store.go`).**
- Add `MachineProfiles map[string]model.MachineProfile \`json:"machine_profiles"\`` to `State`; init it in the State constructor/zero-fill path.
- Add helpers mirroring DDNS: `MachineProfiles()`, `MachineProfile(id)`, `MachineProfileForNode(nodeID)`, `UpsertMachineProfile`, `DeleteMachineProfile`.
- Add bbolt record APIs if the bbolt store enumerates collections (match the DDNS entry).

**Step 3 — At-rest crypto (`lattice-server/internal/store/crypto.go`).**
- Add `encryptMachineProfileRecord` / `decryptMachineProfileRecord` (encrypt `ConsoleURL`, `DetailURL`).
- Range over `MachineProfiles` in both `encryptedState` and `decryptState`.
- Extend `stateHasEnvelope` with the two fields. **Do not skip this.**
- Add a round-trip + lost-key-guard test (copy the DDNS crypto test).

**Step 4 — Agent host facts (`lattice-node-agent/internal/hostfacts/`).**
- `hostfacts.go` (cross-platform bits) + `hostfacts_linux.go` / `hostfacts_other.go` for `syscall.Uname` (build-tag split like `taskexec`).
- `Collect() model.HostFacts`, table-driven tests for the pure parsers (os-release, cpuinfo, meminfo) using fixture strings — no real `/proc` in tests (mirror `metrics_test.go`'s `cpuBusy` pure-function testing).
- Wire into `cmd/lattice-agent/main.go`: add `"host_facts": hostfacts.Collect()` to the hello payload and to `reportMetrics`.

**Step 5 — Agent ingest (`lattice-server/internal/server/server.go`).**
- Add `HostFacts model.HostFacts \`json:"host_facts"\`` to `agentAuthRequest`.
- In `handleAgentHello` and `handleAgentMetrics`, after auth: clamp facts (`sanitizeHostFacts`), stamp `ReportedAt`/`BootTime` if zero, set `n.HostFacts`, `UpsertNode`.
- Add `sanitizeHostFacts` (length caps, control-char strip, numeric ceilings) + tests in `server_agent_security_test.go`.

**Step 6 — Inventory API (`lattice-server/internal/server/server_inventory.go`, NEW).**
- `handleMachines` (GET list / POST create), `handleMachineUpdate`, `handleDeleteMachine`, `handleMachineRenew`, `handleMachineRemindersRun`, (v2) `handleMachineReveal`.
- `toMachineView` joining node + profile, redacting secret links to `has_*` and computing `days_until_renewal`.
- Validation helpers (`validateMachineProfile`): cycle const, currency-with-price, custom-days, remind offsets.
- Register routes in `server.go` mux:
  ```go
  mux.HandleFunc("/api/machines", s.withAuth("inventory:read", s.handleMachines))            // GET list / POST create gated inside
  mux.HandleFunc("/api/machines/update", s.withAuth("inventory:admin", s.handleMachineUpdate))
  mux.HandleFunc("/api/machines/delete", s.withAuth("inventory:admin", s.handleDeleteMachine))
  mux.HandleFunc("/api/machines/renew", s.withAuth("inventory:admin", s.handleMachineRenew))
  mux.HandleFunc("/api/machines/reminders/run", s.withAuth("inventory:admin", s.handleMachineRemindersRun))
  ```
  (POST create on `/api/machines` re-checks `inventory:admin` inside the handler, as `/api/ddns` does GET vs POST.)
- Add the new scopes to the RBAC scope registry / default admin role.

**Step 7 — Reminder scheduler (`server_inventory.go` + constructor wiring).**
- `startRenewalScheduler(ctx)`, `evaluateReminders(now)`, `daysUntil`, `advanceRenewal`, idempotency cursor logic.
- Reuse the existing notify fan-out helper (`notifyAll`/equivalent) — pass title/body, don't rebuild dispatching.
- Start the scheduler in the server constructor (where other goroutines/tickers start); make `reminderInterval` a field defaulting to 1h, overridable in tests for fast iteration.
- Tests: table-driven `evaluateReminders` with a fake clock + a recording notify sink, asserting fire-once-per-(date,offset), overdue, restart idempotency (re-run same `now`, assert no double fire), and roll-forward.

**Step 8 — Dashboard (`lattice-dashboard`).**
- New **Machines** panel: fetch `GET /api/machines`, render the table (zero-dep vanilla JS, `textContent` only, strict CSP — no inline handlers; wire via `addEventListener`).
- Add/edit form POSTing to the endpoints; "Mark renewed" → `/renew`.
- Color `days_until_renewal` (overdue red / ≤7 amber). Show `has_console_url` as a badge (no value).

**Step 9 — Verify.** `GOWORK=… go test -race ./...` across server + agent + sdk; gofmt/goimports clean; `go vet`; manual dashboard smoke (add a profile, set `next_renewal` 1 day out with `remind_days_before:[1]`, run `/api/machines/reminders/run`, confirm the channel receives it exactly once).

**Step 10 — Review.** Independent adversarial pass (separate context / `code-reviewer` + `security-reviewer`): focus on (a) the crypto-field wiring + `stateHasEnvelope`, (b) host-fact clamping, (c) reminder idempotency across restart, (d) that no endpoint ever returns a console/detail URL in a list. Fix must-fixes with regression tests.

**Step 11 — Commit & iterate.** Conventional commits, small and coherent (`feat: host facts`, `feat: machine cost profiles`, `feat: renewal reminder scheduler`, `feat: machines dashboard panel`). Record outcome + residuals in the iteration doc; update PRODUCT-VISION if this lands a roadmap item.
