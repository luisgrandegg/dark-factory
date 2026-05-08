# Escalation playbook

What to do when a WorkItem is in `stage:escalated`. Pair with
[`runbook.md`](./runbook.md) for general operational guidance.

## How escalation happens

The orchestrator (or a station agent) calls
`scripts/factory/escalate.sh` with a controlled `--reason`, which:

1. Swaps the current `stage:*` label for `stage:escalated`.
2. Adds `needs-human` (and assigns
   `escalation.defaultAssignee` from `policy.yml` if set).
3. Posts a structured comment with reason, detail, originating Run id.

The factory will not advance the WorkItem further until a human acts.

## Reasons (controlled vocabulary)

These are the only values the script accepts (and the only ones that
appear in the ledger's `failureReason` field):

| Reason            | Meaning                                                  | Default response                              |
| ----------------- | -------------------------------------------------------- | --------------------------------------------- |
| `budget`          | Per-WorkItem or per-day cap exceeded                     | [§ Budget exceeded](#budget-exceeded)         |
| `tool-denied`     | A required tool was on the deny list                     | [§ Tool denied](#tool-denied)                 |
| `gated-path`      | PR diff touched an `approvalGates` path                  | [§ Gated path touched](#gated-path-touched)   |
| `ci-failed`       | Project CI red after `maxRetries` attempts               | [§ CI red after retries](#ci-red-after-retries) |
| `review-rejected` | Human reviewer left a blocking review                    | [§ Review rejected](#review-rejected)         |
| `corrupt-state`   | Multiple `stage:*` labels, missing PR, etc.              | [§ Corrupt state](#corrupt-state)             |
| `secret-leak`     | `secret-scan.yml` workflow flagged a leaked credential   | [§ Secret leak](#secret-leak)                 |
| `interrupted`     | Operator killed the session mid-station                  | Just re-run `/factory-tick`                   |
| `unknown`         | The agent didn't recognise the failure mode              | Investigate manually                          |

## Resolution recipes

Every recipe ends in either *re-tagging the issue back into a stage* or
*closing it as out-of-scope*. The legal "from `stage:escalated`"
transitions are in `policy.stages.transitions["stage:escalated"]`:
`stage:intake`, `stage:plan`, `stage:implement`, `stage:qa`.

Generic re-tag pattern:

```bash
gh issue edit <id> --remove-label "stage:escalated,needs-human" \
                   --add-label "stage:<next>"
```

### Budget exceeded

1. Read the escalation comment to see which cap tripped.
2. If the cap is too low for legitimate reasons (the project is bigger
   than the budget assumes), bump it via PR to `.factory/policy.yml`.
   That PR will trip the `policy.yml` approval gate; merge it manually.
3. If the WorkItem itself is the problem (runaway, infinite-loop in the
   plan), close as out-of-scope and refile a smaller issue.
4. After the policy change merges, re-tag back to whatever stage the
   item escalated from.

### Tool denied

The agent tried to run a command the deny list refuses. This usually
means the spec is asking for something destructive that no station was
meant to do.

1. Re-read the spec. Does it really need that operation?
2. If yes — and it's safe — adjust the policy allowlist via PR. Don't
   bypass the hook.
3. If no, edit the spec to constrain the approach, then re-tag to
   `stage:plan` so the plan station can produce a different test plan.

### Gated path touched

The PR diff touched `infra/**`, `migrations/**`, `.github/workflows/**`,
or another `approvalGates` pattern. The factory deliberately stops here
because it cannot evaluate whether the change is safe.

1. Open the PR. Read the diff.
2. If the gated change is correct: review and merge it manually
   (the integrate sealer will not). Then close the issue.
3. If the gated change is incorrect or unintended: ask the operator to
   reduce the diff to non-gated paths. Re-tag to `stage:implement`.

### CI red after retries

The implement station tried `maxRetries` times and CI was still red.

1. Read the contract-check comment for the failing job names.
2. Run `gh pr checks <pr>` or open the failing job in the browser.
3. If the failure is a flake: re-tag to `stage:qa`; the next tick
   re-runs.
4. If the failure is real and the fix is small: push a commit to the
   PR yourself, then re-tag to `stage:qa`.
5. If the failure indicates a wrong plan: re-tag to `stage:plan`.

### Review rejected

A human left a blocking review on a PR.

1. Read the review.
2. If actionable: re-tag to `stage:implement` after summarising the
   feedback as a comment on the issue (the plan station reads the
   issue, not the PR).
3. If the change is unwanted entirely: `gh pr close <pr> --delete-branch`
   and close the issue with `stage:rejected`.

### Corrupt state

`scripts/doctor.sh` flagged either multiple `stage:*` labels or a state
the orchestrator can't reconcile.

1. `gh issue view <id> --json labels,state,title`
2. Look at the most recent ledger Run for this workitem to figure out
   what stage it actually was last in. The Run's `labelTransition.to`
   is the answer.
3. Remove every `stage:*` label except that one, leave `needs-human`,
   and re-investigate manually before clearing it.

### Secret leak

The `secret-scan.yml` workflow flagged a credential in the PR diff.
**Treat the diff as compromised.**

1. **Do not** merge the PR. **Do not** push another commit that fixes
   only the offending file — the secret is in git history.
2. Rotate the credential immediately at the source (whatever issued it).
3. `gh pr close <pr> --delete-branch` to take the branch out of git's
   reachability.
4. If the secret was in the issue body or a comment: edit it out, but
   assume it's already public.
5. Investigate how the agent got the credential into the diff. Likely
   a misconfigured test fixture or an envvar leaking. Fix the source
   and refile the issue from scratch.

## Closing the loop

When you re-tag an escalated item back into a working stage, post one
comment on the issue with:

- what was wrong (one sentence),
- what you did about it (one sentence),
- which stage you put it in.

That comment is what a future you (or the next operator) reads when the
same problem reappears. The escalation comment from the factory tells
you what tripped; your closing comment tells you what fixed it.

## When to give up

If the same WorkItem escalates twice for the same reason, stop. The
factory can't safely make this change. Close the issue with
`stage:rejected` and a comment explaining why; refile a smaller, more
constrained issue if the underlying need still matters.
