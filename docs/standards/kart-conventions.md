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
- RabbitMQ: one topic exchange per publishing service, `<service>.exchange` (e.g. `order.exchange`, `payment.exchange`) — no shared exchange. Each service also owns its own DLX (`<service>.dlx`) and retry ladder (`<service>.retry.5s`/`.30s`/`.5m`). Full topology and rationale: [kart-requirements.md §8](../requirements/kart-requirements.md); per-service manifest shape: §9 there.
- Kafka topics: `kart.<service>.<entity>`, e.g. `kart.analytics.order-events`.
- Ticket prefixes: `OFF-` (Offer), `ORD-` (Order), and similarly per bounded context.
- CI: service repos call the reusable workflow published from `kart-devops`.

## Bounded Contexts

Order, Payment, Inventory, Offer, and other kart domain services — see [PLATFORM_BLUEPRINT.md](../PLATFORM_BLUEPRINT.md) and [kart-requirements.md](../requirements/kart-requirements.md) for the full domain model and repository list.

## Client Applications

Kart ships **two** Angular applications, not one — `kart-web` (the `Customer` storefront) and `kart-admin-web` (the `Support Agent`/`Admin` back-office console) — per [`docs/client/README.md`](../client/README.md)'s app-split rationale, which formalizes the `Client / Mobile / Web` vs. `Support/Admin Console` distinction [`container-diagram.md`](../architecture/container-diagram.md) and [`system-context.md`](../architecture/system-context.md) already draw. Both names follow the naming convention [`PLATFORM_BLUEPRINT.md`](../PLATFORM_BLUEPRINT.md) §2.5 states for anything that isn't a `-service`: `kart-<role>`, stating what the repo *is*.

Every project-agnostic frontend engineering standard (Angular architecture, coding standards, design-token system, state management, networking/resilience, performance, accessibility/i18n, security, testing, observability) lives in `agent-reusables/docs/standards/frontend/` — resolved via this repo's `reusables.config.json`, same pattern as every backend standard. This repo only holds what's Kart-specific: the actual requirements per app ([`docs/client/kart-web/requirement-spec.md`](../client/kart-web/requirement-spec.md), [`docs/client/kart-admin-web/requirement-spec.md`](../client/kart-admin-web/requirement-spec.md)), the actual brand token values ([`docs/client/kart-web/design-tokens.md`](../client/kart-web/design-tokens.md)), and the actual per-feature backend-service consumption map ([`docs/client/kart-web/api-integration-map.md`](../client/kart-web/api-integration-map.md)).

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

## Observability

Concrete Kart policy layered on top of `agent-reusables`'s generic, project-agnostic [`observability-standards.md`](https://github.com/kakon-mehedi/agent-reusables) (Serilog + OpenTelemetry → Grafana Tempo/Loki, Prometheus metrics, Grafana dashboards/alerting — the LGTM stack; full pillar-by-pillar detail lives there, not restated here). Every one of Kart's 18 services follows it identically:

- **Shared instrumentation package**: `Kart.Shared.Observability`, a versioned NuGet package published from `kart-shared`, wires Serilog + the OpenTelemetry SDK (ASP.NET Core/HttpClient/Npgsql/EF Core/message-bus instrumentation, OTLP exporter) with one DI registration call per service — the same "one platform-wide implementation, not built locally by each service" pattern `kart-requirements.md` §24.3 already establishes for `Kart.Shared.Auditing`. Reimplementing Serilog/OTel wiring per service would be the same per-service-drift failure mode that decision already rejects.
- **100%-trace-coverage tier**: `kart-order-service`, `kart-inventory-service`, `kart-payment-service`, and `kart-shipping-service` — the four services that actually execute the Order Saga (`kart-requirements.md` §12; the same four `kart-cart-service/requirement-spec.md` names as the only ones wired into the saga steps) — are sampled at 100% per BRD §3/§23's mandate. Every other service uses the reusable standard's default sampling (100% of error traces, a smaller percentage of successful ones).
- **Correlation/entity-id field**: each service's structured logs and trace attributes carry its own primary entity id (`orderId`, `paymentId`, `cartId`, `userId`, ...) alongside the mandatory `traceId`/`service`/`level` fields — named explicitly in that service's own `requirement-spec.md` Observability NFR row, not centralized here, since the field differs per bounded context.
- **Platform stack ownership**: the shared Grafana + Loki + Tempo + Prometheus stack is provisioned once (Helm charts in `kart-infra`) and every service's dashboard/alert config is provisioned as code alongside it — never hand-built per service in the Grafana UI. The shared local `docker-compose` profile (reusable standard's "Local Development" section) is owned centrally in `kart-devops`, not duplicated per repo.
- **Alerting criticality**: mirrors the Money-Moving Criticality rule above — `Payment*`/`Order*` alert rules page on-call directly on breach; catalog/search-tier services notify a non-paging channel first.

## Error Handling & Response Consistency

Concrete Kart policy layered on top of `agent-reusables`'s generic, project-agnostic [`api-standards.md`](https://github.com/kakon-mehedi/agent-reusables) Error Handling / Consistent Response Model sections (global exception handler mandate, `ProblemDetails`-based envelope — full rule set lives there, not restated here). Every one of Kart's 18 services follows it identically:

- **Shared handling package**: `Kart.Shared.ErrorHandling`, a versioned NuGet package published from `kart-shared`, wires the global exception-handling middleware and the `ProblemDetails` factory (platform-standard `traceId`/`errorCode` extension members) with one DI registration call per service — the same "one platform-wide implementation, not built locally by each service" pattern already established for `Kart.Shared.Observability` and `Kart.Shared.Auditing`. No service hand-rolls its own exception middleware or error-response shape.
- **No local try/catch for translation.** A `Handler`/controller never wraps business logic in try/catch to turn an exception into a response or to log-and-rethrow — that's `Kart.Shared.ErrorHandling`'s job, wired once. Domain/business errors keep using the Result/Either pattern (`agent-reusables/docs/standards/api-standards.md`); exceptions stay reserved for genuine infrastructure failures, caught exactly once by the global handler.
- **One log per exception, not zero, not two.** The global handler logs every caught exception exactly once, at `Error` level, through the same Serilog/OTel pipeline `Kart.Shared.Observability` wires — tagged with `traceId`/`service` and that service's own primary correlation field (named in its `design-decisions.md` Observability & Instrumentation decision).
- **Consistent response envelope, every service.** Errors are always `ProblemDetails` + the platform's extension fields; success responses follow the same envelope convention across all 18 services, so `kart-web`/`kart-admin-web`'s generated OpenAPI clients (per `docs/client/README.md`) never special-case one service's response shape against another's.
- **Alerting criticality**: mirrors the Money-Moving Criticality rule above — an unhandled exception reaching the global handler on a `Payment*`/`Order*` service pages on-call directly; elsewhere it's a non-paging signal.
