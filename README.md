# kart-platform

> **If you are an AI agent/tool of any kind, read [`AGENTS.md`](AGENTS.md) first — it is the actual system instructions for this repo (rules, reading order, build status), tool-agnostic by design. This README is the human-facing status board it points to.**

KART is an ecommerce application. This repository holds only content specific to the KART business: requirements, the platform blueprint, and KART-specific conventions (`docs/standards/kart-conventions.md`).

Project-agnostic engineering standards — coding standards, DDD, CQRS, event/messaging standards, folder structure, API standards, git workflow — live in [agent-reusables](https://github.com/kakon-mehedi/agent-reusables), so they can be reused across every project in the organization, not just this one.

Every developer may clone `agent-reusables` to a different location, so its local path is never hardcoded — it's read from `reusables.config.json` (gitignored, machine-specific). To set yours up:

```
cp reusables.config.example.json reusables.config.json
# then edit reusablesPath to point at your local agent-reusables checkout
```

## Docs

- [`docs/requirements/kart-requirements.md`](docs/requirements/kart-requirements.md) — business requirements (BRD). **Synced copy, not the source** — edit the BRD in the standalone [`kart-requirements`](https://github.com/kakon-mehedi/kart-requirements) repo and copy changes here, not the other way around.
- [`docs/PLATFORM_BLUEPRINT.md`](docs/PLATFORM_BLUEPRINT.md) — implementation blueprint for the agent pipeline that builds Kart
- [`docs/standards/kart-conventions.md`](docs/standards/kart-conventions.md) — KART-specific naming, bounded contexts, and conventions layered on top of the shared standards in `agent-reusables`
- [`docs/standards/content-placement-policy.md`](docs/standards/content-placement-policy.md) — decision rules for whether new content belongs in this repo, in `agent-reusables`, or in a service's own repo
- [`docs/adr/`](docs/adr/) — architecture decision records specific to Kart (the blank ADR template is reusable and lives in `agent-reusables`)
- [`docs/architecture/`](docs/architecture/) — cumulative service-boundary graph and container diagram, built up as each service passes through the Architecture Agent
- [`docs/ddd/ubiquitous-language.md`](docs/ddd/ubiquitous-language.md) — cross-service glossary, single term ownership, built up as each service passes through the DDD Agent
- [`docs/services/`](docs/services/README.md) — **start here for any service**. Index of all 18 service folders, each with its own `requirement-spec.md` → `edge-cases.md` → `architecture.md` → `ddd-model.md` → contracts → `tickets.md`, populated by the agent pipeline below
- [`AGENTS.md`](AGENTS.md) — the real system instructions for any agent/tool working in this repo (rules, reading order, approval-gate policy). Read directly — no per-tool pointer file in this repo.

## Agent Pipeline

The blueprint (§8) describes a multi-agent pipeline that turns the BRD into running services: Requirement → Edge Case Analysis → Architecture → DDD → API/Database/Event Design → Ticket → Scaffold → Coding → Review → ... Each stage is a human-approval gate before the next runs.

The pipeline methodology itself (each stage's definition, and the DAG that sequences them) isn't Kart-specific, so it lives in [`agent-reusables`](https://github.com/kakon-mehedi/agent-reusables) — `agents/<name>.md` per stage, `workflows/new-service.workflow.yaml` for the DAG — resolved via this repo's `reusables.config.json`, same as the coding standards. [`.claude/agents/<name>.md`](.claude/agents/) here is a thin Claude Code wrapper that just points at the reusables copy. There is no automated orchestrator — sequencing is documented as data, not executed by a scheduler:

- [`.claude/agents/registry.yaml`](.claude/agents/registry.yaml) — agent name → where its real definition lives (in `agent-reusables`) → Claude Code wrapper

A human (or a Claude Code session picking this repo up cold) reads that file, then the DAG in `agent-reusables`, to know what to run next — checking each dependency's output doc for `status: approved` in its frontmatter before running the next stage, same as this session has been doing manually.

All 18 BRD services now have `status: approved` `requirement-spec.md` + `edge-cases.md` in `docs/services/<name>/` — clear to start `architecture-agent` on any of them. A professional-grade review pass originally found 9 passing outright and 9 with concrete, named gaps; a follow-up gap-closure pass re-drafted and re-reviewed each of the 9, plus 3 more services found to have the same ADR-citation staleness during the pass (never originally flagged for it). See [`docs/services/README.md`](docs/services/README.md) for the full index, the original gap table, and how each was resolved.

The cross-service BRD contradictions surfaced while drafting and reviewing (Order↔Shipping integration direction, Notification's and Analytics' actual consumed-event sets, several published events missing from the Event Catalog, and the `OrderCompleted`/`OrderDelivered`/Identity↔User missing-event gaps) are **resolved** via [ADR-0002 through ADR-0009](docs/adr/) and reflected directly in `kart-requirements.md`'s Event Catalog (§10). Identity, Admin, Order, Recommendation, Inventory, Wishlist, and Review's own docs were drafted before these ADRs and have since been re-drafted to cite them — see `docs/services/README.md`. A subsequent BRD self-consistency audit found the BRD's own text was still stale in several places even after ADR-0002–0007 were accepted — ADR-0001's Offer merge had never actually been applied to §2.1/§5.4, 4 more events had no Event Catalog row, `UserAccountUpdated` was missing Analytics as a consumer, and a note under §12.1 overreached to claim the Order↔Inventory reserve call was async when §5.1 states it's synchronous. **ADR-0008** and **ADR-0009** resolve these, applied directly to the BRD (in the source `kart-requirements` repo, then synced here).

Pilot service (furthest along the full pipeline): `kart-offer-service` (Coupon/Pricing/Promotion merge per [ADR-0001](docs/adr/0001-offer-service-merge.md)).

- **`requirement-agent`** — done, approved. [`requirement-spec.md`](docs/services/kart-offer-service/requirement-spec.md) — flagged and resolved a real BRD contradiction (who publishes `ProductPriceChanged`); carried three non-blocking questions forward to later stages.
- **`edge-case-analyzer-agent`** — done, **approved**. [`edge-cases.md`](docs/services/kart-offer-service/edge-cases.md) — retrofitted after `architecture-agent`/`ddd-agent` already ran, so it reuses their resolutions (e.g. best-discount-wins) instead of re-deriving them; flagged a new coupon-redemption-cap race the earlier stages hadn't caught. A later review pass found its cache-invalidation choice contradicted BRD §16's write-through mandate and two hard ddd-model.md invariants (coupon expiry, `PricingQuote` TTL) had no corresponding edge case — both fixed and re-approved.
- **`architecture-agent`** — done, approved. [`architecture.md`](docs/services/kart-offer-service/architecture.md) — boundary rationale, sync/async dependency table, resolved the Pricing↔Promotion integration question (in-process, same bounded context), no distributed-monolith risk found. Also updated the cumulative [service-boundaries.md](docs/architecture/service-boundaries.md) and [container-diagram.md](docs/architecture/container-diagram.md).
- **`ddd-agent`** — done, approved. [`ddd-model.md`](docs/services/kart-offer-service/ddd-model.md) — three aggregate roots (`Coupon`, `PricingQuote`, `PromotionCampaign`), proposed two new domain events not in the BRD (`CouponRedemptionVoided`, `PromotionDeactivated`), and resolved the promo-precedence business question with you (best-discount-wins, no stacking). Seeded [`ubiquitous-language.md`](docs/ddd/ubiquitous-language.md).
- **`api-design-agent`**, **`database-design-agent`**, **`event-design-agent`** — done, approved (these three run off the same DDD model, no ordering dependency between them). Outputs: [`api-contract.yaml`](docs/services/kart-offer-service/api-contract.yaml), [`database-design.md`](docs/services/kart-offer-service/database-design.md), [`event-contract.md`](docs/services/kart-offer-service/event-contract.md). The Event Design Agent resolved the last carried-forward question (Coupon's retry tier stays at the BRD's original 2x/no-page — Order/Payment's own idempotency is the actual double-charge guard, not Coupon's).
- **`ticket-agent`** — done. [`tickets.md`](docs/services/kart-offer-service/tickets.md) — 8 vertical-slice tickets (OFF-1..OFF-8), dependency-linked, no circular dependencies.
- Sprint Planner Agent — **skipped** for this project (no team/capacity to plan sprints around).
- **`scaffold-agent`** — not yet built. Next step: generate the actual `kart-offer-service` repo skeleton (Clean Architecture + Vertical Slice, Dockerfile, CI stub) as a sibling repo — the first step that produces code/infra rather than design docs.
