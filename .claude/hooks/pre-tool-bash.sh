#!/usr/bin/env bash
# PreToolUse hook for Bash.
#
# Last line of defence above the settings.json deny list. Blocks:
#
#   1. Destructive shell operations (force pushes, hard resets, rm -rf,
#      branch deletes, gh auth login/logout).
#   2. Direct edits to `main`: any `git commit` / `git add` while HEAD
#      is on `main` or `master`. Implement work belongs on
#      `claude/<slug>` branches; this catches the case where the agent
#      forgot to switch.
#   3. Direct pushes to non-`claude/*` branches on origin.
#
# Phase 2: items 2 and 3 are the worktree-isolation rule from
# docs/roadmap.md ("no agent edits main"). Items 1's pattern set
# mirrors policy.yml's `allowlist.deny`.
#
# Hook protocol: read JSON event from stdin, exit 0 to allow, exit 2 to
# block. stderr surfaces to the model and user.
#
# Escape hatches (set in env, intentionally undocumented elsewhere so
# they require an operator to know they exist):
#   FACTORY_AUTH_DESTRUCTIVE=1 — bypass item 1 for one shell.
#   FACTORY_ALLOW_MAIN_EDIT=1  — bypass item 2.
#
# Both are flags for human operators recovering a broken state. The
# orchestrator skill does not set them.

set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)
[[ -z "$cmd" ]] && exit 0

block() {
  printf 'blocked by pre-tool-bash hook: %s\n' "$1" >&2
  exit 2
}

# ---- 1. destructive ops --------------------------------------------------
if [[ "${FACTORY_AUTH_DESTRUCTIVE:-0}" != "1" ]]; then
  case "$cmd" in
    *"git push --force"*|*"git push -f"*)        block "force push" ;;
    *"git push origin main"*|*"git push origin master"*) block "direct push to main/master" ;;
    *"git push origin HEAD:main"*|*"git push origin HEAD:master"*) block "direct push to main/master via HEAD ref" ;;
    *"git reset --hard"*)                         block "hard reset" ;;
    *"git clean -fd"*)                            block "git clean -fd" ;;
    *"git branch -D"*)                            block "force branch delete" ;;
    *"git push --delete"*|*"git push -d "*)       block "remote branch delete" ;;
    *"rm -rf"*)                                   block "rm -rf" ;;
    *"gh auth login"*)                            block "would overwrite operator credentials" ;;
    *"gh auth logout"*)                           block "would clear operator credentials" ;;
    *"gh repo delete"*)                           block "repo delete" ;;
    *"gh pr merge"*)                              block "merging is the integrate workflow's job, not the agent's" ;;
  esac
fi

# ---- 2. worktree isolation: no edits while on main -----------------------
#
# Trigger only on commands that write history. We approximate "on main"
# by reading HEAD synchronously; the cost (~1ms) is cheap relative to
# the safety win.
case "$cmd" in
  *"git commit"*|*"git add"*|*"git rebase"*|*"git merge"*|*"git cherry-pick"*|*"git apply"*)
    if [[ "${FACTORY_ALLOW_MAIN_EDIT:-0}" != "1" ]]; then
      head_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      case "$head_branch" in
        main|master)
          block "refusing $head_branch-mutating command on $head_branch (open a claude/<slug> branch first)" ;;
      esac
    fi
    ;;
esac

# ---- 3. push only to claude/* on origin ---------------------------------
#
# `git push origin <ref>` where <ref> is anything other than a
# claude/* head, factory/state, factory/ledger, or a tag. We let plain
# `git push -u origin claude/foo`, `git push origin HEAD:refs/heads/claude/foo`,
# and `git push origin factory/ledger` through.
case "$cmd" in
  *"git push origin "*)
    target=$(printf '%s' "$cmd" \
      | sed -E 's/.*git push (-[^ ]+ +)*origin +([^ ]+).*/\2/' \
      | sed -E 's/.*://')   # strip "HEAD:" / "<src>:" prefix
    case "$target" in
      claude/*|factory/state|factory/ledger|refs/tags/*|"") ;;
      *) block "push target '$target' is not on the claude/* allowlist (only claude/*, factory/state, factory/ledger, tags allowed)" ;;
    esac
    ;;
esac

exit 0
