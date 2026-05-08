# 0002 — State durability

- **Status:** Accepted
- **Date:** 2026-05-08

## Context

Every WorkItem moves through a state machine (`intake → spec → plan →
implement → qa → integrate → done`, with `escalated` / `rejected` exits).
Two questions: where does the **current state** live, and where does the
**history** live?

Candidates:

1. **Labels + comments only.** State is the set of `stage:*` labels on the
   issue/PR; history is reconstructed from the issue and PR timeline.
2. **JSON ledger only.** A `.factory/state/<id>.json` file per WorkItem
   committed to the repo, plus `.factory/runs/<ulid>.json` for each agent run.
3. **Hybrid: labels are authoritative for state, JSON ledger is authoritative
   for history.**

Forces:

- The orchestrator is a Claude Code session (ADR 0001) that may be running
  on the web, on the operator's laptop, or not at all. State has to live
  somewhere both hosts can read on tick, and somewhere a human can inspect
  while no session is running.
- Two sessions can be alive at once (ADR 0003). The "current state" surface
  has to support a cheap atomic swap so the multi-session lock has
  something to commit against.
- The repo as the source of truth keeps everything auditable and replayable.
  But a JSON file per WorkItem committed back to the repo creates merge
  contention with the active branches it describes.
- Reviewers and humans live on the GitHub UI; they read labels and comments,
  not JSON files in `main`.
- Run-level data (tokens, wall-clock, tool calls, artifacts) is too noisy
  for issue comments and too valuable to throw away.

## Decision

**Hybrid, with clear ownership of each surface.**

- **Current state — labels.** Exactly one `stage:*` label per WorkItem at
  any time. The orchestrator transitions state by swapping the label as the
  last step of a station, via the GitHub API. The set of valid transitions
  is encoded in `.factory/policy.yml`. Additional flags (`needs-human`,
  `escalated`, `priority:*`) are orthogonal labels.
- **Spec / plan artifacts — issue comments.** The spec subagent posts the
  acceptance criteria as a comment; the plan subagent posts the task list
  as a comment. These are the human-readable artefacts.
- **Run history — JSON ledger.** Each agent invocation appends one file:
  `.factory/runs/YYYY/MM/DD/<ulid>.json`, schema per `architecture.md §2.2`
  with the `usage` block from ADR 0004. Ledger files are append-only,
  never edited.
- **WorkItem snapshots — derived, not authoritative.** `.factory/state/`
  (including `budget.json` and `lock.json`) is rebuilt from labels + ledger
  by the orchestrator at the start of each tick. It exists for the
  dashboard and the tick loop, not as a source of truth.

Ledger writes go directly to `main` via the GitHub API (the orchestrator is
not necessarily holding a working copy, and even when it is, writing to
`main` avoids contention with the feature branches the runs describe).

## Consequences

Positive:

- Any session can pick up where another left off — labels + ledger are
  enough to reconstruct what to do next. There is no in-memory queue to
  lose.
- Labels are an atomic GitHub primitive, which is what ADR 0003's
  multi-session lock dance ultimately commits against.
- The state of the factory is human-readable from the GitHub UI alone, even
  when no session is running.
- The ledger gives us replayable, queryable history without polluting the
  human-facing surfaces.
- The split keeps the audit trail in the repo (good for forensics) without
  putting hot mutable state into git history.

Negative / accepted costs:

- Two surfaces means we have to keep them consistent. The runbook has a
  reconciliation step (`doctor.sh` flags WorkItems where labels and ledger
  disagree).
- Labels can be edited by hand. We treat that as a feature (operators can
  unstick a WorkItem) but log it explicitly when the next run notices a
  mismatch.
- Ledger commits to `main` show up in `git log`. We accept the noise; a
  later ADR can move the ledger to an external blob store with periodic
  repo snapshots if it becomes painful.

## Alternatives considered

- **Labels-only.** Loses run-level usage and artifact data. Rebuilding
  "what did this agent do at 3am Tuesday" from issue timelines is brutal.
- **JSON-only.** Reviewers lose the at-a-glance UX of labels, and we'd
  have to invent our own atomic-swap discipline on a JSON file for the
  multi-session lock to commit against. Labels give that for free.
- **External database.** Rejected as a v1 dependency; revisit if we ever
  go multi-repo or hosted.
