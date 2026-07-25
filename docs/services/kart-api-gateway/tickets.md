---
doc_type: tickets
service: kart-api-gateway
status: approved
generated_by: ticket-agent
source: [requirement-spec.md, edge-cases.md, design-decisions.md, architecture.md, ddd-model.md, api-contract.yaml]
---

# Tickets: kart-api-gateway

Local draft. Not yet created as real GitHub Issues — that requires the target repo's own project board wiring, a separate explicit step. This service has no `database-design.md`/`event-contract.md` (ddd-model.md: no database, no events) — six upstream artifacts are `status: approved`, and this ticket list decomposes directly from that set, scoped to Release 0's stated "gateway skeleton + routing config" milestone (`docs/releases/generated/release-0-platform-bootstrap.md`).

## Epic: kart-api-gateway v0 (Release 0 skeleton)

Single entry point for the platform: path-based routing to today's two backend services, edge JWT validation + revocation check, tiered rate limiting, and a documented extensibility pattern for future services (`architecture.md`, Boundary Rationale).

| ID | Task | Depends On | Design Source |
|---|---|---|---|
| GW-1 | YARP proxy skeleton: clusters + routes for `kart-identity-service` and `kart-category-service`, config-driven (`appsettings.json`) | — | `api-contract.yaml`'s route table; `design-decisions.md` "Reverse Proxy Technology" |
| GW-2 | JWT bearer validation middleware: JWKS fetch-and-cache resolver reusing `kart-category-service`'s `JwksSigningKeyResolver.cs` pattern | GW-1 | `design-decisions.md` "JWT Validation — Reuse of kart-category-service's JWKS Pattern"; `edge-cases.md` "JWT validation failure modes" |
| GW-3 | JWT forwarding (no internal header minted) — confirm `Authorization` header is passed through unchanged to upstream | GW-2 | ADR-0023 (`docs/adr/0023-api-gateway-jwt-forwarding.md`); `design-decisions.md` "JWT Forwarding vs. Internal Header" |
| GW-4 | Redis revocation-list check middleware: read `identity:revocation:token:{jti}` and `identity:revocation:user:{userId}`, fail-closed on Redis error/timeout | GW-2 | `design-decisions.md` "Identity Revocation-List Redis Access"; `edge-cases.md` "Redis revocation-check unavailable" |
| GW-5 | Tiered rate-limiting middleware: four token-bucket policies (`anonymous`, `authenticated`, `partner`, `admin`), applied per route via `RateLimiterPolicy` config, 429 + `Retry-After` on rejection | GW-1 | `design-decisions.md` "Rate Limiting"; `api-contract.yaml`'s `rateLimitTiers`; `edge-cases.md` "Rate-limit exceeded" |
| GW-6 | Request body size limit (1 MB default, 413 before proxy/auth/rate-limit accounting) | GW-1 | `edge-cases.md` "Request larger than a size limit" |
| GW-7 | Per-upstream-cluster circuit breaker + timeout budget (isolates Identity-routed traffic from a Category outage and vice versa) | GW-1 | `edge-cases.md` "Upstream service down or circuit-open"; `architecture.md` Distributed-Monolith Risk |
| GW-8 | Observability wiring: Serilog + OpenTelemetry, trace-context origination (`traceparent` on every proxied request), `route`/`upstreamCluster` correlation fields | GW-1 | `design-decisions.md` "Observability & Instrumentation" |
| GW-9 | Docker + CI: multi-stage Dockerfile, `kart-devops` reusable `.NET Service CI` workflow_call wiring | GW-1 through GW-8 | Release 0 checklist ("Docker Build", "CI/CD" gates) |

## Flagged Gaps — Not Decomposed Into Tickets (would invent scope, not decompose it)

- **No `/admin/*`-prefixed route or `admin` `authRequirement` usage.** `api-contract.yaml` defines the `admin` rate-limit tier for future use, but no route in this release actually needs it — Category's own write endpoints re-check `Admin` on their own side (requirement-spec §5). No ticket here; a future service's route needing this is that pass's own addition, per `design-decisions.md`'s extensibility pattern.
- **No Redis-backed distributed rate limiter.** `design-decisions.md`'s Rate Limiting decision explicitly defers this until the Gateway needs to scale to multiple non-sticky-routed replicas — not needed for this release's skeleton scope.
- **No WAF, GraphQL federation, or API-management-platform features.** Out of scope per `design-decisions.md`'s YARP-vs-Kong/Envoy decision — this release is a routing/auth/rate-limit skeleton, not a full API-management product.

## Notes for Sprint Planner Agent

- GW-1 (proxy skeleton) is the foundation every other ticket builds on — build first.
- GW-2 → GW-3 → GW-4 form a chain (JWT validation must succeed before forwarding or revocation-checking makes sense) — sequence in that order.
- GW-5 and GW-6 depend only on GW-1 and are independent of the JWT/revocation chain (GW-2–GW-4) and of each other — parallelizable once GW-1 lands.
- GW-7 (circuit breaker) and GW-8 (observability) both depend only on GW-1 and are independent of every other ticket — parallelizable.
- GW-9 (Docker/CI) depends on the full set (GW-1 through GW-8) being buildable/testable, since the CI pipeline runs `dotnet build`/`dotnet test` against the whole solution.
- No circular dependencies in this graph. Longest chain is 4 nodes (GW-1 → GW-2 → GW-3 → GW-4).
