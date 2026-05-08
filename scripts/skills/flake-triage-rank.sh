#!/usr/bin/env bash
# Rank workflow runs on the default branch by flake rate.
#
# Read-only. Calls `gh api repos/:owner/:repo/actions/runs` (paginated)
# and emits one JSON object per workflow_name on stdout, sorted by
# flake rate descending. Output shape per line:
#
#   {
#     "workflow":     "<name>",
#     "flakeEvents":  <int>,      # number of (workflow, sha) pairs that flaked
#     "totalRuns":    <int>,      # total runs (any conclusion) in window
#     "flakeRate":    <float>,    # flakeEvents / totalShas
#     "recentSamples": [          # up to 5 most recent flake samples
#       {"sha": "abc1234", "url": "https://...", "attempts": 2}
#     ]
#   }
#
# Definition of "flake event" for a (workflow, head_sha) pair:
#   (a) some run has run_attempt > 1 AND conclusion success, OR
#   (b) the same SHA produced at least one `failure` AND at least
#       one `success` across separate runs (force-rerun without
#       bumping run_attempt).
#
# Usage:
#   scripts/skills/flake-triage-rank.sh \
#     [--lookback 1d|7d|24h|...]   # default 1d
#     [--workflow NAME]             # filter to one workflow
#     [--branch NAME]               # default the repo's default branch
#     [--repo OWNER/NAME]           # default $GH_REPO or `gh repo view`
#     [--from-fixture PATH]         # read runs from a JSON file (no API)
#     [--top N]                     # only emit top N rows
#     [--min-flake-rate F]          # drop rows with rate < F
#
# --from-fixture is for the smoke test. The fixture file shape is
# `{"workflow_runs": [...]}` with the same keys as the GitHub API
# response.

set -uo pipefail

lookback="1d"
workflow_filter=""
branch_filter=""
repo_arg=""
fixture=""
top=""
min_rate=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lookback)        lookback="$2"; shift 2 ;;
    --workflow)        workflow_filter="$2"; shift 2 ;;
    --branch)          branch_filter="$2"; shift 2 ;;
    --repo)            repo_arg="$2"; shift 2 ;;
    --from-fixture)    fixture="$2"; shift 2 ;;
    --top)             top="$2"; shift 2 ;;
    --min-flake-rate)  min_rate="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Translate lookback ("1d", "7d", "24h", "30m") to a since-ISO8601 timestamp.
since=$(python3 - "$lookback" <<'PY'
import sys, re, datetime
spec = sys.argv[1]
m = re.fullmatch(r"(\d+)([dhm])", spec)
if not m:
    sys.stderr.write(f"invalid --lookback: {spec}\n")
    sys.exit(2)
n, unit = int(m.group(1)), m.group(2)
delta = {"d": datetime.timedelta(days=n),
         "h": datetime.timedelta(hours=n),
         "m": datetime.timedelta(minutes=n)}[unit]
since = datetime.datetime.now(datetime.timezone.utc) - delta
print(since.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
) || exit $?

# Pull runs.
runs_json=""
if [[ -n "$fixture" ]]; then
  [[ -f "$fixture" ]] || { echo "no fixture: $fixture" >&2; exit 2; }
  runs_json=$(cat "$fixture")
else
  repo="${repo_arg:-${GH_REPO:-}}"
  if [[ -z "$repo" ]]; then
    repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
      || { echo "could not determine repo (set --repo or GH_REPO)" >&2; exit 2; }
  fi
  branch="$branch_filter"
  if [[ -z "$branch" ]]; then
    branch=$(gh repo view "$repo" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null) \
      || branch="main"
  fi

  # Build query. created>=since lets us bound the window cheaply.
  query="branch=$branch&created=>=$since&per_page=100"
  pages_json=()
  page=1
  while :; do
    body=$(gh api "repos/$repo/actions/runs?$query&page=$page" 2>/dev/null) || {
      echo "gh api failed (rate limit? auth?)" >&2; exit 2;
    }
    pages_json+=("$body")
    count=$(printf '%s' "$body" | python3 -c 'import sys,json; print(len(json.loads(sys.stdin.read()).get("workflow_runs", [])))')
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
    [[ "$page" -gt 10 ]] && break  # safety cap: 1000 runs/window is plenty
  done
  # Merge pages into a single workflow_runs array.
  runs_json=$(python3 - "${pages_json[@]}" <<'PY'
import sys, json
runs = []
for p in sys.argv[1:]:
    runs.extend(json.loads(p).get("workflow_runs", []))
print(json.dumps({"workflow_runs": runs}))
PY
)
fi

# Aggregate.
python3 - "$runs_json" "${workflow_filter}" "${top:-0}" "${min_rate:-0}" <<'PY'
import sys, json
data = json.loads(sys.argv[1])
filt_workflow = sys.argv[2] or None
top_n        = int(sys.argv[3] or 0)
min_rate     = float(sys.argv[4] or 0)

runs = data.get("workflow_runs", [])
by_wf = {}
for r in runs:
    wf = r.get("name") or r.get("workflow_id") or "<unknown>"
    if filt_workflow and wf != filt_workflow:
        continue
    by_wf.setdefault(wf, []).append(r)

rows = []
for wf, wf_runs in by_wf.items():
    by_sha = {}
    for r in wf_runs:
        by_sha.setdefault(r.get("head_sha", ""), []).append(r)

    flake_events = 0
    samples = []
    for sha, sha_runs in by_sha.items():
        conclusions = {(rr.get("conclusion") or "") for rr in sha_runs}
        attempts    = max((rr.get("run_attempt", 1) or 1) for rr in sha_runs)
        rerun_succeeded = any(
            (rr.get("run_attempt", 1) or 1) > 1
            and rr.get("conclusion") == "success"
            for rr in sha_runs
        )
        force_rerun = ("failure" in conclusions and "success" in conclusions)
        if rerun_succeeded or force_rerun:
            flake_events += 1
            # Pick the most recent run for the URL.
            latest = sorted(sha_runs, key=lambda x: x.get("created_at", ""), reverse=True)[0]
            samples.append({
                "sha":      (sha or "")[:7],
                "url":      latest.get("html_url", ""),
                "attempts": attempts,
                "_created": latest.get("created_at", ""),
            })

    total_shas = len(by_sha)
    rate = (flake_events / total_shas) if total_shas else 0.0
    samples.sort(key=lambda s: s["_created"], reverse=True)
    for s in samples:
        s.pop("_created", None)
    rows.append({
        "workflow":      wf,
        "flakeEvents":   flake_events,
        "totalRuns":     len(wf_runs),
        "flakeRate":     round(rate, 4),
        "recentSamples": samples[:5],
    })

rows.sort(key=lambda r: (r["flakeRate"], r["flakeEvents"]), reverse=True)
if min_rate > 0:
    rows = [r for r in rows if r["flakeRate"] >= min_rate]
if top_n > 0:
    rows = rows[:top_n]

for r in rows:
    print(json.dumps(r))
PY
