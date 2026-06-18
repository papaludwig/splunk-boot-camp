#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EC2_HOST=""
SSH_USER="ubuntu"
SSH_KEY="${HOME}/Downloads/cpl.pem"

LOCAL_CHAIN="${HOME}/ib-fullchain.pem"
LOCAL_KEY="${HOME}/ib-privkey.pem"
BUILD_SCRIPT="${SCRIPT_DIR}/build-splunk-training.sh"

SPLUNK_TGZ_URL="${SPLUNK_TGZ_URL:-https://download.splunk.com/products/splunk/releases/10.0.2/linux/splunk-10.0.2-e2d18b4767e9-linux-amd64.tgz}"
SPLUNK_SERVER_NAME="${SPLUNK_SERVER_NAME:-instantbrains.com}"
SPLUNK_WEB_PORT="${SPLUNK_WEB_PORT:-443}"
STUDENT_USER="${STUDENT_USER:-student}"
STUDENT_PASSWORD="${STUDENT_PASSWORD:-splunk}"
SPLUNK_ADMIN_PASSWORD="${SPLUNK_ADMIN_PASSWORD:-SplunkB00tcamp}"
BUILD_START_STEP="${BUILD_START_STEP:-1}"

NO_RUN=0

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

strip_wrapping_quotes() {
  local value="$1"

  while [[ "$value" == \"*\" || "$value" == \'*\' ]]; do
    value="${value:1:${#value}-2}"
  done

  printf '%s' "$value"
}

prompt_for_secret() {
  local label="$1"
  local value1=""
  local value2=""

  [[ -t 0 ]] || die "${label} is required, but no interactive terminal is available."
  while true; do
    printf '\n' >&2
    read -r -s -p "Enter ${label}: " value1
    printf '\n' >&2
    read -r -s -p "Confirm ${label}: " value2
    printf '\n' >&2

    if [[ -z "$value1" ]]; then
      printf '%s\n' "${label} cannot be empty." >&2
      continue
    fi
    if [[ "$value1" != "$value2" ]]; then
      printf '%s\n' "${label} entries do not match. Try again." >&2
      continue
    fi

    printf '%s' "$value1"
    return 0
  done
}

quote() {
  printf '%q' "$1"
}

usage() {
  cat <<'EOF'
Usage:
  copy-build-aws.sh --host HOST --splunk-url URL [options]

Required:
  --host HOST              EC2 public IP or DNS name
  --splunk-url URL         Direct Splunk Enterprise .tgz URL

Optional:
  --ssh-user USER          SSH username (default: ubuntu)
  --ssh-key PATH           SSH private key path (default: ~/Downloads/cpl.pem)
  --cert-chain PATH        Local fullchain PEM (default: ~/ib-fullchain.pem)
  --cert-key PATH          Local private key PEM (default: ~/ib-privkey.pem)
  --build-script PATH      Local build script (default: setup/build-splunk-training.sh)
  --server-name NAME       Splunk serverName (default: instantbrains.com)
  --web-port PORT          Splunk web port (default: 443)
  --student-user USER      Student account name (default: student)
  --student-password PASS  Student password; if omitted, prompted locally
  --admin-password PASS    Splunk admin password; if omitted, prompted locally
  --start-step STEP        Remote build step to start from, 1-10 (default: 1)
  --no-run                 Copy files but do not execute remote build script
  -h, --help               Show help

Environment variable equivalents:
  SPLUNK_TGZ_URL, SPLUNK_SERVER_NAME, SPLUNK_WEB_PORT,
  STUDENT_USER, STUDENT_PASSWORD, SPLUNK_ADMIN_PASSWORD,
  BUILD_START_STEP
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      EC2_HOST="$2"
      shift 2
      ;;
    --splunk-url)
      [[ $# -ge 2 ]] || die "--splunk-url requires a value"
      SPLUNK_TGZ_URL="$2"
      shift 2
      ;;
    --ssh-user)
      [[ $# -ge 2 ]] || die "--ssh-user requires a value"
      SSH_USER="$2"
      shift 2
      ;;
    --ssh-key)
      [[ $# -ge 2 ]] || die "--ssh-key requires a value"
      SSH_KEY="$2"
      shift 2
      ;;
    --cert-chain)
      [[ $# -ge 2 ]] || die "--cert-chain requires a value"
      LOCAL_CHAIN="$2"
      shift 2
      ;;
    --cert-key)
      [[ $# -ge 2 ]] || die "--cert-key requires a value"
      LOCAL_KEY="$2"
      shift 2
      ;;
    --build-script)
      [[ $# -ge 2 ]] || die "--build-script requires a value"
      BUILD_SCRIPT="$2"
      shift 2
      ;;
    --server-name)
      [[ $# -ge 2 ]] || die "--server-name requires a value"
      SPLUNK_SERVER_NAME="$2"
      shift 2
      ;;
    --web-port)
      [[ $# -ge 2 ]] || die "--web-port requires a value"
      SPLUNK_WEB_PORT="$2"
      shift 2
      ;;
    --student-user)
      [[ $# -ge 2 ]] || die "--student-user requires a value"
      STUDENT_USER="$2"
      shift 2
      ;;
    --student-password)
      [[ $# -ge 2 ]] || die "--student-password requires a value"
      STUDENT_PASSWORD="$2"
      shift 2
      ;;
    --admin-password)
      [[ $# -ge 2 ]] || die "--admin-password requires a value"
      SPLUNK_ADMIN_PASSWORD="$2"
      shift 2
      ;;
    --start-step)
      [[ $# -ge 2 ]] || die "--start-step requires a value"
      BUILD_START_STEP="$2"
      shift 2
      ;;
    --no-run)
      NO_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

need_cmd ssh
need_cmd scp
need_cmd sudo

[[ -n "$EC2_HOST" ]] || die "--host is required"
[[ -n "$SPLUNK_TGZ_URL" ]] || die "--splunk-url is required (or set SPLUNK_TGZ_URL)"
SPLUNK_TGZ_URL="$(strip_wrapping_quotes "$SPLUNK_TGZ_URL")"
[[ "$SPLUNK_TGZ_URL" =~ ^https?:// ]] || die "--splunk-url must start with http:// or https://"
[[ "$BUILD_START_STEP" =~ ^[0-9]+$ ]] || die "--start-step must be an integer from 1 through 10"
(( BUILD_START_STEP >= 1 && BUILD_START_STEP <= 10 )) || die "--start-step must be an integer from 1 through 10"
[[ -f "$SSH_KEY" ]] || die "SSH key not found: $SSH_KEY"
[[ -f "$LOCAL_CHAIN" ]] || die "Cert chain file not found: $LOCAL_CHAIN"
[[ -f "$LOCAL_KEY" ]] || die "Cert key file not found: $LOCAL_KEY"
[[ -f "$BUILD_SCRIPT" ]] || die "Build script not found: $BUILD_SCRIPT"

chmod 600 "$SSH_KEY"

SSH_TARGET="${SSH_USER}@${EC2_HOST}"
SSH_OPTS=(
  -i "$SSH_KEY"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
)

run_remote() {
  local cmd="$1"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "bash -lc $(quote "$cmd")"
}

run_remote_tty() {
  local cmd="$1"
  ssh -tt "${SSH_OPTS[@]}" "$SSH_TARGET" "bash -lc $(quote "$cmd")"
}

REMOTE_STAGE="/tmp/splunk-build-${USER}-$$"

echo "Creating remote staging directory on ${SSH_TARGET}..."
run_remote "set -euo pipefail; rm -rf '$REMOTE_STAGE'; mkdir -m 700 '$REMOTE_STAGE'"

echo "Uploading certs and build script..."
scp "${SSH_OPTS[@]}" "$LOCAL_CHAIN" "$SSH_TARGET:$REMOTE_STAGE/ib-fullchain.pem"
scp "${SSH_OPTS[@]}" "$LOCAL_KEY" "$SSH_TARGET:$REMOTE_STAGE/ib-privkey.pem"
scp "${SSH_OPTS[@]}" "$BUILD_SCRIPT" "$SSH_TARGET:$REMOTE_STAGE/build-splunk-training.sh"

echo "Installing files in /root with secure permissions..."
run_remote "set -euo pipefail; sudo install -d -m 700 /root; sudo install -m 600 '$REMOTE_STAGE/ib-fullchain.pem' /root/ib-fullchain.pem; sudo install -m 600 '$REMOTE_STAGE/ib-privkey.pem' /root/ib-privkey.pem; sudo install -m 700 '$REMOTE_STAGE/build-splunk-training.sh' /root/build-splunk-training.sh; rm -rf '$REMOTE_STAGE'"

if [[ "$NO_RUN" -eq 1 ]]; then
  echo "Copy-only mode complete. To run later:"
  echo "  ssh -i $(quote "$SSH_KEY") ${SSH_TARGET}"
  echo "  sudo SPLUNK_TGZ_URL=$(quote "$SPLUNK_TGZ_URL") BUILD_START_STEP=$(quote "$BUILD_START_STEP") SPLUNK_ADMIN_PASSWORD='<admin-pass>' STUDENT_PASSWORD='<student-pass>' /root/build-splunk-training.sh"
  exit 0
fi

if [[ -z "$STUDENT_PASSWORD" ]]; then
  STUDENT_PASSWORD="$(prompt_for_secret "Student password")"
fi

if [[ -z "$SPLUNK_ADMIN_PASSWORD" ]]; then
  SPLUNK_ADMIN_PASSWORD="$(prompt_for_secret "Splunk admin password")"
fi

REMOTE_BUILD_CMD="set -euo pipefail; sudo SPLUNK_TGZ_URL=$(quote "$SPLUNK_TGZ_URL") SPLUNK_SERVER_NAME=$(quote "$SPLUNK_SERVER_NAME") SPLUNK_WEB_PORT=$(quote "$SPLUNK_WEB_PORT") STUDENT_USER=$(quote "$STUDENT_USER")"
REMOTE_BUILD_CMD="${REMOTE_BUILD_CMD} BUILD_START_STEP=$(quote "$BUILD_START_STEP")"
REMOTE_BUILD_CMD="${REMOTE_BUILD_CMD} STUDENT_PASSWORD=$(quote "$STUDENT_PASSWORD")"
REMOTE_BUILD_CMD="${REMOTE_BUILD_CMD} SPLUNK_ADMIN_PASSWORD=$(quote "$SPLUNK_ADMIN_PASSWORD")"
REMOTE_BUILD_CMD="${REMOTE_BUILD_CMD} /root/build-splunk-training.sh"

echo "Running remote build script..."
run_remote_tty "$REMOTE_BUILD_CMD"
