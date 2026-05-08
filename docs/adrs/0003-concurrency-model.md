# 0003 — Concurrency model

- **Status:** Accepted
- **Date:** 2026-05-08

## Context

Multiple WorkItems will be in flight. Within a single WorkItem, the plan
station may emit several tasks. We need rules for what runs in parallel,
what serialises, and how to keep concurrent agents from corrupting each
other's state.

Forces:

- Worktree isolation is already a guardrail (`architecture.md §5`): each run
  in its own branch.
- GitHub Actions has its own `concurrency:` primitive, plus a per-account
  job cap.
- Agents are non-deterministic. Two agents working the same files on the
  same WorkItem produce harder-to-merge conflicts than one agent doing it
  sequentially.
- Budgets are enforced per-WorkItem and per-day. Unbounded parallelism breaks
  budget enforcement.
- v1 throughput target is small (single-digit WorkItems in flight).

## Decision

Three layers of concurrency, each with an explicit cap:

### 1. Cross-WorkItem: parallel, capped

Different WorkItems run in parallel. The cap is `policy.maxConcurrency` (v1
default: **3**). Implementation: every station workflow uses

```yaml
concurrency:
  group: factory-global
  cancel-in-progress: false
```

with a job-level matrix gated by a "slot" check that reads the count of
in-flight WorkItems from labels and skips if at cap. Items waiting on a slot
sit in `stage:queued`.

### 2. Per-WorkItem: serial across stations

A single WorkItem only runs one station at a time. Implementation:

```yaml
concurrency:
  group: factory-workitem-${{ github.event.issue.number }}
  cancel-in-progress: false
```

This makes the state machine in ADR 0002 safe: there is never a race between
two workflows trying to swap the `stage:*` label on the same issue.

### 3. Within Implement: serial in v1, parallel later

The plan subagent may produce several tasks. **In v1, the implement station
processes them sequentially on a single branch.** Reasons:

- Merge conflicts between sibling task branches dominate the savings from
  parallelism at our throughput.
- Cost attribution and budget enforcement are simpler with one active branch
  per WorkItem.
- Worktree isolation only protects the filesystem; it does not protect a
  shared review surface.

Phase 4 introduces parallel task implementation behind a policy flag
(`policy.parallelImplement: true`) once we have the budget telemetry to keep
it safe. Until then the plan agent is told to emit a linear plan.

### Cancellation

`cancel-in-progress: false` everywhere. We never want a later event to kill
an in-flight agent run mid-edit; we'd rather queue the new event. Budget
overrun is the foreman's job, not Actions'.

## Consequences

Positive:

- The state machine cannot race itself.
- The `maxConcurrency` knob is a single, well-understood throttle.
- Cost telemetry stays interpretable in v1 (one active run per WorkItem).
- Migrating to a long-running orchestrator later (per ADR 0001) is mostly a
  matter of replacing the slot check; the per-WorkItem and per-station
  invariants carry over.

Negative / accepted costs:

- v1 throughput is bounded by serial implementation. Acceptable: side-project
  scale.
- The slot mechanism via labels is a polling pattern. The 5-minute `tick.yml`
  (ADR 0001) wakes queued items; worst-case latency is ~5 min.
- `cancel-in-progress: false` means a runaway label-flip storm could queue
  many no-op runs. The tick workflow deduplicates before scheduling.

## Alternatives considered

- **Unbounded parallelism, rely on Actions caps.** Rejected: budgets become
  impossible to enforce and merge conflicts dominate.
- **Per-task parallelism from day one.** Rejected for v1; parked for Phase 4
  with a policy flag.
- **Cancel-on-new-event.** Rejected: corrupts mid-edit work and undermines
  the run ledger.
