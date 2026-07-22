---
doc_type: standard
service: kart-platform
status: accepted
layer: architecture
applies_to_agents: [architecture-agent, ddd-agent, api-design-agent, event-design-agent, scaffold-agent, code-review-agent]
---

# Kart-Specific Conventions

Concrete choices for this platform, layered on top of the project-agnostic standards in [agent-reusables](https://github.com/kakon-mehedi/agent-reusables) (`docs/standards/` there). Your local checkout path is set in `reusables.config.json` at the repo root — see [README.md](../../README.md).

## Naming

- Service repos: `kart-<noun>-service`, e.g. `kart-offer-service`.
- RabbitMQ topic exchange: `ecommerce.events`.
- Kafka topics: `kart.<service>.<entity>`, e.g. `kart.analytics.order-events`.
- Ticket prefixes: `OFF-` (Offer), `ORD-` (Order), and similarly per bounded context.
- CI: service repos call the reusable workflow published from `kart-devops`.

## Bounded Contexts

Order, Payment, Inventory, Offer, and other kart domain services — see [PLATFORM_BLUEPRINT.md](../PLATFORM_BLUEPRINT.md) and [kart-requirements.md](../requirements/kart-requirements.md) for the full domain model and repository list.

## Money-Moving Criticality

Payment* events get the highest RabbitMQ retry count and human paging on final failure; catalog/search events tolerate looser retry — per the retry-budget rule in the reusable event standards.

## API Versioning

Concrete Kart policy layered on top of `agent-reusables`'s generic API standard (URL-prefix versioning, SemVer, mandatory Contract Compatibility Agent report on breaking changes — see `docs/standards/api-standards.md` there). Every `api-contract.yaml` produced by the API Design Agent for any of the 18 Kart services must follow this:

- **Every service starts at `/v1`.** No service may skip straight to `/v2` at initial release.
- **Breaking change, concretely defined** (any one of these triggers a new major version path, e.g. `/v2`):
  - Removing or renaming a field, endpoint, or event.
  - Changing a field's type or making an optional field required.
  - Tightening request validation in a way that rejects previously-valid requests.
  - Changing authentication/authorization requirements on an existing endpoint.
- **Non-breaking, does not require a version bump:** adding a new optional request field, adding a new endpoint, adding a new field to a response (consumers must ignore unknown fields — this is itself a Domain Invariant every `ddd-model.md` should state for its aggregates' external-facing DTOs).
- **Deprecation window: minimum 90 days** from the day a new major version is published to the day the previous major version is removed. The old version must return a `Deprecation` and `Sunset` HTTP header (per the published removal date) for the entire window, and the removal date must be recorded in that service's `api-contract.yaml` and in `docs/services/<name>/tickets.md` as a tracked ticket.
- **Internal gRPC calls** (e.g. Inventory's synchronous reserve check) version via the protobuf package name (`kart.inventory.v1`), not a URL — but the same breaking-change definition, Contract Compatibility Agent gate, and 90-day deprecation window apply identically; gRPC is not exempt just because it's internal-only, since Kart's services are independently deployed (see `PLATFORM_BLUEPRINT.md` §1's "distributed monolith" risk this is meant to prevent).
- **Every version bump — REST or gRPC — requires a passed Contract Compatibility Agent report before merge**, confirming all known consumers (per the API/Event Memory consumer registry) are migrated or the deprecation window has been communicated. This is not optional for internal-only endpoints; an unnoticed breaking change to a synchronous internal call (e.g. Order's Inventory reserve call) is exactly the "distributed monolith via silent breaking change" failure mode the Contract Compatibility Agent exists to prevent.
