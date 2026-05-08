#!/usr/bin/env bash
# Apply (or preview) a codemod described by a JSON spec.
#
# Default mode is dry-run: the script reports what would change but
# leaves the working copy untouched. Pass --apply to write changes.
#
# Spec shape (see .claude/skills/codemod/SKILL.md):
#
#   {
#     "engine":     "regex" | "comby" | "ast-grep" | "jscodeshift",
#     "include":    ["src/**/*.ts", ...],
#     "exclude":    ["**/*.min.js", ...],
#     "transform":  { engine-specific },
#     "thresholds": { "maxFiles": 100, "maxLines": 2000 }
#   }
#
# stdout (one JSON object):
#
#   {
#     "engine":             "regex",
#     "filesMatched":       <int>,
#     "linesAdded":         <int>,
#     "linesRemoved":       <int>,
#     "thresholdsExceeded": [<string>, ...],
#     "sampleDiff":         "<unified diff hunk, truncated>",
#     "applied":            true|false
#   }
#
# Exit codes:
#   0 — preview/apply finished cleanly
#   2 — bad invocation, malformed spec, or thresholds exceeded
#   3 — engine binary not installed (comby/ast-grep/jscodeshift)
#
# Phase 4 supports the `regex` engine fully (pure python). The other
# engines are recognised but exit 3 if their binary is missing — the
# skill escalates rather than silently doing nothing.

set -uo pipefail

spec_path=""
apply=0
root="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec)   spec_path="$2"; shift 2 ;;
    --apply)  apply=1; shift ;;
    --root)   root="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,32p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$spec_path" ]] || { echo "missing --spec" >&2; exit 2; }
[[ -f "$spec_path" ]] || { echo "no such spec: $spec_path" >&2; exit 2; }
[[ -d "$root"      ]] || { echo "no such root: $root" >&2; exit 2; }

python3 - "$spec_path" "$root" "$apply" <<'PY'
import json, os, re, sys, difflib

spec_path, root, apply_str = sys.argv[1], sys.argv[2], sys.argv[3]
apply = apply_str == "1"

# --- gitignore-ish glob matcher
# Supports:
#   *   matches any chars except /
#   ?   matches a single char except /
#   **  matches zero or more path segments (must be its own segment)
def glob_match(path, pat):
    if pat == "**":
        return True
    SENT_MID, SENT_HEAD, SENT_TAIL, SENT_STAR, SENT_QM = "\x01\x02\x03\x04\x05"
    p = pat
    if p.startswith("**/"):
        p = SENT_HEAD + p[3:]
    if p.endswith("/**"):
        p = p[:-3] + SENT_TAIL
    p = p.replace("/**/", SENT_MID)
    p = p.replace("*", SENT_STAR)
    p = p.replace("?", SENT_QM)
    rx = re.escape(p)
    rx = (rx.replace(re.escape(SENT_MID),  "/(?:.*/)?")
            .replace(re.escape(SENT_HEAD), "(?:.*/)?")
            .replace(re.escape(SENT_TAIL), "(?:/.*)?")
            .replace(re.escape(SENT_STAR), "[^/]*")
            .replace(re.escape(SENT_QM),   "[^/]"))
    return re.match("^" + rx + "$", path) is not None

def globs_match(path, patterns):
    return any(glob_match(path, p) for p in patterns)

# --- Parse spec
try:
    with open(spec_path) as f:
        spec = json.load(f)
except Exception as e:
    sys.stderr.write(f"spec is not valid JSON: {e}\n")
    sys.exit(2)

required = ["engine", "include", "transform", "thresholds"]
missing = [k for k in required if k not in spec]
if missing:
    sys.stderr.write(f"spec missing required fields: {missing}\n")
    sys.exit(2)

engine = spec["engine"]
if engine not in ("regex", "comby", "ast-grep", "jscodeshift"):
    sys.stderr.write(f"unsupported engine: {engine}\n")
    sys.exit(2)

include = spec["include"]
exclude = spec.get("exclude", []) or []
transform = spec["transform"]
thresholds = spec["thresholds"]

if engine != "regex":
    # Stub: would dispatch to comby / ast-grep / jscodeshift here.
    # For Phase 4 MVP we exit 3 cleanly so the skill can escalate.
    sys.stderr.write(f"engine '{engine}' not implemented in Phase 4 MVP\n")
    sys.exit(3)

# --- regex engine
pattern = transform.get("pattern")
replacement = transform.get("replacement", "")
flags_str = transform.get("flags", "") or ""
if not pattern:
    sys.stderr.write("regex transform requires 'pattern'\n")
    sys.exit(2)

flag_bits = 0
for ch in flags_str:
    flag_bits |= {"i": re.IGNORECASE, "m": re.MULTILINE, "s": re.DOTALL}.get(ch, 0)
# 'g' is implied — re.sub replaces all occurrences by default.
try:
    rx = re.compile(pattern, flag_bits)
except re.error as e:
    sys.stderr.write(f"invalid regex: {e}\n")
    sys.exit(2)

# --- Collect candidate files
# Approval-gate paths are always excluded, regardless of spec.
gate_excludes = [
    "infra/**", "migrations/**", ".github/workflows/**",
    ".factory/policy.yml", ".claude/settings.json",
]

candidates = []
for dirpath, dirnames, filenames in os.walk(root):
    # prune .git
    dirnames[:] = [d for d in dirnames if d != ".git"]
    for fn in filenames:
        full = os.path.join(dirpath, fn)
        rel = os.path.relpath(full, root)
        if not globs_match(rel, include):
            continue
        if globs_match(rel, exclude) or globs_match(rel, gate_excludes):
            continue
        candidates.append(rel)

candidates.sort()

# --- Pass 1: collect changes in memory. We never write before the
# threshold check, so an --apply run that exceeds thresholds leaves
# the working tree untouched.
changes = []
lines_added = 0
lines_removed = 0
sample_diff = ""

for rel in candidates:
    full = os.path.join(root, rel)
    try:
        with open(full, "r", encoding="utf-8") as f:
            old = f.read()
    except (UnicodeDecodeError, OSError):
        continue  # skip binaries / unreadable
    new, n = rx.subn(replacement, old)
    if n == 0 or new == old:
        continue
    old_lines = old.splitlines(keepends=True)
    new_lines = new.splitlines(keepends=True)
    diff = list(difflib.unified_diff(
        old_lines, new_lines, fromfile=f"a/{rel}", tofile=f"b/{rel}", n=2,
    ))
    for line in diff:
        if line.startswith("+") and not line.startswith("+++"):
            lines_added += 1
        elif line.startswith("-") and not line.startswith("---"):
            lines_removed += 1
    if not sample_diff and diff:
        sample_diff = "".join(diff[:40])
    changes.append((full, new))

files_matched = len(changes)

# --- Threshold check
exceeded = []
max_files = thresholds.get("maxFiles")
max_lines = thresholds.get("maxLines")
if isinstance(max_files, int) and files_matched > max_files:
    exceeded.append(f"maxFiles ({files_matched}>{max_files})")
if isinstance(max_lines, int) and (lines_added + lines_removed) > max_lines:
    exceeded.append(f"maxLines ({lines_added + lines_removed}>{max_lines})")

applied = bool(apply and not exceeded and changes)

# Pass 2: write. Only happens once thresholds have been verified to fit.
if applied:
    for full, new in changes:
        with open(full, "w", encoding="utf-8") as f:
            f.write(new)

result = {
    "engine":             engine,
    "filesMatched":       files_matched,
    "linesAdded":         lines_added,
    "linesRemoved":       lines_removed,
    "thresholdsExceeded": exceeded,
    "sampleDiff":         sample_diff,
    "applied":            applied,
}
print(json.dumps(result))
sys.exit(2 if exceeded else 0)
PY
