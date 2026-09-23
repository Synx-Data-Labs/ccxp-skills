#!/usr/bin/env bash
# mode.sh <solo|team> [--repo OWNER/NAME] [--doc PATH] [--skip-ci-check] [--yes]
#
# Switches a repo between "solo" (direct-to-main, no CI) and "team"
# (feature-branch + PR + CI required) branch policy: rewrites the target
# repo's `## Branch and Merge Policy` section to the canonical wording for
# that mode, and applies the matching GitHub branch-protection state on
# `main` (DELETE for solo, PUT for team).
#
# The GitHub API call runs BEFORE the doc rewrite, deliberately: live branch
# protection is the harder side to recover from, so a failed API call must
# never leave the doc claiming a mode reality doesn't match (T20260915-315552).
#
# `claim/SKILL.md` and `drive/SKILL.md`'s existing solo-repo detection reads
# the rewritten doc with a `grep -qi "no ci"` + `grep -qi "direct.to.main"`
# heuristic — the canonical solo wording below is written to satisfy both,
# verified against the literal patterns (not just eyeballed).
set -uo pipefail

GH_SH="${GH_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../_gh" && pwd)/gh.sh}"

usage() {
  echo "usage: mode.sh <solo|team> [--repo OWNER/NAME] [--doc PATH] [--skip-ci-check] [--yes]" >&2
}

MODE="${1:-}"
case "$MODE" in
  solo|team) ;;
  *) usage; exit 64 ;;
esac
shift

REPO=""
DOC=""
SKIP_CI_CHECK=0
YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:?--repo requires a value}"; shift 2 ;;
    --doc) DOC="${2:?--doc requires a value}"; shift 2 ;;
    --skip-ci-check) SKIP_CI_CHECK=1; shift ;;
    --yes) YES=1; shift ;;
    *) echo "mode.sh: unknown argument: $1" >&2; usage; exit 64 ;;
  esac
done

# --- resolve the target doc ---------------------------------------------------
if [ -z "$DOC" ]; then
  if [ -f "dev/guidelines.md" ] && grep -q '^## Branch and Merge Policy$' "dev/guidelines.md"; then
    DOC="dev/guidelines.md"
  elif [ -f "CLAUDE.md" ] && grep -q '^## Branch and Merge Policy$' "CLAUDE.md"; then
    DOC="CLAUDE.md"
  else
    echo "mode.sh: no '## Branch and Merge Policy' section found in dev/guidelines.md or CLAUDE.md — run /repo-conventions sync first" >&2
    exit 1
  fi
elif ! grep -q '^## Branch and Merge Policy$' "$DOC"; then
  echo "mode.sh: $DOC has no '## Branch and Merge Policy' section" >&2
  exit 1
fi

# --- detect current mode (same heuristic claim/SKILL.md already uses) --------
if grep -qi "no ci" "$DOC" && grep -qi "direct.to.main" "$DOC"; then
  CURRENT=solo
else
  CURRENT=team
fi

if [ "$CURRENT" = "$MODE" ]; then
  echo "mode.sh: already in $MODE mode ($DOC unchanged)"
  exit 0
fi

# --- resolve repo slug ---------------------------------------------------------
if [ -z "$REPO" ]; then
  REPO="$(bash "$GH_SH" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)"
fi
if [ -z "$REPO" ]; then
  echo "mode.sh: could not determine repo. Pass --repo OWNER/NAME or run from inside a gh-recognized repo." >&2
  exit 1
fi

# --- team: verify CI is plausibly configured before enabling protection -----
if [ "$MODE" = team ] && [ "$SKIP_CI_CHECK" -ne 1 ]; then
  if ! ls .github/workflows/*.yml >/dev/null 2>&1 && ! ls .github/workflows/*.yaml >/dev/null 2>&1; then
    echo "mode.sh: team mode assumes CI is configured — no .github/workflows/*.yml found. Add CI first, or pass --skip-ci-check if CI lives elsewhere." >&2
    exit 1
  fi
fi

# --- confirmation before mutating live repo security settings ---------------
if [ "$YES" -ne 1 ]; then
  if [ -t 0 ]; then
    read -r -p "This will call GitHub's branch-protection API ($([ "$MODE" = team ] && echo enable || echo disable) protection on $REPO's main). Continue? [y/N] " ans
    case "$ans" in
      y|Y|yes|YES) ;;
      *) echo "mode.sh: aborted." >&2; exit 1 ;;
    esac
  else
    echo "mode.sh: refusing to mutate branch protection without --yes (non-interactive)." >&2
    exit 1
  fi
fi

# --- API call FIRST; doc rewrite only after it succeeds ----------------------
if [ "$MODE" = team ]; then
  # contexts: [] deliberately names no specific required check (see the
  # task's design Alternatives rejected) — job names drift across a repo's
  # CI evolution and a stale contexts list would silently block merges once
  # a job is renamed. This means the branch-protection API call enforces
  # "no direct push" but NOT "CI must pass" as a hard GitHub-side gate; the
  # latter is enforced procedurally by this suite's own /address-pr loop,
  # not by branch protection. A repo wanting GitHub-side named-check
  # enforcement can add `contexts` itself via the GitHub UI/API afterward.
  BODY='{
  "required_status_checks": {"strict": true, "contexts": []},
  "enforce_admins": false,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "restrictions": null
}'
  if ! OUT=$(printf '%s' "$BODY" | bash "$GH_SH" api -X PUT "repos/$REPO/branches/main/protection" --input - 2>&1); then
    echo "mode.sh: failed to enable branch protection on $REPO: $OUT" >&2
    exit 1
  fi
else
  if ! OUT=$(bash "$GH_SH" api -X DELETE "repos/$REPO/branches/main/protection" 2>&1); then
    if ! echo "$OUT" | grep -qiE "404|not found|not protected"; then
      echo "mode.sh: failed to disable branch protection on $REPO: $OUT" >&2
      exit 1
    fi
    # 404 == already unprotected — treat as success
  fi
fi

# --- rewrite the Branch and Merge Policy section -----------------------------
# The API call above already succeeded (live GitHub state has been mutated),
# so a failure HERE must not be silently swallowed — set -uo pipefail alone
# doesn't catch it (no -e, and the script's last statement is an unconditional
# echo), which would otherwise exit 0 while leaving $DOC and reality out of
# sync, exactly the drift state the API-first ordering exists to prevent.
if ! DOC="$DOC" MODE="$MODE" python3 - <<'PY'
import os

doc = os.environ["DOC"]
mode = os.environ["MODE"]

TEAM_BLOCK = """## Branch and Merge Policy

The `main` branch is the source of truth. Never push directly to `main`.

1. **Create a feature branch** — all changes go through a feature branch, no exceptions
2. **Branch naming**: `t{task-id}-short-description` for tracked tasks; `fix/`, `feat/`, `docs/` prefixes for untracked work
3. **Open a PR** — clear summary and test plan
4. **CI must pass** — all checks green before merge
5. **Merge method** — rebase and merge, via the ccxp-skills `_gh/gh.sh` wrapper (`pr merge --rebase --delete-branch`) — resolve its path relative to wherever the ccxp-skills plugin is installed, not a hardcoded location
6. **Delete the branch after merge**
"""

SOLO_BLOCK = """## Branch and Merge Policy

This is a solo repo with no CI — direct-to-main, no feature-branch PRs required.

1. **Push directly to `main`** — no feature branch or PR required
2. **Branch naming** (optional, for WIP): `t{task-id}-short-description` for tracked tasks; `fix/`, `feat/`, `docs/` prefixes for untracked work
3. **No CI gate** — there is no automated pipeline to wait on before landing a change
4. **Merge method** — not applicable; commits land directly on `main`
"""

block = TEAM_BLOCK if mode == "team" else SOLO_BLOCK

with open(doc) as f:
    lines = f.read().split("\n")

start = next(i for i, l in enumerate(lines) if l.strip() == "## Branch and Merge Policy")

end = len(lines)
for i in range(start + 1, len(lines)):
    if lines[i].startswith("## "):
        end = i
        break

new_lines = lines[:start] + block.rstrip("\n").split("\n") + [""] + lines[end:]

with open(doc, "w") as f:
    f.write("\n".join(new_lines))
PY
then
  echo "mode.sh: FATAL — GitHub's branch protection on $REPO was already $([ "$MODE" = team ] && echo enabled || echo disabled), but rewriting $DOC failed. $DOC and live protection are now OUT OF SYNC — fix $DOC by hand or re-run mode.sh." >&2
  exit 1
fi

echo "mode.sh: switched $DOC to $MODE mode ($REPO's main protection $([ "$MODE" = team ] && echo enabled || echo disabled))"
