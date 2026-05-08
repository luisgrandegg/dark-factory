#!/usr/bin/env bash
# Smoke test for scripts/skills/codemod-run.sh.
#
# Builds synthetic source trees + JSON specs, runs the regex engine
# in dry-run and apply modes, and asserts file/line counts, threshold
# behaviour, idempotency, gate-path exclusion, and bad-spec handling.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/scripts/skills/codemod-run.sh"
[[ -x "$SCRIPT" ]] || { echo "missing $SCRIPT"; exit 1; }

tmp=$(mktemp -d -t codemod-smoke-XXXX)
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

field() {
  python3 -c '
import sys, json
out = sys.stdin.read().strip()
if not out:
    print("")
    sys.exit(0)
d = json.loads(out)
v = d.get(sys.argv[1])
print(v if not isinstance(v, (list, dict)) else json.dumps(v))
' "$1" <<< "$2"
}

# === Fixture A: rename `oldName` to `newName` across two files
mkdir -p "$tmp/A/src"
cat > "$tmp/A/src/a.js" <<'EOF'
function oldName() { return oldName.call(this); }
EOF
cat > "$tmp/A/src/b.js" <<'EOF'
const x = oldName();
const y = "oldName";  // string usage
EOF
mkdir -p "$tmp/A/node_modules"
echo "oldName everywhere" > "$tmp/A/node_modules/c.js"

cat > "$tmp/A/spec.json" <<'JSON'
{
  "engine": "regex",
  "include": ["src/**/*.js"],
  "exclude": ["node_modules/**"],
  "transform": {"pattern": "oldName", "replacement": "newName"},
  "thresholds": {"maxFiles": 100, "maxLines": 500}
}
JSON

# Dry run
out=$("$SCRIPT" --spec "$tmp/A/spec.json" --root "$tmp/A")
rc=$?
check "A.dry.exit-0"        "$rc"                         "0"
check "A.dry.filesMatched"  "$(field filesMatched "$out")" "2"
check "A.dry.applied"       "$(field applied "$out")"      "False"
check "A.dry.exceeded"      "$(field thresholdsExceeded "$out")" "[]"
# File contents unchanged
grep -q oldName "$tmp/A/src/a.js" && echo "ok   A.dry.no-write"  || { echo "FAIL A.dry.no-write"; fails=$((fails+1)); }

# Apply
out=$("$SCRIPT" --spec "$tmp/A/spec.json" --root "$tmp/A" --apply)
rc=$?
check "A.apply.exit-0"      "$rc"                         "0"
check "A.apply.applied"     "$(field applied "$out")"     "True"
grep -q newName "$tmp/A/src/a.js" && echo "ok   A.apply.write-a" || { echo "FAIL A.apply.write-a"; fails=$((fails+1)); }
grep -q newName "$tmp/A/src/b.js" && echo "ok   A.apply.write-b" || { echo "FAIL A.apply.write-b"; fails=$((fails+1)); }
grep -q oldName "$tmp/A/node_modules/c.js" && echo "ok   A.apply.exclude-honored" \
  || { echo "FAIL A.apply.exclude-honored (node_modules touched!)"; fails=$((fails+1)); }

# Idempotency
out2=$("$SCRIPT" --spec "$tmp/A/spec.json" --root "$tmp/A")
check "A.idempotent.filesMatched" "$(field filesMatched "$out2")" "0"

# === Fixture B: thresholds exceeded → exit 2, applied:false
mkdir -p "$tmp/B/src"
for i in 1 2 3 4 5; do
  echo "TODO: rename me" > "$tmp/B/src/f$i.txt"
done
cat > "$tmp/B/spec.json" <<'JSON'
{
  "engine": "regex",
  "include": ["src/**/*.txt"],
  "transform": {"pattern": "TODO", "replacement": "DONE"},
  "thresholds": {"maxFiles": 3, "maxLines": 1000}
}
JSON
out=$("$SCRIPT" --spec "$tmp/B/spec.json" --root "$tmp/B" --apply)
rc=$?
check "B.threshold.exit-2"   "$rc"                          "2"
check "B.threshold.applied"  "$(field applied "$out")"      "False"
check "B.threshold.exceeded" "$(field thresholdsExceeded "$out" | python3 -c 'import sys,json; print(len(json.loads(sys.stdin.read())))')" "1"
# Even with --apply, files must NOT have been written.
grep -q TODO "$tmp/B/src/f1.txt" && echo "ok   B.threshold.no-write" \
  || { echo "FAIL B.threshold.no-write (files were modified despite exceeded threshold!)"; fails=$((fails+1)); }

# === Fixture C: gate paths always excluded, even if include matches.
# Spec lives outside the scan root (mirrors how the skill ships in
# production — the spec comes from the issue, not the working tree).
mkdir -p "$tmp/C/root/.github/workflows" "$tmp/C/root/migrations"
echo "TODO" > "$tmp/C/root/.github/workflows/ci.yml"
echo "TODO" > "$tmp/C/root/migrations/001.sql"
echo "TODO" > "$tmp/C/root/normal.txt"
cat > "$tmp/C/spec.json" <<'JSON'
{
  "engine": "regex",
  "include": ["**/*"],
  "transform": {"pattern": "TODO", "replacement": "DONE"},
  "thresholds": {"maxFiles": 100, "maxLines": 500}
}
JSON
out=$("$SCRIPT" --spec "$tmp/C/spec.json" --root "$tmp/C/root" --apply)
check "C.gate.filesMatched" "$(field filesMatched "$out")" "1"
grep -q TODO "$tmp/C/root/.github/workflows/ci.yml" && echo "ok   C.gate.workflow-untouched" \
  || { echo "FAIL C.gate.workflow-untouched"; fails=$((fails+1)); }
grep -q TODO "$tmp/C/root/migrations/001.sql"       && echo "ok   C.gate.migration-untouched" \
  || { echo "FAIL C.gate.migration-untouched"; fails=$((fails+1)); }
grep -q DONE "$tmp/C/root/normal.txt"               && echo "ok   C.gate.normal-touched" \
  || { echo "FAIL C.gate.normal-touched"; fails=$((fails+1)); }

# === Fixture D: zero matches → applied: false, exit 0
mkdir -p "$tmp/D/src"
echo "nothing here" > "$tmp/D/src/a.js"
cat > "$tmp/D/spec.json" <<'JSON'
{
  "engine": "regex",
  "include": ["src/**/*.js"],
  "transform": {"pattern": "nope", "replacement": "yep"},
  "thresholds": {"maxFiles": 10, "maxLines": 100}
}
JSON
out=$("$SCRIPT" --spec "$tmp/D/spec.json" --root "$tmp/D" --apply)
rc=$?
check "D.zero.exit-0"           "$rc"                          "0"
check "D.zero.filesMatched"     "$(field filesMatched "$out")" "0"
check "D.zero.applied"          "$(field applied "$out")"      "False"

# === Fixture E: unsupported engine → exit 3
cat > "$tmp/E.spec.json" <<'JSON'
{
  "engine": "comby",
  "include": ["**/*"],
  "transform": {"matchTemplate": "x", "rewriteTemplate": "y"},
  "thresholds": {"maxFiles": 10, "maxLines": 100}
}
JSON
"$SCRIPT" --spec "$tmp/E.spec.json" --root "$tmp" 2>/dev/null
check "E.engine-stub.exit-3" "$?" "3"

# === Fixture F: malformed spec → exit 2
echo "{ this is not json" > "$tmp/F.spec.json"
"$SCRIPT" --spec "$tmp/F.spec.json" --root "$tmp" 2>/dev/null
check "F.bad-json.exit-2" "$?" "2"

# === Fixture G: missing required field → exit 2
echo '{"engine":"regex"}' > "$tmp/G.spec.json"
"$SCRIPT" --spec "$tmp/G.spec.json" --root "$tmp" 2>/dev/null
check "G.missing-field.exit-2" "$?" "2"

# === Fixture H: invalid regex → exit 2
cat > "$tmp/H.spec.json" <<'JSON'
{
  "engine": "regex",
  "include": ["**/*"],
  "transform": {"pattern": "[unclosed", "replacement": "x"},
  "thresholds": {"maxFiles": 10, "maxLines": 100}
}
JSON
"$SCRIPT" --spec "$tmp/H.spec.json" --root "$tmp" 2>/dev/null
check "H.bad-regex.exit-2" "$?" "2"

# === Fixture I: bad invocation
"$SCRIPT" 2>/dev/null
check "I.no-spec.exit-2" "$?" "2"
"$SCRIPT" --spec /nope --root "$tmp" 2>/dev/null
check "I.bad-spec-path.exit-2" "$?" "2"

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "PASSED"
