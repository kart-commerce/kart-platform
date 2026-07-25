---
doc_type: design-decisions
service: kart-api-gateway
status: approved
generated_by: design-decision-agent
source: docs/services/kart-api-gateway/requirement-spec.md, docs/services/kart-api-gateway/edge-cases.md
---

# Design Decisions: kart-api-gateway

Scope: cross-cutting technology/pattern choices this service's own approved `requirement-spec.md` and `edge-cases.md` force. Route table contents are `api-contract.yaml`'s job; this doc fixes the mechanism, not the per-route data.

## Decision: Reverse Proxy Technology — YARP vs. a Non-.NET Gateway (Kong/Envoy)

- **Requirement driving this:** requirement-spec §1/§2 needs path-based routing, edge JWT validation, a Redis-backed shared-state read, and per-route rate limiting, all in one process fronting every one of the platform's 18 (eventually) .NET 8 services.
- **Options considered (3):** **YARP** (`Yarp.ReverseProxy`) — Microsoft's own reverse-proxy library, distributed as an ASP.NET Core middleware/NuGet package, not a separate process · **Kong** — a widely-used, Lua/OpenResty-based API gateway, deployed as its own separate service with its own plugin ecosystem · **Envoy** — a C++ L4/L7 proxy, typically configured via xDS/YAML, common as a service-mesh data plane (e.g. Istio).
- **Decision (5 bullets):**
  - Chosen: **YARP**, hosted as its own ASP.NET Core 8 application (`kart-api-gateway`), configured via `appsettings.json` route/cluster sections plus code-level middleware for the two things YARP itself doesn't natively provide as first-class primitives (the Identity revocation-list check; the exact JWKS-consumption pattern).
  - Why: every one of the platform's 18 services is .NET 8 (BRD Stack line: ".NET 9 / ASP.NET Core..."; every already-shipped service — `kart-identity-service`, `kart-category-service` — targets `net8.0` per their `Directory.Build.props`). YARP lets the Gateway share the *exact* JWT-validation code path already shipped in `kart-category-service`'s `JwksSigningKeyResolver.cs`/`AuthenticationExtensions.cs` (same `Microsoft.AspNetCore.Authentication.JwtBearer` + `System.IdentityModel.Tokens.Jwt` stack, same `IMemoryCache`-backed JWKS cache), the same Serilog/OpenTelemetry observability wiring every service already uses (`kart-conventions.md`), and the same reusable `kart-devops` `.NET Service CI` `workflow_call` pipeline (`dotnet-service-ci.yml`) every other repo calls — none of which Kong or Envoy can consume without a rewrite in a different language/config format.
  - Why not Kong: Kong's plugin model (Lua) is a second language/runtime the platform's engineers (and this pipeline's Coding Agent, tuned for .NET) would need to maintain in parallel with 18 .NET services — the JWT/JWKS/revocation logic would have to be reimplemented as a Kong plugin instead of reused as a C# class library, duplicating logic that already exists and is already tested in `kart-category-service`.
  - Why not Envoy: Envoy's xDS/YAML configuration model and C++ extension surface is the furthest from this platform's own stack and skill investment; it is the right choice for a polyglot mesh, which this platform explicitly is not (every deployable service is .NET 8, per `PLATFORM_BLUEPRINT.md` §2's repo list).
  - Trade-off accepted: YARP is less mature as a general-purpose API-gateway product than Kong/Envoy (fewer built-in plugins for things like WAF, GraphQL federation, etc.) — accepted because this release's stated scope is a routing/auth/rate-limit skeleton for two backend services, not a full API-management platform; if a future need genuinely requires a capability YARP doesn't have, that is a new finding for a later pass, not a reason to abandon stack consistency now.

## Decision: JWT Validation — Reuse of `kart-category-service`'s JWKS Pattern

- **Requirement driving this:** requirement-spec §2's edge JWT validation, explicitly required to reuse `kart-category-service`'s already-shipped `JwksSigningKeyResolver.cs`/`AuthenticationExtensions.cs` pattern rather than invent a new one (requirement-spec §2, §6).
- **Options considered (3):** Reuse the exact `IMemoryCache`-backed JWKS-fetch-and-cache resolver pattern already shipped in `kart-category-service`, adapted only in namespace · Point `JwtBearerOptions.MetadataAddress` at a full OIDC discovery document · Have the Gateway call Identity's (hypothetical) token-introspection endpoint synchronously on every request instead of validating locally.
- **Decision (4 bullets):**
  - Chosen: Reuse the `kart-category-service` pattern verbatim (same `HttpClient`-based fetch, same 10-minute `IMemoryCache` duration, same synchronous `IssuerSigningKeyResolver` delegate shape) — the Gateway's own `JwksSigningKeyResolver` class is a near copy, differing only in namespace and the configuration key it reads (`Identity:JwksUri`, identical key name).
  - Why: `kart-identity-service`'s `JwksEndpoints.cs` exposes `GET /.well-known/jwks.json` directly (no full OIDC discovery document exists to point `MetadataAddress` at — the same reason `kart-category-service`'s own resolver doc-comment gives); synchronous per-request introspection is exactly what `kart-identity-service/edge-cases.md`'s "Stale Revocation Under Stateless JWT Validation" already rejected ("Full introspection on every request defeats the stated purpose of edge JWT validation") — the Gateway inherits that same already-settled reasoning rather than re-litigating it.
  - Trade-off accepted: same 10-minute key-rotation-blind-spot window as `kart-category-service` already accepts (`edge-cases.md`'s "JWT validation failure modes") — consistent, not novel.
  - `ValidateIssuer`/`ValidateAudience` are both `false`, matching `kart-category-service`'s own configuration exactly, for the identical reason: `kart-identity-service`'s `JwtAccessTokenGenerator` sets neither claim on minted tokens today.

## Decision: JWT Forwarding vs. Internal Header

- **Requirement driving this:** BRD §18's literal "downstream services trust a signed internal header, not the raw client token" line, in tension with BRD §24's "re-checked at service" and every already-shipped downstream service's actual JWKS-validation implementation.
- Already resolved as a full ADR, not re-litigated here: **ADR-0023** (`docs/adr/0023-api-gateway-jwt-forwarding.md`) — the Gateway forwards the original client JWT unchanged; no internal-header format is minted. See that ADR for the full context/consequences. This entry exists only to record that this decision was made at the ADR level, per this doc's own convention of pointing to an existing resolution rather than duplicating it (matching how `kart-category-service/design-decisions.md` points to ADR-0010/ADR-0011 rather than re-deriving them).

## Decision: Identity Revocation-List Redis Access — Direct Shared-Infra Read

- **Requirement driving this:** requirement-spec §2's revocation-list check; `kart-identity-service/architecture.md`'s Dependencies table already names this exact edge from Identity's own side: "Shared-state (not a service-to-service call) | API Gateway | Redis-backed revocation list (`identity:revocation:*`)" — Identity writes, Gateway reads, same shared Redis deployment, no API call in either direction.
- **Options considered (3, already enumerated and decided from Identity's side in `edge-cases.md`'s "Stale Revocation Under Stateless JWT Validation"):** Direct shared-Redis key read (chosen from Identity's side) · Full synchronous token-introspection call to a (hypothetical) Identity API endpoint on every request · No revocation check at all, relying solely on the ~15-minute access-token TTL.
- **Decision (5 bullets):**
  - Chosen: The Gateway connects to the same Redis deployment `kart-identity-service`'s `RedisTokenRevocationStore` writes to, and reads two key shapes directly: `identity:revocation:token:{jti}` (existence check — if present, this specific token was explicitly revoked, e.g. via `POST /auth/logout`) and `identity:revocation:user:{userId}` (if present, its value is a Unix-seconds `revokedAt` marker — any token whose `iat` claim is at or before that value is revoked, e.g. via admin-lock, password-reset, forced role-change, or GDPR erasure).
  - Why: this is not a new pattern invented by this doc — it is the exact mechanism `kart-identity-service/architecture.md`'s own Dependencies table and Distributed-Monolith Risk section already commit the Gateway to from Identity's side ("a deliberate, narrow exception to 'access another service's data only through its API/events,' not a precedent to generalize"). Building anything else here (e.g. a Gateway-invented introspection call) would contradict an already-approved upstream doc, which `AGENTS.md` explicitly forbids doing silently.
  - Mechanism: `RevokeTokenAsync`/`RevokeAllForUserAsync` (`kart-identity-service`'s `ITokenRevocationStore`) are the write side; the Gateway implements only the read side — a `StackExchange.Redis` connection (same client library every other Kart service already uses for Redis), checking both keys per authenticated request, short-circuiting to "not revoked" only if *neither* key indicates revocation.
  - Ordering: the `token:{jti}` check and the `user:{userId}` check are independent and both must be evaluated — a token can be individually revoked (logout) without its user ever being globally revoked, and vice versa (admin-lock revokes every token for a user without needing to know each one's `jti`).
  - Trade-off accepted / HA posture: already addressed from Identity's own side (`kart-identity-service/architecture.md`'s Redundancy section commits this Redis cluster to Identity's own 99.99% HA posture specifically *because* the Gateway depends on it too) — this doc does not need to re-specify a separate HA design, only consume the one already committed to. See `edge-cases.md`'s "Redis revocation-check unavailable" for the fail-closed behavior on an outage of this dependency specifically.

## Decision: Rate Limiting — ASP.NET Core Built-In Middleware, Tiered Per Route

- **Requirement driving this:** BRD §18's Rate Limiting row: "Token-bucket per API key/user, tiered limits (anonymous < authenticated < partner API)"; requirement-spec §3 fixes this as needing concrete numbers since the BRD's own RPM table (§4.2) is system-wide, not per-caller-class.
- **Options considered (3):** ASP.NET Core's built-in `Microsoft.AspNetCore.RateLimiting` middleware (`System.Threading.RateLimiting`, part of the shared framework since .NET 7/8 — no extra NuGet package) with `AddTokenBucketLimiter` policies, partitioned per caller · A Redis-backed distributed rate limiter (e.g. a Lua-script token bucket in the same shared Redis), needed only if the Gateway runs as multiple replicas that must share one bucket state · A third-party rate-limiting library.
- **Decision (6 bullets):**
  - Chosen: ASP.NET Core's built-in token-bucket rate limiter, four named policies applied per route via YARP's route-level `RateLimiterPolicy` config key:
    | Tier | Partition Key | Tokens/Window | Window | Queue |
    |---|---|---|---|---|
    | `anonymous` | client IP | 60 | 1 minute | 0 (reject immediately) |
    | `authenticated` | JWT `sub` claim | 300 | 1 minute | 0 |
    | `partner` | JWT `sub`/client-credentials client id, `roles` contains `Partner API` | 1200 | 1 minute | 0 |
    | `admin` | JWT `sub` claim, `roles` contains `Admin` | 600 | 1 minute | 0 |
  - Why these numbers: not BRD-stated at this granularity — an explicit engineering default (flagged per `AGENTS.md`, not silently picked). Ordered to satisfy BRD §18's literal "anonymous < authenticated < partner API" ordering; `admin` is priced between `authenticated` and `partner` since back-office traffic is low-volume-per-operator but must not be starved by the same limit as anonymous browse traffic. All four are comfortably above what a single legitimate caller in that tier would generate against today's two routed services (auth + category-read/write), while still bounding a single caller's worst-case load on shared upstream capacity.
  - Why token-bucket specifically (vs. fixed/sliding window): BRD §18 names the algorithm explicitly ("Token-bucket per API key/user") — not re-derived, just implemented as stated, using .NET's own `TokenBucketRateLimiterOptions` (`TokenLimit`, `TokensPerPeriod`, `ReplenishmentPeriod`).
  - Why no Redis-backed distributed limiter yet: this release's Gateway is not yet specified to run as more than one replica behind a load balancer with sticky routing per limiter partition; the in-process `System.Threading.RateLimiting` limiter is the simplest mechanism that satisfies BRD §18 today. If/when the Gateway scales horizontally with non-sticky routing, a shared-state limiter (the same Redis deployment already in use for revocation) becomes the correct upgrade — flagged here as a known future revisit, not built speculatively now.
  - Rejected requests return 429 with `Retry-After` (`edge-cases.md`'s "Rate-limit exceeded" decision), computed in the limiter's `OnRejected` callback from the same `TokenBucketRateLimiterOptions.ReplenishmentPeriod` the policy is configured with.
  - Partition-key resolution order: routes requiring authentication resolve a partition key from the validated JWT (`sub` claim) — this only runs *after* JWT validation succeeds, so the rate limiter never has to distinguish "no token" from "bad token" itself; an anonymous-allowed route (e.g. `GET /v1/categories`) partitions purely on IP regardless of whether a token happens to be present.

## Decision: Adding a Future Service's Route (Extensibility Pattern)

- **Requirement driving this:** requirement-spec §5's "documented pattern for adding future services' routes as they come online" — required scope, not invented.
- **Decision (4 bullets):**
  - A new service's route is added as: one new YARP cluster (upstream base address) + one or more new YARP routes (path-prefix match → that cluster, with a `AuthorizationPolicy` — `"anonymous"` or `"authenticated"` — and a `RateLimiterPolicy` from the four tiers above) in `appsettings.json`, plus one new row in `api-contract.yaml`'s route table describing the same thing declaratively.
  - No change to the JWT-validation middleware, the revocation-check middleware, or the rate-limiter policy definitions themselves — all three are route-agnostic by construction (`requirement-spec.md` §5), which is the entire point of building them once, generically, in this release rather than per-route.
  - The new service's own `api-contract.yaml` (its actual domain API, produced by its own API Design Agent pass) is the source of truth for its path prefix and per-endpoint auth requirement (public read vs. bearer-required vs. `Admin`-gated) — this Gateway's route table is a thin routing/auth-tier/rate-tier projection of that, the same relationship this doc's own route table already has to `kart-identity-service`'s and `kart-category-service`'s contracts.
  - A route needing a *coarse* role gate beyond "authenticated or not" (e.g. a hypothetical future `/admin/*` prefix) adds a new named ASP.NET Core authorization policy (`RequireClaim("roles", "Admin")`, the exact claim shape `kart-category-service`'s own `AuthenticationExtensions.cs` already uses) and references it from that route's `AuthorizationPolicy` config key — no new mechanism, reusing the same claim-based policy pattern already proven downstream.

## Decision: Observability & Instrumentation

**Decision:** Serilog (structured logging) + OpenTelemetry SDK (distributed tracing + metrics), identical stack to every other Kart service (`kart-conventions.md` Observability section). The Gateway additionally originates the W3C Trace Context for every request (it is the first hop of any distributed trace, BRD §23), propagating `traceparent` into the proxied request's headers — YARP forwards headers by default, so this requires no extra code beyond the standard `OpenTelemetry.Instrumentation.AspNetCore`/`Http` instrumentation every service already wires.

**Options considered:** Ad-hoc gateway-specific logging/APM tool — rejected, fragments the single Grafana pane every other service already correlates through. Platform-standard Serilog + OpenTelemetry + Grafana LGTM stack — adopted, same reasoning `kart-category-service/design-decisions.md` already gives.

**Why:** the Gateway's primary correlation fields are `route`/`upstreamCluster` (which route/service a request was proxied to) alongside the mandatory `traceId`/`service`/`level`; the metric most worth alerting on is the 429/503 rate per tier/route — a spike there is the earliest signal of either an abusive caller (rate-limit tier) or an upstream/Redis outage (edge-cases.md's two failure-mode decisions above).

## Escalations

None. Every decision above resolves to one option on engineering grounds already stated in requirement-spec.md, edge-cases.md, an existing or newly-added ADR (ADR-0023), or an already-approved upstream service's own docs (`kart-identity-service/architecture.md`, `kart-category-service`'s shipped code) — none is a genuine business call (cost, vendor lock-in, team familiarity) between equivalent options; the "reuse the .NET stack every other service already uses" reasoning applies uniformly.

## Sign-off

- [x] Chosen technologies/patterns reviewed — Automated architecture pipeline, autonomous completion authorized by project owner per `AGENTS.md`'s defensible-engineering-default rule
- [x] Approved to proceed to Architecture Agent
