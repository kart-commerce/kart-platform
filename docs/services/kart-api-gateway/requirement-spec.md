---
doc_type: requirement-spec
service: kart-api-gateway
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-api-gateway

## 1. Scope

Covers the single BRD component **API Gateway** (BRD §18, plus the enforcement flow named in §24.1.3 and the reverse-proxy topology in §19). This is not a bounded-context service in the DDD sense — it owns no domain aggregates, no database, and publishes no events (see `ddd-model.md` for why this is stated explicitly rather than force-fitting a fake aggregate). It is cross-cutting platform infrastructure: the single entry point every client request passes through before reaching a bounded-context service.

Release scope is fixed by `docs/releases/generated/release-0-platform-bootstrap.md`: **"gateway skeleton + routing config."** This is deliberately a skeleton, not a feature-complete edge for all 18 eventual Kart services — only two backend services exist today (`kart-identity-service`, `kart-category-service`), so this pass designs the routing/auth/rate-limit mechanism generically and wires exactly those two services' real path prefixes, plus a documented pattern for adding each future service's route as it comes online (§5).

**Topology note (BRD §19):** Nginx sits in front of this Gateway for TLS termination, static asset serving, and request buffering — a distinct reverse-proxy role from this Gateway's own job (auth, rate limiting, routing to backend services). This spec covers the Gateway only; Nginx's own configuration is out of scope here and not this repo's concern.

## 2. Functional Requirements

- **Path-based request routing** to backend services, with a version prefix, per BRD §18's Routing row ("Path-based routing to services (`/orders/*` → Order Service) with version prefix (`/v1/`)"). Concretely for this release: `/v1/auth/*` and `/.well-known/jwks.json` → `kart-identity-service`; `/v1/categories*` → `kart-category-service`. See `api-contract.yaml` for the full route table and §5 below for how a future service's route is added.
- **JWT validation at the edge** (BRD §18's Authentication row): every request to a route that requires authentication is checked for a structurally valid, non-expired, RS256-signed JWT before being proxied upstream. The signing key is retrieved from Identity's `GET /.well-known/jwks.json` (cached, not a per-request call — matching `kart-identity-service/architecture.md`'s Dependencies table: "JWKS public-key retrieval ... but cached and infrequent — not a per-request round trip") and the exact JWKS-fetch-and-cache pattern already shipped in `kart-category-service`'s `JwksSigningKeyResolver.cs` is reused verbatim, not reinvented (`design-decisions.md`).
- **Forwarding, not replacing, the validated JWT.** BRD §18's literal text ("downstream services trust a signed internal header, not the raw client token") is superseded for this platform by **ADR-0023** (`docs/adr/0023-api-gateway-jwt-forwarding.md`), which resolves the conflict between that line and BRD §24's "re-checked at service" AuthZ row plus the already-shipped downstream JWKS-validation code in `kart-category-service`/`kart-identity-service`. The Gateway forwards the original `Authorization: Bearer <token>` header unchanged; it does not mint a second internal-header format.
- **Coarse-grained RBAC route gating** (BRD §24.1.3, check #1 of "Three Checks, Not Two"): a route that requires a given coarse role (e.g. an eventual `/admin/*` prefix requiring `Admin`) rejects the request at the edge if the JWT's `roles` claim doesn't carry it, before the request ever reaches the owning service. No route in this release's two-service scope needs this beyond the generic bearer-required/anonymous distinction (`api-contract.yaml`) — Category's own write endpoints already re-check `Admin` themselves (`kart-category-service/api-contract.yaml`'s `clientCredentials` scheme), and neither exposed route needs a second coarse gate the owning service doesn't already perform. The mechanism (an ASP.NET Core authorization policy per route) is built now so a future `Admin`-gated route only needs a route-table entry, not new code.
- **Revocation-list check** (`kart-identity-service/architecture.md`'s Dependencies table, "Shared-state (not a service-to-service call) | API Gateway | Redis-backed revocation list (`identity:revocation:*`)"): on every request bearing a validated JWT, the Gateway checks the same Redis key space Identity writes to on logout/role-change/admin-lock/erasure, and rejects the request (401) if the token's `jti` or its subject's revoked-at marker indicates the token is revoked-but-unexpired. This is a **shared-infrastructure read**, not a call to any Identity API — see `design-decisions.md` for why this is a deliberate, narrow exception to "access another service's data only through its API/events" (already named as such in Identity's own architecture.md), not a new pattern invented here.
- **Per-route, tiered rate limiting** (BRD §18's Rate Limiting row: "Token-bucket per API key/user, tiered limits (anonymous < authenticated < partner API)"). Concrete tier numbers are not stated anywhere in the BRD at the per-caller granularity this requires (the BRD's own RPM table, §4.2, gives *system-wide* traffic tiers, not per-caller-class limits) — §3 below fixes engineering-default numbers explicitly, as a defensible default rather than a silently invented one.
- **Upstream failure isolation**: a route whose upstream is down or slow does not cascade into the Gateway itself becoming unavailable for other routes — see `edge-cases.md`'s "Upstream service down or circuit-open."
- **Request size limiting**: a request body exceeding a configured limit is rejected at the edge before being proxied, rather than forwarded to (and potentially exhausting resources on) an upstream service. See `edge-cases.md`.

## 3. Non-Functional Requirements

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.99% (platform's highest tier, by construction) | Every authenticated request platform-wide passes through the Gateway (BRD §18); an outage here is an outage for the whole platform, not one bounded context. Matches Identity's own stated tier for the same "everything depends on this at request time" reasoning (`kart-identity-service/architecture.md`) |
| Latency | Added edge overhead budget: P95 < 20ms, P99 < 50ms on top of whatever the proxied upstream call itself takes | Not BRD-stated at this granularity — an explicit engineering default. The Gateway's own work per request (JWT signature check against a cached key, one Redis round-trip for revocation, one rate-limiter decision, then proxy) must stay a small fraction of the platform's overall P95 < 150ms / P99 < 400ms read-path budget (BRD §3) that every routed service already carries |
| Rate Limiting | Token-bucket, tiered: anonymous < authenticated < partner API < admin (see `design-decisions.md` for the concrete per-tier RPM numbers) | BRD §18's stated algorithm and tiering order, literally |
| Reliability | Fail closed on JWT/revocation-check infrastructure failure (reject the request), fail per-route on upstream failure (circuit breaker, does not take down other routes) | BRD §3's general reliability posture, applied to the two distinct failure classes a gateway faces — see `edge-cases.md` for the fail-open-vs-fail-closed reasoning on the revocation check specifically |
| Observability | Serilog (structured JSON logs) + OpenTelemetry SDK (traces/metrics), same stack every Kart service uses (`kart-conventions.md` Observability section) — plus W3C Trace Context propagation into every proxied request, since the Gateway is the first hop of every distributed trace on the platform (BRD §23: "a single order can be traced across all 8+ services it touches") | BRD §23 (mandatory stack); the Gateway's specific role as trace *originator*, not just another participant |
| Security | TLS 1.3 in transit (terminated at Nginx per BRD §19, re-established or passed through to the Gateway per the cluster's own network policy — out of scope for this doc); no payment/PII data logged from headers/bodies passing through | BRD §24 Encryption row; standard platform default, no gateway-specific exception |

## 4. Domain Invariants

None. This is a deliberate, explicit statement, not an omission — see `ddd-model.md` for the full reasoning. The Gateway holds no aggregate with business invariants of its own; its only "state" is the route table (static configuration, not domain data) and ephemeral, Identity-owned Redis reads it never writes to.

## 5. API Surface (from BRD, starting point only)

This is a **routing config contract**, not a domain API — see `api-contract.yaml` for the full route table (path prefix → upstream service, auth requirement, rate-limit tier per route).

| Route Prefix | Upstream | Notes |
|---|---|---|
| `/v1/auth/*` | `kart-identity-service` | Public AuthN surface (`kart-identity-service/api-contract.yaml`'s `/auth/*` paths under its own `/v1` server prefix). No bearer token required to reach `/auth/login`/`/auth/register` themselves (a caller has no token yet); `/auth/logout`, `/auth/refresh`, `/auth/mfa/verify` etc. do require one — see `api-contract.yaml` for the per-path breakdown |
| `/.well-known/jwks.json` | `kart-identity-service` | Unversioned (IANA well-known convention, matching Identity's own contract); proxied for any external consumer, though the Gateway itself talks to Identity's JWKS endpoint directly (not through its own proxy route) for its own signing-key cache |
| `/v1/categories*` | `kart-category-service` | `kart-category-service/api-contract.yaml`'s five paths (`GET /categories`, `POST /categories`, `PATCH/DELETE /categories/{categoryId}`, `POST /categories/{categoryId}/move`) under its own `/v1` server prefix. Read path (`GET`) is anonymous-allowed; the four write paths require a bearer token (Category's own `clientCredentials` scheme re-checks the `Admin` role itself — the Gateway's own auth requirement here is "authenticated," not "Admin-gated," since the fine-grained check per §24.1.3 belongs to Category, not the Gateway) |
| **Not routed today, explicitly:** `/internal/*` (e.g. Identity's `POST /internal/users/{userId}/lock`/`unlock`) | n/a | `kart-identity-service/architecture.md`'s own Dependencies table names this as a direct Admin-Service-to-Identity call, not a Gateway-proxied one ("Inbound (service-to-service) | Admin Service | ... | Sync (internal, client-credentials, `Admin`-scoped only)" — no Gateway hop in that row). Routing it through the Gateway would contradict that already-approved edge; this doc does not add scope Identity's own docs didn't ask for |

Adding a future service's route (e.g. once `kart-order-service` exists) is a routing-config addition only — new entries in `api-contract.yaml` and the corresponding YARP cluster/route config (see `design-decisions.md`'s "Adding a Future Service's Route" note) — never a code change to the Gateway's auth/rate-limit/revocation middleware, which are route-agnostic by construction.

## 6. Open Questions / Flagged Ambiguities

**Resolved this pass:**

1. *BRD §18 ("signed internal header") vs. §24 ("re-checked at service") vs. already-shipped downstream JWKS-validation code* — resolved by new **ADR-0023** (`docs/adr/0023-api-gateway-jwt-forwarding.md`): the Gateway forwards the original client JWT; it does not mint an internal header. See §2.
2. *Concrete rate-limit tier numbers* — not stated in the BRD at per-caller granularity; resolved as an explicit engineering default in `design-decisions.md`, not silently picked.
3. *Fail-open vs. fail-closed on revocation-check/JWKS-fetch infrastructure failure* — resolved in `edge-cases.md`: fail closed (reject) on a JWT/revocation-check infrastructure failure, since Identity's own edge-cases.md already accepts a bounded stale-revocation window as the *expected* case, not the infrastructure-failure case — silently letting every request through on a Redis outage would materially widen that already-accepted window rather than staying inside it.

**Carried forward (non-blocking).** Normal handoffs to later stages, not gaps:

- Exact YARP cluster/route JSON shape (`appsettings.json`) is the Coding Agent's/scaffold's own job, not re-derived here — `design-decisions.md` and `api-contract.yaml` fix the shape (path prefix, auth requirement, rate-limit tier) that config must express, not its literal JSON.
- Whether a future service's route needs a coarse `Admin`/`Support Agent`/`Partner API` gate at the Gateway (beyond "authenticated or not") is that future pass's own call, following the pattern this doc already establishes — not pre-decided here for services that don't exist yet.

## Sign-off

- [x] Blocking open questions resolved
- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner, per `AGENTS.md`'s defensible-engineering-default rule
- [x] Approved to proceed to Architecture Agent
