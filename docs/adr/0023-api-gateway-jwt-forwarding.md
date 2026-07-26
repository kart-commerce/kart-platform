---
doc_type: adr
status: accepted
---

# ADR-0023: API Gateway Forwards the Original Client JWT — No Minted Internal Header

## Status

Accepted

## Context

BRD §18's API Gateway table states, under Authentication: "JWT validated at gateway edge; downstream services trust a signed internal header, not the raw client token." Read literally, this requires the Gateway to validate the client's JWT, then mint a *second*, gateway-signed artifact (an internal header) that is what downstream services actually trust — the raw client-issued JWT would stop at the edge.

This is in direct tension with two already-approved, already-implemented downstream services:

- `kart-category-service`'s `AuthenticationExtensions.cs`/`JwksSigningKeyResolver.cs` (approved, shipped) configure `JwtBearer` to validate the **original** Identity-issued RS256 JWT directly against Identity's own JWKS — there is no internal-header scheme anywhere in that service's auth pipeline, and its own code comment states the claim shape is read directly off `kart-identity-service`'s `JwtAccessTokenGenerator` (`roles` claim, `RS256`).
- `kart-identity-service/architecture.md`'s Dependencies table lists "API Gateway | JWKS public-key retrieval ... RS256 local signature verification" as the **only** Gateway→Identity coupling, and separately documents the Gateway's shared-Redis revocation-list read as reading `identity:revocation:*` keys directly — neither of which is consistent with the Gateway instead minting and signing its own internal token format.

BRD §24's own AuthZ row is the second, more specific data point: "JWT with scoped claims, validated at gateway **+ re-checked at service** for sensitive operations." This directly names the pattern every already-shipped service actually implements — the service re-validates the same JWT, it does not trust a gateway-minted substitute. §24.1.3's "Three Checks, Not Two" enforcement flow is built entirely around the Gateway performing a coarse role check and the **owning service** performing its own fine-grained check against claims in the same token — again presupposing the service sees the original token's claims, not an opaque internal header.

Per this repo's own rule (`AGENTS.md` §2, "never silently resolve a contradiction ... by picking one reading"): both readings are named above. §18's "signed internal header" phrasing is the more generic, single-line summary row (analogous to how ADR-0011 treated BRD §6.1's "Read-heavy" grouping as the less specific of two conflicting passages); §24/§24.1.3's "re-checked at service" description is the more detailed, itemized description of the same enforcement flow, and it is also the reading every downstream service's *own already-approved and already-implemented* code follows. Building the Gateway to the §18 reading would not just contradict a doc — it would make two already-shipped services' auth pipelines subtly wrong in production (they'd be validating a token the Gateway no longer forwards).

## Decision

**The Gateway forwards the client's original Identity-issued JWT to upstream services unchanged (`Authorization: Bearer <token>`, verbatim). It does not mint, sign, or forward any second "internal header" token format.**

The Gateway still performs its own edge-level JWT work — RS256 signature/expiry validation against Identity's JWKS, plus the Redis revocation-list check (`kart-identity-service/architecture.md`'s Dependencies table) — and rejects a request outright (401/403) before it ever reaches an upstream service if that validation fails. This is the coarse check in §24.1.3's three-check flow. The token that *does* reach the upstream service is the same one the client presented, letting each service's own JWKS-backed `JwtBearer` configuration (already shipped identically in `kart-category-service`, and to be shipped identically in `kart-identity-service` itself for its own internal-facing surface) re-validate it and read its own claims for the fine-grained check, exactly as §24's AuthZ row and §24.1.3 describe.

## Consequences

- No new token format, signing key, or claims-mapping layer is introduced at the Gateway — it reuses the same RS256/JWKS trust chain every service already implements, which is also why `kart-api-gateway`'s own `JwksSigningKeyResolver` (this repo's `design-decisions.md`) can be a near-verbatim reuse of `kart-category-service`'s implementation rather than a new design.
- Downstream services keep re-validating the JWT on every request (§24's stated "re-checked at service") — this is accepted latency/CPU cost per service, not eliminated by the Gateway's edge check; the Gateway's check exists to reject obviously-bad/revoked traffic early, not to be the sole authority.
- If a future need arises for the Gateway to assert something no client JWT can express (e.g., a WAF/bot-score signal), that is new scope requiring its own ADR — this decision does not foreclose ever adding a second, additive header, only rejects *replacing* the forwarded JWT with one.
- This ADR is scoped to the Gateway's own `architecture.md`/`design-decisions.md`; it does not require reopening `kart-category-service`'s or `kart-identity-service`'s already-approved docs, since both already independently describe (and implement) the direct-JWKS-validation behavior this decision formalizes as the platform-wide pattern.
