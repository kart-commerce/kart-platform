---
doc_type: architecture
service: kart-api-gateway
status: approved
generated_by: architecture-agent
source: docs/services/kart-api-gateway/requirement-spec.md, docs/services/kart-api-gateway/edge-cases.md, docs/services/kart-api-gateway/design-decisions.md, docs/services/kart-api-gateway/ddd-model.md
---

# Architecture: kart-api-gateway

## Boundary Rationale

`kart-api-gateway` is the single entry point every client request passes through before reaching any Kart bounded-context service (BRD §18; `docs/architecture/container-diagram.md` already shows every client edge — `kart-web`, `kart-admin-web` — routed through a `GW` node into every one of the 18 downstream services). It is not itself a bounded context: it owns no domain aggregate, no database, publishes no domain event, and its "business logic" is entirely cross-cutting infrastructure concern (routing, authentication, rate limiting) rather than a slice of the Kart e-commerce domain (`ddd-model.md`).

Nginx sits in front of this Gateway (BRD §19) for TLS termination, static asset serving, and request buffering — a distinct reverse-proxy role. This document's boundary is the Gateway process itself: everything from "TLS has already been terminated, here is a plaintext HTTP request" through "here is the response from whichever upstream service owns this route."

Three already-approved upstream documents fix hard constraints this boundary must not contradict, all read and accounted for before this pass:

- **`kart-identity-service/architecture.md`**'s Dependencies table already names two Gateway-side edges from Identity's own perspective: (1) "JWKS public-key retrieval ... but cached and infrequent — not a per-request round trip," and (2) "Shared-state (not a service-to-service call) | API Gateway | Redis-backed revocation list (`identity:revocation:*`)." Both are implemented here exactly as already committed from Identity's side — this pass does not renegotiate either edge, only formalizes the Gateway's own side of them (`design-decisions.md`).
- **`kart-category-service`'s already-shipped code** (`JwksSigningKeyResolver.cs`, `AuthenticationExtensions.cs`) establishes the JWKS-consumption pattern (fetch, cache 10 minutes, synchronous `IssuerSigningKeyResolver` delegate) this Gateway reuses verbatim rather than reinventing.
- **BRD §18 vs. §24**: §18's literal "downstream services trust a signed internal header" is superseded by the already-shipped downstream reality (both existing services independently re-validate the original JWT) and by §24's own "re-checked at service" phrasing — resolved formally as **ADR-0023** (`docs/adr/0023-api-gateway-jwt-forwarding.md`), not silently picked (`AGENTS.md`).

## Dependencies

| Direction | Peer | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (client) | Customer / Support Agent / Admin / Partner API clients, via Nginx (BRD §19) | All routed HTTP traffic | **Sync** | The Gateway is the sole entry point for every client-originated request into the platform's backend services (requirement-spec §1) |
| Outbound (proxied) | `kart-identity-service` | `/v1/auth/*`, `/.well-known/jwks.json` | **Sync** (REST, proxied) | requirement-spec §5; identity's own `api-contract.yaml` path set under its own `/v1` server prefix |
| Outbound (proxied) | `kart-category-service` | `/v1/categories*` | **Sync** (REST, proxied) | requirement-spec §5; category's own `api-contract.yaml` five paths under its own `/v1` server prefix |
| Outbound (edge, cached, low-frequency) | `kart-identity-service` | `GET /.well-known/jwks.json` — the Gateway's *own* signing-key cache fetch, distinct from proxying that same path for external callers | **Sync**, but cached (10-minute `IMemoryCache`, `design-decisions.md`) — not a per-request coupling | Mirrors the identical edge already recorded from Identity's side (`kart-identity-service/architecture.md`'s Dependencies table) |
| Shared-state (not a service-to-service call) | `kart-identity-service`-owned Redis (`identity:revocation:*`) | Direct key reads: `identity:revocation:token:{jti}`, `identity:revocation:user:{userId}` | **Shared infra**, not REST/event | Identity writes on logout/admin-lock/password-reset/erasure; Gateway reads on every request bearing a validated JWT (`design-decisions.md`) — the exact edge already named from Identity's own architecture.md, not a new one introduced here |
| Not routed (explicit non-edge) | `kart-identity-service`'s `/internal/*` | n/a | n/a | Admin Service calls Identity's internal lock/unlock endpoints directly, bypassing the Gateway (`kart-identity-service/architecture.md`'s Dependencies table names this as a direct Admin→Identity edge with no Gateway hop) — this document does not add a route that doesn't exist upstream (requirement-spec §5) |

No synchronous dependency exists here that isn't already anticipated by an upstream service's own approved docs — every edge in this table either proxies a path an existing `api-contract.yaml` already defines, or reuses a shared-infra edge Identity's own architecture.md already committed to from its side.

## Distributed-Monolith Risk

**This is the one service on the platform where "is this a distributed monolith?" is the wrong question to ask in the usual shape** — by design, every authenticated request platform-wide passes through this one process (requirement-spec §3, 99.99% tier), which is the *intended* topology for an edge gateway, not an accidental chatty coupling to flag. The risk assessment here is about **blast-radius containment within that intended topology**, not about whether the coupling itself is a mistake:

- **Per-upstream-cluster circuit breaking (`edge-cases.md`, "Upstream service down or circuit-open") is the load-bearing mitigation.** Without it, `kart-identity-service`'s 99.99% critical-path status and `kart-category-service`'s 99.9% secondary-path status would be silently equalized at the Gateway — a Category outage should never degrade Identity-routed traffic, and the per-cluster breaker is what keeps that true. This is analogous to `kart-admin-service/architecture.md`'s "five outbound sync dependencies, each isolated to one back-office category by an independent circuit breaker" pattern, applied here per upstream cluster instead of per back-office category.
- **The Redis revocation-check dependency is a genuine hard dependency for all authenticated traffic, by deliberate design, not an oversight.** `edge-cases.md`'s "Redis revocation-check unavailable" decision fails closed specifically because `kart-identity-service/edge-cases.md`'s own accepted stale-revocation window is bounded (~15 minutes, the access-token TTL) and failing open on a Redis outage would silently unbound it. This makes the shared Redis cluster's own HA posture load-bearing for the whole platform's authenticated-traffic availability — already accounted for from Identity's side (`kart-identity-service/architecture.md`'s Redundancy section explicitly commits this Redis to Identity's own 99.99% tier "because the Gateway's per-request revocation check on every authenticated request platform-wide now depends on it too"). This document does not introduce a new shared-fate dependency; it consumes one Identity's own architecture pass already named and already sized correctly.
- **No multi-hop synchronous chain exists downstream of the Gateway.** The Gateway calls exactly one upstream service per request (never chaining Identity→Category or vice versa within a single client request) — the classic "chatty, should-be-async" distributed-monolith pattern this stage exists to catch does not apply here, since a gateway's entire purpose is to be the single hop every request takes before reaching exactly one bounded-context service.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner, see `docs/adr/0023-api-gateway-jwt-forwarding.md` and this run's decision log
- [x] Approved to proceed to DDD Agent
