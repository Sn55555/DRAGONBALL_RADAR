#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/build_radar.sh [default|field|fielddiag|near|debug|diag|sim|beach] [build|upload]

Examples:
  tools/build_radar.sh field
  tools/build_radar.sh fielddiag upload
  tools/build_radar.sh near upload
  tools/build_radar.sh diag upload
  tools/build_radar.sh sim upload
  tools/build_radar.sh beach upload
  RADAR_PORT=/dev/cu.usbmodem101 tools/build_radar.sh field upload
  COLLECT_RSSI=-47 COLLECT_HOLD_MS=1500 tools/build_radar.sh field

Environment:
  PIO_BIN          PlatformIO executable, default: pio
  RADAR_PLATFORM   PlatformIO platform package for custom-flag builds
  RADAR_MODE       Mode used when first arg is omitted, default: field
  RADAR_ACTION     build or upload when second arg is omitted, default: build
  RADAR_PORT       Optional serial upload port, such as /dev/cu.usbmodem101
  COLLECT_RSSI     Override collection threshold in dBm, such as -47
  COLLECT_HOLD_MS  Override close-hold time in milliseconds
  BEACON_TTL_MS    Override active beacon timeout in milliseconds
  BEACON_TRACE_MS  Override dim last-known trace lifetime in milliseconds
  BEACON_FRESH_MS  Override bright fresh-beacon lifetime in milliseconds
  RADAR_BRIGHTNESS Override AMOLED brightness, 0-255, default: 184
  AUDIO_GAIN        Override audio level percent, 0-200, default: 100
  FRAME_MS          Override display frame interval, 20-180 ms, default: 25
  DISPLAY_BUS_HZ    Override CO5300 QSPI display bus, 20000000-80000000 Hz, default: 80000000
  BOOT_FRAME_DELAY_MS Override boot animation frame delay, 30-140 ms, default: 45
  GRID_SNAP         1 to latch target blips to rectangular grid, 0 for smooth motion
  SERIAL_DIAG       1 to print hidden hardware/BLE diagnostics over USB serial
  DEMO_TOUCH        1 to allow center-tap simulated collection, 0 to disable
  SIMULATED_BLE     1 to inject deterministic DBALL beacons in the radar firmware
  BEACH_SCENE       1 to show the beach walking scene, 0 for radar modes
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 2 ]]; then
  usage >&2
  exit 2
fi

require_int() {
  local name="$1"
  local value="${!name:-}"
  if [[ -n "$value" && ! "$value" =~ ^-?[0-9]+$ ]]; then
    echo "$name must be an integer, got: $value" >&2
    exit 2
  fi
}

for override in \
  COLLECT_RSSI \
  COLLECT_HOLD_MS \
  BEACON_TTL_MS \
  BEACON_TRACE_MS \
  BEACON_FRESH_MS \
  RADAR_BRIGHTNESS \
  AUDIO_GAIN \
  FRAME_MS \
  DISPLAY_BUS_HZ \
  BOOT_FRAME_DELAY_MS \
  GRID_SNAP \
  SERIAL_DIAG \
  DEMO_TOUCH \
  SIMULATED_BLE \
  BEACH_SCENE; do
  require_int "$override"
done

require_range() {
  local name="$1"
  local min="$2"
  local max="$3"
  local value="${!name:-}"
  if [[ -n "$value" && ( "$value" -lt "$min" || "$value" -gt "$max" ) ]]; then
    echo "$name must be in $min..$max, got: $value" >&2
    exit 2
  fi
}

require_range RADAR_BRIGHTNESS 0 255
require_range AUDIO_GAIN 0 200
require_range FRAME_MS 20 180
require_range DISPLAY_BUS_HZ 20000000 80000000
require_range BOOT_FRAME_DELAY_MS 30 140
require_range GRID_SNAP 0 1
require_range SERIAL_DIAG 0 1
require_range DEMO_TOUCH 0 1
require_range SIMULATED_BLE 0 1
require_range BEACH_SCENE 0 1

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
RADAR_PLATFORM="${RADAR_PLATFORM:-https://github.com/pioarduino/platform-espressif32/releases/download/stable/platform-espressif32.zip}"
MODE="${1:-${RADAR_MODE:-field}}"
ACTION="${2:-${RADAR_ACTION:-build}}"

BASE_FLAGS=(
  "-DARDUINO_USB_CDC_ON_BOOT=1"
  "-DARDUINO_USB_MODE=1"
  "-DBOARD_HAS_PSRAM"
  "-DUSE_PRIVATE_BOOT_LOGO=1"
)

BUILD_FLAGS=("${BASE_FLAGS[@]}")
case "$MODE" in
  default)
    ENV_NAME="esp32-s3-touch-amoled-175c"
    ;;
  field)
    ENV_NAME="esp32-s3-touch-amoled-175c-field"
    BUILD_FLAGS+=("-DDRAGON_RADAR_DEMO_ON_BOOT=0")
    if [[ -z "${DEMO_TOUCH:-}" ]]; then
      BUILD_FLAGS+=("-DDRAGON_RADAR_DEMO_TOUCH=0")
    fi
    ;;
  fielddiag)
    ENV_NAME="esp32-s3-touch-amoled-175c-fielddiag"
    BUILD_FLAGS+=(
      "-DDRAGON_RADAR_SERIAL_DIAG=1"
      "-DDRAGON_RADAR_DEMO_ON_BOOT=0"
      "-DDRAGON_RADAR_DEMO_TOUCH=0"
    )
    ;;
  near)
    ENV_NAME="esp32-s3-touch-amoled-175c-near"
    BUILD_FLAGS+=("-DDRAGON_RADAR_DEMO_ON_BOOT=0")
    if [[ -z "${DEMO_TOUCH:-}" ]]; then
      BUILD_FLAGS+=("-DDRAGON_RADAR_DEMO_TOUCH=0")
    fi
    if [[ -z "${COLLECT_RSSI:-}" ]]; then
      BUILD_FLAGS+=("-DDRAGON_RADAR_COLLECT_RSSI=-45")
    fi
    if [[ -z "${COLLECT_HOLD_MS:-}" ]]; then
      BUILD_FLAGS+=("-DDRAGON_RADAR_COLLECT_HOLD_MS=1500")
    fi
    ;;
  debug)
    ENV_NAME="esp32-s3-touch-amoled-175c-debug"
    BUILD_FLAGS+=(
      "-DDRAGON_RADAR_DEBUG_HUD=1"
      "-DDRAGON_RADAR_SCAN_LINE=1"
      "-DDRAGON_RADAR_STAR_BLIPS=1"
    )
    ;;
  diag)
    ENV_NAME="esp32-s3-touch-amoled-175c-diag"
    BUILD_FLAGS+=(
      "-DDRAGON_RADAR_DEBUG_HUD=1"
      "-DDRAGON_RADAR_SCAN_LINE=1"
      "-DDRAGON_RADAR_STAR_BLIPS=1"
      "-DDRAGON_RADAR_SERIAL_DIAG=1"
      "-DDRAGON_RADAR_DEMO_ON_BOOT=0"
      "-DDRAGON_RADAR_DEMO_TOUCH=0"
    )
    ;;
  sim)
    ENV_NAME="esp32-s3-touch-amoled-175c-sim"
    BUILD_FLAGS+=(
      "-DDRAGON_RADAR_SERIAL_DIAG=1"
      "-DDRAGON_RADAR_DEMO_ON_BOOT=0"
      "-DDRAGON_RADAR_DEMO_TOUCH=0"
      "-DDRAGON_RADAR_SIMULATED_BLE=1"
    )
    ;;
  beach)
    ENV_NAME="esp32-s3-touch-amoled-175c-beach"
    BUILD_FLAGS+=(
      "-DDRAGON_RADAR_BEACH_SCENE=1"
      "-DDRAGON_RADAR_SERIAL_DIAG=1"
      "-DDRAGON_RADAR_DEMO_ON_BOOT=0"
      "-DDRAGON_RADAR_DEMO_TOUCH=0"
      "-DDRAGON_RADAR_AUDIO_GAIN=180"
    )
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

case "$ACTION" in
  build|upload)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

CUSTOM_FLAGS=0
append_override() {
  local value="$1"
  local macro="$2"
  if [[ -n "$value" ]]; then
    BUILD_FLAGS+=("-D${macro}=${value}")
    CUSTOM_FLAGS=1
  fi
}

append_override "${COLLECT_RSSI:-}" "DRAGON_RADAR_COLLECT_RSSI"
append_override "${COLLECT_HOLD_MS:-}" "DRAGON_RADAR_COLLECT_HOLD_MS"
append_override "${BEACON_TTL_MS:-}" "DRAGON_RADAR_BEACON_TTL_MS"
append_override "${BEACON_TRACE_MS:-}" "DRAGON_RADAR_BEACON_TRACE_MS"
append_override "${BEACON_FRESH_MS:-}" "DRAGON_RADAR_BEACON_FRESH_MS"
append_override "${RADAR_BRIGHTNESS:-}" "DRAGON_RADAR_BRIGHTNESS"
append_override "${AUDIO_GAIN:-}" "DRAGON_RADAR_AUDIO_GAIN"
append_override "${FRAME_MS:-}" "DRAGON_RADAR_FRAME_MS"
append_override "${DISPLAY_BUS_HZ:-}" "DRAGON_RADAR_DISPLAY_BUS_HZ"
append_override "${BOOT_FRAME_DELAY_MS:-}" "DRAGON_RADAR_BOOT_FRAME_DELAY_MS"
append_override "${GRID_SNAP:-}" "DRAGON_RADAR_GRID_SNAP"
append_override "${SERIAL_DIAG:-}" "DRAGON_RADAR_SERIAL_DIAG"
append_override "${DEMO_TOUCH:-}" "DRAGON_RADAR_DEMO_TOUCH"
append_override "${SIMULATED_BLE:-}" "DRAGON_RADAR_SIMULATED_BLE"
append_override "${BEACH_SCENE:-}" "DRAGON_RADAR_BEACH_SCENE"

CUSTOM_WORK_DIR=""
cleanup() {
  if [[ -n "$CUSTOM_WORK_DIR" ]]; then
    rm -rf "$CUSTOM_WORK_DIR"
  fi
}
trap cleanup EXIT

RUN_ARGS=(run --project-dir "$ROOT_DIR" -e "$ENV_NAME")
if [[ "$CUSTOM_FLAGS" == "1" ]]; then
  CUSTOM_WORK_DIR="$(mktemp -d)"
  CUSTOM_CONF="$CUSTOM_WORK_DIR/platformio.ini"
  {
    echo "[platformio]"
    echo "src_dir = $ROOT_DIR/firmware/DragonRadar"
    echo "lib_dir = $ROOT_DIR/lib"
    echo "boards_dir = $ROOT_DIR/boards"
    echo
    echo "[env:radar-custom]"
    echo "platform = $RADAR_PLATFORM"
    echo "board = waveshare_esp32_s3_touch_amoled_175c"
    echo "framework = arduino"
    echo "monitor_speed = 115200"
    echo "upload_speed = 921600"
    echo "board_build.flash_size = 32MB"
    echo "board_build.partitions = huge_app.csv"
    echo "build_flags ="
    for flag in "${BUILD_FLAGS[@]}"; do
      echo "  $flag"
    done
    echo "lib_ldf_mode = deep+"
  } > "$CUSTOM_CONF"
  ENV_NAME="radar-custom"
  RUN_ARGS=(run --project-dir "$ROOT_DIR" --project-conf "$CUSTOM_CONF" -e "$ENV_NAME")
fi
if [[ "$ACTION" == "upload" ]]; then
  RUN_ARGS+=(-t upload)
fi
if [[ -n "${RADAR_PORT:-}" ]]; then
  RUN_ARGS+=(--upload-port "$RADAR_PORT")
fi

echo "$ACTION radar mode '$MODE' with PlatformIO env '$ENV_NAME'"
if [[ "$CUSTOM_FLAGS" == "1" ]]; then
  echo "Custom build flags: ${BUILD_FLAGS[*]}"
fi
"$PIO_BIN" "${RUN_ARGS[@]}"
