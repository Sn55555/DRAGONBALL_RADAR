#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import hashlib
import hmac
import json
import os
import sys
import traceback
from typing import Any
from urllib import error
from urllib import request
from urllib.parse import urlparse, urlunparse

import websockets


DEFAULT_PAIRING_HMAC_KEY = "dragon-radar-dev-pairing-key"


def pairing_response_valid(challenge: str, response: str) -> bool:
    parts = response.split(":")
    if len(parts) != 5 or parts[:2] != ["dra-pair", "v2"]:
        return False
    _, _, device_id, nonce, signature = parts
    message = f"v2|{challenge}|{device_id}|{nonce}".encode("utf-8")
    key = (os.environ.get("DRAGON_RADAR_PAIRING_HMAC_KEY") or DEFAULT_PAIRING_HMAC_KEY).encode("utf-8")
    expected = hmac.new(key, message, hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature, expected)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Smoke test the Dragon Radar Relay WebSocket protocol.")
    parser.add_argument("--url", default="ws://127.0.0.1:8787", help="Relay base URL.")
    parser.add_argument("--http-url", default="", help="Relay HTTP API base URL. Defaults to ws port + 1.")
    parser.add_argument("--room", default="DRGN-TEST", help="Room code.")
    return parser.parse_args()


def infer_http_url(ws_url: str) -> str:
    parsed = urlparse(ws_url)
    port = parsed.port or (443 if parsed.scheme == "wss" else 80)
    netloc = parsed.hostname or "127.0.0.1"
    if ":" in netloc and not netloc.startswith("["):
        netloc = f"[{netloc}]"
    netloc = f"{netloc}:{port + 1}"
    return urlunparse(("https" if parsed.scheme == "wss" else "http", netloc, "", "", "", ""))


def request_json(
    method: str,
    base_url: str,
    path: str,
    payload: dict[str, Any] | None = None,
    access_token: str = "",
) -> tuple[int, dict[str, Any]]:
    data = None
    headers = {"Accept": "application/json"}
    if access_token:
        headers["Authorization"] = f"Bearer {access_token}"
    if payload is not None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = request.Request(f"{base_url.rstrip('/')}{path}", data=data, headers=headers, method=method)
    try:
        with request.urlopen(req, timeout=4) as response:
            body = response.read().decode("utf-8")
            return response.status, json.loads(body) if body else {}
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        return exc.code, json.loads(body) if body else {}


def smoke_http(base_url: str) -> dict[str, Any]:
    health_status, health = request_json("GET", base_url, "/healthz")
    limits = health.get("limits", {}) if isinstance(health.get("limits"), dict) else {}
    protocol = health.get("protocol", {}) if isinstance(health.get("protocol"), dict) else {}
    notifications = health.get("notifications", {}) if isinstance(health.get("notifications"), dict) else {}
    max_body_bytes = int(limits.get("http_max_body_bytes") or 65536)
    oversized_status, oversized = request_json(
        "POST",
        base_url,
        "/v1/auth/apple",
        {
            "apple_user_id": "smoke-oversized",
            "display_name": "Oversized Smoke",
            "identity_token": "x" * (max_body_bytes + 1024),
        },
    )
    unauth_status, unauth = request_json("GET", base_url, "/v1/rooms")
    invalid_auth_status, invalid_auth = request_json(
        "POST",
        base_url,
        "/v1/auth/apple",
        {"apple_user_id": "smoke-user", "display_name": "Smoke User"},
    )
    auth_status, auth = request_json(
        "POST",
        base_url,
        "/v1/auth/apple",
        {"apple_user_id": "smoke-user", "display_name": "Smoke User", "identity_token": "development"},
    )
    session = auth.get("session", {})
    access_token = session.get("access_token", "")
    refresh_status, refreshed = request_json(
        "POST",
        base_url,
        "/v1/auth/refresh",
        {"refresh_token": session.get("refresh_token", "")},
    )
    refreshed_session = refreshed.get("session", {})
    device_unauth_status, device_unauth = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {"pairing_challenge": "smoke-challenge"},
    )
    register_device_status, registered_device = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {"pairing_challenge": "smoke-challenge-A17C", "name": "Smoke ESP"},
        access_token,
    )
    device = registered_device.get("device", {})
    duplicate_device_status, duplicate_device = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {"pairing_challenge": "smoke-challenge-A17C", "name": "Smoke ESP Again"},
        access_token,
    )
    other_auth_status, other_auth = request_json(
        "POST",
        base_url,
        "/v1/auth/apple",
        {"apple_user_id": "smoke-user-other", "display_name": "Other Smoke User", "identity_token": "development"},
    )
    other_token = other_auth.get("session", {}).get("access_token", "")
    stolen_device_status, stolen_device = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {"pairing_challenge": "smoke-challenge-A17C", "name": "Stolen ESP"},
        other_token,
    )
    revoke_register_status, revoke_registered_device = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {"pairing_challenge": "smoke-revoke-B22D", "name": "Revoke ESP"},
        access_token,
    )
    revoke_device = revoke_registered_device.get("device", {})
    busy_register_status, busy_registered_device = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {"pairing_challenge": "smoke-busy-C33E", "name": "Busy ESP"},
        access_token,
    )
    busy_device = busy_registered_device.get("device", {})
    revoke_status, revoked_device = request_json(
        "DELETE",
        base_url,
        f"/v1/devices/{revoke_device.get('device_id', '')}",
        access_token=access_token,
    )
    diagnostics_unauth_status, diagnostics_unauth = request_json(
        "POST",
        base_url,
        "/v1/diagnostics",
        {"report": {"app": {"version": "smoke"}}},
    )
    diagnostics_status, diagnostics = request_json(
        "POST",
        base_url,
        "/v1/diagnostics",
        {
            "report": {
                "app": {"version": "smoke", "build": "1", "environment": "test"},
                "room": {"room_code": "SMOKE"},
                "privacy": {"contains_token": False, "contains_wifi_password": False},
            }
        },
        access_token,
    )
    push_register_status, push_registered = request_json(
        "POST",
        base_url,
        "/v1/push/register",
        {
            "device_token": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            "platform": "ios",
            "environment": "sandbox",
            "app_version": "smoke",
        },
        access_token,
    )
    list_devices_status, listed_devices = request_json("GET", base_url, "/v1/devices", access_token=access_token)
    create_status, created = request_json("POST", base_url, "/v1/rooms", {"name": "Smoke Test Room"}, access_token)
    room = created.get("room", {})
    room_code = room.get("room_code", "")
    join_status, joined = request_json(
        "POST",
        base_url,
        "/v1/rooms/join",
        {"room_code": room_code, "member_id": "smoke-member-2", "display_name": "Smoke Member"},
        access_token,
    )
    patch_status, renamed = request_json("PATCH", base_url, f"/v1/rooms/{room_code}", {"name": "Smoke Renamed Room"}, access_token)
    invite_status, invite = request_json(
        "POST",
        base_url,
        f"/v1/rooms/{room_code}/invite",
        {"target_user_id": session.get("user_id", "")},
        access_token,
    )
    list_status, listed = request_json("GET", base_url, "/v1/rooms", access_token=access_token)
    get_status, fetched = request_json("GET", base_url, f"/v1/rooms/{room_code}", access_token=access_token)
    remove_status, removed = request_json("DELETE", base_url, f"/v1/rooms/{room_code}/members/smoke-member-2", access_token=access_token)
    delete_status, deleted = request_json("DELETE", base_url, f"/v1/rooms/{room_code}", access_token=access_token)
    get_deleted_status, get_deleted = request_json("GET", base_url, f"/v1/rooms/{room_code}", access_token=access_token)

    fetched_room = fetched.get("room", {})
    ok = (
        health_status == 200
        and health.get("ok") is True
        and int(protocol.get("relay") or 0) >= 2
        and int(protocol.get("min_app") or 0) >= 2
        and int(protocol.get("min_device") or 0) >= 2
        and int(protocol.get("location_frame") or 0) == 1
        and int(protocol.get("voice") or 0) == 1
        and int(limits.get("http_max_body_bytes") or 0) >= 1024
        and int(limits.get("ws_max_message_bytes") or 0) >= 1024
        and oversized_status == 413
        and oversized.get("code") == "request_too_large"
        and unauth_status == 401
        and unauth.get("code") == "unauthorized"
        and invalid_auth_status == 403
        and invalid_auth.get("code") == "invalid_apple_identity_token"
        and auth_status == 200
        and access_token.startswith("dra_")
        and refresh_status == 200
        and refreshed_session.get("access_token", "").startswith("dra_")
        and device_unauth_status == 401
        and device_unauth.get("code") == "unauthorized"
        and register_device_status == 201
        and device.get("device_token", "").startswith("ddt_")
        and pairing_response_valid("smoke-challenge-A17C", device.get("pairing_response", ""))
        and duplicate_device_status == 201
        and duplicate_device.get("device", {}).get("device_id") == device.get("device_id")
        and other_auth_status == 200
        and stolen_device_status == 403
        and stolen_device.get("code") == "device_already_bound"
        and revoke_register_status == 201
        and busy_register_status == 201
        and busy_device.get("device_token", "").startswith("ddt_")
        and revoke_status == 200
        and revoked_device.get("device", {}).get("revoked_at", 0) > 0
        and diagnostics_unauth_status == 401
        and diagnostics_unauth.get("code") == "unauthorized"
        and diagnostics_status == 201
        and diagnostics.get("diagnostics", {}).get("report_id", "").startswith("diag_")
        and push_register_status == 201
        and push_registered.get("subscription", {}).get("device_token", "").endswith("abcdef")
        and list_devices_status == 200
        and any(item.get("device_id") == device.get("device_id") for item in listed_devices.get("devices", []))
        and not any(item.get("device_id") == revoke_device.get("device_id") for item in listed_devices.get("devices", []))
        and create_status == 201
        and room.get("name") == "Smoke Test Room"
        and room.get("max_members") == 7
        and join_status == 200
        and joined.get("room", {}).get("member_count") == 2
        and patch_status == 200
        and renamed.get("room", {}).get("name") == "Smoke Renamed Room"
        and invite_status == 201
        and invite.get("invite", {}).get("invite_code") == room_code
        and invite.get("notification", {}).get("status") == ("dry_run" if notifications.get("mode") == "dry_run" else "skipped")
        and list_status == 200
        and any(item.get("room_code") == room_code for item in listed.get("rooms", []))
        and get_status == 200
        and fetched_room.get("room_code") == room_code
        and fetched_room.get("member_count") == 2
        and remove_status == 200
        and removed.get("room", {}).get("member_count") == 1
        and delete_status == 200
        and deleted.get("ok") is True
        and get_deleted_status == 404
        and get_deleted.get("code") == "invalid_room"
    )
    return {
        "ok": ok,
        "base_url": base_url,
        "room_code": room_code,
        "access_token": access_token,
        "device_token": device.get("device_token", ""),
        "health": health,
        "oversized": oversized,
        "unauth": unauth,
        "invalid_auth": invalid_auth,
        "auth": {
            "session": {
                **session,
                "access_token": "redacted",
                "refresh_token": "redacted",
            }
        },
        "refresh": {
            "session": {
                **refreshed_session,
                "access_token": "redacted",
                "refresh_token": "redacted",
            }
        },
        "registered_device": {
            "device": {
                **device,
                "device_token": "redacted",
                "pairing_response": "redacted",
            }
        },
        "duplicate_device": {"status": duplicate_device_status},
        "stolen_device": stolen_device,
        "revoked_device": {
            "device": {
                **revoked_device.get("device", {}),
                "device_token": "redacted",
                "pairing_response": "redacted",
            }
        },
        "revoked_device_token": revoke_device.get("device_token", ""),
        "busy_device_token": busy_device.get("device_token", ""),
        "diagnostics": diagnostics,
        "push_registered": {
            "subscription": {
                **push_registered.get("subscription", {}),
                "device_token": "redacted",
            }
        },
        "listed_devices_count": len(listed_devices.get("devices", [])),
        "created": created,
        "joined": joined,
        "renamed": renamed,
        "invite": invite,
        "listed_count": len(listed.get("rooms", [])),
        "fetched": fetched,
        "removed": removed,
        "deleted": deleted,
        "get_deleted": get_deleted,
    }


async def recv_json(socket: Any, timeout: float = 3.0) -> dict[str, Any]:
    raw = await asyncio.wait_for(socket.recv(), timeout=timeout)
    return json.loads(raw)


async def recv_until(socket: Any, message_type: str, timeout: float = 4.0) -> dict[str, Any]:
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {message_type}")
        message = await recv_json(socket, timeout=remaining)
        if message.get("type") == message_type:
            return message


async def recv_room_state_with_device_voice(socket: Any, timeout: float = 4.0) -> dict[str, Any]:
    deadline = asyncio.get_running_loop().time() + timeout
    latest: dict[str, Any] = {}
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            raise TimeoutError("timed out waiting for device voice room_state")
        message = await recv_json(socket, timeout=remaining)
        if message.get("type") != "room_state":
            continue
        latest = message
        members = message.get("members", [])
        device_member = next((member for member in members if member.get("member_id") == "smoke"), {})
        if device_member.get("last_type") == "voice_frame":
            return message


async def recv_room_state_member(
    socket: Any,
    member_id: str,
    predicate: Any,
    description: str,
    timeout: float = 4.0,
) -> dict[str, Any]:
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {description}")
        message = await recv_json(socket, timeout=remaining)
        if message.get("type") != "room_state":
            continue
        member = next((item for item in message.get("members", []) if item.get("member_id") == member_id), {})
        if predicate(member):
            return message


async def smoke(args: argparse.Namespace) -> dict[str, Any]:
    http_api = smoke_http(args.http_url or infer_http_url(args.url))
    access_token = http_api.get("access_token", "")
    device_token = http_api.get("device_token", "")
    revoked_device_token = http_api.get("revoked_device_token", "")
    busy_device_token = http_api.get("busy_device_token", "")
    location_stale_after_seconds = int(
        ((http_api.get("health", {}).get("limits", {}) or {}).get("location_stale_after_seconds") or 30)
    )
    http_api_report = {
        **http_api,
        "access_token": "redacted",
        "device_token": "redacted",
        "revoked_device_token": "redacted",
        "busy_device_token": "redacted",
    }
    base = args.url.rstrip("/")
    unauth_app_url = f"{base}/v1/radar/app/ws?room={args.room}&app_id=app-smoke-unauth&group_id=smoke-unauth"
    app_url = f"{base}/v1/radar/app/ws?room={args.room}&app_id=app-smoke&group_id=smoke&token={access_token}"
    old_app_url = f"{base}/v1/radar/app/ws?room={args.room}&app_id=app-smoke-old&group_id=smoke-old&token={access_token}"
    unauth_device_url = f"{base}/v1/radar/device/ws?room={args.room}&device_id=device-smoke-unauth&group_id=smoke-unauth"
    revoked_device_url = f"{base}/v1/radar/device/ws?room={args.room}&device_id={revoked_device_token}&group_id=smoke-revoked"
    old_device_url = f"{base}/v1/radar/device/ws?room={args.room}&device_id={busy_device_token}&group_id=smoke-old-device"
    busy_device_url = f"{base}/v1/radar/device/ws?room={args.room}&device_id={busy_device_token}&group_id=smoke-busy"
    device_url = f"{base}/v1/radar/device/ws?room={args.room}&device_id={device_token}&group_id=smoke"

    async with websockets.connect(unauth_app_url) as unauth_app:
        unauth_app_error = await recv_until(unauth_app, "error")

    async with websockets.connect(unauth_device_url) as unauth_device:
        unauth_device_error = await recv_until(unauth_device, "error")

    async with websockets.connect(revoked_device_url) as revoked_device:
        revoked_device_error = await recv_until(revoked_device, "error")

    async with websockets.connect(old_app_url) as old_app:
        old_app_ack = await recv_until(old_app, "hello_ack")
        await old_app.send(
            json.dumps(
                {
                    "type": "hello",
                    "app": "smoke-old",
                    "protocol_version": 1,
                },
                separators=(",", ":"),
            )
        )
        old_app_error = await recv_until(old_app, "error")

    async with websockets.connect(old_device_url) as old_device:
        old_device_ack = await recv_until(old_device, "hello_ack")
        await old_device.send(
            json.dumps(
                {
                    "type": "hello",
                    "firmware": "smoke-old",
                    "protocol_version": 1,
                },
                separators=(",", ":"),
            )
        )
        old_device_error = await recv_until(old_device, "error")

    async with websockets.connect(app_url) as app, websockets.connect(device_url) as device:
        app_ack = await recv_until(app, "hello_ack")
        device_ack = await recv_until(device, "hello_ack")

        await device.send(
            json.dumps(
                {
                    "type": "hello",
                    "firmware": "smoke",
                    "protocol_version": 2,
                    "min_relay_protocol_version": 2,
                    "capabilities": ["display", "ble", "wifi"],
                },
                separators=(",", ":"),
            )
        )
        app_event = await recv_until(app, "relay_event")

        await app.send(
            json.dumps(
                {
                    "type": "app_location",
                    "sequence": 7,
                    "location": {
                        "lat_e7": 312304160,
                        "lon_e7": 1214737010,
                        "h_acc_cm": 850,
                        "sequence": 7,
                    },
                },
                separators=(",", ":"),
            )
        )
        app_location_ack = await recv_until(app, "app_location_ack")
        device_event = await recv_until(device, "relay_event")

        await app.send(
            json.dumps(
                {
                    "type": "location_paused",
                    "reason": "user_paused",
                },
                separators=(",", ":"),
            )
        )
        location_paused_ack = await recv_until(app, "location_paused_ack")
        location_paused_event = await recv_until(device, "relay_event")
        location_paused_state = await recv_room_state_member(
            app,
            "smoke",
            lambda member: member.get("location_paused") is True and member.get("location") is None,
            "location_paused room_state",
        )

        await app.send(
            json.dumps(
                {
                    "type": "app_location",
                    "sequence": 8,
                    "location": {
                        "lat_e7": 312304260,
                        "lon_e7": 1214737110,
                        "h_acc_cm": 750,
                        "sequence": 8,
                    },
                },
                separators=(",", ":"),
            )
        )
        app_location_restore_ack = await recv_until(app, "app_location_ack")
        device_event_restored = await recv_until(device, "relay_event")
        location_restored_state = await recv_room_state_member(
            app,
            "smoke",
            lambda member: member.get("location_paused") is False
            and (member.get("location") or {}).get("sequence") == 8,
            "restored location room_state",
        )
        if location_stale_after_seconds <= 2:
            await asyncio.sleep(location_stale_after_seconds + 0.25)

        room_switch_request_id = "smoke-switch-1"
        await app.send(
            json.dumps(
                {
                    "type": "room_switch",
                    "request_id": room_switch_request_id,
                    "relay_url": base,
                    "room_token": args.room,
                    "device_token": device_token,
                },
                separators=(",", ":"),
            )
        )
        room_switch_ack = await recv_until(app, "room_switch_ack")
        room_switch_event = await recv_until(device, "relay_event")

        await device.send(
            json.dumps(
                {
                    "type": "device_status",
                    "device_status": {
                        "wifi": "connected",
                        "rssi": -42,
                        "ip": "172.20.10.2",
                    },
                },
                separators=(",", ":"),
            )
        )
        await device.send(
            json.dumps(
                {
                    "type": "voice_frame",
                    "codec": "pcm16le",
                    "sample_rate": 16000,
                    "frame_ms": 20,
                    "sequence": 1,
                    "ptt": True,
                    "vad": True,
                    "muted": False,
                },
                separators=(",", ":"),
            )
        )
        room_state = await recv_room_state_with_device_voice(app)

        async with websockets.connect(busy_device_url) as busy_device:
            busy_device_ack = await recv_until(busy_device, "hello_ack")
            await busy_device.send(
                json.dumps(
                    {
                        "type": "voice_frame",
                        "codec": "pcm16le",
                        "sample_rate": 16000,
                        "frame_ms": 20,
                        "sequence": 2,
                        "ptt": True,
                        "vad": True,
                        "muted": False,
                    },
                    separators=(",", ":"),
                )
            )
            busy_error = await recv_until(busy_device, "voice_busy")

    audit_status, audit = request_json(
        "GET",
        http_api.get("base_url", ""),
        "/v1/audit/events?limit=80",
        access_token=access_token,
    )
    audit_types = {event.get("event_type") for event in audit.get("events", [])}
    push_notification_types = {
        (event.get("detail") or {}).get("notification_type")
        for event in audit.get("events", [])
        if event.get("event_type") == "push_delivery"
    }
    expected_audit_types = {
        "device_register",
        "room_create",
        "room_join",
        "ws_join",
        "ws_leave",
        "room_switch",
        "location_paused",
        "voice_busy",
        "diagnostics_submit",
    }
    if http_api.get("health", {}).get("notifications", {}).get("mode") == "dry_run":
        expected_audit_types.update({"push_register", "push_delivery"})
    members = room_state.get("members", [])
    device_member = next((member for member in members if member.get("member_id") == "smoke"), {})
    location = device_member.get("location", {})
    ok = (
        app_ack.get("type") == "hello_ack"
        and unauth_app_error.get("code") == "unauthorized"
        and unauth_device_error.get("code") == "unauthorized"
        and revoked_device_error.get("code") == "device_revoked"
        and device_ack.get("type") == "hello_ack"
        and int((app_ack.get("protocol") or {}).get("relay") or 0) >= 2
        and int((device_ack.get("protocol") or {}).get("relay") or 0) >= 2
        and old_app_ack.get("type") == "hello_ack"
        and old_app_error.get("code") == "protocol_unsupported"
        and old_app_error.get("required_protocol") == 2
        and old_device_ack.get("type") == "hello_ack"
        and old_device_error.get("code") == "protocol_unsupported"
        and old_device_error.get("required_protocol") == 2
        and app_event.get("event") == "hello"
        and app_location_ack.get("sequence") == 7
        and device_event.get("event") == "app_location"
        and device_event.get("payload", {}).get("sequence") == 7
        and location_paused_ack.get("type") == "location_paused_ack"
        and location_paused_event.get("event") == "location_paused"
        and next((member for member in location_paused_state.get("members", []) if member.get("member_id") == "smoke"), {}).get("location_paused") is True
        and app_location_restore_ack.get("sequence") == 8
        and device_event_restored.get("event") == "app_location"
        and device_event_restored.get("payload", {}).get("sequence") == 8
        and next((member for member in location_restored_state.get("members", []) if member.get("member_id") == "smoke"), {}).get("location_paused") is False
        and room_switch_ack.get("request_id") == "smoke-switch-1"
        and room_switch_ack.get("delivered_devices") == 1
        and room_switch_event.get("event") == "room_switch"
        and (room_switch_event.get("payload") or {}).get("request_id") == "smoke-switch-1"
        and busy_device_ack.get("type") == "hello_ack"
        and busy_error.get("type") == "voice_busy"
        and busy_error.get("speaker_group_id") == "smoke"
        and len(members) == 1
        and device_member.get("connection_count") == 2
        and device_member.get("app_online") is True
        and device_member.get("device_online") is True
        and device_member.get("location_paused") is False
        and location.get("sequence") == 8
        and (
            location_stale_after_seconds > 2
            or (
                device_member.get("location_stale") is True
                and int(device_member.get("location_age_ms") or 0) >= location_stale_after_seconds * 1000
            )
        )
        and device_member.get("last_type") == "voice_frame"
        and room_state.get("voice_floor", {}).get("active") is True
        and device_member.get("voice_status", {}).get("vad") is True
        and device_member.get("voice_status", {}).get("ptt") is True
        and device_member.get("voice_status", {}).get("codec") == "pcm16le"
        and audit_status == 200
        and expected_audit_types.issubset(audit_types)
        and (
            http_api.get("health", {}).get("notifications", {}).get("mode") != "dry_run"
            or {"room_invite", "voice_busy", "device_offline"}.issubset(push_notification_types)
        )
    )
    return {
        "ok": ok and http_api.get("ok") is True,
        "http_api": http_api_report,
        "unauth_app_error": unauth_app_error,
        "unauth_device_error": unauth_device_error,
        "revoked_device_error": revoked_device_error,
        "old_app_ack": old_app_ack,
        "old_app_error": old_app_error,
        "old_device_ack": old_device_ack,
        "old_device_error": old_device_error,
        "app_ack": app_ack,
        "device_ack": device_ack,
        "app_event": app_event,
        "app_location_ack": app_location_ack,
        "device_event": device_event,
        "location_paused_ack": location_paused_ack,
        "location_paused_event": location_paused_event,
        "location_paused_state": location_paused_state,
        "app_location_restore_ack": app_location_restore_ack,
        "device_event_restored": device_event_restored,
        "location_restored_state": location_restored_state,
        "room_switch_ack": room_switch_ack,
        "room_switch_event": room_switch_event,
        "busy_device_ack": busy_device_ack,
        "busy_error": busy_error,
        "room_state": room_state,
        "location_stale_after_seconds": location_stale_after_seconds,
        "audit_status": audit_status,
        "audit_types": sorted(item for item in audit_types if item),
        "push_notification_types": sorted(item for item in push_notification_types if item),
    }


def main() -> int:
    args = parse_args()
    try:
        result = asyncio.run(smoke(args))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc), "traceback": traceback.format_exc()}, ensure_ascii=False, indent=2))
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
