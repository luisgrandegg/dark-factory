#!/usr/bin/env bash
# SessionStart hook
#
# Two responsibilities, in order:
#
#   1. On Claude Code on the web (CLAUDE_CODE_REMOTE=true): install the
#      tools the factory requires (`gh`, `yq`) if they're missing, and
#      surface the `GITHUB_TOKEN` setup hint when auth isn't configured.
#      Web sandboxes start with no GitHub credentials; the operator
#      should set `GITHUB_TOKEN` (or `GH_TOKEN`) under
#      claude.ai/code → Environments → Environment variables.
#      gh reads either env var automatically.
#
#   2. Always: surface where state lives, who we are, and whether
#      credentials look healthy. Output is parsed by humans, not
#      machines — keep it short.
#
# Idempotent. Safe to re-run. Never fails the session; the real
# preconditions are asserted by scripts/setup.sh and the factory skill.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
POLICY="$REPO_ROOT/.factory/policy.yml"

emit() { printf '%s\n' "$*"; }

# ---------- 1. web bootstrap (gh + yq) -----------------------------------
if [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]; then
  needs=()
  command -v gh >/dev/null 2>&1 || needs+=("gh")
  command -v yq >/dev/null 2>&1 || needs+=("yq")
  if (( ${#needs[@]} > 0 )); then
    emit "session-start: installing ${needs[*]} (first session in this container)…"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${needs[@]}" >/dev/null 2>&1 || true
  fi
fi

# ---------- 2. session header --------------------------------------------

emit "=== dark-factory session ==="

if [[ ! -f "$POLICY" ]]; then
  emit "WARNING: $POLICY missing. Run scripts/setup.sh."
  exit 0
fi

# Best-effort yaml parsing without yq: grep two named scalars.
state_branch=$(grep -E '^[[:space:]]*branch:' "$POLICY" | sed -n '1p' | awk '{print $2}')
ledger_branch=$(grep -E '^[[:space:]]*branch:' "$POLICY" | sed -n '2p' | awk '{print $2}')
emit "state branch:   ${state_branch:-factory/state}"
emit "ledger branch:  ${ledger_branch:-factory/ledger}"

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    emit "gh auth:        ok"
  else
    if [[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]; then
      emit "gh auth:        NOT AUTHENTICATED — set GITHUB_TOKEN under claude.ai/code → Environments → Environment variables."
    else
      emit "gh auth:        NOT AUTHENTICATED — orchestrator cannot write state."
    fi
  fi
else
  emit "gh:             NOT INSTALLED — required for the factory loop."
fi

if ! command -v yq >/dev/null 2>&1; then
  emit "yq:             not installed (setup.sh has a fallback parser; install yq for safety)."
fi

emit ""
emit "Invariants:"
emit "  - main is PR-only; never push directly."
emit "  - state/ledger writes go through the GitHub API on their own branches."
emit "  - obey .factory/policy.yml (budgets, allowlist, gates)."
emit "  - escalate via stage:escalated + a comment, never silently."
emit ""
emit "To advance the queue: /factory-tick"
