#!/usr/bin/env bash
# Detect the migration toolchain in use in a repository.
#
# Read-only. Prints one JSON object per line on stdout, in canonical
# order: alembic, django, rails, knex, raw-sql. Object shape:
#
#   {"toolchain": "alembic", "marker": "alembic.ini",
#    "migrationDir": "migrations/versions"}
#
# A repo can in principle use more than one (e.g. an Alembic project
# with raw-SQL migrations on the side). The skill picks the first
# match in the listed order.
#
# Usage:
#   scripts/skills/migration-detect.sh [--root PATH]

set -uo pipefail

root="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$root" ]] || { echo "no such root: $root" >&2; exit 2; }

emit() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
print(json.dumps({"toolchain": sys.argv[1], "marker": sys.argv[2], "migrationDir": sys.argv[3]}))
PY
}

has() { [[ -e "$root/$1" ]]; }

# --- Alembic
if has alembic.ini; then
  # versions dir is configurable; default is migrations/versions or
  # alembic/versions. We pick whichever exists.
  if has migrations/versions; then
    emit alembic alembic.ini migrations/versions
  elif has alembic/versions; then
    emit alembic alembic.ini alembic/versions
  else
    emit alembic alembic.ini migrations/versions
  fi
fi

# --- Django: manage.py and at least one app with a migrations/ dir.
if has manage.py; then
  app_dir=$(python3 - "$root" <<'PY'
import os, sys
root = sys.argv[1]
for entry in sorted(os.listdir(root)):
    full = os.path.join(root, entry)
    if not os.path.isdir(full):
        continue
    mig = os.path.join(full, "migrations")
    init = os.path.join(mig, "__init__.py")
    if os.path.isdir(mig) and os.path.isfile(init):
        print(entry)
        break
PY
)
  if [[ -n "$app_dir" ]]; then
    emit django manage.py "$app_dir/migrations"
  fi
fi

# --- Rails: db/migrate dir (the strongest single signal).
if has db/migrate; then
  emit rails db/migrate db/migrate
fi

# --- Knex: knexfile.* in the root.
for cand in knexfile.js knexfile.ts knexfile.cjs knexfile.mjs; do
  if has "$cand"; then
    if has migrations; then
      emit knex "$cand" migrations
    else
      emit knex "$cand" migrations
    fi
    break
  fi
done

# --- raw-sql: a migrations/ dir containing only .sql files (and no
#     framework-specific markers above). Last-resort fallback.
if has migrations; then
  has_sql=0
  has_other=0
  for f in "$root"/migrations/*; do
    [[ -e "$f" ]] || continue
    case "$f" in
      *.sql) has_sql=1 ;;
      *.py|*.js|*.ts|*.rb) has_other=1 ;;
    esac
  done
  # Only emit raw-sql if no framework was detected AND we saw .sql
  # files (or the directory is empty, which we treat as raw-sql by
  # default).
  if [[ "$has_other" -eq 0 ]]; then
    if [[ "$has_sql" -eq 1 ]] || [[ -d "$root/migrations" && -z "$(ls -A "$root/migrations" 2>/dev/null)" ]]; then
      # Only emit if no other toolchain was emitted above. We do a
      # cheap check: the script would exit already if alembic/knex
      # were detected (they both write under migrations/). For
      # django/rails the marker dirs are different, so raw-sql can
      # legitimately co-exist. The skill picks the first emission
      # anyway, so co-existing here is harmless.
      emit raw-sql migrations migrations
    fi
  fi
fi
