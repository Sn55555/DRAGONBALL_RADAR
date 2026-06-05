#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/run_release_acceptance.sh [all|bringup|sim|beacons|hunt]

Runs hardware acceptance from a packaged release without rebuilding firmware.
It flashes packaged factory binaries and monitors the DIAG stream for the same
proof gates used by the source-tree acceptance flow.

Environment:
  RELEASE_DIR              Release folder, default: output/release-current from
                           the repo; the release folder itself when copied.
  RADAR_PORT               Optional serial port, e.g. /dev/cu.usbmodem101.
  RELEASE_ACCEPTANCE_DIR   Report folder, default: output/release-acceptance-current
                           from the repo or evidence/release-acceptance in a release.
  RELEASE_ACCEPTANCE_FLASH 1 to flash each required factory image, default: 1.
  RELEASE_ACCEPTANCE_ERASE 1 to erase before each flash, default: 0.
  RELEASE_ACCEPTANCE_RAW   1 to echo raw DIAG serial lines, default: 0.
  RELEASE_ACCEPTANCE_DRY_RUN
                           1 to print commands without flashing or monitoring.
  RELEASE_ACCEPTANCE_MOCK  1 to run a deterministic local DIAG self-test instead
                           of flashing or reading a serial port. This validates
                           the packaged tools only; it is not hardware proof.
  ACCEPTANCE_BRINGUP_TIMEOUT  Bring-up timeout seconds, default: 30.
  ACCEPTANCE_SIM_TIMEOUT      Sim bench timeout seconds, default: 45.
  ACCEPTANCE_BEACON_TIMEOUT   Seven-beacon verify timeout seconds, default: 90.
  ACCEPTANCE_HUNT_TIMEOUT     Field hunt timeout seconds, default: 600.
  PIO_BIN                  PlatformIO executable for serial monitor.
  ESPTOOL_BIN              esptool executable for factory-bin flashing.

Examples:
  RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh all
  RELEASE_ACCEPTANCE_DRY_RUN=1 RADAR_PORT=/dev/cu.test tools/run_release_acceptance.sh all
  RELEASE_ACCEPTANCE_MOCK=1 tools/run_release_acceptance.sh all
  RELEASE_ACCEPTANCE_FLASH=0 RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh hunt
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MODE="${1:-all}"
case "$MODE" in
  all|bringup|sim|beacons|hunt)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "$ROOT_DIR/firmware" && -f "$ROOT_DIR/MANIFEST.md" ]]; then
  DEFAULT_RELEASE_DIR="$ROOT_DIR"
  DEFAULT_OUTPUT_DIR="$ROOT_DIR/evidence/release-acceptance"
  DEFAULT_MOCK_OUTPUT_DIR="$ROOT_DIR/evidence/release-acceptance-mock"
else
  DEFAULT_RELEASE_DIR="$ROOT_DIR/output/release-current"
  DEFAULT_OUTPUT_DIR="$ROOT_DIR/output/release-acceptance-current"
  DEFAULT_MOCK_OUTPUT_DIR="$ROOT_DIR/output/release-acceptance-mock"
fi

TOOLS_DIR="$ROOT_DIR/tools"
RELEASE_DIR="${RELEASE_DIR:-$DEFAULT_RELEASE_DIR}"
RELEASE_ACCEPTANCE_MOCK="${RELEASE_ACCEPTANCE_MOCK:-0}"
if [[ -z "${RELEASE_ACCEPTANCE_DIR+x}" ]]; then
  if [[ "$RELEASE_ACCEPTANCE_MOCK" == "1" ]]; then
    RELEASE_ACCEPTANCE_DIR="$DEFAULT_MOCK_OUTPUT_DIR"
  else
    RELEASE_ACCEPTANCE_DIR="$DEFAULT_OUTPUT_DIR"
  fi
fi
RELEASE_ACCEPTANCE_FLASH="${RELEASE_ACCEPTANCE_FLASH:-1}"
RELEASE_ACCEPTANCE_ERASE="${RELEASE_ACCEPTANCE_ERASE:-0}"
RELEASE_ACCEPTANCE_RAW="${RELEASE_ACCEPTANCE_RAW:-0}"
RELEASE_ACCEPTANCE_DRY_RUN="${RELEASE_ACCEPTANCE_DRY_RUN:-0}"
ACCEPTANCE_BRINGUP_TIMEOUT="${ACCEPTANCE_BRINGUP_TIMEOUT:-30}"
ACCEPTANCE_SIM_TIMEOUT="${ACCEPTANCE_SIM_TIMEOUT:-45}"
ACCEPTANCE_BEACON_TIMEOUT="${ACCEPTANCE_BEACON_TIMEOUT:-90}"
ACCEPTANCE_HUNT_TIMEOUT="${ACCEPTANCE_HUNT_TIMEOUT:-600}"

for flag in RELEASE_ACCEPTANCE_FLASH RELEASE_ACCEPTANCE_ERASE RELEASE_ACCEPTANCE_RAW RELEASE_ACCEPTANCE_DRY_RUN RELEASE_ACCEPTANCE_MOCK; do
  value="${!flag}"
  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo "$flag must be 0 or 1, got: $value" >&2
    exit 2
  fi
done

for number in ACCEPTANCE_BRINGUP_TIMEOUT ACCEPTANCE_SIM_TIMEOUT ACCEPTANCE_BEACON_TIMEOUT ACCEPTANCE_HUNT_TIMEOUT; do
  value="${!number}"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "$number must be a non-negative integer, got: $value" >&2
    exit 2
  fi
done

run_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$RELEASE_ACCEPTANCE_DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

ensure_output_dir() {
  if [[ "$RELEASE_ACCEPTANCE_DRY_RUN" == "1" ]]; then
    printf '+ mkdir -p %q\n' "$RELEASE_ACCEPTANCE_DIR"
  else
    mkdir -p "$RELEASE_ACCEPTANCE_DIR"
  fi
}

flash_mode() {
  local mode="$1"
  if [[ "$RELEASE_ACCEPTANCE_MOCK" == "1" ]]; then
    printf '+ mock-skip-flash %q\n' "$mode"
    return 0
  fi
  if [[ "$RELEASE_ACCEPTANCE_FLASH" != "1" ]]; then
    return 0
  fi
  local env_items=(
    "RELEASE_DIR=$RELEASE_DIR"
    "FLASH_ERASE=$RELEASE_ACCEPTANCE_ERASE"
    "FLASH_DRY_RUN=$RELEASE_ACCEPTANCE_DRY_RUN"
  )
  if [[ -n "${RADAR_PORT:-}" ]]; then
    env_items+=("RADAR_PORT=$RADAR_PORT")
  fi
  if [[ -n "${ESPTOOL_BIN:-}" ]]; then
    env_items+=("ESPTOOL_BIN=$ESPTOOL_BIN")
  fi
  run_cmd env "${env_items[@]}" "$TOOLS_DIR/flash_release_firmware.sh" "$mode"
}

mock_feed_command() {
  local gate="$1"
  case "$gate" in
    bringup)
      MOCK_FEED_CMD=("$TOOLS_DIR/simulate_diag_feed.py" --beacons 1 --samples 12 --touch-events --seed 31)
      ;;
    sim)
      MOCK_FEED_CMD=(
        "$TOOLS_DIR/simulate_diag_feed.py"
        --beacons 7
        --samples 24
        --touch-events
        --seed 41
        --simulated-ble
        --hunt-session 1
        --collect-all
        --summon
      )
      ;;
    beacons)
      MOCK_FEED_CMD=("$TOOLS_DIR/simulate_diag_feed.py" --beacons 7 --samples 28 --touch-events --seed 51)
      ;;
    hunt)
      MOCK_FEED_CMD=(
        "$TOOLS_DIR/simulate_diag_feed.py"
        --beacons 7
        --samples 24
        --touch-events
        --seed 61
        --hunt-session 1
        --collect-all
        --summon
      )
      ;;
    *)
      echo "unknown mock gate: $gate" >&2
      exit 2
      ;;
  esac
}

monitor_diag() {
  local gate="$1"
  shift
  local report_json="$1"
  local raw_log="$2"
  shift 2
  local cmd=("$TOOLS_DIR/monitor_diag.py" --baud 115200 --report-json "$report_json" --log-file "$raw_log")
  if [[ "$RELEASE_ACCEPTANCE_MOCK" == "1" ]]; then
    cmd+=("--stdin")
  else
    if [[ -n "${PIO_BIN:-}" ]]; then
      cmd+=(--pio-bin "$PIO_BIN")
    fi
    if [[ -n "${RADAR_PORT:-}" ]]; then
      cmd+=(--port "$RADAR_PORT")
    fi
  fi
  if [[ "$RELEASE_ACCEPTANCE_RAW" == "1" ]]; then
    cmd+=(--raw)
  fi
  cmd+=("$@")

  if [[ "$RELEASE_ACCEPTANCE_MOCK" == "1" ]]; then
    mock_feed_command "$gate"
    printf '+'
    printf ' %q' "${MOCK_FEED_CMD[@]}"
    printf ' |'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    if [[ "$RELEASE_ACCEPTANCE_DRY_RUN" != "1" ]]; then
      "${MOCK_FEED_CMD[@]}" | "${cmd[@]}"
    fi
    return 0
  fi

  run_cmd "${cmd[@]}"
}

render_bench() {
  local report_json="$1"
  local report_md="$2"
  run_cmd "$TOOLS_DIR/render_bench_report.py" "$report_json" "$report_md"
}

render_hunt() {
  local report_json="$1"
  local report_md="$2"
  run_cmd "$TOOLS_DIR/render_hunt_report.py" "$report_json" "$report_md"
}

copy_if_present() {
  local source="$1"
  local target="$2"
  if [[ "$RELEASE_ACCEPTANCE_DRY_RUN" == "1" ]]; then
    printf '+ cp-if-present %q %q\n' "$source" "$target"
    return 0
  fi
  if [[ -f "$source" ]]; then
    mkdir -p "$(dirname "$target")"
    cp "$source" "$target"
  fi
}

sync_repo_reports() {
  if [[ "$RELEASE_ACCEPTANCE_MOCK" == "1" ]]; then
    return 0
  fi
  if [[ "$ROOT_DIR" == "$RELEASE_DIR" ]]; then
    return 0
  fi
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/bringup-diag-report.json" "$ROOT_DIR/output/bringup-diag-report.json"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/bringup-diag-report.md" "$ROOT_DIR/output/bringup-diag-report.md"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/bringup-diag-raw.log" "$ROOT_DIR/output/bringup-diag-raw.log"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/bench-sim-report.json" "$ROOT_DIR/output/bench-sim-report.json"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/bench-sim-report.md" "$ROOT_DIR/output/bench-sim-report.md"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/bench-sim-raw.log" "$ROOT_DIR/output/bench-sim-raw.log"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/beacon-set-verify-report.json" "$ROOT_DIR/output/beacon-set-verify-report.json"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/beacon-set-verify-report.md" "$ROOT_DIR/output/beacon-set-verify-report.md"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/beacon-set-verify-raw.log" "$ROOT_DIR/output/beacon-set-verify-raw.log"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/field-hunt-report.json" "$ROOT_DIR/output/field-hunt-report.json"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/field-hunt-report.md" "$ROOT_DIR/output/field-hunt-report.md"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/field-hunt-bench-report.md" "$ROOT_DIR/output/field-hunt-bench-report.md"
  copy_if_present "$RELEASE_ACCEPTANCE_DIR/field-hunt-raw.log" "$ROOT_DIR/output/field-hunt-raw.log"
  if [[ -f "$TOOLS_DIR/render_project_status.py" ]]; then
    run_cmd "$TOOLS_DIR/render_project_status.py" --output "$ROOT_DIR/output/project-status.md"
  fi
}

run_bringup() {
  flash_mode diag
  local report="$RELEASE_ACCEPTANCE_DIR/bringup-diag-report.json"
  monitor_diag bringup "$report" "$RELEASE_ACCEPTANCE_DIR/bringup-diag-raw.log" \
    --timeout "$ACCEPTANCE_BRINGUP_TIMEOUT" \
    --require-online touch,imu,ble,audio \
    --calibrate
  render_bench "$report" "$RELEASE_ACCEPTANCE_DIR/bringup-diag-report.md"
}

run_sim() {
  flash_mode sim
  local report="$RELEASE_ACCEPTANCE_DIR/bench-sim-report.json"
  monitor_diag sim "$report" "$RELEASE_ACCEPTANCE_DIR/bench-sim-raw.log" \
    --timeout "$ACCEPTANCE_SIM_TIMEOUT" \
    --require-online touch,imu,ble,audio \
    --require-simulated-ble \
    --min-beacons 7 \
    --min-collected 7 \
    --min-collections 7 \
    --require-collection-set \
    --require-summon \
    --calibrate
  render_bench "$report" "$RELEASE_ACCEPTANCE_DIR/bench-sim-report.md"
}

run_beacons() {
  flash_mode diag
  local report="$RELEASE_ACCEPTANCE_DIR/beacon-set-verify-report.json"
  monitor_diag beacons "$report" "$RELEASE_ACCEPTANCE_DIR/beacon-set-verify-raw.log" \
    --timeout "$ACCEPTANCE_BEACON_TIMEOUT" \
    --require-online touch,imu,ble,audio \
    --min-beacons 7 \
    --calibrate
  render_bench "$report" "$RELEASE_ACCEPTANCE_DIR/beacon-set-verify-report.md"
}

run_hunt() {
  flash_mode fielddiag
  local report="$RELEASE_ACCEPTANCE_DIR/field-hunt-report.json"
  monitor_diag hunt "$report" "$RELEASE_ACCEPTANCE_DIR/field-hunt-raw.log" \
    --timeout "$ACCEPTANCE_HUNT_TIMEOUT" \
    --require-online touch,imu,ble,audio \
    --min-beacons 7 \
    --min-collected 7 \
    --min-collections 7 \
    --require-collection-set \
    --require-summon \
    --calibrate
  render_hunt "$report" "$RELEASE_ACCEPTANCE_DIR/field-hunt-report.md"
  render_bench "$report" "$RELEASE_ACCEPTANCE_DIR/field-hunt-bench-report.md"
}

ensure_output_dir
if [[ "$RELEASE_ACCEPTANCE_MOCK" == "1" ]]; then
  if [[ "$RELEASE_ACCEPTANCE_DRY_RUN" == "1" ]]; then
    printf '+ write-mock-notice %q\n' "$RELEASE_ACCEPTANCE_DIR/MOCK-NOT-HARDWARE.txt"
  else
    cat > "$RELEASE_ACCEPTANCE_DIR/MOCK-NOT-HARDWARE.txt" <<'NOTICE'
This folder was produced with RELEASE_ACCEPTANCE_MOCK=1.
It validates the packaged DIAG parser, report renderers, and acceptance script.
It does not prove the ESP32-S3 board, display, touch, IMU, BLE, audio, or physical beacons.
NOTICE
  fi
fi
case "$MODE" in
  bringup)
    run_bringup
    sync_repo_reports
    ;;
  sim)
    run_sim
    sync_repo_reports
    ;;
  beacons)
    run_beacons
    sync_repo_reports
    ;;
  hunt)
    run_hunt
    sync_repo_reports
    ;;
  all)
    run_bringup
    run_sim
    run_beacons
    run_hunt
    sync_repo_reports
    ;;
esac
