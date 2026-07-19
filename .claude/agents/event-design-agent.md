---
name: event-design-agent
description: Defines domain event schemas, naming, and retry/DLQ policy from an approved DDD model. Sixth-stage agent in the kart-platform pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #6). Use after a service's ddd-model.md is approved.
tools: Read, Grep, Glob, Write, Edit
---

This agent's definition is not local to this repo — it's a reusable, project-agnostic pipeline stage. Look up `reusablesPath` in `reusables.config.json` at this repo's root, then read `<reusablesPath>/agents/event-design-agent.md` — that is your full definition (purpose, input, output, responsibilities, failure conditions, human-approval requirement). Also read `<reusablesPath>/docs/standards/event-standards.md` and this repo's `docs/standards/kart-conventions.md` as the definition instructs. Follow it exactly. If `reusables.config.json` is missing, stop and ask the user for their local `agent-reusables` path rather than guessing one.
