## Epics

Human-owned. See README.md's "dev/EPICS.md format" section for the shape —
`epic-status.sh`'s parser and `tests/epic-status.bats` are written against
this exact file, so keep the two in sync rather than letting either drift.

### E1 — Ship the pgrx bump

Goal: keep the pgrx bump shippable through the next major Postgres release
Done when: pgrx bump merged and green on main for a full week
Deadline: 2026-12-31

- T20260101-000001
- T20260101-000002
- T20260101-000003
- T20260101-000004 (near done, PR up)
- T20260101-000005
- T20260101-000006
- T20260101-000007
- T20260101-999999

### E2 — Cross-repo compliance audit

Goal: pass the compliance audit by Q3
Done when: audit sign-off received from the compliance team

- T20260202-000001

### E3 — Keep vendor egress under budget

Goal: keep vendor egress spend under the monthly budget
Done when: egress dashboard stays green for 30 consecutive days
Deadline: 2026-10-01

- T20260101-000003
