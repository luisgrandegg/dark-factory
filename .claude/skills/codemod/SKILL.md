---
name: codemod
description: Apply a scripted code transformation (rename a symbol, swap an API, normalise imports, etc.) across many files in a single PR. The transform is described declaratively in a JSON spec on the WorkItem; the skill previews the diff, checks it against size thresholds, applies it if safe, runs the project test command, and opens one PR. Source-code-editing by design — every guardrail is in the preview-and-threshold step.
---

# Codemod skill

You are filling the **implement** station for a WorkItem that asks for
a codemod. Triggered by an issue with the `skill:codemod` label and a
**codemod spec** in the issue body or in a fenced JSON block on the
spec comment.

Codemods are different from dep-upgrade and flake-triage: they
**deliberately edit source code**. The safety story therefore lives
in the *preview-and-threshold* step, not in a "don't edit code" rule.

## Hard rules

1. **The spec is the contract.** No transform runs without a JSON
   spec naming `engine`, `include`/`exclude` globs, `transform`, and
   `thresholds`. If the spec is missing or malformed, escalate.
2. **Always preview first.** Run the codemod in dry-run mode and
   compute file-count, line-add, and line-remove totals **before**
   applying. If any threshold is exceeded, escalate — do not apply.
3. **Single PR, single commit.** A codemod is one logical change.
   The commit message lists the files touched and embeds a sample
   diff; the body of the PR explains the *why*. No per-file commits.
4. **Tests must pass.** After applying, run the project's existing
   test command. On failure: `git reset --hard origin/main`, report
   `failureReason: ci-failed`, do **not** push.
5. **Never touch approval-gate paths.** `infra/**`, `migrations/**`,
   `.github/workflows/**`, `.factory/policy.yml`,
   `.claude/settings.json`. Add them to `exclude` if the include
   globs would match.
6. **Idempotent or escalate.** Re-running the codemod against the
   applied tree must produce zero changes. If the preview against an
   already-applied tree shows further matches, the transform is
   incorrect — escalate.

## The codemod spec

Embedded as a fenced JSON block on the WorkItem (typically the spec
comment). Shape:

```json
{
  "engine":   "regex" | "comby" | "ast-grep" | "jscodeshift",
  "include":  ["src/**/*.ts", "test/**/*.ts"],
  "exclude":  ["**/*.min.js", "node_modules/**", ".github/workflows/**"],
  "transform": {
    "pattern":     "<engine-specific>",
    "replacement": "<engine-specific>",
    "flags":       "<engine-specific, optional>"
  },
  "thresholds": {
    "maxFiles": 100,
    "maxLines": 2000
  },
  "rationale": "Free-form: why this codemod is being run. Embedded in the PR body."
}
```

Engines and what they need:

| Engine        | Tool needed                | Transform fields                                 |
| ------------- | -------------------------- | ------------------------------------------------ |
| `regex`       | (none — pure python)       | `pattern`, `replacement`, optional `flags` (`g`, `i`, `m`, `s`) |
| `comby`       | `comby` binary             | `matchTemplate`, `rewriteTemplate`               |
| `ast-grep`    | `sg` (ast-grep) binary     | `pattern`, `rewrite`                             |
| `jscodeshift` | `node` + `jscodeshift`     | `transformPath` (relative to repo root)          |

`regex` is the supported engine for this skill in Phase 4. The other
engines are recognised by the driver and dispatched to a shim if the
binary is present, but most repos won't have those binaries in CI; if
the engine's binary is missing, the driver exits non-zero with a
clear message and the skill escalates.

## Procedure

### 1. Read & validate the spec

```
spec=$(scripts/skills/codemod-extract-spec.sh <issue-id>)   # not yet implemented
# Phase 4 MVP: paste the JSON spec from the issue body into a tmp file
# and pass it via --spec PATH. The skill reads the issue body itself.
```

The driver script below validates the spec shape; if it errors,
escalate with the validator's message.

### 2. Preview

```
scripts/skills/codemod-run.sh --spec spec.json
```

(no `--apply`) reads the spec, runs the engine in dry-run mode, and
prints a JSON summary on stdout:

```json
{
  "engine":            "regex",
  "filesMatched":      42,
  "linesAdded":        84,
  "linesRemoved":      84,
  "thresholdsExceeded": [],
  "sampleDiff":         "..."
}
```

If `thresholdsExceeded` is non-empty, **escalate**. Don't try to
narrow the include globs to fit under the threshold — a too-large
preview is a signal that the spec needs human review.

If `filesMatched == 0`, comment "no matches" on the issue and swap
to `stage:done`. The codemod is a no-op; nothing to ship.

### 3. Apply

```
scripts/skills/codemod-run.sh --spec spec.json --apply
```

Re-runs the engine, this time writing the changes. After this, run
the engine **once more** with the same spec, no `--apply`. The
re-run should report `filesMatched: 0` (idempotency check). If it
doesn't, the transform is incorrect — `git reset --hard origin/main`
and escalate.

### 4. Test

Run the project's test command (read from the test plan). On
non-zero exit: `git reset --hard origin/main`, `failureReason:
ci-failed`, escalate. The codemod is correctness-critical; a red
test means we got something wrong.

### 5. Commit & PR

Single commit:

```
chore(codemod): <short summary>

Applies the spec on issue #<id>. Files touched: <n>
(<a> added, <b> removed lines).

Sample diff:
<the sampleDiff from preview, fenced>

Closes #<id>
```

Open one draft PR with the same title; body includes the full spec
JSON, the preview output, and the test command's output. No per-file
breakdown — that's noise.

Then swap labels `stage:implement` → `stage:qa`. Contract-check
verifies the test plan's checks against the PR head; if it passes,
the integrate sealer takes over.

## What this skill does NOT do

- It does not write codemod scripts. The spec must be self-contained.
  (For `jscodeshift`, `transformPath` must already exist in the
  repo.)
- It does not split a too-large codemod into smaller PRs. If the
  preview exceeds thresholds, a human re-scopes.
- It does not re-run after the first idempotency failure.
- It does not modify approval-gate paths even if the include globs
  match.
- It does not run on a schedule. There's no recurring "weekly
  codemod" — this is always operator-filed for a specific transform.

See `docs/skills/codemod.md` for the long-form rationale and example
spec shapes per engine.
