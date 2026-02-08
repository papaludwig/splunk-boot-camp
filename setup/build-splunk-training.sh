#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Splunk Training AMI Builder (Ubuntu 24.04) — ROOT USER VERSION
#
# - Runs Splunk as root (SPLUNK_OS_USER=root)
# - Configures Splunk Web on HTTPS port 443 using provided PEM files
# - Creates a sudo-enabled "student" user and enables password SSH auth
# - Accepts Splunk license, starts Splunk (interactive admin password),
#   enables boot-start for AMI usage
#
# Expected inputs (uploaded to /root before running):
#   /root/ib-fullchain.pem
#   /root/ib-privkey.pem
#   /root/build-splunk-training.sh  (this script)
###############################################################################

#############################################
# CONFIG: EDIT THESE PER BUILD IF NEEDED
#############################################

# Splunk tarball URL (wget link from splunk.com)
SPLUNK_TGZ_URL="https://download.splunk.com/path/to/splunk-X.Y.Z-Linux-x86_64.tgz"

# Where the input certs are expected to be (uploaded by you)
CERT_CHAIN_SRC="/root/ib-fullchain.pem"
CERT_KEY_SRC="/root/ib-privkey.pem"

# Where to install certs on the server
CERT_DST_DIR="/etc/ssl/instantbrains"

# Splunk install home
SPLUNK_HOME="/opt/splunk"

# Splunk Web port + serverName
SPLUNK_WEB_PORT="443"
SPLUNK_SERVER_NAME="instantbrains.com"

# Student account name
STUDENT_USER="student"

#############################################
# END CONFIG
#############################################

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

if [[ $EUID -ne 0 ]]; then
  die "Run as root (e.g., sudo su - ; then ./build-splunk-training.sh)"
fi

need_cmd apt-get
need_cmd wget
need_cmd tar
need_cmd sed
need_cmd grep
need_cmd passwd
need_cmd adduser
need_cmd usermod

echo "=== [1/10] OS updates (apt-get update/upgrade) ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y

echo "=== [2/10] Create '${STUDENT_USER}' user and add to sudo ==="
if id "$STUDENT_USER" &>/dev/null; then
  echo "User '$STUDENT_USER' already exists, skipping creation."
else
  adduser --gecos "" "$STUDENT_USER"
  usermod -aG sudo "$STUDENT_USER"
fi

echo
echo "You will now be prompted to set/confirm the password for '$STUDENT_USER'."
echo "If you don't want password login for student, you can cancel here, but SSH"
echo "password auth will be enabled later for training convenience."
passwd "$STUDENT_USER" || true
echo

echo "=== [3/10] Enable SSH password + keyboard-interactive auth (no restart needed for AMI) ==="
SSHD_CONFIG="/etc/ssh/sshd_config"

# PasswordAuthentication yes
if grep -Eq '^\s*PasswordAuthentication' "$SSHD_CONFIG"; then
  sed -i 's/^\s*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CONFIG"
else
  echo "PasswordAuthentication yes" >> "$SSHD_CONFIG"
fi

# KbdInteractiveAuthentication yes
if grep -Eq '^\s*KbdInteractiveAuthentication' "$SSHD_CONFIG"; then
  sed -i 's/^\s*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication yes/' "$SSHD_CONFIG"
else
  echo "KbdInteractiveAuthentication yes" >> "$SSHD_CONFIG"
fi

echo "sshd_config updated. No restart required during AMI build; will apply on boot."
echo

echo "=== [4/10] Verify cert inputs exist in /root ==="
[[ -f "$CERT_CHAIN_SRC" ]] || die "Missing $CERT_CHAIN_SRC (upload ib-fullchain.pem to /root)"
[[ -f "$CERT_KEY_SRC"   ]] || die "Missing $CERT_KEY_SRC (upload ib-privkey.pem to /root)"

echo "=== [5/10] Install certs to $CERT_DST_DIR ==="
mkdir -p "$CERT_DST_DIR"
cp "$CERT_CHAIN_SRC" "$CERT_DST_DIR/ib-fullchain.pem"
cp "$CERT_KEY_SRC"   "$CERT_DST_DIR/ib-privkey.pem"
chmod 600 "$CERT_DST_DIR/ib-fullchain.pem" "$CERT_DST_DIR/ib-privkey.pem"
chown root:root "$CERT_DST_DIR/ib-fullchain.pem" "$CERT_DST_DIR/ib-privkey.pem"

echo "=== [6/10] Download Splunk tarball (if needed) ==="
mkdir -p /opt
cd /tmp
if [[ ! -f splunk.tgz ]]; then
  echo "Downloading Splunk from: $SPLUNK_TGZ_URL"
  wget "$SPLUNK_TGZ_URL" -O splunk.tgz
else
  echo "Found existing /tmp/splunk.tgz, reusing it."
fi

echo "=== [7/10] Install Splunk under $SPLUNK_HOME (untar if needed) ==="
if [[ ! -d "$SPLUNK_HOME" ]]; then
  tar xvf /tmp/splunk.tgz -C /opt
else
  echo "Splunk directory $SPLUNK_HOME already exists; skipping untar."
fi
[[ -x "$SPLUNK_HOME/bin/splunk" ]] || die "Splunk binary not found at $SPLUNK_HOME/bin/splunk"

echo "=== [8/10] Force Splunk to run as root ==="
LAUNCH_CONF="$SPLUNK_HOME/etc/splunk-launch.conf"
if grep -q '^SPLUNK_OS_USER=' "$LAUNCH_CONF" 2>/dev/null; then
  sed -i 's/^SPLUNK_OS_USER=.*/SPLUNK_OS_USER=root/' "$LAUNCH_CONF"
else
  echo "SPLUNK_OS_USER=root" >> "$LAUNCH_CONF"
fi

echo "=== [9/10] Configure Splunk Web (HTTPS on port $SPLUNK_WEB_PORT) + serverName ==="
mkdir -p "$SPLUNK_HOME/etc/system/local"

cat > "$SPLUNK_HOME/etc/system/local/web.conf" <<EOF
[settings]
enableSplunkWebSSL = true
httpport = $SPLUNK_WEB_PORT
serverCert = $CERT_DST_DIR/ib-fullchain.pem
privKeyPath = $CERT_DST_DIR/ib-privkey.pem
EOF

# Keep server.conf simple; append is fine for these throwaway training AMIs
cat >> "$SPLUNK_HOME/etc/system/local/server.conf" <<EOF

[general]
serverName = $SPLUNK_SERVER_NAME
EOF

echo "=== [10/10] Accept license (no start), start Splunk (interactive), enable boot-start ==="
# Accept license without starting Splunk
"$SPLUNK_HOME/bin/splunk" status --accept-license || true

echo
echo ">>> Splunk will now start for the first time."
echo ">>> You will be prompted to set the Splunk admin password."
echo
"$SPLUNK_HOME/bin/splunk" start

# Enable boot-start so AMI instances auto-start Splunk on boot
"$SPLUNK_HOME/bin/splunk" enable boot-start --accept-license

echo
echo "========================================================="
echo "✅ Splunk training AMI setup complete."
echo
echo "Splunk:"
echo "  - Home:      $SPLUNK_HOME"
echo "  - OS user:   root"
echo "  - Web URL:   https://<server-ip>/  (port $SPLUNK_WEB_PORT)"
echo
echo "TLS files:"
echo "  - Chain:     $CERT_DST_DIR/ib-fullchain.pem"
echo "  - Key:       $CERT_DST_DIR/ib-privkey.pem"
echo
echo "Accounts:"
echo "  - Student user: $STUDENT_USER (sudo enabled)"
echo
echo "Verify:"
echo "  ss -tulpn | grep $SPLUNK_WEB_PORT"
echo
echo "Next: Install any Splunk apps/configs for class, then snapshot the AMI."
echo "========================================================="
