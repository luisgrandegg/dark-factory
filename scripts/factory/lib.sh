#!/usr/bin/env bash
# Shared helpers for factory scripts.
#
# All factory writes to the state and ledger branches go through `gh api`
# against the GitHub Contents API. The orchestrator never holds a working
# copy of those branches (ADR 0002).
#
# Source this file: `. "$(dirname "$0")/lib.sh"`.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
POLICY="$REPO_ROOT/.factory/policy.yml"

# ---------- policy helpers ------------------------------------------------

# yq is optional. Fall back to grep+sed for the two scalars we actually need.
policy_state_branch() {
  if command -v yq >/dev/null 2>&1; then
    yq -r '.state.branch' "$POLICY"
  else
    awk '/^state:/{f=1;next} f && /branch:/{print $2; exit}' "$POLICY"
  fi
}

policy_ledger_branch() {
  if command -v yq >/dev/null 2>&1; then
    yq -r '.ledger.branch' "$POLICY"
  else
    awk '/^ledger:/{f=1;next} f && /branch:/{print $2; exit}' "$POLICY"
  fi
}

policy_lock_ttl_minutes() {
  if command -v yq >/dev/null 2>&1; then
    yq -r '.concurrency.lockTtlMinutes' "$POLICY"
  else
    awk '/lockTtlMinutes:/{print $2; exit}' "$POLICY"
  fi
}

# ---------- repo identity -------------------------------------------------

repo_slug() {
  # Returns "<owner>/<repo>" for the repo whose remote is `origin`.
  gh repo view --json nameWithOwner -q .nameWithOwner
}

# ---------- ids and timestamps -------------------------------------------

# ULIDs without a dependency: timestamp ms in Crockford base32 + randomness.
# Not a perfect ULID, but monotonic-enough and unique-enough for our scale.
ulid() {
  local ts rnd
  ts=$(date +%s%3N 2>/dev/null || python3 -c 'import time;print(int(time.time()*1000))')
  rnd=$(LC_ALL=C tr -dc 'A-Z0-9' </dev/urandom | head -c 16)
  printf '%013d%s' "$ts" "$rnd"
}

iso_now() {
  date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null \
    || python3 -c 'import datetime as d;print(d.datetime.utcnow().isoformat(timespec="milliseconds")+"Z")'
}

epoch_now() { date -u +%s; }

# ---------- contents API CRUD -------------------------------------------

# Get file from a branch. Echoes JSON with .content (base64) and .sha.
# Exits 0 with empty stdout when the file does not exist (404).
contents_get() {
  local repo="$1" branch="$2" path="$3"
  local out status
  out=$(gh api -X GET "repos/$repo/contents/$path?ref=$branch" 2>/dev/null)
  status=$?
  if [[ $status -ne 0 ]]; then
    return 0
  fi
  printf '%s' "$out"
}

# Decode the .content of a contents API response.
contents_decode() {
  python3 -c '
import sys, json, base64
try:
  doc = json.loads(sys.stdin.read())
  sys.stdout.write(base64.b64decode(doc["content"]).decode("utf-8"))
except Exception:
  sys.exit(0)
'
}

# Write a file to a branch. Optimistic: if a `sha` is supplied, the API
# updates that blob; otherwise it creates a new file. A mismatched sha
# returns HTTP 409 and a non-zero exit, which the caller treats as a race.
#
# Args: repo branch path message content_b64 [sha]
contents_put() {
  local repo="$1" branch="$2" path="$3" message="$4" content_b64="$5" sha="${6:-}"
  local payload
  if [[ -n "$sha" ]]; then
    payload=$(python3 -c '
import json,sys
print(json.dumps({"message":sys.argv[1],"content":sys.argv[2],"branch":sys.argv[3],"sha":sys.argv[4]}))
' "$message" "$content_b64" "$branch" "$sha")
  else
    payload=$(python3 -c '
import json,sys
print(json.dumps({"message":sys.argv[1],"content":sys.argv[2],"branch":sys.argv[3]}))
' "$message" "$content_b64" "$branch")
  fi
  printf '%s' "$payload" | gh api -X PUT "repos/$repo/contents/$path" --input -
}

# Delete a file. Args: repo branch path message sha
contents_delete() {
  local repo="$1" branch="$2" path="$3" message="$4" sha="$5"
  local payload
  payload=$(python3 -c '
import json,sys
print(json.dumps({"message":sys.argv[1],"branch":sys.argv[2],"sha":sys.argv[3]}))
' "$message" "$branch" "$sha")
  printf '%s' "$payload" | gh api -X DELETE "repos/$repo/contents/$path" --input -
}

b64() { base64 | tr -d '\n'; }

# ---------- logging ------------------------------------------------------

log() { printf '[%s] %s\n' "$(iso_now)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }
