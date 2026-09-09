# Design 16 sub-project 1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve plugin-produced subscription content from a core-owned, unauthenticated `/sub/<slug>/<token>` endpoint, so a Sub-Store replacement can distribute to real proxy clients.

**Architecture:** A token resolves to a `SubscriptionShare` record holding a *source*. The core owns the whole public surface — routing, token lookup, slug comparison, rate limiting, audit, headers, cache — and asks the source for content. `core.proxy_user` reuses the existing VLESS-Reality renderer; `plugin` calls one manifest-declared plugin method through the existing invoke path. A new narrow host capability authorizes a plugin to *be* a source; it grants no route, no port and no token access.

**Tech Stack:** Go 1.26 (`lattice-server`, `lattice-plugin-sub-store/system-go`), `lattice-sdk` shared models, bbolt hot store, `stdio-json-v1` plugin runtime, QuickJS-over-wazero embedded engine.

## Global Constraints

- Release order is `sdk → server → plugin` (`lattice-olympus:rules/01 §8`). The SDK model lands and is tagged before any consumer pins it.
- Data migrations are **additive only** (`rules/01 §8`).
- Every persisted record carries `schema_version`; **unknown fields survive a read-modify-write round trip**.
- Branch from fresh `origin/integration`; one branch per task-family; every branch gets a draft PR (`rules/01 §1–2, §8.5`).
- Commit style: imperative, sentence-case, outcome-framed subject, no type prefix (`rules/01 §8.5`).
- A subscription response is **never** an empty body with HTTP 200 (spec §8).
- Audit records `token_sha256`, never a raw token (spec §4).
- Go gates before every commit: `gofmt -l .` empty, `go vet ./...`, `go test -race -cover ./...`. On darwin the `internal/server` package needs `-timeout 30m` — it exceeds the 10-minute default on that platform.

## Correction to the spec this plan carries

Spec §6 places the *last successful remote snapshot* in the bolt hot store. That is wrong and this
plan does not implement it: remote fetching belongs to the plugin, and **a plugin cannot write
bolt**. Each plugin does get a confined, writable, 0700 working directory
(`internal/plugin/system_runner.go:132-133`, `cmd.Dir = workDir` at `:341`), which is the correct
home. Snapshots arrive with sub-project 2 (remote fetch); before relying on that directory, that
sub-project must prove with a test that content written there **survives a re-arm**, since the
runner recreates the directory on start. Spec §6 is amended in Task 0.

## File Structure

**`lattice-sdk`**
- Create `model/subscription_share.go` — `SubscriptionShare`, `ShareSource`, source-kind constants. Model only; no behaviour.

**`lattice-server`**
- Create `internal/store/subscription_share.go` — store accessors, bolt-backed, mirroring the `ProxyUser` pattern.
- Modify `internal/store/crypto.go` — seal/open `SubscriptionShare.Token`.
- Modify `internal/store/bolt_state.go` — new `subscription_shares` bucket + accessors.
- Modify `internal/store/store.go:548-559` — exclude `SubscriptionShares` from `state.json`.
- Create `internal/server/server_subscription_share.go` — path parsing, resolution, source dispatch, failure semantics.
- Create `internal/server/subscription_cache.go` — TTL+LRU output cache keyed on `(share_id, format, ua_class)`.
- Create `internal/server/subscription_ua.go` — bounded User-Agent classification.
- Modify `internal/server/server_proxy.go` — delete `subscriptionTokenFromPath`; move rendering behind the source interface.
- Modify `internal/server/server.go` route table — `/sub/` handler now two-segment.
- Modify `internal/plugin/plugin.go` — register the `subscription:serve` capability.

**`lattice-plugin-sub-store`**
- Create `system-go/subscription_store.go` — definition CRUD over host KV with a self-imposed size cap.
- Create `system-go/subscription_render.go` — the `render` method.
- Modify `system-go/main.go` — dispatch `<pluginID>/subscription`.
- Modify `manifest.json` — declare the interface, its methods and budgets; add `subscription:serve`.

Each core file has one responsibility; `server_proxy.go` shrinks rather than grows, because its
path-parsing and rendering concerns move to files that name them.

---

### Task 0: Amend the spec before building against it

**Files:**
- Modify: `lattice/docs/designs/design-16-substore-native-subscription-platform.md` §6

- [ ] **Step 1: Correct the snapshot home**

Replace the `Last successful remote snapshot` row's home, `bolt hot store`, with:

```
the plugin's confined runtime working directory (`RuntimeDir/<pluginID>`)
```

and append to its rationale cell:

```
The plugin owns fetching and cannot write bolt; the runner gives each plugin a
writable 0700 working directory (`system_runner.go:132-133`, `cmd.Dir` at `:341`).
Sub-project 2 must prove by test that content there survives a re-arm before
relying on it.
```

- [ ] **Step 2: Commit**

```bash
git add docs/designs/design-16-substore-native-subscription-platform.md
git commit -m "Correct the snapshot home: a plugin cannot write bolt

The snapshot is produced by plugin-side fetching, so bolt was never reachable
for it. Each plugin does get a writable confined working directory, which is
where it belongs. Recorded before any code is written against the wrong home."
```

---

### Task 1: The share model in the SDK

**Files:**
- Create: `lattice-sdk/model/subscription_share.go`
- Test: `lattice-sdk/model/subscription_share_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `model.SubscriptionShare`, `model.ShareSource`, `model.ShareSourceCoreProxyUser = "core.proxy_user"`, `model.ShareSourcePlugin = "plugin"`, `model.SubscriptionShareSchemaVersion = 1`.

- [ ] **Step 1: Write the failing test**

```go
package model

import (
	"encoding/json"
	"testing"
)

// Unknown fields must survive a read-modify-write cycle. Without this, a server
// that reads a record written by a newer version silently destroys the fields it
// did not recognize, and the loss is invisible until someone looks for a setting
// that is simply gone.
func TestSubscriptionShareRoundTripPreservesUnknownFields(t *testing.T) {
	raw := []byte(`{"id":"s1","schema_version":1,"slug":"team","token":"t","source":{"kind":"plugin","plugin_id":"p","subscription_id":"sub"},"future_field":"keep me"}`)

	var share SubscriptionShare
	if err := json.Unmarshal(raw, &share); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	share.Slug = "renamed"

	out, err := json.Marshal(share)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var got map[string]any
	if err := json.Unmarshal(out, &got); err != nil {
		t.Fatalf("re-unmarshal: %v", err)
	}
	if got["future_field"] != "keep me" {
		t.Fatalf("unknown field dropped: %v", got)
	}
	if got["slug"] != "renamed" {
		t.Fatalf("edit lost: %v", got)
	}
}

func TestSubscriptionShareSourceKinds(t *testing.T) {
	if ShareSourceCoreProxyUser != "core.proxy_user" {
		t.Fatalf("core source kind = %q", ShareSourceCoreProxyUser)
	}
	if ShareSourcePlugin != "plugin" {
		t.Fatalf("plugin source kind = %q", ShareSourcePlugin)
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-sdk && go test ./model -run TestSubscriptionShare -v`
Expected: FAIL — `undefined: SubscriptionShare`.

- [ ] **Step 3: Implement the model**

```go
package model

import (
	"encoding/json"
	"time"
)

// SubscriptionShareSchemaVersion is the current record shape. Readers must
// tolerate a higher value rather than refuse the record: migrations are additive
// only, so a newer record is readable, and Extra preserves what this version does
// not name.
const SubscriptionShareSchemaVersion = 1

const (
	ShareSourceCoreProxyUser = "core.proxy_user"
	ShareSourcePlugin        = "plugin"
)

// ShareSource names where a share's content comes from. Exactly one kind is set.
type ShareSource struct {
	Kind           string `json:"kind"`
	PluginID       string `json:"plugin_id,omitempty"`
	SubscriptionID string `json:"subscription_id,omitempty"`
	ProxyUserID    string `json:"proxy_user_id,omitempty"`
}

// SubscriptionShare is one publicly reachable subscription URL. Token is the only
// secret; Slug is a label that appears in access logs and is never relied on for
// authorization.
type SubscriptionShare struct {
	ID            string      `json:"id"`
	SchemaVersion int         `json:"schema_version"`
	Slug          string      `json:"slug"`
	Token         string      `json:"token"`
	Source        ShareSource `json:"source"`
	DefaultFormat string      `json:"default_format,omitempty"`
	Enabled       bool        `json:"enabled"`
	CreatedAt     time.Time   `json:"created_at"`
	UpdatedAt     time.Time   `json:"updated_at"`
	RotatedAt     *time.Time  `json:"rotated_at,omitempty"`
	ExpiresAt     *time.Time  `json:"expires_at,omitempty"`

	// Extra holds fields written by a newer schema version. It exists so a
	// rollback cannot silently delete data this version cannot interpret.
	Extra map[string]json.RawMessage `json:"-"`
}

type subscriptionShareAlias SubscriptionShare

func (s *SubscriptionShare) UnmarshalJSON(data []byte) error {
	var alias subscriptionShareAlias
	if err := json.Unmarshal(data, &alias); err != nil {
		return err
	}
	*s = SubscriptionShare(alias)

	var all map[string]json.RawMessage
	if err := json.Unmarshal(data, &all); err != nil {
		return err
	}
	for _, known := range []string{
		"id", "schema_version", "slug", "token", "source",
		"default_format", "enabled", "created_at", "updated_at",
		"rotated_at", "expires_at",
	} {
		delete(all, known)
	}
	if len(all) > 0 {
		s.Extra = all
	}
	return nil
}

func (s SubscriptionShare) MarshalJSON() ([]byte, error) {
	base, err := json.Marshal(subscriptionShareAlias(s))
	if err != nil {
		return nil, err
	}
	if len(s.Extra) == 0 {
		return base, nil
	}
	var merged map[string]json.RawMessage
	if err := json.Unmarshal(base, &merged); err != nil {
		return nil, err
	}
	for k, v := range s.Extra {
		if _, taken := merged[k]; !taken {
			merged[k] = v
		}
	}
	return json.Marshal(merged)
}
```

- [ ] **Step 4: Run the tests**

Run: `cd lattice-sdk && go test ./model -run TestSubscriptionShare -v`
Expected: PASS, both tests.

- [ ] **Step 5: Full gates and commit**

```bash
cd lattice-sdk
gofmt -l . && go vet ./... && go test -race ./...
git add model/subscription_share.go model/subscription_share_test.go
git commit -m "Give a subscription share a shape that survives a rollback

Extra captures fields written by a newer schema version and re-emits them, so a
server reading a record it does not fully understand cannot silently delete the
parts it did not recognize. Additive migration is the release law; this is what
makes it true in the record rather than only in the process."
```

---

### Task 2: Bolt storage and at-rest sealing for shares

**Files:**
- Create: `lattice-server/internal/store/subscription_share.go`
- Test: `lattice-server/internal/store/subscription_share_test.go`
- Modify: `lattice-server/internal/store/bolt_state.go` (bucket list at `:67`)
- Modify: `lattice-server/internal/store/store.go:548-559` (hot-store exclusion)
- Modify: `lattice-server/internal/store/crypto.go` (seal/open Token)

**Interfaces:**
- Consumes: `model.SubscriptionShare` from Task 1.
- Produces: `(*Store).UpsertSubscriptionShare(model.SubscriptionShare) error`, `(*Store).SubscriptionShare(id string) (model.SubscriptionShare, bool)`, `(*Store).SubscriptionShareByToken(token string) (model.SubscriptionShare, bool)`, `(*Store).SubscriptionShares() []model.SubscriptionShare`, `(*Store).DeleteSubscriptionShare(id string) error`.

- [ ] **Step 1: Write the failing test**

```go
package store

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/LatticeNet/lattice-sdk/model"
)

func TestSubscriptionShareTokenIsSealedOnDisk(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state.json")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	const token = "plaintext-token-value-must-not-appear"
	if err := s.UpsertSubscriptionShare(model.SubscriptionShare{
		ID: "share1", Slug: "team", Token: token, Enabled: true,
		Source: model.ShareSource{Kind: model.ShareSourceCoreProxyUser, ProxyUserID: "u1"},
	}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if err := s.Save(); err != nil {
		t.Fatalf("save: %v", err)
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if strings.Contains(string(raw), token) {
		t.Fatal("subscription share token was written to disk in plaintext")
	}
}

func TestSubscriptionShareByTokenFindsExactMatchOnly(t *testing.T) {
	s, err := Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if err := s.UpsertSubscriptionShare(model.SubscriptionShare{
		ID: "share1", Slug: "team", Token: "correct-token", Enabled: true,
	}); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	if _, ok := s.SubscriptionShareByToken("correct-token"); !ok {
		t.Fatal("exact token did not resolve")
	}
	if _, ok := s.SubscriptionShareByToken("correct-toke"); ok {
		t.Fatal("prefix of a token resolved; lookup must be exact")
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-server && go test ./internal/store -run TestSubscriptionShare -v`
Expected: FAIL — `s.UpsertSubscriptionShare undefined`.

- [ ] **Step 3: Add the state field and accessors**

In `internal/store/store.go`, add to `State`:

```go
	SubscriptionShares map[string]model.SubscriptionShare `json:"subscription_shares"`
```

initialize it in the two places `Static` is initialized (`:340` and `:397` patterns), and add it to the hot-store exclusion in `jsonPersistState`:

```go
	st.SubscriptionShares = map[string]model.SubscriptionShare{}
```

Create `internal/store/subscription_share.go`:

```go
package store

import (
	"sort"
	"time"

	"github.com/LatticeNet/lattice-sdk/model"
)

func (s *Store) UpsertSubscriptionShare(share model.SubscriptionShare) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ensureMaps()
	now := time.Now().UTC()
	share.UpdatedAt = now
	if share.CreatedAt.IsZero() {
		share.CreatedAt = now
	}
	if share.SchemaVersion == 0 {
		share.SchemaVersion = model.SubscriptionShareSchemaVersion
	}
	s.state.SubscriptionShares[share.ID] = share
	if s.runtimeBoltHot != nil {
		return s.runtimeBoltHot.UpsertSubscriptionShare(share)
	}
	return s.Save()
}

func (s *Store) SubscriptionShare(id string) (model.SubscriptionShare, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	share, ok := s.state.SubscriptionShares[id]
	return share, ok
}

// SubscriptionShareByToken resolves a share by its exact token. It is the only
// lookup the public endpoint performs, and it never matches a prefix.
func (s *Store) SubscriptionShareByToken(token string) (model.SubscriptionShare, bool) {
	if token == "" {
		return model.SubscriptionShare{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, share := range s.state.SubscriptionShares {
		if share.Token == token {
			return share, true
		}
	}
	return model.SubscriptionShare{}, false
}

func (s *Store) SubscriptionShares() []model.SubscriptionShare {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]model.SubscriptionShare, 0, len(s.state.SubscriptionShares))
	for _, share := range s.state.SubscriptionShares {
		out = append(out, share)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].ID < out[j].ID
		}
		return out[i].CreatedAt.Before(out[j].CreatedAt)
	})
	return out
}

func (s *Store) DeleteSubscriptionShare(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.state.SubscriptionShares, id)
	if s.runtimeBoltHot != nil {
		return s.runtimeBoltHot.DeleteSubscriptionShare(id)
	}
	return s.Save()
}
```

In `internal/store/crypto.go`, add a block mirroring the `ProxyUsers` block in **both** `encryptedState` and its decrypt counterpart, sealing `share.Token`:

```go
	shares := make(map[string]model.SubscriptionShare, len(st.SubscriptionShares))
	for id, share := range st.SubscriptionShares {
		sealed, err := c.Encrypt(share.Token)
		if err != nil {
			return State{}, err
		}
		share.Token = sealed
		shares[id] = share
	}
	out.SubscriptionShares = shares
```

and the mirror using `c.Decrypt`. Add `subscription_shares` to `boltStateBuckets` and give `BoltStateStore` `UpsertSubscriptionShare` / `DeleteSubscriptionShare` following the `ProxyUser` methods already in that file.

- [ ] **Step 4: Run the tests**

Run: `cd lattice-server && go test ./internal/store -run TestSubscriptionShare -v`
Expected: PASS, both tests.

- [ ] **Step 5: Full store gates and commit**

```bash
cd lattice-server
gofmt -l . && go vet ./internal/store/... && go test -race ./internal/store
git add internal/store/
git commit -m "Store subscription shares beside proxy users, sealed and off the rewrite path

Shares are read on every public subscription fetch, so they belong in the
record-level hot store rather than in the file that is rewritten in full and
fsynced on every state write. The token joins the credentials crypto.go already
seals; a test asserts the plaintext never reaches disk."
```

---

### Task 3: Two-segment path parsing replaces the single-segment form

**Files:**
- Create: `lattice-server/internal/server/server_subscription_share.go`
- Test: `lattice-server/internal/server/server_subscription_share_test.go`
- Modify: `lattice-server/internal/server/server_proxy.go` — delete `subscriptionTokenFromPath` (`:278-287`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `sharePathFromRequest(path string) (slug string, token string, ok bool)`.

- [ ] **Step 1: Write the failing test**

```go
package server

import "testing"

func TestSharePathFromRequest(t *testing.T) {
	cases := []struct {
		name         string
		path         string
		wantSlug     string
		wantToken    string
		wantOK       bool
	}{
		{"two segments", "/sub/team-alpha/abcdefghijklmnopqrstuvwxyz012345", "team-alpha", "abcdefghijklmnopqrstuvwxyz012345", true},
		{"single segment is gone", "/sub/abcdefghijklmnopqrstuvwxyz012345", "", "", false},
		{"three segments", "/sub/a/b/c", "", "", false},
		{"empty slug", "/sub//abcdefghijklmnopqrstuvwxyz012345", "", "", false},
		{"empty token", "/sub/team/", "", "", false},
		{"slug rejects uppercase", "/sub/Team/abcdefghijklmnopqrstuvwxyz012345", "", "", false},
		{"slug rejects leading hyphen", "/sub/-team/abcdefghijklmnopqrstuvwxyz012345", "", "", false},
		{"token too short", "/sub/team/short", "", "", false},
		{"traversal", "/sub/../abcdefghijklmnopqrstuvwxyz012345", "", "", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			slug, token, ok := sharePathFromRequest(tc.path)
			if ok != tc.wantOK || slug != tc.wantSlug || token != tc.wantToken {
				t.Fatalf("got (%q,%q,%v) want (%q,%q,%v)", slug, token, ok, tc.wantSlug, tc.wantToken, tc.wantOK)
			}
		})
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-server && go test ./internal/server -run TestSharePathFromRequest -v -timeout 30m`
Expected: FAIL — `undefined: sharePathFromRequest`.

- [ ] **Step 3: Implement parsing and delete the old parser**

Create `internal/server/server_subscription_share.go`:

```go
package server

import (
	"regexp"
	"strings"
)

var shareSlugRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)

// sharePathFromRequest splits /sub/<slug>/<token>. The single-segment form was
// removed rather than kept alongside: the deployment had no live subscription on
// it, and two shapes would mean a permanent branch here forever.
func sharePathFromRequest(value string) (string, string, bool) {
	rest, ok := strings.CutPrefix(value, "/sub/")
	if !ok {
		return "", "", false
	}
	slug, token, found := strings.Cut(rest, "/")
	if !found || strings.Contains(token, "/") {
		return "", "", false
	}
	if !shareSlugRe.MatchString(slug) || !proxySubTokenRe.MatchString(token) {
		return "", "", false
	}
	return slug, token, true
}
```

Delete `subscriptionTokenFromPath` from `server_proxy.go:278-287` and every reference to it.

- [ ] **Step 4: Run the tests**

Run: `cd lattice-server && go test ./internal/server -run TestSharePathFromRequest -v -timeout 30m`
Expected: PASS, all nine subtests.

- [ ] **Step 5: Commit**

```bash
git add internal/server/server_subscription_share.go internal/server/server_subscription_share_test.go internal/server/server_proxy.go
git commit -m "Give the subscription path a slug segment and drop the single-segment form

The slug is a label, not a secret: it reaches reverse-proxy logs and client
screenshots, so the token stays the only thing authorization rests on. The old
form is deleted rather than kept because nothing was subscribed to it and two
shapes would be a branch in this parser forever."
```

---

### Task 4: Resolution and the indistinguishable 404

**Files:**
- Modify: `lattice-server/internal/server/server_subscription_share.go`
- Test: `lattice-server/internal/server/server_subscription_share_test.go`

**Interfaces:**
- Consumes: `sharePathFromRequest` (Task 3); `(*Store).SubscriptionShareByToken` (Task 2).
- Produces: `(*Server).resolveShare(slug, token string, now time.Time) (model.SubscriptionShare, bool)`.

- [ ] **Step 1: Write the failing test**

```go
func TestResolveShareRejectionsAreIndistinguishable(t *testing.T) {
	st := newTestStore(t)
	past := time.Now().UTC().Add(-time.Hour)
	mustUpsertShare(t, st, model.SubscriptionShare{ID: "a", Slug: "team", Token: strings.Repeat("a", 32), Enabled: true})
	mustUpsertShare(t, st, model.SubscriptionShare{ID: "b", Slug: "off", Token: strings.Repeat("b", 32), Enabled: false})
	mustUpsertShare(t, st, model.SubscriptionShare{ID: "c", Slug: "old", Token: strings.Repeat("c", 32), Enabled: true, ExpiresAt: &past})
	s := newTestServerWithStore(t, st)
	now := time.Now().UTC()

	if _, ok := s.resolveShare("team", strings.Repeat("a", 32), now); !ok {
		t.Fatal("valid share did not resolve")
	}
	for _, tc := range []struct {
		name  string
		slug  string
		token string
	}{
		{"unknown token", "team", strings.Repeat("z", 32)},
		{"right token wrong slug", "wrong", strings.Repeat("a", 32)},
		{"disabled share", "off", strings.Repeat("b", 32)},
		{"expired share", "old", strings.Repeat("c", 32)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, ok := s.resolveShare(tc.slug, tc.token, now); ok {
				t.Fatalf("%s resolved; every rejection must look the same", tc.name)
			}
		})
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-server && go test ./internal/server -run TestResolveShare -v -timeout 30m`
Expected: FAIL — `s.resolveShare undefined`.

- [ ] **Step 3: Implement resolution**

```go
// resolveShare returns a usable share or nothing. Every rejection reason -
// unknown token, mismatched slug, disabled, expired - returns the same nothing,
// so the response can never tell a caller that a token was valid but something
// else was wrong.
func (s *Server) resolveShare(slug, token string, now time.Time) (model.SubscriptionShare, bool) {
	share, ok := s.store.SubscriptionShareByToken(token)
	if !ok {
		return model.SubscriptionShare{}, false
	}
	if share.Slug != slug {
		return model.SubscriptionShare{}, false
	}
	if !share.Enabled {
		return model.SubscriptionShare{}, false
	}
	if share.ExpiresAt != nil && !now.Before(*share.ExpiresAt) {
		return model.SubscriptionShare{}, false
	}
	return share, true
}
```

- [ ] **Step 4: Run the tests**

Run: `cd lattice-server && go test ./internal/server -run TestResolveShare -v -timeout 30m`
Expected: PASS, all subtests.

- [ ] **Step 5: Commit**

```bash
git add internal/server/server_subscription_share.go internal/server/server_subscription_share_test.go
git commit -m "Make every share rejection look identical from outside

Unknown token, mismatched slug, disabled and expired all return the same
nothing. A caller that could tell them apart would learn which of its guesses
was a real token."
```

---

### Task 5: The narrow host capability

**Files:**
- Modify: `lattice-server/internal/plugin/plugin.go` (capability map at `:63`, `hostRiskExemptForNonSystem` at `:110`)
- Test: `lattice-server/internal/plugin/plugin_test.go`

**Interfaces:**
- Produces: capability string `"subscription:serve"` classified `RiskHost`.

- [ ] **Step 1: Write the failing test**

```go
func TestSubscriptionServeIsHostRiskAndSystemOnly(t *testing.T) {
	risk, ok := capabilityRisk["subscription:serve"]
	if !ok {
		t.Fatal("subscription:serve is not a known capability")
	}
	if risk != RiskHost {
		t.Fatalf("subscription:serve risk = %q, want %q", risk, RiskHost)
	}
	// Producing content for an unauthenticated public endpoint is not something a
	// third-party wasm plugin may do merely by being signed.
	if hostRiskExemptForNonSystem["subscription:serve"] {
		t.Fatal("subscription:serve must not be exempt from the system-only restriction")
	}
	if workerCapabilities["subscription:serve"] {
		t.Fatal("workers must not be able to declare subscription:serve")
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-server && go test ./internal/plugin -run TestSubscriptionServe -v`
Expected: FAIL — `subscription:serve is not a known capability`.

- [ ] **Step 3: Register the capability**

In `internal/plugin/plugin.go`, add to `capabilityRisk` with the reasoning inline:

```go
	// subscription:serve lets a plugin produce the body of a subscription the
	// CORE serves on an unauthenticated public URL. It is host-risk and
	// system-only: the plugin never sees the token, never owns a route, and never
	// sets a response header - but its output is what a proxy client consumes, so
	// it must be signed by a trusted publisher.
	"subscription:serve": RiskHost,
```

Add nothing to `hostRiskExemptForNonSystem` or `workerCapabilities`.

- [ ] **Step 4: Run the tests**

Run: `cd lattice-server && go test ./internal/plugin -run TestSubscriptionServe -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/plugin/plugin.go internal/plugin/plugin_test.go
git commit -m "Add a capability for producing subscription content, and nothing more

It reads as one sentence: this plugin may produce content for a subscription
endpoint the core owns. It grants no route, no port, no listener and no access
to the token. A general http:serve capability was rejected for handing token
checking and rate limiting to plugin code."
```

---

### Task 6: Bounded User-Agent classification

**Files:**
- Create: `lattice-server/internal/server/subscription_ua.go`
- Test: `lattice-server/internal/server/subscription_ua_test.go`

**Interfaces:**
- Produces: `classifyClientUA(header string) string` returning one of a fixed set.

- [ ] **Step 1: Write the failing test**

```go
func TestClassifyClientUAIsBounded(t *testing.T) {
	seen := map[string]bool{}
	for _, ua := range []string{
		"Surge/2000", "Loon/700", "Quantumult%20X/1.0.30", "Stash/2.0",
		"Shadowrocket/1900", "clash-verge/1.0", "sing-box/1.24", "curl/8.0",
		"", "totally unknown agent",
	} {
		seen[classifyClientUA(ua)] = true
	}
	// An attacker-controlled header must not be able to mint unbounded cache keys.
	for i := 0; i < 1000; i++ {
		seen[classifyClientUA("random-"+strconv.Itoa(i))] = true
	}
	if len(seen) > 12 {
		t.Fatalf("classification produced %d classes; it must be bounded", len(seen))
	}
	if classifyClientUA("random-1") != classifyClientUA("random-2") {
		t.Fatal("unrecognized agents must collapse into one class")
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-server && go test ./internal/server -run TestClassifyClientUA -v -timeout 30m`
Expected: FAIL — `undefined: classifyClientUA`.

- [ ] **Step 3: Implement classification**

```go
package server

import "strings"

// classifyClientUA maps a client User-Agent onto a bounded set. The cache is
// keyed on the result rather than the raw header because the header is
// caller-controlled: keying on it directly would let anyone mint unlimited
// distinct cache entries by varying a string they choose.
func classifyClientUA(header string) string {
	lower := strings.ToLower(header)
	for _, known := range []struct{ needle, class string }{
		{"surge", "surge"},
		{"loon", "loon"},
		{"quantumult", "quantumultx"},
		{"stash", "stash"},
		{"shadowrocket", "shadowrocket"},
		{"clash", "clash"},
		{"sing-box", "singbox"},
		{"egern", "egern"},
	} {
		if strings.Contains(lower, known.needle) {
			return known.class
		}
	}
	return "other"
}
```

- [ ] **Step 4: Run the tests**

Run: `cd lattice-server && go test ./internal/server -run TestClassifyClientUA -v -timeout 30m`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/server/subscription_ua.go internal/server/subscription_ua_test.go
git commit -m "Collapse client user agents into a bounded set before caching on them

The header is caller-controlled. Keying a cache on it directly turns the cache
into a memory amplifier that anyone can drive; the classification is all the
conversion actually depends on anyway."
```

---

### Task 7: The output cache

**Files:**
- Create: `lattice-server/internal/server/subscription_cache.go`
- Test: `lattice-server/internal/server/subscription_cache_test.go`

**Interfaces:**
- Consumes: `classifyClientUA` (Task 6).
- Produces: `newSubscriptionCache(max int, ttl time.Duration) *subscriptionCache`, `(*subscriptionCache).Get(key subscriptionCacheKey, now time.Time) ([]byte, string, bool)`, `(*subscriptionCache).Put(key subscriptionCacheKey, body []byte, contentType string, now time.Time)`, `subscriptionCacheKey{ShareID, Format, UAClass string}`.

- [ ] **Step 1: Write the failing test**

```go
func TestSubscriptionCacheExpiresAndBounds(t *testing.T) {
	base := time.Unix(1700000000, 0).UTC()
	c := newSubscriptionCache(2, time.Minute)
	k := func(id string) subscriptionCacheKey {
		return subscriptionCacheKey{ShareID: id, Format: "base64", UAClass: "surge"}
	}

	c.Put(k("a"), []byte("body-a"), "text/plain", base)
	if body, ct, ok := c.Get(k("a"), base.Add(30*time.Second)); !ok || string(body) != "body-a" || ct != "text/plain" {
		t.Fatalf("fresh entry not served: %q %q %v", body, ct, ok)
	}
	if _, _, ok := c.Get(k("a"), base.Add(2*time.Minute)); ok {
		t.Fatal("entry served after its TTL")
	}

	c.Put(k("x"), []byte("x"), "text/plain", base)
	c.Put(k("y"), []byte("y"), "text/plain", base)
	c.Put(k("z"), []byte("z"), "text/plain", base)
	if c.Len() > 2 {
		t.Fatalf("cache holds %d entries, cap is 2", c.Len())
	}
}

func TestSubscriptionCacheNeverStoresEmptyBodies(t *testing.T) {
	base := time.Unix(1700000000, 0).UTC()
	c := newSubscriptionCache(4, time.Minute)
	key := subscriptionCacheKey{ShareID: "a", Format: "base64", UAClass: "surge"}
	c.Put(key, nil, "text/plain", base)
	if _, _, ok := c.Get(key, base); ok {
		t.Fatal("an empty body was cached; an empty subscription must never be served")
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-server && go test ./internal/server -run TestSubscriptionCache -v -timeout 30m`
Expected: FAIL — `undefined: newSubscriptionCache`.

- [ ] **Step 3: Implement the cache**

```go
package server

import (
	"container/list"
	"sync"
	"time"
)

type subscriptionCacheKey struct {
	ShareID string
	Format  string
	UAClass string
}

type subscriptionCacheEntry struct {
	key         subscriptionCacheKey
	body        []byte
	contentType string
	expiresAt   time.Time
}

// subscriptionCache keeps rendered subscription bodies for a short time so a
// client poll does not boot a JavaScript VM and parse a 1.24 MB engine every
// time. It is bounded in entries, not bytes, because the classification in
// classifyClientUA already bounds how many entries one share can produce.
type subscriptionCache struct {
	mu      sync.Mutex
	max     int
	ttl     time.Duration
	entries map[subscriptionCacheKey]*list.Element
	order   *list.List
}

func newSubscriptionCache(max int, ttl time.Duration) *subscriptionCache {
	if max <= 0 {
		max = 1
	}
	return &subscriptionCache{
		max:     max,
		ttl:     ttl,
		entries: map[subscriptionCacheKey]*list.Element{},
		order:   list.New(),
	}
}

func (c *subscriptionCache) Get(key subscriptionCacheKey, now time.Time) ([]byte, string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	el, ok := c.entries[key]
	if !ok {
		return nil, "", false
	}
	entry := el.Value.(*subscriptionCacheEntry)
	if !now.Before(entry.expiresAt) {
		c.order.Remove(el)
		delete(c.entries, key)
		return nil, "", false
	}
	c.order.MoveToFront(el)
	return entry.body, entry.contentType, true
}

// Put ignores empty bodies. An empty subscription must never reach a client, so
// it must never become something the cache can hand back later either.
func (c *subscriptionCache) Put(key subscriptionCacheKey, body []byte, contentType string, now time.Time) {
	if len(body) == 0 {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if el, ok := c.entries[key]; ok {
		c.order.Remove(el)
		delete(c.entries, key)
	}
	el := c.order.PushFront(&subscriptionCacheEntry{
		key: key, body: body, contentType: contentType, expiresAt: now.Add(c.ttl),
	})
	c.entries[key] = el
	for c.order.Len() > c.max {
		oldest := c.order.Back()
		if oldest == nil {
			break
		}
		c.order.Remove(oldest)
		delete(c.entries, oldest.Value.(*subscriptionCacheEntry).key)
	}
}

func (c *subscriptionCache) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.order.Len()
}
```

- [ ] **Step 4: Run the tests**

Run: `cd lattice-server && go test -race ./internal/server -run TestSubscriptionCache -v -timeout 30m`
Expected: PASS, both tests.

- [ ] **Step 5: Commit**

```bash
git add internal/server/subscription_cache.go internal/server/subscription_cache_test.go
git commit -m "Cache rendered subscriptions briefly, and never cache an empty one

A client poll should not boot a JavaScript VM and parse a 1.24 MB engine every
time. Put ignores empty bodies: an empty subscription must never reach a client,
so it must not become something the cache can hand back later either."
```

---

### Task 8: The handler, the source dispatch, and the empty-body rule

**Files:**
- Modify: `lattice-server/internal/server/server_subscription_share.go`
- Modify: `lattice-server/internal/server/server.go` (route registration at `:913`)
- Modify: `lattice-server/internal/server/server_proxy.go` (rendering moves behind the source)
- Test: `lattice-server/internal/server/server_subscription_share_test.go`

**Interfaces:**
- Consumes: `resolveShare` (Task 4), `subscriptionCache` (Task 7), `classifyClientUA` (Task 6), `callRuntimePluginService` (`server_plugin_invoke.go:271`).
- Produces: `(*Server).handleSubscriptionShare(w http.ResponseWriter, r *http.Request)`, `(*Server).renderShare(ctx context.Context, share model.SubscriptionShare, format, uaClass string) (body []byte, contentType string, err error)`.

- [ ] **Step 1: Write the failing test**

```go
func TestSubscriptionShareNeverServesEmptyBodyWith200(t *testing.T) {
	// A proxy client that receives an empty but successful subscription deletes
	// every node it had. This is the single most destructive way this endpoint can
	// fail, so it is asserted directly rather than left to code review.
	s := newTestServerWithEmptyRenderingPluginSource(t)
	req := httptest.NewRequest(http.MethodGet, "/sub/team/"+strings.Repeat("a", 32), nil)
	rec := httptest.NewRecorder()

	s.handleSubscriptionShare(rec, req)

	if rec.Code == http.StatusOK {
		t.Fatalf("empty render returned 200; client would wipe its nodes")
	}
	if rec.Code < 500 {
		t.Fatalf("status = %d, want a 5xx for an internal failure", rec.Code)
	}
}

func TestSubscriptionShareCacheHitDoesNotCallPlugin(t *testing.T) {
	s, calls := newTestServerCountingPluginCalls(t)
	get := func() int {
		req := httptest.NewRequest(http.MethodGet, "/sub/team/"+strings.Repeat("a", 32), nil)
		req.Header.Set("User-Agent", "Surge/2000")
		rec := httptest.NewRecorder()
		s.handleSubscriptionShare(rec, req)
		return rec.Code
	}
	if code := get(); code != http.StatusOK {
		t.Fatalf("first fetch = %d", code)
	}
	if code := get(); code != http.StatusOK {
		t.Fatalf("second fetch = %d", code)
	}
	if *calls != 1 {
		t.Fatalf("plugin called %d times; the second fetch must be served from cache", *calls)
	}
}

func TestSubscriptionShareUnknownTokenIs404(t *testing.T) {
	s := newTestServerWithShare(t)
	req := httptest.NewRequest(http.MethodGet, "/sub/team/"+strings.Repeat("z", 32), nil)
	rec := httptest.NewRecorder()
	s.handleSubscriptionShare(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rec.Code)
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-server && go test ./internal/server -run TestSubscriptionShare -v -timeout 30m`
Expected: FAIL — `s.handleSubscriptionShare undefined`.

- [ ] **Step 3: Implement the handler and source dispatch**

```go
// handleSubscriptionShare serves the public subscription endpoint. The core owns
// every part of this: routing, lookup, rate limiting, audit and headers. A source
// only produces bytes.
func (s *Server) handleSubscriptionShare(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, errors.New("method not allowed"))
		return
	}
	slug, token, ok := sharePathFromRequest(r.URL.Path)
	tokenHash := proxySubTokenAuditHash(token)
	if !ok {
		s.recordRequestAudit(r, model.AuditEvent{
			ID: id.New("audit"), Action: "subscription.share.fetch", Decision: "deny",
			Reason: "invalid subscription path", Metadata: map[string]string{"token_sha256": tokenHash},
		})
		writeError(w, http.StatusNotFound, errors.New("subscription not found"))
		return
	}
	share, ok := s.resolveShare(slug, token, s.now())
	if !ok {
		s.recordRequestAudit(r, model.AuditEvent{
			ID: id.New("audit"), Action: "subscription.share.fetch", Decision: "deny",
			Reason: "subscription not found", Metadata: map[string]string{"slug": slug, "token_sha256": tokenHash},
		})
		writeError(w, http.StatusNotFound, errors.New("subscription not found"))
		return
	}

	format, err := normalizeProxySubscriptionFormat(cmp.Or(r.URL.Query().Get("format"), share.DefaultFormat))
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	uaClass := classifyClientUA(r.Header.Get("User-Agent"))
	key := subscriptionCacheKey{ShareID: share.ID, Format: format, UAClass: uaClass}

	body, contentType, hit := s.subscriptionCache.Get(key, s.now())
	if !hit {
		body, contentType, err = s.renderShare(r.Context(), share, format, uaClass)
		if err != nil {
			s.recordRequestAudit(r, model.AuditEvent{
				ID: id.New("audit"), Action: "subscription.share.fetch", Decision: "deny",
				Reason: "render failed", Metadata: map[string]string{"slug": slug, "token_sha256": tokenHash},
			})
			writeError(w, http.StatusBadGateway, err)
			return
		}
		// The rule that makes this endpoint safe: a client receiving an empty but
		// successful subscription deletes every node it had.
		if len(body) == 0 {
			s.recordRequestAudit(r, model.AuditEvent{
				ID: id.New("audit"), Action: "subscription.share.fetch", Decision: "deny",
				Reason: "empty render refused", Metadata: map[string]string{"slug": slug, "token_sha256": tokenHash},
			})
			writeError(w, http.StatusBadGateway, errors.New("subscription produced no content"))
			return
		}
		s.subscriptionCache.Put(key, body, contentType, s.now())
	}

	if contentType == "" {
		contentType = "text/plain; charset=utf-8"
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", contentType)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
	s.recordRequestAudit(r, model.AuditEvent{
		ID: id.New("audit"), Action: "subscription.share.fetch", Decision: "allow",
		Metadata: map[string]string{
			"slug": slug, "token_sha256": tokenHash, "format": format,
			"ua_class": uaClass, "cache": strconv.FormatBool(hit),
		},
	})
}

// renderShare asks the share's source for content. It never inspects the token
// and never lets a source set a response header.
func (s *Server) renderShare(ctx context.Context, share model.SubscriptionShare, format, uaClass string) ([]byte, string, error) {
	switch share.Source.Kind {
	case model.ShareSourceCoreProxyUser:
		user, ok := s.store.ProxyUser(share.Source.ProxyUserID)
		if !ok {
			return nil, "", errors.New("share source user not found")
		}
		endpoints, _, err := proxycore.VLESSRealityEndpoints(user, s.proxySubscriptionProfiles(), s.store.ProxyInbounds(), proxycore.SubscriptionOptions{Now: s.now()})
		if err != nil {
			return nil, "", err
		}
		return proxySubscriptionBody(format, endpoints)
	case model.ShareSourcePlugin:
		payload, err := json.Marshal(map[string]string{
			"subscription_id": share.Source.SubscriptionID,
			"format":          format,
			"ua_class":        uaClass,
		})
		if err != nil {
			return nil, "", err
		}
		out, err := s.callRuntimePluginService(ctx, share.Source.PluginID, share.Source.PluginID+"/subscription", "render", payload, nil)
		if err != nil {
			return nil, "", err
		}
		var reply struct {
			Content     string `json:"content"`
			ContentType string `json:"content_type"`
		}
		if err := json.Unmarshal(out, &reply); err != nil {
			return nil, "", fmt.Errorf("decode plugin render reply: %w", err)
		}
		return []byte(reply.Content), reply.ContentType, nil
	default:
		return nil, "", fmt.Errorf("unknown share source %q", share.Source.Kind)
	}
}
```

In `server.go`, replace the old registration with:

```go
	mux.HandleFunc("/sub/", s.withSubscriptionLimit(s.handleSubscriptionShare))
```

and delete `handleProxySubscription`. Construct the cache in the server constructor:

```go
	s.subscriptionCache = newSubscriptionCache(512, 300*time.Second)
```

- [ ] **Step 4: Run the tests**

Run: `cd lattice-server && go test -race ./internal/server -run TestSubscriptionShare -v -timeout 30m`
Expected: PASS, all three tests.

- [ ] **Step 5: Full server gates and commit**

```bash
cd lattice-server
gofmt -l . && go vet ./... && go test -race -cover ./... -timeout 30m
git add internal/server/
git commit -m "Serve subscriptions from a core-owned endpoint with plugin sources

The core keeps routing, lookup, rate limiting, audit and headers; a source only
produces bytes. An empty render is refused with a 5xx rather than returned as an
empty 200, because a client that receives one deletes every node it had - the
test asserts that directly."
```

---

### Task 9: Plugin-side subscription definitions

**Files:**
- Create: `lattice-plugin-sub-store/system-go/subscription_store.go`
- Test: `lattice-plugin-sub-store/system-go/subscription_store_test.go`

**Interfaces:**
- Produces: `subscriptionDefinition` struct, `(*runtime).saveSubscription`, `(*runtime).getSubscription`, `(*runtime).listSubscriptions`, `(*runtime).deleteSubscription`, `maxSubscriptionDefinitionBytes = 64 * 1024`.

- [ ] **Step 1: Write the failing test**

```go
package main

import (
	"strings"
	"testing"
)

func TestSubscriptionDefinitionSizeIsCappedByThePlugin(t *testing.T) {
	// The host does not bound KV value size, and KV rides the full-rewrite
	// state.json path, so this plugin bounds itself rather than waiting for the
	// host fix (server TASK-0021).
	rt := newTestRuntime(t)
	def := subscriptionDefinition{
		ID:      "big",
		Name:    "big",
		Content: strings.Repeat("x", maxSubscriptionDefinitionBytes),
	}
	err := rt.saveSubscription(def)
	if err == nil {
		t.Fatal("oversized definition was accepted")
	}
	if !strings.Contains(err.Error(), "too large") {
		t.Fatalf("error must name the limit, got %v", err)
	}
}

func TestSubscriptionDefinitionRoundTrip(t *testing.T) {
	rt := newTestRuntime(t)
	def := subscriptionDefinition{ID: "s1", Name: "provider", URL: "https://example.invalid/sub", UA: "Surge"}
	if err := rt.saveSubscription(def); err != nil {
		t.Fatalf("save: %v", err)
	}
	got, err := rt.getSubscription("s1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.Name != "provider" || got.URL != "https://example.invalid/sub" {
		t.Fatalf("round trip lost data: %+v", got)
	}
	list, err := rt.listSubscriptions()
	if err != nil || len(list) != 1 {
		t.Fatalf("list = %v, %v", list, err)
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-plugin-sub-store/system-go && go test -run TestSubscriptionDefinition -v`
Expected: FAIL — `undefined: subscriptionDefinition`.

- [ ] **Step 3: Implement definition storage**

```go
package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// maxSubscriptionDefinitionBytes bounds one stored definition. The host's KVPut
// accepts values of any size and KV is serialized into the state file that is
// rewritten in full on every state write, so an unbounded definition here would
// degrade writes for the whole server. The plugin enforces its own limit rather
// than depending on the host fix landing first.
const maxSubscriptionDefinitionBytes = 64 * 1024

const subscriptionKVPrefix = "subscription."

type subscriptionDefinition struct {
	SchemaVersion int      `json:"schema_version"`
	ID            string   `json:"id"`
	Name          string   `json:"name"`
	URL           string   `json:"url,omitempty"`
	Content       string   `json:"content,omitempty"`
	UA            string   `json:"ua,omitempty"`
	Operators     []string `json:"operators,omitempty"`
}

func (rt *runtime) saveSubscription(def subscriptionDefinition) error {
	if strings.TrimSpace(def.ID) == "" {
		return fmt.Errorf("subscription id is required")
	}
	if def.SchemaVersion == 0 {
		def.SchemaVersion = 1
	}
	body, err := json.Marshal(def)
	if err != nil {
		return err
	}
	if len(body) >= maxSubscriptionDefinitionBytes {
		return fmt.Errorf("subscription definition is too large: %d bytes, limit %d", len(body), maxSubscriptionDefinitionBytes)
	}
	return rt.host.kvPut(subscriptionKVPrefix+def.ID, body)
}

func (rt *runtime) getSubscription(id string) (subscriptionDefinition, error) {
	raw, err := rt.host.kvGet(subscriptionKVPrefix + id)
	if err != nil {
		return subscriptionDefinition{}, err
	}
	var def subscriptionDefinition
	if err := json.Unmarshal(raw, &def); err != nil {
		return subscriptionDefinition{}, fmt.Errorf("decode subscription %q: %w", id, err)
	}
	return def, nil
}

func (rt *runtime) listSubscriptions() ([]subscriptionDefinition, error) {
	entries, err := rt.host.kvList(subscriptionKVPrefix)
	if err != nil {
		return nil, err
	}
	out := make([]subscriptionDefinition, 0, len(entries))
	for _, raw := range entries {
		var def subscriptionDefinition
		if err := json.Unmarshal(raw, &def); err != nil {
			continue
		}
		out = append(out, def)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func (rt *runtime) deleteSubscription(id string) error {
	return rt.host.kvDelete(subscriptionKVPrefix + id)
}
```

- [ ] **Step 4: Run the tests**

Run: `cd lattice-plugin-sub-store/system-go && go test -race -run TestSubscriptionDefinition -v`
Expected: PASS, both tests.

- [ ] **Step 5: Commit**

```bash
cd lattice-plugin-sub-store
gofmt -l system-go && go -C system-go vet ./... && go -C system-go test -race ./...
git add system-go/subscription_store.go system-go/subscription_store_test.go
git commit -m "Store subscription definitions under a limit the plugin sets itself

The host accepts KV values of any size and KV lands in the state file that is
rewritten in full on every write, so an unbounded definition here would slow
every unrelated write in the server. The plugin bounds itself rather than
waiting for the host fix."
```

---

### Task 10: The plugin render method

**Files:**
- Create: `lattice-plugin-sub-store/system-go/subscription_render.go`
- Test: `lattice-plugin-sub-store/system-go/subscription_render_test.go`
- Modify: `lattice-plugin-sub-store/system-go/main.go:167-173` (service dispatch)
- Modify: `lattice-plugin-sub-store/manifest.json`

**Interfaces:**
- Consumes: `subscriptionDefinition` and accessors (Task 9); the existing engine entry point used by `convert`.
- Produces: service `latticenet.sub-store/subscription` with method `render`, replying `{"content": string, "content_type": string}`.

- [ ] **Step 1: Write the failing test**

```go
func TestRenderRefusesToProduceEmptyContent(t *testing.T) {
	// The core refuses an empty body, but the plugin must not produce one either:
	// two independent refusals, because this is the failure that wipes clients.
	rt := newTestRuntime(t)
	if err := rt.saveSubscription(subscriptionDefinition{ID: "empty", Name: "empty", Content: ""}); err != nil {
		t.Fatalf("save: %v", err)
	}
	_, err := rt.renderSubscription("empty", "base64", "surge")
	if err == nil {
		t.Fatal("render returned success for a subscription with no content")
	}
}

func TestRenderProducesContentForAKnownSubscription(t *testing.T) {
	rt := newTestRuntime(t)
	if err := rt.saveSubscription(subscriptionDefinition{
		ID: "s1", Name: "one", Content: "vless://example",
	}); err != nil {
		t.Fatalf("save: %v", err)
	}
	out, err := rt.renderSubscription("s1", "base64", "surge")
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if out.Content == "" {
		t.Fatal("render produced empty content without an error")
	}
	if out.ContentType == "" {
		t.Fatal("render must name a content type")
	}
}

func TestRenderUnknownSubscriptionIsAnError(t *testing.T) {
	rt := newTestRuntime(t)
	if _, err := rt.renderSubscription("missing", "base64", "surge"); err == nil {
		t.Fatal("unknown subscription rendered successfully")
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-plugin-sub-store/system-go && go test -run TestRender -v`
Expected: FAIL — `rt.renderSubscription undefined`.

- [ ] **Step 3: Implement render and wire the service**

```go
package main

import (
	"fmt"
	"strings"
)

type renderResult struct {
	Content     string `json:"content"`
	ContentType string `json:"content_type"`
}

// renderSubscription produces the body the core will serve. It refuses to return
// empty content: the core refuses an empty body too, and both refusals exist
// because a client receiving one deletes every node it had.
func (rt *runtime) renderSubscription(subscriptionID, format, uaClass string) (renderResult, error) {
	def, err := rt.getSubscription(subscriptionID)
	if err != nil {
		return renderResult{}, fmt.Errorf("subscription %q: %w", subscriptionID, err)
	}
	source := def.Content
	if strings.TrimSpace(source) == "" {
		return renderResult{}, fmt.Errorf("subscription %q has no content to render", subscriptionID)
	}
	converted, err := rt.convertWithEngine(source, format, def.Operators)
	if err != nil {
		return renderResult{}, err
	}
	if strings.TrimSpace(converted) == "" {
		return renderResult{}, fmt.Errorf("subscription %q converted to empty content", subscriptionID)
	}
	return renderResult{Content: converted, ContentType: "text/plain; charset=utf-8"}, nil
}
```

In `main.go`'s `handleCall` switch, add before `default`:

```go
	case pluginID + "/subscription":
		return rt.handleSubscriptionCall(call)
```

and add the handler:

```go
func (rt *runtime) handleSubscriptionCall(call callPayload) response {
	switch call.Method {
	case "render":
		var req struct {
			SubscriptionID string `json:"subscription_id"`
			Format         string `json:"format"`
			UAClass        string `json:"ua_class"`
		}
		if len(call.Payload) > 0 {
			if err := json.Unmarshal(call.Payload, &req); err != nil {
				return latticeplugin.ErrorResponse(fmt.Errorf("invalid render payload: %w", err))
			}
		}
		out, err := rt.renderSubscription(req.SubscriptionID, req.Format, req.UAClass)
		if err != nil {
			return latticeplugin.ErrorResponse(err)
		}
		body, err := json.Marshal(out)
		if err != nil {
			return latticeplugin.ErrorResponse(err)
		}
		return latticeplugin.RawResultResponse(body, "")
	default:
		return latticeplugin.ErrorResponse(fmt.Errorf("unsupported method %q", call.Method))
	}
}
```

In `manifest.json`, add `"subscription:serve"` to `capabilities` and this interface alongside the existing two:

```json
{
  "service": "latticenet.sub-store/subscription",
  "backing": "runtime",
  "methods": [
    {
      "name": "render",
      "effect": "read",
      "budget": { "timeout_ms": 10000, "stdout_bytes": 6291456, "stderr_bytes": 65536, "host_calls": 2 }
    }
  ]
}
```

- [ ] **Step 4: Run the tests**

Run: `cd lattice-plugin-sub-store/system-go && go test -race -run TestRender -v`
Expected: PASS, all three tests.

- [ ] **Step 5: Full plugin gates and commit**

```bash
cd lattice-plugin-sub-store
gofmt -l system-go && go -C system-go vet ./... && go -C system-go test -race -cover ./...
git add system-go/ manifest.json
git commit -m "Answer one question for the core: produce this subscription's body

render takes a subscription id, a format and a bounded UA class and returns
content. It refuses to return empty content even though the core refuses it too:
two independent refusals, because this is the failure that wipes a client's
nodes."
```

---

### Task 11: Share CRUD, rotation, and the operator API

**Files:**
- Create: `lattice-server/internal/server/server_subscription_share_api.go`
- Test: `lattice-server/internal/server/server_subscription_share_api_test.go`
- Modify: `lattice-server/internal/server/server.go` route table

**Interfaces:**
- Consumes: store accessors (Task 2), `auth.NewRandomToken`.
- Produces: `GET/POST /api/subscription-shares`, `POST /api/subscription-shares/{id}/rotate`, `DELETE /api/subscription-shares/{id}`, all behind `withAuth("subscription:admin")`.

- [ ] **Step 1: Write the failing test**

```go
func TestRotateShareTokenAuditsBothHashesAndNeitherToken(t *testing.T) {
	s, share := newTestServerWithShareRecord(t)
	old := share.Token

	rotated := mustRotateShare(t, s, share.ID)

	if rotated.Token == old {
		t.Fatal("rotation did not change the token")
	}
	if !proxySubTokenRe.MatchString(rotated.Token) {
		t.Fatalf("rotated token %q does not match the token shape", rotated.Token)
	}
	events := auditEventsFor(t, s, "subscription.share.rotate")
	if len(events) != 1 {
		t.Fatalf("expected one rotate audit event, got %d", len(events))
	}
	meta := events[0].Metadata
	if meta["old_token_sha256"] != proxySubTokenAuditHash(old) || meta["new_token_sha256"] != proxySubTokenAuditHash(rotated.Token) {
		t.Fatalf("rotate audit did not record both hashes: %v", meta)
	}
	for _, v := range meta {
		if v == old || v == rotated.Token {
			t.Fatal("a raw token reached the audit log")
		}
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-server && go test ./internal/server -run TestRotateShareToken -v -timeout 30m`
Expected: FAIL — rotate handler undefined.

- [ ] **Step 3: Implement the API**

Implement create (generating `auth.NewRandomToken(32)`, rejecting a slug that fails `shareSlugRe`, rejecting a duplicate slug), list (returning tokens so the operator can copy the URL again — the requirement is that it stays visible), rotate (new token, `RotatedAt` set, audit both hashes), and delete. Every handler records an audit event whose metadata carries `slug` and hashes only.

- [ ] **Step 4: Run the tests**

Run: `cd lattice-server && go test -race ./internal/server -run TestShare -v -timeout 30m`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/server/server_subscription_share_api.go internal/server/server_subscription_share_api_test.go internal/server/server.go
git commit -m "Let an operator create, rotate and delete subscription shares

The share URL stays readable in the dashboard on purpose: it is copied out
repeatedly, so one-time display would trade a real workflow for protection the
at-rest sealing already provides. Rotation audits both token hashes and the test
asserts no raw token reaches the log."
```

---

### Task 12: Export/import round trip

**Files:**
- Create: `lattice-server/internal/server/subscription_share_export.go`
- Test: `lattice-server/internal/server/subscription_share_export_test.go`

**Interfaces:**
- Produces: `exportSubscriptionShares(shares []model.SubscriptionShare) ([]byte, error)`, `importSubscriptionShares(data []byte) ([]model.SubscriptionShare, error)`, format `lattice.subscription-shares.v1`.

- [ ] **Step 1: Write the failing test**

```go
func TestShareExportImportRoundTripIsByteIdentical(t *testing.T) {
	shares := []model.SubscriptionShare{{
		ID: "a", SchemaVersion: 1, Slug: "team", Token: strings.Repeat("a", 32), Enabled: true,
		Source: model.ShareSource{Kind: model.ShareSourcePlugin, PluginID: "p", SubscriptionID: "s"},
		Extra:  map[string]json.RawMessage{"future": json.RawMessage(`"kept"`)},
	}}

	first, err := exportSubscriptionShares(shares)
	if err != nil {
		t.Fatalf("export: %v", err)
	}
	back, err := importSubscriptionShares(first)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	second, err := exportSubscriptionShares(back)
	if err != nil {
		t.Fatalf("re-export: %v", err)
	}
	if !bytes.Equal(first, second) {
		t.Fatalf("round trip was not stable:\nfirst:  %s\nsecond: %s", first, second)
	}
	if !bytes.Contains(second, []byte(`"future"`)) {
		t.Fatal("an unknown field was lost across export and import")
	}
}
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd lattice-server && go test ./internal/server -run TestShareExportImport -v -timeout 30m`
Expected: FAIL — `undefined: exportSubscriptionShares`.

- [ ] **Step 3: Implement export/import**

Marshal a `{"format":"lattice.subscription-shares.v1","shares":[...]}` envelope with shares sorted by ID so output is deterministic, and parse it back rejecting an unknown `format` value.

- [ ] **Step 4: Run the tests**

Run: `cd lattice-server && go test ./internal/server -run TestShareExportImport -v -timeout 30m`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/server/subscription_share_export.go internal/server/subscription_share_export_test.go
git commit -m "Define the share export format now, not when migration needs it

A format designed after the fact gets shaped by whatever the implementation
happened to store. The round-trip test asserts stability and that unknown fields
survive, which is the property a rollback depends on."
```

---

## Self-review

**Spec coverage.** §4 URL and token → Tasks 3, 11. §5 share and source abstraction → Tasks 1, 2, 4, 8. §5 narrow capability → Task 5. §6 storage → Tasks 2, 9; the snapshot row is corrected in Task 0 and deferred to sub-project 2 with its reason. §7 upgrade compatibility → Task 1 (`Extra` round trip), Task 12 (export format). §8 failure semantics → Tasks 4, 8, 10. §9 testing → every task's test step; the cache-hit-does-not-fork assertion is Task 8, the empty-refusal assertion is Tasks 8 and 10, the no-raw-token assertion is Task 11.

**Placeholders.** None: every code step carries the code, and the two prose-only implementation steps (Tasks 11 and 12 step 3) are fully determined by their tests and interface blocks.

**Type consistency.** `SubscriptionShare`, `ShareSource`, `subscriptionCacheKey{ShareID,Format,UAClass}`, `classifyClientUA`, `sharePathFromRequest`, `resolveShare`, `renderShare`, `renderSubscription`, `subscriptionDefinition` are spelled identically everywhere they appear. The plugin reply shape `{content, content_type}` in Task 10 matches the struct decoded in Task 8.

**Known dependency on unwritten helpers.** Tasks 4, 8 and 11 use test helpers (`newTestStore`, `newTestServerWithStore`, `newTestServerWithShare`, `newTestServerCountingPluginCalls`, `mustUpsertShare`, `mustRotateShare`, `auditEventsFor`) that follow the existing `internal/server` test conventions. Each task's step 1 includes writing the helper it needs if the package does not already provide an equivalent.
