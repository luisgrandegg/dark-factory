#!/usr/bin/env bash
# Smoke test for scripts/factory/metrics.sh.
#
# Builds a synthetic ledger directory (no GitHub round-trip), runs the
# metrics script against it, and asserts the output shape and a few
# computed values. Pure local, fast.
#
# Usage:
#   scripts/test/metrics-smoke.sh
#
# Exit code: 0 on pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/factory/metrics.sh"
[[ -x "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

tmp=$(mktemp -d -t metrics-smoke-XXXX)
trap 'rm -rf "$tmp"' EXIT

today=$(date -u +"%Y/%m/%d")
mkdir -p "$tmp/runs/$today"

# Three intake runs (2 success, 1 failure), wallSeconds 10/20/30.
# Two plan runs (both success), wallSeconds 5/45.
# One escalated qa run.
write_run() {
  local id="$1" station="$2" status="$3" wall="$4" ended="$5"
  cat > "$tmp/runs/$today/$id.json" <<JSON
{
  "schemaVersion": 1,
  "id": "$id",
  "workItemId": 1,
  "station": "$station",
  "agent": "subagent:$station",
  "host": "local",
  "sessionId": "smoke",
  "parentRunId": null,
  "startedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "endedAt": $ended,
  "status": "$status",
  "failureReason": null,
  "artifacts": {"filesTouched": [], "branch": null, "pr": null, "comments": [], "snapshot": null},
  "usage": {"tokensIn": null, "tokensOut": null, "wallSeconds": $wall, "toolCalls": 1, "costUsd": null},
  "labelTransition": null
}
JSON
}

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
write_run A1 intake success    10 "\"$now_iso\""
write_run A2 intake success    20 "\"$now_iso\""
write_run A3 intake failure    30 "\"$now_iso\""
write_run B1 plan   success     5 "\"$now_iso\""
write_run B2 plan   success    45 "\"$now_iso\""
write_run C1 qa     escalated  60 "\"$now_iso\""

fails=0
check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s — expected %q, got %q\n' "$label" "$expected" "$actual"
    fails=$((fails + 1))
  fi
}

# JSON output
out=$("$SCRIPT" --ledger-dir "$tmp" --format json --days 7) || {
  echo "FAIL: script exited non-zero"; exit 1
}
check "totalRuns"          "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["totalRuns"])')" "6"
check "intake.runs"        "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stations"]["intake"]["runs"])')" "3"
check "intake.success"     "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stations"]["intake"]["success"])')" "2"
check "intake.failure"     "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stations"]["intake"]["failure"])')" "1"
check "intake.successRate" "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stations"]["intake"]["successRate"])')" "0.667"
check "intake.p50Wall"     "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stations"]["intake"]["p50WallSeconds"])')" "20"
check "plan.runs"          "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stations"]["plan"]["runs"])')" "2"
check "plan.successRate"   "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stations"]["plan"]["successRate"])')" "1.0"
check "qa.escalated"       "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stations"]["qa"]["escalated"])')" "1"
check "qa.successRate"     "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin)["stations"]["qa"]["successRate"])')" "0.0"

# Markdown output sanity (just contains the header and station rows).
md=$("$SCRIPT" --ledger-dir "$tmp" --format md --days 7)
printf '%s\n' "$md" | grep -q "Factory metrics" || { echo "FAIL: md missing header"; fails=$((fails + 1)); }
printf '%s\n' "$md" | grep -q "| intake |"      || { echo "FAIL: md missing intake row"; fails=$((fails + 1)); }
printf '%s\n' "$md" | grep -q "| plan |"        || { echo "FAIL: md missing plan row"; fails=$((fails + 1)); }
printf '%s\n' "$md" | grep -q "| qa |"          || { echo "FAIL: md missing qa row"; fails=$((fails + 1)); }

# Empty-window case: --days 0 should produce no station rows but exit 0.
empty=$("$SCRIPT" --ledger-dir "$tmp" --format json --days 0)
check "empty.totalRuns" "$(printf '%s' "$empty" | python3 -c 'import sys,json;print(json.load(sys.stdin)["totalRuns"])')" "0"

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "PASSED"
