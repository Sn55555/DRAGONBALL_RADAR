#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/flash_beacon_set.sh [all|1 2 ... 7]

Uploads numbered DBALL beacon firmware to a set of spare ESP32 boards. Connect
one beacon board at a time; the script prompts before each upload and writes a
small manifest for the finished set.

Environment:
  PIO_BIN               PlatformIO executable, inherited by upload_beacon.sh
  BEACON_BOARD          PlatformIO board id, default: esp32-s3-devkitc1-n8r8
  BEACON_PLATFORM       PlatformIO platform package
  BEACON_PORT           Optional serial upload port, such as /dev/cu.usbmodem101
  BEACON_PROFILE        fast, balanced, or battery; default: balanced
  BEACON_ADV_MIN_MS     Override BLE advertising minimum interval
  BEACON_ADV_MAX_MS     Override BLE advertising maximum interval
  BEACON_SET_MANIFEST   Manifest path, default: output/beacon-set-manifest.md
  BEACON_SET_LOG        Upload log path, default: output/beacon-set-flash.log
  BEACON_SET_ASSUME_YES 1 to skip interactive prompts
  BEACON_SET_DRY_RUN    1 to print/write the planned sequence without uploading
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${BEACON_SET_MANIFEST:-$ROOT_DIR/output/beacon-set-manifest.md}"
LOG_FILE="${BEACON_SET_LOG:-$ROOT_DIR/output/beacon-set-flash.log}"
DRY_RUN="${BEACON_SET_DRY_RUN:-0}"
ASSUME_YES="${BEACON_SET_ASSUME_YES:-0}"

if [[ $# -eq 0 || ( $# -eq 1 && "$1" == "all" ) ]]; then
  INDICES=(1 2 3 4 5 6 7)
else
  INDICES=("$@")
fi

for index in "${INDICES[@]}"; do
  if ! [[ "$index" =~ ^[1-7]$ ]]; then
    usage >&2
    exit 2
  fi
done

if [[ "$DRY_RUN" != "1" && "$ASSUME_YES" != "1" && ! -t 0 ]]; then
  echo "stdin is not interactive; set BEACON_SET_ASSUME_YES=1 or BEACON_SET_DRY_RUN=1" >&2
  exit 2
fi

mkdir -p "$(dirname "$MANIFEST")" "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

profile="${BEACON_PROFILE:-balanced}"
case "$profile" in
  fast)
    default_min=60
    default_max=120
    ;;
  balanced)
    default_min=100
    default_max=200
    ;;
  battery)
    default_min=400
    default_max=900
    ;;
  *)
    echo "BEACON_PROFILE must be fast, balanced, or battery" >&2
    exit 2
    ;;
esac

adv_min="${BEACON_ADV_MIN_MS:-$default_min}"
adv_max="${BEACON_ADV_MAX_MS:-$default_max}"
started="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

{
  echo "# Dragon Ball Beacon Flash Manifest"
  echo
  echo "- Started: $started"
  echo "- Board: ${BEACON_BOARD:-esp32-s3-devkitc1-n8r8}"
  echo "- Port: ${BEACON_PORT:-auto}"
  echo "- Profile: $profile"
  echo "- Advertising interval: ${adv_min}-${adv_max} ms"
  echo "- Dry run: $DRY_RUN"
  echo "- Log: $LOG_FILE"
  echo
  echo "| Beacon | Status |"
  echo "| --- | --- |"
} > "$MANIFEST"

echo "Writing manifest to $MANIFEST"
echo "Writing upload log to $LOG_FILE"

append_manifest() {
  local index="$1"
  local status="$2"
  printf '| DBALL-%s | %s |\n' "$index" "$status" >> "$MANIFEST"
}

prompt_for_board() {
  local index="$1"
  if [[ "$DRY_RUN" == "1" || "$ASSUME_YES" == "1" ]]; then
    return
  fi
  echo
  echo "Connect the ESP32 board that will become DBALL-$index, then press Enter."
  read -r _
}

for index in "${INDICES[@]}"; do
  prompt_for_board "$index"
  echo
  echo "==> DBALL-$index"
  {
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] DBALL-$index start"
    echo "board=${BEACON_BOARD:-esp32-s3-devkitc1-n8r8} port=${BEACON_PORT:-auto} profile=$profile interval=${adv_min}-${adv_max}ms dryRun=$DRY_RUN"
  } >> "$LOG_FILE"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "+ $ROOT_DIR/tools/upload_beacon.sh $index"
    append_manifest "$index" "planned"
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] DBALL-$index planned" >> "$LOG_FILE"
    continue
  fi

  set +e
  "$ROOT_DIR/tools/upload_beacon.sh" "$index" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e
  if [[ "$rc" -ne 0 ]]; then
    append_manifest "$index" "failed rc=$rc"
    echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] DBALL-$index failed rc=$rc" >> "$LOG_FILE"
    echo "Upload failed for DBALL-$index; see $LOG_FILE" >&2
    exit "$rc"
  fi
  append_manifest "$index" "uploaded"
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] DBALL-$index uploaded" >> "$LOG_FILE"
done

echo
echo "Beacon set sequence complete."
echo "$MANIFEST"
