# Iteration 031 — Domain-Valued NetPolicy Egress Remotes

- **Date:** 2026-06-14
- **Status:** Complete
- **Design reference:** `docs/designs/design-05-network-acl-and-map.md`
- **Repos:** `lattice-sdk`, `lattice-server`, `lattice-dashboard`, `lattice`

## Goal

Allow an operator to express an egress policy remote as a DNS hostname, for
example "node-a may reach `api.example.com:443`", without ever placing a
hostname literal inside nft syntax.

This closes the main Design 05 residual after iter-030's IPv6 CIDR/node support.

## Scope

- Add `NetRefDomain = "domain"` and `NetEndpoint.Domain` to the shared SDK model
  and proto contract.
- Normalize domain remotes server-side:
  - lower-case;
  - trim a trailing dot;
  - require a fully-qualified hostname with at least one dot;
  - reject IP literals, unsafe labels, empty labels, and labels over 63 bytes.
- Keep domain remotes **egress-only**. Ingress domain sources remain rejected
  because DNS is not an inbound identity mechanism.
- Compile each enabled egress domain remote into deterministic IPv4/IPv6 nft
  named sets under `table inet lattice_policy`.
- Bind the domain set metadata into the hidden approval action payload so the
  queued apply script can populate and periodically refresh those sets on the
  node.
- Expose the remote kind in the zero-dependency dashboard Network Policy form.

## Design

The compiler now returns an `EgressPlan`:

```go
type EgressPlan struct {
    Ruleset    string
    DomainSets []DomainSet
}
```

For `remote.kind == "domain"`, the ruleset renders:

```nft
set lattice_dom_<hash>4 { type ipv4_addr; flags interval; }
set lattice_dom_<hash>6 { type ipv6_addr; flags interval; }

ip daddr @lattice_dom_<hash>4 tcp dport 443 accept
ip6 daddr @lattice_dom_<hash>6 tcp dport 443 accept
```

The hostname itself is stored only in the approval metadata and in the node-side
refresh script. The agent fills the named sets with:

```sh
lattice-agent --update-nft-domain-set \
  -host api.example.com \
  -family inet \
  -table lattice_policy \
  -set lattice_dom_<hash>4 \
  -set6 lattice_dom_<hash>6
```

The same command is written into
`/etc/lattice/nftpolicy-domain-refresh.sh`, which the existing systemd timer
runs every minute. If an approved plan has no control-plane hostname and no
operator domain remotes, the apply script removes stale timer artifacts.

## Security Notes

- Domain remotes are egress-only. Ingress still requires `any`, literal CIDR/IP,
  or a known Lattice node identity expanded to current node IPs.
- The ruleset contains only nft identifiers and set references; no hostname is
  rendered as `ip daddr <hostname>`.
- Domain set names are generated from a deterministic SHA-256 hash and fit the
  agent/server nft identifier allowlist.
- The apply path remains rollback-protected: if DNS resolution or set updates
  fail, `set -e` plus the existing rollback trap restores the previous ruleset.
- DNS answers are authorization input only after explicit operator policy and
  node-side refresh. DNS is not treated as authentication; HTTPS/selfcheck and
  Lattice credentials still carry identity.

## Verification

- `lattice-sdk`: `GOCACHE=/private/tmp/lattice-gocache go test ./model`
- `lattice-server`: `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go test ./internal/netpolicy`
- `lattice-server`: targeted `./internal/server` tests for domain public URL and
  operator domain remotes
- `lattice-dashboard`: `node --test assets/netpolicy.test.mjs`

- `lattice-server`: `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go test ./internal/netpolicy ./internal/server -run 'TestCompileEgressPlanRendersDomainRemoteSets|TestNormalizePolicyCanonicalizesDomainRemote|TestNormalizePolicyRejectsDomainIngress|TestNetPolicyPlanBindsOperatorDomainRemoteSets|TestNetPolicyPlanRejectsIngressAndAcceptsHTTPSDomainPublicURL'`
- `lattice-server`: `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go build -o /private/tmp/lattice-server-check ./cmd/lattice-server` (exit 0; Go printed the known user module stat-cache warning because the sandbox cannot write `/Users/cdcd/go/pkg/mod/cache/...`)
- `lattice-node-agent`: `GOCACHE=/private/tmp/lattice-gocache GOWORK=... go build -o /private/tmp/lattice-agent-check ./cmd/lattice-agent` (exit 0; same stat-cache warning)
- `lattice-dashboard`: `node --check assets/app.js && npm test`
- Broader `go test ./...` for server/agent was attempted. Packages that require `httptest.NewServer` or raw local TCP listen failed with `bind: operation not permitted`, which is a sandbox network restriction; unrelated non-listening packages passed.

## Execution Log

- Added the SDK model/proto field and locked it with `proto_contract_test`.
- Added server normalization for `remote.kind:"domain"`.
- Added `CompileEgressPlan` and `DomainSet` metadata while preserving the legacy
  `CompileEgressRuleset` wrapper.
- Extended hidden nftpolicy approval actions to support a structured,
  backward-compatible payload: legacy base64 URL still decodes; new JSON payload
  carries `public_url` plus `domain_sets`.
- Extended apply and refresh scripts to update all operator domain sets, not
  only the control-plane `lattice_control4`/`lattice_control6` sets.
- Added dashboard form support for `domain` remotes.

## Review Outcome

- **Blocking findings:** none.
- **Fix applied during review:** removed a silent fallback in structured
  nftpolicy approval action encoding. JSON marshaling this payload is not
  expected to fail; falling back to the legacy action would have dropped domain
  set metadata and produced an apply script that could not refresh operator
  domain sets.
- **Security stance:** approved for this slice. Hostnames are normalized and
  validated, nft set names are deterministic allowlisted identifiers, shell
  command hosts are shell-quoted, operator-controlled set names are validated
  before script generation, and ingress domain sources remain rejected.

## Residuals

- Non-systemd refresh scheduling remains pending.
- Domain ingress sources remain intentionally unsupported.
- The graph shows domain remotes as external endpoints but does not yet annotate
  which nft set backs each domain.
- Bulk geo import and map latency/renewal overlays remain later Design 05 work.
