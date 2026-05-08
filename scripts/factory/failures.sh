#!/usr/bin/env bash
# Cluster recent factory failures by reason, station, and WorkItem.
#
# Read-only over `factory/ledger`. Same input shape as metrics.sh:
# walks runs/YYYY/MM/DD/*.json within a rolling window, but keeps
# only Runs whose status is `failure` or `escalated`. Emits either a
# markdown summary or JSON.
#
# Usage:
#   scripts/factory/failures.sh [--days N] [--format md|json] [--ledger-dir PATH] [--top N]
#
# Defaults: --days 7, --format md, --top 5.

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

days=7
format="md"
ledger_dir=""
top=5

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)        days="$2"; shift 2 ;;
    --format)      format="$2"; shift 2 ;;
    --ledger-dir)  ledger_dir="$2"; shift 2 ;;
    --top)         top="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ "$format" =~ ^(md|json)$ ]] || die "invalid --format: $format"
[[ "$days" =~ ^[0-9]+$ ]]      || die "invalid --days: $days"
[[ "$top"  =~ ^[0-9]+$ ]]      || die "invalid --top: $top"

cleanup=""
if [[ -z "$ledger_dir" ]]; then
  ledger_branch=$(policy_ledger_branch); ledger_branch=${ledger_branch:-factory/ledger}
  tmp=$(mktemp -d -t factory-failures-XXXX)
  cleanup="$tmp"
  trap 'rm -rf "$cleanup"' EXIT
  remote_url=$(git config --get remote.origin.url 2>/dev/null) \
    || die "no origin remote; pass --ledger-dir to read from a checkout"
  if ! git clone --quiet --depth 50 --branch "$ledger_branch" \
        --single-branch "$remote_url" "$tmp" 2>/dev/null; then
    die "could not clone $ledger_branch from $remote_url"
  fi
  ledger_dir="$tmp"
fi

[[ -d "$ledger_dir/runs" ]] || die "no runs/ directory under $ledger_dir"

python3 - "$ledger_dir" "$days" "$format" "$top" <<'PY'
import json, sys, datetime, pathlib
from collections import Counter, defaultdict

ledger_dir, days, fmt, top = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
runs_root = pathlib.Path(ledger_dir) / "runs"
now = datetime.datetime.now(datetime.timezone.utc)
since = now - datetime.timedelta(days=days)

KNOWN = {"budget", "lock-stolen", "tool-denied", "ci-failed",
         "review-rejected", "interrupted", "unknown"}

total_runs = 0
failed = []
for path in runs_root.glob("[0-9][0-9][0-9][0-9]/*/*/*.json"):
    try:
        doc = json.loads(path.read_text())
    except Exception:
        continue
    started = doc.get("startedAt")
    if not started:
        continue
    try:
        ts = datetime.datetime.fromisoformat(started.replace("Z", "+00:00"))
    except ValueError:
        continue
    if ts < since:
        continue
    total_runs += 1
    if doc.get("status") in ("failure", "escalated"):
        failed.append((ts, doc))

# Group by reason → station counts, and per-WorkItem.
by_reason = defaultdict(lambda: {"count": 0, "byStation": Counter(), "byStatus": Counter()})
by_workitem = defaultdict(list)

for ts, doc in failed:
    reason = doc.get("failureReason") or "unknown"
    if reason not in KNOWN:
        reason = "unknown"
    station = doc.get("station") or "unknown"
    status  = doc.get("status")  or "unknown"
    by_reason[reason]["count"] += 1
    by_reason[reason]["byStation"][station] += 1
    by_reason[reason]["byStatus"][status] += 1
    wi = doc.get("workItemId")
    if wi:
        by_workitem[wi].append((ts, reason, station, status))

reason_rows = sorted(
    (
        {
            "reason": r,
            "count":  v["count"],
            "byStation": dict(v["byStation"]),
            "byStatus":  dict(v["byStatus"]),
        }
        for r, v in by_reason.items()
    ),
    key=lambda x: (-x["count"], x["reason"]),
)

# Top affected WorkItems by failure count; tie-break by most-recent first.
wi_rows = []
for wi, runs in by_workitem.items():
    runs_sorted = sorted(runs, reverse=True)  # most recent first
    last_ts, last_reason, last_station, last_status = runs_sorted[0]
    wi_rows.append({
        "workItemId":  wi,
        "failures":    len(runs),
        "lastReason":  last_reason,
        "lastStation": last_station,
        "lastStatus":  last_status,
        "lastAt":      last_ts.isoformat(timespec="seconds").replace("+00:00", "Z"),
    })
wi_rows.sort(key=lambda x: (-x["failures"], x["lastAt"]), reverse=False)
# secondary key already applied; ensure descending by failures, ascending by lastAt
wi_rows.sort(key=lambda x: -x["failures"])
wi_rows = wi_rows[:top]

summary = {
    "windowDays":  days,
    "since":       since.isoformat(timespec="seconds").replace("+00:00", "Z"),
    "generatedAt": now.isoformat(timespec="seconds").replace("+00:00", "Z"),
    "totalRuns":   total_runs,
    "failedRuns":  len(failed),
    "byReason":    reason_rows,
    "topWorkItems": wi_rows,
}

if fmt == "json":
    print(json.dumps(summary, indent=2))
    sys.exit(0)

# ---- markdown ----
print(f"# Factory failures — {now.date().isoformat()} (last {days} days)\n")
rate = (len(failed) / total_runs * 100) if total_runs else 0
print(f"_window since {summary['since']} · {len(failed)} failed/escalated of {total_runs} runs ({rate:.0f}%)_\n")

if not failed:
    print("_no failures in window — nothing to cluster_")
    sys.exit(0)

print("## Top reasons\n")
print("| reason | count | stations | statuses |")
print("| --- | ---: | --- | --- |")
for row in reason_rows:
    stations = ", ".join(f"{k}({v})" for k, v in sorted(row["byStation"].items(), key=lambda x: -x[1]))
    statuses = ", ".join(f"{k}({v})" for k, v in sorted(row["byStatus"].items(),  key=lambda x: -x[1]))
    print(f"| {row['reason']} | {row['count']} | {stations} | {statuses} |")

if wi_rows:
    print(f"\n## Top affected WorkItems (top {len(wi_rows)})\n")
    print("| issue | failures | last reason | last station | last at |")
    print("| --- | ---: | --- | --- | --- |")
    for w in wi_rows:
        print(f"| #{w['workItemId']} | {w['failures']} | {w['lastReason']} | {w['lastStation']} | {w['lastAt']} |")
PY
