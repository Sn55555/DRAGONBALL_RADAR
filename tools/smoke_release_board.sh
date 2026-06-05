#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/smoke_release_board.sh [all|flash|monitor]

Flashes the packaged `sim` factory binary, then runs the strict one-board
simulated seven-ball bench monitor. This is the fastest hardware smoke test for
a release package because it does not rebuild firmware and does not need the
seven physical beacons.

Environment:
  RELEASE_DIR       Release folder, default: output/release-current when run
                    from the repo; the release folder itself when run from a
                    copied release package.
  RADAR_PORT        Optional serial port, e.g. /dev/cu.usbmodem101.
  SMOKE_OUTPUT_DIR  Report folder, default: output/release-smoke-current from
                    the repo or evidence/release-smoke in a release package.
  SMOKE_TIMEOUT     Monitor timeout seconds, default: 45.
  SMOKE_ERASE       1 to erase flash before writing the sim factory image.
  SMOKE_RAW         1 to echo raw DIAG serial lines during monitor.
  SMOKE_DRY_RUN     1 to print commands without flashing or monitoring.
  PIO_BIN           PlatformIO executable for the serial monitor.
  ESPTOOL_BIN       esptool executable for factory-bin flashing.

Examples:
  RADAR_PORT=/dev/cu.usbmodem101 tools/smoke_release_board.sh all
  SMOKE_DRY_RUN=1 RADAR_PORT=/dev/cu.test tools/smoke_release_board.sh all
  RADAR_PORT=/dev/cu.usbmodem101 tools/smoke_release_board.sh monitor
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MODE="${1:-all}"
case "$MODE" in
  all|flash|monitor)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "$ROOT_DIR/firmware" && -f "$ROOT_DIR/MANIFEST.md" ]]; then
  DEFAULT_RELEASE_DIR="$ROOT_DIR"
  DEFAULT_OUTPUT_DIR="$ROOT_DIR/evidence/release-smoke"
else
  DEFAULT_RELEASE_DIR="$ROOT_DIR/output/release-current"
  DEFAULT_OUTPUT_DIR="$ROOT_DIR/output/release-smoke-current"
fi

TOOLS_DIR="$ROOT_DIR/tools"
RELEASE_DIR="${RELEASE_DIR:-$DEFAULT_RELEASE_DIR}"
SMOKE_OUTPUT_DIR="${SMOKE_OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-45}"
SMOKE_ERASE="${SMOKE_ERASE:-0}"
SMOKE_RAW="${SMOKE_RAW:-0}"
SMOKE_DRY_RUN="${SMOKE_DRY_RUN:-0}"

for flag in SMOKE_ERASE SMOKE_RAW SMOKE_DRY_RUN; do
  value="${!flag}"
  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo "$flag must be 0 or 1, got: $value" >&2
    exit 2
  fi
done

if ! [[ "$SMOKE_TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "SMOKE_TIMEOUT must be a non-negative integer, got: $SMOKE_TIMEOUT" >&2
  exit 2
fi

run_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$SMOKE_DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

ensure_output_dir() {
  if [[ "$SMOKE_DRY_RUN" == "1" ]]; then
    printf '+ mkdir -p %q\n' "$SMOKE_OUTPUT_DIR"
  else
    mkdir -p "$SMOKE_OUTPUT_DIR"
  fi
}

copy_if_present() {
  local source="$1"
  local target="$2"
  if [[ "$SMOKE_DRY_RUN" == "1" ]]; then
    printf '+ cp-if-present %q %q\n' "$source" "$target"
    return 0
  fi
  if [[ -f "$source" ]]; then
    mkdir -p "$(dirname "$target")"
    cp "$source" "$target"
  fi
}

run_flash() {
  local env_items=(
    "RELEASE_DIR=$RELEASE_DIR"
    "FLASH_ERASE=$SMOKE_ERASE"
    "FLASH_DRY_RUN=$SMOKE_DRY_RUN"
  )
  if [[ -n "${RADAR_PORT:-}" ]]; then
    env_items+=("RADAR_PORT=$RADAR_PORT")
  fi
  if [[ -n "${ESPTOOL_BIN:-}" ]]; then
    env_items+=("ESPTOOL_BIN=$ESPTOOL_BIN")
  fi
  run_cmd env "${env_items[@]}" "$TOOLS_DIR/flash_release_firmware.sh" sim
}

run_monitor() {
  local env_items=(
    "SIM_TIMEOUT=$SMOKE_TIMEOUT"
    "SIM_REQUIRE_ONLINE=touch,imu,ble,audio"
    "SIM_MIN_BEACONS=7"
    "SIM_MIN_COLLECTED=7"
    "SIM_MIN_COLLECTIONS=7"
    "SIM_REQUIRE_COLLECTION_SET=1"
    "SIM_REQUIRE_SUMMON=1"
    "SIM_REPORT_JSON=$SMOKE_OUTPUT_DIR/bench-sim-report.json"
    "SIM_REPORT_MD=$SMOKE_OUTPUT_DIR/bench-sim-report.md"
    "SIM_LOG=$SMOKE_OUTPUT_DIR/bench-sim-raw.log"
    "SIM_RAW=$SMOKE_RAW"
    "BENCH_DRY_RUN=$SMOKE_DRY_RUN"
  )
  if [[ -n "${RADAR_PORT:-}" ]]; then
    env_items+=("RADAR_PORT=$RADAR_PORT")
  fi
  if [[ -n "${PIO_BIN:-}" ]]; then
    env_items+=("PIO_BIN=$PIO_BIN")
  fi
  run_cmd env "${env_items[@]}" "$TOOLS_DIR/bench_sim.sh" monitor
}

sync_repo_reports() {
  if [[ "$ROOT_DIR" == "$RELEASE_DIR" ]]; then
    return 0
  fi
  copy_if_present "$SMOKE_OUTPUT_DIR/bench-sim-report.json" "$ROOT_DIR/output/bench-sim-report.json"
  copy_if_present "$SMOKE_OUTPUT_DIR/bench-sim-report.md" "$ROOT_DIR/output/bench-sim-report.md"
  copy_if_present "$SMOKE_OUTPUT_DIR/bench-sim-raw.log" "$ROOT_DIR/output/bench-sim-raw.log"
  if [[ -x "$TOOLS_DIR/render_project_status.py" || -f "$TOOLS_DIR/render_project_status.py" ]]; then
    run_cmd "$TOOLS_DIR/render_project_status.py" --output "$ROOT_DIR/output/project-status.md"
  fi
}

ensure_output_dir
case "$MODE" in
  flash)
    run_flash
    ;;
  monitor)
    run_monitor
    sync_repo_reports
    ;;
  all)
    run_flash
    run_monitor
    sync_repo_reports
    ;;
esac
