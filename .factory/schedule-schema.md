# Schedule schema

`.factory/schedule.yml` declares **recurring jobs**: WorkItem
templates that the factory files as GitHub issues on a schedule. The
`recurring-jobs.yml` workflow runs hourly, evaluates each job, and
files the issue when due, then records the fact in
`schedule-state.json` on the state branch so the next tick doesn't
double-fire.

The factory itself doesn't run on any cron — the orchestrator is
operator-driven (ADR 0001). Recurring jobs are just a way to *file*
issues that the operator's next `/factory-tick` will then process
through the normal pipeline.

## File

```yaml
version: 1

jobs:
  - id: <slug>
    title: "<issue title>"
    body: |
      <issue body markdown>
    every: hourly|daily|weekly|monthly
    onHour:        <0..23>          # default 13 UTC
    onDayOfWeek:   <monday..sunday> # weekly only
    onDayOfMonth:  <1..28>          # monthly only
    labels:        ["stage:intake", "priority:p3", "factory:recurring", ...]
    enabled:       true|false       # default true
```

## Fields

| Field          | Required        | Notes                                                              |
| -------------- | --------------- | ------------------------------------------------------------------ |
| `id`           | yes             | Stable slug, lowercase, `[a-z0-9-]`. Used as the state-file key.   |
| `title`        | yes             | Issue title. The current UTC date is appended in parentheses.      |
| `body`         | yes             | Issue body. Treat as a brief for the implement station.            |
| `every`        | yes             | `hourly`, `daily`, `weekly`, `monthly`.                            |
| `onHour`       | optional        | UTC hour the job is eligible to fire. Default `13`.                |
| `onDayOfWeek`  | weekly only     | `monday`..`sunday`. Required when `every: weekly`.                 |
| `onDayOfMonth` | monthly only    | `1`..`28` (avoiding month-end ambiguity).                          |
| `labels`       | yes             | Must include exactly one `stage:*` label (usually `stage:intake`). |
| `enabled`      | optional        | Default `true`. Set `false` to pause without deleting.             |

## Eval logic (when does a job fire?)

A job is considered **due** at workflow tick time `now` if all of:

- `enabled` is `true`,
- `onHour` is satisfied (`now.hour >= onHour`, in UTC),
- the cadence guard is satisfied:
  - `hourly`: more than 50 minutes since `lastFiredAt`,
  - `daily`:  the job has not fired today (UTC date),
  - `weekly`: today is `onDayOfWeek` and the job has not fired this week (Mon-anchored),
  - `monthly`: today is `onDayOfMonth` and the job has not fired this month.

The 50-minute slack on `hourly` absorbs Actions cron jitter without
double-firing.

## State file

Path: `schedule-state.json` on the state branch (default `factory/state`).

```json
{
  "schemaVersion": 1,
  "jobs": {
    "weekly-deps": {
      "lastFiredAt": "2026-05-04T13:00:12Z",
      "lastIssue":   142
    }
  }
}
```

Written via the GitHub Contents API on every fire (ADR 0002 — no
working copy of the state branch).

## Disabling a job temporarily

Set `enabled: false`. The job stays in version control (so the
operator can see what's paused and why) and resumes the next time
the workflow ticks after `enabled` flips back to `true`.

## Removing a job

Delete it from the file. Stale entries in `schedule-state.json` are
ignored; they harm nothing but you may want to prune them on a
maintenance pass.
