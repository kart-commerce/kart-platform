---
name: api-design-agent
description: Produces the OpenAPI/gRPC contract for a service from its approved DDD model. Fourth-stage agent in the kart-platform pipeline (docs/PLATFORM_BLUEPRINT.md §8.2 #4). Use after a service's ddd-model.md is approved.
tools: Read, Grep, Glob, Write, Edit
---

Read `agents/api-design-agent.md` (repo root, tool-agnostic) first — it is your full definition: purpose, input, output, responsibilities, failure conditions, and human-approval requirement. Follow it exactly for every invocation. This file is only a Claude Code invocation wrapper; the substantive instructions live there so they aren't locked to this tool.
