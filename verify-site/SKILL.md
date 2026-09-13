---
name: verify-site
description: Use when the user explicitly asks to verify a site PR — local preview, run the test plan's automated checks, tick boxes
disable-model-invocation: false
argument-hint: "[PR number]"
---

Start a local preview server, run automated checks against every route the PR touches, and tick test-plan items the automation can definitively verify. Items that need human judgement (visual hierarchy, copy review, "does this feel right") are left untouched and reported.

## Argument

`<arg>` is optional:

- `/verify-site 11` — verify a specific PR
- `/verify-site` — use the current branch's open PR

## Prerequisites

Consumer repo must have:

- A build + preview workflow — auto-detected for Astro, Next, Vite (`npm run build` + `npm run preview` on localhost). Override with `.verify-site.json` (see Config below).
- `npx` on PATH — the skill installs Lighthouse and Playwright on demand via `npx`.

The first run downloads Chromium for Playwright (~200 MB) and Lighthouse. Subsequent runs are fast.

## Workflow

### 1. Resolve PR

- If `<arg>` is numeric, use it directly
- If empty, discover from the current branch:

  ```bash
  BRANCH=$(git branch --show-current)
  bash ~/.claude/skills/_gh/gh.sh pr list --head "$BRANCH" --state open --json number --jq '.[0].number'
  ```

- If no PR is found, stop and report.

### 2. Read the test plan from the PR body

```bash
bash ~/.claude/skills/_gh/gh.sh pr view "$PR" --json body --jq '.body' > /tmp/pr-body.md
```

The skill expects a `## Test plan` section with `- [ ]` / `- [x]` items. Only unchecked items are candidates for auto-ticking.

### 3. Build + start preview

```bash
bash "$(dirname "${BASH_SOURCE[0]}")/scripts/preview-up.sh"
```

This resolves the preview command + URL, runs the build, starts the server in the background, writes the PID + URL to `/tmp/verify-site.env`, and waits for the server to answer 200 on `/` (up to 60s).

On error (build fails, port in use, server never answers): stop, clean up, report.

### 4. Discover routes

Prefer the sitemap:

```bash
curl -sf "$URL/sitemap-index.xml" | grep -oE '<loc>[^<]+' | sed 's#<loc>##' \
  || curl -sf "$URL/sitemap.xml"  | grep -oE '<loc>[^<]+' | sed 's#<loc>##'
```

If no sitemap, fall back to the list in `.verify-site.json` routes field, or crawl one hop from `/`.

### 5. Run checks

Each script is independent and writes results to `/tmp/verify-site-results.json` (an array of `{check, route, status, detail}` objects). The orchestrator merges them.

| Check | Script | What it verifies |
|------|--------|------------------|
| Build | (already done in step 3) | `npm run build` exits 0 |
| Routes | `check-routes.sh` | Every discovered route returns HTTP 200, no JS errors in the response HTML |
| Links | `check-links.sh` | No broken internal links, all images have `alt`, heading order not skipped |
| Lighthouse | `check-lighthouse.sh` | Runs Lighthouse mobile profile on each route; parses Performance, Accessibility, Best Practices, SEO scores |
| A11y | `check-a11y.sh` | Playwright + `@axe-core/playwright` against each route; reports violations |
| Responsive | `check-responsive.sh` | Playwright at 375 / 768 / 1280 — no horizontal overflow (`scrollWidth > clientWidth`); optional screenshots to `/tmp/verify-site-screens/` |

Each script accepts a space-separated list of routes via `ROUTES` env var and the base URL via `URL`.

### 6. Match results to test-plan items

Run `scripts/match-testplan.sh /tmp/pr-body.md /tmp/verify-site-results.json`. It applies a heuristic keyword match:

| Test plan phrase contains… | Match against |
|---|---|
| `npm run build`, "build green", "compiles" | Build result |
| "renders", "loads", "200", "no 500", "route" | Route check |
| "no broken links", "alt text", "heading order" | Links check |
| "Lighthouse", "Performance", "Perf ≥", "A11y ≥" | Lighthouse scores |
| "accessibility", "axe", "a11y", "aria", "focus" | A11y audit |
| "mobile", "375px", "responsive", "no horizontal overflow", "stacks" | Responsive check |

An item ticks green only if the associated check passed with zero failures across all routes. If any route fails, the item stays unchecked and the failure is listed in the report.

### 7. Update PR body

For every auto-tickable item that passed, rewrite `- [ ]` → `- [x]`:

```bash
bash ~/.claude/skills/_gh/gh.sh pr edit "$PR" --body-file /tmp/pr-body-updated.md
```

Do NOT change items the automation couldn't match or that failed — those stay `- [ ]` and are listed in the report so the human reviewer can decide.

### 8. Tear down + report

```bash
bash "$(dirname "${BASH_SOURCE[0]}")/scripts/preview-down.sh"
```

Report to the user:

- PR + URL
- Preview base URL (for manual follow-up)
- **Checks run**: routes, lighthouse, a11y, responsive — with per-route pass/fail counts and any standout numbers (lowest Lighthouse score, a11y violation count)
- **Test plan items auto-ticked**: N of M
- **Test plan items still human-only**: list them — these are typically "copy review", "does X feel right", "click through each page"
- **New findings** (checks that aren't in the test plan but uncovered regressions): broken links, a11y violations, Lighthouse regression vs last run (if available)

## Config

Optional `.verify-site.json` at repo root overrides auto-detection:

```json
{
  "preview": {
    "build": "npm run build",
    "start": "npm run preview -- --host",
    "url": "http://localhost:4321",
    "ready_path": "/"
  },
  "routes": ["/", "/blog/", "/product/acme-cloud"],
  "lighthouse": {
    "enabled": true,
    "thresholds": {
      "performance": 85,
      "accessibility": 90,
      "best-practices": 95,
      "seo": 95
    },
    "sample_routes": ["/", "/blog/", "/product/acme-cloud"]
  },
  "a11y": { "enabled": true },
  "responsive": {
    "enabled": true,
    "widths": [375, 768, 1280]
  }
}
```

If absent, defaults are:

- Astro detected by `astro.config.*` → preview is `npm run preview`, URL `http://localhost:4321`
- Next detected by `next.config.*` → `npm run start`, URL `http://localhost:3000`
- Vite detected by `vite.config.*` → `npm run preview`, URL `http://localhost:4173`
- Routes discovered from `sitemap-index.xml` → `sitemap.xml` → `/`
- Lighthouse samples at most 3 routes (hero + blog index + one product page) to stay under a minute of audit time
- Responsive runs at `[375, 768, 1280]`
- A11y runs on every discovered route

## Important Notes

- **Never amend the PR author's intent.** Only flip `- [ ]` → `- [x]` when the check passed clean. Never unflip an already-ticked item. Never add or remove items.
- **Concurrency.** The preview server is one process; run checks against it sequentially to keep logs deterministic. Lighthouse in particular is noisy if you run it concurrently.
- **Teardown is unconditional.** Always stop the preview server, even on check failures, via `trap` in `verify.sh`. Leaving a stuck server on the port breaks the next run.
- **Network-bound assets (e.g. Google Fonts, external images) depress Lighthouse Performance.** Report the score but don't fail the test plan on Perf unless the PR explicitly sets a threshold.
- **One PR = one run.** If the PR pushes a new commit mid-run, the results are stale. Note the HEAD SHA in the report; re-run after a new push.
- **Tick fidelity over coverage.** When in doubt, leave a box unticked. A false green is worse than a human having to tick three extra boxes.
