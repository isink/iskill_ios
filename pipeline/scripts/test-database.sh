#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
pipeline_dir="$(cd "$script_dir/.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/skiller-db-test.XXXXXX")"
project_prefix="skiller-db-test-$$-$RANDOM"
active_workdir=""
active_project_id=""
database_container=""

command -v docker >/dev/null
command -v supabase >/dev/null
docker info >/dev/null

cleanup_active_instance() {
  if [[ -z "$active_workdir" ]]; then
    return 0
  fi

  local cleanup_status=0
  supabase stop \
    --workdir "$active_workdir" \
    --project-id "$active_project_id" \
    --no-backup || cleanup_status=$?

  if (( cleanup_status == 0 )); then
    active_workdir=""
    active_project_id=""
    database_container=""
  else
    printf 'Failed to remove Supabase test instance %s\n' "$active_project_id" >&2
  fi

  return "$cleanup_status"
}

cleanup_on_exit() {
  local test_status=$?
  local cleanup_status=0
  trap - EXIT

  cleanup_active_instance || cleanup_status=$?
  rm -rf "$test_root"

  if (( test_status == 0 && cleanup_status != 0 )); then
    exit "$cleanup_status"
  fi
  exit "$test_status"
}
trap cleanup_on_exit EXIT

start_instance() {
  local scenario="$1"
  active_workdir="$test_root/$scenario"
  active_project_id="${project_prefix}-${scenario}"
  database_container="supabase_db_${active_project_id}"

  mkdir -p "$active_workdir/supabase"
  cp "$pipeline_dir/supabase/config.toml" "$active_workdir/supabase/config.toml"
  perl -0pi -e \
    's/^project_id = "[^"]+"$/project_id = "'$active_project_id'"/m' \
    "$active_workdir/supabase/config.toml"

  supabase start \
    --workdir "$active_workdir" \
    --yes \
    --exclude realtime,storage-api,imgproxy,kong,mailpit,postgrest,postgres-meta,studio,edge-runtime,logflare,vector,supavisor
}

run_sql() {
  docker exec -i "$database_container" \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$1"
}

capture_upgrade_state() {
  docker exec -i "$database_container" \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 -qAt \
    < "$pipeline_dir/supabase/tests/upgrade-state.sql"
}

apply_hardening_migrations() {
  for migration in \
    "$pipeline_dir/supabase/migrations/014_favorites_sync.sql" \
    "$pipeline_dir/supabase/migrations/015_skills_contract.sql" \
    "$pipeline_dir/supabase/migrations/016_lock_down_public_writes.sql"; do
    run_sql "$migration"
  done
}

printf '%s\n' 'Testing the final schema snapshot...'
start_instance snapshot
run_sql "$pipeline_dir/supabase/schema.sql"
run_sql "$pipeline_dir/supabase/tests/security.sql"
cleanup_active_instance

printf '%s\n' 'Testing the representative 013 -> 014 -> 015 -> 016 upgrade path...'
start_instance upgrade
run_sql "$pipeline_dir/supabase/tests/pre-014-schema.sql"
apply_hardening_migrations
run_sql "$pipeline_dir/supabase/tests/post-016-upgrade.sql"
run_sql "$pipeline_dir/supabase/tests/security.sql"

printf '%s\n' 'Testing 014-016 idempotency on upgraded historical data...'
upgrade_state_before="$(capture_upgrade_state)"
apply_hardening_migrations
upgrade_state_after="$(capture_upgrade_state)"
if [[ "$upgrade_state_before" != "$upgrade_state_after" ]]; then
  printf '%s\n' '014-016 changed data or function definitions on the second run' >&2
  exit 1
fi
run_sql "$pipeline_dir/supabase/tests/post-016-upgrade.sql"
run_sql "$pipeline_dir/supabase/tests/security.sql"
cleanup_active_instance
