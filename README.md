# Dark Factory

A **lights-out software development system** powered by [Claude Code](https://claude.ai/code).

A "dark factory" in manufacturing is a fully automated plant that runs without
human presence on the floor. This repository is the design of the **software
equivalent**: a template you can clone to bootstrap a repo where Claude Code
agents take work items from intake to merged PR with minimal human steering.

> Status: **design only**. No code yet. See [`docs/`](./docs).

---

## What you get when you clone the (future) template

A new GitHub repository pre-wired with:

- **Intake** — issues and external signals are automatically triaged, labelled,
  and turned into specs.
- **Planning** — specs are decomposed into tasks with file-level pointers.
- **Implementation** — Claude Code agents pick up tasks on isolated branches.
- **Review & QA** — automated review agents, tests, lint, type-checks.
- **Integration** — green PRs are merged; risky ones escalate to a human.
- **Observability** — per-run logs, token spend, success metrics, failure
  clusters.
- **Guardrails** — tool allowlists, budgets, approval gates for risky actions.

You bring the product idea and the budget. The factory does the floor work.

---

## The factory metaphor

| Factory          | Software Dark Factory                                |
| ---------------- | ---------------------------------------------------- |
| Raw materials    | Issues, backlog, alerts, scheduled tasks             |
| Conveyor         | GitHub Actions / orchestrator                        |
| Workstations     | Intake → Spec → Plan → Implement → QA → Integrate    |
| Workers          | Claude Code agents (main + subagents)                |
| Tooling          | Skills, hooks, slash commands, MCP servers           |
| Foreman          | Orchestrator that routes work and handles failures   |
| Quality control  | Review agents, tests, security scans                 |
| Loading dock     | Deploy pipeline                                      |
| Control room     | Dashboard: runs, cost, throughput, escalations       |
| Andon cord       | Human-in-the-loop escalation paths                   |

---

## Documents

- [`docs/architecture.md`](./docs/architecture.md) — components, domain model, workflows
- [`docs/template-contents.md`](./docs/template-contents.md) — what the cloneable template will contain
- [`docs/roadmap.md`](./docs/roadmap.md) — phased path from design → working template
- [`docs/adrs/`](./docs/adrs/) — architecture decision records

---

## Non-goals

- Replacing senior engineering judgement on novel product decisions.
- Operating without budgets, allowlists, or escalation paths.
- Locking into one stack — the template is **language- and stack-agnostic**;
  per-project specialisation happens after clone.
