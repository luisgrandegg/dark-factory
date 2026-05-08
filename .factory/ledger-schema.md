# Ledger schema

The ledger is the append-only audit trail of every Run. Files live on the
configured ledger branch (default `factory/ledger`, see ADR 0002), one
JSON document per Run. Files are written once and never edited.

## Layout

```
runs/YYYY/MM/DD/<ulid>.json
artifacts/YYYY/MM/DD/<ulid>.md
```

The Run record (`runs/...`) is mutable in shape (one read-modify-write
between `start` and `end`) but each station emission is final. Its
sibling artifact (`artifacts/...`) is the immutable snapshot of the
station's output body — the literal markdown the station posted as a
GitHub comment, captured the moment it was posted. GitHub comments
remain the canonical mutable surface for humans; the snapshot is the
audit trail that survives later edits.

`YYYY/MM/DD` is the UTC date the Run started. The ULID sorts
lexicographically by time, so `ls runs/2026/05/08 | sort` is a
chronological view.

A small index, `runs/by-workitem/<id>.jsonl`, is appended to on Run end
with one line per Run for O(1) per-WorkItem lookup. JSONL because we
only ever append — no rewrite race.

## Document

```json
{
  "schemaVersion": 1,
  "id": "01HW4...",                  // ULID, also the filename stem
  "workItemId": 42,                  // GitHub issue number
  "station": "intake|spec|plan|implement|qa|integrate",
  "agent":   "main|subagent:<name>|skill:<name>",
  "host":    "web|local",            // which orchestrator host drove it
  "sessionId": "claude-...",         // best-effort; null if unknown
  "parentRunId": null,               // set when emitted by a sub-run

  "startedAt": "2026-05-08T13:01:02.123Z",
  "endedAt":   "2026-05-08T13:01:47.998Z",  // null while status=running
  "status":    "running|success|failure|escalated",
  "failureReason": null,             // short string when status != success

  "artifacts": {
    "filesTouched": [],              // implement only
    "branch": null,                  // claude/<slug> when applicable
    "pr": null,                      // PR number
    "comments": [],                  // [{type:"spec|plan|review", url, id}]
    "snapshot": null                 // ledger path of immutable artefact body, e.g.
                                     //   artifacts/2026/05/08/<id>.md
  },

  "usage": {
    "tokensIn":    null,             // null when the host doesn't expose it
    "tokensOut":   null,
    "wallSeconds": 0,
    "toolCalls":   0,
    "costUsd":     null              // reserved; never populated in v1
  },

  "labelTransition": {               // last-step label swap, when applicable
    "from": "stage:plan",
    "to":   "stage:implement"
  }
}
```

### Invariants

- `id` is a Crockford ULID; the filename is `<id>.json`.
- A Run is written *twice*: once at start (`status=running`, `endedAt=null`)
  and once at end (full payload). Both writes use the GitHub Contents API
  with the parent SHA from the previous read; conflicts are retried.
- `artifacts/<...>.md` is **write-once**. `artifact-write.sh` is
  idempotent on re-run with the same `runId`: it does not overwrite. If
  a station re-runs (retry), it reuses its prior snapshot; comments may
  be re-posted but the audit trail does not branch.
- Each artifact begins with a small YAML front-matter (`kind`,
  `workItemId`, `runId`, `recordedAt`); the body that follows is the
  literal markdown the station posted as a comment.
- `usage.toolCalls` and `usage.wallSeconds` are always populated. Token
  fields are best-effort (ADR 0004).
- `parentRunId` chains sub-runs to the station Run that spawned them.
  Roll-ups sum the leaves to avoid double-counting.
- `failureReason` uses a short controlled vocabulary:
  `budget`, `lock-stolen`, `tool-denied`, `ci-failed`, `review-rejected`,
  `interrupted`, `unknown`.

### Reading the ledger

The dashboard generator reads the ledger branch and renders the static
control room into `.factory/dashboard/` on `main`. Operators can also
`git fetch origin factory/ledger && git log` for a raw view.

### Compaction

Ledger files are immutable. When the branch grows large (Phase 3+),
compaction takes the form of a new orphan branch
`factory/ledger-archive-<yyyy>` and a force-push of the live branch to
prune older months. Because nothing on `main` references ledger paths,
this is safe.
