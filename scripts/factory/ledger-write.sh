#!/usr/bin/env bash
# Write a Run record to the ledger branch.
#
# Usage:
#   ledger-write.sh start  --workitem 42 --station intake --agent subagent:intake [--parent <ulid>]
#   ledger-write.sh end    --id <ulid> --status success [--reason ...] [--tool-calls N] [--wall-seconds N] [--from <label> --to <label>]
#
# `start` prints the new ULID on stdout; pass it back to `end`.
#
# Both invocations write to:
#   runs/YYYY/MM/DD/<ulid>.json    (replaced atomically using the prior sha)
#
# `end` also appends a one-line summary to runs/by-workitem/<id>.jsonl
# for cheap per-WorkItem lookup.

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

mode="${1:-}"; shift || true
[[ "$mode" =~ ^(start|end)$ ]] || die "usage: ledger-write.sh start|end ..."

# argv parsing
workitem=""; station=""; agent=""; parent=""
id=""; status=""; reason=""; tool_calls=0; wall_seconds=0
label_from=""; label_to=""
files_touched=""; pr=""; branch_ref=""; artifact_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workitem) workitem="$2"; shift 2 ;;
    --station)  station="$2"; shift 2 ;;
    --agent)    agent="$2"; shift 2 ;;
    --parent)   parent="$2"; shift 2 ;;
    --id)       id="$2"; shift 2 ;;
    --status)   status="$2"; shift 2 ;;
    --reason)   reason="$2"; shift 2 ;;
    --tool-calls) tool_calls="$2"; shift 2 ;;
    --wall-seconds) wall_seconds="$2"; shift 2 ;;
    --from)     label_from="$2"; shift 2 ;;
    --to)       label_to="$2"; shift 2 ;;
    --pr)       pr="$2"; shift 2 ;;
    --branch)   branch_ref="$2"; shift 2 ;;
    --files)    files_touched="$2"; shift 2 ;;  # comma-separated
    --artifact) artifact_path="$2"; shift 2 ;;  # ledger-relative artifact snapshot path
    *) die "unknown arg: $1" ;;
  esac
done

repo=$(repo_slug) || die "could not determine repo slug"
ledger=$(policy_ledger_branch); ledger=${ledger:-factory/ledger}
host="${FACTORY_HOST:-local}"
session_id="${CLAUDE_SESSION_ID:-${USER:-unknown}}"

if [[ "$mode" == "start" ]]; then
  [[ -n "$workitem" && -n "$station" && -n "$agent" ]] \
    || die "start needs --workitem --station --agent"
  id=$(ulid)
fi

# YYYY/MM/DD path is fixed once; on `end` we recover the date from the ULID's
# embedded timestamp by asking the caller to pass the same ULID and re-deriving.
# Simpler: just use today's UTC date for both calls. ULIDs spanning midnight
# would mis-shard but the impact is cosmetic.
day_path=$(date -u +"%Y/%m/%d")
path="runs/$day_path/$id.json"

# Read existing file (only relevant on `end`).
existing=$(contents_get "$repo" "$ledger" "$path" || true)
existing_sha=""
existing_doc='{}'
if [[ -n "$existing" ]]; then
  existing_sha=$(printf '%s' "$existing" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sha",""))')
  existing_doc=$(printf '%s' "$existing" | contents_decode)
fi

now=$(iso_now)

doc=$(python3 - "$mode" "$id" "$workitem" "$station" "$agent" "$host" "$session_id" \
                 "$parent" "$status" "$reason" "$tool_calls" "$wall_seconds" \
                 "$label_from" "$label_to" "$pr" "$branch_ref" "$files_touched" \
                 "$artifact_path" "$now" "$existing_doc" <<'PY'
import json, sys
mode, id, wi, station, agent, host, sess, parent, status, reason, tc, ws, lf, lt, pr, br, files, artifact, now, existing = sys.argv[1:]
try:
    base = json.loads(existing) if existing.strip() else {}
except Exception:
    base = {}
doc = {
    "schemaVersion": 1,
    "id": id,
    "workItemId": int(wi) if wi else base.get("workItemId"),
    "station":    station or base.get("station"),
    "agent":      agent or base.get("agent"),
    "host":       host or base.get("host"),
    "sessionId":  sess or base.get("sessionId"),
    "parentRunId": parent or base.get("parentRunId") or None,
    "startedAt":  base.get("startedAt") or now,
    "endedAt":    base.get("endedAt"),
    "status":     base.get("status", "running"),
    "failureReason": base.get("failureReason"),
    "artifacts": base.get("artifacts", {
        "filesTouched": [], "branch": None, "pr": None, "comments": [],
        "snapshot": None,
    }),
    "usage": base.get("usage", {
        "tokensIn": None, "tokensOut": None, "wallSeconds": 0,
        "toolCalls": 0, "costUsd": None,
    }),
    "labelTransition": base.get("labelTransition"),
}
doc["artifacts"].setdefault("snapshot", None)
if mode == "start":
    doc["status"] = "running"
    doc["startedAt"] = now
    doc["endedAt"] = None
else:
    doc["endedAt"] = now
    if status: doc["status"] = status
    if reason: doc["failureReason"] = reason
    try: doc["usage"]["toolCalls"] = int(tc) if tc else doc["usage"]["toolCalls"]
    except: pass
    try: doc["usage"]["wallSeconds"] = int(ws) if ws else doc["usage"]["wallSeconds"]
    except: pass
    if lf or lt:
        doc["labelTransition"] = {"from": lf or None, "to": lt or None}
    if pr: doc["artifacts"]["pr"] = pr
    if br: doc["artifacts"]["branch"] = br
    if files:
        doc["artifacts"]["filesTouched"] = [f for f in files.split(",") if f]
    if artifact:
        doc["artifacts"]["snapshot"] = artifact
print(json.dumps(doc, indent=2))
PY
)

content_b64=$(printf '%s' "$doc" | b64)
msg="factory: $mode run $id ($station)"

if ! contents_put "$repo" "$ledger" "$path" "$msg" "$content_b64" "$existing_sha" >/dev/null 2>&1; then
  die "failed to write $path on $ledger"
fi

if [[ "$mode" == "end" ]]; then
  # Roll today's usage into state/budget.json so the per-day kill-switch
  # has a cheap O(1) check (Phase 2). Best-effort: a failed roll-up logs
  # but does not fail the Run.
  state_branch=$(policy_state_branch); state_branch=${state_branch:-factory/state}
  bdoc=$(contents_get "$repo" "$state_branch" "budget.json" || true)
  bsha=""; bbody=""
  if [[ -n "$bdoc" ]]; then
    bsha=$(printf '%s' "$bdoc" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sha",""))')
    bbody=$(printf '%s' "$bdoc" | contents_decode)
  fi
  rollup=$(python3 - "$bbody" "$tool_calls" "$wall_seconds" <<'PY'
import sys, json, datetime
body, tc, ws = sys.argv[1], int(sys.argv[2] or 0), int(sys.argv[3] or 0)
try:
    doc = json.loads(body) if body.strip() else {}
except Exception:
    doc = {}
day = datetime.datetime.utcnow().strftime("%Y-%m-%d")
days = doc.setdefault("days", {})
d = days.setdefault(day, {"tokens": 0, "toolCalls": 0, "wallMinutes": 0})
d["toolCalls"] = int(d.get("toolCalls", 0) or 0) + tc
# wallSeconds → wallMinutes, rounded.
d["wallMinutes"] = int(d.get("wallMinutes", 0) or 0) + (ws // 60)
# Trim to last 14 days to keep budget.json bounded.
for old in sorted(days)[:-14]:
    days.pop(old, None)
doc["updatedAt"] = datetime.datetime.utcnow().isoformat(timespec="seconds") + "Z"
print(json.dumps(doc, indent=2))
PY
)
  rb64=$(printf '%s\n' "$rollup" | b64)
  contents_put "$repo" "$state_branch" "budget.json" "factory: budget rollup ($id)" "$rb64" "$bsha" >/dev/null 2>&1 \
    || log "warning: budget.json roll-up failed"

  # Append to per-workitem index. JSONL keeps appends commutative.
  index_path="runs/by-workitem/$workitem.jsonl"
  if [[ -z "$workitem" ]]; then
    workitem=$(printf '%s' "$doc" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("workItemId",""))')
    index_path="runs/by-workitem/$workitem.jsonl"
  fi
  idx_existing=$(contents_get "$repo" "$ledger" "$index_path" || true)
  idx_sha=""
  idx_body=""
  if [[ -n "$idx_existing" ]]; then
    idx_sha=$(printf '%s' "$idx_existing" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sha",""))')
    idx_body=$(printf '%s' "$idx_existing" | contents_decode)
  fi
  line=$(python3 -c '
import sys, json
d = json.loads(sys.argv[1])
print(json.dumps({
  "id": d["id"], "station": d["station"], "status": d["status"],
  "endedAt": d["endedAt"], "pr": d["artifacts"].get("pr"),
}))
' "$doc")
  new_idx="${idx_body:+$idx_body
}$line"
  idx_b64=$(printf '%s\n' "$new_idx" | b64)
  contents_put "$repo" "$ledger" "$index_path" "factory: index $id" "$idx_b64" "$idx_sha" >/dev/null 2>&1 || \
    log "warning: index append failed for $index_path"
fi

printf '%s\n' "$id"
