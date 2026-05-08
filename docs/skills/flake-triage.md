# Skill: flake-triage

The `flake-triage` skill is a **nightly observatory**: it ranks the
workflows on the default branch by how often they flake (failed and
then passed without a real fix), files one follow-up issue per top
offender, and posts a short report on the originating WorkItem. It
never edits source code, tests, workflows, or other PRs.

The terse, operational version lives in
[`.claude/skills/flake-triage/SKILL.md`](../../.claude/skills/flake-triage/SKILL.md);
this document is the long-form rationale.

## Why this shape

### Workflow granularity, not test names

We do **not** parse test reporter output. Every framework spells
failures differently — JUnit XML for some, jest's GitHub Actions
matcher for others, raw stdout for many — and any parser we wrote
would silently miss most of them. The signal we *do* have for free
is the GitHub Actions runs API: per workflow, per commit SHA, what
were the conclusions across attempts? That gives a deterministic
"this passed only after a rerun" signal. Less precise than test-name
ranking, but trustworthy.

The follow-up issue points at the run URL; whoever picks it up reads
the failing job's log and identifies the test there. Humans are
better at the messy parsing step than we are.

### Rerun-and-passed is the flake definition

Two flavours:

1. `run_attempt > 1 && conclusion == success` for some run on a
   given (workflow, head_sha) pair. Classic "click rerun, it passed"
   signal.
2. The same (workflow, head_sha) produced both `failure` and
   `success` across separate runs (force-rerun without bumping
   `run_attempt`).

A SHA where every run failed is **not** a flake — it's a regression
that someone is presumably actively debugging. A SHA where every run
passed is also not a flake. The interesting middle is "intermittent
green," which is what these rules detect.

### Report + follow-up issues, not PRs

The skill produces two kinds of output:
- **A report comment** on the WorkItem that triggered it (so the
  ledger and the issue both have an immutable record of what was
  ranked when).
- **One follow-up issue per top-N flaky workflow**, with
  `flake:investigate` and `priority:p2` labels, addressed to a human.

It explicitly does **not**:
- Open a PR.
- Push commits.
- Quarantine tests.
- Re-run jobs.
- Edit other open PRs or issues.

A flake that has not been investigated by a human is not safely
auto-fixable, so we don't try.

### Threshold-gated

Default `--min-flake-rate 0.05` (a flake event on at least 5% of the
SHAs the workflow ran for in the lookback window). One-off rerun
events under that bar are noise; they create alert fatigue without
representing a problem worth a human's time.

`--top` (default 3) caps how many follow-up issues a single triage
run produces. A nightly job that filed 30 issues every morning would
be net-negative for the team.

### Lookback of a day, not a quarter

The default schedule is nightly with `--lookback 1d`. Why so short?
A flake that started Tuesday and was fixed Wednesday should not pollute
Thursday's report. Recent regressions are what's actionable. If a
team wants weekly trends, a `--lookback 7d` weekly variant is fine —
just file it as a separate `schedule.yml` entry.

## Triggering

### Recurring schedule (intended path)

`.factory/schedule.yml` ships a (commented-out) `nightly-flake-triage`
entry that fires every UTC night at 05:00 with the
`skill:flake-triage, stage:intake, priority:p2` labels. The factory
loop triages the issue through intake → spec → plan → implement, and
the implement station follows
[`.claude/skills/flake-triage/SKILL.md`](../../.claude/skills/flake-triage/SKILL.md).

To enable: uncomment the entry.

### Ad-hoc

A human files an issue titled "Flake triage" with the
`skill:flake-triage, stage:intake` labels. Same flow.

## What the rank script does

[`scripts/skills/flake-triage-rank.sh`](../../scripts/skills/flake-triage-rank.sh)
is read-only and emits JSON Lines on stdout:

```json
{"workflow":"CI","flakeEvents":7,"totalRuns":120,"flakeRate":0.058,"recentSamples":[{"sha":"abc1234","url":"https://github.com/.../actions/runs/12345","attempts":2}]}
```

Sorted by flake rate descending. Filters: `--workflow`, `--branch`,
`--min-flake-rate`, `--top`. The script accepts `--from-fixture` so
tests can mock the API; the recurring-jobs runner uses
`gh api repos/:owner/:repo/actions/runs` directly. Smoke-tested by
[`scripts/test/flake-triage-rank-smoke.sh`](../../scripts/test/flake-triage-rank-smoke.sh)
(20 cases: ranking, the two flake-event flavours, the regression
non-flake case, all filter flags, empty input, bad args).

## What humans should do with each follow-up issue

Each `Flaky workflow: <name>` issue includes recent run URLs. The
expected playbook:

1. Open one of the recent run URLs and read the failing job's log.
2. Identify the failing test or step.
3. Decide:
   - **Fix**: real bug. Open a normal WorkItem.
   - **Quarantine**: known flaky test that needs investigation later.
     Tag with `@pytest.mark.flaky` / `test.skip` / equivalent and
     comment on the issue with a link to the tracking ticket.
   - **Infra**: it's the runner / network / external service. File
     an infra ticket and close.
4. Close the flake-triage issue when the underlying cause is on
   somebody's plate or merged.

The skill does **not** auto-close these issues; that's a human
signal that the work is owned.

## Out of scope (today)

- Job-level granularity (rank "test (ubuntu-latest, node-20)" rather
  than "CI"). Possible follow-up — needs an extra API call per run.
- Test-name parsing.
- Quarantine PRs (auto-add `@pytest.mark.skip` etc.).
- Slack/email notifications.
- Cross-workflow correlation (e.g. "these three workflows always
  flake on the same SHA").

## See also

- [`.claude/skills/flake-triage/SKILL.md`](../../.claude/skills/flake-triage/SKILL.md) — operational checklist.
- [`scripts/skills/flake-triage-rank.sh`](../../scripts/skills/flake-triage-rank.sh) — rank script.
- [`scripts/test/flake-triage-rank-smoke.sh`](../../scripts/test/flake-triage-rank-smoke.sh) — synthetic-fixture tests.
- [`.factory/schedule.yml`](../../.factory/schedule.yml) — the `nightly-flake-triage` example.
- [`docs/skills/dep-upgrade.md`](./dep-upgrade.md) — sibling skill, similar shape.
