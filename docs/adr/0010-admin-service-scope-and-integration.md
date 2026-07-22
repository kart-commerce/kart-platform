---
doc_type: adr
status: accepted
---

# ADR-0010: Admin Service's Back-Office Operation Set Is a Closed Enumeration, and Admin Never Owns a Second Copy of Another Service's Domain Data

## Status

Accepted

## Context

BRD §2.1 item 20 gives Admin Service one line — "Back-office operations, RBAC" — and §24.1's role table adds exactly three illustrative example grants for the `Admin` role: "Catalog management, coupon issuance, user suspension." No BRD section anywhere gives a complete, closed list of back-office operations, and no BRD section states *how* Admin performs an operation that mutates data another service already owns as its aggregate root (a product, a category node, a coupon, a user account, a stock level). This is not only `kart-admin-service`'s own gap — the same missing half of the picture surfaces independently in three other services' already-approved requirement-specs, each unable to close its own write-path question without an answer from Admin's side:

- `kart-category-service/requirement-spec.md` Open Question #6: "The BRD does not say whether taxonomy curation happens through Category's own write API or is proxied through Admin."
- `kart-product-service/requirement-spec.md` Open Question #4 (carried forward, blocking): "Whether product mutation goes through Product's own API, through Admin Service's `/admin/*` (§5.4), or both, is unstated."
- `kart-inventory-service/requirement-spec.md` Open Question #5: "no BRD section ... states what actually triggers a replenishment: a manual admin action, an automated upstream supplier/warehouse feed, or something else."

This is exactly the "affects another service" case the platform's ADR policy reserves for an ADR rather than a single-service engineering default: whatever Admin Service's own requirement-spec decides here changes what Category, Product, and Inventory must expose on their own API surfaces. No existing ADR (0001–0009) touches Admin's scope or its integration pattern with other services' data — the closest, ADR-0007/0008, only fixed `AdminActionPerformed`'s Event Catalog row, not this question.

A second, related risk this ADR also closes: if left unstated, the natural but wrong implementation is for Admin Service to grow its own copies of product/category/coupon/user/inventory data inside its own PostgreSQL database so that `/admin/*` handlers can read and write them locally. That would silently make Admin a second source of truth for data several other services already own as their aggregate root — the identical anti-pattern BRD §24.1 explicitly forbids for RBAC role state ("never a second source of truth for who can do what"), just recurring one layer down, for business data instead of authorization state.

## Decision

**1. The back-office operation set is a closed enumeration for v1, not an open-ended "whatever an admin needs to do":**

| Category | Concrete operations | Owning service whose data is mutated |
|---|---|---|
| Catalog management | Create/update/deactivate a `Product`; create/update/reorder/move a `Category` node | Product Service; Category Service |
| Coupon issuance | Create/deactivate a `Coupon` | Offer Service (`Coupon` aggregate, per ADR-0001) |
| User suspension | Lock/unlock a user's ability to authenticate | Identity Service (auth-identity fields are Identity's domain per ADR-0006's boundary, not User's) |
| Inventory replenishment | Manually trigger a restock adjustment, publishing `InventoryReplenished` | Inventory Service |

This list is grounded in BRD §24.1's three named example grants (catalog management, coupon issuance, user suspension) plus the one additional candidate operation independently surfaced by Inventory's own open question (a manual admin-triggered replenishment). It explicitly excludes two plausible-sounding candidates that the BRD already assigns elsewhere, so they are not silently duplicated under Admin:

- **Review moderation** — BRD §2.1 item 14 names "moderation" as Review Service's own responsibility, not Admin's; `kart-review-service/requirement-spec.md` already tracks its moderation workflow as its own (separately blocking) open question.
- **Refund adjustment** — BRD §24.1's Support Agent example grant is "issue a refund up to a capped amount," exercised through Payment Service's own `POST /payments/{id}/refund` (`kart-payment-service/requirement-spec.md`), under the `Support Agent` role — not the `Admin` role, and not routed through `/admin/*`.

If a future product decision adds a back-office action outside these four categories, that is a new, explicit extension to this table — not a silent expansion of "back-office operations" read as open-ended.

**2. For every operation above, Admin Service invokes the owning service's own write API synchronously (service-to-service, internal client-credentials call) to perform the mutation. Admin Service's own PostgreSQL database stores only Admin-owned records — its fine-grained permission grants (see `kart-admin-service/requirement-spec.md` §4/§6) and its `AdminActionPerformed` outbox rows — never a duplicate copy of Product, Category, Coupon, user-identity, or Inventory data.**

This mirrors the exact pattern BRD §24.1 already uses for RBAC itself (one owning service per kind of state, everyone else is a caller/consumer, never a second store) and is the same reasoning ADR-0011 (`docs/adr/0011-category-read-model-scope.md`) uses for CQRS placement — the specific, already-settled ownership boundary wins over inventing a second copy. Admin Service becomes an *orchestration/control-plane* caller across four domains, not a fifth owner of their data.

## Consequences

- `kart-category-service/requirement-spec.md` Open Question #6 and `kart-product-service/requirement-spec.md` Open Question #4 are answered by this ADR: taxonomy curation and product mutation happen through Category's/Product's own write API, invoked by Admin Service as a caller — those services should add an internal-write endpoint (or confirm their existing one accepts the internal service-to-service caller) and cite this ADR (ADR-0010), instead of carrying their own question as open.
- `kart-inventory-service/requirement-spec.md` Open Question #5 gains one confirmed candidate trigger (a manual admin action calling into Inventory's own write path) but this ADR does not foreclose Inventory also supporting an automated supplier/warehouse feed as a second trigger — that remains Inventory's own call.
- Admin Service's own API surface stays exactly `/admin/*` (BRD §5.4) — it gains no new inbound domain-data endpoints. Its outbound calls to Product/Category/Offer/Identity/Inventory are a new, explicit dependency edge that the Architecture Agent must add to the service boundary diagram (BRD §5.5 does not currently draw Admin at all).
- Admin's own DDD model has exactly one aggregate root of its own consequence — the admin action / permission grant — never a `Product`, `Category`, `Coupon`, or `InventoryStock` aggregate; this bounds the DDD Agent's design instead of leaving it to guess whether Admin needs read/write models for four other services' domains.
- If any of these four owning services' write APIs turn out not to exist yet in the BRD (true today for Category and Product; Offer's coupon-creation write endpoint is likewise unstated), that is that service's own open question to close — this ADR fixes the *integration pattern* (who calls whom), not each callee's own missing endpoint definition.
