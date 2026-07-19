#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import os
import re
import sys
import traceback
from typing import Any
from urllib import error
from urllib import request
from urllib.parse import quote, urlparse, urlunparse

import websockets


DEFAULT_PAIRING_HMAC_KEY = "dragon-radar-dev-pairing-key"
DEFAULT_MODERATION_HMAC_KEY = "dragon-radar-dev-moderation-key"


def pairing_response_valid(challenge: str, response: str) -> bool:
    parts = response.split(":")
    if len(parts) != 5 or parts[:2] != ["dra-pair", "v2"]:
        return False
    _, _, device_id, nonce, signature = parts
    message = f"v2|{challenge}|{device_id}|{nonce}".encode("utf-8")
    key = (os.environ.get("DRAGON_RADAR_PAIRING_HMAC_KEY") or DEFAULT_PAIRING_HMAC_KEY).encode("utf-8")
    expected = hmac.new(key, message, hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature, expected)


def moderation_ref_for_user(room_code: str, user_id: str) -> str:
    key = (
        os.environ.get("DRAGON_RADAR_MODERATION_HMAC_KEY")
        or DEFAULT_MODERATION_HMAC_KEY
    ).encode("utf-8")
    message = f"dragon-radar-moderation-v1|{room_code.strip().upper()}|{user_id.strip()}".encode("utf-8")
    digest = hmac.new(key, message, hashlib.sha256).digest()
    encoded = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return "mod_v1_" + encoded


def websocket_headers(token: str) -> dict[str, str]:
    clean_token = token.strip()
    return {"Authorization": f"Bearer {clean_token}"} if clean_token else {}


def contains_raw_room_identity(value: Any) -> bool:
    forbidden_keys = {"owner_user_id", "user_id", "member_id"}
    if isinstance(value, dict):
        return any(
            str(key) in forbidden_keys or contains_raw_room_identity(item)
            for key, item in value.items()
        )
    if isinstance(value, list):
        return any(contains_raw_room_identity(item) for item in value)
    return False


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Smoke test the Capsule Relay WebSocket protocol.")
    parser.add_argument("--url", default="ws://127.0.0.1:8787", help="Relay base URL.")
    parser.add_argument("--http-url", default="", help="Relay HTTP API base URL. Defaults to ws port + 1.")
    parser.add_argument("--room", default="DRGN-TEST", help="Room code.")
    parser.add_argument(
        "--expect-firmware",
        action="store_true",
        help="Require and exercise the signed firmware manifest/artifact endpoints.",
    )
    parser.add_argument(
        "--expect-retained-artifact",
        default="",
        help="Immutable previous artifact basename that must remain downloadable.",
    )
    parser.add_argument("--expect-retained-sha256", default="")
    parser.add_argument("--expect-retained-size", type=int, default=0)
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


def request_json_with_headers(
    method: str,
    base_url: str,
    path: str,
    payload: dict[str, Any] | None = None,
    access_token: str = "",
) -> tuple[int, dict[str, str], dict[str, Any]]:
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
            response_headers = {name.lower(): value for name, value in response.headers.items()}
            return response.status, response_headers, json.loads(body) if body else {}
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8")
        response_headers = {name.lower(): value for name, value in exc.headers.items()}
        return exc.code, response_headers, json.loads(body) if body else {}


def request_bytes(
    method: str,
    base_url: str,
    path: str,
    access_token: str = "",
    headers: dict[str, str] | None = None,
) -> tuple[int, dict[str, str], bytes]:
    request_headers = {"Accept": "application/octet-stream", **(headers or {})}
    if access_token:
        request_headers["Authorization"] = f"Bearer {access_token}"
    req = request.Request(
        f"{base_url.rstrip('/')}{path}",
        headers=request_headers,
        method=method,
    )
    try:
        with request.urlopen(req, timeout=4) as response:
            response_headers = {name.lower(): value for name, value in response.headers.items()}
            return response.status, response_headers, response.read()
    except error.HTTPError as exc:
        response_headers = {name.lower(): value for name, value in exc.headers.items()}
        return exc.code, response_headers, exc.read()


def smoke_http(
    base_url: str,
    expect_firmware: bool = False,
    retained_artifact: str = "",
    retained_sha256: str = "",
    retained_size: int = 0,
) -> dict[str, Any]:
    health_status, health = request_json("GET", base_url, "/healthz")
    limits = health.get("limits", {}) if isinstance(health.get("limits"), dict) else {}
    protocol = health.get("protocol", {}) if isinstance(health.get("protocol"), dict) else {}
    notifications = health.get("notifications", {}) if isinstance(health.get("notifications"), dict) else {}
    moderation = health.get("moderation", {}) if isinstance(health.get("moderation"), dict) else {}
    retention = health.get("retention", {}) if isinstance(health.get("retention"), dict) else {}
    retention_days = (
        retention.get("retention_days", {})
        if isinstance(retention.get("retention_days"), dict)
        else {}
    )
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
    original_access_token = session.get("access_token", "")
    refresh_status, refreshed = request_json(
        "POST",
        base_url,
        "/v1/auth/refresh",
        {"refresh_token": session.get("refresh_token", "")},
    )
    refreshed_session = refreshed.get("session", {})
    access_token = refreshed_session.get("access_token", "") or original_access_token
    rotated_access_status, rotated_access = request_json(
        "GET",
        base_url,
        "/v1/rooms",
        access_token=original_access_token,
    )
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
        {
            "pairing_challenge": "CR-A17C-00112233445566778899AABBCCDDEEFF",
            "name": "Ｓｍｏｋｅ\u202e ESP",
        },
        access_token,
    )
    device = registered_device.get("device", {})
    duplicate_device_status, duplicate_device = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {
            "pairing_challenge": "CR-A17C-FFEEDDCCBBAA99887766554433221100",
            "name": "Smoke ESP Again",
        },
        access_token,
    )
    other_auth_status, other_auth = request_json(
        "POST",
        base_url,
        "/v1/auth/apple",
        {"apple_user_id": "smoke-user-other", "display_name": "Other Smoke User", "identity_token": "development"},
    )
    other_session = other_auth.get("session", {})
    other_token = other_session.get("access_token", "")
    outsider_auth_status, outsider_auth = request_json(
        "POST",
        base_url,
        "/v1/auth/apple",
        {"apple_user_id": "smoke-user-outsider", "display_name": "Outsider Smoke User", "identity_token": "development"},
    )
    outsider_session = outsider_auth.get("session", {})
    outsider_token = outsider_session.get("access_token", "")
    stolen_device_status, stolen_device = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {
            "pairing_challenge": "CR-A17C-FFEEDDCCBBAA99887766554433221100",
            "name": "Stolen ESP",
        },
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
    target_device_register_status, target_registered_device = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {"pairing_challenge": "smoke-target-E55G", "name": "Target ESP"},
        other_token,
    )
    target_device = target_registered_device.get("device", {})
    revoke_status, revoked_device = request_json(
        "DELETE",
        base_url,
        f"/v1/devices/{revoke_device.get('device_id', '')}",
        access_token=access_token,
    )

    firmware_health = health.get("firmware", {}) if isinstance(health.get("firmware"), dict) else {}
    firmware_checks: dict[str, Any] = {
        "expected": expect_firmware,
        "available": firmware_health.get("available") is True,
    }
    firmware_ok = not expect_firmware
    if expect_firmware:
        manifest_unauth_status, manifest_unauth = request_json("GET", base_url, "/v1/firmware/manifest")
        manifest_status, manifest = request_json(
            "GET",
            base_url,
            "/v1/firmware/manifest?hardware=esp32-s3-touch-amoled-1.75c&channel=stable",
            access_token=access_token,
        )
        hardware = str(manifest.get("hardware") or "")
        hardware_miss_status, hardware_miss = request_json(
            "GET",
            base_url,
            f"/v1/firmware/manifest?hardware={quote(hardware + '-wrong', safe='')}",
            access_token=access_token,
        )
        channel_miss_status, channel_miss = request_json(
            "GET",
            base_url,
            "/v1/firmware/manifest?channel=beta",
            access_token=access_token,
        )
        artifact_path = str(manifest.get("artifact_url") or "")
        artifact_unauth_status, _, artifact_unauth_body = request_bytes("GET", base_url, artifact_path)
        artifact_user_status, artifact_user_headers, artifact_user_body = request_bytes(
            "GET",
            base_url,
            artifact_path,
            access_token,
        )
        artifact_device_status, artifact_device_headers, artifact_device_body = request_bytes(
            "GET",
            base_url,
            artifact_path,
            str(device.get("device_token") or ""),
            {"Range": "bytes=1-"},
        )
        artifact_head_status, artifact_head_headers, artifact_head_body = request_bytes(
            "HEAD",
            base_url,
            artifact_path,
            access_token,
        )
        artifact_bad_range_status, artifact_bad_range_headers, artifact_bad_range_body = request_bytes(
            "GET",
            base_url,
            artifact_path,
            access_token,
            {"Range": "bytes=999999999-"},
        )
        artifact_revoked_status, _, artifact_revoked_body = request_bytes(
            "GET",
            base_url,
            artifact_path,
            str(revoke_device.get("device_token") or ""),
        )
        retained_checks: dict[str, Any] = {"expected": bool(retained_artifact)}
        retained_ok = not retained_artifact
        if retained_artifact:
            retained_path = "/v1/firmware/artifacts/" + quote(retained_artifact, safe="")
            retained_unauth_status, _, retained_unauth_body = request_bytes(
                "GET", base_url, retained_path
            )
            retained_status, retained_headers, retained_body = request_bytes(
                "GET", base_url, retained_path, access_token
            )
            retained_range_status, retained_range_headers, retained_range_body = request_bytes(
                "GET",
                base_url,
                retained_path,
                str(device.get("device_token") or ""),
                {"Range": "bytes=1-"},
            )
            retained_ok = (
                retained_path != artifact_path
                and retained_size > 1
                and retained_unauth_status == 401
                and json.loads(retained_unauth_body.decode("utf-8")).get("code") == "unauthorized"
                and retained_status == 200
                and len(retained_body) == retained_size
                and hashlib.sha256(retained_body).hexdigest() == retained_sha256
                and retained_headers.get("etag") == f'"{retained_sha256}"'
                and retained_headers.get("cache-control") == "private, max-age=86400, immutable"
                and retained_range_status == 206
                and retained_range_body == retained_body[1:]
                and retained_range_headers.get("content-range")
                == f"bytes 1-{retained_size - 1}/{retained_size}"
            )
            retained_checks = {
                "expected": True,
                "ok": retained_ok,
                "artifact_status": retained_status,
                "artifact_range_status": retained_range_status,
                "artifact_unauth_status": retained_unauth_status,
                "artifact_size": len(retained_body),
                "artifact_sha256": hashlib.sha256(retained_body).hexdigest(),
            }
        expected_size = int(manifest.get("size") or 0)
        expected_sha256 = str(manifest.get("sha256") or "")
        firmware_ok = (
            firmware_health.get("available") is True
            and firmware_health.get("development") is False
            and manifest_unauth_status == 401
            and manifest_unauth.get("code") == "unauthorized"
            and manifest_status == 200
            and manifest.get("schema") == 1
            and manifest.get("hardware") == "esp32-s3-touch-amoled-1.75c"
            and manifest.get("signature_algorithm") == "ecdsa-p256-sha256"
            and manifest.get("key_id") == "local-2026-01"
            and isinstance(manifest.get("signed_payload"), str)
            and artifact_path.startswith("/v1/firmware/artifacts/")
            and "://" not in artifact_path
            and hardware_miss_status == 404
            and hardware_miss.get("code") == "firmware_release_not_found"
            and channel_miss_status == 404
            and channel_miss.get("code") == "firmware_release_not_found"
            and artifact_unauth_status == 401
            and json.loads(artifact_unauth_body.decode("utf-8")).get("code") == "unauthorized"
            and artifact_user_status == 200
            and len(artifact_user_body) == expected_size
            and hashlib.sha256(artifact_user_body).hexdigest() == expected_sha256
            and artifact_user_headers.get("accept-ranges") == "bytes"
            and artifact_user_headers.get("etag") == f'"{expected_sha256}"'
            and artifact_device_status == 206
            and artifact_device_body == artifact_user_body[1:]
            and artifact_device_headers.get("content-range") == f"bytes 1-{expected_size - 1}/{expected_size}"
            and artifact_head_status == 200
            and artifact_head_body == b""
            and artifact_head_headers.get("content-length") == str(expected_size)
            and artifact_bad_range_status == 416
            and artifact_bad_range_headers.get("content-range") == f"bytes */{expected_size}"
            and artifact_bad_range_body == b""
            and artifact_revoked_status == 403
            and json.loads(artifact_revoked_body.decode("utf-8")).get("code") == "device_revoked"
            and retained_ok
        )
        firmware_checks = {
            **firmware_checks,
            "ok": firmware_ok,
            "manifest_status": manifest_status,
            "manifest_unauth_status": manifest_unauth_status,
            "hardware_miss_status": hardware_miss_status,
            "channel_miss_status": channel_miss_status,
            "artifact_unauth_status": artifact_unauth_status,
            "artifact_user_status": artifact_user_status,
            "artifact_device_status": artifact_device_status,
            "artifact_head_status": artifact_head_status,
            "artifact_bad_range_status": artifact_bad_range_status,
            "artifact_revoked_status": artifact_revoked_status,
            "artifact_size": len(artifact_user_body),
            "artifact_sha256": hashlib.sha256(artifact_user_body).hexdigest(),
            "retained": retained_checks,
        }
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
    primary_push_token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    target_push_token = "1123456789abcdef1123456789abcdef1123456789abcdef1123456789abcdef"
    migration_push_token = "2123456789abcdef2123456789abcdef2123456789abcdef2123456789abcdef"
    push_register_status, push_registered = request_json(
        "POST",
        base_url,
        "/v1/push/register",
        {
            "device_token": primary_push_token,
            "platform": "ios",
            "environment": "sandbox",
            "app_version": "smoke",
        },
        access_token,
    )
    push_unregister_other_status, push_unregister_other = request_json(
        "DELETE",
        base_url,
        "/v1/push/register",
        {"device_token": primary_push_token},
        other_token,
    )
    push_unregister_owner_status, push_unregister_owner = request_json(
        "DELETE",
        base_url,
        "/v1/push/register",
        {"device_token": primary_push_token},
        access_token,
    )
    push_reregister_status, _ = request_json(
        "POST",
        base_url,
        "/v1/push/register",
        {
            "device_token": primary_push_token,
            "platform": "ios",
            "environment": "sandbox",
            "app_version": "smoke-reregistered",
        },
        access_token,
    )
    migration_register_owner_status, _ = request_json(
        "POST",
        base_url,
        "/v1/push/register",
        {"device_token": migration_push_token, "platform": "ios", "environment": "sandbox"},
        access_token,
    )
    migration_register_other_status, _ = request_json(
        "POST",
        base_url,
        "/v1/push/register",
        {"device_token": migration_push_token, "platform": "ios", "environment": "sandbox"},
        other_token,
    )
    migration_old_owner_delete_status, _ = request_json(
        "DELETE",
        base_url,
        "/v1/push/register",
        {"device_token": migration_push_token},
        access_token,
    )
    migration_new_owner_delete_status, migration_new_owner_delete = request_json(
        "DELETE",
        base_url,
        "/v1/push/register",
        {"device_token": migration_push_token},
        other_token,
    )
    target_push_register_status, _ = request_json(
        "POST",
        base_url,
        "/v1/push/register",
        {
            "device_token": target_push_token,
            "platform": "ios",
            "environment": "sandbox",
            "app_version": "smoke-target",
        },
        other_token,
    )
    list_devices_status, listed_devices = request_json("GET", base_url, "/v1/devices", access_token=access_token)
    prohibited_room_status, prohibited_room = request_json(
        "POST",
        base_url,
        "/v1/rooms",
        {"name": "kill yourself"},
        access_token,
    )
    create_status, created = request_json(
        "POST",
        base_url,
        "/v1/rooms",
        {"name": "Ｓｍｏｋｅ\u202e Test Room"},
        access_token,
    )
    room = created.get("room", {})
    room_code = room.get("room_code", "")
    join_status, joined = request_json(
        "POST",
        base_url,
        "/v1/rooms/join",
        {"room_code": room_code, "display_name": "Smoke Member"},
        other_token,
    )
    member_get_status, member_fetched = request_json(
        "GET",
        base_url,
        f"/v1/rooms/{room_code}",
        access_token=other_token,
    )
    outsider_get_status, outsider_get = request_json(
        "GET",
        base_url,
        f"/v1/rooms/{room_code}",
        access_token=outsider_token,
    )
    member_patch_status, member_patch = request_json(
        "PATCH",
        base_url,
        f"/v1/rooms/{room_code}",
        {"name": "Unauthorized Member Rename"},
        other_token,
    )
    outsider_patch_status, outsider_patch = request_json(
        "PATCH",
        base_url,
        f"/v1/rooms/{room_code}",
        {"name": "Unauthorized Outsider Rename"},
        outsider_token,
    )
    patch_status, renamed = request_json("PATCH", base_url, f"/v1/rooms/{room_code}", {"name": "Smoke Renamed Room"}, access_token)
    member_invite_status, member_invite = request_json(
        "POST",
        base_url,
        f"/v1/rooms/{room_code}/invite",
        {},
        other_token,
    )
    outsider_invite_status, outsider_invite = request_json(
        "POST",
        base_url,
        f"/v1/rooms/{room_code}/invite",
        {},
        outsider_token,
    )
    invite_status, invite = request_json(
        "POST",
        base_url,
        f"/v1/rooms/{room_code}/invite",
        {"target_user_id": other_session.get("user_id", "")},
        access_token,
    )
    list_status, listed = request_json("GET", base_url, "/v1/rooms", access_token=access_token)
    get_status, fetched = request_json("GET", base_url, f"/v1/rooms/{room_code}", access_token=access_token)
    room_responses_have_no_raw_identity = not contains_raw_room_identity(
        {
            "created": created.get("room", {}),
            "joined": joined.get("room", {}),
            "member_fetched": member_fetched.get("room", {}),
            "renamed": renamed.get("room", {}),
            "listed": listed.get("rooms", []),
            "fetched": fetched.get("room", {}),
        }
    )
    room_response_text = json.dumps(
        {
            "created": created.get("room", {}),
            "joined": joined.get("room", {}),
            "member_fetched": member_fetched.get("room", {}),
            "renamed": renamed.get("room", {}),
            "listed": listed.get("rooms", []),
            "fetched": fetched.get("room", {}),
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    room_responses_have_no_account_ids = not any(
        account_id and account_id in room_response_text
        for account_id in (
            str(session.get("user_id") or ""),
            str(other_session.get("user_id") or ""),
            str(outsider_session.get("user_id") or ""),
        )
    )
    other_member_id = str(other_session.get("user_id") or "")
    remove_status, removed = request_json(
        "DELETE",
        base_url,
        f"/v1/rooms/{room_code}/members/{other_member_id}",
        access_token=access_token,
    )
    delete_status, deleted = request_json("DELETE", base_url, f"/v1/rooms/{room_code}", access_token=access_token)
    get_deleted_status, get_deleted = request_json("GET", base_url, f"/v1/rooms/{room_code}", access_token=access_token)
    live_create_status, live_created = request_json(
        "POST",
        base_url,
        "/v1/rooms",
        {"name": "Smoke Live Relay Room"},
        access_token,
    )
    live_room = live_created.get("room", {})
    live_room_code = str(live_room.get("room_code") or "")
    live_join_status, live_joined = request_json(
        "POST",
        base_url,
        "/v1/rooms/join",
        {"room_code": live_room_code},
        other_token,
    )
    deletion_auth_status, deletion_auth = request_json(
        "POST",
        base_url,
        "/v1/auth/apple",
        {
            "apple_user_id": "smoke-user-delete",
            "display_name": "Deletion Smoke User",
            "identity_token": "development",
        },
    )
    deletion_session = deletion_auth.get("session", {})
    deletion_token = str(deletion_session.get("access_token") or "")
    deletion_room_status, deletion_room = request_json(
        "POST",
        base_url,
        "/v1/rooms",
        {"name": "Deletion Smoke Room"},
        deletion_token,
    )
    deletion_room_code = str(deletion_room.get("room", {}).get("room_code") or "")
    deletion_target_join_status, _ = request_json(
        "POST",
        base_url,
        "/v1/rooms/join",
        {"room_code": deletion_room_code},
        outsider_token,
    )
    deletion_target_ref = moderation_ref_for_user(
        deletion_room_code,
        str(outsider_session.get("user_id") or ""),
    )
    deletion_report_status, deletion_report = request_json(
        "POST",
        base_url,
        "/v1/reports",
        {
            "room_code": deletion_room_code,
            "moderation_ref": deletion_target_ref,
            "content_type": "behavior",
            "category": "harassment",
            "details": "Account deletion cleanup report",
        },
        deletion_token,
    )
    deletion_block_status, deletion_block = request_json(
        "POST",
        base_url,
        "/v1/blocks",
        {
            "room_code": deletion_room_code,
            "moderation_ref": deletion_target_ref,
        },
        deletion_token,
    )
    deletion_join_status, _ = request_json(
        "POST",
        base_url,
        "/v1/rooms/join",
        {"room_code": live_room_code, "display_name": "Deletion Smoke Member"},
        deletion_token,
    )
    deletion_device_status, _ = request_json(
        "POST",
        base_url,
        "/v1/devices/register-challenge",
        {"pairing_challenge": "smoke-delete-D44F", "name": "Deletion Smoke ESP"},
        deletion_token,
    )
    deletion_diagnostics_status, _ = request_json(
        "POST",
        base_url,
        "/v1/diagnostics",
        {"report": {"app": {"version": "delete-smoke"}}},
        deletion_token,
    )
    deletion_push_status, _ = request_json(
        "POST",
        base_url,
        "/v1/push/register",
        {
            "device_token": "3123456789abcdef3123456789abcdef3123456789abcdef3123456789abcdef",
            "platform": "ios",
            "environment": "sandbox",
        },
        deletion_token,
    )
    account_delete_status, account_deleted = request_json(
        "DELETE",
        base_url,
        "/v1/account",
        access_token=deletion_token,
    )
    deleted_session_status, deleted_session = request_json(
        "GET",
        base_url,
        "/v1/rooms",
        access_token=deletion_token,
    )
    deleted_owned_room_status, deleted_owned_room = request_json(
        "GET",
        base_url,
        f"/v1/rooms/{deletion_room_code}",
        access_token=access_token,
    )
    deletion_reauth_status, deletion_reauth = request_json(
        "POST",
        base_url,
        "/v1/auth/apple",
        {
            "apple_user_id": "smoke-user-delete",
            "display_name": "Deletion Smoke User",
            "identity_token": "development",
        },
    )
    deletion_reauth_token = str(deletion_reauth.get("session", {}).get("access_token") or "")
    deletion_reauth_rooms_status, deletion_reauth_rooms = request_json(
        "GET",
        base_url,
        "/v1/rooms",
        access_token=deletion_reauth_token,
    )
    deletion_reauth_blocks_status, deletion_reauth_blocks = request_json(
        "GET",
        base_url,
        "/v1/blocks",
        access_token=deletion_reauth_token,
    )

    fetched_room = fetched.get("room", {})
    ok = (
        health_status == 200
        and health.get("ok") is True
        and int(protocol.get("relay") or 0) >= 2
        and int(protocol.get("min_app") or 0) >= 2
        and int(protocol.get("min_device") or 0) >= 2
        and int(protocol.get("location_frame") or 0) == 1
        and int(protocol.get("voice") or 0) == 1
        and moderation.get("enabled") is True
        and isinstance(moderation.get("hmac_key_configured"), bool)
        and isinstance(moderation.get("production_ready"), bool)
        and int(moderation.get("blocked_terms_count") or 0) >= 5
        and "hmac_key" not in moderation
        and "secret" not in json.dumps(moderation, ensure_ascii=False).lower()
        and "harassment" in moderation.get("report_categories", [])
        and "voice" in moderation.get("report_types", [])
        and retention.get("configured") is True
        and int(retention_days.get("diagnostics_reports") or 0) == 30
        and int(retention_days.get("audit_events") or 0) == 90
        and int(retention_days.get("radar_reminders") or 0) == 90
        and int(retention_days.get("content_reports") or 0) == 365
        and int(retention.get("cleanup_interval_seconds") or 0) >= 60
        and int(retention.get("last_cleanup_at") or 0) > 0
        and "last_cleanup_deleted" in retention
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
        and rotated_access_status == 401
        and rotated_access.get("code") == "unauthorized"
        and device_unauth_status == 401
        and device_unauth.get("code") == "unauthorized"
        and register_device_status == 201
        and device.get("device_token", "").startswith("ddt_")
        and device.get("name") == "Smoke ESP"
        and device.get("device_short_id") == "A17C"
        and pairing_response_valid(
            "CR-A17C-00112233445566778899AABBCCDDEEFF",
            device.get("pairing_response", ""),
        )
        and duplicate_device_status == 201
        and duplicate_device.get("device", {}).get("device_id") == device.get("device_id")
        and duplicate_device.get("device", {}).get("device_token") == device.get("device_token")
        and pairing_response_valid(
            "CR-A17C-FFEEDDCCBBAA99887766554433221100",
            duplicate_device.get("device", {}).get("pairing_response", ""),
        )
        and other_auth_status == 200
        and outsider_auth_status == 200
        and stolen_device_status == 403
        and stolen_device.get("code") == "device_already_bound"
        and revoke_register_status == 201
        and busy_register_status == 201
        and busy_device.get("device_token", "").startswith("ddt_")
        and target_device_register_status == 201
        and target_device.get("device_token", "").startswith("ddt_")
        and revoke_status == 200
        and revoked_device.get("device", {}).get("revoked_at", 0) > 0
        and diagnostics_unauth_status == 401
        and diagnostics_unauth.get("code") == "unauthorized"
        and diagnostics_status == 201
        and diagnostics.get("diagnostics", {}).get("report_id", "").startswith("diag_")
        and push_register_status == 201
        and push_registered.get("subscription", {}).get("device_token", "").endswith("abcdef")
        and push_unregister_other_status == 404
        and push_unregister_other.get("code") == "push_subscription_not_found"
        and push_unregister_owner_status == 200
        and push_unregister_owner.get("ok") is True
        and push_reregister_status == 201
        and migration_register_owner_status == 201
        and migration_register_other_status == 201
        and migration_old_owner_delete_status == 404
        and migration_new_owner_delete_status == 200
        and migration_new_owner_delete.get("ok") is True
        and target_push_register_status == 201
        and list_devices_status == 200
        and any(item.get("device_id") == device.get("device_id") for item in listed_devices.get("devices", []))
        and not any(item.get("device_id") == revoke_device.get("device_id") for item in listed_devices.get("devices", []))
        and create_status == 201
        and room.get("name") == "Smoke Test Room"
        and prohibited_room_status == 400
        and prohibited_room.get("code") == "prohibited_name"
        and room.get("max_members") == 7
        and join_status == 200
        and joined.get("room", {}).get("member_count") == 2
        and member_get_status == 200
        and member_fetched.get("room", {}).get("room_code") == room_code
        and outsider_get_status == 403
        and outsider_get.get("code") == "not_room_member"
        and member_patch_status == 403
        and member_patch.get("code") == "forbidden"
        and outsider_patch_status == 403
        and outsider_patch.get("code") == "not_room_member"
        and patch_status == 200
        and renamed.get("room", {}).get("name") == "Smoke Renamed Room"
        and member_invite_status == 201
        and member_invite.get("invite", {}).get("invite_code") == room_code
        and outsider_invite_status == 403
        and outsider_invite.get("code") == "not_room_member"
        and invite_status == 201
        and invite.get("invite", {}).get("invite_code") == room_code
        and invite.get("notification", {}).get("status") == ("dry_run" if notifications.get("mode") == "dry_run" else "skipped")
        and list_status == 200
        and any(item.get("room_code") == room_code for item in listed.get("rooms", []))
        and get_status == 200
        and fetched_room.get("room_code") == room_code
        and fetched_room.get("member_count") == 2
        and room_responses_have_no_raw_identity
        and room_responses_have_no_account_ids
        and remove_status == 200
        and removed.get("room", {}).get("member_count") == 1
        and not contains_raw_room_identity(removed.get("room", {}))
        and not any(
            account_id and account_id in json.dumps(removed.get("room", {}), ensure_ascii=False)
            for account_id in (
                str(session.get("user_id") or ""),
                str(other_session.get("user_id") or ""),
            )
        )
        and delete_status == 200
        and deleted.get("ok") is True
        and get_deleted_status == 404
        and get_deleted.get("code") == "invalid_room"
        and live_create_status == 201
        and live_room_code.startswith("CAPS-")
        and live_join_status == 200
        and live_joined.get("room", {}).get("member_count") == 2
        and any(
            member.get("display_name") == "Other Smoke User"
            for member in live_joined.get("room", {}).get("members", [])
        )
        and "apple:" not in json.dumps(live_joined.get("room", {}), ensure_ascii=False)
        and deletion_auth_status == 200
        and deletion_room_status == 201
        and deletion_target_join_status == 200
        and deletion_report_status == 201
        and deletion_report.get("report", {}).get("case_number", "").startswith("DR-")
        and deletion_block_status == 201
        and deletion_block.get("block", {}).get("block_id", "").startswith("blk_")
        and deletion_join_status == 200
        and deletion_device_status == 201
        and deletion_diagnostics_status == 201
        and deletion_push_status == 201
        and account_delete_status == 200
        and account_deleted.get("ok") is True
        and account_deleted.get("deletion", {}).get("users") == 1
        and account_deleted.get("deletion", {}).get("owned_rooms") == 1
        and account_deleted.get("deletion", {}).get("devices") == 1
        and account_deleted.get("deletion", {}).get("push_subscriptions") == 1
        and account_deleted.get("deletion", {}).get("diagnostics") == 1
        and account_deleted.get("deletion", {}).get("content_reports") == 1
        and account_deleted.get("deletion", {}).get("user_blocks") == 1
        and account_deleted.get("apple_access_revocation", {}).get("status") == "manual_required"
        and deleted_session_status == 401
        and deleted_session.get("code") == "unauthorized"
        and deleted_owned_room_status == 404
        and deleted_owned_room.get("code") == "invalid_room"
        and deletion_reauth_status == 200
        and deletion_reauth_rooms_status == 200
        and deletion_reauth_rooms.get("rooms") == []
        and deletion_reauth_blocks_status == 200
        and deletion_reauth_blocks.get("blocks") == []
        and firmware_ok
    )
    return {
        "ok": ok,
        "base_url": base_url,
        "room_code": live_room_code,
        "access_token": access_token,
        "other_access_token": other_token,
        "other_user_id": str(other_session.get("user_id") or ""),
        "outsider_access_token": outsider_token,
        "device_token": device.get("device_token", ""),
        "health": health,
        "account_deletion": {
            "status": account_delete_status,
            "body": account_deleted,
            "old_session_status": deleted_session_status,
            "deleted_room_status": deleted_owned_room_status,
            "reauth_status": deletion_reauth_status,
            "reauth_rooms_status": deletion_reauth_rooms_status,
            "reauth_blocks_status": deletion_reauth_blocks_status,
        },
        "firmware": firmware_checks,
        "oversized": oversized,
        "unauth": unauth,
        "invalid_auth": invalid_auth,
        "prohibited_room": {"status": prohibited_room_status, "body": prohibited_room},
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
        "target_device_token": target_device.get("device_token", ""),
        "diagnostics": diagnostics,
        "push_registered": {
            "subscription": {
                **push_registered.get("subscription", {}),
                "device_token": "redacted",
            }
        },
        "push_unregister_other": push_unregister_other,
        "push_unregister_owner": push_unregister_owner,
        "push_migration_new_owner_delete": migration_new_owner_delete,
        "listed_devices_count": len(listed_devices.get("devices", [])),
        "created": created,
        "joined": joined,
        "member_get": {"status": member_get_status, "body": member_fetched},
        "outsider_get": {"status": outsider_get_status, "body": outsider_get},
        "member_patch": {"status": member_patch_status, "body": member_patch},
        "outsider_patch": {"status": outsider_patch_status, "body": outsider_patch},
        "renamed": renamed,
        "member_invite": {"status": member_invite_status, "body": member_invite},
        "outsider_invite": {"status": outsider_invite_status, "body": outsider_invite},
        "invite": invite,
        "room_response_identity_redacted": (
            room_responses_have_no_raw_identity and room_responses_have_no_account_ids
        ),
        "listed_count": len(listed.get("rooms", [])),
        "fetched": fetched,
        "removed": removed,
        "deleted": deleted,
        "get_deleted": get_deleted,
        "live_created": live_created,
        "live_joined": live_joined,
    }


def redact_sensitive_output(value: Any, key: str = "") -> Any:
    normalized_key = key.lower()
    if any(marker in normalized_key for marker in ("token", "password", "secret", "authorization", "pairing_response")):
        return "redacted"
    if isinstance(value, dict):
        return {name: redact_sensitive_output(item, str(name)) for name, item in value.items()}
    if isinstance(value, list):
        return [redact_sensitive_output(item) for item in value]
    if isinstance(value, str):
        return re.sub(r"\b(?:ddt|dra|drr)_[A-Za-z0-9_-]+", "redacted", value)
    return value


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


async def assert_no_message_type(socket: Any, message_type: str, timeout: float = 0.35) -> bool:
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            return True
        try:
            message = await recv_json(socket, timeout=remaining)
        except asyncio.TimeoutError:
            return True
        if message.get("type") == message_type:
            return False


async def wait_for_socket_close(socket: Any, timeout: float = 4.0) -> dict[str, Any]:
    async def consume_until_closed() -> dict[str, Any]:
        try:
            while True:
                await socket.recv()
        except websockets.ConnectionClosed as exc:
            return {"closed": True, "code": exc.code, "reason": exc.reason}

    try:
        return await asyncio.wait_for(consume_until_closed(), timeout=timeout)
    except asyncio.TimeoutError:
        return {"closed": False, "code": None, "reason": "timeout"}


async def recv_room_state_matching(socket: Any, predicate: Any, description: str, timeout: float = 4.0) -> dict[str, Any]:
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            raise TimeoutError(f"timed out waiting for {description}")
        message = await recv_json(socket, timeout=remaining)
        if message.get("type") == "room_state" and predicate(message):
            return message


async def recv_room_state_with_device_voice(
    socket: Any,
    member_id: str,
    timeout: float = 4.0,
) -> dict[str, Any]:
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
        device_member = next((member for member in members if member.get("member_id") == member_id), {})
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
    http_api = smoke_http(
        args.http_url or infer_http_url(args.url),
        expect_firmware=args.expect_firmware,
        retained_artifact=args.expect_retained_artifact,
        retained_sha256=args.expect_retained_sha256,
        retained_size=args.expect_retained_size,
    )
    access_token = http_api.get("access_token", "")
    other_access_token = http_api.get("other_access_token", "")
    other_user_id = http_api.get("other_user_id", "")
    outsider_access_token = http_api.get("outsider_access_token", "")
    device_token = http_api.get("device_token", "")
    revoked_device_token = http_api.get("revoked_device_token", "")
    busy_device_token = http_api.get("busy_device_token", "")
    target_device_token = http_api.get("target_device_token", "")
    location_stale_after_seconds = int(
        ((http_api.get("health", {}).get("limits", {}) or {}).get("location_stale_after_seconds") or 30)
    )
    http_api_report = {
        **http_api,
        "access_token": "redacted",
        "other_access_token": "redacted",
        "other_user_id": "redacted",
        "outsider_access_token": "redacted",
        "device_token": "redacted",
        "revoked_device_token": "redacted",
        "busy_device_token": "redacted",
        "target_device_token": "redacted",
    }
    base = args.url.rstrip("/")
    room_code = str(http_api.get("room_code") or "")
    device_group_id = hashlib.sha256(device_token.encode("utf-8")).hexdigest()[:24]
    busy_device_group_id = hashlib.sha256(busy_device_token.encode("utf-8")).hexdigest()[:24]
    target_device_group_id = hashlib.sha256(target_device_token.encode("utf-8")).hexdigest()[:24]
    unauth_app_url = f"{base}/v1/radar/app/ws?room={room_code}&app_id=app-smoke-unauth&group_id=smoke-unauth"
    outsider_app_url = f"{base}/v1/radar/app/ws?room={room_code}&app_id=app-smoke-outsider&group_id=smoke-outsider"
    app_url = f"{base}/v1/radar/app/ws?room={room_code}&app_id=app-{device_group_id}"
    target_app_url = f"{base}/v1/radar/app/ws?room={room_code}&app_id=app-{target_device_group_id}"
    target_device_url = f"{base}/v1/radar/device/ws?room={room_code}&device_id=device-smoke-target"
    old_app_url = f"{base}/v1/radar/app/ws?room={room_code}&app_id=app-{device_group_id}"
    unauth_device_url = f"{base}/v1/radar/device/ws?room={room_code}&device_id=device-smoke-unauth&group_id=smoke-unauth"
    revoked_device_url = f"{base}/v1/radar/device/ws?room={room_code}&device_id=device-smoke-revoked&group_id=smoke-revoked"
    old_device_url = f"{base}/v1/radar/device/ws?room={room_code}&device_id=device-smoke-old&group_id=smoke-old-device"
    busy_device_url = f"{base}/v1/radar/device/ws?room={room_code}&device_id=device-smoke-busy&group_id=smoke-busy"
    device_url = f"{base}/v1/radar/device/ws?room={room_code}&device_id=device-smoke&group_id=smoke"

    async with websockets.connect(unauth_app_url) as unauth_app:
        unauth_app_error = await recv_until(unauth_app, "error")

    async with websockets.connect(outsider_app_url, extra_headers=websocket_headers(outsider_access_token)) as outsider_app:
        outsider_app_error = await recv_json(outsider_app)

    async with websockets.connect(unauth_device_url) as unauth_device:
        unauth_device_error = await recv_until(unauth_device, "error")

    async with websockets.connect(revoked_device_url, extra_headers=websocket_headers(revoked_device_token)) as revoked_device:
        revoked_device_error = await recv_until(revoked_device, "error")

    async with websockets.connect(old_app_url, extra_headers=websocket_headers(access_token)) as old_app:
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

    async with websockets.connect(old_device_url, extra_headers=websocket_headers(busy_device_token)) as old_device:
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

    async with (
        websockets.connect(app_url, extra_headers=websocket_headers(access_token)) as app,
        websockets.connect(device_url, extra_headers=websocket_headers(device_token)) as device,
        websockets.connect(target_app_url, extra_headers=websocket_headers(other_access_token)) as target_app,
        websockets.connect(
            target_device_url,
            extra_headers=websocket_headers(target_device_token),
        ) as target_device,
    ):
        app_ack = await recv_until(app, "hello_ack")
        device_ack = await recv_until(device, "hello_ack")
        target_app_ack = await recv_until(target_app, "hello_ack")
        target_device_ack = await recv_until(target_device, "hello_ack")

        await device.send(
            json.dumps(
                {
                    "type": "hello",
                    "name": "Ｓｍｏｋｅ\u202e Radar",
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
            device_group_id,
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
            device_group_id,
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
                    "room_token": room_code,
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
        room_state = await recv_room_state_with_device_voice(app, device_group_id)

        async with websockets.connect(
            busy_device_url,
            extra_headers=websocket_headers(busy_device_token),
        ) as busy_device:
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

        reminder_path = f"/v1/rooms/{room_code}/radar-reminders"
        reminder_request_id = "smoke-reminder-0001"
        reminder_unauth_status, reminder_unauth = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            reminder_path,
            {"request_id": "smoke-reminder-unauth"},
        )
        reminder_outsider_status, reminder_outsider = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            reminder_path,
            {"request_id": "smoke-reminder-outsider"},
            outsider_access_token,
        )
        reminder_status, reminder_response = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            reminder_path,
            {"request_id": reminder_request_id},
            access_token,
        )
        reminder_event = await recv_until(target_app, "radar_reminder")
        sender_received_no_reminder = await assert_no_message_type(app, "radar_reminder")
        device_received_no_reminder = await assert_no_message_type(device, "radar_reminder")

        duplicate_status, duplicate_response = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            reminder_path,
            {"request_id": reminder_request_id},
            access_token,
        )
        target_received_no_duplicate = await assert_no_message_type(target_app, "radar_reminder")
        rate_status, rate_headers, rate_response = await asyncio.to_thread(
            request_json_with_headers,
            "POST",
            http_api.get("base_url", ""),
            reminder_path,
            {"request_id": "smoke-reminder-0002"},
            access_token,
        )
        reminder_payload_text = json.dumps(
            {"response": reminder_response, "event": reminder_event},
            ensure_ascii=False,
            sort_keys=True,
        )
        sensitive_values = [
            access_token,
            other_access_token,
            outsider_access_token,
            device_token,
            busy_device_token,
            target_device_token,
            str(http_api.get("auth", {}).get("session", {}).get("user_id") or ""),
        ]
        reminder_has_no_sensitive_values = not any(
            value and value in reminder_payload_text
            for value in sensitive_values
        )

        live_members = room_state.get("members", [])
        owner_live_member = next(
            (member for member in live_members if member.get("member_id") == device_group_id),
            {},
        )
        target_live_member = next(
            (member for member in live_members if member.get("member_id") == target_device_group_id),
            {},
        )
        owner_moderation_ref = str(owner_live_member.get("moderation_ref") or "")
        target_moderation_ref = str(target_live_member.get("moderation_ref") or "")
        room_state_identity_text = json.dumps(room_state, ensure_ascii=False, sort_keys=True)
        report_payload = {
            "room_code": room_code,
            "moderation_ref": target_moderation_ref,
            "content_type": "voice",
            "category": "harassment",
            "details": "Smoke moderation report",
        }
        report_status, report_response = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/reports",
            report_payload,
            access_token,
        )
        self_report_status, self_report_response = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/reports",
            {**report_payload, "moderation_ref": owner_moderation_ref},
            access_token,
        )
        outsider_report_status, outsider_report_response = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/reports",
            report_payload,
            outsider_access_token,
        )
        invalid_report_status, invalid_report_response = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/reports",
            {**report_payload, "category": "not-a-category"},
            access_token,
        )
        long_report_status, long_report_response = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/reports",
            {
                **report_payload,
                "details": "x" * (
                    int(
                        (http_api.get("health", {}).get("moderation", {}) or {}).get(
                            "report_detail_max_chars"
                        )
                        or 1000
                    )
                    + 1
                ),
            },
            access_token,
        )
        report_response_text = json.dumps(report_response, ensure_ascii=False, sort_keys=True)

        live_remove_member_status, live_remove_member = await asyncio.to_thread(
            request_json,
            "DELETE",
            http_api.get("base_url", ""),
            f"/v1/rooms/{room_code}/members/{other_user_id}",
            None,
            access_token,
        )
        target_app_close, target_device_close = await asyncio.gather(
            wait_for_socket_close(target_app),
            wait_for_socket_close(target_device),
        )
        post_remove_room_state = await recv_room_state_matching(
            app,
            lambda state: len(state.get("members", [])) == 1
            and state.get("members", [{}])[0].get("member_id") == device_group_id,
            "post-removal owner-only room_state",
        )
        await app.send(json.dumps({"type": "ping"}, separators=(",", ":")))
        await device.send(json.dumps({"type": "ping"}, separators=(",", ":")))
        owner_app_pong = await recv_until(app, "pong")
        owner_device_pong = await recv_until(device, "pong")

        async with websockets.connect(
            app_url,
            extra_headers=websocket_headers(access_token),
        ) as replacement_app:
            replacement_app_ack = await recv_until(replacement_app, "hello_ack")
            replaced_app_error = await recv_until(app, "error")
            replaced_app_close = await wait_for_socket_close(app)
            await replacement_app.send(
                json.dumps(
                    {
                        "type": "hello",
                        "app": "smoke-replacement",
                        "name": "Smoke Profile User",
                        "protocol_version": 2,
                    },
                    separators=(",", ":"),
                )
            )
            replacement_state = await recv_room_state_member(
                replacement_app,
                device_group_id,
                lambda member: member.get("name") == "Smoke Profile User"
                and (member.get("location") or {}).get("sequence") == 8,
                "replacement connection preserves username and location",
            )

    profile_room_status, profile_room_response = await asyncio.to_thread(
        request_json,
        "GET",
        http_api.get("base_url", ""),
        f"/v1/rooms/{room_code}",
        None,
        access_token,
    )

    moderation_room_create_status, moderation_room_created = await asyncio.to_thread(
        request_json,
        "POST",
        http_api.get("base_url", ""),
        "/v1/rooms",
        {"name": "Smoke Moderation Owner Room"},
        access_token,
    )
    moderation_room_code = str(
        moderation_room_created.get("room", {}).get("room_code") or ""
    )
    moderation_target_join_status, moderation_target_join = await asyncio.to_thread(
        request_json,
        "POST",
        http_api.get("base_url", ""),
        "/v1/rooms/join",
        {"room_code": moderation_room_code},
        other_access_token,
    )
    member_room_create_status, member_room_created = await asyncio.to_thread(
        request_json,
        "POST",
        http_api.get("base_url", ""),
        "/v1/rooms",
        {"name": "Smoke Moderation Member Room"},
        outsider_access_token,
    )
    member_room_code = str(member_room_created.get("room", {}).get("room_code") or "")
    member_room_blocker_join_status, _ = await asyncio.to_thread(
        request_json,
        "POST",
        http_api.get("base_url", ""),
        "/v1/rooms/join",
        {"room_code": member_room_code},
        access_token,
    )
    member_room_target_join_status, _ = await asyncio.to_thread(
        request_json,
        "POST",
        http_api.get("base_url", ""),
        "/v1/rooms/join",
        {"room_code": member_room_code},
        other_access_token,
    )

    moderation_owner_app_url = f"{base}/v1/radar/app/ws?room={moderation_room_code}&app_id=app-{device_group_id}"
    moderation_owner_device_url = f"{base}/v1/radar/device/ws?room={moderation_room_code}"
    moderation_target_app_url = f"{base}/v1/radar/app/ws?room={moderation_room_code}&app_id=app-{target_device_group_id}"
    moderation_target_device_url = f"{base}/v1/radar/device/ws?room={moderation_room_code}"
    member_owner_app_url = f"{base}/v1/radar/app/ws?room={member_room_code}&app_id=app-{device_group_id}"
    member_owner_device_url = f"{base}/v1/radar/device/ws?room={member_room_code}"

    async with (
        websockets.connect(
            moderation_owner_app_url,
            extra_headers=websocket_headers(access_token),
        ) as moderation_owner_app,
        websockets.connect(
            moderation_owner_device_url,
            extra_headers=websocket_headers(device_token),
        ) as moderation_owner_device,
        websockets.connect(
            moderation_target_app_url,
            extra_headers=websocket_headers(other_access_token),
        ) as moderation_target_app,
        websockets.connect(
            moderation_target_device_url,
            extra_headers=websocket_headers(target_device_token),
        ) as moderation_target_device,
        websockets.connect(
            member_owner_app_url,
            extra_headers=websocket_headers(access_token),
        ) as member_owner_app,
        websockets.connect(
            member_owner_device_url,
            extra_headers=websocket_headers(device_token),
        ) as member_owner_device,
    ):
        moderation_owner_ack = await recv_until(moderation_owner_app, "hello_ack")
        moderation_owner_device_ack = await recv_until(moderation_owner_device, "hello_ack")
        moderation_target_ack = await recv_until(moderation_target_app, "hello_ack")
        moderation_target_device_ack = await recv_until(moderation_target_device, "hello_ack")
        member_owner_ack = await recv_until(member_owner_app, "hello_ack")
        member_owner_device_ack = await recv_until(member_owner_device, "hello_ack")
        moderation_app_state = await recv_room_state_matching(
            moderation_owner_app,
            lambda state: len(state.get("members", [])) == 2
            and all(member.get("moderation_ref") for member in state.get("members", [])),
            "moderation app room_state refs",
        )
        moderation_device_state = await recv_room_state_matching(
            moderation_owner_device,
            lambda state: len(state.get("members", [])) == 2,
            "moderation device room_state",
        )
        moderation_target_member = next(
            (
                member
                for member in moderation_app_state.get("members", [])
                if member.get("member_id") == target_device_group_id
            ),
            {},
        )
        block_target_ref = str(moderation_target_member.get("moderation_ref") or "")
        block_status, block_response = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/blocks",
            {
                "room_code": moderation_room_code,
                "moderation_ref": block_target_ref,
            },
            access_token,
        )
        block_id = str(block_response.get("block", {}).get("block_id") or "")
        (
            moderation_target_app_close,
            moderation_target_device_close,
            member_owner_app_close,
            member_owner_device_close,
        ) = await asyncio.gather(
            wait_for_socket_close(moderation_target_app),
            wait_for_socket_close(moderation_target_device),
            wait_for_socket_close(member_owner_app),
            wait_for_socket_close(member_owner_device),
        )
        moderation_owner_state_after_block = await recv_room_state_matching(
            moderation_owner_app,
            lambda state: len(state.get("members", [])) == 1
            and state.get("members", [{}])[0].get("member_id") == device_group_id,
            "block owner-only room_state",
        )
        await moderation_owner_app.send(json.dumps({"type": "ping"}, separators=(",", ":")))
        await moderation_owner_device.send(json.dumps({"type": "ping"}, separators=(",", ":")))
        moderation_owner_pong = await recv_until(moderation_owner_app, "pong")
        moderation_owner_device_pong = await recv_until(moderation_owner_device, "pong")

        blocked_target_rejoin_status, blocked_target_rejoin = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/rooms/join",
            {"room_code": moderation_room_code},
            other_access_token,
        )
        blocked_blocker_rejoin_status, blocked_blocker_rejoin = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/rooms/join",
            {"room_code": member_room_code},
            access_token,
        )
        blocked_invite_status, blocked_invite = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            f"/v1/rooms/{moderation_room_code}/invite",
            {"target_user_id": other_user_id},
            access_token,
        )
        blocks_status, blocks_response = await asyncio.to_thread(
            request_json,
            "GET",
            http_api.get("base_url", ""),
            "/v1/blocks",
            None,
            access_token,
        )
        blocked_reminder_status, blocked_reminder = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            f"/v1/rooms/{moderation_room_code}/radar-reminders",
            {"request_id": "smoke-blocked-reminder-0001"},
            access_token,
        )
        unblock_status, unblock_response = await asyncio.to_thread(
            request_json,
            "DELETE",
            http_api.get("base_url", ""),
            "/v1/blocks",
            {
                "room_code": moderation_room_code,
                "moderation_ref": block_target_ref,
            },
            access_token,
        )
        blocks_after_unblock_status, blocks_after_unblock = await asyncio.to_thread(
            request_json,
            "GET",
            http_api.get("base_url", ""),
            "/v1/blocks",
            None,
            access_token,
        )
        unblocked_target_rejoin_status, unblocked_target_rejoin = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/rooms/join",
            {"room_code": moderation_room_code},
            other_access_token,
        )
        unblocked_blocker_rejoin_status, unblocked_blocker_rejoin = await asyncio.to_thread(
            request_json,
            "POST",
            http_api.get("base_url", ""),
            "/v1/rooms/join",
            {"room_code": member_room_code},
            access_token,
        )

    moderation_room_delete_status, _ = request_json(
        "DELETE",
        http_api.get("base_url", ""),
        f"/v1/rooms/{moderation_room_code}",
        access_token=access_token,
    )
    member_room_delete_status, _ = request_json(
        "DELETE",
        http_api.get("base_url", ""),
        f"/v1/rooms/{member_room_code}",
        access_token=outsider_access_token,
    )
    moderation_payload_text = json.dumps(
        {
            "app_state": moderation_app_state,
            "block": block_response,
            "blocks": blocks_response,
            "unblock": unblock_response,
        },
        ensure_ascii=False,
        sort_keys=True,
    )

    audit_status, audit = request_json(
        "GET",
        http_api.get("base_url", ""),
        "/v1/audit/events?limit=80",
        access_token=access_token,
    )
    outsider_audit_status, outsider_audit = request_json(
        "GET",
        http_api.get("base_url", ""),
        "/v1/audit/events?limit=80",
        access_token=outsider_access_token,
    )
    outsider_room_audit_status, outsider_room_audit = request_json(
        "GET",
        http_api.get("base_url", ""),
        f"/v1/audit/events?limit=80&room={quote(room_code, safe='')}",
        access_token=outsider_access_token,
    )
    audit_types = {event.get("event_type") for event in audit.get("events", [])}
    radar_reminder_audits = [
        event
        for event in audit.get("events", [])
        if event.get("event_type") == "radar_reminder"
    ]
    radar_audit_text = json.dumps(radar_reminder_audits, ensure_ascii=False, sort_keys=True)
    radar_audit_is_redacted = (
        len(radar_reminder_audits) == 1
        and radar_reminder_audits[0].get("actor_id") == ""
        and radar_reminder_audits[0].get("group_id") == ""
        and "apple:" not in radar_audit_text
        and not re.search(r"\b(?:ddt|dra|drr)_[A-Za-z0-9_-]+", radar_audit_text)
    )
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
        "push_unregister",
        "radar_reminder",
    }
    if http_api.get("health", {}).get("notifications", {}).get("mode") == "dry_run":
        expected_audit_types.update({"push_register", "push_delivery"})
    members = room_state.get("members", [])
    device_member = next((member for member in members if member.get("member_id") == device_group_id), {})
    location = device_member.get("location", {})
    reminder = reminder_response.get("reminder", {})
    duplicate_reminder = duplicate_response.get("reminder", {})
    expected_reminder_push_status = (
        "dry_run"
        if http_api.get("health", {}).get("notifications", {}).get("mode") == "dry_run"
        else "skipped"
        if http_api.get("health", {}).get("notifications", {}).get("mode") == "disabled"
        else reminder.get("push_status")
    )
    live_delete_status, live_deleted = request_json(
        "DELETE",
        http_api.get("base_url", ""),
        f"/v1/rooms/{room_code}",
        access_token=access_token,
    )
    ok = (
        app_ack.get("type") == "hello_ack"
        and unauth_app_error.get("code") == "unauthorized"
        and outsider_app_error.get("type") == "error"
        and outsider_app_error.get("code") == "not_room_member"
        and unauth_device_error.get("code") == "unauthorized"
        and revoked_device_error.get("code") == "device_revoked"
        and device_ack.get("type") == "hello_ack"
        and target_app_ack.get("type") == "hello_ack"
        and target_app_ack.get("peer_id") == f"app-{target_device_group_id}"
        and target_device_ack.get("type") == "hello_ack"
        and target_device_ack.get("peer_id") == target_device_group_id
        and int((app_ack.get("protocol") or {}).get("relay") or 0) >= 2
        and int((device_ack.get("protocol") or {}).get("relay") or 0) >= 2
        and old_app_ack.get("type") == "hello_ack"
        and old_app_error.get("code") == "protocol_unsupported"
        and old_app_error.get("required_protocol") == 2
        and old_device_ack.get("type") == "hello_ack"
        and old_device_error.get("code") == "protocol_unsupported"
        and old_device_error.get("required_protocol") == 2
        and app_event.get("event") == "hello"
        and app_event.get("payload", {}).get("name") == "Smoke Radar"
        and app_location_ack.get("sequence") == 7
        and device_event.get("event") == "app_location"
        and device_event.get("payload", {}).get("sequence") == 7
        and location_paused_ack.get("type") == "location_paused_ack"
        and location_paused_event.get("event") == "location_paused"
        and next((member for member in location_paused_state.get("members", []) if member.get("member_id") == device_group_id), {}).get("location_paused") is True
        and app_location_restore_ack.get("sequence") == 8
        and device_event_restored.get("event") == "app_location"
        and device_event_restored.get("payload", {}).get("sequence") == 8
        and next((member for member in location_restored_state.get("members", []) if member.get("member_id") == device_group_id), {}).get("location_paused") is False
        and room_switch_ack.get("request_id") == "smoke-switch-1"
        and room_switch_ack.get("delivered_devices") == 1
        and room_switch_event.get("event") == "room_switch"
        and (room_switch_event.get("payload") or {}).get("request_id") == "smoke-switch-1"
        and "device_token" not in (room_switch_event.get("payload") or {})
        and busy_device_ack.get("type") == "hello_ack"
        and busy_device_ack.get("peer_id") == busy_device_group_id
        and busy_error.get("type") == "voice_busy"
        and busy_error.get("speaker_group_id") == device_group_id
        and len(members) == 2
        and device_member.get("name") == "Smoke User"
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
        and reminder_unauth_status == 401
        and reminder_unauth.get("code") == "unauthorized"
        and reminder_outsider_status == 403
        and reminder_outsider.get("code") == "not_room_member"
        and reminder_status == 202
        and set(reminder) == {
            "event_id",
            "request_id",
            "room_code",
            "recipient_count",
            "online_delivered",
            "push_status",
            "cooldown_seconds",
            "server_time",
            "duplicate",
        }
        and reminder.get("event_id", "").startswith("rr_")
        and reminder.get("request_id") == reminder_request_id
        and reminder.get("room_code") == room_code
        and reminder.get("recipient_count") == 1
        and reminder.get("online_delivered") == 1
        and reminder.get("push_status") == expected_reminder_push_status
        and reminder.get("cooldown_seconds") == 30
        and reminder.get("duplicate") is False
        and reminder_event.get("type") == "radar_reminder"
        and reminder_event.get("event_id") == reminder.get("event_id")
        and reminder_event.get("request_id") == reminder_request_id
        and reminder_event.get("room_code") == room_code
        and reminder_event.get("recipient_count") == 1
        and reminder_event.get("online_delivered") == 1
        and reminder_event.get("push_status") == expected_reminder_push_status
        and reminder_event.get("duplicate") is False
        and reminder_event.get("sender_name") == "Smoke User"
        and reminder_event.get("action") == "open_radar"
        and sender_received_no_reminder
        and device_received_no_reminder
        and duplicate_status == 200
        and duplicate_reminder.get("duplicate") is True
        and duplicate_reminder.get("event_id") == reminder.get("event_id")
        and duplicate_reminder.get("request_id") == reminder_request_id
        and target_received_no_duplicate
        and rate_status == 429
        and rate_response.get("code") == "radar_reminder_rate_limited"
        and int(rate_response.get("retry_after") or 0) > 0
        and rate_headers.get("retry-after") == str(rate_response.get("retry_after"))
        and reminder_has_no_sensitive_values
        and "apple:" not in reminder_payload_text
        and re.fullmatch(r"mod_v1_[A-Za-z0-9_-]{43}", owner_moderation_ref) is not None
        and re.fullmatch(r"mod_v1_[A-Za-z0-9_-]{43}", target_moderation_ref) is not None
        and target_moderation_ref == moderation_ref_for_user(room_code, other_user_id)
        and "apple:" not in room_state_identity_text
        and report_status == 201
        and report_response.get("report", {}).get("case_number", "").startswith("DR-")
        and report_response.get("report", {}).get("status") == "received"
        and "apple:" not in report_response_text
        and other_user_id not in report_response_text
        and self_report_status == 400
        and self_report_response.get("code") == "cannot_report_self"
        and outsider_report_status == 403
        and outsider_report_response.get("code") == "not_room_member"
        and invalid_report_status == 400
        and invalid_report_response.get("code") == "invalid_report_category"
        and long_report_status == 400
        and long_report_response.get("code") == "report_details_too_long"
        and live_remove_member_status == 200
        and live_remove_member.get("room", {}).get("member_count") == 1
        and target_app_close == {
            "closed": True,
            "code": 1008,
            "reason": "room_membership_removed",
        }
        and target_device_close == {
            "closed": True,
            "code": 1008,
            "reason": "room_membership_removed",
        }
        and len(post_remove_room_state.get("members", [])) == 1
        and post_remove_room_state.get("members", [{}])[0].get("member_id") == device_group_id
        and owner_app_pong.get("type") == "pong"
        and owner_device_pong.get("type") == "pong"
        and replacement_app_ack.get("type") == "hello_ack"
        and replaced_app_error.get("code") == "connection_replaced"
        and replaced_app_close.get("closed") is True
        and replacement_state.get("members", [{}])[0].get("name") == "Smoke Profile User"
        and (replacement_state.get("members", [{}])[0].get("location") or {}).get("sequence") == 8
        and profile_room_status == 200
        and (profile_room_response.get("room", {}).get("members") or [{}])[0].get("display_name")
        == "Smoke Profile User"
        and moderation_room_create_status == 201
        and moderation_target_join_status == 200
        and member_room_create_status == 201
        and member_room_blocker_join_status == 200
        and member_room_target_join_status == 200
        and moderation_owner_ack.get("type") == "hello_ack"
        and moderation_owner_device_ack.get("type") == "hello_ack"
        and moderation_target_ack.get("type") == "hello_ack"
        and moderation_target_device_ack.get("type") == "hello_ack"
        and member_owner_ack.get("type") == "hello_ack"
        and member_owner_device_ack.get("type") == "hello_ack"
        and re.fullmatch(r"mod_v1_[A-Za-z0-9_-]{43}", block_target_ref) is not None
        and block_target_ref == moderation_ref_for_user(moderation_room_code, other_user_id)
        and block_target_ref != target_moderation_ref
        and all(
            re.fullmatch(r"mod_v1_[A-Za-z0-9_-]{43}", str(member.get("moderation_ref") or ""))
            is not None
            for member in moderation_app_state.get("members", [])
        )
        and not any(
            "moderation_ref" in member
            for member in moderation_device_state.get("members", [])
        )
        and block_status == 201
        and block_id.startswith("blk_")
        and {effect.get("action") for effect in block_response.get("effects", [])}
        == {"blocked_user_removed", "blocker_left"}
        and all(
            int(effect.get("disconnected_connections") or 0) == 2
            for effect in block_response.get("effects", [])
        )
        and moderation_target_app_close == {
            "closed": True,
            "code": 1008,
            "reason": "blocked_relationship",
        }
        and moderation_target_device_close == {
            "closed": True,
            "code": 1008,
            "reason": "blocked_relationship",
        }
        and member_owner_app_close == {
            "closed": True,
            "code": 1008,
            "reason": "blocked_relationship",
        }
        and member_owner_device_close == {
            "closed": True,
            "code": 1008,
            "reason": "blocked_relationship",
        }
        and len(moderation_owner_state_after_block.get("members", [])) == 1
        and moderation_owner_pong.get("type") == "pong"
        and moderation_owner_device_pong.get("type") == "pong"
        and blocked_target_rejoin_status == 403
        and blocked_target_rejoin.get("code") == "blocked_relationship"
        and blocked_blocker_rejoin_status == 403
        and blocked_blocker_rejoin.get("code") == "blocked_relationship"
        and blocked_invite_status == 403
        and blocked_invite.get("code") == "blocked_relationship"
        and blocks_status == 200
        and len(blocks_response.get("blocks", [])) == 1
        and blocks_response.get("blocks", [{}])[0].get("block_id") == block_id
        and blocked_reminder_status == 202
        and blocked_reminder.get("reminder", {}).get("recipient_count") == 0
        and unblock_status == 200
        and unblock_response.get("ok") is True
        and blocks_after_unblock_status == 200
        and blocks_after_unblock.get("blocks") == []
        and unblocked_target_rejoin_status == 200
        and unblocked_target_rejoin.get("room", {}).get("member_count") == 2
        and unblocked_blocker_rejoin_status == 200
        and unblocked_blocker_rejoin.get("room", {}).get("member_count") == 3
        and moderation_room_delete_status == 200
        and member_room_delete_status == 200
        and "apple:" not in moderation_payload_text
        and other_user_id not in moderation_payload_text
        and audit_status == 200
        and expected_audit_types.issubset(audit_types)
        and radar_audit_is_redacted
        and outsider_audit_status == 200
        and not any(
            event.get("event_type") == "radar_reminder"
            for event in outsider_audit.get("events", [])
        )
        and outsider_room_audit_status == 403
        and outsider_room_audit.get("code") == "not_room_member"
        and live_delete_status == 200
        and live_deleted.get("ok") is True
        and (
            http_api.get("health", {}).get("notifications", {}).get("mode") != "dry_run"
            or {"voice_busy", "device_offline"}.issubset(push_notification_types)
        )
    )
    return {
        "ok": ok and http_api.get("ok") is True,
        "http_api": http_api_report,
        "unauth_app_error": unauth_app_error,
        "outsider_app_error": outsider_app_error,
        "unauth_device_error": unauth_device_error,
        "revoked_device_error": revoked_device_error,
        "old_app_ack": old_app_ack,
        "old_app_error": old_app_error,
        "old_device_ack": old_device_ack,
        "old_device_error": old_device_error,
        "app_ack": app_ack,
        "device_ack": device_ack,
        "target_app_ack": target_app_ack,
        "target_device_ack": target_device_ack,
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
        "reminder_unauth": {"status": reminder_unauth_status, "body": reminder_unauth},
        "reminder_outsider": {"status": reminder_outsider_status, "body": reminder_outsider},
        "reminder": {"status": reminder_status, "body": reminder_response},
        "reminder_event": reminder_event,
        "reminder_duplicate": {"status": duplicate_status, "body": duplicate_response},
        "reminder_rate_limit": {
            "status": rate_status,
            "retry_after": rate_headers.get("retry-after"),
            "body": rate_response,
        },
        "reminder_non_target_delivery": {
            "sender": not sender_received_no_reminder,
            "device": not device_received_no_reminder,
            "duplicate": not target_received_no_duplicate,
        },
        "reminder_has_no_sensitive_values": reminder_has_no_sensitive_values,
        "content_moderation": {
            "report": {"status": report_status, "body": report_response},
            "self_report": {"status": self_report_status, "body": self_report_response},
            "outsider_report": {"status": outsider_report_status, "body": outsider_report_response},
            "invalid_report": {"status": invalid_report_status, "body": invalid_report_response},
            "long_report": {"status": long_report_status, "body": long_report_response},
            "room_state_has_refs": all(
                bool(member.get("moderation_ref")) for member in room_state.get("members", [])
            ),
            "room_state_has_raw_account_id": "apple:" in room_state_identity_text,
        },
        "live_member_removal": {
            "status": live_remove_member_status,
            "body": live_remove_member,
            "target_app_close": target_app_close,
            "target_device_close": target_device_close,
            "owner_app_alive": owner_app_pong.get("type") == "pong",
            "owner_device_alive": owner_device_pong.get("type") == "pong",
            "post_remove_room_state": post_remove_room_state,
        },
        "connection_replacement": {
            "ack": replacement_app_ack,
            "replaced_error": replaced_app_error,
            "replaced_close": replaced_app_close,
            "room_state": replacement_state,
            "profile_room_status": profile_room_status,
            "profile_room": profile_room_response,
        },
        "user_blocking": {
            "status": block_status,
            "body": block_response,
            "target_app_close": moderation_target_app_close,
            "target_device_close": moderation_target_device_close,
            "blocker_member_app_close": member_owner_app_close,
            "blocker_member_device_close": member_owner_device_close,
            "target_rejoin_while_blocked": {
                "status": blocked_target_rejoin_status,
                "body": blocked_target_rejoin,
            },
            "blocker_rejoin_while_blocked": {
                "status": blocked_blocker_rejoin_status,
                "body": blocked_blocker_rejoin,
            },
            "invite_while_blocked": {"status": blocked_invite_status, "body": blocked_invite},
            "reminder_while_blocked": {
                "status": blocked_reminder_status,
                "body": blocked_reminder,
            },
            "list": {"status": blocks_status, "body": blocks_response},
            "unblock": {"status": unblock_status, "body": unblock_response},
            "list_after_unblock": {
                "status": blocks_after_unblock_status,
                "body": blocks_after_unblock,
            },
            "target_rejoin_after_unblock": unblocked_target_rejoin_status,
            "blocker_rejoin_after_unblock": unblocked_blocker_rejoin_status,
            "raw_account_id_exposed": "apple:" in moderation_payload_text,
        },
        "room_state": room_state,
        "location_stale_after_seconds": location_stale_after_seconds,
        "audit_status": audit_status,
        "audit_types": sorted(item for item in audit_types if item),
        "radar_reminder_audit_count": len(radar_reminder_audits),
        "radar_reminder_audit_redacted": radar_audit_is_redacted,
        "outsider_audit_status": outsider_audit_status,
        "outsider_room_audit_status": outsider_room_audit_status,
        "live_delete_status": live_delete_status,
        "push_notification_types": sorted(item for item in push_notification_types if item),
    }


def main() -> int:
    args = parse_args()
    try:
        result = asyncio.run(smoke(args))
    except Exception as exc:
        print(
            json.dumps(
                redact_sensitive_output(
                    {"ok": False, "error": str(exc), "traceback": traceback.format_exc()}
                ),
                ensure_ascii=False,
                indent=2,
            )
        )
        return 1
    print(json.dumps(redact_sensitive_output(result), ensure_ascii=False, indent=2, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
