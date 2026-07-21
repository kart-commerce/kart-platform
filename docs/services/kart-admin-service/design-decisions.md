---
doc_type: design-decisions
service: kart-admin-service
status: proposed
generated_by: design-decision-agent
source: docs/services/kart-admin-service/requirement-spec.md, docs/services/kart-admin-service/edge-cases.md
---

# Design Decisions: kart-admin-service

Cross-cutting technology/pattern choices this service's requirement-spec and edge-cases force. Service boundaries, domain model, and schema are out of scope here (Architecture/DDD/Database Design Agents). Q1 (fine-grained permission model) and Q2 (back-office operation enumeration), flagged blocking in an earlier pass, are already closed as business/domain decisions in `requirement-spec.md` §6 Decision items 1–2 and ADR-0010 (`docs/adr/0010-admin-service-scope-and-integration.md`) — not re-decided here; this doc only adds the technology/pattern layer on top of them.

## Decision: Concurrency Control for Back-Office Writes

- **Requirement driving this:** `edge-cases.md`'s "Concurrent Admins Editing the Same Back-Office Record"; Consistency NFR (`requirement-spec.md` §3 — "a stale read is a security or operational-correctness defect, not a UX one")
- **Options considered (3):** Optimistic concurrency control (version/ETag token, conditional update, reject the stale writer) · Pessimistic row-level locking for the duration of an admin edit · No concurrency control (last-write-wins)
- **Decision:**
  - Chosen: Optimistic concurrency control via a version token — enforced locally as a row version on Admin's own `admin_permission_grants` table for grant/revoke writes, and carried as an `If-Match`/version precondition on every synchronous outbound call Admin makes to an owning service's write API (Product, Category, Offer, Identity, Inventory), since ADR-0010 keeps the domain record itself — and thus its own version column — with the owning service, never a copy inside Admin
  - Why: matches `edge-cases.md`'s chosen fix directly; admin actions are infrequent and human-paced (per requirement-spec §6 Decision D4's own reasoning), so lock contention is not a throughput concern, and rejecting a stale writer forces the second admin to see the first admin's change before proceeding
  - Trade-off accepted: the losing admin's action is rejected and must be manually re-read and retried, never silently merged; this also requires each of the four owning services' write APIs to actually expose a version/ETag Admin can read-then-replay — carried forward as a cross-service API contract expectation for the Architecture/API Design stage, not decided here

## Decision: Audit Trail Publication Atomicity (Transactional Outbox)

- **Requirement driving this:** Domain Invariant #2 and `requirement-spec.md` §6 Decision item 7; `edge-cases.md`'s "Admin Action Succeeds but `AdminActionPerformed` Is Lost"; Reliability NFR (§3)
- **Options considered (3):** Transactional Outbox (write the `AdminActionPerformed` row into the same local PostgreSQL transaction as Admin's own local record of the action; a poller publishes after commit) · Synchronous publish-then-commit (publish first, commit the local record only on broker ack) · Best-effort fire-and-forget publish with no transactional guarantee
- **Decision:**
  - Chosen: Transactional Outbox, matching the BRD §11 platform-wide default already adopted by every other write-path service
  - Why: already the platform's standard fix for this exact dual-write failure mode; reusing it avoids inventing a one-off mechanism for the platform's highest-privilege write path, and this is exactly what `edge-cases.md` already decided
  - Trade-off accepted: poller latency (the event becomes visible to Analytics slightly after the local commit, not synchronously); the outbound synchronous call to the owning service must complete and succeed *before* Admin's local record/outbox row is committed, so a crash strictly between "remote call succeeded" and "local commit" is the one residual gap the Outbox pattern alone does not close — that ordering is an implementation detail carried to the coding stage, not a second pattern decided here

## Decision: Communication Style for Outbound Calls to Owning Services

- **Requirement driving this:** ADR-0010 Decision 2 (Admin invokes each owning service's own write API synchronously, internal client-credentials call); `api-standards.md`'s gRPC restriction ("reserved for internal, high-throughput synchronous calls only")
- **Options considered (3):** Synchronous REST/HTTP call to each owning service's own versioned write endpoint (client-credentials OAuth2 token) · Synchronous internal gRPC call · Async messaging (command event with correlation-based response)
- **Decision:**
  - Chosen: Synchronous REST/HTTP, against each owning service's own standard write API
  - Why: Admin's calls are low-volume, human-paced back-office writes — confirmed absent from the Order Saga and every high-throughput path (requirement-spec §3 Availability row) — not the high-throughput case `api-standards.md` reserves gRPC for; async messaging is ruled out because Admin must know the owning service's write succeeded before it commits its own local audit record (previous Decision), which a fire-and-forget event cannot guarantee
  - Trade-off accepted: Admin's own write-path latency is now coupled to each downstream owning service's availability for that call, bounded only by the resilience pattern below, rather than decoupled via a queue

## Decision: Resilience Pattern for Outbound Calls to Owning Services

- **Requirement driving this:** Latency NFR (`requirement-spec.md` §3 — P95 < 300ms write ceiling including the Outbox insert); ADR-0010's five new synchronous dependency edges (Product, Category, Offer, Identity, Inventory) flagged as "not yet drawn in BRD §5.5"; `edge-cases.md`'s "Over-Broad `/admin/*` Surface" decision to keep blast radius domain-scoped
- **Options considered (3):** Timeout budget carved from the write ceiling + small bounded retry (idempotent-safe only) + one independent circuit breaker per downstream owning service · Timeout only, no retry or circuit breaker · Unbounded retry with no circuit breaker
- **Decision:**
  - Chosen: A short per-call timeout carved out of the 300ms P95 write budget, a small bounded retry (made safe by the Idempotency-Key mechanism below), and five independent circuit breakers — one per owning service — rather than one shared breaker
  - Why: Admin now depends synchronously on five services it never called before; a single slow or down dependency must not silently blow Admin's own write-path P95 or cascade into unrelated categories — independent breakers keep, e.g., a Category Service outage from also degrading user-suspension or coupon-issuance actions, consistent with the domain-scoped blast-radius decision already made in `edge-cases.md`
  - Trade-off accepted: an admin action fails fast with a clear "downstream unavailable" error rather than queuing indefinitely — a transient blip in one owning service blocks only that one category of admin action, with no automatic async fallback

## Decision: Idempotency Mechanism for Outbound Write Calls

- **Requirement driving this:** `api-standards.md` ("`Idempotency-Key` header is mandatory on every ... non-retry-safe write"); the bounded-retry resilience decision above, which requires retries to be safe; Domain Invariant #2 (action and its audit record must not silently diverge, including via an unsafe retry producing a duplicate effect)
- **Options considered (3):** `Idempotency-Key` generated once per admin-action attempt, stored with Admin's pending local action record before the outbound call, and forwarded on every retry to the owning service's write API for server-side dedupe · No idempotency key — rely on the human operator to notice and avoid double-submission · Client-side-only dedupe (Admin checks its own local log before retrying, no key passed downstream)
- **Decision:**
  - Chosen: `Idempotency-Key` generated per admin-action attempt and forwarded on every retry of that action
  - Why: back-office actions are the platform's highest-privilege operations — double-issuing a coupon or double-locking a user is a real high-impact effect, not a cosmetic one — so this reuses the same mandatory mechanism `api-standards.md` already requires for non-retry-safe writes rather than inventing a bespoke one for this service
  - Trade-off accepted: each of the four owning services' write APIs must accept and honor this header for the retry-safety the resilience decision above depends on — carried forward as a cross-service API contract expectation for the Architecture/API Design stage, the same five dependency edges ADR-0010 already flags as new

## Decision: Caching Strategy for Fine-Grained Permission Grants

- **Requirement driving this:** Domain Invariant #1 (`admin_permission_grants` looked up fresh on every request, unlike the JWT-embedded coarse claim); `edge-cases.md`'s "Stale Admin Permission Outliving an Identity-Side Revocation" (fine-grained check "always consults its own `admin_permission_grants` table live, per request"); Consistency NFR ("an RBAC permission check ... reading stale state is a security or operational-correctness defect")
- **Options considered (3):** No caching — query `admin_permission_grants` directly on every `/admin/*` request · Cache-aside with a short TTL · Write-through cache invalidated synchronously on every grant/revoke
- **Decision:**
  - Chosen: No caching; every `/admin/*` handler reads `admin_permission_grants` fresh in the same request
  - Why: this is the exact mechanism `edge-cases.md`'s revocation decision already relies on to get "no token-TTL exposure window at all" for the fine-grained layer — any TTL or invalidation-lag would reopen precisely the staleness window that decision was chosen to close
  - Trade-off accepted: one extra synchronous, indexed point-lookup per admin action versus a cached read — acceptable given Admin's low, human-paced request volume (the same reasoning `requirement-spec.md` §6 Decision D4 uses for its availability/latency tier) and given ample headroom under the 300ms write ceiling

## Sign-off

- [ ] Reviewed by human before Architecture Agent runs against this service (per design-decision-agent's Human Approval Required gate)
