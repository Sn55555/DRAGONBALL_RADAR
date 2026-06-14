#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
import struct
import sys
import time
from dataclasses import dataclass
from typing import Any


SERVICE_UUID = "7d540100-f82d-4b2f-91c6-4f0f88aa5a11"
PAIRING_CHALLENGE_UUID = "7d540101-f82d-4b2f-91c6-4f0f88aa5a11"
PAIRING_RESPONSE_UUID = "7d540102-f82d-4b2f-91c6-4f0f88aa5a11"
WIFI_CONFIG_UUID = "7d540103-f82d-4b2f-91c6-4f0f88aa5a11"
LOCAL_LOCATION_UUID = "7d540104-f82d-4b2f-91c6-4f0f88aa5a11"
DEVICE_STATUS_UUID = "7d540105-f82d-4b2f-91c6-4f0f88aa5a11"
SERVER_CONFIG_UUID = "7d540106-f82d-4b2f-91c6-4f0f88aa5a11"


@dataclass
class ScanHit:
    device: Any
    name: str
    rssi: int | None
    services: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Smoke test the Dragon Radar ESP provisioning BLE GATT service."
    )
    parser.add_argument("--name-prefix", default="CapsuleRadar", help="BLE device name prefix to match.")
    parser.add_argument("--address", help="Connect to a specific BLE address/identifier.")
    parser.add_argument("--scan-timeout", type=float, default=8.0, help="Seconds to scan before connecting.")
    parser.add_argument("--lat", type=float, default=31.230416, help="Test latitude for local_location.")
    parser.add_argument("--lon", type=float, default=121.473701, help="Test longitude for local_location.")
    parser.add_argument("--accuracy-cm", type=int, default=850, help="Horizontal accuracy in centimeters.")
    parser.add_argument("--pair-response", help="Optional pairing_response payload to write.")
    parser.add_argument("--wifi-ssid", help="Optional Wi-Fi SSID to write. Requires --wifi-password.")
    parser.add_argument("--wifi-password", help="Optional Wi-Fi password to write.")
    parser.add_argument("--relay-url", help="Optional Relay URL to write in server_config.")
    parser.add_argument("--room-token", default="", help="Optional room token for server_config.")
    parser.add_argument("--device-token", default="", help="Optional device token for server_config.")
    parser.add_argument("--json", action="store_true", help="Print final result as JSON only.")
    return parser.parse_args()


def import_bleak():
    try:
        from bleak import BleakClient, BleakScanner
    except ModuleNotFoundError as exc:
        print(
            "Missing dependency: bleak. Install with `python3 -m pip install --user bleak`.",
            file=sys.stderr,
        )
        raise SystemExit(2) from exc
    return BleakClient, BleakScanner


def service_matches(service_uuids: list[str]) -> bool:
    return any(uuid.lower() == SERVICE_UUID for uuid in service_uuids)


async def find_device(args: argparse.Namespace) -> ScanHit:
    _, BleakScanner = import_bleak()
    hits: list[ScanHit] = []

    def callback(device: Any, advertisement_data: Any) -> None:
        name = advertisement_data.local_name or getattr(device, "name", None) or ""
        services = [str(uuid).lower() for uuid in getattr(advertisement_data, "service_uuids", [])]
        address = getattr(device, "address", "")
        if args.address and args.address != address:
            return
        if not args.address and not (name.startswith(args.name_prefix) or service_matches(services)):
            return
        hits.append(ScanHit(device=device, name=name or address, rssi=getattr(device, "rssi", None), services=services))

    scanner = BleakScanner(callback)
    await scanner.start()
    await asyncio.sleep(args.scan_timeout)
    await scanner.stop()

    if not hits:
        raise RuntimeError(f"No BLE device found for prefix={args.name_prefix!r} service={SERVICE_UUID}")

    hits.sort(key=lambda hit: (not service_matches(hit.services), -(hit.rssi or -999)))
    return hits[0]


def build_location_frame(lat: float, lon: float, accuracy_cm: int) -> bytes:
    lat_e7 = int(round(lat * 10_000_000))
    lon_e7 = int(round(lon * 10_000_000))
    flags = 0b0000_0001
    altitude_unknown = -2_147_483_648
    vertical_accuracy_cm = 0
    speed_cms = 0
    course_deg100 = 0
    heading_deg100 = 0
    unix_time = int(time.time())
    return struct.pack(
        "<BBiiiHHHHHI",
        1,
        flags,
        lat_e7,
        lon_e7,
        altitude_unknown,
        max(0, min(accuracy_cm, 65535)),
        vertical_accuracy_cm,
        speed_cms,
        course_deg100,
        heading_deg100,
        unix_time,
    )


async def read_text(client: Any, uuid: str) -> str:
    data = await client.read_gatt_char(uuid)
    return bytes(data).decode("utf-8", errors="replace")


async def smoke(args: argparse.Namespace) -> dict[str, Any]:
    BleakClient, _ = import_bleak()
    hit = await find_device(args)
    result: dict[str, Any] = {
        "device": hit.name,
        "rssi": hit.rssi,
        "service_uuid": SERVICE_UUID,
        "wrote": [],
    }

    async with BleakClient(hit.device) as client:
        result["connected"] = client.is_connected
        result["pairing_challenge"] = await read_text(client, PAIRING_CHALLENGE_UUID)
        initial_status = await read_text(client, DEVICE_STATUS_UUID)
        result["initial_status_raw"] = initial_status
        try:
            result["initial_status"] = json.loads(initial_status)
        except json.JSONDecodeError:
            result["initial_status"] = None

        if args.pair_response:
            await client.write_gatt_char(PAIRING_RESPONSE_UUID, args.pair_response.encode("utf-8"), response=True)
            result["wrote"].append("pairing_response")

        if args.wifi_ssid or args.wifi_password:
            if not (args.wifi_ssid and args.wifi_password is not None):
                raise RuntimeError("--wifi-ssid and --wifi-password must be provided together")
            payload = json.dumps(
                {"version": "1", "ssid": args.wifi_ssid, "password": args.wifi_password},
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            await client.write_gatt_char(WIFI_CONFIG_UUID, payload, response=True)
            result["wrote"].append("wifi_config")

        if args.relay_url:
            payload = json.dumps(
                {
                    "version": "1",
                    "relay_url": args.relay_url,
                    "room_token": args.room_token,
                    "device_token": args.device_token,
                },
                separators=(",", ":"),
                sort_keys=True,
            ).encode("utf-8")
            await client.write_gatt_char(SERVER_CONFIG_UUID, payload, response=True)
            result["wrote"].append("server_config")

        await client.write_gatt_char(
            LOCAL_LOCATION_UUID,
            build_location_frame(args.lat, args.lon, args.accuracy_cm),
            response=True,
        )
        result["wrote"].append("local_location")
        await asyncio.sleep(0.4)

        final_status = await read_text(client, DEVICE_STATUS_UUID)
        result["final_status_raw"] = final_status
        try:
            result["final_status"] = json.loads(final_status)
        except json.JSONDecodeError:
            result["final_status"] = None

    return result


def main() -> int:
    args = parse_args()
    try:
        result = asyncio.run(smoke(args))
    except Exception as exc:
        if args.json:
            print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        else:
            print(f"BLE smoke failed: {exc}", file=sys.stderr)
        return 1

    ok = bool(result.get("connected")) and "local_location" in result.get("wrote", [])
    final_status = result.get("final_status") or {}
    if isinstance(final_status, dict):
        ok = ok and final_status.get("loc") == 1
    result["ok"] = ok

    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(f"device: {result['device']} rssi={result.get('rssi')}")
        print(f"challenge: {result.get('pairing_challenge')}")
        print(f"initial: {result.get('initial_status_raw')}")
        print(f"wrote: {', '.join(result.get('wrote', []))}")
        print(f"final: {result.get('final_status_raw')}")
        print(f"ok: {'yes' if ok else 'no'}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
