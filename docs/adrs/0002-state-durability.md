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
- We want **`main` to be PR-only**. Anything the orchestrator writes
  directly to `main` becomes an exception that branch protection has to
  carve out for the bot identity. We'd rather the bot only write to
  clearly-scoped factory branches and open PRs for product changes like a
  normal contributor.

## Decision

**Hybrid, with each surface on the ref that fits its mutability profile.**

Four surfaces, four owners:

- **Current state — labels (repo-level).** Exactly one `stage:*` label per
  WorkItem at any time. The orchestrator transitions state by swapping the
  label as the last step of a station, via the GitHub API. The set of
  valid transitions is encoded in `.factory/policy.yml`. Additional flags
  (`needs-human`, `escalated`, `priority:*`) are orthogonal labels.
  Issues and PRs are not branch-scoped, so labels need no branch decision.
- **Spec / plan artifacts — issue comments (repo-level).** The spec
  subagent posts the acceptance criteria as a comment; the plan subagent
  posts the task list as a comment. These are the human-readable
  artefacts.
- **Mutable derived state — its own orphan branch.** A dedicated branch
  (default `factory/state`, configurable) holds `lock.json`,
  `budget.json`, and any per-WorkItem snapshots the dashboard wants.
  These files are *rewritten* on every tick; they do not belong on the
  append-only ledger branch and do not belong on `main` (which we want
  PR-only).
- **Run history — its own orphan branch.** A dedicated branch (default
  `factory/ledger`, configurable) holds append-only Run records at
  `runs/YYYY/MM/DD/<ulid>.json`. Schema per `architecture.md §2.2` with
  the `usage` block from ADR 0004. Files are written once and never
  edited; this is what lets us safely compact, archive, or migrate the
  ledger later.

Both factory branches are created with `git checkout --orphan` so they
share no history with `main`. Their names are configurable in
`.factory/policy.yml`:

```yaml
ledger:
  branch: factory/ledger    # append-only run records
state:
  branch: factory/state     # mutable lock + budget + dashboard snapshots
```

`scripts/setup.sh` creates both branches on first run, drops a root
`README.md` on each explaining what it is, and pushes them. `doctor.sh`
re-creates either branch if it has been deleted upstream and reconciles
content drift (e.g., a `lock.json` whose `expiresAt` is in the past).

All factory writes go directly to these branches via the GitHub API; the
orchestrator does not hold a working copy of either branch. **The
orchestrator never pushes to `main` directly.** Product changes go
through `claude/<slug>` feature branches and PRs, exactly like a normal
contributor.

`main` carries: product code, `.factory/policy.yml`, `.factory/prompts/`,
`.factory/dashboard/` (the rendered control room), the `.claude/`
directory, `CLAUDE.md`, `docs/`, `scripts/`, and the minimal
`.github/workflows/` footprint from ADR 0001. Nothing on `main` is
written by the orchestrator outside of PR merges.

## Consequences

Positive:

- Any session can pick up where another left off — labels + state branch
  + ledger branch are enough to reconstruct what to do next. There is no
  in-memory queue to lose.
- Labels are an atomic GitHub primitive, which is what ADR 0003's
  multi-session lock dance ultimately commits against.
- The state of the factory is human-readable from the GitHub UI: labels
  and PRs from the default branch view, mutable state by switching to the
  state branch, history by switching to the ledger branch (or, more
  commonly, by reading the rendered dashboard on `main`).
- **`main` can be fully PR-protected with no bot exemption.** The
  orchestrator only writes to `factory/state` and `factory/ledger`
  branches and opens PRs for product changes; branch protection on
  `main` can require PR review for everyone, which is hard to claw back
  later.
- `main`'s history stays clean. `git log`, blame, and bisect on `main`
  reflect product changes only — at our throughput we'd otherwise see
  state writes outnumber product commits roughly 10–20× per busy day.
- CI workflows scoped to `branches: [main]` never fire on state or
  ledger writes. No per-workflow `paths-ignore` to maintain; the safety
  is structural.
- The append-only property of the ledger branch is preserved (no
  rewritten files mixed in), which is what lets future compaction or
  migration to external storage happen without touching `main`.
- Wiping or rebuilding either factory branch is a low-risk operation —
  delete the branch, run `setup.sh recreate`, no `main` history touched.

Negative / accepted costs:

- Three surfaces (labels + state branch + ledger branch) means more to
  keep consistent. `doctor.sh` reconciles all three and re-creates either
  branch if missing.
- Two extra fetches per cold tick (one for state, one for ledger) on top
  of the `main` fetch for config and agents. Roughly **+250–500 ms of
  latency per tick**, irrelevant at our throughput.
- Two extra `policy.yml` knobs (`state.branch`, `ledger.branch`) and the
  matching `setup.sh` / `doctor.sh` plumbing to create and validate both.
- Discoverability friction. A human asking "who holds the lock?" or
  "where is the run for issue #42?" has to switch branches in the GitHub
  UI. The dashboard surfaces these without the branch hop and is the
  intended human entry point; raw branch access is a debugging fallback.
- Two orphan sibling branches are unusual. New contributors will assume
  they're stale. `CLAUDE.md` and the runbook call them out as
  intentional, and each branch carries a root `README.md`.
- All factory tooling has to read `policy.state.branch` and
  `policy.ledger.branch` rather than hardcoding paths. The orchestrator,
  `doctor.sh`, the dashboard generator, and any ad-hoc operator script
  must look up the configured names.
- Per-tick state writes still produce commit churn — they just live on
  `factory/state` instead of `main`. The state branch is expected to
  reach hundreds of commits per busy day; periodic squash/force-push on
  that branch is the documented mitigation, safe because nothing
  downstream depends on its history.

## Alternatives considered

- **Labels-only.** Loses run-level usage and artifact data. Rebuilding
  "what did this agent do at 3am Tuesday" from issue timelines is brutal.
- **JSON-only.** Reviewers lose the at-a-glance UX of labels, and we'd
  have to invent our own atomic-swap discipline on a JSON file for the
  multi-session lock to commit against. Labels give that for free.
- **Ledger on `main` (initial draft of this ADR).** Rejected: every
  ledger commit risked triggering CI and polluted `git log`. A
  path-filter on every workflow is fragile compared to a separate ref,
  and compaction becomes risky when the ledger and product history share
  a branch.
- **State on `main`, ledger on its own branch (intermediate draft).**
  Rejected for three reinforcing reasons: (1) it forces branch protection
  on `main` to grant the bot direct push access, which is hard to claw
  back; (2) state churn (~120–240 commits/day at our scale) drowns
  product commits in `git log main` ~10–20×; (3) every workflow needs a
  `paths-ignore: ['.factory/state/**']` filter to avoid burning Actions
  minutes on state writes, which is fragile. Splitting state to its own
  branch eliminates all three at the cost of a second extra fetch per
  tick (~250 ms) and one more configurable branch name.
- **State and ledger on the same orphan branch.** Rejected: state files
  are mutated on every tick while ledger files are append-only.
  Combining them on one branch forfeits the append-only property that
  makes the ledger safe to compact / archive / migrate independently.
- **External database.** Rejected as a v1 dependency; revisit if we
  ever go multi-repo or hosted.
