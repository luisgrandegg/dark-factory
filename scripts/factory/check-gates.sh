#!/usr/bin/env bash
# Approval-gate matcher. Reads .factory/policy.yml's `approvalGates` section,
# and matches a list of paths (one per line on stdin) and an optional set of
# labels (comma-separated) against the configured patterns.
#
# Exits 0 with no output → no gate hits.
# Exits 1 with one line per hit on stdout, in the form:
#   path:<path>:<pattern>          (path-pattern hit)
#   label:<label>                  (label gate hit)
#
# Phase 2 enforcement point. Used by:
#   - .github/workflows/integrate.yml (defence in depth at merge time)
#   - .claude/agents/contract-check.md (early stop, before integrate)
#   - scripts/factory/doctor.sh (sanity check)
#
# Usage:
#   gh pr diff "$PR" --name-only | scripts/factory/check-gates.sh [--labels "a,b,c"]

set -uo pipefail
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

labels=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --labels) labels="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,17p' "$0"; exit 0 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -f "$POLICY" ]] || die "$POLICY missing"

# Slurp stdin (changed paths) once.
paths=$(cat)

# Parse approvalGates entries from policy.yml. Without yq, fall back to a
# minimal awk parser that handles the exact shape committed in policy.yml.
gates_yaml() {
  if command -v yq >/dev/null 2>&1; then
    yq -r '
      .approvalGates // []
      | .[]
      | (.pattern // "") as $p
      | (.label // "")   as $l
      | "\($p)|\($l)"
    ' "$POLICY"
  else
    awk '
      /^approvalGates:/ { in_g=1; next }
      in_g && /^[a-z]/  { in_g=0 }                   # next top-level key
      in_g && /^[[:space:]]*-[[:space:]]*pattern:/ {
        line=$0; sub(/.*pattern:[[:space:]]*"?/,"",line); sub(/".*/,"",line)
        cur_p=line; cur_l=""; have=1; next
      }
      in_g && /^[[:space:]]*-[[:space:]]*label:/ {
        line=$0; sub(/.*label:[[:space:]]*"?/,"",line); sub(/".*/,"",line)
        cur_l=line; cur_p=""; have=1; next
      }
      in_g && /reviewer:/ {
        if (have) { printf "%s|%s\n", cur_p, cur_l; have=0 }
      }
    ' "$POLICY"
  fi
}

hits=0
trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# Path patterns: glob match on each changed path. We translate the glob
# minimally — `**` becomes `.*`, `*` becomes `[^/]*`. Sufficient for the
# patterns in policy.yml today.
glob_to_regex() {
  python3 -c '
import sys, re
g = sys.argv[1]
out = ""
i = 0
while i < len(g):
    c = g[i]
    if c == "*":
        if i+1 < len(g) and g[i+1] == "*":
            out += ".*"; i += 2; continue
        out += "[^/]*"
    elif c == "?":
        out += "."
    elif c in ".+()|^$[]{}\\":
        out += re.escape(c)
    elif c == "/":
        out += "/"
    else:
        out += re.escape(c)
    i += 1
print("^" + out + "$")
' "$1"
}

while IFS='|' read -r pat lab; do
  pat=$(printf '%s' "$pat" | trim)
  lab=$(printf '%s' "$lab" | trim)
  if [[ -n "$pat" ]]; then
    re=$(glob_to_regex "$pat")
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      if [[ "$p" =~ $re ]]; then
        printf 'path:%s:%s\n' "$p" "$pat"
        hits=$((hits + 1))
      fi
    done <<<"$paths"
  fi
  if [[ -n "$lab" ]]; then
    if [[ ",$labels," == *",$lab,"* ]]; then
      printf 'label:%s\n' "$lab"
      hits=$((hits + 1))
    fi
  fi
done < <(gates_yaml)

(( hits == 0 )) || exit 1
exit 0
