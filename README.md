# kart-platform

KART is an ecommerce application. This repository holds only content specific to the KART business: requirements, the platform blueprint, and KART-specific conventions (`docs/standards/kart-conventions.md`).

Project-agnostic engineering standards — coding standards, DDD, CQRS, event/messaging standards, folder structure, API standards, git workflow — live in [agent-reusables](https://github.com/kakon-mehedi/agent-reusables), so they can be reused across every project in the organization, not just this one.

Every developer may clone `agent-reusables` to a different location, so its local path is never hardcoded — it's read from `reusables.config.json` (gitignored, machine-specific). To set yours up:

```
cp reusables.config.example.json reusables.config.json
# then edit reusablesPath to point at your local agent-reusables checkout
```

## Docs

- [`kart-requirements.md`](kart-requirements.md) — business requirements
- [`docs/PLATFORM_BLUEPRINT.md`](docs/PLATFORM_BLUEPRINT.md) — implementation blueprint
- [`docs/standards/kart-conventions.md`](docs/standards/kart-conventions.md) — KART-specific naming, bounded contexts, and conventions layered on top of the shared standards in `agent-reusables`
