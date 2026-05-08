#!/usr/bin/env bash
# SessionStart hook
#
# Surfaces, at the top of every session, the few things an orchestrator
# session needs to know before it starts ticking: where state lives, who
# we are, whether credentials look healthy. Output is parsed by humans,
# not machines — keep it short.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
POLICY="$REPO_ROOT/.factory/policy.yml"

emit() { printf '%s\n' "$*"; }

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
    emit "gh auth:        NOT AUTHENTICATED — orchestrator cannot write state."
  fi
else
  emit "gh:             NOT INSTALLED — required for the factory loop."
fi

emit ""
emit "Invariants:"
emit "  - main is PR-only; never push directly."
emit "  - state/ledger writes go through the GitHub API on their own branches."
emit "  - obey .factory/policy.yml (budgets, allowlist, gates)."
emit "  - escalate via stage:escalated + a comment, never silently."
emit ""
emit "To advance the queue: /factory-tick"
