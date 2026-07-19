#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import math
import os
import time
from typing import Any
from urllib import error, request
from urllib.parse import urlencode

import websockets


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Join a Capsule room as a simulated remote iPhone + ESP pair.")
    parser.add_argument("--url", default="ws://139.224.41.192:8787", help="Relay base URL.")
    parser.add_argument("--http-url", default="http://139.224.41.192:8788", help="Relay HTTP API base URL used for authentication.")
    parser.add_argument("--room", default="CAPS-07", help="Room code.")
    parser.add_argument("--group-id", default="", help="Logical room group id. Defaults to device id, or app id without app- prefix.")
    parser.add_argument("--app-id", default="app-sim-remote", help="Simulated app member id.")
    parser.add_argument("--device-id", default="", help="Registered simulated ESP device token. Leave empty for app-only.")
    parser.add_argument("--name", default="远端模拟组", help="Name shown in room_state.")
    parser.add_argument("--auth-user", default="", help="Development Apple user id used to obtain an access token when DRAGON_RADAR_ACCESS_TOKEN is unset.")
    parser.add_argument("--auth-display-name", default="胶囊模拟成员", help="Display name used for development authentication.")
    parser.add_argument("--lat-e7", type=int, default=311560430, help="Latitude * 1e7.")
    parser.add_argument("--lon-e7", type=int, default=1215599150, help="Longitude * 1e7.")
    parser.add_argument("--accuracy-cm", type=int, default=1200, help="Horizontal accuracy in cm.")
    parser.add_argument("--interval", type=float, default=2.0, help="Publish interval in seconds.")
    parser.add_argument("--log-every", type=int, default=15, help="Log every N location sends; use 0 to disable periodic send logs.")
    parser.add_argument("--verbose-room-state", action="store_true", help="Print every room_state payload received from the Relay.")
    parser.add_argument("--mode", choices=("fixed", "circle"), default="circle", help="Location simulation mode.")
    parser.add_argument("--radius-m", type=float, default=80.0, help="Circle radius in meters.")
    parser.add_argument("--period-s", type=float, default=120.0, help="Seconds per full circle.")
    parser.add_argument("--anchor-live", action="store_true", help="Anchor the simulated center to the first other live member with a location.")
    parser.add_argument("--anchor-north-m", type=float, default=0.0, help="North offset from the live anchor in meters.")
    parser.add_argument("--anchor-east-m", type=float, default=100.0, help="East offset from the live anchor in meters.")
    parser.add_argument("--speaking", action="store_true", help="Publish periodic simulated voice activity.")
    parser.add_argument("--speak-period-s", type=float, default=8.0, help="Voice activity cycle seconds.")
    parser.add_argument("--speak-duty-s", type=float, default=2.0, help="Seconds speaking in each cycle.")
    return parser.parse_args()


def post_json(url: str, payload: dict[str, Any]) -> dict[str, Any]:
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    req = request.Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with request.urlopen(req, timeout=8) as response:
            parsed = json.loads(response.read().decode("utf-8"))
    except error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise RuntimeError(f"authentication failed: HTTP {exc.code} {detail}") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError("authentication returned a non-object response")
    return parsed


def resolve_access_token(args: argparse.Namespace) -> str:
    token = os.environ.get("DRAGON_RADAR_ACCESS_TOKEN", "").strip()
    if token:
        return token
    if not args.auth_user:
        raise RuntimeError("set DRAGON_RADAR_ACCESS_TOKEN or pass --auth-user")
    identity_token = os.environ.get("DRAGON_RADAR_IDENTITY_TOKEN", "").strip()
    if not identity_token:
        raise RuntimeError("DRAGON_RADAR_IDENTITY_TOKEN is required with --auth-user")
    response = post_json(
        f"{args.http_url.rstrip('/')}/v1/auth/apple",
        {
            "apple_user_id": args.auth_user,
            "display_name": args.auth_display_name,
            "identity_token": identity_token,
        },
    )
    session = response.get("session")
    token = str(session.get("access_token") if isinstance(session, dict) else "").strip()
    if not token:
        raise RuntimeError("authentication response did not include an access token")
    return token


def compact_json(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def offset_lat_lon_e7(center_lat_e7: int, center_lon_e7: int, north_m: float, east_m: float) -> tuple[int, int]:
    center_lat = center_lat_e7 / 10_000_000
    center_lon = center_lon_e7 / 10_000_000
    lat = center_lat + north_m / 111_320.0
    lon_scale = max(0.01, math.cos(math.radians(center_lat)))
    lon = center_lon + east_m / (111_320.0 * lon_scale)
    return round(lat * 10_000_000), round(lon * 10_000_000)


def location_for_tick(args: argparse.Namespace, started_at: float) -> dict[str, int]:
    if args.mode == "fixed":
        return {
            "lat_e7": args.lat_e7,
            "lon_e7": args.lon_e7,
            "speed_cms": 0,
            "course_deg100": 0,
        }

    elapsed = time.time() - started_at
    angle = (elapsed / max(1.0, args.period_s)) * math.tau
    north = math.sin(angle) * args.radius_m
    east = math.cos(angle) * args.radius_m
    lat_e7, lon_e7 = offset_lat_lon_e7(args.lat_e7, args.lon_e7, north, east)
    tangent_deg = (math.degrees(angle) + 90.0) % 360.0
    speed_mps = math.tau * args.radius_m / max(1.0, args.period_s)
    return {
        "lat_e7": lat_e7,
        "lon_e7": lon_e7,
        "speed_cms": round(speed_mps * 100),
        "course_deg100": round(tangent_deg * 100),
    }


async def run(args: argparse.Namespace) -> None:
    base = args.url.rstrip("/")
    access_token = resolve_access_token(args)
    app_query = {"room": args.room, "app_id": args.app_id}
    if args.group_id:
        app_query["group_id"] = args.group_id
    app_url = f"{base}/v1/radar/app/ws?{urlencode(app_query)}"
    device_socket = None
    stack = websockets.connect(
        app_url,
        ping_interval=20,
        ping_timeout=20,
        extra_headers={"Authorization": f"Bearer {access_token}"},
    )
    async with stack as app_socket:
        if args.device_id:
            device_peer_id = hashlib.sha256(args.device_id.encode("utf-8")).hexdigest()[:24]
            device_query = {"room": args.room, "device_id": device_peer_id}
            if args.group_id:
                device_query["group_id"] = args.group_id
            device_url = f"{base}/v1/radar/device/ws?{urlencode(device_query)}"
            device_socket = await websockets.connect(
                device_url,
                ping_interval=20,
                ping_timeout=20,
                extra_headers={"Authorization": f"Bearer {args.device_id}"},
            )
        initial_app_message = json.loads(await app_socket.recv())
        print(compact_json(initial_app_message), flush=True)
        if device_socket is not None:
            print(await device_socket.recv(), flush=True)

        if args.anchor_live:
            anchor_message: dict[str, Any] | None = None
            for _ in range(4):
                try:
                    candidate = json.loads(await asyncio.wait_for(app_socket.recv(), timeout=2.0))
                except asyncio.TimeoutError:
                    break
                if candidate.get("type") == "room_state":
                    print(
                        f"APP room_state members={len(candidate.get('members', []))} room={candidate.get('room')}",
                        flush=True,
                    )
                    anchor_message = candidate
                    break
                print(f"APP {json.dumps(candidate, ensure_ascii=False)}", flush=True)
            if anchor_message is not None:
                for member in anchor_message.get("members", []):
                    if not isinstance(member, dict) or member.get("group_id") == args.group_id:
                        continue
                    location = member.get("location")
                    if not isinstance(location, dict):
                        continue
                    lat_e7 = int(location.get("lat_e7") or 0)
                    lon_e7 = int(location.get("lon_e7") or 0)
                    if not lat_e7 or not lon_e7:
                        continue
                    args.lat_e7, args.lon_e7 = offset_lat_lon_e7(
                        lat_e7,
                        lon_e7,
                        args.anchor_north_m,
                        args.anchor_east_m,
                    )
                    print(
                        f"anchored group={args.group_id or args.app_id} to member={member.get('group_id')} "
                        f"center={args.lat_e7},{args.lon_e7}",
                        flush=True,
                    )
                    break
        await app_socket.send(
            compact_json(
                {
                    "type": "hello",
                    "app": "MacRemotePairSimulator",
                    "name": f"{args.name} iPhone",
                    "protocol_version": 2,
                    "min_relay_protocol_version": 2,
                    "capabilities": ["location", "mac_simulator"],
                    "room": args.room,
                }
            )
        )
        if device_socket is not None:
            await device_socket.send(
                compact_json(
                    {
                        "type": "hello",
                        "firmware": "mac-simulated-esp",
                        "name": f"{args.name} ESP",
                        "protocol_version": 2,
                        "min_relay_protocol_version": 2,
                        "capabilities": ["display", "voice_status", "mac_simulator"],
                        "room": args.room,
                    }
                )
            )

        async def receiver() -> None:
            async def receive_one(socket: Any, label: str) -> None:
                async for raw in socket:
                    message = json.loads(raw)
                    if message.get("type") == "error" or (
                        message.get("type") == "room_state" and args.verbose_room_state
                    ):
                        print(f"{label} {json.dumps(message, ensure_ascii=False)}", flush=True)

            tasks = [receive_one(app_socket, "APP")]
            if device_socket is not None:
                tasks.append(receive_one(device_socket, "ESP"))
            await asyncio.gather(*tasks)

        receive_task = asyncio.create_task(receiver())
        started_at = time.time()
        sequence = 0
        try:
            while True:
                location = location_for_tick(args, started_at)
                sequence += 1
                await app_socket.send(
                    compact_json(
                        {
                            "type": "app_location",
                            "name": f"{args.name} iPhone",
                            "sequence": sequence,
                            "location": {
                                "lat_e7": location["lat_e7"],
                                "lon_e7": location["lon_e7"],
                                "h_acc_cm": args.accuracy_cm,
                                "speed_cms": location["speed_cms"],
                                "course_deg100": location["course_deg100"],
                                "unix_time": int(time.time()),
                            },
                        }
                    )
                )
                if device_socket is not None:
                    speaking = False
                    if args.speaking:
                        speaking = ((time.time() - started_at) % max(1.0, args.speak_period_s)) < args.speak_duty_s
                    await device_socket.send(
                        compact_json(
                            {
                                "type": "voice_frame" if speaking else "device_status",
                                "name": f"{args.name} ESP",
                                "device_status": {
                                    "name": f"{args.name} ESP",
                                    "wifi": "connected",
                                    "relay": "connected",
                                    "battery_pct": 88,
                                    "sequence": sequence,
                                },
                                "voice_status": {
                                    "codec": "sim-status",
                                    "sample_rate": 16000,
                                    "frame_ms": 20,
                                    "sequence": sequence,
                                    "muted": False,
                                    "ptt": speaking,
                                    "vad": speaking,
                                },
                            }
                        )
                    )
                if args.log_every > 0 and (sequence == 1 or sequence % args.log_every == 0):
                    print(
                        f"sent seq={sequence} lat_e7={location['lat_e7']} lon_e7={location['lon_e7']} "
                        f"mode={args.mode} room={args.room}",
                        flush=True,
                    )
                await asyncio.sleep(args.interval)
        finally:
            receive_task.cancel()
            if device_socket is not None:
                await device_socket.close()


def main() -> int:
    args = parse_args()
    asyncio.run(run(args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
