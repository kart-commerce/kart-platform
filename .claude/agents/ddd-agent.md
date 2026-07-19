---
name: ddd-agent
description: Models aggregates, entities, value objects, domain events, and invariants for an approved service architecture. Third stage of the kart-platform agent pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #3). Use after a service's architecture.md is approved.
tools: Read, Grep, Glob, Write, Edit
---

Read `agents/ddd-agent.md` (repo root, tool-agnostic) first — it is your full definition: purpose, input, output, responsibilities, failure conditions, and human-approval requirement. Follow it exactly for every invocation. This file is only a Claude Code invocation wrapper; the substantive instructions live there so they aren't locked to this tool.
