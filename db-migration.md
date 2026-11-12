# Database Migration Guide: Standalone PostgreSQL to Patroni HA Cluster

This guide documents the migration of an application database from a **single standalone PostgreSQL server** (running behind a k3s service) to a **new Patroni + etcd HA cluster fronted by HAProxy**.

It follows the migration that was actually performed, including the problems encountered and their fixes.

Related documents:

| File | Purpose |
|---|---|
| `postgresql-ha-patroni-guide.md` | How the HA cluster was built |
| `README-haproxy.md` | How HAProxy was set up in front of the cluster |
| `architecture-overview.md` | The overall architecture |

---

## 1. Scenario

| | Before | After |
|---|---|---|
| Database | Single PostgreSQL 18.6 server | Patroni cluster: node1 + node2 (PostgreSQL 18) with a witness for etcd quorum |
| Reachable at | `postgres.postgres.svc.cluster.local:5432` (k3s service), also on a public IP | HAProxy `172.31.12.7:5000` (private) |
| Failover | None | Automatic (about 10 to 30 seconds) |
| App | k3s backend | Same app, only the database settings changed |
| Database / user | `appdb` / `appuser` | Same names, recreated on the new cluster |

**Approach:** logical backup and restore (`pg_dump -Fc` and `pg_restore`). The new cluster starts empty, so the user, database and extensions are created first, then the data is loaded, then the app is repointed. The old database stays untouched as a rollback.

**Downtime:** only the time between stopping the app and starting it on the new database. For this database (15 tables, small data) the restore itself took under a second.

---

## 2. Values used (replace with your own)

| Item | Example value |
|---|---|
| Old DB host (public) | `<OLD_DB_HOST>` (here: `47.130.56.240`), port `5432` |
| Old DB user / database | `appuser` / `appdb` |
| New cluster entry point | HAProxy `172.31.12.7`, port `5000` (leader) / `5001` (replica) |
| New cluster superuser | `postgres` |
| Work machine inside the VPC | The witness VM (`172.31.14.43`), any VM that can reach HAProxy works |
| App namespace / deployment | `<app-namespace>` / `<backend-deployment>` |

> **Never paste real passwords into chats, tickets or git.** The guide uses `<placeholders>` for passwords. Use strong, URL-safe passwords (letters, digits, `-`, `_`). Characters such as `@ : / ? # %` break connection URLs.

---

## 3. Prerequisites

1. The HA cluster is healthy:

   ```bash
   patronictl -c /etc/patroni/config.yml list     # one Leader, one Replica (streaming, lag 0)
   ```

2. HAProxy works. From a VPC machine:

   ```bash
   psql -h 172.31.12.7 -p 5000 -U postgres -Atc "select inet_server_addr(), pg_is_in_recovery();"   # leader IP and f
   ```

3. A work machine inside the VPC with the **PostgreSQL 18 client tools** (see the version note in section 4):

   ```bash
   sudo apt-get install -y postgresql-client-18
   ls /usr/lib/postgresql/
   ```

4. The **HAProxy Security Group allows the k3s nodes on TCP 5000**. Otherwise the app times out after cutover.

5. A maintenance window, and a way to stop the app (scale the deployment to 0).

---

## 4. Know the old database first

Connect to the old database and collect these facts:

```bash
psql -h <OLD_DB_HOST> -p 5432 -U appuser -d appdb
```

```sql
select version();
select pg_size_pretty(pg_database_size('appdb'));
\dx
\l appdb
\q
```

| Fact | Why it matters |
|---|---|
| **Server version** | `pg_dump` refuses to dump from a server **newer** than itself. The old server was 18.6, so the client must be version 18 (see troubleshooting) |
| **Size** | Estimates dump and restore time |
| **Extensions (`\dx`)** | Each must be created on the new database before restoring |
| **Collation** | If it is not the default, create the new database with the same one |

---

## 5. Step 1: Create the user and database on the new cluster

Connect through HAProxy port 5000 (always the leader) as the superuser. Use **two separate `-c` flags** because `CREATE DATABASE` cannot run in the same transaction as another statement:

```bash
read -s -p "postgres (superuser) password: " PGPASSWORD; export PGPASSWORD; echo

psql -h 172.31.12.7 -p 5000 -U postgres \
  -c "CREATE ROLE appuser WITH LOGIN PASSWORD '<new-appuser-password>';" \
  -c "CREATE DATABASE appdb OWNER appuser ENCODING 'UTF8';"
```

Expected output: `CREATE ROLE` and `CREATE DATABASE`.

Verify:

```bash
psql -h 172.31.12.7 -p 5000 -U postgres -c "\du appuser" -c "\l appdb"
```

Notes:

- Patroni replicates roles and databases to the replica automatically. This is done once.
- If the old database used a non-default collation, create it with the same one:
  `CREATE DATABASE appdb OWNER appuser TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';` (the locale must exist on the DB nodes).
- Avoid heredocs (`<<'SQL'`) when pasting into a terminal. If the closing `SQL` is not on its own line, the shell waits forever at a `>` prompt. Use the `-c` form above.

Test that the app user can log in:

```bash
read -s -p "appuser password: " PGPASSWORD; export PGPASSWORD; echo
psql -h 172.31.12.7 -p 5000 -U appuser -d appdb -c "select current_user, inet_server_addr();"
```

---

## 6. Step 2: Take the backup from the old database

Use the **version 18** `pg_dump` and custom format (`-Fc`: compressed, restorable selectively and in parallel).

> **Important:** clear any leftover `PGPASSWORD` first. It silently overrides the password prompt, and a password left over from the new cluster is rejected by the old one.

```bash
unset PGPASSWORD
/usr/lib/postgresql/18/bin/pg_dump -h <OLD_DB_HOST> -p 5432 -U appuser -d appdb -Fc -v -f appdb.dump
```

Type the **old** database's `appuser` password when prompted. Then check the file:

```bash
ls -lh appdb.dump
/usr/lib/postgresql/18/bin/pg_restore -l appdb.dump | head -30
```

List the extensions it needs:

```bash
/usr/lib/postgresql/18/bin/pg_restore -l appdb.dump | grep -i "EXTENSION"
```

`plpgsql` is built in, so ignore it. Any other name must be created on the new database (Step 3).

Keep a copy of `appdb.dump` outside the server (laptop, S3). It is also your backup.

### If the dump cannot be taken from the work machine

| Symptom | Cause | Fix |
|---|---|---|
| `Connection timed out` | The old DB firewall or Security Group allows only certain source IPs (your desktop), not the VPC machine | Dump from the allowed machine (for example your desktop), then copy the file: `scp -i key.pem appdb.dump ubuntu@<work-machine>:/home/ubuntu/` |
| `password authentication failed` (old DB) | Stale `PGPASSWORD` from the new cluster, or the wrong password | `unset PGPASSWORD` and retype the old password |
| `aborting because of server version mismatch` | Client older than the server (client 16 against server 18.6) | Install `postgresql-client-18` and run `/usr/lib/postgresql/18/bin/pg_dump` |
| Dump seems to hang with no output | `pg_dump -Fc` prints nothing without `-v` | Add `-v`, and check the file grows with `watch -n 2 ls -lh appdb.dump` |

For long dumps, run inside `tmux` so an SSH drop does not kill the job.

---

## 7. Step 3: Create the extensions on the new database

Only for extensions from the list in Step 2 (skip `plpgsql`). Run as the **superuser**:

```bash
read -s -p "postgres (superuser) password: " PGPASSWORD; export PGPASSWORD; echo
psql -h 172.31.12.7 -p 5000 -U postgres -d appdb -c "CREATE EXTENSION IF NOT EXISTS <extension-name>;"
```

Names with hyphens need double quotes: `-c 'CREATE EXTENSION IF NOT EXISTS "uuid-ossp";'`.

If the error is `could not open extension control file`, the extension package is missing on the DB nodes. Install it on **both** node1 and node2 (for contrib extensions: `sudo apt-get install -y postgresql-contrib`) and retry.

In this migration the dump contained no extensions besides `plpgsql`, so nothing was needed.

---

## 8. Step 4: Cutover (this is the downtime window)

Practice is optional because the old database is never modified and the restore can be repeated. For production with large data, a practice restore into a temporary database (`appdb_test`) tells you how long the window will be.

**4.1. Stop the application** so no writes reach the old database:

```bash
kubectl scale deployment <backend-deployment> -n <app-namespace> --replicas=0
```

**4.2. Take a final dump** (a dump taken earlier misses later writes). Repeat Step 2 and name it `appdb-final.dump`.

**4.3. Restore into the new database** as the app user:

```bash
read -s -p "appuser password: " PGPASSWORD; export PGPASSWORD; echo

time /usr/lib/postgresql/18/bin/pg_restore -h 172.31.12.7 -p 5000 -U appuser -d appdb \
  --no-owner --no-acl -j 4 -v appdb-final.dump 2>&1 | tee restore.log
```

| Option | Meaning |
|---|---|
| `--no-owner --no-acl` | Do not try to restore the old owners and grants (the new owner is `appuser`) |
| `-j 4` | 4 parallel jobs |
| `-v` | Verbose progress |

**4.4. Check for errors:**

```bash
grep -i error restore.log
```

- No output: clean restore.
- `COMMENT ON EXTENSION` or "already exists" messages are safe to ignore.
- Anything about a missing table, constraint or permission is **not**. Fix it before continuing.

A healthy restore log ends with `finished main parallel loop`. In this migration it created 3 enum types (`orderstatus`, `restaurant_status`, `user_role`) and 15 tables with all indexes, primary keys and foreign keys, with no errors.

**If the restore fails halfway,** wipe the database and retry. Restoring over a half-loaded database causes "already exists" errors:

```bash
read -s -p "postgres (superuser) password: " PGPASSWORD; export PGPASSWORD; echo
psql -h 172.31.12.7 -p 5000 -U postgres \
  -c "DROP DATABASE appdb;" \
  -c "CREATE DATABASE appdb OWNER appuser ENCODING 'UTF8';"
```

Then repeat Step 3 and Step 4.3.

**4.5. Refresh planner statistics:**

```bash
/usr/lib/postgresql/18/bin/vacuumdb -h 172.31.12.7 -p 5000 -U appuser -d appdb --analyze-only
```

**4.6. Compare row counts, old against new.** Run this query on both databases (old: `-h <OLD_DB_HOST> -p 5432` with the old password, new: `-h 172.31.12.7 -p 5000`) and compare:

```sql
select table_name,
  (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::int as rows
from information_schema.tables
where table_schema = 'public' and table_type = 'BASE TABLE'
order by 1;
```

Do not continue until the counts match.

**4.7. Check sequences.** If tables use auto-increment IDs, make sure the next value is higher than the existing maximum:

```bash
psql -h 172.31.12.7 -p 5000 -U appuser -d appdb -c "select sequencename, last_value from pg_sequences;"
```

- No sequences listed: IDs are generated by the app (for example UUIDs). Nothing to do.
- Sequences with a `last_value` lower than the table's `max(id)`: fix it with `select setval('<sequence_name>', (select max(id) from <table>));`. Dumps normally carry sequence values, but always verify by creating a test record in the app after cutover.

**4.8. Confirm the data reached the replica** (port 5001 goes to the replica):

```bash
psql -h 172.31.12.7 -p 5001 -U appuser -d appdb -c "select count(*) from users;"
patronictl -c /etc/patroni/config.yml list     # on a DB node: replica streaming, lag 0
```

---

## 9. Step 5: Point the application at the new database

### Old values

```yaml
database:
  host: "postgres.postgres.svc.cluster.local"
  port: 5432
  name: "appdb"
  user: "appuser"

secret:
  postgresPassword: "<old-password>"
```

### New values, option A: straight to HAProxy

```yaml
database:
  host: "172.31.12.7"        # HAProxy private IP
  port: 5000                 # HAProxy leader port
  name: "appdb"
  user: "appuser"

secret:
  postgresPassword: "<new-appuser-password>"
```

### New values, option B: a DNS name inside the cluster

A Service with no selector plus a manual Endpoints object forwards to HAProxy. If the HAProxy IP changes later, only this object is edited:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-ha
  namespace: postgres
spec:
  ports:
    - port: 5432
      targetPort: 5000
---
apiVersion: v1
kind: Endpoints
metadata:
  name: postgres-ha
  namespace: postgres
subsets:
  - addresses:
      - ip: 172.31.12.7
    ports:
      - port: 5000
```

```bash
kubectl apply -f postgres-ha.yaml
```

```yaml
database:
  host: "postgres-ha.postgres.svc.cluster.local"
  port: 5432
  name: "appdb"
  user: "appuser"
```

Use a **new name** (`postgres-ha`), not the old `postgres`, so the old database stays reachable and rollback is a one-line change.

### Test connectivity from inside k3s (before starting the app)

```bash
kubectl run pgtest --rm -it --restart=Never --image=postgres:18 -n <app-namespace> \
  --env="PGPASSWORD=<new-appuser-password>" -- \
  psql -h 172.31.12.7 -p 5000 -U appuser -d appdb -c "select inet_server_addr(), pg_is_in_recovery();"
```

Expected: the leader's IP and `f`. A timeout means the HAProxy Security Group does not yet allow the k3s nodes.

### Apply and start

```bash
# Helm:
helm upgrade <release-name> <chart> -n <namespace> -f values.yaml
# or plain manifests:
kubectl apply -f <your-config-and-secret-files>.yaml

kubectl rollout restart deployment/<backend-deployment> -n <app-namespace>
kubectl scale deployment <backend-deployment> -n <app-namespace> --replicas=<original-count>
kubectl logs deployment/<backend-deployment> -n <app-namespace> --tail=50
```

Pods do **not** reload secrets or environment variables on their own, so a restart is required. Logs should show a successful connection with no timeout or authentication errors.

---

## 10. Step 6: Verify after cutover

- [ ] Log in to the app and run the main flows (login, orders, and so on).
- [ ] Create a test record, and confirm it saves (this also proves sequences are fine).
- [ ] Old users and data are present.
- [ ] `patronictl -c /etc/patroni/config.yml list`: replica `streaming`, lag 0.
- [ ] HAProxy stats page: leader green in `postgres_primary`, replica green in `postgres_replica`.
- [ ] **Failover test with the real app:** `sudo systemctl stop patroni` on the leader. Expect a short burst of errors (10 to 30 seconds), then recovery. If the app does not reconnect on its own, add retry or reconnect logic to its connection pool. Restart Patroni afterwards (`sudo systemctl start patroni`).

---

## 11. Rollback plan

If something is wrong after cutover:

1. Scale the backend to 0.
2. Set `host` back to `postgres.postgres.svc.cluster.local`, `port` to `5432` and the password to the old one.
3. Apply, restart and scale the backend back up.

Writes made to the new cluster after cutover are not in the old database. Dump them from the new cluster and load them back if needed. Decide quickly, and never let both databases accept writes.

---

## 12. After the migration

| Task | Details |
|---|---|
| **Keep the old DB for a few days** | Make sure nothing writes to it. It is the rollback |
| **Final backup of the old DB** | Keep the last dump somewhere safe, then shut the old server down |
| **Close the old DB's public port** | Port 5432 on a public IP is a common attack target |
| **Change weak or leaked passwords** | `appuser`, `postgres`, `replicator` and the HAProxy stats password. For superuser or replicator changes, update `/etc/patroni/config.yml` on **both** DB nodes, then restart Patroni one node at a time, replica first |
| **Set up backups of the new cluster** | HA is not a backup. At minimum a scheduled `pg_dump` against the replica port 5001 to off-server storage. Better: pgBackRest or WAL-G for point-in-time recovery |
| **Store passwords properly** | Kubernetes Secret or a secret manager, not a values file in git |
| **Monitoring** | Replication lag, disk space, Patroni and etcd health, HAProxy stats |

Changing a password safely, without leaving it in shell history:

```bash
psql -h 172.31.12.7 -p 5000 -U postgres -c "\password appuser"
```

Then update the app's secret and restart its pods.

---

## 13. Troubleshooting summary

| Symptom | Cause | Fix |
|---|---|---|
| Shell shows a `>` prompt and nothing runs | Heredoc pasted on one line, closing delimiter not on its own line | Press Ctrl+C and use `-c` flags |
| `password authentication failed` against the **new** cluster in 0.02 seconds | Wrong password typed, or the role was never created | `\du appuser` as superuser; `ALTER ROLE appuser WITH PASSWORD '...'` or `CREATE ROLE` |
| `password authentication failed` against the **old** DB | Stale `PGPASSWORD` from another cluster | `unset PGPASSWORD` |
| `server version mismatch` | `pg_dump` older than the server | Use `/usr/lib/postgresql/18/bin/pg_dump` |
| `Connection timed out` to the old DB | Source IP not allowed by the old DB firewall | Dump from an allowed machine and `scp` the file |
| `Connection timed out` from the app pods to HAProxy | HAProxy Security Group does not allow the k3s nodes | Add an inbound rule for TCP 5000 |
| "already exists" errors during restore | Restoring over a partly loaded database | `DROP DATABASE appdb;` then recreate and restore again |
| `duplicate key` after cutover | A sequence is behind the table data | `setval` as in section 8, step 4.7 |
| App connects but fails after a few minutes of idle | Connection idle timeout (HAProxy `timeout client/server 30m`) | Use pool keepalive or a shorter pool idle timeout |
| Password with `@` breaks the connection | The app builds a URL from the password | Use a URL-safe password, or percent-encode (`@` is `%40`) |

---

## 14. Checklist

**Before**
- [ ] HA cluster healthy; HAProxy working
- [ ] Work machine has `postgresql-client-18`
- [ ] HAProxy Security Group allows k3s nodes on 5000
- [ ] Old DB version, size and extensions noted

**Cutover**
- [ ] User and database created on the new cluster
- [ ] Extensions created
- [ ] App scaled to 0
- [ ] Final dump taken and stored safely
- [ ] Restore finished with no real errors
- [ ] Row counts match; sequences verified
- [ ] App config changed; connectivity tested from k3s
- [ ] App restarted and verified

**After**
- [ ] Failover tested with the real app
- [ ] Backups scheduled for the new cluster
- [ ] Passwords rotated
- [ ] Old DB kept as rollback, then final dump taken, shut down, and its public port closed