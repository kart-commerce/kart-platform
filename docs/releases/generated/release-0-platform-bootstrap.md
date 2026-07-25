---
doc_type: release-plan
release_number: 0
status: planned
generated_by: scripts/release.sh from docs/releases/releases.json
generated_at: 2026-07-25T01:34:39Z
---

# Release 0: Platform Bootstrap (prerequisite, not a customer-facing release)

**Exit milestone:** A hello-world service can be scaffolded, built, containerized, and deployed to a local/staging k8s cluster via the shared pipeline.

Regenerate this file with `scripts/release.sh 0 --force` after editing `docs/releases/releases.json` -- do not hand-edit the Scope section below, hand-edit the checklists.

---

## Scope

### Backend

| Service | Tickets | Notes |
|---|---|---|
| `kart-shared` | n/a | versioned event schemas + OpenAPI contracts + common libs |
| `kart-infra` | n/a | Terraform/Helm/K8s cluster bootstrap |
| `kart-devops` | n/a | reusable CI/CD workflows |
| `kart-api-gateway` | n/a | gateway skeleton + routing config |

### Frontend

- kart-web repo shell + @kart/design-system integration
- kart-admin-web repo shell + @kart/design-system integration
- Generated-API-client tooling (openapi-generator-cli wired into CI)

### Load / Stress Testing

| Tier | Target | Focus |
|---|---|---|
| none | n/a RPM | Nothing deployed yet -- no service exists to load test. |

---

## Pre-Release Checklist

### Design-time (should already be true -- verify, don't assume)

- [ ] `kart-shared`: requirement-spec, edge-cases, architecture, ddd-model, api/db/event contracts, and tickets are all `status: approved`
- [ ] `kart-infra`: requirement-spec, edge-cases, architecture, ddd-model, api/db/event contracts, and tickets are all `status: approved`
- [ ] `kart-devops`: requirement-spec, edge-cases, architecture, ddd-model, api/db/event contracts, and tickets are all `status: approved`
- [ ] `kart-api-gateway`: requirement-spec, edge-cases, architecture, ddd-model, api/db/event contracts, and tickets are all `status: approved`

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

- [ ] Executed the none tier load test described above and recorded the result in `docs/benchmarks/` (one dated file per service, see `docs/benchmarks/0000-benchmark-template.md`)
- [ ] Any gap between target and observed is either fixed, or explicitly accepted with a written reason

### Cross-service integration

- [ ] Every dependency this release's services consume (sync or async) is confirmed *actually deployed* in the target environment, not just "approved" on paper
- [ ] Every feature flag introduced this release is registered in `docs/client/approval-checklist.md`'s tracked-flag list

---

## Common Mistakes & Precautions (this release's top risks)

Full catalogue: [`docs/releases/COMMON_MISTAKES.md`](../COMMON_MISTAKES.md). Highest-relevance items for this release:

- [ ] Letting kart-shared become a dumping ground for domain logic instead of only versioned contracts + generic libs (PLATFORM_BLUEPRINT.md §2.2 item 3)
- [ ] Hardcoding CI steps per service instead of calling kart-devops's reusable workflow_call -- guarantees drift across 18 repos later
- [ ] Skipping branch protection / required PR review on kart-shared's main -- it is the one repo every other repo depends on as a package

---

## GitHub Release Items

| Field | Value |
|---|---|
| Tag | `v0.0.0` |
| Title | Release 0: Platform Bootstrap (prerequisite, not a customer-facing release) |
| Milestone | `Release 0: Platform Bootstrap (prerequisite, not a customer-facing release)` |
| Target | only tag once this release's code is actually merged and deployed -- a tag on unmerged/undeployed code is a rollback target for nothing |

### Release notes template (Keep a Changelog style, populate from Conventional Commit history)

```markdown
## v0.0.0 -- Release 0: Platform Bootstrap (prerequisite, not a customer-facing release)

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
gh release create v0.0.0 --title "Release 0: Platform Bootstrap (prerequisite, not a customer-facing release)" --notes-file <path-to-filled-in-notes.md>
```

