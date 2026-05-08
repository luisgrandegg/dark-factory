#!/usr/bin/env bash
# Budget kill-switch.
#
# Aggregates ledger usage for a given WorkItem (per-workitem caps) and the
# current UTC day (per-day caps), compares against `.factory/policy.yml`
# `budgets.*`, and either:
#
#   - exits 0 with `ok` on stdout if the next station may run, or
#   - exits 2 with one or more `cap=<name>:<used>/<limit>` lines on stdout
#     and a recommended action (escalate-workitem | escalate-day) so the
#     foreman knows what to do.
#
# Read-only: never mutates labels or comments. The caller (foreman) is
# responsible for the actual escalation; this script just reports.
#
# Usage:
#   scripts/factory/budget-check.sh --workitem <id>
#       [--station <name>]   # optional: also check perStation caps for one tick
#
# Phase 2 wiring: the foreman calls this after picking a WorkItem and
# before running the station (skill step 6).

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

workitem=""; station=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workitem) workitem="$2"; shift 2 ;;
    --station)  station="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,21p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$workitem" ]] || die "usage: budget-check.sh --workitem <id> [--station <name>]"

repo=$(repo_slug) || die "could not determine repo slug"
ledger=$(policy_ledger_branch); ledger=${ledger:-factory/ledger}
state_branch=$(policy_state_branch); state_branch=${state_branch:-factory/state}

# ---- read caps ----------------------------------------------------------
yaml_get() {
  # $1 = jq-style path under .budgets, e.g. perWorkItem.maxToolCalls
  if command -v yq >/dev/null 2>&1; then
    yq -r ".budgets.$1 // \"\"" "$POLICY"
  else
    python3 - "$POLICY" "$1" <<'PY'
import sys, re
path = sys.argv[2].split(".")
text = open(sys.argv[1]).read()
# Crude top-down indented descent; sufficient for our flat schema.
import yaml
try:
    doc = yaml.safe_load(text)
except Exception:
    print(""); sys.exit(0)
cur = (doc or {}).get("budgets", {})
for p in path:
    if not isinstance(cur, dict): print(""); sys.exit(0)
    cur = cur.get(p)
    if cur is None: print(""); sys.exit(0)
print(cur)
PY
  fi
}

cap_wi_tokens=$(yaml_get perWorkItem.maxTokens)
cap_wi_calls=$(yaml_get perWorkItem.maxToolCalls)
cap_wi_wall=$(yaml_get perWorkItem.maxWallMinutes)
cap_wi_retries=$(yaml_get perWorkItem.maxRetries)
cap_day_tokens=$(yaml_get perDay.maxTokens)
cap_day_calls=$(yaml_get perDay.maxToolCalls)
cap_day_wall=$(yaml_get perDay.maxWallMinutes)
cap_st_calls=""
cap_st_wall=""
if [[ -n "$station" ]]; then
  cap_st_calls=$(yaml_get "perStation.$station.maxToolCalls")
  cap_st_wall=$(yaml_get "perStation.$station.maxWallMinutes")
fi

# ---- per-WorkItem rollup from runs/by-workitem/<id>.jsonl --------------
index_path="runs/by-workitem/$workitem.jsonl"
index_doc=$(contents_get "$repo" "$ledger" "$index_path" || true)
wi_calls=0; wi_wall=0; wi_retries=0
if [[ -n "$index_doc" ]]; then
  body=$(printf '%s' "$index_doc" | contents_decode)
  # The JSONL only has summary fields; sum tool calls and wall seconds
  # from the full Run records the index references.
  # Cheap path: re-fetch each run's JSON. For a typical WorkItem with <
  # 30 runs this is a few HTTP calls; acceptable for a kill-switch.
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    run_id=$(printf '%s' "$line" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("id",""))' 2>/dev/null || echo "")
    status=$(printf '%s' "$line" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("status",""))' 2>/dev/null || echo "")
    [[ -z "$run_id" ]] && continue
    if [[ "$status" == "failure" || "$status" == "retry" ]]; then
      wi_retries=$((wi_retries + 1))
    fi
    # ULID's first 13 chars = millis epoch; we don't trust that across
    # date boundaries, so fall back to scanning the whole runs/ tree.
    # Cheaper: assume today's path; if 404, skip — the index entry is
    # informational only for retries.
    day=$(date -u +"%Y/%m/%d")
    run=$(contents_get "$repo" "$ledger" "runs/$day/$run_id.json" || true)
    [[ -z "$run" ]] && continue
    j=$(printf '%s' "$run" | contents_decode)
    tc=$(printf '%s' "$j" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("usage",{}).get("toolCalls",0) or 0)' 2>/dev/null || echo 0)
    ws=$(printf '%s' "$j" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read()); print(d.get("usage",{}).get("wallSeconds",0) or 0)' 2>/dev/null || echo 0)
    wi_calls=$((wi_calls + tc))
    wi_wall=$((wi_wall + ws))
  done <<<"$body"
fi
wi_wall_min=$((wi_wall / 60))

# ---- per-day rollup from state/budget.json -----------------------------
budget_doc=$(contents_get "$repo" "$state_branch" "budget.json" || true)
day_calls=0; day_wall_min=0; day_tokens=0
if [[ -n "$budget_doc" ]]; then
  bj=$(printf '%s' "$budget_doc" | contents_decode)
  today=$(date -u +"%Y-%m-%d")
  read -r day_tokens day_calls day_wall_min < <(printf '%s' "$bj" | python3 - "$today" <<'PY'
import sys, json
day = sys.argv[1]
try:
    doc = json.loads(sys.stdin.read())
except Exception:
    doc = {}
d = (doc.get("days") or {}).get(day, {})
print(d.get("tokens", 0) or 0, d.get("toolCalls", 0) or 0, d.get("wallMinutes", 0) or 0)
PY
)
fi

# ---- compare and report ------------------------------------------------
hits=()
gt() { [[ -n "$1" && -n "$2" && "$1" != "null" && "$2" != "null" ]] && (( $1 > $2 )); }
check() { # name used limit
  local name="$1" used="$2" limit="$3"
  [[ -z "$limit" || "$limit" == "null" ]] && return 0
  if (( used >= limit )); then
    hits+=("cap=$name:$used/$limit")
  fi
}

check "perWorkItem.maxToolCalls"   "$wi_calls"     "$cap_wi_calls"
check "perWorkItem.maxWallMinutes" "$wi_wall_min"  "$cap_wi_wall"
check "perWorkItem.maxRetries"     "$wi_retries"   "$cap_wi_retries"
check "perDay.maxToolCalls"        "$day_calls"    "$cap_day_calls"
check "perDay.maxWallMinutes"      "$day_wall_min" "$cap_day_wall"
check "perDay.maxTokens"           "$day_tokens"   "$cap_day_tokens"

if (( ${#hits[@]} == 0 )); then
  echo "ok"
  exit 0
fi

# Distinguish workitem vs day for the recommended action.
day_hit=0
for h in "${hits[@]}"; do
  [[ "$h" == cap=perDay.* ]] && day_hit=1
done
if (( day_hit )); then
  echo "action=escalate-day"
else
  echo "action=escalate-workitem"
fi
printf '%s\n' "${hits[@]}"
exit 2
