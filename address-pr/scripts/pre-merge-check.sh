#!/usr/bin/env bash
#
# pre-merge-check.sh — Hard gate before merging a PR
#
# Exits non-zero if any check fails. Must be called before every gh pr merge.
#
# Usage:
#   ~/.claude/skills/address-pr/scripts/pre-merge-check.sh <pr-number>
#
# Repo is auto-detected from cwd via `gh repo view`. Override with REPO env var:
#   REPO=your-org/other-repo bash .../pre-merge-check.sh 42
#
# Checks:
#   1. CI green
#   2. Copilot has reviewed since latest push + all comments resolved
#   3. All pre-merge test plan items checked
#
set -euo pipefail

PR="${1:?Usage: $0 <pr-number>}"

if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "Error: PR number must be numeric, got: $PR" >&2
  exit 1
fi

# Resolve repo: explicit REPO env var wins, otherwise discover from cwd
REPO="${REPO:-$(bash ~/.claude/skills/_gh/gh.sh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)}"
if [ -z "${REPO:-}" ]; then
  echo "Error: could not determine repo. Run from inside a gh-recognized repo or set REPO=owner/name." >&2
  exit 1
fi
OWNER="${REPO%%/*}"
NAME="${REPO##*/}"

echo "=========================================="
echo "Pre-merge gate: ${REPO} PR #${PR}"
echo "=========================================="

ERRORS=0

# ── 1. CI green ──────────────────────────────────────────────────────────────

echo ""
echo "1. CI status..."
CI_OUTPUT=$(bash ~/.claude/skills/_gh/gh.sh pr checks "$PR" --repo "$REPO" 2>&1) || CI_EXIT=$?
CI_EXIT=${CI_EXIT:-0}
if [ "$CI_EXIT" -ne 0 ] && [ -z "$CI_OUTPUT" ]; then
  echo "  ❌ Failed to get CI status (API error?)"
  ERRORS=$((ERRORS + 1))
# `grep -q PATTERN <<<"$VAR"`, not `echo "$VAR" | grep -q PATTERN`: under
# `set -o pipefail` (line 18), a `grep -q` that matches early can SIGPIPE the
# `echo` subprocess mid-write on a large enough $VAR, and pipefail then
# reports that SIGPIPE (141) as the whole pipeline's exit status instead of
# grep's real one — found and fixed the same bug class in design-score's
# score.sh (2026-07-21); a here-string has no live producer process to SIGPIPE.
elif grep -q "fail" <<<"$CI_OUTPUT"; then
  echo "  ❌ CI has failures:"
  echo "$CI_OUTPUT" | grep "fail" | sed 's/^/     /'
  ERRORS=$((ERRORS + 1))
elif grep -q "pending" <<<"$CI_OUTPUT"; then
  echo "  ❌ CI still pending:"
  echo "$CI_OUTPUT" | grep "pending" | sed 's/^/     /'
  ERRORS=$((ERRORS + 1))
elif grep -q "no checks reported" <<<"$CI_OUTPUT"; then
  echo "  ✅ No CI checks (docs-only PR)"
else
  echo "  ✅ All CI checks pass"
fi

# ── 2. Copilot review completed + comments resolved ─────────────────────────
#
# GitHub offers two separate Copilot PR products:
#
#   * Copilot Code Review — bot `copilot-pull-request-reviewer`, posts
#     formal PullRequestReview objects. Available on Copilot Enterprise
#     or Business orgs with the Code Review add-on.
#   * Copilot Coding Agent — bot `copilot-swe-agent` (shown as "Copilot"
#     in the UI), posts plain issue comments in response to `@copilot
#     review` mentions. Present on any Copilot Business/Enterprise seat.
#
# Many orgs only have the Coding Agent tier (not the Code Review add-on),
# whose reviews never appear in the `reviews` object. This check
# treats EITHER a formal Copilot review OR a post-push issue comment
# authored by "Copilot" as "reviewed since latest push".

echo ""
echo "2. Review comments..."

if ! command -v jq >/dev/null 2>&1; then
  echo "  ❌ Review check requires 'jq' but it is not installed"
  ERRORS=$((ERRORS + 1))
else
  REVIEW_JSON=$(bash ~/.claude/skills/_gh/gh.sh api graphql \
    -f owner="$OWNER" -f name="$NAME" -F number="$PR" \
    -f query='
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviews(last: 20) {
            nodes { author { login } state submittedAt }
          }
          commits(last: 1) {
            nodes { commit { pushedDate } }
          }
          reviewThreads(first: 100) {
            nodes { isResolved }
          }
        }
      }
    }' 2>&1) || REVIEW_EXIT=$?
  REVIEW_EXIT=${REVIEW_EXIT:-0}

  # Separately fetch issue comments (Coding Agent posts here, not in `reviews`).
  COMMENTS_JSON=$(bash ~/.claude/skills/_gh/gh.sh api \
    "/repos/${OWNER}/${NAME}/issues/${PR}/comments" \
    --paginate 2>&1) || COMMENTS_EXIT=$?
  COMMENTS_EXIT=${COMMENTS_EXIT:-0}

  if [ "$REVIEW_EXIT" -ne 0 ] || grep -q '"errors"' <<<"$REVIEW_JSON"; then
    echo "  ❌ Failed to query review state (API error)"
    ERRORS=$((ERRORS + 1))
  elif [ "$COMMENTS_EXIT" -ne 0 ]; then
    echo "  ❌ Failed to query issue comments (API error)"
    ERRORS=$((ERRORS + 1))
  else
    LAST_PUSH=$(echo "$REVIEW_JSON" | jq -r '.data.repository.pullRequest.commits.nodes[0].commit.pushedDate // ""')

    # Count formal reviews from Copilot Code Review bot since last push.
    FORMAL_COPILOT_REVIEWS=$(echo "$REVIEW_JSON" | jq -r --arg push "$LAST_PUSH" '
      [.data.repository.pullRequest.reviews.nodes[]
       | select(.author.login == "copilot[bot]"
                or .author.login == "copilot-pull-request-reviewer[bot]"
                or .author.login == "github-actions[bot]")
       | select(.submittedAt >= $push)]
      | length')

    # Count Coding Agent issue comments (author "Copilot") since last push.
    # Exclude our own "@copilot review" mentions — match by author, not body.
    CODING_AGENT_COMMENTS=$(echo "$COMMENTS_JSON" | jq --arg push "$LAST_PUSH" '
      [.[] | select(.user.login == "Copilot" or .user.login == "copilot-swe-agent" or .user.login == "copilot-swe-agent[bot]")
           | select(.created_at >= $push)]
      | length')

    COPILOT_REVIEWED_AFTER_PUSH=$((FORMAL_COPILOT_REVIEWS + CODING_AGENT_COMMENTS))

    UNRESOLVED=$(echo "$REVIEW_JSON" | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length')

    if [ "${COPILOT_REVIEWED_AFTER_PUSH:-0}" -eq 0 ] && [ -n "$LAST_PUSH" ]; then
      echo "  ❌ Copilot has not reviewed since latest push (${LAST_PUSH})"
      echo "    Wait a few minutes for Copilot to finish, then re-run."
      echo "    (Checked both formal PullRequestReviews and Coding Agent issue comments.)"
      ERRORS=$((ERRORS + 1))
    elif ! [[ "$UNRESOLVED" =~ ^[0-9]+$ ]]; then
      echo "  ❌ Failed to parse unresolved thread count"
      ERRORS=$((ERRORS + 1))
    elif [ "$UNRESOLVED" -gt 0 ]; then
      echo "  ❌ ${UNRESOLVED} unresolved comment(s)"
      ERRORS=$((ERRORS + 1))
    else
      if [ "$FORMAL_COPILOT_REVIEWS" -gt 0 ]; then
        echo "  ✅ All comments resolved (Copilot Code Review)"
      else
        echo "  ✅ All comments resolved (Copilot Coding Agent)"
      fi
    fi
  fi
fi

# ── 3. Test plan items checked ───────────────────────────────────────────────

echo ""
echo "3. Test plan..."
BODY=$(bash ~/.claude/skills/_gh/gh.sh pr view "$PR" --repo "$REPO" --json body --jq '.body' 2>/dev/null || echo "")

if grep -q '^### Post-merge' <<<"$BODY"; then
  PRE_MERGE_SECTION=$(echo "$BODY" | sed -n '/### Pre-merge/,/### Post-merge/{/### Post-merge/d;p;}')
else
  PRE_MERGE_SECTION=$(echo "$BODY" | sed -n '/### Pre-merge/,$p')
fi
if [ -z "$PRE_MERGE_SECTION" ]; then
  PRE_MERGE_SECTION="$BODY"
fi

UNCHECKED=$(echo "$PRE_MERGE_SECTION" | grep -c '^\- \[ \]' || true)
if [ "$UNCHECKED" -gt 0 ]; then
  echo "  ❌ ${UNCHECKED} unchecked pre-merge item(s):"
  echo "$PRE_MERGE_SECTION" | grep '^\- \[ \]' | sed 's/^/     /'
  ERRORS=$((ERRORS + 1))
else
  echo "  ✅ All pre-merge items checked"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
if [ $ERRORS -gt 0 ]; then
  echo "❌ BLOCKED: ${ERRORS} check(s) failed — DO NOT MERGE"
  echo "=========================================="
  exit 1
else
  echo "✅ ALL CHECKS PASSED — safe to merge"
  echo "=========================================="
  exit 0
fi
