---
doc_type: standard
service: kart-platform
status: accepted
layer: process
applies_to_agents: [all]
---

# Content Placement Policy — kart-platform vs agent-reusables vs product repos

Three repositories can hold engineering knowledge or artifacts for this platform. Before adding anything — a doc, a convention, a template, an agent definition — decide which one it belongs to. Getting this wrong is how standards drift and duplicate.

## The three buckets

| Repo | Holds | Does NOT hold |
|---|---|---|
| **`kart-platform`** (this repo) | Kart-business-specific knowledge: the BRD, the platform blueprint, Kart's bounded contexts and naming, per-service design records (requirement → architecture → DDD → contracts → tickets), ADRs about Kart decisions, the cumulative service-boundary/ubiquitous-language docs. | Anything true of a different project too. Any deployable/microservice code. |
| **`agent-reusables`** (external, resolved via `reusablesPath`) | Anything project-agnostic: the agent pipeline's stage definitions (purpose/input/output/failure conditions), the workflow DAG, coding/DDD/CQRS/event/API/git-workflow standards, the blank ADR template. Would read identically if pasted into an unrelated project. | Anything that names a Kart concept (Order, Coupon, `ecommerce.events`, `kart.<service>.<entity>`), any Kart-specific parameter or threshold. |
| **Each service's own `kart-<name>-service` repo** (not yet scaffolded for most services) | The actual runnable microservice code, its own Dockerfile/CI, its own tests. | Design records (those stay here, in `docs/services/<name>/`, as the source of truth the service was built from) or reusable standards (those stay in `agent-reusables`). |

**This repo and `agent-reusables` never contain product code.** `kart-platform` is documentation, requirements, and guidelines only — see `AGENTS.md` §1. If a task starts looking like "write the controller" or "implement the handler," that code belongs in the service's own repo, generated *from* the docs and standards here, not committed here.

## The decision test

Ask, in order, and stop at the first "yes":

1. **Is this runnable/deployable code for a microservice?** → Neither `kart-platform` nor `agent-reusables`. It goes in that service's own repo.
2. **Does it name a Kart-specific concept** — a bounded context (Order, Payment, Offer...), a Kart naming convention, a concrete threshold or business rule from the BRD, a decision about *this* platform's services? → `kart-platform`.
3. **Would the same content apply unchanged to a different project** (a different domain, not ecommerce, not Kart) — a generic engineering standard, an agent's generic responsibilities, a template? → `agent-reusables`.
4. **Still unclear** (e.g. it's a Kart-specific *value* plugged into a generic *rule*)? → Split it: the generic rule/template goes to `agent-reusables`; the Kart-specific value or exception layers on top here, the way `docs/standards/kart-conventions.md` layers on top of `agent-reusables`'s generic standards. Don't duplicate the generic part to make the split easier — reference it.
5. **Genuinely a business/product judgment call the BRD doesn't answer?** Don't decide the placement yourself — ask the human (same rule as any other business judgment call, `AGENTS.md` §2).

## Examples already in this repo

- `docs/standards/kart-conventions.md` stays here — it's Kart's concrete naming and thresholds layered on `agent-reusables`'s generic standards.
- `.claude/agents/<name>.md` files are thin wrappers only — the substantive agent definition lives in `agent-reusables/agents/<name>.md`, because that content is tool-agnostic and project-agnostic (see `AGENTS.md` §4).
- `docs/adr/0001-offer-service-merge.md` stays here — it's a decision about Kart's own service boundaries. The blank ADR template it was written from lives in `agent-reusables`.
- `docs/services/kart-offer-service/*` stays here — it's the design record for one Kart service, produced *using* the generic pipeline stages from `agent-reusables`.

## Don't duplicate to make a tool happy

If a specific tool needs its own filename to auto-load something (e.g. Claude Code's subagent system), the tool-specific file is a pointer, never a restatement. See `AGENTS.md` §4 for the pattern this repo already follows.
