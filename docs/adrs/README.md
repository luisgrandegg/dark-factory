# Architecture Decision Records

Lightweight records of the decisions that shape the dark factory. Each ADR
captures the context, the decision, and the consequences — including the
options we rejected and why.

ADRs are immutable once accepted. To change a decision, write a new ADR that
**supersedes** the old one and update the status link below.

| #    | Title                                                | Status   |
| ---- | ---------------------------------------------------- | -------- |
| 0001 | [Orchestrator runtime](./0001-orchestrator-runtime.md) | Accepted |
| 0002 | [State durability](./0002-state-durability.md)         | Accepted |
| 0003 | [Concurrency model](./0003-concurrency-model.md)       | Accepted |
| 0004 | [Secret and cost attribution](./0004-secret-and-cost-attribution.md) | Accepted |
| 0005 | [SDLC step contract and implementation registry](./0005-sdlc-step-contract.md) | Proposed |
| 0006 | [Repo-level check harness](./0006-repo-check-harness.md) | Proposed |

## Format

Each ADR follows:

- **Status** — Proposed / Accepted / Superseded by #N
- **Context** — what forces are at play
- **Decision** — what we're doing
- **Consequences** — what becomes easier, harder, or required as a result
- **Alternatives considered** — options we rejected, with reasons

Keep them short. If an ADR runs past two pages, it's probably two ADRs.
