#!/usr/bin/env bash
# Canonical escalation path for the foreman.
#
# Pulls the WorkItem out of the factory's control by:
#   1. swapping its current `stage:*` label for `stage:escalated`
#   2. adding `needs-human` and (if asked) `escalated`
#   3. assigning a human owner if `--assign <user>` (or the default
#      from policy.yml's `escalation.defaultAssignee`)
#   4. posting a structured comment with reason, detail and Run id
#
# A confused factory state is "stage:escalated + needs-human + a comment
# that describes what you saw" (CLAUDE.md). This script is the only
# blessed way to get there.
#
# Usage:
#   scripts/factory/escalate.sh \
#     --workitem 42 \
#     --reason budget|tool-denied|gated-path|ci-failed|review-rejected|corrupt-state|unknown \
#     [--detail "<one paragraph>"] \
#     [--from stage:plan] \
#     [--run <ulid>] \
#     [--assign <github-login>]
#
# Exits 0 on success, non-zero on transport failure. Idempotent: a
# re-run on an already-escalated WorkItem is a no-op for labels and just
# appends another comment.

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

workitem=""; reason=""; detail=""; from=""; run=""; assign=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --workitem) workitem="$2"; shift 2 ;;
    --reason)   reason="$2"; shift 2 ;;
    --detail)   detail="$2"; shift 2 ;;
    --from)     from="$2"; shift 2 ;;
    --run)      run="$2"; shift 2 ;;
    --assign)   assign="$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$workitem" ]] || die "usage: escalate.sh --workitem <id> --reason <vocab> [--detail ...]"
[[ -n "$reason"   ]] || die "missing --reason (controlled vocabulary)"

# Controlled vocabulary mirrors the ledger schema's failureReason.
case "$reason" in
  budget|tool-denied|gated-path|ci-failed|review-rejected|corrupt-state|secret-leak|interrupted|unknown) ;;
  *) die "reason '$reason' not in controlled vocabulary" ;;
esac

# Default assignee: lookup `escalation.defaultAssignee` in policy.yml if
# the caller didn't supply one. Optional; if neither is set, no assign.
if [[ -z "$assign" ]]; then
  if command -v yq >/dev/null 2>&1; then
    assign=$(yq -r '.escalation.defaultAssignee // ""' "$POLICY")
  else
    assign=$(awk '/^escalation:/{f=1;next} f && /defaultAssignee:/{print $2; exit}' "$POLICY" \
              | tr -d '"')
  fi
fi

# Discover current stage if --from was not supplied.
if [[ -z "$from" ]]; then
  from=$(gh issue view "$workitem" --json labels --jq \
    '[.labels[].name | select(startswith("stage:"))] | first // empty' 2>/dev/null || true)
fi

# Label moves. `gh issue edit` is idempotent for adds and removes.
add_args=(--add-label "stage:escalated" --add-label "needs-human")
rm_args=()
if [[ -n "$from" && "$from" != "stage:escalated" ]]; then
  rm_args+=(--remove-label "$from")
fi
gh issue edit "$workitem" "${add_args[@]}" "${rm_args[@]}" >/dev/null \
  || die "failed to set escalation labels on #$workitem"

if [[ -n "$assign" ]]; then
  gh issue edit "$workitem" --add-assignee "$assign" >/dev/null 2>&1 \
    || log "warning: could not assign $assign (insufficient permission?)"
fi

# Comment.
ts=$(date -u +%Y-%m-%d)
body=$(cat <<EOF
**Escalated — $ts**

- **reason:** \`$reason\`
- **from stage:** \`${from:-unknown}\`
${detail:+- **detail:** $detail}
${assign:+- **assigned:** @$assign}
${run:+- **run id:** \`$run\`}

The factory will not advance this WorkItem further until a human
removes the \`stage:escalated\` and \`needs-human\` labels (and, if
appropriate, restores a \`stage:*\` label that's a legal target from
\`stage:escalated\` per \`.factory/policy.yml\`).

See \`docs/runbook.md\` for the recovery checklist.
EOF
)
gh issue comment "$workitem" --body "$body" >/dev/null \
  || die "failed to post escalation comment on #$workitem"

log "escalated #$workitem ($reason)${assign:+ → @$assign}"
