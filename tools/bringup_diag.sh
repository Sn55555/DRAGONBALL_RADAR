#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/bringup_diag.sh [all|build|upload|monitor]

Modes:
  all      Upload the diag firmware, then start the summarized DIAG monitor.
  build    Build the diag firmware only.
  upload   Build and upload the diag firmware only.
  monitor  Start the summarized DIAG monitor only.

Environment:
  PIO_BIN          PlatformIO executable, default: pio
  RADAR_PORT       Optional serial port, such as /dev/cu.usbmodem101
  DIAG_BAUD        Monitor baud rate, default: 115200
  DIAG_TIMEOUT     Optional monitor timeout in seconds
  DIAG_REQUIRE_ONLINE
                   Comma-separated required online components, e.g. touch,imu,ble,audio
  DIAG_MIN_BEACONS Minimum distinct DBALL beacons that must be seen
  DIAG_MIN_COLLECTIONS
                   Minimum DIAG collect events that must be seen
  DIAG_REQUIRE_COLLECTION_SET
                   1 to require collect events for DBALL-1..7
  DIAG_CALIBRATE   1 to print aggregate RSSI and bearing calibration stats on exit
  DIAG_REPORT_JSON Report path, default: output/bringup-diag-report.json
  DIAG_REPORT_MD   Markdown report path, default: output/bringup-diag-report.md
  DIAG_LOG         Raw DIAG log path, default: output/bringup-diag-raw.log
  DIAG_RAW         1 to also show raw serial lines
  BRINGUP_DRY_RUN  1 to print commands without running them
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
find_pio() {
  if [[ -n "${PIO_BIN:-}" ]]; then
    printf '%s\n' "$PIO_BIN"
  elif command -v pio >/dev/null 2>&1; then
    command -v pio
  elif [[ -x "$HOME/.platformio/penv/bin/pio" ]]; then
    printf '%s\n' "$HOME/.platformio/penv/bin/pio"
  elif [[ -x "$HOME/Library/Python/3.11/bin/pio" ]]; then
    printf '%s\n' "$HOME/Library/Python/3.11/bin/pio"
  else
    printf '%s\n' "pio"
  fi
}

PIO_BIN="$(find_pio)"
DIAG_BAUD="${DIAG_BAUD:-115200}"
DIAG_REPORT_JSON="${DIAG_REPORT_JSON:-$ROOT_DIR/output/bringup-diag-report.json}"
DIAG_REPORT_MD="${DIAG_REPORT_MD:-$ROOT_DIR/output/bringup-diag-report.md}"
DIAG_LOG="${DIAG_LOG:-$ROOT_DIR/output/bringup-diag-raw.log}"

run_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "${BRINGUP_DRY_RUN:-0}" != "1" ]]; then
    "$@"
  fi
}

run_radar_build() {
  local action="$1"
  if [[ "$action" == "upload" ]]; then
    run_cmd env PIO_BIN="$PIO_BIN" RADAR_PORT="${RADAR_PORT:-}" "$ROOT_DIR/tools/build_radar.sh" diag upload
  else
    run_cmd env PIO_BIN="$PIO_BIN" "$ROOT_DIR/tools/build_radar.sh" diag
  fi
}

run_diag_monitor() {
  local monitor_cmd=("$ROOT_DIR/tools/monitor_diag.py" --pio-bin "$PIO_BIN" --baud "$DIAG_BAUD")
  if [[ -n "${RADAR_PORT:-}" ]]; then
    monitor_cmd+=(--port "$RADAR_PORT")
  fi
  if [[ -n "${DIAG_TIMEOUT:-}" ]]; then
    monitor_cmd+=(--timeout "$DIAG_TIMEOUT")
  fi
  if [[ -n "${DIAG_REQUIRE_ONLINE:-}" ]]; then
    monitor_cmd+=(--require-online "$DIAG_REQUIRE_ONLINE")
  fi
  if [[ -n "${DIAG_MIN_BEACONS:-}" ]]; then
    monitor_cmd+=(--min-beacons "$DIAG_MIN_BEACONS")
  fi
  if [[ -n "${DIAG_MIN_COLLECTIONS:-}" ]]; then
    monitor_cmd+=(--min-collections "$DIAG_MIN_COLLECTIONS")
  fi
  if [[ "${DIAG_REQUIRE_COLLECTION_SET:-0}" == "1" ]]; then
    monitor_cmd+=(--require-collection-set)
  fi
  if [[ "${DIAG_CALIBRATE:-0}" == "1" ]]; then
    monitor_cmd+=(--calibrate)
  fi
  if [[ -n "${DIAG_REPORT_JSON:-}" ]]; then
    monitor_cmd+=(--report-json "$DIAG_REPORT_JSON")
  fi
  if [[ -n "${DIAG_LOG:-}" ]]; then
    monitor_cmd+=(--log-file "$DIAG_LOG")
  fi
  if [[ "${DIAG_RAW:-0}" == "1" ]]; then
    monitor_cmd+=(--raw)
  fi
  if [[ "${BRINGUP_DRY_RUN:-0}" == "1" ]]; then
    run_cmd "${monitor_cmd[@]}"
    if [[ -n "${DIAG_REPORT_JSON:-}" && -n "${DIAG_REPORT_MD:-}" ]]; then
      run_cmd "$ROOT_DIR/tools/render_bench_report.py" "$DIAG_REPORT_JSON" "$DIAG_REPORT_MD"
    fi
    return 0
  fi

  printf '+'
  printf ' %q' "${monitor_cmd[@]}"
  printf '\n'
  set +e
  "${monitor_cmd[@]}"
  local rc=$?
  set -e

  if [[ -n "${DIAG_REPORT_JSON:-}" && -f "$DIAG_REPORT_JSON" && -n "${DIAG_REPORT_MD:-}" ]]; then
    run_cmd "$ROOT_DIR/tools/render_bench_report.py" "$DIAG_REPORT_JSON" "$DIAG_REPORT_MD"
  fi
  return "$rc"
}

case "$MODE" in
  build)
    run_radar_build build
    ;;
  upload)
    run_radar_build upload
    ;;
  monitor)
    run_diag_monitor
    ;;
  all)
    run_radar_build upload
    run_diag_monitor
    ;;
esac
