# Contributing to the dark factory

This document is for contributors **extending** the factory itself —
adding a station, an agent, a skill, or a new storage surface. It is
deliberately **not** in `CLAUDE.md`: that file is loaded into every
session, and nothing here is needed during a routine `/factory-tick`.

If you only want to file or watch a WorkItem, you don't need this.

## Adding a new station, agent, or skill

1. **Write the ADR first if the change is structural** — new station,
   new storage surface, new lock, new escalation path. ADRs live in
   `docs/adrs/` and are immutable once accepted. See ADRs 0001–0004
   for shape.
2. **Add the agent definition to `.claude/agents/<name>.md`.** Keep
   `tools:` tight (only what the station needs) and write a
   `description:` the foreman can route on — it's the one line the
   orchestrator reads to pick this agent over another.
3. **If the station spawns its own subagents,** every spawn must pass
   `parentRunId` so the ledger roll-up doesn't double-count usage.
   See the QA station for the pattern.
4. **Update `.factory/policy.yml`** to register the stage in `stages`,
   add transitions, and put a budget under `budgets.perStation`.
5. **Update the factory skill** (`.claude/skills/factory/SKILL.md`) so
   the foreman knows when to spawn the new station and how to interpret
   its verdict.
6. **Smoke-test** by filing a `factory:smoke` issue and watching it
   land end-to-end. If a station hangs, escalate manually and read the
   ledger before changing the agent — the wrong fix here is
   prompt-iteration based on vibes.

## Adding a new ADR

ADRs are numbered, accepted-only-once, and live forever. The numbering
goes 000N-short-slug.md. Use the existing ADRs as the template:
context → decision → consequences → status. If the decision needs to
change, file a new ADR that supersedes the old one — never edit an
accepted ADR in place.

## Where else to look before touching the factory

- `docs/architecture.md` — how the pieces fit together.
- `docs/roadmap.md` — what's deferred to Phase 2+ and why.
- `.factory/ledger-schema.md` — the Run record contract.
- `CLAUDE.md` — the operating contract for every session (invariants,
  escalation, where to look).
