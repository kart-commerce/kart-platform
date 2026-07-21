---
doc_type: adr
status: accepted
---

# ADR-0004: Analytics Ingests Full Event Fan-In

## Status

Accepted

## Context

`kart-requirements.md` §2.2 states, as a named forcing domain rule, "Analytics ingests every domain event → forces a durable event bus and schema versioning discipline," and §5.4 describes Analytics' consumption as "(fan-in)." §10's Event Catalog, however, only listed Analytics as a consumer on 6 of the 13 rows it contained at the time. `docs/services/README.md` tracked this as an open cross-service contradiction, affecting Kafka topic/partition sizing. `kart-analytics-service`'s own docs correctly flagged this as an open question (and were approved on that basis) — the underlying ambiguity itself needed a decision.

## Decision

Analytics consumes **every** published event in the platform — full fan-in, not a subset. §2.2's forcing rule is treated as authoritative over §10's incomplete table, because:

- §2.2 sits in "Domain Rules That Force Hard Engineering Decisions" — it's stated as a deliberate constraint, not incidental prose.
- §14/§15 (Kafka migration) explicitly justify migrating Analytics first *because* it needs replay across the full event set — a partial-fan-in reading would undercut the BRD's own stated migration rationale.
- §10 is independently known to be incomplete (see ADR-0007) — several published events had no catalog row at all — so its per-row consumer lists were never a reliable ceiling on scope.

`kart-requirements.md` §10 now lists Analytics as a consumer on every row; §5.4's Analytics row was updated to state this explicitly rather than leave "(fan-in)" as an ambiguous shorthand.

## Consequences

- Analytics' Kafka topic/partition sizing and schema-registry versioning discipline must be planned against the full 20-service event volume, not a 6-event subset — this is a real capacity-planning input, not just a documentation fix.
- Every future new event automatically has Analytics as a consumer by default — event-design-agent should treat "does Analytics need this" as already answered (yes) rather than a per-event question.
- `kart-analytics-service`'s `requirement-spec.md` should update its open question to cite this ADR as resolved.
