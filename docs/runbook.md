# Runbook

Operational guide for someone with the on-call hat for a dark-factory
install. Assumes the factory is set up (`scripts/setup.sh` ran cleanly)
and at least one tick has happened. For "what is this thing" read
[`README.md`](../README.md); for "why is it shaped like this" read
[`docs/adrs/`](./adrs/). For escalations specifically, see
[`escalation-playbook.md`](./escalation-playbook.md).

## Cheat sheet

| You see                                          | Do                                                    |
| ------------------------------------------------ | ----------------------------------------------------- |
| Factory hasn't ticked in a while                 | `scripts/doctor.sh` — usually the lock or auth        |
| `stage:escalated` issue showed up                | [Escalation playbook](./escalation-playbook.md)       |
| `lock.json` says held but no session is running  | Stale lock; next tick steals it. Or force release.    |
| CI red on a PR the factory opened                | Read the test plan and contract-check comments first  |
| Secret-scan check failed on a PR                 | Treat the diff as compromised — see "secret leak" §   |
| `budget.json` shows the day cap tripped          | Either bump the cap (PR), or wait for UTC roll-over   |
| Multiple `stage:*` labels on one issue           | Corrupt state — `doctor.sh` lists them; escalate      |
| Two sessions appear to be ticking                | Lock is broken; investigate before forcing            |

If you're new to the runbook, run `scripts/doctor.sh` first. Most "what's
wrong" questions answer themselves once you see its output.

## Daily checks

Once a day, ideally before opening new issues:

1. `scripts/doctor.sh` — should be all green.
2. Skim `gh issue list --label "stage:escalated"`. If any are stale (>
   24 h), [resolve them](./escalation-playbook.md).
3. Glance at [`budget.json`](#budgetjson) on the state branch to see
   yesterday's spend. Big spike → look at the corresponding ledger Runs.

```bash
gh api "repos/:owner/:repo/contents/budget.json?ref=factory/state" \
  --jq .content | base64 -d | jq '.days'
```

## Common procedures

### Recover a stuck lock

`scripts/factory/lock-acquire.sh` exits 1 with `lock held by <session>`
when another session holds it. The TTL (`policy.concurrency.lockTtlMinutes`,
default 10 min) bounds this — once `expiresAt` is in the past the next
tick steals the lock automatically and labels the WorkItem with
`factory:lock-stolen`.

If you need to release it before the TTL expires (e.g. you know the
holding session is dead), run:

```bash
FACTORY_FORCE=1 scripts/factory/lock-release.sh
```

This is the only blessed way to forcibly clear `lock.json`. Never
manually edit the state branch.

### Re-run a failed station

The factory only retries automatically while
`policy.budgets.perWorkItem.maxRetries` allows it. To re-run after the
cap, remove the `stage:escalated` label and add the appropriate stage
label — but only after you've fixed whatever caused the failure (read
the last Run in `runs/by-workitem/<id>.jsonl`).

```bash
# E.g. an item that escalated out of QA and you've fixed the test plan
gh issue edit <id> --remove-label "stage:escalated,needs-human" \
                   --add-label "stage:qa"
```

The legal "from-escalated" transitions are listed in
`policy.stages.transitions["stage:escalated"]`. The orchestrator refuses
moves not on that list.

### Bump a budget

Budgets live in `.factory/policy.yml` under `budgets.*`. Editing the
file lands on `main` via PR (and trips the `policy.yml` approval gate,
so a human review is mandatory). The change takes effect on the next
tick — there is no cache.

Per-day caps reset at UTC midnight. If you've tripped the day cap and
need to keep going today, the right tool is the PR; there is no
emergency override flag.

### Fix a corrupt stage-label state

If `doctor.sh` flags an issue with multiple `stage:*` labels, do this:

1. `gh issue view <id> --json labels` — see the full list.
2. Decide which stage is correct from the most recent ledger Run for
   that workitem (`runs/by-workitem/<id>.jsonl`).
3. Remove every `stage:*` label except the right one.
4. If you can't tell, escalate it (see playbook) and let a human read
   the comments.

### Spin up a throwaway test factory

When you want to exercise a guardrail without polluting the real
factory's history (e.g. testing the secret-scan workflow with a fake
credential, or tripping an `approvalGates` path on purpose), don't do
it here. Use:

```bash
scripts/seed-test-repo.sh --name dark-factory-test
```

That creates a private GitHub repo, pushes the current tree as a single
seed commit, clones it locally, and runs `setup.sh` for you. Teardown
is a single `gh repo delete` when you're done. See the script's
`--help` for flags.

### Replace a bad PR

If a PR opened by the factory is wrong in a way that can't be fixed by
another tick (e.g. it solved the wrong problem because the spec was
wrong), the cleanest path is:

1. `gh pr close <pr> --delete-branch`
2. Edit the spec comment on the issue (or post a follow-up comment that
   supersedes it; the plan station reads the latest one).
3. `gh issue edit <id> --remove-label "stage:qa,stage:implement,stage:integrate" --add-label "stage:plan"`

The factory will pick it up on the next tick from `stage:plan`.

## State surfaces

### `factory/state` branch

Mutable. The orchestrator rewrites these on every tick:

- `lock.json` — multi-session lock (ADR 0003).
- `budget.json` — rolling per-day usage (Phase 2). Bounded to ~14 days.
- (future) dashboard snapshots.

Never push to this branch from a working copy. All writes go through
the GitHub Contents API; the only blessed clients are
`scripts/factory/*.sh`.

### `factory/ledger` branch

Append-only. One Run per file:

- `runs/YYYY/MM/DD/<ulid>.json`
- `runs/by-workitem/<id>.jsonl` — index per WorkItem; cheap reads.

Schema in [`.factory/ledger-schema.md`](../.factory/ledger-schema.md).
Files here are immutable; if you "fix" a Run, do it by appending a
correction, not by editing.

## Failure-mode index

| Symptom                                   | First thing to check          | Likely cause                     |
| ----------------------------------------- | ----------------------------- | -------------------------------- |
| `/factory-tick` returns "lock held"       | `scripts/doctor.sh`           | Stale lock; wait or force-release |
| Issue advanced once, then stalled         | last Run's `failureReason`    | Budget, CI red, or gated path    |
| PR opened but never moved past `stage:qa` | contract-check verdict        | `wait` (CI pending) or `retry`   |
| `stage:integrate` never seals             | the integrate workflow run    | secret-scan failed or gated path |
| `gh auth` expired mid-tick                | `gh auth status`              | Re-login; rerun `/factory-tick`  |
| `budget.json` won't parse                 | doctor's "budget.json" check  | Mid-write crash; delete it       |

Anything not on this list and not obvious — escalate.

## Where to look (deeper)

- `.factory/policy.yml` — budgets, allowlist, gates, escalation
  defaults.
- `.factory/ledger-schema.md` — Run record schema.
- `docs/architecture.md` — components and workflows.
- `docs/adrs/` — decisions and rationale.
- `docs/escalation-playbook.md` — what to do when an issue gets
  escalated.
