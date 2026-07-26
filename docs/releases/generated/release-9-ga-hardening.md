---
doc_type: release-plan
release_number: 9
status: planned
generated_by: scripts/release.sh from docs/releases/releases.json
generated_at: 2026-07-25T01:34:19Z
---

# Release 9: GA Hardening (final release, no new services)

**Exit milestone:** v1.0 / GA-ready.

Regenerate this file with `scripts/release.sh 9 --force` after editing `docs/releases/releases.json` -- do not hand-edit the Scope section below, hand-edit the checklists.

---

## Scope

### Backend

_No new backend services in this release._

### Frontend

- Remove all remaining feature flags platform-wide
- kart-web Lighthouse / Core Web Vitals / SEO audit

### Load / Stress Testing

| Tier | Target | Focus |
|---|---|---|
| Extreme | 10,000,000+ RPM | Full-system flash-sale simulation across the entire platform simultaneously (not just the Order path this time) + the full BRD §26 chaos suite run platform-wide. |

---

## Pre-Release Checklist

### Design-time (should already be true -- verify, don't assume)

- [ ] N/A (no new backend services this release)

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

- [ ] Executed the Extreme tier load test described above and recorded the result in `docs/benchmarks/` (one dated file per service, see `docs/benchmarks/0000-benchmark-template.md`)
- [ ] Any gap between target and observed is either fixed, or explicitly accepted with a written reason

### Cross-service integration

- [ ] Every dependency this release's services consume (sync or async) is confirmed *actually deployed* in the target environment, not just "approved" on paper
- [ ] Every feature flag introduced this release is registered in `docs/client/approval-checklist.md`'s tracked-flag list

---

## Common Mistakes & Precautions (this release's top risks)

Full catalogue: [`docs/releases/COMMON_MISTAKES.md`](../COMMON_MISTAKES.md). Highest-relevance items for this release:

- [ ] Leaving a stale feature flag in code past its feature's 100% rollout (api-strategy.md's own explicit rule: delete the same or next sprint)
- [ ] Treating the full-system Extreme test as 'we already tested Order in Release 5' -- concurrent load across all 18 services surfaces cross-service resource contention no single-path test can
- [ ] Skipping the security/pen-test pass because 'each service already passed its own Security Review gate' -- a system-wide pass catches cross-service auth/authorization gaps individual passes structurally can't see

---

## GitHub Release Items

| Field | Value |
|---|---|
| Tag | `v1.0.0` |
| Title | Release 9: GA Hardening (final release, no new services) |
| Milestone | `Release 9: GA Hardening (final release, no new services)` |
| Target | only tag once this release's code is actually merged and deployed -- a tag on unmerged/undeployed code is a rollback target for nothing |

### Release notes template (Keep a Changelog style, populate from Conventional Commit history)

```markdown
## v1.0.0 -- Release 9: GA Hardening (final release, no new services)

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
gh release create v1.0.0 --title "Release 9: GA Hardening (final release, no new services)" --notes-file <path-to-filled-in-notes.md>
```

