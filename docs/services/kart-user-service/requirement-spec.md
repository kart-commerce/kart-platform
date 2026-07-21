---
doc_type: requirement-spec
service: kart-user-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-user-service

## 1. Scope

Covers the **User Service** (BRD §2.1 item 2: "Profile, addresses, preferences"). No merge, no ADR for scope itself — this is a single BRD service, unlike `kart-offer-service`.

The BRD's treatment of User Service is condensed to one row in §5.4's "Remaining Services (condensed)" table plus the one-line responsibility in §2.1. It is not given a dedicated deep-dive section (unlike Order, Inventory, Payment at §5.1–5.3), is not named in §2.2's "Domain Rules That Force Hard Engineering Decisions," and does not appear in the Service Boundary Diagram (§5.5). This spec works from that limited material and does not invent detail the BRD doesn't support — the few genuine gaps that remain after the closure pass below (§6) are named explicitly rather than papered over.

The Identity/User data-ownership boundary — the one place this condensation could have caused real ambiguity — is resolved by **ADR-0006** (`docs/adr/0006-identity-user-profile-sync-event.md`): Identity owns login-credential-adjacent fields (email, display name) as source of truth and publishes `UserAccountUpdated` on change; User Service owns the broader profile (addresses, preferences) and keeps a denormalized, eventually-consistent copy of email/display name via that event. See §6 for how this closes the former Open Question 1.

## 2. Functional Requirements

- Serve a user's profile via `GET /users/{id}`, sourced from the MongoDB read projection (BRD §5.4).
- Accept profile writes against the PostgreSQL write model and publish `UserProfileUpdated` after a successful write, projected asynchronously into MongoDB via the platform's standard Outbox pipeline (BRD §5.4, §7 CQRS Design, §11 Outbox Pattern). The exact HTTP verb/path split for reads vs. writes is left to the API Design Agent — see §7.
- Initialize a User Service profile record upon consuming `UserRegistered`, published by Identity Service at account registration (BRD §5.4, BRD §10 Event Catalog) — the profile write model is seeded by, and downstream of, Identity's registration flow, not the reverse.
- Consume `UserAccountUpdated` (payload: `userId`, `email`, `displayName`), published by Identity Service whenever a login email or display name changes after registration, and reconcile it into User Service's own denormalized copy of those fields (BRD §5.4, §10; ADR-0006). This is the resolution to the email/contact-field-drift concern previously flagged in this spec and in edge-cases.md.
- Store and manage addresses associated with a user (BRD §2.1 item 2: "addresses"). Concrete schema decision (the BRD gives only the noun, no structure — see §6, formerly Open Question 5): a user may hold zero or more addresses; each address record has a `type` (`shipping` | `billing` | `other`), structured fields (`line1`, `line2`, `city`, `region`, `postalCode`, `countryCode`, `phone`), and an `isDefault` flag scoped per type (at most one default `shipping` address and one default `billing` address at a time). This is the industry-standard shape for this exact domain object (comparable to every major e-commerce platform's address book) and is the minimum structure Order/Shipping need to receive as an opaque object at checkout time — it does not force any schema decision onto those services.
- Store and manage user preferences (BRD §2.1 item 2: "preferences"). Concrete schema decision (§6, formerly Open Question 5): a small fixed initial set — `locale`, `currency`, `notificationOptIn` (per-channel booleans: email/SMS/push), `marketingConsent` (boolean) — stored as a single JSONB column on the write model rather than fully normalized columns, so additive fields (new preference types) don't require a schema migration. This mirrors the platform's general bias toward denormalized, additive-friendly read/write shapes (BRD §6.2's rationale for embedding over joins) applied here to a write-side column instead of a read collection.
- On a verified user-erasure request, tombstone this service's own PII fields (name, email copy, address lines, phone) in the PostgreSQL write model within 30 days, and publish `UserDataErased` so downstream services can redact their own copies. See §6 (formerly Open Question 6) and ADR-0016 (`docs/adr/0016-user-gdpr-erasure-policy.md`) for the full decision, rationale, and cross-service consequences.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) — resolved, see §6 | User Service is absent from the Order Saga (§5.1, §12) and does not gate order/checkout completion; the BRD's NFR table (§3) names only "order path" (99.99%) vs. "secondary" (99.9%) without assigning services to either tier, but User's absence from every Saga step is a strong enough signal to commit to the secondary tier rather than leave it a hedge |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/users/{id}` is a read against the MongoDB projection (BRD §3, §5.4) |
| Consistency | Strong (PostgreSQL write model), Eventual (MongoDB read projection) | BRD §5.4 states "PostgreSQL → MongoDB read" for User — the exact CQRS split defined generally at §3 and §7 |
| Reliability | At-least-once delivery + idempotent consumers | Global NFR (§3); applies to consuming `UserRegistered` and `UserAccountUpdated` — redelivery of either must not corrupt or duplicate profile state |
| Security | AES-256 at rest for PII columns; TLS 1.3 in transit; PII tombstoned within 30 days of a verified erasure request | BRD §24 covers encryption; the erasure clause is this spec's own resolution (§6, ADR-0016 (`docs/adr/0016-user-gdpr-erasure-policy.md`)) of the deletion/retention gap BRD §24 left open |
| Retry/DLQ | Resolved, see §6 | BRD §10 Event Catalog (as completed by ADR-0007/ADR-0008) now gives concrete per-event policy: `UserRegistered` 3x retry → `identity.dlq`; `UserProfileUpdated` 2x retry → `user.dlq`; `UserAccountUpdated` 2x retry → `identity.dlq`; all three include Analytics as a consumer per ADR-0004's standing fan-in default |

## 4. Domain Invariants

- A User Service profile record must not exist independent of a corresponding `UserRegistered` event — profile creation is derived from, and downstream of, Identity's registration (inferred from the consume/publish direction stated at BRD §5.4; the BRD does not state this as an invariant explicitly).
- Exactly one canonical profile write-model record per user id — implicit in `/users/{id}` being a singular resource key (BRD §5.4); not stated as an explicit rule in the BRD.
- The MongoDB read projection must be rebuildable from the PostgreSQL write model and must eventually converge to it — the general CQRS safety property stated at BRD §7, applied here since §5.4 places User Service in that exact split.
- Email and display name are owned by Identity Service, not User Service, after registration; User Service's copy is a denormalized, eventually-consistent projection kept current via `UserAccountUpdated` (ADR-0006) — User Service must never treat its own copy of these two fields as authoritative for write conflicts with Identity.
- On a verified erasure request, PII fields must be tombstoned in the write model within 30 days, and the projection/downstream fan-out must follow from that single write via `UserDataErased` — no separate, undocumented purge path may exist (ADR-0016 (`docs/adr/0016-user-gdpr-erasure-policy.md`)).
- Note: unlike Inventory (oversell), Payment (double-charge), Search (staleness), Order (saga), and Analytics (durable bus) — each given an explicit forced-decision domain rule at BRD §2.2 — User Service is not listed there at all. No BRD-stated high-stakes invariant around address or preference *business* correctness (e.g., address deliverability) exists beyond what's captured above; the address/preference schema and erasure invariants above are this spec's own engineering decisions, not inventions presented as BRD fact.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/users/{id}` (HTTP verb(s) unspecified) | Inbound API | BRD §5.4; read/write split not stated — left to the API Design Agent, see §7 (formerly Open Question 3, non-blocking) |
| `UserProfileUpdated` | Published | Consumed by Analytics (BRD §10, per ADR-0004's default; ADR-0008 added the missing catalog row) |
| `UserRegistered` | Consumed | Published by Identity Service (BRD §5.4, §10); also consumed by Notification and Analytics |
| `UserAccountUpdated` | Consumed | Published by Identity Service on login-email/display-name change (BRD §5.4, §10; ADR-0006) |
| `UserDataErased` | Published | New event, this spec's own resolution of the erasure gap (§6; ADR-0016 (`docs/adr/0016-user-gdpr-erasure-policy.md`)) — not yet in the BRD's Event Catalog; needs a catalog row added in a later documentation pass, same as `UserAccountUpdated` was |

Gateway routing: the Service Boundary Diagram (BRD §5.5) does not draw an edge from `GW` to a `User` node, but that diagram is a representative/non-exhaustive view (its own section header calls Order the "representative deep-dive"; Cart, Offer, Wishlist, Review, Notification, Shipping, Delivery Tracking, Recommendation, and Admin all have defined client- or admin-facing API surfaces in §5.4 and are equally absent from the diagram). Reading the diagram as an exhaustive routing table would imply none of those services are reachable at all, which contradicts their own §5.4 rows. Resolved here (§6, formerly Open Question 2): `/users/{id}` is Gateway-routed like every other service with a defined client-facing API surface; the diagram's limited node set reflects Order-Saga-path emphasis, not a routing exclusion.

Final contract is the API Design Agent's job, not this spec's.

## 6. Resolved Decisions (Closure of Former Open Questions)

Every item previously carried in this section's predecessor ("Open Questions / Flagged Ambiguities") has been closed below, using one of three closure modes: (a) cited resolution via an existing ADR, (b) a direct engineering-default decision made in this spec, or (c) a new PENDING ADR where the decision is genuinely cross-cutting. Only §7 below still carries anything forward, and only as an explicitly non-blocking handoff.

1. **Identity Service vs. User Service data ownership boundary — resolved by citation.** `docs/adr/0006-identity-user-profile-sync-event.md` establishes: Identity owns login-email/display-name as source of truth and publishes `UserAccountUpdated`; User owns the broader profile and keeps a denormalized copy of those two fields, reconciled via that event. This spec already anticipated the need for exactly this kind of event before the ADR existed; no re-decision needed here.
2. **`/users/{id}` gateway routing gap — resolved as a direct decision.** See §5 above: the Service Boundary Diagram (BRD §5.5) is non-exhaustive by its own section's framing and by the presence of multiple other §5.4-listed API surfaces that are equally undrawn; `/users/{id}` is Gateway-routed like any other client-facing endpoint. No cross-service impact — this only affects how User Service itself is reached, not any other service's contract — so no ADR is warranted.
3. **HTTP verbs / read-vs-write split on `/users/{id}` — not resolved here, and correctly so.** This is genuinely the API Design Agent's job (it depends on REST-vs-command conventions the API Design Agent sets platform-wide, not a User-Service-local call) — carried forward in §7 as non-blocking.
4. **Retry/DLQ policy for `UserRegistered`/`UserProfileUpdated` — resolved by citation.** The premise that these events are absent from the Event Catalog is stale: `docs/adr/0007-event-catalog-completeness.md` and `docs/adr/0008-event-catalog-completeness-round-2.md` closed exactly this gap platform-wide, and BRD §10 now carries concrete rows for `UserRegistered` (3x, `identity.dlq`), `UserProfileUpdated` (2x, `user.dlq`), and `UserAccountUpdated` (2x, `identity.dlq`), each following `event-standards.md`'s per-consumer-queue DLQ and TTL-ladder retry convention.
5. **Address count/structure and preference schema — resolved as a direct decision.** See §2 above for the concrete schema (address `type`/`isDefault` model; preference set stored as JSONB). This is a single-service data-modeling default with no cross-cutting effect on any other service's contract (Order/Shipping consume whatever structured address object User Service exposes, regardless of its internal representation) — no ADR needed. Trade-off accepted: this schema is an engineering default, not a BRD-derived fact; it can be extended (e.g., additional address types, richer preference keys) without a breaking change since preferences are JSONB and addresses are additively structured.
6. **GDPR / right-to-erasure and data-deletion semantics — resolved via new PENDING ADR.** This is genuinely cross-cutting: multiple other services (Order, Notification, Analytics, Review, Recommendation, Wishlist) hold userId-linked PII copies that would need to react to an erasure request the same way User Service's own copy does. See ADR-0016 (`docs/adr/0016-user-gdpr-erasure-policy.md`) for the full decision: PII tombstoned within 30 days of a verified request; retained order/audit history anonymized rather than deleted; a new `UserDataErased` event fans the erasure out to downstream consumers. This also closes edge-cases.md's "PII lingering in the read projection after a correction or deletion" (previously escalated).
7. **Availability/criticality tier for User Service — resolved as a direct decision.** See §3 above: committed to the 99.9% "secondary" tier. Rationale: User Service does not appear anywhere in the Order Saga (§5.1, §12) as a dependency Order orchestrates around, and none of Order/Inventory/Payment/Shipping's success or failure paths block on User Service being available — the defining characteristic BRD §3 implies for the "secondary" tier. This does not affect any other service's contract, so no ADR is needed; if a later stage finds User Service actually gates some order-path flow the BRD doesn't mention, that finding would warrant revisiting this, not this spec guessing further today.

## 7. Open Questions (Non-Blocking, Carried Forward)

These are handoffs to a specific downstream pipeline stage by design, not unresolved gaps blocking this sign-off:

1. **HTTP verbs / read-vs-write split on `/users/{id}`.** BRD §5.4 states only the endpoint string. Whether `GET /users/{id}` is the sole client-facing surface (reading the Mongo projection) while writes go through a separate unlisted path, or the same path serves both via verb differentiation, is the API Design Agent's job — it depends on platform-wide REST/command conventions that agent sets consistently across all 18 services, not a call this spec should make unilaterally for User Service alone.

## Sign-off

- [x] Blocking open questions resolved
- [x] Reviewed by: Automated architecture pipeline — see docs/adr and this run's decision log
- [x] Approved to proceed to Architecture Agent
