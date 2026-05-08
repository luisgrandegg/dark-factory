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

- We chose Actions as the orchestrator (ADR 0001), so workflow triggers must
  be cheap to express. GitHub already triggers on label events — that's free.
- The repo as the source of truth keeps everything auditable and replayable.
  But a JSON file per WorkItem committed back to the repo creates merge
  contention with the active branches it describes.
- Reviewers and humans live on the GitHub UI; they read labels and comments,
  not JSON files in `main`.
- Run-level data (tokens, cost, artifacts) is too noisy for issue comments
  and too valuable to throw away.

## Decision

**Hybrid, with clear ownership of each surface.**

- **Current state — labels.** Exactly one `stage:*` label per WorkItem at any
  time. Workflows transition state by swapping the label. The set of valid
  transitions is encoded in `.factory/policy.yml`. Additional flags
  (`needs-human`, `escalated`, `priority:*`) are orthogonal labels.
- **Spec / plan artifacts — issue comments.** The spec subagent posts the
  acceptance criteria as a comment; the plan subagent posts the task list as
  a comment. These are the human-readable artefacts.
- **Run history — JSON ledger.** Each agent invocation appends one file:
  `.factory/runs/<ulid>.json`, schema per `architecture.md §2.2`. Ledger
  files are append-only, never edited.
- **WorkItem snapshots — derived, not authoritative.** `.factory/state/` is
  rebuilt from labels + ledger by `report.yml`. It exists for the dashboard,
  not as a source of truth.

Ledger writes happen on a dedicated branch / commit per run, on `main`
directly via the GitHub API (no working-copy contention with feature
branches). Naming: `.factory/runs/YYYY/MM/DD/<ulid>.json` to keep directories
small.

## Consequences

Positive:

- Workflows trigger naturally on label events — no custom dispatch glue.
- The state of the factory is human-readable from the GitHub UI alone.
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
- Ledger commits to `main` show up in `git log`. We accept the noise; future
  ADR may move runs to an Actions artifact store + periodic snapshot if it
  becomes painful.

## Alternatives considered

- **Labels-only.** Loses run-level cost and token data. Rebuilding "what did
  this agent do at 3am Tuesday" from issue timelines is brutal.
- **JSON-only.** Workflow triggers become awkward (we'd need polling or a
  custom dispatcher) and reviewers lose the at-a-glance UX of labels.
- **External database.** Rejected as a v1 dependency; revisit if we ever go
  multi-repo or hosted.
