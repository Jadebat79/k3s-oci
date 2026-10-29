#!/usr/bin/env bash
# add-database.sh <app>: creates login role <app> (not superuser) and database
# <app> owned by it, closed to every other role. The password goes into
# Secret db-<app> in the data namespace (keys: username, password, database,
# host). Safe to re-run; never changes an existing password.
set -euo pipefail
app=${1:?usage: add-database.sh <app>}
[[ $app =~ ^[a-z][a-z0-9_]*$ ]] || { echo "app name must be lowercase [a-z0-9_]" >&2; exit 1; }
if ! kubectl -n data get secret "db-$app" >/dev/null 2>&1; then
  kubectl -n data create secret generic "db-$app" \
    --from-literal=username="$app" --from-literal=database="$app" \
    --from-literal=host=postgres.data.svc.cluster.local \
    --from-literal=password="$(openssl rand -hex 24)"
fi
pw=$(kubectl -n data get secret "db-$app" -o jsonpath='{.data.password}' | base64 -d)
kubectl -n data exec -i postgres-0 -- psql -v ON_ERROR_STOP=1 -U postgres -d postgres -q \
  -v app="$app" -v pw="$pw" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'app') WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'app') \gexec
ALTER ROLE :"app" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'pw';
SELECT format('CREATE DATABASE %I OWNER %I', :'app', :'app') WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'app') \gexec
REVOKE ALL ON DATABASE :"app" FROM PUBLIC;
SQL
echo "database $app ready (credentials in Secret data/db-$app)"
