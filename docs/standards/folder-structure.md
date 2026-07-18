---
doc_type: standard
service: null
status: accepted
layer: coding
applies_to_agents: [scaffold-agent, coding-agent, code-review-agent]
---

# Folder Structure Standard

Every service combines **Clean Architecture** layering with **Vertical Slice** organization inside the Application layer — slices by use case, not by technical concern.

```
kart-<name>-service/
├── src/
│   ├── Api/                      # controllers/endpoints, thin, maps to Application
│   ├── Application/
│   │   └── Features/
│   │       └── <UseCaseName>/    # one folder per vertical slice
│   │           ├── Command.cs (or Query.cs)
│   │           ├── Handler.cs
│   │           ├── Validator.cs
│   │           └── Response.cs
│   ├── Domain/                   # aggregates, entities, value objects, domain events
│   └── Infrastructure/           # EF/Mongo/Redis/RabbitMQ implementations, outbox
├── tests/
│   ├── UnitTests/                # colocated by feature, mirrors Application/Features
│   ├── IntegrationTests/
│   └── ContractTests/
├── Dockerfile
└── .github/workflows/ci.yml      # calls reusable workflow from kart-devops
```

Rules:
- A vertical slice folder is self-contained: adding a feature should not require touching files outside its own folder plus `Domain` if a new invariant is needed.
- `Domain` never references `Infrastructure` or `Api`.
- No "Controllers/Services/Repositories" horizontal folders at the top of `Application` — that's the anti-pattern this structure explicitly rejects.
