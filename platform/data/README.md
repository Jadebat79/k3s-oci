# Shared data services (namespace `data`)

One Postgres 16 and one Redis 7 for every app on the cluster, instead of one of
each per app. Each app gets:

- **Postgres:** its own database and a non-superuser login that owns it.
  Other roles can't connect to it.
- **Redis:** an ACL user that can only touch keys starting with its own prefix,
  with no admin or dangerous commands (`FLUSHALL`, `KEYS`, `CONFIG`…). The
  default user is off.
- **Network:** only the pods listed in `network-policy.yaml` can reach either
  service.

Passwords are generated into Secrets in `data`. They are never in git.

| App | Postgres DB/login | Redis user / key prefix | Wired via |
|---|---|---|---|
| aristocrats | `aristocrats` | `aristocrats` / `aa:` | `DATABASE_URL`, `REDIS_URL` in `aristocrats/aristocrats-secrets` |
| omnipay | `omnipay` | none | `POSTGRES_*` in `omnipay/omnipay-secrets`; Service `omnipay/postgres` is an ExternalName to `postgres.data.svc.cluster.local` |

## Setup

```sh
./bootstrap.sh                      # namespace, admin secrets, Postgres, Redis, policies, backup CronJob
./add-database.sh <app>             # role + database; creds in Secret data/db-<app>
./add-redis-user.sh <app> <prefix>  # ACL user; creds in Secret data/redis-<app>
```

Then copy the credentials into the app's own Secret. Add the app's namespace
and pod label to `network-policy.yaml` and apply it.

Connect from an app at `postgres.data.svc.cluster.local:5432` and
`redis://<app>:<password>@redis.data.svc.cluster.local:6379/0`.

## Copying an existing database in

```sh
kubectl -n <ns> exec postgres-0 -- pg_dump -U <user> -Fc --no-owner --no-acl <db> > db.dump
kubectl -n data cp db.dump postgres-0:/tmp/db.dump
kubectl -n data exec postgres-0 -- pg_restore -U <app> -d <app> --no-owner --no-acl /tmp/db.dump
```

Restore as the app's role, so it owns every object. If the dump has a
`COMMENT ON EXTENSION`, filter it out with `pg_restore -l | grep -v "COMMENT - EXTENSION"`
and pass the list with `-L`. Only the superuser may run that statement.

## Backups

`backup.yaml` is suspended until an Object Storage PAR exists; see its header.
Until then nothing is backed up, and everything lives on one node's disk.
