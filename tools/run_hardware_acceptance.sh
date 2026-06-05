#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/run_hardware_acceptance.sh [all|bringup|sim|beacons|hunt|status|package]

Runs the hardware proof gates needed before the Dragon Radar goal can be
called complete. The default `all` flow uploads/monitors the real board in this
order: hardware bring-up, one-board simulated seven-ball bench, physical
seven-beacon verification, clean field hunt, status render, and release package.

Environment:
  RADAR_PORT               Optional serial port, e.g. /dev/cu.usbmodem101
  PIO_BIN                  PlatformIO executable, forwarded to child scripts
  ACCEPTANCE_DIR           Output folder, default: output/hardware-acceptance-current
  ACCEPTANCE_UPLOAD        1 to upload each required firmware before monitoring,
                           0 to monitor already-flashed firmware, default: 1
  ACCEPTANCE_DRY_RUN       1 to print commands without touching hardware, default: 0
  ACCEPTANCE_PACKAGE       1 to refresh a release package after status, default: 1
  ACCEPTANCE_BRINGUP_TIMEOUT
                           Bring-up monitor timeout seconds, default: 30
  ACCEPTANCE_SIM_TIMEOUT   Sim bench timeout seconds, default: 45
  ACCEPTANCE_BEACON_TIMEOUT
                           Seven-beacon verify timeout seconds, default: 90
  ACCEPTANCE_HUNT_TIMEOUT  Field hunt timeout seconds, default: 600
  ACCEPTANCE_HUNT_MIN_BEACONS
                           Visible DBALL beacons required during hunt, default: 7
  ACCEPTANCE_RAW           1 to echo raw DIAG serial lines in monitor steps

Examples:
  RADAR_PORT=/dev/cu.usbmodem101 tools/run_hardware_acceptance.sh all
  ACCEPTANCE_DRY_RUN=1 tools/run_hardware_acceptance.sh all
  ACCEPTANCE_UPLOAD=0 tools/run_hardware_acceptance.sh sim
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MODE="${1:-all}"
case "$MODE" in
  all|bringup|sim|beacons|hunt|status|package)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACCEPTANCE_DIR="${ACCEPTANCE_DIR:-$ROOT_DIR/output/hardware-acceptance-current}"
ACCEPTANCE_UPLOAD="${ACCEPTANCE_UPLOAD:-1}"
ACCEPTANCE_DRY_RUN="${ACCEPTANCE_DRY_RUN:-0}"
ACCEPTANCE_PACKAGE="${ACCEPTANCE_PACKAGE:-1}"
ACCEPTANCE_BRINGUP_TIMEOUT="${ACCEPTANCE_BRINGUP_TIMEOUT:-30}"
ACCEPTANCE_SIM_TIMEOUT="${ACCEPTANCE_SIM_TIMEOUT:-45}"
ACCEPTANCE_BEACON_TIMEOUT="${ACCEPTANCE_BEACON_TIMEOUT:-90}"
ACCEPTANCE_HUNT_TIMEOUT="${ACCEPTANCE_HUNT_TIMEOUT:-600}"
ACCEPTANCE_HUNT_MIN_BEACONS="${ACCEPTANCE_HUNT_MIN_BEACONS:-7}"
ACCEPTANCE_RAW="${ACCEPTANCE_RAW:-0}"
ACCEPTANCE_REPORT_MD="$ACCEPTANCE_DIR/ACCEPTANCE.md"

for flag in ACCEPTANCE_UPLOAD ACCEPTANCE_DRY_RUN ACCEPTANCE_PACKAGE ACCEPTANCE_RAW; do
  value="${!flag}"
  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo "$flag must be 0 or 1, got: $value" >&2
    exit 2
  fi
done

for number in \
  ACCEPTANCE_BRINGUP_TIMEOUT \
  ACCEPTANCE_SIM_TIMEOUT \
  ACCEPTANCE_BEACON_TIMEOUT \
  ACCEPTANCE_HUNT_TIMEOUT \
  ACCEPTANCE_HUNT_MIN_BEACONS; do
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
  if [[ "$ACCEPTANCE_DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

monitor_mode() {
  if [[ "$ACCEPTANCE_UPLOAD" == "1" ]]; then
    printf '%s\n' "all"
  else
    printf '%s\n' "monitor"
  fi
}

copy_if_present() {
  local source="$1"
  local target="$2"
  if [[ "$ACCEPTANCE_DRY_RUN" == "1" ]]; then
    printf '+ cp-if-present %q %q\n' "$source" "$target"
    return 0
  fi
  if [[ -f "$source" ]]; then
    mkdir -p "$(dirname "$target")"
    cp "$source" "$target"
  fi
}

ensure_dir() {
  if [[ "$ACCEPTANCE_DRY_RUN" == "1" ]]; then
    printf '+ mkdir -p %q\n' "$ACCEPTANCE_DIR"
  else
    mkdir -p "$ACCEPTANCE_DIR"
  fi
}

write_acceptance_report() {
  if [[ "$ACCEPTANCE_DRY_RUN" == "1" ]]; then
    printf '+ write acceptance report %q\n' "$ACCEPTANCE_REPORT_MD"
    return 0
  fi

  {
    printf '# Dragon Radar Hardware Acceptance\n\n'
    printf -- '- Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf -- '- Acceptance directory: `%s`\n' "$ACCEPTANCE_DIR"
    printf -- '- Upload firmware before monitor: `%s`\n' "$ACCEPTANCE_UPLOAD"
    if [[ -n "${RADAR_PORT:-}" ]]; then
      printf -- '- Radar port: `%s`\n' "$RADAR_PORT"
    else
      printf -- '- Radar port: auto-detect\n'
    fi
    printf '\n## Proof Gates\n\n'
    printf '| Gate | JSON | Markdown | Raw log |\n'
    printf '| --- | --- | --- | --- |\n'
    printf '| Hardware bring-up | `bringup-diag-report.json` | `bringup-diag-report.md` | `bringup-diag-raw.log` |\n'
    printf '| One-board simulated bench | `bench-sim-report.json` | `bench-sim-report.md` | `bench-sim-raw.log` |\n'
    printf '| Seven physical beacons | `beacon-set-verify-report.json` | `beacon-set-verify-report.md` | `beacon-set-verify-raw.log` |\n'
    printf '| Clean field hunt | `field-hunt-report.json` | `field-hunt-report.md` | `field-hunt-raw.log` |\n'
    printf '\n## Completion Rule\n\n'
    printf 'The goal is complete only when `output/project-status.md` reports `Hardware completion: PASS` after this flow.\n'
  } > "$ACCEPTANCE_REPORT_MD"

  copy_if_present "$ACCEPTANCE_REPORT_MD" "$ROOT_DIR/output/hardware-acceptance-report.md"
}

sync_canonical_reports() {
  copy_if_present "$ACCEPTANCE_DIR/bringup-diag-report.json" "$ROOT_DIR/output/bringup-diag-report.json"
  copy_if_present "$ACCEPTANCE_DIR/bringup-diag-report.md" "$ROOT_DIR/output/bringup-diag-report.md"
  copy_if_present "$ACCEPTANCE_DIR/bringup-diag-raw.log" "$ROOT_DIR/output/bringup-diag-raw.log"
  copy_if_present "$ACCEPTANCE_DIR/bench-sim-report.json" "$ROOT_DIR/output/bench-sim-report.json"
  copy_if_present "$ACCEPTANCE_DIR/bench-sim-report.md" "$ROOT_DIR/output/bench-sim-report.md"
  copy_if_present "$ACCEPTANCE_DIR/bench-sim-raw.log" "$ROOT_DIR/output/bench-sim-raw.log"
  copy_if_present "$ACCEPTANCE_DIR/beacon-set-verify-report.json" "$ROOT_DIR/output/beacon-set-verify-report.json"
  copy_if_present "$ACCEPTANCE_DIR/beacon-set-verify-report.md" "$ROOT_DIR/output/beacon-set-verify-report.md"
  copy_if_present "$ACCEPTANCE_DIR/beacon-set-verify-raw.log" "$ROOT_DIR/output/beacon-set-verify-raw.log"
  copy_if_present "$ACCEPTANCE_DIR/field-hunt-report.json" "$ROOT_DIR/output/field-hunt-report.json"
  copy_if_present "$ACCEPTANCE_DIR/field-hunt-report.md" "$ROOT_DIR/output/field-hunt-report.md"
  copy_if_present "$ACCEPTANCE_DIR/field-hunt-bench-report.md" "$ROOT_DIR/output/field-hunt-bench-report.md"
  copy_if_present "$ACCEPTANCE_DIR/field-hunt-raw.log" "$ROOT_DIR/output/field-hunt-raw.log"
}

run_bringup() {
  local child_mode
  child_mode="$(monitor_mode)"
  local env_items=()
  if [[ -n "${PIO_BIN:-}" ]]; then
    env_items+=("PIO_BIN=$PIO_BIN")
  fi
  if [[ -n "${RADAR_PORT:-}" ]]; then
    env_items+=("RADAR_PORT=$RADAR_PORT")
  fi
  run_cmd env \
    "DIAG_TIMEOUT=$ACCEPTANCE_BRINGUP_TIMEOUT" \
    "DIAG_REQUIRE_ONLINE=touch,imu,ble,audio" \
    "DIAG_REPORT_JSON=$ACCEPTANCE_DIR/bringup-diag-report.json" \
    "DIAG_REPORT_MD=$ACCEPTANCE_DIR/bringup-diag-report.md" \
    "DIAG_LOG=$ACCEPTANCE_DIR/bringup-diag-raw.log" \
    "DIAG_RAW=$ACCEPTANCE_RAW" \
    "BRINGUP_DRY_RUN=$ACCEPTANCE_DRY_RUN" \
    "${env_items[@]}" \
    "$ROOT_DIR/tools/bringup_diag.sh" "$child_mode"
}

run_sim() {
  local child_mode
  child_mode="$(monitor_mode)"
  local env_items=()
  if [[ -n "${PIO_BIN:-}" ]]; then
    env_items+=("PIO_BIN=$PIO_BIN")
  fi
  if [[ -n "${RADAR_PORT:-}" ]]; then
    env_items+=("RADAR_PORT=$RADAR_PORT")
  fi
  run_cmd env \
    "SIM_TIMEOUT=$ACCEPTANCE_SIM_TIMEOUT" \
    "SIM_REQUIRE_ONLINE=touch,imu,ble,audio" \
    "SIM_MIN_BEACONS=7" \
    "SIM_MIN_COLLECTED=7" \
    "SIM_MIN_COLLECTIONS=7" \
    "SIM_REQUIRE_COLLECTION_SET=1" \
    "SIM_REQUIRE_SUMMON=1" \
    "SIM_REPORT_JSON=$ACCEPTANCE_DIR/bench-sim-report.json" \
    "SIM_REPORT_MD=$ACCEPTANCE_DIR/bench-sim-report.md" \
    "SIM_LOG=$ACCEPTANCE_DIR/bench-sim-raw.log" \
    "SIM_RAW=$ACCEPTANCE_RAW" \
    "BENCH_DRY_RUN=$ACCEPTANCE_DRY_RUN" \
    "${env_items[@]}" \
    "$ROOT_DIR/tools/bench_sim.sh" "$child_mode"
}

run_beacons() {
  local child_mode
  child_mode="$(monitor_mode)"
  local env_items=()
  if [[ -n "${PIO_BIN:-}" ]]; then
    env_items+=("PIO_BIN=$PIO_BIN")
  fi
  if [[ -n "${RADAR_PORT:-}" ]]; then
    env_items+=("RADAR_PORT=$RADAR_PORT")
  fi
  run_cmd env \
    "BEACON_VERIFY_TIMEOUT=$ACCEPTANCE_BEACON_TIMEOUT" \
    "BEACON_VERIFY_REQUIRE_ONLINE=touch,imu,ble,audio" \
    "BEACON_VERIFY_MIN_BEACONS=7" \
    "BEACON_VERIFY_REPORT_JSON=$ACCEPTANCE_DIR/beacon-set-verify-report.json" \
    "BEACON_VERIFY_REPORT_MD=$ACCEPTANCE_DIR/beacon-set-verify-report.md" \
    "BEACON_VERIFY_LOG=$ACCEPTANCE_DIR/beacon-set-verify-raw.log" \
    "BEACON_VERIFY_RAW=$ACCEPTANCE_RAW" \
    "BEACON_VERIFY_DRY_RUN=$ACCEPTANCE_DRY_RUN" \
    "${env_items[@]}" \
    "$ROOT_DIR/tools/verify_beacon_set.sh" "$child_mode"
}

run_hunt() {
  local child_mode
  child_mode="$(monitor_mode)"
  local env_items=()
  if [[ -n "${PIO_BIN:-}" ]]; then
    env_items+=("PIO_BIN=$PIO_BIN")
  fi
  if [[ -n "${RADAR_PORT:-}" ]]; then
    env_items+=("RADAR_PORT=$RADAR_PORT")
  fi
  run_cmd env \
    "HUNT_TIMEOUT=$ACCEPTANCE_HUNT_TIMEOUT" \
    "HUNT_REQUIRE_ONLINE=touch,imu,ble,audio" \
    "HUNT_MIN_BEACONS=$ACCEPTANCE_HUNT_MIN_BEACONS" \
    "HUNT_MIN_COLLECTED=7" \
    "HUNT_MIN_COLLECTIONS=7" \
    "HUNT_REQUIRE_COLLECTION_SET=1" \
    "HUNT_REQUIRE_SUMMON=1" \
    "HUNT_REPORT_JSON=$ACCEPTANCE_DIR/field-hunt-report.json" \
    "HUNT_REPORT_MD=$ACCEPTANCE_DIR/field-hunt-report.md" \
    "HUNT_BENCH_REPORT_MD=$ACCEPTANCE_DIR/field-hunt-bench-report.md" \
    "HUNT_LOG=$ACCEPTANCE_DIR/field-hunt-raw.log" \
    "HUNT_RAW=$ACCEPTANCE_RAW" \
    "HUNT_DRY_RUN=$ACCEPTANCE_DRY_RUN" \
    "${env_items[@]}" \
    "$ROOT_DIR/tools/record_field_hunt.sh" "$child_mode"
}

run_status() {
  sync_canonical_reports
  write_acceptance_report
  run_cmd "$ROOT_DIR/tools/render_project_status.py" --output "$ROOT_DIR/output/project-status.md"
  copy_if_present "$ROOT_DIR/output/project-status.md" "$ACCEPTANCE_DIR/project-status.md"
}

run_package() {
  run_cmd env \
    "RELEASE_DIR=$ACCEPTANCE_DIR/release" \
    "RELEASE_MODES=field fielddiag diag sim" \
    "$ROOT_DIR/tools/package_release.sh"
}

ensure_dir
case "$MODE" in
  bringup)
    run_bringup
    ;;
  sim)
    run_sim
    ;;
  beacons)
    run_beacons
    ;;
  hunt)
    run_hunt
    ;;
  status)
    run_status
    ;;
  package)
    run_package
    ;;
  all)
    run_bringup
    run_sim
    run_beacons
    run_hunt
    run_status
    if [[ "$ACCEPTANCE_PACKAGE" == "1" ]]; then
      run_package
    fi
    ;;
esac
