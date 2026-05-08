# Skill: dep-upgrade

The `dep-upgrade` skill is a **conservative dependency-upgrade
sweeper**: per ecosystem present in the repo, it bumps patch and minor
versions, runs the project's existing test command, and opens one PR
per ecosystem. Major-version bumps are listed in the PR description
for human triage but **not applied**.

The terse, operational version of these rules lives in
[`.claude/skills/dep-upgrade/SKILL.md`](../../.claude/skills/dep-upgrade/SKILL.md);
that's what the implement station reads each tick. This document is
the long-form rationale — read it once, refer back when something
unexpected happens.

## Why this shape

### One PR per ecosystem

The naive design is one big PR with everything bumped. We avoid it for
three reasons:

1. **Test isolation.** A flaky cargo test that's unrelated to any of
   the npm changes shouldn't block the npm PR's merge. With one PR per
   ecosystem, contract-check evaluates each independently.
2. **Bisect-friendly.** When a dep upgrade breaks production a week
   later, you want a single-ecosystem revert, not a 200-line surgical
   extraction.
3. **Reviewer cognitive load.** Reading "10 patch bumps in npm" is
   cheap. Reading "10 patch bumps spread across 4 ecosystems with
   2 incidental cross-references" is not.

The tradeoff is more PRs per week. We accept that.

### Patch + minor only

SemVer is mostly aspirational, but it's the contract publishers
broadcast. Patch and minor are *meant* to be safe; major is *meant* to
require migration work. We follow that contract: the bot does what's
billed as safe, and stops at the line where SemVer says a human should
be involved.

For `0.x` versions we treat the second segment as the major-equivalent
(`0.4.5 → 0.4.6` is a patch; `0.4.5 → 0.5.0` is a major). This
matches the SemVer spec's "0.x is unstable" footnote and how most
ecosystems' resolvers actually behave.

### Tests must pass on the upgraded branch

The skill runs the project's existing test command on each ecosystem
branch. If it fails, the skill does `git reset --hard origin/main` on
that branch and reports `failureReason: ci-failed`. Two reasons:

1. **A green dep upgrade is the entire point.** A red upgrade is
   strictly worse than no upgrade — it's noise that someone has to
   investigate.
2. **No half-measures.** We don't try to "fix" the failure with code
   changes. The skill does not edit source code. If patch+minor breaks
   tests, that's a real signal — a human owns it.

### No source-code edits

The skill edits only `package.json`/lockfiles, `pyproject.toml`/locks,
`Cargo.toml`/`Cargo.lock`, `go.mod`/`go.sum`. It declines, by policy,
to:

- Apply codemods to chase deprecations.
- Bump runtime versions (Node, Python, Rust, Go).
- Touch CI configuration.
- Modify any approval-gate path (`.github/workflows/**`,
  `infra/**`, `migrations/**`, `.factory/policy.yml`,
  `.claude/settings.json`).

If a tool (e.g. `npm dedupe`) tries to rewrite an unrelated file, the
skill stages only the manifest+lockfile and discards the rest.

### No private-registry credentials

Private registries are trust boundaries. We don't authenticate from
inside the factory because:

- Credentials in CI broaden the blast radius if the runner is
  compromised.
- A failed resolve on the public registry is informative on its own
  ("internal package X is missing") and the skill notes it in the PR;
  a human can decide to authenticate and re-run manually.

## Triggering

Three ways a `dep-upgrade` WorkItem reaches the implement station:

### 1. Recurring schedule (the intended path)

`.factory/schedule.yml` ships a (commented) `weekly-deps` entry that
files an issue every Monday at 13:00 UTC with the
`skill:dep-upgrade, stage:intake, priority:p3` labels. The factory
loop triages it through intake → spec → plan → implement, and the
implement station picks up the SKILL.md when it sees the
`skill:dep-upgrade` label.

To enable it: uncomment the entry in `.factory/schedule.yml` and merge
the result through PR (the file is on a non-gated path, so it doesn't
need approval).

### 2. Ad-hoc issue

A human files an issue titled "Dependency upgrade sweep" with the
`skill:dep-upgrade, stage:intake` labels. Same flow as above, just
without the schedule.

### 3. CVE-driven (Phase 2+)

Not implemented yet. The future shape: a `dependency-review` workflow
on `main` opens a `priority:p1, skill:dep-upgrade` issue for any
critical advisory it sees. The implement station then upgrades only
the affected package, not the full sweep.

## What gets attempted, per ecosystem

| Ecosystem | Manifest         | Lockfile           | Upgrade command                            | Test command (default)        |
| --------- | ---------------- | ------------------ | ------------------------------------------ | ----------------------------- |
| npm       | `package.json`   | `package-lock.json`/`npm-shrinkwrap.json` | `npm update --save && npm dedupe` | `npm test`             |
| pnpm      | `package.json`   | `pnpm-lock.yaml`   | `pnpm update --latest=false`               | `pnpm test`                   |
| yarn      | `package.json`   | `yarn.lock`        | `yarn upgrade --pattern '*' --tilde`       | `yarn test`                   |
| pip       | `requirements.in`| `requirements.txt` | `pip-compile --upgrade requirements.in`    | `pytest -q`                   |
| poetry    | `pyproject.toml` | `poetry.lock`      | `poetry update --no-interaction`           | `poetry run pytest -q`        |
| uv        | `pyproject.toml` | `uv.lock`          | `uv lock --upgrade`                        | `uv run pytest -q`            |
| cargo     | `Cargo.toml`     | `Cargo.lock`       | `cargo update`                             | `cargo test --all`            |
| go        | `go.mod`         | `go.sum`           | `go get -u=patch ./... && go mod tidy`     | `go test ./...`               |

`pip` is conservative: only repos using `pip-tools` (a `requirements.in`
alongside `requirements.txt`) are detected, because we need a
deterministic source to compile from. A bare `requirements.txt` is
intentionally skipped.

The detector that produces this list is
[`scripts/skills/dep-upgrade-detect.sh`](../../scripts/skills/dep-upgrade-detect.sh).
Smoke-tested by
[`scripts/test/dep-upgrade-detect-smoke.sh`](../../scripts/test/dep-upgrade-detect-smoke.sh)
across 25 cases (every ecosystem, missing-lockfile fallbacks,
multi-lockfile JS repos, polyglot canonical ordering, and the bad-arg
paths).

## Failure modes & what the skill does

| Symptom                          | Skill behaviour                                                |
| -------------------------------- | -------------------------------------------------------------- |
| Detector finds nothing           | Comment "no supported ecosystems" on the issue and close it.   |
| Tool not installed in runner     | Skip ecosystem with reason `tool-not-installed`.               |
| Lockfile resolution fails        | Skip ecosystem with reason `resolver-failed`; PR-of-record gets the first 30 lines of resolver output. |
| Tests fail after upgrade         | `git reset --hard origin/main`; skip with reason `ci-failed`. |
| Major-version bump available     | Listed in PR description; **not applied**.                     |
| All ecosystems already up-to-date| No PRs opened; comment "nothing to upgrade" and close.         |

## Out of scope (today)

- Major-version bumps (the skill lists them; humans decide).
- Editing source code to chase API changes.
- Bumping runtime/toolchain versions.
- Modifying CI configuration.
- Touching approval-gate paths.
- Authenticating to private registries.
- Cross-ecosystem coordination (e.g. "bump TypeScript and `@types/*`
  together in one PR"). The skill does each ecosystem independently.

## See also

- [`.claude/skills/dep-upgrade/SKILL.md`](../../.claude/skills/dep-upgrade/SKILL.md) — operational checklist used at tick time.
- [`.factory/schedule.yml`](../../.factory/schedule.yml) — recurring trigger.
- [`.factory/schedule-schema.md`](../../.factory/schedule-schema.md) — schedule format.
- [`docs/architecture.md`](../architecture.md) — where this skill sits in the factory.
