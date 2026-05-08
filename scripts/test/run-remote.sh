#!/usr/bin/env bash
# scripts/test/run-remote.sh — one-shot bootstrap: clone dark-factory,
# seed a throwaway repo, run tier3.sh against it.
#
# Designed to be runnable from anywhere on the operator's machine (no
# pre-existing clone of dark-factory required) via:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/luisgrandegg/dark-factory/main/scripts/test/run-remote.sh)
#
# Trailing arguments are forwarded to tier3.sh:
#
#   bash <(curl -fsSL .../run-remote.sh) --filter hook
#   bash <(curl -fsSL .../run-remote.sh) --with-smoke
#   bash <(curl -fsSL .../run-remote.sh) --no-cleanup
#
# What it does:
#   1. clones dark-factory (shallow) to a tmp dir
#   2. runs scripts/seed-test-repo.sh to create a fresh private GitHub
#      repo named dark-factory-tier3-<UTC-timestamp>
#   3. cd's into the seeded clone and runs scripts/test/tier3.sh
#
# Leaves the throwaway repo and its local clone in place after the run
# so the operator can inspect failures. Prints the teardown command at
# the end.
#
# Requires gh authenticated and git installed.

set -euo pipefail

REPO="${DARK_FACTORY_REPO:-luisgrandegg/dark-factory}"
BRANCH="${DARK_FACTORY_BRANCH:-main}"
ts="$(date -u +%Y%m%d%H%M%S)"
test_name="dark-factory-tier3-$ts"
work="$(mktemp -d -t df-tier3-XXXXXX)"

ok()  { printf '\033[32m✓\033[0m %s\n' "$*"; }
die() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git not installed"
command -v gh  >/dev/null 2>&1 || die "gh not installed (https://cli.github.com)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"

ok "scratch dir: $work"
ok "cloning $REPO@$BRANCH"
git clone --depth=1 --branch "$BRANCH" "https://github.com/$REPO.git" \
  "$work/dark-factory" >/dev/null 2>&1 \
  || die "could not clone $REPO@$BRANCH"

cd "$work/dark-factory"
ok "seeding throwaway $test_name"
"$work/dark-factory/scripts/seed-test-repo.sh" \
  --name "$test_name" --workdir "$work"

cd "$work/$test_name"
echo
ok "running tier3.sh $*"
echo
set +e
bash scripts/test/tier3.sh --yes "$@"
rc=$?
set -e

echo
owner="$(gh api user --jq .login)"
echo "tier3 finished (exit $rc)"
echo
echo "throwaway artefacts left for inspection:"
echo "  github: https://github.com/$owner/$test_name"
echo "  local:  $work/$test_name"
echo
echo "to delete the throwaway:"
echo "  gh repo delete $owner/$test_name --yes && rm -rf $work"

exit "$rc"
