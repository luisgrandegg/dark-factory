#!/usr/bin/env bash
# Smoke test for scripts/skills/dep-upgrade-detect.sh.
#
# Builds synthetic fixture trees per ecosystem and asserts the detector
# emits the expected JSON lines in canonical order.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/skills/dep-upgrade-detect.sh"
[[ -x "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

tmp=$(mktemp -d -t dep-upgrade-smoke-XXXX)
trap 'rm -rf "$tmp"' EXIT

fails=0
check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$label" "$expected" "$actual"
    fails=$((fails + 1))
  fi
}

ecos() {
  python3 -c '
import sys, json
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    print(json.loads(line)["ecosystem"])
' < <(printf '%s' "$1")
}

field() {
  python3 -c '
import sys, json
target_eco, key = sys.argv[1], sys.argv[2]
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d["ecosystem"] == target_eco:
        v = d.get(key)
        print("" if v is None else v)
        break
' "$2" "$3" < <(printf '%s' "$1")
}

# Case 1: empty repo → no output
mkdir -p "$tmp/empty"
out=$("$SCRIPT" --root "$tmp/empty")
check "empty.no-output" "$out" ""

# Case 2: npm only (package.json + package-lock.json)
mkdir -p "$tmp/npm-only"
echo '{}' > "$tmp/npm-only/package.json"
echo '{}' > "$tmp/npm-only/package-lock.json"
out=$("$SCRIPT" --root "$tmp/npm-only")
check "npm.ecosystems"      "$(ecos "$out")"                    "npm"
check "npm.lockfile"        "$(field "$out" npm lockfile)"      "package-lock.json"
check "npm.test"            "$(field "$out" npm test)"          "npm test"

# Case 3: package.json with no JS lockfile → npm with null lockfile
mkdir -p "$tmp/no-lock"
echo '{}' > "$tmp/no-lock/package.json"
out=$("$SCRIPT" --root "$tmp/no-lock")
check "no-lock.ecosystems"  "$(ecos "$out")"                    "npm"
check "no-lock.lockfile"    "$(field "$out" npm lockfile)"      ""

# Case 4: pnpm + npm coexist (multi-lockfile repo)
mkdir -p "$tmp/multi-js"
echo '{}' > "$tmp/multi-js/package.json"
echo '{}' > "$tmp/multi-js/package-lock.json"
touch     "$tmp/multi-js/pnpm-lock.yaml"
out=$("$SCRIPT" --root "$tmp/multi-js")
check "multi-js.ecosystems" "$(ecos "$out" | tr '\n' ',')"      "npm,pnpm,"

# Case 5: yarn classic
mkdir -p "$tmp/yarn"
echo '{}' > "$tmp/yarn/package.json"
touch     "$tmp/yarn/yarn.lock"
out=$("$SCRIPT" --root "$tmp/yarn")
# yarn.lock means the npm path takes the "no JS lockfile" branch and
# is suppressed; we should see only yarn.
check "yarn.ecosystems"     "$(ecos "$out" | tr '\n' ',')"      "yarn,"
check "yarn.lockfile"       "$(field "$out" yarn lockfile)"     "yarn.lock"

# Case 6: poetry
mkdir -p "$tmp/poetry"
touch "$tmp/poetry/pyproject.toml" "$tmp/poetry/poetry.lock"
out=$("$SCRIPT" --root "$tmp/poetry")
check "poetry.ecosystems"   "$(ecos "$out")"                    "poetry"
check "poetry.test"         "$(field "$out" poetry test)"       "poetry run pytest -q"

# Case 7: uv
mkdir -p "$tmp/uv"
touch "$tmp/uv/pyproject.toml" "$tmp/uv/uv.lock"
out=$("$SCRIPT" --root "$tmp/uv")
check "uv.ecosystems"       "$(ecos "$out")"                    "uv"
check "uv.test"             "$(field "$out" uv test)"           "uv run pytest -q"

# Case 8: pip-tools (requirements.in + requirements.txt)
mkdir -p "$tmp/pip"
touch "$tmp/pip/requirements.in" "$tmp/pip/requirements.txt"
out=$("$SCRIPT" --root "$tmp/pip")
check "pip.ecosystems"      "$(ecos "$out")"                    "pip"
check "pip.manifest"        "$(field "$out" pip manifest)"      "requirements.in"

# Case 9: requirements.txt without .in is NOT detected (no reproducible source)
mkdir -p "$tmp/pip-bare"
touch "$tmp/pip-bare/requirements.txt"
out=$("$SCRIPT" --root "$tmp/pip-bare")
check "pip-bare.no-output"  "$out"                              ""

# Case 10: cargo
mkdir -p "$tmp/cargo"
touch "$tmp/cargo/Cargo.toml" "$tmp/cargo/Cargo.lock"
out=$("$SCRIPT" --root "$tmp/cargo")
check "cargo.ecosystems"    "$(ecos "$out")"                    "cargo"
check "cargo.test"          "$(field "$out" cargo test)"        "cargo test --all"

# Case 11: go with go.sum
mkdir -p "$tmp/go-sum"
touch "$tmp/go-sum/go.mod" "$tmp/go-sum/go.sum"
out=$("$SCRIPT" --root "$tmp/go-sum")
check "go-sum.ecosystems"   "$(ecos "$out")"                    "go"
check "go-sum.lockfile"     "$(field "$out" go lockfile)"       "go.sum"

# Case 12: go without go.sum — still reported, lockfile null
mkdir -p "$tmp/go-bare"
touch "$tmp/go-bare/go.mod"
out=$("$SCRIPT" --root "$tmp/go-bare")
check "go-bare.ecosystems"  "$(ecos "$out")"                    "go"
check "go-bare.lockfile"    "$(field "$out" go lockfile)"       ""

# Case 13: polyglot — npm + cargo + go, canonical order
mkdir -p "$tmp/poly"
echo '{}' > "$tmp/poly/package.json"
echo '{}' > "$tmp/poly/package-lock.json"
touch "$tmp/poly/Cargo.toml" "$tmp/poly/Cargo.lock"
touch "$tmp/poly/go.mod"     "$tmp/poly/go.sum"
out=$("$SCRIPT" --root "$tmp/poly")
check "poly.canonical-order" "$(ecos "$out" | tr '\n' ',')"     "npm,cargo,go,"

# Bad arg
if "$SCRIPT" --bogus 2>/dev/null; then
  echo "FAIL bad-arg: should have exited non-zero"
  fails=$((fails + 1))
else
  echo "ok   bad-arg.exits-nonzero"
fi

# Bad root
if "$SCRIPT" --root /no/such/path 2>/dev/null; then
  echo "FAIL bad-root: should have exited non-zero"
  fails=$((fails + 1))
else
  echo "ok   bad-root.exits-nonzero"
fi

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "PASSED"
