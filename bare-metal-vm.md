# PostgreSQL High Availability on Bare Metal / On-Prem VMs

A complete, detailed guide for building an automatic-failover PostgreSQL cluster (Patroni + etcd + HAProxy + keepalived) on **bare metal servers or on-premises VMs** (VMware, Proxmox, KVM, Hyper-V and so on), with no cloud services.

It is the on-prem counterpart of `postgresql-ha-patroni-guide.md` (AWS EC2). The database layer is identical. What changes is networking, the floating address, firewalling, backups and hardware planning. Lessons learned from a real build are included.

---

## Contents

1. [What changes compared with AWS](#1-what-changes-compared-with-aws)
2. [Architecture](#2-architecture)
3. [Planning: hosts, IPs, sizing](#3-planning-hosts-ips-sizing)
4. [Prepare every machine](#4-prepare-every-machine)
5. [Install the cluster (Patroni + etcd)](#5-install-the-cluster-patroni--etcd)
6. [Verify the cluster](#6-verify-the-cluster)
7. [Client routing: HAProxy + keepalived VIP](#7-client-routing-haproxy--keepalived-vip)
8. [Alternative routing options](#8-alternative-routing-options)
9. [Failover tests](#9-failover-tests)
10. [Application settings](#10-application-settings)
11. [Backups](#11-backups)
12. [Security hardening](#12-security-hardening)
13. [Monitoring](#13-monitoring)
14. [Maintenance procedures](#14-maintenance-procedures)
15. [Disaster scenarios](#15-disaster-scenarios)
16. [Troubleshooting](#16-troubleshooting)
17. [Final checklist](#17-final-checklist)
18. [Appendix A: setup-pg-ha.sh](#appendix-a-setup-pg-hash)
19. [Appendix B: reference configs](#appendix-b-reference-configs)

---

## 1. What changes compared with AWS

| Topic | AWS EC2 | Bare metal / on-prem |
|---|---|---|
| Firewall | Security Groups | `ufw`, `nftables` or `firewalld` on every host |
| Client entry point | NLB, or Route 53 | **HAProxy pair + keepalived floating IP (VIP)**, or vip-manager |
| Floating IP | Does not move across AZs | Works on one L2 network (same VLAN/subnet) |
| Failure domains | Availability Zones | **Physical hosts, racks, power feeds** |
| IP addressing | DHCP private IPs | **Static IPs** you assign (netplan) |
| Time | Amazon time service | **chrony to your NTP servers** (critical for etcd) |
| Storage | EBS | Local SSD/NVMe, SAN or hypervisor datastore |
| Backups | S3 | NFS, a backup server, or MinIO (S3 compatible) |
| Fencing | Instance stop via API | Watchdog (`softdog` or a hardware watchdog) |
| Hypervisor risks | None | Snapshots, live migration, host failure, VM placement |

The Patroni, etcd and PostgreSQL parts do not change.

---

## 2. Architecture

```
                  +----------------------------------+
                  |   Applications (app servers,     |
                  |   Kubernetes, etc.)              |
                  +----------------+-----------------+
                                   |
                                   |  db host = VIP 192.168.10.20
                                   |  :5000 leader   :5001 replicas
                                   v
              +--------------------+---------------------+
              |           keepalived floating VIP        |
              |              192.168.10.20               |
              +----------+--------------------+----------+
                         |                    |
            +------------v-----+      +-------v----------+
            | haproxy1         |      | haproxy2         |
            | 192.168.10.21    |      | 192.168.10.22    |
            | keepalived MASTER|      | keepalived BACKUP|
            +--------+---------+      +---------+--------+
                     \                        /
                      \  health: GET :8008/primary  /replica
                       +----------+-----------+
                                  |
                +-----------------+-------------------+
                |                                     |
     +----------v-----------+            +------------v---------+
     | node1 192.168.10.11  |  streaming | node2 192.168.10.12  |
     | PostgreSQL     :5432 |<---------->| PostgreSQL     :5432 |
     | Patroni        :8008 | replication| Patroni        :8008 |
     | etcd      :2379/2380 |            | etcd      :2379/2380 |
     +----------+-----------+            +------------+---------+
                |                                      |
                +-------------------+------------------+
                                    | etcd peer :2380
                          +---------v----------+
                          | witness            |
                          | 192.168.10.13      |
                          | etcd only          |
                          +--------------------+
```

| Component | Count | Role |
|---|---|---|
| PostgreSQL 18 + Patroni + etcd | 2 (node1, node2) | Database, leader election |
| Witness (etcd only) | 1 | Third vote so quorum survives one failure |
| HAProxy + keepalived | 2 | One stable address that always points to the leader |

**Why a witness?** etcd needs a majority. With 2 members, losing one leaves no majority, so nothing can be promoted safely. Three members tolerate one failure.

**Small-lab shortcut:** you can run HAProxy and keepalived on the **witness** and one DB node, or even on both DB nodes, to save VMs. That ties proxy availability to database hosts, so use dedicated proxy VMs for production.

---

## 3. Planning: hosts, IPs, sizing

### 3.1 Example addressing (replace with yours)

| Machine | Hostname | IP | Runs |
|---|---|---|---|
| DB node 1 | `pg-node1` | `192.168.10.11` | PostgreSQL, Patroni, etcd |
| DB node 2 | `pg-node2` | `192.168.10.12` | PostgreSQL, Patroni, etcd |
| Witness | `pg-witness` | `192.168.10.13` | etcd |
| Proxy 1 | `pg-proxy1` | `192.168.10.21` | HAProxy, keepalived |
| Proxy 2 | `pg-proxy2` | `192.168.10.22` | HAProxy, keepalived |
| **VIP** | none | `192.168.10.20` | Floats between proxy1 and proxy2 |

Subnet: `192.168.10.0/24`, gateway `192.168.10.1`. All machines are on the same L2 segment (needed for the VIP).

The Patroni **node names** used in the cluster are `node1` and `node2` (set with `NODE_NAME`), independent of the hostnames.

### 3.2 Sizing guide

| Role | vCPU | RAM | Disk | Notes |
|---|---|---|---|---|
| DB node | 4 or more | 8 GB or more | SSD/NVMe sized for data plus WAL, with headroom | The same specs on both nodes, so either can be leader |
| Witness | 1 | 1 GB | 10 GB | etcd needs a low-latency disk |
| Proxy | 1 to 2 | 1 to 2 GB | 10 GB | Light load |

- Use **fast local storage** (SSD/NVMe) for DB nodes and the etcd disk. etcd is very sensitive to disk latency (slow fsync causes leader flapping).
- Keep at least 30 percent disk free. A full disk stops PostgreSQL, and WAL accumulates if a replica is down.
- Optional: a separate disk or mount for WAL (`pg_wal`) on busy systems.

### 3.3 Failure domains (the most important on-prem decision)

| Rule | Why |
|---|---|
| **node1 and node2 on different physical hosts** | One host failure must not take both |
| **Witness on a third host (or at least not the same one as a DB node)** | Otherwise one host failure removes 2 of 3 etcd votes and the cluster stops |
| proxy1 and proxy2 on different hosts | Same reason |
| Different racks, power feeds and switches when possible | Wider fault tolerance |
| **Hypervisor anti-affinity rules** | Prevents DRS/HA from placing both DB VMs on one host |

If everything lives on one physical server, the cluster protects against software and VM failures only, not hardware failure.

### 3.4 Hypervisor cautions

- **Never restore an etcd VM from a snapshot.** An old etcd state can corrupt the cluster. Use `etcdctl snapshot` backups instead (section 11).
- **Do not roll back a DB node VM from a snapshot** either. Rebuild the node from the leader (`patronictl reinit`).
- Avoid snapshots held open for long on DB VMs (performance, disk growth).
- Live migration or vMotion pauses can look like a failure to Patroni (the TTL is 30 seconds). Keep pauses short, or run `patronictl pause` before planned host maintenance.
- Use the paravirtualized disk and network drivers (virtio, vmxnet3, pvscsi).
- Make sure the hypervisor does not overcommit CPU or RAM on DB VMs. Ballooning and swapping cause latency spikes that trigger failovers.

---

## 4. Prepare every machine

Run on **all 5 machines** unless noted. Use Ubuntu Server 24.04 LTS or 26.04. (Notes for RHEL-family systems are in section 4.9.)

### 4.1 Static IP (netplan)

`/etc/netplan/01-static.yaml` (interface name varies: `ens18`, `ens192`, `eth0`; check with `ip -br a`). Example for node1:

```yaml
network:
  version: 2
  ethernets:
    ens18:
      dhcp4: false
      addresses: [192.168.10.11/24]
      routes:
        - to: default
          via: 192.168.10.1
      nameservers:
        addresses: [192.168.10.1, 1.1.1.1]
```

```bash
sudo chmod 600 /etc/netplan/01-static.yaml
sudo netplan try        # reverts automatically if you lose connectivity
sudo netplan apply
```

### 4.2 Hostname and name resolution

```bash
sudo hostnamectl set-hostname pg-node1        # unique on each machine
```

Add every machine to `/etc/hosts` on every machine (so the cluster does not depend on DNS):

```
192.168.10.11 pg-node1
192.168.10.12 pg-node2
192.168.10.13 pg-witness
192.168.10.21 pg-proxy1
192.168.10.22 pg-proxy2
192.168.10.20 pg-vip
```

The cluster itself is configured with **IP addresses**, which are more reliable.

### 4.3 Time synchronization (critical)

etcd and Patroni rely on timing (TTL, leases). Clock drift causes unstable leadership.

```bash
sudo apt-get update
sudo apt-get install -y chrony
```

Point chrony at your internal NTP server if you have one (`/etc/chrony/chrony.conf`, `server ntp.example.local iburst`), then:

```bash
sudo systemctl enable --now chrony
chronyc tracking        # offset should be milliseconds
chronyc sources -v
```

If the hypervisor also syncs guest time, use **one** source of truth and keep the offset small. Do not let both fight.

### 4.4 Apt sanity check

```bash
sudo apt-get update
```

If you see `NO_PUBKEY ... apt.postgresql.org ... not signed`, a PGDG repo was added without its key and the setup script will stop. You do not need it, because Ubuntu's own repos have everything. Remove it:

```bash
grep -rl apt.postgresql.org /etc/apt/
sudo rm -f /etc/apt/sources.list.d/pgdg.list /etc/apt/sources.list.d/pgdg.sources
sudo apt-get update          # must finish without Err: or E: lines
```

### 4.5 Kernel and OS tuning (DB nodes)

```bash
cat <<'EOF' | sudo tee /etc/sysctl.d/99-postgres.conf
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
net.core.somaxconn = 1024
EOF
sudo sysctl --system
```

Disable Transparent Huge Pages (recommended for PostgreSQL):

```bash
cat <<'EOF' | sudo tee /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'

[Install]
WantedBy=basic.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now disable-thp
cat /sys/kernel/mm/transparent_hugepage/enabled     # [never] selected
```

### 4.6 Firewall (ufw)

Replace the IPs with yours. Allow SSH from your admin network first, so you do not lock yourself out.

**On node1 and node2:**

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.10.0/24 to any port 22 proto tcp          # SSH (admin network)

# etcd between the 3 cluster machines
sudo ufw allow from 192.168.10.11 to any port 2379,2380 proto tcp
sudo ufw allow from 192.168.10.12 to any port 2379,2380 proto tcp
sudo ufw allow from 192.168.10.13 to any port 2379,2380 proto tcp

# PostgreSQL and the Patroni API: from the other DB node and from both proxies
sudo ufw allow from 192.168.10.11 to any port 5432,8008 proto tcp
sudo ufw allow from 192.168.10.12 to any port 5432,8008 proto tcp
sudo ufw allow from 192.168.10.21 to any port 5432,8008 proto tcp
sudo ufw allow from 192.168.10.22 to any port 5432,8008 proto tcp

sudo ufw enable
sudo ufw status numbered
```

**On the witness** (etcd only):

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.10.0/24 to any port 22 proto tcp
sudo ufw allow from 192.168.10.11 to any port 2379,2380 proto tcp
sudo ufw allow from 192.168.10.12 to any port 2379,2380 proto tcp
sudo ufw allow from 192.168.10.13 to any port 2379,2380 proto tcp
sudo ufw enable
```

**On the proxies** (HAProxy and keepalived rules are in section 7).

Port summary:

| Port | Machines | Purpose |
|---|---|---|
| 22 | all | SSH (admin network only) |
| 5432 | DB nodes | PostgreSQL (from the other node and the proxies) |
| 8008 | DB nodes | Patroni REST API (health checks) |
| 2379, 2380 | node1, node2, witness | etcd client and peer |
| 5000, 5001 | proxies | Database access for applications |
| 7000 | proxies | HAProxy stats (admin only) |
| VRRP (protocol 112) | proxies | keepalived heartbeat |

### 4.7 Quick connectivity test

From each machine, check that the others are reachable:

```bash
for ip in 192.168.10.11 192.168.10.12 192.168.10.13; do ping -c1 -W1 $ip >/dev/null && echo "$ip ok" || echo "$ip FAIL"; done
```

After the cluster is installed, test the ports with `timeout 3 bash -c '</dev/tcp/192.168.10.12/8008' && echo open`.

### 4.8 Get the setup script onto the DB nodes and the witness

The script is in [Appendix A](#appendix-a-setup-pg-hash). Save it as `setup-pg-ha.sh` on node1, node2 and the witness:

```bash
nano setup-pg-ha.sh          # paste, save
chmod +x setup-pg-ha.sh
bash -n setup-pg-ha.sh && echo "syntax OK"
```

### 4.9 RHEL, Rocky and Alma notes

The commands in this guide use Ubuntu. On RHEL-family systems:

- Install PostgreSQL, Patroni and etcd from the PGDG repository (and the etcd project binaries or EPEL packages), then place the configs shown here.
- Use `firewalld` (`firewall-cmd --permanent --add-port=...`) and `chrony`.
- **SELinux:** either set the right contexts for `/var/lib/etcd` and the Patroni ports (`semanage port`), or run in permissive mode while building. Do not simply disable it in production without a decision.
- The PostgreSQL binary path is `/usr/pgsql-<ver>/bin`, not `/usr/lib/postgresql/<ver>/bin`. Set `bin_dir` and `data_dir` in the Patroni config accordingly.

---

## 5. Install the cluster (Patroni + etcd)

### 5.1 Variables

**Same on every machine** (nodes and witness):

```bash
export NODE1_IP=192.168.10.11
export NODE2_IP=192.168.10.12
export WITNESS_IP=192.168.10.13
export SUBNET=192.168.10.0/24
```

`SUBNET` is the range allowed to connect to PostgreSQL in `pg_hba`. HAProxy connections appear to PostgreSQL as coming from the **proxy IPs**, so the subnet must include them. For tighter security use a smaller range, or edit `pg_hba` afterwards (section 12).

**Different per machine:**

| Machine | ROLE | NODE_NAME | NODE_IP |
|---|---|---|---|
| node1 | `db` | `node1` | `192.168.10.11` |
| node2 | `db` | `node2` | `192.168.10.12` |
| witness | `witness` | `witness` | `192.168.10.13` |

**Passwords** (node1 and node2 only, **identical on both**):

```bash
export REPL_PASSWORD='<strong-replication-password>'
export SUPERUSER_PASSWORD='<strong-postgres-password>'
```

Use strong, URL-safe passwords (letters, digits, `-`, `_`). Characters such as `@ : / ? # %` break connection URLs.

### 5.2 Run order

> **Tip:** switch to root for the session (`sudo -i`) and `export` the variables there. On recent Ubuntu versions `sudo -E` may be ignored (sudo-rs). Also check that the prompt hostname matches the machine you think you are on, because running the node1 command on node2 is an easy mistake.

**Step 1: witness**, then **Step 2: node1** within about a minute (etcd needs a second member before it becomes healthy), then **Step 3: node2** after about 30 seconds.

**Witness (`pg-witness`):**

```bash
sudo -i
cd /home/<user>        # folder containing setup-pg-ha.sh

export NODE1_IP=192.168.10.11 NODE2_IP=192.168.10.12 WITNESS_IP=192.168.10.13 SUBNET=192.168.10.0/24
export ROLE=witness NODE_NAME=witness NODE_IP=192.168.10.13
./setup-pg-ha.sh
```

Expected last line: `==> Witness done.` etcd may show as "waiting" until the other members start, which is normal.

**Node 1 (`pg-node1`):**

```bash
sudo -i
cd /home/<user>

export NODE1_IP=192.168.10.11 NODE2_IP=192.168.10.12 WITNESS_IP=192.168.10.13 SUBNET=192.168.10.0/24
export REPL_PASSWORD='<strong-replication-password>'
export SUPERUSER_PASSWORD='<strong-postgres-password>'
export ROLE=db NODE_NAME=node1 NODE_IP=192.168.10.11
./setup-pg-ha.sh
```

At this point node1 and the witness form a 2-of-3 quorum. Patroni on node1 may log etcd warnings until node2 joins. That is expected.

**Node 2 (`pg-node2`), about 30 seconds later:**

```bash
sudo -i
cd /home/<user>

export NODE1_IP=192.168.10.11 NODE2_IP=192.168.10.12 WITNESS_IP=192.168.10.13 SUBNET=192.168.10.0/24
export REPL_PASSWORD='<strong-replication-password>'      # same as node1
export SUPERUSER_PASSWORD='<strong-postgres-password>'    # same as node1
export ROLE=db NODE_NAME=node2 NODE_IP=192.168.10.12
./setup-pg-ha.sh
```

### 5.3 What the script does

1. Installs chrony and etcd, plus PostgreSQL, Patroni and `python3-etcd` on DB nodes.
2. Writes `/etc/default/etcd` for a 3-member cluster and starts etcd.
3. On DB nodes: disables the stock `postgresql` service, drops the default cluster so Patroni can initialize an empty data directory.
4. Writes `/etc/patroni/config.yml` and starts Patroni.

> **Never re-run the script on a node that already holds data.** It wipes `/var/lib/etcd` and the PostgreSQL data directory. To recover a node, restart its services instead (section 14 and 16).

### 5.4 If Patroni was started before etcd had all 3 members

On the affected node:

```bash
sudo systemctl reset-failed patroni
sudo systemctl restart patroni
sleep 30
```

`reset-failed` clears systemd's "Start request repeated too quickly" block.

---

## 6. Verify the cluster

```bash
# all 3 etcd members healthy, and the cluster version is 3.5.0 (not 3.0.0)
curl -s http://192.168.10.11:2379/version; echo
etcdctl --endpoints=192.168.10.11:2379,192.168.10.12:2379,192.168.10.13:2379 endpoint health
etcdctl --endpoints=192.168.10.11:2379 member list -w table

# Patroni
patronictl -c /etc/patroni/config.yml list
```

Expected: one **Leader** and one **Replica** in `streaming` state, lag 0:

```
| Member | Host          | Role    | State     | TL | Lag |
| node1  | 192.168.10.11 | Leader  | running   |  1 |     |
| node2  | 192.168.10.12 | Replica | streaming |  1 |   0 |
```

Either node can be the leader.

> **etcd cluster version 3.0.0** only means that not all members have joined yet. Patroni reads it and logs `Detected Etcd version 3.0.0 ... 404 .../v3alpha`. It clears by itself once the third member joins. Do **not** wipe etcd because of this.

More checks:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.10.11:8008/primary     # 200 on the leader
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.10.12:8008/primary     # 503 on the replica

PGPASSWORD='<postgres-password>' psql -h <leader-ip> -U postgres \
  -c "select client_addr, state, sync_state from pg_stat_replication;"
```

---

## 7. Client routing: HAProxy + keepalived VIP

Apps connect to the **VIP** (`192.168.10.20`). keepalived keeps the VIP on a healthy proxy host, and HAProxy sends traffic to the current Patroni leader. Run this on **both** proxy machines.

### 7.1 Firewall on the proxies

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.10.0/24 to any port 22 proto tcp
sudo ufw allow from <app-network-cidr> to any port 5000,5001 proto tcp     # your app servers
sudo ufw allow from <admin-ip> to any port 7000 proto tcp                  # stats page
```

keepalived uses **VRRP, which is IP protocol 112**, not TCP or UDP. ufw needs a raw rule. Edit `/etc/ufw/before.rules` and add this line **before** the final `COMMIT` of the `*filter` section (use the other proxy's IP on each host):

```
-A ufw-before-input -p 112 -s 192.168.10.22 -j ACCEPT
```

On proxy2 use `-s 192.168.10.21`. Then:

```bash
sudo ufw enable
sudo ufw reload
```

### 7.2 Install HAProxy (script)

Use `setup-haproxy.sh` on **both** proxies. It installs HAProxy and writes the config. On each proxy, as root:

```bash
sudo -i
NODE1_IP=192.168.10.11 NODE2_IP=192.168.10.12 STATS_PASS='<stats-password>' ./setup-haproxy.sh
```

Or configure it by hand. `/etc/haproxy/haproxy.cfg`:

```
global
    log /dev/log local0
    maxconn 1000
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode tcp
    retries 2
    timeout connect 5s
    timeout client 30m
    timeout server 30m
    timeout check 5s

listen postgres_primary
    bind *:5000
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 192.168.10.11:5432 check port 8008
    server node2 192.168.10.12:5432 check port 8008

listen postgres_replica
    bind *:5001
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server node1 192.168.10.11:5432 check port 8008
    server node2 192.168.10.12:5432 check port 8008

listen stats
    mode http
    bind *:7000
    stats enable
    stats uri /
    stats refresh 5s
    stats auth admin:<stats-password>
```

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
sudo systemctl enable --now haproxy
```

It is normal for one server in each pool to show DOWN with `Layer7 wrong status, code: 503`. It is the other role being correctly rejected by Patroni.

### 7.3 Install keepalived

```bash
sudo apt-get install -y keepalived
```

Find the interface name (`ip -br a`), for example `ens18`.

**`/etc/keepalived/keepalived.conf` on proxy1 (MASTER):**

```
global_defs {
    router_id PG_PROXY1
    script_user root
    enable_script_security
}

vrrp_script chk_haproxy {
    script "/usr/bin/systemctl is-active --quiet haproxy"
    interval 2
    fall 2
    rise 2
}

vrrp_instance VI_PG {
    state MASTER
    interface ens18
    virtual_router_id 51
    priority 110
    advert_int 1
    unicast_src_ip 192.168.10.21
    unicast_peer {
        192.168.10.22
    }
    authentication {
        auth_type PASS
        auth_pass <8chars>
    }
    virtual_ipaddress {
        192.168.10.20/24
    }
    track_script {
        chk_haproxy
    }
}
```

**On proxy2 (BACKUP),** change only these lines:

```
    router_id PG_PROXY2
    state BACKUP
    priority 100
    unicast_src_ip 192.168.10.22
    unicast_peer {
        192.168.10.21
    }
```

Notes:

- `auth_pass` is limited to 8 characters, and must be the same on both proxies.
- `virtual_router_id` (1 to 255) must be unique among VRRP groups on that network segment, and the same on both proxies.
- `unicast_*` avoids multicast, which some virtual switches and clouds block.
- If HAProxy stops, `chk_haproxy` fails and keepalived releases the VIP, so the other proxy takes it.

```bash
sudo systemctl enable --now keepalived
sudo systemctl status keepalived --no-pager
ip -br a show ens18          # the MASTER proxy shows 192.168.10.20
```

### 7.4 Hypervisor and network requirements for the VIP

- Both proxy VMs must be on the **same L2 network/VLAN**.
- **VMware:** the port group security policy must allow it (set *Forged transmits* and *MAC address changes* to Accept, and consider promiscuous mode only if needed).
- **Proxmox/KVM:** disable MAC or IP filtering on the VM NICs that would block the VIP's ARP replies (check the firewall and `ipfilter` options).
- If the VIP does not move in tests, capture VRRP: `sudo tcpdump -ni ens18 proto 112`.

### 7.5 Test the VIP and HAProxy

```bash
PGPASSWORD='<postgres-password>' psql -h 192.168.10.20 -p 5000 -U postgres -Atc "select inet_server_addr(), pg_is_in_recovery();"   # leader IP and f
PGPASSWORD='<postgres-password>' psql -h 192.168.10.20 -p 5001 -U postgres -Atc "select inet_server_addr(), pg_is_in_recovery();"   # replica IP and t
```

Test proxy failover: `sudo systemctl stop haproxy` on the MASTER proxy. Within a couple of seconds `ip -br a` on the other proxy shows the VIP, and the `psql` commands above keep working. Start HAProxy again afterwards.

---

## 8. Alternative routing options

| Option | How | Notes |
|---|---|---|
| **vip-manager** | Runs on each DB node, reads the leader key from etcd and attaches the VIP to the leader's NIC | No proxy at all. The VIP always sits on the leader. Same L2 requirement. The package is `vip-manager` (check `dpkg -L vip-manager` for its config file path). Existing connections drop on failover as the IP moves |
| **keepalived on DB nodes** with a check script against `:8008/primary` | The VIP follows the node where `/primary` returns 200 | Simple, but keepalived and Patroni are decided separately, so brief mismatches are possible |
| **Multi-host connection strings** | `host=192.168.10.11,192.168.10.12 target_session_attrs=read-write` | No infrastructure at all. The driver finds the leader. Needs a driver with multi-host support (libpq, JDBC, and others) |
| **HAProxy on each app server** | A local proxy per app host | No shared proxy tier, more machines to manage |

The HAProxy + keepalived pair (section 7) is the most widely used and works with every client.

---

## 9. Failover tests

Test everything **before** go-live, and repeat regularly.

### 9.1 Start a continuous writer (from any machine allowed to reach the VIP)

```bash
export PGPASSWORD='<postgres-password>'
CONN="host=192.168.10.20 port=5000 user=postgres dbname=postgres connect_timeout=3"

psql "$CONN" -c "create table if not exists ha_test(id serial primary key, ts timestamptz default now(), host text);"

while true; do
  psql "$CONN" -Atc "insert into ha_test(host) values (inet_server_addr()::text) returning id, host;" \
    || echo "$(date +%T) WRITE FAILED"
  sleep 1
done
```

`WRITE FAILED` lines during a failover are normal. Writes are impossible between the moment the leader dies and the moment HAProxy sees the new one. The host column changes to the new leader's IP when it recovers.

### 9.2 Tests

| # | Test | How | Expected |
|---|---|---|---|
| 1 | **Planned switchover** | `patronictl -c /etc/patroni/config.yml switchover` (enter the leader, the candidate and `now`) | Roles swap in a few seconds, lag 0 |
| 2 | **Stop Patroni on the leader** | `sudo systemctl stop patroni` | Replica promoted in seconds, writer recovers. Start Patroni again, and the old leader rejoins as a replica |
| 3 | **Hard power-off of the leader VM** | Power off the VM from the hypervisor (not a graceful shutdown) | Promotion within about 30 seconds (`ttl: 30`) |
| 4 | **Kill PostgreSQL only** | `sudo pkill -9 postgres` on the leader | Patroni restarts it, or fails over if it cannot |
| 5 | **Lose the witness** | Stop etcd or power off the witness | Everything keeps working (2 of 3 etcd members). Restore it afterwards |
| 6 | **Lose one DB node's etcd** | `sudo systemctl stop etcd` on one DB node | The cluster keeps working. Start it again |
| 7 | **Network isolation of the leader** | Disconnect its virtual NIC in the hypervisor, or block the other machines with iptables | The isolated leader demotes itself, and the other node is promoted |
| 8 | **Proxy failover** | `sudo systemctl stop haproxy` on the VIP holder | The VIP moves to the other proxy within about 2 seconds |
| 9 | **Power off a whole hypervisor host** | Only if you have multiple hosts | VMs on other hosts keep the cluster alive |

Never stop **two** etcd members at once. With no quorum, the leader demotes itself and writes stop, which is the intended protection.

### 9.3 After each test

```bash
patronictl -c /etc/patroni/config.yml list         # one Leader, replica streaming, lag 0
```

If a few IDs are missing in `ha_test`, check whether they were written during the failure window. Sequence gaps are normal. With asynchronous replication, the last commit or two before a hard crash can be lost, so enable `synchronous_mode` (section 12) if that is unacceptable.

---

## 10. Application settings

```
host     = 192.168.10.20        # the VIP
port     = 5000                 # leader (reads and writes); use 5001 for read-only workloads
database = <your database>
user     = <app user>
```

Create the application database and user on the **leader** (through the VIP port 5000), as the superuser:

```bash
psql -h 192.168.10.20 -p 5000 -U postgres \
  -c "CREATE ROLE appuser WITH LOGIN PASSWORD '<app-password>';" \
  -c "CREATE DATABASE appdb OWNER appuser ENCODING 'UTF8';"
```

Use two `-c` flags (`CREATE DATABASE` cannot share a transaction with another statement), and avoid heredocs when pasting into a terminal.

Application guidelines:

- Failover **drops existing connections**. The app or its pool must reconnect and retry.
- HAProxy closes connections idle for more than 30 minutes (`timeout client/server 30m`). Enable pool keepalive or a shorter idle timeout.
- Retry failed writes for 30 to 60 seconds before giving up.
- Do not connect applications directly to node1 or node2.

To migrate an existing database into the cluster, follow `db-migration-guide.md` (dump with the same or a newer client version, restore through the VIP, verify counts, switch the app).

---

## 11. Backups

> **HA is not a backup.** A `DROP TABLE`, a bad deploy or corruption replicates to the replica immediately.

### 11.1 Minimum: nightly logical dump from the replica

Using the replica port (5001) keeps load off the leader. Use the client version that matches the server (`/usr/lib/postgresql/18/bin/pg_dump`).

`/usr/local/bin/pg-backup.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
DEST=/backup/pg
mkdir -p "$DEST"
export PGPASSWORD="$(cat /root/.pgbackup_pass)"     # chmod 600
STAMP=$(date +%Y%m%d-%H%M%S)
/usr/lib/postgresql/18/bin/pg_dump -h 192.168.10.20 -p 5001 -U postgres -d appdb -Fc -f "$DEST/appdb-$STAMP.dump"
find "$DEST" -name 'appdb-*.dump' -mtime +14 -delete
```

```bash
sudo chmod 700 /usr/local/bin/pg-backup.sh
echo '0 2 * * * root /usr/local/bin/pg-backup.sh >> /var/log/pg-backup.log 2>&1' | sudo tee /etc/cron.d/pg-backup
```

Store the dumps **off the DB servers** (NFS share, backup server, MinIO), and test a restore regularly.

### 11.2 Recommended: pgBackRest (point-in-time recovery)

Outline (see the pgBackRest documentation for details, and test the restore before relying on it):

1. Install on both DB nodes: `sudo apt-get install -y pgbackrest`.
2. Provide a repository that **both nodes** can reach (an NFS mount, a dedicated backup VM, or MinIO with `repo1-type=s3`).
3. `/etc/pgbackrest/pgbackrest.conf` on both nodes:

   ```
   [global]
   repo1-path=/backup/pgbackrest
   repo1-retention-full=2
   start-fast=y
   log-level-console=info

   [pgcluster]
   pg1-path=/var/lib/postgresql/18/main
   pg1-socket-path=/var/run/postgresql
   ```

4. Enable WAL archiving cluster-wide through Patroni (`patronictl -c /etc/patroni/config.yml edit-config`), adding under `postgresql: parameters:`:

   ```
   archive_mode: "on"
   archive_command: "pgbackrest --stanza=pgcluster archive-push %p"
   archive_timeout: 60
   ```

5. On the **current leader**, as the `postgres` user:

   ```bash
   sudo -u postgres pgbackrest --stanza=pgcluster stanza-create
   sudo -u postgres pgbackrest --stanza=pgcluster check
   sudo -u postgres pgbackrest --stanza=pgcluster --type=full backup
   ```

6. Schedule full and incremental backups (cron on the leader, or a small wrapper that checks `/primary` first).
7. **Practice a restore on a spare VM** and document the procedure. A backup that has never been restored is not a backup.

### 11.3 Back up etcd (small, but valuable)

```bash
etcdctl --endpoints=192.168.10.11:2379 snapshot save /backup/etcd-$(date +%F).db
```

etcd holds only cluster state, which Patroni can rebuild, but a snapshot saves time. **Never restore an etcd VM from a hypervisor snapshot** (section 3.4).

---

## 12. Security hardening

| Task | How |
|---|---|
| **Strong, unique passwords** | `postgres`, `replicator` and the app user. Keep them in a secret manager. Never commit them |
| **Restrict `pg_hba`** | Allow only the proxy IPs, the other DB node and admin hosts, not the whole subnet. Edit with `patronictl edit-config` (`postgresql.pg_hba`) |
| **Firewall** | As in section 4.6. Only the listed sources reach 5432, 8008 and 2379/2380 |
| **SSH** | Key-only login (`PasswordAuthentication no`), a restricted admin network, no root login |
| **TLS** | Add certificates for etcd (2379/2380), the Patroni REST API (`restapi.certfile`/`keyfile`) and PostgreSQL (`ssl = on`). Then use `sslmode=verify-full` in clients |
| **etcd authentication** | Enable users and roles in etcd once TLS is in place |
| **Automatic updates** | Use unattended security updates, but set `Automatic-Reboot "false"` so nodes are never rebooted together |
| **Synchronous replication** | `patronictl edit-config`, set `synchronous_mode: true` to avoid losing the last commit on a crash (costs some write latency). Keep `synchronous_mode_strict: false` unless you need strict guarantees, because strict mode stops writes when no replica is available |
| **Patroni watchdog** | See below |

### 12.1 Patroni watchdog (fencing a hung primary)

A frozen VM or node may be unable to release the leader lock. A watchdog reboots it so it cannot keep accepting writes.

```bash
sudo modprobe softdog
echo softdog | sudo tee /etc/modules-load.d/softdog.conf
echo 'KERNEL=="watchdog", OWNER="postgres", GROUP="postgres", MODE="0660"' | sudo tee /etc/udev/rules.d/60-watchdog.rules
sudo udevadm control --reload && sudo udevadm trigger
ls -l /dev/watchdog
```

Add to `/etc/patroni/config.yml` on both DB nodes:

```yaml
watchdog:
  mode: automatic        # off | automatic | required
  device: /dev/watchdog
  safety_margin: 5
```

Restart Patroni one node at a time (replica first). Hypervisors may offer a virtual hardware watchdog (for example `i6300esb` in KVM) that is more reliable than `softdog`, so use it if available.

### 12.2 Resource tuning

Default PostgreSQL settings are conservative. Set cluster-wide parameters with `patronictl edit-config`, for example (adapt to your RAM):

```yaml
postgresql:
  parameters:
    shared_buffers: 2GB            # about 25% of RAM
    effective_cache_size: 6GB      # about 75% of RAM
    work_mem: 16MB
    maintenance_work_mem: 512MB
    max_connections: 200
```

Some parameters require a restart (`patronictl restart pgcluster <node>`, replica first).

---

## 13. Monitoring

| What | How |
|---|---|
| Cluster state | `patronictl list` (alert if there is no leader, a replica is not `streaming`, or the timeline changes unexpectedly) |
| Patroni metrics | `curl http://<node>:8008/metrics` (Prometheus format) |
| PostgreSQL metrics | `postgres_exporter` (connections, replication lag, locks, size) |
| etcd | `etcdctl endpoint health`, `etcdctl endpoint status -w table`, etcd's `/metrics` |
| HAProxy | The stats page on port 7000, or the HAProxy Prometheus endpoint |
| keepalived | Which proxy holds the VIP, and alert on VIP flapping |
| Host metrics | `node_exporter` (CPU, memory, disk space, disk latency, network) |
| Logs | `journalctl -u patroni`, `journalctl -u etcd`, `journalctl -u haproxy`, `journalctl -u keepalived`, and the PostgreSQL log |

Alerts worth having:

- No Patroni leader, or two leaders.
- A replica not streaming, or lag above a threshold.
- Fewer than 3 healthy etcd members.
- Disk usage above 80 percent (data, WAL, etcd).
- Leader changes (investigate every unplanned one).
- HAProxy backend down, VIP moved.
- Backup job failed or too old.
- Clock offset above about 100 ms.

---

## 14. Maintenance procedures

### 14.1 Rolling OS updates and reboots (no downtime beyond one switchover)

Do **one machine at a time**, and wait for the cluster to be healthy before the next.

1. Update and reboot the **replica** node. Wait until `patronictl list` shows it `streaming` with lag 0.
2. Run a **switchover** to the updated node (`patronictl switchover`).
3. Update and reboot the old leader (now a replica). Wait for `streaming`.
4. Update and reboot the **witness**, then proxy2, then proxy1 (the VIP moves automatically).

Never reboot two etcd members at the same time (node1, node2 and the witness count). If an etcd member will be unavailable for a long time, use `patronictl pause` first.

### 14.2 PostgreSQL minor updates

Same as 14.1: update the replica, restart PostgreSQL through Patroni (`patronictl restart`), switch over, then update the other node. Test major version upgrades (`pg_upgrade`) in a separate environment first.

### 14.3 Rebuilding a broken replica

```bash
patronictl -c /etc/patroni/config.yml reinit pgcluster <replica-node>
```

Patroni wipes the replica and clones it from the leader with `pg_basebackup`.

### 14.4 Replacing a failed DB node (new VM)

1. Build a new VM with the same IP and name, and do the preparation in section 4.
2. If it had an etcd member, remove the dead member and add the replacement. **Do not use the setup script**, because it starts a *new* etcd cluster:

   ```bash
   etcdctl --endpoints=<healthy-member>:2379 member list -w table
   etcdctl --endpoints=<healthy-member>:2379 member remove <old-member-id>
   etcdctl --endpoints=<healthy-member>:2379 member add node2 --peer-urls=http://192.168.10.12:2380
   ```

   On the new VM, configure `/etc/default/etcd` as in the script, but with `ETCD_INITIAL_CLUSTER_STATE="existing"` and an `ETCD_INITIAL_CLUSTER` listing all current members, then start etcd.
3. Install PostgreSQL, Patroni and `python3-etcd`, write `/etc/patroni/config.yml` (the same as the old node), with an **empty data directory**, and start Patroni. It clones from the leader automatically.

### 14.5 Replacing the witness

Same etcd member replacement as above (remove, add, start with `existing` state). The database keeps running because the 2 DB nodes still form a majority.

### 14.6 Changing passwords

```bash
psql -h 192.168.10.20 -p 5000 -U postgres -c "\password appuser"     # prompts without echo
```

For `postgres` or `replicator`, also update `/etc/patroni/config.yml` on **both** DB nodes, then restart Patroni one node at a time, replica first.

### 14.7 Planned hypervisor or host maintenance

If a DB VM must be live-migrated or its host paused for more than a few seconds, run `patronictl pause` first (and `patronictl resume` afterwards), or perform a switchover away from that VM beforehand.

---

## 15. Disaster scenarios

| Scenario | What happens | Your action |
|---|---|---|
| Leader VM or host dies | Replica promoted in about 30 seconds | Repair or replace the failed node (14.4), then check the cluster is healthy |
| Replica VM dies | Leader keeps serving (port 5001 has no healthy server) | Repair, start it, and it catches up (or `reinit`) |
| Witness dies | No impact (2 of 3 etcd) | Restore or replace it soon, because the cluster has no spare tolerance meanwhile |
| Witness **and** one DB node die | etcd quorum is lost and the leader goes read-only | Bring one back. If the DB node cannot return, you must recover the cluster by hand (restore from backup or reconfigure etcd) |
| Both DB nodes die | Database down | Start whichever node has the newest data, or restore from backup |
| Proxy dies | The VIP moves to the other proxy in about 2 seconds | Repair the failed proxy |
| Both proxies die | Apps cannot reach the database even though it is healthy | Restore a proxy, or temporarily use direct multi-host connection strings |
| Network partition | The side without etcd quorum goes read-only or demotes. The majority side continues | Fix the network. Nodes rejoin automatically |
| Corrupted data or accidental deletion | The error replicates | Restore from backup (pgBackRest PITR) |
| Whole site lost | Total outage | Rebuild from off-site backups |

---

## 16. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `sudo: preserving the entire environment is not supported, '-E' is ignored` | Already root, or sudo-rs | Use `sudo -i` and `export`, or `sudo env VAR=... ./script` |
| `unexpected EOF while looking for matching '"'` | Corrupted or outdated copy of the script | Re-copy the script from Appendix A, `bash -n setup-pg-ha.sh` |
| `./setup-pg-ha.shNODE1_IP=...: No such file` | The command was pasted twice and joined | Paste the command once |
| Ran node1's command on node2 | The prompt hostname was not checked | Compare the prompt with the table in section 3.1 |
| `apt-get update` fails with `NO_PUBKEY ... pgdg` | PGDG repo without a key | Section 4.4 |
| Patroni: `Failed to import patroni.dcs.etcd3 ... Available implementations: consul, kubernetes` | `python3-etcd` missing | `sudo apt-get install -y python3-etcd`, then `systemctl reset-failed patroni && systemctl restart patroni` |
| Patroni: `Start request repeated too quickly` | systemd rate limit | `sudo systemctl reset-failed patroni`, then restart |
| Patroni: `Detected Etcd version 3.0.0 ... 404 /v3alpha` | Not all etcd members have joined yet | Finish the third machine. Do not wipe etcd |
| etcd log: `connection refused` to a peer on 2380 | That peer is down, or the port is blocked | Start it, or open 2379/2380 in ufw |
| Patroni waits on etcd forever | No quorum (fewer than 2 members) | `etcdctl endpoint health`, bring members up |
| `etcdserver: request timed out` or frequent leader changes | Slow disk or clock drift | Check disk latency and `chronyc tracking`. Use SSD and fix time sync |
| HAProxy shows both nodes DOWN | The proxy cannot reach port 8008 (firewall) | Allow 8008 and 5432 from the proxy IPs on the DB nodes |
| VIP does not appear or does not move | VRRP blocked (protocol 112), wrong interface, hypervisor filtering | `sudo tcpdump -ni <if> proto 112`, add the ufw `before.rules` line, relax the vSwitch security policy |
| Both proxies hold the VIP (split VIP) | VRRP packets are not reaching the peer | Check the firewall, `unicast_peer` and the network path |
| `psql` through the VIP hangs | The app host is not allowed on 5000, or no healthy leader | Check ufw on the proxy, the HAProxy stats page, `patronictl list` |
| `password authentication failed` through HAProxy | Wrong password, or `pg_hba` does not include the proxy IP | Check the password and `pg_hba` (it must allow the proxy IPs) |
| `pg_dump: server version mismatch` | Client older than the server | Use the matching `/usr/lib/postgresql/<ver>/bin/pg_dump` |
| Stale `PGPASSWORD` causes `password authentication failed` against another server | An exported password overrides prompts | `unset PGPASSWORD` |
| Shell stuck at a `>` prompt after pasting `<<'SQL'` | The heredoc closing line was not on its own line | Ctrl+C, and use `-c` flags |
| Replica not streaming, or lag growing | Network, disk, or a missing WAL segment | `journalctl -u patroni`, then `patronictl reinit pgcluster <replica>` |
| Cluster has no leader | Quorum lost, or both Patroni services are down | `etcdctl endpoint health`, `systemctl status patroni etcd` on all nodes |
| Failover too slow or too sensitive | `ttl`, `loop_wait` and HAProxy timings | Tune with `patronictl edit-config`. Lower values fail over faster but trigger more falsely on brief stalls |
| Nodes failed over during a VM migration | A pause longer than the TTL | `patronictl pause` before planned maintenance |

Useful commands:

```bash
sudo journalctl -u patroni -n 50 --no-pager
sudo journalctl -u etcd -n 50 --no-pager
sudo journalctl -u haproxy -n 50 --no-pager
sudo journalctl -u keepalived -n 50 --no-pager
sudo ss -tlnp | grep -E '5432|8008|2379|2380|5000|5001|7000'
chronyc tracking
```

---

## 17. Final checklist

**Planning and prep**
- [ ] DB nodes, witness and proxies are on separate physical hosts (anti-affinity set)
- [ ] Static IPs, hostnames and `/etc/hosts` configured
- [ ] chrony synchronized on all machines (offset in milliseconds)
- [ ] ufw rules in place on every machine (SSH first)
- [ ] `apt-get update` is clean (no PGDG key error)

**Cluster**
- [ ] The witness and node1 were started together, then node2
- [ ] 3 etcd members healthy, cluster version `3.5.0`
- [ ] `patronictl list`: one Leader, one Replica streaming, lag 0

**Routing**
- [ ] HAProxy on both proxies: leader green in 5000, replica green in 5001
- [ ] keepalived: the VIP on the MASTER and it moves when HAProxy stops
- [ ] Apps connect to the VIP, not to the DB nodes

**Resilience**
- [ ] Switchover, leader stop, hard power-off, witness loss, proxy loss all tested
- [ ] The app reconnects and retries after a failover
- [ ] Watchdog enabled (optional but recommended)

**Operations**
- [ ] Backups configured **and a restore tested**
- [ ] Monitoring and alerts in place
- [ ] All default and test passwords replaced, stored in a secret manager
- [ ] `pg_hba` restricted, TLS planned or enabled
- [ ] Maintenance runbook agreed (rolling updates, replace a node)

---

## Appendix A: `setup-pg-ha.sh`

Run as root on each of node1, node2 and the witness. Behavior depends on `ROLE`. It installs packages, configures etcd, and on DB nodes prepares PostgreSQL and starts Patroni.

```bash
#!/usr/bin/env bash
# PostgreSQL HA: Patroni + etcd on 2 DB nodes + 1 witness (etcd only)
# Works on EC2, bare metal or on-prem VMs. Tested on Ubuntu 22.04 / 24.04 / 26.04.
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

## Appendix B: Reference configs

### B.1 Files and locations

| File | Machine | Purpose |
|---|---|---|
| `/etc/default/etcd` | node1, node2, witness | etcd member name, URLs, initial cluster |
| `/etc/patroni/config.yml` | node1, node2 | Patroni, PostgreSQL and replication settings |
| `/etc/haproxy/haproxy.cfg` | proxy1, proxy2 | Pools on 5000 and 5001, health checks, stats |
| `/etc/keepalived/keepalived.conf` | proxy1, proxy2 | VRRP and the VIP |
| `/etc/ufw/before.rules` | proxy1, proxy2 | VRRP (protocol 112) allow rule |
| `/var/lib/etcd` | node1, node2, witness | etcd data |
| `/var/lib/postgresql/18/main` | node1, node2 | PostgreSQL data (managed by Patroni) |

### B.2 Patroni timing parameters

| Setting | Value | Meaning |
|---|---|---|
| `ttl` | 30 | Seconds a silent leader keeps the lock, which bounds crash failover time |
| `loop_wait` | 10 | Seconds between Patroni cycles |
| `retry_timeout` | 10 | Retry time for etcd and PostgreSQL operations |
| `maximum_lag_on_failover` | 1048576 | A replica more than 1 MB behind is not promoted |
| `use_pg_rewind` | true | Lets a former primary rejoin as a replica |
| `use_slots` | true | Replication slots keep WAL for replicas |

HAProxy checks: `inter 3s fall 3 rise 2`, about 9 seconds to mark a node DOWN and about 6 seconds to mark it UP.
keepalived: `advert_int 1` and the `chk_haproxy` script every 2 seconds, so VIP failover takes about 2 to 4 seconds.

### B.3 Command cheat sheet

```bash
# Cluster
patronictl -c /etc/patroni/config.yml list
patronictl -c /etc/patroni/config.yml switchover
patronictl -c /etc/patroni/config.yml restart pgcluster <node>
patronictl -c /etc/patroni/config.yml reinit pgcluster <replica>
patronictl -c /etc/patroni/config.yml edit-config
patronictl -c /etc/patroni/config.yml pause        # and: resume
patronictl -c /etc/patroni/config.yml history

# etcd
etcdctl --endpoints=192.168.10.11:2379,192.168.10.12:2379,192.168.10.13:2379 endpoint health
etcdctl --endpoints=192.168.10.11:2379 member list -w table
curl -s http://192.168.10.11:2379/version

# Who is the leader (200 only on the leader)
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.10.11:8008/primary
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.10.12:8008/primary

# Through the VIP
psql -h 192.168.10.20 -p 5000 -U postgres -Atc "select inet_server_addr(), pg_is_in_recovery();"   # f = leader
psql -h 192.168.10.20 -p 5001 -U postgres -Atc "select inet_server_addr(), pg_is_in_recovery();"   # t = replica

# Proxies
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
ip -br a | grep 192.168.10.20          # which proxy holds the VIP
sudo systemctl status haproxy keepalived
```