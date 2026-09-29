#!/usr/bin/env bash
# native-ops-manager-lab.sh
#
# Single-VM, non-Kubernetes lab: installs Ops Manager directly on this EC2 host
# (Amazon Linux 2023, x86_64) using the traditional rpm-based install, backed by
# a single-node AppDB, and deploys a 3-node MongoDB replica set + a 1-node Oplog
# Store replica set through the Automation Agent - everything colocated on this
# one VM. Backup uses a Filesystem Snapshot Store (no Blockstore needed).
#
# Run as: sudo ./native-ops-manager-lab.sh
#
# Place the signed Ops Manager RPM beside this script before running; MongoDB's
# direct RPM URL returns 403. The Backup Daemon and Filesystem Store still need
# their one-time first-run configuration in the Ops Manager UI.
set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
OM_VERSION="8.0.26"
MDB_VERSION="7.0.14"
OM_RPM="mongodb-mms-${OM_VERSION}.x86_64.rpm"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
OM_RPM_PATH="${OM_RPM_PATH:-${SCRIPT_DIR}/${OM_RPM}}"

OM_ADMIN_USER="admin@example.com"
OM_ADMIN_PASSWORD="$(openssl rand -base64 18)Aa1!"
PROJECT_NAME="native-lab-project"

OPLOG_RS_PORT=37017
RS_PORTS=(37018 37019 37020)
BACKUP_HEAD_DIR="/data/backup_head"

log() { echo -e "\033[1;32m[native-om-lab]\033[0m $*"; }
api() { curl -sS --digest -u "${PUBLIC_KEY}:${PRIVATE_KEY}" "$@"; }

if [ "$(id -u)" -ne 0 ]; then
  echo "Run this script as root (sudo ./native-ops-manager-lab.sh)"; exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: base packages
# ---------------------------------------------------------------------------
log "Installing base packages (jq, openssl, initscripts)"
dnf install -y jq openssl initscripts >/dev/null

if [ ! -s "$OM_RPM_PATH" ]; then
  cat >&2 <<EOF
Ops Manager ${OM_VERSION} RPM is required before the lab can continue.
The direct downloads.mongodb.com URL returned HTTP 403, so download it from:
  https://www.mongodb.com/try/download/ops-manager
Select version ${OM_VERSION}, Amazon Linux 2023, RPM, then copy the file here:
  ${SCRIPT_DIR}/${OM_RPM}
Or rerun with OM_RPM_PATH=/absolute/path/to/${OM_RPM}.
The AppDB packages have not been changed by this run.
EOF
  exit 1
fi

log "Verifying Ops Manager RPM signature"
curl -fsSL "https://pgp.mongodb.com/opsmanager-${OM_VERSION%.*}.asc" -o /tmp/opsmanager-signing-key.asc
rpm --import /tmp/opsmanager-signing-key.asc
rpm -K "$OM_RPM_PATH"

# ---------------------------------------------------------------------------
# Step 2: AppDB - single-node MongoDB replica set backing Ops Manager itself
# ---------------------------------------------------------------------------
log "Installing MongoDB ${MDB_VERSION%.*} Enterprise for the AppDB"
community_packages=()
mapfile -t community_packages < <(rpm -qa 'mongodb-org*')
if [ "${#community_packages[@]}" -gt 0 ]; then
  log "Replacing Community RPMs with Enterprise RPMs; preserving /var/lib/mongo"
  cp -a /etc/mongod.conf /tmp/native-ops-manager-mongod.conf
  systemctl stop mongod || true
  dnf remove -y "${community_packages[@]}" >/dev/null
fi
rm -f /etc/yum.repos.d/mongodb-org.repo
cat > /etc/yum.repos.d/mongodb-enterprise-7.0.repo <<EOF
[mongodb-enterprise-7.0]
name=MongoDB Enterprise Repository
baseurl=https://repo.mongodb.com/yum/amazon/2023/mongodb-enterprise/7.0/\$basearch/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-7.0.asc
EOF
dnf install -y mongodb-enterprise >/dev/null
if [ -s /tmp/native-ops-manager-mongod.conf ]; then
  cp -a /tmp/native-ops-manager-mongod.conf /etc/mongod.conf
fi

sed -i 's/^  bindIp:.*/  bindIp: 127.0.0.1/' /etc/mongod.conf
if ! grep -q "^replication:" /etc/mongod.conf; then
  echo -e "replication:\n  replSetName: appdb" >> /etc/mongod.conf
fi
systemctl enable --now mongod

log "Waiting for AppDB mongod to accept connections"
for i in $(seq 1 30); do mongosh --quiet --eval "db.runCommand('ping')" >/dev/null 2>&1 && break; sleep 2; done

mongosh --quiet --eval '
  try { rs.status() } catch (e) { rs.initiate({_id:"appdb", members:[{_id:0, host:"127.0.0.1:27017"}]}) }
'
log "AppDB replica set 'appdb' is up on 127.0.0.1:27017"

# ---------------------------------------------------------------------------
# Step 3: install and start Ops Manager
# ---------------------------------------------------------------------------
log "Installing Ops Manager ${OM_VERSION}"
dnf install -y "$OM_RPM_PATH" >/dev/null

EC2_IP="$(curl -fsS -m 2 http://169.254.169.254/latest/meta-data/local-ipv4 || hostname -I | awk '{print $1}')"

CONF=/opt/mongodb/mms/conf/conf-mms.properties
log "Writing $CONF"
cat >> "$CONF" <<EOF

mongo.mongoUri=mongodb://127.0.0.1:27017/?replicaSet=appdb
mms.centralUrl=http://${EC2_IP}:8080
mms.ignoreInitialUiSetup=true
mms.user.invitationOnly=true
mms.fromEmailAddr=mms-alerts@example.com
mms.replyToEmailAddr=mms-alerts@example.com
mms.adminEmailAddr=mms-admin@example.com
mms.mail.transport=smtp
mms.mail.hostname=localhost
mms.mail.port=25
EOF

systemctl enable --now mongodb-mms

log "Waiting for Ops Manager HTTP to come up (first boot can take several minutes)"
for i in $(seq 1 60); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:8080/user/login" || true)
  echo "  http://localhost:8080 -> ${code:-none} ($i/60)"
  [ "$code" = "200" ] && break
  sleep 15
done

# ---------------------------------------------------------------------------
# Step 4: bootstrap the first user + Global Owner API key (fully headless)
# ---------------------------------------------------------------------------
log "Creating the first Ops Manager user via the unauth bootstrap API"
FIRST_USER_RESPONSE=$(curl -sS --digest -u "x:x" \
  --header "Content-Type: application/json" \
  --request POST "http://localhost:8080/api/public/v1.0/unauth/users?whitelist=0.0.0.0%2F0" \
  --data "{\"username\":\"${OM_ADMIN_USER}\",\"password\":\"${OM_ADMIN_PASSWORD}\",\"firstName\":\"Native\",\"lastName\":\"Admin\"}")

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
  --request POST "http://localhost:8080/api/public/v1.0/groups" \
  --data "{\"name\":\"${PROJECT_NAME}\"}")
GROUP_ID=$(echo "$PROJECT_RESPONSE" | jq -r '.id')
log "Project id: ${GROUP_ID}"

# ---------------------------------------------------------------------------
# Step 6: create an Agent API key for this project
# ---------------------------------------------------------------------------
AGENT_KEY_RESPONSE=$(api --header "Content-Type: application/json" \
  --request POST "http://localhost:8080/api/public/v1.0/groups/${GROUP_ID}/agentapikeys" \
  --data '{"desc":"native-lab-agent-key"}')
AGENT_API_KEY=$(echo "$AGENT_KEY_RESPONSE" | jq -r '.key')
log "Agent API key created"

# ---------------------------------------------------------------------------
# Step 7: install + configure the MongoDB Automation Agent on this same host
# ---------------------------------------------------------------------------
log "Downloading the Automation Agent build matching this Ops Manager version"
curl -fsSL -o /tmp/mongodb-mms-automation-agent-manager-latest.x86_64.rpm \
  "http://localhost:8080/download/agent/automation/mongodb-mms-automation-agent-manager-latest.x86_64.rpm"
dnf install -y /tmp/mongodb-mms-automation-agent-manager-latest.x86_64.rpm >/dev/null

AGENT_CONF=/etc/mongodb-mms/automation-agent.config
sed -i "s|^mmsGroupId=.*|mmsGroupId=${GROUP_ID}|; s|^mmsApiKey=.*|mmsApiKey=${AGENT_API_KEY}|; s|^mmsBaseUrl=.*|mmsBaseUrl=http://localhost:8080|" "$AGENT_CONF"

mkdir -p /data/oplog-rs /data/my-replica-set/rs0 /data/my-replica-set/rs1 /data/my-replica-set/rs2 "$BACKUP_HEAD_DIR"
chown -R mongodb-mms:mongodb-mms /data "$BACKUP_HEAD_DIR"

systemctl enable --now mongodb-mms-automation-agent

log "Waiting for the Automation Agent to register this host with the project"
HOSTNAME_IN_OM=""
for i in $(seq 1 30); do
  HOSTS_RESPONSE=$(api "http://localhost:8080/api/public/v1.0/groups/${GROUP_ID}/hosts")
  HOSTNAME_IN_OM=$(echo "$HOSTS_RESPONSE" | jq -r '.results[0].hostname // empty')
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
log "Pushing automation config: oplog-rs (1 node) + my-replica-set (3 nodes)"
CURRENT_CONFIG=$(api "http://localhost:8080/api/public/v1.0/groups/${GROUP_ID}/automationConfig")

NEW_CONFIG=$(echo "$CURRENT_CONFIG" | jq \
  --arg host "$HOSTNAME_IN_OM" \
  --arg version "$MDB_VERSION" \
  --argjson oplogPort "$OPLOG_RS_PORT" \
  --argjson p0 "${RS_PORTS[0]}" \
  --argjson p1 "${RS_PORTS[1]}" \
  --argjson p2 "${RS_PORTS[2]}" '
  .auth.disabled = true |
  .version += 1 |
  .processes += [
    {name:"oplog-rs-0", processType:"mongod", version:$version, hostname:$host,
     args2_6:{net:{port:$oplogPort}, storage:{dbPath:"/data/oplog-rs"},
              systemLog:{destination:"file", path:"/data/oplog-rs/mongod.log"},
              replication:{replSetName:"oplog-rs"}},
     logRotate:{sizeThresholdMB:1000, timeThresholdHrs:24}},
    {name:"my-replica-set-0", processType:"mongod", version:$version, hostname:$host,
     args2_6:{net:{port:$p0}, storage:{dbPath:"/data/my-replica-set/rs0"},
              systemLog:{destination:"file", path:"/data/my-replica-set/rs0/mongod.log"},
              replication:{replSetName:"my-replica-set"}},
     logRotate:{sizeThresholdMB:1000, timeThresholdHrs:24}},
    {name:"my-replica-set-1", processType:"mongod", version:$version, hostname:$host,
     args2_6:{net:{port:$p1}, storage:{dbPath:"/data/my-replica-set/rs1"},
              systemLog:{destination:"file", path:"/data/my-replica-set/rs1/mongod.log"},
              replication:{replSetName:"my-replica-set"}},
     logRotate:{sizeThresholdMB:1000, timeThresholdHrs:24}},
    {name:"my-replica-set-2", processType:"mongod", version:$version, hostname:$host,
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

api --header "Content-Type: application/json" \
  --request PUT "http://localhost:8080/api/public/v1.0/groups/${GROUP_ID}/automationConfig" \
  --data "$NEW_CONFIG" -o /dev/null -w "PUT automationConfig -> HTTP %{http_code}\n"

log "Waiting for the Automation Agent to reach goal state (deploys + starts mongod processes)"
TARGET_VERSION=$(echo "$NEW_CONFIG" | jq -r '.version')
for i in $(seq 1 60); do
  STATUS=$(api "http://localhost:8080/api/public/v1.0/groups/${GROUP_ID}/automationStatus")
  MIN_VERSION=$(echo "$STATUS" | jq '[.processes[].lastGoalVersionAchieved] | min // 0')
  echo "  goal version target=${TARGET_VERSION} min-achieved=${MIN_VERSION} ($i/60)"
  [ "$MIN_VERSION" -ge "$TARGET_VERSION" ] 2>/dev/null && break
  sleep 15
done

# ---------------------------------------------------------------------------
# Step 9: everything scriptable is done - print login info + the one manual backup step
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
  Deployments:     oplog-rs (1 node, port ${OPLOG_RS_PORT})
                   my-replica-set (3 nodes, ports ${RS_PORTS[*]})

-------------------------------------------------------------------
ONE MANUAL STEP - enabling Filesystem-store Backup
(Ops Manager has no stable public API for first-time Backup Daemon /
Snapshot Store setup - this is a short UI wizard.)

1. Log into the UI above, click Admin (top right) -> Backup tab.
2. Configure the Backup Daemon: set the head directory to
   ${BACKUP_HEAD_DIR}
3. Add Snapshot Storage -> choose "File System Store", point it at any
   local directory (e.g. /data/snapshots - create it with
   'sudo mkdir -p /data/snapshots && sudo chown mongodb-mms /data/snapshots').
4. Assign oplog-rs as the Oplog Store Database for this project.
5. Go to Deployment -> my-replica-set -> Backup tab -> Start/Enable Backup.
-------------------------------------------------------------------
EOF
