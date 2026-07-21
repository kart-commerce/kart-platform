---
doc_type: adr
status: proposed
---

# ADR-0016: User Data Erasure Policy — Tombstone PII on Request, Anonymize Retained History, Fan Out `UserDataErased` for Downstream Redaction

## Status

Proposed (final ADR number assigned in a later pipeline pass)

## Context

BRD §24 (Security) specifies encryption controls for PII (AES-256 at rest, TLS 1.3 in transit) but states no deletion, retention, or right-to-erasure requirement anywhere in the document. `kart-user-service` is the platform's primary PII-holding service (profile, addresses, preferences per BRD §2.1 item 2), so this gap blocks that service's sign-off more than any other — but the gap is not actually local to User Service alone:

- Multiple other services persist userId-linked PII as part of their own normal operation and would need to act on an erasure request too: Order (`orders.user_id`, shipping address embedded per BRD §6.1's `orders` table and the `OrderConfirmed` event's `address` payload field, §10), Notification (audit trail of sent messages, BRD §5.4), Analytics (full fan-in ingestion of every event per ADR-0004, meaning every event ever published carrying a userId or PII field lands in the warehouse), Review (`ReviewSubmitted` carries `userId`-attributable review content per §10), and Recommendation/Wishlist (userId-keyed personalization data).
- None of ADR-0001 through ADR-0009 addresses data erasure, retention, or a redaction event contract. This is a genuinely new cross-cutting concern, not a re-litigation of an existing decision.
- Whatever event contract and semantics User Service picks here is exactly what every one of those other services would need to consume against — the same "affects another service's required behavior" bar that justified ADR-0006 (a new cross-service event) and ADR-0003/0004 (consumer-scope resolutions).

This ADR resolves `kart-user-service/requirement-spec.md`'s Open Question 6 (GDPR / right-to-erasure semantics) and the same service's `edge-cases.md` "PII lingering in the read projection after a correction or deletion" edge case, both previously escalated as unresolved pending a compliance decision the BRD never states.

## Decision

1. **Erasure is distinct from correction.** An ordinary profile correction (a user editing their own address or display data) continues to flow through the existing `UserProfileUpdated` → Outbox → MongoDB projection pipeline with no new mechanism — that path already exists and is sufficient for the ordinary "stale read after a write" propagation window (see this service's edge-cases.md, "Stale MongoDB read after PostgreSQL write"). Erasure is a separate, compliance-bound workflow because it must produce a *guaranteed* end-state (PII gone) rather than merely an eventually-consistent re-projection of live data.
2. **On a verified erasure request, User Service overwrites PII fields in the PostgreSQL write model with tombstone values** (e.g., name/email/phone/address lines replaced with a fixed sentinel or nulled, per field) **within 30 days of the verified request.** 30 days is chosen as a concrete, defensible default (GDPR's own "without undue delay, and in any event within one month" language is the closest real-world anchor available; no BRD-internal number exists to derive this from instead) — flagged here as an engineering default, not a BRD-derived fact, in case legal/compliance later mandates a shorter SLA. The existing Outbox pipeline re-projects the tombstoned record into MongoDB the same way any other write does — no separate projection-purge mechanism is needed for User Service's own read model.
3. **Order/audit/financial history that other parts of the BRD require the platform to retain is anonymized, not deleted.** Records that legally or operationally must survive (e.g., Order's own order history, Payment's transaction records, Notification's audit trail) keep `userId` as an opaque referential key but have their own copies of directly-identifying fields (name, email, address text) tombstoned in the same pass — this is each downstream service's own responsibility to implement against its own schema, not something User Service can do on their behalf.
4. **User Service publishes a new event, `UserDataErased`** (payload: `userId`, `erasedAt`), once its own tombstone write commits — following the same pattern ADR-0006 already established (add a new event when no existing one fits, rather than overload `UserProfileUpdated`'s semantics, since "this profile changed" and "this user's PII must now be redacted everywhere" are materially different downstream actions). Naming follows the platform's `<Entity><PastTenseVerb>` convention (`event-standards.md`).
5. **Every downstream service holding userId-linked PII is expected to consume `UserDataErased` and redact/anonymize its own copy**, on the same idempotent-upsert-by-userId pattern this service already uses for `UserRegistered` (see edge-cases.md, "Duplicate/out-of-order `UserRegistered` delivery") — at-least-once delivery means each consumer's redaction action must be safely repeatable. This ADR establishes the event contract and the platform-wide expectation only; it does not enumerate which specific fields each of those services must redact — that is each service's own requirement-spec's job, the same way ADR-0006 recorded Identity's new publishing responsibility without editing Identity's docs directly.
6. **Analytics consumes `UserDataErased` under its standing full fan-in default (ADR-0004)** — additive, not a special case. Whether Analytics' own warehouse copy is redacted or merely tagged for exclusion from future reporting is Analytics' own retention-policy decision, out of scope here.
7. **Retry/DLQ policy for `UserDataErased` follows the platform's standard per-event classification** (`event-standards.md`): treated as a compliance-critical event, so it takes the same high-retry-budget/human-paging tier the platform already reserves for money-critical events (BRD §10's `Payment*` rows) rather than the looser catalog/search tier — an erasure event silently swallowed by DLQ is a compliance failure, not a tolerable staleness window.

## Consequences

- `kart-user-service`'s domain invariants can now state a concrete erasure guarantee ("PII tombstoned within 30 days of a verified request") instead of leaving the question open.
- A new event (`UserDataErased`) needs a row added to the BRD's living Event Catalog (§10) in a later documentation pass, the same way ADR-0006's `UserAccountUpdated` was added — not done in this ADR itself, since this ADR's job is the decision, not the catalog file's maintenance.
- Every other service that holds userId-linked PII (Order, Notification, Analytics, Review, Recommendation, Wishlist, and any future service that stores PII) picks up a new consumer responsibility the next time its own requirement-spec/edge-cases pass runs — tracked here as a cross-service follow-up, not implemented service-by-service by this ADR.
- Accepted risk: the 30-day figure and the tombstone-vs-hard-delete choice are engineering/compliance defaults chosen in the absence of BRD or legal guidance, not a legally-reviewed policy — flagged explicitly so a real compliance review can tighten or override it before this is load-bearing in production.
- Accepted risk: if a downstream consumer never implements its own redaction handler for `UserDataErased`, that service's copy of the user's PII persists indefinitely — mitigated only by the same DLQ/paging visibility every other event gets, not a platform-enforced guarantee.
