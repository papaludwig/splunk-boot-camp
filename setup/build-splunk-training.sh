#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Splunk Training AMI Builder (Ubuntu 24.04) - root-run version
#
# This script is intended to run on the EC2 instance as root.
# It installs/configures Splunk Enterprise and prepares the host for AMI capture.
###############################################################################

# Required
SPLUNK_TGZ_URL="${SPLUNK_TGZ_URL:-}"

# Optional overrides
CERT_CHAIN_SRC="${CERT_CHAIN_SRC:-/root/ib-fullchain.pem}"
CERT_KEY_SRC="${CERT_KEY_SRC:-/root/ib-privkey.pem}"
CERT_DST_DIR="${CERT_DST_DIR:-/etc/ssl/instantbrains}"
SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK_TGZ_PATH="${SPLUNK_TGZ_PATH:-/tmp/splunk.tgz}"
SPLUNK_WEB_PORT="${SPLUNK_WEB_PORT:-443}"
SPLUNK_SERVER_NAME="${SPLUNK_SERVER_NAME:-instantbrains.com}"
STUDENT_USER="${STUDENT_USER:-student}"
STUDENT_PASSWORD="${STUDENT_PASSWORD:-}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

splunk_is_running() {
  local pid_file="${SPLUNK_HOME}/var/run/splunk/splunkd.pid"
  local pid=""
  [[ -f "$pid_file" ]] || return 1
  read -r pid < "$pid_file" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

set_splunk_conf_value() {
  local file="$1"
  local stanza="$2"
  local key="$3"
  local value="$4"
  local tmp_file

  tmp_file="$(mktemp)"
  if [[ -f "$file" ]]; then
    awk -v stanza="$stanza" -v key="$key" -v value="$value" '
      BEGIN { in_stanza=0; stanza_found=0; key_written=0 }
      {
        if ($0 ~ /^[[:space:]]*\[[^]]+\][[:space:]]*$/) {
          if (in_stanza && !key_written) {
            print key " = " value
            key_written=1
          }

          header=$0
          sub(/^[[:space:]]*\[/, "", header)
          sub(/\][[:space:]]*$/, "", header)
          in_stanza=(header == stanza)
          if (in_stanza) {
            stanza_found=1
          }
          print
          next
        }

        if (in_stanza && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
          if (!key_written) {
            print key " = " value
            key_written=1
          }
          next
        }

        print
      }
      END {
        if (!stanza_found) {
          if (NR > 0) {
            print ""
          }
          print "[" stanza "]"
          print key " = " value
        } else if (in_stanza && !key_written) {
          print key " = " value
        }
      }
    ' "$file" > "$tmp_file"
  else
    {
      echo "[${stanza}]"
      echo "${key} = ${value}"
    } > "$tmp_file"
  fi

  install -d -m 755 "$(dirname "$file")"
  install -m 600 "$tmp_file" "$file"
  rm -f "$tmp_file"
}

usage() {
  cat <<'EOF'
Usage:
  sudo SPLUNK_TGZ_URL="https://download.splunk.com/..." SPLUNK_ADMIN_PASSWORD="<admin-pass>" /root/build-splunk-training.sh

Optional environment variables:
  CERT_CHAIN_SRC, CERT_KEY_SRC, CERT_DST_DIR
  SPLUNK_HOME, SPLUNK_TGZ_PATH
  SPLUNK_WEB_PORT, SPLUNK_SERVER_NAME
  STUDENT_USER, STUDENT_PASSWORD (required if STUDENT_USER is newly created)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $EUID -ne 0 ]]; then
  die "Run as root (or via sudo)."
fi

need_cmd apt-get
need_cmd wget
need_cmd tar
need_cmd sed
need_cmd grep
need_cmd adduser
need_cmd usermod
need_cmd chpasswd
need_cmd install
need_cmd awk
need_cmd sshd

[[ -n "$SPLUNK_TGZ_URL" ]] || die "SPLUNK_TGZ_URL is required."
[[ -n "$SPLUNK_ADMIN_PASSWORD" ]] || die "SPLUNK_ADMIN_PASSWORD is required."
[[ "$SPLUNK_ADMIN_PASSWORD" != *$'\n'* ]] || die "SPLUNK_ADMIN_PASSWORD cannot contain newlines."
[[ "$SPLUNK_ADMIN_PASSWORD" != *$'\r'* ]] || die "SPLUNK_ADMIN_PASSWORD cannot contain carriage returns."
if [[ "$SPLUNK_TGZ_URL" == *"path/to/splunk"* ]]; then
  die "SPLUNK_TGZ_URL still contains placeholder text."
fi

echo "=== [1/10] OS updates (apt-get update/upgrade) ==="
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get update -y
apt-get upgrade -y

echo "=== [2/10] Ensure '${STUDENT_USER}' exists and is sudo-enabled ==="
STUDENT_CREATED=0
if id "$STUDENT_USER" >/dev/null 2>&1; then
  echo "User '${STUDENT_USER}' already exists."
else
  adduser --disabled-password --gecos "" "$STUDENT_USER"
  STUDENT_CREATED=1
fi
usermod -aG sudo "$STUDENT_USER"

if [[ -n "$STUDENT_PASSWORD" ]]; then
  [[ "$STUDENT_PASSWORD" != *$'\n'* ]] || die "STUDENT_PASSWORD cannot contain newlines."
  [[ "$STUDENT_PASSWORD" != *$'\r'* ]] || die "STUDENT_PASSWORD cannot contain carriage returns."
  printf '%s:%s\n' "$STUDENT_USER" "$STUDENT_PASSWORD" | chpasswd
  echo "Student password set via STUDENT_PASSWORD."
elif [[ "$STUDENT_CREATED" -eq 1 ]]; then
  die "STUDENT_PASSWORD is required when creating new user '${STUDENT_USER}'."
else
  echo "No STUDENT_PASSWORD provided; keeping existing password for '${STUDENT_USER}'."
fi

echo "=== [3/10] Enable SSH password + keyboard-interactive auth ==="
SSH_DROPIN="/etc/ssh/sshd_config.d/99-splunk-training.conf"
install -d -m 755 /etc/ssh/sshd_config.d
cat > "$SSH_DROPIN" <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
EOF
sshd -t
echo "SSH config validated (applies on ssh service restart or reboot)."

echo "=== [4/10] Verify TLS cert inputs ==="
[[ -f "$CERT_CHAIN_SRC" ]] || die "Missing cert chain file: $CERT_CHAIN_SRC"
[[ -f "$CERT_KEY_SRC" ]] || die "Missing cert key file: $CERT_KEY_SRC"

echo "=== [5/10] Install TLS certs to ${CERT_DST_DIR} ==="
install -d -m 700 "$CERT_DST_DIR"
install -m 600 "$CERT_CHAIN_SRC" "${CERT_DST_DIR}/ib-fullchain.pem"
install -m 600 "$CERT_KEY_SRC" "${CERT_DST_DIR}/ib-privkey.pem"

echo "=== [6/10] Download Splunk tarball ==="
rm -f "$SPLUNK_TGZ_PATH"
wget "$SPLUNK_TGZ_URL" -O "$SPLUNK_TGZ_PATH"

echo "=== [7/10] Install Splunk under ${SPLUNK_HOME} ==="
if [[ ! -d "$SPLUNK_HOME" ]]; then
  mkdir -p /opt
  tar xvf "$SPLUNK_TGZ_PATH" -C /opt
else
  echo "Directory ${SPLUNK_HOME} already exists; skipping untar."
fi
[[ -x "${SPLUNK_HOME}/bin/splunk" ]] || die "Splunk binary not found at ${SPLUNK_HOME}/bin/splunk"

echo "=== [8/10] Force Splunk to run as root ==="
LAUNCH_CONF="${SPLUNK_HOME}/etc/splunk-launch.conf"
if [[ -f "$LAUNCH_CONF" ]] && grep -q '^SPLUNK_OS_USER=' "$LAUNCH_CONF"; then
  sed -i 's/^SPLUNK_OS_USER=.*/SPLUNK_OS_USER=root/' "$LAUNCH_CONF"
else
  echo "SPLUNK_OS_USER=root" >> "$LAUNCH_CONF"
fi

echo "=== [9/10] Configure Splunk Web TLS + serverName ==="
WEB_CONF="${SPLUNK_HOME}/etc/system/local/web.conf"
SERVER_CONF="${SPLUNK_HOME}/etc/system/local/server.conf"

set_splunk_conf_value "$WEB_CONF" "settings" "enableSplunkWebSSL" "true"
set_splunk_conf_value "$WEB_CONF" "settings" "httpport" "$SPLUNK_WEB_PORT"
set_splunk_conf_value "$WEB_CONF" "settings" "serverCert" "${CERT_DST_DIR}/ib-fullchain.pem"
set_splunk_conf_value "$WEB_CONF" "settings" "privKeyPath" "${CERT_DST_DIR}/ib-privkey.pem"
set_splunk_conf_value "$SERVER_CONF" "general" "serverName" "$SPLUNK_SERVER_NAME"

echo "=== [10/10] Start Splunk and enable boot-start ==="
if splunk_is_running; then
  echo "Splunk is already running."
else
  "${SPLUNK_HOME}/bin/splunk" start --accept-license --answer-yes --no-prompt --seed-passwd "$SPLUNK_ADMIN_PASSWORD"
fi

"${SPLUNK_HOME}/bin/splunk" enable boot-start -user root --accept-license --answer-yes --no-prompt

echo
echo "Build complete."
echo "  Splunk home: ${SPLUNK_HOME}"
echo "  Splunk URL:  https://<instance-ip>/"
echo "  Cert chain:  ${CERT_DST_DIR}/ib-fullchain.pem"
echo "  Cert key:    ${CERT_DST_DIR}/ib-privkey.pem"
echo "  Student user:${STUDENT_USER}"
echo
echo "Next: install class apps/config, then create the AMI snapshot."
