---
doc_type: standard
service: null
status: accepted
layer: architecture
applies_to_agents: [architecture-agent, ddd-agent, database-design-agent, code-review-agent]
---

# DDD & CQRS Standards

## DDD

- One bounded context per repo. A service never implements domain logic that belongs to another context.
- Aggregates never span a database transaction boundary. If two "things" can't be saved in one transaction, they are two aggregates, not one.
- Ubiquitous language terms are owned by exactly one bounded context. Other contexts reference the concept through an Anti-Corruption Layer (ACL), never by importing the owning context's model.
- Every new or reused term is checked against `docs/ddd/ubiquitous-language.md` before being introduced. New terms are proposed additions, not silent introductions.
- Domain invariants (e.g., "inventory must never oversell") live in the aggregate that owns them, enforced in domain code — never only validated at the API edge.

## CQRS

- Write model is always PostgreSQL and is the source of truth.
- Read model (MongoDB, Redis, search index) is always rebuildable from the write model + event log. Never write to a read model outside a projection consumer.
- Eventual consistency windows must be surfaced to the client (e.g., "processing" state), never hidden behind a fake-synchronous response.
- A failed projection consumer must not lose data — the Outbox/event log is replayed, not patched by hand.
