# kart-platform — Agent Onboarding Guide

Tool-agnostic. Any coding agent (or human) working in this repo should read this first, regardless of which tool is driving.

This repo is the **control plane** for building Kart (a 20-service ecommerce system) — an agentic engineering pipeline that turns a BRD into approved designs, tickets, and eventually running services. It is **not** the product itself and holds **no deployable code** for Kart. See `docs/PLATFORM_BLUEPRINT.md` §1 for the control-plane/data-plane split.

Read `README.md` next — it's the live status board (which pipeline stages are done/pending, links to every doc). This file only covers things README doesn't: how to navigate cold and how the pipeline actually gets executed.

## Before doing any pipeline-stage work (e.g. "build X for kart-offer-service")

Read in this order — don't scan the whole repo, these are the only files that matter for sequencing:

1. `README.md` — Agent Pipeline section: what's done, what's next, for which service.
2. `workflows/new-service.workflow.yaml` + `.claude/agents/registry.yaml` — the actual stage DAG and where each agent's definition lives. **Nothing executes this automatically** — no orchestrator, no scheduler. You (or a human) read it and manually check whether a stage's dependencies have `status: approved` before running the next one.
3. `docs/services/<name>/` — that service's design record (requirement-spec → architecture → ddd-model → api-contract/database-design/event-contract → tickets). This is where the actual content of each stage's output lives.
4. `docs/standards/kart-conventions.md`, then `reusables.config.json` → the `agent-reusables` checkout it points at, for the actual coding/API/DDD/event/folder-structure standards. `reusables.config.json` is gitignored and machine-local — if it's missing, copy `reusables.config.example.json` and ask the user for their local `agent-reusables` path rather than guessing one.

If a requested task doesn't map cleanly onto one ticket in `docs/services/<name>/tickets.md` (e.g. "the controller" — this is a Vertical Slice architecture, there's no single controller file, each ticket gets its own thin `Api/` endpoint mapped to its own `Application/Features/<UseCase>/` folder), stop and ask which ticket, don't guess.

## Agent definitions: where the real instructions live

Every pipeline stage's substantive definition (purpose, input, output, responsibilities, failure conditions) lives in `agents/<name>.md` at the repo root — plain markdown, no tool-specific frontmatter, readable by any tool or a human. `.claude/agents/<name>.md` is a **thin wrapper** that only exists so Claude Code's subagent system can invoke that definition by name; its body just points back to `agents/<name>.md`. If this pipeline is ever driven by a different tool, that tool gets its own thin wrapper pointing at the same `agents/<name>.md` — the actual instructions are defined once, not duplicated per tool. `.claude/agents/registry.yaml` documents this mapping.

`CLAUDE.md` at the repo root is a similarly thin pointer — it exists only because Claude Code auto-loads a file by that exact name at the start of every session in this directory. It points back to this file for the actual content, so a hypothetical future `AGENTS.md` (Codex's equivalent auto-load convention) can do the same without duplicating or drifting from this guide.

## Approval gates are real, not decorative

Every pipeline-stage doc has `status: pending-approval | approved` in its frontmatter. Don't treat a doc as ready for the next stage to consume just because it exists — check the status field. When a stage surfaces a genuine business judgment call (not an engineering default), ask the human rather than resolving it yourself — see the flagged-vs-resolved pattern in `docs/services/kart-offer-service/requirement-spec.md` §6 for what that distinction looks like in practice.

## What's built vs. not, as of the last update to this file

Pipeline stages defined (`agents/*.md` + their `.claude/agents/*.md` wrappers): requirement, architecture, ddd, api-design, database-design, event-design, ticket. **Not yet defined**: scaffold-agent, coding-agent, or anything after — check README before assuming otherwise, this list goes stale.

Only one service has gone through the pipeline: `kart-offer-service` (pilot, Coupon+Pricing+Promotion merge, ADR-0001). No service repo has been scaffolded yet — `docs/services/<name>/` design docs exist independently of whether the actual `kart-<name>-service` code repo exists.
