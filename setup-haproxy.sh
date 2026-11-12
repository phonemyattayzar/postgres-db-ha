#!/usr/bin/env bash
# =============================================================================
# HAProxy for a Patroni PostgreSQL HA cluster (2 DB nodes)
#
#   :5000  -> current LEADER only   (reads + writes)
#   :5001  -> REPLICA only          (read-only, optional)
#   :7000  -> HAProxy stats page    (optional)
#
# Run as root on a SEPARATE EC2 / VM (not on the DB nodes):
#   sudo ./setup-haproxy.sh
#
# Or pass the values on the command line instead of editing this file:
#   NODE1_IP=172.31.7.43 NODE2_IP=172.31.5.238 sudo -E ./setup-haproxy.sh
# =============================================================================

set -euo pipefail

# =============================================================================
# >>> REPLACE THESE VALUES WITH YOUR OWN <<<
# =============================================================================

# >>> REPLACE: private IP of DB node 1 (the machine running Patroni "node1")
NODE1_IP="${NODE1_IP:-172.31.7.43}"

# >>> REPLACE: private IP of DB node 2 (the machine running Patroni "node2")
NODE2_IP="${NODE2_IP:-172.31.5.238}"

# Names shown in the HAProxy stats page (any label you like)
NODE1_NAME="${NODE1_NAME:-node1}"
NODE2_NAME="${NODE2_NAME:-node2}"

# PostgreSQL port on the DB nodes (default 5432, change only if you changed it)
PG_PORT="${PG_PORT:-5432}"

# Patroni REST API port on the DB nodes (default 8008, used for health checks)
PATRONI_PORT="${PATRONI_PORT:-8008}"

# Ports that HAProxy listens on (apps connect to these)
WRITE_PORT="${WRITE_PORT:-5000}"     # leader (read + write)
READ_PORT="${READ_PORT:-5001}"       # replicas (read-only)
STATS_PORT="${STATS_PORT:-7000}"     # stats page; restrict it in the Security Group

# >>> REPLACE: login for the stats page at http://<this-host>:7000
STATS_USER="${STATS_USER:-admin}"
STATS_PASS="${STATS_PASS:-CHANGE_ME_STATS_PASSWORD}"

# Set ENABLE_STATS=false to skip the stats page, ENABLE_READ_POOL=false to skip port 5001
ENABLE_STATS="${ENABLE_STATS:-true}"
ENABLE_READ_POOL="${ENABLE_READ_POOL:-true}"

# =============================================================================
# End of values to replace
# =============================================================================

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root (sudo ./setup-haproxy.sh)." >&2
  exit 1
fi

# Basic sanity check: IPs must look like IPv4 addresses
ip_re='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
for ip in "$NODE1_IP" "$NODE2_IP"; do
  if ! [[ "$ip" =~ $ip_re ]]; then
    echo "ERROR: '$ip' is not a valid IPv4 address. Edit NODE1_IP / NODE2_IP." >&2
    exit 1
  fi
done

if [[ "$ENABLE_STATS" == "true" && "$STATS_PASS" == "CHANGE_ME_STATS_PASSWORD" ]]; then
  echo "WARNING: stats password is still the placeholder. Set STATS_PASS or ENABLE_STATS=false." >&2
fi

echo "==> [1/4] Installing HAProxy"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y haproxy

echo "==> [2/4] Backing up existing config"
if [[ -f /etc/haproxy/haproxy.cfg ]]; then
  cp -a /etc/haproxy/haproxy.cfg "/etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d%H%M%S)"
fi

echo "==> [3/4] Writing /etc/haproxy/haproxy.cfg"
{
cat <<EOF
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

# ---- Writes and reads: always the current Patroni LEADER ----
# Patroni answers HTTP 200 on /primary only on the leader,
# so only the leader is marked UP in this pool.
listen postgres_primary
    bind *:${WRITE_PORT}
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server ${NODE1_NAME} ${NODE1_IP}:${PG_PORT} check port ${PATRONI_PORT}
    server ${NODE2_NAME} ${NODE2_IP}:${PG_PORT} check port ${PATRONI_PORT}
EOF

if [[ "$ENABLE_READ_POOL" == "true" ]]; then
cat <<EOF

# ---- Read-only: healthy REPLICAS only ----
listen postgres_replica
    bind *:${READ_PORT}
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server ${NODE1_NAME} ${NODE1_IP}:${PG_PORT} check port ${PATRONI_PORT}
    server ${NODE2_NAME} ${NODE2_IP}:${PG_PORT} check port ${PATRONI_PORT}
EOF
fi

if [[ "$ENABLE_STATS" == "true" ]]; then
cat <<EOF

# ---- Stats page (restrict this port in the Security Group) ----
listen stats
    mode http
    bind *:${STATS_PORT}
    stats enable
    stats uri /
    stats refresh 5s
    stats auth ${STATS_USER}:${STATS_PASS}
EOF
fi
} > /etc/haproxy/haproxy.cfg

chmod 640 /etc/haproxy/haproxy.cfg

echo "==> [4/4] Validating and starting HAProxy"
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl enable haproxy
systemctl restart haproxy
sleep 2
systemctl --no-pager --lines=5 status haproxy || true

MYIP="$(hostname -I | awk '{print $1}')"
cat <<EOF

Done. HAProxy is running on ${MYIP}.

Applications connect to:
  writes (leader):   ${MYIP}:${WRITE_PORT}
  reads (replicas):  ${MYIP}:${READ_PORT}
  stats page:        http://${MYIP}:${STATS_PORT}   (user: ${STATS_USER})

Test it from a machine allowed to reach this host:
  PGPASSWORD='<postgres-password>' psql -h ${MYIP} -p ${WRITE_PORT} -U postgres -Atc "select inet_server_addr(), pg_is_in_recovery();"
  -> should show the leader IP and: f

Reminder (Security Groups):
  - This host: allow TCP ${WRITE_PORT}/${READ_PORT} from your app hosts, ${STATS_PORT} from your own IP only.
  - DB nodes:  allow TCP ${PG_PORT} and ${PATRONI_PORT} from this host.
EOF