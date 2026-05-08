---
name: factory
description: The orchestrator loop. Acquires the multi-session lock, picks the highest-priority actionable WorkItem, advances it one station, releases the lock, and loops until idle, budget-bound, or interrupted. This is what `/factory-tick` calls.
---

# Factory orchestrator loop

You are the **foreman** of the dark factory. Your job is to advance
WorkItems through the state machine described in `.factory/policy.yml`.
Read that file before doing anything else; it is the source of truth for
budgets, allowlists, gates, and legal transitions.

This skill executes **one tick at a time**. A tick is: acquire lock →
pick an item → run one station → write the ledger → release lock. Loop
until the queue is idle or you hit a stop condition.

## Stations and who handles them

| Stage label       | Handler                                                |
| ----------------- | ------------------------------------------------------ |
| `stage:intake`    | spawn the **intake** subagent                          |
| `stage:spec`      | inline (this skill writes the spec comment directly)   |
| `stage:plan`      | spawn the **plan** subagent                            |
| `stage:implement` | the main session — open a worktree on `claude/<slug>`, follow the plan, push, open the PR |
| `stage:qa`        | spawn the **contract-check** subagent (mechanical: tests + CI + path gates) |
| `stage:integrate` | no agent — the GitHub Action `integrate.yml` seals the merge once CI is green |
| `stage:done`      | terminal                                               |
| `stage:escalated` | terminal until a human acts                            |

## The tick loop

Run the steps below, in order. Each numbered step is one logical block;
do not interleave them.

### 1. Read policy

```
cat .factory/policy.yml
```

Extract: `state.branch`, `ledger.branch`, `concurrency.maxConcurrency`,
`concurrency.lockTtlMinutes`, `budgets.*`, `stages.transitions`,
`approvalGates`. Memorise the legal transitions — you will refuse any
move that is not on the list.

### 2. Acquire the lock

```
scripts/factory/lock-acquire.sh
```

- Exit 0 → you hold the lock; continue.
- Exit 1 → another live session holds it. **Stop the tick** and report
  `lock-held-by <session> until <epoch>` to the user.
- Exit 2 → transport error. **Stop**, report, do not retry — the next
  tick will try again.

If `FACTORY_LOCK_STOLEN_FROM` is set in the environment, immediately
write a ledger entry tagged `factory:lock-stolen` (status `success`,
station `intake`, agent `skill:factory`, reason field set to
`lock-stolen`) so the audit trail records the recovery.

### 3. Read the queue

```
gh issue list --label "stage:intake,stage:spec,stage:plan,stage:implement,stage:qa,stage:queued" \
              --state open --json number,title,labels,createdAt --limit 50
```

For each issue, derive its current stage from the single `stage:*` label
present and its priority from `priority:*`. An issue with multiple
`stage:*` labels is a corrupt state — escalate it (`needs-human`,
`stage:escalated`, comment "multiple stage labels detected") and skip.

### 4. Count concurrency

Items in `stage:intake|spec|plan|implement|qa|integrate` are "active".
If the active count is at or above `policy.concurrency.maxConcurrency`,
new `stage:queued` items stay queued. Otherwise the highest-priority
queued item is promoted to `stage:intake` first.

### 5. Pick the WorkItem

Order by priority (p0 > p1 > p2 > p3), then by `createdAt` ascending.
Among equal-priority items, prefer one whose stage is **closer to
done** — finish what's in flight before starting new work.

### 6. Check budgets

For the chosen WorkItem, fetch its prior runs from the ledger via
`runs/by-workitem/<id>.jsonl` on the ledger branch:

```
gh api "repos/:owner/:repo/contents/runs/by-workitem/<id>.jsonl?ref=<ledger-branch>" \
  | jq -r .content | base64 -d
```

Sum `usage.toolCalls`, `usage.wallSeconds`, retries. If any
`policy.budgets.perWorkItem.*` cap is exceeded, transition the item to
`stage:escalated` with `failureReason: budget` in the ledger and a
comment explaining which cap tripped. Continue to step 8 (release lock).

Also check the day-level rollup at `budget.json` on the state branch.
Same response if that's exceeded — escalate, then release.

### 7. Run the station

Open the Run record:

```
RUN_ID=$(scripts/factory/ledger-write.sh start \
  --workitem <id> --station <station> --agent <agent>)
```

Then run the station handler from the table above. **Pass `RUN_ID` to
any subagent you spawn**; the subagent quotes it back into its artefact
comment (the ledger and the comment cross-reference each other).

#### intake / plan / qa

Spawn the corresponding subagent with the Agent tool. The subagent
reads, writes its artefact comment, swaps labels, and prints a one-line
JSON summary to stdout. Capture that summary; it tells you the next
state and feeds the ledger.

The QA station is **only** `contract-check` in Phase 1 — a mechanical
verifier that runs the test plan's checks against a worktree on the
PR head, reads project CI, and matches the diff against
`policy.approvalGates` plus explicit out-of-scope paths from the spec.
Phase 1 ships **no subjective code-review subagent**: linters, type
checkers, and (Phase 2) secret scanners catch what's worth catching
deterministically; an LLM doing a second-pass diff read pays a high
token cost to produce mostly-noise verdicts. See `docs/architecture.md`
for the full reasoning. Phase 2 brings reviewers back when they have
a deterministic trigger (security-review on `infra/**`, dependency-
review on lockfile changes, etc.).

#### spec (inline)

The spec station does not have a dedicated subagent in Phase 1. You
write the spec comment yourself, in this shape:

```
**Spec — <yyyy-mm-dd>**

**Goal**
<one sentence in user-visible language>

**Acceptance criteria**
- <bullet> (each must be objectively checkable)

**Out of scope**
- <bullet>

**Risks**
- <bullet, or "none">

_Run id: <RUN_ID>_
```

Then swap labels `stage:spec` → `stage:plan`.

#### implement

The main session does the work. The plan station did **not** prescribe
files or tasks — it produced a **test plan** (a list of objective checks
plus regression checks). The implement agent owns the strategy; the test
plan is the contract.

##### Branch, commit, and PR shape

These conventions live here because implement is the only station that
creates branches, commits, or PRs in Phase 1. Don't re-state them in
CLAUDE.md — every tick of every stage would pay the token cost.

- **Branch:** `claude/<short-slug>-<issue#>`. Created by this step;
  deleted by the integrate sealer on merge. The slug is derived from
  the issue title (lowercase, hyphenated, ≤ 40 chars).
- **Commits:** one logical change per commit — commit per task as you
  satisfy each check, not one mega-commit at the end. Subject in
  imperative mood, < 70 chars. Body explains the *why*; the diff shows
  the *what*. Never amend a published commit.
- **PR:** title mirrors the issue title. Body must `Closes #<id>` and
  link the spec and test plan comments. Open as **draft**; mark ready
  only after the intended diff is pushed. The integrate sealer flips
  ready and enables auto-merge; squash-merge is enforced there.

##### Steps

1. `slug=$(printf '%s' "<title>" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | head -c 40)`
2. `git switch -c "claude/${slug}-<id>"`
3. Read the test plan comment. Run every check **before** writing any
   code: most should fail (red baseline). Regression checks should pass.
4. Decide a strategy yourself. Make the smallest change that turns each
   check green without breaking regression checks. Stay strictly inside
   the test plan's "out of scope" boundary.
5. After each meaningful change, re-run the relevant check(s). When all
   primary checks pass and all regression checks still pass, commit per
   logical change. Push: `git push -u origin claude/${slug}-<id>`.
6. `gh pr create --draft --title "<title>" --body "<body>"` where the
   body links the issue ("Closes #<id>"), references the spec and test
   plan comments, and lists each check with its final status.
7. Comment on the issue with the PR number. Swap labels
   `stage:implement` → `stage:qa`.

If checks stay red after a reasonable attempt and retries are below
`budgets.perWorkItem.maxRetries`, log the Run as `failure` with
`failureReason: ci-failed` and leave the item in `stage:implement` for
the next tick. Otherwise escalate.

#### integrate

This skill never merges. The integrate workflow does. If you see an
item sitting in `stage:integrate` with green CI for more than one tick,
something is wrong with the workflow — escalate.

### 8. Close the Run

```
scripts/factory/ledger-write.sh end \
  --id "$RUN_ID" \
  --workitem <id> \
  --status success|failure|escalated \
  --tool-calls <n> --wall-seconds <n> \
  --from <prev stage label> --to <next stage label> \
  [--pr <n>] [--branch claude/...] [--files a,b,c] \
  [--reason <controlled-vocab>]
```

Use the controlled `failureReason` vocabulary from the schema:
`budget`, `lock-stolen`, `tool-denied`, `ci-failed`, `review-rejected`,
`interrupted`, `unknown`.

### 9. Release the lock

```
scripts/factory/lock-release.sh
```

This always runs, even on error. If you hit a hard error after step 2
and before step 9, **still call lock-release.sh** before exiting.

### 10. Loop or stop

Stop conditions (any one):

- The queue is empty (no `stage:*` issues other than `done`/`rejected`/`escalated`).
- The day-level budget would be exceeded by the next tick.
- The user interrupted (the slash command captured a signal).
- More than 10 ticks in this session — bail out and let the operator
  inspect; this is a sanity cap, not a feature.

Otherwise, loop back to step 2.

## Hard rules

- **Never** push to `main`. Product changes flow through `claude/<slug>`
  branches and PRs. State / ledger changes flow through the GitHub
  Contents API on their own branches.
- **Never** transition a label outside `policy.stages.transitions`.
- **Never** spawn a subagent that isn't in `.claude/agents/`.
- **Never** swallow a failure silently — every Run gets a ledger entry,
  even the ones that abort partway.
- If you encounter a state you can't safely act on, escalate
  (`stage:escalated` + `needs-human` + a comment describing what you
  saw). Do **not** guess.

## Reporting

At the end of the session, print a short summary to the user:
ticks executed, items advanced, items escalated, and the PR numbers
opened or merged. Keep it under 10 lines.
