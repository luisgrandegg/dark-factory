---
name: dep-upgrade
description: Apply safe dependency upgrades to a repository — patch and minor versions across the ecosystems present (npm/pnpm/yarn, pip/poetry/uv, cargo, go modules) — and open one PR per ecosystem. Runs the project test suite per ecosystem; rolls back any ecosystem whose tests fail. Major version bumps are listed but NOT applied automatically.
---

# Dependency upgrade skill

You are filling the **implement** station for a WorkItem that asks for a
dependency-upgrade sweep. The WorkItem will usually carry the
`skill:dep-upgrade` label and have been filed by the recurring
`weekly-deps` schedule (see `.factory/schedule.yml`), but a human can
file one ad-hoc.

This skill is intentionally **conservative**. The default is "boring,
mergeable, rollback-cheap." If you find yourself wanting to bypass a
guardrail, escalate instead.

## Hard rules

1. **Patch and minor only by default.** Major-version bumps land in the
   PR description as a checklist for a human to triage; you do not apply
   them. Major = the leading SemVer segment changes (or, for `0.x`
   versions, the second segment).
2. **One PR per ecosystem.** A flaky cargo test must not block the npm
   PR. Each ecosystem gets its own branch `claude/dep-upgrade-<eco>-<id>`
   and its own PR titled `chore(deps): <ecosystem> patch+minor sweep`.
3. **Test after, not before.** Run the project's existing test command
   per ecosystem; if it fails, hard-reset the ecosystem's working tree
   and report `failureReason: ci-failed` for that ecosystem only —
   continue with the others.
4. **Never touch approval-gate paths.** `.github/workflows/**`,
   `infra/**`, `migrations/**`, `.factory/policy.yml`,
   `.claude/settings.json` are off-limits even if a tool wants to edit
   them. The integrate sealer would refuse anyway.
5. **Never edit source code.** This skill only edits manifests and
   lockfiles. If a tool offers to "auto-fix" call sites, decline.
6. **No credentials.** Don't authenticate to private registries; if the
   public registry can't satisfy a resolve, leave the upgrade out and
   note it.

## Procedure

### 1. Read the test plan

The plan station produced a test-plan comment with checks like "all
ecosystems' lockfiles still resolve" and "project test command exits
0 on each ecosystem branch." Treat those as the contract. If the test
plan doesn't exist or doesn't match this skill's shape, escalate
(`stage:escalated`, `needs-human`).

### 2. Detect ecosystems

```
scripts/skills/dep-upgrade-detect.sh
```

Output is one JSON object per line: `{"ecosystem":"...", "manifest":"...", "lockfile":"...", "test":"..."}`.
A missing lockfile means *don't* upgrade that ecosystem — there's
nothing to pin against and a working-copy install would be
non-reproducible. Skip it and note it in the PR-of-record summary.

The detector understands: `npm`, `pnpm`, `yarn`, `pip` (requirements
files), `poetry`, `uv`, `cargo`, `go`. Ecosystems not detected are not
attempted — silence is correct.

### 3. For each ecosystem, in order

Branch from `main`:

```
git switch -c claude/dep-upgrade-<eco>-<id> origin/main
```

Run the upgrade command for the ecosystem (see table below). Commit the
manifest+lockfile change with subject
`chore(deps): <eco> patch+minor sweep` and a body listing each package
with `name old → new`. Commit nothing else.

Then run the project's test command **as recorded by the detector**
(e.g. `npm test`, `cargo test`, `go test ./...`, `pytest -q`). If it
exits non-zero:

```
git reset --hard origin/main
```

…and skip to the next ecosystem. Record the failure in the run summary
so the PR-of-record explains why this ecosystem was skipped.

If tests pass, push the branch and open a draft PR titled
`chore(deps): <eco> patch+minor sweep` with the body shape below.

### Ecosystem upgrade commands

| Eco    | Patch+minor upgrade command                                   | Test command (default)        |
| ------ | ------------------------------------------------------------- | ----------------------------- |
| npm    | `npm update --save && npm dedupe`                             | `npm test`                    |
| pnpm   | `pnpm update --latest=false`                                  | `pnpm test`                   |
| yarn   | `yarn upgrade --pattern '*' --tilde` (yarn classic) or `yarn up` (berry) | `yarn test`         |
| pip    | `pip-compile --upgrade requirements.in` (if `pip-tools`); otherwise leave manual and list outdated only | `pytest -q` |
| poetry | `poetry update --no-interaction`                              | `poetry run pytest -q`        |
| uv     | `uv lock --upgrade`                                           | `uv run pytest -q`            |
| cargo  | `cargo update`                                                | `cargo test --all`            |
| go     | `go get -u=patch ./... && go mod tidy`                        | `go test ./...`               |

Override the test command if the repo's README / package.json /
pyproject says something different — the detector will surface that.

### 4. Open the PR

Each ecosystem PR uses this body shape (markdown):

```
## Dependency upgrade — <ecosystem>

Filed by the `dep-upgrade` skill from #<workitem-id>.

### Patch + minor (applied)

| package | from | to |
| --- | --- | --- |
| ... | ... | ... |

### Major version bumps (NOT applied — needs human review)

| package | current | latest major |
| --- | --- | --- |
| ... | ... | ... |

### Test result

`<test command>` exited <code>. Output excerpt below if non-zero.

Closes #<workitem-id>
```

If the ecosystem produced **no** changes (everything already up to
date), do not open an empty PR. Note "no changes" in the run summary
and continue.

### 5. PR of record

After all ecosystems are processed, comment on the WorkItem issue with:

- One bullet per ecosystem: `npm: PR #N (12 patch, 4 minor, 0 major-skipped)` or `pip: skipped (no lockfile)` or `cargo: failed (test exited 101) — branch deleted`.
- The list of major-version bumps across all ecosystems, so a human can decide which deserve their own follow-up.

Then swap labels `stage:implement` → `stage:qa`. The contract-check
station picks up each PR independently.

### 6. Failure handling

- Detector exits non-zero → escalate. (Probably means the script is
  broken, not the repo.)
- Tool not installed (e.g. `pnpm` referenced by `pnpm-lock.yaml` but
  binary missing in the runner) → skip that ecosystem with reason
  `tool-not-installed`. Do not try to install it.
- Lockfile resolution fails → skip with reason `resolver-failed` and
  attach the first 30 lines of the resolver's output.
- Tests fail → skip with reason `ci-failed` after the hard-reset (rule
  3); do NOT keep retrying.

## What this skill does NOT do

- It does not bump major versions.
- It does not edit source code, even to chase deprecations.
- It does not touch private registries or credentials.
- It does not run on a schedule by itself — the recurring-jobs system
  (`.github/workflows/recurring-jobs.yml`) is what triggers it via the
  `weekly-deps` schedule.
- It does not bypass the QA station; each ecosystem PR goes through
  contract-check like any other PR.

See `docs/skills/dep-upgrade.md` for the long-form rationale and the
shape of the recurring-job entry that triggers it.
