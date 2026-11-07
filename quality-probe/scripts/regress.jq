# regress.jq — the single quality-probe regression-direction rule, shared by
# probe.sh (qp-warnings) and drive/scripts/verify-close.sh (T20260820-989935).
# coverage_pct and design_score regress when they FALL; every other metric
# regresses when it RISES. Input: a record's `delta` object. Output: one
# "<metric> <delta>" string per regressed metric.
def qp_regressed:
  to_entries[]
  | .key as $k | .value as $v
  | if ($k == "coverage_pct" or $k == "design_score") then
      (if $v < 0 then "\($k) \($v)" else empty end)
    else
      (if $v > 0 then "\($k) \($v)" else empty end)
    end;
