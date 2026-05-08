#!/usr/bin/env bash
# Detect package-manager ecosystems present in the repo.
#
# Read-only. Prints one JSON object per line on stdout, in a stable
# canonical order (npm, pnpm, yarn, pip, poetry, uv, cargo, go).
# Each object has shape:
#
#   {
#     "ecosystem": "npm|pnpm|yarn|pip|poetry|uv|cargo|go",
#     "manifest":  "<path>",        // e.g. package.json
#     "lockfile":  "<path>|null",   // null when no lockfile present
#     "test":      "<command>"      // suggested test command (best-guess)
#   }
#
# Used by:
#   - the dep-upgrade skill (SKILL.md, .claude/skills/dep-upgrade/)
#   - scripts/test/dep-upgrade-detect-smoke.sh
#
# Usage:
#   scripts/skills/dep-upgrade-detect.sh [--root PATH]
#
# --root defaults to the current working directory. The smoke test
# uses --root to point at synthetic fixture trees.

set -uo pipefail

root="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "unknown arg: $1" >&2
      exit 2 ;;
  esac
done

[[ -d "$root" ]] || { echo "no such root: $root" >&2; exit 2; }

emit() {
  # emit <eco> <manifest> <lockfile|''> <test>
  local eco="$1" manifest="$2" lock="$3" test_cmd="$4"
  python3 - "$eco" "$manifest" "$lock" "$test_cmd" <<'PY'
import json, sys
eco, manifest, lock, test = sys.argv[1:5]
out = {"ecosystem": eco, "manifest": manifest, "lockfile": lock or None, "test": test}
print(json.dumps(out))
PY
}

has() { [[ -e "$root/$1" ]]; }

# Order matters: emit in the canonical order so callers and tests can
# rely on a stable sequence.

# --- JS ecosystems. A repo can in principle have multiple JS lockfiles,
#     but we treat each independently — npm packages a npm-lock, pnpm
#     packages pnpm-lock, etc.
if has package.json; then
  if has package-lock.json; then
    emit npm "package.json" "package-lock.json" "npm test"
  elif has npm-shrinkwrap.json; then
    emit npm "package.json" "npm-shrinkwrap.json" "npm test"
  else
    # package.json without an npm-style lock — still report so the
    # skill can mention it, but with empty lockfile so it'll skip.
    if ! has pnpm-lock.yaml && ! has yarn.lock; then
      emit npm "package.json" "" "npm test"
    fi
  fi
  if has pnpm-lock.yaml; then
    emit pnpm "package.json" "pnpm-lock.yaml" "pnpm test"
  fi
  if has yarn.lock; then
    emit yarn "package.json" "yarn.lock" "yarn test"
  fi
fi

# --- Python ecosystems
# pyproject.toml could be poetry / uv / pep621 / hatch / etc.; we
# disambiguate by looking at the lockfile name.
if has pyproject.toml; then
  if has poetry.lock; then
    emit poetry "pyproject.toml" "poetry.lock" "poetry run pytest -q"
  fi
  if has uv.lock; then
    emit uv "pyproject.toml" "uv.lock" "uv run pytest -q"
  fi
fi

# pip: a pinned requirements file. We accept requirements.txt (the
# canonical pinned name) but only when paired with a *.in (pip-tools)
# OR when the user passes --root to a fixture; otherwise we have no
# way to upgrade reproducibly. Be conservative: report only when an
# `.in` is alongside, so dep-upgrade has something to compile from.
if has requirements.in && has requirements.txt; then
  emit pip "requirements.in" "requirements.txt" "pytest -q"
fi

# --- Rust
if has Cargo.toml && has Cargo.lock; then
  emit cargo "Cargo.toml" "Cargo.lock" "cargo test --all"
fi

# --- Go
if has go.mod; then
  # go.sum is recommended but optional for module resolution
  lock=""
  has go.sum && lock="go.sum"
  emit go "go.mod" "$lock" "go test ./..."
fi
