# CLAUDE.md — project memory

This file is loaded into every Claude Code session that runs in this repo.
Read it before doing anything that touches the factory.

The full design lives in [`docs/`](./docs); this file is the operating
contract for sessions that act on it.

---

## What this repo is

A **dark factory** for software: a Claude Code session is the foreman, and
WorkItems flow through `intake → spec → plan → implement → qa → integrate
→ done`. State lives in the repo; ADRs in `docs/adrs/` are the source of
truth for *why*.

Phase 1 is implemented. Phase 2+ items are still in `docs/roadmap.md`.

---

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

---

## Where to look

| You want to                                       | Read                                |
| ------------------------------------------------- | ----------------------------------- |
| Advance the queue                                 | `/factory-tick` → `factory` skill   |
| See what each station does                        | `.claude/agents/<station>.md`       |
| Change a budget, allowlist, gate, or branch name  | `.factory/policy.yml`               |
| Understand a Run record                           | `.factory/ledger-schema.md`         |
| Recover from a stuck lock                         | `scripts/factory/lock-release.sh`   |
| Re-run setup or recreate a missing factory branch | `scripts/setup.sh`                  |
| Decide whether a station should exist             | the relevant ADR in `docs/adrs/`    |

---

## Conventions

### Branches

- Product changes: `claude/<short-slug>-<issue#>`. Created by the
  implement station; deleted by the integrate sealer on merge.
- Factory state: `factory/state` (mutable; periodic squash is fine).
- Factory ledger: `factory/ledger` (append-only; never rewrite history
  in place — archive into `factory/ledger-archive-<yyyy>` instead).

### Commits

- One logical change per commit. The implement station should commit per
  task in the plan, not one mega-commit at the end.
- Subject in imperative mood, < 70 chars.
- Body explains the *why*, not the *what*. The diff already shows the
  what.
- Never amend a published commit; always make a new one.

### PRs

- Title mirrors the issue title. Body must `Closes #<id>` and link the
  spec and plan comments.
- Open as draft; the implement station marks ready only after the
  intended diff is pushed. The integrate sealer flips ready and
  enables auto-merge.
- Squash-merge is the default; the sealer enforces it.

### Comments on issues

- Each station posts exactly one artefact comment per Run, using the
  template in its agent definition. The Run id appears in the comment so
  ledger and discussion cross-reference.

---

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

---

## Adding a new station, agent, or skill

1. Write the ADR first if the change is structural (new station, new
   storage surface, new lock). ADRs live in `docs/adrs/` and are
   immutable once accepted.
2. Add the agent definition to `.claude/agents/<name>.md` with a tight
   `tools:` list and a `description:` the foreman can route on.
3. If the station spawns its own subagents, every spawn must pass
   `parentRunId` so the ledger roll-up doesn't double-count.
4. Update `.factory/policy.yml` to register the stage in `stages` and
   any new budgets in `budgets.perStation`.
5. Update the factory skill (`.claude/skills/factory/SKILL.md`) to teach
   the foreman about the new station.
6. Smoke-test by filing a `factory:smoke` issue and watching it land.
