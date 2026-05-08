#!/usr/bin/env bash
# PreToolUse hook for Bash
#
# Last line of defence above the settings.json deny list: blocks a small
# set of destructive commands by string match on the command argv. The
# settings.json deny list is the primary control; this hook catches
# variants the matcher syntax misses (chained commands, env-prefixed
# invocations, etc.).
#
# Hook protocol: read JSON event from stdin, exit 0 to allow, exit 2 to
# block (stderr surfaces to the model and user).

set -uo pipefail

input=$(cat)

# Cheap extractor: pluck the command field without depending on jq.
cmd=$(printf '%s' "$input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -1)

if [[ -z "$cmd" ]]; then
  exit 0
fi

block() {
  printf 'blocked by pre-tool-bash hook: %s\n' "$1" >&2
  exit 2
}

# Pattern set mirrors policy.allowlist.deny. Regex over the whole command
# string so chained forms (`foo && git push --force`) still trip.
case "$cmd" in
  *"git push --force"*|*"git push -f"*) block "force push" ;;
  *"git push origin main"*|*"git push origin master"*) block "direct push to main/master" ;;
  *"git reset --hard"*) block "hard reset" ;;
  *"git clean -fd"*) block "git clean -fd" ;;
  *"git branch -D"*) block "force branch delete" ;;
  *"rm -rf"*) block "rm -rf" ;;
  *"gh auth login"*) block "would overwrite operator credentials" ;;
  *"gh auth logout"*) block "would clear operator credentials" ;;
esac

exit 0
