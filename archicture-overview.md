# Architecture Overview: PostgreSQL High Availability on AWS

This document describes the complete architecture of the production database platform: what each component does, how traffic flows, what happens during failures, and what is still a single point of failure.

| Related document | Purpose |
|---|---|
| `postgresql-ha-patroni-guide.md` | Step-by-step build of the Patroni + etcd cluster |
| `README-haproxy.md` | HAProxy setup |
| `db-migration-guide.md` | Migration from the old standalone database |

---

## 1. Summary

| | |
|---|---|
| **Goal** | A PostgreSQL database that survives the loss of a server without manual work |
| **Database** | PostgreSQL 18 with streaming replication |
| **HA manager** | Patroni 4.1.0 |
| **Consensus store** | etcd 3.5.16, 3 members (2 DB nodes + 1 witness) |
| **Routing** | HAProxy (TCP mode), health-checking Patroni's REST API |
| **Clients** | Backend app running on a k3s cluster |
| **OS** | Ubuntu 26.04 (24.04 LTS is also suitable) |
| **Platform** | AWS EC2 in one VPC (`172.31.0.0/16`), works the same on bare metal |
| **Failover time** | About 10 to 30 seconds (a few seconds for a planned switchover) |
| **Replication** | Asynchronous by default (synchronous mode is optional) |

---

## 2. Architecture diagram

```
                        +-----------------------------+
                        |   k3s cluster (backend app) |
                        +--------------+--------------+
                                       |
                                       |  db host = 172.31.12.7
                                       |  port 5000 (writes+reads) / 5001 (read-only)
                                       v
                        +-----------------------------+
                        |  HAProxy host  172.31.12.7  |
                        |  :5000 -> leader only       |
                        |  :5001 -> replicas only     |
                        |  :7000 -> stats page        |
                        +--------------+--------------+
                                       |  health check: GET :8008/primary  and  /replica
                       +---------------+----------------+
                       |                                |
         +-------------v-------------+    +-------------v-------------+
         | node1   172.31.7.43       |    | node2   172.31.5.238      |
         | PostgreSQL        :5432   |<-->| PostgreSQL        :5432   |
         | Patroni (REST)    :8008   |    | Patroni (REST)    :8008   |
         | etcd         :2379/:2380  |    | etcd         :2379/:2380  |
         +-------------+-------------+    +-------------+-------------+
                       |    WAL streaming (leader -> replica)  |
                       |                                       |
                       +----------------+----------------------+
                                        |  etcd peer traffic (:2380)
                          +-------------v-------------+
                          | witness   172.31.14.43    |
                          | etcd only         :2379/80|
                          +---------------------------+
```

Roles of node1 and node2 are not fixed. One is the **Leader** (accepts writes) and the other is a **Replica** (streams from the leader). They swap roles on failover or switchover.

---

## 3. Components

### 3.1 PostgreSQL (node1, node2)

- Version 18, managed entirely by Patroni. The Ubuntu `postgresql` service is **disabled**, and Patroni starts and stops PostgreSQL itself.
- Data directory: `/var/lib/postgresql/18/main` (initialized by Patroni, not by apt).
- **Streaming replication** copies WAL from the leader to the replica continuously, using replication slots (`use_slots: true`).
- `wal_log_hints` and `pg_rewind` are enabled, so a failed leader can rejoin as a replica without a full rebuild.

### 3.2 Patroni (node1, node2)

- Runs next to PostgreSQL on each DB node and decides which node is the leader.
- Holds the **leader key** in etcd. The leader renews it continuously. If it stops renewing (crash, hang, network loss), the key expires and the replica promotes itself.
- Exposes a REST API on port 8008. This is what HAProxy health checks use:

  | Endpoint | Returns 200 on |
  |---|---|
  | `/primary` | The current leader only |
  | `/replica` | A healthy replica only |

- Config: `/etc/patroni/config.yml`. Control tool: `patronictl -c /etc/patroni/config.yml <command>`.

### 3.3 etcd (node1, node2, witness)

- A 3-member cluster that stores cluster state and the leader lock. It requires a majority (2 of 3) to work, which is **quorum**.
- It prevents **split-brain**: only the node that holds the lock may be primary. A node that cannot reach etcd demotes itself.
- Config: `/etc/default/etcd`. Data: `/var/lib/etcd`.
- Patroni needs the Python module `etcd` (package `python3-etcd`) for its etcd backend.

### 3.4 Witness (a tiny VM)

- Runs **only etcd**, no database. It is the third member, so the cluster still has quorum when one DB node is lost.
- Without it, 2 etcd members could not form a majority after one failed, and no safe promotion would be possible.
- It also serves as a convenient work machine inside the VPC (running `psql` and restore commands).
- Sizing: 1 vCPU / 1 GB RAM is enough (for example `t3.micro`).

### 3.5 HAProxy (172.31.12.7)

- TCP-mode proxy giving applications **one stable address**.
- Two pools:

  | Port | Pool | Health check | Purpose |
  |---|---|---|---|
  | 5000 | `postgres_primary` | `GET /primary` expects 200 | Writes and reads (leader) |
  | 5001 | `postgres_replica` | `GET /replica` expects 200 | Read-only queries |
  | 7000 | stats | none | Monitoring page, password protected |

- Checks run every 3 seconds, a server goes DOWN after 3 failures and UP after 2 successes (`inter 3s fall 3 rise 2`). `on-marked-down shutdown-sessions` closes connections to a node that is no longer the leader, so clients reconnect to the new one.
- It is normal for one server in each pool to show DOWN with `Layer7 wrong status, code: 503`. It is the other role being correctly rejected by Patroni.

### 3.6 Application (k3s)

- The backend connects with host `172.31.12.7` and port `5000` (or through the Kubernetes Service `postgres-ha`, which forwards to HAProxy).
- Database `appdb`, user `appuser`.
- The app (or its connection pool) must reconnect and retry after a failover, because existing connections are dropped.

---

## 4. Network layout and ports

| Machine | Private IP | Runs |
|---|---|---|
| node1 | `172.31.7.43` | PostgreSQL, Patroni, etcd |
| node2 | `172.31.5.238` | PostgreSQL, Patroni, etcd |
| witness | `172.31.14.43` | etcd |
| HAProxy | `172.31.12.7` | HAProxy |
| k3s nodes | VPC | Backend app |

All machines are in the same VPC, so cluster traffic uses private IPs only.

### Security Group rules

| Destination | Port | Allowed from | Purpose |
|---|---|---|---|
| node1, node2 | 5432 | HAProxy host, the other DB node | PostgreSQL |
| node1, node2 | 8008 | HAProxy host, the other DB node | Patroni REST API (health checks) |
| node1, node2, witness | 2379, 2380 | The 3 cluster machines | etcd client and peer |
| HAProxy | 5000, 5001 | k3s nodes | Database access for the app |
| HAProxy | 7000 | Admin IP only | Stats page |
| All | 22 | Admin IP only | SSH |

Rules of thumb:

- Applications never talk to node1 or node2 directly, only to HAProxy.
- Port 5432 and the etcd ports are never open to the internet.
- If HAProxy cannot reach port 8008 on the DB nodes, every health check fails and both nodes show DOWN.

---

## 5. Request flow

**Normal write:**

1. The app connects to `172.31.12.7:5000`.
2. HAProxy forwards the TCP connection to the one server whose `/primary` check returns 200 (the leader).
3. PostgreSQL commits on the leader and streams WAL to the replica in the background.

**Read-only workload (optional):** connect to port 5001 and HAProxy balances across healthy replicas.

**Health checking (continuous):** HAProxy polls port 8008 on both nodes every 3 seconds. Patroni answers according to its own role, based on its state in etcd.

---

## 6. Failure scenarios

| Event | What happens | Impact |
|---|---|---|
| **Planned switchover** (`patronictl switchover`) | Leader demotes, replica promotes, old leader becomes replica | A few seconds of interruption, no data loss |
| **Leader PostgreSQL or Patroni stops** | Lock is released (graceful stop) or expires (crash). The replica promotes. HAProxy marks the new leader UP | About 10 to 30 seconds of write errors, then automatic recovery |
| **Leader VM crashes or reboots** | Same as above, using the lock's TTL (30 seconds) | About 30 seconds. Rare loss of the last un-replicated commit with asynchronous replication |
| **Old leader returns** | Patroni rejoins it as a replica, using `pg_rewind` if needed | None for clients |
| **Replica fails** | The leader keeps serving. Port 5001 has no healthy server until it returns | None for writes |
| **Witness fails** | etcd keeps quorum with the 2 DB nodes (2 of 3). Everything keeps working | None, but the cluster has no spare tolerance until it is restored |
| **One DB node and the witness both fail** | etcd quorum lost. The remaining leader demotes itself to read-only, intentionally | Writes stop until quorum returns |
| **Network partition isolating the leader** | The isolated leader cannot renew its lock and demotes itself. The other side promotes | Prevents split-brain, with a brief failover |
| **HAProxy host fails** | Apps cannot reach the database even though the cluster is healthy | **Outage until HAProxy is restored** (see single points of failure) |
| **Both DB nodes fail** | No database | Outage. Restore from backup or restart the nodes |

### Key timings

| Setting | Value | Meaning |
|---|---|---|
| `ttl` | 30 s | How long a silent leader keeps the lock, which bounds crash failover time |
| `loop_wait` | 10 s | Patroni check interval |
| `retry_timeout` | 10 s | Retry time for etcd and PostgreSQL operations |
| `maximum_lag_on_failover` | 1 MB | A replica further behind than this is not promoted |
| HAProxy `inter/fall/rise` | 3 s / 3 / 2 | Detection about 9 s down, about 6 s up |

---

## 7. Data safety

| Topic | Current state |
|---|---|
| **Replication** | Asynchronous. After a hard crash the last commit or two may not have reached the replica |
| **Option** | `synchronous_mode: true` (`patronictl edit-config`) makes commits wait for the replica. Costs some write latency |
| **Backups** | **Not configured yet.** HA is not a backup. A `DROP TABLE` replicates to the replica immediately |
| **Recommended** | Scheduled `pg_dump` from the replica port 5001 to off-server storage as a minimum. pgBackRest or WAL-G (point-in-time recovery) for production |
| **Encryption in transit** | Not configured. No TLS on etcd, Patroni or PostgreSQL |

---

## 8. Single points of failure and limits

| Item | Risk | Mitigation |
|---|---|---|
| **HAProxy (one host)** | If it fails, the app loses the database | Two HAProxy hosts behind an internal NLB, or EC2 auto-recovery |
| **One Availability Zone** | An AZ outage takes everything down | Place node1, node2 and the witness in different AZs |
| **No backups** | Logical corruption or deletion is unrecoverable | Set up pgBackRest or WAL-G and test restores |
| **Only 2 DB nodes** | After one failure there is no redundancy until it is repaired | Alert on a degraded cluster; consider a third DB node |
| **Plain-text traffic** | Passwords and data travel unencrypted inside the VPC | TLS for etcd, Patroni REST and PostgreSQL |
| **Shared or weak passwords** | Credentials were exposed in chats and shell history | Rotate all passwords and use a secret manager |

---

## 9. Operations cheat sheet

```bash
# Cluster state (run on a DB node)
patronictl -c /etc/patroni/config.yml list
patronictl -c /etc/patroni/config.yml switchover
patronictl -c /etc/patroni/config.yml restart pgcluster <node>
patronictl -c /etc/patroni/config.yml reinit pgcluster <replica-node>   # rebuild a broken replica
patronictl -c /etc/patroni/config.yml edit-config                       # cluster-wide settings
patronictl -c /etc/patroni/config.yml history

# Services
sudo systemctl status patroni etcd
sudo systemctl restart patroni
sudo journalctl -u patroni -n 50 --no-pager
sudo journalctl -u etcd -n 50 --no-pager

# etcd
etcdctl --endpoints=172.31.7.43:2379,172.31.5.238:2379,172.31.14.43:2379 endpoint health
etcdctl --endpoints=172.31.7.43:2379 member list -w table
curl -s http://172.31.7.43:2379/version        # "etcdcluster" should be 3.5.0

# Who is the leader? (200 only on the leader)
curl -s -o /dev/null -w '%{http_code}\n' http://172.31.7.43:8008/primary
curl -s -o /dev/null -w '%{http_code}\n' http://172.31.5.238:8008/primary

# HAProxy
sudo systemctl status haproxy
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
# stats page: http://172.31.12.7:7000

# Connect through HAProxy
psql -h 172.31.12.7 -p 5000 -U appuser -d appdb -Atc "select inet_server_addr(), pg_is_in_recovery();"   # leader: f
psql -h 172.31.12.7 -p 5001 -U appuser -d appdb -Atc "select inet_server_addr(), pg_is_in_recovery();"   # replica: t
```

Cautions:

- **Never re-run `setup-pg-ha.sh` on a live node.** It wipes `/var/lib/etcd` and the PostgreSQL data directory. To recover a single node, restart its service (`patroni` or `etcd`) instead.
- Use the **version 18** client tools (`/usr/lib/postgresql/18/bin/...`) for dumps and restores. Older clients cannot dump a newer server.
- Do not stop two etcd members at once. With no quorum, the leader demotes itself.
- Change passwords for `postgres` or `replicator` in `/etc/patroni/config.yml` on **both** nodes, then restart Patroni one node at a time, replica first.

---

## 10. Configuration files

| File | Machine | Contents |
|---|---|---|
| `/etc/default/etcd` | node1, node2, witness | etcd member name, peer and client URLs, initial cluster |
| `/etc/patroni/config.yml` | node1, node2 | Cluster name (`pgcluster`), REST API, etcd hosts, PostgreSQL paths, replication and superuser credentials, `pg_hba` rules, timing parameters |
| `/etc/haproxy/haproxy.cfg` | HAProxy host | Pools on 5000 and 5001, health checks, stats page. Backups are saved as `haproxy.cfg.bak.<timestamp>` |
| `/var/lib/etcd` | node1, node2, witness | etcd data |
| `/var/lib/postgresql/18/main` | node1, node2 | PostgreSQL data (managed by Patroni) |

### Database objects

| Object | Value |
|---|---|
| Application database | `appdb` (owner `appuser`) |
| Application user | `appuser` |
| Superuser | `postgres` (used for administration only, not by the app) |
| Replication user | `replicator` (used by the replica to stream WAL) |
| `pg_hba` | Password (`scram-sha-256`) authentication from the VPC subnet only |

---

## 11. Recommended improvements

Priority order:

1. **Backups:** pgBackRest or WAL-G to S3, with a tested restore procedure.
2. **Rotate passwords:** `postgres`, `replicator`, `appuser` and the HAProxy stats password. Store them in a secret manager.
3. **Redundant HAProxy:** two hosts in different AZs behind an internal NLB.
4. **Spread across AZs:** node1, node2, witness and HAProxy in separate Availability Zones.
5. **Close the old database:** shut down the old server and close its public port 5432.
6. **TLS:** etcd, Patroni REST API and PostgreSQL (then enable `sslmode` in the app).
7. **Synchronous replication:** if losing the last commit on a crash is not acceptable.
8. **Monitoring and alerts:** Patroni `/metrics`, replication lag, disk space, etcd health, HAProxy backend status.
9. **Patroni watchdog:** so a hung primary is fenced.
10. **Regular failover drills:** at least once per quarter, with the real application.

---

## 12. Glossary

| Term | Meaning |
|---|---|
| **HA** | High availability: the service keeps running when a component fails |
| **Leader / Primary** | The node accepting writes |
| **Replica / Standby** | A node that streams changes from the leader and serves read-only queries |
| **Failover** | Automatic promotion of a replica after the leader fails |
| **Switchover** | A planned, controlled leader change |
| **Quorum** | A majority of etcd members (2 of 3) needed to make decisions |
| **Split-brain** | Two nodes both believing they are the primary. Quorum and the leader lock prevent it |
| **Witness** | A lightweight member that only provides a vote (here: an etcd-only VM) |
| **WAL** | Write-ahead log: the change stream used for replication |
| **TTL** | Time-to-live of the leader lock. It bounds how long a crashed leader blocks failover |
| **`pg_rewind`** | Tool that resynchronizes a former primary so it can rejoin as a replica |
| **DCS** | Distributed configuration store (etcd here) |