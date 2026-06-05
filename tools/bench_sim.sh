#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/bench_sim.sh [all|build|upload|monitor]

Modes:
  all      Upload the simulated-beacon radar firmware, then monitor it.
  build    Build the simulated-beacon radar firmware only.
  upload   Build and upload the simulated-beacon radar firmware only.
  monitor  Start the summarized monitor for an already-flashed sim build.

Environment:
  PIO_BIN             PlatformIO executable, auto-detected when omitted
  RADAR_PORT          Optional serial port, such as /dev/cu.usbmodem101
  SIM_BAUD            Monitor baud rate, default: 115200
  SIM_TIMEOUT         Monitor timeout in seconds, default: 30
  SIM_REQUIRE_ONLINE  Required online components, default: touch,imu,ble,audio
  SIM_MIN_BEACONS     Minimum distinct simulated DBALL beacons, default: 7
  SIM_MIN_COLLECTED   Minimum collected balls, default: 7
  SIM_MIN_COLLECTIONS Minimum DIAG collect events, default: 7
  SIM_REQUIRE_COLLECTION_SET
                      1 to require DIAG collect events for DBALL-1..7, default: 1
  SIM_REQUIRE_SUMMON  1 to require summon mode after collection, default: 1
  SIM_CALIBRATE       1 to print aggregate RSSI and bearing stats, default: 1
  SIM_REPORT_JSON     Report path, default: output/bench-sim-report.json
  SIM_REPORT_MD       Markdown report path, default: output/bench-sim-report.md
  SIM_LOG             Raw DIAG log path, default: output/bench-sim-raw.log
  SIM_RAW             1 to also show raw serial lines
  BENCH_DRY_RUN       1 to print commands without running them
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
SIM_BAUD="${SIM_BAUD:-115200}"
SIM_TIMEOUT="${SIM_TIMEOUT:-30}"
SIM_REQUIRE_ONLINE="${SIM_REQUIRE_ONLINE:-touch,imu,ble,audio}"
SIM_MIN_BEACONS="${SIM_MIN_BEACONS:-7}"
SIM_MIN_COLLECTED="${SIM_MIN_COLLECTED:-7}"
SIM_MIN_COLLECTIONS="${SIM_MIN_COLLECTIONS:-7}"
SIM_REQUIRE_COLLECTION_SET="${SIM_REQUIRE_COLLECTION_SET:-1}"
SIM_REQUIRE_SUMMON="${SIM_REQUIRE_SUMMON:-1}"
SIM_CALIBRATE="${SIM_CALIBRATE:-1}"
SIM_REPORT_JSON="${SIM_REPORT_JSON:-$ROOT_DIR/output/bench-sim-report.json}"
SIM_REPORT_MD="${SIM_REPORT_MD:-$ROOT_DIR/output/bench-sim-report.md}"
SIM_LOG="${SIM_LOG:-$ROOT_DIR/output/bench-sim-raw.log}"

run_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "${BENCH_DRY_RUN:-0}" != "1" ]]; then
    "$@"
  fi
}

run_sim_build() {
  local action="$1"
  if [[ "$action" == "upload" ]]; then
    run_cmd env PIO_BIN="$PIO_BIN" RADAR_PORT="${RADAR_PORT:-}" "$ROOT_DIR/tools/build_radar.sh" sim upload
  else
    run_cmd env PIO_BIN="$PIO_BIN" "$ROOT_DIR/tools/build_radar.sh" sim
  fi
}

run_sim_monitor() {
  local monitor_cmd=(
    "$ROOT_DIR/tools/monitor_diag.py"
    --pio-bin "$PIO_BIN"
    --baud "$SIM_BAUD"
    --require-simulated-ble
  )
  if [[ -n "${RADAR_PORT:-}" ]]; then
    monitor_cmd+=(--port "$RADAR_PORT")
  fi
  if [[ -n "${SIM_TIMEOUT:-}" ]]; then
    monitor_cmd+=(--timeout "$SIM_TIMEOUT")
  fi
  if [[ -n "${SIM_REQUIRE_ONLINE:-}" ]]; then
    monitor_cmd+=(--require-online "$SIM_REQUIRE_ONLINE")
  fi
  if [[ -n "${SIM_MIN_BEACONS:-}" ]]; then
    monitor_cmd+=(--min-beacons "$SIM_MIN_BEACONS")
  fi
  if [[ -n "${SIM_MIN_COLLECTED:-}" ]]; then
    monitor_cmd+=(--min-collected "$SIM_MIN_COLLECTED")
  fi
  if [[ -n "${SIM_MIN_COLLECTIONS:-}" ]]; then
    monitor_cmd+=(--min-collections "$SIM_MIN_COLLECTIONS")
  fi
  if [[ "$SIM_REQUIRE_COLLECTION_SET" == "1" ]]; then
    monitor_cmd+=(--require-collection-set)
  fi
  if [[ "$SIM_REQUIRE_SUMMON" == "1" ]]; then
    monitor_cmd+=(--require-summon)
  fi
  if [[ -n "${SIM_REPORT_JSON:-}" ]]; then
    monitor_cmd+=(--report-json "$SIM_REPORT_JSON")
  fi
  if [[ -n "${SIM_LOG:-}" ]]; then
    monitor_cmd+=(--log-file "$SIM_LOG")
  fi
  if [[ "$SIM_CALIBRATE" == "1" ]]; then
    monitor_cmd+=(--calibrate)
  fi
  if [[ "${SIM_RAW:-0}" == "1" ]]; then
    monitor_cmd+=(--raw)
  fi
  if [[ "${BENCH_DRY_RUN:-0}" == "1" ]]; then
    run_cmd "${monitor_cmd[@]}"
    if [[ -n "${SIM_REPORT_JSON:-}" && -n "${SIM_REPORT_MD:-}" ]]; then
      run_cmd "$ROOT_DIR/tools/render_bench_report.py" "$SIM_REPORT_JSON" "$SIM_REPORT_MD"
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

  if [[ -n "${SIM_REPORT_JSON:-}" && -f "$SIM_REPORT_JSON" && -n "${SIM_REPORT_MD:-}" ]]; then
    run_cmd "$ROOT_DIR/tools/render_bench_report.py" "$SIM_REPORT_JSON" "$SIM_REPORT_MD"
  fi
  return "$rc"
}

case "$MODE" in
  build)
    run_sim_build build
    ;;
  upload)
    run_sim_build upload
    ;;
  monitor)
    run_sim_monitor
    ;;
  all)
    run_sim_build upload
    run_sim_monitor
    ;;
esac
