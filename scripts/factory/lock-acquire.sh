#!/usr/bin/env bash
# Acquire the multi-session lock on the configured state branch.
#
# Writes lock.json with optimistic concurrency on the GitHub Contents
# API. ADR 0003 is the source of truth for the lock semantics.
#
# Outputs the acquired lock as JSON on stdout. Exits 0 on success, 1
# if another live session holds the lock, 2 on transport error.

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

repo=$(repo_slug) || die "could not determine repo slug"
branch=$(policy_state_branch); branch=${branch:-factory/state}
ttl=$(policy_lock_ttl_minutes); ttl=${ttl:-10}

session_id="${CLAUDE_SESSION_ID:-${USER:-unknown}-$(epoch_now)}"
host="${FACTORY_HOST:-local}"
now=$(epoch_now)
expires=$((now + ttl * 60))

# Read current lock if any.
existing=$(contents_get "$repo" "$branch" "lock.json")
existing_sha=""
if [[ -n "$existing" ]]; then
  existing_sha=$(printf '%s' "$existing" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sha",""))')
  body=$(printf '%s' "$existing" | contents_decode)
  expires_at=$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("expiresAt",0))' 2>/dev/null || echo 0)
  holder=$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sessionId",""))' 2>/dev/null || echo "")
  if [[ "$holder" == "$session_id" ]]; then
    log "already hold the lock"
    printf '%s' "$body"
    exit 0
  fi
  if (( expires_at > now )); then
    log "lock held by $holder until epoch $expires_at"
    exit 1
  fi
  log "stealing stale lock from $holder (expired $((now - expires_at))s ago)"
  export FACTORY_LOCK_STOLEN_FROM="$holder"
fi

payload=$(python3 -c '
import json, sys
print(json.dumps({
  "sessionId": sys.argv[1],
  "host":      sys.argv[2],
  "acquiredAt": int(sys.argv[3]),
  "expiresAt":  int(sys.argv[4]),
}, indent=2))
' "$session_id" "$host" "$now" "$expires")

content_b64=$(printf '%s' "$payload" | b64)
msg="factory: acquire lock ($host/$session_id)"

if ! response=$(contents_put "$repo" "$branch" "lock.json" "$msg" "$content_b64" "$existing_sha" 2>&1); then
  log "lock write failed (likely a race): $response"
  exit 1
fi

printf '%s\n' "$payload"
exit 0
