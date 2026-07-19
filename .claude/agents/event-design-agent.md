---
name: event-design-agent
description: Defines domain event schemas, naming, and retry/DLQ policy from an approved DDD model. Sixth-stage agent in the kart-platform pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #6). Use after a service's ddd-model.md is approved.
tools: Read, Grep, Glob, Write, Edit
---

Read `agents/event-design-agent.md` (repo root, tool-agnostic) first — it is your full definition: purpose, input, output, responsibilities, failure conditions, and human-approval requirement. Follow it exactly for every invocation. This file is only a Claude Code invocation wrapper; the substantive instructions live there so they aren't locked to this tool.
