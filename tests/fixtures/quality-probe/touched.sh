#!/usr/bin/env bash
# Fixture: a touched shell file with a known, stable shape so qp-size pins
# exact numbers. 13 physical lines total; one function body of 5 lines.
set -euo pipefail

qp_fixture_fn() {
  local a="$1"
  local b="$2"
  echo "$a"
  echo "$b"
}

qp_fixture_fn "x" "y"
