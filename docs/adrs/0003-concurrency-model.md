# 0003 — Concurrency model

- **Status:** Accepted
- **Date:** 2026-05-08

## Context

Multiple WorkItems will be in flight. Within a single WorkItem, the plan
station may emit several tasks. With ADR 0001 the orchestrator is a Claude
Code session — possibly more than one (a web background session and a
local operator session can both be alive). We need rules for what runs in
parallel, what serialises, and how to keep concurrent agents from
corrupting each other's state.

Forces:

- Worktree isolation is already a guardrail (`architecture.md §5`): each
  run in its own branch.
- The orchestrator is not GitHub Actions, so we can't lean on Actions'
  `concurrency:` primitive. The lock has to live in the repo or in
  something both hosts can see.
- Two simultaneous orchestrator sessions must not double-process the same
  WorkItem.
- Agents are non-deterministic. Two agents working the same files on the
  same WorkItem produce harder-to-merge conflicts than one agent doing it
  sequentially.
- Budgets are enforced per-WorkItem and per-day. Unbounded parallelism
  breaks budget enforcement.
- v1 throughput target is small (single-digit WorkItems in flight).

## Decision

Three layers of concurrency, each with an explicit cap:

### 1. Cross-WorkItem: parallel, capped

Different WorkItems can advance in parallel. The cap is
`policy.maxConcurrency` (v1 default: **3**). The orchestrator counts items
with an active `stage:*` label other than `queued`/`done`/`escalated`, and
holds further items in `stage:queued` once the cap is hit.

### 2. Per-WorkItem: serial across stations

A single WorkItem only runs one station at a time. Enforced by two locks:

- **Workflow lock (logical):** the WorkItem's `stage:*` label is the lock.
  A station starts by reading the label, doing its work, then atomically
  swapping the label on completion. The orchestrator refuses to start a
  station whose input label has already moved.
- **Edit lock (physical):** the WorkItem's branch (`claude/<slug>`). Only
  the implement station writes there. Other stations work via comments and
  ledger entries.

### 3. Within Implement: serial in v1, parallel later

The plan subagent may produce several tasks. **In v1, the implement
station processes them sequentially on a single branch.** Reasons:

- Merge conflicts between sibling task branches dominate the savings from
  parallelism at our throughput.
- Cost attribution and budget enforcement are simpler with one active
  branch per WorkItem.

Phase 4 introduces parallel task implementation behind a policy flag
(`policy.parallelImplement: true`). Until then the plan agent is told to
emit a linear plan.

### Multi-session lock (foreman-of-foremen)

Because two orchestrator sessions can be alive (e.g. a web background
session and a local CLI session), we need a single-writer guarantee on the
"pick next WorkItem and start ticking it" loop. We use a soft repo-level
lock:

- File: `lock.json` at the root of the configured **state branch**
  (default `factory/state`; see ADR 0002).
- Contents: `{ sessionId, host, acquiredAt, expiresAt }`.
- Acquire: orchestrator commits the file via the GitHub Contents API
  with a TTL of N minutes (v1: 10). The API uses optimistic concurrency
  on the parent SHA — commit conflict ⇒ another session won; this
  session goes idle.
- Release: orchestrator deletes the file at end of tick, or the TTL
  expires.
- Stale recovery: a session may forcibly take a lock whose `expiresAt`
  is in the past; doing so logs a `factory:lock-stolen` event in the
  ledger.

This is a coarse, optimistic lock — fine for the cap of one writer at a
time at our scale. It is not a transactional system; the ledger is the
audit trail of who did what.

The lock guards the orchestrator's *decision* step (label swaps,
branch creation). Once a station is running, the work itself is serialised
by layers 1 and 2 above; the lock can be released and re-acquired on the
next tick.

### Cancellation

The orchestrator never cancels in-flight station runs to start a newer
one. Budget overrun is enforced by the foreman before starting the next
station, not by killing the current one. A SIGINT in the local CLI ends
the session cleanly: the current station finishes (or is marked
`failed:interrupted` in the ledger), the lock is released, no label is
left in an inconsistent state.

## Consequences

Positive:

- The state machine cannot race itself, even with a web session and a
  local session running at once.
- The `maxConcurrency` knob is a single, well-understood throttle.
- Cost telemetry stays interpretable in v1 (one active run per WorkItem).
- The lock file is grep-able and human-fixable when something goes
  sideways.

Negative / accepted costs:

- v1 throughput is bounded by serial implementation. Acceptable:
  side-project scale.
- The repo-level lock is optimistic; in pathological cases two sessions
  can both think they hold it for a few hundred ms (commit conflict
  resolution latency). The label-swap atomicity at layer 2 is the real
  safety net.
- Stale-lock recovery is a manual recovery surface that has to be
  documented in the runbook.

## Alternatives considered

- **Actions `concurrency:` keys.** Doesn't apply — orchestrator no longer
  runs in Actions (ADR 0001).
- **No multi-session lock, rely only on label atomicity.** Possible, but
  two sessions would each pick the same `queued` WorkItem and start a
  station before the loser noticed; we'd waste a Run on the loser. The
  lock prevents that.
- **External lock service** (Redis, DynamoDB). Rejected as a v1
  dependency; revisit only if the optimistic lock proves insufficient.
- **Cancel-on-new-event.** Rejected: corrupts mid-edit work and
  undermines the Run ledger.
