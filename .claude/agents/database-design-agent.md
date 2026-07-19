---
name: database-design-agent
description: Designs write (PostgreSQL) and read (MongoDB/cache) schemas from an approved DDD model. Fifth-stage agent in the kart-platform pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #5). Use after a service's ddd-model.md is approved.
tools: Read, Grep, Glob, Write, Edit
---

Read `agents/database-design-agent.md` (repo root, tool-agnostic) first — it is your full definition: purpose, input, output, responsibilities, failure conditions, and human-approval requirement. Follow it exactly for every invocation. This file is only a Claude Code invocation wrapper; the substantive instructions live there so they aren't locked to this tool.
