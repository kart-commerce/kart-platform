---
doc_type: requirement-spec
service: kart-delivery-tracking-service
status: approved
generated_by: requirement-agent
source: docs/requirements/kart-requirements.md
---

# Requirement Spec: kart-delivery-tracking-service

## 1. Scope

Covers a single BRD service: **Delivery Tracking** (BRD §2.1 item 17, "Real-time tracking, ETA"). No merge with another BRD service applies here — like Search and Product, Delivery Tracking maps 1:1 onto one bounded context, so no ADR is required to justify scope.

The BRD's treatment of this service is minimal: one API endpoint, one database, one published event, and one condensed consumed-event description (§5.4). Most of the "how" is left unstated — this spec surfaces those gaps rather than filling them in.

## 2. Functional Requirements

- Serve tracking status/detail reads (`GET /tracking/{id}`, BRD §5.4).
- Consume `ShipmentDispatched` (BRD §10: published by Shipping, consumed by Order, Notification, **Tracking**; payload `orderId, carrier, trackingId`) — the BRD does not state the business meaning of this consumption explicitly, but its presence in Tracking's consumer list and its `trackingId` payload strongly imply it is the trigger that creates a trackable shipment record (see Open Questions).
- Consume carrier status updates via "carrier webhook → internal event" (BRD §5.4's condensed Consumes column for this service) — an inbound HTTP callback from an external carrier, translated into an internal event for processing. The BRD names this integration but gives no schema, carrier list, or translation contract (see Open Questions).
- Publish `DeliveryStatusUpdated` (`trackingId, status`) on a status change (BRD §10), consumed by Notification and Analytics.
- Provide real-time tracking and an ETA (BRD §2.1's stated primary responsibility) — the BRD names ETA as core scope but gives no field in the published event payload, no computation method, and no dedicated endpoint for it (see Open Questions).
- Persist tracking state in MongoDB (BRD §5.4) — no read/write split is stated for this service the way it is for Product/Search (§6.1); the BRD does not name a PostgreSQL write side for Delivery Tracking at all.

## 3. Non-Functional Requirements

Pulled from the BRD's global NFR table (§3), scoped to this service. The BRD names no Delivery-Tracking-specific forced decision at §2.2 (unlike Search's consistency callout or Inventory's oversell rule).

| Attribute | Target | Applies here because |
|---|---|---|
| Availability | 99.9% (secondary path) | BRD's 99.99% tier is scoped to "order path" (§3); §5.5's diagram shows Delivery Tracking only as a Bus fan-out consumer, not a Saga participant alongside Order/Inventory/Payment/Shipping |
| Latency | P95 < 150ms, P99 < 400ms (read path) | `GET /tracking/{id}` is a read-path endpoint (§3 read-path row) |
| Consistency | Eventual (MongoDB, fed by `ShipmentDispatched` and carrier webhooks) | No PostgreSQL write side is named for this service (§5.4); state arrives via async event/webhook, consistent with the platform's general eventual-consistency read-side pattern (§6.1, §7) |
| Reliability | At-least-once delivery + idempotent consumers | Applies to `ShipmentDispatched` consumption and `DeliveryStatusUpdated` publication (BRD NFR §3, Reliability row) — the BRD states no equivalent delivery guarantee for the carrier webhook path itself, since that is not on the internal message bus (see Open Questions) |
| Retry/DLQ | `ShipmentDispatched`: 3x retry, `shipping.dlq`; `DeliveryStatusUpdated`: 3x retry, `tracking.dlq` (BRD §10) | Both are catalog-tier (not `Payment*` money-moving tier); no retry/DLQ policy is stated for carrier webhook ingestion, since it is not a bus message (see Open Questions) |

## 4. Domain Invariants

- A tracking record is addressable by `trackingId`, and that identity must exist before any carrier status can be recorded against it — inferred from `ShipmentDispatched`'s payload (`orderId, carrier, trackingId`, BRD §10) being the only stated source of a `trackingId`, and from `GET /tracking/{id}` requiring that id to already resolve to something.
- The exposed delivery status must reflect the service's stated purpose of "real-time tracking" (BRD §2.1) rather than a stale or long-superseded one — the BRD gives no staleness bound for this, unlike Search's (still numerically unspecified) "seconds, not milliseconds" callout at §2.2 (see Open Questions).
- `DeliveryStatusUpdated` publication must be idempotent under RabbitMQ's at-least-once delivery (BRD NFR §3, Reliability row) — the same idempotency demand made of every other publisher in the Event Catalog (§10).
- Once a later delivery lifecycle stage has been recorded for a `trackingId`, the exposed current status should not regress to an earlier stage — inferred at a general level from "real-time tracking" being the stated purpose combined with status originating from an external, not BRD-controlled carrier webhook source. The BRD does not state this explicitly, nor does it define a status vocabulary or lifecycle ordering at all (see Open Questions and edge-cases.md).

## 5. API Surface (from BRD, starting point only)

| Endpoint/Event | Direction | Notes |
|---|---|---|
| `GET /tracking/{id}` | Inbound API | BRD §5.4 — the only endpoint the BRD names for this service; request/response shape unspecified |
| `ShipmentDispatched` | Consumed | Published by Shipping (BRD §10); also consumed by Order and Notification. Business meaning of Tracking's consumption is inferred, not stated — see Open Questions |
| Carrier webhook | Consumed → translated to internal event | BRD §5.4's condensed description only ("carrier webhook → internal event") — no schema, carrier identity, auth/signature scheme, or per-carrier vocabulary stated |
| `DeliveryStatusUpdated` | Published | Consumed by Notification, Analytics (BRD §10) |

Final contract is the API Design Agent's job, not this spec's.

## 6. Open Questions / Flagged Ambiguities

1. **Carrier webhook contract is entirely unspecified.** BRD §5.4 states only "carrier webhook → internal event" — no payload schema, no list of supported carriers, no authentication/signature verification mechanism, and no shared status vocabulary across carriers. This is expected to be external and carrier-dependent (the BRD cannot reasonably define a third party's API), but it is still a real, blocking gap for implementation. Carried to the Architecture/API Design Agent stages to define an internal adapter contract; likely requires a per-carrier translation layer.
2. **ETA computation method is unspecified.** BRD §2.1 names "ETA" as this service's core scope alongside "real-time tracking," but no other BRD section — not the API table, not the Event Catalog, not the NFRs — describes how an ETA is derived (carrier-supplied, distance/route model, static per-carrier SLA, or ML-based), where it is exposed, or how/when it is recomputed. Carried forward as unresolved; this spec does not invent a method the BRD doesn't state.
3. **Relationship to Shipping's `ShipmentDispatched` is inferred, not stated.** BRD §10 lists Tracking as a consumer of `ShipmentDispatched`, and the payload includes `trackingId` — the natural reading is that this event is what creates a trackable shipment record in this service, but the BRD never states this causal relationship in prose the way it does for, e.g., Order's Saga role (§5.1). Carried to the DDD Agent to confirm as the aggregate-creation trigger.
4. **No retry/DLQ policy for carrier webhook ingestion.** The BRD's retry/DLQ topology (§8–§11) is defined only for the internal RabbitMQ bus. Carrier webhooks are third-party-initiated HTTP calls, not bus messages, so there is no BRD-stated failure-handling policy for a webhook that never arrives (carrier outage, misconfigured endpoint, or silent drop) — no broker exists to redeliver it. Carried to the Architecture Agent; likely needs a polling fallback (see edge-cases.md).
5. **Consistency/staleness bound is unnamed.** Unlike Search, which at least names (without numbering) a "seconds, not milliseconds" bound at BRD §2.2, Delivery Tracking gets no equivalent callout despite "real-time" being its stated primary responsibility (§2.1). Carried to the Architecture Agent to propose a concrete freshness SLA, with human sign-off since it affects webhook/polling design.

## Sign-off

- [ ] Blocking open questions resolved
- [ ] Reviewed by:
- [ ] Approved to proceed to Architecture Agent
