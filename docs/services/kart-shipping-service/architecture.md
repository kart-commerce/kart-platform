---
doc_type: architecture
service: kart-shipping-service
status: pending-approval
generated_by: architecture-agent
source: docs/services/kart-shipping-service/requirement-spec.md, docs/services/kart-shipping-service/edge-cases.md
---

# Architecture: kart-shipping-service

## Boundary Rationale

`kart-shipping-service` is the bounded context that answers "how does a confirmed order physically leave the warehouse" — carrier selection and label generation (BRD §2.1 item 16). It is a distinct context from `kart-delivery-tracking-service` (BRD item 17, "real-time tracking, ETA"): Shipping's job ends once a label exists and `ShipmentDispatched` is published; everything after that (carrier webhooks, status polling, ETA) belongs to Tracking's own aggregate, which merely *starts* from Shipping's event (per `kart-delivery-tracking-service/requirement-spec.md`, resolved: `ShipmentDispatched` is Tracking's aggregate-creation trigger). Keeping them separate avoids merging two aggregates with different consistency/availability profiles (Shipping: PostgreSQL, strong-consistency write; Tracking: MongoDB, eventually-consistent read fed by webhooks) into one service the way ADR-0001 deliberately *did* merge Coupon/Pricing/Promotion — there is no analogous one-bounded-context argument here.

Shipping is a **downstream, post-confirmation fulfillment step**, not a transactional gate in the Order Saga's confirmation path. Per [ADR-0002](../../adr/0002-order-shipping-async-integration.md), `OrderConfirmed` is published by Order as soon as `PaymentCompleted` is received — before Shipping has done anything — and Shipping only acts afterward as a pure async consumer. This is why the service sits at the platform's **secondary availability tier (99.9%)** rather than the 99.99% order-path tier (requirement-spec §3): by construction, nothing Shipping does can block or delay order confirmation.

Two BRD diagrams use a generic solid/request-reply arrow style for `Order -> Shipping` that, read literally, looks synchronous:

- §12.1's Saga sequence diagram — already resolved by ADR-0002 (the arrow style carries no sync/async meaning; the prose note under §12.1 is now authoritative).
- §5.5's Service Boundary Diagram (`Order --> Shipping`, the same solid-arrow style used for the genuinely-synchronous `Order --> Inventory` edge) — **not previously called out by name in ADR-0002 or any other ADR**, but the same resolution applies for the identical reason ADR-0002 already gives for §12.1: §5.4/§10 (Shipping's own row and Event Catalog entry) are unambiguous that `OrderConfirmed` is the trigger Shipping consumes asynchronously, and §5.1's Dependencies row explicitly lists "Shipping Service (async)" for Order. This architecture doc records that resolution explicitly for §5.5 so it isn't re-litigated at a later stage the way §12.1 briefly was.

## Dependencies

| Direction | Peer | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound (consumed) | Order | `OrderConfirmed` event | **Async** | Sole shipment-creation trigger ([ADR-0002](../../adr/0002-order-shipping-async-integration.md)). Shipping has no synchronous inbound endpoint invoked by Order — the §5.5/§12.1 diagram arrows do not carry sync/async meaning (see Boundary Rationale above). |
| Inbound (internal/ops, unconfirmed) | Not confirmed — likely Admin/ops tooling | `/shipments` (query and/or manual shipment creation) | **Sync**, if built | requirement-spec §5: BRD §5.4 lists `/shipments` as Shipping's API surface, but per ADR-0002 it is *not* the Order-triggered creation path. Whether it's exposed via the API Gateway to `kart-admin-service`/ops staff, called service-to-service, or dropped entirely is left to the API Design Agent — not drawn into the container diagram until confirmed. |
| Outbound (published) | Order, Notification, Delivery Tracking, Analytics | `ShipmentDispatched` event | **Async** | Published once a shipment/label is durably persisted (PostgreSQL) with non-empty `carrier`/`trackingId`. Purely informational to Order — does not gate `OrderConfirmed` (ADR-0002). Standard tier: 3x retry, `shipping.dlq`. |
| Outbound (published) | Order, Notification, Analytics | `ShipmentCreationFailed` event | **Async** | New event per [ADR-0015](../../adr/0015-shipping-shipment-creation-failed-event.md), published once all configured carrier options are exhausted (address-validation failure or no carrier services the destination). Standard tier: 3x retry, `shipping.dlq` — not the elevated `Payment*` tier, since this is a fulfillment failure, not a financial one. **Cross-service note:** ADR-0015 commits Order to a distinguishable post-confirmation "held / fulfillment-exception" status on this event, *not* a re-run of its pre-confirmation Saga compensation (§12.2). `kart-order-service/edge-cases.md`'s existing "Payment-Success/Shipping-Failure Compensation Ordering" decision still describes automatic reverse compensation (release Inventory, then refund Payment) for a Shipping-step failure — which is exactly the scenario `ShipmentCreationFailed` covers, since `OrderConfirmed` already fired before Shipping acts. ADR-0015 itself flags this as expected, deferred reconciliation work for Order's own next pipeline pass, not a gap in Shipping's docs — recorded here so it isn't lost, not something this architecture doc can fix (out of scope: it's `kart-order-service`'s file). |
| Outbound (sync, external — not a Kart service) | Shipping Carriers (external system, see `docs/architecture/system-context.md`) | Carrier REST API — rate/label generation | **Sync**, circuit breaker + retry-with-backoff against a primary carrier, failing over to a secondary carrier on trip (edge-cases.md decision; concrete bulkhead shape in `design-decisions.md`) | The platform's only outbound third-party call for this service. Decoupled from the internal write-path latency budget via Transactional Outbox (`design-decisions.md`): `OrderConfirmed` is consumed and a shipment-intent persisted fast, the carrier call happens out-of-band, and `ShipmentDispatched`/`ShipmentCreationFailed` publish once it resolves. |

### Resolving requirement-spec's deferred Open Questions at this stage

- **OQ5 (multi-carrier roster/count) — partially resolved here.** edge-cases.md's chosen failover pattern (circuit breaker, primary → secondary) structurally requires **at least two** carrier integrations; that minimum is now fixed as an architectural fact, not left open. The actual vendor roster (which named carriers, contract terms, rate cards) is a procurement/business decision outside this doc's scope — carried forward as a normal downstream detail for whoever finalizes carrier contracts, not a further open architecture question.
- **OQ4 (carrier selection criteria — cheapest/fastest/contracted-rate)** is a domain-model/strategy question (how the `Shipment` aggregate picks a carrier and rate), not a boundary or dependency-graph question — left to the **DDD Agent** stage as requirement-spec already directs, not resolved here.

## Distributed-Monolith Risk

**No inter-service (Kart-to-Kart) distributed-monolith risk identified.** Shipping's only inbound trigger (`OrderConfirmed`) and both its outbound events are async; it has no synchronous outbound call to any other Kart service, and no other Kart service synchronously calls it (the one possible sync inbound endpoint is internal/ops-only and unconfirmed — see Dependencies). Shipping can be deployed, scaled, and degraded independently of Order/Inventory/Payment's saga, matching its secondary-availability-tier NFR.

**External-dependency risk (not distributed-monolith, but worth naming for the same reason):** Shipping's *only* synchronous call of any kind is to the third-party Carrier API — a genuinely blocking dependency at the point of the call. This is already mitigated at the architecture level, not left as a risk to carry forward: circuit breaker + bulkhead-isolated failover to a secondary carrier (edge-cases.md, design-decisions.md), and the call itself is kept out of the `OrderConfirmed`-processing hot path via the Transactional Outbox pattern, so a slow/down carrier degrades *fulfillment latency*, never the internal write-path NFR or Order's confirmation latency.

**Cross-service contract risk (flagged, not fixed here — out of scope for this file):** see the `ShipmentCreationFailed` row above — Order's own edge-cases.md has not yet been reconciled with ADR-0015's "held / fulfillment-exception" reaction. This is expected per ADR-0015's own Consequences section (explicitly deferred to Order's next pipeline pass), not a new gap found here, but it is called out again so it isn't lost between docs.

## Sign-off

- [ ] Reviewed by: _pending human review_
- [ ] Approved to proceed to DDD Agent
