---
doc_type: release-plan
release_number: 4
status: planned
generated_by: scripts/release.sh from docs/releases/releases.json
generated_at: 2026-07-25T01:34:19Z
---

# Release 4: Cart & Wishlist

**Exit milestone:** The full pre-checkout shopping experience works end-to-end.

Regenerate this file with `scripts/release.sh 4 --force` after editing `docs/releases/releases.json` -- do not hand-edit the Scope section below, hand-edit the checklists.

---

## Scope

### Backend

| Service | Tickets | Notes |
|---|---|---|
| [`kart-wishlist-service`](../../services/kart-wishlist-service/) | 9 |  |
| [`kart-cart-service`](../../services/kart-cart-service/) | 10 |  |

### Frontend

- Cart page (add/remove/merge-on-login)
- Wishlist page
- Price-drop alert UI hooks

### Load / Stress Testing

| Tier | Target | Focus |
|---|---|---|
| High | 1,000,000 RPM | Cart sits immediately upstream of the money path -- verify it holds up before Release 5 depends on it. |

---

## Pre-Release Checklist

### Design-time (should already be true -- verify, don't assume)

- [ ] `kart-wishlist-service`: requirement-spec, edge-cases, architecture, ddd-model, api/db/event contracts, and tickets are all `status: approved`
- [ ] `kart-cart-service`: requirement-spec, edge-cases, architecture, ddd-model, api/db/event contracts, and tickets are all `status: approved`

### Delivery (per service in this release, per PLATFORM_BLUEPRINT.md §11 Quality Gates)

- [ ] Coding Standards -- zero linter errors, standards-doc compliant
- [ ] Static Analysis -- no new critical/high findings
- [ ] Security Scan -- no critical/high CVE or SAST finding unresolved
- [ ] Code Review -- human approval obtained (agent verdict is advisory, never sufficient alone)
- [ ] Unit Tests -- coverage >= service-defined threshold, all pass
- [ ] Integration Tests -- all pass against the real contract
- [ ] Contract Tests -- provider/consumer contract verified (Pact-style) against every consumer in the registry
- [ ] Contract Compatibility -- no undeclared breaking change vs. any known consumer
- [ ] Performance Tests -- Baseline -> Low -> Medium tier all green (this is the routine gate; see Load/Stress table above for this release's milestone tier)
- [ ] Documentation Updated -- docs diff present in the same PR as the change it describes
- [ ] Memory Updated -- Decision/API/DB/Event/Coding memory rows written before CI/CD proceeds
- [ ] Docker Build -- multi-stage build succeeds, base image scan clean
- [ ] CI/CD -- all prior gates green
- [ ] Deployment Verification -- SLO metrics within budget during the canary verification window
- [ ] Rollback Strategy -- rollback executes within the defined RTO if verification fails (tested, not just documented)

### This release's milestone-level testing

- [ ] Executed the High tier load test described above and recorded the result in `docs/benchmarks/` (one dated file per service, see `docs/benchmarks/0000-benchmark-template.md`)
- [ ] Any gap between target and observed is either fixed, or explicitly accepted with a written reason

### Cross-service integration

- [ ] Every dependency this release's services consume (sync or async) is confirmed *actually deployed* in the target environment, not just "approved" on paper
- [ ] Every feature flag introduced this release is registered in `docs/client/approval-checklist.md`'s tracked-flag list

---

## Common Mistakes & Precautions (this release's top risks)

Full catalogue: [`docs/releases/COMMON_MISTAKES.md`](../COMMON_MISTAKES.md). Highest-relevance items for this release:

- [ ] Making the lazy stock/price validation gRPC call a hard gate on checkout initiation instead of fail-open with circuit breaker (architecture.md is explicit: never a hard gate)
- [ ] Losing the sum-on-overlap / union-on-distinct cart-merge rule on login and silently picking one behavior
- [ ] Forgetting the UserDataErased hard-delete responsibility for Cart and Wishlist (ADR-0016 names both directly) -- a GDPR gap here is a compliance bug, not a nice-to-have

---

## GitHub Release Items

| Field | Value |
|---|---|
| Tag | `v0.4.0` |
| Title | Release 4: Cart & Wishlist |
| Milestone | `Release 4: Cart & Wishlist` |
| Target | only tag once this release's code is actually merged and deployed -- a tag on unmerged/undeployed code is a rollback target for nothing |

### Release notes template (Keep a Changelog style, populate from Conventional Commit history)

```markdown
## v0.4.0 -- Release 4: Cart & Wishlist

### Added
- (feat: commits since the last tag)

### Changed
- (refactor:/perf: commits)

### Fixed
- (fix: commits)

### Security
- (any security-relevant fix -- never omit even if minor)

### Deprecated
- (any flag/endpoint marked for removal in a future release)

**Benchmarks:** link the dated report(s) in `docs/benchmarks/` for this release's load test.
**Rollback plan:** link the runbook/procedure to revert this release if Deployment Verification fails.
**Known issues:** anything carried forward, and any feature flag still OFF in Production at release time.
```

To generate the commit list once this release is merged:

```bash
git log $(git describe --tags --abbrev=0)..HEAD --pretty=format:'- %s (%h)' | grep -E '^- (feat|fix|refactor|perf|security)'
```

To actually publish the GitHub Release once the tag exists and CI is green:

```bash
gh release create v0.4.0 --title "Release 4: Cart & Wishlist" --notes-file <path-to-filled-in-notes.md>
```

