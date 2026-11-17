#!/usr/bin/env bash
# Filter and group dev/TODO tasks by time / place / person / event
# (T20261114-380745). Read-only; see task_query.py for the flags.
set -euo pipefail
exec python3 -I "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/task_query.py" "$@"
