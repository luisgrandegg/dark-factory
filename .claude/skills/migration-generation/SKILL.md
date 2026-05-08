---
name: migration-generation
description: Scaffold a new database migration file for the toolchain in use (Alembic, Django, Rails, Knex, or raw SQL). The skill detects the toolchain, generates a properly-named empty migration with the canonical boilerplate, and opens a draft PR tagged needs-human. It does NOT write the migration body and does NOT execute migrations against any database.
---

# Migration-generation skill

You are filling the **implement** station for a WorkItem that asks
for a new database migration. Triggered by an issue with the
`skill:migration` label and a small JSON spec naming the
toolchain (or letting the skill detect it) and a migration name.

This skill is the **only** factory skill that deliberately writes
inside an approval-gate path (`migrations/**` for some toolchains).
The safety play has three layers:

1. The skill produces an **empty scaffold** — filename, location,
   boilerplate. It does not invent migration logic.
2. Every PR opened by this skill carries the `needs-human` label,
   which is on `policy.approvalGates`. The integrate sealer refuses
   to auto-merge.
3. The skill never executes migrations. There is no contact with
   any database from inside the factory.

## Hard rules

1. **Scaffold only, never body.** The migration file is created
   with the canonical class/exports skeleton plus a `# TODO: human
   writes the body` comment in the up/down (or change) sections.
   No further edits.
2. **Single file per PR.** One migration scaffold per WorkItem.
   Multi-step migrations are filed as multiple WorkItems.
3. **`needs-human` label always.** Even though the implement
   station opens the PR, the integrate sealer must not auto-merge.
4. **No database connection.** The skill does not run
   `alembic upgrade`, `python manage.py migrate`, `bundle exec
   rails db:migrate`, or `knex migrate:latest`. It also does not
   use `--autogenerate`-style commands that introspect a live
   database.
5. **No model edits.** Even when `--autogenerate` would work, this
   skill does not edit models / schemas / `models.py` / etc. The
   human writes the migration body that matches the model state
   they themselves are introducing.
6. **Detector tells the truth or escalate.** If the detector
   doesn't recognise the toolchain, escalate. Don't guess.

## The spec

Embedded as a fenced JSON block on the WorkItem:

```json
{
  "toolchain": "alembic" | "django" | "rails" | "knex" | "raw-sql",
  "name":      "add_email_to_users",
  "app":       "<app-name>"  // django only
}
```

`toolchain` is optional — if absent, the skill runs the detector
(`scripts/skills/migration-detect.sh`) and uses its first match.
If the detector finds nothing, escalate.

`name` is required. Lowercase, snake_case, ≤ 60 chars. Used as part
of the filename per toolchain convention.

`app` is required only for Django.

## Procedure

### 1. Read & validate the spec

If `toolchain` is missing, run the detector:

```
scripts/skills/migration-detect.sh
```

It emits one JSON line per detected toolchain. Pick the first one
(detector emits in canonical order). If empty, escalate.

### 2. Scaffold the file

```
scripts/skills/migration-scaffold.sh \
  --toolchain <name> \
  --migration-name <slug> \
  [--app <app>]   # django only
```

The scaffolder:
- Computes the canonical filename per toolchain (timestamp / sequence).
- Writes a stub file with the toolchain's required boilerplate.
- Includes a single `# TODO: human writes the migration body` comment.
- Prints the new file's relative path on stdout.

Do NOT edit the file after scaffolding. The body belongs to the
human reviewer.

### 3. Open the draft PR

Single commit. Subject:

```
chore(migration): scaffold <toolchain> migration <name>
```

Body:

```
Filed by the **migration-generation** skill from #<workitem-id>.

This PR contains an empty scaffold only. The migration body is
intentionally left blank for the human reviewer to fill in.

- Toolchain: <name>
- File:      <path>
- App:       <app>   (django only)

⚠️ This PR is tagged `needs-human` and will not be auto-merged.
The reviewer must:

  1. Fill in the migration body (up + down, or change).
  2. Run the toolchain's verifier locally
     (e.g. `alembic check`, `python manage.py makemigrations
     --check`, `rails db:migrate:status`).
  3. Approve and merge once green.

Closes #<workitem-id>
```

Apply labels: existing factory labels for the workflow, plus
`needs-human` (so the integrate sealer doesn't auto-merge).

Open the PR as **draft** — the human marks it ready after writing
the body.

### 4. Close out

Comment on the issue with the PR number. Swap labels
`stage:implement` → `stage:qa`. The contract-check station verifies
the test plan's checks (e.g. "scaffold file exists at expected
path", "PR has needs-human label"); since the PR is draft, the
integrate sealer holds it until a human flips it to ready.

### 5. Failure handling

| Symptom                              | Skill behaviour                                               |
| ------------------------------------ | ------------------------------------------------------------- |
| Detector finds nothing               | Escalate (`stage:escalated`, comment explains).               |
| Spec has no `name`                   | Escalate.                                                     |
| Toolchain `django` and no `app`      | Escalate.                                                     |
| Filename collision                   | Escalate. (Don't append `-1` — the human picks the name.)     |
| Approval-gate path edit attempted    | Refuse and escalate. Should be impossible — the scaffolder writes only to the toolchain's canonical migration directory. |

## What this skill does NOT do

- It does not write migration bodies.
- It does not run `--autogenerate` or any database introspection.
- It does not execute migrations.
- It does not touch models / schema files.
- It does not auto-merge: every PR carries `needs-human`.
- It does not run on a schedule. Always operator-filed for a
  specific change.

See `docs/skills/migration-generation.md` for the long-form
rationale and per-toolchain examples.
