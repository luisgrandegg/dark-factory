# Testing the factory

Practical recipes for verifying that the factory works end-to-end.
Three tiers: cheap to expensive. Each later tier exercises more of the
system but takes more time, more Actions minutes, or more cleanup.

| Tier | Cost | What it catches |
| ---- | ---- | --------------- |
| 1 — local helpers (~30 s) | none | regressions in the shell helpers, hook patterns, gate-pattern matcher |
| 2 — live read-only (~1 min) | one `gh` session | install drift: missing labels, stale lock, malformed `budget.json`, branches gone |
| 3 — end-to-end (~5–15 min) | a real PR per test | the orchestrator loop and each Phase 2 guardrail under the conditions it's there to catch |

## Where to run tests

| Test                                        | Repo                                          |
| ------------------------------------------- | --------------------------------------------- |
| Tier 1, Tier 2, Tier 3 **smoke**            | this (canonical) repo                         |
| Tier 3 **negative tests** (fake secret, tripped budgets, gated-path PRs, etc.) | a throwaway, via `scripts/seed-test-repo.sh` |

The negative tests deliberately misbehave — fake secrets in PR history,
intentionally lowered caps, gated-path PRs that escalate. You don't
want that noise in the canonical template repo someone else will
eventually clone. One command spins up a clean target:

```bash
scripts/seed-test-repo.sh --name dark-factory-test
# teardown when done:
gh repo delete <owner>/dark-factory-test --yes && rm -rf dark-factory-test
```

See the script's `--help` for `--public`, `--org`, `--workdir`,
`--no-clone`.

---

## Tier 1 — local helpers (no GitHub roundtrip)

```bash
# Static lint of every shell script the factory ships.
shellcheck -P scripts/factory -x \
  scripts/factory/*.sh .claude/hooks/*.sh \
  scripts/setup.sh scripts/doctor.sh scripts/seed-test-repo.sh

# Doctor's offline checks (skips API roundtrips).
bash scripts/doctor.sh --quick
```

### PreToolUse hook

The hook should refuse destructive shell ops and pushes to anything
other than `claude/*`, `factory/state`, `factory/ledger`, or tags.

```bash
# These should each exit 2 and print "blocked by pre-tool-bash hook: ..."
printf '%s' '{"command":"git reset --hard HEAD"}' | .claude/hooks/pre-tool-bash.sh; echo $?
printf '%s' '{"command":"git push origin main"}'  | .claude/hooks/pre-tool-bash.sh; echo $?
printf '%s' '{"command":"git push origin random-branch"}' | .claude/hooks/pre-tool-bash.sh; echo $?

# These should exit 0.
printf '%s' '{"command":"ls -la"}'                       | .claude/hooks/pre-tool-bash.sh; echo $?
printf '%s' '{"command":"git push -u origin claude/foo-1"}' | .claude/hooks/pre-tool-bash.sh; echo $?
```

### Approval-gate matcher

```bash
# Path hits.
printf 'infra/foo.tf\nsrc/app.py\n' | scripts/factory/check-gates.sh --labels ""
# expect exit 1 and "path:infra/foo.tf:infra/**"

# Label hit only.
printf '' | scripts/factory/check-gates.sh --labels "release"
# expect exit 1 and "label:release"

# Clean.
printf 'src/app.py\n' | scripts/factory/check-gates.sh --labels "priority:p2"
# expect exit 0
```

---

## Tier 2 — live, read-only on your repo

```bash
# Full doctor: branches, lock health, label inventory, workflows,
# multi-stage corruption.
bash scripts/doctor.sh

# Inspect the per-day budget rollup the foreman maintains.
slug=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api "repos/$slug/contents/budget.json?ref=factory/state" \
  --jq .content | base64 -d | jq .

# Inspect the smoke-test issue's ledger index (replace <id> with its number).
gh api "repos/$slug/contents/runs/by-workitem/<id>.jsonl?ref=factory/ledger" \
  --jq .content | base64 -d
```

If `doctor.sh` is green, your install is healthy.

---

## Tier 3 — end-to-end

### Smoke (always run this first)

The cheapest end-to-end check is to re-run Phase 1's smoke test under
Phase 2's guardrails. If the original smoke issue is closed, file a new
one:

```bash
gh issue create --title "factory: smoke test" \
  --body "Add scripts/hello-2.sh that prints 'hello, dark factory v2' and exits 0." \
  --label "stage:queued,priority:p2,factory:smoke"
```

Then in Claude Code (CLI: `claude`, or via the web app):

```
/factory-tick
```

Expected end-state: the issue is closed; a `claude/<slug>-<id>` PR was
merged into `main`; the ledger branch has Run records under
`runs/YYYY/MM/DD/`. If this works, the orchestrator loop, lock,
ledger, integrate sealer, and `secret-scan.yml` are all healthy
together.

### Negative tests (one per Phase 2 guardrail)

Run each in a throwaway repo (`seed-test-repo.sh`). Each is independent;
order doesn't matter.

#### 1. Approval gate (path-based)

File an issue that *requires* an `infra/**` change:

```bash
gh issue create --title "factory: gated-path test" \
  --body "Add infra/dummy.tf containing a single \`# dark-factory test\` line." \
  --label "stage:queued,priority:p2"
```

Tick. Expected:

- `contract-check` returns `human-review` with reason `gated-path`.
- The issue is back in `stage:qa` with `needs-human` (not in
  `stage:integrate`).
- If you manually re-label to `stage:integrate`, `integrate.yml`
  comments and removes the label rather than merging.

#### 2. Secret scan

File an issue, let the factory open the PR, then push a fake-secret
commit to its branch:

```bash
gh issue create --title "factory: secret-scan test" \
  --body "Add scripts/leak.sh that prints a hard-coded message." \
  --label "stage:queued,priority:p2"
# /factory-tick once, until a PR exists. Then:
PR_BRANCH=$(gh pr list --json headRefName --jq '.[0].headRefName')
git fetch origin "$PR_BRANCH" && git switch "$PR_BRANCH"
printf '\nAWS_KEY="AKIAIOSFODNN7EXAMPLE"\n' >> scripts/leak.sh
git commit -am "test: trip secret-scan" && git push
```

Expected: the `Secret scan (gitleaks)` check fails; the integrate
sealer comments and adds `needs-human` instead of merging, even if
`stage:integrate` is set.

After the test: `gh pr close <pr> --delete-branch`. The fake key is
already in git history, but the throwaway repo will be deleted soon.

#### 3. Budget kill-switch

Drop a per-WorkItem cap to 1 via PR (the policy.yml gate forces a
manual merge — that's expected):

```bash
git switch -c claude/test-budget-cap
sed -i 's/maxToolCalls: 400/maxToolCalls: 1/' .factory/policy.yml
git commit -am "test: lower per-WorkItem cap"
git push -u origin claude/test-budget-cap
gh pr create --fill
gh pr merge <pr> --squash    # manual merge: integrate sealer refuses (gated path)

gh issue create --title "factory: budget test" \
  --body "Add scripts/budget.sh that echoes hi." \
  --label "stage:queued,priority:p2"
```

Tick twice. Expected on the second tick:

- `scripts/factory/budget-check.sh` exits 2 with
  `cap=perWorkItem.maxToolCalls:<used>/1`.
- The foreman calls `escalate.sh --reason budget`.
- The issue moves to `stage:escalated + needs-human` with a
  structured comment.

#### 4. Escalation script (direct invocation)

```bash
ID=$(gh issue list --state open --limit 1 --json number --jq '.[0].number')
scripts/factory/escalate.sh --workitem "$ID" --reason corrupt-state \
  --detail "manual smoke test of escalate.sh" --from "stage:intake"
gh issue view "$ID"
```

Expected: previous `stage:*` removed, `stage:escalated + needs-human`
added, structured comment posted.

#### 5. Main-branch isolation

No factory needed:

```bash
git switch main
git commit --allow-empty -m "test"
```

Expected: hook exits 2 with
`blocked by pre-tool-bash hook: refusing main-mutating command on main`.

The escape hatch (set when you launch your shell, not inline at the
command):

```bash
export FACTORY_ALLOW_MAIN_EDIT=1
git commit --allow-empty -m "test"   # allowed
unset FACTORY_ALLOW_MAIN_EDIT
```

---

## Teardown

For a throwaway repo, one command:

```bash
gh repo delete <owner>/<name> --yes && rm -rf <local-clone>
```

For tests run on the canonical repo, close any noisy issues / PRs and
let the next tick re-converge state.

## What "passing" means

A reasonable smoke pass:

- Tier 1 clean.
- `doctor.sh` clean against your repo.
- Tier 3 smoke lands as a merged PR within budget.

The other Tier 3 rows are worth running once when you set up a fresh
factory, then again only when something here changes (e.g. a new gate
pattern, a new escalation reason).
