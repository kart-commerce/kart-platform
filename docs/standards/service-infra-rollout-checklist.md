---
doc_type: standard
service: kart-platform
status: accepted
layer: infrastructure
applies_to_agents: [scaffold-agent, code-review-agent]
---

# Service Infra Rollout Checklist — DB Migrations & Startup Readiness

Companion to `kart-conventions.md`'s "Database Migrations & Startup Readiness" section. That
section states the policy; this file is the reusable, paste-as-is prompt used to bring one more
service into compliance, plus the status table to keep updated as each service is done.

`kart-identity-service` is the reference implementation. `kart-category-service` was brought to
parity with it on 2026-07-29, and that pass is what this checklist is distilled from.

## Status table

| Service | DbContextFactory | migrate.sh + .env.example | Dockerfile.migrate | dotnet-tools.json | StartupConnectivityChecks | Health checks | Notes |
|---|---|---|---|---|---|---|---|
| `kart-identity-service` | yes | yes | yes | yes | yes | yes | Reference implementation |
| `kart-category-service` | yes | yes | yes | yes | yes | yes | Done 2026-07-29 |
| `kart-cart-service` | yes | no | no | no | no | no | Next candidate |
| `kart-inventory-service` | yes | no | no | no | no | no | Next candidate |
| `kart-offer-service` | yes | no | no | no | no | no | Next candidate |
| `kart-payment-service` | yes | no | no | no | no | no | Next candidate |
| `kart-product-service` | yes | no | no | no | no | no | Next candidate |
| `kart-user-service` | yes | no | no | no | no | no | Next candidate |
| `kart-delivery-tracking-service` | n/a | n/a | n/a | n/a | n/a | n/a | Scaffolded, no PostgreSQL/EF (different data store) |
| `kart-search-service` | n/a | n/a | n/a | n/a | n/a | n/a | Scaffolded, no PostgreSQL/EF (different data store) |
| All other service repos | — | — | — | — | — | — | Not yet scaffolded |

Update this table (and `kart-conventions.md`'s "Rollout status" line) whenever a service is brought
to parity or a new service is scaffolded with a PostgreSQL/EF store.

## The reusable prompt

Paste this into a fresh session for the target service, filling in the bracketed values. It assumes
the session's working directory has every `kart-*-service` repo checked out as a sibling (so
`kart-identity-service`'s actual files can be read directly, not guessed at).

```
Bring <SERVICE_REPO> (e.g. kart-inventory-service) up to parity with
kart-identity-service's migration/health/connectivity tooling. Identity is
the reference implementation for this pattern — read its actual files
before writing anything, don't guess at the shape:
  src/Infrastructure/Persistence/IdentityDbContextFactory.cs
  .config/dotnet-tools.json
  scripts/migrate.sh, .env.example
  Dockerfile.migrate
  src/Api/HealthChecks/IdentityDbHealthCheck.cs
  src/Api/StartupConnectivityChecks.cs
  Program.cs (AddHealthChecks/MapHealthChecks/StartupConnectivityChecks.RunAsync wiring)
  tests/ContractTests/IdentityApiFactory.cs (the UseEnvironment("Testing") guard)

First check what already exists in <SERVICE_REPO> — don't duplicate or
overwrite:
- src/Infrastructure/Persistence/*DbContextFactory.cs (most services
  already have this one — reuse its existing env var name, don't invent
  a new one)
- .config/dotnet-tools.json
- scripts/migrate.sh + .env.example
- Dockerfile.migrate
- src/Api/HealthChecks/*DbHealthCheck.cs
- src/Api/StartupConnectivityChecks.cs
- AddHealthChecks()/MapHealthChecks("/health/live","/health/ready") and
  the StartupConnectivityChecks.RunAsync(app) call in Program.cs
- Whichever WebApplicationFactory-based test factory the service has
  under tests/ContractTests (and tests/IntegrationTests if it also uses
  one) — check whether it already sets builder.UseEnvironment("Testing")

For each missing piece, mirror identity's exact file 1:1, substituting:
- the service's own DbContext type name (e.g. InventoryDbContext)
- its own env var name, <SERVICE>_DB_CONNECTION_STRING (match whatever
  convention the service's *existing* DbContextFactory.cs already uses)
- its own project/namespace names and .csproj paths in Dockerfile.migrate
- the dotnet-ef tool version matching that service's own
  Microsoft.EntityFrameworkCore.Design package version (check the
  Infrastructure .csproj)
- its own migration-sensitive table name in the health check's doc
  comment (e.g. identity's outbox_events -> whatever this service's own
  equivalent table is)

If the service has a WebApplicationFactory-based contract test factory
that does NOT swap out real Postgres/Redis/RabbitMQ registrations (i.e.
it just replaces application-layer interfaces with in-memory fakes, the
same way CategoryContractTestFactory does), add
builder.UseEnvironment("Testing") to it — StartupConnectivityChecks must
no-op there or the tests will try to hit real infra and fail. If it
already swaps them out with SQLite/removed hosted services (like
IdentityApiFactory), it should already have this guard — just confirm.

Also add:
- contracts/api-contract.yaml + contracts/README.md at repo root if not
  already vendored there (some services may only have a copy under
  tests/*/Fixtures/ — add the top-level one alongside it, don't touch
  the test-referenced copy or its csproj wiring)
- a migration-bundle CI job in .github/workflows/ci.yml that does
  `docker build -f Dockerfile.migrate -t ci-migrate-smoke-check:${{ github.sha }} .`
- a "contracts" solution folder in the .sln (ProjectSection(SolutionItems),
  same shape as kart-identity-service's .sln) listing every file actually
  present in contracts/

Verify at the end:
1. `dotnet build <Solution>.sln` — must succeed with 0 errors
2. `dotnet test` on every test project — no regressions vs. before your
   changes
3. `docker build -f Dockerfile.migrate -t smoke-check:local .` — must
   succeed and actually discover the service's existing migrations
   (confirm with `dotnet ef migrations list` against the same
   Infrastructure project)

Report back a table of what already existed vs. what you added, same
shape as: gap | file added | identity's equivalent. Then update this
service's row in kart-platform/docs/standards/service-infra-rollout-
checklist.md's status table.
```
