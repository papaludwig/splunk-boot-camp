#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SSH_USER="ubuntu"
SSH_KEY="${HOME}/Downloads/cpl.pem"
EC2_HOST=""

DESTINATIONS_APP_DIR="${DESTINATIONS_APP_DIR:-/opt/splunk/etc/apps/destinations}"
DESTINATIONS_SAMPLES_DIR="${DESTINATIONS_SAMPLES_DIR:-${SCRIPT_DIR}/assets/destinations-samples/samples}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

quote() {
  printf '%q' "$1"
}

usage() {
  cat <<'EOF'
Usage:
  install-destinations-samples-aws.sh --host HOST [options]

Required:
  --host HOST              EC2 public IP or DNS name

Optional:
  --ssh-user USER          SSH username (default: ubuntu)
  --ssh-key PATH           SSH private key path (default: ~/Downloads/cpl.pem)
  --app-dir PATH           Remote destinations app dir
                           (default: /opt/splunk/etc/apps/destinations)
  --samples-dir PATH       Local source samples directory
                           (default: setup/assets/destinations-samples/samples)
  -h, --help               Show help

Environment variable equivalents:
  DESTINATIONS_APP_DIR, DESTINATIONS_SAMPLES_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      EC2_HOST="$2"
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
    --app-dir)
      [[ $# -ge 2 ]] || die "--app-dir requires a value"
      DESTINATIONS_APP_DIR="$2"
      shift 2
      ;;
    --samples-dir)
      [[ $# -ge 2 ]] || die "--samples-dir requires a value"
      DESTINATIONS_SAMPLES_DIR="$2"
      shift 2
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
need_cmd tar

[[ -n "$EC2_HOST" ]] || die "--host is required"
[[ -n "$DESTINATIONS_APP_DIR" ]] || die "--app-dir cannot be empty"
[[ -d "$DESTINATIONS_SAMPLES_DIR" ]] || die "Samples directory not found: $DESTINATIONS_SAMPLES_DIR"
[[ -f "${DESTINATIONS_SAMPLES_DIR}/eventgen.conf" ]] || die "Missing ${DESTINATIONS_SAMPLES_DIR}/eventgen.conf"
[[ -f "${DESTINATIONS_SAMPLES_DIR}/destinations-codes.sample" ]] || die "Missing ${DESTINATIONS_SAMPLES_DIR}/destinations-codes.sample"
[[ -f "$SSH_KEY" ]] || die "SSH key not found: $SSH_KEY"

chmod 600 "$SSH_KEY"

SSH_TARGET="${SSH_USER}@${EC2_HOST}"
SSH_OPTS=(
  -i "$SSH_KEY"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
)

tmp_dir="$(mktemp -d)"
remote_stage="/tmp/destinations-samples-${USER}-$$"

cleanup() {
  rm -rf "$tmp_dir"
  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "rm -rf $(quote "$remote_stage")" >/dev/null 2>&1 || true
}
trap cleanup EXIT

archive_path="${tmp_dir}/destinations-samples.tar.gz"
package_root="${tmp_dir}/package"
package_samples_dir="${package_root}/samples"

echo "Packaging ${DESTINATIONS_SAMPLES_DIR}..."
mkdir -p "$package_samples_dir"
find "$DESTINATIONS_SAMPLES_DIR" -maxdepth 1 -type f ! -name '._*' -print0 |
  while IFS= read -r -d '' file; do
    cp "$file" "${package_samples_dir}/"
  done
COPYFILE_DISABLE=1 tar -czf "$archive_path" -C "$package_root" samples

echo "Creating remote staging directory on ${SSH_TARGET}..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "rm -rf $(quote "$remote_stage") && mkdir -m 700 $(quote "$remote_stage")"

echo "Uploading destinations samples archive..."
scp "${SSH_OPTS[@]}" "$archive_path" "$SSH_TARGET:${remote_stage}/destinations-samples.tar.gz"

REMOTE_CMD="sudo bash -s -- $(quote "${remote_stage}/destinations-samples.tar.gz") $(quote "$DESTINATIONS_APP_DIR")"

echo "Installing destinations samples on ${SSH_TARGET}..."
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$REMOTE_CMD" <<'REMOTE_SCRIPT'
set -euo pipefail

archive_path="$1"
app_dir="$2"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ -f "$archive_path" ]] || die "Archive not found: $archive_path"
[[ -d "$app_dir" ]] || die "Destinations app directory not found: $app_dir"
command -v tar >/dev/null 2>&1 || die "Missing tar on remote host."

cd "$app_dir"
tar -xzf "$archive_path"

[[ -f samples/eventgen.conf ]] || die "Archive did not contain samples/eventgen.conf"
install -d -m 755 local
mv -f samples/eventgen.conf local/
rm -f "$archive_path"

echo "Installed destinations samples:"
echo "  Samples:  ${app_dir}/samples"
echo "  Eventgen: ${app_dir}/local/eventgen.conf"
REMOTE_SCRIPT
