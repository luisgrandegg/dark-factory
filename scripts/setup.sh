#!/usr/bin/env bash
# scripts/setup.sh — one-shot bootstrap after cloning a dark-factory repo.
#
# Idempotent. Safe to re-run. Phase 1 minimum:
#   1. verify gh is installed and authenticated
#   2. create the labels listed in .factory/policy.yml
#   3. create the state and ledger orphan branches if missing
#   4. file the smoke-test issue if it doesn't already exist
#
# Phase 2 will add the factory-deploy GitHub Environment wiring and
# `.env.local` loading (see ADR 0004).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
POLICY=".factory/policy.yml"

ok()    { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m!\033[0m %s\n' "$*"; }
err()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; }
die()   { err "$*"; exit 1; }

[[ -f "$POLICY" ]] || die "$POLICY missing — are you in a dark-factory repo?"

# ---------- 1. credentials ------------------------------------------------

command -v gh >/dev/null 2>&1 || die "gh CLI not installed (https://cli.github.com)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"
ok "gh authenticated"

REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner)
ok "repo: $REPO_SLUG"

# ---------- 2. labels -----------------------------------------------------

ensure_label() {
  local name="$1" color="$2" desc="$3"
  if gh label list --limit 200 --json name -q '.[].name' | grep -Fxq "$name"; then
    gh label edit "$name" --color "$color" --description "$desc" >/dev/null
  else
    gh label create "$name" --color "$color" --description "$desc" >/dev/null
  fi
  ok "label $name"
}

# Parse the labels block out of policy.yml. A real yq is preferred; if
# absent we fall back to a tiny awk parser that handles only this exact
# shape.
parse_labels() {
  if command -v yq >/dev/null 2>&1; then
    yq -r '
      .labels | to_entries[] | .value[] |
      [.name, .color, .description] | @tsv
    ' "$POLICY"
  else
    awk '
      /^labels:/ { in_labels=1; next }
      in_labels && /^[a-z]/ { in_labels=0 }   # next top-level key
      in_labels && /name:/  {
        n=$0; sub(/.*name:[[:space:]]*"?/,"",n); sub(/".*/,"",n); sub(/,.*/,"",n);
        match($0, /color:[[:space:]]*"?[a-f0-9]+/); c=substr($0,RSTART+7,RLENGTH-7); gsub(/"/,"",c)
        match($0, /description:[[:space:]]*"[^"]*/); d=substr($0,RSTART+13,RLENGTH-13); gsub(/^"/,"",d)
        printf "%s\t%s\t%s\n", n, c, d
      }
    ' "$POLICY"
  fi
}

while IFS=$'\t' read -r name color desc; do
  [[ -z "$name" ]] && continue
  ensure_label "$name" "$color" "$desc"
done < <(parse_labels)

# ---------- 3. orphan branches -------------------------------------------

state_branch=$(awk '/^state:/{f=1;next} f && /branch:/{print $2; exit}' "$POLICY")
ledger_branch=$(awk '/^ledger:/{f=1;next} f && /branch:/{print $2; exit}' "$POLICY")
state_branch="${state_branch:-factory/state}"
ledger_branch="${ledger_branch:-factory/ledger}"

ensure_orphan() {
  local branch="$1" readme_body="$2"
  if gh api "repos/$REPO_SLUG/branches/$branch" >/dev/null 2>&1; then
    ok "branch $branch already exists"
    return 0
  fi
  warn "creating orphan branch $branch"

  # Use the Contents API to create the branch's first file. The API
  # rejects creating files on a non-existent branch, so we first need a
  # commit. Approach: create a tree with a README, a commit pointing at
  # that tree (no parent), then a ref at refs/heads/<branch>.
  local tree_sha commit_sha blob_sha
  blob_sha=$(gh api -X POST "repos/$REPO_SLUG/git/blobs" \
    -f content="$readme_body" -f encoding="utf-8" --jq .sha)

  # Tree with README.md.
  tree_sha=$(gh api -X POST "repos/$REPO_SLUG/git/trees" \
    -f tree[0][path]="README.md" \
    -f tree[0][mode]="100644" \
    -f tree[0][type]="blob" \
    -f tree[0][sha]="$blob_sha" --jq .sha)

  # Commit with no parents.
  commit_sha=$(gh api -X POST "repos/$REPO_SLUG/git/commits" \
    -f message="factory: initialise $branch" \
    -f tree="$tree_sha" --jq .sha)

  # Create the ref.
  gh api -X POST "repos/$REPO_SLUG/git/refs" \
    -f ref="refs/heads/$branch" \
    -f sha="$commit_sha" >/dev/null

  ok "branch $branch created"
}

ensure_orphan "$state_branch" "# factory/state

Mutable derived state for the dark factory.

This branch holds:
- \`lock.json\` — the multi-session lock (ADR 0003)
- \`budget.json\` — rolling daily usage roll-up (ADR 0004)
- dashboard snapshots, when generated

Files here are *rewritten* on every tick. Do not depend on this
branch's history; periodic squash/force-push is expected.

See ADR 0002 for the rationale behind keeping this on its own branch.
"

ensure_orphan "$ledger_branch" "# factory/ledger

Append-only run history for the dark factory.

Layout:
- \`runs/YYYY/MM/DD/<ulid>.json\` — one Run per file, written once
- \`runs/by-workitem/<id>.jsonl\` — append-only index per WorkItem

Schema in \`.factory/ledger-schema.md\` on \`main\`. Files here are
immutable; compaction takes the form of new archive branches, never
edits in place.

See ADR 0002.
"

# ---------- 4. smoke-test issue ------------------------------------------

smoke_title="factory: smoke test (hello-world script)"
existing=$(gh issue list --search "$smoke_title in:title label:factory:smoke" \
            --state all --limit 1 --json number -q '.[0].number')
if [[ -n "$existing" ]]; then
  ok "smoke-test issue already exists: #$existing"
else
  # shellcheck disable=SC2016  # backticks here are markdown, not shell.
  body='This is the **smoke test** issue filed automatically by `setup.sh`.

The factory should consume this end-to-end on the first `/factory-tick`:

- intake → spec → plan → implement → qa → integrate → done

**Acceptance**

Add a `scripts/hello.sh` that prints `hello, dark factory` and exits 0.
That is the entire deliverable. Anything more (refactors, docs, extra
scripts) must be flagged out-of-scope.

If this issue lands as a merged PR within budget, Phase 1 is working.'
  num=$(gh issue create --title "$smoke_title" --body "$body" \
        --label "stage:queued,priority:p2,factory:smoke" \
        --json number -q .number)
  ok "smoke-test issue filed: #$num"
fi

# ---------- 5. summary ----------------------------------------------------

cat <<EOF

Setup complete. Next:

  1. Open Claude Code in this repo (CLI: \`claude\`, or via the web).
  2. Run \`/factory-tick\` to advance the smoke-test issue.
  3. Watch it land as a merged PR.

Branches:
  - main           : product code, policy, agents
  - $state_branch  : lock.json, budget.json (mutable, expect churn)
  - $ledger_branch : append-only Run history

Operator docs:
  - .factory/policy.yml          — budgets, allowlist, gates
  - .factory/ledger-schema.md    — Run record schema
  - docs/architecture.md         — components and workflows
  - docs/adrs/                   — decisions and rationale
EOF
