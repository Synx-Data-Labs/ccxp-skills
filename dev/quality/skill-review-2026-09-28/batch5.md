# Batch 5 review — Cloudflare family + general-purpose utilities

Scope: cloudflare, cloudflare-email-service, cloudflare-one, cloudflare-one-migrations, agents-sdk, durable-objects, sandbox-sdk, turnstile-spin, workers-best-practices, wrangler, web-perf, verify-site, help-net, md-to-pdf, proof-read, translate-patent.
Read-only review. Line refs are to `<skill>/SKILL.md` unless another file is named.

## Cross-cutting findings

1. **The Cloudflare family's descriptions overlap and have no routing rules between them.** `cloudflare` (L3) says "Use for any Cloudflare development task". Its description also names Workers, KV/D1/R2, Agents SDK and Tunnel, so it competes with every sibling. It also ships references that duplicate most of them:
   - `cloudflare/references/wrangler/` (954 lines)
   - `durable-objects/` (949)
   - `agents-sdk/` (832)
   - `sandbox/` (847)
   - `turnstile/` (1038)
   - `email-routing/` + `email-workers/` (1634)

   These are second copies of the dedicated skills, so the two copies will drift apart. Other overlapping trigger pairs:
   - `wrangler` and `workers-best-practices` both claim "configuring wrangler.jsonc" (wrangler L3, wbp L3). `durable-objects` claims "wrangler config" too (L3).
   - `durable-objects` and `agents-sdk` both claim WebSockets, chat apps and scheduled work.
   - `agents-sdk` also claims "durable workflows" and "browser automation", which overlaps `cloudflare/references/{workflows,browser-rendering}`.
   - `cloudflare-email-service` and `agents-sdk` (email) and `cloudflare/references/email-*` all cover email.
   - `cloudflare-one` covers Tunnel, as do `cloudflare/references/tunnel`, `cloudflare-one` "migration" (L12) and `cloudflare-one-migrations`.
   - `turnstile-spin` and `cloudflare/references/turnstile` both cover Turnstile.

   Only `workers-best-practices` (L114-120) and `turnstile-spin` (L30) have a "Scope / do not load for" section. Recommendation: add a one-line routing rule to every Cloudflare description, for example `cloudflare`: "…Use only when no more specific cloudflare-*/wrangler/durable-objects/agents-sdk/sandbox-sdk/turnstile-spin skill applies." Then drop the duplicated `cloudflare/references/*` dirs, or make them one-line pointers to the sibling skill.
2. **Over-broad triggers that fire outside Cloudflare.**
   - `sandbox-sdk` (L3) never says "Cloudflare". "CI/CD systems, interactive dev environments, executing untrusted code" matches Docker, E2B or GitHub Actions work.
   - `cloudflare-email-service` (L3): "integrating email into any app — Node.js, Python, Go… when a coding agent needs to send emails". This fires for SendGrid, SES or SMTP work.
   - `turnstile-spin` (L3, L25): "set up CAPTCHA, protect a form from bots". This fires for hCaptcha/reCAPTCHA work, and the skill then takes irreversible actions (widget creation via API).
3. **None of the 10 vendored skills follow skill-conventions §1/§2.**
   - No description starts with `Use when…`.
   - None has `argument-hint` or `disable-model-invocation`.
   - Two use a non-standard `references:` frontmatter key (cloudflare L4-9, turnstile-spin L4-10).

   Decide once: either exempt `vendored` skills explicitly in skill-conventions, or normalise them. Also record upstream provenance (commit SHA from cloudflare/skills) somewhere, so re-syncs are diffable.
4. **The "prefer retrieval over pre-training" boilerplate is repeated 2-3× per skill.** It appears in the description, again in body prose, and again in a "Retrieval Sources" table (for example cloudflare-email-service L8, L10, L12). One sentence plus the table is enough, which saves about 5-10 lines per skill.
5. **Script-path conventions are inconsistent.** The README convention (README.md L208-217) is `bash ../<name>/scripts/x.sh`. Deviations:
   - `turnstile-spin` uses bare `scripts/…` (L40, L68, L93, L95, L127).
   - `verify-site` uses `$(dirname "${BASH_SOURCE[0]}")/scripts/…` inside SKILL prose (L51, L112). `BASH_SOURCE` is empty in a tool shell, so this path is broken.
   - `translate-patent` uses `translate-patent/scripts/…` (L150-159, L187).

   All three break when the cwd is the consumer repo.
6. **Most scripts and prose have drifted apart when a script exists.** `verify-site` is the worst case (see its section). `help-net` is the exception: its probe keys match its SKILL.md exactly.
7. **The largest determinism gaps** are `md-to-pdf` (a fully mechanical pipeline written as prose), `proof-read` (it asks for "deterministic parsing" at L265 but ships no parser) and `help-net` (the classification tree A-H is pure rules).

---

## cloudflare

- Grades: concision B | trigger D | clarity B | determinism B | correctness B
- Est. cuttable/movable: 45%. The Product Index (L141-259) repeats every path already in the decision trees (L31-139). Keep one of them.
- Top recommendations:
  1. L3: narrow the description to act as a router and fallback: "Use when a Cloudflare task isn't covered by wrangler / workers-best-practices / durable-objects / agents-sdk / sandbox-sdk / turnstile-spin / cloudflare-email-service / cloudflare-one*". Then replace the duplicated `references/{wrangler,durable-objects,agents-sdk,sandbox,turnstile,email-routing,email-workers}` (about 6.2k lines) with pointers to the sibling skills. Otherwise two copies drift.
  2. L141-259: delete the Product Index tables (about 118 lines). The decision trees already map need → dir, and `ls references/` is the index.
  3. L4-9: the `references:` frontmatter key is non-standard and lists only 5 of 63 dirs. Remove it.
- Verified stale refs: none among dir refs (every `references/<x>/` exists; all 63 dirs are indexed). Staleness in the corpus: 23 reference snippets pin `"compatibility_date": "2025-01-01"`. 2.2 MB / 48k lines of vendored refs have no provenance SHA.
- Eval cases:
  - Trigger: "Run `wrangler d1 migrations apply` for my prod DB". The `wrangler` skill should fire, not `cloudflare`. Assert that the loaded skill name == wrangler.
  - "Which Cloudflare product should I use to run SQL analytics over Iceberg tables in R2?" Assert that the answer names R2 SQL and reads `references/r2-sql/`.

## cloudflare-email-service

- Grades: concision C | trigger C | clarity B | determinism B | correctness B
- Est. cuttable/movable: 30%
- Top recommendations:
  1. L8 and L10 are the same "prefer retrieval" sentence twice, and L12 is a third variant. Keep one.
  2. L95-103 "References" repeats the L35-43 routing table. The Common Mistakes rows at L91 (dup of L84), L92 (dup of L73) and L93 (dup of L74) repeat earlier content. Delete them, which is about 15 lines.
  3. L3: scope the trigger to Cloudflare. Drop "any app — Node.js, Python, Go" and "when a coding agent needs to send emails", and add "Not for SendGrid/SES/SMTP providers". Drop the "Even for simple requests… critical config details" puffery.
- Verified stale refs: none (all 5 references exist). The "launched in 2025" wording at L10 will age badly.
- Eval cases:
  - Trigger (negative): "Send a password-reset email from my Express app using SendGrid". This skill must NOT fire.
  - "Add email sending to my Worker". Assert that the output contains `"send_email": [{ "name": "EMAIL" }]` in wrangler.jsonc, uses `env.EMAIL.send` with both `html` and `text`, and uses `from.email` (not `address`).

## cloudflare-one

- Grades: concision C | trigger B | clarity C | determinism B | correctness C
- Est. cuttable/movable: 40%
- Top recommendations:
  1. Duplicate section headings split one topic in two places:
     - "Gateway, TLS, and DLP" at L48 and L116
     - "Cloudflare WAN / Site Connectivity" at L61 and L151
     - Tunnel/Private networking at L38 and L108
     - Identity at L28/L31 and L76

     Merge them into one section per product (assessment prompts plus guardrails). Move the Assessment Prompts (L18-63) and Validation Prompts (L163-170) to `references/assessment.md`.
  2. L12 lists "migration" as a category here. Route it explicitly: "Migrations from Zscaler/Palo Alto/VPN → use `cloudflare-one-migrations`". The description (L3) should also say "Not for Workers/developer-platform Tunnel exposure; use `cloudflare`".
  3. Fix the text and doc URLs:
     - L74 has garbled grammar ("disabled limited to a pilot").
     - L90 has a missing space (",or").
     - L136 is truncated mid-sentence ("epheme").
     - L139 short-lived-certs URL `/identity/users/short-lived-certificates/` conflicts with the newer path style at L136. L144/L148 `/analytics/logs/…` conflicts with `/insights/logs/…` at L145. Re-verify both sets of URLs; one of each pair is stale.
     - L140 "today" is undated.
     - L84 "Browser Rendering" (Access) collides with the Workers Browser Rendering product in `cloudflare`. Say "Access browser-rendered SSH/RDP".
- Verified stale refs: no local refs. Internal URL-path inconsistency at L139 vs L136 and L144/148 vs L145 (at least one of each pair is out of date).
- Eval cases:
  - "Users on WARP can't reach 10.2.0.5 behind our tunnel". Assert that the answer checks both split-tunnel include/exclude alignment and tunnel CIDR routes (L103), and asks for Gateway/Access logs first (L149).
  - Trigger: "Map our Zscaler ZPA app segments to Cloudflare". `cloudflare-one-migrations` should fire, not `cloudflare-one`.

## cloudflare-one-migrations

- Grades: concision B | trigger B | clarity B | determinism C | correctness C
- Est. cuttable/movable: 20%
- Top recommendations:
  1. L89 uses status labels (`unsupported`, `partial`, `unmapped`, `needs_identity`, `needs_posture`, `manual_review`) that are defined nowhere, which suggests a missing upstream parser. Either define the enum in the L95-110 template (for example a mapping-table column) or ship a `scripts/parse-zia-export.py` that emits it. The object-count parity gate (L88) and the source-rule accounting table (L93) are also mechanical, so a script would make them checkable.
  2. Two hard-coded "facts" have no retrieval hedge. L62 says split-tunnel excludes have "no API automation", but the Devices policy exclude endpoints exist, so this is likely wrong. L64 says "5 hostnames per app … up to 50". Wrap both in "retrieve current limits".
  3. The Gotchas at L80-84 restate the traps at L50/L73/L82. Merge them, and prefix the description with `Use when…`.
- Verified stale refs: none local. L62 is likely incorrect (split tunnel is API-configurable) and L64 has an unverified numeric limit.
- Eval cases:
  - Given a ZPA export with 2 connector groups (3 connectors each), assert that the plan proposes exactly 2 tunnels with 3 cloudflared replicas each (L59-60).
  - Assert that the output ends with a source-rule accounting table where every source rule has a row, either mapped or "Not Migrated" with a reason (L18, L93).

## agents-sdk

- Grades: concision C | trigger C | clarity B | determinism B | correctness C
- Est. cuttable/movable: 40%
- Top recommendations:
  1. L136 has a correctness bug. `routeAgentRequest(req, env) ?? new Response(...)`: `routeAgentRequest` is async and returns a Promise, so `??` never falls back. Fix it to `async fetch(req, env) { return (await routeAgentRequest(req, env)) ?? new Response("Not found", {status:404}) }`. Also L178 uses `useState` without importing it.
  2. Three lists cover the same topics. The Capabilities list (L50-71) duplicates the 34-row retrieval table (L14-48) and the References list (L195-229). Keep the References list plus a trimmed retrieval table, and move the full URL table to `references/docs-index.md`. That cuts about 55 lines.
  3. L3 "durable workflows, real-time WebSocket apps, scheduled tasks, browser automation" overlaps durable-objects and cloudflare workflows/browser-rendering. Scope it to "when the code uses the `agents` package / Agent, AIChatAgent or McpAgent classes".
- Verified stale refs: none (all 19 references exist). L136 is a code bug.
- Eval cases:
  - "Create a counter agent with a callable increment". Assert that the output awaits `routeAgentRequest`, uses a `new_sqlite_classes` migration, and does not set `experimentalDecorators`.
  - Trigger: "Build a multiplayer game room with WebSockets on Durable Objects (no Agents SDK)". `durable-objects` should fire, not agents-sdk.

## durable-objects

- Grades: concision B | trigger C | clarity A | determinism B | correctness B
- Est. cuttable/movable: 35%
- Top recommendations:
  1. L23-30 "When to Use" repeats the description. Stub creation, storage, alarms and testing (L130-185) repeat `references/rules.md` (L11, L228-255) and `references/testing.md`. Keep Critical Rules and Anti-Patterns plus one example and move the rest, which is about 60 lines.
  2. L12 is buried below a heading and duplicates the retrieval instruction. Merge L8 and L12.
  3. L3: add "Not for Agents SDK agents (use agents-sdk) or general Worker review (workers-best-practices)", because DO and Agents share the WebSocket/chat triggers.
- Verified stale refs: none (all 3 references exist).
- Eval cases:
  - "Review this DO: it calls `blockConcurrencyWhile` in fetch() and awaits between two `storage.put`s". Assert that both anti-patterns are flagged (L125, L127).
  - "Scaffold a DO for a booking system". Assert that the config uses `new_sqlite_classes`, the code uses `getByName`, there are RPC methods rather than a fetch handler, and it imports from `cloudflare:workers`.

## sandbox-sdk

- Grades: concision B | trigger D | clarity B | determinism B | correctness C
- Est. cuttable/movable: 30%
- Top recommendations:
  1. L3: the trigger never says Cloudflare. Rewrite it as "Use when building on Cloudflare's Sandbox SDK (`@cloudflare/sandbox`)…" so it doesn't fire for Docker, E2B or GitHub Actions "CI/CD" work.
  2. L132 `EXPOSE 8080  # Required…` is an invalid Dockerfile line. Docker only recognises `#` comments at line start, so the build fails with "invalid containerPort: #". Move the comment to its own line. L116/L121 pin `cloudflare/sandbox:0.7.0`, which must match the installed npm version. Say "use the tag matching `npm ls @cloudflare/sandbox`" instead of hard-coding it.
  3. The Quick Reference (L56-68) and Core Patterns (L70-103) duplicate each other and `references/api-quick-ref.md`. Keep one. L158 `examples/openai-agents` is an upstream-GitHub path; give the full URL.
- Verified stale refs: L158 `examples/openai-agents` does not exist locally (it's upstream). L116/L121 image tag 0.7.0 is likely stale.
- Eval cases:
  - Trigger (negative): "Set up a GitHub Actions CI pipeline that runs tests in Docker". sandbox-sdk must NOT fire.
  - "Add a Python code interpreter to my Worker". Assert that the Worker has `export { Sandbox } from '@cloudflare/sandbox'`, the containers + DO + migration config matches L34-46, and it uses `runCode` with `createCodeContext`.

## turnstile-spin

- Grades: concision C | trigger C | clarity B | determinism A | correctness C
- Est. cuttable/movable: 30%
- Top recommendations:
  1. The per-framework snippet files are never linked. SKILL.md body references none of `references/{vanilla-html,nextjs-app,nextjs-pages,astro,sveltekit,hugo}.md` (grep = 0). They appear only in the non-standard `references:` frontmatter (L4-10). In Step 9 (L70), add: "Read `references/<framework>.md` for the detected framework."
  2. Step 11 (L95) runs `persist-skill.sh`, which does `npx degit cloudflare/skills/...` (unpinned upstream fetch) into the user's repo. In this suite the skill is already installed, so this step is redundant, writes into the consumer repo, and bypasses the vendored copy. Remove it, or gate it behind "only if not loaded from an installed plugin". Also anchor every `scripts/…` call (L40, L68, L93, L127) as `bash ../turnstile-spin/scripts/…` per the README convention.
  3. Trim no-op steps: L38 "CLI check" does nothing and L50 "Account selection" only restates Step 3. Tighten the trigger (L3, L25): "CAPTCHA" / "bot protection" alone shouldn't fire an API-creating wizard. Require Turnstile or Cloudflare to be mentioned, or an explicit setup ask.
- Verified stale refs: `README.md` L50 links `SKILL.md#step-11--persist-the-skill`, and that anchor doesn't exist (no such heading). L38 claims "Wrangler 4.109+" for `turnstile widget`; unverified and version-specific.
- Eval cases:
  - Trigger (negative): "Add hCaptcha to my signup form". turnstile-spin must NOT fire (or must ask before creating a widget).
  - Recovery flow: "I have sitekey 0x4AAA… but siteverify never worked". Assert that no `widget-create` call is made and that `fetch-secret.sh` runs (L126-134).

## workers-best-practices

- Grades: concision B | trigger C | clarity A | determinism B | correctness B
- Est. cuttable/movable: 30%
- Top recommendations:
  1. The Rules Quick Reference (L36-82) and Anti-Patterns (L84-101) state the same rules twice: streaming, secrets, Math.random, floating promises, global state, REST-from-Worker, passThroughOnException, hand-written Env. Keep only the anti-pattern table, since it is what a review checks, which removes about 45 lines.
  2. L3: drop "configuring wrangler.jsonc", which competes with `wrangler`. Keep it to "writing/reviewing Worker code". The Scope section (L114-120) is good; mirror it in the description.
  3. L23-29 has a hard-coded `/tmp/workers-types-latest` npm-pack snippet. Move it to `scripts/fetch-types.sh`, shared with `cloudflare` (which recommends the same thing at L25). Reconcile the compatibility_date guidance: "today" / "periodically" here (L42) vs wrangler's "within 30 days" (L39) vs "quarterly" (L919).
- Verified stale refs: none (both references exist). Missing H1 title (starts at L6).
- Eval cases:
  - Review of a Worker containing `const { waitUntil } = ctx;` and `Math.random()` for a session token. Assert that both are flagged with the L97 and L90 rationales.
  - Trigger: "What's the wrangler command to tail logs for my worker?" `wrangler` should fire, not workers-best-practices.

## wrangler

- Grades: concision D | trigger B | clarity B | determinism B | correctness C
- Est. cuttable/movable: 75%. 923 lines; keep about 200.
- Top recommendations:
  1. Progressive disclosure. Keep L1-67 (retrieval, install, key guidelines, core-command table) plus a product index. Move each product block to `references/<product>.md`:
     - KV (L282-330)
     - R2 (L331-376)
     - D1 (L377-453)
     - Vectorize (L454-496)
     - Hyperdrive (L497-540)
     - AI (L541-564)
     - Queues (L565-606)
     - Containers (L607-666)
     - Workflows (L667-716)
     - Pipelines (L717-749)
     - Secrets Store (L750-796)
     - Pages (L797-814)

     `cloudflare/references/wrangler/` (954 lines) already exists and duplicates this. Consolidate into one location.
  2. Correctness (Wrangler v4 behavior):
     - `wrangler kv key …` (L301-316) and `wrangler r2 object …` (L356-362) default to LOCAL storage in v4. Without `--remote` they silently write to the local simulator. Add `--remote`.
     - L723/L732 `pipelines create --r2` / `--batch-max-mb` is legacy Pipelines syntax (Pipelines was redesigned around streams and sinks). Re-verify.
     - L49 `wrangler init` is superseded by `create-cloudflare`.
     - L907-908 `wrangler docs configuration` is labelled "View config schema" but only opens the docs.
     - L79 has a hard-coded `2026-01-01` compatibility date.
  3. Remove the internal duplication:
     - L873-881 duplicates L186-188 (test-scheduled).
     - The Best Practices list (L913-923) repeats L36-43 and L209.
     - L39 "within 30 days" contradicts L919 "quarterly".
- Verified stale refs: none local (no links). Stale/likely-wrong API facts at L301-316 and L356-362 (missing `--remote`), L723-735, L49 and L907.
- Eval cases:
  - "Put key foo=bar into my production KV namespace". Assert that the command includes `--remote`.
  - Trigger: "Deploy my worker to staging". wrangler fires and the output contains `wrangler deploy --env staging`.

## web-perf

- Grades: concision B | trigger B | clarity B | determinism B | correctness C
- Est. cuttable/movable: 30%
- Top recommendations:
  1. L24-28: the MCP config snippet uses OpenCode's format (`"type":"local","command":[…]`), which is wrong for Claude Code. Replace it with `claude mcp add chrome-devtools -- npx -y chrome-devtools-mcp@latest`, or `{"command":"npx","args":["-y","chrome-devtools-mcp@latest"]}`. Refer to tools by their `mcp__chrome-devtools__*` names.
  2. The Quick Reference table (L40-49) repeats the Phase 1-4 calls (L64-146). Delete one. Move Phase 5 codebase analysis (L155-201) to `references/codebase.md`, since it's skipped for third-party sites. The L155 heading level (`##`) is inconsistent with Phases 1-4 (`###`).
  3. Staleness: L188 "Tailwind's `content` config" (Tailwind v4 removed `content` and auto-detects sources). L107-115 thresholds are hard-coded despite L8's "retrieve" instruction; keep one source. Add `Use when` to the description and state its boundary with `verify-site`, which also runs Lighthouse.
- Verified stale refs: none local. L24-28 is the wrong config format for Claude Code; L188 is stale.
- Eval cases:
  - Without the chrome-devtools MCP configured, "audit example.com performance". Assert that the skill stops and prints the Claude-Code MCP setup (L20).
  - Assert that the output has the L207-210 four-part structure, and that the CWV table has a rating column with good/needs-improvement/poor.

## verify-site

- Grades: concision C | trigger A | clarity C | determinism B | correctness D
- Est. cuttable/movable: 50%. Most of the workflow can be replaced by "run `verify.sh <PR>`, then report".
- Top recommendations:
  1. SKILL.md and scripts disagree. `scripts/verify.sh` already orchestrates steps 3-8, and SKILL.md only mentions it in passing at L169. Replace L28-113 with: resolve PR → `bash ../verify-site/scripts/verify.sh "$PR"` → relay `/tmp/verify-site-report.md`. Then fix the drift:
     - L77 references `check-links.sh`, which **does not exist**, so the Links check is fiction.
     - L71 says results go to `.json`; verify.sh writes `.ndjson`.
     - L82 says scripts take `ROUTES` env; they read stdin.
     - L22 says deps come via `npx`; `ensure-deps.sh` uses skill-local node_modules.
     - L63-64 sitemap logic ignores nested sitemaps, which verify.sh handles.
  2. The `.verify-site.json` schema (L128-153) is mostly unimplemented. Only `preview.{build,start,url}` is read (`preview-up.sh` L29-32). `routes`, `lighthouse.enabled/thresholds/sample_routes`, `a11y.enabled` and `responsive.*` are ignored. The documented defaults (85/90/95/95) also differ from `check-lighthouse.sh` L9-12 (80/90/90/90). Either implement the keys or cut them from the doc. The verify.sh sampling of `/blog/` and `/product/` is site-specific leakage.
  3. L51 and L112 use `$(dirname "${BASH_SOURCE[0]}")` in SKILL prose. It is empty in a tool shell, so use `../verify-site/scripts/`. L35/L43/L104 use `../_gh/gh.sh` (OK per convention). Add BATS tests for `match-testplan.sh` (pure function: body + ndjson → ticked body), per conventions §5/§9.
- Verified stale refs: `scripts/check-links.sh` (L77) is MISSING. The `verify.sh` trap exists (L169 OK). The `.verify-site.json` keys `routes`, `lighthouse.*`, `a11y`, `responsive` are unimplemented.
- Eval cases:
  - Fixture PR body with `- [ ] npm run build passes`, `- [ ] copy review`, and ndjson with all routes `pass`. Running `match-testplan.sh` must tick exactly 1 item and print `1`.
  - Trigger: "Is the Lighthouse score on my PR's preview ok?" verify-site fires only if the user explicitly asks to verify the PR. For a generic perf audit of a live URL, web-perf fires.

## help-net

- Grades: concision C | trigger A | clarity B | determinism C | correctness C
- Est. cuttable/movable: 35%
- Top recommendations:
  1. The AT&T/Nomad facts appear twice. Pre-trip L112-123 is repeated at L182-191, and "disable macOS auto-updates" appears 4× (L119, L144, L187, L189). Keep one dated "carrier notes" block and move it to `references/carriers.md` with an "as of" date. L127 "Lesson from 2026-04 trip… $200 spent" is personal journal content; cut it.
  2. The classification tree (L38-78) is pure threshold rules over probe keys, so make it `scripts/classify.sh`, which reads the probe output and emits the class plus the matched evidence keys. Test it with BATS fixtures, and keep only the report-writing in prose. (Probe keys were verified to match `probe.sh` exactly.)
  3. L204: the Low Data Mode fix is wrong. "Maximize Compatibility" switches the hotspot to 2.4 GHz and does not disable Low Data Mode. The real toggle is iPhone Settings → Cellular → Cellular Data Options → Data Mode (or the Wi-Fi network's Low Data Mode). L10-12 "company VPN-gated resource" is outside the travel trigger (L3), which excludes routine office network issues. Move it to the Reference section or drop it. L228 "Safari is more loss-tolerant" is unsupported.
- Verified stale refs: none (`scripts/probe.sh` exists; all keys match). Time-sensitive prices and plans at L112-123 and L182-191.
- Eval cases:
  - Classifier fixture: `primary.is_tether: true`, `exit.country: US`, `http.google_com.size: 20000`, `total_s: 12`, `ping loss 15%`. Assert class B, and that the "Won't help" section mentions VPN.
  - Trigger (negative): "My home Wi-Fi is slow". help-net must NOT fire.

## md-to-pdf

- Grades: concision C | trigger C | clarity B | determinism D | correctness C
- Est. cuttable/movable: 65%. The CSS (L94-172) and Python snippets should move into files.
- Top recommendations:
  1. The whole workflow is mechanical: preprocess, pandoc, HTML post-process, weasyprint, and the pdffonts check. Ship `scripts/md-to-pdf.sh` (or `.py`) plus `default.css` (the current L94-172), and have `translate-patent` call the script directly. SKILL.md then shrinks to args plus "run the script; if the pdffonts check fails, add the char to the wrap list". Add a BATS test on a CJK+↔ fixture, asserting no `.LastResort` and that the primary font is Latin.
  2. L60 and L89 embed literal invisible U+FE0E/U+FE0F characters in `replace('︎','')`. They are invisible, easily lost by editors, and the model cannot see them reliably. Use `'︎'` / `'️'` escapes.
  3. Correctness and internal refs:
     - L42 "replace curly quotes with straight" destroys Chinese “” quotes. Limit it to Latin contexts or drop it.
     - L64 says sizing is "handled by CSS in step 3"; it is step 4.
     - Step 6 "clean up" (L186) runs before the REQUIRED step 7 check (L192). Reorder.
     - The description (L3) lacks `Use when`.
- Verified stale refs: internal step ref L64 ("step 3" should be step 4). Invisible literal chars at L60 and L89.
- Eval cases:
  - Convert a fixture `.md` containing "A ↔ B" and CJK text. Assert that `pdffonts out.pdf` has no `.LastResort` and that the first font is Helvetica/Arial.
  - Run with `--img-width 40`. Assert that the intermediate HTML contains `max-width: 40%`.

## proof-read

- Grades: concision C | trigger B | clarity B | determinism D | correctness C
- Est. cuttable/movable: 40%
- Top recommendations:
  1. L265 asks for "deterministic parsing… stable output across runs", but everything is prose re-executed by the LLM. Port the mechanical checks to `scripts/proofread.py`, keep the judgment checks (3a synonyms, 3d, 3e) in prose, and add BATS parity fixtures (convention §9). The mechanical checks are:
     - section tree
     - sentence split
     - figure-label extraction
     - reference multiset diff (4f)
     - numeric parity (4c)
     - sentence-count parity (4b)
     - broken refs (3c)
     - wall-of-text counter (3g)
  2. L143-183 (4f) is 40 lines of design rationale and history ("T20260804-151091…", "Known limitation" essay). Keep the 5-line rule and move the rationale to the journal entry. L253 promises exit codes `0`/`1`, which a prose skill cannot return. Either implement them via the script or replace them with "report `errors: N` on the final line".
  3. Stale and leaked references:
     - L97 cites `private-skills-repo/engineering-standards.md` "Markdown writing style". The file is at the repo root as `engineering-standards.md`, and that section **does not exist** (grep = 0).
     - L260 "defrag patent pipeline v1" is company-specific leakage.
     - L264 "do not shell out with cat" conflicts with the scripting direction.
- Verified stale refs: L97 `private-skills-repo/engineering-standards.md` § "Markdown writing style" is MISSING (neither path nor section). `../glossary.md` (L17) exists.
- Eval cases:
  - Mode B fixture: CN `见图2-图5` vs EN "see Figs. 1-4" in the same section. Assert exactly one Error "figure-reference number mismatch" citing both lines.
  - Mode A fixture: a figure with label `205` never mentioned in prose. Assert a finding for the unmentioned label at `file:line`, and that the input file is unchanged (checksum).

## translate-patent

- Grades: concision B | trigger A | clarity B | determinism B | correctness B
- Est. cuttable/movable: 20%
- Top recommendations:
  1. Paths: `translate-patent/scripts/postprocess.py` (L150-159) and `translate-patent/patent-pdf-extra.css` (L187, L193) resolve only from the skills root. Use `../translate-patent/…` per the README convention, or they break in a consumer repo cwd.
  2. Steps 2-3 (L36-60: pandoc extract, media flatten, strip `{width=…}`, strip Windows paths) are mechanical. Fold them into `scripts/extract.sh`, or add an `extract` mode to postprocess.py, which already has BATS coverage (`tests/translate_patent_postprocess.bats`). L10 `--target-lang` accepts only `en` in practice; drop it, or say "only en supported".
  3. L17 and L34 spend a lot of text on `--en-only` semantics. Replace them with a small flag × step matrix (steps 5-10 × {default, --cn-only, --en-only, --no-proofread, --no-pdf}), which removes the repeated "unless --X" clauses at L135, L156, L176-177 and L184-190.
- Verified stale refs: none missing (`scripts/postprocess.py` and `patent-pdf-extra.css` exist; `/proof-read` and `/md-to-pdf` exist). The path style is non-conventional (see rec 1).
- Eval cases:
  - Run with `--cn-only --no-pdf` on a fixture DOCX. Assert that no `en/` dir is created, a CN proof-read report exists, and there are no PDFs.
  - After step 8, re-running `postprocess.py --in-place` on the output yields a byte-identical file (idempotence claim, L170).
