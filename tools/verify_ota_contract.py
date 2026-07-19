#!/usr/bin/env python3
from __future__ import annotations

import csv
import io
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[1]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8")


def require(condition: bool, detail: str) -> None:
    if not condition:
        raise AssertionError(detail)


def require_in_order(source: str, needles: list[str], detail: str) -> None:
    offset = -1
    for needle in needles:
        found = source.find(needle, offset + 1)
        if found < 0:
            raise AssertionError(f"{detail}: missing or out of order: {needle}")
        offset = found


def verify() -> None:
    partitions = read("partitions_dragon_radar_32mb.csv")
    partition_rows: dict[str, list[str]] = {}
    for row in csv.reader(io.StringIO(partitions)):
        values = [value.strip() for value in row]
        if not values or not values[0] or values[0].startswith("#"):
            continue
        partition_rows[values[0]] = values
    require("otadata" in partition_rows, "partition table must have otadata")
    otadata_offset = int(partition_rows["otadata"][3], 0)
    board = json.loads(read("boards/waveshare_esp32_s3_touch_amoled_175c.json"))
    boot_app0_offset = int(board["upload"]["arduino"]["boot_app0"], 0)
    require(
        boot_app0_offset == otadata_offset,
        "board boot_app0 upload offset must match the custom otadata partition",
    )
    ota_slots = [row for row in partition_rows.values() if len(row) >= 5 and row[2] in {"ota_0", "ota_1"}]
    require(len(ota_slots) == 2, "partition table must have exactly ota_0 and ota_1")
    for row in ota_slots:
        require(int(row[4], 0) >= 8 * 1024 * 1024, f"OTA slot {row[0]} must be at least 8 MiB")

    manager = read("firmware/DragonRadar/OtaManager.cpp")
    firmware = read("firmware/DragonRadar/DragonRadar.ino")
    version_header = read("firmware/DragonRadar/FirmwareVersion.h")
    trust_header = read("firmware/DragonRadar/OtaSigningPublicKey.h")

    require("setInsecure" not in manager, "OTA TLS must never use setInsecure")
    require(
        'extern "C" bool verifyRollbackLater() {\n  return true;\n}' in manager,
        "Arduino rollback validation must be deferred until runtime health checks",
    )
    for needle in (
        'kArtifactPathPrefix = "/v1/firmware/artifacts/"',
        "parseHttpUrl",
        "validArtifactPath",
        "urlMatchesProvisionedOrigin",
        'error = "origin_unconfigured"',
        'error = "origin_invalid"',
        'error = "origin_mismatch"',
        'error = "artifact_path"',
        "HTTPC_DISABLE_FOLLOW_REDIRECTS",
        'http.addHeader("Range", String("bytes=")',
        'validContentRange(http.header("Content-Range")',
        'http.addHeader("Authorization", String("Bearer ") + deviceToken',
        "secureClient->setCACert(rootCa.c_str())",
        "esp_ota_mark_app_valid_cancel_rollback()",
        "esp_ota_mark_app_invalid_rollback_and_reboot()",
        "configTime(0, 0",
        'fail("time_sync")',
        "CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE",
    ):
        require(needle in manager, f"missing ESP OTA security contract: {needle}")
    require_in_order(
        manager,
        [
            "if (!urlMatchesProvisionedOrigin(manifest.artifactUrl, expectedHttpApiBase, secure, error))",
            'http.addHeader("Authorization", String("Bearer ") + deviceToken',
        ],
        "origin/path validation must happen before attaching the device Bearer",
    )
    require_in_order(
        manager,
        ["configTime(0, 0", 'fail("time_sync")', "secureClient->setCACert(rootCa.c_str())"],
        "TLS time sync must complete before opening a CA-validated HTTPS request",
    )
    require_in_order(
        manager,
        [
            'String canonical = "dragon-radar-ota-v1"',
            '"\\nschema="',
            '"\\nproduct="',
            '"\\nhardware="',
            '"\\nversion="',
            '"\\nbuild="',
            '"\\nminimum_version="',
            '"\\nsecurity_counter="',
            '"\\nsize="',
            '"\\nsha256="',
        ],
        "ESP canonical manifest fields",
    )

    for needle in (
        "String httpApiUrl;",
        'prefs.putString("httpApi", provisioning.httpApiUrl)',
        'prefs.isKey("httpApi") ? prefs.getString("httpApi", "") : ""',
        'extractJsonStringValue(json, "http_api_url", httpApiUrl)',
        "BLEDevice::setMTU(517)",
        "kBleDeviceStatusLastEventMaxBytes = 64",
        "kFirmwareStatusNotifySafeBytes = 180",
        "bool ownerSessionAuthorized = false;",
        "uint16_t ownerSessionConnectionHandle = kInvalidBleConnectionHandle;",
        '"CR-%04X-%08lX%08lX%08lX%08lX"',
        'const String message = String("v1|") + provisioning.challenge + "|t|" + nonce',
        'provisioning.lastWrite = "owner_auth_required"',
        'status += ",\\\"owner_auth_required\\\":1"',
        'status += ",\\\"owner_auth\\\":"',
        "String status = buildDeviceStatusJson();",
        "status = buildDeviceStatusJson(false, true);",
        'escapedLastWrite = "status_event_truncated"',
    ):
        require(needle in firmware, f"server_config must persist HTTP API origin: {needle}")
    require_in_order(
        firmware,
        [
            "if (includeExtendedState) {",
            'status += ",\\\"protocol_version\\\":"',
            'status += ",\\\"min_relay_protocol_version\\\":"',
        ],
        "Relay-only protocol metadata must not consume the BLE device-status budget",
    )
    require_in_order(
        firmware,
        [
            "relaySocket.beginSslWithCA(host.c_str(), port, path.c_str(), relayRootCaPem.c_str())",
            "relaySocket.begin(host.c_str(), port, path.c_str())",
            "relaySocket.setAuthorization(authorization.c_str())",
        ],
        "WebSocketsClient begin clears authorization, so Bearer setup must happen afterwards",
    )
    for needle in (
        "gfx->fillCircle(x, y, radius + 2, outer);",
        "gfx->fillCircle(x, y, radius, body);",
        "if (focusedMemberSlot == kFocusNone || now > focusFlashUntilMs)",
        "drawDistanceLabel(markers[slot].x, markers[slot].y, markers[slot].distanceM);",
        "drawMotionBadge(markers[slot].x, markers[slot].y,",
    ):
        require(needle in firmware, f"radar member display contract missing: {needle}")
    require_in_order(
        firmware,
        [
            "String status = buildDeviceStatusJson();",
            "if (status.length() > kBleCharacteristicMaxValueBytes)",
            "status = buildDeviceStatusJson(false, true);",
            "if (status.length() > kBleCharacteristicMaxValueBytes)",
        ],
        "BLE device status must compact before applying the hard characteristic limit",
    )
    status_builder_start = firmware.index(
        "String buildDeviceStatusJson(bool includeExtendedState = false, bool compactBleState = false)"
    )
    status_builder_end = firmware.index("void notifyDeviceStatus(bool force)", status_builder_start)
    status_builder = firmware[status_builder_start:status_builder_end]
    for needle in (
        '"\\"v\\":1"',
        '",\\"fw\\":\\""',
        '",\\"build\\":"',
        '",\\"hw\\":\\""',
        '",\\"ota\\":1"',
        '",\\"security_counter\\":"',
        '",\\"ota_origin\\":"',
        '",\\"paired\\":"',
        '",\\"owner_auth_required\\":1"',
        '",\\"owner_auth\\":"',
        '",\\"wifi\\":\\""',
        '",\\"server\\":"',
        '",\\"loc\\":"',
        '",\\"battery\\":{"',
        '",\\"last\\":\\""',
    ):
        require(needle in status_builder, f"compact BLE 105 lost required field builder: {needle}")
    for optional_block in (
        'if (!compactBleState) {\n    status += ",\\"relay\\":\\"";',
        'if (!compactBleState) {\n    status += ",\\"power_state\\":\\"";',
        'status += ",\\"display_state\\":\\"";',
    ):
        require(optional_block in status_builder, f"compact BLE 105 must omit optional field: {optional_block}")

    version_match = re.search(r'#define DRAGON_RADAR_FW_VERSION "([^"]+)"', version_header)
    hardware_match = re.search(r'#define DRAGON_RADAR_HARDWARE "([^"]+)"', version_header)
    require(version_match is not None, "firmware version macro missing")
    require(hardware_match is not None, "firmware hardware macro missing")
    compact_budget_sample = {
        "v": 1,
        "fw": version_match.group(1),
        "build": 4_294_967_295,
        "hw": hardware_match.group(1),
        "ota": 1,
        "security_counter": 4_294_967_295,
        "ota_origin": 1,
        "name": "X" * 40,
        "ble": 1,
        "paired": 1,
        "owner_auth_required": 1,
        "owner_auth": 1,
        "wifi": "connected",
        "rssi": -127,
        "ip": "255.255.255.255",
        "server": 1,
        "loc": 1,
        "battery": {
            "present": True,
            "percent": 100,
            "voltage_mv": 99_999,
            "charging": True,
            "discharging": True,
            "low": True,
        },
        "last": "X" * 64,
    }
    compact_budget_bytes = len(
        json.dumps(compact_budget_sample, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    )
    require(
        compact_budget_bytes <= 512,
        f"compact BLE 105 conservative budget exceeds 512 bytes: {compact_budget_bytes}",
    )
    require_in_order(
        firmware,
        [
            "void beginProvisioningConnection(BLEServer *server, uint16_t connectionHandle)",
            "provisioning.ownerSessionAuthorized = false;",
            "rotateProvisioningChallenge();",
        ],
        "each BLE connection must invalidate authorization and rotate its 128-bit challenge",
    )
    require_in_order(
        firmware,
        [
            "bool authorizeGattWrite(RadarGattWriteRole role, uint16_t connectionHandle)",
            "provisioning.ownerSessionAuthorized",
            "connectionHandle == ownerSessionConnectionHandle",
            "void handleGattWrite(\n    RadarGattWriteRole role,",
            "if (!authorizeGattWrite(role, connectionHandle))",
        ],
        "protected BLE writes must require the current owner session",
    )
    require_in_order(
        firmware,
        [
            "void endProvisioningConnection(uint16_t connectionHandle)",
            "ownerSessionConnectionHandle = kInvalidBleConnectionHandle;",
            "provisioning.ownerSessionAuthorized = false;",
        ],
        "disconnect must invalidate owner authorization",
    )

    app_runtime = read("ios/DragonRadarMVP/DragonRadarMVP/Sources/AppRuntimeHost.swift")
    app_update = read("ios/DragonRadarMVP/DragonRadarMVP/Sources/FirmwareUpdate.swift")
    app_ble = read("ios/DragonRadarMVP/DragonRadarMVP/Sources/BLEDeviceBridge.swift")
    for needle, source in (
        ("firmwareControlWriteError", app_ble),
        ("BLEOwnerSessionProof", app_ble),
        ("configureOwnerSession(deviceToken:", app_ble),
        ("ownerSessionAuthorized", app_ble),
        ('deviceStatusText = "等待雷达确认绑定"', app_ble),
        ("if deviceStatus?.server == 1", app_ble),
        ("ownerDeviceToken = cleanDeviceToken", app_ble),
        ("ownerAuthAttemptChallenge = pairingChallengeText", app_ble),
        ("syncCurrentRoomToESPIfOwnerReady", app_runtime),
        ("deviceStatus.ownerAuthRequired == 1", app_runtime),
        ("readFirmwareStatus()", app_runtime),
        ("beginSendingAcknowledgementTimeout()", app_update),
        ("handleFirmwareControlWriteFailure", app_update),
    ):
        require(needle in source, f"App OTA BLE acknowledgement fallback missing: {needle}")

    require("DRAGON_RADAR_FW_SECURITY_COUNTER >= 1" in version_header, "firmware security counter floor")
    require("kSigningKeyId[] = \"local-2026-01\"" in trust_header, "embedded OTA key id")
    require("BEGIN PUBLIC KEY" in trust_header, "embedded OTA public key")

    build_tool = read("tools/build_radar.sh")
    for needle in (
        '"ota_public_key_sha256"',
        '"ota_allow_http"',
        '"ota_root_ca_configured"',
        '"ota_root_ca_sha256"',
        '"release_build"',
        "firmware-metadata.json",
        "DRAGON_RADAR_OTA_ROOT_CA_PEM_FILE",
        "DRAGON_RADAR_OTA_ALLOW_HTTP",
        "4294967295",
    ):
        require(needle in build_tool, f"build sidecar/readiness gate missing: {needle}")

    relay = read("relay/server.py")
    for needle in (
        'OTA_HARDWARE = "esp32-s3-touch-amoled-1.75c"',
        'artifact_prefix = "/v1/firmware/artifacts/"',
        'path == "/v1/firmware/manifest"',
        'requested_channel != "stable"',
        "build_metadata_stat.st_mtime_ns",
        'metadata.get("release_build")',
        'metadata.get("ota_allow_http")',
        'metadata.get("ota_root_ca_configured")',
        'environment == "field"',
        'DRAGON_RADAR_ALLOW_DEVELOPMENT_OTA',
        'OTA_RETAINED_RELEASES_DIR = "retained"',
        "firmware_releases.artifact(requested_name)",
        'artifact_path.name != f"{expected_sha256}.bin"',
        'self.send_header("Accept-Ranges", "bytes")',
        'self.send_header("Content-Range"',
    ):
        require(needle in relay, f"Relay OTA contract missing: {needle}")

    package_tool = read("tools/package_ota_release.py")
    for needle in (
        "DEFAULT_RETAIN_RELEASES = 3",
        'RETAINED_RELEASES_DIR = "retained"',
        'return f"{sha256}.bin"',
        "retained_release_sources(",
        "copy_release_snapshot(",
        "new build must be greater than every published build",
        "new security_counter must not be lower than any published release",
        "new version must not be lower than any published release",
        "an immutable firmware digest is already bound to a different release identity",
    ):
        require(needle in package_tool, f"OTA immutable retention contract missing: {needle}")

    release_verifier = read("tools/verify_ota_release.py")
    require(
        'artifact.name != f"{manifest[\'sha256\']}.bin"' in release_verifier,
        "OTA verifier must enforce content-addressed artifact names",
    )

    ios_update = read("ios/DragonRadarMVP/DragonRadarMVP/Sources/FirmwareUpdate.swift")
    ios_ble = read("ios/DragonRadarMVP/DragonRadarMVP/Sources/BLEDeviceBridge.swift")
    for needle in (
        'expectedHardware = "esp32-s3-touch-amoled-1.75c"',
        'expectedAlgorithm = "ecdsa-p256-sha256"',
        'expectedKeyID = "local-2026-01"',
        "manifest.build <= Int(UInt32.max)",
        "manifest.securityCounter <= Int(UInt32.max)",
        'invalidField("version_minimum_order")',
        "url.scheme?.lowercased() == baseURL.scheme?.lowercased()",
        "url.host?.lowercased() == baseURL.host?.lowercased()",
        "url.port == baseURL.port",
        'case "success"',
        "phase = .succeeded",
    ):
        require(needle in ios_update, f"iOS OTA contract missing: {needle}")
    for needle in (
        'case otaOrigin = "ota_origin"',
        "otaOrigin == 1",
        'CBUUID(string: "7d540107-f82d-4b2f-91c6-4f0f88aa5a11")',
        'CBUUID(string: "7d540108-f82d-4b2f-91c6-4f0f88aa5a11")',
        'case httpAPIURL = "http_api_url"',
    ):
        require(needle in ios_ble, f"iOS BLE OTA contract missing: {needle}")


def main() -> int:
    try:
        verify()
    except (OSError, UnicodeError, AssertionError) as exc:
        print(f"ota-contract-static-error: {exc}", file=sys.stderr)
        return 1
    print("ota-contract-static-ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
