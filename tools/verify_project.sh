#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/verify_project.sh [quick|firmware|full]

Modes:
  quick     Check current helper syntax and Relay smoke test.
  firmware  quick + ESP field firmware build.
  full      firmware + iOS unit/UI tests + Debug/Release builds without signing and production URL gate.

This verifier follows the current product direction: room-based live location
and ESP push-to-talk voice. The retired physical beacon hunt is not verified.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MODE="${1:-quick}"
case "$MODE" in
  quick|firmware|full)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log_step() {
  printf '\n==> %s\n' "$1"
}

log_step "Checking shell helper syntax"
bash -n \
  tools/build_radar.sh \
  tools/deploy_relay_update.sh \
  tools/flash_release_firmware.sh \
  tools/prepare_release_pairing_key.sh \
  tools/verify_project.sh

log_step "Checking Python helper syntax"
python3 -m py_compile \
  relay/server.py \
  tools/ota_release_common.py \
  tools/package_ota_release.py \
  tools/verify_ota_release.py \
  tools/verify_ota_contract.py \
  tools/test_gateway_voice.py \
  tools/smoke_esp_provisioning_ble.py \
  tools/smoke_relay.py \
  tools/smoke_relay_limits.py \
  tools/simulate_mac_room_member.py \
  tools/list_radar_ports.py \
  tools/wait_for_radar_port.py \
  tools/diagnose_usb_serial.py

log_step "Checking BLE ADPCM codec and phone-gateway Relay state machine"
(
  VOICE_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dragon-radar-voice-test.XXXXXX")"
  trap 'rm -rf "$VOICE_TEST_ROOT"' EXIT
  "${CXX:-c++}" -std=c++17 -Wall -Wextra -pedantic \
    tools/test_voice_adpcm.cpp -o "$VOICE_TEST_ROOT/test_voice_adpcm"
  "$VOICE_TEST_ROOT/test_voice_adpcm"
)
python3 tools/test_gateway_voice.py

log_step "Checking retired character and virtual-pet content"
for forbidden_path in \
  assets/avatar_badges \
  assets/pixel_sprites \
  firmware/DragonRadar/beach_scene_assets.h \
  firmware/DragonRadar/easter_badge.h \
  firmware/DragonRadar/private_boot_logo.h.example \
  tmp/login_font_options.png \
  tmp/login_tall_font_options.png \
  tools/generate_beach_scene_assets.py \
  tools/install_private_boot_logo.py \
  tools/verify_beach_scene.py \
  tools/verify_private_boot_logo.py; do
  if [[ -e "$forbidden_path" ]]; then
    echo "Removed character/virtual-pet content returned: $forbidden_path" >&2
    exit 1
  fi
done

if rg -n -i \
  '(tamagotchi|拓麻歌子|pixel[ _-]?(pet|sprite)|beach[ _-]?scene|avatar[ _-]?badge|summon|goku|krillin|popo|七龙珠|龙珠|easter[ _-]?(mode|egg|badge)|private[ _-]?boot[ _-]?logo|DRAGON_RADAR_STAR_BLIPS|drawCapsuleLogo|drawMemberCapsule|RetiredTarget|kRetiredTarget|activeTargetCount|collectedTargetCount|strongestActiveTargetIndex|clearRetiredTargetState|reset(All)?TargetTrails|drawRssiCalibrationStrip|drawBearingCalibrationStrip|initTargets)' \
  firmware/DragonRadar \
  ios/DragonRadarMVP/DragonRadarMVP \
  preview \
  tools/build_radar.sh \
  platformio.ini; then
  echo "Character, virtual-pet, hidden-easter-egg, or retired visual code remains." >&2
  exit 1
fi

if rg -n '(隐藏彩蛋入口|斜向胶囊|胶囊形(目标|标记))' docs/esp-radar-ui-spec.zh.md; then
  echo "Retired capsule-shaped target or hidden-easter specification remains." >&2
  exit 1
fi
echo "removed-character-and-virtual-pet-content-ok"

log_step "Checking BLE transport security contract"
for required_firmware_security_marker in \
  '#include <BLESecurity.h>' \
  'security->setPassKey(false);' \
  'security->regenPassKeyOnConnect(true);' \
  'security->setCapability(ESP_IO_CAP_OUT);' \
  'security->setAuthenticationMode(true, true, true);' \
  'BLECharacteristic::PROPERTY_READ_AUTHEN' \
  'BLECharacteristic::PROPERTY_WRITE_AUTHEN' \
  'ESP_GATT_PERM_READ_ENC_MITM' \
  'ESP_GATT_PERM_WRITE_ENC_MITM' \
  'ble_link_authenticated'; do
  grep -Fq "$required_firmware_security_marker" firmware/DragonRadar/DragonRadar.ino || {
    echo "Missing BLE security marker: $required_firmware_security_marker" >&2
    exit 1
  }
done
grep -Fq 'bleSecure = "ble_secure"' ios/DragonRadarMVP/DragonRadarMVP/Sources/BLEDeviceBridge.swift || {
  echo "iOS does not decode the authenticated BLE-link state." >&2
  exit 1
}
grep -Fq '首次连接成功后，以后会自动连接。' ios/DragonRadarMVP/DragonRadarMVP/Sources/DevicesView.swift || {
  echo "iOS pairing UI does not explain first-time scan and automatic reconnection." >&2
  exit 1
}
for required_owner_release_marker in \
  'kOwnerBleServiceUuid' \
  'prepare_release' \
  'commit_release' \
  'release_committed'; do
  grep -Fq "$required_owner_release_marker" firmware/DragonRadar/DragonRadar.ino || {
    echo "Missing owner-release firmware marker: $required_owner_release_marker" >&2
    exit 1
  }
done
grep -Fq 'devices.ownership.release' ios/DragonRadarMVP/DragonRadarMVP/Sources/DevicesView.swift || {
  echo "iOS owner-release action is missing." >&2
  exit 1
}
echo "ble-transport-security-contract-ok"

log_step "Checking heading alignment math"
(
  HEADING_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dragon-radar-heading-test.XXXXXX")"
  trap 'rm -rf "$HEADING_TEST_ROOT"' EXIT
  "${CXX:-c++}" \
    -std=c++17 \
    -Wall \
    -Wextra \
    -Werror \
    -pedantic \
    -Ifirmware/DragonRadar \
    tools/test_heading_alignment.cpp \
    -o "$HEADING_TEST_ROOT/test_heading_alignment"
  "$HEADING_TEST_ROOT/test_heading_alignment"
)

log_step "Checking stationary heading stability"
(
  HEADING_STABILITY_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dragon-radar-heading-stability-test.XXXXXX")"
  trap 'rm -rf "$HEADING_STABILITY_TEST_ROOT"' EXIT
  "${CXX:-c++}" \
    -std=c++17 \
    -Wall \
    -Wextra \
    -Werror \
    -pedantic \
    -Ifirmware/DragonRadar \
    tools/test_heading_stability.cpp \
    -o "$HEADING_STABILITY_TEST_ROOT/test_heading_stability"
  "$HEADING_STABILITY_TEST_ROOT/test_heading_stability"
)

log_step "Checking display orientation and touch mapping"
(
  ORIENTATION_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dragon-radar-orientation-test.XXXXXX")"
  trap 'rm -rf "$ORIENTATION_TEST_ROOT"' EXIT
  "${CXX:-c++}" \
    -std=c++17 \
    -Wall \
    -Wextra \
    -Werror \
    -pedantic \
    -Ifirmware/DragonRadar \
    tools/test_display_orientation.cpp \
    -o "$ORIENTATION_TEST_ROOT/test_display_orientation"
  "$ORIENTATION_TEST_ROOT/test_display_orientation"
)

log_step "Checking Relay limit primitives"
python3 tools/smoke_relay_limits.py

log_step "Checking release pairing key preflight"
tools/prepare_release_pairing_key.sh self-test

log_step "Checking cross-component OTA security contract"
python3 tools/verify_ota_contract.py

log_step "Checking signed OTA release tooling"
OTA_SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dragon-radar-ota-smoke.XXXXXX")"
OTA_SMOKE_FIRMWARE="$OTA_SMOKE_ROOT/firmware.bin"
OTA_SMOKE_PRIVATE_KEY="$OTA_SMOKE_ROOT/private.pem"
OTA_SMOKE_PUBLIC_KEY="$OTA_SMOKE_ROOT/public.pem"
OTA_SMOKE_WRONG_PRIVATE_KEY="$OTA_SMOKE_ROOT/wrong-private.pem"
OTA_SMOKE_WRONG_PUBLIC_KEY="$OTA_SMOKE_ROOT/wrong-public.pem"
OTA_SMOKE_RELEASE="$OTA_SMOKE_ROOT/release"
OTA_SMOKE_RETENTION_RELEASE="$OTA_SMOKE_ROOT/retention-release"
OTA_SMOKE_RETENTION_FIRMWARE="$OTA_SMOKE_ROOT/retention-next/firmware.bin"
OTA_SMOKE_TAMPERED="$OTA_SMOKE_ROOT/tampered"
OTA_SMOKE_BAD_SIGNATURE="$OTA_SMOKE_ROOT/bad-signature"
cleanup_ota() {
  rm -rf "$OTA_SMOKE_ROOT"
}
trap cleanup_ota EXIT
python3 - "$OTA_SMOKE_FIRMWARE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
payload = b"\xe9" + bytes(index % 251 for index in range(4096))
path.write_bytes(payload)
PY
openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -pkeyopt ec_param_enc:named_curve \
  -out "$OTA_SMOKE_PRIVATE_KEY" \
  >/dev/null 2>&1
openssl pkey \
  -in "$OTA_SMOKE_PRIVATE_KEY" \
  -pubout \
  -out "$OTA_SMOKE_PUBLIC_KEY" \
  >/dev/null 2>&1
openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -pkeyopt ec_param_enc:named_curve \
  -out "$OTA_SMOKE_WRONG_PRIVATE_KEY" \
  >/dev/null 2>&1
openssl pkey \
  -in "$OTA_SMOKE_WRONG_PRIVATE_KEY" \
  -pubout \
  -out "$OTA_SMOKE_WRONG_PUBLIC_KEY" \
  >/dev/null 2>&1
python3 - "$OTA_SMOKE_FIRMWARE" "$OTA_SMOKE_PUBLIC_KEY" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

firmware = Path(sys.argv[1])
public_key = Path(sys.argv[2])
sys.path.insert(0, str(Path.cwd() / "tools"))
from ota_release_common import public_key_spki_sha256

payload = firmware.read_bytes()
metadata = {
    "schema": 1,
    "product": "dragon-radar",
    "hardware": "esp32-s3-touch-amoled-1.75c",
    "version": "9.9.9",
    "build": 999,
    "security_counter": 999,
    "artifact": firmware.name,
    "size": len(payload),
    "sha256": hashlib.sha256(payload).hexdigest(),
    "environment": "field",
    "ota_key_id": "local-2026-01",
    "ota_public_key_sha256": public_key_spki_sha256(public_key),
    "ota_allow_http": False,
    "release_build": True,
    "ota_root_ca_configured": True,
    "ota_root_ca_sha256": hashlib.sha256(b"ota-smoke-root-ca").hexdigest(),
}
firmware.with_name("firmware-metadata.json").write_text(
    json.dumps(metadata, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY
python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_FIRMWARE" \
  --output-dir "$OTA_SMOKE_RELEASE" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 9.9.9 \
  --build 999 \
  --minimum-version 0.0.0 \
  --security-counter 999 \
  --max-size 8192
python3 tools/verify_ota_release.py \
  "$OTA_SMOKE_RELEASE" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --max-size 8192
python3 - "$OTA_SMOKE_RELEASE" <<'PY'
import json
from pathlib import Path
import sys

release = Path(sys.argv[1])
canonical = (release / "canonical.txt").read_bytes()
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
assert not canonical.startswith(b"\xef\xbb\xbf")
assert not canonical.endswith(b"\n")
assert canonical.decode("utf-8") == manifest["signed_payload"]
assert manifest["hardware"] == "esp32-s3-touch-amoled-1.75c"
sys.path.insert(0, str(Path.cwd() / "tools"))
from ota_release_common import OTAReleaseError, canonical_payload

for field_name, invalid_value in (
    ("version", "1.0.0-rc.1"),
    ("version", "4294967296.0.0"),
    ("minimum_version", "0.0.0+bootstrap"),
    ("security_counter", 0),
    ("security_counter", 4294967296),
    ("build", 4294967296),
):
    invalid = dict(manifest)
    invalid[field_name] = invalid_value
    try:
        canonical_payload(invalid)
    except OTAReleaseError:
        pass
    else:
        raise AssertionError(f"invalid {field_name} passed canonical validation")
invalid_range = dict(manifest)
invalid_range["version"] = "1.0.0"
invalid_range["minimum_version"] = "2.0.0"
try:
    canonical_payload(invalid_range)
except OTAReleaseError:
    pass
else:
    raise AssertionError("target version lower than minimum_version passed validation")
PY
cp -R "$OTA_SMOKE_RELEASE" "$OTA_SMOKE_TAMPERED"
python3 - "$OTA_SMOKE_TAMPERED" <<'PY'
import json
from pathlib import Path
import sys

release = Path(sys.argv[1])
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
artifact = release / manifest["artifact"]
payload = bytearray(artifact.read_bytes())
payload[-1] ^= 0x01
artifact.write_bytes(payload)
PY
if python3 tools/verify_ota_release.py \
  "$OTA_SMOKE_TAMPERED" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --max-size 8192 \
  >/dev/null 2>&1; then
  echo "Tampered OTA artifact unexpectedly passed verification." >&2
  exit 1
fi
echo "ota-artifact-tamper-rejection-ok"
cp -R "$OTA_SMOKE_RELEASE" "$OTA_SMOKE_BAD_SIGNATURE"
python3 - "$OTA_SMOKE_BAD_SIGNATURE" <<'PY'
import base64
import json
from pathlib import Path
import sys

release = Path(sys.argv[1])
manifest_path = release / "manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
signature = bytearray(base64.b64decode(manifest["signature"], validate=True))
signature[-1] ^= 0x01
manifest["signature"] = base64.b64encode(signature).decode("ascii")
manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
PY
if python3 tools/verify_ota_release.py \
  "$OTA_SMOKE_BAD_SIGNATURE" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --max-size 8192 \
  >/dev/null 2>&1; then
  echo "Tampered OTA signature unexpectedly passed verification." >&2
  exit 1
fi
echo "ota-signature-tamper-rejection-ok"
if python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_FIRMWARE" \
  --output-dir "$OTA_SMOKE_ROOT/invalid-prerelease" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 1.0.0-rc.1 \
  --build 1000 \
  --minimum-version 0.0.0 \
  --security-counter 1000 \
  --max-size 8192 \
  >/dev/null 2>&1; then
  echo "Prerelease OTA version unexpectedly passed packaging." >&2
  exit 1
fi
if python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_FIRMWARE" \
  --output-dir "$OTA_SMOKE_ROOT/invalid-build-metadata" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 1.0.0 \
  --build 1001 \
  --minimum-version 0.0.0+bootstrap \
  --security-counter 1001 \
  --max-size 8192 \
  >/dev/null 2>&1; then
  echo "OTA minimum_version build metadata unexpectedly passed packaging." >&2
  exit 1
fi
echo "ota-release-field-contract-ok"
mkdir -p "$OTA_SMOKE_ROOT/missing-metadata"
cp "$OTA_SMOKE_FIRMWARE" "$OTA_SMOKE_ROOT/missing-metadata/firmware.bin"
if python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_ROOT/missing-metadata/firmware.bin" \
  --output-dir "$OTA_SMOKE_ROOT/missing-metadata-release" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 9.9.9 \
  --build 999 \
  --minimum-version 0.0.0 \
  --security-counter 999 \
  --max-size 8192 \
  >/dev/null 2>&1; then
  echo "OTA firmware without build metadata unexpectedly passed packaging." >&2
  exit 1
fi
mkdir -p "$OTA_SMOKE_ROOT/hash-mismatch"
cp "$OTA_SMOKE_FIRMWARE" "$OTA_SMOKE_ROOT/hash-mismatch/firmware.bin"
cp "$OTA_SMOKE_ROOT/firmware-metadata.json" "$OTA_SMOKE_ROOT/hash-mismatch/firmware-metadata.json"
python3 - "$OTA_SMOKE_ROOT/hash-mismatch/firmware.bin" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
payload = bytearray(path.read_bytes())
payload[-1] ^= 0x01
path.write_bytes(payload)
PY
if python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_ROOT/hash-mismatch/firmware.bin" \
  --output-dir "$OTA_SMOKE_ROOT/hash-mismatch-release" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 9.9.9 \
  --build 999 \
  --minimum-version 0.0.0 \
  --security-counter 999 \
  --max-size 8192 \
  >/dev/null 2>&1; then
  echo "OTA firmware hash mismatch unexpectedly passed packaging." >&2
  exit 1
fi
echo "ota-binary-metadata-binding-ok"
if python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_FIRMWARE" \
  --output-dir "$OTA_SMOKE_ROOT/wrong-key-release" \
  --private-key "$OTA_SMOKE_WRONG_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_WRONG_PUBLIC_KEY" \
  --version 9.9.9 \
  --build 999 \
  --minimum-version 0.0.0 \
  --security-counter 999 \
  --max-size 8192 \
  >/dev/null 2>&1; then
  echo "OTA release signed by a non-embedded key unexpectedly passed packaging." >&2
  exit 1
fi
echo "ota-embedded-trust-key-binding-ok"
mkdir -p \
  "$OTA_SMOKE_ROOT/unusable-transport" \
  "$OTA_SMOKE_ROOT/development-http" \
  "$OTA_SMOKE_ROOT/development-pairing" \
  "$OTA_SMOKE_ROOT/wrong-environment"
cp "$OTA_SMOKE_FIRMWARE" "$OTA_SMOKE_ROOT/unusable-transport/firmware.bin"
cp "$OTA_SMOKE_ROOT/firmware-metadata.json" "$OTA_SMOKE_ROOT/unusable-transport/firmware-metadata.json"
cp "$OTA_SMOKE_FIRMWARE" "$OTA_SMOKE_ROOT/development-http/firmware.bin"
cp "$OTA_SMOKE_ROOT/firmware-metadata.json" "$OTA_SMOKE_ROOT/development-http/firmware-metadata.json"
cp "$OTA_SMOKE_FIRMWARE" "$OTA_SMOKE_ROOT/development-pairing/firmware.bin"
cp "$OTA_SMOKE_ROOT/firmware-metadata.json" "$OTA_SMOKE_ROOT/development-pairing/firmware-metadata.json"
cp "$OTA_SMOKE_FIRMWARE" "$OTA_SMOKE_ROOT/wrong-environment/firmware.bin"
cp "$OTA_SMOKE_ROOT/firmware-metadata.json" "$OTA_SMOKE_ROOT/wrong-environment/firmware-metadata.json"
python3 - \
  "$OTA_SMOKE_ROOT/unusable-transport/firmware-metadata.json" \
  "$OTA_SMOKE_ROOT/development-http/firmware-metadata.json" \
  "$OTA_SMOKE_ROOT/development-pairing/firmware-metadata.json" \
  "$OTA_SMOKE_ROOT/wrong-environment/firmware-metadata.json" <<'PY'
import json
from pathlib import Path
import sys

unusable_path = Path(sys.argv[1])
unusable = json.loads(unusable_path.read_text(encoding="utf-8"))
unusable["ota_allow_http"] = False
unusable["ota_root_ca_configured"] = False
unusable["ota_root_ca_sha256"] = ""
unusable_path.write_text(json.dumps(unusable), encoding="utf-8")

development_path = Path(sys.argv[2])
development = json.loads(development_path.read_text(encoding="utf-8"))
development["ota_allow_http"] = True
development["ota_root_ca_configured"] = False
development["ota_root_ca_sha256"] = ""
development["release_build"] = False
development_path.write_text(json.dumps(development), encoding="utf-8")

development_pairing_path = Path(sys.argv[3])
development_pairing = json.loads(development_pairing_path.read_text(encoding="utf-8"))
development_pairing["release_build"] = False
development_pairing_path.write_text(json.dumps(development_pairing), encoding="utf-8")

wrong_environment_path = Path(sys.argv[4])
wrong_environment = json.loads(wrong_environment_path.read_text(encoding="utf-8"))
wrong_environment["environment"] = "beach"
wrong_environment_path.write_text(json.dumps(wrong_environment), encoding="utf-8")
PY
if python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_ROOT/unusable-transport/firmware.bin" \
  --output-dir "$OTA_SMOKE_ROOT/unusable-transport-release" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 9.9.9 --build 999 --minimum-version 0.0.0 --security-counter 999 --max-size 8192 \
  >/dev/null 2>&1; then
  echo "OTA firmware without CA or development HTTP unexpectedly passed packaging." >&2
  exit 1
fi
if python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_ROOT/development-http/firmware.bin" \
  --output-dir "$OTA_SMOKE_ROOT/development-http-rejected" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 9.9.9 --build 999 --minimum-version 0.0.0 --security-counter 999 --max-size 8192 \
  >/dev/null 2>&1; then
  echo "Development HTTP OTA firmware unexpectedly passed stable packaging." >&2
  exit 1
fi
if python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_ROOT/development-pairing/firmware.bin" \
  --output-dir "$OTA_SMOKE_ROOT/development-pairing-release" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 9.9.9 --build 999 --minimum-version 0.0.0 --security-counter 999 --max-size 8192 \
  >/dev/null 2>&1; then
  echo "OTA firmware built without RADAR_RELEASE unexpectedly passed stable packaging." >&2
  exit 1
fi
if python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_ROOT/wrong-environment/firmware.bin" \
  --output-dir "$OTA_SMOKE_ROOT/wrong-environment-release" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 9.9.9 --build 999 --minimum-version 0.0.0 --security-counter 999 --max-size 8192 \
  >/dev/null 2>&1; then
  echo "Non-field OTA firmware unexpectedly passed stable packaging." >&2
  exit 1
fi
python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_ROOT/development-http/firmware.bin" \
  --output-dir "$OTA_SMOKE_ROOT/development-http-release" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 9.9.9 --build 999 --minimum-version 0.0.0 --security-counter 999 --max-size 8192 \
  --allow-development-http \
  >/dev/null
echo "ota-release-and-transport-readiness-gate-ok"
DRAGON_RADAR_FIRMWARE_RELEASE_DIR="$OTA_SMOKE_ROOT/development-http-release" \
DRAGON_RADAR_OTA_PUBLIC_KEY="$OTA_SMOKE_PUBLIC_KEY" \
python3 - <<'PY'
import os

from relay.server import FirmwareReleaseStore, FirmwareReleaseUnavailable

try:
    FirmwareReleaseStore().current()
except FirmwareReleaseUnavailable:
    pass
else:
    raise AssertionError("Relay accepted a development OTA without explicit opt-in")

os.environ["DRAGON_RADAR_ALLOW_DEVELOPMENT_OTA"] = "1"
release = FirmwareReleaseStore().current()
assert release.build_metadata["release_build"] is False
assert release.build_metadata["ota_allow_http"] is True
PY
echo "relay-development-ota-policy-ok"
python3 - \
  "$OTA_SMOKE_ROOT" \
  "$OTA_SMOKE_FIRMWARE" \
  "$OTA_SMOKE_PRIVATE_KEY" \
  "$OTA_SMOKE_PUBLIC_KEY" <<'PY'
from argparse import Namespace
from pathlib import Path
import sys
from unittest import mock

root = Path(sys.argv[1]).resolve()
firmware = Path(sys.argv[2]).resolve()
private_key = Path(sys.argv[3]).resolve()
public_key = Path(sys.argv[4]).resolve()
sys.path.insert(0, str(Path.cwd() / "tools"))
from package_ota_release import package

output = root / "atomic-current"
output.mkdir()
sentinel = output / "sentinel.txt"
sentinel.write_text("previous release", encoding="utf-8")
args = Namespace(
    firmware=firmware,
    output_dir=output,
    private_key=private_key,
    public_key=public_key,
    product="dragon-radar",
    hardware="esp32-s3-touch-amoled-1.75c",
    version="9.9.9",
    build=999,
    minimum_version="0.0.0",
    security_counter=999,
    max_size=8192,
    force=True,
)
real_replace = Path.replace


def fail_publish_replace(path: Path, target: Path) -> Path:
    target = Path(target)
    if (
        path.parent == output.parent
        and path.name.startswith(f".{output.name}.")
        and target == output
    ):
        raise OSError("injected publish failure")
    return real_replace(path, target)


try:
    with mock.patch.object(Path, "replace", new=fail_publish_replace):
        package(args)
except OSError as exc:
    assert str(exc) == "injected publish failure"
else:
    raise AssertionError("injected publish failure did not fire")

assert sentinel.read_text(encoding="utf-8") == "previous release"
assert not output.with_name(output.name + ".previous").exists()
print("ota-atomic-publish-restore-ok")
PY

log_step "Checking immutable OTA artifact retention"
cp -R "$OTA_SMOKE_RELEASE" "$OTA_SMOKE_RETENTION_RELEASE"
mkdir -p "$(dirname "$OTA_SMOKE_RETENTION_FIRMWARE")"
cp "$OTA_SMOKE_FIRMWARE" "$OTA_SMOKE_RETENTION_FIRMWARE"
cp "$OTA_SMOKE_ROOT/firmware-metadata.json" "$(dirname "$OTA_SMOKE_RETENTION_FIRMWARE")/firmware-metadata.json"
python3 - \
  "$(dirname "$OTA_SMOKE_RETENTION_FIRMWARE")/firmware-metadata.json" \
  "$OTA_SMOKE_RETENTION_FIRMWARE" <<'PY'
import hashlib
import json
from pathlib import Path
import sys

metadata_path = Path(sys.argv[1])
firmware_path = Path(sys.argv[2])
payload = bytearray(firmware_path.read_bytes())
payload[-1] ^= 0x02
firmware_path.write_bytes(payload)
metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
metadata["version"] = "10.0.0"
metadata["build"] = 1000
metadata["security_counter"] = 1000
metadata["size"] = len(payload)
metadata["sha256"] = hashlib.sha256(payload).hexdigest()
metadata_path.write_text(json.dumps(metadata, sort_keys=True) + "\n", encoding="utf-8")
PY
OTA_SMOKE_RETAINED_ARTIFACT="$(python3 - "$OTA_SMOKE_RELEASE" <<'PY'
import json
from pathlib import Path
import sys

release = Path(sys.argv[1])
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
print(manifest["artifact"])
PY
)"
OTA_SMOKE_RETAINED_SHA256="$(python3 - "$OTA_SMOKE_RELEASE" <<'PY'
import json
from pathlib import Path
import sys

release = Path(sys.argv[1])
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
print(manifest["sha256"])
PY
)"
OTA_SMOKE_RETAINED_SIZE="$(python3 - "$OTA_SMOKE_RELEASE" <<'PY'
import json
from pathlib import Path
import sys

release = Path(sys.argv[1])
manifest = json.loads((release / "manifest.json").read_text(encoding="utf-8"))
print(manifest["size"])
PY
)"
python3 tools/package_ota_release.py \
  --firmware "$OTA_SMOKE_RETENTION_FIRMWARE" \
  --output-dir "$OTA_SMOKE_RETENTION_RELEASE" \
  --private-key "$OTA_SMOKE_PRIVATE_KEY" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --version 10.0.0 \
  --build 1000 \
  --minimum-version 0.0.0 \
  --security-counter 1000 \
  --max-size 8192 \
  --retain-releases 3 \
  --force
python3 tools/verify_ota_release.py \
  "$OTA_SMOKE_RETENTION_RELEASE" \
  --public-key "$OTA_SMOKE_PUBLIC_KEY" \
  --max-size 8192
python3 - \
  "$OTA_SMOKE_RETENTION_RELEASE" \
  "$OTA_SMOKE_PUBLIC_KEY" \
  "$OTA_SMOKE_RETAINED_ARTIFACT" \
  "$OTA_SMOKE_RETAINED_SHA256" <<'PY'
import json
import os
from pathlib import Path
import shutil
import sys

release_root = Path(sys.argv[1]).resolve()
public_key = Path(sys.argv[2]).resolve()
retained_name = sys.argv[3]
retained_sha256 = sys.argv[4]
current = json.loads((release_root / "manifest.json").read_text(encoding="utf-8"))
assert current["version"] == "10.0.0"
assert current["artifact"] != retained_name
assert current["sha256"] in current["artifact"]
retained_root = release_root / "retained" / retained_name
retained = json.loads((retained_root / "manifest.json").read_text(encoding="utf-8"))
assert retained["artifact"] == retained_name
assert retained["sha256"] == retained_sha256
assert retained_sha256 in retained_name

os.environ["DRAGON_RADAR_FIRMWARE_RELEASE_DIR"] = str(release_root)
os.environ["DRAGON_RADAR_OTA_PUBLIC_KEY"] = str(public_key)
from relay.server import FirmwareReleaseStore, FirmwareReleaseUnavailable

store = FirmwareReleaseStore()
assert store.current().manifest["version"] == "10.0.0"
historical = store.artifact(retained_name)
assert historical is not None
assert historical.manifest["sha256"] == retained_sha256
assert store.artifact("dragon-radar-missing.bin") is None

tampered_root = release_root.parent / "retained-policy-tampered"
shutil.copytree(release_root, tampered_root)
tampered_metadata_path = tampered_root / "retained" / retained_name / "build-metadata.json"
tampered_metadata = json.loads(tampered_metadata_path.read_text(encoding="utf-8"))
tampered_metadata["release_build"] = False
tampered_metadata_path.write_text(json.dumps(tampered_metadata), encoding="utf-8")
os.environ["DRAGON_RADAR_FIRMWARE_RELEASE_DIR"] = str(tampered_root)
tampered_store = FirmwareReleaseStore()
assert tampered_store.current().manifest["version"] == "10.0.0"
try:
    tampered_store.artifact(retained_name)
except FirmwareReleaseUnavailable:
    pass
else:
    raise AssertionError("Relay accepted retained artifact with downgraded metadata policy")
print("ota-immutable-retention-ok")
PY
python3 - \
  "$OTA_SMOKE_ROOT" \
  "$OTA_SMOKE_FIRMWARE" \
  "$OTA_SMOKE_PRIVATE_KEY" \
  "$OTA_SMOKE_PUBLIC_KEY" <<'PY'
from argparse import Namespace
import hashlib
import json
from pathlib import Path
import shutil
import sys

root = Path(sys.argv[1]).resolve()
source_firmware = Path(sys.argv[2]).resolve()
private_key = Path(sys.argv[3]).resolve()
public_key = Path(sys.argv[4]).resolve()
work = root / "bounded-retention-source"
work.mkdir()
firmware = work / "firmware.bin"
metadata_path = work / "firmware-metadata.json"
shutil.copyfile(source_firmware, firmware)
baseline = json.loads(source_firmware.with_name("firmware-metadata.json").read_text(encoding="utf-8"))
output = root / "bounded-retention-release"

sys.path.insert(0, str(Path.cwd() / "tools"))
from package_ota_release import package
from verify_ota_release import verify

for offset, build in enumerate(range(2001, 2006), start=1):
    version = f"20.0.{offset}"
    payload = bytearray(source_firmware.read_bytes())
    payload[-1] = (payload[-1] + offset) % 256
    firmware.write_bytes(payload)
    metadata = dict(baseline)
    metadata["version"] = version
    metadata["build"] = build
    metadata["security_counter"] = build
    metadata["size"] = len(payload)
    metadata["sha256"] = hashlib.sha256(payload).hexdigest()
    metadata_path.write_text(json.dumps(metadata, sort_keys=True) + "\n", encoding="utf-8")
    package(
        Namespace(
            firmware=firmware,
            firmware_metadata=metadata_path,
            output_dir=output,
            private_key=private_key,
            public_key=public_key,
            product="dragon-radar",
            hardware="esp32-s3-touch-amoled-1.75c",
            version=version,
            build=build,
            minimum_version="0.0.0",
            security_counter=build,
            max_size=8192,
            retain_releases=3,
            allow_development_http=False,
            force=output.exists(),
        )
    )

report = verify(output, public_key, 8192)
assert report["build"] == 2005
retained_builds = sorted(int(item["build"]) for item in report["retained_releases"])
assert retained_builds == [2002, 2003, 2004], retained_builds
assert len(list((output / "retained").iterdir())) == 3

from ota_release_common import OTAReleaseError
current_payload = firmware.read_bytes()

def expect_publish_rejected(version, build, security_counter, expected_text, marker):
    payload = bytearray(current_payload if marker == 0 else source_firmware.read_bytes())
    if marker != 0:
        payload[-1] = (payload[-1] + marker) % 256
    firmware.write_bytes(payload)
    metadata = dict(baseline)
    metadata["version"] = version
    metadata["build"] = build
    metadata["security_counter"] = security_counter
    metadata["size"] = len(payload)
    metadata["sha256"] = hashlib.sha256(payload).hexdigest()
    metadata_path.write_text(json.dumps(metadata, sort_keys=True) + "\n", encoding="utf-8")
    try:
        package(
            Namespace(
                firmware=firmware,
                firmware_metadata=metadata_path,
                output_dir=output,
                private_key=private_key,
                public_key=public_key,
                product="dragon-radar",
                hardware="esp32-s3-touch-amoled-1.75c",
                version=version,
                build=build,
                minimum_version="0.0.0",
                security_counter=security_counter,
                max_size=8192,
                retain_releases=3,
                allow_development_http=False,
                force=True,
            )
        )
    except OTAReleaseError as exc:
        assert expected_text in str(exc), str(exc)
    else:
        raise AssertionError(f"publish rollback gate accepted {version}/{build}/{security_counter}")

expect_publish_rejected("20.0.6", 2006, 2006, "immutable firmware digest", 0)
expect_publish_rejected("20.0.6", 2005, 2006, "new build must be greater", 21)
expect_publish_rejected("20.0.6", 2006, 2000, "security_counter must not be lower", 22)
expect_publish_rejected("19.9.9", 2006, 2006, "new version must not be lower", 23)
assert verify(output, public_key, 8192)["build"] == 2005
print("ota-retention-boundary-ok")
PY

log_step "Checking Relay smoke test"
python3 - <<'PY'
import tempfile
import time
from pathlib import Path

from relay.server import RelayStore

now = int(time.time())
old = now - 400 * 24 * 60 * 60
with tempfile.TemporaryDirectory(prefix="capsule-retention-") as directory:
    store = RelayStore(str(Path(directory) / "retention.sqlite3"))
    with store.lock, store.db:
        store.db.execute(
            "INSERT INTO audit_events VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            ("evt_old", "test", "", "", "", "", "{}", old),
        )
        store.db.execute(
            "INSERT INTO diagnostics_reports VALUES (?, ?, ?, ?, ?)",
            ("diag_old", "user", "", "{}", old),
        )
        store.db.execute(
            "INSERT INTO radar_reminders VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("rem_old", "request-old", "CAPS-TEST", "user", 0, 0, "done", old, old),
        )
        store.db.execute(
            "INSERT INTO content_reports VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("report_old", "DR-OLD", "user", "other", "CAPS-TEST", "other", "other", "", "received", old),
        )
        store.db.execute(
            "INSERT INTO auth_tokens VALUES (?, ?, ?, ?, ?, ?)",
            ("access_old", "refresh_old", "user", old, old, old),
        )
        store.db.execute(
            "INSERT INTO room_invites VALUES (?, ?, ?, ?, ?)",
            ("invite_old", "CAPS-TEST", "user", old, old),
        )
    deleted = store.prune_retained_data(force=True, now=now)
    assert deleted == {
        "diagnostics_reports": 1,
        "audit_events": 1,
        "radar_reminders": 1,
        "content_reports": 1,
        "auth_tokens": 1,
        "room_invites": 1,
    }, deleted
    for table in (
        "diagnostics_reports",
        "audit_events",
        "radar_reminders",
        "content_reports",
        "auth_tokens",
        "room_invites",
    ):
        assert store.db.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0, table
    store.db.close()
print("relay-retention-cleanup-ok")
PY
RELAY_SMOKE_PORT="${RELAY_SMOKE_PORT:-18787}"
RELAY_SMOKE_HTTP_PORT="${RELAY_SMOKE_HTTP_PORT:-18788}"
RELAY_SMOKE_DB="$(mktemp "${TMPDIR:-/tmp}/dragon-radar-relay-smoke.XXXXXX.sqlite3")"
DRAGON_RADAR_ALLOW_DEVELOPMENT_AUTH=1 \
DRAGON_RADAR_APPLE_AUDIENCE=com.sn5.DragonRadarMVP \
DRAGON_RADAR_APNS_MODE=dry_run \
DRAGON_RADAR_LOCATION_STALE_SECONDS=1 \
DRAGON_RADAR_FIRMWARE_RELEASE_DIR="$OTA_SMOKE_RETENTION_RELEASE" \
DRAGON_RADAR_OTA_PUBLIC_KEY="$OTA_SMOKE_PUBLIC_KEY" \
python3 relay/server.py \
  --host 127.0.0.1 \
  --port "$RELAY_SMOKE_PORT" \
  --http-port "$RELAY_SMOKE_HTTP_PORT" \
  --db-path "$RELAY_SMOKE_DB" \
  >/tmp/dragon-radar-relay-smoke.log 2>&1 &
relay_pid=$!
cleanup_relay() {
  if [[ -n "${relay_pid:-}" ]]; then
    kill "$relay_pid" >/dev/null 2>&1 || true
    wait "$relay_pid" >/dev/null 2>&1 || true
    relay_pid=""
  fi
  rm -f "$RELAY_SMOKE_DB" "$RELAY_SMOKE_DB-shm" "$RELAY_SMOKE_DB-wal"
}
cleanup_smoke() {
  cleanup_relay
  cleanup_ota
}
trap cleanup_smoke EXIT
sleep 0.6
python3 tools/smoke_relay.py \
  --url "ws://127.0.0.1:$RELAY_SMOKE_PORT" \
  --http-url "http://127.0.0.1:$RELAY_SMOKE_HTTP_PORT" \
  --expect-firmware \
  --expect-retained-artifact "$OTA_SMOKE_RETAINED_ARTIFACT" \
  --expect-retained-sha256 "$OTA_SMOKE_RETAINED_SHA256" \
  --expect-retained-size "$OTA_SMOKE_RETAINED_SIZE"
cleanup_relay
cleanup_ota
trap - EXIT

if [[ "$MODE" == "firmware" || "$MODE" == "full" ]]; then
  log_step "Building ESP field firmware"
  tools/build_radar.sh field
fi

if [[ "$MODE" == "full" ]]; then
  log_step "Generating iOS project"
  (cd ios/DragonRadarMVP && xcodegen generate)

  log_step "Checking iOS production network config"
  if grep -q "NSAllowsArbitraryLoads" ios/DragonRadarMVP/DragonRadarMVP/Info.plist; then
    echo "Release Info.plist must not allow arbitrary ATS loads." >&2
    exit 1
  fi
  release_settings="$(
    xcodebuild \
      -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
      -scheme DragonRadarMVP \
      -configuration Release \
      -showBuildSettings 2>/dev/null
  )"
  grep -q "DRAGON_RADAR_HTTP_API_BASE_URL = https://" <<<"$release_settings" || {
    echo "Release HTTP API URL must use https." >&2
    exit 1
  }
  grep -q "DRAGON_RADAR_RELAY_BASE_URL = wss://" <<<"$release_settings" || {
    echo "Release Relay URL must use wss." >&2
    exit 1
  }

  log_step "Building iOS app"
  xcodebuild \
    -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
    -scheme DragonRadarMVP \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    build

  log_step "Running iOS unit/UI tests"
  IOS_TEST_DESTINATION="${IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone Air}"
  xcodebuild \
    -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
    -scheme DragonRadarMVP \
    -configuration Debug \
    -destination "$IOS_TEST_DESTINATION" \
    CODE_SIGNING_ALLOWED=NO \
    test

  xcodebuild \
    -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
    -scheme DragonRadarMVP \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

printf '\nverify-project-ok (%s)\n' "$MODE"
