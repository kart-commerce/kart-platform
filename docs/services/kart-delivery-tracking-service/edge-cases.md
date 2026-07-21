---
doc_type: edge-cases
service: kart-delivery-tracking-service
status: approved
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

## Edge Case: Duplicate Carrier Webhook Delivery

- **What happens:** The same underlying status update — same lifecycle stage, potentially the identical webhook payload — is delivered and processed more than once for the same `trackingId` (e.g. the carrier's own retry policy re-sends a webhook it believes failed, or a network-level duplicate delivery), producing a second, redundant `DeliveryStatusUpdated` publish and a duplicate status-history entry.
- **Why it happens:** Carrier webhooks arrive as third-party-initiated HTTP calls outside the platform's RabbitMQ at-least-once/dedup machinery (requirement-spec Open Question #4: no retry/DLQ policy exists for webhook ingestion) — there is no broker-level dedup for this path the way there is for `ShipmentDispatched` consumption or `DeliveryStatusUpdated` publication (Domain Invariant: publication must be idempotent under RabbitMQ's at-least-once delivery). Critically, the "Out-of-Order Carrier Status Updates" edge case's ordinal-regression check only rejects updates that would move status *backward* — a literal duplicate arrives at the *same* ordinal as the already-recorded status, passes that check untouched, and nothing today distinguishes it from a legitimate repeated confirmation from the carrier.
- **Solutions available (3):** Dedup on a carrier-supplied idempotency/message key, where the carrier's webhook contract provides one · Dedup on a computed content hash (`trackingId` + canonical mapped status + carrier event timestamp) as a carrier-agnostic fallback when no carrier key exists · Add no explicit dedup and rely on downstream idempotency (no-op re-publish when the mapped status hasn't changed) to make duplicate processing harmless rather than detected
- **Decision (3-5 bullets max):**
  - Chosen: Content-hash dedup (`trackingId` + canonical status + carrier event timestamp) as the default at ingestion, upgraded per-carrier to that carrier's own idempotency key where the adapter contract for that carrier supplies one.
  - Why: The ordinal-regression check provably does not catch this case — it only guards against backward movement, not repeats at the same stage — so an explicit dedup layer is additive to, not a substitute for, that check; a content hash needs no carrier-specific contract to exist, consistent with Open Question #1 noting the webhook contract is carrier-dependent and not yet defined.
  - Trade-off accepted: Requires a dedup-window/TTL decision (how long a seen hash is remembered before a repeat is treated as a new, legitimate event rather than a duplicate) and a persisted dedup store at the ingestion layer — both carried to the Architecture Agent alongside the per-carrier adapter mapping this decision already depends on.
  - Trade-off accepted: A hash match is suppressed from status history as well as from re-publishing `DeliveryStatusUpdated`, to avoid audit-log noise — meaning status history becomes a record of distinct received states, not a literal receipt log of every webhook call; flagged in case Analytics/audit later needs the latter.

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

## Edge Case: Unmapped Carrier Status

- **What happens:** A carrier sends a status code the per-carrier adapter mapping has never seen (a new status the carrier started sending, an undocumented carrier API change, or a malformed/garbled value) — it doesn't cleanly resolve to any entry in the canonical status enum from the vocabulary-normalization edge case above.
- **Why it happens:** BRD §5.4 states no shared status vocabulary and no per-carrier mapping (requirement-spec Open Question #1: webhook contract is carrier-dependent and unspecified) — any mapping table this service builds is necessarily a finite, maintained snapshot of what each carrier is known to send today, and carriers can add or rename status codes without notifying the platform.
- **Solutions available (3):** Map to an explicit `unknown` bucket in the canonical enum and publish `DeliveryStatusUpdated` with it, treating it as a normal (if uninformative) status · Suppress publication and hold the previous known status as current, while logging/alerting the gap for manual mapping triage · Silently drop the update with no record and no alert
- **Decision (3-5 bullets max):**
  - Chosen: Persist the raw unmapped value to status history for audit/triage, but do not let it become the exposed "current status" from `GET /tracking/{id}` or trigger a `DeliveryStatusUpdated` publish — and raise it to an operational/manual-review queue for adding the missing carrier mapping.
  - Why: The requirement-spec's status-regression invariant ("status should not regress to an earlier stage") can only be evaluated against a defined lifecycle ordinal — an unmapped status has no ordinal, so there is no way to prove it isn't a regression (or that it isn't forward progress either). The only invariant-respecting default is to not let it move the exposed status in either direction. Silently dropping it with no record would repeat the same "goes stale with no signal" failure mode as the Carrier Webhook Failure/Silence edge case above, which BRD §2.1's "real-time tracking" purpose already rules out.
  - Trade-off accepted: If the unmapped status genuinely represents real forward progress (e.g. a carrier added a new terminal-delivery sub-state), the exposed status lags behind reality until a human adds the mapping — trading real-time accuracy for not violating the non-regression invariant on an unproven value.
  - Escalation (unresolved): What operational SLA governs how quickly an unmapped-status alert gets triaged into an actual mapping addition (minutes, hours, days) is a staffing/process decision the BRD gives no basis for — carried to a human decision, not resolved here.

## Edge Case: Tracking Query Before the First Status Event Has Arrived

- **What happens:** `GET /tracking/{id}` is called (e.g. a customer clicks a tracking link surfaced right after checkout) for a `trackingId` that Order/Shipping already treat as real, but this service has not yet consumed/persisted the `ShipmentDispatched` event that creates the addressable record for that id — the query lands in the window where the id exists upstream but not yet here.
- **Why it happens:** The requirement-spec's Domain Invariant states a tracking record's `trackingId` identity is created by consuming `ShipmentDispatched` and "must exist before any carrier status can be recorded against it" — but the NFR table's Consistency row names this feed as **eventual**, not synchronous, and the Reliability row names only "at-least-once delivery + idempotent consumers," not a consumption-latency bound. A caller with no visibility into that internal lag can legitimately query the id before this service's consumer has caught up.
- **Solutions available (3):** Return a plain `404 Not Found`, identical to the response for a genuinely invalid/nonexistent `trackingId` · Return a distinguishable "pending"/"not yet available" state (e.g. a `200`/`202` response body signaling the record is expected but not yet materialized) so the caller can render different UX than a hard error · Return `404` today but document the race for the caller to retry with backoff, treating it as the client's problem rather than the API's
- **Decision (3-5 bullets max):**
  - Chosen: Not resolved here — this is a genuine product/UX judgment call, not an engineering default, and this agent's mandate is to escalate rather than pick one silently.
  - Why not resolved: The requirement-spec's own API Surface table (§5) explicitly flags `GET /tracking/{id}`'s "request/response shape unspecified." There is no BRD basis to prefer a plain 404 (simple, but indistinguishable from "this id will never exist," a materially different customer situation right after checkout) over a distinguishable pending state (better UX, but a new response shape this spec has no upstream approval to invent unilaterally).
  - Escalation (unresolved): Whether callers right after checkout should see a hard error, a distinguishable "preparing your tracking info" state, or something else is a customer-facing product decision — carried to a human decision at the API Design Agent stage, not decided here.
