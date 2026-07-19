#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/flash_release_firmware.sh [field|fielddiag|near|diag|sim|path/to/factory.bin]

Flashes a packaged Capsule factory binary without rebuilding firmware.
Factory images overwrite the NVS partition, including the device owner and
Wi-Fi configuration. For routine firmware updates that preserve pairing, use
`tools/build_radar.sh <mode> upload` instead.

Environment:
  RELEASE_DIR      Release folder, default: output/release-current when run
                   from the repo; the release folder itself when run from a
                   copied release package.
  RADAR_PORT       Optional serial port, e.g. /dev/cu.usbmodem101.
  RADAR_BAUD       Flash baud rate, default: 921600.
  FLASH_MODE       esptool flash mode, default: dio. The generated ESP32-S3
                   factory images currently declare DIO in their image header.
  FLASH_FREQ       esptool flash frequency, default: 80m.
  FLASH_SIZE       esptool flash size, default: 32MB.
  ESPTOOL_BIN      esptool executable. Auto-detects PlatformIO's esptool.
  FLASH_ERASE      1 to erase flash before writing, default: 0.
  FLASH_FACTORY_RESET
                   Must be 1 to acknowledge that factory flashing clears NVS.
  FLASH_DRY_RUN    1 to print commands without flashing, default: 0.

Examples:
  FLASH_FACTORY_RESET=1 RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh field
  RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh near
  RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh sim
  FLASH_DRY_RUN=1 RADAR_PORT=/dev/cu.test tools/flash_release_firmware.sh diag
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -d "$ROOT_DIR/firmware" && -f "$ROOT_DIR/MANIFEST.md" ]]; then
  DEFAULT_RELEASE_DIR="$ROOT_DIR"
else
  DEFAULT_RELEASE_DIR="$ROOT_DIR/output/release-current"
fi

TARGET="${1:-field}"
RELEASE_DIR="${RELEASE_DIR:-$DEFAULT_RELEASE_DIR}"
RADAR_BAUD="${RADAR_BAUD:-921600}"
FLASH_MODE="${FLASH_MODE:-dio}"
FLASH_FREQ="${FLASH_FREQ:-80m}"
FLASH_SIZE="${FLASH_SIZE:-32MB}"
FLASH_ERASE="${FLASH_ERASE:-0}"
FLASH_FACTORY_RESET="${FLASH_FACTORY_RESET:-0}"
FLASH_DRY_RUN="${FLASH_DRY_RUN:-0}"

for flag in FLASH_ERASE FLASH_FACTORY_RESET FLASH_DRY_RUN; do
  value="${!flag}"
  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo "$flag must be 0 or 1, got: $value" >&2
    exit 2
  fi
done

if [[ "$FLASH_FACTORY_RESET" != "1" ]]; then
  echo "Refusing factory flash because it overwrites owner and Wi-Fi configuration in NVS." >&2
  echo "For a pairing-preserving update, use: RADAR_PORT=<port> tools/build_radar.sh field upload" >&2
  echo "For an intentional factory reset, rerun with FLASH_FACTORY_RESET=1." >&2
  exit 2
fi

if ! [[ "$RADAR_BAUD" =~ ^[0-9]+$ ]]; then
  echo "RADAR_BAUD must be a positive integer, got: $RADAR_BAUD" >&2
  exit 2
fi

case "$FLASH_MODE" in
  keep|qio|qout|dio|dout)
    ;;
  *)
    echo "FLASH_MODE must be keep, qio, qout, dio, or dout; got: $FLASH_MODE" >&2
    exit 2
    ;;
esac

find_esptool() {
  if [[ -n "${ESPTOOL_BIN:-}" ]]; then
    printf '%s\n' "$ESPTOOL_BIN"
  elif command -v esptool.py >/dev/null 2>&1; then
    command -v esptool.py
  elif command -v esptool >/dev/null 2>&1; then
    command -v esptool
  elif [[ -x "$HOME/.platformio/penv/bin/esptool.py" ]]; then
    printf '%s\n' "$HOME/.platformio/penv/bin/esptool.py"
  elif [[ -x "$HOME/.platformio/penv/bin/esptool" ]]; then
    printf '%s\n' "$HOME/.platformio/penv/bin/esptool"
  else
    printf '%s\n' "esptool.py"
  fi
}

factory_for_mode() {
  case "$1" in
    field|fielddiag|near|diag|sim)
      printf '%s\n' "$RELEASE_DIR/firmware/dragon-radar-$1-factory.bin"
      ;;
    *)
      printf '%s\n' "$1"
      ;;
  esac
}

run_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$FLASH_DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

ESPTOOL_BIN="$(find_esptool)"
FACTORY_BIN="$(factory_for_mode "$TARGET")"

if [[ ! -f "$FACTORY_BIN" ]]; then
  echo "Factory binary not found: $FACTORY_BIN" >&2
  echo "Run tools/package_release.sh first, or pass a path to a *-factory.bin file." >&2
  exit 1
fi

BASE_CMD=(
  "$ESPTOOL_BIN"
  --chip esp32s3
  --baud "$RADAR_BAUD"
  --before default_reset
  --after hard_reset
)
if [[ -n "${RADAR_PORT:-}" ]]; then
  BASE_CMD+=(--port "$RADAR_PORT")
fi

echo "Flashing Capsule factory image: $FACTORY_BIN"
if [[ -z "${RADAR_PORT:-}" ]]; then
  echo "RADAR_PORT not set; esptool will try to auto-detect a serial port."
fi

if [[ "$FLASH_ERASE" == "1" ]]; then
  run_cmd "${BASE_CMD[@]}" erase_flash
fi

run_cmd "${BASE_CMD[@]}" write_flash \
  -z \
  --flash_mode "$FLASH_MODE" \
  --flash_freq "$FLASH_FREQ" \
  --flash_size "$FLASH_SIZE" \
  0x0 "$FACTORY_BIN"
