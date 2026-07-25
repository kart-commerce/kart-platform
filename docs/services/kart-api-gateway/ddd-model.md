---
doc_type: ddd-model
service: kart-api-gateway
status: approved
generated_by: ddd-agent
source: docs/services/kart-api-gateway/requirement-spec.md, docs/services/kart-api-gateway/edge-cases.md, docs/services/kart-api-gateway/design-decisions.md, docs/services/kart-api-gateway/architecture.md
---

# DDD Model: kart-api-gateway

## No Domain Aggregates — Stated Explicitly, Not Omitted

`kart-api-gateway` has **no aggregate root, no entity, no value object, and no domain event of its own.** This is stated directly because every other service's `ddd-model.md` in this platform has at least one aggregate (even `kart-category-service`, the smallest bounded context so far, has a `Category` aggregate) — the absence here is a deliberate finding, not a skipped section, and force-fitting a fake aggregate (e.g. modeling "Route" as if it were a domain entity with business invariants) would misrepresent what this component actually is.

**Why there is no bounded context here:** a bounded context exists where a ubiquitous language describes a slice of the *business domain* (an Order, a Category, a Coupon) with invariants that protect that domain's correctness. The Gateway's job — proxy this HTTP request to that upstream service, reject it if the token is bad, throttle it if the caller is over budget — is infrastructure/cross-cutting concern, exactly the category `PLATFORM_BLUEPRINT.md` §1 draws a hard line around: "the control plane... is deliberately built using the same architectural patterns as the product... this is not cosmetic," but a *gateway* is not itself a product bounded context any more than the Kubernetes Ingress object in front of it is. `architecture.md`'s Boundary Rationale already states this Gateway owns no database and publishes no event — there is nothing left for a DDD model to aggregate.

## What This Document Models Instead: the Cross-Cutting Routing/Config Model

In place of a domain model, this section documents the **shape of the Gateway's own configuration data** — not because it is a domain, but because `api-contract.yaml` (a *routing config contract*, per requirement-spec §5) needs a concrete shape to describe, and that shape is worth naming precisely so the Coding Agent's `appsettings.json` and this doc's own `api-contract.yaml` describe the same thing consistently.

**Route Table entry** (the closest analogue to a "record shape" here, deliberately *not* called an aggregate or entity — it has no identity beyond its own configuration key, no lifecycle, and no invariant enforced at runtime beyond "does an incoming path match this prefix"):

| Field | Type | Meaning |
|---|---|---|
| `pathPrefix` | string | The incoming request path prefix this entry matches (e.g. `/v1/categories`) |
| `upstreamService` | string | Which backend service owns this prefix (e.g. `kart-category-service`) — resolves to a YARP cluster/destination address, config-time only |
| `authRequirement` | enum: `anonymous` \| `authenticated` | Whether a validated, non-revoked bearer JWT is required to reach this route. There is no `admin`-tier value in this release's route table (requirement-spec §2: no route today needs a Gateway-level coarse-role gate beyond authenticated/not) — the enum is deliberately left open for a future `admin` (or other coarse-role) value once a route needs one (`design-decisions.md`'s extensibility pattern), not pre-built speculatively |
| `rateLimitTier` | enum: `anonymous` \| `authenticated` \| `partner` \| `admin` | Which of the four token-bucket policies (`design-decisions.md`) applies to requests matching this route |
| `stripPrefix` | boolean | Whether the matched prefix is stripped before forwarding to the upstream (matches the upstream's own `api-contract.yaml` server path, e.g. its own `/v1` base) |

This is configuration-as-code, not domain state — it has no write model, no persistence beyond `appsettings.json`, and no business invariant a domain expert would recognize (contrast with `kart-category-service/ddd-model.md`'s `Category` aggregate, whose "no cycles, max depth 4" invariants are genuine domain rules). The one property worth calling an "invariant" at all is purely structural: **route prefixes must not overlap ambiguously** (e.g. two entries both claiming `/v1/categories`) — enforced by YARP's own route-matching/precedence rules at startup, not by any code this service writes.

## Cross-Aggregate / Cross-Context Interaction

There is no aggregate here to reason about cross-aggregate transactions for. The only cross-context relationships are the two already-recorded in `architecture.md`'s Dependencies table: reading (never writing) `kart-identity-service`-owned Redis keys, and proxying (never mutating) requests toward `kart-identity-service`'s and `kart-category-service`'s own domain APIs. Neither upstream service's own aggregate (`UserIdentity`/`Session` for Identity, `Category` for Category) is referenced, embedded, or duplicated here in any form — the Gateway never holds a copy of either service's domain data, only a route table describing how to reach it.

## Modeling Decisions & Assumptions (resolved here, not escalated)

1. **No `Route` aggregate, no `RateLimitPolicy` entity.** Both are static configuration read once at startup (or on config reload), never mutated by a request, never persisted beyond `appsettings.json` — introducing entity/aggregate ceremony (identity, a repository, a unit of work) for data that is never written at runtime would be over-engineering a config file into a fake domain.
2. **No event is published by this service, ever.** Every other service in this platform publishes at least one domain event once it has a meaningful state transition to announce; the Gateway has no state transition of its own to announce — a request either got proxied or it got rejected, and that is an observability/log concern (`design-decisions.md`'s Observability decision), not a domain event any other bounded context would subscribe to.
3. **The revocation-list Redis read is explicitly modeled as "shared infrastructure state," not as a domain concept borrowed from Identity.** The Gateway does not model a `RevokedToken` or `Session` entity of its own — it performs a raw existence/value check against a key space it never owns, exactly as `architecture.md`'s Dependencies table names it ("Shared-state (not a service-to-service call)").

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner, see `docs/adr` and this run's decision log
- [x] Approved to proceed to API/Database/Event Design Agents (Database/Event Design are both out of scope for this service — no database, no events, per this document's own findings above)
