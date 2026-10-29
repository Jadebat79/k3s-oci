#!/usr/bin/env bash
# add-redis-user.sh <app> <key-prefix>: Redis ACL user <app> that can only touch
# keys and channels starting with <key-prefix>, and no admin/dangerous commands.
# Password in Secret redis-<app> in the data namespace. Safe to re-run.
set -euo pipefail
app=${1:?usage: add-redis-user.sh <app> <key-prefix>}
prefix=${2:?usage: add-redis-user.sh <app> <key-prefix>}
kubectl -n data get secret "redis-$app" >/dev/null 2>&1 || \
  kubectl -n data create secret generic "redis-$app" --from-literal=username="$app" \
    --from-literal=password="$(openssl rand -hex 24)"
pw=$(kubectl -n data get secret "redis-$app" -o jsonpath='{.data.password}' | base64 -d)
hash=$(printf %s "$pw" | openssl dgst -sha256 | awk '{print $NF}')
line="user $app on #$hash ~${prefix}* &${prefix}* +@all -@dangerous +client|setinfo"
acl=$(kubectl -n data get secret redis-users -o jsonpath='{.data.users\.acl}' | base64 -d | grep -v "^user $app " || true)
acl=$(printf '%s\n%s\n' "$acl" "$line")
kubectl -n data create secret generic redis-users --from-literal=users.acl="$acl" \
  --dry-run=client -o yaml | kubectl apply -f -
# The mounted Secret updates within ~1 minute; then reload the ACL file.
admin=$(kubectl -n data get secret redis-admin -o jsonpath='{.data.password}' | base64 -d)
for _ in $(seq 1 30); do
  if kubectl -n data exec deploy/redis -- grep -qF "#$hash" /etc/redis/users.acl; then
    kubectl -n data exec deploy/redis -- env REDISCLI_AUTH="$admin" redis-cli --user admin ACL LOAD
    echo "redis user $app ready (credentials in Secret data/redis-$app)"
    exit 0
  fi
  sleep 5
done
echo "timed out waiting for the ACL file to update; re-run" >&2
exit 1
