---
doc_type: standard
service: null
status: accepted
layer: api
applies_to_agents: [api-design-agent, coding-agent, contract-compatibility-agent, code-review-agent]
---

# API Standards

## REST

- Resource-oriented URLs, plural nouns, standard verbs/status codes: `/orders/{id}`, not `/getOrder`.
- Version via URL prefix: `/v1/...`. Breaking change → new major version path; old version deprecated on a documented, published timeline.
- `Idempotency-Key` header is **mandatory** on every money-moving `POST` (charges, refunds, coupon redemption).

## gRPC

- Reserved for internal, high-throughput synchronous calls only (e.g., Inventory reserve check). Never exposed publicly.

## Versioning

- Semantic Versioning for every published contract/package: `MAJOR.MINOR.PATCH`. Additive = minor. Breaking = major.
- A breaking change cannot merge without a passed **Contract Compatibility Agent** report (see agent catalog) confirming all known consumers are migrated or the deprecation window has been communicated.

## Error Handling

- Domain/business errors use a Result/Either pattern — not exceptions. Exceptions are reserved for true infrastructure failures (DB down, network timeout).
- Never catch-and-continue silently; every swallowed exception must be logged with context.

## Validation

- Input validated at the API boundary (e.g., FluentValidation).
- Domain invariants are *also* enforced inside the aggregate — API-layer validation is a fast-fail convenience, never the only line of defense.
