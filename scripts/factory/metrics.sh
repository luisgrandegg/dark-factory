#!/usr/bin/env bash
# Aggregate per-station latency and success metrics from the ledger.
#
# Read-only over `factory/ledger`. Fetches the branch into a tmpdir
# (operators may also `git fetch origin factory/ledger && git log` for
# the same view — see ADR 0002). Walks runs/YYYY/MM/DD/*.json within a
# rolling window and prints either a markdown summary or JSON.
#
# Usage:
#   scripts/factory/metrics.sh [--days N] [--format md|json] [--ledger-dir PATH]
#
# Defaults: --days 7, --format md.
#
# When --ledger-dir is provided, the script reads from that directory
# directly (used by tests); otherwise it shallow-fetches the ledger
# branch into a tmpdir which is cleaned up on exit.

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

days=7
format="md"
ledger_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)        days="$2"; shift 2 ;;
    --format)      format="$2"; shift 2 ;;
    --ledger-dir)  ledger_dir="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,15p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ "$format" =~ ^(md|json)$ ]] || die "invalid --format: $format"
[[ "$days" =~ ^[0-9]+$ ]]      || die "invalid --days: $days"

# Materialise the ledger if the caller didn't provide one.
cleanup=""
if [[ -z "$ledger_dir" ]]; then
  ledger_branch=$(policy_ledger_branch); ledger_branch=${ledger_branch:-factory/ledger}
  tmp=$(mktemp -d -t factory-metrics-XXXX)
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

python3 - "$ledger_dir" "$days" "$format" <<'PY'
import json, os, sys, datetime, statistics, pathlib

ledger_dir, days, fmt = sys.argv[1], int(sys.argv[2]), sys.argv[3]
runs_root = pathlib.Path(ledger_dir) / "runs"
now = datetime.datetime.now(datetime.timezone.utc)
since = now - datetime.timedelta(days=days)

# Walk only runs/YYYY/MM/DD/*.json (skip by-workitem/*.jsonl).
records = []
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
    records.append(doc)

def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1)))))
    return s[k]

stations = {}
for r in records:
    st = r.get("station") or "unknown"
    s = stations.setdefault(st, {
        "runs": 0, "success": 0, "failure": 0, "escalated": 0, "running": 0,
        "wallSecondsSamples": [], "toolCalls": 0,
    })
    s["runs"] += 1
    status = r.get("status", "running")
    if status in s:
        s[status] += 1
    usage = r.get("usage") or {}
    ws = usage.get("wallSeconds")
    if isinstance(ws, (int, float)) and r.get("endedAt"):
        s["wallSecondsSamples"].append(int(ws))
    tc = usage.get("toolCalls")
    if isinstance(tc, int):
        s["toolCalls"] += tc

summary = {
    "windowDays": days,
    "since": since.isoformat(timespec="seconds").replace("+00:00", "Z"),
    "generatedAt": now.isoformat(timespec="seconds").replace("+00:00", "Z"),
    "totalRuns": len(records),
    "stations": {},
}
for st, s in sorted(stations.items()):
    samples = s.pop("wallSecondsSamples")
    completed = s["success"] + s["failure"] + s["escalated"]
    summary["stations"][st] = {
        "runs":          s["runs"],
        "success":       s["success"],
        "failure":       s["failure"],
        "escalated":     s["escalated"],
        "running":       s["running"],
        "successRate":   round(s["success"] / completed, 3) if completed else None,
        "p50WallSeconds": pct(samples, 50),
        "p95WallSeconds": pct(samples, 95),
        "toolCalls":     s["toolCalls"],
    }

if fmt == "json":
    print(json.dumps(summary, indent=2))
    sys.exit(0)

# Markdown
print(f"# Factory metrics — {now.date().isoformat()} (last {days} days)\n")
print(f"_window since {summary['since']} · {summary['totalRuns']} runs_\n")
if not summary["stations"]:
    print("_no runs in window_")
    sys.exit(0)
print("| station | runs | success | failure | escalated | running | success rate | p50 wall (s) | p95 wall (s) | tool calls |")
print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for st, s in summary["stations"].items():
    sr = "—" if s["successRate"] is None else f"{s['successRate']*100:.0f}%"
    p50 = "—" if s["p50WallSeconds"] is None else str(s["p50WallSeconds"])
    p95 = "—" if s["p95WallSeconds"] is None else str(s["p95WallSeconds"])
    print(f"| {st} | {s['runs']} | {s['success']} | {s['failure']} | {s['escalated']} | {s['running']} | {sr} | {p50} | {p95} | {s['toolCalls']} |")
PY
