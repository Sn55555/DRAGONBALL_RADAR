#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/waveshare-esp32s3-amoled-175c"
REPO_URL="https://github.com/waveshareteam/ESP32-S3-Touch-AMOLED-1.75C.git"
SRC_LIB_DIR="$WORK_DIR/examples/Arduino-v3.3.5/libraries"

if [ ! -d "$WORK_DIR/.git" ]; then
  rm -rf "$WORK_DIR"
  git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$WORK_DIR"
else
  git -C "$WORK_DIR" fetch --depth 1 --filter=blob:none origin main
  git -C "$WORK_DIR" checkout -q FETCH_HEAD
fi

git -C "$WORK_DIR" sparse-checkout set \
  examples/Arduino-v3.3.5/libraries/GFX_Library_for_Arduino \
  examples/Arduino-v3.3.5/libraries/SensorLib

mkdir -p "$ROOT_DIR/lib"
rm -rf \
  "$ROOT_DIR/lib/GFX_Library_for_Arduino" \
  "$ROOT_DIR/lib/SensorLib"

cp -R "$SRC_LIB_DIR/GFX_Library_for_Arduino" "$ROOT_DIR/lib/"
cp -R "$SRC_LIB_DIR/SensorLib" "$ROOT_DIR/lib/"

python3 - "$ROOT_DIR/lib/GFX_Library_for_Arduino/src/databus" <<'PY'
from pathlib import Path
import sys

databus = Path(sys.argv[1])
replacements = {
    "Arduino_ESP32SPI.cpp": {
        "spiFrequencyToClockDiv(old_apb / ((_spi->dev->clock.clkdiv_pre + 1) * (_spi->dev->clock.clkcnt_n + 1)))":
            "spiFrequencyToClockDiv(_spi, old_apb / ((_spi->dev->clock.clkdiv_pre + 1) * (_spi->dev->clock.clkcnt_n + 1)))",
        "spiFrequencyToClockDiv(_speed)": "spiFrequencyToClockDiv(NULL, _speed)",
    },
    "Arduino_ESP32SPIDMA.cpp": {
        "spiFrequencyToClockDiv(_speed)": "spiFrequencyToClockDiv(NULL, _speed)",
    },
}

for filename, pairs in replacements.items():
    path = databus / filename
    text = path.read_text()
    for old, new in pairs.items():
        text = text.replace(old, new)
    path.write_text(text)
PY

echo "Installed Waveshare Arduino libraries into $ROOT_DIR/lib"
