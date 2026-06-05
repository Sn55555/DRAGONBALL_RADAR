#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/record_field_hunt.sh [all|build|upload|monitor]

Runs the clean field UI with hidden serial diagnostics so a real play session
can be recorded without showing debug HUD text on the radar screen.

Modes:
  all      Upload the clean fielddiag firmware, then record a hunt session.
  build    Build the fielddiag firmware only.
  upload   Build and upload the fielddiag firmware only.
  monitor  Record an already-flashed fielddiag firmware.

Environment:
  PIO_BIN                    PlatformIO executable, auto-detected when omitted
  RADAR_PORT                 Optional serial port, such as /dev/cu.usbmodem101
  HUNT_BAUD                  Monitor baud rate, default: 115200
  HUNT_TIMEOUT               Optional monitor timeout in seconds
  HUNT_REQUIRE_ONLINE        Required online components, default: touch,imu,ble,audio
  HUNT_MIN_BEACONS           Minimum visible DBALL beacons, default: 0
  HUNT_MIN_COLLECTED         Minimum collected count reported by DIAG tick, default: 0
  HUNT_MIN_COLLECTIONS       Minimum DIAG collect events, default: 0
  HUNT_REQUIRE_COLLECTION_SET
                             1 to require collect events for DBALL-1..7, default: 0
  HUNT_REQUIRE_SUMMON        1 to require summon=yes, default: 0
  HUNT_CALIBRATE             1 to print RSSI/bearing calibration, default: 1
  HUNT_REPORT_JSON           Report path, default: output/field-hunt-report.json
  HUNT_REPORT_MD             Markdown path, default: output/field-hunt-report.md
  HUNT_BENCH_REPORT_MD       Optional technical report path, default: output/field-hunt-bench-report.md
  HUNT_LOG                   Raw DIAG log path, default: output/field-hunt-raw.log
  HUNT_RAW                   1 to also echo raw serial lines
  HUNT_DRY_RUN               1 to print commands without running them
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
HUNT_BAUD="${HUNT_BAUD:-115200}"
HUNT_REQUIRE_ONLINE="${HUNT_REQUIRE_ONLINE:-touch,imu,ble,audio}"
HUNT_MIN_BEACONS="${HUNT_MIN_BEACONS:-0}"
HUNT_MIN_COLLECTED="${HUNT_MIN_COLLECTED:-0}"
HUNT_MIN_COLLECTIONS="${HUNT_MIN_COLLECTIONS:-0}"
HUNT_REQUIRE_COLLECTION_SET="${HUNT_REQUIRE_COLLECTION_SET:-0}"
HUNT_REQUIRE_SUMMON="${HUNT_REQUIRE_SUMMON:-0}"
HUNT_CALIBRATE="${HUNT_CALIBRATE:-1}"
HUNT_REPORT_JSON="${HUNT_REPORT_JSON:-$ROOT_DIR/output/field-hunt-report.json}"
HUNT_REPORT_MD="${HUNT_REPORT_MD:-$ROOT_DIR/output/field-hunt-report.md}"
HUNT_BENCH_REPORT_MD="${HUNT_BENCH_REPORT_MD:-$ROOT_DIR/output/field-hunt-bench-report.md}"
HUNT_LOG="${HUNT_LOG:-$ROOT_DIR/output/field-hunt-raw.log}"

run_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "${HUNT_DRY_RUN:-0}" != "1" ]]; then
    "$@"
  fi
}

run_fielddiag_build() {
  local action="$1"
  if [[ "$action" == "upload" ]]; then
    run_cmd env PIO_BIN="$PIO_BIN" RADAR_PORT="${RADAR_PORT:-}" "$ROOT_DIR/tools/build_radar.sh" fielddiag upload
  else
    run_cmd env PIO_BIN="$PIO_BIN" "$ROOT_DIR/tools/build_radar.sh" fielddiag
  fi
}

run_hunt_monitor() {
  local monitor_cmd=(
    "$ROOT_DIR/tools/monitor_diag.py"
    --pio-bin "$PIO_BIN"
    --baud "$HUNT_BAUD"
  )
  if [[ -n "${RADAR_PORT:-}" ]]; then
    monitor_cmd+=(--port "$RADAR_PORT")
  fi
  if [[ -n "${HUNT_TIMEOUT:-}" ]]; then
    monitor_cmd+=(--timeout "$HUNT_TIMEOUT")
  fi
  if [[ -n "${HUNT_REQUIRE_ONLINE:-}" ]]; then
    monitor_cmd+=(--require-online "$HUNT_REQUIRE_ONLINE")
  fi
  if [[ -n "${HUNT_MIN_BEACONS:-}" ]]; then
    monitor_cmd+=(--min-beacons "$HUNT_MIN_BEACONS")
  fi
  if [[ -n "${HUNT_MIN_COLLECTED:-}" ]]; then
    monitor_cmd+=(--min-collected "$HUNT_MIN_COLLECTED")
  fi
  if [[ -n "${HUNT_MIN_COLLECTIONS:-}" ]]; then
    monitor_cmd+=(--min-collections "$HUNT_MIN_COLLECTIONS")
  fi
  if [[ "$HUNT_REQUIRE_COLLECTION_SET" == "1" ]]; then
    monitor_cmd+=(--require-collection-set)
  fi
  if [[ "$HUNT_REQUIRE_SUMMON" == "1" ]]; then
    monitor_cmd+=(--require-summon)
  fi
  if [[ "$HUNT_CALIBRATE" == "1" ]]; then
    monitor_cmd+=(--calibrate)
  fi
  if [[ -n "${HUNT_REPORT_JSON:-}" ]]; then
    monitor_cmd+=(--report-json "$HUNT_REPORT_JSON")
  fi
  if [[ -n "${HUNT_LOG:-}" ]]; then
    monitor_cmd+=(--log-file "$HUNT_LOG")
  fi
  if [[ "${HUNT_RAW:-0}" == "1" ]]; then
    monitor_cmd+=(--raw)
  fi

  if [[ "${HUNT_DRY_RUN:-0}" == "1" ]]; then
    run_cmd "${monitor_cmd[@]}"
    if [[ -n "${HUNT_REPORT_JSON:-}" && -n "${HUNT_REPORT_MD:-}" ]]; then
      run_cmd "$ROOT_DIR/tools/render_hunt_report.py" "$HUNT_REPORT_JSON" "$HUNT_REPORT_MD"
    fi
    if [[ -n "${HUNT_REPORT_JSON:-}" && -n "${HUNT_BENCH_REPORT_MD:-}" ]]; then
      run_cmd "$ROOT_DIR/tools/render_bench_report.py" "$HUNT_REPORT_JSON" "$HUNT_BENCH_REPORT_MD"
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

  if [[ -n "${HUNT_REPORT_JSON:-}" && -f "$HUNT_REPORT_JSON" && -n "${HUNT_REPORT_MD:-}" ]]; then
    run_cmd "$ROOT_DIR/tools/render_hunt_report.py" "$HUNT_REPORT_JSON" "$HUNT_REPORT_MD"
  fi
  if [[ -n "${HUNT_REPORT_JSON:-}" && -f "$HUNT_REPORT_JSON" && -n "${HUNT_BENCH_REPORT_MD:-}" ]]; then
    run_cmd "$ROOT_DIR/tools/render_bench_report.py" "$HUNT_REPORT_JSON" "$HUNT_BENCH_REPORT_MD"
  fi
  return "$rc"
}

case "$MODE" in
  build)
    run_fielddiag_build build
    ;;
  upload)
    run_fielddiag_build upload
    ;;
  monitor)
    run_hunt_monitor
    ;;
  all)
    run_fielddiag_build upload
    run_hunt_monitor
    ;;
esac
