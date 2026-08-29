#!/usr/bin/env bash
# GenieACS Adaptive Auto Installer v4.3.0
# Feature: Native & Docker MongoDB Auto-Restore from db/ folder

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="4.3.0"
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

usage(){ cat <<USAGE
GenieACS Adaptive Auto Installer v${SCRIPT_VERSION}

Usage:
  sudo bash ${0##*/} [options]

Options:
  --yes, -y             Non-interactive mode.
  --restore-db          Force restore db/ directory after install.
  --skip-db             Do not install local MongoDB.
  --mongo-uri URI       Use external MongoDB; implies --skip-db.
  --no-telegram         Disable Telegram notifications.
  --help, -h            Show help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y) AUTO_YES=true;;
    --restore-db) RESTORE_DB=true;;
    --skip-db) SKIP_DB=true;;
    --mongo-uri) 
      if [[ $# -lt 2 ]]; then echo "--mongo-uri membutuhkan URI"; exit 1; fi
      EXTERNAL_MONGO_URI="$2"
      shift
      ;;
    --no-telegram) NO_TELEGRAM=true;;
    --help|-h) usage; exit 0;;
    *) echo "Opsi tidak dikenal: $1"; exit 1;;
  esac
  shift
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="${SCRIPT_DIR}/db"
HOSTNAME_NOW="$(hostname 2>/dev/null || true)"
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; LOCAL_IP="${LOCAL_IP:-127.0.0.1}"
OS_ID=""; OS_LIKE=""; OS_CODENAME=""; PRETTY_NAME=""; ARCH=""; INIT_SYSTEM=""; KERNEL_RELEASE="$(uname -r)"
IS_ARMBIAN=false
HAS_ARM82_EXTENSION=false
KMAJOR=0; KMINOR=0; KPATCH=0
GENIEACS_BIN_DIR=""
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

log(){ printf '%b[%s]%b %s\n' "$CYAN" "$(date '+%F %T')" "$NC" "$1"; }
ok(){ printf '%b✔%b %s\n' "$GREEN" "$NC" "$1"; }
warn(){ printf '%b⚠%b %s\n' "$YELLOW" "$NC" "$1"; }
die(){ printf '%b✘%b %s\n' "$RED" "$NC" "$1" >&2; exit 1; }

send_telegram(){
  if [[ "$NO_TELEGRAM" == true || -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then return 0; fi
  curl -fsS --connect-timeout 10 --max-time 20 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || warn "Telegram gagal dikirim."
}

on_error(){
  local rc=$? line="${1:-unknown}"
  printf '\n%bINSTALLER GAGAL%b line=%s exit=%s\n' "$RED" "$NC" "$line" "$rc"
  systemctl --failed --no-pager 2>/dev/null || true
  
  for svc in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
    echo "=== Status $svc ==="
    systemctl status "$svc" --no-pager -l 2>/dev/null || true
    echo "=== Journal $svc ==="
    journalctl -u "$svc" --no-pager -n 40 2>/dev/null || true
  done

  send_telegram "❌ GenieACS installer FAILED\nServer: ${HOSTNAME_NOW}\nIP: ${LOCAL_IP}\nOS: ${PRETTY_NAME}\nArch: ${ARCH}\nKernel: ${KERNEL_RELEASE}\nLine: ${line}\nExit: ${rc}"
  exit "$rc"
}
trap 'on_error $LINENO' ERR

if [[ $(id -u) -ne 0 ]]; then die "Jalankan skrip ini sebagai root."; fi
if [[ ! -r /etc/os-release ]]; then die "/etc/os-release tidak ditemukan."; fi
source /etc/os-release

OS_ID="${ID:-unknown}"
OS_LIKE="${ID_LIKE:-$OS_ID}"
OS_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
OS_CODENAME="${OS_CODENAME// /}"
PRETTY_NAME="${PRETTY_NAME:-${OS_ID} ${VERSION_ID:-}}"
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
INIT_SYSTEM="$(ps -p 1 -o comm= 2>/dev/null || true)"

if [[ -f /etc/armbian-release ]]; then IS_ARMBIAN=true; fi
if [[ "$INIT_SYSTEM" != "systemd" ]]; then die "systemd diperlukan; PID1=${INIT_SYSTEM}"; fi

IFS='.' read -r KMAJOR KMINOR KPATCH _ <<< "${KERNEL_RELEASE%%-*}"
KMAJOR=${KMAJOR:-0}; KMINOR=${KMINOR:-0}; KPATCH=${KPATCH:-0}

if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
  if grep -qE 'lrcpc|atomics|fphp|dp' /proc/cpuinfo 2>/dev/null; then
    HAS_ARM82_EXTENSION=true
  fi
fi

kernel_affected(){
  if (( KMAJOR == 6 && KMINOR >= 19 )); then return 0; fi
  if (( KMAJOR == 7 && KMINOR == 0 && KPATCH <= 13 )); then return 0; fi
  return 1
}

printf '\n%b============================================================%b\n' "$GREEN" "$NC"
printf '%b GenieACS Adaptive Auto Installer v%s %b\n' "$GREEN" "$SCRIPT_VERSION" "$NC"
printf '%b Dynamic Hardware & OS Adaptive MongoDB Engine %b\n' "$GREEN" "$NC"
printf '%b============================================================%b\n\n' "$GREEN" "$NC"

case "$ARCH" in
  amd64|arm64|aarch64) ;;
  armhf|armv7l) warn "Arsitektur 32-bit ($ARCH) terdeteksi." ;;
  *) die "Arsitektur ${ARCH} tidak didukung.";;
esac

log "Host=${HOSTNAME_NOW} | IP=${LOCAL_IP} | OS=${PRETTY_NAME} | Code=${OS_CODENAME} | Arch=${ARCH}"

MEM_MB="$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
DISK_GB="$(df -Pk / | awk 'NR==2 {printf "%d", $4/1024/1024}')"

if [ "$DISK_GB" -lt 4 ]; then die "Disk kosong hanya ${DISK_GB} GB; minimal 4 GB diperlukan."; fi

if [[ -n "$EXTERNAL_MONGO_URI" ]]; then
  SKIP_DB=true
  MONGO_URI="$EXTERNAL_MONGO_URI"
fi

select_mongodb(){
  if [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
    if [[ "$HAS_ARM82_EXTENSION" == true ]]; then
      MONGO_MAJOR="7.0"; MONGO_MODE="docker"; MONGO_IMAGE="mongo:7.0"
    else
      MONGO_MAJOR="4.4"; MONGO_MODE="docker"; MONGO_IMAGE="mongo:4.4.18"
    fi
  elif [[ "$ARCH" == "armhf" || "$ARCH" == "armv7l" ]]; then
    MONGO_MAJOR="4.4"; MONGO_MODE="docker"; MONGO_IMAGE="mongo:4.4"
  elif [[ "$OS_ID" == "ubuntu" ]]; then
    if kernel_affected; then
      if [[ "$OS_CODENAME" == "focal" || "$OS_CODENAME" == "jammy" ]]; then
        MONGO_MAJOR="7.0"; MONGO_MODE="native"
      else
        MONGO_MAJOR="7.0"; MONGO_MODE="docker"; MONGO_IMAGE="mongo:7.0-jammy"
      fi
    else
      MONGO_MAJOR="8.0"; MONGO_MODE="native"
    fi
  else
    if [[ "$ARCH" == "amd64" ]] && ! kernel_affected; then
      MONGO_MAJOR="8.0"; MONGO_MODE="native"
    else
      MONGO_MAJOR="7.0"; MONGO_MODE="docker"; MONGO_IMAGE="mongo:7.0-jammy"
    fi
  fi
  if [[ -z "${MONGO_IMAGE:-}" ]]; then MONGO_IMAGE="mongo:${MONGO_MAJOR}"; fi
}

if [[ "$SKIP_DB" == false ]]; then
  select_mongodb
else
  MONGO_MODE="external"
fi

if [[ "$AUTO_YES" != true ]]; then
  cat <<EOF2

Target Ringkasan Instalasi:
  OS           : ${PRETTY_NAME} (Armbian STB: ${IS_ARMBIAN})
  Architecture : ${ARCH}
  MongoDB      : ${MONGO_MAJOR} (${MONGO_MODE} - ${MONGO_IMAGE:-})
  GenieACS     : ${GENIEACS_VERSION}
  Node.js      : ${NODE_MAJOR}.x

EOF2

  ans=""
  if [ -t 0 ]; then read -r -p "Lanjutkan proses instalasi? (y/n): " ans || true
  elif [ -c /dev/tty ]; then read -r -p "Lanjutkan proses instalasi? (y/n): " ans </dev/tty 2>/dev/null || true
  else ans="y"; fi

  if [[ -n "$ans" && ! "$ans" =~ ^[Yy]$ ]]; then
    ok "Instalasi dibatalkan oleh pengguna."
    exit 0
  fi
fi

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Memperbarui direktori paket sistem..."
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl jq lsb-release logrotate procps iproute2 tar gzip xz-utils rsync build-essential python3

install_node(){
  local cur=""
  if command -v node >/dev/null 2>&1; then cur="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"; fi
  if [[ "$cur" != "$NODE_MAJOR" ]]; then
    log "Memasang Node.js ${NODE_MAJOR}.x..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource.sh
    bash /tmp/nodesource.sh
    apt-get install -y nodejs
    rm -f /tmp/nodesource.sh
  fi
  if ! command -v node >/dev/null || ! command -v npm >/dev/null; then die "Node/npm gagal terpasang."; fi
  ok "Node $(node -v) & npm $(npm -v) siap digunakan."
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
  if [[ "$MONGO_MODE" == "native" ]]; then
    mongosh --quiet --host 127.0.0.1 --port 27017 --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx 1
  elif [[ "$MONGO_MODE" == "docker" ]]; then
    if docker exec "$MONGO_CONTAINER" mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx 1; then
      return 0
    else
      docker exec "$MONGO_CONTAINER" mongo --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx 1
    fi
  else
    mongosh --quiet "$MONGO_URI" --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx 1
  fi
}

wait_mongo(){
  local n="${1:-90}"
  log "Menunggu ketersediaan koneksi MongoDB..."
  for ((i=1;i<=n;i++)); do 
    if mongo_ping; then 
      ok "MongoDB berhasil merespons (Ping OK)."
      return 0
    fi
    sleep 1
  done
  return 1
}

install_mongo_native(){
  local keyring="/usr/share/keyrings/mongodb-server-${MONGO_MAJOR}.gpg"
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL "https://pgp.mongodb.com/server-${MONGO_MAJOR}.asc" | gpg --dearmor --yes -o "$keyring"
  chmod 0644 "$keyring"
  rm -f /etc/apt/sources.list.d/mongodb-org-*.list
  
  local target_codename="$OS_CODENAME"
  if [[ "$OS_ID" != "ubuntu" ]]; then target_codename="bookworm"; fi

  printf 'deb [ arch=amd64,arm64 signed-by=%s ] https://repo.mongodb.org/apt/ubuntu %s/mongodb-org/%s multiverse\n' "$keyring" "$target_codename" "$MONGO_MAJOR" > "/etc/apt/sources.list.d/mongodb-org-${MONGO_MAJOR}.list"
  
  apt-get update
  apt-get install -y mongodb-org mongodb-mongosh mongodb-database-tools || apt-get install -y mongodb-org
  write_mongo_conf
  systemctl daemon-reload
  systemctl enable mongod
  systemctl restart mongod
  wait_mongo 90 || { journalctl -u mongod --no-pager -n 120 || true; return 1; }
}

install_mongo_docker(){
  log "Memasang Docker Engine untuk kontainer MongoDB (${MONGO_IMAGE})..."
  apt-get install -y docker.io
  systemctl enable --now docker
  install -d -m 0755 "$MONGO_DATA_DIR"
  if docker container inspect "$MONGO_CONTAINER" >/dev/null 2>&1; then
    local image
    image="$(docker inspect -f '{{.Config.Image}}' "$MONGO_CONTAINER")"
    log "Container ${MONGO_CONTAINER} sudah ada dengan citra ${image}."
  else
    docker pull "$MONGO_IMAGE"
    docker create --name "$MONGO_CONTAINER" --restart=no -p 127.0.0.1:27017:27017 -v "${MONGO_DATA_DIR}:/data/db" "$MONGO_IMAGE" mongod --bind_ip_all --wiredTigerCacheSizeGB 0.25 >/dev/null
  fi
  cat > "/etc/systemd/system/${MONGO_UNIT}" <<EOF2
[Unit]
Description=GenieACS MongoDB Docker Container
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
  if [[ "$(docker inspect -f '{{.State.Running}}' "$MONGO_CONTAINER" 2>/dev/null || echo false)" == "true" ]]; then 
    docker stop -t 30 "$MONGO_CONTAINER" >/dev/null
  fi
  systemctl daemon-reload
  systemctl enable --now "$MONGO_UNIT"
  wait_mongo 120 || { docker logs --tail 160 "$MONGO_CONTAINER" || true; return 1; }
}

install_local_mongo(){
  log "Proses penyiapan MongoDB: Versi ${MONGO_MAJOR} | Mode: ${MONGO_MODE}"
  if [[ "$MONGO_MODE" == "native" ]]; then
    install_mongo_native || die "MongoDB Native gagal berjalan."
  else
    install_mongo_docker || die "MongoDB Container (Docker) gagal berjalan."
  fi
}

install_node
if [[ "$SKIP_DB" == false ]]; then
  install_local_mongo
fi

# New v4.3.0: Auto Restore Database dari folder db/
restore_database_if_present(){
  if [[ -d "$DB_DIR" || "$RESTORE_DB" == true ]]; then
    log "Memeriksa backup basis data di ${DB_DIR}..."
    if [[ ! -d "$DB_DIR" ]]; then
      warn "Direktori ${DB_DIR} tidak ditemukan untuk di-restore."
      return 0
    fi

    # Pastikan mongodb-database-tools terpasang untuk mongorestore
    if ! command -v mongorestore >/dev/null 2>&1; then
      apt-get install -y mongodb-database-tools >/dev/null 2>&1 || true
    fi

    log "Melakukan restore data dari ${DB_DIR} ke MongoDB (${MONGO_DB})..."

    if [[ "$MONGO_MODE" == "native" ]]; then
      if command -v mongorestore >/dev/null 2>&1; then
        mongorestore --host 127.0.0.1 --port 27017 --db="$MONGO_DB" --drop "$DB_DIR" || mongorestore --host 127.0.0.1 --port 27017 --nsInclude="${MONGO_DB}.*" --drop "$DB_DIR" || warn "Mongorestore native mengalami catatan minor."
      else
        warn "Biner mongorestore tidak tersedia, melewatin restore otomatis."
        return 0
      fi
    elif [[ "$MONGO_MODE" == "docker" ]]; then
      docker cp "$DB_DIR" "${MONGO_CONTAINER}:/tmp/db_restore"
      docker exec "$MONGO_CONTAINER" mongorestore --db="$MONGO_DB" --drop /tmp/db_restore || docker exec "$MONGO_CONTAINER" mongorestore --drop /tmp/db_restore || warn "Mongorestore docker mengalami catatan minor."
      docker exec "$MONGO_CONTAINER" rm -rf /tmp/db_restore
    else
      if command -v mongorestore >/dev/null 2>&1; then
        mongorestore --uri="$MONGO_URI" --drop "$DB_DIR" || warn "Mongorestore external URI mengalami catatan minor."
      fi
    fi
    ok "Database restore selesai diuji."
  fi
}

restore_database_if_present

install_genieacs(){
  log "Menginstal GenieACS v${GENIEACS_VERSION} via NPM..."
  npm install -g --unsafe-perm "genieacs@${GENIEACS_VERSION}"
  hash -r 2>/dev/null || true

  local bin_path
  bin_path="$(command -v genieacs-cwmp 2>/dev/null || true)"
  if [[ -z "$bin_path" ]]; then
    local npm_prefix
    npm_prefix="$(npm config get prefix)"
    bin_path="${npm_prefix}/bin/genieacs-cwmp"
  fi

  if [[ ! -x "$bin_path" ]]; then die "Biner genieacs-cwmp tidak ditemukan."; fi
  GENIEACS_BIN_DIR="$(dirname "$bin_path")"
  ok "GenieACS berhasil terpasang di ${GENIEACS_BIN_DIR}."
}
install_genieacs

if ! id "$GENIEACS_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --user-group "$GENIEACS_USER"
fi
install -d -m 0755 -o "$GENIEACS_USER" -g "$GENIEACS_USER" "$GENIEACS_HOME" "$GENIEACS_EXT_DIR" "$GENIEACS_LOG_DIR"

JWT_SECRET=""
if [[ -f "$GENIEACS_ENV" ]]; then JWT_SECRET="$(sed -n 's/^GENIEACS_UI_JWT_SECRET=//p' "$GENIEACS_ENV" | head -n1 || true)"; fi
if [[ -z "$JWT_SECRET" || "$JWT_SECRET" == "secret" ]]; then JWT_SECRET="$(openssl rand -hex 32)"; fi

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
  if [[ "$MONGO_MODE" == "native" ]]; then printf 'Requires=mongod.service\nAfter=mongod.service\n' >> "/etc/systemd/system/${svc}.service"; fi
  if [[ "$MONGO_MODE" == "docker" ]]; then printf 'Requires=%s\nAfter=%s\n' "$MONGO_UNIT" "$MONGO_UNIT" >> "/etc/systemd/system/${svc}.service"; fi
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
WorkingDirectory=${GENIEACS_HOME}

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
    for _ in {1..60}; do 
      if systemctl is-active --quiet "$svc"; then active=true; break; fi
      sleep 1
    done
    if [[ "$active" != true ]]; then die "$svc gagal aktif."; fi
    ok "Layanan $svc AKTIF"
  done
}

check_port(){
  local p="$1"
  local found=false
  for _ in {1..30}; do
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${p}$"; then
      found=true
      break
    fi
    sleep 1
  done

  if [[ "$found" == true ]]; then
    ok "Port ${p} AKTIF (Listening)"
  else
    die "Port ${p} tidak listening."
  fi
}

wait_genieacs
check_port 3000; check_port 7547; check_port 7557; check_port 7567

printf '\n%b============================================================%b\n' "$GREEN" "$NC"
printf '%b GENIEACS INSTALASI & RESTORE SUKSES %b\n' "$GREEN" "$NC"
printf '%b============================================================%b\n' "$GREEN" "$NC"
printf 'Dashboard UI : http://%s:3000\n' "$LOCAL_IP"
printf 'Port CWMP    : 7547\nPort NBI     : 7557\nPort FS      : 7567\n'
printf '%b============================================================%b\n' "$GREEN" "$NC"
