---
name: flake-triage
description: Rank workflow jobs on `main` by how often they flake (fail and then pass on rerun, or fail-then-pass on the next commit) over a lookback window, and file one follow-up issue per top offender for a human to investigate. Read-only against the GitHub API; never edits source code or tests.
---

# Flake-triage skill

You are filling the **implement** station for a WorkItem that asks for
flake triage. Triggered by the recurring `nightly-flake-triage`
schedule (see `.factory/schedule.yml`) or filed ad-hoc with the
`skill:flake-triage` label.

This skill is **observational, not corrective**. It produces a ranked
list of flaky workflow jobs and files one follow-up issue per top
offender. It does **not** quarantine, retry, or fix tests — those
decisions belong to the humans who own the test in question.

## Hard rules

1. **Read-only against the GitHub API.** No edits to workflow files,
   no force-skipping tests, no quarantine labels added to other PRs.
2. **No source-code edits.** This skill writes one comment on the
   triggering issue, swaps its labels, and (for top-N flaky jobs)
   files a fresh issue. That's it.
3. **Workflow granularity, not test-name granularity.** Parsing test
   output across jest/pytest/go-test/junit is unreliable. The GitHub
   Actions runs listing gives us deterministic flake signal at the
   workflow level (re-run conclusions per commit) without per-run
   job lookups or log parsing. That's good enough for ranking; the
   human investigating each top offender will read the linked run
   logs and identify the failing job/test there.
4. **Lookback is fixed at the schedule cadence.** Nightly =
   `--lookback 1d`. A weekly variant uses `--lookback 7d`. Don't
   widen the window without escalating — a wider window dilutes the
   signal from recent regressions.
5. **Threshold-gated.** Don't file follow-up issues for jobs below
   the configured `--min-flake-rate` (default 0.05 = 5% of runs in
   the window). One-offs are noise; we want repeat offenders.

## Procedure

### 1. Read the test plan

The plan-station test plan should specify:
- the lookback window,
- the workflow(s) to consider (default: all),
- how many top offenders to file follow-up issues for (default: 3),
- the minimum flake rate threshold.

If the test plan doesn't match the skill's shape, escalate.

### 2. Rank flaky jobs

```
scripts/skills/flake-triage-rank.sh \
  --lookback 1d \
  [--workflow CI] \
  [--min-flake-rate 0.05] \
  [--top 3]
```

The script calls `gh api repos/:owner/:repo/actions/runs` (paginated,
already on the allowlist), aggregates by workflow_name, and emits
JSON Lines on stdout — one object per workflow, sorted by flake rate
descending. Each row has shape:

```json
{
  "workflow":     "CI",
  "flakeEvents":  7,
  "totalRuns":    120,
  "flakeRate":    0.058,
  "recentSamples": [
    {"sha": "abc1234", "url": "https://github.com/.../actions/runs/...", "attempts": 2}
  ]
}
```

A "flake event" for a (workflow, head_sha) pair is either:
- a single workflow_run with `run_attempt > 1` whose conclusion is
  `success` (re-run-and-passed signal), OR
- the same SHA + same workflow has at least one run with conclusion
  `failure` and at least one with conclusion `success` across
  separate runs (force-rerun-and-passed without bumping
  `run_attempt`).

Both cases are computed inside the rank script — the SKILL.md does
not need to know the rules, only the output shape.

### 3. Filter and report

Drop rows where `flakeRate < min-flake-rate`. Keep the top `N`
remaining rows.

Comment on the triggering issue with:

```
## Flake-triage report — <YYYY-MM-DD>

Lookback: <window>. Workflows scanned: <list or "all">.
Total runs in window: <n>. Flake events: <n> (<rate>%).

### Top offenders (≥ <min-flake-rate>)

| # | workflow | flake events | total runs | rate |
| - | -------- | ------------ | ---------- | ---- |
| 1 | CI       | 7            | 120        | 5.8% |
| ... |

### Below threshold (FYI, no follow-up filed)

<bullet per row, or "none">
```

If the threshold leaves zero rows: comment "no significant flakes in
window" and swap the label to `stage:done`. Done.

### 4. File follow-up issues

For each top offender (`--top` rows), file one issue with:

- **Title:** `Flaky workflow: <workflow>`
- **Labels:** `priority:p2, factory:report, flake:investigate`
- **Body:**
  ```
  Filed by the **flake-triage** skill from #<workitem-id> on <date>.

  - Workflow: `<workflow>`
  - Window:   <lookback>
  - Flake events: <n> / <total runs> (<rate>%)

  ### Recent samples

  - <commit sha> · <run-url> · attempt <n>
  - ...

  See `docs/skills/flake-triage.md` for what to do next.
  ```

Don't open a follow-up issue if one with the same title already
exists in the open state — assume the human is already on it.

### 5. Close out

Comment on the originating issue with the count of follow-ups filed
(plus their issue numbers) and swap labels
`stage:implement` → `stage:qa`. The contract-check station verifies
the test-plan checks (e.g. "report comment exists",
"top-N issues filed") and pushes to integrate.

This skill does not open a PR; nothing was changed in the working
copy. Contract-check will see "no diff" and that's expected — the
test plan should reflect that.

### 6. Failure handling

| Symptom                                | Skill behaviour                                       |
| -------------------------------------- | ----------------------------------------------------- |
| Rank script exits non-zero             | Escalate (`stage:escalated`). Probably API rate limit or auth issue. |
| Zero workflow runs in window           | Comment "no runs in window" and swap to `stage:done`. |
| Existing open `Flaky job: …` matches   | Note "already tracked in #N" instead of filing.       |
| `flake:investigate` label missing      | Create it on the fly via `gh label create`.           |

## What this skill does NOT do

- It does not parse test output (jest/pytest/junit/etc.).
- It does not quarantine flaky tests.
- It does not push commits.
- It does not modify other PRs.
- It does not run on a schedule by itself — the recurring-jobs system
  triggers it via the `nightly-flake-triage` schedule entry.

See `docs/skills/flake-triage.md` for the rationale and what humans
should do with each follow-up issue.
