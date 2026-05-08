#!/usr/bin/env bash
# Smoke test for migration-detect.sh and migration-scaffold.sh.
#
# Builds synthetic toolchain fixture trees, runs the detector against
# each, and exercises the scaffolder for every supported toolchain.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DETECT="$REPO_ROOT/scripts/skills/migration-detect.sh"
SCAFFOLD="$REPO_ROOT/scripts/skills/migration-scaffold.sh"
[[ -x "$DETECT"   ]] || { echo "missing $DETECT";   exit 1; }
[[ -x "$SCAFFOLD" ]] || { echo "missing $SCAFFOLD"; exit 1; }

tmp=$(mktemp -d -t mig-smoke-XXXX)
trap 'rm -rf "$tmp"' EXIT

fails=0
check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$label" "$expected" "$actual"
    fails=$((fails + 1))
  fi
}

first_toolchain() {
  printf '%s\n' "$1" | head -1 | python3 -c '
import sys, json
line = sys.stdin.read().strip()
if not line:
    print("")
else:
    print(json.loads(line)["toolchain"])
'
}

# === Detector ===

# Empty
mkdir -p "$tmp/empty"
out=$("$DETECT" --root "$tmp/empty")
check "detect.empty" "$out" ""

# Alembic
mkdir -p "$tmp/alembic/migrations/versions"
echo "[alembic]" > "$tmp/alembic/alembic.ini"
out=$("$DETECT" --root "$tmp/alembic")
check "detect.alembic" "$(first_toolchain "$out")" "alembic"

# Django
mkdir -p "$tmp/django/users/migrations"
echo "" > "$tmp/django/users/migrations/__init__.py"
echo "" > "$tmp/django/manage.py"
out=$("$DETECT" --root "$tmp/django")
check "detect.django" "$(first_toolchain "$out")" "django"

# Rails
mkdir -p "$tmp/rails/db/migrate"
out=$("$DETECT" --root "$tmp/rails")
check "detect.rails" "$(first_toolchain "$out")" "rails"

# Knex
mkdir -p "$tmp/knex/migrations"
echo "module.exports = {};" > "$tmp/knex/knexfile.js"
out=$("$DETECT" --root "$tmp/knex")
check "detect.knex" "$(first_toolchain "$out")" "knex"

# raw-sql
mkdir -p "$tmp/raw-sql/migrations"
touch "$tmp/raw-sql/migrations/001_init.sql"
out=$("$DETECT" --root "$tmp/raw-sql")
check "detect.raw-sql" "$(first_toolchain "$out")" "raw-sql"

# Empty migrations dir is also raw-sql by default.
mkdir -p "$tmp/raw-empty/migrations"
out=$("$DETECT" --root "$tmp/raw-empty")
check "detect.raw-empty" "$(first_toolchain "$out")" "raw-sql"

# Migrations dir with .py files but no alembic.ini is NOT raw-sql.
mkdir -p "$tmp/strange/migrations"
touch "$tmp/strange/migrations/foo.py"
out=$("$DETECT" --root "$tmp/strange")
check "detect.strange.no-rawsql" "$out" ""

# Bad root
"$DETECT" --root /no/such 2>/dev/null
check "detect.bad-root.exit-2" "$?" "2"

# === Scaffolder ===

# Alembic
mkdir -p "$tmp/scaffold-alembic/migrations/versions"
out=$("$SCAFFOLD" --toolchain alembic --migration-name add_email_to_users \
                  --root "$tmp/scaffold-alembic" --rev abc123def456)
check "scaffold.alembic.path" "$out" "migrations/versions/abc123def456_add_email_to_users.py"
[[ -f "$tmp/scaffold-alembic/$out" ]] && echo "ok   scaffold.alembic.exists" \
  || { echo "FAIL scaffold.alembic.exists"; fails=$((fails+1)); }
grep -q 'revision = "abc123def456"' "$tmp/scaffold-alembic/$out" \
  && echo "ok   scaffold.alembic.revision-id" \
  || { echo "FAIL scaffold.alembic.revision-id"; fails=$((fails+1)); }
grep -q 'def upgrade'   "$tmp/scaffold-alembic/$out" && echo "ok   scaffold.alembic.upgrade"   || { echo "FAIL"; fails=$((fails+1)); }
grep -q 'def downgrade' "$tmp/scaffold-alembic/$out" && echo "ok   scaffold.alembic.downgrade" || { echo "FAIL"; fails=$((fails+1)); }
grep -q 'TODO: human writes' "$tmp/scaffold-alembic/$out" && echo "ok   scaffold.alembic.todo" || { echo "FAIL"; fails=$((fails+1)); }

# Alembic collision → exit 2
"$SCAFFOLD" --toolchain alembic --migration-name add_email_to_users \
            --root "$tmp/scaffold-alembic" --rev abc123def456 2>/dev/null
check "scaffold.alembic.collision.exit-2" "$?" "2"

# Django: sequence numbering
mkdir -p "$tmp/scaffold-django/users/migrations"
touch "$tmp/scaffold-django/users/migrations/__init__.py"
touch "$tmp/scaffold-django/users/migrations/0001_initial.py"
touch "$tmp/scaffold-django/users/migrations/0002_email.py"
out=$("$SCAFFOLD" --toolchain django --migration-name add_phone_to_users \
                  --app users --root "$tmp/scaffold-django")
check "scaffold.django.next-seq"  "$out" "users/migrations/0003_add_phone_to_users.py"
grep -q 'class Migration' "$tmp/scaffold-django/$out" && echo "ok   scaffold.django.class" \
  || { echo "FAIL scaffold.django.class"; fails=$((fails+1)); }

# Django: empty migrations dir → 0001
mkdir -p "$tmp/scaffold-django2/users/migrations"
touch "$tmp/scaffold-django2/users/migrations/__init__.py"
out=$("$SCAFFOLD" --toolchain django --migration-name initial \
                  --app users --root "$tmp/scaffold-django2")
check "scaffold.django.first" "$out" "users/migrations/0001_initial.py"

# Django without --app → exit 2
"$SCAFFOLD" --toolchain django --migration-name foo --root "$tmp/scaffold-django2" 2>/dev/null
check "scaffold.django.no-app.exit-2" "$?" "2"

# Rails
mkdir -p "$tmp/scaffold-rails/db/migrate"
out=$("$SCAFFOLD" --toolchain rails --migration-name add_email_to_users \
                  --root "$tmp/scaffold-rails" --now 20260508120000)
check "scaffold.rails.path" "$out" "db/migrate/20260508120000_add_email_to_users.rb"
grep -q 'class AddEmailToUsers < ActiveRecord::Migration' "$tmp/scaffold-rails/$out" \
  && echo "ok   scaffold.rails.class" \
  || { echo "FAIL scaffold.rails.class"; fails=$((fails+1)); }

# Knex
mkdir -p "$tmp/scaffold-knex"
out=$("$SCAFFOLD" --toolchain knex --migration-name add_email_to_users \
                  --root "$tmp/scaffold-knex" --now 20260508120000)
check "scaffold.knex.path" "$out" "migrations/20260508120000_add_email_to_users.js"
grep -q 'exports.up'   "$tmp/scaffold-knex/$out" && echo "ok   scaffold.knex.up"   || { echo "FAIL scaffold.knex.up"; fails=$((fails+1)); }
grep -q 'exports.down' "$tmp/scaffold-knex/$out" && echo "ok   scaffold.knex.down" || { echo "FAIL scaffold.knex.down"; fails=$((fails+1)); }

# raw-sql
mkdir -p "$tmp/scaffold-raw"
out=$("$SCAFFOLD" --toolchain raw-sql --migration-name add_email_to_users \
                  --root "$tmp/scaffold-raw" --now 20260508120000)
check "scaffold.raw-sql.path" "$out" "migrations/20260508120000_add_email_to_users.sql"
grep -q -- '-- Up'   "$tmp/scaffold-raw/$out" && echo "ok   scaffold.raw-sql.up"   || { echo "FAIL scaffold.raw-sql.up"; fails=$((fails+1)); }
grep -q -- '-- Down' "$tmp/scaffold-raw/$out" && echo "ok   scaffold.raw-sql.down" || { echo "FAIL scaffold.raw-sql.down"; fails=$((fails+1)); }

# Bad name
"$SCAFFOLD" --toolchain raw-sql --migration-name "Bad-Name" --root "$tmp/scaffold-raw" 2>/dev/null
check "scaffold.bad-name.exit-2" "$?" "2"

# Unknown toolchain
"$SCAFFOLD" --toolchain bogus --migration-name foo --root "$tmp/scaffold-raw" 2>/dev/null
check "scaffold.unknown-toolchain.exit-2" "$?" "2"

# Missing required arg
"$SCAFFOLD" --toolchain raw-sql --root "$tmp/scaffold-raw" 2>/dev/null
check "scaffold.missing-name.exit-2" "$?" "2"

if [[ "$fails" -gt 0 ]]; then
  echo "FAILED: $fails check(s)"
  exit 1
fi
echo "PASSED"
