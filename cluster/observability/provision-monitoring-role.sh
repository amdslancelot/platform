#!/bin/bash
# Create the least-privilege monitoring role that postgres-exporter logs in as.
# Cross-cutting (not per-app), so it deliberately does NOT go through
# provision-db.sh's PROVISION_APPS additive flow — it is one role for the whole
# data plane. Runs INSIDE the postgres pod, same as provision-db.sh:
#
#   kubectl -n data exec -i deploy/postgres -- \
#     env POSTGRES_EXPORTER_PASSWORD=... \
#     bash -s < cluster/observability/provision-monitoring-role.sh
#
# WHY pg_monitor is enough AND safe:
#   pg_monitor bundles pg_read_all_stats + pg_read_all_settings + pg_stat_scan_
#   tables. That lets the exporter read pg_stat_* and call pg_database_size() for
#   EVERY database — so per-app DB sizes are visible — WITHOUT any CONNECT grant
#   into the app databases. It can touch statistics, never app data. This keeps
#   the per-app connect isolation from provision-db.sh fully intact.
#
# Idempotent: re-running never changes the password unless ROTATE=1 (same guard
# as provision-db.sh). PUBLIC CONNECT on `postgres` was revoked by provision-db.sh,
# so we grant CONNECT back to just this role.
set -euo pipefail

admin="${POSTGRES_USER:-postgres}"
role="postgres_exporter"
pw="${POSTGRES_EXPORTER_PASSWORD:-}"
psql_admin() { psql -v ON_ERROR_STOP=1 --username "$admin" --dbname postgres "$@"; }

if [ "$(psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$role'")" = "1" ]; then
  if [ "${ROTATE:-0}" = "1" ]; then
    [ -n "$pw" ] || { echo "provision: ROTATE=1 but POSTGRES_EXPORTER_PASSWORD is empty" >&2; exit 1; }
    psql_admin -v role="$role" -v pw="$pw" <<'EOSQL'
ALTER ROLE :"role" WITH LOGIN PASSWORD :'pw';
EOSQL
    echo "rotated: password for existing role '$role'"
  else
    echo "exists: role '$role' — password untouched (set ROTATE=1 to rotate)"
  fi
else
  [ -n "$pw" ] || { echo "provision: missing POSTGRES_EXPORTER_PASSWORD for new role '$role'" >&2; exit 1; }
  psql_admin -v role="$role" -v pw="$pw" <<'EOSQL'
CREATE ROLE :"role" WITH LOGIN PASSWORD :'pw';
EOSQL
  echo "created: role '$role'"
fi

# Grant the monitoring role + connect on the maintenance DB. Idempotent.
psql_admin -v role="$role" <<'EOSQL'
GRANT pg_monitor TO :"role";
GRANT CONNECT ON DATABASE postgres TO :"role";
EOSQL

echo "monitoring role ready: $role (pg_monitor, CONNECT on postgres)"
