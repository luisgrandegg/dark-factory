# 0005 — SDLC step contract and implementation registry

- **Status:** Proposed
- **Date:** 2026-05-09

## Context

Today the factory's SDLC steps (intake, spec, plan, implement, qa,
integrate) are tightly coupled to this repo's conventions. Each handler
is hardcoded in the orchestrator (`.claude/skills/factory/SKILL.md`) and
points at a specific subagent, an inline block, or a workflow:

| Step      | Handler today                                        |
| --------- | ---------------------------------------------------- |
| intake    | `.claude/agents/intake.md` (subagent)                |
| spec      | inline in the factory skill                          |
| plan      | `.claude/agents/plan.md` (subagent)                  |
| implement | main session + a skill picked by `skill:*` label     |
| qa        | `.claude/agents/contract-check.md` (subagent)        |
| integrate | `.github/workflows/integrate.yml` (workflow)         |

Two pressures push back on this:

1. **Portability.** Phase 5 turns the repo into a GitHub template
   (`docs/roadmap.md`). A second consumer repo will want to plug in its
   own implementations — its own QA harness, its own integrate flow —
   without forking the orchestrator.
2. **Precedent.** The implement step *already* delegates to
   consumer-shaped implementations (`codemod`, `dep-upgrade`,
   `migration-generation`, `flake-triage`) selected by `skill:*` labels.
   The pattern is half-built; we either generalise it or it ossifies as
   a one-step special case.

Forces:

- The invariants in `CLAUDE.md` (one stage label, ledger entry per Run,
  approval gates, escalate-don't-guess) must survive any pluggability.
- Implementations come in different shapes today (subagent, inline,
  skill, workflow). The contract has to accept all four without
  collapsing them into one.
- Selection has to be cheap — it runs every tick.

## Decision

Each SDLC step is a **contract**, declared once in the factory. An
**implementation** is anything that satisfies a contract. The
orchestrator picks an implementation per WorkItem, per tick, via an
explicit selector chain.

### Step contract

A YAML document at `.factory/sdlc/<step>.yml`. One file per step. Owned
by the factory; consumer repos do not edit these.

```yaml
# .factory/sdlc/implement.yml
step: implement
inputs:  [workitem, spec, plan]
outputs: [branch, commits, pr-draft]
preconditions:
  - "workitem has stage:plan"
  - "plan artefact exists on factory/ledger"
postconditions:
  - "workitem has stage:qa"
  - "PR exists referencing workitem"
  - "Run record closed with branch + pr fields"
gates:
  - allowlist
  - approvalGates
  - "budgets.perStation.implement"
ledger:
  required: [branch, pr, files]
  optional: [reason]
```

The contract names *what* must hold; it never prescribes *how*.

### Implementation manifest

Every implementation declares which step it satisfies and how it should
be selected. Manifests live where the implementation lives:

- subagent: frontmatter in `.claude/agents/<name>.md`
- skill:    frontmatter in `.claude/skills/<name>/SKILL.md`
- inline:   a block inside the factory skill registered by name
- workflow: a stub at `.factory/sdlc/impls/<step>-<name>.yml`
            pointing at a `.github/workflows/*.yml` file

Frontmatter shape:

```yaml
implements: implement
kind: skill           # subagent | skill | inline | workflow
selects:
  - { label: "skill:codemod" }
  - { autodetect: { any_file_exists: ["codemod.spec.json"] } }
priority: 50          # tie-break, higher wins; default 0
```

### Selector chain

Per WorkItem, per step, the orchestrator picks in this order and
**stops at the first match**:

1. **Explicit label.** If the WorkItem carries a `skill:*` (or
   `impl:*`) label whose implementation declares that label in
   `selects`, that wins.
2. **Autodetect.** Cheap probes against the consumer repo
   (file-exists, language, CI provider). Probes are pure — they may
   read but not execute.
3. **Default.** A step may declare exactly one `default: true`
   implementation. Used when nothing else matches.
4. **Escalate.** No match, no default → stage flips to
   `stage:escalated` with reason `no-implementation` and a comment
   naming the step.

Ties at the same tier break by `priority`, then by file path.

### Boundaries

- The orchestrator records the chosen implementation in the Run record
  (`impl: { step, name, kind, reason }`) so the ledger explains *why*
  this implementation ran.
- Approval gates and the allowlist are checked by the orchestrator
  *around* the implementation, not by the implementation itself.
- `policy.yml` budgets remain the per-step cap; implementations cannot
  raise them.

## Consequences

Positive:

- A second consumer repo can ship its own QA, its own integrate, its
  own migration scaffolder by adding files — never by forking the
  orchestrator.
- The implement step's existing `skill:*` mechanism becomes a special
  case of a uniform pattern, not its own snowflake.
- Every Run records *which* implementation handled it, making the
  ledger materially more useful for debugging consumer factories.
- Adding a new station (Phase 4 wishlist: parallel implement) is a
  contract + at least one implementation, not a deep edit of the
  factory skill.

Negative / accepted costs:

- A new schema (`.factory/sdlc/*.yml` and the implementation
  frontmatter). Validated by `doctor.sh`; broken manifests escalate
  rather than panic.
- Selection adds tick latency — two file reads and a probe pass. We
  cap probes at fast operations only; expensive checks belong in the
  implementation, not in selection.
- The `factory` skill grows a registry-load step. Documented in
  `docs/architecture.md` so the cost is visible.

## Alternatives considered

- **Status quo (hardcoded stations).** Cheapest today, most expensive
  the day a second repo arrives. Rejected because Phase 5 explicitly
  targets that day.
- **One configurable station object.** Collapse all four
  implementation kinds (subagent / skill / inline / workflow) into a
  single shape. Rejected: the kinds have genuinely different
  invocation models (token cost, where they run, what they can
  write). Forcing one shape would make every implementation the
  worst-case of all four.
- **Autodetect-only, no labels.** Rejected: explicit label override
  is essential for the cases autodetect gets wrong, and matches how
  the implement step already works.
- **Defer until Phase 5.** Rejected: every station added between now
  and then will entrench the hardcoded pattern further. Cheaper to
  pay the abstraction cost now, while there are six steps to convert
  rather than ten.
