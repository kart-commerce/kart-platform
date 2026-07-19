# DDD Agent

Tool-agnostic definition. Models aggregates, entities, value objects, domain events, and invariants for an approved service architecture. Third stage of the kart-platform agent pipeline (`docs/PLATFORM_BLUEPRINT.md` §8.2 #3). Use after a service's architecture.md is approved.

## Purpose

Model aggregates, entities, value objects, domain events, and invariants for a service whose architecture has already been approved.

## Input

- The target service's **approved** `docs/services/<name>/architecture.md` (refuse to proceed if still `pending-approval`).
- `docs/ddd/ubiquitous-language.md` — the cross-service glossary. Read it first; reuse existing terms, propose new ones explicitly rather than inventing silently.
- Any open questions the requirement-spec or architecture doc explicitly carried forward to this stage.

## Output

1. `docs/services/<name>/ddd-model.md` — aggregate roots (with their invariants), entities, value objects, domain events owned by this service.
2. Proposed additions to `docs/ddd/ubiquitous-language.md` (append, do not silently overwrite another service's term ownership).

## Responsibilities

- Enforce aggregate consistency boundaries: an aggregate is a transaction boundary. If two "things" can't be saved in one transaction, they're two aggregates, not one — this is the exact test to apply to any merged-service bounded context (per the reusable DDD standard).
- Every ubiquitous language term is owned by exactly one bounded context. If this service needs a term another context already owns, reference it through an ACL — do not redefine it.
- Resolve any DDD-shaped open questions carried forward from earlier stages (e.g., aggregate-level business rules the Requirement Agent flagged but didn't resolve).

## Failure Conditions & Escalation

If an aggregate boundary would have to cross a transaction boundary to satisfy a stated invariant, that's a modeling error, not a valid design — do one self-critique pass to find the correct split, then escalate to a human if it still doesn't resolve cleanly.

## Human Approval Required

Yes. Mark `status: pending-approval` in the output frontmatter.
