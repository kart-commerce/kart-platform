---
doc_type: requirement-spec
service: kart-user-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-user-service

## 1. Scope

Covers the **User Service** (BRD §2.1 item 2: "Profile, addresses, preferences"). No merge, no ADR — this is a single BRD service, unlike `kart-offer-service`.

The BRD's treatment of User Service is condensed to one row in §5.4's "Remaining Services (condensed)" table plus the one-line responsibility in §2.1. It is not given a dedicated deep-dive section (unlike Order, Inventory, Payment at §5.1–5.3), is not named in §2.2's "Domain Rules That Force Hard Engineering Decisions," and does not appear in the Service Boundary Diagram (§5.5). This spec works from that limited material and does not invent detail the BRD doesn't support — gaps are named explicitly in §6.

## 2. Functional Requirements

- Serve a user's profile via `GET /users/{id}`, sourced from the MongoDB read projection (BRD §5.4).
- Accept profile writes against the PostgreSQL write model and publish `UserProfileUpdated` after a successful write, projected asynchronously into MongoDB via the platform's standard Outbox pipeline (BRD §5.4, §7 CQRS Design, §11 Outbox Pattern) — the BRD states only the `/users/{id}` path with no verb; the write endpoint's exact shape is not given. See Open Questions.
- Initialize a User Service profile record upon consuming `UserRegistered`, published by Identity Service at account registration (BRD §5.4) — the profile write model is seeded by, and downstream of, Identity's registration flow, not the reverse.
- Store and manage addresses associated with a user (BRD §2.1 item 2: "addresses") — the BRD gives no endpoint, cardinality (one vs. many, billing vs. shipping), or validation requirement beyond the noun. See Open Questions.
- Store and manage user preferences (BRD §2.1 item 2: "preferences") — same condensation; no preference schema (notification opt-in, locale, currency, etc.) is given. See Open Questions.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path — inferred) | User Service is absent from the Order Saga (§5.1, §12) and absent from the Gateway routing diagram (§5.5); the BRD's NFR table names only "order path" (99.99%) vs. "secondary" (99.9%) without assigning services to either tier — see Open Questions |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `/users/{id}` is a read against the MongoDB projection (BRD §3, §5.4) |
| Consistency | Strong (PostgreSQL write model), Eventual (MongoDB read projection) | BRD §5.4 states "PostgreSQL → MongoDB read" for User — the exact CQRS split defined generally at §3 and §7 |
| Reliability | At-least-once delivery + idempotent consumers | Global NFR (§3); applies to consuming `UserRegistered` — a redelivered event must not create a duplicate profile record |
| Security | AES-256 at rest for PII columns; TLS 1.3 in transit | BRD §24 — profile and address data are textbook PII, more concentrated in this service than almost anywhere else in the platform |
| Retry/DLQ | Not specified in BRD | Neither `UserRegistered` nor `UserProfileUpdated` appears in the Event Catalog (§10), unlike every other cross-service event named in §5.4 (e.g. `ProductPriceChanged`, `CouponRedeemed` both have catalog rows) — see Open Questions |

## 4. Domain Invariants

- A User Service profile record must not exist independent of a corresponding `UserRegistered` event — profile creation is derived from, and downstream of, Identity's registration (inferred from the consume/publish direction stated at BRD §5.4; the BRD does not state this as an invariant explicitly).
- Exactly one canonical profile write-model record per user id — implicit in `/users/{id}` being a singular resource key (BRD §5.4); not stated as an explicit rule in the BRD.
- The MongoDB read projection must be rebuildable from the PostgreSQL write model and must eventually converge to it — the general CQRS safety property stated at BRD §7, applied here since §5.4 places User Service in that exact split.
- Note: unlike Inventory (oversell), Payment (double-charge), Search (staleness), Order (saga), and Analytics (durable bus) — each given an explicit forced-decision domain rule at BRD §2.2 — User Service is not listed there at all. No high-stakes invariant around address or preference correctness is stated or implied by the BRD; anything beyond the three points above would be invention.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/users/{id}` (HTTP verb(s) unspecified) | Inbound API | BRD §5.4; read/write split not stated — see Open Questions |
| `UserProfileUpdated` | Published | Consumer not specified in BRD (absent from Event Catalog §10) — see Open Questions |
| `UserRegistered` | Consumed | Published by Identity Service (BRD §5.4) |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **Identity Service vs. User Service data ownership boundary.** BRD row 1 (Identity: "AuthN, tokens, sessions, MFA") and row 2 (User: "Profile, addresses, preferences") don't say where the line falls for fields needed by both, e.g. email or display name. The BRD only establishes that Identity publishes `UserRegistered` and User consumes it (§5.4) — this tells us Identity is the registration source of truth and User initializes from it, but not which service is authoritative for such fields afterward. Carried to the Architecture/DDD Agent stage.
2. **`/users/{id}` gateway routing gap.** BRD §5.4 lists `/users/{id}` as User Service's API surface, but the Service Boundary Diagram (§5.5) does not route the Gateway (`GW`) to a `User` node — only Identity, Product, Search, Cart, and Order are wired to `GW`. Not resolved here (the diagram may simply be illustrative/non-exhaustive) — flagged for the Architecture Agent.
3. **HTTP verbs / read-vs-write split on `/users/{id}` unspecified.** The BRD states only the endpoint string, no verb. Given the CQRS split, is `GET /users/{id}` the sole client-facing surface (reading the Mongo projection) while writes go through an unlisted endpoint, or does the same path serve both? Left to the API Design Agent.
4. **Retry/DLQ policy for `UserRegistered` and `UserProfileUpdated` is absent.** Neither event appears in the BRD's Event Catalog (§10). Carried to the Event Design Agent stage.
5. **Address count/structure and preference schema not specified.** BRD §2.1 says "addresses" (plural) and "preferences" with no cardinality limit, address type (billing/shipping), validation/geocoding requirement, or preference schema. Nothing in the BRD to derive this from — a genuine gap, not invented here.
6. **GDPR / right-to-erasure and data-deletion semantics unspecified.** BRD §24 Security covers encryption at rest for PII generally, but gives no deletion, retention, or export requirement anywhere — materially different from encryption, and User Service is the platform's primary PII-holding service. Needs a business decision before the DDD Agent can model account-deletion invariants.
7. **Availability/criticality tier for User Service unstated.** BRD §3's NFR table names "order path" vs. "secondary" tiers without assigning services to either. §3's 99.9% target is used above as an inference (User Service is absent from the Order Saga and Gateway diagram), not asserted as BRD fact — flagged in case that inference is wrong.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
