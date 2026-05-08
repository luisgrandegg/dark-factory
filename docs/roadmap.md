# Roadmap

How we get from this design repo to a working **GitHub template**.

Each phase has a clear exit criterion and ends in something demonstrable.

---

## Phase 0 — Design (this phase)

**Exit:** the system is described well enough that a competent contributor
could start building.

- [x] README with concept and metaphor
- [x] Architecture, domain model, workflows, guardrails
- [x] Template directory layout and setup story
- [x] ADR: orchestrator runtime (Actions vs. long-running process) — [0001](./adrs/0001-orchestrator-runtime.md)
- [x] ADR: state durability (labels + comments vs. JSON ledger) — [0002](./adrs/0002-state-durability.md)
- [x] ADR: concurrency model — [0003](./adrs/0003-concurrency-model.md)
- [x] ADR: secret / cost-attribution strategy — [0004](./adrs/0004-secret-and-cost-attribution.md)

---

## Phase 1 — Walking skeleton

**Exit:** a single issue can flow from intake → merged PR on a sample repo,
with one trivial change (e.g. "add a hello-world script"), end-to-end via the
factory.

- [x] `.claude/settings.json` with strict allowlist + SessionStart hook
- [x] `factory` skill + `/factory-tick` slash command (the orchestrator loop)
- [x] One subagent each: `intake`, `plan`, `contract-check`
- [x] `.factory/policy.yml` with conservative defaults
- [x] Ledger format defined and written to the configured ledger branch
      (default `factory/ledger`, orphan; see ADR 0002)
- [x] `lock.json` (on the state branch) acquire/release wired into the tick loop
- [x] `.github/workflows/ci.yml` — project tests/lint on PRs (only)
- [x] `.github/workflows/integrate.yml` — auto-merge sealer on `stage:integrate`
- [x] `scripts/setup.sh` (minimum viable: labels + credential check, both hosts)
- [x] Smoke-test issue auto-filed by `setup.sh`

Acceptance: clone the repo to a fresh GitHub account, run `setup.sh`, open
Claude Code (web or local) and run `/factory-tick`, observe the smoke-test
issue land as a merged PR within budget.

---

## Phase 2 — Production-grade guardrails

**Exit:** the factory is safe enough to leave running unattended on a real
side-project repo.

- [x] Approval gates wired to path patterns and labels
- [x] Budget enforcement in the foreman (kill-switch on overrun)
- [x] Secret scanning on every PR (block merge on hit)
- [x] Escalation flow with human assignment + `escalated` label
- [x] PreToolUse hook blocking destructive ops without explicit auth
- [x] Worktree isolation enforced (no agent edits `main`)
- [x] `doctor.sh` covers the top failure modes
- [x] Runbook + escalation playbook

---

## Phase 3 — Observability

**Exit:** an operator can answer, in under a minute: how many WorkItems are in
flight, what each is doing, today's spend, and what failed and why.

- [x] Static control-room page generated from the ledger branch —
      `scripts/factory/dashboard.sh` calls `metrics.sh` and
      `failures.sh` and renders a self-contained HTML page
      (default `.factory/dashboard/index.html`). Smoke-tested by
      `scripts/test/dashboard-smoke.sh`.
- [x] Daily cost + throughput report — `.github/workflows/daily-report.yml`
      runs `scripts/factory/metrics.sh` and `scripts/factory/failures.sh`
      against `factory/ledger` once a day (14:00 UTC, plus
      `workflow_dispatch`) and posts a `factory:report` issue.
- [x] Failure clustering (top reasons jobs fail this week) —
      `scripts/factory/failures.sh` clusters Run records with status
      `failure` or `escalated` over a rolling window: top reasons (with
      station + status breakdown) and top affected WorkItems. Smoke-
      tested by `scripts/test/failures-smoke.sh`.
- [x] Per-station latency / success rate — `scripts/factory/metrics.sh`
      reads the ledger over a rolling window and prints a markdown or
      JSON summary (runs, success/failure/escalated counts, success
      rate, p50/p95 wall-seconds, tool calls). Smoke-tested by
      `scripts/test/metrics-smoke.sh`.
- [x] **Artifact snapshots in ledger Run records** — stations
      (`intake`, `spec`, `plan`, `qa`) persist the artefact body to
      `artifacts/YYYY/MM/DD/<run-id>.md` on `factory/ledger`
      via `scripts/factory/artifact-write.sh`, and the closing
      `ledger-write.sh end --artifact <path>` records the path in
      `artifacts.snapshot`. GitHub comments stay the canonical mutable
      surface; the snapshot is the immutable audit trail.

---

## Phase 4 — Specialised stations and skills

**Exit:** the factory is more than just "implement an issue" — it has a
library of repeatable skills the orchestrator can choose from.

- [ ] Skills: dependency upgrade, codemod, migration generation, flake triage
  - [x] Dependency upgrade —
        `.claude/skills/dep-upgrade/SKILL.md` (operational checklist),
        `scripts/skills/dep-upgrade-detect.sh` (ecosystem detector,
        25 cases in `scripts/test/dep-upgrade-detect-smoke.sh`),
        `docs/skills/dep-upgrade.md` (long-form rationale),
        `skill:dep-upgrade` label in policy, and a `weekly-deps`
        example in `.factory/schedule.yml`. Conservative-by-default:
        patch+minor only, one PR per ecosystem, hard-reset on test
        failure, never edits source code or approval-gate paths.
  - [ ] Codemod
  - [ ] Migration generation
  - [x] Flake triage —
        `.claude/skills/flake-triage/SKILL.md` (operational checklist),
        `scripts/skills/flake-triage-rank.sh` (read-only rank script
        that computes flake events at workflow granularity from
        `gh api .../actions/runs`, mockable via `--from-fixture`),
        20 cases in `scripts/test/flake-triage-rank-smoke.sh`,
        `docs/skills/flake-triage.md` (long-form rationale),
        `skill:flake-triage` + `flake:investigate` labels in policy,
        `gh api .../actions*` allowlisted, and a
        `nightly-flake-triage` example in `.factory/schedule.yml`.
        Read-only by design: never edits source, tests, workflows,
        or other PRs; only reports + files follow-up issues.
- [x] Recurring jobs wired to `schedule.yml` —
      `.factory/schedule.yml` declares recurring WorkItem templates
      (hourly/daily/weekly/monthly cadence with UTC hour gating);
      `.github/workflows/recurring-jobs.yml` runs hourly and calls
      `scripts/factory/schedule-tick.sh`, which evaluates each job
      against `schedule-state.json` on the state branch and files
      due issues. Smoke-tested by `scripts/test/schedule-smoke.sh`
      (16 decision cases, no GitHub round-trip). Schema documented
      in `.factory/schedule-schema.md`.
- [ ] Multi-task plans with parallel implementation
- [ ] Optional MCP integrations (additional source-of-truth tools)

---

## Phase 5 — Template polish

**Exit:** the repo is published as a GitHub template; "Use this template"
produces a working factory after `setup.sh`.

- [ ] Repo marked as a template
- [ ] Top-level `README` rewritten for the template consumer (not the designer)
- [ ] Walkthrough video / GIF of the smoke test
- [ ] First external user successfully bootstraps a factory
- [ ] Versioning + upgrade path for existing factory clones

---

## Out of roadmap (for now)

- Multi-repo / fleet management.
- Non-GitHub source hosts.
- A hosted control-room service.
- Self-modifying factory (the factory upgrading its own stations).
