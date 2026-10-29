#!/usr/bin/env bash
# Creates the shared data namespace: secrets (once, never rotated here), then
# Postgres, Redis, network policies and the backup CronJob. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
gen() { openssl rand -hex 24; }
sha() { printf %s "$1" | openssl dgst -sha256 | awk '{print $NF}'; }

kubectl apply -f namespace.yaml
kubectl -n data get secret postgres-admin >/dev/null 2>&1 || \
  kubectl -n data create secret generic postgres-admin --from-literal=password="$(gen)"
if ! kubectl -n data get secret redis-users >/dev/null 2>&1; then
  admin=$(gen)
  kubectl -n data create secret generic redis-admin --from-literal=password="$admin"
  kubectl -n data create secret generic redis-users --from-literal=users.acl="$(cat <<ACL
user default off
user healthcheck on nopass -@all +ping
user admin on #$(sha "$admin") ~* &* +@all
ACL
)"
fi
kubectl apply -f postgres.yaml -f redis.yaml -f network-policy.yaml -f backup.yaml
kubectl -n data rollout status sts/postgres --timeout=3m
kubectl -n data rollout status deploy/redis --timeout=3m
