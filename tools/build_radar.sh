#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/build_radar.sh [default|field|fielddiag|debug|diag] [build|upload]

Examples:
  tools/build_radar.sh field
  tools/build_radar.sh fielddiag upload
  tools/build_radar.sh diag upload
  RADAR_PORT=/dev/cu.usbmodem101 tools/build_radar.sh field upload

Environment:
  PIO_BIN          PlatformIO executable, default: pio
  RADAR_PLATFORM   PlatformIO platform package for custom-flag builds
  RADAR_MODE       Mode used when first arg is omitted, default: field
  RADAR_ACTION     build or upload when second arg is omitted, default: build
  RADAR_PORT       Optional serial upload port, such as /dev/cu.usbmodem101
  RADAR_BRIGHTNESS Override AMOLED brightness, 0-255, default: 184
  AUDIO_GAIN        Override audio level percent, 0-200, default: 100
  FRAME_MS          Override display frame interval, 20-180 ms, default: 25
  DISPLAY_BUS_HZ    Override CO5300 QSPI display bus, 20000000-80000000 Hz, default: 80000000
  BOOT_FRAME_DELAY_MS Override boot animation frame delay, 30-140 ms, default: 45
  GRID_SNAP         1 to latch target blips to rectangular grid, 0 for smooth motion
  SERIAL_DIAG       1 to print hidden hardware/BLE diagnostics over USB serial
  PAIRING_HMAC_KEY  Build-time pairing HMAC key; must match server DRAGON_RADAR_PAIRING_HMAC_KEY
  RADAR_RELEASE     1 to require a non-default production PAIRING_HMAC_KEY
  DRAGON_RADAR_FIRMWARE_VERSION          Numeric x.y.z embedded in the image, default: 1.0.0
  DRAGON_RADAR_FIRMWARE_BUILD            Monotonic image build number >= 1, default: 1
  DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER Monotonic security counter >= 1, default: 1
  DRAGON_RADAR_OTA_ROOT_CA_PEM_FILE      PEM CA bundle for production HTTPS OTA
  DRAGON_RADAR_OTA_ROOT_CA_PEM_B64       Same CA bundle already encoded as one-line base64
  DRAGON_RADAR_OTA_ALLOW_HTTP            1 only for explicit local-development HTTP OTA and WS Relay
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIRMWARE_VERSION_HEADER="$ROOT_DIR/firmware/DragonRadar/FirmwareVersion.h"
DEFAULT_FIRMWARE_VERSION="$(sed -n 's/^#define DRAGON_RADAR_FW_VERSION "\([^"]*\)"$/\1/p' "$FIRMWARE_VERSION_HEADER" | head -1)"
DEFAULT_FIRMWARE_BUILD="$(sed -n 's/^#define DRAGON_RADAR_FW_BUILD \([0-9][0-9]*\)$/\1/p' "$FIRMWARE_VERSION_HEADER" | head -1)"
DEFAULT_FIRMWARE_SECURITY_COUNTER="$(sed -n 's/^#define DRAGON_RADAR_FW_SECURITY_COUNTER \([0-9][0-9]*\)$/\1/p' "$FIRMWARE_VERSION_HEADER" | head -1)"
if [[ -z "$DEFAULT_FIRMWARE_VERSION" || -z "$DEFAULT_FIRMWARE_BUILD" ||
      -z "$DEFAULT_FIRMWARE_SECURITY_COUNTER" ]]; then
  echo "Unable to read firmware identity defaults from $FIRMWARE_VERSION_HEADER" >&2
  exit 2
fi

FIRMWARE_VERSION="${DRAGON_RADAR_FIRMWARE_VERSION:-$DEFAULT_FIRMWARE_VERSION}"
FIRMWARE_BUILD_RAW="${DRAGON_RADAR_FIRMWARE_BUILD:-$DEFAULT_FIRMWARE_BUILD}"
FIRMWARE_SECURITY_COUNTER_RAW="${DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER:-$DEFAULT_FIRMWARE_SECURITY_COUNTER}"
OTA_ALLOW_HTTP_RAW="${DRAGON_RADAR_OTA_ALLOW_HTTP:-${OTA_ALLOW_HTTP:-0}}"
OTA_ROOT_CA_FILE="${DRAGON_RADAR_OTA_ROOT_CA_PEM_FILE:-${OTA_ROOT_CA_FILE:-}}"
OTA_ROOT_CA_B64="${DRAGON_RADAR_OTA_ROOT_CA_PEM_B64:-}"

if [[ ! "$FIRMWARE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "DRAGON_RADAR_FIRMWARE_VERSION must be numeric x.y.z, got: $FIRMWARE_VERSION" >&2
  exit 2
fi

normalize_u32_decimal() {
  local raw="$1"
  local normalized
  normalized="$(printf '%s' "$raw" | sed 's/^0*//')"
  if [[ -z "$normalized" ]]; then
    normalized=0
  fi
  if (( ${#normalized} > 10 )) ||
     { (( ${#normalized} == 10 )) && [[ "$normalized" > "4294967295" ]]; }; then
    return 1
  fi
  printf '%s\n' "$normalized"
}

IFS='.' read -r FIRMWARE_VERSION_MAJOR FIRMWARE_VERSION_MINOR FIRMWARE_VERSION_PATCH <<< "$FIRMWARE_VERSION"
if ! normalize_u32_decimal "$FIRMWARE_VERSION_MAJOR" >/dev/null ||
   ! normalize_u32_decimal "$FIRMWARE_VERSION_MINOR" >/dev/null ||
   ! normalize_u32_decimal "$FIRMWARE_VERSION_PATCH" >/dev/null; then
  echo "Each DRAGON_RADAR_FIRMWARE_VERSION component must be in 0..4294967295" >&2
  exit 2
fi
if [[ ! "$FIRMWARE_BUILD_RAW" =~ ^[0-9]+$ || ! "$FIRMWARE_SECURITY_COUNTER_RAW" =~ ^[0-9]+$ ]]; then
  echo "Firmware build and security counter must be positive integers" >&2
  exit 2
fi
if ! FIRMWARE_BUILD="$(normalize_u32_decimal "$FIRMWARE_BUILD_RAW")" ||
   ! FIRMWARE_SECURITY_COUNTER="$(normalize_u32_decimal "$FIRMWARE_SECURITY_COUNTER_RAW")"; then
  echo "Firmware build and security counter must be in 1..4294967295" >&2
  exit 2
fi
if (( FIRMWARE_BUILD < 1 )); then
  echo "DRAGON_RADAR_FIRMWARE_BUILD must be in 1..4294967295" >&2
  exit 2
fi
if (( FIRMWARE_SECURITY_COUNTER < 1 )); then
  echo "DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER must be in 1..4294967295" >&2
  exit 2
fi
if [[ "$OTA_ALLOW_HTTP_RAW" != "0" && "$OTA_ALLOW_HTTP_RAW" != "1" ]]; then
  echo "DRAGON_RADAR_OTA_ALLOW_HTTP must be 0 or 1" >&2
  exit 2
fi
OTA_ALLOW_HTTP="$OTA_ALLOW_HTTP_RAW"
if [[ -n "$OTA_ROOT_CA_FILE" && -n "$OTA_ROOT_CA_B64" ]]; then
  echo "Set only one of DRAGON_RADAR_OTA_ROOT_CA_PEM_FILE or DRAGON_RADAR_OTA_ROOT_CA_PEM_B64" >&2
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
  RADAR_BRIGHTNESS \
  AUDIO_GAIN \
  FRAME_MS \
  DISPLAY_BUS_HZ \
  BOOT_FRAME_DELAY_MS \
  GRID_SNAP \
  SERIAL_DIAG; do
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
RADAR_PLATFORM="${RADAR_PLATFORM:-https://github.com/pioarduino/platform-espressif32/releases/download/55.03.38/platform-espressif32.zip}"
MODE="${1:-${RADAR_MODE:-field}}"
ACTION="${2:-${RADAR_ACTION:-build}}"

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

RELEASE_BUILD=false
if is_truthy "${RADAR_RELEASE:-}"; then
  RELEASE_BUILD=true
  DRAGON_RADAR_PAIRING_HMAC_KEY="${PAIRING_HMAC_KEY:-}" \
  PAIRING_HMAC_KEY="${PAIRING_HMAC_KEY:-}" \
    "$ROOT_DIR/tools/prepare_release_pairing_key.sh" check >/dev/null
  if [[ "$OTA_ALLOW_HTTP" != "0" ]]; then
    echo "RADAR_RELEASE forbids DRAGON_RADAR_OTA_ALLOW_HTTP=1" >&2
    exit 2
  fi
  if [[ -z "$OTA_ROOT_CA_FILE" && -z "$OTA_ROOT_CA_B64" ]]; then
    echo "RADAR_RELEASE requires DRAGON_RADAR_OTA_ROOT_CA_PEM_FILE or DRAGON_RADAR_OTA_ROOT_CA_PEM_B64" >&2
    exit 2
  fi
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to validate OTA trust material" >&2
  exit 2
fi

OTA_TRUST_HEADER="$ROOT_DIR/firmware/DragonRadar/OtaSigningPublicKey.h"
OTA_KEY_ID="$(sed -n 's/.*kSigningKeyId\[\] = "\([^"]*\)";.*/\1/p' "$OTA_TRUST_HEADER" | head -1)"
OTA_PUBLIC_KEY_SHA256="$({
  awk '
    /kSigningPublicKeyPem.*R"PEM\(/ {
      sub(/^.*R"PEM\(/, "")
      print
      capture = 1
      next
    }
    capture && /^\)PEM";/ { exit }
    capture { print }
  ' "$OTA_TRUST_HEADER"
} | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 -r | awk '{print $1}')"
if [[ ! "$OTA_KEY_ID" =~ ^[A-Za-z0-9._-]+$ ||
      ! "$OTA_PUBLIC_KEY_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Unable to derive embedded OTA trust identity from $OTA_TRUST_HEADER" >&2
  exit 2
fi

OTA_ROOT_CA_CONFIGURED=false
OTA_ROOT_CA_SHA256=""
if [[ -n "$OTA_ROOT_CA_FILE" ]]; then
  if [[ ! -r "$OTA_ROOT_CA_FILE" ]] || ! openssl x509 -in "$OTA_ROOT_CA_FILE" -noout >/dev/null 2>&1; then
    echo "DRAGON_RADAR_OTA_ROOT_CA_PEM_FILE is not a readable PEM certificate: $OTA_ROOT_CA_FILE" >&2
    exit 2
  fi
  OTA_ROOT_CA_B64="$(openssl base64 -A -in "$OTA_ROOT_CA_FILE")"
  OTA_ROOT_CA_SHA256="$(openssl x509 -in "$OTA_ROOT_CA_FILE" -outform DER | openssl dgst -sha256 -r | awk '{print $1}')"
  OTA_ROOT_CA_CONFIGURED=true
elif [[ -n "$OTA_ROOT_CA_B64" ]]; then
  if ! printf '%s' "$OTA_ROOT_CA_B64" | openssl base64 -d -A | openssl x509 -noout >/dev/null 2>&1; then
    echo "DRAGON_RADAR_OTA_ROOT_CA_PEM_B64 does not decode to a PEM certificate" >&2
    exit 2
  fi
  OTA_ROOT_CA_SHA256="$(printf '%s' "$OTA_ROOT_CA_B64" | openssl base64 -d -A | openssl x509 -outform DER | openssl dgst -sha256 -r | awk '{print $1}')"
  OTA_ROOT_CA_CONFIGURED=true
fi
if [[ "$OTA_ROOT_CA_CONFIGURED" == true && ! "$OTA_ROOT_CA_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Unable to fingerprint OTA root CA" >&2
  exit 2
fi

BASE_FLAGS=(
  "-DARDUINO_USB_CDC_ON_BOOT=1"
  "-DARDUINO_USB_MODE=1"
  "-DBOARD_HAS_PSRAM"
  "-I\$PROJECT_PACKAGES_DIR/framework-arduinoespressif32/libraries/Network/src"
  "-I\$PROJECT_PACKAGES_DIR/framework-arduinoespressif32/libraries/WiFi/src"
  "-I\$PROJECT_PACKAGES_DIR/framework-arduinoespressif32/libraries/NetworkClientSecure/src"
)

BUILD_FLAGS=("${BASE_FLAGS[@]}")
if [[ "$RELEASE_BUILD" == true ]]; then
  BUILD_FLAGS+=("-DDRAGON_RADAR_RELEASE_BUILD=1")
fi
case "$MODE" in
  default)
    ENV_NAME="esp32-s3-touch-amoled-175c"
    ;;
  field)
    ENV_NAME="esp32-s3-touch-amoled-175c-field"
    ;;
  fielddiag)
    ENV_NAME="esp32-s3-touch-amoled-175c-fielddiag"
    BUILD_FLAGS+=(
      "-DDRAGON_RADAR_FRAME_MS=20"
      "-DDRAGON_RADAR_SERIAL_DIAG=1"
      "-DDRAGON_RADAR_SOUND_EFFECTS=1"
      "-DDRAGON_RADAR_AUDIO_GAIN=180"
    )
    ;;
  debug)
    ENV_NAME="esp32-s3-touch-amoled-175c-debug"
    BUILD_FLAGS+=(
      "-DDRAGON_RADAR_DEBUG_HUD=1"
      "-DDRAGON_RADAR_SCAN_LINE=1"
    )
    ;;
  diag)
    ENV_NAME="esp32-s3-touch-amoled-175c-diag"
    BUILD_FLAGS+=(
      "-DDRAGON_RADAR_DEBUG_HUD=1"
      "-DDRAGON_RADAR_SCAN_LINE=1"
      "-DDRAGON_RADAR_SERIAL_DIAG=1"
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

append_override "${RADAR_BRIGHTNESS:-}" "DRAGON_RADAR_BRIGHTNESS"
append_override "${AUDIO_GAIN:-}" "DRAGON_RADAR_AUDIO_GAIN"
append_override "${FRAME_MS:-}" "DRAGON_RADAR_FRAME_MS"
append_override "${DISPLAY_BUS_HZ:-}" "DRAGON_RADAR_DISPLAY_BUS_HZ"
append_override "${BOOT_FRAME_DELAY_MS:-}" "DRAGON_RADAR_BOOT_FRAME_DELAY_MS"
append_override "${GRID_SNAP:-}" "DRAGON_RADAR_GRID_SNAP"
append_override "${SERIAL_DIAG:-}" "DRAGON_RADAR_SERIAL_DIAG"

append_string_override() {
  local value="$1"
  local macro="$2"
  if [[ -n "$value" ]]; then
    local escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    BUILD_FLAGS+=("-D${macro}=\\\"${escaped}\\\"")
    CUSTOM_FLAGS=1
  fi
}

append_string_override "${PAIRING_HMAC_KEY:-}" "DRAGON_RADAR_PAIRING_HMAC_KEY"

IDENTITY_EXPLICIT=0
if [[ -n "${DRAGON_RADAR_FIRMWARE_VERSION+x}" ||
      -n "${DRAGON_RADAR_FIRMWARE_BUILD+x}" ||
      -n "${DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER+x}" ]]; then
  IDENTITY_EXPLICIT=1
fi
if [[ "$IDENTITY_EXPLICIT" == "1" ]]; then
  append_string_override "$FIRMWARE_VERSION" "DRAGON_RADAR_FW_VERSION"
  BUILD_FLAGS+=("-DDRAGON_RADAR_FW_BUILD=$FIRMWARE_BUILD")
  BUILD_FLAGS+=("-DDRAGON_RADAR_FW_SECURITY_COUNTER=$FIRMWARE_SECURITY_COUNTER")
  CUSTOM_FLAGS=1
fi
if [[ -n "$OTA_ROOT_CA_B64" ]]; then
  append_string_override "$OTA_ROOT_CA_B64" "DRAGON_RADAR_OTA_ROOT_CA_PEM_B64"
fi
if [[ "$OTA_ALLOW_HTTP" == "1" ]]; then
  BUILD_FLAGS+=("-DDRAGON_RADAR_OTA_ALLOW_HTTP=1")
  CUSTOM_FLAGS=1
fi

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
    echo "board_build.partitions = partitions_dragon_radar_32mb.csv"
    echo "lib_deps ="
    echo "  links2004/WebSockets @ 2.7.3"
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
  REDACTED_BUILD_FLAGS=()
  for flag in "${BUILD_FLAGS[@]}"; do
    if [[ "$flag" == -DDRAGON_RADAR_PAIRING_HMAC_KEY=* ]]; then
      REDACTED_BUILD_FLAGS+=("-DDRAGON_RADAR_PAIRING_HMAC_KEY=<redacted>")
    elif [[ "$flag" == -DDRAGON_RADAR_OTA_ROOT_CA_PEM_B64=* ]]; then
      REDACTED_BUILD_FLAGS+=("-DDRAGON_RADAR_OTA_ROOT_CA_PEM_B64=<redacted-ca>")
    else
      REDACTED_BUILD_FLAGS+=("$flag")
    fi
  done
  echo "Custom build flags: ${REDACTED_BUILD_FLAGS[*]}"
fi
"$PIO_BIN" "${RUN_ARGS[@]}"

BUILD_DIR="${PLATFORMIO_BUILD_DIR:-$ROOT_DIR/.pio/build}/$ENV_NAME"
FIRMWARE_BIN="$BUILD_DIR/firmware.bin"
if [[ ! -f "$FIRMWARE_BIN" ]]; then
  echo "PlatformIO completed but firmware binary is missing: $FIRMWARE_BIN" >&2
  exit 1
fi
if stat -f '%z' "$FIRMWARE_BIN" >/dev/null 2>&1; then
  FIRMWARE_SIZE="$(stat -f '%z' "$FIRMWARE_BIN")"
else
  FIRMWARE_SIZE="$(stat -c '%s' "$FIRMWARE_BIN")"
fi
if command -v shasum >/dev/null 2>&1; then
  FIRMWARE_SHA256="$(shasum -a 256 "$FIRMWARE_BIN" | awk '{print $1}')"
else
  FIRMWARE_SHA256="$(sha256sum "$FIRMWARE_BIN" | awk '{print $1}')"
fi

ROOT_CA_SHA_JSON="\"$OTA_ROOT_CA_SHA256\""
METADATA_PATH="$BUILD_DIR/firmware-metadata.json"
METADATA_TEMP="$(mktemp "$BUILD_DIR/.firmware-metadata.json.XXXXXX")"
printf '{\n  "schema": 1,\n  "product": "dragon-radar",\n  "hardware": "esp32-s3-touch-amoled-1.75c",\n  "version": "%s",\n  "build": %s,\n  "security_counter": %s,\n  "artifact": "firmware.bin",\n  "size": %s,\n  "sha256": "%s",\n  "ota_key_id": "%s",\n  "ota_public_key_sha256": "%s",\n  "ota_allow_http": %s,\n  "ota_root_ca_configured": %s,\n  "ota_root_ca_sha256": %s,\n  "release_build": %s,\n  "environment": "%s"\n}\n' \
  "$FIRMWARE_VERSION" \
  "$FIRMWARE_BUILD" \
  "$FIRMWARE_SECURITY_COUNTER" \
  "$FIRMWARE_SIZE" \
  "$FIRMWARE_SHA256" \
  "$OTA_KEY_ID" \
  "$OTA_PUBLIC_KEY_SHA256" \
  "$([[ "$OTA_ALLOW_HTTP" == "1" ]] && printf true || printf false)" \
  "$OTA_ROOT_CA_CONFIGURED" \
  "$ROOT_CA_SHA_JSON" \
  "$RELEASE_BUILD" \
  "$MODE" > "$METADATA_TEMP"
mv "$METADATA_TEMP" "$METADATA_PATH"
echo "Firmware metadata: $METADATA_PATH"
