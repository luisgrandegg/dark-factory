# Skill: codemod

The `codemod` skill applies a scripted code transformation across many
files in a single PR. The transform is described declaratively as a
JSON spec on the WorkItem; the skill previews the change, checks it
against thresholds, applies it if safe, runs the project's tests, and
opens one PR.

This is the only skill in the factory that **deliberately edits source
code**. Its safety story therefore lives in the *spec + preview +
threshold* triangle, not in a "don't edit code" rule.

The terse, operational version lives in
[`.claude/skills/codemod/SKILL.md`](../../.claude/skills/codemod/SKILL.md);
this is the long-form rationale.

## Why this shape

### Spec-driven, never free-form

The factory does not invent codemods. Every codemod runs from a JSON
spec that lives on the WorkItem (typically in the `stage:spec`
comment). The spec names the engine, the include/exclude globs, the
transform, and the size thresholds. If the spec is missing or
malformed, the skill escalates instead of guessing.

This has two effects:

1. The change is **legible before it runs.** A reviewer can read the
   spec on the issue and predict the diff.
2. The transform is **rerunnable.** Apply it, see the diff, decide
   to revert; the spec is the source of truth, not the (now
   ephemeral) shell-pipeline that produced the change.

### Always preview, then apply (never the other way)

The driver script
([`scripts/skills/codemod-run.sh`](../../scripts/skills/codemod-run.sh))
runs in two phases internally:

1. **Pass 1** (always): collect every change in memory. Compute
   files-matched, lines-added, lines-removed, sample diff. **No
   writes.**
2. **Pass 2** (only if `--apply` and thresholds pass): write the
   collected changes to disk.

The thresholds therefore gate the writes. An `--apply` invocation
that exceeds a threshold produces output (so the operator can read
the would-be diff) but leaves the working tree untouched. This
means the skill can safely escalate without an "ugh, rollback"
dance.

### Single PR, single commit

A codemod is one logical change. Per-file commits are noise: nobody
wants to read 47 commits of "rename oldName → newName in foo.js."
The PR carries:

- A title summarising the transform.
- A body with the full spec JSON, the preview output, and the test
  command output.
- A single commit whose message embeds the sample diff hunk.

Reverts are also one click — that's the point.

### Idempotency is mandatory

After applying, the skill re-runs the preview against the now-applied
tree. If `filesMatched != 0`, the transform is non-idempotent: it
either rewrites its own output or finds new matches the apply pass
missed. Both are bugs. The skill `git reset --hard origin/main` and
escalates.

This catches a common class of regex mistakes ("replacement
introduces a substring that matches the pattern"). It's cheap and
catches real errors.

### Tests must pass

Same rule as dep-upgrade: run the project test command after
applying; on red, hard-reset and report `failureReason: ci-failed`.
The skill does not "fix" failing tests by editing code. A red test
post-codemod means the spec was wrong; that's a human re-scope.

### Approval-gate paths are excluded by the engine, not by the spec

The driver always excludes `infra/**`, `migrations/**`,
`.github/workflows/**`, `.factory/policy.yml`,
`.claude/settings.json`. A spec that includes those paths through
its `include` globs has them stripped out at file-collection time.
Defence in depth: even a buggy spec can't slip a codemod through a
gate.

## The spec

```json
{
  "engine":     "regex" | "comby" | "ast-grep" | "jscodeshift",
  "include":    ["src/**/*.ts", "test/**/*.ts"],
  "exclude":    ["**/*.min.js", "node_modules/**"],
  "transform":  { engine-specific fields },
  "thresholds": { "maxFiles": 100, "maxLines": 2000 },
  "rationale":  "Why this codemod is being run."
}
```

`include` and `exclude` use **gitignore-style** glob matching:

- `*` matches anything except `/`.
- `?` matches a single character except `/`.
- `**` matches zero or more path segments (must be its own segment).

Example: `src/**/*.ts` matches `src/a.ts`, `src/x/a.ts`,
`src/x/y/a.ts`. `node_modules/**` matches every file inside
`node_modules`. `**/*.min.js` matches any minified JS file at any
depth.

## Engines

### `regex` (Phase 4 MVP — fully supported)

Pure-python `re` module. Required transform fields:

- `pattern`: a Python regex.
- `replacement`: the substitution string. Backrefs (`\1`, `\g<name>`) work.
- `flags` (optional): subset of `i` (ignorecase), `m` (multiline), `s` (dotall). `g` is implicit (all matches).

Example (rename a symbol):

```json
{
  "engine": "regex",
  "include": ["src/**/*.ts", "test/**/*.ts"],
  "exclude": ["**/*.d.ts"],
  "transform": {
    "pattern": "\\boldName\\b",
    "replacement": "newName"
  },
  "thresholds": {"maxFiles": 200, "maxLines": 500}
}
```

The `\b` word boundaries are critical — without them, `oldName`
would match inside `oldNameSpace` and `oldNameSerializer`.

### `comby`, `ast-grep`, `jscodeshift` (recognised, not yet implemented)

The driver recognises these engine names and dispatches to a shim,
but the shim exits non-zero with a "not implemented in Phase 4 MVP"
message. The skill escalates rather than silently doing nothing.

Adding one is small: implement the engine in
`scripts/skills/codemod-run.sh` next to the regex engine, including
the same dry-run/apply-with-threshold flow.

## What the smoke test covers

[`scripts/test/codemod-smoke.sh`](../../scripts/test/codemod-smoke.sh)
runs **28 fixture-based checks** without any external binaries:

- Rename across files (dry-run + apply, including `node_modules` exclusion).
- Idempotency on a re-applied tree.
- Threshold-exceeded run with `--apply` does NOT write to disk.
- Approval-gate paths (`migrations/**`, `.github/workflows/**`) are excluded even when the spec's include matches.
- Zero-match runs report `applied: false` and exit cleanly.
- Unsupported engines exit `3` (binary missing) so the skill can escalate.
- Malformed spec, missing required field, invalid regex, missing `--spec`, bad spec path all exit `2`.

## What this skill does NOT do

- It does not write codemod scripts. The spec must already specify
  the transform.
- It does not split a too-large codemod into smaller PRs. If the
  preview exceeds thresholds, a human re-scopes.
- It does not retry after the first idempotency failure.
- It does not modify approval-gate paths even when the spec asks it
  to — the driver enforces this in code.
- It does not run on a schedule. Codemods are operator-filed for
  specific transforms.

## See also

- [`.claude/skills/codemod/SKILL.md`](../../.claude/skills/codemod/SKILL.md) — operational checklist used at tick time.
- [`scripts/skills/codemod-run.sh`](../../scripts/skills/codemod-run.sh) — driver.
- [`scripts/test/codemod-smoke.sh`](../../scripts/test/codemod-smoke.sh) — synthetic-fixture tests.
- [`docs/skills/dep-upgrade.md`](./dep-upgrade.md) and [`docs/skills/flake-triage.md`](./flake-triage.md) — sibling skills with similar shape.
