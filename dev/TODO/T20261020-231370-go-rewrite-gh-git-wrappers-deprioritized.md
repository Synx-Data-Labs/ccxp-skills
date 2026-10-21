---
status: In Progress
estimation: 3
source: Follow-up from T20261020-242723 investigation, 2026-10-20; maintainer raised priority 2026-10-20 (filename suffix `deprioritized` is historical)
related: T20261020-242723, T20261012-280694
claimed_by: cc1-50ac6891:2405baa3ca5b7100
claimed_role: interactive
scheduled: 2026-10-19
---

# T20261020-231370: Rewrite `_gh/gh.sh` / `_gh/git.sh` as a compiled Go binary (staged, opt-in)

## TLDR

- **Type**: feature
- **Problem**: account detection in `_gh/gh.sh` depends on text parsing and external tools that differ per machine (gawk regex bug, `LC_ALL=C` bug).
- **Solution**: one stdlib-only Go binary `ccxp-gh` (modes `gh`, `git`) that reads accounts from `gh auth status --json hosts`; shipped additively behind an opt-in switch in the existing wrappers.
- **Open decision (NEEDS INPUT)**: how the binary is distributed (options below) - stage 1 deliberately avoids choosing.

## Problem

- Original motivation (kernel leak from nested shebangs) does not hold: T20261020-242723 showed every caller already uses `bash <path>`.
- Remaining motivation is real and *verified*: `_gh_list_accounts` (`_gh/gh.sh:61-87`) parses human-readable `gh auth status` text; the file's own comment records the two bugs this caused:
  - mis-linked gawk silently never matching a regex (already worked around by pure-bash `case` matching, `_gh/gh.sh:80-85`);
  - an `LC_ALL=C` locale bug in the same text path.
- Structured output exists and is verified on this machine (gh 2.101.0): `gh auth status --json hosts --jq '.hosts["github.com"]|map({login,active,state})'` returns `[{"active":true,"login":"..."},{"active":false,"login":"..."}]`.
- Stays low-urgency: no active incident, so the rollout must be zero-risk to the existing call sites (`grep -rhoE '_gh/(gh|git)\.sh'` finds ~375 references repo-wide incl. docs/tests).

## Context

- Behavior to preserve (verified by reading `_gh/gh.sh` / `_gh/git.sh`):
  - repo slug from `origin` (any host alias, `.git` stripped) - `_gh_repo_slug`;
  - per-account tier probe: `gh api repos/<slug> --jq .permissions.push` with `GH_TOKEN` per account -> write / read / none;
  - prefer a write-capable account, settle for read-only, else die `no authenticated gh account has access to <slug> (try: gh auth login)`;
  - tab-separated `slug<TAB>user` cache at `${TMPDIR:-/tmp}/.gh-account-cache-${USER:-anon}`, self-heal on permission-shaped stderr (retry once, `_gh_permission_error`);
  - `git` mode additionally wires repo-local `credential.helper` + `url.insteadOf`, then `exec git` with `GH_TOKEN` in env only, never argv (`tests/git.bats:60-70`).
- Existing tests to adapt: `tests/gh.bats`, `tests/git.bats`, `tests/gh-wrapper-usage.bats`, `tests/gh-wrapper-shebang-invocation.bats`, fakes in `tests/fixtures/{gh,git}/`.
- Toolchain: Go 1.26.1 present locally (`go version`); CI `bats` job runs on ubuntu with no Go setup today (`.github/workflows/tests.yml`).

## Solution

- **Layout**: `_gh/go/` (own `go.mod`, stdlib only - no `go.sum`, builds offline):
  - `main.go` - dispatch on first arg `gh` | `git`; error prefix `gh.sh:` / `git.sh:` to match today's messages;
  - `slug.go`, `accounts.go` (parse `--json hosts`), `picker.go` (tier probe + cache), `gitwire.go`;
  - `*_test.go` - table tests with a fake `gh` on `PATH` (same pattern as `tests/fixtures/gh/fake-gh.sh`).
- **Cache file format unchanged**, so bash and Go pickers interoperate and can be flipped back and forth.
- **Token/child handling**: `gh auth token --user <u>` and `gh api` stay shelled out to the real `gh` (no new auth code, no go-gh dependency); child env gets `GH_TOKEN`; `git` mode uses `syscall.Exec` (token never in argv).
- **Opt-in switch (stage 1, additive)**: the existing wrappers stay the default. At the top of `main()` in `_gh/gh.sh` and `main_git()` in `_gh/git.sh`: if `CCXP_GH_GO=1` **and** an executable exists at `${CCXP_GH_BIN:-<_gh>/bin/ccxp-gh}`, `exec` it with mode + args; otherwise fall through to the bash path unchanged (a stderr note is printed at most once per process, and only when `CCXP_GH_DEBUG=1`, because callers may merge stderr into parsed output).
  - No call site changes: all existing `bash .../_gh/gh.sh` callers keep working; skills opt in per process via env, so rollout is a single env var, reversible instantly.
  - Build is manual in stage 1: `cd _gh/go && go build -o ../bin/ccxp-gh .`; `_gh/bin/` is added to `.gitignore` in the impl PR (no entry today).
- **Distribution options (decision needed, not chosen here)**:
  - A. Committed prebuilt binaries per platform (`darwin-arm64`, `darwin-amd64`, `linux-amd64`, `linux-arm64`): zero toolchain need, but binary blobs in git and in the plugin cache; supply-chain/review burden.
  - B. Build on first use (`go build` into a user cache dir, never the possibly read-only/version-pinned plugin dir): no blobs, but requires a Go toolchain on every machine and CI; first call slow; failure mode must fall back to bash.
  - C. GitHub release artifacts fetched on demand: clean repo, needs a release workflow, checksum pinning and network at first use.
  - D. Keep opt-in only (devs who want it build it): zero distribution work, no fleet benefit.
  - Recommendation: B with mandatory bash fallback, then C if Go is not universally present. Choosing needs the maintainer (it decides what the plugin ships).
- **Known scope limits (stage 1)**:
  - Real callers are `bash`-invoked (`_session/_lib.sh:92` runs `bash "$wrapper" "$@"`), so they reach `main()` and take the Go path when the switch is on; their stdout/stderr must stay parity-safe.
  - Only `source`-ers keep the bash internals: `git.sh` sources `gh.sh`, and `tests/gh.bats:22`, `tests/git.bats:114`/`:140`. The bash path also keeps `awk` for cache lookup/invalidate (`_gh/gh.sh:112`, `:154`) - same tool-drift class as the gawk bug - so "no external-tool parsing" holds for the Go path only.
  - `gh auth status --json` needs a recent gh: the Go binary detects an unsupported flag and exits with a clear "upgrade gh or unset CCXP_GH_GO" error; only gh 2.101.0 is verified so far.
- **`--json hosts` parsing rules** (pinned here, tested in impl):
  - parse stdout regardless of exit code (`gh auth status` exits 1 when any account's token is invalid);
  - keep accounts with `state == "success"` only; host scope stays `github.com` (parity with today);
  - order as returned.
- **Parity details the port must copy**:
  - child inherits stdin; `GH_TOKEN` replaces (not duplicates) any existing entry in the child env;
  - exit code: 128+N when the child dies on signal N (bash behavior), not Go's -1;
  - stderr buffered and relayed after the command, as today (`_gh/gh.sh` `main()`), a deliberate parity choice;
  - `git` mode keeps today's order and tolerance: credential wiring runs only after a successful pick and before the token read, errors swallowed, always succeeds (`_gh/git.sh:31-76`); `git` is resolved from `PATH` as bash does;
  - cache path built from `$TMPDIR`/`$USER` env, not `os/user`; appends are not atomic across bash and Go, harmless since the cache is best-effort.
- **Alternatives considered and rejected**:
  - Replace the wrappers in one step - rejected: every skill calls them; hard limit is additive + staged.
  - Keep bash and just use `--json` + `jq` - rejected as the sole fix for this task (adds a `jq` dependency, same class of tool-drift risk), though it remains a cheap intermediate hardening.
  - go-gh library - rejected: a network-fetched dependency for what two `exec`s already do.

## Test plan

- [x] `go test ./...` in `_gh/go/`: slug parsing (SSH alias, https, no `.git`), `--json hosts` parsing (active/inactive, missing host), picker (write beats earlier read-only, read fallback, none -> error text), cache read/write/invalidate, permission-error regexp.
- [x] `tests/gh-go.bats`: black-box run of the built binary against `tests/fixtures/gh/fake-gh.sh` (extended in the impl PR to serve `auth status --json hosts`; today it only emulates the text form and exits 99 on unknown shapes) (account order, token in env not argv, self-heal retry, error messages); skipped when `go` is absent - note CI's `bats` job has no `setup-go` today, so it would never run there unless the impl PR adds that step.
- [x] `_session_gh` (`_session/_lib.sh`) works end-to-end under `CCXP_GH_GO=1` with the fake binary.
- [x] Shim tests: switch off -> bash path untouched; switch on + binary present -> exec'd; switch on + binary missing -> bash fallback.
- [x] Existing `bats tests/*.bats` stays green (the bash path is unchanged by default).
- [ ] Post-merge (external): real-machine smoke with two accounts, `CCXP_GH_GO=1 bash _gh/gh.sh api user --jq .login`.

## Done criteria

- [x] Go binary implements gh + git modes with parity on picker/cache/self-heal/messages - `_gh/go/gh_test.go`, `tests/gh-go.bats` (stage 1, impl PR).
- [x] Account detection uses `gh auth status --json hosts`, no text parsing - `_gh/go/accounts.go:36-52` + `TestParseAccounts` in `_gh/go/gh_test.go`.
- [x] Wrappers unchanged by default, opt-in switch works - `tests/gh-go.bats` shim tests (tests 1-5).
- [x] Build step documented - `_gh/go/build.sh` header, `_gh/go/main.go:1-12`.
- [ ] Stage 2: install.sh + argv[0] mode + forwarders + shim removal - `_gh/go/install.sh`, `tests/gh-go.bats` (stage 2 impl PR).
- [ ] Call sites migrated to bare `gh`/`git`, forwarders deleted - follow-up task (filed at stage 2 close).
- [x] fake-broken-awk / locale regression tests noted as moot for the Go path `tests/gh-go.bats` header comment + test 12.

## Root cause

- `_gh_list_accounts` was written against `gh auth status` prose (introduced with the multi-account picker, T20260819-381973 era; later hardened to pure-bash by T20261012-280694 - a workaround, not a structural fix).
- The prose format is not an API: it is locale/version-dependent, and parsing it is the bug class.

## Repo file references

| File | Lines | Purpose |
|---|---|---|
| `_gh/gh.sh` | 61-87 | text-parsing `_gh_list_accounts` (the fragile part) |
| `_gh/gh.sh` | 158-197 | `main()` - where the opt-in switch goes |
| `_gh/git.sh` | 67-77 | `main_git()` - same switch; credential wiring to port |
| `tests/gh.bats`, `tests/git.bats` | - | behavior to mirror in Go tests |
| `tests/gh-wrapper-shebang-invocation.bats` | - | guardrail; shim must keep explicit `bash` callers valid |

## Stage 1 status

- Shipped (impl PR): Go binary + opt-in shim + tests + CI `setup-go` step; bash wrappers remain the default.
- Distribution decided by the maintainer 2026-10-20: see Stage 2 below (supersedes options A-D and the opt-in switch).

## Stage 2 design (maintainer decision 2026-10-20)

- **Decision (B')**: build locally, install under `~/.local/bin`; nothing committed as a binary, no release artifacts, **no bash in the gh/git path**. Fallback when the binary is missing or fails to start is the real `gh`/`git` (no account switching) - the maintainer accepts losing per-repo account selection in that case.
- **Install**: `_gh/go/install.sh` (hand-run, not in any call path): `go build -ldflags '-s -w'` to a temp file, self-test (`ccxp-gh version`, usage exit code), atomic `mv` to `~/.local/bin/ccxp-gh`; optional `--link-dir DIR` creates `gh`/`git` symlinks to it.
- **Resolution without a bash hop**: one binary, mode by `argv[0]` basename (`gh`, `git`, or `ccxp-gh <gh|git> ...`).
  - PATH order verified on this Mac (`echo $PATH`): `~/workspace/.bin` precedes `/opt/homebrew/bin`; `~/.local/bin` is appended **last** (`~/.zprofile:3`), so a `gh` placed there would NOT shadow the real one.
  - Least invasive choice: put the `gh`/`git` symlinks in `~/workspace/.bin` (the dir that already holds the bash shims, already ahead of homebrew), replacing the shim files. No shell-profile change.
- **Implicit routing (argv[0]=gh|git) reproduces the retired shims exactly** (`~/workspace/.bin/{gh,git}`): act only under `~/workspace`; gh skips `auth|config|extension|alias|completion|version|help|` and non-github/non-repo cwd; git acts only for `push|pull|fetch|ls-remote` with a github.com origin; everything else execs the real binary. Deliberate behavior change per the maintainer: any picker failure in implicit mode (no account with access, old gh without `--json`) execs the real binary instead of dying - plain `gh`/`git` gain no new failure modes, and the cost is that a wrong-account failure is no longer announced (one stderr note only with `CCXP_GH_DEBUG=1`).
  - Keep `auth` in the skip list: the wired credential helper `!gh auth git-credential` resolves back to the Go link and must pass straight through.
  - stderr: streamed live when it is a terminal (prompts, `gh run watch`; no retry then), buffered for the permission-retry otherwise.
- **Real-binary lookup (one `realBin(name)` used by EVERY exec in the Go code)**: accounts probe, tier probe, slug lookup, credential wiring, the final `syscall.Exec` and the retry all go through it (review finding: bare PATH lookups would recurse into our own symlink and fork-bomb).
  - Scan `PATH`, skip any `entry/<name>` whose `EvalSymlinks` equals the `EvalSymlinks` of `os.Executable()`; then `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`; `CCXP_REAL_GH` / `CCXP_REAL_GIT` override (tests).
  - Belt and braces: the Go code sets `CCXP_GH_ACTIVE=1` in the env of every child/exec'd real binary; when it is already set (a copied/hard-linked binary, gh-to-git or git-to-credential-helper chains) implicit mode execs the real binary directly and never re-picks.
- **Explicit mode (`ccxp-gh gh ...`)** keeps stage 1 semantics: always pick, same error messages.
- **Wrappers**: `_gh/gh.sh` / `_gh/git.sh` become minimal forwarders (`exec "${CCXP_GH_BIN:-$HOME/.local/bin/ccxp-gh}" gh "$@"` by absolute path - `~/.local/bin` is only added to PATH in login shells (`~/.zprofile`), so non-login shells such as bats and the Claude tool shell would otherwise miss it; fallback `exec gh "$@"` via PATH when the binary is absent) - the **only remaining bash**; chosen over migrating ~375 call references (SKILL.md prose, tests, lint scripts) because it keeps every skill working today at near-zero risk; a follow-up task migrates call sites to bare `gh`/`git`, after which the forwarders are deleted. All bash picker logic and the `CCXP_GH_GO` switch are removed.
- **Limits**: a binary that exists but cannot launch (bad build, codesign kill) has no runtime fallback - `install.sh`'s self-test is the only protection. GitHub Actions has no `ccxp-gh`: forwarders degrade to plain `gh` + `GH_TOKEN` (arguably better than the old keyring picker there); forwarder bats use a fake via `CCXP_GH_BIN` and a missing-binary test.
- **Tests**: `tests/gh.bats`/`git.bats` internals tests (sourcing removed bash functions) are replaced by forwarder tests; `tests/gh-go.bats` and `tests/git.bats` set their own `PATH=/opt/homebrew/bin:/usr/bin:...` so no user shim can hang them (the hang was a shim recursing into the fake git); Go tests cover routing parity (`""`, `-R x pr list`, `auth`, non-github origin), argv[0] mode, real-binary lookup incl. symlink-first-on-PATH and a dangling symlink, the sentinel, and the fall-through.
- **Machine change (maintainer-authorized, not in the PRs)**: after the install is verified, trash the two bash shims in `~/workspace/.bin` (copies kept for restore) and link `gh`/`git` there to `ccxp-gh`.
- **Alternatives rejected**: `~/.local/bin` links only (does not shadow real gh/git - appended last); editing PATH in `~/.zprofile` (outside authorization, affects every shell); keeping bash as fallback (maintainer: no bash in between).

## Closed

(pending)

## Skills invoked

(pending)
