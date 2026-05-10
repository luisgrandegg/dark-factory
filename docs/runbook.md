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

## Claude Code on the web

Web sandboxes start with no `gh`, no `yq`, and no GitHub credentials.
The repo's `SessionStart` hook installs `gh` and `yq` from apt on the
first session in a container; both are cached for subsequent sessions.

You still need to provide auth. In claude.ai/code → **Environments** →
edit the environment for this repo → **Environment variables**, set:

| Name           | Value                                                   |
| -------------- | ------------------------------------------------------- |
| `GITHUB_TOKEN` | A PAT with `repo`, `workflow`, and `issues` scopes      |

`gh` reads `GITHUB_TOKEN` (or `GH_TOKEN`) automatically — no `gh auth
login` needed. The session header from the hook tells you whether auth
is healthy each session.

If you need to install other tools the factory will reach for (e.g. a
language toolchain so the implement station can run tests), extend
`.claude/hooks/session-start.sh` with another `apt-get install` line
guarded by `[[ "${CLAUDE_CODE_REMOTE:-}" == "true" ]]`.

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
scripts/factory/lock-release.sh
```

This writes a tombstone to `lock.json` on `factory/state`. The next
tick reads `released: true` and proceeds. Always prefer this over
deleting the file by hand.

### Re-run a failed station

The orchestrator does not retry automatically beyond
`budgets.perWorkItem.maxRetries` (default 3). To re-run a station for a
specific WorkItem outside that, edit its labels back to the previous
stage and `/factory-tick`:

```bash
gh issue edit <id> --remove-label "stage:escalated" \
                   --add-label "stage:plan"   # or wherever
# E.g. an item that escalated out of QA and you've fixed the test plan
```

The ledger keeps the failed Run; the next tick adds another with the
new attempt. Don't edit the ledger.

### Bump a budget

Budgets live in `.factory/policy.yml` on `main`, in the `budgets:`
block. Edit on a `claude/<slug>` branch, open a PR, merge. Do not
patch them at runtime — the ledger's daily roll-up is computed
against the policy at the time of each tick, and runtime patches
leak inconsistency into the audit trail.

If the day cap is tripped *right now* and you need to ship one more
WorkItem before midnight UTC, the supported escape hatch is to bump
the cap on a PR and merge it; the next tick reads the new value.

### Fix a corrupt stage-label state

Multiple `stage:*` labels on one issue is corrupt state (invariant
#3). To recover:

1. Decide which stage the issue actually is in. Read the most recent
   intake/spec/plan/qa comment; the latest one wins.
2. Remove the stale labels with `gh issue edit <id> --remove-label
   "stage:<wrong>"`.
3. Comment on the issue explaining the recovery.

The doctor script lists corrupt items at the top of its report so
you see them every morning.

### Spin up a throwaway test factory

When you want to validate a change to the orchestrator without
risking a real factory, use the seed script:

```bash
scripts/seed-test-repo.sh <new-repo-name>
```

It forks the template into a fresh repo under your account and runs
`setup.sh` against it. Tear it down with `gh repo delete` when done.
See [`docs/testing.md`](./testing.md) for what to verify.

### Replace a bad PR

If an opened PR is wrong (touched the wrong files, opened against
the wrong base), close it with a comment, swap the labels back to
`stage:implement`, and let the next tick re-open. Do not force-push
to rewrite. The integrate sealer does not merge force-pushed history.

```bash
gh pr close <pr> --comment "superseding; see <new-pr> when filed"
gh issue edit <id> --add-label "stage:implement" \
                   --remove-label "stage:qa"
```

## State surfaces

### `factory/state` branch

- `lock.json` — multi-session lock. `held: false` is the resting
  state. The schema is in [ADR 0003](./adrs/0003-concurrency-model.md).
- `budget.json` — rolling daily roll-up. `days[<utc-date>]` carries
  `tokens`, `toolCalls`, `wallSeconds` for each WorkItem. Computed by
  `scripts/factory/ledger-write.sh end`; never edit by hand.
- `dashboard/index.html` (Phase 3) — generated by `dashboard.sh`. Not
  yet wired in.

This branch is rewritten frequently; do not depend on its history.

### `factory/ledger` branch

Append-only. Layout:

```
runs/YYYY/MM/DD/<ulid>.json    # one Run per file
runs/by-workitem/<id>.jsonl    # append-only index per WorkItem
artifacts/YYYY/MM/DD/<ulid>.md # one snapshot per artefact comment
```

Run records are immutable once written; artefacts are immutable
snapshots of intake/spec/plan/qa/implement comments at the moment
they were posted (the comments themselves are mutable). To compact,
open a new branch (`factory/ledger-archive-<year>`) rather than
editing in place.

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
