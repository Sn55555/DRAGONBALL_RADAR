#!/usr/bin/env bash
set -euo pipefail

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

for index in 1 2 3 4 5 6 7; do
  BUILD_FLAGS=(
    "-DARDUINO_USB_CDC_ON_BOOT=1"
    "-DARDUINO_USB_MODE=1"
    "-DDRAGON_BALL_INDEX=$index"
    "-DDRAGON_BALL_ADV_MIN_MS=$BEACON_ADV_MIN_MS"
    "-DDRAGON_BALL_ADV_MAX_MS=$BEACON_ADV_MAX_MS"
  )
  echo "Building DBALL-$index for $BEACON_BOARD ($BEACON_PROFILE, ${BEACON_ADV_MIN_MS}-${BEACON_ADV_MAX_MS} ms)"
  "$PIO_BIN" ci "$BEACON_SKETCH" \
    --board "$BEACON_BOARD" \
    --project-option "platform=$BEACON_PLATFORM" \
    --project-option "framework=arduino" \
    --project-option "build_flags=${BUILD_FLAGS[*]}"
done
