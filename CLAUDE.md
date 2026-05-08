# CLAUDE.md — project memory

This file is loaded into every Claude Code session that runs in this repo.
Read it before doing anything that touches the factory.

The full design lives in [`docs/`](./docs); this file is the operating
contract for sessions that act on it. Stage-specific guidance (commit
shape, PR shape, comment templates) lives in the agent or skill that
runs that stage, not here — CLAUDE.md is loaded into every tick, so
keep it tight.

## What this repo is

A **dark factory** for software: a Claude Code session is the foreman, and
WorkItems flow through `intake → spec → plan → implement → qa → integrate
→ done`. State lives in the repo; ADRs in `docs/adrs/` are the source of
truth for *why*.

Phase 1 is implemented. Phase 2+ items are still in `docs/roadmap.md`.

## Invariants — never violate

1. **`main` is PR-only.** Never push to `main` directly. Product changes
   travel on `claude/<slug>` branches and through PRs, like a normal
   contributor.
2. **State and ledger writes go through the GitHub API**, not through a
   working copy. The orchestrator never holds a checkout of
   `factory/state` or `factory/ledger`.
3. **One `stage:*` label per WorkItem** at any time. Transitions must be
   in `policy.stages.transitions`. Multiple stage labels = corrupt state
   = escalate.
4. **Every Run gets a ledger entry** — even the ones that fail or get
   interrupted. Use `scripts/factory/ledger-write.sh start` and `... end`
   on both sides of every station invocation.
5. **Approval-gate paths require human review.** `infra/**`,
   `migrations/**`, `.github/workflows/**`, `.factory/policy.yml`,
   `.claude/settings.json`. The integrate workflow refuses to seal a PR
   that touches these.
6. **No `ANTHROPIC_API_KEY`** anywhere in the factory (ADR 0004). All
   inference goes through the operator's Claude Code session.
7. **Escalate before guessing.** A confused state is `stage:escalated +
   needs-human + a comment that describes what you saw`.

## Where to look

| You want to                                       | Read                                |
| ------------------------------------------------- | ----------------------------------- |
| Advance the queue                                 | `/factory-tick` → `factory` skill   |
| See what each station does                        | `.claude/agents/<station>.md`       |
| Commit / PR / branch shape for the implement step | `.claude/skills/factory/SKILL.md` (implement section) |
| Change a budget, allowlist, gate, or branch name  | `.factory/policy.yml`               |
| Understand a Run record                           | `.factory/ledger-schema.md`         |
| Recover from a stuck lock                         | `scripts/factory/lock-release.sh`   |
| Re-run setup or recreate a missing factory branch | `scripts/setup.sh`                  |
| Decide whether a station should exist             | the relevant ADR in `docs/adrs/`    |
| Add a new station, agent, or skill                | `docs/contributing.md`              |

## When you don't know what to do

Stop and ask. The escalation path is cheap:

```
gh issue edit <id> --add-label "needs-human,stage:escalated" \
                   --remove-label "stage:<current>"
gh issue comment <id> --body "Escalating: <one paragraph>"
```

Then close out the Run with `--status escalated --reason <vocab>` and
move on. A human reading the issue is always better than a wrong autonomous
action.
