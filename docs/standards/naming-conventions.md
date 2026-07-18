---
doc_type: standard
service: null
status: accepted
layer: coding
applies_to_agents: [coding-agent, api-design-agent, event-design-agent, database-design-agent, code-review-agent]
---

# Naming Conventions

| Element | Convention | Example |
|---|---|---|
| Service repo | `kart-<noun>-service` | `kart-offer-service` |
| Domain event | `<Entity><PastTenseVerb>` | `OrderCreated`, `PaymentFailed` |
| RabbitMQ routing key | `service.entity.action` | `order.created`, `payment.completed` |
| Kafka topic | `kart.<service>.<entity>` | `kart.analytics.order-events` |
| REST resource path | plural noun, no verbs | `/orders/{id}`, not `/getOrder` |
| Database table | snake_case, plural | `order_items` |
| C# class/type | PascalCase | `OrderAggregate` |
| C# variable/param | camelCase | `orderId` |
| Environment variable | SCREAMING_SNAKE_CASE | `PAYMENT_GATEWAY_API_KEY` |
| Feature flag | kebab-case | `flash-sale-pricing-v2` |

Rule of thumb: a name should be guessable by someone who has read the ubiquitous language glossary and nothing else.
