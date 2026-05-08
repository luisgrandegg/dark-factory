#!/usr/bin/env bash
# Smoke test for scripts/factory/dashboard.sh.
#
# Builds a synthetic ledger, generates the dashboard into a tmpdir,
# and asserts the rendered HTML contains the expected sections, hero
# numbers, and table rows.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/factory/dashboard.sh"
[[ -x "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

tmp=$(mktemp -d -t dashboard-smoke-XXXX)
trap 'rm -rf "$tmp"' EXIT

today=$(date -u +"%Y/%m/%d")
mkdir -p "$tmp/ledger/runs/$today"
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

write_run() {
  local id="$1" wi="$2" station="$3" status="$4" wall="$5" reason="$6"
  local rfield
  if [[ "$reason" == "null" ]]; then rfield="null"; else rfield="\"$reason\""; fi
  cat > "$tmp/ledger/runs/$today/$id.json" <<JSON
{"id":"$id","workItemId":$wi,"station":"$station","status":"$status",
 "startedAt":"$now_iso","endedAt":"$now_iso","failureReason":$rfield,
 "usage":{"wallSeconds":$wall,"toolCalls":2}}
JSON
}

write_run S1  1 intake    success   10 null
write_run S2  1 plan      success   20 null
write_run F1 42 implement failure   30 ci-failed
write_run F2 42 implement failure   60 ci-failed
write_run E1  7 plan      escalated 15 budget

out="$tmp/dashboard/index.html"
"$SCRIPT" --ledger-dir "$tmp/ledger" --days 7 --out "$out" >/dev/null \
  || { echo "FAIL: dashboard.sh exited non-zero"; exit 1; }

[[ -f "$out" ]] || { echo "FAIL: $out not produced"; exit 1; }

fails=0
have() {
  local label="$1" needle="$2"
  if grep -q -- "$needle" "$out"; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s — missing %q\n' "$label" "$needle"
    fails=$((fails + 1))
  fi
}

have "title"            'Factory control room'
have "hero.totalRuns"   '<div class="value">5</div>'
have "hero.failed"      '<div class="value">3</div>'
have "section.station"  'Per-station latency'
have "section.reasons"  'Top failure reasons'
have "section.wi"       'Top affected WorkItems'
have "row.intake"       '<td>intake</td>'
have "row.plan"         '<td>plan</td>'
have "row.implement"    '<td>implement</td>'
have "row.ci-failed"    '<td>ci-failed</td>'
have "row.budget"       '<td>budget</td>'
have "row.wi42"         '<td>#42</td>'
have "footer"           'scripts/factory/dashboard.sh'

# HTML well-formedness: closing </html> tag.
have "closing.html"     '</html>'

# Empty ledger case: still produces a valid page with empty-state messages.
empty="$tmp/empty"
mkdir -p "$empty/ledger/runs/$today"
"$SCRIPT" --ledger-dir "$empty/ledger" --days 7 --out "$empty/index.html" >/dev/null \
  || { echo "FAIL: empty case exited non-zero"; exit 1; }
grep -q "No runs in window"          "$empty/index.html" || { echo "FAIL: empty.runs message"; fails=$((fails + 1)); }
grep -q "No failures in window"      "$empty/index.html" || { echo "FAIL: empty.failures message"; fails=$((fails + 1)); }

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "PASSED"
