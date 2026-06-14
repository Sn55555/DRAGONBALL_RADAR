#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PAIRING_HMAC_KEY="dragon-radar-dev-pairing-key"
MIN_KEY_LENGTH=32
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
Usage: tools/prepare_release_pairing_key.sh [check|write-env DIR|self-test]

Checks that the release pairing HMAC key is present, non-default, and identical
for Relay and firmware builds.

Accepted environment variables:
  DRAGON_RADAR_PAIRING_HMAC_KEY  Relay server key.
  PAIRING_HMAC_KEY               Firmware build key.

If only one variable is set, it is treated as the shared release key.

Commands:
  check          Validate the current environment and print a redacted fingerprint.
  write-env DIR  Validate and write DIR/relay.env, DIR/firmware.env, and a redacted manifest.
  self-test      Run positive and negative checks without writing secrets.
USAGE
}

sha256_hex() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    printf '%s' "$1" | openssl dgst -sha256 -r | awk '{print $1}'
  else
    echo "ERROR: shasum or openssl is required for key fingerprinting" >&2
    exit 2
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

pairing_key_from_env() {
  local relay_key="${DRAGON_RADAR_PAIRING_HMAC_KEY:-}"
  local firmware_key="${PAIRING_HMAC_KEY:-}"

  if [[ -n "$relay_key" && -n "$firmware_key" && "$relay_key" != "$firmware_key" ]]; then
    echo "ERROR: DRAGON_RADAR_PAIRING_HMAC_KEY and PAIRING_HMAC_KEY differ" >&2
    exit 2
  fi

  if [[ -n "$relay_key" ]]; then
    printf '%s' "$relay_key"
  else
    printf '%s' "$firmware_key"
  fi
}

check_key() {
  local key
  key="$(pairing_key_from_env)"
  if [[ -z "$key" ]]; then
    echo "ERROR: set DRAGON_RADAR_PAIRING_HMAC_KEY or PAIRING_HMAC_KEY" >&2
    exit 2
  fi
  if [[ "$key" == "$DEFAULT_PAIRING_HMAC_KEY" ]]; then
    echo "ERROR: release pairing key must not use the default development key" >&2
    exit 2
  fi
  if [[ "${#key}" -lt "$MIN_KEY_LENGTH" ]]; then
    echo "ERROR: release pairing key must be at least $MIN_KEY_LENGTH characters" >&2
    exit 2
  fi
  printf '%s' "$key"
}

fingerprint_for_key() {
  local key="$1"
  local digest
  digest="$(sha256_hex "$key")"
  printf 'sha256:%s' "${digest:0:16}"
}

write_env_files() {
  local dir="$1"
  local key="$2"
  local fingerprint="$3"
  local created_at
  created_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  mkdir -p "$dir"
  chmod 700 "$dir"
  umask 077
  printf 'DRAGON_RADAR_PAIRING_HMAC_KEY=%q\n' "$key" > "$dir/relay.env"
  printf 'PAIRING_HMAC_KEY=%q\n' "$key" > "$dir/firmware.env"
  cat > "$dir/pairing-key-manifest.json" <<JSON
{
  "created_at": $(json_escape "$created_at"),
  "fingerprint": $(json_escape "$fingerprint"),
  "relay_env": "relay.env",
  "firmware_env": "firmware.env",
  "min_key_length": $MIN_KEY_LENGTH,
  "contains_secret": false
}
JSON
  echo "PAIRING_KEY_ENV_WRITTEN $dir fingerprint=$fingerprint"
}

self_test() {
  local good_key="release-smoke-pairing-key-0123456789abcdef"
  (
    export DRAGON_RADAR_PAIRING_HMAC_KEY="$good_key"
    export PAIRING_HMAC_KEY="$good_key"
    "$ROOT_DIR/tools/prepare_release_pairing_key.sh" check >/dev/null
  )
  if (
    export DRAGON_RADAR_PAIRING_HMAC_KEY="$DEFAULT_PAIRING_HMAC_KEY"
    "$ROOT_DIR/tools/prepare_release_pairing_key.sh" check >/dev/null 2>&1
  ); then
    echo "ERROR: self-test expected default key rejection" >&2
    exit 1
  fi
  if (
    export DRAGON_RADAR_PAIRING_HMAC_KEY="$good_key"
    export PAIRING_HMAC_KEY="${good_key}-different"
    "$ROOT_DIR/tools/prepare_release_pairing_key.sh" check >/dev/null 2>&1
  ); then
    echo "ERROR: self-test expected mismatch rejection" >&2
    exit 1
  fi
  echo "release-pairing-key-self-test-ok"
}

command="${1:-check}"
case "$command" in
  -h|--help)
    usage
    ;;
  check)
    key="$(check_key)"
    fingerprint="$(fingerprint_for_key "$key")"
    echo "PAIRING_KEY_OK fingerprint=$fingerprint"
    ;;
  write-env)
    if [[ $# -ne 2 ]]; then
      usage >&2
      exit 2
    fi
    key="$(check_key)"
    fingerprint="$(fingerprint_for_key "$key")"
    write_env_files "$2" "$key" "$fingerprint"
    ;;
  self-test)
    self_test
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
