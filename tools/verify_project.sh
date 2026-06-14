#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/verify_project.sh [quick|firmware|full]

Modes:
  quick     Check current helper syntax and Relay smoke test.
  firmware  quick + ESP field firmware build.
  full      firmware + iOS unit/UI tests + Debug/Release builds without signing and production URL gate.

This verifier follows the current product direction: room-based live location
and ESP push-to-talk voice. The retired physical DBALL hunt is not verified.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MODE="${1:-quick}"
case "$MODE" in
  quick|firmware|full)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log_step() {
  printf '\n==> %s\n' "$1"
}

log_step "Checking shell helper syntax"
bash -n \
  tools/build_radar.sh \
  tools/deploy_relay_update.sh \
  tools/flash_release_firmware.sh \
  tools/prepare_release_pairing_key.sh \
  tools/verify_project.sh

log_step "Checking Python helper syntax"
python3 -m py_compile \
  tools/smoke_esp_provisioning_ble.py \
  tools/smoke_relay.py \
  tools/smoke_relay_limits.py \
  tools/simulate_mac_room_member.py \
  tools/list_radar_ports.py \
  tools/wait_for_radar_port.py \
  tools/diagnose_usb_serial.py

log_step "Checking Relay limit primitives"
python3 tools/smoke_relay_limits.py

log_step "Checking release pairing key preflight"
tools/prepare_release_pairing_key.sh self-test

log_step "Checking Relay smoke test"
RELAY_SMOKE_PORT="${RELAY_SMOKE_PORT:-18787}"
RELAY_SMOKE_HTTP_PORT="${RELAY_SMOKE_HTTP_PORT:-18788}"
RELAY_SMOKE_DB="$(mktemp "${TMPDIR:-/tmp}/dragon-radar-relay-smoke.XXXXXX.sqlite3")"
DRAGON_RADAR_ALLOW_DEVELOPMENT_AUTH=1 \
DRAGON_RADAR_APPLE_AUDIENCE=com.sn5.DragonRadarMVP \
DRAGON_RADAR_APNS_MODE=dry_run \
DRAGON_RADAR_LOCATION_STALE_SECONDS=1 \
python3 relay/server.py \
  --host 127.0.0.1 \
  --port "$RELAY_SMOKE_PORT" \
  --http-port "$RELAY_SMOKE_HTTP_PORT" \
  --db-path "$RELAY_SMOKE_DB" \
  >/tmp/dragon-radar-relay-smoke.log 2>&1 &
relay_pid=$!
cleanup_relay() {
  kill "$relay_pid" >/dev/null 2>&1 || true
  wait "$relay_pid" >/dev/null 2>&1 || true
  rm -f "$RELAY_SMOKE_DB" "$RELAY_SMOKE_DB-shm" "$RELAY_SMOKE_DB-wal"
}
trap cleanup_relay EXIT
sleep 0.6
python3 tools/smoke_relay.py \
  --url "ws://127.0.0.1:$RELAY_SMOKE_PORT" \
  --http-url "http://127.0.0.1:$RELAY_SMOKE_HTTP_PORT"
cleanup_relay
trap - EXIT

if [[ "$MODE" == "firmware" || "$MODE" == "full" ]]; then
  log_step "Building ESP field firmware"
  tools/build_radar.sh field
fi

if [[ "$MODE" == "full" ]]; then
  log_step "Generating iOS project"
  (cd ios/DragonRadarMVP && xcodegen generate)

  log_step "Checking iOS production network config"
  if grep -q "NSAllowsArbitraryLoads" ios/DragonRadarMVP/DragonRadarMVP/Info.plist; then
    echo "Release Info.plist must not allow arbitrary ATS loads." >&2
    exit 1
  fi
  release_settings="$(
    xcodebuild \
      -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
      -scheme DragonRadarMVP \
      -configuration Release \
      -showBuildSettings 2>/dev/null
  )"
  grep -q "DRAGON_RADAR_HTTP_API_BASE_URL = https://" <<<"$release_settings" || {
    echo "Release HTTP API URL must use https." >&2
    exit 1
  }
  grep -q "DRAGON_RADAR_RELAY_BASE_URL = wss://" <<<"$release_settings" || {
    echo "Release Relay URL must use wss." >&2
    exit 1
  }

  log_step "Building iOS app"
  xcodebuild \
    -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
    -scheme DragonRadarMVP \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    build

  log_step "Running iOS unit/UI tests"
  IOS_TEST_DESTINATION="${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone Air}"
  xcodebuild \
    -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
    -scheme DragonRadarMVP \
    -configuration Debug \
    -destination "$IOS_TEST_DESTINATION" \
    CODE_SIGNING_ALLOWED=NO \
    test

  xcodebuild \
    -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
    -scheme DragonRadarMVP \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

printf '\nverify-project-ok (%s)\n' "$MODE"
