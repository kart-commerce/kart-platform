#!/usr/bin/env bash
#
# release.sh -- generate a complete, production-grade release document (scope,
# checklist, common mistakes, GitHub release items) from docs/releases/releases.json,
# and optionally create the tracking milestone/issue on GitHub.
#
# Usage:
#   scripts/release.sh --list
#   scripts/release.sh <N> [--force]
#   scripts/release.sh <N> --create-github [--repo <owner/name>]
#   scripts/release.sh --ship <N>
#
# Requires: jq, git. --create-github additionally requires an authenticated `gh`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASES_JSON="$REPO_ROOT/docs/releases/releases.json"
OUT_DIR="$REPO_ROOT/docs/releases/generated"
COMMON_MISTAKES="docs/releases/COMMON_MISTAKES.md"
BENCH_TEMPLATE="docs/benchmarks/0000-benchmark-template.md"

FORCE=0
CREATE_GITHUB=0
SHIP_MODE=0
TARGET_REPO=""
RELEASE_NUM=""

die() { echo "error: $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
scripts/release.sh -- release documentation + GitHub automation for Kart

  scripts/release.sh --list                       List all releases with status
  scripts/release.sh <N>                          Generate docs/releases/generated/release-<N>-<slug>.md
  scripts/release.sh <N> --force                   Regenerate even if the file already exists
  scripts/release.sh <N> --create-github           Also create a GitHub milestone + tracking issue (requires `gh auth login`)
  scripts/release.sh <N> --create-github --repo o/r  Target a specific repo (default: current repo's origin)
  scripts/release.sh --ship <N>                    Mark release N as shipped (records today's date in releases.json)
  scripts/release.sh --help

Data source: docs/releases/releases.json (edit this, not the generated files, to change scope).
EOF
}

command -v jq >/dev/null 2>&1 || die "jq is required. Install it and re-run."
[ -f "$RELEASES_JSON" ] || die "not found: $RELEASES_JSON"

# ---- arg parsing ----
[ $# -eq 0 ] && { usage; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --list) LIST_MODE=1; shift ;;
    --force) FORCE=1; shift ;;
    --create-github) CREATE_GITHUB=1; shift ;;
    --ship) SHIP_MODE=1; shift; RELEASE_NUM="${1:-}"; [ -n "$RELEASE_NUM" ] || die "--ship requires a release number"; shift ;;
    --repo) TARGET_REPO="${2:-}"; [ -n "$TARGET_REPO" ] || die "--repo requires an owner/name argument"; shift 2 ;;
    [0-9]*) RELEASE_NUM="$1"; shift ;;
    *) die "unrecognized argument: $1 (see --help)" ;;
  esac
done

# ---- --list ----
if [ "${LIST_MODE:-0}" = "1" ]; then
  printf "%-4s %-28s %-12s %s\n" "#" "SLUG" "STATUS" "THEME"
  jq -r '.releases[] | [.number, .slug, .status, .theme] | @tsv' "$RELEASES_JSON" \
    | while IFS=$'\t' read -r n slug status theme; do
        printf "%-4s %-28s %-12s %s\n" "$n" "$slug" "$status" "$theme"
      done
  exit 0
fi

# ---- --ship ----
if [ "$SHIP_MODE" = "1" ]; then
  jq -e --arg n "$RELEASE_NUM" '.releases[] | select(.number == ($n | tonumber))' "$RELEASES_JSON" >/dev/null \
    || die "release $RELEASE_NUM not found in $RELEASES_JSON"
  TODAY="$(date +%Y-%m-%d)"
  tmp="$(mktemp)"
  jq --arg n "$RELEASE_NUM" --arg d "$TODAY" \
    '(.releases[] | select(.number == ($n | tonumber)) | .status) = "shipped"
     | (.releases[] | select(.number == ($n | tonumber)) | .shipped_date) = $d' \
    "$RELEASES_JSON" > "$tmp"
  mv "$tmp" "$RELEASES_JSON"
  echo "Release $RELEASE_NUM marked shipped ($TODAY) in $RELEASES_JSON"
  exit 0
fi

[ -n "$RELEASE_NUM" ] || { usage; die "no release number given"; }

REL="$(jq -c --arg n "$RELEASE_NUM" '.releases[] | select(.number == ($n | tonumber))' "$RELEASES_JSON")"
[ -n "$REL" ] || die "release $RELEASE_NUM not found in $RELEASES_JSON"

SLUG="$(jq -r '.slug' <<<"$REL")"
THEME="$(jq -r '.theme' <<<"$REL")"
STATUS="$(jq -r '.status' <<<"$REL")"
MILESTONE_TEXT="$(jq -r '.milestone' <<<"$REL")"
PRIORITY_NOTE="$(jq -r '.priority // empty' <<<"$REL")"
LT_TIER="$(jq -r '.load_test.tier' <<<"$REL")"
LT_RPM="$(jq -r '.load_test.rpm' <<<"$REL")"
LT_FOCUS="$(jq -r '.load_test.focus' <<<"$REL")"

OUT_FILE="$OUT_DIR/release-${RELEASE_NUM}-${SLUG}.md"
mkdir -p "$OUT_DIR"

if [ -f "$OUT_FILE" ] && [ "$FORCE" != "1" ]; then
  die "$OUT_FILE already exists. Re-run with --force to regenerate."
fi

# ---- warn if previous release isn't shipped yet (non-blocking) ----
if [ "$RELEASE_NUM" -gt 0 ] 2>/dev/null; then
  PREV=$((RELEASE_NUM - 1))
  PREV_STATUS="$(jq -r --arg n "$PREV" '.releases[] | select(.number == ($n | tonumber)) | .status' "$RELEASES_JSON" 2>/dev/null || true)"
  if [ -n "$PREV_STATUS" ] && [ "$PREV_STATUS" != "shipped" ]; then
    echo "warning: release $PREV is not marked 'shipped' yet (status: $PREV_STATUS) -- proceeding anyway." >&2
  fi
fi

# ---- semver tag convention: v0.N.0 pre-GA, v1.0.0 at the GA release ----
if [ "$RELEASE_NUM" = "9" ]; then
  TAG="v1.0.0"
else
  TAG="v0.${RELEASE_NUM}.0"
fi

# ---- build the document ----
{
  echo "---"
  echo "doc_type: release-plan"
  echo "release_number: ${RELEASE_NUM}"
  echo "status: ${STATUS}"
  echo "generated_by: scripts/release.sh from docs/releases/releases.json"
  echo "generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "---"
  echo
  echo "# Release ${RELEASE_NUM}: ${THEME}"
  echo
  if [ -n "$PRIORITY_NOTE" ]; then
    echo "> **${PRIORITY_NOTE}**"
    echo
  fi
  echo "**Exit milestone:** ${MILESTONE_TEXT}"
  echo
  echo "Regenerate this file with \`scripts/release.sh ${RELEASE_NUM} --force\` after editing \`docs/releases/releases.json\` -- do not hand-edit the Scope section below, hand-edit the checklists."
  echo
  echo "---"
  echo
  echo "## Scope"
  echo
  echo "### Backend"
  echo
  BACKEND_COUNT="$(jq '.backend | length' <<<"$REL")"
  if [ "$BACKEND_COUNT" -gt 0 ]; then
    echo "| Service | Tickets | Notes |"
    echo "|---|---|---|"
    jq -r '.backend[] | [.service, (.tickets // "n/a" | tostring), (.note // "")] | @tsv' <<<"$REL" \
      | while IFS=$'\t' read -r svc tix note; do
          if [ -d "$REPO_ROOT/docs/services/${svc}" ]; then
            echo "| [\`${svc}\`](../../services/${svc}/) | ${tix} | ${note} |"
          else
            echo "| \`${svc}\` | ${tix} | ${note} |"
          fi
        done
  else
    echo "_No new backend services in this release._"
  fi
  echo
  echo "### Frontend"
  echo
  jq -r '.frontend[]' <<<"$REL" | while IFS= read -r item; do echo "- ${item}"; done
  echo
  echo "### Load / Stress Testing"
  echo
  echo "| Tier | Target | Focus |"
  echo "|---|---|---|"
  echo "| ${LT_TIER} | ${LT_RPM} RPM | ${LT_FOCUS} |"
  echo
  echo "---"
  echo
  echo "## Pre-Release Checklist"
  echo
  echo "### Design-time (should already be true -- verify, don't assume)"
  echo
  if [ "$BACKEND_COUNT" -gt 0 ]; then
    jq -r '.backend[].service' <<<"$REL" | while IFS= read -r svc; do
      echo "- [ ] \`${svc}\`: requirement-spec, edge-cases, architecture, ddd-model, api/db/event contracts, and tickets are all \`status: approved\`"
    done
  else
    echo "- [ ] N/A (no new backend services this release)"
  fi
  echo
  echo "### Delivery (per service in this release, per PLATFORM_BLUEPRINT.md §11 Quality Gates)"
  echo
  cat <<'GATES'
- [ ] Coding Standards -- zero linter errors, standards-doc compliant
- [ ] Static Analysis -- no new critical/high findings
- [ ] Security Scan -- no critical/high CVE or SAST finding unresolved
- [ ] Code Review -- human approval obtained (agent verdict is advisory, never sufficient alone)
- [ ] Unit Tests -- coverage >= service-defined threshold, all pass
- [ ] Integration Tests -- all pass against the real contract
- [ ] Contract Tests -- provider/consumer contract verified (Pact-style) against every consumer in the registry
- [ ] Contract Compatibility -- no undeclared breaking change vs. any known consumer
- [ ] Performance Tests -- Baseline -> Low -> Medium tier all green (this is the routine gate; see Load/Stress table above for this release's milestone tier)
- [ ] Documentation Updated -- docs diff present in the same PR as the change it describes
- [ ] Memory Updated -- Decision/API/DB/Event/Coding memory rows written before CI/CD proceeds
- [ ] Docker Build -- multi-stage build succeeds, base image scan clean
- [ ] CI/CD -- all prior gates green
- [ ] Deployment Verification -- SLO metrics within budget during the canary verification window
- [ ] Rollback Strategy -- rollback executes within the defined RTO if verification fails (tested, not just documented)
GATES
  echo
  echo "### This release's milestone-level testing"
  echo
  echo "- [ ] Executed the ${LT_TIER} tier load test described above and recorded the result in \`docs/benchmarks/\` (one dated file per service, see \`${BENCH_TEMPLATE}\`)"
  echo "- [ ] Any gap between target and observed is either fixed, or explicitly accepted with a written reason"
  echo
  echo "### Cross-service integration"
  echo
  echo "- [ ] Every dependency this release's services consume (sync or async) is confirmed *actually deployed* in the target environment, not just \"approved\" on paper"
  echo "- [ ] Every feature flag introduced this release is registered in \`docs/client/approval-checklist.md\`'s tracked-flag list"
  echo
  echo "---"
  echo
  echo "## Common Mistakes & Precautions (this release's top risks)"
  echo
  echo "Full catalogue: [\`${COMMON_MISTAKES}\`](../COMMON_MISTAKES.md). Highest-relevance items for this release:"
  echo
  jq -r '.top_mistakes[]' <<<"$REL" | while IFS= read -r m; do echo "- [ ] ${m}"; done
  echo
  echo "---"
  echo
  echo "## GitHub Release Items"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Tag | \`${TAG}\` |"
  echo "| Title | Release ${RELEASE_NUM}: ${THEME} |"
  echo "| Milestone | \`Release ${RELEASE_NUM}: ${THEME}\` |"
  echo "| Target | only tag once this release's code is actually merged and deployed -- a tag on unmerged/undeployed code is a rollback target for nothing |"
  echo
  echo "### Release notes template (Keep a Changelog style, populate from Conventional Commit history)"
  echo
  cat <<NOTES
\`\`\`markdown
## ${TAG} -- Release ${RELEASE_NUM}: ${THEME}

### Added
- (feat: commits since the last tag)

### Changed
- (refactor:/perf: commits)

### Fixed
- (fix: commits)

### Security
- (any security-relevant fix -- never omit even if minor)

### Deprecated
- (any flag/endpoint marked for removal in a future release)

**Benchmarks:** link the dated report(s) in \`docs/benchmarks/\` for this release's load test.
**Rollback plan:** link the runbook/procedure to revert this release if Deployment Verification fails.
**Known issues:** anything carried forward, and any feature flag still OFF in Production at release time.
\`\`\`
NOTES
  echo
  echo "To generate the commit list once this release is merged:"
  echo
  echo '```bash'
  echo "git log \$(git describe --tags --abbrev=0)..HEAD --pretty=format:'- %s (%h)' | grep -E '^- (feat|fix|refactor|perf|security)'"
  echo '```'
  echo
  echo "To actually publish the GitHub Release once the tag exists and CI is green:"
  echo
  echo '```bash'
  echo "gh release create ${TAG} --title \"Release ${RELEASE_NUM}: ${THEME}\" --notes-file <path-to-filled-in-notes.md>"
  echo '```'
  echo
} > "$OUT_FILE"

echo "Generated: $OUT_FILE"

# ---- optional GitHub automation: milestone + tracking issue ----
if [ "$CREATE_GITHUB" = "1" ]; then
  command -v gh >/dev/null 2>&1 || die "--create-github requires the GitHub CLI (gh). Install it and run 'gh auth login'."
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run 'gh auth login' first."

  REPO_ARG=()
  [ -n "$TARGET_REPO" ] && REPO_ARG=(--repo "$TARGET_REPO")

  MILESTONE_TITLE="Release ${RELEASE_NUM}: ${THEME}"
  echo "Checking for existing milestone: ${MILESTONE_TITLE}"

  OWNER_REPO="$TARGET_REPO"
  if [ -z "$OWNER_REPO" ]; then
    OWNER_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  [ -n "$OWNER_REPO" ] || die "could not determine target repo -- pass --repo <owner/name>"

  EXISTING_MS="$(gh api "repos/${OWNER_REPO}/milestones?state=all" --jq ".[] | select(.title == \"${MILESTONE_TITLE}\") | .number" 2>/dev/null || true)"

  if [ -n "$EXISTING_MS" ]; then
    echo "Milestone already exists (#${EXISTING_MS}), reusing it."
    MS_NUMBER="$EXISTING_MS"
  else
    MS_NUMBER="$(gh api "repos/${OWNER_REPO}/milestones" -f title="$MILESTONE_TITLE" -f description="$MILESTONE_TEXT" --jq .number)"
    echo "Created milestone #${MS_NUMBER}: ${MILESTONE_TITLE}"
  fi

  ISSUE_BODY_FILE="$(mktemp)"
  {
    echo "Tracking issue for **Release ${RELEASE_NUM}: ${THEME}**, generated from \`${OUT_FILE#$REPO_ROOT/}\`."
    echo
    echo "Full checklist: [\`$(basename "$OUT_FILE")\`](../blob/main/${OUT_FILE#$REPO_ROOT/})"
    echo
    sed -n '/## Pre-Release Checklist/,/## Common Mistakes/p' "$OUT_FILE" | sed '$d'
  } > "$ISSUE_BODY_FILE"

  ISSUE_URL="$(gh issue create "${REPO_ARG[@]}" \
    --title "Release ${RELEASE_NUM}: ${THEME}" \
    --body-file "$ISSUE_BODY_FILE" \
    --milestone "$MILESTONE_TITLE" 2>&1)" \
    || die "failed to create tracking issue: $ISSUE_URL"

  rm -f "$ISSUE_BODY_FILE"
  echo "Created tracking issue: $ISSUE_URL"
fi
