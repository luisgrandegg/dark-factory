#!/usr/bin/env bash
# Smoke test for scripts/factory/schedule-tick.sh dry-run decisions.
#
# Builds synthetic schedule.yml + schedule-state.json files and asserts
# the expected fire/skip decisions for hourly/daily/weekly/monthly jobs
# under various clock conditions. No GitHub round-trip.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/factory/schedule-tick.sh"
[[ -x "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "skip: pyyaml not installed"; exit 0; }

tmp=$(mktemp -d -t schedule-smoke-XXXX)
trap 'rm -rf "$tmp"' EXIT

write_schedule() {
  cat > "$tmp/schedule.yml" <<YAML
version: 1
jobs:
  - id: weekly-deps
    title: "Dependency upgrade sweep"
    body: "Run dep upgrades."
    every: weekly
    onDayOfWeek: monday
    onHour: 13
    labels: ["stage:intake", "priority:p3", "factory:recurring"]

  - id: nightly-flake
    title: "Nightly flake triage"
    body: "Look at flakes."
    every: daily
    onHour: 5
    labels: ["stage:intake", "priority:p2", "factory:recurring"]

  - id: hourly-poll
    title: "Hourly poll"
    body: "Poll something."
    every: hourly
    labels: ["stage:intake", "priority:p3", "factory:recurring"]

  - id: monthly-clean
    title: "Monthly cleanup"
    body: "Tidy up."
    every: monthly
    onDayOfMonth: 1
    onHour: 10
    labels: ["stage:intake", "priority:p3", "factory:recurring"]

  - id: paused-job
    title: "Paused"
    body: "."
    every: daily
    enabled: false
    labels: ["stage:intake"]

  - id: invalid-no-every
    title: "Bad"
    body: "."
    labels: ["stage:intake"]
YAML
}

write_state() {
  cat > "$tmp/state.json" <<JSON
$1
JSON
}

decision() {
  local id="$1" out="$2"
  printf '%s\n' "$out" | python3 -c "
import sys, json
target = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d.get('id') == target:
        print(f\"{d.get('fire')}|{d.get('reason')}\")
        break
" "$id"
}

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

write_schedule

# Case A: never fired before, Monday 13:30 UTC.
write_state '{"schemaVersion":1,"jobs":{}}'
out=$("$SCRIPT" --dry-run --schedule "$tmp/schedule.yml" --state-file "$tmp/state.json" --now "2026-05-04T13:30:00Z")

check "A.weekly-deps"      "$(decision weekly-deps      "$out")" "True|due"
check "A.nightly-flake"    "$(decision nightly-flake    "$out")" "True|due"
check "A.hourly-poll"      "$(decision hourly-poll      "$out")" "True|due"
check "A.monthly-clean"    "$(decision monthly-clean    "$out")" "False|today is day 4 not 1"
check "A.paused"           "$(decision paused-job       "$out")" "False|disabled"
check "A.invalid-no-every" "$(decision invalid-no-every "$out")" "False|invalid every=None"

# Case B: same Monday at 04:00 UTC — before nightly-flake's onHour=5
# and weekly-deps's onHour=13. Hourly should still fire.
write_state '{"schemaVersion":1,"jobs":{}}'
out=$("$SCRIPT" --dry-run --schedule "$tmp/schedule.yml" --state-file "$tmp/state.json" --now "2026-05-04T04:00:00Z")
check "B.weekly-deps"   "$(decision weekly-deps   "$out")" "False|before onHour (04<13)"
check "B.nightly-flake" "$(decision nightly-flake "$out")" "False|before onHour (04<05)"
check "B.hourly-poll"   "$(decision hourly-poll   "$out")" "True|due"

# Case C: weekly-deps already fired earlier this week (same Monday).
write_state '{"schemaVersion":1,"jobs":{"weekly-deps":{"lastFiredAt":"2026-05-04T13:00:00Z","lastIssue":1}}}'
out=$("$SCRIPT" --dry-run --schedule "$tmp/schedule.yml" --state-file "$tmp/state.json" --now "2026-05-04T13:30:00Z")
check "C.weekly-deps.same-week" "$(decision weekly-deps "$out")" "False|already fired this week"

# Case D: weekly-deps fired last Monday — should fire again this Monday.
write_state '{"schemaVersion":1,"jobs":{"weekly-deps":{"lastFiredAt":"2026-04-27T13:00:00Z","lastIssue":1}}}'
out=$("$SCRIPT" --dry-run --schedule "$tmp/schedule.yml" --state-file "$tmp/state.json" --now "2026-05-04T13:30:00Z")
check "D.weekly-deps.next-week" "$(decision weekly-deps "$out")" "True|due"

# Case E: hourly fired 30 minutes ago — too soon (< 50min).
write_state '{"schemaVersion":1,"jobs":{"hourly-poll":{"lastFiredAt":"2026-05-04T13:00:00Z","lastIssue":1}}}'
out=$("$SCRIPT" --dry-run --schedule "$tmp/schedule.yml" --state-file "$tmp/state.json" --now "2026-05-04T13:30:00Z")
check "E.hourly.too-soon" "$(decision hourly-poll "$out")" "False|fired 30m ago (<50m)"

# Case F: hourly fired 60 minutes ago — should fire.
write_state '{"schemaVersion":1,"jobs":{"hourly-poll":{"lastFiredAt":"2026-05-04T12:30:00Z","lastIssue":1}}}'
out=$("$SCRIPT" --dry-run --schedule "$tmp/schedule.yml" --state-file "$tmp/state.json" --now "2026-05-04T13:30:00Z")
check "F.hourly.eligible" "$(decision hourly-poll "$out")" "True|due"

# Case G: monthly-clean on the 1st at 10:00 should fire.
write_state '{"schemaVersion":1,"jobs":{}}'
out=$("$SCRIPT" --dry-run --schedule "$tmp/schedule.yml" --state-file "$tmp/state.json" --now "2026-05-01T10:30:00Z")
check "G.monthly.fire" "$(decision monthly-clean "$out")" "True|due"

# Case H: monthly-clean already fired this month.
write_state '{"schemaVersion":1,"jobs":{"monthly-clean":{"lastFiredAt":"2026-05-01T10:00:00Z","lastIssue":1}}}'
out=$("$SCRIPT" --dry-run --schedule "$tmp/schedule.yml" --state-file "$tmp/state.json" --now "2026-05-01T11:00:00Z")
check "H.monthly.same-month" "$(decision monthly-clean "$out")" "False|already fired this month"

# Case I: nightly-flake already fired today.
write_state '{"schemaVersion":1,"jobs":{"nightly-flake":{"lastFiredAt":"2026-05-04T05:30:00Z","lastIssue":1}}}'
out=$("$SCRIPT" --dry-run --schedule "$tmp/schedule.yml" --state-file "$tmp/state.json" --now "2026-05-04T13:30:00Z")
check "I.daily.same-day" "$(decision nightly-flake "$out")" "False|already fired today"

# Empty schedule — no decisions, exit 0.
cat > "$tmp/empty.yml" <<YAML
version: 1
jobs: []
YAML
empty_out=$("$SCRIPT" --dry-run --schedule "$tmp/empty.yml" --state-file "$tmp/state.json" --now "2026-05-04T13:30:00Z")
[[ -z "$empty_out" ]] || { echo "FAIL: empty schedule produced output: $empty_out"; fails=$((fails + 1)); }

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "PASSED"
