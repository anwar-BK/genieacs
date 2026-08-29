#!/usr/bin/env bash
# GenieACS Adaptive Auto Installer v4.0.0
# Supports: Ubuntu 20/22/24, Debian 12, Armbian Ubuntu/Debian, amd64/arm64.
# MongoDB version/backend is selected from OS + architecture + kernel, then
# verified by a real mongod ping before GenieACS is started.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="4.0.0"
GENIEACS_VERSION="1.2.16"
NODE_MAJOR="22"
MONGO_DB="genieacs"
GENIEACS_USER="genieacs"
GENIEACS_HOME="/opt/genieacs"
GENIEACS_ENV="${GENIEACS_HOME}/genieacs.env"
GENIEACS_EXT_DIR="${GENIEACS_HOME}/ext"
GENIEACS_LOG_DIR="/var/log/genieacs"
BACKUP_ROOT="/var/backups/genieacs"
LOG_FILE="/var/log/genieacs-installer.log"
DB_DIR=""
MONGO_MODE=""
MONGO_MAJOR=""
MONGO_IMAGE=""
MONGO_CONTAINER="genieacs-mongodb"
MONGO_DATA_DIR="/var/lib/genieacs-mongodb"
MONGO_UNIT="genieacs-mongodb.service"
MONGO_URI="mongodb://127.0.0.1:27017/genieacs"
EXTERNAL_MONGO_URI=""
AUTO_YES=false
RESTORE_DB=false
SKIP_DB=false
NO_TELEGRAM=false

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="${SCRIPT_DIR}/db"
HOSTNAME_NOW="$(hostname 2>/dev/null || true)"
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; LOCAL_IP="${LOCAL_IP:-127.0.0.1}"
OS_ID=""; OS_CODENAME=""; PRETTY_NAME=""; ARCH=""; INIT_SYSTEM=""; KERNEL_RELEASE="$(uname -r)"
IS_ARMBIAN=false
KMAJOR=0; KMINOR=0; KPATCH=0
GENIEACS_BIN_DIR=""
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

log(){ printf '%b[%s]%b %s\n' "$CYAN" "$(date '+%F %T')" "$NC" "$1"; }
ok(){ printf '%b✔%b %s\n' "$GREEN" "$NC" "$1"; }
warn(){ printf '%b⚠%b %s\n' "$YELLOW" "$NC" "$1"; }
die(){ printf '%b✘%b %s\n' "$RED" "$NC" "$1" >&2; exit 1; }

send_telegram(){
  [[ "$NO_TELEGRAM" == true || -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]] && return 0
  curl -fsS --connect-timeout 10 --max-time 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || warn "Telegram gagal dikirim."
}

on_error(){
  local rc=$? line="${1:-unknown}"
  printf '\n%bINSTALLER GAGAL%b line=%s exit=%s\n' "$RED" "$NC" "$line" "$rc"
  systemctl --failed --no-pager 2>/dev/null || true
  systemctl status mongod --no-pager -l 2>/dev/null || true
  journalctl -u mongod --no-pager -n 80 2>/dev/null || true
  systemctl status "$MONGO_UNIT" --no-pager -l 2>/dev/null || true
  journalctl -u "$MONGO_UNIT" --no-pager -n 80 2>/dev/null || true
  send_telegram "❌ GenieACS installer FAILED\nServer: ${HOSTNAME_NOW}\nIP: ${LOCAL_IP}\nOS: ${PRETTY_NAME}\nArch: ${ARCH}\nKernel: ${KERNEL_RELEASE}\nLine: ${line}\nExit: ${rc}"
  exit "$rc"
}
trap 'on_error $LINENO' ERR

usage(){ cat <<USAGE
GenieACS Adaptive Auto Installer v${SCRIPT_VERSION}

Usage:
  sudo bash ${0##*/} [options]

Options:
  --yes, -y             Non-interactive.
  --restore-db          Restore ${SCRIPT_DIR}/db (or db/genieacs) after install.
  --skip-db             Do not install local MongoDB.
  --mongo-uri URI       Use external MongoDB; implies --skip-db.
  --no-telegram         Disable Telegram notifications.
  --help, -h            Show help.

The installer chooses MongoDB automatically. It does NOT force MongoDB 8.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) AUTO_YES=true;;
    --restore-db) RESTORE_DB=true;;
    --skip-db) SKIP_DB=true;;
    --mongo-uri) [[ $# -ge 2 ]] || die "--mongo-uri membutuhkan URI"; EXTERNAL_MONGO_URI="$2"; shift;;
    --no-telegram) NO_TELEGRAM=true;;
    --help|-h) usage; exit 0;;
    *) die "Opsi tidak dikenal: $1";;
  esac
  shift
done

[[ $(id -u) -eq 0 ]] || die "Jalankan sebagai root."
[[ -r /etc/os-release ]] || die "/etc/os-release tidak ditemukan."
source /etc/os-release
OS_ID="${ID:-unknown}"; OS_CODENAME="${VERSION_CODENAME:-} "; OS_CODENAME="${OS_CODENAME// /}"
PRETTY_NAME="${PRETTY_NAME:-${OS_ID} ${VERSION_ID:-}}"
ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
INIT_SYSTEM="$(ps -p 1 -o comm= 2>/dev/null || true)"
[[ -f /etc/armbian-release ]] && IS_ARMBIAN=true
[[ "$INIT_SYSTEM" == "systemd" ]] || die "systemd diperlukan; PID1=${INIT_SYSTEM}"

IFS='.' read -r KMAJOR KMINOR KPATCH _ <<< "${KERNEL_RELEASE%%-*}"
KMAJOR=${KMAJOR:-0}; KMINOR=${KMINOR:-0}; KPATCH=${KPATCH:-0}

kernel_affected(){
  (( KMAJOR == 6 && KMINOR >= 19 )) && return 0
  (( KMAJOR == 7 && KMINOR == 0 && KPATCH <= 13 )) && return 0
  return 1
}

printf '\n%b============================================================%b\n' "$GREEN" "$NC"
printf '%b GenieACS Adaptive Auto Installer v%s%b\n' "$GREEN" "$SCRIPT_VERSION" "$NC"
printf '%b GenieACS %s | Node.js %s LTS | MongoDB AUTO%b\n' "$GREEN" "$GENIEACS_VERSION" "$NODE_MAJOR" "$NC"
printf '%b============================================================%b\n\n' "$GREEN" "$NC"

case "$ARCH" in amd64|arm64) ;; *) die "Architecture ${ARCH:-unknown} tidak didukung; gunakan amd64/arm64.";; esac
case "$OS_ID:$OS_CODENAME" in
  ubuntu:focal|ubuntu:jammy|ubuntu:noble|debian:bookworm) ;;
  *) die "OS/codename tidak didukung: ${OS_ID}/${OS_CODENAME:-unknown}. Target: Ubuntu 20/22/24 atau Debian 12.";;
esac

log "Host=${HOSTNAME_NOW} | IP=${LOCAL_IP} | OS=${PRETTY_NAME} | code=${OS_CODENAME} | arch=${ARCH} | kernel=${KERNEL_RELEASE} | Armbian=${IS_ARMBIAN}"

# CPU checks: MongoDB requires AVX on x86_64 and ARMv8.2-A on arm64.
if [[ "$ARCH" == amd64 ]] && ! grep -qm1 -E '\bavx\b' /proc/cpuinfo 2>/dev/null; then
  die "CPU x86_64 tidak menunjukkan AVX; MongoDB 5+ tidak didukung pada CPU ini."
fi
if [[ "$ARCH" == arm64 ]]; then
  # We deliberately do not guess from one optional CPU flag. MongoDB itself is
  # the authority: install/start is followed by a real ping. Warn only here.
  warn "ARM64 terdeteksi. MongoDB membutuhkan ARMv8.2-A atau lebih baru; kemampuan CPU akan divalidasi lagi saat mongod start."
fi

MEM_MB="$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
DISK_GB="$(df -Pk / | awk 'NR==2 {printf "%d", $4/1024/1024}')"
(( DISK_GB >= 8 )) || die "Disk kosong hanya ${DISK_GB} GB; minimal 8 GB disarankan."
(( MEM_MB >= 1024 )) || warn "RAM ${MEM_MB} MB; 1 GB+ disarankan."

if [[ -n "$EXTERNAL_MONGO_URI" ]]; then SKIP_DB=true; MONGO_URI="$EXTERNAL_MONGO_URI"; fi
[[ "$RESTORE_DB" == true && "$SKIP_DB" == true ]] && die "--restore-db tidak boleh bersama --skip-db/--mongo-uri."

# -----------------------------------------------------------------------------
# Adaptive MongoDB policy
# -----------------------------------------------------------------------------
# Ubuntu 20/22: MongoDB 7 is officially supported and is the fallback for the
# affected 6.19..7.0.13 kernel range. Otherwise use MongoDB 8.
# Ubuntu 24: MongoDB 8 is the supported major. On affected kernels we use the
# official mongo:7.0-jammy container as a compatibility fallback (container
# userspace is Jammy); startup is still tested before GenieACS continues.
# Debian 12 amd64: MongoDB 8 native when kernel is safe; Docker 7 fallback on
# affected kernels. Debian 12 arm64 uses official Docker image because the
# Community platform matrix lists Debian 12 only for x86_64.
# The official Docker image publishes MongoDB 7 for amd64 and arm64.
# -----------------------------------------------------------------------------
select_mongodb(){
  if [[ "$OS_ID" == ubuntu ]]; then
    if kernel_affected; then
      if [[ "$OS_CODENAME" == focal || "$OS_CODENAME" == jammy ]]; then
        MONGO_MAJOR="7.0"; MONGO_MODE="native"
      else
        MONGO_MAJOR="7.0"; MONGO_MODE="docker"
      fi
    else
      MONGO_MAJOR="8.0"; MONGO_MODE="native"
    fi
  else
    if [[ "$ARCH" == amd64 && ! kernel_affected ]]; then
      MONGO_MAJOR="8.0"; MONGO_MODE="native"
    else
      MONGO_MAJOR="7.0"; MONGO_MODE="docker"
    fi
  fi
  MONGO_IMAGE="mongo:${MONGO_MAJOR}"
  [[ "$MONGO_MODE" == docker && "$MONGO_MAJOR" == 7.0 ]] && MONGO_IMAGE="mongo:7.0-jammy"
}

if [[ "$SKIP_DB" == false ]]; then select_mongodb; else MONGO_MODE=external; fi

if [[ "$AUTO_YES" != true ]]; then
  cat <<EOF2

Target:
  OS            : ${PRETTY_NAME}
  Architecture : ${ARCH}
  Kernel        : ${KERNEL_RELEASE}
  RAM           : ${MEM_MB} MB
  Disk          : ${DISK_GB} GB free
  MongoDB       : $([[ "$SKIP_DB" == true ]] && echo external || echo "${MONGO_MAJOR} (${MONGO_MODE})")
  GenieACS      : ${GENIEACS_VERSION}
  Node.js       : ${NODE_MAJOR}.x
  Restore DB    : ${RESTORE_DB}

Lanjutkan? (y/n)
EOF2
  read -r ans; [[ "$ans" =~ ^[Yy]$ ]] || { ok "Dibatalkan."; exit 0; }
fi

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl jq lsb-release logrotate procps iproute2 tar gzip xz-utils rsync build-essential python3

install_node(){
  local cur=""
  if command -v node >/dev/null 2>&1; then cur="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"; fi
  if [[ "$cur" != "$NODE_MAJOR" ]]; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource.sh
    bash /tmp/nodesource.sh
    apt-get install -y nodejs
    rm -f /tmp/nodesource.sh
  fi
  command -v node >/dev/null && command -v npm >/dev/null || die "Node/npm tidak tersedia."
  cur="$(node -p 'process.versions.node.split(".")[0]')"
  [[ "$cur" == "$NODE_MAJOR" ]] || die "Node.js ${cur} terpasang, diperlukan ${NODE_MAJOR}.x."
  ok "Node $(node -v), npm $(npm -v)"
}

write_mongo_conf(){
  install -d -m 0755 /var/lib/mongodb /var/log/mongodb
  chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb 2>/dev/null || true
  if [[ ! -f /etc/mongod.conf ]]; then
    cat >/etc/mongod.conf <<'MONGOCONF'
storage:
  dbPath: /var/lib/mongodb
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log
net:
  port: 27017
  bindIp: 127.0.0.1
processManagement:
  timeZoneInfo: /usr/share/zoneinfo
MONGOCONF
    chmod 0644 /etc/mongod.conf
  fi
}

mongo_ping(){
  if [[ "$MONGO_MODE" == native ]]; then
    mongosh --quiet --host 127.0.0.1 --port 27017 --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx 1
  elif [[ "$MONGO_MODE" == docker ]]; then
    docker exec "$MONGO_CONTAINER" mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx 1
  else
    mongosh --quiet "$MONGO_URI" --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx 1
  fi
}

wait_mongo(){
  local n="${1:-90}"
  for ((i=1;i<=n;i++)); do mongo_ping && { ok "MongoDB ping OK."; return 0; }; sleep 1; done
  return 1
}

prepare_native_mongo_version(){
  local installed="" installed_major=""
  if dpkg-query -W -f='${Version}\n' mongodb-org-server 2>/dev/null | grep -q .; then
    installed="$(dpkg-query -W -f='${Version}' mongodb-org-server 2>/dev/null || true)"
    installed_major="${installed%%.*}"
    if [[ -n "$installed_major" && "$installed_major" != "${MONGO_MAJOR%%.*}" ]]; then
      warn "MongoDB ${installed_major} terpasang tetapi policy memilih ${MONGO_MAJOR}."
      systemctl stop mongod 2>/dev/null || true
      if find /var/lib/mongodb -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
        die "Data MongoDB ditemukan di /var/lib/mongodb. Installer tidak akan melakukan downgrade major otomatis. Backup/migrasikan database terlebih dahulu."
      fi
      apt-get remove -y mongodb-org mongodb-org-database mongodb-org-server mongodb-mongos mongodb-org-mongos mongodb-org-shell mongodb-org-tools mongodb-database-tools mongodb-org-database-tools-extra mongodb-mongosh 2>/dev/null || true
      apt-get autoremove -y 2>/dev/null || true
    fi
  fi
}

install_mongo_native(){
  prepare_native_mongo_version
  local keyring="/usr/share/keyrings/mongodb-server-${MONGO_MAJOR}.gpg"
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL "https://pgp.mongodb.com/server-${MONGO_MAJOR}.asc" | gpg --dearmor --yes -o "$keyring"
  chmod 0644 "$keyring"
  rm -f /etc/apt/sources.list.d/mongodb-org-*.list
  if [[ "$OS_ID" == ubuntu ]]; then
    printf 'deb [ arch=amd64,arm64 signed-by=%s ] https://repo.mongodb.org/apt/ubuntu %s/mongodb-org/%s multiverse\n' "$keyring" "$OS_CODENAME" "$MONGO_MAJOR" > "/etc/apt/sources.list.d/mongodb-org-${MONGO_MAJOR}.list"
  else
    printf 'deb [ arch=amd64 signed-by=%s ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/%s main\n' "$keyring" "$MONGO_MAJOR" > "/etc/apt/sources.list.d/mongodb-org-${MONGO_MAJOR}.list"
  fi
  apt-get update
  apt-get install -y mongodb-org mongodb-mongosh mongodb-database-tools
  write_mongo_conf
  systemctl daemon-reload
  systemctl enable mongod
  systemctl restart mongod
  wait_mongo 90 || { journalctl -u mongod --no-pager -n 120 || true; return 1; }
}

install_mongo_docker(){
  apt-get install -y docker.io
  systemctl enable --now docker
  install -d -m 0755 "$MONGO_DATA_DIR"
  if docker container inspect "$MONGO_CONTAINER" >/dev/null 2>&1; then
    local image
    image="$(docker inspect -f '{{.Config.Image}}' "$MONGO_CONTAINER")"
    [[ "$image" == "$MONGO_IMAGE" ]] || die "Container ${MONGO_CONTAINER} sudah memakai ${image}; tidak akan dihapus otomatis."
  else
    docker pull "$MONGO_IMAGE"
    docker create --name "$MONGO_CONTAINER" --restart=no -p 127.0.0.1:27017:27017 -v "${MONGO_DATA_DIR}:/data/db" "$MONGO_IMAGE" mongod --bind_ip_all --wiredTigerCacheSizeGB 0.25 >/dev/null
  fi
  cat > "/etc/systemd/system/${MONGO_UNIT}" <<EOF2
[Unit]
Description=GenieACS MongoDB container
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/docker start -a ${MONGO_CONTAINER}
ExecStop=/usr/bin/docker stop -t 30 ${MONGO_CONTAINER}
Restart=always
RestartSec=5
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF2
  if [[ "$(docker inspect -f '{{.State.Running}}' "$MONGO_CONTAINER" 2>/dev/null || echo false)" == true ]]; then docker stop -t 30 "$MONGO_CONTAINER" >/dev/null; fi
  systemctl daemon-reload
  systemctl enable --now "$MONGO_UNIT"
  wait_mongo 120 || { docker logs --tail 160 "$MONGO_CONTAINER" || true; return 1; }
}

install_local_mongo(){
  log "MongoDB selection: ${MONGO_MAJOR} / ${MONGO_MODE} / image=${MONGO_IMAGE:-native}"
  if [[ "$MONGO_MODE" == native ]]; then
    install_mongo_native || die "MongoDB ${MONGO_MAJOR} native gagal start."
  else
    install_mongo_docker || die "MongoDB ${MONGO_MAJOR} Docker gagal start."
  fi
}

install_node
[[ "$SKIP_DB" == true ]] || install_local_mongo

if [[ "$MONGO_MODE" == external ]]; then
  command -v mongosh >/dev/null 2>&1 || apt-get install -y mongodb-mongosh || true
  if command -v mongosh >/dev/null 2>&1; then
    mongosh --quiet "$MONGO_URI" --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx 1 || die "External MongoDB ping gagal."
  else
    warn "mongosh tidak tersedia untuk ping external MongoDB; akan diverifikasi oleh GenieACS."
  fi
fi

install_genieacs(){
  local installed=""
  installed="$(npm list -g --depth=0 --json 2>/dev/null | jq -r '.dependencies.genieacs.version // empty' 2>/dev/null || true)"
  if [[ "$installed" != "$GENIEACS_VERSION" ]]; then npm install -g --unsafe-perm "genieacs@${GENIEACS_VERSION}"; fi
  for b in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do command -v "$b" >/dev/null || die "$b tidak ditemukan."; done
  GENIEACS_BIN_DIR="$(dirname "$(command -v genieacs-cwmp)")"
  installed="$(npm list -g --depth=0 --json 2>/dev/null | jq -r '.dependencies.genieacs.version // empty' 2>/dev/null || true)"
  [[ "$installed" == "$GENIEACS_VERSION" ]] || die "GenieACS version mismatch: ${installed:-unknown}"
  ok "GenieACS ${installed} terpasang."
}
install_genieacs

id "$GENIEACS_USER" >/dev/null 2>&1 || useradd --system --no-create-home --user-group "$GENIEACS_USER"
install -d -m 0755 -o "$GENIEACS_USER" -g "$GENIEACS_USER" "$GENIEACS_HOME" "$GENIEACS_EXT_DIR" "$GENIEACS_LOG_DIR"

JWT_SECRET=""
[[ -f "$GENIEACS_ENV" ]] && JWT_SECRET="$(sed -n 's/^GENIEACS_UI_JWT_SECRET=//p' "$GENIEACS_ENV" | head -n1 || true)"
[[ -n "$JWT_SECRET" && "$JWT_SECRET" != secret ]] || JWT_SECRET="$(openssl rand -hex 32)"

if [[ "$MONGO_MODE" == external ]]; then :; elif [[ -f "$GENIEACS_ENV" ]]; then
  old="$(sed -n 's/^GENIEACS_MONGODB_CONNECTION_URL=//p' "$GENIEACS_ENV" | head -n1 || true)"
  [[ -n "$old" ]] && MONGO_URI="$old"
fi

cat > "$GENIEACS_ENV" <<EOF2
GENIEACS_MONGODB_CONNECTION_URL=${MONGO_URI}
GENIEACS_CWMP_ACCESS_LOG_FILE=${GENIEACS_LOG_DIR}/genieacs-cwmp-access.log
GENIEACS_NBI_ACCESS_LOG_FILE=${GENIEACS_LOG_DIR}/genieacs-nbi-access.log
GENIEACS_FS_ACCESS_LOG_FILE=${GENIEACS_LOG_DIR}/genieacs-fs-access.log
GENIEACS_UI_ACCESS_LOG_FILE=${GENIEACS_LOG_DIR}/genieacs-ui-access.log
GENIEACS_DEBUG_FILE=${GENIEACS_LOG_DIR}/genieacs-debug.yaml
GENIEACS_EXT_DIR=${GENIEACS_EXT_DIR}
GENIEACS_UI_JWT_SECRET=${JWT_SECRET}
EOF2
chown "$GENIEACS_USER:$GENIEACS_USER" "$GENIEACS_ENV"; chmod 0600 "$GENIEACS_ENV"

write_service(){
  local svc="$1" desc="$2" bin="$3"
  cat > "/etc/systemd/system/${svc}.service" <<EOF2
[Unit]
Description=${desc}
After=network-online.target
Wants=network-online.target
EOF2
  if [[ "$MONGO_MODE" == native ]]; then printf 'Requires=mongod.service\nAfter=mongod.service\n' >> "/etc/systemd/system/${svc}.service"; fi
  if [[ "$MONGO_MODE" == docker ]]; then printf 'Requires=%s\nAfter=%s\n' "$MONGO_UNIT" "$MONGO_UNIT" >> "/etc/systemd/system/${svc}.service"; fi
  cat >> "/etc/systemd/system/${svc}.service" <<EOF2

[Service]
Type=simple
User=${GENIEACS_USER}
Group=${GENIEACS_USER}
EnvironmentFile=${GENIEACS_ENV}
ExecStart=${GENIEACS_BIN_DIR}/${bin}
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${GENIEACS_HOME} ${GENIEACS_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF2
}
write_service genieacs-cwmp 'GenieACS CWMP' genieacs-cwmp
write_service genieacs-fs 'GenieACS File Server' genieacs-fs
write_service genieacs-nbi 'GenieACS NBI' genieacs-nbi
write_service genieacs-ui 'GenieACS UI' genieacs-ui

cat >/etc/logrotate.d/genieacs <<'EOF2'
/var/log/genieacs/*.log /var/log/genieacs/*.yaml {
 daily
 rotate 30
 compress
 delaycompress
 missingok
 notifempty
 copytruncate
 dateext
}
EOF2

systemctl daemon-reload
for svc in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do systemctl enable "$svc"; systemctl restart "$svc"; done

wait_genieacs(){
  for svc in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
    local active=false
    for _ in {1..60}; do systemctl is-active --quiet "$svc" && { active=true; break; }; sleep 1; done
    if [[ "$active" != true ]]; then systemctl status "$svc" --no-pager -l || true; journalctl -u "$svc" --no-pager -n 120 || true; die "$svc gagal aktif."; fi
    ok "$svc RUNNING"
  done
}
check_port(){
  local p="$1"; ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$" || die "Port ${p} tidak listening."; ok "Port ${p} LISTENING";
}
wait_genieacs
check_port 3000; check_port 7547; check_port 7557; check_port 7567
curl -fsS --max-time 10 http://127.0.0.1:3000/ >/dev/null || die "UI health check gagal."

backup_existing_db(){
  local stamp out
  stamp="$(date '+%Y%m%d-%H%M%S')"; out="${BACKUP_ROOT}/${stamp}"; install -d -m 0700 "$BACKUP_ROOT"
  if [[ "$MONGO_MODE" == native ]]; then mongodump --db "$MONGO_DB" --out "$out"; else
    docker exec "$MONGO_CONTAINER" mongodump --db "$MONGO_DB" --out "/tmp/backup-${stamp}" >/dev/null
    docker cp "$MONGO_CONTAINER:/tmp/backup-${stamp}" "$out" >/dev/null
    docker exec "$MONGO_CONTAINER" rm -rf "/tmp/backup-${stamp}" || true
  fi
  chmod -R go-rwx "$out"; printf '%s\n' "$out"
}

restore_db(){
  [[ -d "$DB_DIR" ]] || die "Folder DB tidak ditemukan: $DB_DIR"
  local dump="$DB_DIR"; [[ -d "$DB_DIR/$MONGO_DB" ]] && dump="$DB_DIR/$MONGO_DB"
  find "$dump" -maxdepth 2 -type f \( -name '*.bson' -o -name '*.bson.gz' -o -name '*.metadata.json' \) -print -quit | grep -q . || die "${dump} bukan mongodump yang dikenali."
  local backup; backup="$(backup_existing_db)"; ok "Backup: $backup"
  for svc in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do systemctl stop "$svc"; done
  local rc=0
  if [[ "$MONGO_MODE" == native ]]; then
    mongorestore --drop --db "$MONGO_DB" "$dump" || rc=$?
  else
    local tmp="/tmp/genieacs-restore-$$"; rm -rf "$tmp"; mkdir -p "$tmp"; rsync -a "$dump/" "$tmp/"
    docker exec "$MONGO_CONTAINER" rm -rf /tmp/genieacs-restore || true
    docker cp "$tmp/." "$MONGO_CONTAINER:/tmp/genieacs-restore/"
    docker exec "$MONGO_CONTAINER" mongorestore --drop --db "$MONGO_DB" /tmp/genieacs-restore || rc=$?
    docker exec "$MONGO_CONTAINER" rm -rf /tmp/genieacs-restore || true; rm -rf "$tmp"
  fi
  for svc in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do systemctl start "$svc" || true; done
  (( rc == 0 )) || die "Restore gagal exit=${rc}; backup tetap di ${backup}"
  mongo_ping || die "MongoDB ping gagal setelah restore."; wait_genieacs; ok "Restore selesai; backup=${backup}"
}

if [[ "$RESTORE_DB" == true ]]; then restore_db
elif [[ "$AUTO_YES" != true && -d "$DB_DIR" && "$SKIP_DB" == false ]]; then
  read -r -p "Folder db ditemukan. Restore sekarang? (y/n): " ans
  [[ "$ans" =~ ^[Yy]$ ]] && restore_db || warn "Restore dilewati."
fi

wait_genieacs; check_port 3000; check_port 7547; check_port 7557; check_port 7567
curl -fsS --max-time 10 http://127.0.0.1:3000/ >/dev/null || die "Final UI health check gagal."

printf '\n%b============================================================%b\n' "$GREEN" "$NC"
printf '%b GENIEACS INSTALLATION SUCCESS%b\n' "$GREEN" "$NC"
printf '%b============================================================%b\n' "$GREEN" "$NC"
printf 'OS           : %s\n' "$PRETTY_NAME"
printf 'Architecture : %s\n' "$ARCH"
printf 'Kernel       : %s\n' "$KERNEL_RELEASE"
printf 'Node         : %s\n' "$(node -v)"
printf 'GenieACS     : %s\n' "$GENIEACS_VERSION"
printf 'MongoDB      : %s (%s)\n' "${MONGO_MAJOR:-external}" "$MONGO_MODE"
printf 'UI           : http://%s:3000\n' "$LOCAL_IP"
printf 'CWMP         : 7547\nNBI          : 7557\nFS           : 7567\n'
printf 'Environment  : %s\nInstaller log: %s\n' "$GENIEACS_ENV" "$LOG_FILE"
printf '%b============================================================%b\n' "$GREEN" "$NC"
send_telegram "✅ GenieACS ${GENIEACS_VERSION} installed\nServer: ${HOSTNAME_NOW}\nOS: ${PRETTY_NAME}\nArch: ${ARCH}\nKernel: ${KERNEL_RELEASE}\nMongoDB: ${MONGO_MAJOR:-external} (${MONGO_MODE})\nNode: $(node -v)\nUI: http://${LOCAL_IP}:3000"
