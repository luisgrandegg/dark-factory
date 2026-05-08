# Architecture

The dark factory is a pipeline of **workstations**. A piece of work (a `WorkItem`)
flows through the stations; at each one, an agent (or automation) advances its
state until it ships or escalates.

This document covers: components, domain model, workflows, integrations, and
guardrails.

---

## 1. Components

```
                                  ┌─────────────────────┐
   Issues ─────────┐              │      Foreman        │
   Alerts  ────────┼─►  Intake ─► │  (orchestrator)     │
   Schedules ──────┘              └──────────┬──────────┘
                                             │ assigns
                       ┌─────────────────────┼─────────────────────┐
                       ▼                     ▼                     ▼
                  ┌─────────┐           ┌─────────┐           ┌─────────┐
                  │  Spec   │           │  Plan   │           │ Implement│
                  └────┬────┘           └────┬────┘           └────┬────┘
                       └────────────►───────┴───────►───────►─────┘
                                             │
                                             ▼
                                        ┌─────────┐
                                        │   QA    │
                                        └────┬────┘
                                             │
                              ┌──────────────┼──────────────┐
                              ▼              ▼              ▼
                          Integrate     Escalate        Reject
                              │              │
                              ▼              ▼
                            Deploy       Human review
```

### 1.1 Foreman (orchestrator)

- Maintains the queue of `WorkItem`s and their states.
- Spawns the right agent for the current state.
- Enforces budgets (tokens, wall-clock, retries).
- Handles failures: retry, downgrade, escalate.
- Reports throughput and cost to the control room.

Implementation: a Claude Code session — runs on Claude Code on the web for
lights-out operation, or in the local CLI when the operator opens their
laptop. Same code in both. See
[ADR 0001](./adrs/0001-orchestrator-runtime.md).

### 1.2 Workstations

Each workstation is a focused agent with a narrow contract: input state →
output state. Stations should be **idempotent and resumable** so the foreman
can retry safely.

| Station    | Input             | Output                              | Primary tool        |
| ---------- | ----------------- | ----------------------------------- | ------------------- |
| Intake     | Raw issue / signal| Triaged + labelled WorkItem         | Triage subagent     |
| Spec       | WorkItem          | Acceptance criteria, scope, risks   | Spec subagent       |
| Plan       | Spec              | Task list with file pointers        | Plan subagent       |
| Implement  | Task              | Branch + commits + draft PR         | Claude Code main    |
| QA         | PR                | Review + test + scan results        | Review subagents    |
| Integrate  | Green PR          | Merged commit                       | GitHub Action       |
| Deploy     | Merged commit     | Released artifact                   | Project-specific CD |

### 1.3 Worker pool

Workers are Claude Code sessions. Variants:

- **Main session** for implementation (full file edits, command execution).
- **Subagents** for narrow tasks (Explore, Plan, Review, Security-Review).
- **Skills** for repeatable capabilities (e.g. dependency upgrade, migration
  generation, codemod).

Workers run in **isolated worktrees** to keep concurrent jobs from stomping on
each other.

### 1.4 Control room

A dashboard (could be a static page generated from logs, or a more involved
service) showing:

- Live runs and their state
- Token / cost spend per WorkItem and rolling totals
- Throughput: WorkItems shipped per day
- Escalation backlog
- Failure clusters (top reasons jobs fail)

### 1.5 Andon — human-in-the-loop

The factory **always** has escalation paths:

- Budget exceeded.
- Repeated QA failures (>N retries).
- Risky actions (prod deploy, destructive ops, secret access).
- Confidence below threshold from review agents.
- Explicit `needs-human` label.

Escalation surfaces as a GitHub comment / issue assigned to a human reviewer.

---

## 2. Domain model

Minimal entities. All persisted as files in the repo (issues, PRs, labels) plus
a small ledger for runs and cost. No external DB required for v1.

### 2.1 WorkItem

```
WorkItem
  id              GitHub issue number
  source          issue | alert | schedule | manual
  state           intake | spec | plan | implement | qa | integrate | done | escalated | rejected
  priority        p0 | p1 | p2 | p3
  budget          { tokens, wallClock, maxRetries }
  spec            ref to spec doc / comment
  plan            ref to plan doc / comment
  branch          claude/<slug>
  pr              GitHub PR number
  runs            [Run]
  labels          string[]
```

### 2.2 Run

A single agent invocation against a WorkItem.

```
Run
  id              ulid
  workItemId
  station         intake | spec | plan | implement | qa | ...
  agent           main | subagent:<name> | skill:<name>
  startedAt
  endedAt
  status          success | failure | escalated
  tokensIn
  tokensOut
  cost            estimated USD
  artifacts       diff, comments, files-touched
  failureReason   string?
```

### 2.3 Policy

Configuration that bounds the factory.

```
Policy
  budgets         { perWorkItem, perDay, perStation }
  allowlist       { bash, mcp, files }   # what tools/paths agents may touch
  approvalGates   [ pattern → reviewer ] # paths/labels requiring humans
  models          { default, planner, reviewer }
  maxConcurrency  int
```

### 2.4 Why no database

For v1, persisting in the repo (issues, PR comments on `main`, ledger
files on a sibling `factory/ledger` branch — see ADR 0002) keeps the
template **portable** and **auditable**. Promote to a real store only
when we hit limits.

---

## 3. Workflows

### 3.1 Issue → Merged PR (golden path)

1. **Intake**: a new issue lands. Action triggers `intake` subagent: classify
   (bug / feature / chore), label, score priority, estimate budget. Move to
   `spec`.
2. **Spec**: agent reads the issue + linked context, writes acceptance
   criteria and explicit out-of-scope items as a comment. Move to `plan`.
3. **Plan**: agent surveys the codebase (Explore), produces a task list with
   file:line pointers and a test strategy. Move to `implement`.
4. **Implement**: foreman creates a worktree on `claude/<slug>`, spawns Claude
   Code with the task list. On completion, opens a draft PR and moves to `qa`.
5. **QA**: in parallel, the foreman runs CI plus review subagents
   (code-review, security-review). Aggregate verdict.
6. **Integrate**: if all green and no policy gate trips, mark PR ready and
   auto-merge. Move to `done`.
7. **Deploy**: post-merge CD pipeline (project-specific).

### 3.2 Failure paths

- **Implementation fails to make CI green** → up to N retries with the failure
  log fed back. Then **escalate**.
- **Review subagent flags risk** → escalate with the review comment.
- **Budget exceeded** → pause the WorkItem, escalate.
- **Approval gate trips** (e.g. PR touches `infra/`) → request human review;
  agent does not auto-merge.

### 3.3 Recurring jobs

The schedule station emits WorkItems for:

- Dependency updates (weekly).
- Security scans.
- Test-flake triage.
- Stale-branch / stale-PR cleanup.
- Cost / throughput report to the control room.

---

## 4. Integrations

| Concern        | Choice (initial)                         | Notes                          |
| -------------- | ---------------------------------------- | ------------------------------ |
| Source / PRs   | GitHub                                   | Required.                      |
| Orchestrator   | Claude Code session (web or local CLI)   | See ADR 0001.                  |
| GitHub Actions | CI + auto-merge sealing only             | Not used for orchestration.    |
| Worker runtime | Claude Code subagents and skills         | Same session as orchestrator.  |
| Hooks          | `.claude/settings.json` SessionStart, PreToolUse, Stop | Guardrails + setup. |
| Skills         | `.claude/skills/`                        | Capabilities-as-code.          |
| MCP            | GitHub MCP, optional others              | Restricted by allowlist.       |
| Notifications  | Issue / PR comments, optional Slack      | Andon escalations.             |
| Storage        | Repo files + GitHub API                  | No DB in v1.                   |

---

## 5. Guardrails

The whole thing is only safe because of these. Listed in priority order:

1. **Tool allowlist** — every agent runs with an explicit allowlist; no `*`.
2. **Budgets** — token and wall-clock caps per WorkItem and per day; the
   foreman kills runs over budget.
3. **Approval gates** — policy patterns that always require human review
   (paths like `infra/**`, `migrations/**`, labels like `release`).
4. **Worktree isolation** — each run in its own worktree on its own branch;
   never edit `main` directly.
5. **No destructive ops without confirmation** — hooks block `git push --force`,
   `rm -rf`, destructive SQL unless explicitly authorised.
6. **Secrets scoping** — secrets injected per-station via the conveyor; never
   committed; scanning runs on every PR.
7. **Audit trail** — every Run is logged to the ledger branch (ADR 0002)
   and surfaced in the control room.

---

## 6. Open questions

Resolved in [ADRs](./adrs/):

- Orchestrator runtime → [ADR 0001](./adrs/0001-orchestrator-runtime.md)
  (Actions for v1).
- State durability → [ADR 0002](./adrs/0002-state-durability.md) (labels
  authoritative for state, JSON ledger for history).
- Concurrency model → [ADR 0003](./adrs/0003-concurrency-model.md) (parallel
  WorkItems, serial stations and tasks).
- Secret / cost attribution → [ADR 0004](./adrs/0004-secret-and-cost-attribution.md)
  (three Environments; per-Run ledger entries with token / USD totals).

Still open, to be promoted to ADRs as we decide:

- **Multi-repo factory**: does one factory drive many product repos, or one
  factory per repo? (Probably: one per repo, with a shared skills library.)
- **Local-dev story**: can a developer run the factory on their laptop against
  a test repo without paying for cloud agents?
