#!/usr/bin/env bash
# _date/monday.sh [DATE] [--next] — the Monday on or before DATE (default
# today), or on or after it with --next. Thin front for `date.sh monday`; see
# date.sh for the semantics and why this exists.
set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/date.sh" monday "$@"
