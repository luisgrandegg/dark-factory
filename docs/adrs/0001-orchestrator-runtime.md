# 0001 — Orchestrator runtime

- **Status:** Accepted
- **Date:** 2026-05-08

## Context

The foreman has to: pick up new WorkItems, route them through stations, spawn
agents, enforce budgets, retry on failure, and surface results. We need a host
to actually run that loop.

The candidates we considered:

1. **GitHub Actions only.** Each station is a workflow; transitions are driven
   by labels and `workflow_dispatch`. State lives in the repo.
2. **Long-running process** (Node/Python service on a small VM or container).
   Holds an in-memory queue, drives stations via the GitHub API, exposes a
   live dashboard.
3. **Hybrid.** Actions handle the per-event work (intake, QA, integrate);
   a thin scheduler somewhere else pokes the queue when nothing has happened
   for a while.

Forces:

- The whole point of the template is **clone-and-go**. Anything that requires
  hosting infra fights that goal.
- We want a complete audit trail, replayable from the repo alone.
- Concurrency is modest (single-digit WorkItems in flight for v1).
- Live dashboards are nice, but Phase 3 — not Phase 1.
- We are explicitly stack-agnostic; we do not want to make the user adopt a
  particular runtime to host the orchestrator.

## Decision

**v1 runs entirely on GitHub Actions.** Each workstation is a workflow keyed
off labels (`stage:spec`, `stage:plan`, `stage:implement`, `stage:qa`,
`stage:integrate`) plus the natural GitHub events (`issues`, `pull_request`).
A scheduled `tick.yml` workflow (every ~5 min) handles items that need
nudging (retry timers, stuck states).

The "foreman" is the union of these workflows plus the policy file in
`.factory/policy.yml`. There is no separate process.

If and when v1 hits the wall — needs sub-minute reaction time, fan-out beyond
the Actions concurrency limits, or a live operator dashboard — we'll write a
follow-up ADR introducing a long-running process and migrate. The state model
(see ADR 0002) is designed so that move is non-breaking.

## Consequences

Positive:

- "Use this template" produces a working factory with no extra hosting.
- Every transition is a workflow run, which is already audited, retryable,
  and visible in the GitHub UI.
- Secrets management is GitHub Environments — no parallel system.
- Per-job concurrency is solved by Actions' `concurrency:` keys.

Negative / accepted costs:

- Cold-start latency: each station hop pays workflow startup cost (~10-30s).
  Acceptable for v1.
- Live dashboards are out of reach until Phase 3; the control room is a
  static page rebuilt by `report.yml`.
- The 5-minute `tick` granularity is the worst-case reaction time for stuck
  items.
- Workflow concurrency caps and minute-budget become operational constraints
  the runbook has to call out.

## Alternatives considered

- **Long-running process** — rejected for v1. It buys live dashboards and
  finer scheduling at the cost of every clone needing hosting. Revisit when
  Phase 3 demands it.
- **Hybrid** — rejected for v1 as premature complexity. We'd rather have a
  clean Actions-only baseline and graduate cleanly than start with two
  systems to keep in sync.
- **Claude Code background agents as orchestrator** — interesting, but
  couples the orchestrator to a single worker runtime and makes durability
  harder. Workers run inside Claude Code; the orchestrator should not.
