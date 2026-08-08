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
#
# SECTION 2 — VERIFICATION. After provisioning, the script proves the isolation
# it just configured rather than assuming the statements took effect: it checks
# the role holds no SUPERUSER/CREATEDB/CREATEROLE/REPLICATION/BYPASSRLS, that
# PUBLIC cannot connect, and — the one that matters — it CONNECTS AS THE APP
# ROLE TO A PEER'S DATABASE AND REQUIRES THE CONNECTION TO BE REFUSED. Any
# failed check exits non-zero.
#
# A provisioning script that asserts its own outcome is the difference between
# a CONTROL and a CLAIM. Issuing `REVOKE CONNECT` establishes the isolation;
# only observing a refusal proves it.
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

provisioned_dbs=""
provisioned_roles=""

for app in $apps; do
  case "$app" in
    # snoopy predates the db-name == app-name convention.
    snoopy) db="snoopy_home"; role="snoopy_rw"; pwvar="SNOOPY_DB_PASSWORD" ;;
    *)      db="$app";        role="${app}_rw"; pwvar="$(echo "$app" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD" ;;
  esac
  provision "$db" "$role" "${!pwvar:-}"
  provisioned_dbs="$provisioned_dbs $db"
  provisioned_roles="$provisioned_roles $role"
done

echo "app provisioning complete: $apps"

########################################################################
# Section 2 — VERIFY
#
# Everything above CONFIGURES the isolation. Everything below PROVES it,
# by observing the outcome instead of trusting that the statements took.
#
# How the connection checks authenticate: this runs inside the postgres
# pod, so psql uses the unix socket, and the official postgres image
# initialises with `--auth-local=trust`. No password is needed, which is
# what lets the peer test cover EVERY app in this run — including one
# whose password was not passed in because its role already existed.
#
# That is also why the test is meaningful: with authentication out of the
# way, a refusal can only come from the CONNECT privilege, which is
# exactly the thing `REVOKE CONNECT ... FROM PUBLIC` is supposed to have
# taken away.
#
# NOTE ON FAILURE: provisioning above has already completed and is
# idempotent. A failure here does NOT mean the databases are half-made —
# it means the isolation could not be demonstrated. Fix the finding and
# re-run; re-running is safe.
########################################################################

echo
echo "== verifying isolation =="
failures=0

check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    echo "  ok    $1"
  else
    echo "  FAIL  $1 (expected '$2', got '$3')" >&2
    failures=$((failures + 1))
  fi
}

for db in $provisioned_dbs; do
  # Recover this db's role from the same mapping used above.
  case "$db" in
    snoopy_home) role="snoopy_rw" ;;
    *)           role="${db}_rw" ;;
  esac

  # 2.1 — No privilege attribute that would defeat the entire model. A
  #       SUPERUSER role ignores every GRANT and REVOKE issued above, so
  #       this check is a precondition for all the others meaning anything.
  #       These are PostgreSQL's CREATE ROLE defaults; asserted rather than
  #       assumed, because a default is only a default until someone changes it.
  attrs="$(psql_admin -tAc "
    SELECT rolsuper::text || ',' || rolcreatedb::text || ',' || rolcreaterole::text
        || ',' || rolreplication::text || ',' || rolbypassrls::text
    FROM pg_roles WHERE rolname = '$role'")"
  check "$role: no SUPERUSER/CREATEDB/CREATEROLE/REPLICATION/BYPASSRLS" \
        "false,false,false,false,false" "$attrs"

  # 2.2 — The role can LOGIN. A least-privilege role that cannot connect is
  #       not isolation, it is an outage.
  check "$role: has LOGIN" "true" \
        "$(psql_admin -tAc "SELECT rolcanlogin::text FROM pg_roles WHERE rolname = '$role'")"

  # 2.3 — PUBLIC holds no CONNECT on this database. This is the revoke that
  #       stops every OTHER app's role from reaching it.
  check "$db: PUBLIC has no CONNECT" "f" \
        "$(psql_admin -tAc "SELECT has_database_privilege('public', '$db', 'CONNECT')::text" | cut -c1)"

  # 2.4 — The role reaches its OWN database. This also establishes that
  #       authentication works, which is what makes 2.5's refusal
  #       attributable to privilege rather than to a failed login.
  own="$(psql -tAqc "SELECT 'reached'" --username "$role" --dbname "$db" 2>/dev/null || echo "REFUSED")"
  check "$role -> $db: reaches its own database" "reached" "$own"

  # 2.5 — THE ASSERTION. The role must be REFUSED by a database it does not
  #       own. With a single app in this run the peer is `postgres`, the
  #       maintenance database whose PUBLIC CONNECT was revoked at the top —
  #       a genuine peer, and the one database every role knows exists.
  peer="postgres"
  for other in $provisioned_dbs; do
    [ "$other" != "$db" ] && { peer="$other"; break; }
  done

  if [ "$own" != "reached" ]; then
    # Without 2.4 a refusal below is ambiguous — it could be an auth failure
    # rather than a privilege refusal. Refuse to score it either way instead
    # of recording a pass that was never demonstrated.
    echo "  FAIL  $role -> $peer: NOT EVALUATED — 2.4 failed, so a refusal here would be ambiguous" >&2
    failures=$((failures + 1))
  elif psql -tAqc "SELECT 1" --username "$role" --dbname "$peer" >/dev/null 2>&1; then
    echo "  FAIL  $role REACHED peer database '$peer' — isolation is NOT in place" >&2
    failures=$((failures + 1))
  else
    echo "  ok    $role: refused by peer database '$peer'"
  fi
done

echo
if [ "$failures" -ne 0 ]; then
  echo "VERIFICATION FAILED: $failures check(s) did not hold." >&2
  echo "The databases and roles exist and provisioning is idempotent — but the" >&2
  echo "isolation they are supposed to provide has NOT been demonstrated." >&2
  echo "Do not treat this run as complete." >&2
  exit 1
fi

echo "isolation verified for:$provisioned_dbs"
