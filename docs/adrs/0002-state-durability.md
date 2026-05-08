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
- **Run history — JSON ledger on a sibling branch.** Each agent invocation
  appends one file: `runs/YYYY/MM/DD/<ulid>.json` on a dedicated **orphan
  branch** (default `factory/ledger`, configurable). Schema per
  `architecture.md §2.2` with the `usage` block from ADR 0004. Ledger
  files are append-only, never edited.
- **WorkItem snapshots — derived, not authoritative.** `.factory/state/`
  on `main` (including `budget.json` and `lock.json`) is rebuilt from
  labels + ledger by the orchestrator at the start of each tick. It
  exists for the dashboard and the tick loop, not as a source of truth.

The ledger branch is created with no shared history (`git checkout
--orphan`) so its commits never appear in `git log main`. Its branch name
is set in `.factory/policy.yml`:

```yaml
ledger:
  branch: factory/ledger    # configurable; created by setup.sh
```

`scripts/setup.sh` creates the branch on first run, drops a `README.md` at
its root explaining what it is, and pushes it. `doctor.sh` re-creates it
if it's missing or has been deleted upstream.

Ledger writes go directly to the ledger branch via the GitHub API (the
orchestrator is not necessarily holding a working copy, and the branch is
not normally checked out). State files (`.factory/state/lock.json`,
`budget.json`) stay on `main` because that's where humans look and
because the multi-session lock benefits from sharing a ref with the
labels it coordinates with.

## Consequences

Positive:

- Any session can pick up where another left off — labels + ledger are
  enough to reconstruct what to do next. There is no in-memory queue to
  lose.
- Labels are an atomic GitHub primitive, which is what ADR 0003's
  multi-session lock dance ultimately commits against.
- The state of the factory is human-readable from the GitHub UI alone,
  even when no session is running.
- `main`'s history stays clean. `git log`, blame, and bisect on `main`
  reflect product changes only; the ledger lives on its own ref.
- CI workflows scoped to `branches: [main]` never fire on ledger writes,
  preserving ADR 0001's "no Actions minutes burned for orchestration"
  property without per-workflow path filters.
- Compaction (squash, archival, future move to external storage) happens
  on the ledger branch with no risk to `main`.

Negative / accepted costs:

- Two surfaces means we have to keep them consistent. The runbook has a
  reconciliation step (`doctor.sh` flags WorkItems where labels and
  ledger disagree, and re-creates the ledger branch if missing).
- Labels can be edited by hand. We treat that as a feature (operators can
  unstick a WorkItem) but log it explicitly when the next run notices a
  mismatch.
- Discoverability cost. A human browsing the repo on github.com sees only
  `main` by default; they have to know to switch to the ledger branch (or
  use the dashboard, which is the intended access path). The ledger
  branch's root `README.md` and `runbook.md` explain the layout.
- An orphan sibling branch is unusual. New contributors will assume it's
  stale or abandoned. `CLAUDE.md` calls it out as intentional.
- Tooling that reads the ledger has to know the configured branch name.
  The orchestrator, `doctor.sh`, and the dashboard generator all read
  `policy.ledger.branch`; ad-hoc scripts must do the same.

## Alternatives considered

- **Labels-only.** Loses run-level usage and artifact data. Rebuilding
  "what did this agent do at 3am Tuesday" from issue timelines is brutal.
- **JSON-only.** Reviewers lose the at-a-glance UX of labels, and we'd
  have to invent our own atomic-swap discipline on a JSON file for the
  multi-session lock to commit against. Labels give that for free.
- **Ledger on `main`.** Considered first; rejected because every ledger
  commit risks triggering CI and pollutes `git log`. A path-filter on
  every workflow is fragile compared to a separate ref. Compaction also
  becomes much riskier when the ledger and product history share a
  branch.
- **External database.** Rejected as a v1 dependency; revisit if we
  ever go multi-repo or hosted.
