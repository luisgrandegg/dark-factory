# 0001 — Orchestrator runtime

- **Status:** Accepted
- **Date:** 2026-05-08
- **Supersedes:** —

## Context

The foreman has to: pick up new WorkItems, route them through stations, spawn
agents, enforce budgets, retry on failure, and surface results. We need a host
to actually run that loop.

Initial framing considered:

1. **GitHub Actions only.** Each station is a workflow; transitions are
   driven by labels and `workflow_dispatch`.
2. **Long-running process** (Node/Python service on a VM).
3. **Claude Code session as orchestrator** — the foreman *is* a Claude Code
   session; stations are subagents/skills it spawns; state lives in the repo.

Forces:

- The whole point of the template is **clone-and-go**. Anything that
  requires hosting infra fights that goal.
- Operating cost matters. A side-project factory that burns Anthropic API
  spend on every event plus Actions minutes per workflow run will be
  abandoned within a week. The user already pays for Claude Code; we should
  ride that subscription instead of adding per-call API spend on top.
- We want a complete audit trail, replayable from the repo alone.
- Concurrency is modest (single-digit WorkItems in flight for v1).
- Live dashboards are nice, but Phase 3 — not Phase 1.
- The factory must tolerate the operator closing their laptop. It does
  **not** have to make progress while the laptop is closed.

## Decision

**The orchestrator is a Claude Code session.** It is portable across two
hosts, and the implementation must support both:

- **Claude Code on the web** — a long-lived background session subscribed to
  the repo's PR / issue activity. It wakes on events and ticks the queue.
  This is the "lights-out" mode.
- **Local Claude Code CLI** — the operator opens their laptop, runs
  `/factory-tick` (or `/factory-run`), and the session advances the queue
  until it stalls, then exits. This is the "operator on shift" mode.

Both modes execute the same code: a `factory` skill plus a slash command
that drives the loop. Switching hosts is a matter of where the session is
running, not what it does.

Cost shape: orchestrator and subagent invocations consume the operator's
Claude Code subscription, not the Anthropic API. We do not call the API
directly from the factory.

GitHub Actions are used **sparingly**, only for things that genuinely must
run server-side without a Claude Code session present:

- CI: tests, lint, type-check on PR commits (the project's own pipeline).
- Auto-merge sealing: a tiny workflow that flips merge state once a PR has
  the `stage:integrate` label and all checks are green.
- Optional: a webhook → Claude Code on the web nudge, if/when that
  integration is exposed.

No "intake.yml", "plan.yml", "implement.yml", or "qa.yml" workflows. Those
stations run inside the orchestrator session.

### The loop

A single `factory-tick` invocation does, roughly:

1. Read state: pull the issues + PRs filtered by `stage:*` labels, fetch
   `lock.json` and `budget.json` from the state branch, read the most
   recent entries from the ledger branch (ADR 0002).
2. Acquire the multi-session lock on the state branch (ADR 0003); back
   off if another session holds it.
3. Pick the highest-priority actionable WorkItem honouring concurrency.
4. Open a Run ledger entry on the ledger branch (ADR 0004).
5. Spawn the station's subagent / skill.
6. On completion: update the WorkItem's labels, post the artefact
   comment, finalise the ledger entry on the ledger branch, refresh
   `budget.json` on the state branch.
7. Release the lock and loop until: queue empty, budget hit, or operator
   interrupts.

In web mode, the loop sleeps between ticks and is woken by PR-activity
subscriptions. In local mode, the loop runs straight through and the
session ends when the queue drains.

### Re-entrancy

Because the state of the factory is fully in the repo (ADR 0002), any
session — web or local — can pick up where another left off. We treat the
orchestrator as **disposable**: kill the session, start a new one, no data
loss. Concurrency between two simultaneous orchestrator sessions is handled
by ADR 0003.

## Consequences

Positive:

- **No Anthropic API spend for the factory itself** — orchestrator and
  subagent calls live inside the user's Claude Code subscription.
- **No Actions minutes for orchestration** — only for CI, which the user
  was already going to pay for.
- "Use this template" produces a working factory with no extra hosting:
  open Claude Code, run `/factory-tick`.
- The web/local split gives a graceful degradation path: lights-out when
  it's working, lights-on when the operator wants to babysit.
- Faster reaction time than Actions cold-starts; the session is already
  warm.

Negative / accepted costs:

- **No automatic progress while no session is running.** If the web session
  is paused and nobody opens the laptop, work just queues up. Acceptable
  per the user's statement that "human opens the laptop and starts the
  factory" is fine for v1.
- The state model has to be bullet-proof — there is no in-memory queue. Two
  sessions that race must converge. ADR 0003 handles this.
- We lose the per-event audit trail that Actions runs give for free. The
  Run ledger (ADR 0002, 0004) replaces it.
- We depend on Claude Code session features (subagents, skills, PR-activity
  subscriptions for the web case). When those interfaces change, the
  orchestrator changes.
- Live dashboards remain out of reach until Phase 3. The static control
  room is regenerated at the start of each tick.

## Alternatives considered

- **GitHub Actions only.** Rejected: every station hop pays Actions cold
  start + Anthropic API tokens. For a hobby-scale factory the recurring
  cost dominates the value. Also requires writing six near-identical
  workflows.
- **Long-running process on a VM.** Rejected for v1: requires the user to
  host something, undermines clone-and-go. Reconsider in a later ADR if
  Phase 3's live dashboard demands it.
- **Hybrid Actions + session.** Considered. Rejected as a starting point:
  two systems to keep in sync. The minimal Actions footprint above (CI +
  merge-seal) is small enough not to count as "hybrid orchestration".
