---
doc_type: edge-cases
service: kart-admin-service
status: pending-approval
generated_by: edge-case-analyzer-agent
source: docs/services/kart-admin-service/requirement-spec.md
---

# Edge Cases: kart-admin-service

## Edge Case: Privilege Escalation via Misconfigured or Under-Specified RBAC

- **What happens:** An actor performs an admin action their intended role should not permit, either by exploiting a gap in role/permission checks or by being granted a broader role than intended during provisioning.
- **Why it happens:** The role/permission model is unspecified (Open Question 1) — the requirement-spec's only stated invariant is that *some* check must exist (Domain Invariant #1), not its shape (default-allow vs. default-deny, flat roles vs. fine-grained permissions, hierarchy). An under-specified model is the direct condition that lets an implementation drift toward an over-permissive default.
- **Solutions available (3):** Default-deny, explicit-grant permission model (every action requires an explicit permission; absence of a grant blocks the action) · Default-allow role model with an explicit deny-list for restricted actions · Coarse role tiers only (e.g., "admin"/"super-admin") with no per-action granularity
- **Decision:**
  - Chosen: Default-deny, explicit-grant permission model
  - Why: RBAC is Admin Service's stated reason to exist (BRD §2.1 item 20); a default-deny posture fails closed when a new admin action is added and its permission is forgotten, whereas default-allow fails open in the same scenario
  - Trade-off accepted: Every new admin action requires an explicit permission to be defined and assigned before it is usable, which is more provisioning overhead than a coarse role-tier model

## Edge Case: Admin Action Succeeds but `AdminActionPerformed` Is Lost

- **What happens:** A back-office write commits, but the corresponding `AdminActionPerformed` event never publishes (crash between the DB write and the publish step, or a partial-write failure on a multi-record admin operation), leaving the action with no audit trail.
- **Why it happens:** Domain Invariant #2 states the action and its audit event should not silently diverge, but the requirement-spec does not confirm Admin uses the Outbox pattern (BRD §11) that exists platform-wide to solve exactly this dual-write problem (Open Question 3) — without it, a crash between the two writes is unrecoverable by construction.
- **Solutions available (3):** Outbox pattern (write the event into the same PostgreSQL transaction as the admin action; a poller publishes it after commit) · Synchronous publish-then-commit (publish first, commit the action only on broker ack) · Best-effort fire-and-forget publish with no transactional guarantee
- **Decision:**
  - Chosen: Outbox pattern, matching the platform-wide pattern (BRD §11)
  - Why: Admin actions are the platform's highest-privilege operations (Non-Functional Requirement: Security); an audit event that can silently vanish undermines the entire reason RBAC and audit exist, and the platform already has a standard mechanism for this exact failure mode rather than needing a one-off
  - Trade-off accepted: Introduces poller latency (event visible to consumers slightly after the action commits, not synchronously) versus the simpler but unsafe fire-and-forget option

## Edge Case: Concurrent Admins Editing the Same Back-Office Record

- **What happens:** Two admins (or one admin and an automated back-office process) read the same record, both act on it based on that stale read, and the second write silently overwrites the first's change.
- **Why it happens:** The Consistency NFR requires strong consistency on Admin's PostgreSQL write path because a stale read is a "security or operational-correctness defect, not a UX one" — but nothing in the requirement-spec constrains concurrent writers to the same record, and "back-office operations" (Open Question 2) are exactly the kind of infrequent, high-stakes, multi-operator writes where this race is plausible (e.g., two admins independently resolving the same flagged account).
- **Solutions available (3):** Optimistic concurrency control (version/row-timestamp check; second writer's update is rejected and must re-read) · Pessimistic row-level locking for the duration of an admin edit · No concurrency control (last-write-wins)
- **Decision:**
  - Chosen: Optimistic concurrency control (version column, conditional update)
  - Why: Admin actions are infrequent and human-paced relative to customer-facing traffic, so lock contention is not a throughput concern; a rejected stale write forces the second admin to see the first admin's change before proceeding, which matters more here than in a high-throughput path
  - Trade-off accepted: The losing admin's action is rejected and must be manually retried against fresh data, rather than being silently merged or serialized automatically

## Edge Case: Over-Broad `/admin/*` Surface as a Single Blast-Radius Point

- **What happens:** A single compromised admin credential, or a single vulnerability in the `/admin/*` surface, exposes actions across multiple unrelated back-office domains at once (e.g., user accounts, orders, inventory) rather than being contained to one.
- **Why it happens:** "Back-office operations" is unenumerated (Open Question 2) and the BRD gives Admin one flat API surface (`/admin/*`) rather than domain-scoped surfaces — combined with the unspecified role model (Open Question 1), a broad or coarse-grained surface makes any single compromise high-impact by construction, which is exactly the risk the Security NFR flags as Admin's defining concern.
- **Solutions available (3):** Domain-scoped sub-surfaces with independent permission grants per domain (e.g., a role scoped only to user-account actions cannot touch inventory actions) · Single flat `/admin/*` surface with fine-grained per-action permissions but no domain isolation · Separate deployable admin surfaces per domain (no shared blast radius at the service level)
- **Decision:**
  - Chosen: Single service with domain-scoped sub-surfaces and independent permission grants per domain
  - Why: Splitting into separate services per domain contradicts the BRD's own service boundary (Admin is one row, one service, at §2.1 item 20); domain-scoped permissions within one service contains blast radius without inventing a service split the BRD never states
  - Trade-off accepted: A vulnerability in the shared service process itself (as opposed to a permission-model gap) still exposes every domain, since isolation here is at the authorization layer, not the deployment boundary

## Edge Case: Stale Privilege After Role or Permission Revocation

- **What happens:** An admin's role or permission is downgraded or revoked, but a JWT already issued with the old scoped claims continues to be honored for sensitive actions until it naturally expires.
- **Why it happens:** BRD §24 states JWTs carry scoped claims validated at the gateway and re-checked at the service for sensitive operations, with short-lived (~15 min) access tokens and a revocation list for logout — but that revocation list is stated for logout, not for a mid-session permission downgrade, and Domain Invariant #1 only requires that a role check exist, not that it be re-evaluated against current state on every request.
- **Solutions available (3):** Re-check current role/permission state against the authorization store on every sensitive admin action (not just the JWT's cached scoped claims) · Extend the existing revocation list to cover permission downgrades, not just logout, and have the service consult it for sensitive operations · Rely solely on short token TTL (~15 min) as the only bound on stale privilege
- **Decision:**
  - Chosen: Re-check current role/permission state against the authorization store for every sensitive admin action, using the JWT only to establish identity
  - Why: BRD §24 already requires re-checking at the service "for sensitive operations" — every admin action is a sensitive operation by this service's definition, so treating the JWT's scoped claims as a cache to be validated, not a source of truth, is the more targeted fix than widening the logout-specific revocation list
  - Trade-off accepted: Requires a per-request lookup against current authorization state instead of trusting the token's embedded claims, adding a dependency the stateless JWT model was otherwise designed to avoid
