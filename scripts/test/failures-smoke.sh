#!/usr/bin/env bash
# Smoke test for scripts/factory/failures.sh.
#
# Builds a synthetic ledger with a mix of success / failure / escalated
# Runs across multiple stations and WorkItems, then asserts the
# clustering math.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/factory/failures.sh"
[[ -x "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

tmp=$(mktemp -d -t failures-smoke-XXXX)
trap 'rm -rf "$tmp"' EXIT

today=$(date -u +"%Y/%m/%d")
mkdir -p "$tmp/runs/$today"
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_run() {
  local id="$1" wi="$2" station="$3" status="$4" reason="$5"
  local reason_field
  if [[ "$reason" == "null" ]]; then reason_field="null"; else reason_field="\"$reason\""; fi
  cat > "$tmp/runs/$today/$id.json" <<JSON
{
  "schemaVersion": 1,
  "id": "$id",
  "workItemId": $wi,
  "station": "$station",
  "agent": "subagent:$station",
  "host": "local",
  "sessionId": "smoke",
  "parentRunId": null,
  "startedAt": "$now_iso",
  "endedAt": "$now_iso",
  "status": "$status",
  "failureReason": $reason_field,
  "artifacts": {"filesTouched": [], "branch": null, "pr": null, "comments": [], "snapshot": null},
  "usage": {"tokensIn": null, "tokensOut": null, "wallSeconds": 5, "toolCalls": 1, "costUsd": null},
  "labelTransition": null
}
JSON
}

# 10 runs total: 4 success, 4 failure (3 ci-failed, 1 budget),
# 2 escalated (1 budget, 1 review-rejected).
# WorkItem #42 has 3 failures (all ci-failed on implement) — top item.
# WorkItem #7 has 1 failure (budget plan) + 1 escalated (budget plan).
write_run S1 1 intake    success   null
write_run S2 1 plan      success   null
write_run S3 2 implement success   null
write_run S4 2 qa        success   null
write_run F1 42 implement failure   ci-failed
write_run F2 42 implement failure   ci-failed
write_run F3 42 implement failure   ci-failed
write_run F4 7  plan      failure   budget
write_run E1 7  plan      escalated budget
write_run E2 9  qa        escalated review-rejected

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

out=$("$SCRIPT" --ledger-dir "$tmp" --format json --days 7) || {
  echo "FAIL: script exited non-zero"; exit 1
}

py() { python3 -c "$1" <<<"$out"; }

check "totalRuns"   "$(py 'import sys,json;print(json.load(sys.stdin)["totalRuns"])')"   "10"
check "failedRuns"  "$(py 'import sys,json;print(json.load(sys.stdin)["failedRuns"])')"  "6"

# Top reason should be ci-failed with count 3.
check "topReason"        "$(py 'import sys,json;print(json.load(sys.stdin)["byReason"][0]["reason"])')"        "ci-failed"
check "topReason.count"  "$(py 'import sys,json;print(json.load(sys.stdin)["byReason"][0]["count"])')"        "3"
# Second reason should be budget with count 2.
check "secondReason"        "$(py 'import sys,json;print(json.load(sys.stdin)["byReason"][1]["reason"])')"      "budget"
check "secondReason.count"  "$(py 'import sys,json;print(json.load(sys.stdin)["byReason"][1]["count"])')"      "2"
# review-rejected with count 1.
check "thirdReason"         "$(py 'import sys,json;print(json.load(sys.stdin)["byReason"][2]["reason"])')"      "review-rejected"

# Stations under ci-failed: implement(3).
check "ci-failed.implement" "$(py 'import sys,json;print(json.load(sys.stdin)["byReason"][0]["byStation"]["implement"])')" "3"

# Top WorkItem is #42 with 3 failures.
check "topWi.id"       "$(py 'import sys,json;print(json.load(sys.stdin)["topWorkItems"][0]["workItemId"])')"  "42"
check "topWi.failures" "$(py 'import sys,json;print(json.load(sys.stdin)["topWorkItems"][0]["failures"])')"    "3"
check "topWi.lastReason" "$(py 'import sys,json;print(json.load(sys.stdin)["topWorkItems"][0]["lastReason"])')" "ci-failed"

# Markdown output sanity.
md=$("$SCRIPT" --ledger-dir "$tmp" --format md --days 7)
printf '%s\n' "$md" | grep -q "Factory failures"            || { echo "FAIL: md missing header"; fails=$((fails + 1)); }
printf '%s\n' "$md" | grep -q "Top reasons"                 || { echo "FAIL: md missing reasons section"; fails=$((fails + 1)); }
printf '%s\n' "$md" | grep -q "| ci-failed | 3 |"           || { echo "FAIL: md missing ci-failed row"; fails=$((fails + 1)); }
printf '%s\n' "$md" | grep -q "| #42 | 3 |"                 || { echo "FAIL: md missing top WI row"; fails=$((fails + 1)); }

# No-failures case: synthesise an all-green ledger.
empty=$(mktemp -d -t failures-empty-XXXX)
trap 'rm -rf "$tmp" "$empty"' EXIT
mkdir -p "$empty/runs/$today"
cat > "$empty/runs/$today/G1.json" <<JSON
{"id":"G1","workItemId":1,"station":"intake","status":"success","startedAt":"$now_iso","endedAt":"$now_iso","usage":{"wallSeconds":1,"toolCalls":1}}
JSON
nojson=$("$SCRIPT" --ledger-dir "$empty" --format json --days 7)
check "noFails.failedRuns" "$(printf '%s' "$nojson" | python3 -c 'import sys,json;print(json.load(sys.stdin)["failedRuns"])')" "0"
nomd=$("$SCRIPT" --ledger-dir "$empty" --format md --days 7)
printf '%s\n' "$nomd" | grep -q "no failures in window" || { echo "FAIL: md missing no-failures message"; fails=$((fails + 1)); }

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "PASSED"
