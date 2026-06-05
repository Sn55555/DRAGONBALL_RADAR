#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/verify_beacon_set.sh [all|build|upload|monitor]

Verifies a physical seven-beacon DBALL set through the radar's diagnostic
firmware. Defaults require touch/IMU/BLE/audio online and all seven beacon
indexes visible, then writes JSON, Markdown, and raw-log artifacts.

Modes:
  all      Upload the diag radar firmware, then verify the beacon set.
  build    Build the diag radar firmware only.
  upload   Build and upload the diag radar firmware only.
  monitor  Verify an already-flashed diag radar.

Environment:
  PIO_BIN                       PlatformIO executable, passed through when set
  RADAR_PORT                    Optional radar serial port, e.g. /dev/cu.usbmodem101
  BEACON_VERIFY_TIMEOUT         Monitor timeout in seconds, default: 60
  BEACON_VERIFY_REQUIRE_ONLINE  Required components, default: touch,imu,ble,audio
  BEACON_VERIFY_MIN_BEACONS     Minimum visible DBALL beacons, default: 7
  BEACON_VERIFY_MIN_COLLECTIONS Minimum DIAG collect events, default: unset
  BEACON_VERIFY_REQUIRE_COLLECTION_SET
                                1 to require collect events for DBALL-1..7, default: 0
  BEACON_VERIFY_CALIBRATE       1 to print RSSI/bearing calibration, default: 1
  BEACON_VERIFY_REPORT_JSON     Report path, default: output/beacon-set-verify-report.json
  BEACON_VERIFY_REPORT_MD       Markdown path, default: output/beacon-set-verify-report.md
  BEACON_VERIFY_LOG             Raw DIAG log path, default: output/beacon-set-verify-raw.log
  BEACON_VERIFY_RAW             1 to also echo raw serial lines
  BEACON_VERIFY_DRY_RUN         1 to print commands without running them
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MODE="${1:-all}"
case "$MODE" in
  all|build|upload|monitor)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
timeout="${BEACON_VERIFY_TIMEOUT:-60}"
require_online="${BEACON_VERIFY_REQUIRE_ONLINE:-touch,imu,ble,audio}"
min_beacons="${BEACON_VERIFY_MIN_BEACONS:-7}"
calibrate="${BEACON_VERIFY_CALIBRATE:-1}"
report_json="${BEACON_VERIFY_REPORT_JSON:-$ROOT_DIR/output/beacon-set-verify-report.json}"
report_md="${BEACON_VERIFY_REPORT_MD:-$ROOT_DIR/output/beacon-set-verify-report.md}"
raw_log="${BEACON_VERIFY_LOG:-$ROOT_DIR/output/beacon-set-verify-raw.log}"
dry_run="${BEACON_VERIFY_DRY_RUN:-0}"

if ! [[ "$timeout" =~ ^[0-9]+$ && "$min_beacons" =~ ^[0-9]+$ ]]; then
  echo "BEACON_VERIFY_TIMEOUT and BEACON_VERIFY_MIN_BEACONS must be non-negative integers" >&2
  exit 2
fi
if (( min_beacons < 0 || min_beacons > 7 )); then
  echo "BEACON_VERIFY_MIN_BEACONS must be in 0..7" >&2
  exit 2
fi

cmd=(
  env
  "DIAG_TIMEOUT=$timeout"
  "DIAG_REQUIRE_ONLINE=$require_online"
  "DIAG_MIN_BEACONS=$min_beacons"
  "DIAG_MIN_COLLECTIONS=${BEACON_VERIFY_MIN_COLLECTIONS:-}"
  "DIAG_REQUIRE_COLLECTION_SET=${BEACON_VERIFY_REQUIRE_COLLECTION_SET:-0}"
  "DIAG_CALIBRATE=$calibrate"
  "DIAG_REPORT_JSON=$report_json"
  "DIAG_REPORT_MD=$report_md"
  "DIAG_LOG=$raw_log"
  "DIAG_RAW=${BEACON_VERIFY_RAW:-0}"
  "BRINGUP_DRY_RUN=$dry_run"
)

if [[ -n "${PIO_BIN:-}" ]]; then
  cmd+=("PIO_BIN=$PIO_BIN")
fi
if [[ -n "${RADAR_PORT:-}" ]]; then
  cmd+=("RADAR_PORT=$RADAR_PORT")
fi

cmd+=("$ROOT_DIR/tools/bringup_diag.sh" "$MODE")

printf '+'
printf ' %q' "${cmd[@]}"
printf '\n'
"${cmd[@]}"
