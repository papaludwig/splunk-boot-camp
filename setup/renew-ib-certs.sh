#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="${CERT_NAME:-instantbrains.com}"
AWS_PROFILE="${AWS_PROFILE:-default}"
CERTBOT_BIN="${CERTBOT_BIN:-$HOME/.certbot-env/bin/certbot}"
OUTPUT_DIR="${OUTPUT_DIR:-$HOME}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  renew-ib-certs.sh [options]

Options:
  --cert-name NAME        Certbot cert name (default: instantbrains.com)
  --aws-profile PROFILE   AWS profile for DNS challenge (default: default)
  --certbot-bin PATH      Path to certbot binary (default: ~/.certbot-env/bin/certbot)
  --output-dir PATH       Where to copy ib-fullchain.pem / ib-privkey.pem (default: ~)
  -h, --help              Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert-name)
      [[ $# -ge 2 ]] || die "--cert-name requires a value"
      CERT_NAME="$2"
      shift 2
      ;;
    --aws-profile)
      [[ $# -ge 2 ]] || die "--aws-profile requires a value"
      AWS_PROFILE="$2"
      shift 2
      ;;
    --certbot-bin)
      [[ $# -ge 2 ]] || die "--certbot-bin requires a value"
      CERTBOT_BIN="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      OUTPUT_DIR="$2"
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

[[ -x "$CERTBOT_BIN" ]] || die "Certbot binary not found or not executable: $CERTBOT_BIN"
[[ -d "$OUTPUT_DIR" ]] || die "Output directory not found: $OUTPUT_DIR"

LIVE_DIR="/etc/letsencrypt/live/${CERT_NAME}"
OUT_CHAIN="${OUTPUT_DIR}/ib-fullchain.pem"
OUT_KEY="${OUTPUT_DIR}/ib-privkey.pem"

echo "Renewing cert '${CERT_NAME}' with AWS profile '${AWS_PROFILE}'..."
sudo env AWS_PROFILE="$AWS_PROFILE" "$CERTBOT_BIN" renew --cert-name "$CERT_NAME"

sudo test -f "${LIVE_DIR}/fullchain.pem" || die "Missing ${LIVE_DIR}/fullchain.pem after renew"
sudo test -f "${LIVE_DIR}/privkey.pem" || die "Missing ${LIVE_DIR}/privkey.pem after renew"

sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "${LIVE_DIR}/fullchain.pem" "$OUT_CHAIN"
sudo install -m 600 -o "$(id -un)" -g "$(id -gn)" "${LIVE_DIR}/privkey.pem" "$OUT_KEY"

echo "Copied:"
echo "  ${OUT_CHAIN}"
echo "  ${OUT_KEY}"
