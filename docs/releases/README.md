---
doc_type: index
service: null
status: living-document
---

# Kart Releases — Plan, Tooling, and Generated Docs

This folder turns [`../DEVELOPMENT_PLAN.md`](../DEVELOPMENT_PLAN.md)'s release sequencing into machine-readable data plus a generator, so producing a complete, production-grade release document — scope, checklist, common mistakes, GitHub release items — is a one-command, sub-second operation instead of an hour of manual writing per release.

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
- **Single source of truth.** `releases.json` is also what `DEVELOPMENT_PLAN.md`'s table is derived from. If a release's scope changes, it changes in one JSON file, and every downstream doc regenerates identically.
- **Speed.** Each release's full doc generates in well under a second. Release 2 through Release *n* becoming available "within minutes" isn't a design goal to work toward — it already runs in under a second per release; the actual bottleneck is (correctly) the human checklist items themselves, not the documentation.

## What this tool does not automate, on purpose

- It does not write code, run tests, or deploy anything — it produces the *plan and checklist* for a release, which a human (or an agent, per `AGENTS.md`) then executes.
- It does not auto-publish a GitHub Release (a real git tag against real shipped code) — see above.
- `--create-github`'s milestone/issue creation is opt-in per invocation, never a side effect of plain generation — creating visible state in a shared GitHub repo is a decision each time, not a default.
