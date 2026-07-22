---
doc_type: design-decisions
service: kart-identity-service
status: approved
generated_by: design-decision-agent
source: docs/services/kart-identity-service/requirement-spec.md, docs/services/kart-identity-service/edge-cases.md
---

# Design Decisions: kart-identity-service

Cross-cutting technology/design-pattern choices this service's requirement-spec.md and edge-cases.md force, beyond what those two docs already settled themselves. Where a decision was already fully resolved in requirement-spec.md/edge-cases.md (MFA mechanism, session/refresh-token TTLs, refresh-token-reuse response, external-IdP role mapping, JIT account provisioning), it is **not re-decided here** — it is cited as the grounding for the technology/pattern choice that generalizes from it, per this agent's own rule against re-deriving an already-made call.

## Decision: Shared State-Store Technology for Ephemeral Security State

- **Requirement driving this:** edge-cases.md independently proposes short-lived, TTL-scoped server-side state in three places — the Redis-backed revocation list ("Stale Revocation Under Stateless JWT Validation," also reused for role-change staleness per "RBAC Role Change Outlives an Already-Minted JWT"), the MFA partial-auth challenge state ("Partial-Auth Window During MFA"), and the SAML consumed-assertion-ID cache ("SAML Assertion Replay at the ACS Endpoint") — without naming one consistent store for the latter two.
- **Options considered (3):** One shared Redis instance/cluster for all ephemeral security state (revocation list, MFA challenge state, SAML assertion-ID cache), each in its own key namespace · A separate purpose-built store per use case (e.g., in-memory/local cache for MFA challenge state) · Persist all three in PostgreSQL with an expiry column and a cleanup job
- **Decision (5 bullets max):**
  - Chosen: A single shared Redis deployment, namespaced per use case (`identity:revocation:*`, `identity:mfa-challenge:*`, `identity:saml-assertion:*`), consistent with the platform's standard Redis usage (`PLATFORM_BLUEPRINT.md` §15 Redis row) and the store edge-cases.md already names explicitly for the revocation list.
  - Why: All three are the same shape of problem — short-lived, TTL-bounded, must-be-visible-to-every-instance state — and edge-cases.md already committed to Redis for one of them; introducing a second technology (in-memory cache, which breaks under horizontal scaling since a Gateway/Identity instance other than the one that wrote the state can't see it) or a third (PostgreSQL, which adds unnecessary write load to the strong-consistency store for data that is inherently non-relational and self-expiring) for the other two would fragment operational tooling for no gain.
  - Trade-off accepted: Identity's login, logout, MFA-verify, and SAML-callback paths all now have a hard runtime dependency on Redis availability — mitigated by the Resilience Pattern decision below, but not eliminated; Redis becomes a single shared failure domain across three previously-independent edge-case fixes.

## Decision: Concurrency Control for Refresh-Token Rotation

- **Requirement driving this:** Domain Invariant §4 ("a refresh token must be single-use and rotated on every refresh") combined with the Consistency NFR ("strong (PostgreSQL write path)... a stale... 'still valid' read is a security defect"); edge-cases.md's "Concurrent Refresh Race (Double-Spend on One Refresh Token)" already resolves the specific race but the underlying pattern is this service's general concurrency-control default for token-state writes.
- **Options considered (3, per edge-cases.md):** DB-level conditional update (`UPDATE ... WHERE consumed = false`, atomic on PostgreSQL) · Distributed lock keyed on the token/session before allowing rotation · Optimistic retry (both requests proceed, reconcile after, revoke on conflict)
- **Decision (4 bullets max):**
  - Chosen: DB-level conditional update (optimistic conditional write), as already decided in edge-cases.md — generalized here as this service's concurrency-control pattern for token-state mutation generally (refresh-token consumption, token-family revocation-on-reuse), not just the one race it was first identified against.
  - Why: Gets atomicity from the existing PostgreSQL store the Consistency NFR already mandates, instead of adding a distributed-lock component (Redis-based or otherwise) as a second point of coordination for the same guarantee Postgres already provides.
  - Trade-off accepted: A losing concurrent request must be handled as a normal, expected outcome (retry / fall into the reuse-detection path) by every caller of the rotation write, not treated as an infrastructure error — this is an API/error-contract obligation the API Design Agent must carry forward, not just an internal implementation detail.

## Decision: Event Publication Reliability — Transactional Outbox on RabbitMQ

- **Requirement driving this:** the Latency NFR's write-path row explicitly names "Outbox insert" as part of `/auth/login`'s write path; the Reliability NFR requires "at-least-once delivery + idempotent consumers" for `UserRegistered`, `SessionCreated`, and `UserAccountUpdated` (ADR-0007, ADR-0006); edge-cases.md's "Out-of-Order Delivery of Successive `UserAccountUpdated` Events" additionally requires an ordering-safe payload for that one event without moving it off the platform's messaging default.
- **Options considered (3):** Transactional Outbox (event row written in the same PostgreSQL transaction as the domain write, relayed to RabbitMQ by a separate publisher) · Dual write (publish to RabbitMQ directly, then commit the DB write, or vice versa) · Move to Kafka with partition-by-`userId` for native per-entity ordering
- **Decision (5 bullets max):**
  - Chosen: Transactional Outbox, publishing to the platform's default RabbitMQ topic exchange (`ecommerce.events`, per `docs/standards/kart-conventions.md`) — not Kafka — with `UserAccountUpdated`'s payload carrying an added monotonic `updatedAt`/sequence field per edge-cases.md's own decision, so User Service applies last-write-wins by version rather than relying on RabbitMQ delivery order.
  - Why: The NFR table already assumes an Outbox insert exists on the write path, so this formalizes rather than introduces a component; dual-write is explicitly the failure mode the Outbox pattern exists to avoid (a DB commit and a broker publish can never be made atomic any other way without XA/2PC, which this platform does not use); moving to Kafka for one low-volume event type just to get partition ordering is the option edge-cases.md itself already rejected in favor of the cheaper versioned-payload fix.
  - Trade-off accepted: Consumers of `UserAccountUpdated` (User Service) must implement version-aware apply logic instead of naive overwrite-on-receipt — a small consumer-side cost accepted in exchange for not taking Identity off the platform's RabbitMQ default.
  - Retry/DLQ tiers (3x `UserRegistered`, 2x `SessionCreated`, 2x `UserAccountUpdated`, all `identity.dlq`) are already fixed by ADR-0007/ADR-0006 and requirement-spec.md §5 — not re-decided here, only the delivery mechanism producing them.
  - Note: the added `updatedAt` field on `UserAccountUpdated` remains, per edge-cases.md, a proposed contract addition for the Architecture/Event-Design Agent to confirm when the schema is finalized — not treated as already-approved here.

## Decision: Resilience Pattern for External IdP Calls (SSO Federation)

- **Requirement driving this:** Identity is stated as "the platform's sole point of contact with any external IdP" (Domain Invariant §4, BRD §24.2) — its only synchronous outbound dependency on a system Identity does not control; the platform's general Resilience standard (`PLATFORM_BLUEPRINT.md` §15: "Circuit breaker on every synchronous outbound call... bulkhead isolation per dependency; explicit timeout budgets; degrade gracefully rather than cascade") applies directly, and nothing in requirement-spec.md/edge-cases.md already covers this specific external-dependency call — the carried-forward SLO gap (§6 item 1) addresses the reverse direction (IdP deprovisioning), not this outbound-call resilience question.
- **Options considered (3):** Apply the platform-default circuit breaker + bulkhead + explicit timeout budget, scoped per configured IdP · No isolation — treat every enterprise IdP's SAML/OIDC endpoint as equally reliable as Identity's own infrastructure · Defer/async the federation exchange (queue the assertion, respond later) instead of handling it inline
- **Decision (4 bullets max):**
  - Chosen: Platform-default circuit breaker, bulkhead isolation, and an explicit timeout budget, each scoped **per configured enterprise IdP** (Okta/Azure AD/Google Workspace are each an independent bulkhead), plus the social-login OIDC providers as their own bulkhead group separate from enterprise SAML/OIDC.
  - Why: Per-IdP scoping means one customer's slow or down enterprise IdP trips its own breaker and degrades only federated logins against that specific IdP — it cannot cascade into native email/password login, other customers' federation, or customer social login, matching the platform's "degrade gracefully rather than cascade" rule.
  - Trade-off accepted: An inline, synchronous request-response exchange is retained (federation cannot be deferred — SAML ACS/OIDC callback is inherently a redirect-and-respond flow within the user's browser session) rather than an async pattern, and per-IdP breaker/timeout configuration is additional operational config the Architecture Agent must account for when adding each enterprise customer's IdP.

## Decision: Communication Style for Admin-Triggered Suspension

- **Requirement driving this:** requirement-spec.md §2's admin-suspension FR and ADR-0010 (`docs/adr/0010-admin-service-scope-and-integration.md`) both state Admin Service invokes Identity's own write API synchronously — this is a communication-style choice (sync REST vs. gRPC vs. an event Identity would have to consume) squarely in this agent's remit, formalized here rather than re-litigated.
- **Options considered (3):** Synchronous internal REST endpoint (`POST /internal/users/{userId}/lock` / `.../unlock`) · Internal gRPC call · An event Identity consumes from Admin Service
- **Decision (4 bullets max):**
  - Chosen: Synchronous internal REST, per ADR-0010 and requirement-spec.md §2/§5.
  - Why: gRPC is reserved, per `docs/standards/api-standards.md` and `PLATFORM_BLUEPRINT.md` §15, for internal **high-throughput** synchronous calls (e.g., an inventory reserve check) — admin-triggered lock/unlock is a low-frequency, human-triggered back-office action that doesn't meet that bar, so plain REST is the standards-consistent default; an event is ruled out because ADR-0010 already assigns this integration pattern as "owning service's write API invoked by Admin as a caller," and requirement-spec.md §5 confirms Identity's Consumes list stays empty by design.
  - Trade-off accepted: None material — this is the standards-consistent default, not a genuine trade-off between comparably-viable options.

## Decision: JWT Signing Algorithm

- **Requirement driving this:** BRD §18 / requirement-spec.md §2 states the Gateway validates the JWT at the edge and "every other service trusts" it; Domain Invariant §4 states Identity is "the platform's single issuer of role/permission claims; no other service may maintain its own independent role or permission table as a second source of truth"; the Security NFR requires "zero plaintext secrets" and "signed tokens."
- **Options considered (3):** RS256 (RSA, asymmetric — Identity holds the private signing key, every verifying service/Gateway holds only the public key) · HS256 (HMAC, symmetric — the same shared secret must be distributed to and held by every verifying service) · ES256 (ECDSA, asymmetric, smaller keys/faster verification, but unstated whether all 18 services' JWT libraries/language stacks support it uniformly)
- **Decision (4 bullets max):**
  - Chosen: RS256.
  - Why: An asymmetric scheme keeps Identity's private signing key exclusively at Identity — matching the single-issuer invariant literally, since HS256 would require distributing the same shared verification secret to every one of the platform's other services, itself becoming a second copy of a secret that must stay in sync across ~18 codebases (the same anti-pattern the single-issuer invariant exists to prevent, recurring at the key-material layer instead of the role-table layer). ES256 is not chosen only because, unlike RS256, its support across every consuming service's JWT library stack is not something requirement-spec.md/edge-cases.md state or can confirm — RS256 is the safer, universally-supported industry default.
  - Trade-off accepted: RS256 tokens/signatures are larger and verification is more CPU-costly than HMAC — accepted given the Security NFR's explicit priority and that token size is not named as a constraint anywhere in the spec.

## Decision: Caching Strategy for Role/Group-Mapping Resolution (No Cache)

- **Requirement driving this:** the Latency NFR states "token-mint-time role resolution (§24.1) adds work to that same critical path" as the reason for the login/refresh latency target, creating pressure to cache; the Consistency NFR simultaneously states "a stale... 'wrong role' read is a security defect, not a UX one," and Domain Invariant §4's fail-closed IdP group→role mapping rule depends on reading the *current* mapping table, not a possibly-stale cached one (an operator adding a new mapping entry must take effect immediately, not after a cache TTL).
- **Options considered (3):** No cache — read the group→role mapping table directly from PostgreSQL on every token mint, under strong consistency · Cache-aside per the platform's default caching standard (`PLATFORM_BLUEPRINT.md` §15 Caching/Redis rows), with explicit invalidation on mapping-change · TTL-only cache with a short expiry as a compromise
- **Decision (4 bullets max):**
  - Chosen: No cache — direct, strongly-consistent PostgreSQL read of the group→role mapping table at token-mint time.
  - Why: This is a stated, service-specific divergence from the platform's default cache-aside standard: a stale read of this specific table is a direct security defect (a just-revoked mapping still granting a role, or a just-added mapping not yet taking effect for a new hire), which the Consistency NFR treats as categorically worse than the latency cost of an indexed lookup against a small, infrequently-changed config table. A TTL-only cache was rejected for the same reason a TTL-only cache is rejected platform-wide for price-sensitive data (`PLATFORM_BLUEPRINT.md` §15 Caching row: "never TTL-only... for price-sensitive data") — here the sensitive value is a role grant, not a price, but the same staleness argument applies.
  - Trade-off accepted: Every federated login pays a direct-DB-read cost for role resolution instead of a cache hit; acceptable because the table is small (one row per configured IdP group) and indexed, so this is not expected to be the dominant cost against the stated P95/P99 latency targets — the Architecture Agent should confirm this with the actual query plan once the mapping table's schema is designed.

## Sign-off

- [x] Chosen technologies/patterns reviewed by a human — Automated architecture pipeline, autonomous completion authorized by project owner
- [x] Approved to proceed to Architecture Agent
