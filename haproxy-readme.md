# HAProxy for a Patroni PostgreSQL HA Cluster

This sets up **HAProxy on a separate EC2 / VM** so applications have one stable address that always points to the current PostgreSQL leader, even after a failover.

It is the routing layer for the Patroni + etcd cluster described in `postgresql-ha-patroni-guide.md`.

| File | Purpose |
|---|---|
| `setup-haproxy.sh` | Installs and configures HAProxy automatically |
| `README-haproxy.md` | This document |

---

## 1. How it works

```
   apps (k3s pods, servers, ...)
              |
              v
   +----------------------+
   |  HAProxy host        |
   |   :5000  leader      |  reads + writes
   |   :5001  replicas    |  read-only (optional)
   |   :7000  stats page  |  (optional)
   +----------+-----------+
              |   health checks: http://<node>:8008/primary  and  /replica
      +-------+--------+
      v                v
   node1             node2
   PostgreSQL :5432  PostgreSQL :5432
   Patroni    :8008  Patroni    :8008
```

- Patroni's REST API returns **HTTP 200 on `/primary` only on the leader**, and 200 on `/replica` only on healthy replicas.
- HAProxy checks port 8008 on both nodes every 3 seconds and sends traffic only to the node that answers 200.
- When Patroni promotes the other node, HAProxy notices within about 10 seconds, drops the old connections, and routes new ones to the new leader.

### Ports

| Port | Pool | Used for |
|---|---|---|
| **5000** | `postgres_primary` | Writes and reads (leader only) |
| **5001** | `postgres_replica` | Read-only queries (replicas only, optional) |
| **7000** | stats page | Monitoring in a browser (optional, password protected) |

---

## 2. Prerequisites

- The Patroni cluster is already running (`patronictl -c /etc/patroni/config.yml list` shows one Leader and one Replica).
- A **separate** EC2 / VM for HAProxy, in the same VPC (or network) as the DB nodes. A `t3.micro` or `t3.small` is enough.
- Ubuntu 22.04, 24.04 or 26.04, with root or sudo access.
- The private IPs of both DB nodes. On a node, run `hostname -I` or `ip -4 addr show`.

Example values used in this README (replace them with yours):

| Machine | Private IP |
|---|---|
| DB node 1 | `172.31.7.43` |
| DB node 2 | `172.31.5.238` |
| HAProxy host | `172.31.x.x` (its own private IP) |

---

## 3. Security Groups / firewall (do this first)

| On | Allow inbound | From |
|---|---|---|
| **HAProxy host** | TCP **5000** (and **5001** if used) | your app hosts, for example the k3s node Security Group or CIDR |
| **HAProxy host** | TCP **7000** | your own IP only |
| **HAProxy host** | TCP **22** | your own IP only |
| **node1 and node2** | TCP **5432** and **8008** | the HAProxy host's Security Group or private IP |

Important:

- If HAProxy cannot reach port **8008** on the DB nodes, every health check fails and HAProxy marks **both** nodes DOWN.
- If your DB nodes currently allow ports only "from the same Security Group", add a rule for the HAProxy host's Security Group (or its IP).
- Never open 5432 or 8008 to the internet. Apps should connect to HAProxy, not directly to the DB nodes.

---

## 4. What to replace

All values are in the block at the top of `setup-haproxy.sh`, marked `REPLACE THESE VALUES WITH YOUR OWN`.

| Variable | Replace with | Example |
|---|---|---|
| `NODE1_IP` | Private IP of DB node 1 | `172.31.7.43` |
| `NODE2_IP` | Private IP of DB node 2 | `172.31.5.238` |
| `STATS_PASS` | A password for the stats page | `S0me-Str0ng-Pass` |

Optional variables (defaults are fine for most setups):

| Variable | Default | Meaning |
|---|---|---|
| `NODE1_NAME` / `NODE2_NAME` | `node1` / `node2` | Labels shown on the stats page |
| `PG_PORT` | `5432` | PostgreSQL port on the DB nodes |
| `PATRONI_PORT` | `8008` | Patroni REST API port |
| `WRITE_PORT` | `5000` | HAProxy leader port |
| `READ_PORT` | `5001` | HAProxy replica port |
| `STATS_PORT` | `7000` | HAProxy stats port |
| `STATS_USER` | `admin` | Stats page username |
| `ENABLE_READ_POOL` | `true` | Set `false` to skip port 5001 |
| `ENABLE_STATS` | `true` | Set `false` to skip the stats page |

---

## 5. Install

Copy `setup-haproxy.sh` to the HAProxy host (with `scp`, or paste it into `nano setup-haproxy.sh`).

### Option A: edit the file, then run

```bash
nano setup-haproxy.sh          # change NODE1_IP, NODE2_IP, STATS_PASS
chmod +x setup-haproxy.sh
sudo ./setup-haproxy.sh
```

### Option B: pass values on the command line (no editing)

Become root first, so the variables reach the script:

```bash
sudo -i
cd /home/ubuntu                # folder that contains setup-haproxy.sh

NODE1_IP=172.31.7.43 NODE2_IP=172.31.5.238 STATS_PASS='<your-password>' ./setup-haproxy.sh
```

Not root? Use `sudo env`:

```bash
sudo env NODE1_IP=172.31.7.43 NODE2_IP=172.31.5.238 STATS_PASS='<your-password>' ./setup-haproxy.sh
```

> On recent Ubuntu versions `sudo -E` may be ignored (`sudo-rs`), so `sudo -i` or `sudo env` is the reliable way.

### What the script does

1. Installs HAProxy.
2. Backs up any existing `/etc/haproxy/haproxy.cfg` to `haproxy.cfg.bak.<timestamp>`.
3. Writes the new config (leader pool, optional replica pool, optional stats page).
4. Validates it with `haproxy -c`, then enables and restarts the service.

It also checks that both IPs look valid, and warns if the stats password is still the placeholder.

---

## 6. Verify

### 6.1 Service is running

```bash
sudo systemctl status haproxy --no-pager
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo ss -tlnp | grep haproxy        # should show 5000, 5001, 7000
```

### 6.2 Connect through HAProxy

Run this from a machine that is allowed to reach the HAProxy host (`psql` needs `postgresql-client`):

```bash
export PGPASSWORD='<postgres-password>'

# Leader pool: expect the leader IP and "f"
psql -h <haproxy-ip> -p 5000 -U postgres -Atc "select inet_server_addr(), pg_is_in_recovery();"

# Replica pool: expect the replica IP and "t"
psql -h <haproxy-ip> -p 5001 -U postgres -Atc "select inet_server_addr(), pg_is_in_recovery();"
```

| Port | `pg_is_in_recovery()` | Meaning |
|---|---|---|
| 5000 | `f` (false) | You are on the leader |
| 5001 | `t` (true) | You are on a replica |

### 6.3 Stats page

Open `http://<haproxy-ip>:7000` and log in with `STATS_USER` / `STATS_PASS`.

- In `postgres_primary`: the **leader is green, the replica is red**.
- In `postgres_replica`: the **replica is green, the leader is red**.

The red entries are normal. They are the health checks (`/primary` or `/replica`) correctly returning 503 for the other role.

---

## 7. Test failover through HAProxy

In one terminal, run a continuous writer against HAProxy:

```bash
export PGPASSWORD='<postgres-password>'

psql -h <haproxy-ip> -p 5000 -U postgres -c "create table if not exists ha_test(id serial primary key, ts timestamptz default now(), host text);"

while true; do
  psql -h <haproxy-ip> -p 5000 -U postgres -Atc "insert into ha_test(host) values (inet_server_addr()::text) returning id, host;" \
    || echo "$(date +%T) WRITE FAILED"
  sleep 1
done
```

In another terminal, stop Patroni on the **current leader**:

```bash
sudo systemctl stop patroni
```

Expected:

- A few `WRITE FAILED` lines (about 10 to 30 seconds with a hard crash, less with a graceful stop).
- Writes resume automatically, now showing the **other node's IP**.
- The stats page shows the green and red nodes swapping.

Bring the old leader back with `sudo systemctl start patroni`. It rejoins as a replica.

---

## 8. Connecting your applications

Point apps at the HAProxy host instead of a DB node:

```
host=<haproxy-private-ip>  port=5000
```

Connection string:

```
postgresql://user:password@<haproxy-private-ip>:5000/mydb
```

For read-only workloads (reports, dashboards), use port **5001**.

### From k3s / Kubernetes

Use the HAProxy host's private IP directly as the database host. For a cleaner setup, create a Service with no selector and a manual Endpoints object, so pods can use a DNS name:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  ports:
    - port: 5432
      targetPort: 5000
---
apiVersion: v1
kind: Endpoints
metadata:
  name: postgres
subsets:
  - addresses:
      - ip: <haproxy-private-ip>
    ports:
      - port: 5000
```

Pods then connect to `postgres:5432` (inside the same namespace).

### Tips for application connections

- Failover **drops existing connections**. Make sure your app or connection pool reconnects and retries.
- HAProxy closes connections idle for more than 30 minutes (`timeout client/server 30m`). Use pool keepalive or a shorter pool idle timeout.
- Avoid very long transactions across a failover. They are rolled back when the leader changes.

---

## 9. Make HAProxy itself highly available

A single HAProxy host is a single point of failure: if it dies, apps lose database access even though the cluster is healthy.

| Option | Notes |
|---|---|
| **Single host + EC2 auto-recovery** | Enable the instance auto-recovery alarm (or an Auto Scaling group of size 1). Cheap, with a short outage if it fails. Fine for dev/test. |
| **Two HAProxy hosts behind an NLB** | Run this script on two hosts (ideally different AZs). Put an **internal** NLB in front: TCP listener to a target group on port 5000 with a plain TCP health check. |
| **Two HAProxy hosts with keepalived (VIP)** | Works in a single subnet/AZ. A floating IP does not move easily across AZs on AWS. |
| **HAProxy on every app host** | Run it as a sidecar/DaemonSet. No shared point of failure, but more to manage. |

Both HAProxy hosts use the **same config**. Just run `setup-haproxy.sh` on each.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Stats page shows **both nodes red** in `postgres_primary` | HAProxy cannot reach port 8008 on the DB nodes | Allow TCP 8008 (and 5432) from the HAProxy host in the DB nodes' Security Group |
| `psql` to port 5000 hangs or times out | App host not allowed to reach HAProxy on 5000 | Add the inbound rule on the HAProxy Security Group |
| `psql` to port 5000 says `connection refused` | HAProxy not running, or wrong port | `sudo systemctl status haproxy`, `sudo ss -tlnp | grep haproxy` |
| `psql` through HAProxy: `password authentication failed` | Wrong password, or `pg_hba` does not allow the HAProxy IP | Check the password. The Patroni `pg_hba` must allow the subnet that contains the HAProxy host (`SUBNET` in the cluster setup) |
| Port 5000 connects but lands on a **replica** | `/primary` check not applied | Confirm the config has `option httpchk GET /primary` and `http-check expect status 200` |
| Port 5001 has **no healthy server** | No replica is healthy, or only one node exists | `patronictl list`; a replica must be `streaming` |
| Writes fail for a long time after failover | Patroni has not promoted yet, or etcd lost quorum | `patronictl -c /etc/patroni/config.yml list`, `etcdctl ... endpoint health` |
| `haproxy -c` reports an error | Typo in the config | Read the error line, or restore the backup (see below) |
| Script says `not a valid IPv4 address` | `NODE1_IP` / `NODE2_IP` not set correctly | Edit the values or pass them on the command line |

Useful commands:

```bash
sudo journalctl -u haproxy -n 50 --no-pager
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
curl -s -o /dev/null -w '%{http_code}\n' http://172.31.7.43:8008/primary     # 200 on the leader
curl -s -o /dev/null -w '%{http_code}\n' http://172.31.5.238:8008/primary    # 503 on the replica
```

Run those `curl` checks **from the HAProxy host**. If they time out there, the problem is the Security Group, not HAProxy.

---

## 11. Maintenance

### Change the DB node IPs or settings
Edit the variables, then re-run the script. It is safe to re-run: it backs up the old config and rewrites it.

```bash
sudo ./setup-haproxy.sh
```

### Reload after a manual config edit

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
```

### Restore a previous config

```bash
ls /etc/haproxy/haproxy.cfg.bak.*
sudo cp /etc/haproxy/haproxy.cfg.bak.<timestamp> /etc/haproxy/haproxy.cfg
sudo systemctl restart haproxy
```

### Uninstall

```bash
sudo systemctl disable --now haproxy
sudo apt-get remove --purge -y haproxy
```

---

## 12. Security checklist

- [ ] Stats password changed from the placeholder (or stats disabled)
- [ ] Port 7000 allowed from your own IP only
- [ ] Ports 5000/5001 allowed only from your app hosts, never `0.0.0.0/0`
- [ ] DB nodes allow 5432/8008 only from the HAProxy host(s) and each other
- [ ] Strong PostgreSQL passwords (not the test values)
- [ ] TLS between apps and PostgreSQL (HAProxy runs in TCP mode, so it passes TLS through untouched)
- [ ] A second HAProxy host or auto-recovery for production