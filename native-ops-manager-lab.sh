#!/usr/bin/env bash
# native-ops-manager-lab.sh
#
# Single-VM, non-Kubernetes lab: installs Ops Manager directly on this EC2 host
# (Amazon Linux 2023, x86_64) using the traditional rpm-based install, backed by
# a 3-node AppDB, and deploys a 3-node MongoDB replica set + a 1-node Oplog
# Store replica set through the Automation Agent - everything colocated on this
# one VM. Backup uses a Filesystem Snapshot Store (no Blockstore needed).
#
# Run as: sudo ./native-ops-manager-lab.sh
#
# Downloads and verifies the signed Ops Manager RPM, then configures backup
# through the Ops Manager API without requiring UI setup.
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OM_VERSION="9.0.0"
OM_BUILD="9.0.0.500.20260921T1537Z"
OM_RPM="mongodb-mms-${OM_BUILD}.x86_64.rpm"
OM_RPM_URL="https://downloads.mongodb.com/on-prem-mms/rpm/${OM_RPM}"
APPDB_VERSION="8.0"
APPDB_PORTS=(27017 27018 27019)
MDB_VERSION="7.0.14-ent"
OM_LOCAL_URL="http://127.0.0.1:8080"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OM_RPM_PATH="${OM_RPM_PATH:-${SCRIPT_DIR}/${OM_RPM}}"

OM_ADMIN_USER="admin@example.com"
OM_ADMIN_PASSWORD="$(openssl rand -base64 18)Aa1!"
PROJECT_NAME="native-lab-project"

OPLOG_RS_PORT=37017
RS_PORTS=(37018 37019 37020)
BACKUP_HEAD_DIR="/data/backup_head"
SNAPSHOT_STORE_DIR="/data/snapshots"
FILE_SYSTEM_STORE_ID="native-lab-filesystem"
OPLOG_STORE_ID="native-lab-oplog"

log() { echo -e "\033[1;32m[native-om-lab]\033[0m $*"; }
api() { curl --fail-with-body -sS --digest -u "${PUBLIC_KEY}:${PRIVATE_KEY}" "$@"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root (sudo ./native-ops-manager-lab.sh)"; exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: base packages
# ---------------------------------------------------------------------------
log "Installing base packages and MongoDB Enterprise runtime dependencies"
dnf install -y jq openssl initscripts cyrus-sasl cyrus-sasl-gssapi \
  cyrus-sasl-plain krb5-libs openldap xz-libs >/dev/null

if [ ! -s "$OM_RPM_PATH" ]; then
  log "Downloading Ops Manager ${OM_VERSION}"
  OM_RPM_PATH="/tmp/${OM_RPM}"
  curl -fsSL --retry 3 "$OM_RPM_URL" -o "$OM_RPM_PATH"
fi

log "Verifying Ops Manager RPM signature"
curl -fsSL "https://pgp.mongodb.com/opsmanager-${OM_VERSION%.*}.asc" -o /tmp/opsmanager-signing-key.asc
rpm --import /tmp/opsmanager-signing-key.asc
rpm -K "$OM_RPM_PATH"

# ---------------------------------------------------------------------------
# Step 2: AppDB - 3-node replica set (one host) backing Ops Manager; OM 9 pre-flight requires 3 nodes
# ---------------------------------------------------------------------------
log "Installing MongoDB Enterprise ${APPDB_VERSION} for the AppDB"
community_packages=()
mapfile -t community_packages < <(rpm -qa 'mongodb-org*')
if [ "${#community_packages[@]}" -gt 0 ]; then
  printf 'This lab requires a fresh VM; Community MongoDB RPMs are installed:\n' >&2
  printf '  %s\n' "${community_packages[@]}" >&2
  echo "Use a clean VM; this script intentionally does not convert Community installations." >&2
  exit 1
fi
rm -f /etc/yum.repos.d/mongodb-org.repo
rm -f /etc/yum.repos.d/mongodb-enterprise-7.0.repo
cat > /etc/yum.repos.d/mongodb-enterprise-8.0.repo <<EOF
[mongodb-enterprise-8.0]
name=MongoDB Enterprise Repository
baseurl=https://repo.mongodb.com/yum/amazon/2023/mongodb-enterprise/8.0/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
EOF
dnf install -y mongodb-enterprise >/dev/null

sed -i 's/^  bindIp:.*/  bindIp: 127.0.0.1/' /etc/mongod.conf
if ! grep -q "^replication:" /etc/mongod.conf; then
  echo -e "replication:\n  replSetName: appdb" >> /etc/mongod.conf
fi
systemctl enable --now mongod

for port in 27018 27019; do
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
done
systemctl daemon-reload
systemctl enable --now mongod-appdb-27018 mongod-appdb-27019

log "Waiting for all 3 AppDB mongod processes to accept connections"
for port in "${APPDB_PORTS[@]}"; do
  for i in $(seq 1 30); do mongosh --quiet --port "$port" --eval "db.runCommand('ping')" >/dev/null 2>&1 && break; sleep 2; done
done

mongosh --quiet --eval '
  try { rs.status() } catch (e) {
    rs.initiate({_id:"appdb", members:[
      {_id:0, host:"127.0.0.1:27017"}, {_id:1, host:"127.0.0.1:27018"}, {_id:2, host:"127.0.0.1:27019"}]})
  }
'
log "Waiting for an AppDB primary"
for i in $(seq 1 60); do
  [ "$(mongosh --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null)" = "true" ] && break; sleep 2
done
APPDB_FCV=$(mongosh --quiet --eval 'db.adminCommand({getParameter:1,featureCompatibilityVersion:1}).featureCompatibilityVersion.version')
if [ "$APPDB_FCV" != "$APPDB_VERSION" ]; then
  log "Upgrading AppDB feature compatibility version to ${APPDB_VERSION}"
  mongosh --quiet --eval "db.adminCommand({setFeatureCompatibilityVersion:'${APPDB_VERSION}',confirm:true})"
fi
log "AppDB replica set 'appdb' is up on 127.0.0.1:27017-27019"

# RESET_OM=1 wipes Ops Manager state (users, projects, agent, managed mongods) so a failed run can be repeated.
if [ "${RESET_OM:-0}" = "1" ]; then
  log "RESET_OM=1: wiping previous Ops Manager state"
  systemctl stop mongodb-mms-automation-agent mongodb-mms 2>/dev/null || true
  pkill -u mongodb-mms -x mongod 2>/dev/null || true
  mongosh --quiet --eval '
    db.adminCommand({listDatabases:1}).databases
      .filter(d => !["admin","local","config"].includes(d.name))
      .forEach(d => db.getSiblingDB(d.name).dropDatabase())
  ' >/dev/null
  rpm -q mongodb-mms-automation-agent-manager >/dev/null 2>&1 && rpm -e mongodb-mms-automation-agent-manager
  rm -rf /var/lib/mongodb-mms-automation /var/log/mongodb-mms-automation /etc/mongodb-mms/automation-agent.config* \
    /data/oplog-rs /data/my-replica-set "$BACKUP_HEAD_DIR" "$SNAPSHOT_STORE_DIR"
fi

# ---------------------------------------------------------------------------
# Step 3: install and start Ops Manager
# ---------------------------------------------------------------------------
log "Installing Ops Manager ${OM_VERSION}"
dnf install -y "$OM_RPM_PATH" >/dev/null

# IMDSv2 (token required); prefer the public IP so browser redirects work.
IMDS_TOKEN="$(curl -fsS -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)"
imds() { curl -fsS -m 2 -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || true; }
EC2_IP="$(imds public-ipv4)"
[ -n "$EC2_IP" ] || EC2_IP="$(imds local-ipv4)"
[ -n "$EC2_IP" ] || EC2_IP="$(hostname -I | awk '{print $1}')"

CONF=/opt/mongodb/mms/conf/conf-mms.properties
log "Writing $CONF"
sed -i '/^# native-om-lab begin/,/^# native-om-lab end/d' "$CONF"
cat >> "$CONF" <<EOF
# native-om-lab begin
mongo.mongoUri=mongodb://127.0.0.1:27017,127.0.0.1:27018,127.0.0.1:27019/?replicaSet=appdb
mms.centralUrl=http://${EC2_IP}:8080
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

systemctl enable --now mongodb-mms

log "Waiting for Ops Manager HTTP to come up (first boot can take several minutes)"
OM_UP=false
for i in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "${OM_LOCAL_URL}/user/login" || true)
  echo "  ${OM_LOCAL_URL} -> ${code:-none} ($i/40)"
  case "$code" in 200|30[1-8]) OM_UP=true; break ;; esac
  if [ "$i" -ge 8 ] && ! systemctl is-active --quiet mongodb-mms; then break; fi
  sleep 15
done
if [ "$OM_UP" != true ]; then
  echo "Ops Manager did not start. Diagnostics:" >&2
  systemctl status mongodb-mms --no-pager -l 2>&1 | head -20 >&2 || true
  tail -n 40 /opt/mongodb/mms/logs/mms0-startup.log /opt/mongodb/mms/logs/mms0.log 2>&1 >&2 || true
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 4: bootstrap the first user + Global Owner API key (fully headless)
# ---------------------------------------------------------------------------
log "Creating the first Ops Manager user via the unauth bootstrap API"
FIRST_USER_BODY=$(jq -n --arg u "$OM_ADMIN_USER" --arg p "$OM_ADMIN_PASSWORD" \
  '{username:$u,password:$p,emailAddress:$u,firstName:"Native",lastName:"Admin"}')
# No --digest: curl sends an empty probe body first, which OM 9 rejects as INVALID_JSON.
FIRST_USER_RESPONSE=$(curl -sS \
  --header "Content-Type: application/json" \
  --request POST "${OM_LOCAL_URL}/api/public/v1.0/unauth/users?whitelist=127.0.0.1" \
  --data "$FIRST_USER_BODY")

PUBLIC_KEY=$(echo "$FIRST_USER_RESPONSE" | jq -r '.programmaticApiKey.publicKey')
PRIVATE_KEY=$(echo "$FIRST_USER_RESPONSE" | jq -r '.programmaticApiKey.privateKey')

if [ "$PUBLIC_KEY" = "null" ] || [ -z "$PUBLIC_KEY" ]; then
  echo "Failed to bootstrap first user. Response was:"; echo "$FIRST_USER_RESPONSE"; exit 1
fi
log "Bootstrapped admin user ${OM_ADMIN_USER} (password: ${OM_ADMIN_PASSWORD})"

# ---------------------------------------------------------------------------
# Step 5: create Organization + Project in one call
# ---------------------------------------------------------------------------
log "Creating project '${PROJECT_NAME}' (and its organization)"
PROJECT_RESPONSE=$(api --header "Content-Type: application/json" \
  --request POST "${OM_LOCAL_URL}/api/public/v1.0/groups" \
  --data "{\"name\":\"${PROJECT_NAME}\"}")
GROUP_ID=$(echo "$PROJECT_RESPONSE" | jq -r '.id')
log "Project id: ${GROUP_ID}"

# ---------------------------------------------------------------------------
# Step 6: create an Agent API key for this project
# ---------------------------------------------------------------------------
AGENT_KEY_RESPONSE=$(api --header "Content-Type: application/json" \
  --request POST "${OM_LOCAL_URL}/api/public/v1.0/groups/${GROUP_ID}/agentapikeys" \
  --data '{"desc":"native-lab-agent-key"}')
AGENT_API_KEY=$(echo "$AGENT_KEY_RESPONSE" | jq -r '.key')
log "Agent API key created"

# ---------------------------------------------------------------------------
# Step 7: install + configure the MongoDB Automation Agent on this same host
# ---------------------------------------------------------------------------
log "Downloading the Automation Agent build matching this Ops Manager version"
curl -fsSL -o /tmp/mongodb-mms-automation-agent-manager-latest.x86_64.rpm \
  "${OM_LOCAL_URL}/download/agent/automation/mongodb-mms-automation-agent-manager-latest.x86_64.rpm"
dnf install -y /tmp/mongodb-mms-automation-agent-manager-latest.x86_64.rpm >/dev/null

AGENT_CONF=/etc/mongodb-mms/automation-agent.config
sed -i "s|^mmsGroupId=.*|mmsGroupId=${GROUP_ID}|; s|^mmsApiKey=.*|mmsApiKey=${AGENT_API_KEY}|; s|^mmsBaseUrl=.*|mmsBaseUrl=${OM_LOCAL_URL}|" "$AGENT_CONF"

mkdir -p /data/oplog-rs /data/my-replica-set/rs0 /data/my-replica-set/rs1 /data/my-replica-set/rs2 "$BACKUP_HEAD_DIR"
# The agent runs as its own service user (not mongodb-mms) and must own the mongod data dirs.
AGENT_USER="$(systemctl show -p User --value mongodb-mms-automation-agent)"
AGENT_USER="${AGENT_USER:-mongod}"
chown -R "${AGENT_USER}:${AGENT_USER}" /data/oplog-rs /data/my-replica-set
chown -R mongodb-mms:mongodb-mms "$BACKUP_HEAD_DIR"

systemctl enable --now mongodb-mms-automation-agent

log "Waiting for the Automation Agent to register this host with the project"
HOSTNAME_IN_OM=""
for i in $(seq 1 30); do
  HOSTS_RESPONSE=$(api "${OM_LOCAL_URL}/api/public/v1.0/groups/${GROUP_ID}/agents/AUTOMATION" || true)
  HOSTNAME_IN_OM=$(echo "$HOSTS_RESPONSE" | jq -r '.results[0].hostname // empty' 2>/dev/null || true)
  [ -n "$HOSTNAME_IN_OM" ] && break
  echo "  waiting for agent check-in ($i/30)"; sleep 10
done
if [ -z "$HOSTNAME_IN_OM" ]; then
  echo "Automation Agent never checked in. Check: journalctl -u mongodb-mms-automation-agent"; exit 1
fi
log "Host registered in Ops Manager as: ${HOSTNAME_IN_OM}"

# ---------------------------------------------------------------------------
# Step 8: build and push the automation config (oplog store + 3-node RS)
# ---------------------------------------------------------------------------
log "Pushing automation config: Enterprise ${MDB_VERSION} oplog-rs (1 node) + my-replica-set (3 nodes)"
MDB_VERSION_SPEC=$(curl -fsSL "https://opsmanager.mongodb.com/static/version_manifest/7.0.json" | \
  jq -ce --arg version "$MDB_VERSION" '.versions[] | select(.name == $version)')
if ! echo "$MDB_VERSION_SPEC" | jq -e \
  '[.builds[] | select(.platform == "linux" and .flavor == "amazon2023" and .architecture == "amd64" and (.modules | index("enterprise")))] | length > 0' >/dev/null; then
  echo "Enterprise build ${MDB_VERSION} is not available for Amazon Linux 2023 x86_64." >&2
  exit 1
fi
CURRENT_CONFIG=$(api "${OM_LOCAL_URL}/api/public/v1.0/groups/${GROUP_ID}/automationConfig")

NEW_CONFIG=$(echo "$CURRENT_CONFIG" | jq \
  --arg host "$HOSTNAME_IN_OM" \
  --arg version "$MDB_VERSION" \
  --slurpfile versionSpecFile <(echo "$MDB_VERSION_SPEC") \
  --argjson oplogPort "$OPLOG_RS_PORT" \
  --argjson p0 "${RS_PORTS[0]}" \
  --argjson p1 "${RS_PORTS[1]}" \
  --argjson p2 "${RS_PORTS[2]}" '
  .auth.disabled = true |
  .monitoringVersions = [{hostname:$host, logPath:"/var/log/mongodb-mms-automation/monitoring-agent.log",
    logRotate:{sizeThresholdMB:1000, timeThresholdHrs:24}}] |
  .backupVersions = [{hostname:$host, logPath:"/var/log/mongodb-mms-automation/backup-agent.log",
    logRotate:{sizeThresholdMB:1000, timeThresholdHrs:24}}] |
  $versionSpecFile[0] as $versionSpec |
  .version += 1 |
  .mongoDbVersions = (((.mongoDbVersions // []) | map(select(.name != $versionSpec.name))) + [$versionSpec]) |
  .processes += [
    {name:"oplog-rs-0", processType:"mongod", version:$version, hostname:$host,
     authSchemaVersion:5, featureCompatibilityVersion:"7.0",
     args2_6:{net:{port:$oplogPort}, storage:{dbPath:"/data/oplog-rs"},
              systemLog:{destination:"file", path:"/data/oplog-rs/mongod.log"},
              replication:{replSetName:"oplog-rs"}},
     logRotate:{sizeThresholdMB:1000, timeThresholdHrs:24}},
    {name:"my-replica-set-0", processType:"mongod", version:$version, hostname:$host,
     authSchemaVersion:5, featureCompatibilityVersion:"7.0",
     args2_6:{net:{port:$p0}, storage:{dbPath:"/data/my-replica-set/rs0"},
              systemLog:{destination:"file", path:"/data/my-replica-set/rs0/mongod.log"},
              replication:{replSetName:"my-replica-set"}},
     logRotate:{sizeThresholdMB:1000, timeThresholdHrs:24}},
    {name:"my-replica-set-1", processType:"mongod", version:$version, hostname:$host,
     authSchemaVersion:5, featureCompatibilityVersion:"7.0",
     args2_6:{net:{port:$p1}, storage:{dbPath:"/data/my-replica-set/rs1"},
              systemLog:{destination:"file", path:"/data/my-replica-set/rs1/mongod.log"},
              replication:{replSetName:"my-replica-set"}},
     logRotate:{sizeThresholdMB:1000, timeThresholdHrs:24}},
    {name:"my-replica-set-2", processType:"mongod", version:$version, hostname:$host,
     authSchemaVersion:5, featureCompatibilityVersion:"7.0",
     args2_6:{net:{port:$p2}, storage:{dbPath:"/data/my-replica-set/rs2"},
              systemLog:{destination:"file", path:"/data/my-replica-set/rs2/mongod.log"},
              replication:{replSetName:"my-replica-set"}},
     logRotate:{sizeThresholdMB:1000, timeThresholdHrs:24}}
  ] |
  .replicaSets += [
    {_id:"oplog-rs", protocolVersion:"1", members:[{_id:0, host:"oplog-rs-0", priority:1, votes:1}]},
    {_id:"my-replica-set", protocolVersion:"1", members:[
        {_id:0, host:"my-replica-set-0", priority:1, votes:1},
        {_id:1, host:"my-replica-set-1", priority:1, votes:1},
        {_id:2, host:"my-replica-set-2", priority:1, votes:1}
    ]}
  ]
')

echo "$NEW_CONFIG" > /tmp/automation-config.json
api --header "Content-Type: application/json" \
  --request PUT "${OM_LOCAL_URL}/api/public/v1.0/groups/${GROUP_ID}/automationConfig" \
  --data-binary @/tmp/automation-config.json -o /dev/null -w "PUT automationConfig -> HTTP %{http_code}\n"

log "Waiting for the Automation Agent to reach goal state (deploys + starts mongod processes)"
TARGET_VERSION=$(echo "$NEW_CONFIG" | jq -r '.version')
for i in $(seq 1 60); do
  STATUS=$(api "${OM_LOCAL_URL}/api/public/v1.0/groups/${GROUP_ID}/automationStatus")
  MIN_VERSION=$(echo "$STATUS" | jq '[.processes[].lastGoalVersionAchieved] | min // 0')
  echo "  goal version target=${TARGET_VERSION} min-achieved=${MIN_VERSION} ($i/60)"
  [ "$MIN_VERSION" -ge "$TARGET_VERSION" ] 2>/dev/null && break
  sleep 15
done

# ---------------------------------------------------------------------------
# Step 9: configure backup entirely through the Ops Manager API
# ---------------------------------------------------------------------------
if [ "$MIN_VERSION" -lt "$TARGET_VERSION" ]; then
  echo "Automation did not reach its goal version; refusing to configure backup." >&2
  exit 1
fi

BACKUP_API="${OM_LOCAL_URL}/api/public/v1.0/admin/backup"
mkdir -p "$BACKUP_HEAD_DIR" "$SNAPSHOT_STORE_DIR"
chown -R mongodb-mms:mongodb-mms "$BACKUP_HEAD_DIR" "$SNAPSHOT_STORE_DIR"

log "Configuring the Backup Daemon"
BACKUP_DAEMONS=$(api "${BACKUP_API}/daemon/configs")
DAEMON_BODY=$(jq -n \
  --arg machine "$HOSTNAME_IN_OM" \
  --arg headRootDirectory "${BACKUP_HEAD_DIR}/" \
  '{assignmentEnabled:true,backupJobsEnabled:true,configured:true,
    garbageCollectionEnabled:true,headDiskType:"SSD",
    machine:{headRootDirectory:$headRootDirectory,machine:$machine},
    numWorkers:2,resourceUsageEnabled:true,restoreQueryableJobsEnabled:true}')
DAEMON_MATCH=$(echo "$BACKUP_DAEMONS" | jq -r \
  --arg machine "$HOSTNAME_IN_OM" \
  --arg head "${BACKUP_HEAD_DIR}/" \
  '[.results[]? | select(.machine.machine == $machine and .machine.headRootDirectory == $head)] | length')
if [ "$DAEMON_MATCH" -gt 0 ]; then
  HEAD_PATH_ENCODED=$(jq -rn --arg path "${BACKUP_HEAD_DIR}/" '$path | @uri')
  api --header "Content-Type: application/json" \
    --request PUT "${BACKUP_API}/daemon/configs/${HOSTNAME_IN_OM}/${HEAD_PATH_ENCODED}" \
    --data "$DAEMON_BODY" >/dev/null
else
  api --header "Content-Type: application/json" \
    --request PUT "${BACKUP_API}/daemon/configs/${HOSTNAME_IN_OM}/" \
    --data "$DAEMON_BODY" >/dev/null
fi

log "Registering the filesystem snapshot store"
FILESYSTEM_CONFIGS=$(api "${BACKUP_API}/snapshot/fileSystemConfigs")
FILESYSTEM_EXISTS=$(echo "$FILESYSTEM_CONFIGS" | jq -r \
  --arg id "$FILE_SYSTEM_STORE_ID" \
  '[.results[]? | select(.id == $id)] | length')
if [ "$FILESYSTEM_EXISTS" -gt 0 ]; then
  FILESYSTEM_BODY=$(jq -n --arg path "$SNAPSHOT_STORE_DIR" \
    '{assignmentEnabled:true,loadFactor:1,storePath:$path,mmapv1CompressionSetting:"NONE",wtCompressionSetting:"GZIP"}')
  api --header "Content-Type: application/json" \
    --request PUT "${BACKUP_API}/snapshot/fileSystemConfigs/${FILE_SYSTEM_STORE_ID}" \
    --data "$FILESYSTEM_BODY" >/dev/null
else
  FILESYSTEM_BODY=$(jq -n --arg id "$FILE_SYSTEM_STORE_ID" --arg path "$SNAPSHOT_STORE_DIR" \
    '{assignmentEnabled:true,id:$id,loadFactor:1,storePath:$path,mmapv1CompressionSetting:"NONE",wtCompressionSetting:"GZIP"}')
  api --header "Content-Type: application/json" \
    --request POST "${BACKUP_API}/snapshot/fileSystemConfigs" \
    --data "$FILESYSTEM_BODY" >/dev/null
fi

log "Registering oplog-rs as the Oplog Store"
OPLOG_CONFIGS=$(api "${BACKUP_API}/oplog/mongoConfigs")
OPLOG_EXISTS=$(echo "$OPLOG_CONFIGS" | jq -r \
  --arg id "$OPLOG_STORE_ID" \
  '[.results[]? | select(.id == $id)] | length')
OPLOG_URI="mongodb://127.0.0.1:${OPLOG_RS_PORT}/?replicaSet=oplog-rs"
if [ "$OPLOG_EXISTS" -gt 0 ]; then
  OPLOG_BODY=$(jq -n --arg uri "$OPLOG_URI" \
    '{assignmentEnabled:true,encryptedCredentials:false,uri:$uri,ssl:false,writeConcern:"ACKNOWLEDGED"}')
  api --header "Content-Type: application/json" \
    --request PUT "${BACKUP_API}/oplog/mongoConfigs/${OPLOG_STORE_ID}" \
    --data "$OPLOG_BODY" >/dev/null
else
  OPLOG_BODY=$(jq -n --arg id "$OPLOG_STORE_ID" --arg uri "$OPLOG_URI" \
    '{assignmentEnabled:true,encryptedCredentials:false,id:$id,uri:$uri,ssl:false,writeConcern:"ACKNOWLEDGED"}')
  api --header "Content-Type: application/json" \
    --request POST "${BACKUP_API}/oplog/mongoConfigs" \
    --data "$OPLOG_BODY" >/dev/null
fi

log "Enabling backup and configuring the snapshot schedule"
CLUSTERS=$(api "${OM_LOCAL_URL}/api/public/v1.0/groups/${GROUP_ID}/clusters")
CLUSTER_ID=$(echo "$CLUSTERS" | jq -r \
  '[.results[] | select(.replicaSetName == "my-replica-set") | .id][0] // empty')
if [ -z "$CLUSTER_ID" ]; then
  echo "Ops Manager did not return the my-replica-set cluster ID." >&2
  exit 1
fi

api --header "Content-Type: application/json" \
  --request PATCH "${OM_LOCAL_URL}/api/public/v1.0/groups/${GROUP_ID}/backupConfigs/${CLUSTER_ID}" \
  --data '{"statusName":"STARTED","storageEngineName":"WIRED_TIGER","syncSource":"primary"}' >/dev/null
api --header "Content-Type: application/json" \
  --request PATCH "${OM_LOCAL_URL}/api/public/v1.0/groups/${GROUP_ID}/backupConfigs/${CLUSTER_ID}/snapshotSchedule" \
  --data '{"snapshotIntervalHours":24,"snapshotRetentionDays":2,"fullIncrementalDayOfWeek":"SUNDAY"}' >/dev/null
ON_DEMAND_RESPONSE=""
for i in $(seq 1 20); do
  if ON_DEMAND_RESPONSE=$(api --request POST \
    "${OM_LOCAL_URL}/api/public/v1.0/groups/${GROUP_ID}/clusters/${CLUSTER_ID}/snapshots/onDemandSnapshot?retentionDays=2" 2>/tmp/native-ops-manager-snapshot-api.err); then
    break
  fi
  echo "  waiting for the Backup Daemon to accept the snapshot request ($i/20)"
  sleep 15
done
if [ -z "$ON_DEMAND_RESPONSE" ]; then
  cat /tmp/native-ops-manager-snapshot-api.err >&2
  echo "Backup was enabled, but Ops Manager did not accept the initial snapshot request." >&2
  exit 1
fi
ON_DEMAND_DESCRIPTION=$(echo "$ON_DEMAND_RESPONSE" | jq -r '.description // "accepted"')

# ---------------------------------------------------------------------------
# Step 10: print login information and automated backup result
# ---------------------------------------------------------------------------
CREDS_FILE=/root/ops-manager-credentials.txt
cat > "$CREDS_FILE" <<EOF
Ops Manager URL: http://${EC2_IP}:8080
Username:        ${OM_ADMIN_USER}
Password:        ${OM_ADMIN_PASSWORD}
EOF
chmod 600 "$CREDS_FILE"

cat <<EOF

===================================================================
Native Ops Manager lab is up.

HOW TO LOG IN:
  1. Open http://${EC2_IP}:8080 in a browser
     (from your laptop instead: ssh -L 8080:localhost:8080 <user>@${EC2_IP}
      then browse to http://localhost:8080)
  2. Username: ${OM_ADMIN_USER}
     Password: ${OM_ADMIN_PASSWORD}
  These are also saved on this host at ${CREDS_FILE} (root-readable only)
  in case you lose this terminal output - copy them somewhere safe now.

  Project:         ${PROJECT_NAME}
  AppDB:           MongoDB Enterprise ${APPDB_VERSION} (1 node)
  Deployments:     MongoDB Enterprise ${MDB_VERSION}
                   oplog-rs (1 node, port ${OPLOG_RS_PORT})
                   my-replica-set (3 nodes, ports ${RS_PORTS[*]})
  Backup:          enabled; filesystem store ${SNAPSHOT_STORE_DIR}
  Initial snapshot: ${ON_DEMAND_DESCRIPTION}
EOF
