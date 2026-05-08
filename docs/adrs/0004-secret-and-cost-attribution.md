# 0004 — Secret and cost attribution

- **Status:** Accepted
- **Date:** 2026-05-08

## Context

The factory handles real secrets (a GitHub token for write operations,
optional MCP credentials, project-specific deploy creds the user wires in)
and consumes a metered resource — Claude Code subscription usage rather
than direct API spend, after ADR 0001. Two related problems:

1. **Secret scoping.** Which station gets which secret, how it's injected,
   and how we keep secrets out of the run ledger and PR diffs.
2. **Cost attribution.** Every unit of work should be tied to a specific
   Run on a specific WorkItem so budgets work and the dashboard means
   anything — even though "cost" is now measured in subscription usage,
   not USD.

Forces:

- The orchestrator is a Claude Code session running either on the web or
  on the operator's laptop (ADR 0001). There is no Actions runner whose
  Environments we can use to scope secrets to a station.
- The orchestrator does not call the Anthropic API. All inference happens
  through Claude Code's session, billed against the subscription. We can't
  read a per-call USD figure the way the GitHub Action exposes one.
- The run ledger lives in the repo (ADR 0002). Anything that lands there
  is permanently auditable — and permanently leaked if it contains a
  secret.
- Budgets are enforced per-WorkItem and per-day; the foreman needs a
  number it can compare against the cap, in near-real time.

## Decision

### Secrets

We move from "Environments per blast radius" to "credentials sourced from
the host, scoped per call site". Three blast-radius tiers remain — what
changes is where they come from.

| Tier              | Used by                    | Local CLI host                      | Web host                             |
| ----------------- | -------------------------- | ----------------------------------- | ------------------------------------ |
| `factory-read`    | intake, spec, plan, QA     | `gh auth` (read scope) + repo files | Web session's GitHub integration     |
| `factory-write`   | implement, integrate       | `gh auth` (write scope)             | Web session's GitHub integration     |
| `factory-deploy`  | deploy / prod-touching ops | Operator-supplied env vars          | GitHub Environment with reviewers on |

Rules that hold across both hosts:

- **Secrets are referenced, never echoed.** A PreToolUse hook blocks any
  tool call whose argv contains the literal value of a known secret env
  var, and redacts before logging.
- **The run ledger never contains secret values.** The artefact field
  stores diffs and file lists, not raw command output. A small allowlist
  of env-var *names* (not values) may be recorded.
- **No `ANTHROPIC_API_KEY` in the factory.** Inference is via the user's
  Claude Code session. If a future feature needs direct API access, it
  comes with its own ADR.
- **Deploy creds stay out of the orchestrator session.** Deploy steps run
  in a constrained context: a small GitHub Action triggered by the
  `stage:integrate` label, with `factory-deploy` Environment + required
  reviewers. The orchestrator session never sees those secrets.
- **Rotation is a `doctor.sh` action.** Doctor checks token age (where
  visible) and warns over a threshold (default 90 days).
- **Local development** uses a `.env.local` file (gitignored) loaded by
  `scripts/setup.sh` when present. The same hook-based redaction applies.

### Cost attribution

"Cost" in v1 is **subscription usage**, not USD. Each Run records the
session-reported usage figures available at the time. The unit of
attribution is still the Run.

Every station, regardless of which session is driving it, follows the
same shape:

1. **Start:** generate a ULID. Write
   `.factory/runs/YYYY/MM/DD/<ulid>.json` with
   `{ status: "running", workItemId, station, host, sessionId, startedAt }`.
2. **Invoke** the station subagent / skill, threading `runId` so any
   sub-runs can record `parentRunId`.
3. **Capture usage.** Read whatever the Claude Code session exposes:
   - Token counts (in / out) for the run, when available.
   - Wall-clock time.
   - Tool-call counts (a useful proxy when token data is missing).
4. **End:** patch the ledger entry with `endedAt`, `status`, files
   touched, PR/comment refs, and a `usage` block:

   ```
   usage:
     tokensIn:    int | null
     tokensOut:   int | null
     wallSeconds: int
     toolCalls:   int
     costUsd:     null   # populated only if a future runtime exposes it
   ```

5. **Roll up:** at the start of each tick, the orchestrator sums the
   day's runs and writes `.factory/state/budget.json` (derived; ADR 0002).
   The next station refuses to start if the cap is hit and labels the
   WorkItem `escalated` with reason `budget`.

Budgets in `policy.yml` are expressed in the same units the ledger
captures: `maxTokensPerWorkItem`, `maxToolCallsPerDay`,
`maxWallMinutesPerDay`. When token data is unavailable, `toolCalls` and
`wallSeconds` are the binding caps.

For sub-runs (a station agent that spawns a subagent), the subagent
emits its own ledger entry tagged with `parentRunId`. Roll-ups sum the
leaves to avoid double-counting.

## Consequences

Positive:

- No per-station Environment matrix to maintain — credentials follow the
  host the session is running on.
- Removing `ANTHROPIC_API_KEY` from the factory shrinks the secret
  surface meaningfully. The most expensive credential is no longer
  present at all.
- Deploy isolation is stronger: deploy creds live in an Action with
  required reviewers, not in any orchestrator session.
- The `usage` block captures what we *can* measure and is honest about
  what we can't (`costUsd: null` is allowed). Operators see the gap in
  the dashboard rather than getting a false zero.
- Every Run still has a WorkItem; every WorkItem still has an issue.
  The audit chain is complete even without USD figures.

Negative / accepted costs:

- Token / wall-time figures depend on what the Claude Code session
  surfaces to skills and slash commands. If that surface changes, the
  capture step changes. Acceptable; the ledger schema isolates it.
- Subscription usage is harder to reason about as money than per-call
  API costs. We compensate with `toolCalls` and `wallSeconds` caps,
  which are coarser but always present.
- Two hosts means two slightly different credential setup paths in
  `setup.sh`. Doctor reconciles them.
- Sub-run accounting requires every subagent invocation to receive a
  `parentRunId`. The `architecture.md` Run schema is updated
  accordingly.

## Alternatives considered

- **Three GitHub Environments for everything.** Deferred from the prior
  draft of this ADR. The orchestrator no longer runs in Actions, so
  Environments only make sense for the deploy step — kept there.
- **Skip cost attribution entirely while subscription is a flat cost.**
  Rejected: budgets are also a runaway-protection mechanism, not just a
  spend tracker. We need *some* measured value to compare against caps,
  even if it's tool-call count.
- **Direct Anthropic API calls for cost transparency.** Rejected: that
  reintroduces the spend that ADR 0001 went out of its way to remove.
