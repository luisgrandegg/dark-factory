#!/usr/bin/env bash
# Scaffold an empty migration file in the canonical location for the
# requested toolchain. Writes ONE file with the toolchain's required
# boilerplate plus a `# TODO: human writes the migration body`
# placeholder. Prints the new file's relative path on stdout.
#
# Usage:
#   scripts/skills/migration-scaffold.sh \
#     --toolchain alembic|django|rails|knex|raw-sql \
#     --migration-name <slug> \
#     [--app <app>]              # required for django
#     [--root <path>]            # default .
#     [--rev <hex>]              # alembic only; defaults to a random 12-hex
#     [--now <YYYYMMDDHHMMSS>]   # rails/knex/raw-sql only; defaults to UTC now
#
# --rev and --now exist for deterministic tests.
#
# Exit codes:
#   0  scaffold written; path printed on stdout
#   2  bad invocation, unknown toolchain, missing app for django,
#      filename collision, or output would land in an approval-gate
#      path other than the canonical migrations directory.

set -uo pipefail

toolchain=""
name=""
app=""
root="."
rev=""
now=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --toolchain)      toolchain="$2"; shift 2 ;;
    --migration-name) name="$2"; shift 2 ;;
    --app)            app="$2"; shift 2 ;;
    --root)           root="$2"; shift 2 ;;
    --rev)            rev="$2"; shift 2 ;;
    --now)            now="$2"; shift 2 ;;
    -h|--help)        sed -n '2,24p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -d "$root" ]] || { echo "no such root: $root" >&2; exit 2; }
[[ -n "$toolchain" ]] || { echo "missing --toolchain" >&2; exit 2; }
[[ -n "$name" ]] || { echo "missing --migration-name" >&2; exit 2; }

# Validate name
if ! [[ "$name" =~ ^[a-z][a-z0-9_]{0,59}$ ]]; then
  echo "invalid --migration-name: must match ^[a-z][a-z0-9_]{0,59}$" >&2
  exit 2
fi

# Defaults
if [[ -z "$now" ]]; then
  now=$(date -u +%Y%m%d%H%M%S)
fi
if [[ -z "$rev" ]]; then
  rev=$(python3 -c 'import secrets; print(secrets.token_hex(6))')
fi

write_file() {
  local path="$1" body="$2"
  if [[ -e "$root/$path" ]]; then
    echo "filename collision: $path already exists" >&2
    exit 2
  fi
  mkdir -p "$root/$(dirname "$path")"
  printf '%s' "$body" > "$root/$path"
  printf '%s\n' "$path"
}

case "$toolchain" in
  alembic)
    path="migrations/versions/${rev}_${name}.py"
    body=$(cat <<PY
"""${name}

Revision ID: ${rev}
Revises:
Create Date: $(date -u +%Y-%m-%d) (scaffolded)

"""
from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision = "${rev}"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # TODO: human writes the migration body
    pass


def downgrade() -> None:
    # TODO: human writes the migration body
    pass
PY
)
    write_file "$path" "$body"
    ;;

  django)
    [[ -n "$app" ]] || { echo "django toolchain requires --app" >&2; exit 2; }
    [[ -d "$root/$app/migrations" ]] || { echo "no such app: $app/migrations" >&2; exit 2; }
    # Compute next sequence: max existing NNNN + 1, default 0001.
    next=$(python3 - "$root/$app/migrations" <<'PY'
import os, re, sys
d = sys.argv[1]
n = 0
for f in os.listdir(d):
    m = re.match(r"^(\d{4})_", f)
    if m:
        n = max(n, int(m.group(1)))
print(f"{n+1:04d}")
PY
)
    path="${app}/migrations/${next}_${name}.py"
    body=$(cat <<PY
from django.db import migrations, models


class Migration(migrations.Migration):

    dependencies = [
        # TODO: add the previous migration here, e.g. ("${app}", "0001_initial")
    ]

    operations = [
        # TODO: human writes the migration body
    ]
PY
)
    write_file "$path" "$body"
    ;;

  rails)
    # Convert snake_case to CamelCase for the class name.
    class_name=$(python3 -c 'import sys; print("".join(w.capitalize() for w in sys.argv[1].split("_")))' "$name")
    path="db/migrate/${now}_${name}.rb"
    body=$(cat <<RB
class ${class_name} < ActiveRecord::Migration[7.0]
  def change
    # TODO: human writes the migration body
  end
end
RB
)
    write_file "$path" "$body"
    ;;

  knex)
    path="migrations/${now}_${name}.js"
    body=$(cat <<'JS'
/** @param { import("knex").Knex } knex */
exports.up = async function (knex) {
  // TODO: human writes the migration body
};

/** @param { import("knex").Knex } knex */
exports.down = async function (knex) {
  // TODO: human writes the migration body
};
JS
)
    write_file "$path" "$body"
    ;;

  raw-sql)
    path="migrations/${now}_${name}.sql"
    body=$(cat <<'SQL'
-- Up
-- TODO: human writes the migration body

-- Down
-- TODO: human writes the migration body
SQL
)
    write_file "$path" "$body"
    ;;

  *)
    echo "unknown toolchain: $toolchain" >&2
    exit 2 ;;
esac
