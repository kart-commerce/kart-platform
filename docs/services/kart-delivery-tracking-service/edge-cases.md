---
doc_type: edge-cases
service: kart-delivery-tracking-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-delivery-tracking-service/requirement-spec.md
---

# Edge Cases: kart-delivery-tracking-service

## Edge Case: Out-of-Order Carrier Status Updates

- **What happens:** A later-arriving webhook reports an earlier lifecycle stage than one already recorded (e.g. "in transit" arrives after "delivered" was already recorded), and a naive last-write-wins update regresses the exposed status.
- **Why it happens:** Carrier webhook delivery has no ordering guarantee across HTTP callbacks — network jitter, carrier-side retries, or multi-region carrier senders can deliver updates out of send order (requirement-spec Domain Invariant: status should not regress; FR: carrier webhook → internal event).
- **Solutions available (3):** Compare incoming status against a defined lifecycle-stage ordinal and reject/ignore updates that would regress it · Use the carrier-provided event timestamp (not receipt time) as the ordering key and apply last-by-event-time · Store full status history and let reads select the max-ordinal entry, without discarding any received update
- **Decision (3-5 bullets max):**
  - Chosen: Compare against a defined lifecycle-stage ordinal per status; discard updates that would regress the exposed current status, but persist every received update in status history for audit.
  - Why: Doesn't require trusting carrier-supplied timestamps, whose precision/timezone handling varies per carrier (requirement-spec Open Question: webhook contract is unspecified and carrier-dependent).
  - Trade-off accepted: This service must own and maintain a canonical status-lifecycle ordinal mapping per carrier, rather than trusting each carrier's own ordering — same mapping layer the vocabulary-normalization edge case below also requires.

## Edge Case: Carrier Webhook Failure or Silence

- **What happens:** A carrier stops sending webhook calls for a shipment (carrier-side outage, endpoint misconfiguration, or a silently dropped call), and the tracking record goes stale with no signal that anything is wrong.
- **Why it happens:** Webhook ingestion is a third-party-initiated HTTP push entirely outside the platform's RabbitMQ retry/DLQ topology (requirement-spec Open Question: no retry/DLQ policy exists for carrier webhook ingestion) — there is no broker to redeliver a webhook the carrier never sent.
- **Solutions available (2):** Add a scheduled polling fallback that queries the carrier's tracking API directly once a shipment's last-updated timestamp exceeds a staleness threshold · Rely solely on webhooks and treat webhook silence as an out-of-scope, carrier-side problem
- **Decision (3-5 bullets max):**
  - Chosen: Scheduled polling fallback, triggered per-shipment once its last-updated timestamp exceeds a staleness threshold.
  - Why: BRD §2.1 names "real-time tracking" as this service's primary responsibility — silently going stale with no fallback directly contradicts that responsibility.
  - Trade-off accepted: Requires building and maintaining a carrier-API polling client per carrier, in addition to the webhook receiver — added integration surface the BRD doesn't scope or size, flagged for the Architecture Agent's capacity planning.

## Edge Case: ETA Going Stale Mid-Transit

- **What happens:** An ETA computed at an earlier tracking event (e.g. "picked up") no longer reflects reality by the time a later event arrives (e.g. a delay surfaced by "in transit"), but the stale ETA keeps being served to reads.
- **Why it happens:** The BRD names ETA as core scope (BRD §2.1) but specifies no computation method or recompute trigger (requirement-spec Open Question: ETA computation method is unspecified) — with no explicit recompute-on-update rule, ETA is only ever whatever was last written.
- **Solutions available (3):** Recompute ETA on every incoming status update (webhook- or poll-driven) · Recompute ETA on a fixed schedule independent of status updates · Pass through the carrier-provided ETA when the carrier supplies one, falling back to a platform-computed estimate only when it doesn't
- **Decision (3-5 bullets max):**
  - Chosen: Recompute (or re-fetch from the carrier) on every incoming status update; no independent fixed-schedule recompute.
  - Why: Ties ETA freshness to the same real-time signal already driving `DeliveryStatusUpdated`, without adding a second scheduling mechanism to reason about.
  - Trade-off accepted: If a carrier goes silent (see the webhook-failure edge case above), ETA goes stale along with status — this decision doesn't solve that case; the polling fallback does.
  - Escalation (unresolved): The actual computation formula (carrier-supplied vs. distance/route model vs. static per-carrier SLA) has no BRD basis to decide from and is as much a business call as an engineering one (requirement-spec Open Question) — carried to a human/Architecture Agent decision, not resolved here.

## Edge Case: Inconsistent Status Vocabulary Across Carriers

- **What happens:** Different carriers report the same real-world delivery state using different terms/codes (e.g. one carrier's `OUT_FOR_DELIVERY` vs. another's `on_vehicle_for_delivery`), and publishing these raw values in `DeliveryStatusUpdated` gives Notification and Analytics inconsistent status strings for the same lifecycle stage.
- **Why it happens:** BRD §5.4 implies a translation step exists ("carrier webhook → internal event") but names no shared status vocabulary or per-carrier mapping (requirement-spec Open Question: webhook contract/format is unspecified and carrier-dependent).
- **Solutions available (2):** Define a canonical internal status enum with a per-carrier adapter/mapping layer at ingestion · Pass through each carrier's raw status string unmapped and let downstream consumers handle per-carrier variance themselves
- **Decision (3-5 bullets max):**
  - Chosen: Canonical internal status enum with a per-carrier adapter/mapping layer at ingestion.
  - Why: `DeliveryStatusUpdated` is consumed by both Notification and Analytics (BRD §10) — both need one stable vocabulary to key logic/dashboards off of; pushing per-carrier variance downstream would duplicate the same mapping problem in every consumer instead of solving it once.
  - Trade-off accepted: Every new carrier integration requires writing and maintaining its own mapping to the canonical enum, and any carrier status that doesn't cleanly map needs an explicit fallback bucket (e.g. "unknown") rather than silent pass-through.
