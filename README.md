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
- [`docs/services/<name>/`](docs/services/) — per-service design record (requirement spec → architecture → DDD model → contracts), populated by the agent pipeline below

## Agent Pipeline

The blueprint (§8) describes a multi-agent pipeline that turns the BRD into running services: Requirement → Architecture → DDD → API/Database/Event Design → Ticket → Scaffold → Coding → Review → ... Each stage is a human-approval gate before the next runs.

Implemented as Claude Code subagents under [`.claude/agents/`](.claude/agents/), one per pipeline stage, added incrementally rather than all at once. Pilot service: `kart-offer-service` (Coupon/Pricing/Promotion merge per [ADR-0001](docs/adr/0001-offer-service-merge.md)).

- **`requirement-agent`** — done, approved. [`requirement-spec.md`](docs/services/kart-offer-service/requirement-spec.md) — flagged and resolved a real BRD contradiction (who publishes `ProductPriceChanged`); carried three non-blocking questions forward to later stages.
- **`architecture-agent`** — done, pending your sign-off. [`architecture.md`](docs/services/kart-offer-service/architecture.md) — boundary rationale, sync/async dependency table, resolved the Pricing↔Promotion integration question (in-process, same bounded context), no distributed-monolith risk found. Also updated the cumulative [service-boundaries.md](docs/architecture/service-boundaries.md) and [container-diagram.md](docs/architecture/container-diagram.md).
