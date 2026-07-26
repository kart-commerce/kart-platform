---
doc_type: design-decisions
service: kart-admin-web
status: approved
generated_by: design-decision-agent
source: docs/client/kart-admin-web/requirement-spec.md, docs/client/kart-admin-web/edge-cases.md
---

# Design Decisions: kart-admin-web

Cross-cutting technology/pattern choices this app's requirement-spec and edge-cases force. Service/architecture boundaries (`architecture.md`'s thin fan-out client, no domain logic) and the design-token/component-sharing mechanism (`design-system.md`) are already decided elsewhere and out of scope here — this doc only covers the client-side technology and pattern layer this app's own smaller surface (idle-session lifecycle, multi-tab sync, the Refund Requests queue, category-grant UI gating) forces on top of those.

## Decision: Idle-Session Client State Machine (Idle Timer, Warning Modal, Active-Tab-Gated Silent Refresh)

- **Requirement driving this:** `security.md` §2.2 (role-split idle timeout — `Admin` 15 min / `Support Agent` 20 min — 60-second warning modal, and silent refresh "only while the tab is active/interacted-with"); `edge-cases.md`'s "Idle-Timeout Warning Countdown Racing an In-Flight Refund-Approval Submit"
- **Options considered (3):** A dedicated in-house idle-session state machine (`Active → Warning → Expired`) that resets on interaction/`visibilitychange`, gates the silent-refresh interceptor on tab-active state, and treats any outstanding mutating HTTP request as activity (pausing the countdown until it resolves) · A third-party idle-detection library (e.g. `ngx-idle`) wired independently to a separate refresh interceptor, with no shared state or in-flight-request awareness · No client-side idle detection at all — rely solely on the 15-minute access token lapsing naturally, reactive re-auth on the next 401
- **Decision:**
  - Chosen: a dedicated in-house idle-session state machine
  - Why: `security.md` §2.2's active-tab-only silent-refresh rule and the edge-case's pause-during-in-flight-mutation fix both require the idle timer, the refresh interceptor, and the HTTP layer to share one coordinated state — a stock idle-detection library only solves generic inactivity detection, not this app's specific "an in-flight write counts as activity" rule; a token-lapse-only approach gives zero warning, violating §2.2's mandatory 60-second warning-popup requirement outright
  - Trade-off accepted: a small piece of custom-built, custom-tested infrastructure this app must own and maintain itself (an in-flight-request counter feeding the timer, a tab-active flag feeding the refresh interceptor) rather than delegating idle-detection's well-trodden edge cases to a maintained third-party library

## Decision: Multi-Tab Session Sync — `BroadcastChannel`, Session-Lifecycle-Scoped Only

- **Requirement driving this:** `security.md` §2.2 (`BroadcastChannel('kart-admin-session')`, "any tab's interaction resets the shared idle timer... a warning popup or logout in any tab is mirrored to all tabs immediately"); `edge-cases.md`'s "Multi-Tab BroadcastChannel Doesn't Propagate a Mid-Session Grant/Role Change"
- **Options considered (3):** `BroadcastChannel` scoped strictly to session-lifecycle events (activity ping, warning-shown, logout), with a `storage`-event fallback for older engines, matching `security.md` §2.1's already-established `kart-session` pattern for `kart-web` · Extend the same channel (or add a sibling one) to also carry permission/grant-change events, pushed whenever an Admin edits any principal's grant · A `SharedWorker`-based single leader-election session coordinator, centralizing idle-timer/refresh logic in one worker instead of replicated per-tab state
- **Decision:**
  - Chosen: `BroadcastChannel` scoped to session lifecycle only — no grant-change propagation
  - Why: reuses the already-established platform pattern (`security.md` §2.1) rather than inventing a different multi-tab mechanism for this app; `edge-cases.md`'s own resolved decision explicitly rejects extending the channel to grant-change events, since `requirement-spec.md` §5's "UX convenience, not the enforcement point" rule already guarantees no privilege escalation from a stale-rendered control regardless of channel scope — a `SharedWorker` coordinator would centralize more state than this app's actual need ("logout is instant and total") justifies
  - Trade-off accepted: the consistency guarantee is narrow and best-effort — delivery is same-origin, same-browser-profile, open-tabs-only (no cross-device guarantee, no guarantee to a backgrounded/suspended tab until it resumes foreground), and by design carries nothing about permission/grant state; a tab can render a stale-but-harmless enabled control until its own next navigation/reload, with the server remaining the sole actual enforcement point (`security.md` §2.2's own enforcement note)

## Decision: Refund Request Approval — No Client-Side Concurrency or Live-Validation Layer

- **Requirement driving this:** `edge-cases.md`'s "Concurrent Support Agents Double-Approving the Same Refund Request" and "Support Agent's Refund-Approval Cap Changes Between Viewing and Approving"; `checkout-and-refunds.md` §B.4's `ReturnRequest` state machine (`Requested → Approved/Rejected`); `architecture.md`'s thin fan-out client boundary ("holds none of `kart-admin-service`'s actual authorization decisions client-side")
- **Options considered (3):** Rely entirely on the backend's own optimistic concurrency/state-transition guard (`Requested → Approved` rejected if already resolved in `kart-order-service`; per-order refund cap re-checked live, per request, in `kart-admin-service`), with the client only surfacing a friendly "already resolved by \<principal\>" / "escalated to Admin" message and an auto-refresh of the queue · Client-side soft-lock ("being reviewed by X") plus a just-in-time cap re-fetch before enabling Approve, without any new backend guarantee · WS/SSE-driven live queue push so a second viewer sees an item resolve, or their own cap change, before they can click
- **Decision:**
  - Chosen: no client-side concurrency-control or live-validation mechanism at all — every Approve/Reject submit is trusted to the backend's existing transition guard and live per-request grant check; the client's only job is presenting a rejection or escalation outcome well
  - Why: both edge cases already establish the actual invariant (transition guard, live cap check) lives in `kart-order-service`/`kart-admin-service` regardless of what this app does client-side, and `architecture.md` forecloses this app from holding any domain logic of its own; a soft-lock or a live push channel would be new infrastructure built solely to shave a rare, human-paced, low-volume race to zero when the backend already makes that race safe
  - Trade-off accepted: a Support Agent can waste a click on an already-resolved item, or see a surprise "escalated to Admin" outcome for a cap that changed after render — both handled via existing error-toast/messaging patterns, not a pre-emptively greyed-out control; no WS/SSE infrastructure is stood up for this feature alone, consistent with `architecture.md` marking that channel "optional at launch," not required

## Decision: Category-Grant UI Gating — Layered Route Guard + Render-Time Control Check

- **Requirement driving this:** `requirement-spec.md` §5 ("a control for an action the current principal's grant doesn't cover renders disabled/hidden... UX convenience, not the enforcement point"); `edge-cases.md`'s "Direct-URL Navigation to a Category-Gated Route the Session's Grant Doesn't Cover"
- **Options considered (3):** Route-level `CanActivate` guard only (redirect to Access Denied on navigation), no separate per-control render-time check inside an already-accessible screen · Render-time conditional disabling/hiding of individual controls only, no route guard — an ungated route simply lets its own API calls fail 403 · Both layered: a route guard at navigation entry (dedicated Access Denied component) plus a render-time grant check on every individual write control within an accessible screen
- **Decision:**
  - Chosen: both, layered
  - Why: the edge case shows a route guard alone only stops navigation to a screen a grant doesn't cover at all — it says nothing about a screen the principal *can* enter (e.g., the shared Audit & Compliance screen) that contains individual actions or sub-views gated at a finer grain than the route itself; `requirement-spec.md` §5's rule applies at both grains, so both mechanisms are needed, each still UX-only
  - Trade-off accepted: two separate gating mechanisms (route table + per-control render conditions) must be kept in sync with `kart-admin-service`'s grant model as it evolves — a review/lint discipline item per `edge-cases.md`'s own accepted trade-off, not a single framework-enforced source of truth

## Decision: `compliance` Category Addition — Reuse the Existing Gating Pattern at Sub-View Granularity

- **Requirement driving this:** `edge-cases.md`'s "Privacy Requests View's Blanket 'Any Admin' Read Access Over-Exposes GDPR-Sensitive Data" (final decision: gate behind a new `compliance` category grant, adding one enum value to `kart-admin-service`'s existing grant mechanism); `requirement-spec.md` §3.5 (Audit & Compliance dashboard, "deliberately readable by any `Admin`-role holder regardless of category grant"); `privacy.md` §B.9
- **Options considered (3):** Treat `compliance` as an ordinary fifth category value and gate the Privacy Requests sub-view using the identical route-guard-plus-render-time-check pattern (previous Decision) already built for the other four categories, applied at sub-view/component granularity since the parent Audit & Compliance route itself stays reachable by any `Admin` · Build a bespoke access-check specific to the Privacy Requests view, separate from the category-grant enum and its existing UI pattern · Render the view unconditionally for every `Admin` and mask/redact PII fields client-side based on grant, rather than gating the view itself
- **Decision:**
  - Chosen: treat `compliance` as an ordinary fifth grant value, reusing the previous Decision's pattern applied at sub-view granularity — the Audit & Compliance route stays reachable by any `Admin` (§3.5's blanket rule, unchanged), but the Privacy Requests panel nested within it renders only for a principal holding the `compliance` grant
  - Why: `edge-cases.md`'s own resolution frames this explicitly as "adding one new category value, not a new access-control mechanism" — the client-side implication is symmetric: no new UI-gating mechanism either, only a fifth value flowing through the render-time check this app already needs for every other category; a field-level redaction scheme would be new engineering to solve a problem the existing gate-the-view approach already closes
  - Trade-off accepted: the Audit & Compliance screen becomes this app's one deliberately mixed-granularity screen — reachable by route for any `Admin`, but internally render-gated at the sub-view level for its most sensitive panel — a pattern this app's other four features don't need and must not casually copy elsewhere without the same GDPR-driven justification

## Decision: Absolute-Session-Cap Advance Warning + Client-Side Draft Persistence

- **Requirement driving this:** `edge-cases.md`'s "Admin's Federated Session Hits Its 24-Hour Absolute Cap Mid-Task With No Warning"; `security.md` §1/§2.2 (24-hour federated cap, no sliding extension; warning-popup scoped only to idle-timeout, leaving the absolute-cap path with none)
- **Options considered (3):** A distinct one-time advance-warning modal (~5 minutes before the absolute cap, no "Stay signed in" action, separate copy from the idle-timeout modal) plus client-side autosave/draft persistence for genuinely multi-step Admin forms (permission-grant edits, bulk catalog operations) · Accept the hard cliff as inherent to "no sliding extension" and invest only in autosave/resumable forms, no warning modal at all · A silent, transparent re-federation redirect attempted at the cap boundary
- **Decision:**
  - Chosen: both the advance-warning modal and client-side draft persistence, drafts stored in a distinct browser-storage key from any session/token data
  - Why: matches `edge-cases.md`'s resolved decision directly — the 24-hour figure itself is correct and not renegotiated, only the total absence of any warning for that specific path is the gap being closed; silent re-federation was rejected outright as it would defeat the entire point of a hard, non-sliding cap
  - Trade-off accepted: the warning is best-effort only (an Admin mid-submit when it fires can still lose unsaved work), and the draft-persistence store must hold only form-field content, never a token or session identifier, to stay inside `security.md` §1's "never write a token to `localStorage`/`sessionStorage`" prohibition — a boundary this new mechanism must not blur just because it also uses browser storage

## Sign-off

- [x] Reviewed by: Automated architecture pipeline — autonomous completion authorized by project owner (per design-decision-agent's Human Approval Required gate)
