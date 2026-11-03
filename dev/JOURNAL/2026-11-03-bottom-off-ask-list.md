# Ask-list: drop `bottom`

- **Change**: `bottom` removed from `hooks/ask-skills.txt`; the other seven stay
  - Autopilot's housekeeping calls `/bottom` through the Skill tool, so every cycle prompted the owner
  - Owner decision: "i like the skill, just remove the prompt"
- **Docs and tests**
  - `README.md` ask-list sentence updated
  - New bats test: `bottom` (bare and qualified) gets no opinion from the hook
- **Typed `/bottom`**: unaffected, as before
