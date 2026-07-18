---
doc_type: standard
service: null
status: accepted
layer: messaging
applies_to_agents: [event-design-agent, coding-agent, contract-compatibility-agent]
---

# Event & Messaging Standards

## RabbitMQ (default, per BRD §8)

- Topic exchange (`ecommerce.events`); routing key convention `service.entity.action` (e.g., `order.created`).
- Every consumer queue has its own DLQ — never a shared/global DLQ.
- Retry via TTL-ladder parking-lot queues (`retry.5s`, `retry.30s`, `retry.5m`), never immediate requeue (avoids hot-loop under persistent failure).
- Topology is JSON-manifest-declared and applied idempotently at startup — never manual `rabbitmqctl` setup.
- Retry budget scales with criticality: money-moving events (Payment*) get the highest retry count + human paging on final failure; catalog/search events tolerate looser retry.

## Kafka (adopted per consumer group, per BRD §15)

- Only for consumers that need replay or partitioned high-throughput consumption (Analytics, Recommendation).
- Partition key = aggregate id, to preserve per-entity ordering.
- Migration is strangler-pattern: dual-publish from the Outbox during transition, cut over one consumer group at a time. Order/Payment/Inventory transactional flows stay on RabbitMQ permanently — this is case-by-case, not wholesale.

## Event Contract Rules

- Event name: `<Entity><PastTenseVerb>` — the event describes something that already happened.
- Every event schema is versioned; a breaking payload change requires a new version, old version supported through the consumer's documented migration window.
- Every new/changed event must pass through the Contract Compatibility Agent before merge.
