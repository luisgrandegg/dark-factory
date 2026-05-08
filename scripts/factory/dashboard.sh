#!/usr/bin/env bash
# Render the static control-room page from the ledger.
#
# Reads `factory/ledger` (read-only) by reusing scripts/factory/metrics.sh
# and scripts/factory/failures.sh in JSON mode, then renders a single
# self-contained HTML file. No JavaScript, embedded CSS — viewable from
# a local file:// URL or served by any static host.
#
# Usage:
#   scripts/factory/dashboard.sh [--days N] [--ledger-dir PATH] [--out PATH]
#
# Defaults:
#   --days 7
#   --out  .factory/dashboard/index.html
#
# When --ledger-dir is omitted, the script shallow-clones factory/ledger
# into a tmpdir and passes it to the metric scripts (so we clone once,
# not twice).

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
days=7
ledger_dir=""
out="$REPO_ROOT/.factory/dashboard/index.html"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --days)       days="$2"; shift 2 ;;
    --ledger-dir) ledger_dir="$2"; shift 2 ;;
    --out)        out="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ "$days" =~ ^[0-9]+$ ]] || die "invalid --days: $days"

cleanup=""
if [[ -z "$ledger_dir" ]]; then
  ledger_branch=$(policy_ledger_branch); ledger_branch=${ledger_branch:-factory/ledger}
  tmp=$(mktemp -d -t factory-dashboard-XXXX)
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

metrics_json=$("$REPO_ROOT/scripts/factory/metrics.sh"  --ledger-dir "$ledger_dir" --days "$days" --format json)  || die "metrics.sh failed"
failures_json=$("$REPO_ROOT/scripts/factory/failures.sh" --ledger-dir "$ledger_dir" --days "$days" --format json) || die "failures.sh failed"

mkdir -p "$(dirname "$out")"

python3 - "$out" "$metrics_json" "$failures_json" <<'PY'
import json, sys, html, datetime

out_path, metrics_raw, failures_raw = sys.argv[1], sys.argv[2], sys.argv[3]
metrics  = json.loads(metrics_raw)
failures = json.loads(failures_raw)

def esc(x):
    if x is None:
        return "&mdash;"
    return html.escape(str(x))

def pct(v):
    if v is None:
        return "&mdash;"
    return f"{v*100:.0f}%"

def cell_num(v):
    return "&mdash;" if v is None else esc(v)

generated_at = metrics.get("generatedAt", "")
since        = metrics.get("since", "")
window_days  = metrics.get("windowDays", 0)
total_runs   = metrics.get("totalRuns", 0)
failed_runs  = failures.get("failedRuns", 0)
failure_rate = (failed_runs / total_runs * 100) if total_runs else 0.0

# Hero numbers: total runs, failure rate, distinct stations, total tool calls.
station_rows = sorted(metrics.get("stations", {}).items())
total_tool_calls = sum(s.get("toolCalls", 0) for _, s in station_rows)
distinct_stations = len(station_rows)

# Per-station rows
station_html = []
for st, s in station_rows:
    station_html.append(
        "<tr>"
        f"<td>{esc(st)}</td>"
        f"<td class=num>{cell_num(s.get('runs'))}</td>"
        f"<td class=num>{cell_num(s.get('success'))}</td>"
        f"<td class=num>{cell_num(s.get('failure'))}</td>"
        f"<td class=num>{cell_num(s.get('escalated'))}</td>"
        f"<td class=num>{cell_num(s.get('running'))}</td>"
        f"<td class=num>{pct(s.get('successRate'))}</td>"
        f"<td class=num>{cell_num(s.get('p50WallSeconds'))}</td>"
        f"<td class=num>{cell_num(s.get('p95WallSeconds'))}</td>"
        f"<td class=num>{cell_num(s.get('toolCalls'))}</td>"
        "</tr>"
    )

# Failures by reason
reason_html = []
for r in failures.get("byReason", []):
    stations_str = ", ".join(f"{k}({v})" for k, v in sorted(r.get("byStation", {}).items(), key=lambda x: -x[1]))
    statuses_str = ", ".join(f"{k}({v})" for k, v in sorted(r.get("byStatus",  {}).items(), key=lambda x: -x[1]))
    reason_html.append(
        "<tr>"
        f"<td>{esc(r.get('reason'))}</td>"
        f"<td class=num>{cell_num(r.get('count'))}</td>"
        f"<td>{esc(stations_str)}</td>"
        f"<td>{esc(statuses_str)}</td>"
        "</tr>"
    )

# Top affected WorkItems
wi_html = []
for w in failures.get("topWorkItems", []):
    wi_html.append(
        "<tr>"
        f"<td>#{esc(w.get('workItemId'))}</td>"
        f"<td class=num>{cell_num(w.get('failures'))}</td>"
        f"<td>{esc(w.get('lastReason'))}</td>"
        f"<td>{esc(w.get('lastStation'))}</td>"
        f"<td class=num>{esc(w.get('lastAt'))}</td>"
        "</tr>"
    )

doc = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Factory control room &mdash; last {esc(window_days)} days</title>
<style>
  :root {{
    --fg: #0b0d12; --fg-mut: #5a6477; --bg: #f6f7f9;
    --card: #ffffff; --line: #e5e7eb; --accent: #1d4ed8;
    --good: #047857; --warn: #b45309; --bad: #b91c1c;
  }}
  body {{ font: 14px/1.5 -apple-system, system-ui, sans-serif; color: var(--fg); background: var(--bg); margin: 0; padding: 32px; }}
  h1 {{ margin: 0 0 4px; font-size: 22px; }}
  h2 {{ margin: 0 0 12px; font-size: 16px; font-weight: 600; }}
  .sub {{ color: var(--fg-mut); margin-bottom: 24px; }}
  .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-bottom: 24px; }}
  .card {{ background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 16px; }}
  .card .label {{ color: var(--fg-mut); font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; }}
  .card .value {{ font-size: 28px; font-weight: 600; margin-top: 4px; }}
  section {{ background: var(--card); border: 1px solid var(--line); border-radius: 8px; padding: 16px 20px; margin-bottom: 16px; }}
  table {{ border-collapse: collapse; width: 100%; }}
  th, td {{ text-align: left; padding: 8px 10px; border-bottom: 1px solid var(--line); }}
  th {{ font-weight: 600; color: var(--fg-mut); font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; }}
  td.num, th.num {{ text-align: right; font-variant-numeric: tabular-nums; }}
  .empty {{ color: var(--fg-mut); font-style: italic; }}
  footer {{ color: var(--fg-mut); font-size: 12px; margin-top: 24px; }}
</style>
</head>
<body>
  <h1>Factory control room</h1>
  <div class="sub">Last {esc(window_days)} days &middot; window since {esc(since)} &middot; generated {esc(generated_at)}</div>

  <div class="grid">
    <div class="card"><div class="label">Total runs</div><div class="value">{esc(total_runs)}</div></div>
    <div class="card"><div class="label">Failed / escalated</div><div class="value">{esc(failed_runs)}</div></div>
    <div class="card"><div class="label">Failure rate</div><div class="value">{failure_rate:.0f}%</div></div>
    <div class="card"><div class="label">Stations seen</div><div class="value">{esc(distinct_stations)}</div></div>
    <div class="card"><div class="label">Total tool calls</div><div class="value">{esc(total_tool_calls)}</div></div>
  </div>

  <section>
    <h2>Per-station latency &amp; success</h2>
    {('<table><thead><tr><th>station</th><th class=num>runs</th><th class=num>success</th><th class=num>failure</th><th class=num>escalated</th><th class=num>running</th><th class=num>success rate</th><th class=num>p50 wall (s)</th><th class=num>p95 wall (s)</th><th class=num>tool calls</th></tr></thead><tbody>' + ''.join(station_html) + '</tbody></table>') if station_html else '<div class="empty">No runs in window.</div>'}
  </section>

  <section>
    <h2>Top failure reasons</h2>
    {('<table><thead><tr><th>reason</th><th class=num>count</th><th>stations</th><th>statuses</th></tr></thead><tbody>' + ''.join(reason_html) + '</tbody></table>') if reason_html else '<div class="empty">No failures in window.</div>'}
  </section>

  <section>
    <h2>Top affected WorkItems</h2>
    {('<table><thead><tr><th>issue</th><th class=num>failures</th><th>last reason</th><th>last station</th><th class=num>last at</th></tr></thead><tbody>' + ''.join(wi_html) + '</tbody></table>') if wi_html else '<div class="empty">No affected WorkItems in window.</div>'}
  </section>

  <footer>
    Generated by <code>scripts/factory/dashboard.sh</code>. Data read from <code>factory/ledger</code>.
  </footer>
</body>
</html>
"""

with open(out_path, "w") as f:
    f.write(doc)
print(out_path)
PY
