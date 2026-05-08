#!/usr/bin/env bash
# Release the multi-session lock by deleting lock.json from the state
# branch. Idempotent: a missing file is treated as success. Refuses to
# delete a lock held by a different session unless FACTORY_FORCE=1.

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

repo=$(repo_slug) || die "could not determine repo slug"
branch=$(policy_state_branch); branch=${branch:-factory/state}
session_id="${CLAUDE_SESSION_ID:-${USER:-unknown}-$(epoch_now)}"

existing=$(contents_get "$repo" "$branch" "lock.json")
if [[ -z "$existing" ]]; then
  log "no lock to release"
  exit 0
fi

sha=$(printf '%s' "$existing" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sha",""))')
holder=$(printf '%s' "$existing" | contents_decode | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sessionId",""))' 2>/dev/null || echo "")

if [[ "$holder" != "$session_id" && "${FACTORY_FORCE:-0}" != "1" ]]; then
  log "refusing to release a lock held by $holder (set FACTORY_FORCE=1 to override)"
  exit 1
fi

if ! contents_delete "$repo" "$branch" "lock.json" "factory: release lock" "$sha" >/dev/null 2>&1; then
  log "lock delete failed"
  exit 2
fi

log "lock released"
