---
doc_type: adr
status: proposed
---

# ADR-0013: Recommendation Consumes `ProductCreated` — §5.4/§10 Inconsistency Resolved in Favor of the Event Catalog

## Status

Proposed (final ADR number assigned in a later pass)

## Context

`kart-requirements.md` §10's Event Catalog lists `ProductCreated`'s consumers as "Search, Recommendation, Analytics" (Publisher: Product; payload `sku, attributes`; 3x retry; `catalog.dlq`). §5.4's condensed row for Recommendation, however, names only `OrderDelivered` and "clickstream events" as its consumed inputs — `ProductCreated` is absent from that row, and no other BRD section (§2.1, §2.2, §5.5's diagram, §15) attributes any purpose to Recommendation consuming catalog-creation events.

This is the same *shape* of inconsistency ADR-0005 resolved for `OrderCompleted`/`OrderDelivered` — an event named in one BRD source of truth but not the other — except mirrored: there, §5.4 named an event §10 had no publisher for; here, §10 names a consumer that §5.4's own row for that service omits. `kart-recommendation-service/requirement-spec.md` flagged this as Open Question #6 (found during a later documentation pass, after the spec's initial approval). `kart-recommendation-service/edge-cases.md`'s "Newly catalogued products are unrecommendable" edge case escalated the resulting product question: a newly catalogued product has zero purchase/clickstream signal and also cannot appear in the non-personalized fallback (which is itself computed from historical purchase/clickstream aggregation) — so without some seeding mechanism, new products are structurally invisible to Recommendation indefinitely.

Search faces the identical structural situation (a new product needs some event to become discoverable) and its own §5.4 row already lists `ProductCreated` consistently with §10 — Search is not in dispute. Only Recommendation's row disagrees with §10.

## Decision

Treat §10's Event Catalog as authoritative over §5.4 for consumer-set questions. §5.4 is explicitly headed "Remaining Services (**condensed**)" (§5.4, verbatim) — it is a deliberately abbreviated summary table, not a second, competing source of truth to the platform's dedicated, purpose-built Event Catalog (§10). Where the two disagree on which events a service consumes, §10 wins.

Therefore: **Recommendation does consume `ProductCreated`**, per §10's existing row — no change to §10 itself is needed, only the removal of the ambiguity about whether §5.4's silence meant exclusion (it did not; it means the condensed row simply left it out, the same way it leaves out other detail §10 carries).

Purpose assigned to this input (not previously stated anywhere in the BRD, and needed for the event to have a defined use rather than being consumed with no defined effect): on `ProductCreated`, Recommendation seeds the new product into its candidate pool (the same fallback/trending list used for the Cold-start User edge case) with a neutral default score, so the product is discoverable through Recommendation before it accumulates real purchase/clickstream signal. This mirrors Search's identical use of the same event at the same catalog-creation trigger point (indexing a new product for discoverability) — the same trigger, applied to Recommendation's own read model instead of Search's index.

## Consequences

- `kart-recommendation-service/requirement-spec.md` Open Question #6 and `edge-cases.md`'s "Newly catalogued products are unrecommendable" edge case are both resolved by this ADR — no other service's docs need to change, since §10 already listed Recommendation as a consumer; this ADR only settles which BRD source governs when §5.4 and §10 disagree, it does not alter §10's row.
- Recommendation's API/Event surface gains a confirmed consumed input: `ProductCreated` (Publisher: Product; payload `sku, attributes`; 3x retry; `catalog.dlq` — all already stated in §10). The Event Design Agent should treat this as already scoped, not a new open question.
- Establishes a reusable precedent for the rest of the platform: a future §5.4-condensed-row-vs-§10-event-catalog disagreement for any other service should default to §10 as authoritative for consumer-set questions, the same way ADR-0004 already established Analytics' fan-in scope by preferring the more authoritative/complete source over an incomplete condensed summary.
- Recommendation's read model must now handle two structurally different input types with different cardinality/velocity (per-product catalog events, much lower volume than clickstream) — a minor added consumption path, not a new architectural pattern (it reuses the same Kafka/partitioned-consumption approach already decided for `OrderDelivered`/clickstream in `edge-cases.md`).
