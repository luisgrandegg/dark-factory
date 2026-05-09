# 0006 — Repo-level check harness

- **Status:** Proposed
- **Date:** 2026-05-09
- **Builds on:** [0005](./0005-sdlc-step-contract.md)

## Context

The implement station's "ready to hand off" gate today is the per-
WorkItem **test plan** produced by the plan agent (see
`.claude/skills/factory/SKILL.md` implement section). The test plan
covers acceptance criteria for that specific change.

What it does **not** cover is project-wide baseline hygiene: linters,
formatters, type checkers, and the like — checks that should pass on
*every* PR regardless of what the WorkItem is about. Today, getting
those enforced means either:

- the plan agent re-asserts them in every test plan (repetitive,
  fragile, drifts), or
- they only run in CI / qa, so implement can flip the stage label with
  a broken lint and qa has to bounce it back.

We want a single place a consumer repo can declare "these checks must
pass before any change leaves implement", and have the factory honour
it without further per-WorkItem ceremony.

Forces:

- The factory must work on a TS project, a Python project, or a Go
  project with the same orchestrator. Whatever schema we add cannot
  bake in a language.
- A slow check (e.g. full type check on a large repo) must not silently
  blow the per-station budget.
- Failures need a controlled vocabulary so the dashboard and budget
  kill-switch can reason about them.
- ADR 0005 introduces step contracts; harness execution is most natural
  as a gate on those contracts rather than a one-off in the implement
  skill.

## Decision

A consumer repo declares its harness in **`.factory/checks.yml`**. The
factory ships an empty default — pure opt-in.

### Schema

```yaml
# .factory/checks.yml
version: 1
checks:
  lint:
    cmd: "npm run -s lint"
    blocking: true
    runs_at: [implement.exit, qa]
    timeout_seconds: 60
  format:
    cmd: "npx prettier --check ."
    blocking: true
    runs_at: [implement.exit]
    timeout_seconds: 30
  typecheck:
    cmd: "npx tsc --noEmit"
    blocking: true
    runs_at: [implement.exit, qa]
    timeout_seconds: 120
  audit:
    cmd: "npm audit --omit=dev"
    blocking: false
    runs_at: [qa]
    timeout_seconds: 60
```

Per-check fields:

| Field             | Required | Notes                                                            |
| ----------------- | -------- | ---------------------------------------------------------------- |
| `cmd`             | yes      | Single shell command. Must be in `policy.yml` allowlist.         |
| `blocking`        | yes      | If `false`, failure is recorded but does not halt the stage.     |
| `runs_at`         | yes      | Subset of `[implement.exit, qa]`. No other slots in v1.          |
| `timeout_seconds` | no       | Default 60. Hard kill on timeout; treated as failure.            |
| `tags`            | no       | Free-text for dashboard grouping.                                |

### Execution

- **`implement.exit`** — the implement implementation runs every check
  whose `runs_at` includes `implement.exit` *after* primary + regression
  checks from the test plan are green. **All blocking checks must
  pass** before the stage can flip to `stage:qa`.
- **`qa`** — `contract-check` re-runs every `runs_at: qa` check against
  the PR head. A flaky local pass cannot slip through.

The two slots are AND-ed with the per-WorkItem test plan; they do not
replace it.

### Failure semantics

A blocking-check failure is treated like a test-plan failure today:

- log the Run as `failure` with
  `failureReason: "harness-failed:<check-name>"` (added to the
  controlled vocabulary in `.factory/ledger-schema.md`),
- consume one retry against `budgets.perWorkItem.maxRetries`,
- past the cap, escalate with the same reason.

Non-blocking failures are recorded under `harnessResults` on the Run
but do not advance the retry counter.

### Ledger shape

Every Run for steps that ran the harness gains:

```yaml
harnessResults:
  - { name: lint,      status: pass, durationSeconds: 4 }
  - { name: format,    status: pass, durationSeconds: 1 }
  - { name: typecheck, status: fail, durationSeconds: 78,
      excerpt: "src/foo.ts(12,3): error TS2322: ..." }
```

Excerpts are bounded (≤ 4 KiB) and pass through the same secret-
redaction hook as everything else (ADR 0004).

### Composition with ADR 0005

In step-contract terms (ADR 0005), `implement.exit` and `qa` become
named gates the contract recognises. The harness runner is the
orchestrator's responsibility, not the implementation's — so swapping
the implement implementation does not let it skip the harness.

## Consequences

Positive:

- One place to declare baseline hygiene per consumer repo. Plan agents
  stop re-asserting lint/format/types in every test plan.
- The implement station gains a real exit gate beyond convention.
  Today, "lint passes" is honour-system; with this, it's enforced.
- The dashboard gets per-check trend data nearly for free
  (`harnessResults` is structured).

Negative / accepted costs:

- New file (`.factory/checks.yml`), new schema, new ledger field,
  expanded `failureReason` vocabulary.
- Harness runtime counts against `budgets.perStation.implement` and
  `budgets.perStation.qa`. Slow checks need explicit `timeout_seconds`
  or they will trip the budget kill-switch.
- Two failure surfaces (test plan + harness) instead of one. We keep
  them distinct in the ledger so the dashboard can distinguish "this
  WorkItem's tests failed" from "the project's baseline regressed".

## Alternatives considered

- **Status quo: per-WorkItem test plan only.** Rejected — every plan
  re-asserts the same hygiene checks, drifts between WorkItems, and
  the gate is honour-system at implement.
- **Autodetect from `package.json` / `pyproject.toml`.** Tempting,
  hides surprising overrides. Deferred to a later iteration; explicit
  declaration first.
- **Run harness only at qa.** Rejected — implement can ship a broken
  lint and qa has to bounce it. Cheaper to fail fast at
  `implement.exit`.
- **Run harness only at implement.exit.** Rejected — a flaky local
  pass would slip through. The qa re-run is the trust boundary.
- **Bake harness into the implement skill itself.** Rejected — under
  ADR 0005 the implementation is pluggable, so a custom implement
  could silently skip the harness. The orchestrator owns gates.
