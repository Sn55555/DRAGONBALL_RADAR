#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <1..7>"
  echo
  echo "Environment:"
  echo "  PIO_BIN           PlatformIO executable, default: pio"
  echo "  BEACON_BOARD      PlatformIO board id, default: esp32-s3-devkitc1-n8r8"
  echo "  BEACON_PLATFORM   PlatformIO platform package"
  echo "  BEACON_PORT       Optional serial upload port, such as /dev/cu.usbmodem101"
  echo "  BEACON_PROFILE    fast, balanced, or battery; default: balanced"
  echo "  BEACON_ADV_MIN_MS Override BLE advertising minimum interval"
  echo "  BEACON_ADV_MAX_MS Override BLE advertising maximum interval"
  echo "  BEACON_DRY_RUN    Set to 1 to build without uploading"
}

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 2
fi

INDEX="$1"
if ! [[ "$INDEX" =~ ^[1-7]$ ]]; then
  usage >&2
  exit 2
fi

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
BEACON_BOARD="${BEACON_BOARD:-esp32-s3-devkitc1-n8r8}"
BEACON_PLATFORM="${BEACON_PLATFORM:-https://github.com/pioarduino/platform-espressif32/releases/download/stable/platform-espressif32.zip}"
BEACON_SKETCH="$ROOT_DIR/firmware/DragonBallBeacon/DragonBallBeacon.ino"
BEACON_PROFILE="${BEACON_PROFILE:-balanced}"

case "$BEACON_PROFILE" in
  fast)
    DEFAULT_ADV_MIN_MS=60
    DEFAULT_ADV_MAX_MS=120
    ;;
  balanced)
    DEFAULT_ADV_MIN_MS=100
    DEFAULT_ADV_MAX_MS=200
    ;;
  battery)
    DEFAULT_ADV_MIN_MS=400
    DEFAULT_ADV_MAX_MS=900
    ;;
  *)
    echo "BEACON_PROFILE must be fast, balanced, or battery" >&2
    exit 2
    ;;
esac

BEACON_ADV_MIN_MS="${BEACON_ADV_MIN_MS:-$DEFAULT_ADV_MIN_MS}"
BEACON_ADV_MAX_MS="${BEACON_ADV_MAX_MS:-$DEFAULT_ADV_MAX_MS}"

if ! [[ "$BEACON_ADV_MIN_MS" =~ ^[0-9]+$ && "$BEACON_ADV_MAX_MS" =~ ^[0-9]+$ ]]; then
  echo "BEACON_ADV_MIN_MS and BEACON_ADV_MAX_MS must be positive integers" >&2
  exit 2
fi
if (( BEACON_ADV_MIN_MS < 20 || BEACON_ADV_MAX_MS < BEACON_ADV_MIN_MS || BEACON_ADV_MAX_MS > 10240 )); then
  echo "Beacon advertising interval must satisfy 20 <= min <= max <= 10240 ms" >&2
  exit 2
fi

WORK_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$WORK_DIR/src"
cp "$BEACON_SKETCH" "$WORK_DIR/src/DragonBallBeacon.ino"

{
  echo "[env:beacon]"
  echo "platform = $BEACON_PLATFORM"
  echo "board = $BEACON_BOARD"
  echo "framework = arduino"
  echo "monitor_speed = 115200"
  echo "build_flags ="
  echo "  -DARDUINO_USB_CDC_ON_BOOT=1"
  echo "  -DARDUINO_USB_MODE=1"
  echo "  -DDRAGON_BALL_INDEX=$INDEX"
  echo "  -DDRAGON_BALL_ADV_MIN_MS=$BEACON_ADV_MIN_MS"
  echo "  -DDRAGON_BALL_ADV_MAX_MS=$BEACON_ADV_MAX_MS"
  if [[ -n "${BEACON_PORT:-}" ]]; then
    echo "upload_port = $BEACON_PORT"
  fi
} > "$WORK_DIR/platformio.ini"

if [[ "${BEACON_DRY_RUN:-0}" == "1" ]]; then
  echo "Building DBALL-$INDEX for $BEACON_BOARD ($BEACON_PROFILE, ${BEACON_ADV_MIN_MS}-${BEACON_ADV_MAX_MS} ms)"
  "$PIO_BIN" run -d "$WORK_DIR" -e beacon
else
  echo "Uploading DBALL-$INDEX to ${BEACON_PORT:-auto-detected port} for $BEACON_BOARD ($BEACON_PROFILE, ${BEACON_ADV_MIN_MS}-${BEACON_ADV_MAX_MS} ms)"
  "$PIO_BIN" run -d "$WORK_DIR" -e beacon -t upload
fi
