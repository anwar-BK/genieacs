#!/usr/bin/env bash
#
# GenieACS Auto Installer v3
#
# Targets:
#   - Ubuntu 20.04 / 22.04 / 24.04 (amd64/arm64 where MongoDB supports it)
#   - Debian 12 / Armbian Debian 12 (amd64 native; arm64 via official MongoDB Docker image)
#   - Armbian Ubuntu 20.04 / 22.04 / 24.04 (native MongoDB where supported)
#
# Components:
#   - GenieACS 1.2.16
#   - Node.js 22 LTS
#   - MongoDB 8.0
#
# Important:
#   MongoDB is NOT compatible with Linux kernel 6.19 through 7.0.13.
#   This installer refuses to touch MongoDB on those kernels instead of
#   installing a known-broken configuration.
#
# Usage:
#   sudo bash genieacs_auto_installer_v3.sh
#   sudo bash genieacs_auto_installer_v3.sh --yes
#   sudo bash genieacs_auto_installer_v3.sh --yes --restore-db
#   sudo bash genieacs_auto_installer_v3.sh --yes --mongo-uri 'mongodb://...'
#
# Optional Telegram:
#   export TELEGRAM_BOT_TOKEN='...'
#   export TELEGRAM_CHAT_ID='...'
#

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_VERSION="3.0.0"
GENIEACS_VERSION="1.2.16"
NODE_MAJOR="22"
MONGODB_MAJOR="8.0"
MONGODB_IMAGE="mongo:8.0"
GENIEACS_USER="genieacs"
GENIEACS_HOME="/opt/genieacs"
GENIEACS_ENV="${GENIEACS_HOME}/genieacs.env"
GENIEACS_EXT_DIR="${GENIEACS_HOME}/ext"
GENIEACS_LOG_DIR="/var/log/genieacs"
MONGO_DB="genieacs"
MONGO_URI_DEFAULT="mongodb://127.0.0.1:27017/${MONGO_DB}"
MONGO_CONTAINER="genieacs-mongodb"
MONGO_DATA_DIR="/var/lib/genieacs-mongodb"
MONGO_LOG_DIR="/var/log/genieacs-mongodb"
MONGO_UNIT="genieacs-mongodb.service"
BACKUP_ROOT="/var/backups/genieacs"
LOG_FILE="/var/log/genieacs-installer.log"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

AUTO_YES=false
RESTORE_DB=false
SKIP_DB=false
NO_TELEGRAM=false
MONGO_URI="${MONGO_URI_DEFAULT}"
EXTERNAL_MONGO_URI=""

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DB_DIR="${SCRIPT_DIR}/db"

SERVER_HOSTNAME="$(hostname 2>/dev/null || true)"
LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
LOCAL_IP="${LOCAL_IP:-127.0.0.1}"
OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
OS_CODENAME=""
PRETTY_NAME=""
ARCH=""
INIT_SYSTEM=""
KERNEL_RELEASE="$(uname -r)"
MONGO_MODE=""
NODE_BIN=""
GENIEACS_BIN_DIR=""

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

log() { printf '%b[%s]%b %s\n' "${CYAN}" "$(date '+%F %T')" "${NC}" "$1"; }
ok() { printf '%b✔%b %s\n' "${GREEN}" "${NC}" "$1"; }
warn() { printf '%b⚠%b %s\n' "${YELLOW}" "${NC}" "$1"; }
die() { printf '%b✘%b %s\n' "${RED}" "${NC}" "$1" >&2; exit 1; }

send_telegram() {
    local message="${1:-}"
    if [[ "${NO_TELEGRAM}" == true || -z "${TELEGRAM_BOT_TOKEN}" || -z "${TELEGRAM_CHAT_ID}" ]]; then
        return 0
    fi
    curl -fsS --connect-timeout 10 --max-time 20 \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1 || \
        warn "Telegram notification gagal dikirim."
}

on_error() {
    local code=$?
    local line="${1:-unknown}"
    printf '\n%b============================================================%b\n' "${RED}" "${NC}"
    printf '%bINSTALLER GAGAL%b\n' "${RED}" "${NC}"
    printf 'Line: %s\nExit: %s\n' "${line}" "${code}"
    printf '%b============================================================%b\n' "${RED}" "${NC}"

    systemctl --failed --no-pager 2>/dev/null || true
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^mongod.service'; then
        systemctl status mongod --no-pager -l 2>/dev/null || true
        journalctl -u mongod --no-pager -n 60 2>/dev/null || true
    fi
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${MONGO_UNIT}"; then
        systemctl status "${MONGO_UNIT}" --no-pager -l 2>/dev/null || true
        journalctl -u "${MONGO_UNIT}" --no-pager -n 60 2>/dev/null || true
    fi

    send_telegram "❌ GenieACS installer FAILED\nServer: ${SERVER_HOSTNAME}\nIP: ${LOCAL_IP}\nOS: ${PRETTY_NAME:-${OS_ID}}\nArch: ${ARCH}\nKernel: ${KERNEL_RELEASE}\nLine: ${line}\nExit: ${code}"
    exit "${code}"
}
trap 'on_error $LINENO' ERR

usage() {
    cat <<USAGE
GenieACS Auto Installer v${SCRIPT_VERSION}

Usage:
  sudo bash ${0##*/} [options]

Options:
  --yes, -y                  Non-interactive mode.
  --restore-db               Restore ${SCRIPT_DIR}/db into database.
  --skip-db                  Do not install/manage local MongoDB.
  --mongo-uri URI            Use an external MongoDB URI; implies --skip-db.
  --no-telegram              Disable Telegram notifications.
  --help, -h                 Show this help.

Examples:
  sudo bash ${0##*/}
  sudo bash ${0##*/} --yes
  sudo bash ${0##*/} --yes --restore-db
  sudo bash ${0##*/} --yes --mongo-uri 'mongodb://10.0.0.10:27017/genieacs'
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y) AUTO_YES=true ;;
        --restore-db) RESTORE_DB=true ;;
        --skip-db) SKIP_DB=true ;;
        --mongo-uri)
            [[ $# -ge 2 ]] || die "--mongo-uri membutuhkan URI."
            EXTERNAL_MONGO_URI="$2"
            shift
            ;;
        --no-telegram) NO_TELEGRAM=true ;;
        --help|-h) usage; exit 0 ;;
        *) die "Opsi tidak dikenal: $1" ;;
    esac
    shift
done

[[ "$(id -u)" -eq 0 ]] || die "Jalankan sebagai root: sudo bash ${0##*/}"

[[ -r /etc/os-release ]] || die "/etc/os-release tidak ditemukan."
# shellcheck disable=SC1091
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_ID_LIKE="${ID_LIKE:-}"
OS_VERSION_ID="${VERSION_ID:-unknown}"
OS_CODENAME="${VERSION_CODENAME:-}"
PRETTY_NAME="${PRETTY_NAME:-${OS_ID} ${OS_VERSION_ID}}"
ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
INIT_SYSTEM="$(ps -p 1 -o comm= 2>/dev/null || true)"

mkdir -p "$(dirname "${LOG_FILE}")"
exec > >(tee -a "${LOG_FILE}") 2>&1

printf '\n%b============================================================%b\n' "${GREEN}" "${NC}"
printf '%b GenieACS Auto Installer v%s%b\n' "${GREEN}" "${SCRIPT_VERSION}" "${NC}"
printf '%b GenieACS %s | Node.js %s LTS | MongoDB %s%b\n' "${GREEN}" "${GENIEACS_VERSION}" "${NODE_MAJOR}" "${MONGODB_MAJOR}" "${NC}"
printf '%b============================================================%b\n\n' "${GREEN}" "${NC}"

[[ "${INIT_SYSTEM}" == "systemd" ]] || die "systemd diperlukan. PID 1: ${INIT_SYSTEM}"

case "${ARCH}" in
    amd64|arm64) ;;
    *) die "Architecture ${ARCH:-unknown} tidak didukung. Dibutuhkan amd64 atau arm64." ;;
esac

# -----------------------------------------------------------------------------
# Detection
# -----------------------------------------------------------------------------

if [[ -z "${OS_CODENAME}" ]] && command -v lsb_release >/dev/null 2>&1; then
    OS_CODENAME="$(lsb_release -sc 2>/dev/null || true)"
fi

IS_ARMBIAN=false
if [[ -f /etc/armbian-release ]] || grep -qi armbian /etc/os-release 2>/dev/null; then
    IS_ARMBIAN=true
fi

# Armbian can report Ubuntu/Debian as its userspace. We use the userspace
# codename, not the board name, to select repositories.
case "${OS_ID}" in
    ubuntu)
        case "${OS_CODENAME}" in
            focal|jammy|noble) ;;
            *) die "Ubuntu ${OS_CODENAME:-unknown} tidak didukung. Gunakan Ubuntu 20.04/22.04/24.04." ;;
        esac
        ;;
    debian)
        case "${OS_CODENAME}" in
            bookworm) ;;
            *) die "Debian ${OS_CODENAME:-unknown} tidak didukung oleh MongoDB 8 profile ini. Debian 12 Bookworm diperlukan." ;;
        esac
        ;;
    *)
        if [[ "${OS_ID_LIKE}" == *ubuntu* || "${OS_ID_LIKE}" == *debian* ]]; then
            die "Distro turunan ${OS_ID} tidak dikenali secara aman. Untuk Armbian, /etc/os-release harus melaporkan Ubuntu atau Debian.";
        fi
        die "OS ${OS_ID} tidak didukung. Target: Ubuntu 20/22/24 atau Debian 12/Armbian berbasis keduanya.";
        ;;
esac

log "Host=${SERVER_HOSTNAME} | IP=${LOCAL_IP} | OS=${PRETTY_NAME} | codename=${OS_CODENAME} | arch=${ARCH} | kernel=${KERNEL_RELEASE}"
log "Armbian=${IS_ARMBIAN} | script=${SCRIPT_DIR}"

# -----------------------------------------------------------------------------
# Kernel compatibility: fail BEFORE installing MongoDB.
# MongoDB documents 6.19 through 7.0.13 as incompatible, including Docker.
# -----------------------------------------------------------------------------

KERNEL_VERSION="${KERNEL_RELEASE%%-*}"
IFS='.' read -r KMAJOR KMINOR KPATCH _ <<< "${KERNEL_VERSION}"
KMAJOR="${KMAJOR:-0}"; KMINOR="${KMINOR:-0}"; KPATCH="${KPATCH:-0}"

kernel_is_affected() {
    if (( KMAJOR == 6 && KMINOR >= 19 )); then
        return 0
    fi
    if (( KMAJOR == 7 && KMINOR == 0 && KPATCH <= 13 )); then
        return 0
    fi
    if (( KMAJOR == 7 && KMINOR < 0 )); then
        return 0
    fi
    return 1
}

if kernel_is_affected; then
    die "Kernel ${KERNEL_RELEASE} tidak kompatibel dengan MongoDB ${MONGODB_MAJOR}. MongoDB mendokumentasikan kernel 6.19 sampai 7.0.13 sebagai tidak kompatibel. Upgrade/downgrade kernel ke versi yang didukung sebelum menjalankan installer ini. Docker juga tidak menghindari masalah tersebut."
fi

# -----------------------------------------------------------------------------
# CPU compatibility
# -----------------------------------------------------------------------------

if [[ "${ARCH}" == "arm64" ]]; then
    # Match the common-feature heuristic used by the official MongoDB Docker
    # image for ARM64. MongoDB requires ARMv8.2-A or later.
    if [[ -r /proc/cpuinfo ]] && ! grep -Eq '^Features.*(fphp|dcpop|sha3|sm3|sm4|asimddp|sha512|sve)( |$)' /proc/cpuinfo; then
        die "ARM64 CPU tidak menunjukkan fitur umum ARMv8.2-A. MongoDB membutuhkan ARMv8.2-A atau lebih baru; STB/board ini tidak aman untuk MongoDB 8."
    fi
fi

if [[ "${ARCH}" == "amd64" ]]; then
    if ! grep -qm1 -E '\bavx\b' /proc/cpuinfo 2>/dev/null; then
        die "CPU x86_64 tidak menunjukkan AVX. MongoDB 5+ memerlukan AVX dan minimum microarchitecture tertentu."
    fi
fi

# -----------------------------------------------------------------------------
# Resource checks
# -----------------------------------------------------------------------------

MEM_MB="$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
DISK_GB="$(df -Pk / | awk 'NR==2 {printf "%d", $4/1024/1024}' 2>/dev/null || echo 0)"
(( MEM_MB >= 1024 )) || warn "RAM terdeteksi ${MEM_MB} MB. GenieACS+MongoDB dapat berjalan pada sistem kecil, tetapi 1 GB atau lebih sangat disarankan."
(( DISK_GB >= 8 )) || die "Ruang kosong root hanya ${DISK_GB} GB. Sediakan minimal 8 GB untuk instalasi yang aman."

# -----------------------------------------------------------------------------
# User confirmation
# -----------------------------------------------------------------------------

if [[ -n "${EXTERNAL_MONGO_URI}" ]]; then
    SKIP_DB=true
    MONGO_URI="${EXTERNAL_MONGO_URI}"
fi

if [[ "${RESTORE_DB}" == true && "${SKIP_DB}" == true ]]; then
    die "--restore-db tidak dapat dipakai bersama --skip-db atau --mongo-uri."
fi

if [[ "${AUTO_YES}" != true ]]; then
    cat <<EOF2
Target instalasi:
  OS              : ${PRETTY_NAME}
  Armbian         : ${IS_ARMBIAN}
  Architecture    : ${ARCH}
  Kernel          : ${KERNEL_RELEASE}
  RAM             : ${MEM_MB} MB
  Free disk       : ${DISK_GB} GB
  Node.js         : ${NODE_MAJOR}.x LTS
  GenieACS        : ${GENIEACS_VERSION}
  MongoDB         : ${MONGODB_MAJOR}
  MongoDB mode    : $([[ "${SKIP_DB}" == true ]] && echo external/skipped || echo local)
  Restore DB      : ${RESTORE_DB}
  DB directory    : ${DB_DIR}

Lanjutkan? (y/n)
EOF2
    read -r confirmation
    [[ "${confirmation}" =~ ^[Yy]$ ]] || { ok "Instalasi dibatalkan."; exit 0; }
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# -----------------------------------------------------------------------------
# Base packages
# -----------------------------------------------------------------------------

log "Installing base packages..."
apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg openssl jq lsb-release logrotate \
    procps iproute2 net-tools tar gzip xz-utils rsync \
    build-essential python3

# -----------------------------------------------------------------------------
# Node.js 22 LTS
# -----------------------------------------------------------------------------

install_nodejs() {
    local current_major=""
    if command -v node >/dev/null 2>&1; then
        current_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)"
    fi

    if [[ "${current_major}" != "${NODE_MAJOR}" ]]; then
        log "Installing Node.js ${NODE_MAJOR}.x..."
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh
        bash /tmp/nodesource_setup.sh
        apt-get install -y nodejs
        rm -f /tmp/nodesource_setup.sh
    fi

    command -v node >/dev/null 2>&1 || die "node tidak ditemukan."
    command -v npm >/dev/null 2>&1 || die "npm tidak ditemukan."
    current_major="$(node -p 'process.versions.node.split(".")[0]')"
    [[ "${current_major}" == "${NODE_MAJOR}" ]] || die "Node.js version mismatch: ${current_major}; expected ${NODE_MAJOR}.x"
    NODE_BIN="$(command -v node)"
    ok "Node.js $(node -v) / npm $(npm -v)"
}

install_nodejs

# -----------------------------------------------------------------------------
# MongoDB helpers
# -----------------------------------------------------------------------------

mongo_ping() {
    if [[ "${MONGO_MODE}" == "native" ]]; then
        mongosh --quiet --host 127.0.0.1 --port 27017 --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx '1'
    elif [[ "${MONGO_MODE}" == "docker" ]]; then
        docker exec "${MONGO_CONTAINER}" mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx '1'
    else
        mongosh --quiet --host 127.0.0.1 --port 27017 --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx '1'
    fi
}

wait_for_mongo() {
    local attempts="${1:-60}"
    for ((i=1; i<=attempts; i++)); do
        if mongo_ping; then
            ok "MongoDB ping OK."
            return 0
        fi
        sleep 1
    done
    return 1
}

write_native_mongod_conf() {
    install -d -m 0755 /var/lib/mongodb /var/log/mongodb
    chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb 2>/dev/null || true

    # Preserve an existing configuration. Only create ours when none exists.
    if [[ ! -f /etc/mongod.conf ]]; then
        cat > /etc/mongod.conf <<'MONGOCONF'
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
        chown root:root /etc/mongod.conf
        chmod 0644 /etc/mongod.conf
    fi
}

install_mongodb_ubuntu() {
    MONGO_MODE="native"
    log "Installing MongoDB ${MONGODB_MAJOR} natively on Ubuntu..."

    install -d -m 0755 /usr/share/keyrings
    local keyring="/usr/share/keyrings/mongodb-server-${MONGODB_MAJOR}.gpg"
    curl -fsSL "https://pgp.mongodb.com/server-${MONGODB_MAJOR}.asc" | gpg --dearmor --yes -o "${keyring}"
    chmod 0644 "${keyring}"

    rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    printf 'deb [ arch=amd64,arm64 signed-by=%s ] https://repo.mongodb.org/apt/ubuntu %s/mongodb-org/%s multiverse\n' \
        "${keyring}" "${OS_CODENAME}" "${MONGODB_MAJOR}" \
        > "/etc/apt/sources.list.d/mongodb-org-${MONGODB_MAJOR}.list"

    apt-get update
    apt-get install -y mongodb-org mongodb-mongosh mongodb-database-tools
    write_native_mongod_conf

    systemctl daemon-reload
    systemctl enable mongod
    systemctl restart mongod

    wait_for_mongo 60 || {
        journalctl -u mongod --no-pager -n 80 || true
        die "MongoDB native gagal start. Installer berhenti sebelum GenieACS dijalankan."
    }
}

install_mongodb_debian_amd64() {
    MONGO_MODE="native"
    log "Installing MongoDB ${MONGODB_MAJOR} natively on Debian 12 amd64..."

    install -d -m 0755 /usr/share/keyrings
    local keyring="/usr/share/keyrings/mongodb-server-${MONGODB_MAJOR}.gpg"
    curl -fsSL "https://pgp.mongodb.com/server-${MONGODB_MAJOR}.asc" | gpg --dearmor --yes -o "${keyring}"
    chmod 0644 "${keyring}"

    rm -f /etc/apt/sources.list.d/mongodb-org-*.list
    printf 'deb [ signed-by=%s ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/%s main\n' \
        "${keyring}" "${MONGODB_MAJOR}" \
        > "/etc/apt/sources.list.d/mongodb-org-${MONGODB_MAJOR}.list"

    apt-get update
    apt-get install -y mongodb-org mongodb-mongosh mongodb-database-tools
    write_native_mongod_conf

    systemctl daemon-reload
    systemctl enable mongod
    systemctl restart mongod

    wait_for_mongo 60 || {
        journalctl -u mongod --no-pager -n 80 || true
        die "MongoDB native gagal start."
    }
}

install_mongodb_docker() {
    MONGO_MODE="docker"
    log "Installing Docker-backed MongoDB ${MONGODB_IMAGE}..."

    if ! command -v docker >/dev/null 2>&1; then
        apt-get install -y docker.io
    fi
    command -v docker >/dev/null 2>&1 || die "Docker tidak tersedia."
    systemctl enable --now docker

    install -d -m 0755 "${MONGO_DATA_DIR}" "${MONGO_LOG_DIR}"

    if docker container inspect "${MONGO_CONTAINER}" >/dev/null 2>&1; then
        if ! docker inspect -f '{{.Config.Image}}' "${MONGO_CONTAINER}" | grep -q '^mongo:8\.0'; then
            die "Container ${MONGO_CONTAINER} sudah ada dengan image berbeda. Saya tidak akan menghapus container/data secara otomatis."
        fi
    else
        docker pull "${MONGODB_IMAGE}"
        docker create \
            --name "${MONGO_CONTAINER}" \
            --restart=no \
            --publish 127.0.0.1:27017:27017 \
            --volume "${MONGO_DATA_DIR}:/data/db" \
            "${MONGODB_IMAGE}" \
            mongod --bind_ip_all --wiredTigerCacheSizeGB 0.25 >/dev/null
    fi

    # Use a real long-running systemd unit so systemctl status reflects the
    # container's lifetime. Do not double-manage Docker's restart policy.
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
    # If the container was already running, stop it so systemd can take ownership.
    if [[ "$(docker inspect -f '{{.State.Running}}' "${MONGO_CONTAINER}" 2>/dev/null || echo false)" == "true" ]]; then
        docker stop -t 30 "${MONGO_CONTAINER}" >/dev/null
    fi
    systemctl daemon-reload
    systemctl enable "${MONGO_UNIT}"
    systemctl start "${MONGO_UNIT}"

    wait_for_mongo 90 || {
        docker logs --tail 120 "${MONGO_CONTAINER}" || true
        die "MongoDB Docker gagal start."
    }
}

install_local_mongodb() {
    case "${OS_ID}:${ARCH}" in
        ubuntu:amd64|ubuntu:arm64)
            install_mongodb_ubuntu
            ;;
        debian:amd64)
            install_mongodb_debian_amd64
            ;;
        debian:arm64)
            # MongoDB 8 Debian package support is documented for x86_64 only.
            # Use the official MongoDB Docker image for Debian/Armbian ARM64.
            install_mongodb_docker
            ;;
        *)
            die "Kombinasi ${OS_ID}/${ARCH} tidak memiliki jalur MongoDB yang aman di installer ini."
            ;;
    esac
}

if [[ "${SKIP_DB}" == true ]]; then
    MONGO_MODE="external"
    if [[ -z "${MONGO_URI}" ]]; then
        die "MongoDB dilewati tetapi tidak ada --mongo-uri."
    fi
    log "Local MongoDB dilewati. Menggunakan external URI."
else
    install_local_mongodb
fi

if [[ "${MONGO_MODE}" == "external" ]]; then
    # GenieACS needs a working MongoDB. Use mongosh if available, otherwise only
    # accept the URI and let GenieACS validate it at startup.
    if command -v mongosh >/dev/null 2>&1; then
        if ! mongosh --quiet "${MONGO_URI}" --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx '1'; then
            die "External MongoDB URI tidak lolos ping."
        fi
    else
        warn "mongosh tidak tersedia untuk menguji external MongoDB URI; GenieACS akan memverifikasinya saat start."
    fi
fi

# -----------------------------------------------------------------------------
# GenieACS
# -----------------------------------------------------------------------------

install_genieacs() {
    log "Installing GenieACS ${GENIEACS_VERSION}..."
    local installed=""
    installed="$(npm list -g --depth=0 --json 2>/dev/null | jq -r '.dependencies.genieacs.version // empty' 2>/dev/null || true)"

    if [[ "${installed}" != "${GENIEACS_VERSION}" ]]; then
        npm install -g --unsafe-perm "genieacs@${GENIEACS_VERSION}"
    fi

    for bin in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
        command -v "${bin}" >/dev/null 2>&1 || die "${bin} tidak ditemukan setelah instalasi GenieACS."
    done

    GENIEACS_BIN_DIR="$(dirname "$(command -v genieacs-cwmp)")"
    local final_version=""
    final_version="$(npm list -g --depth=0 --json 2>/dev/null | jq -r '.dependencies.genieacs.version // empty' 2>/dev/null || true)"
    [[ "${final_version}" == "${GENIEACS_VERSION}" ]] || die "Versi GenieACS mismatch: ${final_version:-unknown}"
    ok "GenieACS ${final_version} installed."
}

install_genieacs

if ! id "${GENIEACS_USER}" >/dev/null 2>&1; then
    useradd --system --no-create-home --user-group "${GENIEACS_USER}"
fi

install -d -m 0755 -o "${GENIEACS_USER}" -g "${GENIEACS_USER}" \
    "${GENIEACS_HOME}" "${GENIEACS_EXT_DIR}" "${GENIEACS_LOG_DIR}"

JWT_SECRET=""
if [[ -f "${GENIEACS_ENV}" ]]; then
    JWT_SECRET="$(sed -n 's/^GENIEACS_UI_JWT_SECRET=//p' "${GENIEACS_ENV}" | head -n1 || true)"
fi
[[ -n "${JWT_SECRET}" && "${JWT_SECRET}" != "secret" ]] || JWT_SECRET="$(openssl rand -hex 32)"

# Never silently replace a previously configured MongoDB URI with localhost.
if [[ "${MONGO_MODE}" == "external" ]]; then
    : "${MONGO_URI:?Mongo URI required}"
elif [[ -f "${GENIEACS_ENV}" ]]; then
    existing_url="$(sed -n 's/^GENIEACS_MONGODB_CONNECTION_URL=//p' "${GENIEACS_ENV}" | head -n1 || true)"
    if [[ -n "${existing_url}" ]]; then
        MONGO_URI="${existing_url}"
    fi
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

# -----------------------------------------------------------------------------
# systemd services
# -----------------------------------------------------------------------------

write_service() {
    local service="$1"
    local description="$2"
    local binary="$3"
    local unit="/etc/systemd/system/${service}.service"

    cat > "${unit}" <<EOF2
[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target
EOF2

    if [[ "${MONGO_MODE}" == "native" ]]; then
        cat >> "${unit}" <<EOF2
Requires=mongod.service
After=mongod.service
EOF2
    elif [[ "${MONGO_MODE}" == "docker" ]]; then
        cat >> "${unit}" <<EOF2
Requires=${MONGO_UNIT}
After=${MONGO_UNIT}
EOF2
    fi

    cat >> "${unit}" <<EOF2

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

# -----------------------------------------------------------------------------
# Start + verify GenieACS before any DB restore.
# -----------------------------------------------------------------------------

systemctl daemon-reload
for service in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
    systemctl enable "${service}.service"
    systemctl restart "${service}.service"
done

wait_for_genieacs() {
    local service
    for service in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
        local active=false
        for _ in {1..45}; do
            if systemctl is-active --quiet "${service}.service"; then
                active=true
                break
            fi
            sleep 1
        done
        if [[ "${active}" != true ]]; then
            systemctl status "${service}.service" --no-pager -l || true
            journalctl -u "${service}.service" --no-pager -n 100 || true
            die "Service ${service} gagal aktif."
        fi
        ok "${service}: RUNNING"
    done
}

check_port() {
    local port="$1"
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
        ok "TCP ${port}: LISTENING"
    else
        die "TCP ${port} tidak listening."
    fi
}

wait_for_genieacs
check_port 3000
check_port 7547
check_port 7557
check_port 7567

curl -fsS --max-time 10 http://127.0.0.1:3000/ >/dev/null || die "GenieACS UI HTTP health check gagal."

# -----------------------------------------------------------------------------
# Database restore, safely.
# -----------------------------------------------------------------------------

backup_existing_db() {
    local stamp="$(date '+%Y%m%d-%H%M%S')"
    local out="${BACKUP_ROOT}/${stamp}"
    install -d -m 0700 "${BACKUP_ROOT}"

    if [[ "${MONGO_MODE}" == "native" ]]; then
        mongodump --db "${MONGO_DB}" --out "${out}"
    elif [[ "${MONGO_MODE}" == "docker" ]]; then
        docker exec "${MONGO_CONTAINER}" mongodump --db "${MONGO_DB}" --out "/tmp/genieacs-backup-${stamp}"
        docker cp "${MONGO_CONTAINER}:/tmp/genieacs-backup-${stamp}" "${out}"
        docker exec "${MONGO_CONTAINER}" rm -rf "/tmp/genieacs-backup-${stamp}"
    else
        die "Backup lokal tidak tersedia untuk external MongoDB."
    fi
    chmod -R go-rwx "${out}"
    printf '%s\n' "${out}"
}

restore_database() {
    [[ "${SKIP_DB}" == false ]] || die "Restore membutuhkan MongoDB lokal."
    [[ -d "${DB_DIR}" ]] || die "Folder DB tidak ditemukan: ${DB_DIR}"

    local dump_dir="${DB_DIR}"
    [[ -d "${DB_DIR}/${MONGO_DB}" ]] && dump_dir="${DB_DIR}/${MONGO_DB}"

    if ! find "${dump_dir}" -maxdepth 2 -type f \( -name '*.bson' -o -name '*.bson.gz' -o -name '*.metadata.json' \) -print -quit | grep -q .; then
        die "Folder ${dump_dir} tidak terlihat seperti mongodump."
    fi

    log "Creating backup before destructive restore..."
    local backup_path
    backup_path="$(backup_existing_db)"
    ok "Backup database: ${backup_path}"

    for service in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
        systemctl stop "${service}.service"
    done

    local restore_rc=0
    if [[ "${MONGO_MODE}" == "native" ]]; then
        mongorestore --drop --db "${MONGO_DB}" "${dump_dir}" || restore_rc=$?
    else
        local tmp="/tmp/genieacs-restore-$$"
        rm -rf "${tmp}"
        mkdir -p "${tmp}"
        rsync -a "${dump_dir}/" "${tmp}/"
        docker exec "${MONGO_CONTAINER}" rm -rf /tmp/genieacs-restore
        docker cp "${tmp}/." "${MONGO_CONTAINER}:/tmp/genieacs-restore/"
        docker exec "${MONGO_CONTAINER}" mongorestore --drop --db "${MONGO_DB}" /tmp/genieacs-restore || restore_rc=$?
        docker exec "${MONGO_CONTAINER}" rm -rf /tmp/genieacs-restore || true
        rm -rf "${tmp}"
    fi

    for service in genieacs-cwmp genieacs-fs genieacs-nbi genieacs-ui; do
        systemctl start "${service}.service" || true
    done

    if (( restore_rc != 0 )); then
        die "mongorestore gagal (exit ${restore_rc}). Service GenieACS sudah dicoba dihidupkan kembali. Backup tersedia di ${backup_path}"
    fi

    mongo_ping || die "MongoDB ping gagal setelah restore."
    wait_for_genieacs
    ok "Database restore selesai. Backup tersedia di ${backup_path}"
}

if [[ "${RESTORE_DB}" == true ]]; then
    restore_database
elif [[ "${AUTO_YES}" != true && -d "${DB_DIR}" && "${SKIP_DB}" == false ]]; then
    printf '\n%bFolder DB ditemukan:%b %s\n' "${YELLOW}" "${NC}" "${DB_DIR}"
    read -r -p "Restore database sekarang? (y/n): " answer
    if [[ "${answer}" =~ ^[Yy]$ ]]; then
        restore_database
    else
        warn "Restore database dilewati."
    fi
fi

# Final verification after optional restore.
wait_for_genieacs
check_port 3000
check_port 7547
check_port 7557
check_port 7567
curl -fsS --max-time 10 http://127.0.0.1:3000/ >/dev/null || die "Final UI health check gagal."

printf '\n%b============================================================%b\n' "${GREEN}" "${NC}"
printf '%b GenieACS INSTALLATION SUCCESS%b\n' "${GREEN}" "${NC}"
printf '%b============================================================%b\n' "${GREEN}" "${NC}"
printf 'OS            : %s\n' "${PRETTY_NAME}"
printf 'Architecture  : %s\n' "${ARCH}"
printf 'Kernel        : %s\n' "${KERNEL_RELEASE}"
printf 'Node.js       : %s\n' "$(node -v)"
printf 'GenieACS      : %s\n' "${GENIEACS_VERSION}"
printf 'MongoDB mode  : %s\n' "${MONGO_MODE}"
printf 'MongoDB       : %s\n' "${MONGODB_MAJOR}"
printf 'UI            : http://%s:3000\n' "${LOCAL_IP}"
printf 'CWMP          : http://%s:7547\n' "${LOCAL_IP}"
printf 'NBI           : http://%s:7557\n' "${LOCAL_IP}"
printf 'FS            : http://%s:7567\n' "${LOCAL_IP}"
printf 'Environment   : %s\n' "${GENIEACS_ENV}"
printf 'Installer log : %s\n' "${LOG_FILE}"
printf '%b============================================================%b\n' "${GREEN}" "${NC}"

send_telegram "✅ GenieACS Installation Completed\nServer: ${SERVER_HOSTNAME}\nIP: ${LOCAL_IP}\nOS: ${PRETTY_NAME}\nArch: ${ARCH}\nKernel: ${KERNEL_RELEASE}\nNode: $(node -v)\nGenieACS: ${GENIEACS_VERSION}\nMongoDB: ${MONGODB_MAJOR} (${MONGO_MODE})\nUI: http://${LOCAL_IP}:3000\nCWMP: 7547\nNBI: 7557\nFS: 7567"

exit 0
