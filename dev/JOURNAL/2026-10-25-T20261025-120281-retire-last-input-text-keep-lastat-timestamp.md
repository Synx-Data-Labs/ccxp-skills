---
status: Done
scheduled: 2026-10-25
estimation: 2
source: user request, 2026-10-21 ("we can deprecate the last-input-hook.sh and the last input in the status line"); scope narrowed 2026-10-25 ("i need the timestamp, but I don't need to remember the last input")
related: T20260924-366770
claimed_by:
claimed_role:
---

# T20261025-120281: Retire the remembered last-input text, keep the timestamp-only `lastat`

## Problem

- **Type**: refactor
- The classic statusline's trailing `last: <text>` segment and the HUD's opt-in `last` field (T20260924-366770) are no longer wanted.
- The first attempt (a branch deleting `last-input-hook.sh` outright) went stale: main gained the HUD `lastat` field (`you HH:MM`), which is fed only by that hook's cache file mtime. Deleting the hook would have silently hidden `lastat` for good.

## TLDR

- Text retired everywhere: `sl-last-input-part` and the `last:` segment, the HUD `last` field (`--with-last-input`, `last_input`, `Field` type, config, model, register), and every code path that wrote or read prompt text.
- `last-input-hook.sh` kept at the same path, now timestamp-only: it reads only `session_id` and truncates an empty `<state>/<session_id>` file, so the mtime is the last-prompt time. Pruning of files older than 30 days and the path-traversal guard are unchanged.
- `sl-last-input-epoch` and `hud-data.sh`'s `last_input_at` are unchanged, so `lastat` behaves exactly as before.
- Rest of the statusline output is byte-identical to main (checked old vs new on the same payloads, with and without a cache).

## Decisions

- **Keep the name `last-input-hook.sh`** (no rename, no shim): existing `settings.json` entries point at that path, and the script still records the time of the last input. A rename would force every registrant to edit settings and need a compatibility shim; the blast radius is not worth the cosmetic gain.
- **Old text files self-heal**: the hook truncates the session's file on the next prompt, so cached text from the old version is wiped. Nothing reads file contents any more, so leftovers are inert; `rm -rf ~/.claude/state/last-input` clears them (optional).
- **Hookless alternative, not adopted**: the session transcript file's mtime needs no hook, but it also changes on assistant and tool events, so it is not the time of the last user input. Switching would change `lastat` semantics; ask first.
- **Registering the hook is required for `lastat`**: without a `hooks.UserPromptSubmit` entry the cache never exists, `last_input_at` stays 0 and `lastat` is hidden (the state for anyone who never registered it). Entry: `{ "hooks": [ { "type": "command", "command": "bash <plugin-or-checkout path>/statusline-setup/scripts/last-input-hook.sh" } ] }`, appended to the array (SKILL.md Deploy step 4).
- **No version bump**: separate maintainer PR. The maintainer classifies it; it removes an opt-in text feature (statusline segment, HUD `last` field and its `--with-last-input` flag) and changes the hook's behavior.

## Test Plan

- [x] `bats tests/statusline_setup.bats tests/last_input_hook.bats tests/hud_data.bats tests/ledger.bats` passes.
- [x] Old vs new `statusline-command.sh` on the same payloads: the only difference is the removed `last: <text>` segment and its separator.
- [x] The hook writes an empty file (no prompt text), bumps the mtime, wipes old cached text; `sl-last-input-epoch` reads it.
- [x] Skill-score ratchet holds (`statusline-setup` stays at 99).
