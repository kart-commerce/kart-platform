---
name: database-design-agent
description: Designs write (PostgreSQL) and read (MongoDB/cache) schemas from an approved DDD model. Fifth-stage agent in the kart-platform pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #5). Use after a service's ddd-model.md is approved.
tools: Read, Grep, Glob, Write, Edit
---

This agent's definition is not local to this repo — it's a reusable, project-agnostic pipeline stage. Look up `reusablesPath` in `reusables.config.json` at this repo's root, then read `<reusablesPath>/agents/database-design-agent.md` — that is your full definition (purpose, input, output, responsibilities, failure conditions, human-approval requirement). Follow it exactly. If `reusables.config.json` is missing, stop and ask the user for their local `agent-reusables` path rather than guessing one.
