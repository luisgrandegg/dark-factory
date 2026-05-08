#!/usr/bin/env bash
# Snapshot a station's artefact body to the ledger branch.
#
# Comments on GitHub issues are the canonical mutable surface; this
# snapshot is the immutable audit trail for point-in-time replay
# ("what did plan see when it produced this test plan?"). The path
# mirrors runs/ so the snapshot and its Run record share a date shard.
#
# Usage:
#   scripts/factory/artifact-write.sh \
#     --run-id <ulid> --workitem <id> --kind intake|spec|plan|qa \
#     < body_from_stdin
#
# Writes:
#   artifacts/YYYY/MM/DD/<run-id>.md    on the ledger branch
#
# Prints the relative ledger path on stdout. Idempotent: a re-run with
# the same run-id is a no-op.

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

run_id=""; workitem=""; kind=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-id)   run_id="$2"; shift 2 ;;
    --workitem) workitem="$2"; shift 2 ;;
    --kind)     kind="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$run_id" && -n "$workitem" && -n "$kind" ]] \
  || die "usage: artifact-write.sh --run-id ULID --workitem N --kind intake|spec|plan|qa < body"
[[ "$kind" =~ ^(intake|spec|plan|qa)$ ]] \
  || die "invalid --kind: $kind (expected intake|spec|plan|qa)"

repo=$(repo_slug)               || die "could not determine repo slug"
ledger=$(policy_ledger_branch); ledger=${ledger:-factory/ledger}

day_path=$(date -u +"%Y/%m/%d")
path="artifacts/$day_path/$run_id.md"

# Write-once: if the artifact already exists, succeed without rewriting.
if [[ -n "$(contents_get "$repo" "$ledger" "$path" 2>/dev/null || true)" ]]; then
  printf '%s\n' "$path"
  exit 0
fi

body=$(cat)
[[ -n "$body" ]] || die "empty body on stdin"

now=$(iso_now)
content=$(printf -- '---\nkind: %s\nworkItemId: %s\nrunId: %s\nrecordedAt: %s\n---\n\n%s\n' \
                    "$kind" "$workitem" "$run_id" "$now" "$body")

content_b64=$(printf '%s' "$content" | b64)
msg="factory: artifact $kind run $run_id"

if ! contents_put "$repo" "$ledger" "$path" "$msg" "$content_b64" >/dev/null 2>&1; then
  die "failed to write $path on $ledger"
fi

printf '%s\n' "$path"
