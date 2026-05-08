#!/usr/bin/env bash
# Smoke test for scripts/skills/flake-triage-rank.sh.
#
# Builds synthetic fixtures (no API calls) and asserts the ranking,
# flake-detection rules, and filter flags behave as expected.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/skills/flake-triage-rank.sh"
[[ -x "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

tmp=$(mktemp -d -t flake-rank-XXXX)
trap 'rm -rf "$tmp"' EXIT

fails=0
check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$label" "$expected" "$actual"
    fails=$((fails + 1))
  fi
}

field() {
  python3 -c '
import sys, json
target_wf, key = sys.argv[1], sys.argv[2]
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d["workflow"] == target_wf:
        v = d.get(key)
        print("" if v is None else json.dumps(v) if isinstance(v, (list, dict)) else v)
        break
' "$1" "$2" < <(printf '%s' "$3")
}

count_lines() { printf '%s\n' "$1" | grep -c . || true; }

# === Fixture A: one clean workflow, one flaky workflow.
# CI: 4 SHAs, 1 of them had a rerun that succeeded → 1 flake event / 4 SHAs = 25%.
# Lint: 4 SHAs, all clean → 0%.
cat > "$tmp/A.json" <<'JSON'
{
  "workflow_runs": [
    {"name": "CI",   "head_sha": "sha1", "run_attempt": 1, "conclusion": "success", "html_url": "u/1", "created_at": "2026-05-08T00:00:00Z"},
    {"name": "CI",   "head_sha": "sha2", "run_attempt": 1, "conclusion": "failure", "html_url": "u/2", "created_at": "2026-05-08T01:00:00Z"},
    {"name": "CI",   "head_sha": "sha2", "run_attempt": 2, "conclusion": "success", "html_url": "u/2-r","created_at": "2026-05-08T01:30:00Z"},
    {"name": "CI",   "head_sha": "sha3", "run_attempt": 1, "conclusion": "success", "html_url": "u/3", "created_at": "2026-05-08T02:00:00Z"},
    {"name": "CI",   "head_sha": "sha4", "run_attempt": 1, "conclusion": "success", "html_url": "u/4", "created_at": "2026-05-08T03:00:00Z"},

    {"name": "Lint", "head_sha": "sha1", "run_attempt": 1, "conclusion": "success", "html_url": "u/L1","created_at": "2026-05-08T00:00:00Z"},
    {"name": "Lint", "head_sha": "sha2", "run_attempt": 1, "conclusion": "success", "html_url": "u/L2","created_at": "2026-05-08T01:00:00Z"},
    {"name": "Lint", "head_sha": "sha3", "run_attempt": 1, "conclusion": "success", "html_url": "u/L3","created_at": "2026-05-08T02:00:00Z"},
    {"name": "Lint", "head_sha": "sha4", "run_attempt": 1, "conclusion": "success", "html_url": "u/L4","created_at": "2026-05-08T03:00:00Z"}
  ]
}
JSON

out=$("$SCRIPT" --from-fixture "$tmp/A.json")
check "A.row-count"        "$(count_lines "$out")"           "2"
# CI ranks first because it has higher flake rate.
first_wf=$(printf '%s' "$out" | head -1 | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["workflow"])')
check "A.first-workflow"   "$first_wf"                        "CI"
check "A.CI.flakeEvents"   "$(field CI flakeEvents   "$out")" "1"
check "A.CI.totalRuns"     "$(field CI totalRuns     "$out")" "5"
check "A.CI.flakeRate"     "$(field CI flakeRate     "$out")" "0.25"
check "A.Lint.flakeEvents" "$(field Lint flakeEvents "$out")" "0"
check "A.Lint.flakeRate"   "$(field Lint flakeRate   "$out")" "0.0"

# === Fixture B: force-rerun-without-attempt-bump (separate runs, same SHA, both fail+success).
# Two workflow_runs at run_attempt=1 for the same SHA: one failure, one success.
cat > "$tmp/B.json" <<'JSON'
{
  "workflow_runs": [
    {"name": "CI", "head_sha": "shaX", "run_attempt": 1, "conclusion": "failure", "html_url": "u/x1", "created_at": "2026-05-08T00:00:00Z"},
    {"name": "CI", "head_sha": "shaX", "run_attempt": 1, "conclusion": "success", "html_url": "u/x2", "created_at": "2026-05-08T00:30:00Z"}
  ]
}
JSON
out=$("$SCRIPT" --from-fixture "$tmp/B.json")
check "B.force-rerun.flakeEvents" "$(field CI flakeEvents "$out")" "1"
check "B.force-rerun.flakeRate"   "$(field CI flakeRate   "$out")" "1.0"

# === Fixture C: failure-only SHA does NOT count as a flake.
# A genuine regression that stays red is not a flake.
cat > "$tmp/C.json" <<'JSON'
{
  "workflow_runs": [
    {"name": "CI", "head_sha": "shaR", "run_attempt": 1, "conclusion": "failure", "html_url": "u/r1", "created_at": "2026-05-08T00:00:00Z"},
    {"name": "CI", "head_sha": "shaR", "run_attempt": 2, "conclusion": "failure", "html_url": "u/r2", "created_at": "2026-05-08T00:30:00Z"}
  ]
}
JSON
out=$("$SCRIPT" --from-fixture "$tmp/C.json")
check "C.regression.flakeEvents" "$(field CI flakeEvents "$out")" "0"

# === Fixture D: --workflow filter
out=$("$SCRIPT" --from-fixture "$tmp/A.json" --workflow Lint)
check "D.filter.row-count" "$(count_lines "$out")" "1"
check "D.filter.workflow"  "$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["workflow"])')" "Lint"

# === Fixture E: --min-flake-rate drops Lint
out=$("$SCRIPT" --from-fixture "$tmp/A.json" --min-flake-rate 0.05)
check "E.min-rate.row-count" "$(count_lines "$out")" "1"
check "E.min-rate.workflow"  "$(printf '%s' "$out" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["workflow"])')" "CI"

# === Fixture F: --top
out=$("$SCRIPT" --from-fixture "$tmp/A.json" --top 1)
check "F.top.row-count" "$(count_lines "$out")" "1"

# === Fixture G: empty fixture
echo '{"workflow_runs":[]}' > "$tmp/G.json"
out=$("$SCRIPT" --from-fixture "$tmp/G.json")
check "G.empty.no-output" "$out" ""

# === Fixture H: recentSamples preserved & ordered descending by date
out=$("$SCRIPT" --from-fixture "$tmp/A.json")
samples=$(field CI recentSamples "$out")
# Should be one sample (the sha2 flake), with sha "sha2".
sample_count=$(printf '%s' "$samples" | python3 -c 'import sys,json; print(len(json.loads(sys.stdin.read())))')
check "H.samples.count" "$sample_count" "1"
sample_sha=$(printf '%s' "$samples" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())[0]["sha"])')
check "H.samples.sha"   "$sample_sha"    "sha2"

# Bad lookback
if "$SCRIPT" --lookback bogus --from-fixture "$tmp/A.json" 2>/dev/null; then
  echo "FAIL bad-lookback should have errored"
  fails=$((fails + 1))
else
  echo "ok   bad-lookback.exits-nonzero"
fi

# Bad fixture path
if "$SCRIPT" --from-fixture /no/such/file 2>/dev/null; then
  echo "FAIL bad-fixture should have errored"
  fails=$((fails + 1))
else
  echo "ok   bad-fixture.exits-nonzero"
fi

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "PASSED"
