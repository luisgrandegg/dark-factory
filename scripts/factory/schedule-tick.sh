#!/usr/bin/env bash
# Evaluate .factory/schedule.yml and file any recurring jobs that are due.
#
# Read schedule.yml + schedule-state.json (state branch via Contents API),
# decide what's due using the rules in .factory/schedule-schema.md, then
# for each due job:
#   1. Open a GitHub issue with the configured title/body/labels.
#   2. Update schedule-state.json on the state branch (lastFiredAt, lastIssue).
#
# Usage:
#   scripts/factory/schedule-tick.sh [--dry-run]
#                                    [--schedule PATH]
#                                    [--state-file PATH]
#                                    [--now ISO8601]
#
# In --dry-run mode the script writes nothing and prints a JSON line per
# decision (whether the job would fire and why) — used by the smoke test.
#
# --state-file lets the smoke test point at a local JSON file instead of
# round-tripping through the GitHub Contents API. --now overrides the
# wall clock for deterministic tests.

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
schedule="$REPO_ROOT/.factory/schedule.yml"
state_file=""
dry_run=0
now_override=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    dry_run=1; shift ;;
    --schedule)   schedule="$2"; shift 2 ;;
    --state-file) state_file="$2"; shift 2 ;;
    --now)        now_override="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -f "$schedule" ]] || die "no schedule file at $schedule"

# When state-file is supplied we read/write it locally; otherwise we
# round-trip through the state branch via Contents API.
state_branch=""
state_sha=""
if [[ -z "$state_file" ]]; then
  if [[ "$dry_run" -eq 1 ]]; then
    # Dry-run without a local state file: synthesise an empty state.
    state_file=$(mktemp -t schedule-state-XXXX.json)
    printf '{"schemaVersion":1,"jobs":{}}\n' > "$state_file"
    trap 'rm -f "$state_file"' EXIT
  else
    repo=$(repo_slug) || die "could not determine repo slug"
    state_branch=$(policy_state_branch); state_branch=${state_branch:-factory/state}
    state_path="schedule-state.json"
    raw=$(contents_get "$repo" "$state_branch" "$state_path" || true)
    state_file=$(mktemp -t schedule-state-XXXX.json)
    trap 'rm -f "$state_file"' EXIT
    if [[ -n "$raw" ]]; then
      state_sha=$(printf '%s' "$raw" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sha",""))')
      printf '%s' "$raw" | contents_decode > "$state_file"
    else
      printf '{"schemaVersion":1,"jobs":{}}\n' > "$state_file"
    fi
  fi
fi

# Decide. The python block emits JSON Lines on stdout: one decision per
# job, plus a final summary line.
decisions=$(python3 - "$schedule" "$state_file" "${now_override:-}" <<'PY'
import json, sys, datetime, re

schedule_path, state_path, now_override = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    import yaml
except ImportError:
    sys.stderr.write("error: pyyaml is required (pip install pyyaml)\n")
    sys.exit(2)

with open(schedule_path) as f:
    sched = yaml.safe_load(f) or {}
with open(state_path) as f:
    state = json.load(f) or {}

if now_override:
    now = datetime.datetime.fromisoformat(now_override.replace("Z", "+00:00"))
else:
    now = datetime.datetime.now(datetime.timezone.utc)
if now.tzinfo is None:
    now = now.replace(tzinfo=datetime.timezone.utc)

DAYS = {d: i for i, d in enumerate(
    ["monday","tuesday","wednesday","thursday","friday","saturday","sunday"])}

state_jobs = state.get("jobs", {})
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")

decisions = []
for job in sched.get("jobs", []) or []:
    out = {"id": job.get("id"), "fire": False, "reason": ""}

    # Validate
    jid = job.get("id")
    if not jid or not ID_RE.match(jid):
        out["reason"] = "invalid id"
        decisions.append(out); continue
    if not job.get("title") or not job.get("body"):
        out["reason"] = "missing title/body"
        decisions.append(out); continue
    if not job.get("enabled", True):
        out["reason"] = "disabled"
        decisions.append(out); continue
    every = job.get("every")
    if every not in ("hourly", "daily", "weekly", "monthly"):
        out["reason"] = f"invalid every={every}"
        decisions.append(out); continue
    on_hour = int(job.get("onHour", 13))
    if not (0 <= on_hour <= 23):
        out["reason"] = "invalid onHour"
        decisions.append(out); continue

    last = state_jobs.get(jid, {}).get("lastFiredAt")
    last_dt = None
    if last:
        try:
            last_dt = datetime.datetime.fromisoformat(last.replace("Z", "+00:00"))
            if last_dt.tzinfo is None:
                last_dt = last_dt.replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            last_dt = None

    # Hour gate (everything but hourly has it).
    if every != "hourly" and now.hour < on_hour:
        out["reason"] = f"before onHour ({now.hour:02d}<{on_hour:02d})"
        decisions.append(out); continue

    # Cadence
    if every == "hourly":
        if last_dt and (now - last_dt).total_seconds() < 50 * 60:
            mins = int((now - last_dt).total_seconds() // 60)
            out["reason"] = f"fired {mins}m ago (<50m)"
            decisions.append(out); continue

    elif every == "daily":
        if last_dt and last_dt.astimezone(datetime.timezone.utc).date() == now.date():
            out["reason"] = "already fired today"
            decisions.append(out); continue

    elif every == "weekly":
        wanted = job.get("onDayOfWeek")
        if not wanted or wanted not in DAYS:
            out["reason"] = "weekly job missing onDayOfWeek"
            decisions.append(out); continue
        if now.weekday() != DAYS[wanted]:
            out["reason"] = f"today is {list(DAYS)[now.weekday()]} not {wanted}"
            decisions.append(out); continue
        # ISO week guard so weekly + Monday don't double-fire if the workflow
        # ran twice on Monday.
        if last_dt:
            iso_now  = now.isocalendar()
            iso_last = last_dt.astimezone(datetime.timezone.utc).isocalendar()
            if (iso_now[0], iso_now[1]) == (iso_last[0], iso_last[1]):
                out["reason"] = "already fired this week"
                decisions.append(out); continue

    elif every == "monthly":
        dom = job.get("onDayOfMonth")
        if not isinstance(dom, int) or not (1 <= dom <= 28):
            out["reason"] = "monthly job missing/invalid onDayOfMonth"
            decisions.append(out); continue
        if now.day != dom:
            out["reason"] = f"today is day {now.day} not {dom}"
            decisions.append(out); continue
        if last_dt and (last_dt.year, last_dt.month) == (now.year, now.month):
            out["reason"] = "already fired this month"
            decisions.append(out); continue

    out["fire"]   = True
    out["reason"] = "due"
    out["title"]  = job["title"]
    out["body"]   = job["body"]
    out["labels"] = job.get("labels", [])
    decisions.append(out)

# Emit JSONL (one decision per line) so the bash side can parse easily.
for d in decisions:
    print(json.dumps(d))
PY
) || die "decision pass failed"

if [[ "$dry_run" -eq 1 ]]; then
  printf '%s\n' "$decisions"
  exit 0
fi

# Real mode: for each fire-eligible job, open the issue and update state.
fired=0
total=0
state_changed=0
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  total=$((total + 1))
  fire=$(printf '%s' "$line" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("fire", False))')
  jid=$(printf  '%s' "$line" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("id", ""))')
  if [[ "$fire" != "True" ]]; then
    log "skip $jid: $(printf '%s' "$line" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("reason",""))')"
    continue
  fi

  # Build the issue.
  date_tag=$(date -u +%Y-%m-%d)
  title=$(printf '%s' "$line" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(f\"{d['title']} ({sys.argv[1]})\")" "$date_tag")
  body_file=$(mktemp -t schedule-body-XXXX.md)
  printf '%s' "$line" | python3 -c 'import sys,json; sys.stdout.write(json.loads(sys.stdin.read()).get("body",""))' > "$body_file"
  labels_csv=$(printf '%s' "$line" | python3 -c 'import sys,json; print(",".join(json.loads(sys.stdin.read()).get("labels", [])))')

  if [[ -z "$labels_csv" ]]; then
    log "warning: $jid has no labels — skipping"
    rm -f "$body_file"
    continue
  fi

  log "fire $jid: opening issue \"$title\""
  if ! issue_url=$(gh issue create --title "$title" --body-file "$body_file" --label "$labels_csv" 2>&1); then
    log "FAILED to open issue for $jid: $issue_url"
    rm -f "$body_file"
    continue
  fi
  rm -f "$body_file"

  issue_num=$(printf '%s' "$issue_url" | grep -oE '/issues/[0-9]+' | grep -oE '[0-9]+$' || true)
  log "fired $jid: issue #${issue_num:-?}"
  fired=$((fired + 1))
  state_changed=1

  # Update the local state file in place.
  python3 - "$state_file" "$jid" "$(iso_now)" "${issue_num:-0}" <<'PY'
import json, sys
path, jid, iso, num = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4] or 0)
with open(path) as f:
    state = json.load(f)
state.setdefault("schemaVersion", 1)
state.setdefault("jobs", {})
state["jobs"][jid] = {"lastFiredAt": iso, "lastIssue": num}
with open(path, "w") as f:
    json.dump(state, f, indent=2)
    f.write("\n")
PY
done <<< "$decisions"

# Persist state-file changes back to the state branch.
if [[ "$state_changed" -eq 1 && -n "$state_branch" ]]; then
  body=$(cat "$state_file")
  b64=$(printf '%s' "$body" | b64)
  msg="factory: schedule state ($fired/$total fired)"
  if ! contents_put "$repo" "$state_branch" "schedule-state.json" "$msg" "$b64" "$state_sha" >/dev/null 2>&1; then
    die "failed to write schedule-state.json on $state_branch"
  fi
  log "wrote schedule-state.json on $state_branch"
fi

log "schedule-tick: $fired fired of $total evaluated"
