---
doc_type: requirement-spec
service: kart-admin-service
status: pending-approval
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-admin-service

## 1. Scope

Covers the single BRD service **Admin Service** (BRD §2.1 item 20): "Back-office operations, RBAC." No merge; no ADR applies.

The BRD's treatment of Admin is the most condensed of any service: it gets one row in the core-modules table (§2.1), one row in the "remaining services" table (§5.4), and no dedicated deep-dive section (unlike Order/Inventory/Payment at §5.1–5.3). It is not part of the Order Saga (§5.5's boundary diagram does not route Admin at all) and is absent from the Event Catalog (§10) entirely, despite §5.4 stating it publishes an event. This spec draws only on those scattered mentions plus the cross-cutting Security section (§24) and does not invent the operational detail the BRD omits — see §6 for the resulting gaps, which are unusually large for this service.

## 2. Functional Requirements

- Expose a back-office API surface gated by role-based access control (`/admin/*`, RBAC-gated, BRD §5.4).
- Perform "back-office operations" (BRD §2.1 item 20) — the BRD names this as the service's core responsibility but does not enumerate a single concrete operation (e.g., locking a user account, overriding an order, issuing a manual refund, adjusting inventory, moderating content). No operation-level functional requirement can be derived beyond the general RBAC-gated surface; see Open Questions.
- Enforce role-based access control on every admin action before it executes (BRD §2.1 item 20: "RBAC"; reinforced by BRD §24's AuthZ row: "JWT with scoped claims, validated at gateway + re-checked at service for sensitive operations" — admin actions are the platform's clearest example of a "sensitive operation," though the BRD never draws this connection explicitly).
- Publish `AdminActionPerformed` after an admin action (BRD §5.4) — the BRD states the event exists but not its payload, what counts as an "action" for publication purposes, or whether publication is guaranteed-atomic with the action (cf. the Outbox pattern at BRD §11, used elsewhere for exactly this dual-write problem, but not stated as applying to Admin).
- No consumed events are stated for this service — BRD §5.4 lists "—" under Admin's "Key Events Consumed" column. A back-office service reacting to nothing elsewhere in the platform (no `OrderCreated`, no `PaymentFailed`, no support-ticket-style trigger) is a notable BRD gap given the "back-office operations" label; see Open Questions.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3) and the cross-cutting Security section (§24), scoped to this service:

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | Unassigned — BRD §3 splits Availability into "99.99% (order path)" and "99.9% (secondary)," and Admin is absent from the Order Saga (§5.5), which argues for the 99.9% secondary tier, but the BRD never places Admin in either tier explicitly; see Open Questions | Back-office tooling is not itself customer-facing, but a prolonged outage blocks operational recovery from incidents elsewhere on the platform |
| Latency | Not stated for this service — BRD §3's P95/P99 targets are framed around "read path" and "write path" for customer-facing traffic; the BRD gives no latency budget for internal/back-office tooling | Admin is absent from every request path in the §5.5 service boundary diagram |
| Consistency | Strong (PostgreSQL write path) per BRD §3's general write-path rule; Admin's DB is PostgreSQL (§5.4) | An RBAC permission check or a back-office write (e.g., an account lock) reading stale state is a security or operational-correctness defect, not a UX one |
| Reliability | At-least-once delivery + idempotent consumers (BRD §3 general rule) — but BRD gives Admin no explicit retry/DLQ row in the Event Catalog (§10) at all; `AdminActionPerformed` is absent from that table entirely, unlike every other published event in the BRD; see Open Questions | `AdminActionPerformed` is Admin's only stated integration point with the rest of the platform |
| Security | Zero plaintext secrets, signed tokens, TLS everywhere (BRD §3); JWT with scoped claims, re-checked at service for sensitive operations; short-lived access tokens (~15 min), rotating refresh tokens, revocation list for logout; AES-256 at rest for PII (BRD §24) | This is Admin's defining NFR — "RBAC" is the service's stated reason to exist (BRD §2.1 item 20), and back-office actions are the platform's highest-privilege operations |
| Observability | 100% trace coverage on order path (BRD §3/§23) — Admin is not on the order path and the BRD states no separate audit/observability requirement for back-office actions beyond the single `AdminActionPerformed` event | A compromised or misused admin credential is high-impact; the BRD does not state an audit requirement commensurate with that risk beyond one event type — see Open Questions |

## 4. Domain Invariants

- An admin action must not be permitted unless the actor's role/permission set explicitly grants it (BRD §2.1 item 20: "RBAC"; BRD §24 AuthZ row) — the BRD does not state whether the model is default-allow or default-deny, role-based or permission-based, or whether roles are hierarchical; see Open Questions. Only the existence of an enforced check, not its shape, is stated.
- A state-changing admin action and its corresponding `AdminActionPerformed` record should not silently diverge (BRD §5.4 states the event is published; BRD §11's Outbox pattern exists platform-wide precisely to prevent a business write and its event from disagreeing after a crash) — the BRD does not state that Admin uses the Outbox pattern, only that the general dual-write problem and its standard solution exist elsewhere on the platform; see Open Questions.
- Admin authorization ultimately traces back to a validated, signed identity (BRD §24: JWT re-checked at service for sensitive operations) — the BRD does not state whether Admin Service issues its own admin-scoped credentials or consumes tokens minted by Identity Service (BRD §2.1 item 1), nor does it list any integration between the two services anywhere in the BRD; see Open Questions.

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `/admin/*` | Inbound API | RBAC-gated (BRD §5.4); no specific endpoint, verb, or resource is enumerated anywhere in the BRD |
| `AdminActionPerformed` | Published | BRD §5.4 states it is published; absent from the Event Catalog (§10) — no payload fields, consumer, retry count, or DLQ strategy stated anywhere; see Open Questions |

No consumed events appear in the BRD (§5.4 shows "—"). Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **Role/permission model unspecified.** BRD §2.1 item 20 names "RBAC" as the service's responsibility, but no section states what roles exist, whether authorization is role-based or finer-grained permission-based, whether roles are hierarchical, or how role assignment/delegation works. This is blocking for any concrete RBAC enforcement design — the Domain Invariant above can only state that a check exists, not its shape.
2. **"Back-office operations" is never enumerated.** No BRD section lists a single concrete admin operation (account lock/unlock, order override, manual refund, inventory adjustment, content moderation override, etc.). Item 14 (Review Service) separately owns "moderation" for reviews, so at least that one candidate operation is confirmed to belong elsewhere — but nothing confirms what, if anything, Admin Service actually does beyond exposing an RBAC-gated surface.
3. **`AdminActionPerformed` missing from the Event Catalog (§10).** Every other event named anywhere in the BRD's service tables has a corresponding Event Catalog row with publisher, consumer(s), payload fields, retry count, and DLQ strategy. `AdminActionPerformed` has none of these — it is stated to exist (§5.4) and nothing else. Carried to the Event Design Agent stage, but flagged here since it is a direct, total BRD gap rather than a downstream design choice.
4. **Relationship to Identity Service for admin authentication is unconfirmed.** BRD §24 describes a platform-wide JWT model with scoped claims and service-level re-checks for sensitive operations, but no BRD section states whether Admin Service trusts tokens issued by Identity Service (BRD §2.1 item 1) with elevated scoped claims, or mints/manages its own admin-specific credentials. No integration between the two services is listed anywhere (Identity's own consumed-events row is "—" per its requirement-spec, and Admin's is also "—").
5. **Audit completeness beyond `AdminActionPerformed` is unstated.** Given that back-office actions are the platform's highest-privilege operations, the BRD gives no requirement for an audit trail beyond the one event type — no mention of immutability, retention, or a compliance-grade log distinct from the general message bus. Whether `AdminActionPerformed` is meant to serve as that audit trail, or a separate one is assumed and simply unstated, is not resolved here.
6. **Availability and latency tiers unassigned.** BRD §3 splits Availability into "99.99% (order path)" and "99.9% (secondary)" and gives P95/P99 latency budgets framed around customer-facing read/write paths; Admin is absent from the §5.5 service boundary diagram entirely, which argues for treating it as secondary/internal, but the BRD never says so explicitly.
7. **Integration pattern with other services' data is unstated.** Admin has its own PostgreSQL database (§5.4), yet "back-office operations" plausibly implies acting on data owned by other services (e.g., a User account, an Order, Inventory stock). The BRD does not state whether Admin calls other services synchronously, only records actions in its own DB while other services independently react to `AdminActionPerformed`, or something else.
8. **Overlap with "admin tooling" mentioned in the messaging design (§8.1) is ambiguous.** The RabbitMQ DLQ row states DLQs are "inspected via admin tooling," which reads as generic ops/observability tooling rather than this Admin Service's `/admin/*` business surface — but the BRD never disambiguates the two, and a reader could conflate them. Not assumed to be the same thing here.

## Sign-off

- [ ] Blocking open questions resolved (Q1–Q3 in particular)
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
