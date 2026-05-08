# Template contents

This is the shape of the cloneable template repo we're working towards. When a
user clicks **Use this template** on GitHub, they should get a repo that is
ready to operate after a one-shot setup.

> Status: planned. Nothing in this list exists yet.

---

## Directory layout

```
.
├── .claude/
│   ├── agents/                  # subagent definitions (intake, spec, plan, review, ...)
│   ├── skills/                  # repeatable capabilities
│   ├── commands/                # slash commands (/factory-status, /factory-retry, ...)
│   ├── hooks/                   # SessionStart / PreToolUse / Stop scripts
│   └── settings.json            # tool allowlist, hooks, model defaults
│
├── .factory/
│   ├── policy.yml               # budgets, allowlists, approval gates
│   ├── prompts/                 # canonical prompts per station
│   ├── runs/                    # run ledger (one file per run, JSON)
│   ├── state/                   # WorkItem state snapshots
│   └── dashboard/               # static control room (generated)
│
├── .github/
│   ├── workflows/
│   │   ├── intake.yml           # on: issues opened/edited
│   │   ├── plan.yml             # on: label "stage:plan"
│   │   ├── implement.yml        # on: label "stage:implement"
│   │   ├── qa.yml               # on: pull_request
│   │   ├── integrate.yml        # on: PR labelled "stage:integrate"
│   │   ├── schedule.yml         # cron: recurring jobs
│   │   └── report.yml           # cron: control-room rebuild
│   ├── ISSUE_TEMPLATE/          # the shape of work the factory consumes
│   └── PULL_REQUEST_TEMPLATE.md
│
├── docs/
│   ├── architecture.md          # what's here
│   ├── runbook.md               # how to operate the factory
│   ├── escalation.md            # what to do when the andon is pulled
│   └── adrs/                    # decision records
│
├── scripts/
│   ├── setup.sh                 # one-shot bootstrap after clone
│   ├── doctor.sh                # diagnoses misconfiguration
│   └── new-skill.sh             # scaffolds a new skill
│
├── CLAUDE.md                    # project memory: conventions and invariants
├── LICENSE
└── README.md
```

---

## What `setup.sh` does

A single command after cloning. Idempotent.

1. Verifies `gh` is installed and authenticated.
2. Creates the labels the factory needs (`stage:*`, `priority:*`,
   `needs-human`, `escalated`, `factory:*`).
3. Creates the GitHub Environments and required secrets (`ANTHROPIC_API_KEY`,
   etc.) — prompts the user for values it can't infer.
4. Enables the workflows.
5. Files a "first ticket" issue that the factory consumes end-to-end as a
   smoke test.
6. Prints links to the control room and the runbook.

Failure modes surface as a list of `doctor.sh`-fixable items.

---

## What `CLAUDE.md` should contain (in the template)

Project memory for every Claude Code session that runs in this repo:

- The factory's invariants ("never push to main directly", "never bypass the
  approval-gate paths").
- How to read the policy file.
- Where state lives.
- How to add a new station / agent / skill.
- Conventions for commit messages, branch names, PR descriptions.

The template ships a generic `CLAUDE.md`; project owners specialise it.

---

## What ships empty (intentionally)

- Application code. The template is **stack-agnostic**; users add their app.
- Deploy pipelines. Project-specific.
- Product-specific skills. Generic ones ship; users add domain skills.

---

## What does NOT ship in the template

- Secrets or API keys.
- A bundled database.
- A vendored Claude Code binary (we depend on the user's installation / the
  GitHub Action).
- Opinionated language tooling (linters, formatters, test runners) — those
  arrive when the user adds their app.
