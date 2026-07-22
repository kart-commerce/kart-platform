---
doc_type: tickets
service: kart-category-service
status: approved
generated_by: ticket-agent
source: [requirement-spec.md, edge-cases.md, design-decisions.md, architecture.md, ddd-model.md, api-contract.yaml, database-design.md, event-contract.md]
---

# Tickets: kart-category-service

Local draft. Not yet created as real GitHub Issues — that requires the target repo to exist (Project Scaffold Agent) and is a separate, explicit step.

All 9 upstream design artifacts for this service are `status: approved`. This ticket list is decomposed directly from that fully-approved set; five vertical slices map 1:1 to `api-contract.yaml`'s five paths — no endpoint in the contract is left undecomposed.

## Epic: kart-category-service v1

Category taxonomy: hierarchy maintenance (create/rename/move/deprecate, RBAC-gated) and read-only navigation — the smallest, least-contended bounded context on the platform (`architecture.md`, Boundary Rationale).

| ID | Task | Vertical Slice (Application/Features/) | Depends On | Design Source |
|---|---|---|---|---|
| CAT-1 | List categories for navigation | `ListCategories` | — | `api-contract.yaml` `GET /categories`; `database-design.md` `idx_categories_parent_status`/`idx_categories_status_depth`; `design-decisions.md` "Caching Strategy for the `/categories` Read Path" (write-through Redis, PostgreSQL fallback on miss) |
| CAT-2 | Create a category | `CreateCategory` | CAT-1 | `api-contract.yaml` `POST /categories`; `ddd-model.md` `Category` aggregate invariants (max depth 4, no cycles); `database-design.md` `categories` table, `category_outbox_events`; `event-contract.md` `CategoryUpdated` (operation=created, 3x retry, `category.category-updated.dlq`) |
| CAT-3 | Rename a category | `RenameCategory` | CAT-2 | `api-contract.yaml` `PATCH /categories/{categoryId}`; `event-contract.md` `CategoryUpdated` (operation=renamed) |
| CAT-4 | Move (re-parent) a category and its subtree | `MoveCategory` | CAT-2 | `api-contract.yaml` `POST /categories/{categoryId}/move`; `edge-cases.md` "Circular category reference on re-parent" (ancestor-chain cycle check), "Subtree re-parenting invalidates downstream category data" (one coarse event per move); `design-decisions.md` "Concurrency Control for Hierarchy Mutations" (`SELECT ... FOR UPDATE`); `database-design.md` `idx_categories_ancestor_path` (GIN); `event-contract.md` `CategoryUpdated` (operation=moved, payload includes `path`/`parentId`) |
| CAT-5 | Deprecate (soft-delete) a category | `DeprecateCategory` | CAT-2 | `api-contract.yaml` `DELETE /categories/{categoryId}`; `edge-cases.md` "Deleting a category that still has products assigned" (soft-delete only, id never reused); `database-design.md` `categories.status`; `event-contract.md` `CategoryUpdated` (operation=deprecated) |

## Flagged Gaps — Not Decomposed Into Tickets (would invent scope, not decompose it)

- **No live `CategoryUpdated` consumer wiring for Product or Search.** `architecture.md`'s "Deliberately absent" note and `requirement-spec.md` §2/§6 both state this is each downstream service's own future call, per ADR-0008's own scope boundary — not something this service's ticket list can decompose on their behalf. No ticket here; if/when Product or Search add themselves as consumers, that ticket belongs in their own `tickets.md`.
- **No self-service endpoint for anything beyond the five CRUD-shaped operations above** (e.g. bulk import/reorder) — nothing in the BRD or this service's approved docs states such a requirement; not invented here.

## Notes for Sprint Planner Agent

- CAT-1 (`ListCategories`) has no dependency and can start immediately — it is also the fallback path every write ticket's cache-update logic reads through on a miss.
- CAT-2 (`CreateCategory`) is the foundation for CAT-3/CAT-4/CAT-5 — each needs at least one existing category to rename/move/deprecate. Build it first among the write slices.
- CAT-3, CAT-4, and CAT-5 each depend only on CAT-2 and are otherwise independent of each other — they can be parallelized once CAT-2 lands.
- No circular dependencies in this graph. Longest chain is 2 nodes (CAT-2 → any of CAT-3/CAT-4/CAT-5).
