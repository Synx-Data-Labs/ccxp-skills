---
status: Open
estimation: 1
depends_on: [T20261125-366351, T20261125-264487]
source: follow-up of T20261125-264487 (retire blocks); drive after the plugin release carrying it
related: T20261125-315142
description: Run todo-deps.sh migrate on ccxp-skills own dev/TODO and dev/PARKING once the release with the derived-dependants readers is installed
---

# T20261125-288322: Migrate ccxp-skills' own task files from `blocks:` to `depends_on`

## Problem

- **Type**: chore
- After the plugin release carrying T20261125-264487 (the owner releases separately): run `todo-deps.sh migrate --dry-run`, review, then `migrate` on this repo's `dev/TODO` and `dev/PARKING`; lint and bats green; one PR.
- Check `rg '^blocks:' dev/TODO dev/PARKING` is empty afterwards.
