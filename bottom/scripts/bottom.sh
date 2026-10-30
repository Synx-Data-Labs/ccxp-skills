#!/usr/bin/env bash
# bottom.sh — /bottom entry point: _queue/queue-op.sh with the verb bound (see its header for the CLI).
set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../_queue/queue-op.sh" bottom "$@"
