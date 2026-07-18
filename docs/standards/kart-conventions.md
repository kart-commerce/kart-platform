---
doc_type: standard
service: kart-platform
status: accepted
layer: architecture
applies_to_agents: [architecture-agent, ddd-agent, api-design-agent, event-design-agent, scaffold-agent, code-review-agent]
---

# Kart-Specific Conventions

Concrete choices for this platform, layered on top of the project-agnostic standards in [agent-reusables](../../../agent-reusables/docs/standards/).

## Naming

- Service repos: `kart-<noun>-service`, e.g. `kart-offer-service`.
- RabbitMQ topic exchange: `ecommerce.events`.
- Kafka topics: `kart.<service>.<entity>`, e.g. `kart.analytics.order-events`.
- Ticket prefixes: `OFF-` (Offer), `ORD-` (Order), and similarly per bounded context.
- CI: service repos call the reusable workflow published from `kart-devops`.

## Bounded Contexts

Order, Payment, Inventory, Offer, and other kart domain services — see [PLATFORM_BLUEPRINT.md](../PLATFORM_BLUEPRINT.md) and [kart-requirements.md](../../kart-requirements.md) for the full domain model and repository list.

## Money-Moving Criticality

Payment* events get the highest RabbitMQ retry count and human paging on final failure; catalog/search events tolerate looser retry — per the retry-budget rule in the reusable event standards.
