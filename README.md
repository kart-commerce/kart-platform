# kart-platform

KART is an ecommerce application. This repository holds only content specific to the KART business: requirements, the platform blueprint, and KART-specific conventions (`docs/standards/kart-conventions.md`).

Project-agnostic engineering standards — coding standards, DDD, CQRS, event/messaging standards, folder structure, API standards, git workflow — live in [agent-reusables](https://github.com/kakon-mehedi/agent-reusables), so they can be reused across every project in the organization, not just this one.

Every developer may clone `agent-reusables` to a different location, so its local path is never hardcoded — it's read from `reusables.config.json` (gitignored, machine-specific). To set yours up:

```
cp reusables.config.example.json reusables.config.json
# then edit reusablesPath to point at your local agent-reusables checkout
```

## Docs

- [`docs/requirements/kart-requirements.md`](docs/requirements/kart-requirements.md) — business requirements (BRD)
- [`docs/PLATFORM_BLUEPRINT.md`](docs/PLATFORM_BLUEPRINT.md) — implementation blueprint for the agent pipeline that builds Kart
- [`docs/standards/kart-conventions.md`](docs/standards/kart-conventions.md) — KART-specific naming, bounded contexts, and conventions layered on top of the shared standards in `agent-reusables`
- [`docs/adr/`](docs/adr/) — architecture decision records
- [`docs/architecture/`](docs/architecture/) — cumulative service-boundary graph and container diagram, built up as each service passes through the Architecture Agent
- [`docs/ddd/ubiquitous-language.md`](docs/ddd/ubiquitous-language.md) — cross-service glossary, single term ownership, built up as each service passes through the DDD Agent
- [`docs/services/<name>/`](docs/services/) — per-service design record (requirement spec → architecture → DDD model → contracts), populated by the agent pipeline below

## Agent Pipeline

The blueprint (§8) describes a multi-agent pipeline that turns the BRD into running services: Requirement → Architecture → DDD → API/Database/Event Design → Ticket → Scaffold → Coding → Review → ... Each stage is a human-approval gate before the next runs.

Implemented as Claude Code subagents under [`.claude/agents/`](.claude/agents/), one per pipeline stage, added incrementally rather than all at once. Pilot service: `kart-offer-service` (Coupon/Pricing/Promotion merge per [ADR-0001](docs/adr/0001-offer-service-merge.md)).

- **`requirement-agent`** — done, approved. [`requirement-spec.md`](docs/services/kart-offer-service/requirement-spec.md) — flagged and resolved a real BRD contradiction (who publishes `ProductPriceChanged`); carried three non-blocking questions forward to later stages.
- **`architecture-agent`** — done, approved. [`architecture.md`](docs/services/kart-offer-service/architecture.md) — boundary rationale, sync/async dependency table, resolved the Pricing↔Promotion integration question (in-process, same bounded context), no distributed-monolith risk found. Also updated the cumulative [service-boundaries.md](docs/architecture/service-boundaries.md) and [container-diagram.md](docs/architecture/container-diagram.md).
- **`ddd-agent`** — done, approved. [`ddd-model.md`](docs/services/kart-offer-service/ddd-model.md) — three aggregate roots (`Coupon`, `PricingQuote`, `PromotionCampaign`), proposed two new domain events not in the BRD (`CouponRedemptionVoided`, `PromotionDeactivated`), and resolved the promo-precedence business question with you (best-discount-wins, no stacking). Seeded [`ubiquitous-language.md`](docs/ddd/ubiquitous-language.md).
- **`api-design-agent`**, **`database-design-agent`**, **`event-design-agent`** — done, approved (these three run off the same DDD model, no ordering dependency between them). Outputs: [`api-contract.yaml`](docs/services/kart-offer-service/api-contract.yaml), [`database-design.md`](docs/services/kart-offer-service/database-design.md), [`event-contract.md`](docs/services/kart-offer-service/event-contract.md). The Event Design Agent resolved the last carried-forward question (Coupon's retry tier stays at the BRD's original 2x/no-page — Order/Payment's own idempotency is the actual double-charge guard, not Coupon's).

All open questions from the original requirement spec are now resolved. Next: **Ticket Agent** (break the approved design into GitHub issues) or **Project Scaffold Agent** (generate the actual `kart-offer-service` repo skeleton) — first real step that produces code/infra rather than design docs.
