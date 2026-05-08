#!/usr/bin/env bash
# scripts/doctor.sh — diagnose a dark-factory installation.
#
# Walks the top failure modes that have actually broken the factory in
# practice (or the equivalent in Phase 2 design intent) and prints a
# verdict per check. Exit code is the count of failures, capped at 1.
#
# Usage:
#   scripts/doctor.sh             # human-readable
#   scripts/doctor.sh --quick     # skip API roundtrips
#   scripts/doctor.sh --json      # machine-readable; one object per check
#
# Read-only: doctor never mutates state, never pushes, never edits
# labels. Recovery is up to the operator (see docs/runbook.md).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$REPO_ROOT"
POLICY=".factory/policy.yml"

quick=0; json=0
for a in "$@"; do
  case "$a" in
    --quick) quick=1 ;;
    --json)  json=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$a" >&2; exit 1 ;;
  esac
done

fails=0
emit() {
  local status="$1" name="$2" detail="$3"
  if (( json )); then
    python3 -c '
import sys, json
print(json.dumps({"check": sys.argv[1], "status": sys.argv[2], "detail": sys.argv[3]}))
' "$name" "$status" "$detail"
  else
    case "$status" in
      ok)   printf '\033[32m✓\033[0m  %-30s %s\n' "$name" "$detail" ;;
      warn) printf '\033[33m!\033[0m  %-30s %s\n' "$name" "$detail" ;;
      fail) printf '\033[31m✗\033[0m  %-30s %s\n' "$name" "$detail"; fails=$((fails+1)) ;;
    esac
  fi
}

# ---- 0. policy file present --------------------------------------------
if [[ ! -f "$POLICY" ]]; then
  emit fail "policy.yml" "missing — run scripts/setup.sh"
  exit 1
fi
emit ok "policy.yml" "present"

# Source lib helpers (defines repo_slug, contents_get, etc).
. scripts/factory/lib.sh 2>/dev/null || {
  emit fail "lib.sh" "could not source scripts/factory/lib.sh"
  exit 1
}

# ---- 1. binaries -------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
have python3 && emit ok "python3"   "$(python3 -c 'import sys;print(sys.version.split()[0])')" \
              || emit fail "python3" "not on PATH"
have git     && emit ok "git"       "$(git --version | awk '{print $3}')" \
              || emit fail "git"     "not on PATH"
if have gh; then
  if gh auth status >/dev/null 2>&1; then
    user=$(gh api user --jq .login 2>/dev/null || echo "?")
    emit ok "gh"       "authenticated as $user"
  else
    emit fail "gh"     "installed but not authenticated (run: gh auth login)"
  fi
else
  emit fail "gh"       "not installed (https://cli.github.com)"
fi
have yq      && emit ok "yq (optional)"  "$(yq --version 2>/dev/null | awk '{print $NF}')" \
              || emit warn "yq (optional)" "absent — falling back to awk parser"

# ---- 2. settings.json validity ----------------------------------------
if python3 -c "import json; json.load(open('.claude/settings.json'))" 2>/dev/null; then
  emit ok "settings.json" "parses as JSON"
else
  emit fail "settings.json" "does not parse as JSON"
fi

# ---- 3. policy.yml validity -------------------------------------------
if python3 -c "import yaml; yaml.safe_load(open('.factory/policy.yml'))" 2>/dev/null; then
  emit ok "policy.yml syntax" "parses as YAML"
else
  if have yq && yq '.' "$POLICY" >/dev/null 2>&1; then
    emit ok "policy.yml syntax" "parses (via yq)"
  else
    emit warn "policy.yml syntax" "could not validate (PyYAML missing); awk parsers will still work"
  fi
fi

# ---- 4. hook scripts executable ---------------------------------------
for hook in .claude/hooks/session-start.sh .claude/hooks/pre-tool-bash.sh; do
  if [[ -x "$hook" ]]; then
    emit ok "hook" "$hook"
  elif [[ -f "$hook" ]]; then
    emit fail "hook" "$hook is not executable (chmod +x $hook)"
  else
    emit fail "hook" "$hook missing"
  fi
done

# Pre-tool-bash hook self-test: feed a known-bad command, expect exit 2.
if have bash && [[ -x .claude/hooks/pre-tool-bash.sh ]]; then
  out=$(printf '%s' '{"command":"FAKE_test git reset --hard HEAD"}' \
        | bash .claude/hooks/pre-tool-bash.sh 2>&1; echo "[exit=$?]")
  if [[ "$out" == *"[exit=2]"* ]]; then
    emit ok "pre-tool-bash self-test" "blocks destructive ops"
  else
    emit fail "pre-tool-bash self-test" "did NOT block 'git reset --hard' — patterns broken"
  fi
fi

# ---- 5. helper scripts executable -------------------------------------
for s in scripts/factory/lock-acquire.sh scripts/factory/lock-release.sh \
         scripts/factory/ledger-write.sh scripts/factory/check-gates.sh \
         scripts/factory/budget-check.sh scripts/factory/escalate.sh \
         scripts/setup.sh; do
  if [[ -x "$s" ]]; then
    emit ok "script" "$s"
  elif [[ -f "$s" ]]; then
    emit fail "script" "$s is not executable"
  else
    emit fail "script" "$s missing"
  fi
done

(( quick )) && { exit $(( fails > 0 ? 1 : 0 )); }

# ---- 6. live state via gh API -----------------------------------------
if ! have gh || ! gh auth status >/dev/null 2>&1; then
  emit warn "live checks" "skipping (no gh auth) — re-run after 'gh auth login'"
  exit $(( fails > 0 ? 1 : 0 ))
fi

repo=$(repo_slug 2>/dev/null || echo "")
if [[ -z "$repo" ]]; then
  emit fail "repo slug" "could not determine; is origin a GitHub remote?"
  exit 1
fi
emit ok "repo" "$repo"

state_branch=$(policy_state_branch); state_branch=${state_branch:-factory/state}
ledger_branch=$(policy_ledger_branch); ledger_branch=${ledger_branch:-factory/ledger}

for b in "$state_branch" "$ledger_branch"; do
  if gh api "repos/$repo/branches/$b" >/dev/null 2>&1; then
    emit ok "branch" "$b exists"
  else
    emit fail "branch" "$b missing — run scripts/setup.sh"
  fi
done

# Lock health: a lock with expiresAt in the past is stale.
lock_doc=$(contents_get "$repo" "$state_branch" "lock.json" 2>/dev/null || true)
if [[ -z "$lock_doc" ]]; then
  emit ok "lock" "free"
else
  body=$(printf '%s' "$lock_doc" | contents_decode)
  exp=$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("expiresAt",0))' 2>/dev/null || echo 0)
  holder=$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sessionId",""))' 2>/dev/null || echo "")
  now=$(epoch_now)
  if (( exp > now )); then
    emit ok "lock" "held by $holder until epoch $exp ($((exp-now))s remaining)"
  else
    emit warn "lock" "STALE: $holder, expired $((now-exp))s ago — next tick will steal it"
  fi
fi

# Budget rollup readability.
b_doc=$(contents_get "$repo" "$state_branch" "budget.json" 2>/dev/null || true)
if [[ -z "$b_doc" ]]; then
  emit ok "budget.json" "absent (no runs yet)"
else
  if printf '%s' "$b_doc" | contents_decode | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null; then
    emit ok "budget.json" "parses"
  else
    emit fail "budget.json" "does not parse — delete on $state_branch and let next run rebuild"
  fi
fi

# Required labels present.
missing=()
for lbl in stage:queued stage:intake stage:spec stage:plan stage:implement \
           stage:qa stage:integrate stage:done stage:rejected stage:escalated \
           needs-human escalated factory:smoke priority:p0 priority:p1 priority:p2 priority:p3; do
  gh api "repos/$repo/labels/$(printf '%s' "$lbl" | sed 's/:/%3A/g')" >/dev/null 2>&1 \
    || missing+=("$lbl")
done
if (( ${#missing[@]} == 0 )); then
  emit ok "labels" "all required labels present"
else
  emit fail "labels" "missing: ${missing[*]} — re-run scripts/setup.sh"
fi

# Workflows.
for wf in ci.yml integrate.yml secret-scan.yml; do
  if [[ -f ".github/workflows/$wf" ]]; then
    emit ok "workflow" "$wf"
  else
    emit fail "workflow" "$wf missing"
  fi
done

# Multiple stage labels on any open issue (corrupt state).
corrupt=$(gh issue list --state open --limit 100 \
          --json number,labels \
          --jq '
            map({
              n: .number,
              stages: ([.labels[].name | select(startswith("stage:"))])
            })
            | map(select(.stages | length > 1))
            | map("#" + (.n|tostring) + ": " + (.stages | join(",")))
            | join("; ")
          ' 2>/dev/null || echo "")
if [[ -z "$corrupt" || "$corrupt" == "null" ]]; then
  emit ok "stage labels" "no issue holds multiple stage:* labels"
else
  emit fail "stage labels" "corrupt state: $corrupt"
fi

exit $(( fails > 0 ? 1 : 0 ))
