#!/usr/bin/env bash
# native-ops-manager-lab.sh
#
# Single-VM, non-Kubernetes lab (Amazon Linux 2023, x86_64, run as root):
#   - 3-node MongoDB Enterprise AppDB replica set (ports 27017-27019)
#   - Ops Manager installed from the signed RPM
#   - Automation Agent deploying oplog-rs (1 node) and my-replica-set (3 nodes)
#   - Backup with a filesystem snapshot store and oplog-rs as the oplog store
# Everything is configured through APIs; no UI steps are needed.
#
# Usage:   sudo ./native-ops-manager-lab.sh
# Retry:   sudo RESET_OM=1 ./native-ops-manager-lab.sh   (wipes Ops Manager state, keeps packages)
set -Eeuo pipefail
trap 'echo "ERROR: line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OM_VERSION="9.0.0"
OM_BUILD="9.0.0.500.20260921T1537Z"
OM_RPM="mongodb-mms-${OM_BUILD}.x86_64.rpm"
OM_RPM_URL="https://downloads.mongodb.com/on-prem-mms/rpm/${OM_RPM}"
OM_LOCAL_URL="http://127.0.0.1:8080"
OM_API="${OM_LOCAL_URL}/api/public/v1.0"
OM_CONF="/opt/mongodb/mms/conf/conf-mms.properties"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OM_RPM_PATH="${OM_RPM_PATH:-${SCRIPT_DIR}/${OM_RPM}}"

APPDB_VERSION="8.0"
APPDB_PORTS=(27017 27018 27019)

MDB_VERSION="7.0.14-ent"
MDB_SERIES="7.0"
OPLOG_RS_PORT=37017
RS_PORTS=(37018 37019 37020)
OPLOG_DIR="/data/oplog-rs"
RS_DIR="/data/my-replica-set"
BACKUP_HEAD_DIR="/data/backup_head"
SNAPSHOT_STORE_DIR="/data/snapshots"
FILE_SYSTEM_STORE_ID="native-lab-filesystem"
OPLOG_STORE_ID="native-lab-oplog"

OM_ADMIN_USER="admin@example.com"
OM_ADMIN_PASSWORD="$(openssl rand -base64 18)Aa1!"
PROJECT_NAME="native-lab-project"
CREDS_FILE="/root/ops-manager-credentials.txt"

# Populated at runtime.
PUBLIC_KEY="" PRIVATE_KEY="" GROUP_ID="" AGENT_API_KEY="" HOSTNAME_IN_OM="" CLUSTER_ID=""
PUBLIC_IP="" PRIVATE_IP="" TARGET_VERSION="" ON_DEMAND_DESCRIPTION=""
OM_POLLS=0
WORK_DIR="$(mktemp -d)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo -e "\033[1;32m[native-om-lab]\033[0m $*"; }
die() { echo "$*" >&2; exit 1; }

# wait_for <label> <tries> <sleep-seconds> <command...>: retry until the command succeeds.
wait_for() {
  local label=$1 tries=$2 delay=$3 i
  shift 3
  for i in $(seq 1 "$tries"); do
    if "$@"; then return 0; fi
    echo "  waiting for ${label} (${i}/${tries})"
    sleep "$delay"
  done
  return 1
}

# Authenticated Ops Manager API call; --fail-with-body prints the error message on 4xx/5xx.
api() { curl --fail-with-body -sS --digest -u "${PUBLIC_KEY}:${PRIVATE_KEY}" "$@"; }
api_send() { api --header "Content-Type: application/json" --request "$1" "$2" --data "$3" >/dev/null; }

# upsert <collection-url> <id> <json-body>: PUT to <url>/<id> if it exists, otherwise POST.
upsert() {
  local url=$1 id=$2 body
  body=$(jq --arg id "$id" '. + {id: $id}' <<<"$3")
  if api "$url" | jq -e --arg id "$id" '[.results[]? | select(.id == $id)] | length > 0' >/dev/null; then
    api_send PUT "${url}/${id}" "$body"
  else
    api_send POST "$url" "$body"
  fi
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run this script as root (sudo ./native-ops-manager-lab.sh)"
}

# ---------------------------------------------------------------------------
# Step 1: packages and the signed Ops Manager RPM
# ---------------------------------------------------------------------------
install_prerequisites() {
  log "Installing base packages and MongoDB Enterprise runtime dependencies"
  # curl is intentionally omitted: AL2023 ships curl-minimal, which conflicts with curl.
  dnf install -y jq openssl initscripts cyrus-sasl cyrus-sasl-gssapi \
    cyrus-sasl-plain krb5-libs openldap xz-libs >/dev/null
}

download_and_verify_om_rpm() {
  if [ ! -s "$OM_RPM_PATH" ]; then
    log "Downloading Ops Manager ${OM_VERSION}"
    OM_RPM_PATH="/tmp/${OM_RPM}"
    curl -fsSL --retry 3 "$OM_RPM_URL" -o "$OM_RPM_PATH"
  fi
  log "Verifying Ops Manager RPM signature"
  curl -fsSL "https://pgp.mongodb.com/opsmanager-${OM_VERSION%.*}.asc" -o "${WORK_DIR}/opsmanager.asc"
  rpm --import "${WORK_DIR}/opsmanager.asc"
  rpm -K "$OM_RPM_PATH"
}

# ---------------------------------------------------------------------------
# Step 2: AppDB - 3-node Enterprise replica set on one host (OM 9 pre-flight requires 3 nodes)
# ---------------------------------------------------------------------------
require_fresh_vm() {
  local community_packages=()
  mapfile -t community_packages < <(rpm -qa 'mongodb-org*')
  if [ "${#community_packages[@]}" -gt 0 ]; then
    printf 'This lab requires a fresh VM; Community MongoDB RPMs are installed:\n' >&2
    printf '  %s\n' "${community_packages[@]}" >&2
    die "Use a clean VM; this script intentionally does not convert Community installations."
  fi
}

install_appdb_packages() {
  log "Installing MongoDB Enterprise ${APPDB_VERSION} for the AppDB"
  rm -f /etc/yum.repos.d/mongodb-org.repo /etc/yum.repos.d/mongodb-enterprise-7.0.repo
  cat > /etc/yum.repos.d/mongodb-enterprise-8.0.repo <<EOF
[mongodb-enterprise-8.0]
name=MongoDB Enterprise Repository
baseurl=https://repo.mongodb.com/yum/amazon/2023/mongodb-enterprise/8.0/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
EOF
  dnf install -y mongodb-enterprise >/dev/null
}

# Extra AppDB member: own dbPath, config file and systemd unit.
write_appdb_member() {
  local port=$1
  mkdir -p "/var/lib/mongo-appdb-${port}"
  chown mongod:mongod "/var/lib/mongo-appdb-${port}"
  cat > "/etc/mongod-appdb-${port}.conf" <<EOF
storage:
  dbPath: /var/lib/mongo-appdb-${port}
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod-appdb-${port}.log
net:
  port: ${port}
  bindIp: 127.0.0.1
replication:
  replSetName: appdb
EOF
  cat > "/etc/systemd/system/mongod-appdb-${port}.service" <<EOF
[Unit]
Description=MongoDB AppDB member on port ${port}
After=network.target

[Service]
User=mongod
Group=mongod
ExecStart=/usr/bin/mongod -f /etc/mongod-appdb-${port}.conf
LimitNOFILE=64000

[Install]
WantedBy=multi-user.target
EOF
}

appdb_port_ready() { mongosh --quiet --port "$1" --eval "db.runCommand('ping')" >/dev/null 2>&1; }
appdb_has_primary() { [ "$(mongosh --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null)" = "true" ]; }

start_appdb() {
  local port fcv

  # First member uses the packaged mongod service.
  sed -i 's/^  bindIp:.*/  bindIp: 127.0.0.1/' /etc/mongod.conf
  grep -q "^replication:" /etc/mongod.conf || printf 'replication:\n  replSetName: appdb\n' >> /etc/mongod.conf
  systemctl enable --now mongod

  for port in "${APPDB_PORTS[@]:1}"; do write_appdb_member "$port"; done
  systemctl daemon-reload
  for port in "${APPDB_PORTS[@]:1}"; do systemctl enable --now "mongod-appdb-${port}"; done

  log "Waiting for all ${#APPDB_PORTS[@]} AppDB mongod processes to accept connections"
  for port in "${APPDB_PORTS[@]}"; do
    wait_for "mongod on ${port}" 30 2 appdb_port_ready "$port" || die "AppDB mongod on port ${port} did not start"
  done

  mongosh --quiet --eval '
    try { rs.status() } catch (e) {
      rs.initiate({_id: "appdb", members: [
        {_id: 0, host: "127.0.0.1:27017"}, {_id: 1, host: "127.0.0.1:27018"}, {_id: 2, host: "127.0.0.1:27019"}]})
    }' >/dev/null
  log "Waiting for an AppDB primary"
  wait_for "AppDB primary" 60 2 appdb_has_primary || die "AppDB replica set did not elect a primary"

  fcv=$(mongosh --quiet --eval 'db.adminCommand({getParameter: 1, featureCompatibilityVersion: 1}).featureCompatibilityVersion.version')
  if [ "$fcv" != "$APPDB_VERSION" ]; then
    log "Upgrading AppDB feature compatibility version to ${APPDB_VERSION}"
    mongosh --quiet --eval "db.adminCommand({setFeatureCompatibilityVersion: '${APPDB_VERSION}', confirm: true})" >/dev/null
  fi
  log "AppDB replica set 'appdb' is up on 127.0.0.1:${APPDB_PORTS[0]}-${APPDB_PORTS[-1]}"
}

# RESET_OM=1: drop Ops Manager state so a failed run can be repeated on the same VM.
reset_om_state() {
  [ "${RESET_OM:-0}" = "1" ] || return 0
  log "RESET_OM=1: wiping previous Ops Manager state"
  systemctl stop mongodb-mms-automation-agent mongodb-mms 2>/dev/null || true
  pkill -u mongodb-mms -x mongod 2>/dev/null || true
  mongosh --quiet --eval '
    db.adminCommand({listDatabases: 1}).databases
      .filter(d => !["admin", "local", "config"].includes(d.name))
      .forEach(d => db.getSiblingDB(d.name).dropDatabase())' >/dev/null
  if rpm -q mongodb-mms-automation-agent-manager >/dev/null 2>&1; then
    rpm -e mongodb-mms-automation-agent-manager
  fi
  rm -rf /var/lib/mongodb-mms-automation /var/log/mongodb-mms-automation /etc/mongodb-mms/automation-agent.config* \
    "$OPLOG_DIR" "$RS_DIR" "$BACKUP_HEAD_DIR" "$SNAPSHOT_STORE_DIR"
}

# ---------------------------------------------------------------------------
# Step 3: install and start Ops Manager
# ---------------------------------------------------------------------------
detect_ips() {
  local token
  token="$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)"
  imds() { curl -fsS -m 2 -H "X-aws-ec2-metadata-token: ${token}" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true; }

  PRIVATE_IP="$(imds local-ipv4)"
  [ -n "$PRIVATE_IP" ] || PRIVATE_IP="$(hostname -I | awk '{print $1}')"
  PUBLIC_IP="$(imds public-ipv4)"
  [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$PRIVATE_IP"
}

write_om_conf() {
  log "Writing ${OM_CONF}"
  local uri
  uri="mongodb://$(printf '127.0.0.1:%s,' "${APPDB_PORTS[@]}" | sed 's/,$//')/?replicaSet=appdb"
  sed -i '/^# native-om-lab begin/,/^# native-om-lab end/d' "$OM_CONF"
  # centralUrl uses the private IP: agents on this host time out on the instance's own public IP.
  cat >> "$OM_CONF" <<EOF
# native-om-lab begin
mongo.mongoUri=${uri}
mms.centralUrl=http://${PRIVATE_IP}:8080
mms.ignoreInitialUiSetup=true
mms.user.invitationOnly=true
mms.fromEmailAddr=mms-alerts@example.com
mms.replyToEmailAddr=mms-alerts@example.com
mms.adminEmailAddr=mms-admin@example.com
mms.mail.transport=smtp
mms.mail.hostname=localhost
mms.mail.port=25
# native-om-lab end
EOF
}

om_diagnostics() {
  echo "Ops Manager did not start. Diagnostics:" >&2
  systemctl status mongodb-mms --no-pager -l 2>&1 | head -20 >&2 || true
  tail -n 40 /opt/mongodb/mms/logs/mms0-startup.log /opt/mongodb/mms/logs/mms0.log >&2 2>&1 || true
}

# Ready on 200 or a redirect; bails out early if the service has died.
om_http_ready() {
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "${OM_LOCAL_URL}/user/login" || true)
  echo "  ${OM_LOCAL_URL} -> ${code:-none}"
  case "$code" in 200 | 30[1-8]) return 0 ;; esac
  OM_POLLS=$((OM_POLLS + 1))
  if [ "$OM_POLLS" -ge 8 ] && ! systemctl is-active --quiet mongodb-mms; then
    om_diagnostics
    exit 1
  fi
  return 1
}

install_and_start_om() {
  log "Installing Ops Manager ${OM_VERSION}"
  dnf install -y "$OM_RPM_PATH" >/dev/null
  write_om_conf
  systemctl enable --now mongodb-mms
  log "Waiting for Ops Manager HTTP (first boot takes a few minutes: migrations, then startup)"
  wait_for "Ops Manager" 40 15 om_http_ready || { om_diagnostics; exit 1; }
}

# ---------------------------------------------------------------------------
# Steps 4-6: first user, project, agent API key
# ---------------------------------------------------------------------------
bootstrap_admin() {
  log "Creating the first Ops Manager user via the unauth bootstrap API"
  local body response
  body=$(jq -n --arg u "$OM_ADMIN_USER" --arg p "$OM_ADMIN_PASSWORD" \
    '{username: $u, password: $p, emailAddress: $u, firstName: "Native", lastName: "Admin"}')
  # No --digest: curl sends an empty probe body first, which OM 9 rejects as INVALID_JSON.
  response=$(curl -sS --header "Content-Type: application/json" \
    --request POST "${OM_API}/unauth/users?whitelist=127.0.0.1" --data "$body")
  PUBLIC_KEY=$(jq -r '.programmaticApiKey.publicKey // empty' <<<"$response")
  PRIVATE_KEY=$(jq -r '.programmaticApiKey.privateKey // empty' <<<"$response")
  [ -n "$PUBLIC_KEY" ] || die "Failed to bootstrap first user. Response was: ${response}"
  log "Bootstrapped admin user ${OM_ADMIN_USER}"
}

create_project() {
  log "Creating project '${PROJECT_NAME}' (and its organization)"
  GROUP_ID=$(api --header "Content-Type: application/json" --request POST "${OM_API}/groups" \
    --data "$(jq -n --arg n "$PROJECT_NAME" '{name: $n}')" | jq -r '.id')
  AGENT_API_KEY=$(api --header "Content-Type: application/json" \
    --request POST "${OM_API}/groups/${GROUP_ID}/agentapikeys" \
    --data '{"desc": "native-lab-agent-key"}' | jq -r '.key')
  log "Project id: ${GROUP_ID}"
}

# ---------------------------------------------------------------------------
# Step 7: Automation Agent on this host
# ---------------------------------------------------------------------------
agent_registered() {
  HOSTNAME_IN_OM=$(api "${OM_API}/groups/${GROUP_ID}/agents/AUTOMATION" 2>/dev/null \
    | jq -r '.results[0].hostname // empty' 2>/dev/null || true)
  [ -n "$HOSTNAME_IN_OM" ]
}

install_automation_agent() {
  local rpm_file="${WORK_DIR}/automation-agent.rpm" agent_user
  log "Installing the Automation Agent matching this Ops Manager version"
  curl -fsSL -o "$rpm_file" "${OM_LOCAL_URL}/download/agent/automation/mongodb-mms-automation-agent-manager-latest.x86_64.rpm"
  dnf install -y "$rpm_file" >/dev/null

  sed -i "s|^mmsGroupId=.*|mmsGroupId=${GROUP_ID}|; s|^mmsApiKey=.*|mmsApiKey=${AGENT_API_KEY}|; s|^mmsBaseUrl=.*|mmsBaseUrl=${OM_LOCAL_URL}|" \
    /etc/mongodb-mms/automation-agent.config

  mkdir -p "$OPLOG_DIR" "$RS_DIR" "$BACKUP_HEAD_DIR"
  # The agent runs as its own service user (not mongodb-mms) and must own the mongod data dirs.
  agent_user="$(systemctl show -p User --value mongodb-mms-automation-agent)"
  agent_user="${agent_user:-mongod}"
  chown -R "${agent_user}:${agent_user}" "$OPLOG_DIR" "$RS_DIR"
  chown -R mongodb-mms:mongodb-mms "$BACKUP_HEAD_DIR"
  systemctl enable --now mongodb-mms-automation-agent

  log "Waiting for the Automation Agent to register this host with the project"
  wait_for "agent check-in" 30 10 agent_registered \
    || die "Automation Agent never checked in. Check: journalctl -u mongodb-mms-automation-agent"
  log "Host registered in Ops Manager as: ${HOSTNAME_IN_OM}"
}

# ---------------------------------------------------------------------------
# Step 8: automation config (oplog-rs + my-replica-set, monitoring and backup agents)
# ---------------------------------------------------------------------------
build_automation_config() {
  local current=$1 version_spec=$2 rs_ports_json
  rs_ports_json=$(printf '%s\n' "${RS_PORTS[@]}" | jq -sc .)
  jq \
    --arg host "$HOSTNAME_IN_OM" \
    --arg version "$MDB_VERSION" \
    --arg series "$MDB_SERIES" \
    --arg oplogDir "$OPLOG_DIR" \
    --arg rsDir "$RS_DIR" \
    --argjson oplogPort "$OPLOG_RS_PORT" \
    --argjson rsPorts "$rs_ports_json" \
    --slurpfile versionSpecFile <(echo "$version_spec") '
    def logrot: {sizeThresholdMB: 1000, timeThresholdHrs: 24};
    def agent($file): {hostname: $host, logPath: "/var/log/mongodb-mms-automation/\($file)", logRotate: logrot};
    def proc($name; $rs; $port; $dir): {
      name: $name, processType: "mongod", version: $version, hostname: $host,
      authSchemaVersion: 5, featureCompatibilityVersion: $series,
      args2_6: {net: {port: $port}, storage: {dbPath: $dir},
                systemLog: {destination: "file", path: "\($dir)/mongod.log"},
                replication: {replSetName: $rs}},
      logRotate: logrot};
    def rs($id; $names): {_id: $id, protocolVersion: "1",
      members: ($names | to_entries | map({_id: .key, host: .value, priority: 1, votes: 1}))};

    $versionSpecFile[0] as $spec
    | [range(0; $rsPorts | length) | "my-replica-set-\(.)"] as $rsNames
    | .auth.disabled = true
    | .version += 1
    | .monitoringVersions = [agent("monitoring-agent.log")]
    | .backupVersions = [agent("backup-agent.log")]
    | .mongoDbVersions = (((.mongoDbVersions // []) | map(select(.name != $spec.name))) + [$spec])
    | .processes += ([proc("oplog-rs-0"; "oplog-rs"; $oplogPort; $oplogDir)]
        + [range(0; $rsPorts | length) as $i
           | proc($rsNames[$i]; "my-replica-set"; $rsPorts[$i]; "\($rsDir)/rs\($i)")])
    | .replicaSets += [rs("oplog-rs"; ["oplog-rs-0"]), rs("my-replica-set"; $rsNames)]
  ' <<<"$current"
}

goal_reached() {
  local min
  min=$(api "${OM_API}/groups/${GROUP_ID}/automationStatus" \
    | jq '[.processes[].lastGoalVersionAchieved] | min // 0')
  echo "  goal version target=${TARGET_VERSION} min-achieved=${min}"
  [ "$min" -ge "$TARGET_VERSION" ]
}

push_automation_config() {
  log "Pushing automation config: Enterprise ${MDB_VERSION} oplog-rs (1 node) + my-replica-set (${#RS_PORTS[@]} nodes)"
  local version_spec current new_config="${WORK_DIR}/automation-config.json"

  version_spec=$(curl -fsSL "https://opsmanager.mongodb.com/static/version_manifest/${MDB_SERIES}.json" \
    | jq -ce --arg v "$MDB_VERSION" '.versions[] | select(.name == $v)')
  jq -e '[.builds[] | select(.platform == "linux" and .flavor == "amazon2023" and .architecture == "amd64"
         and (.modules | index("enterprise")))] | length > 0' <<<"$version_spec" >/dev/null \
    || die "Enterprise build ${MDB_VERSION} is not available for Amazon Linux 2023 x86_64."

  current=$(api "${OM_API}/groups/${GROUP_ID}/automationConfig")
  build_automation_config "$current" "$version_spec" > "$new_config"
  TARGET_VERSION=$(jq -r '.version' "$new_config")

  # Sent from a file: the config is too large for a command-line argument.
  api --header "Content-Type: application/json" --request PUT "${OM_API}/groups/${GROUP_ID}/automationConfig" \
    --data-binary "@${new_config}" -o /dev/null -w "PUT automationConfig -> HTTP %{http_code}\n"

  log "Waiting for the Automation Agent to reach goal state (downloads binaries, starts mongod processes)"
  wait_for "goal state" 60 15 goal_reached || die "Automation did not reach its goal version; refusing to configure backup."
}

# ---------------------------------------------------------------------------
# Step 9: backup via the Ops Manager API
# ---------------------------------------------------------------------------
configure_backup_daemon() {
  log "Configuring the Backup Daemon"
  local backup_api="${OM_API}/admin/backup" head="${BACKUP_HEAD_DIR}/" body match
  body=$(jq -n --arg machine "$HOSTNAME_IN_OM" --arg head "$head" \
    '{assignmentEnabled: true, backupJobsEnabled: true, configured: true,
      garbageCollectionEnabled: true, headDiskType: "SSD",
      machine: {headRootDirectory: $head, machine: $machine},
      numWorkers: 2, resourceUsageEnabled: true, restoreQueryableJobsEnabled: true}')
  match=$(api "${backup_api}/daemon/configs" | jq -r --arg machine "$HOSTNAME_IN_OM" --arg head "$head" \
    '[.results[]? | select(.machine.machine == $machine and .machine.headRootDirectory == $head)] | length')
  if [ "$match" -gt 0 ]; then
    api_send PUT "${backup_api}/daemon/configs/${HOSTNAME_IN_OM}/$(jq -rn --arg p "$head" '$p | @uri')" "$body"
  else
    api_send PUT "${backup_api}/daemon/configs/${HOSTNAME_IN_OM}/" "$body"
  fi
}

configure_backup_stores() {
  local backup_api="${OM_API}/admin/backup"
  log "Registering the filesystem snapshot store"
  upsert "${backup_api}/snapshot/fileSystemConfigs" "$FILE_SYSTEM_STORE_ID" "$(jq -n --arg path "$SNAPSHOT_STORE_DIR" \
    '{assignmentEnabled: true, loadFactor: 1, storePath: $path,
      mmapv1CompressionSetting: "NONE", wtCompressionSetting: "GZIP"}')"

  log "Registering oplog-rs as the Oplog Store"
  upsert "${backup_api}/oplog/mongoConfigs" "$OPLOG_STORE_ID" "$(jq -n \
    --arg uri "mongodb://127.0.0.1:${OPLOG_RS_PORT}/?replicaSet=oplog-rs" \
    '{assignmentEnabled: true, encryptedCredentials: false, uri: $uri, ssl: false, writeConcern: "ACKNOWLEDGED"}')"
}

cluster_id() {
  api "${OM_API}/groups/${GROUP_ID}/clusters" \
    | jq -r '[.results[] | select(.replicaSetName == "my-replica-set") | .id][0] // empty'
}

cluster_found() { CLUSTER_ID=$(cluster_id); [ -n "$CLUSTER_ID" ]; }

request_snapshot() {
  local response
  response=$(api --request POST \
    "${OM_API}/groups/${GROUP_ID}/clusters/${CLUSTER_ID}/snapshots/onDemandSnapshot?retentionDays=2" 2>"${WORK_DIR}/snapshot.err") || return 1
  ON_DEMAND_DESCRIPTION=$(jq -r '.description // "accepted"' <<<"$response")
}

enable_backup() {
  log "Enabling backup and configuring the snapshot schedule"
  mkdir -p "$BACKUP_HEAD_DIR" "$SNAPSHOT_STORE_DIR"
  chown -R mongodb-mms:mongodb-mms "$BACKUP_HEAD_DIR" "$SNAPSHOT_STORE_DIR"

  wait_for "my-replica-set cluster id" 20 15 cluster_found \
    || die "Ops Manager did not return the my-replica-set cluster ID."

  api_send PATCH "${OM_API}/groups/${GROUP_ID}/backupConfigs/${CLUSTER_ID}" \
    '{"statusName": "STARTED", "storageEngineName": "WIRED_TIGER", "syncSource": "primary"}'
  api_send PATCH "${OM_API}/groups/${GROUP_ID}/backupConfigs/${CLUSTER_ID}/snapshotSchedule" \
    '{"snapshotIntervalHours": 24, "snapshotRetentionDays": 2, "fullIncrementalDayOfWeek": "SUNDAY"}'

  wait_for "the Backup Daemon to accept the snapshot request" 20 15 request_snapshot || {
    cat "${WORK_DIR}/snapshot.err" >&2
    die "Backup was enabled, but Ops Manager did not accept the initial snapshot request."
  }
}

# ---------------------------------------------------------------------------
# Step 10: credentials and summary
# ---------------------------------------------------------------------------
print_summary() {
  (umask 077; cat > "$CREDS_FILE" <<EOF
Ops Manager URL: http://${PUBLIC_IP}:8080
Username:        ${OM_ADMIN_USER}
Password:        ${OM_ADMIN_PASSWORD}
EOF
  )
  cat <<EOF

===================================================================
Native Ops Manager lab is up.

HOW TO LOG IN:
  1. Open http://${PUBLIC_IP}:8080 in a browser
     (or tunnel: ssh -L 8080:localhost:8080 <user>@${PUBLIC_IP}, then http://localhost:8080)
  2. Username: ${OM_ADMIN_USER}
     Password: ${OM_ADMIN_PASSWORD}
  Also saved on this host at ${CREDS_FILE} (root-readable only).

  Project:          ${PROJECT_NAME}
  AppDB:            MongoDB Enterprise ${APPDB_VERSION} (${#APPDB_PORTS[@]} nodes, ports ${APPDB_PORTS[*]})
  Deployments:      MongoDB Enterprise ${MDB_VERSION}
                    oplog-rs (1 node, port ${OPLOG_RS_PORT})
                    my-replica-set (${#RS_PORTS[@]} nodes, ports ${RS_PORTS[*]})
  Backup:           enabled; filesystem store ${SNAPSHOT_STORE_DIR}
  Initial snapshot: ${ON_DEMAND_DESCRIPTION}
  Monitoring and backup agents take a few minutes to turn active in the UI.
===================================================================
EOF
}

# ---------------------------------------------------------------------------
main() {
  require_root
  install_prerequisites
  download_and_verify_om_rpm
  require_fresh_vm
  install_appdb_packages
  start_appdb
  reset_om_state
  detect_ips
  install_and_start_om
  bootstrap_admin
  create_project
  install_automation_agent
  push_automation_config
  configure_backup_daemon
  configure_backup_stores
  enable_backup
  print_summary
}

main "$@"
