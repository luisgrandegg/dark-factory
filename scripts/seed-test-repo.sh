#!/usr/bin/env bash
# scripts/seed-test-repo.sh — bootstrap a throwaway repo for testing the
# factory.
#
# Creates a new GitHub repo, pushes this dark-factory checkout's
# *working tree* (no commit history) as a single "seed" commit on main,
# clones the new repo locally, and runs scripts/setup.sh inside it.
# After this script returns you have a clean factory ready for
# /factory-tick.
#
# Usage:
#   scripts/seed-test-repo.sh                       # default: private, $USER/dark-factory-test
#   scripts/seed-test-repo.sh --name my-test
#   scripts/seed-test-repo.sh --org acme --name df
#   scripts/seed-test-repo.sh --public              # for share/demo, not for fake-secret tests
#   scripts/seed-test-repo.sh --workdir /tmp/factories
#   scripts/seed-test-repo.sh --no-clone            # just create + push, skip the local clone
#
# Teardown:
#   gh repo delete <owner>/<name> --yes && rm -rf <workdir>/<name>
#
# Dependencies: gh (authed), git, tar.

set -euo pipefail

name="dark-factory-test"
org=""
visibility="--private"
workdir=""
skip_clone=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     name="$2"; shift 2 ;;
    --org)      org="$2"; shift 2 ;;
    --public)   visibility="--public"; shift ;;
    --private)  visibility="--private"; shift ;;
    --workdir)  workdir="$2"; shift 2 ;;
    --no-clone) skip_clone=1; shift ;;
    -h|--help)  sed -n '2,21p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 1 ;;
  esac
done

ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v gh  >/dev/null 2>&1 || die "gh CLI not installed"
command -v git >/dev/null 2>&1 || die "git not installed"
command -v tar >/dev/null 2>&1 || die "tar not installed"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

repo_root="$(git rev-parse --show-toplevel)"
[[ -f "$repo_root/.factory/policy.yml" ]] \
  || die "run this from inside a dark-factory checkout (.factory/policy.yml missing)"

owner="${org:-$(gh api user --jq .login)}"
slug="$owner/$name"

if gh repo view "$slug" >/dev/null 2>&1; then
  die "repo $slug already exists. Delete it (gh repo delete $slug --yes) or pass --name."
fi

ok "creating $slug ($visibility)"
gh repo create "$slug" "$visibility" >/dev/null

# ---- 1. seed the new repo with one commit ------------------------------
#
# We don't want the dark-factory commit history in the test repo (it
# would clutter the factory's own ledger of what *its* runs did). Stage
# HEAD's tree in a temp dir, init a fresh repo there, commit once,
# push.

seed=$(mktemp -d -t df-seed-XXXX)
cleanup() { rm -rf "$seed"; }
trap cleanup EXIT

git -C "$repo_root" archive HEAD | tar -x -C "$seed"
ok "staged HEAD's tree at $seed"

(
  cd "$seed"
  git init -q -b main
  git add -A
  # Author the seed deterministically; falls back to gh user identity.
  email=$(git config --global user.email 2>/dev/null || true)
  uname=$(git config --global user.name  2>/dev/null || true)
  email="${email:-$(gh api user --jq .email 2>/dev/null || echo factory@example.com)}"
  uname="${uname:-$(gh api user --jq .login 2>/dev/null || echo dark-factory)}"
  src_sha=$(git -C "$repo_root" rev-parse --short HEAD 2>/dev/null || echo "?")
  git -c "user.email=$email" -c "user.name=$uname" \
      commit -q -m "seed: dark-factory template @ $src_sha"
  git remote add origin "https://github.com/$slug.git"
  git push -q -u origin main
)
ok "pushed seed commit to $slug:main"

# ---- 2. clone locally and run setup.sh ---------------------------------

if (( skip_clone )); then
  ok "skipping local clone (--no-clone). Run setup.sh manually after cloning."
  cat <<EOF

Next:
  gh repo clone $slug
  cd $name
  scripts/setup.sh

Teardown:
  gh repo delete $slug --yes
EOF
  exit 0
fi

dest="${workdir:+$workdir/}$name"
if [[ -e "$dest" ]]; then
  warn "$dest already exists; skipping clone. Run setup.sh inside it manually."
  exit 0
fi
[[ -n "$workdir" ]] && mkdir -p "$workdir"

gh repo clone "$slug" "$dest" >/dev/null
ok "cloned to $dest"

(
  cd "$dest"
  bash scripts/setup.sh
)
ok "setup.sh complete"

cat <<EOF

Ready. Next:

  cd $dest
  claude                    # open Claude Code in the new repo
  # at the prompt:
  /factory-tick

Negative tests (run after the smoke test lands):
  - gated path:        file an issue that asks for an infra/** change
  - secret scan:       push an "AKIA..." string into a factory PR's branch
  - budget kill-switch: lower budgets.perWorkItem.maxToolCalls in policy.yml
  - escalation:        scripts/factory/escalate.sh --workitem <id> --reason corrupt-state
  - main isolation:    git switch main && git commit --allow-empty -m test

Teardown when done:
  gh repo delete $slug --yes && rm -rf $dest
EOF
