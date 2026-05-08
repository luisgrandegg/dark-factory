#!/usr/bin/env bash
# shellcheck disable=SC2317  # tests + cleanup are dispatched via "$fn" / trap
# scripts/test/tier3.sh — run the Phase 2 guardrail integration tests
# against the current repo, report pass/fail per test, clean up.
#
# Designed to run in a throwaway repo created by
# `scripts/seed-test-repo.sh`. It refuses to run on a repo whose name
# doesn't contain "test", "throwaway", or "sandbox" unless you set
# `TIER3_FORCE=1`. It also refuses when the repo is public (the
# secret-scan test commits a fake AKIA-format key on a temp branch).
#
# Tests:
#   hook          — pre-tool-bash hook against canned bad inputs (local)
#   escalate      — scripts/factory/escalate.sh on a test issue
#   budget        — budget-check.sh against a synthetic ledger entry
#   gated-path    — opens an infra/** PR, labels stage:integrate,
#                   asserts integrate.yml refuses to merge
#   secret-scan   — opens a PR with a constructed fake key, asserts
#                   the Secret scan workflow fails
#   smoke         — operator-driven; prints instructions and verifies
#                   after you confirm the smoke-test issue is merged
#
# Usage:
#   scripts/test/tier3.sh                # all auto tests; skips smoke
#   scripts/test/tier3.sh --with-smoke   # also run the operator smoke test
#   scripts/test/tier3.sh --filter hook  # only run tests whose id matches
#   scripts/test/tier3.sh --no-cleanup   # leave artefacts for inspection
#   scripts/test/tier3.sh --help
#
# Exit code: 0 if everything that ran passed, 1 otherwise.

set -uo pipefail

# ---- args --------------------------------------------------------------
filter=""
with_smoke=0
no_cleanup=0
yes=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-smoke)  with_smoke=1; shift ;;
    --no-cleanup)  no_cleanup=1; shift ;;
    --filter)      filter="$2"; shift 2 ;;
    --yes|-y)      yes=1; shift ;;
    -h|--help)     sed -n '3,31p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# ---- preflight ---------------------------------------------------------
ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
fail()  { printf '\033[31m✗\033[0m %s\n' "$*"; }
die()   { fail "$*"; exit 1; }
hr()    { printf -- '----------------------------------------\n'; }

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || die "not inside a git repo"
cd "$repo_root" || die "could not cd to $repo_root"
[[ -f .factory/policy.yml ]] || die "this isn't a dark-factory checkout"

# shellcheck source=../factory/lib.sh
. scripts/factory/lib.sh

command -v gh  >/dev/null 2>&1 || die "gh not installed"
gh auth status >/dev/null 2>&1 || die "gh not authenticated"

slug=$(repo_slug) || die "could not determine repo slug"
name=${slug##*/}
visibility=$(gh repo view --json visibility --jq '.visibility' 2>/dev/null)

# Safety: only run on a repo that looks like a throwaway. The secret-scan
# test commits an AKIA-pattern key on a temp branch.
if [[ "${TIER3_FORCE:-0}" != "1" ]]; then
  case "$name" in
    *test*|*throwaway*|*sandbox*) ;;
    *) die "repo '$name' doesn't look like a test repo. Set TIER3_FORCE=1 to override." ;;
  esac
  case "$visibility" in
    PRIVATE|private) ;;
    *) die "repo '$slug' is $visibility; this script commits fake secrets on a temp branch. Set TIER3_FORCE=1 to override." ;;
  esac
fi

# Working tree must be clean — we'll be switching branches.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "working tree has uncommitted changes; commit or stash first"
fi

orig_branch=$(git rev-parse --abbrev-ref HEAD)
runid=$(date -u +%Y%m%d%H%M%S)-$$

ok "repo:        $slug ($visibility)"
ok "run id:      $runid"
ok "orig branch: $orig_branch"

if (( ! yes )); then
  echo
  echo "About to run Tier 3 guardrail tests against $slug."
  echo "Tests create temp issues, branches, and PRs, then clean up."
  read -r -p "proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy] ]] || { echo "aborted"; exit 1; }
fi

# ---- artefact tracking & cleanup --------------------------------------
ISSUES=()
PRS=()
BRANCHES=()
LEDGER_FILES=()

# shellcheck disable=SC2317  # invoked via `trap cleanup EXIT`
cleanup() {
  local rc=$?
  echo
  hr
  if (( no_cleanup )); then
    warn "skipping cleanup (--no-cleanup)"
    echo "  issues:  ${ISSUES[*]:-(none)}"
    echo "  prs:     ${PRS[*]:-(none)}"
    echo "  branches: ${BRANCHES[*]:-(none)}"
    echo "  ledger:  ${LEDGER_FILES[*]:-(none)}"
    return "$rc"
  fi
  echo "cleaning up…"
  for n in "${ISSUES[@]}"; do
    if gh issue close "$n" --comment "tier3 cleanup ($runid)" >/dev/null 2>&1; then
      ok "closed issue #$n"
    else
      warn "could not close issue #$n"
    fi
  done
  for n in "${PRS[@]}"; do
    if gh pr close "$n" --delete-branch >/dev/null 2>&1; then
      ok "closed PR #$n"
    else
      warn "could not close PR #$n"
    fi
  done
  for b in "${BRANCHES[@]}"; do
    git push origin ":$b" >/dev/null 2>&1 || true   # may already be gone via PR close
    git branch -D "$b" >/dev/null 2>&1 || true
  done
  for f in "${LEDGER_FILES[@]}"; do
    if delete_ledger_file "$f"; then
      ok "deleted ledger file $f"
    else
      warn "could not delete ledger file $f"
    fi
  done
  git switch "$orig_branch" >/dev/null 2>&1 || true
  return "$rc"
}
trap cleanup EXIT

delete_ledger_file() {
  local path="$1"
  local lb; lb=$(policy_ledger_branch); lb=${lb:-factory/ledger}
  local doc; doc=$(contents_get "$slug" "$lb" "$path" || true)
  [[ -z "$doc" ]] && return 0
  local sha; sha=$(printf '%s' "$doc" \
    | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("sha",""))')
  [[ -z "$sha" ]] && return 0
  contents_delete "$slug" "$lb" "$path" "tier3 cleanup ($runid)" "$sha" >/dev/null 2>&1
}

# ---- result tracking ---------------------------------------------------
declare -A RESULTS
ORDER=()

run_test() {
  local id="$1" name="$2" fn="$3"
  ORDER+=("$id")
  if [[ -n "$filter" && "$id" != *"$filter"* ]]; then
    RESULTS[$id]="SKIP (filter)"
    return
  fi
  echo
  hr
  printf '[%s] %s\n' "$id" "$name"
  hr
  local rc=0
  "$fn" || rc=$?
  case "$rc" in
    0) RESULTS[$id]="PASS"; ok "PASS: $id" ;;
    2) RESULTS[$id]="SKIP" ; warn "SKIP: $id" ;;
    *) RESULTS[$id]="FAIL"; fail "FAIL: $id" ;;
  esac
}

# ---- helpers -----------------------------------------------------------
issue_create() {
  local title="$1" body="$2" labels="$3"
  local out
  out=$(gh issue create --title "$title" --body "$body" --label "$labels") \
    || { echo "$out" >&2; return 1; }
  printf '%s' "${out##*/}"
}
pr_create() {
  local title="$1" body="$2" head="$3"
  local out
  out=$(gh pr create --title "$title" --body "$body" --base main --head "$head") \
    || { echo "$out" >&2; return 1; }
  printf '%s' "${out##*/}"
}

# ---- t_hook ------------------------------------------------------------
t_hook() {
  local h=.claude/hooks/pre-tool-bash.sh
  [[ -x "$h" ]] || { fail "$h not executable"; return 1; }
  local fails=0
  expect() { # cmd_json want_exit description
    local got
    printf '%s' "$1" | "$h" >/dev/null 2>&1; got=$?
    if [[ "$got" == "$2" ]]; then ok "  $3"
    else fail "  $3 (want exit $2, got $got)"; fails=$((fails + 1))
    fi
  }
  expect '{"command":"git reset --hard HEAD"}'              2 "blocks hard reset"
  expect '{"command":"git push origin main"}'               2 "blocks push to main"
  expect '{"command":"git push origin random-branch"}'      2 "blocks non-allowlist push"
  expect '{"command":"gh pr merge 1 --auto"}'               2 "blocks gh pr merge"
  expect '{"command":"ls -la"}'                             0 "allows ls"
  expect '{"command":"git push -u origin claude/foo-1"}'    0 "allows claude/* push"
  return "$fails"
}

# ---- t_escalate --------------------------------------------------------
t_escalate() {
  local n
  n=$(issue_create "tier3 escalate ($runid)" \
                   "tier3 automated test; safe to close" \
                   "stage:queued,priority:p3") || return 1
  ISSUES+=("$n")
  ok "  issue #$n created"
  gh issue edit "$n" --remove-label "stage:queued" --add-label "stage:intake" >/dev/null \
    || { fail "  could not move issue to stage:intake"; return 1; }

  scripts/factory/escalate.sh --workitem "$n" --reason corrupt-state \
    --detail "tier3 automated test ($runid)" --from "stage:intake" >/dev/null \
    || { fail "  escalate.sh exited non-zero"; return 1; }

  local labels
  labels=$(gh issue view "$n" --json labels --jq '[.labels[].name] | sort | join(",")')
  case ",$labels," in *,stage:escalated,*) ok "  stage:escalated set" ;; *) fail "  stage:escalated missing ($labels)"; return 1 ;; esac
  case ",$labels," in *,needs-human,*)     ok "  needs-human set" ;;     *) fail "  needs-human missing ($labels)"; return 1 ;; esac
  case ",$labels," in *,stage:intake,*)    fail "  stage:intake still present"; return 1 ;; esac

  local last
  last=$(gh issue view "$n" --json comments --jq '.comments[-1].body')
  case "$last" in *"**Escalated"*) ok "  escalation comment posted" ;; *) fail "  no escalation comment found"; return 1 ;; esac
}

# ---- t_budget ----------------------------------------------------------
t_budget() {
  local wid=999999999
  local lb; lb=$(policy_ledger_branch); lb=${lb:-factory/ledger}
  local fake_run="01TIER3${runid//[!0-9A-Z]/}"
  fake_run=${fake_run:0:26}
  local today; today=$(date -u +"%Y/%m/%d")
  local run_path="runs/$today/$fake_run.json"
  local idx_path="runs/by-workitem/$wid.jsonl"

  local cap
  if command -v yq >/dev/null 2>&1; then
    cap=$(yq -r '.budgets.perWorkItem.maxToolCalls' .factory/policy.yml)
  else
    cap=$(awk '/perWorkItem:/{f=1;next} f && /maxToolCalls:/{print $2; exit}' .factory/policy.yml)
  fi
  cap=${cap:-400}
  local synth=$(( cap + 1 ))

  local run_doc='{"id":"'"$fake_run"'","workItemId":'"$wid"',"station":"implement","usage":{"toolCalls":'"$synth"',"wallSeconds":0}}'
  local run_b64; run_b64=$(printf '%s' "$run_doc" | b64)
  if ! contents_put "$slug" "$lb" "$run_path" "tier3: synth run ($runid)" "$run_b64" "" >/dev/null 2>&1; then
    fail "  could not write synth run blob"; return 1
  fi
  LEDGER_FILES+=("$run_path")

  local idx_doc='{"id":"'"$fake_run"'","station":"implement","status":"failure","endedAt":"now","pr":null}'
  local idx_b64; idx_b64=$(printf '%s\n' "$idx_doc" | b64)
  if ! contents_put "$slug" "$lb" "$idx_path" "tier3: synth index ($runid)" "$idx_b64" "" >/dev/null 2>&1; then
    fail "  could not write synth index"; return 1
  fi
  LEDGER_FILES+=("$idx_path")
  ok "  synthesised ledger entry for workitem $wid (toolCalls=$synth, cap=$cap)"

  local out rc
  out=$(scripts/factory/budget-check.sh --workitem "$wid" 2>&1); rc=$?
  if (( rc != 2 )); then
    fail "  budget-check.sh exit $rc (want 2)"; printf '%s\n' "$out"; return 1
  fi
  if ! grep -q '^cap=perWorkItem.maxToolCalls:' <<<"$out"; then
    fail "  budget-check.sh did not report perWorkItem.maxToolCalls"; printf '%s\n' "$out"; return 1
  fi
  ok "  exit=2, cap reported: $(grep '^cap=' <<<"$out")"
}

# ---- t_gated_path ------------------------------------------------------
t_gated_path() {
  local branch="claude/tier3-gated-$runid"
  git switch -q -c "$branch" || return 1
  BRANCHES+=("$branch")
  mkdir -p infra
  printf '# tier3 gated-path test (%s)\n' "$runid" > "infra/tier3-$runid.tf"
  git add "infra/tier3-$runid.tf"
  git -c user.email=tier3@example.com -c user.name=tier3 \
      commit -q -m "tier3: gated-path test ($runid)"
  if ! git push -q -u origin "$branch" >/dev/null 2>&1; then
    fail "  could not push $branch"; return 1
  fi

  local pr_n
  pr_n=$(pr_create "tier3 gated-path ($runid)" \
                   "tier3 automated test; safe to close" "$branch") || return 1
  PRS+=("$pr_n")
  ok "  PR #$pr_n opened from $branch"

  gh pr ready "$pr_n" >/dev/null 2>&1 || true
  gh pr edit "$pr_n" --add-label "stage:integrate" >/dev/null \
    || { fail "  could not label stage:integrate"; return 1; }
  ok "  labelled stage:integrate; waiting for integrate.yml…"

  local deadline=$(( $(date +%s) + 120 ))
  while (( $(date +%s) < deadline )); do
    local labels state
    labels=$(gh pr view "$pr_n" --json labels --jq '[.labels[].name] | join(",")')
    state=$(gh pr view "$pr_n" --json state --jq .state)
    if [[ ",$labels," == *",needs-human,"* ]]; then
      ok "  needs-human label set by integrate.yml"
      return 0
    fi
    if [[ "$state" == "MERGED" ]]; then
      fail "  PR was merged despite gated path"; return 1
    fi
    printf '.'
    sleep 8
  done
  echo
  fail "  timed out waiting for integrate.yml to react"
  return 1
}

# ---- t_secret_scan -----------------------------------------------------
t_secret_scan() {
  local branch="claude/tier3-secret-$runid"
  git switch -q -c "$branch" || return 1
  BRANCHES+=("$branch")
  # Construct a fake AWS key at write-time so this script's source
  # doesn't itself contain an AKIA[16] literal that would trip scanners
  # of *its* PR.
  local k1=AKIA k2=IOSFODNN7EXAMPLE
  local leak="scripts/tier3-leak-$runid.sh"
  printf 'AWS_KEY="%s%s"\n' "$k1" "$k2" > "$leak"
  git add "$leak"
  git -c user.email=tier3@example.com -c user.name=tier3 \
      commit -q -m "tier3: secret-scan test ($runid)"
  if ! git push -q -u origin "$branch" >/dev/null 2>&1; then
    fail "  could not push $branch"; return 1
  fi

  local pr_n
  pr_n=$(pr_create "tier3 secret-scan ($runid)" \
                   "tier3 automated test; safe to close" "$branch") || return 1
  PRS+=("$pr_n")
  ok "  PR #$pr_n opened; waiting for Secret scan…"

  local deadline=$(( $(date +%s) + 240 ))
  while (( $(date +%s) < deadline )); do
    local bucket
    bucket=$(gh pr checks "$pr_n" --json name,bucket 2>/dev/null \
              | python3 -c '
import sys, json
checks = json.loads(sys.stdin.read() or "[]")
for c in checks:
    if (c.get("name","") or "").startswith("Secret scan"):
        print(c.get("bucket","")); sys.exit(0)
' )
    case "$bucket" in
      fail) ok "  Secret scan = fail (as expected)"; return 0 ;;
      pass) fail "  Secret scan = pass; expected fail (gitleaks may have allowlisted the example key)"; return 1 ;;
    esac
    printf '.'
    sleep 10
  done
  echo
  fail "  timed out waiting for Secret scan"
  return 1
}

# ---- t_smoke -----------------------------------------------------------
t_smoke() {
  if (( ! with_smoke )); then return 2; fi
  echo "  Smoke needs an operator-driven /factory-tick session."
  echo "  In another terminal:"
  echo "    cd $(pwd) && claude    # then run: /factory-tick"
  echo "  Tick until the factory:smoke issue is closed and its PR is merged."
  read -r -p "  press ENTER once that's done (or Ctrl-C to skip): " _ || return 2
  local closed
  closed=$(gh issue list --label "factory:smoke" --state closed --limit 1 \
            --json number --jq '.[0].number // empty')
  if [[ -n "$closed" ]]; then
    ok "  smoke issue #$closed is closed"
    local merged
    merged=$(gh pr list --state merged --limit 5 --json number,headRefName \
              --jq '[.[] | select(.headRefName | startswith("claude/"))] | length')
    if (( merged > 0 )); then
      ok "  found $merged merged claude/* PR(s)"
      return 0
    fi
    fail "  no merged claude/* PR found"; return 1
  fi
  fail "  no closed factory:smoke issue found"; return 1
}

# ---- run ---------------------------------------------------------------
run_test hook        "PreToolUse hook (local)"           t_hook
run_test escalate    "scripts/factory/escalate.sh"       t_escalate
run_test budget      "scripts/factory/budget-check.sh"   t_budget
run_test gated-path  "approval gates via integrate.yml"  t_gated_path
run_test secret-scan "secret-scan workflow"              t_secret_scan
run_test smoke       "end-to-end smoke (operator)"       t_smoke

# ---- summary -----------------------------------------------------------
echo
hr
echo "summary"
hr
fails=0
for id in "${ORDER[@]}"; do
  v="${RESULTS[$id]:-?}"
  printf '  %-12s  %s\n' "$id" "$v"
  case "$v" in FAIL*) fails=$((fails + 1)) ;; esac
done
echo
if (( fails == 0 )); then
  ok "all tests that ran passed"
else
  fail "$fails test(s) failed"
fi
exit $(( fails > 0 ? 1 : 0 ))
