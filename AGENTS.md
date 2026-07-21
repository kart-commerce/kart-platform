# kart-platform — Agent Instructions

**Read this file first, every session, regardless of which tool you are.** Treat everything below as binding system-level instructions for working in this repository — not background reading, not optional context. If you are an LLM being given this file manually (e.g. pasted into a plain chat interface with no repo access), the human handing it to you wants you to follow it for the rest of the conversation as if it were your system prompt.

`AGENTS.md` is an emerging cross-tool convention (originated with Codex, increasingly read by other coding agents by default) for exactly this purpose — read directly, no per-tool pointer file needed unless a specific tool requires its own exact filename to auto-load (verify before assuming). **This file is the only place the real instructions live. Do not duplicate them elsewhere.**

If your tool has no automatic file-loading at all (e.g. a plain ChatGPT web chat with no file/repo access) — the human must paste or upload this file at the start of the session and tell you explicitly to treat it as governing instructions. There is no way for that to happen automatically; say so if asked and it hasn't happened.

---

## 1. What this repo is

The **control plane** for building Kart (a 20-service ecommerce system) — an agentic engineering pipeline that turns a BRD into approved designs, tickets, and eventually running services. It is **not** the product itself and holds **no deployable code** for Kart. See `docs/PLATFORM_BLUEPRINT.md` §1 for the full control-plane/data-plane split.

Read `README.md` next — it's the live status board (which pipeline stages are done/pending, links to every doc, for which service). This file covers what README doesn't: rules, reading order, and how the pipeline actually gets executed.

## 2. Standards — what to do, what not to do

This is a living standard. Add to it as new failure modes or good patterns show up; don't let it go stale.

**Always:**
- Before adding any new file, section, or standard, decide where it belongs using `docs/standards/content-placement-policy.md`: Kart-business-specific content lives here; anything that would apply unchanged to a different project belongs in `agent-reusables` instead; runnable microservice code belongs in that service's own repo, never here.
- Before relying on anything from `agent-reusables` (a standard, an agent definition, the workflow DAG), confirm the checkout actually resolves — see §5. Don't guess a path or work from memory of what it used to contain.
- Check `status: pending-approval | approved` in a doc's frontmatter before treating it as ready for the next pipeline stage to consume.
- When a design decision is a genuine business/product judgment call (revenue tradeoffs, policy choices, anything the BRD doesn't state and isn't a defensible engineering default) — ask the human. Don't decide it yourself and move on.
- When a design decision is a defensible engineering default (e.g. a cache TTL, an index choice) — make the call, state the assumption explicitly in the doc, and keep moving. Don't stop for permission on every reversible technical choice.
- Keep every module small and single-purpose: one file per service's design doc, one file per agent definition, one ADR per decision. Don't let any one file become the dumping ground for everything.
- Update `README.md`'s status board when you finish a stage — it's the **only** place pipeline status lives. Load-bearing, not decoration; a stale status board is worse than none.
- Commit locally with clear messages after each meaningful unit of work. Never push without being asked.

**Never:**
- Never silently resolve a contradiction in the BRD or an approved doc by picking one reading. Name both readings and flag it.
- Never treat a `pending-approval` doc as approved because it's convenient to keep moving.
- Never invent a requirement, event, or field that isn't in the BRD or an approved upstream doc without explicitly marking it as a proposed addition (see how new domain events were flagged in `docs/services/kart-offer-service/ddd-model.md` as a pattern).
- Never scan the entire repo to figure out what to do next. Use the reading order in §3 — it exists so you don't have to.
- Never push to a remote, create real GitHub issues/PRs, or create a new repo without explicit confirmation — these are external, visible, and hard to reverse.
- Never duplicate this file's content into a tool-specific file. Tool-specific files point here; they don't restate.
- Never write, scaffold, or commit deployable microservice/product code in this repo. This repo is documentation and design records only — product code lives in each service's own `kart-<name>-service` repo, built *from* what's documented here. See `docs/standards/content-placement-policy.md`.

## 3. Reading order for pipeline-stage work (e.g. "build X for kart-offer-service")

Don't scan the whole repo — these are the only files that matter for sequencing:

1. `README.md` — Agent Pipeline section: what's done, what's next, for which service.
2. `.claude/agents/registry.yaml` — where each agent's real definition lives (in `agent-reusables`, resolved via `reusables.config.json`) — and `<reusablesPath>/workflows/new-service.workflow.yaml` for the actual stage DAG. **Nothing executes this automatically** — no orchestrator, no scheduler. You (or a human) read it and manually check whether a stage's dependencies have `status: approved` before running the next one.
3. `docs/services/<name>/` — that service's design record (requirement-spec → architecture → ddd-model → api-contract/database-design/event-contract → tickets). This is where the actual content of each stage's output lives.
4. `docs/standards/kart-conventions.md`, then `reusables.config.json` → the `agent-reusables` checkout it points at, for the actual coding/API/DDD/event/folder-structure standards. `reusables.config.json` is gitignored and machine-local — if it's missing or invalid, see §5, don't guess a path.

If a requested task doesn't map cleanly onto one ticket in `docs/services/<name>/tickets.md` (e.g. "the controller" — this is a Vertical Slice architecture, there's no single controller file; each ticket gets its own thin `Api/` endpoint mapped to its own `Application/Features/<UseCase>/` folder), stop and ask which ticket, don't guess.

## 4. Agent definitions: where the real instructions live

Every pipeline stage's substantive definition (purpose, input, output, responsibilities, failure conditions) is **not local to this repo** — it lives in `agent-reusables` at `agents/<name>.md` (path resolved via `reusablesPath` in `reusables.config.json`), because the pipeline methodology itself isn't Kart-specific. `.claude/agents/<name>.md` here is a thin wrapper that only exists so Claude Code's subagent system can invoke that definition by name; its body just points at the reusables copy. `.claude/agents/registry.yaml` documents this mapping.

## 5. Validating the `agent-reusables` checkout

Every shared standard and every pipeline stage's real definition resolves through `reusablesPath` in `reusables.config.json` — nothing generic is duplicated into this repo. Don't assume it's set up; check it, every session, before relying on anything from `agent-reusables`:

1. Does `reusables.config.json` exist at the repo root?
2. Does its `reusablesPath` point at a directory that actually exists?
3. Does that directory look like `agent-reusables` — does it contain an `agents/` folder, a `workflows/` folder, and a `docs/standards/` folder?

If any of these fail, stop and surface exactly this — don't guess a path, don't skip the standard, don't invent the missing content locally:

```
❌ agent-reusables not found or misconfigured.

reusables.config.json is missing, or its "reusablesPath" does not resolve
to a valid agent-reusables checkout (expected agents/, workflows/, and
docs/standards/ inside it).

Fix:
  1. cp reusables.config.example.json reusables.config.json
  2. Edit "reusablesPath" to point at your local agent-reusables checkout.

This repo keeps no fallback copy of these standards/definitions on purpose
(see docs/standards/content-placement-policy.md) — proceeding without a
valid path means working from stale memory or a guess, not the source of truth.
```

## 6. Current build status

Lives in `README.md` only — not repeated here. This file is rules and process, which barely change; status changes every session and a second copy would drift. Go read README's "Agent Pipeline" section.
