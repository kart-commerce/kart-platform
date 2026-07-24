---
doc_type: architecture
service: kart-admin-service
status: approved
generated_by: architecture-agent
source: docs/services/kart-admin-service/requirement-spec.md, docs/services/kart-admin-service/edge-cases.md
---

# Architecture: kart-admin-service

## Boundary Rationale

`kart-admin-service` is the bounded context that answers "which back-office action is *this* authenticated operator allowed to trigger, right now" — not "what is a Product/Category/Coupon/user account/stock level," which stays owned by its existing bounded context. Per BRD §2.1 item 20 and ADR-0010 (`docs/adr/0010-admin-service-scope-and-integration.md`), Admin is a **thin orchestration/control-plane layer** across four fixed operational categories (catalog management, coupon issuance, user suspension, inventory replenishment), never a fifth owner of another service's domain data. Its own PostgreSQL database holds exactly two kinds of Admin-owned state — the `admin_permission_grants` table and its `AdminActionPerformed` outbox rows (requirement-spec.md §4, §6 Decision item 1) — nothing else.

The boundary is deliberately split from Identity Service along a coarse/fine-grained line, not duplicated: Identity is the single issuer and sole owner of "who holds the `Admin` role" (BRD §24.1); Admin Service owns and consults, on every request, the narrower and separate question of "which of the four categories can *this* `Admin`-role holder actually exercise" (`admin_permission_grants`, Domain Invariant #1). Admin never mints its own credentials, never maintains a parallel role/session store, and never re-implements Identity's coarse revocation-list check (edge-cases.md, "Stale Admin Permission Outliving an Identity-Side Revocation") — the coarse layer is entirely Identity's, the fine-grained layer is entirely Admin's, and the two are never conflated.

Admin is confirmed absent from the Order Saga and from BRD §5.5's boundary diagram (requirement-spec.md §3) — it sits in the platform's secondary availability tier (99.9%) and has no dedicated customer-facing latency SLA. This is the resolution basis for placing Admin outside the transactional order-confirmation critical path: a degraded or briefly unavailable Admin Service blocks operational/back-office recovery, not a live customer checkout.

This architecture pass also closes the one integration-contract item requirement-spec.md §6 explicitly deferred here ("carried forward, non-blocking"): wiring Admin's five new outbound service-to-service dependency edges (Product, Category, Offer, Identity, Inventory) into the cumulative service boundary graph, per ADR-0010's own Consequences section. See Dependencies below.

## Dependencies

| Direction | Peer Service | Mechanism | Type | Notes |
|---|---|---|---|---|
| Inbound | Back-office operator (human), via API Gateway | `/admin/*` — RBAC-gated: Gateway-validated Identity-issued `Admin` role claim (coarse), plus Admin's own category-scoped `admin_permission_grants` check (fine-grained) | **Sync** (REST) | Sole inbound surface. No service ever calls Admin synchronously and no event ever triggers it (BRD §5.4 confirms "—" for consumed events) — Admin is entirely human/operator-initiated, confirmed intentional per requirement-spec.md §2 |
| Outbound | Product Service | `POST /products`, `PUT`/`PATCH /products/{id}` | **Sync** (REST, internal client-credentials call) | Catalog-management category (product half). `kart-product-service/requirement-spec.md` §5 already names Admin's `/admin/*` surface as a confirmed caller of this API, per ADR-0010 |
| Outbound | Category Service | Category's own write API (create/update/reorder/move a `Category` node) | **Sync** (REST, internal client-credentials call) | Catalog-management category (category half). `kart-category-service/requirement-spec.md` §6 item 6 confirms: "Category owns its own write model and write API; Admin calls it, never writes Category's tables directly" |
| Outbound | Offer Service | `POST /coupons` (internal, admin-only) | **Sync** (REST, internal client-credentials call) | Coupon-issuance category. `kart-offer-service/requirement-spec.md` §5 confirms this endpoint's caller as "internal, admin-only," per ADR-0010 |
| Outbound | Identity Service | `POST /internal/users/{userId}/lock`, `POST /internal/users/{userId}/unlock` | **Sync** (REST, internal client-credentials call) | User-suspension category. `kart-identity-service/requirement-spec.md` §5 confirms these routes are "called only by Admin Service's client-credentials principal," per ADR-0010 |
| Outbound | Inventory Service | Inventory's own replenishment write path (manual trigger) | **Sync** (REST, internal client-credentials call) | Inventory-replenishment category. `kart-inventory-service/requirement-spec.md` §6 Decision 5 confirms manual admin-initiated replenishment is "supported through the identical replenishment write path" as the threshold-based automated trigger; Inventory itself publishes `InventoryReplenished` as a result — Admin does not publish this event itself |
| Outbound (published) | Analytics Service (consumer) | `AdminActionPerformed` event — payload `adminId`, `action`, `entityId` | **Async** (event, via Outbox pattern + poller) | Admin's sole published event and sole audit trail (requirement-spec.md §3 Observability, §6 Decision item 3). Full Event Catalog row added by ADR-0007: 1x retry (fire-and-forget audit tier), DLQ `admin.dlq`. Publication is atomic with the triggering write via the Outbox pattern (BRD §11) — resolved in edge-cases.md's "Admin Action Succeeds but `AdminActionPerformed` Is Lost" |

Note on what is *not* a separate dependency edge: Identity's minting/validation of the coarse `Admin` role claim is a platform-wide, Gateway-mediated concern every RBAC-gated service relies on (BRD §24.1) — it is not modeled here as an Admin-specific synchronous call, to avoid double-counting it against the Identity **lock/unlock** edge above, which *is* a direct, Admin-specific outbound call.

## Sync vs. Async Resolution

All five of Admin's outbound calls to owning services (Product, Category, Offer, Identity, Inventory) are synchronous by deliberate choice, not oversight: Domain Invariant #2 (requirement-spec.md §4) requires that a back-office action and its `AdminActionPerformed` audit record never silently diverge, which in turn requires Admin to know the downstream write actually succeeded *before* it commits its own local action/audit record. An async, fire-and-forget command would let Admin record "action performed" before (or even if) the owning service's write ever lands — reopening exactly the audit-integrity gap Domain Invariant #2 exists to close. This reasoning is already settled at the design-decision layer (`design-decisions.md`, "Communication Style for Outbound Calls to Owning Services") and is restated here because it is also the basis for this section's Distributed-Monolith Risk call.

`AdminActionPerformed` itself remains async (Outbox + poller) in the opposite direction — Analytics does not need to block Admin's write path to receive the audit trail, and fire-and-forget audit delivery is the correct tier for a non-blocking downstream consumer.

## Distributed-Monolith Risk

**Flagged, but assessed as an accepted, intentional coupling rather than a boundary defect.** Admin now carries five synchronous outbound dependencies (Product, Category, Offer, Identity, Inventory) — the widest synchronous fan-out of any service placed in the graph so far (compare `kart-offer-service`, which has zero synchronous outbound dependencies). Two properties keep this from being the "chatty, should-be-async" or "can't function at all without X" pattern this stage exists to catch:

- **No multi-hop synchronous chain.** Every `/admin/*` handler maps to exactly one of the four fixed categories (requirement-spec.md §6 Decision item 1), and each category calls exactly one downstream owning service. A single admin request never fans out synchronously across more than one peer service — there is no `Admin → Product → Category → …` chain to collapse.
- **Contained, not shared, blast radius per downstream outage.** `edge-cases.md`'s "Over-Broad `/admin/*` Surface" decision and `design-decisions.md`'s "Resilience Pattern for Outbound Calls to Owning Services" both fix five *independent* circuit breakers, one per owning service, rather than one shared breaker. A Category Service outage blocks only catalog-management actions; it does not degrade coupon-issuance, user-suspension, or inventory-replenishment actions. Admin's own availability posture (99.9%, secondary tier) is therefore gated **per-category** on one of its five peers being up, not on all five simultaneously.

The residual, accepted risk worth naming explicitly for later stages: Admin cannot perform *any* action in a given category while that category's owning service is down — this is a genuine hard synchronous coupling, not softened into eventual consistency, because Domain Invariant #2 requires knowing the downstream write succeeded before Admin's own audit record commits (see Sync vs. Async Resolution above). This is judged acceptable rather than re-litigated here because Product, Category, Offer, Identity, and Inventory are all core services the rest of the platform already requires to be up for their own primary (non-Admin) traffic — Admin is inheriting an already-existing liveness dependency, not introducing a new single point of failure that didn't otherwise exist.

**Follow-up flagged, not fixed in this pass (out of scope for this run — target service is `kart-admin-service` only):** `kart-offer-service/architecture.md` (already approved) predates ADR-0010 and does not yet list this new inbound edge from Admin's `POST /coupons` call. The same is true, by construction, for Product/Category/Identity/Inventory once each reaches its own Architecture Agent pass — none of those four services has an `architecture.md` yet. Whoever next revises `kart-offer-service/architecture.md` (or drafts the other four) should add the corresponding inbound-from-Admin edge for consistency with this doc.

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner
- [x] Approved to proceed to DDD Agent
