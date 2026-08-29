#!/usr/bin/env bash
#
# GenieACS Auto Installer v2
# Ubuntu 20.04 / 22.04 / 24.04 + Armbian (Ubuntu/Debian) + ARM64/AMD64
# GenieACS 1.2.16 + MongoDB 8.0 + Node.js 22
#
# Usage:
#   sudo bash install.sh
#   sudo bash install.sh --yes
#   sudo bash install.sh --yes --restore-db
#   sudo bash install.sh --yes --skip-db
#
# Telegram (optional):
#   export TELEGRAM_BOT_TOKEN='...'
#   export TELEGRAM_CHAT_ID='...'
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="2.0.0"
GENIEACS_VERSION="1.2.16"
NODE_MAJOR="22"
MONGODB_MAJOR="8.0"
MONGODB_IMAGE="mongo:8.0"
GENIEACS_USER="genieacs"
GENIEACS_HOME="/opt/genieacs"
GENIEACS_ENV="${GENIEACS_HOME}/genieacs.env"
GENIEACS_LOG_DIR="/var/log/genieacs"
GENIEACS_EXT_DIR="${GENIEACS_HOME}/ext"
MONGO_DATA_DIR="/var/lib/genieacs-mongodb"
MONGO_CONTAINER="genieacs-mongodb"
MONGO_UNIT="genieacs-mongodb.service"
MONGO_NATIVE_UNIT="mongod.service"
MONGO_DB="genieacs"
MONGO_URL="mongodb://127.0.0.1:27017/${MONGO_DB}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

AUTO_YES=false
RESTORE_DB=false
SKIP_DB=false
SKIP_TELEGRAM=false

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="${SCRIPT_DIR}/db"
LOG_FILE="/var/log/genieacs-installer.log"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

LOCAL_IP=""
SERVER_HOSTNAME="$(hostname 2>/dev/null || true)"
SERVER_KERNEL="$(uname -r 2>/dev/null || true)"
OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_CODENAME=""
ARCH=""
INIT_SYSTEM=""
MONGO_MODE=""
MONGO_URI="${MONGO_URL}"
NODE_BIN=""
GENIEACS_BIN_DIR=""

log() {
    local msg="$1"
    printf '%b[%s]%b %s\n' "${CYAN}" "$(date '+%F %T')" "${NC}" "${msg}"
}

ok() { printf '%b✔%b %s\n' "${GREEN}" "${NC}" "$1"; }
warn() { printf '%b⚠%b %s\n' "${YELLOW}" "${NC}" "$1"; }
die() { printf '%b✘%b %s\n' "${RED}" "${NC}" "$1" >&2; exit 1; }

run_quiet() {
    "$@"
}

send_telegram() {
    local message="${1:-}"
    if [[ "${SKIP_TELEGRAM}" == true || -z "${TELEGRAM_BOT_TOKEN}" || -z "${TELEGRAM_CHAT_ID}" ]]; then
        return 0
    fi
    curl -fsS --connect-timeout 10 --max-time 20 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || warn "Telegram notification gagal dikirim."
}

on_error() {
    local code=$?
    local line="${1:-unknown}"
    printf '\n%b============================================================%b\n' "${RED}" "${NC}"
    printf '%bINSTALLER GAGAL%b\n' "${RED}" "${NC}"
    printf 'Line: %s\nExit: %s\n' "${line}" "${code}"
    printf '%b============================================================%b\n' "${RED}" "${NC}"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl --failed --no-pager 2>/dev/null || true
        if [[ "${MONGO_MODE}" == "native" ]]; then
            systemctl status mongod --no-pager -l 2>/dev/null || true
            journalctl -u mongod --no-pager -n 40 2>/dev/null || true
        elif [[ "${MONGO_MODE}" == "docker" ]]; then
            systemctl status "${MONGO_UNIT}" --no-pager -l 2>/dev/null || true
            journalctl -u "${MONGO_UNIT}" --no-pager -n 40 2>/dev/null || true
        fi
    fi

    send_telegram "❌ GenieACS installer FAILED\nServer: ${SERVER_HOSTNAME}\nIP: ${LOCAL_IP}\nOS: ${OS_ID} ${OS_VERSION_ID}\nArch: ${ARCH}\nLine: ${line}\nExit: ${code}"
    exit "${code}"
}
trap 'on_error $LINENO' ERR

usage() {
    cat <<USAGE
GenieACS Auto Installer v${SCRIPT_VERSION}

Usage:
  sudo bash install.sh [options]

Options:
  --yes, -y           Non-interactive mode.
  --restore-db        Restore ./db into GenieACS database (requires ./db).
  --skip-db           Do not install MongoDB.
  --no-telegram       Disable Telegram notifications.
  --help, -h          Show this help.

Examples:
  sudo bash install.sh
  sudo bash install.sh --yes
  sudo bash install.sh --yes --restore-db
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) AUTO_YES=true ;;
        --restore-db) RESTORE_DB=true ;;
        --skip-db) SKIP_DB=true ;;
        --no-telegram) SKIP_TELEGRAM=true ;;
        --help|-h) usage; exit 0 ;;
        *) die "Opsi tidak dikenal: $1" ;;
    esac
    shift
done

[[ "$(id -u)" -eq 0 ]] || die "Jalankan sebagai root: sudo bash install.sh"

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release tidak ditemukan. OS tidak dapat dideteksi."
fi
# shellcheck disable=SC1091
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_ID_LIKE="${ID_LIKE:-}"
OS_VERSION_ID="${VERSION_ID:-unknown}"
OS_CODENAME="${VERSION_CODENAME:-}"
ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
INIT_SYSTEM="$(ps -p 1 -o comm= 2>/dev/null || true)"
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
LOCAL_IP="${LOCAL_IP:-127.0.0.1}"

mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

printf '\n%b============================================================%b\n' "${GREEN}" "${NC}"
printf '%b GenieACS Auto Installer v%s%b\n' "${GREEN}" "${SCRIPT_VERSION}" "${NC}"
printf '%b GenieACS %s | Node.js %s | MongoDB %s%b\n' "${GREEN}" "${GENIEACS_VERSION}" "${NODE_MAJOR}" "${MONGODB_MAJOR}" "${NC}"
printf '%b============================================================%b\n\n' "${GREEN}" "${NC}"

[[ "${INIT_SYSTEM}" == "systemd" ]] || die "systemd diperlukan. PID 1 terdeteksi: ${INIT_SYSTEM}"

case "${ARCH}" in
    amd64|arm64) ;;
    armhf|armel|i386|ppc64el|s390x) die "Architecture ${ARCH} tidak didukung. Gunakan OS 64-bit (amd64/arm64)." ;;
    *) die "Architecture ${ARCH:-unknown} tidak dikenali." ;;
esac

# MongoDB 5+ on ARM64 needs a sufficiently new ARMv8 CPU. The official image warns
# about this too; fail early when the common ARMv8.2 feature set is absent.
if [[ "${ARCH}" == "arm64" ]]; then
    if ! grep -Eqi '^Features.*(fphp|dcpop|sha3|sm3|sm4|asimddp|sha512|sve)( |$)' /proc/cpuinfo 2>/dev/null; then
        die "CPU ARM64 ini tidak menunjukkan fitur ARMv8.2-A yang dibutuhkan MongoDB 5+. Banyak STB lama gagal di sini."
    fi
fi

if [[ "${OS_ID}" != "ubuntu" && "${OS_ID}" != "debian" ]]; then
    if [[ "${OS_ID_LIKE}" == *debian* || "${OS_ID_LIKE}" == *ubuntu* ]]; then
        warn "OS ${OS_ID} terdeteksi Debian/Ubuntu-compatible. Installer akan mencoba melanjutkan."
    else
        die "OS ${OS_ID} tidak didukung. Target: Ubuntu 20/22/24 atau Armbian berbasis Ubuntu/Debian."
    fi
fi

if [[ -z "${OS_CODENAME}" ]] && command -v lsb_release >/dev/null 2>&1; then
    OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
fi

log "Host: ${SERVER_HOSTNAME} | IP: ${LOCAL_IP} | OS: ${PRETTY_NAME:-${OS_ID}} | Arch: ${ARCH}"
log "Script directory: ${SCRIPT_DIR}"

if [[ "${OS_ID}" == "ubuntu" ]]; then
    case "${OS_CODENAME}" in
        focal|jammy|noble) ;;
        *) die "Ubuntu ${OS_CODENAME:-unknown} tidak didukung oleh profil installer ini." ;;
    esac
elif [[ "${OS_ID}" == "debian" || "${OS_ID_LIKE}" == *debian* ]]; then
    # Debian/Armbian uses Docker for MongoDB because official MongoDB 8 apt packages
    # are not published for Debian ARM64. The official Mongo image supports linux/arm64.
    case "${OS_CODENAME}" in
        bullseye|bookworm|trixie|jammy|noble|focal) ;;
        *) warn "Debian codename ${OS_CODENAME:-unknown} tidak dikenal; Docker MongoDB akan digunakan." ;;
    esac
fi

if [[ "${AUTO_YES}" != true ]]; then
    cat <<EOF

Target instalasi:
  OS             : ${PRETTY_NAME:-${OS_ID}}
  Architecture   : ${ARCH}
  Node.js        : ${NODE_MAJOR}.x
  GenieACS       : ${GENIEACS_VERSION}
  MongoDB        : ${MONGODB_MAJOR}
  DB directory   : ${DB_DIR}
  Restore DB     : ${RESTORE_DB}

Lanjutkan? (y/n)
EOF
    read -r confirmation
    [[ "${confirmation}" =~ ^[Yy]$ ]] || { ok "Instalasi dibatalkan."; exit 0; }
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

log "Installing base packages..."
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    openssl \
    jq \
    lsb-release \
    apt-transport-https \
    logrotate \
    procps \
    iproute2 \
    net-tools \
    tar \
    gzip \
    xz-utils \
    rsync

install_nodejs() {
    local current_major=""
    if command -v node >/dev/null 2>&1; then
        current_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
    fi

    if [[ "${current_major}" != "${NODE_MAJOR}" ]]; then
        log "Installing Node.js ${NODE_MAJOR}.x..."
        rm -f /tmp/nodesource_setup.sh
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh
        bash /tmp/nodesource_setup.sh
        apt-get install -y nodejs
        rm -f /tmp/nodesource_setup.sh
    else
        ok "Node.js ${NODE_MAJOR}.x sudah tersedia."
    fi

    command -v node >/dev/null 2>&1 || die "node tidak ditemukan setelah instalasi."
    command -v npm >/dev/null 2>&1 || die "npm tidak ditemukan setelah instalasi."

    current_major="$(node -p 'process.versions.node.split(".")[0]')"
    [[ "${current_major}" == "${NODE_MAJOR}" ]] || die "Node.js version mismatch: ${current_major}"
    NODE_BIN="$(command -v node)"
    ok "Node.js: $(node -v), npm: $(npm -v)"
}

install_nodejs

install_mongodb_native() {
    MONGO_MODE="native"
    log "Installing MongoDB ${MONGODB_MAJOR} natively..."

    systemctl stop mongod 2>/dev/null || true
    rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    rm -f /usr/share/keyrings/mongodb-server-*.gpg
    install -d -m 0755 /usr/share/keyrings

    local keyring="/usr/share/keyrings/mongodb-server-${MONGODB_MAJOR}.gpg"
    curl -fsSL "https://pgp.mongodb.com/server-${MONGODB_MAJOR}.asc" \
        | gpg --dearmor --yes -o "${keyring}"
    chmod 0644 "${keyring}"

    local repo=""
    case "${OS_CODENAME}" in
        focal|jammy|noble)
            repo="deb [ arch=amd64,arm64 signed-by=${keyring} ] https://repo.mongodb.org/apt/ubuntu ${OS_CODENAME}/mongodb-org/${MONGODB_MAJOR} multiverse"
            ;;
        *)
            die "Native MongoDB ${MONGODB_MAJOR} hanya dikonfigurasi untuk Ubuntu focal/jammy/noble."
            ;;
    esac

    printf '%s\n' "${repo}" > /etc/apt/sources.list.d/mongodb-org-${MONGODB_MAJOR}.list
    chmod 0644 /etc/apt/sources.list.d/mongodb-org-${MONGODB_MAJOR}.list

    apt-get update
    apt-get install -y mongodb-org

    command -v mongosh >/dev/null 2>&1 || die "mongosh tidak ditemukan setelah instalasi MongoDB."
    command -v mongorestore >/dev/null 2>&1 || die "mongorestore tidak ditemukan setelah instalasi MongoDB."

    systemctl daemon-reload
    systemctl enable mongod
    systemctl restart mongod

    for _ in {1..30}; do
        if mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -q '^1$'; then
            ok "MongoDB native aktif."
            return 0
        fi
        sleep 1
    done

    systemctl status mongod --no-pager -l || true
    journalctl -u mongod --no-pager -n 80 || true
    die "MongoDB native gagal start."
}

install_mongodb_docker() {
    MONGO_MODE="docker"
    log "Installing MongoDB ${MONGODB_MAJOR} menggunakan Docker untuk Armbian/Debian..."

    if ! command -v docker >/dev/null 2>&1; then
        apt-get update
        apt-get install -y docker.io
    fi
    command -v docker >/dev/null 2>&1 || die "Docker tidak tersedia."

    systemctl enable --now docker

    install -d -m 0755 "${MONGO_DATA_DIR}"
    chown -R 999:999 "${MONGO_DATA_DIR}" 2>/dev/null || true

    if docker inspect "${MONGO_CONTAINER}" >/dev/null 2>&1; then
        docker stop "${MONGO_CONTAINER}" >/dev/null 2>&1 || true
        docker rm "${MONGO_CONTAINER}" >/dev/null 2>&1 || true
    fi
    docker pull "${MONGODB_IMAGE}"

    docker run -d \
        --name "${MONGO_CONTAINER}" \
        --restart unless-stopped \
        -p 127.0.0.1:27017:27017 \
        -v "${MONGO_DATA_DIR}:/data/db" \
        "${MONGODB_IMAGE}" \
        --bind_ip_all

    cat > "/etc/systemd/system/${MONGO_UNIT}" <<EOF2
[Unit]
Description=GenieACS MongoDB Docker container
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/docker start ${MONGO_CONTAINER}
ExecStop=/usr/bin/docker stop -t 20 ${MONGO_CONTAINER}
ExecReload=/usr/bin/docker restart ${MONGO_CONTAINER}

[Install]
WantedBy=multi-user.target
EOF2

    systemctl daemon-reload
    systemctl enable "${MONGO_UNIT}"
    systemctl restart "${MONGO_UNIT}"

    for _ in {1..45}; do
        if docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -q '^1$'; then
            ok "MongoDB Docker aktif."
            return 0
        fi
        sleep 1
    done

    docker logs --tail 100 "${MONGO_CONTAINER}" || true
    die "MongoDB Docker gagal start."
}

mongo_eval() {
    if [[ "${MONGO_MODE}" == "native" ]]; then
        mongosh --quiet --eval "$1"
    else
        docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval "$1"
    fi
}

mongo_restore() {
    local db_source="$1"
    if [[ "${MONGO_MODE}" == "native" ]]; then
        mongorestore --drop --db "${MONGO_DB}" "${db_source}"
    else
        local tmp_dir="/tmp/genieacs-restore-$$"
        rm -rf "${tmp_dir}"
        mkdir -p "${tmp_dir}"
        rsync -a "${db_source}/" "${tmp_dir}/"
        docker cp "${tmp_dir}/." "${MONGO_CONTAINER}:/tmp/genieacs-restore/"
        docker exec "${MONGO_CONTAINER}" mongorestore --drop --db "${MONGO_DB}" "/tmp/genieacs-restore/"
        docker exec "${MONGO_CONTAINER}" rm -rf /tmp/genieacs-restore
        rm -rf "${tmp_dir}"
    fi
}

if [[ "${SKIP_DB}" == true ]]; then
    warn "MongoDB dilewati (--skip-db)."
else
    if [[ "${OS_ID}" == "ubuntu" ]]; then
        install_mongodb_native
    else
        install_mongodb_docker
    fi
fi

if [[ "${SKIP_DB}" == false ]]; then
    mongo_eval 'db.adminCommand({ping:1})' >/dev/null
    ok "MongoDB ping OK."
fi

install_genieacs() {
    log "Installing GenieACS ${GENIEACS_VERSION}..."

    local installed=""
    if command -v genieacs-cwmp >/dev/null 2>&1; then
        installed="$(npm list -g --depth=0 --json 2>/dev/null | jq -r '.dependencies.genieacs.version // empty' 2>/dev/null || true)"
    fi

    if [[ "${installed}" != "${GENIEACS_VERSION}" ]]; then
        npm install -g --unsafe-perm "genieacs@${GENIEACS_VERSION}"
    fi

    command -v genieacs-cwmp >/dev/null 2>&1 || die "genieacs-cwmp tidak ditemukan."
    command -v genieacs-fs >/dev/null 2>&1 || die "genieacs-fs tidak ditemukan."
    command -v genieacs-nbi >/dev/null 2>&1 || die "genieacs-nbi tidak ditemukan."
    command -v genieacs-ui >/dev/null 2>&1 || die "genieacs-ui tidak ditemukan."

    GENIEACS_BIN_DIR="$(dirname "$(command -v genieacs-cwmp)")"
    ok "GenieACS binary directory: ${GENIEACS_BIN_DIR}"
}

install_genieacs

if ! id "${GENIEACS_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --user-group "${GENIEACS_USER}"
fi

install -d -m 0755 -o "${GENIEACS_USER}" -g "${GENIEACS_USER}" "${GENIEACS_HOME}"
install -d -m 0755 -o "${GENIEACS_USER}" -g "${GENIEACS_USER}" "${GENIEACS_EXT_DIR}"
install -d -m 0755 -o "${GENIEACS_USER}" -g "${GENIEACS_USER}" "${GENIEACS_LOG_DIR}"

JWT_SECRET=""
if [[ -f "${GENIEACS_ENV}" ]]; then
    JWT_SECRET="$(sed -n 's/^GENIEACS_UI_JWT_SECRET=//p' "${GENIEACS_ENV}" | head -n1 || true)"
fi
if [[ -z "${JWT_SECRET}" || "${JWT_SECRET}" == "secret" ]]; then
    JWT_SECRET="$(openssl rand -hex 32)"
fi

if [[ -f "${GENIEACS_ENV}" ]]; then
    existing_url="$(sed -n 's/^GENIEACS_MONGODB_CONNECTION_URL=//p' "${GENIEACS_ENV}" | head -n1 || true)"
    [[ -n "${existing_url}" ]] && MONGO_URI="${existing_url}"
fi

cat > "${GENIEACS_ENV}" <<EOF2
GENIEACS_MONGODB_CONNECTION_URL=${MONGO_URI}
GENIEACS_CWMP_ACCESS_LOG_FILE=${GENIEACS_LOG_DIR}/genieacs-cwmp-access.log
GENIEACS_NBI_ACCESS_LOG_FILE=${GENIEACS_LOG_DIR}/genieacs-nbi-access.log
GENIEACS_FS_ACCESS_LOG_FILE=${GENIEACS_LOG_DIR}/genieacs-fs-access.log
GENIEACS_UI_ACCESS_LOG_FILE=${GENIEACS_LOG_DIR}/genieacs-ui-access.log
GENIEACS_DEBUG_FILE=${GENIEACS_LOG_DIR}/genieacs-debug.yaml
GENIEACS_EXT_DIR=${GENIEACS_EXT_DIR}
GENIEACS_UI_JWT_SECRET=${JWT_SECRET}
EOF2
chown "${GENIEACS_USER}:${GENIEACS_USER}" "${GENIEACS_ENV}"
chmod 0600 "${GENIEACS_ENV}"

write_service() {
    local service="$1"
    local description="$2"
    local binary="$3"

    cat > "/etc/systemd/system/${service}.service" <<EOF2
[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target
EOF2

    if [[ "${MONGO_MODE}" == "native" ]]; then
        cat >> "/etc/systemd/system/${service}.service" <<EOF2
Requires=${MONGO_NATIVE_UNIT}
After=${MONGO_NATIVE_UNIT}
EOF2
    elif [[ "${MONGO_MODE}" == "docker" ]]; then
        cat >> "/etc/systemd/system/${service}.service" <<EOF2
Requires=${MONGO_UNIT}
After=${MONGO_UNIT}
EOF2
    fi

    cat >> "/etc/systemd/system/${service}.service" <<EOF2

[Service]
Type=simple
User=${GENIEACS_USER}
Group=${GENIEACS_USER}
EnvironmentFile=${GENIEACS_ENV}
ExecStart=${GENIEACS_BIN_DIR}/${binary}
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

write_service "genieacs-cwmp" "GenieACS CWMP" "genieacs-cwmp"
write_service "genieacs-fs" "GenieACS File Server" "genieacs-fs"
write_service "genieacs-nbi" "GenieACS NBI" "genieacs-nbi"
write_service "genieacs-ui" "GenieACS UI" "genieacs-ui"

cat > /etc/logrotate.d/genieacs <<'EOF2'
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
chmod 0644 /etc/logrotate.d/genieacs

systemctl daemon-reload
for service in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
    systemctl enable "${service}.service"
    systemctl restart "${service}.service"
done

wait_for_services() {
    for service in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
        local active=false
        for _ in {1..30}; do
            if systemctl is-active --quiet "${service}.service"; then
                active=true
                break
            fi
            sleep 1
        done
        if [[ "${active}" != true ]]; then
            systemctl status "${service}.service" --no-pager -l || true
            journalctl -u "${service}.service" --no-pager -n 80 || true
            die "Service ${service} gagal aktif."
        fi
        ok "${service}: RUNNING"
    done
}

wait_for_services

check_port() {
    local port="$1"
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
        ok "TCP ${port}: LISTENING"
    else
        die "TCP ${port} tidak listening."
    fi
}

check_port 3000
check_port 7547
check_port 7557
check_port 7567

curl -fsS --max-time 10 http://127.0.0.1:3000/ >/dev/null || die "GenieACS UI HTTP health check gagal."
curl -fsS --max-time 10 http://127.0.0.1:7557/ >/dev/null || warn "NBI HTTP root tidak 2xx; service/port tetap diperiksa."

backup_existing_db() {
    local backup_root="/var/backups/genieacs"
    local stamp="$(date '+%Y%m%d-%H%M%S')"
    install -d -m 0700 "${backup_root}"

    if [[ "${MONGO_MODE}" == "native" ]]; then
        mongodump --db "${MONGO_DB}" --out "${backup_root}/${stamp}"
    else
        docker exec "${MONGO_CONTAINER}" mongodump --db "${MONGO_DB}" --out "/tmp/genieacs-backup-${stamp}"
        docker cp "${MONGO_CONTAINER}:/tmp/genieacs-backup-${stamp}" "${backup_root}/${stamp}"
        docker exec "${MONGO_CONTAINER}" rm -rf "/tmp/genieacs-backup-${stamp}"
    fi
    chmod -R go-rwx "${backup_root}/${stamp}"
    echo "${backup_root}/${stamp}"
}

restore_database() {
    [[ "${SKIP_DB}" == false ]] || die "--restore-db tidak dapat digunakan bersama --skip-db."
    [[ -d "${DB_DIR}" ]] || die "Folder database tidak ditemukan: ${DB_DIR}"

    local dump_dir=""
    if [[ -d "${DB_DIR}/${MONGO_DB}" ]]; then
        dump_dir="${DB_DIR}/${MONGO_DB}"
    else
        dump_dir="${DB_DIR}"
    fi

    if ! find "${dump_dir}" -maxdepth 2 -type f \( -name '*.bson' -o -name '*.bson.gz' -o -name '*.metadata.json' \) -print -quit | grep -q .; then
        die "Folder DB tidak terlihat seperti mongodump: ${dump_dir}"
    fi

    log "Creating backup before destructive restore..."
    local backup_path
    backup_path="$(backup_existing_db)"
    ok "Backup database: ${backup_path}"

    for service in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
        systemctl stop "${service}.service"
    done

    log "Restoring MongoDB dump: ${dump_dir}"
    mongo_restore "${dump_dir}"
    mongo_eval 'db.adminCommand({ping:1})' >/dev/null

    for service in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
        systemctl start "${service}.service"
    done

    wait_for_services
    ok "Virtual parameters/database restore selesai."
}

if [[ "${RESTORE_DB}" == true ]]; then
    restore_database
elif [[ "${AUTO_YES}" != true && -d "${DB_DIR}" ]]; then
    printf '\n%bFolder DB ditemukan:%b %s\n' "${YELLOW}" "${NC}" "${DB_DIR}"
    read -r -p "Restore database sekarang? (y/n): " answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        restore_database
    else
        warn "Restore database dilewati."
    fi
fi

wait_for_services
check_port 3000
check_port 7547
check_port 7557
check_port 7567

printf '\n%b============================================================%b\n' "${GREEN}" "${NC}"
printf '%b GenieACS INSTALLATION SUCCESS%b\n' "${GREEN}" "${NC}"
printf '%b============================================================%b\n' "${GREEN}" "${NC}"
printf 'OS           : %s\n' "${PRETTY_NAME:-${OS_ID}}"
printf 'Architecture  : %s\n' "${ARCH}"
printf 'Node.js       : %s\n' "$(node -v)"
printf 'GenieACS      : %s\n' "${GENIEACS_VERSION}"
printf 'MongoDB mode  : %s\n' "${MONGO_MODE:-skipped}"
printf 'MongoDB       : %s\n' "${MONGODB_MAJOR}"
printf 'UI            : http://%s:3000\n' "${LOCAL_IP}"
printf 'CWMP          : http://%s:7547\n' "${LOCAL_IP}"
printf 'NBI           : http://%s:7557\n' "${LOCAL_IP}"
printf 'FS            : http://%s:7567\n' "${LOCAL_IP}"
printf 'Environment   : %s\n' "${GENIEACS_ENV}"
printf 'Installer log : %s\n' "${LOG_FILE}"
printf '%b============================================================%b\n' "${GREEN}" "${NC}"

send_telegram "✅ GenieACS Installation Completed\nServer: ${SERVER_HOSTNAME}\nIP: ${LOCAL_IP}\nOS: ${PRETTY_NAME:-${OS_ID}}\nArch: ${ARCH}\nNode: $(node -v)\nGenieACS: ${GENIEACS_VERSION}\nMongoDB: ${MONGODB_MAJOR} (${MONGO_MODE:-skipped})\nUI: http://${LOCAL_IP}:3000\nCWMP: 7547\nNBI: 7557\nFS: 7567"

exit 0
