# 0004 — Secret and cost attribution

- **Status:** Accepted
- **Date:** 2026-05-08

## Context

The factory spends real money (Anthropic API calls, optional MCP services)
and handles real secrets (`ANTHROPIC_API_KEY`, GitHub tokens, project secrets
the user wires in). Two related problems:

1. **Secret scoping.** Which station gets which secret, how it's injected,
   and how we keep secrets out of the run ledger and PR diffs.
2. **Cost attribution.** Every dollar spent should be tied to a specific Run
   on a specific WorkItem so budgets work and the dashboard means anything.

Forces:

- We chose Actions as the runtime (ADR 0001), so GitHub Environments are the
  natural secret store.
- Workers are Claude Code sessions invoked via the GitHub Action (and, later,
  the CLI). The Action exposes usage data; we have to capture it before the
  run ends.
- The run ledger lives in the repo (ADR 0002). Anything that lands there is
  permanently auditable — and permanently leaked if it contains a secret.
- Budgets are enforced per-WorkItem and per-day; the foreman needs a number
  it can compare against the cap, in near-real time.

## Decision

### Secrets

- **One Environment per blast radius**, not per station. v1 ships three:
  - `factory-read` — read-only access (intake, spec, plan, QA review).
    Carries `ANTHROPIC_API_KEY` and a read-scoped `GITHUB_TOKEN`.
  - `factory-write` — branch + PR write. Carries the same plus a
    write-scoped token. Used by implement and integrate.
  - `factory-deploy` — anything that touches prod. Empty in v1; users wire
    in deploy creds here. Required reviewers turned **on** by default.
- **Secrets are referenced, never echoed.** Hooks block any tool call whose
  argv contains the literal value of a known secret env var. The PreToolUse
  hook also redacts before logging.
- **The run ledger never contains secret values.** The artifact field stores
  diffs and file lists, not raw command output. A small allowlist of
  environment variable *names* (not values) may be recorded for debugging.
- **Rotation is a `doctor.sh` action.** Doctor checks secret age via the
  GitHub API and warns over a threshold (default 90 days).
- **Local development** uses a `.env.local` file (gitignored) loaded by
  `scripts/setup.sh` when present. The same hook-based redaction applies.

### Cost attribution

Each Run is the unit of attribution. The implement, plan, spec, intake, and
QA workflows all follow the same shape:

1. **Start:** generate a ULID, write `.factory/runs/<...>/<ulid>.json` with
   `status: "running"`, `workItemId`, `station`, `startedAt`.
2. **Invoke** the Claude Code Action / CLI with `--run-id <ulid>` so the
   value is available to subagents that want to nest sub-runs.
3. **End:** capture the Action's reported `tokensIn` / `tokensOut` /
   `cost-usd` outputs and patch the ledger entry to `success` / `failure` /
   `escalated`. End time, failure reason, files-touched, PR/comment refs go
   in the same patch.
4. **Roll up:** the `tick.yml` workflow sums today's runs and writes
   `.factory/state/budget.json` (derived, see ADR 0002). The next station
   workflow refuses to start if the cap is hit and labels the WorkItem
   `escalated` with reason `budget`.

Cost numbers come from the Action's reported usage. If a run uses a runtime
that doesn't report usage (e.g. a future MCP-only run), we record `cost:
null` and the budget code treats that station as opaque — operators see the
gap in the dashboard rather than getting a false zero.

For sub-runs (a main session that spawns a subagent), the subagent emits its
own ledger entry tagged with `parentRunId`. Roll-ups sum the leaves to avoid
double-counting.

## Consequences

Positive:

- Three Environments give us escalating gates without a station-by-station
  matrix to maintain.
- Budgets are enforced from a single derived file — easy to test, easy to
  inspect.
- Every dollar has a Run, every Run has a WorkItem, every WorkItem has an
  issue. The audit chain is complete.
- The `cost: null` convention surfaces measurement gaps instead of hiding
  them.

Negative / accepted costs:

- Cost numbers depend on what the Action reports. If reporting changes
  shape, we need to update the parser. Acceptable; we pin the action
  version in the workflows.
- Three Environments mean a slightly larger setup script and three secret
  copies if the user reuses the same key. We keep `setup.sh` idempotent so
  re-runs converge.
- Budget enforcement reaction time is bounded by the `tick` interval (ADR
  0001). A runaway run can overshoot by one tick. Per-WorkItem token caps
  in the worker config provide a second line of defence.
- Sub-run accounting requires every subagent invocation to receive a
  `parentRunId`. The `architecture.md` Run schema is updated accordingly.

## Alternatives considered

- **One Environment for everything.** Rejected: deploy creds end up in QA
  runs. Bad blast radius.
- **One Environment per station.** Rejected: bookkeeping cost outweighs the
  isolation benefit at our scale; the three blast-radius tiers cover the
  threats we actually have.
- **Cost from monthly Anthropic console totals.** Rejected: too coarse;
  can't attribute to a Run, can't enforce per-WorkItem budgets.
- **External billing/observability service.** Rejected as a v1 dependency;
  revisit when Phase 3 builds the live dashboard.
