# PostgreSQL High Availability with Patroni + etcd (2 DB nodes + 1 witness)

Automatic failover for PostgreSQL on **3 VMs**. Works on AWS EC2 or bare metal.
This guide is based on a real, working build on Ubuntu 26.04 (PostgreSQL 18, Patroni 4.1.0, etcd 3.5.16), and includes every problem hit along the way and its fix.

---

## 1. Architecture

```
                      +-------------------+
   clients / apps --> | HAProxy / NLB     |  (routes to the current leader)
                      +---------+---------+
                                |  checks http://node:8008/primary
              +-----------------+-----------------+
              |                                   |
     +--------v---------+                +--------v---------+
     | node1            |  streaming     | node2            |
     | PostgreSQL       | <------------> | PostgreSQL       |
     | Patroni (:8008)  |  replication   | Patroni (:8008)  |
     | etcd (:2379/80)  |                | etcd (:2379/80)  |
     +--------+---------+                +--------+---------+
              \                                  /
               \          +-------------+       /
                +-------->| witness     |<-----+
                          | etcd only   |
                          +-------------+
```

| Component | Role |
|---|---|
| **PostgreSQL streaming replication** | Copies writes from the primary to the standby in real time |
| **Patroni** | Watches PostgreSQL, promotes the standby when the primary fails |
| **etcd (3 members)** | Consensus store that decides who is leader and prevents split-brain |
| **Witness VM** | Third etcd member, so 2 of 3 members can still form a quorum when one VM dies |
| **HAProxy / NLB / VIP** | Gives applications one address that always points to the leader |

**Why 3 VMs?** With only 2 etcd members, losing one VM means no quorum and no safe promotion. The witness only needs 1 vCPU / 1 GB RAM (for example `t3.micro`).

---

## 2. Example environment used in this guide

| Machine | Hostname | NODE_NAME | Private IP |
|---|---|---|---|
| DB node 1 | `ip-172-31-7-43` | `node1` | `172.31.7.43` |
| DB node 2 | `ip-172-31-5-238` | `node2` | `172.31.5.238` |
| Witness | `ip-172-31-14-43` | `witness` | `172.31.14.43` |

- Subnet / VPC CIDR: `172.31.0.0/16`
- OS: Ubuntu 24.04 or 26.04 (24.04 is the safest LTS choice)
- **Replace all IPs and passwords with your own.** Use **private** IPs only.

### How to find a machine's private IP

```bash
hostname -I
# or
ip -4 addr show
```

On EC2 you can also use the console (Instance, Details, **Private IPv4 addresses**) or the metadata service:

```bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4
```

---

## 3. Prerequisites (do these first, on all 3 machines)

### 3.1 Same VPC and subnet routing
All 3 VMs must reach each other by private IP. Use different Availability Zones (EC2) or different hosts/racks (bare metal) if you can.

### 3.2 Open ports between the 3 machines

| Port | Purpose |
|---|---|
| 22 | SSH (from your IP only) |
| 5432 | PostgreSQL |
| 8008 | Patroni REST API |
| 2379 | etcd client |
| 2380 | etcd peer |

On **AWS**: add inbound rules to the Security Group used by all 3 instances, with the source set to **the same Security Group** (or `172.31.0.0/16`).
On **bare metal**: use `ufw` or `firewalld`, for example:

```bash
sudo ufw allow from 172.31.0.0/16 to any port 5432,8008,2379,2380 proto tcp
```

Never expose 5432, 2379, 2380 or 8008 to the internet.

### 3.3 Check that `apt update` works (important)

```bash
sudo apt-get update
```

If you see an error like this:

```
Err: ... apt.postgresql.org ... resolute-pgdg InRelease
NO_PUBKEY 7FCC7D46ACCC4CF8
E: The repository ... is not signed.
```

the PostgreSQL PGDG repo was added without its key, and the setup script will stop on it. You don't need PGDG because Ubuntu's own repos have everything. Remove it:

```bash
grep -rl apt.postgresql.org /etc/apt/
sudo rm -f /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/pgdg.sources
sudo apt-get update      # must finish with no Err: / E: lines
```

If `grep` shows a different file, delete that one instead.

### 3.4 Python etcd module (needed by Patroni)

Patroni needs the Python module `etcd` for its etcd backend. The script installs it (`python3-etcd`). If you ever install by hand:

```bash
sudo apt-get install -y python3-etcd
```

(`python3-etcd3` is a **different** library and does **not** work. Patroni will report `Available implementations: consul, kubernetes`.)

---

## 4. Get the script onto all 3 machines

The script is in [Appendix A](#appendix-a--setup-pg-hash). Save it as `setup-pg-ha.sh` on each machine (for example `nano setup-pg-ha.sh`, paste, save; or `scp` it), then:

```bash
chmod +x setup-pg-ha.sh
bash -n setup-pg-ha.sh && echo "syntax OK"
```

All 3 machines use **the same script file**. Only the variables differ.

---

## 5. Variables cheat sheet

### Same on every machine

```bash
export NODE1_IP=172.31.7.43
export NODE2_IP=172.31.5.238
export WITNESS_IP=172.31.14.43
export SUBNET=172.31.0.0/16
```

### Different per machine

| Machine | ROLE | NODE_NAME | NODE_IP | Passwords needed? |
|---|---|---|---|---|
| node1 | `db` | `node1` | `172.31.7.43` | yes |
| node2 | `db` | `node2` | `172.31.5.238` | yes (same as node1) |
| witness | `witness` | `witness` | `172.31.14.43` | no |

### Passwords (node1 and node2 only, **identical on both**)

```bash
export REPL_PASSWORD='<strong-replication-password>'
export SUPERUSER_PASSWORD='<strong-postgres-password>'
```

Use strong passwords. Single quotes protect special characters.

### Optional variables (defaults shown)

| Variable | Default |
|---|---|
| `CLUSTER_NAME` | `pgcluster` |
| `ETCD_TOKEN` | `pg-etcd-cluster` |

---

## 6. Installation steps (run in this order)

> **Tip:** log in as root for the session (`sudo -i`) and `export` the variables there. This avoids the `sudo -E` problem described in the troubleshooting section. Also check your **prompt hostname** matches the machine you think you are on.

### Step 1: Witness (`ip-172-31-14-43`)

```bash
sudo -i
cd /home/ubuntu          # or wherever setup-pg-ha.sh is

export NODE1_IP=172.31.7.43
export NODE2_IP=172.31.5.238
export WITNESS_IP=172.31.14.43
export SUBNET=172.31.0.0/16

export ROLE=witness NODE_NAME=witness NODE_IP=172.31.14.43
./setup-pg-ha.sh
```

Expected last line: `==> Witness done.`
etcd may show as "waiting" or unhealthy until the other members start. That is normal.

### Step 2: Node 1 (`ip-172-31-7-43`), right after the witness (within about a minute)

```bash
sudo -i
cd /home/ubuntu

export NODE1_IP=172.31.7.43
export NODE2_IP=172.31.5.238
export WITNESS_IP=172.31.14.43
export SUBNET=172.31.0.0/16
export REPL_PASSWORD='<strong-replication-password>'
export SUPERUSER_PASSWORD='<strong-postgres-password>'

export ROLE=db NODE_NAME=node1 NODE_IP=172.31.7.43
./setup-pg-ha.sh
```

At this point node1 + witness are 2 of 3 etcd members (quorum). Patroni on node1 may still log etcd warnings until node2 joins. That is expected.

### Step 3: Node 2 (`ip-172-31-5-238`)

Wait about 30 seconds after node1, then:

```bash
sudo -i
cd /home/ubuntu

export NODE1_IP=172.31.7.43
export NODE2_IP=172.31.5.238
export WITNESS_IP=172.31.14.43
export SUBNET=172.31.0.0/16
export REPL_PASSWORD='<strong-replication-password>'      # same as node1
export SUPERUSER_PASSWORD='<strong-postgres-password>'    # same as node1

export ROLE=db NODE_NAME=node2 NODE_IP=172.31.5.238
./setup-pg-ha.sh
```

### Step 4: Verify etcd has all 3 members

```bash
curl -s http://172.31.7.43:2379/version; echo
etcdctl --endpoints=172.31.7.43:2379,172.31.5.238:2379,172.31.14.43:2379 endpoint health
```

You want `"etcdcluster":"3.5.0"` and 3 healthy endpoints.

> `"etcdcluster":"3.0.0"` simply means **not all members have joined yet**. Patroni misreads this and logs `404 ... /v3alpha`. It clears by itself after the third member joins. Do not wipe etcd for this.

### Step 5: Restart Patroni on any node that is stuck

If Patroni failed earlier (before etcd was complete), on that node:

```bash
sudo systemctl reset-failed patroni
sudo systemctl restart patroni
sleep 30
```

`reset-failed` clears systemd's "Start request repeated too quickly" block.

### Step 6: Check the cluster

```bash
patronictl -c /etc/patroni/config.yml list
```

Expected: one **Leader** and one **Replica** in `streaming` state, lag 0:

```
| Member | Host         | Role    | State     | TL | Lag |
| node1  | 172.31.7.43  | Replica | streaming |  2 |   0 |
| node2  | 172.31.5.238 | Leader  | running   |  2 |     |
```

Whichever node wins the election first becomes Leader, so either node1 or node2 can be Leader. Both are fine.

---

## 7. Verification

```bash
# Which node answers as primary? (200 = leader, 503 = replica)
curl -s -o /dev/null -w '%{http_code}\n' http://172.31.7.43:8008/primary
curl -s -o /dev/null -w '%{http_code}\n' http://172.31.5.238:8008/primary

# Replication status (run against the leader's IP)
PGPASSWORD='<postgres-password>' psql -h <leader-ip> -U postgres \
  -c "select client_addr, state, sync_state from pg_stat_replication;"

# Write on the leader, read on the replica
PGPASSWORD='<postgres-password>' psql -h <leader-ip> -U postgres \
  -c "create table if not exists ha_test(id int, ts timestamptz default now()); insert into ha_test values (1);"
PGPASSWORD='<postgres-password>' psql -h <replica-ip> -U postgres -c "select * from ha_test;"

# etcd members
etcdctl --endpoints=172.31.7.43:2379 member list -w table
```

---

## 8. Failover tests

### 8.1 Planned switchover (zero surprise)

```bash
patronictl -c /etc/patroni/config.yml switchover
```

Choose the current leader, the candidate and `now`. Then run `patronictl ... list` to see the roles swap.

### 8.2 Unplanned failure (the real test)

On the **current Leader**:

```bash
sudo systemctl stop patroni
```

On the other node:

```bash
watch -n 2 patronictl -c /etc/patroni/config.yml list
```

Within about 30 seconds (`ttl: 30`) the surviving node becomes Leader. Bring the old leader back:

```bash
sudo systemctl start patroni
```

It rejoins as a Replica automatically (using `pg_rewind` if needed).

### 8.3 Hard crash

Stop or reboot the Leader's EC2 instance (or power off the VM). The surviving DB node plus the witness still have etcd quorum (2 of 3), so the survivor is promoted.

### 8.4 etcd member loss

Stop etcd on **one** machine (`sudo systemctl stop etcd`). The cluster must keep working. Start it again afterward. Stopping **two** etcd members will make the cluster read-only. That is the expected safety behavior.

---

## 9. Client routing (how applications find the leader)

Patroni's REST API returns **200 only on the leader** at `GET :8008/primary` (and `/replica` for replicas).

### Option A: HAProxy (works on EC2 and bare metal)

Install on a separate host or on the app servers:

```bash
sudo apt-get install -y haproxy
```

Add to `/etc/haproxy/haproxy.cfg`:

```
listen postgres_primary
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 172.31.7.43:5432 check port 8008
    server node2 172.31.5.238:5432 check port 8008

listen postgres_replica
    bind *:5001
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 172.31.7.43:5432 check port 8008
    server node2 172.31.5.238:5432 check port 8008
```

```bash
sudo systemctl reload haproxy
```

Apps connect to `haproxy-host:5000` (writes) or `:5001` (read-only). Run HAProxy on two hosts behind keepalived or an NLB so the proxy is not a new single point of failure.

### Option B: AWS Network Load Balancer
Target group on port 5432 with an **HTTP health check on port 8008, path `/primary`**.

### Option C: Virtual IP (bare metal / same L2 network)
Use `vip-manager` (reads the leader key from etcd) or `keepalived` with a check script against `:8008/primary`. A floating VIP does not work well across EC2 availability zones.

---

## 10. Troubleshooting (problems seen in this build)

| Symptom | Cause | Fix |
|---|---|---|
| `sudo: preserving the entire environment is not supported, '-E' is ignored` | You are already root, or the system uses `sudo-rs` | Run as root with `sudo -i` and `export` the variables, or use `sudo env VAR=... ./setup-pg-ha.sh` |
| `unexpected EOF while looking for matching '"'` | Old copy of the script with an apostrophe in a `${VAR:?...}` message | Use the script in Appendix A, or run `bash -n setup-pg-ha.sh` to check syntax |
| `./setup-pg-ha.shNODE1_IP=...: No such file` | The command was pasted twice and joined | Paste the command once |
| Ran the node1 command on node2's machine | Prompt hostname not checked | Match the prompt (`ip-172-31-...`) to the machine table in section 2 |
| `NO_PUBKEY ... pgdg ... repository is not signed` | PGDG repo present without key | Section 3.3 |
| Patroni: `Failed to import patroni.dcs.etcd3 ... Available implementations: consul, kubernetes` | `python3-etcd` missing | `sudo apt-get install -y python3-etcd`, then `systemctl reset-failed patroni && systemctl restart patroni` |
| Patroni: `Start request repeated too quickly` | systemd rate limit after repeated failures | `sudo systemctl reset-failed patroni` then restart |
| Patroni: `Detected Etcd version 3.0.0 ... 404 .../v3alpha` | etcd cluster version stays 3.0.0 until all 3 members have joined | Finish setting up the third machine, wait a minute, restart Patroni |
| etcd log: `connection refused` to a peer on 2380 | That peer's etcd is not running yet, or the port is blocked | Start that node, or open port 2380 in the Security Group |
| Patroni waits on etcd forever | No quorum (fewer than 2 etcd members up) | Check `etcdctl endpoint health`, start witness/node1/node2 etcd |
| `pg_lsclusters: not found` during apt install | Harmless message from debconf | Ignore it |

### Useful logs and status commands

```bash
sudo journalctl -u patroni -n 50 --no-pager
sudo journalctl -u etcd -n 50 --no-pager
sudo systemctl status patroni etcd --no-pager
patronictl -c /etc/patroni/config.yml list
patronictl -c /etc/patroni/config.yml history
```

---

## 11. Rebuilding from scratch

> **Warning:** this destroys all data in the cluster. The setup script itself also wipes `/var/lib/etcd` and the default PostgreSQL cluster, so **never re-run it on a live or populated node**.

On **node1 and node2**:

```bash
sudo systemctl stop patroni
sudo rm -rf /var/lib/postgresql/18/main      # use 16 on Ubuntu 24.04
```

Remove the cluster key from etcd (once, from any DB node, while etcd is still running):

```bash
patronictl -c /etc/patroni/config.yml remove pgcluster
```

Then on **all 3 machines**, stop and wipe etcd:

```bash
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd/*
```

Now start again from section 6, step 1.

To restart only a **single failed node** without rebuilding, just `sudo systemctl restart patroni` (or `etcd`). Do not re-run the full script.

---

## 12. Production hardening checklist

- [ ] **Change test passwords.** Use strong values in `/etc/patroni/config.yml`, and rotate the `postgres` and `replicator` passwords.
- [ ] **Backups.** HA is not a backup. Set up pgBackRest or WAL-G to S3 or other storage, and test restores.
- [ ] **Synchronous replication** (no data loss on failover, slightly higher write latency): `patronictl -c /etc/patroni/config.yml edit-config` and set `synchronous_mode: true`.
- [ ] **TLS** for etcd (2379/2380), the Patroni REST API (8008) and PostgreSQL.
- [ ] **etcd authentication** enabled.
- [ ] **Restrict `pg_hba`** from the whole subnet to specific app hosts or proxies.
- [ ] **Monitoring** for Patroni (`/metrics`), replication lag, etcd health and disk space.
- [ ] **Watchdog** (`softdog` or `/dev/watchdog`) so a hung primary is fenced.
- [ ] **Security Groups** allow 5432 only from app hosts, never the public internet.
- [ ] **Spread VMs** across availability zones or racks.
- [ ] Test failover **regularly**, not just once.

---

## Appendix A: `setup-pg-ha.sh`

<a id="appendix-a--setup-pg-hash"></a>

Run as root on each machine. Behavior depends on `ROLE`. It installs packages, configures etcd, and (on DB nodes) prepares PostgreSQL and starts Patroni.

```bash
#!/usr/bin/env bash
# PostgreSQL HA: Patroni + etcd on 2 DB nodes + 1 witness (etcd only)
# Works on EC2 or bare metal VMs. Tested layout: Ubuntu 22.04 / 24.04 / 26.04.
#
# Usage (run as root on each machine):
#   Node 1:   ROLE=db      NODE_NAME=node1   NODE_IP=10.0.0.11 ./setup-pg-ha.sh
#   Node 2:   ROLE=db      NODE_NAME=node2   NODE_IP=10.0.0.12 ./setup-pg-ha.sh
#   Witness:  ROLE=witness NODE_NAME=witness NODE_IP=10.0.0.13 ./setup-pg-ha.sh
#
# Required env on db nodes (SAME values on both):
#   REPL_PASSWORD=...  SUPERUSER_PASSWORD=...
#
# Order: run the witness and node1 close together, then node2 about 30s later.

set -euo pipefail

: "${ROLE:?set ROLE=db or ROLE=witness}"
: "${NODE_NAME:?set NODE_NAME to node1, node2 or witness}"
: "${NODE_IP:?set NODE_IP to the private IP of this machine}"

# ---- cluster layout (edit to match your network) ----
NODE1_IP="${NODE1_IP:-10.0.0.11}"
NODE2_IP="${NODE2_IP:-10.0.0.12}"
WITNESS_IP="${WITNESS_IP:-10.0.0.13}"
SUBNET="${SUBNET:-10.0.0.0/24}"          # who may connect to Postgres
CLUSTER_NAME="${CLUSTER_NAME:-pgcluster}"
ETCD_TOKEN="${ETCD_TOKEN:-pg-etcd-cluster}"

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)." >&2; exit 1; fi

if [[ "$ROLE" == "db" ]]; then
  : "${REPL_PASSWORD:?set REPL_PASSWORD}"
  : "${SUPERUSER_PASSWORD:?set SUPERUSER_PASSWORD}"
fi

echo "==> [1/5] Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y chrony etcd-server etcd-client
if [[ "$ROLE" == "db" ]]; then
  apt-get install -y postgresql postgresql-contrib patroni python3-etcd || \
  apt-get install -y postgresql postgresql-contrib patroni
fi
systemctl enable --now chrony

echo "==> [2/5] Configuring etcd"
systemctl stop etcd || true
rm -rf /var/lib/etcd/*   # fresh cluster; remove this line if re-running on a live cluster
cat > /etc/default/etcd <<EOF
ETCD_NAME="${NODE_NAME}"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_LISTEN_PEER_URLS="http://${NODE_IP}:2380"
ETCD_LISTEN_CLIENT_URLS="http://${NODE_IP}:2379,http://127.0.0.1:2379"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://${NODE_IP}:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://${NODE_IP}:2379"
ETCD_INITIAL_CLUSTER="node1=http://${NODE1_IP}:2380,node2=http://${NODE2_IP}:2380,witness=http://${WITNESS_IP}:2380"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="${ETCD_TOKEN}"
EOF
systemctl enable etcd
systemctl restart etcd &   # backgrounded: it blocks until a peer joins
sleep 5

if [[ "$ROLE" == "witness" ]]; then
  echo "==> Witness done. Verify once all 3 etcd members are up:"
  echo "    etcdctl --endpoints=${NODE1_IP}:2379,${NODE2_IP}:2379,${WITNESS_IP}:2379 endpoint health"
  exit 0
fi

echo "==> [3/5] Preparing PostgreSQL (Patroni will manage it)"
systemctl stop postgresql || true
systemctl disable postgresql || true
PGVER="$(ls /usr/lib/postgresql | sort -V | tail -n1)"
# remove the default cluster so Patroni can initdb into an empty dir
pg_dropcluster --stop "$PGVER" main 2>/dev/null || true
rm -rf "/var/lib/postgresql/${PGVER}/main"
echo "    PostgreSQL version: ${PGVER}"

echo "==> [4/5] Writing Patroni config"
mkdir -p /etc/patroni
cat > /etc/patroni/config.yml <<EOF
scope: ${CLUSTER_NAME}
name: ${NODE_NAME}

restapi:
  listen: 0.0.0.0:8008
  connect_address: ${NODE_IP}:8008

etcd3:
  hosts: ${NODE1_IP}:2379,${NODE2_IP}:2379,${WITNESS_IP}:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: "on"
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - local all all scram-sha-256
    - host all all 127.0.0.1/32 scram-sha-256
    - host replication replicator ${SUBNET} scram-sha-256
    - host all all ${SUBNET} scram-sha-256

postgresql:
  listen: 0.0.0.0:5432
  connect_address: ${NODE_IP}:5432
  data_dir: /var/lib/postgresql/${PGVER}/main
  bin_dir: /usr/lib/postgresql/${PGVER}/bin
  pgpass: /tmp/pgpass
  authentication:
    replication:
      username: replicator
      password: "${REPL_PASSWORD}"
    superuser:
      username: postgres
      password: "${SUPERUSER_PASSWORD}"

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
  nosync: false
EOF
chown postgres:postgres /etc/patroni/config.yml
chmod 600 /etc/patroni/config.yml

echo "==> [5/5] Starting Patroni"
systemctl enable patroni
systemctl restart patroni

cat <<EOF

Done on ${NODE_NAME}.
 - Start order: node1 first, wait ~30s, then node2.
 - Check:    patronictl -c /etc/patroni/config.yml list
 - Logs:     journalctl -u patroni -f
 - Primary check (200 only on leader): curl -s -o /dev/null -w '%{http_code}\n' http://${NODE_IP}:8008/primary
EOF
```

---

## Appendix B: What the script configures

| File | Purpose |
|---|---|
| `/etc/default/etcd` | etcd member name, peer/client URLs and the 3-member initial cluster |
| `/etc/patroni/config.yml` | Patroni cluster name, REST API, etcd hosts, PostgreSQL paths, replication and superuser credentials, `pg_hba` rules |
| `/var/lib/etcd` | etcd data (cluster state) |
| `/var/lib/postgresql/<ver>/main` | PostgreSQL data directory, created by Patroni, not by apt |

Key Patroni timings (in `config.yml`):

| Setting | Value | Meaning |
|---|---|---|
| `ttl` | 30 | Seconds before a silent leader loses its lock, which sets the failover time |
| `loop_wait` | 10 | Seconds between Patroni checks |
| `retry_timeout` | 10 | Seconds to retry etcd or PostgreSQL operations |
| `maximum_lag_on_failover` | 1048576 | A replica more than 1 MB behind is not promoted |
| `use_pg_rewind` | true | Lets a former primary rejoin as a replica |

---

## Quick command reference

```bash
# cluster state
patronictl -c /etc/patroni/config.yml list
patronictl -c /etc/patroni/config.yml switchover
patronictl -c /etc/patroni/config.yml restart pgcluster node1
patronictl -c /etc/patroni/config.yml reinit pgcluster node2   # rebuild a broken replica
patronictl -c /etc/patroni/config.yml edit-config              # change cluster-wide settings

# services
sudo systemctl status patroni etcd
sudo systemctl restart patroni
sudo journalctl -u patroni -f

# etcd
etcdctl --endpoints=172.31.7.43:2379,172.31.5.238:2379,172.31.14.43:2379 endpoint health
etcdctl --endpoints=172.31.7.43:2379 member list -w table

# who is the leader?
curl -s -o /dev/null -w '%{http_code}\n' http://172.31.7.43:8008/primary
```