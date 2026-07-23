#!/bin/bash
# Provision one database + one least-privilege login role per app on the shared
# data-plane Postgres (namespace `data`). Platform-owned single source of truth;
# supersedes the copies that lived in transigen/deploy/provision-db.sh and
# snoopy_home's runbook SQL. It runs INSIDE the postgres pod — pipe it in over
# kubectl exec:
#
#   kubectl -n data exec -i deploy/postgres -- \
#     env PROVISION_APPS="transigen" TRANSIGEN_DB_PASSWORD=... \
#     bash -s < cluster/data-postgres/provision-db.sh
#
# App roster (db / role — snoopy predates the unified naming, hence the map):
#   snoopy    → db snoopy_home, role snoopy_rw,    pw SNOOPY_DB_PASSWORD
#   gelp      → db gelp,        role gelp_rw,      pw GELP_DB_PASSWORD
#   transigen → db transigen,   role transigen_rw, pw TRANSIGEN_DB_PASSWORD
#   <new app> → db <app>,       role <app>_rw,     pw <APP>_DB_PASSWORD
#
# SAFETY MODEL (why onboarding app N can never hurt apps 1..N-1):
#   - PROVISION_APPS lists ONLY the apps you are touching this run. Apps not
#     listed are never visited at all.
#   - Databases are NEVER dropped or recreated; an existing DB is left as-is.
#   - An existing role's password is NOT touched unless ROTATE=1 is set — so
#     even accidentally listing a live app is a no-op. Rotating a password is
#     an explicit, deliberate act (and requires updating that app's secret).
#   - Grants/isolation statements are idempotent.
#
# Disaster recovery (empty re-initialised volume) is the ONE case where you
# list every app: re-run with the full roster + stored passwords, then restore
# each database from backup.
set -euo pipefail

admin="${POSTGRES_USER:-postgres}"
psql_admin() { psql -v ON_ERROR_STOP=1 --username "$admin" --dbname postgres "$@"; }

apps="${PROVISION_APPS:-}"
if [ -z "$apps" ]; then
  echo "provision: PROVISION_APPS is empty — pass it in the kubectl exec env (e.g. \"transigen\")" >&2
  exit 1
fi

# Isolation hardening: these apps only ever connect to their own database, so
# revoke the default PUBLIC CONNECT on the maintenance databases too. Without it
# an app role could still connect to `postgres`/`template1` and enumerate the
# other apps' database and role names. Idempotent; the superuser is unaffected.
psql_admin <<'EOSQL'
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
EOSQL

# provision <database> <role> <password-or-empty>
provision() {
  local db="$1" role="$2" pw="$3"

  # Role: create if absent. If it already exists, leave the password alone
  # unless ROTATE=1 — this is the guard that makes re-listing a live app safe.
  if [ "$(psql_admin -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$role'")" = "1" ]; then
    if [ "${ROTATE:-0}" = "1" ]; then
      [ -n "$pw" ] || { echo "provision: ROTATE=1 but no password for '$role'" >&2; exit 1; }
      psql_admin -v role="$role" -v pw="$pw" <<'EOSQL'
ALTER ROLE :"role" WITH LOGIN PASSWORD :'pw';
EOSQL
      echo "rotated: password for existing role '$role'"
    else
      echo "exists: role '$role' — password untouched (set ROTATE=1 to rotate)"
    fi
  else
    [ -n "$pw" ] || { echo "provision: missing password for new role '$role' (pass <APP>_DB_PASSWORD in the exec env)" >&2; exit 1; }
    psql_admin -v role="$role" -v pw="$pw" <<'EOSQL'
CREATE ROLE :"role" WITH LOGIN PASSWORD :'pw';
EOSQL
  fi

  # Database: created once, owned by the app role. As the owner it also owns the
  # public schema (via pg_database_owner on PG15+), so it can create tables with
  # no extra grants. NEVER dropped here.
  if [ "$(psql_admin -tAc "SELECT 1 FROM pg_database WHERE datname = '$db'")" != "1" ]; then
    createdb --username "$admin" --owner "$role" "$db"
  fi

  # Isolation: revoke the default PUBLIC CONNECT so no other app's role can reach
  # this database, then grant it back to just the owner.
  psql_admin -v role="$role" -v db="$db" <<'EOSQL'
REVOKE CONNECT ON DATABASE :"db" FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE :"db" TO :"role";
EOSQL

  echo "provisioned: database '$db' owned by role '$role'"
}

for app in $apps; do
  case "$app" in
    # snoopy predates the db-name == app-name convention.
    snoopy) db="snoopy_home"; role="snoopy_rw"; pwvar="SNOOPY_DB_PASSWORD" ;;
    *)      db="$app";        role="${app}_rw"; pwvar="$(echo "$app" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD" ;;
  esac
  provision "$db" "$role" "${!pwvar:-}"
done

echo "app provisioning complete: $apps"
