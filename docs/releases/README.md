---
doc_type: index
service: null
status: living-document
---

# Kart Releases — Rules, Scope, and Tooling

This folder is the single source of truth for release planning: the rules that govern every release, the actual per-release scope, and the generator that turns both into a complete, production-grade release document — scope, checklist, common mistakes, GitHub release items — in under a second instead of an hour of manual writing per release.

## Governing Rules

Three questions the design docs establish the *rules* for but never assembled in one place: when frontend work happens relative to backend, when routine vs. milestone load/stress testing happens, and why backend sequencing is sourced from `docs/services/README.md` rather than re-derived. These rules explain the `load_test` tier and frontend scope choices in `releases.json` below — they aren't re-derived per release, only applied.

### 1. Frontend does not wait for backend deployment

Per [`docs/client/api-strategy.md`](../client/api-strategy.md) §8, every FE feature moves through a 4-stage lifecycle, independent of whether the real backend service has shipped yet:

1. **Mocked** — built entirely against MSW, generated from the service's *approved* `api-contract.yaml`. Fully implemented, tested, demoable. Feature flag OFF everywhere except Dev/QA.
2. **Contract-Tested** — real contract lands; generated client replaces the mock in an integration-test lane; contract validation passes against a Staging deployment. Flag still OFF in Production.
3. **Staged** — flag ON in Staging/UAT against the real service; one full QA soak cycle, contract-validation gate continuously green.
4. **GA** — flag ON in Production; flag deleted same/next sprint.

**Consequence for planning:** a release's FE scope starts the **same release the backend service's contract is approved**, not the release after it deploys. A `🚧`-flagged feature that ships mocked is still "done" for that release's purposes — a later release is what flips it live.

### 2. Load testing has two different cadences — don't collapse them

Per BRD §25 (`kart-requirements.md`) and the Performance Tests gate (`PLATFORM_BLUEPRINT.md` §11):

- **Routine, every release:** Baseline (100 RPM) → Low (1K) → Medium (100K) tiers run as part of the standard per-service Performance Tests quality gate, before that service's first production deploy. This is inherent to "ship the service," not a separately scheduled task, so it isn't its own row in `releases.json`.
- **Milestone stress/chaos (High 1M RPM, Extreme 10M+ RPM, BRD §26 chaos suite):** only meaningful once there's a real end-to-end path worth breaking. Running these earlier tests nothing real; skipping them until the very end misses hardening runway for the services that need it most (Inventory, Order Saga) — this is exactly what each release's `load_test` field in `releases.json` schedules.

### 3. Backend sequencing is not re-derived here

The build order is [`docs/services/README.md`](../services/README.md)'s "Recommended Build Order" — already derived from the actual event/API dependency graph and cross-checked against every service's approved docs. `releases.json` only groups that existing order into shippable releases and layers FE + load-testing timing on top. If the build order in that file ever changes, `releases.json`'s groupings must be re-checked, not assumed still valid.

**Prerequisite for the first release (not itself a release):** `kart-shared`, `kart-infra`, `kart-devops` must exist first — every service's Dockerfile/CI calls `kart-devops`'s reusable workflow, and every contract is a versioned `kart-shared` package (`PLATFORM_BLUEPRINT.md` §2.4). Stand up `kart-web`/`kart-admin-web` repo shells + `@kart/design-system` + generated-API-client tooling in the same window. No load test yet — nothing exists to test. This is `releases.json`'s Release 0.

## Files

| File | Purpose |
|---|---|
| [`releases.json`](releases.json) | **Source of truth.** One object per release: backend services + ticket counts, frontend scope, load/stress-test tier, exit milestone, and the top release-specific mistakes to watch for. Edit this to change scope — never hand-edit a generated file. |
| [`COMMON_MISTAKES.md`](COMMON_MISTAKES.md) | Full enterprise release-engineering mistakes catalogue, organized by category (migrations, contracts, money-path, testing, deployment/rollback, security, process, frontend). Each release's generated doc pulls its most relevant subset from here via `releases.json`'s `top_mistakes`. |
| [`generated/`](generated/) | Output of `scripts/release.sh` — one `release-<N>-<slug>.md` per release. Regenerate with `--force` after editing `releases.json`; do not hand-edit the Scope section of a generated file (the checklists below it are meant to be checked off by hand as work progresses). |
| [`../../scripts/release.sh`](../../scripts/release.sh) | The generator + optional GitHub automation. See below. |

## Usage

```bash
# See every release and its current status
./scripts/release.sh --list

# Generate release N's full doc (scope, checklist, mistakes, GitHub items) in the target dir
./scripts/release.sh 2

# Regenerate after editing releases.json
./scripts/release.sh 2 --force

# Additionally create the GitHub milestone + a tracking issue (the checklist as task-list items)
# Requires `gh auth login` first. Confirm you actually want this — it creates real, visible
# GitHub state (a milestone + an issue) in the target repo.
./scripts/release.sh 2 --create-github

# Target a specific repo instead of the current one
./scripts/release.sh 2 --create-github --repo kart-commerce/kart-platform

# Mark a release shipped (records today's date in releases.json)
./scripts/release.sh --ship 1
```

Each generated doc includes, at the bottom, the exact `gh release create <tag> ...` command to run once that release's code is actually merged, deployed, and its CI is green — publishing the real GitHub Release is a deliberate final step you run yourself, never something the generator does automatically (a tag on code that isn't actually shipped is a rollback target for nothing).

## Why a script instead of hand-writing 10 documents

- **Consistency.** Every release doc has the same shape — the same 15-item PLATFORM_BLUEPRINT.md §11 quality-gate checklist, the same GitHub-release-items structure — so nothing gets forgotten because a release's doc was written in a hurry.
- **Single source of truth.** `releases.json` is the only place release scope lives. If it changes, every downstream doc regenerates identically — there is no second table anywhere else to fall out of sync with.
- **Speed.** Each release's full doc generates in well under a second. Release 2 through Release *n* becoming available "within minutes" isn't a design goal to work toward — it already runs in under a second per release; the actual bottleneck is (correctly) the human checklist items themselves, not the documentation.

## What this tool does not automate, on purpose

- It does not write code, run tests, or deploy anything — it produces the *plan and checklist* for a release, which a human (or an agent, per `AGENTS.md`) then executes.
- It does not auto-publish a GitHub Release (a real git tag against real shipped code) — see above.
- `--create-github`'s milestone/issue creation is opt-in per invocation, never a side effect of plain generation — creating visible state in a shared GitHub repo is a decision each time, not a default.
