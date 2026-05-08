---
description: Run one or more orchestrator ticks. Picks the highest-priority actionable WorkItem, advances it one station, writes the ledger, and loops until the queue is idle, the budget is hit, or the operator interrupts.
argument-hint: "[max-ticks]"
allowed-tools: Bash, Read, Grep, Glob, Edit, Write, Agent
---

Invoke the **factory** skill. Pass through the operator's optional
`max-ticks` argument (default unbounded, capped at 10 by the skill's
sanity check).

If the lock is held by another live session, surface that and exit;
do not retry. If `gh auth status` fails, surface that and exit; the
skill cannot operate without GitHub credentials.

After the loop completes, print:

- ticks executed
- WorkItems advanced (id → from-stage → to-stage)
- WorkItems escalated (id + reason)
- PRs opened / merged this session
- the path on the ledger branch where each Run record was written

Keep the summary under 10 lines unless the operator asks for more.
