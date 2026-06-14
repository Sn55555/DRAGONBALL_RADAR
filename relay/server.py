#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import hmac
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import signal
import secrets
import sqlite3
import string
import subprocess
import threading
import time
from dataclasses import dataclass, field
from typing import Any
from urllib import request as urlrequest
from urllib.parse import parse_qs, urlparse

import websockets
from websockets.server import WebSocketServerProtocol


MAX_ROOM_MEMBERS = 7
VOICE_FLOOR_TTL_SECONDS = 1.2
APP_PATH = "/v1/radar/app/ws"
DEVICE_PATH = "/v1/radar/device/ws"
ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
DEFAULT_APPLE_AUDIENCE = "com.sn5.DragonRadarMVP"
SHA256_DIGEST_INFO_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")
DEFAULT_PAIRING_HMAC_KEY = "dragon-radar-dev-pairing-key"


def env_int(name: str, default: int, minimum: int = 0) -> int:
    raw = os.environ.get(name, "").strip()
    if not raw:
        return default
    try:
        return max(minimum, int(raw))
    except ValueError:
        return default


HTTP_MAX_BODY_BYTES = env_int("DRAGON_RADAR_HTTP_MAX_BODY_BYTES", 64 * 1024, 1024)
HTTP_RATE_LIMIT_PER_MINUTE = env_int("DRAGON_RADAR_HTTP_RATE_LIMIT_PER_MINUTE", 240, 0)
WS_MAX_MESSAGE_BYTES = env_int("DRAGON_RADAR_WS_MAX_MESSAGE_BYTES", 64 * 1024, 1024)
WS_MESSAGE_RATE_LIMIT_PER_SECOND = env_int("DRAGON_RADAR_WS_MESSAGE_RATE_LIMIT_PER_SECOND", 30, 0)
WS_IDLE_TIMEOUT_SECONDS = env_int("DRAGON_RADAR_WS_IDLE_TIMEOUT_SECONDS", 90, 10)
WS_PING_INTERVAL_SECONDS = env_int("DRAGON_RADAR_WS_PING_INTERVAL_SECONDS", 20, 5)
WS_PING_TIMEOUT_SECONDS = env_int("DRAGON_RADAR_WS_PING_TIMEOUT_SECONDS", 20, 5)
LOCATION_STALE_AFTER_SECONDS = env_int("DRAGON_RADAR_LOCATION_STALE_SECONDS", 30, 1)
RELAY_PROTOCOL_VERSION = env_int("DRAGON_RADAR_RELAY_PROTOCOL_VERSION", 2, 1)
MIN_APP_PROTOCOL_VERSION = env_int("DRAGON_RADAR_MIN_APP_PROTOCOL_VERSION", 2, 1)
MIN_DEVICE_PROTOCOL_VERSION = env_int("DRAGON_RADAR_MIN_DEVICE_PROTOCOL_VERSION", 2, 1)
LOCATION_FRAME_PROTOCOL_VERSION = 1
VOICE_PROTOCOL_VERSION = 1


class RateLimitExceeded(Exception):
    pass


class PayloadTooLarge(Exception):
    pass


class FixedWindowRateLimiter:
    def __init__(self, limit: int, window_seconds: float) -> None:
        self.limit = max(0, limit)
        self.window_seconds = max(1.0, window_seconds)
        self.lock = threading.RLock()
        self.windows: dict[str, tuple[float, int]] = {}

    def allow(self, key: str, now: float | None = None) -> bool:
        if self.limit <= 0:
            return True
        timestamp = time.time() if now is None else now
        with self.lock:
            window_start, count = self.windows.get(key, (timestamp, 0))
            if timestamp - window_start >= self.window_seconds:
                window_start = timestamp
                count = 0
            count += 1
            self.windows[key] = (window_start, count)
            return count <= self.limit


http_rate_limiter = FixedWindowRateLimiter(HTTP_RATE_LIMIT_PER_MINUTE, 60.0)


@dataclass
class VerifiedAppleIdentity:
    apple_user_id: str
    audience: str
    expires_at: int
    development: bool = False


class AppleIdentityVerifier:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.keys: list[dict[str, Any]] = []
        self.keys_fetched_at = 0.0

    def verify(self, identity_token: str, requested_apple_user_id: str = "") -> VerifiedAppleIdentity:
        token = identity_token.strip()
        requested = requested_apple_user_id.strip()
        if self.development_auth_allowed() and token == "development":
            if not requested:
                raise PermissionError("apple_user_id_required")
            return VerifiedAppleIdentity(
                apple_user_id=requested[:128],
                audience="development",
                expires_at=int(time.time()) + 3600,
                development=True,
            )

        header, payload, signed_input, signature = self.decode_jwt(token)
        if header.get("alg") != "RS256":
            raise PermissionError("invalid_apple_identity_token")
        kid = str(header.get("kid") or "")
        if not kid:
            raise PermissionError("invalid_apple_identity_token")

        key = self.key_for_kid(kid)
        if key is None:
            self.fetch_keys(force=True)
            key = self.key_for_kid(kid)
        if key is None or not self.verify_rs256(signed_input, signature, key):
            raise PermissionError("invalid_apple_identity_token")

        now = int(time.time())
        issuer = str(payload.get("iss") or "")
        subject = str(payload.get("sub") or "")
        audience = payload.get("aud")
        expires_at = int(payload.get("exp") or 0)
        issued_at = int(payload.get("iat") or 0)
        if issuer != APPLE_ISSUER or not subject or expires_at <= now:
            raise PermissionError("invalid_apple_identity_token")
        if issued_at and issued_at > now + 300:
            raise PermissionError("invalid_apple_identity_token")
        if not self.audience_allowed(audience):
            raise PermissionError("invalid_apple_identity_token")
        if requested and requested != subject:
            raise PermissionError("apple_user_mismatch")
        return VerifiedAppleIdentity(
            apple_user_id=subject[:128],
            audience=self.audience_text(audience),
            expires_at=expires_at,
        )

    @staticmethod
    def development_auth_allowed() -> bool:
        return os.environ.get("DRAGON_RADAR_ALLOW_DEVELOPMENT_AUTH", "").strip().lower() in {"1", "true", "yes"}

    @staticmethod
    def allowed_audiences() -> set[str]:
        raw = os.environ.get("DRAGON_RADAR_APPLE_AUDIENCES") or os.environ.get("DRAGON_RADAR_APPLE_AUDIENCE") or DEFAULT_APPLE_AUDIENCE
        return {item.strip() for item in raw.split(",") if item.strip()}

    def audience_allowed(self, audience: Any) -> bool:
        allowed = self.allowed_audiences()
        if isinstance(audience, str):
            return audience in allowed
        if isinstance(audience, list):
            return any(str(item) in allowed for item in audience)
        return False

    @staticmethod
    def audience_text(audience: Any) -> str:
        if isinstance(audience, list):
            return ",".join(str(item) for item in audience)
        return str(audience or "")

    def decode_jwt(self, token: str) -> tuple[dict[str, Any], dict[str, Any], bytes, bytes]:
        parts = token.split(".")
        if len(parts) != 3 or not all(parts):
            raise PermissionError("invalid_apple_identity_token")
        try:
            header = json.loads(base64url_decode(parts[0]))
            payload = json.loads(base64url_decode(parts[1]))
            signature = base64url_decode(parts[2])
        except (ValueError, json.JSONDecodeError):
            raise PermissionError("invalid_apple_identity_token") from None
        if not isinstance(header, dict) or not isinstance(payload, dict):
            raise PermissionError("invalid_apple_identity_token")
        return header, payload, f"{parts[0]}.{parts[1]}".encode("ascii"), signature

    def fetch_keys(self, force: bool = False) -> list[dict[str, Any]]:
        with self.lock:
            if not force and self.keys and time.time() - self.keys_fetched_at < 6 * 3600:
                return self.keys
        with urlrequest.urlopen(APPLE_JWKS_URL, timeout=4) as response:
            body = response.read().decode("utf-8")
        parsed = json.loads(body)
        keys = parsed.get("keys", [])
        if not isinstance(keys, list):
            raise PermissionError("invalid_apple_identity_token")
        with self.lock:
            self.keys = [key for key in keys if isinstance(key, dict)]
            self.keys_fetched_at = time.time()
            return self.keys

    def key_for_kid(self, kid: str) -> dict[str, Any] | None:
        keys = self.fetch_keys()
        return next((key for key in keys if str(key.get("kid") or "") == kid and key.get("kty") == "RSA"), None)

    @staticmethod
    def verify_rs256(signed_input: bytes, signature: bytes, key: dict[str, Any]) -> bool:
        try:
            modulus = int.from_bytes(base64url_decode(str(key["n"])), "big")
            exponent = int.from_bytes(base64url_decode(str(key["e"])), "big")
        except (KeyError, ValueError):
            return False
        key_length = (modulus.bit_length() + 7) // 8
        if len(signature) != key_length:
            return False
        decoded = pow(int.from_bytes(signature, "big"), exponent, modulus).to_bytes(key_length, "big")
        digest_info = SHA256_DIGEST_INFO_PREFIX + hashlib.sha256(signed_input).digest()
        expected_padding_length = key_length - len(digest_info) - 3
        if expected_padding_length < 8:
            return False
        expected = b"\x00\x01" + (b"\xff" * expected_padding_length) + b"\x00" + digest_info
        return secrets.compare_digest(decoded, expected)


apple_identity_verifier = AppleIdentityVerifier()


def pairing_hmac_key() -> bytes:
    return (os.environ.get("DRAGON_RADAR_PAIRING_HMAC_KEY") or DEFAULT_PAIRING_HMAC_KEY).encode("utf-8")


def make_pairing_response(pairing_challenge: str, device_id: str, nonce: str) -> str:
    message = f"v2|{pairing_challenge}|{device_id}|{nonce}".encode("utf-8")
    signature = hmac.new(pairing_hmac_key(), message, hashlib.sha256).hexdigest()
    return f"dra-pair:v2:{device_id}:{nonce}:{signature}"


class RelayStore:
    def __init__(self, path: str) -> None:
        self.path = path
        self.lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.setup()

    def setup(self) -> None:
        with self.lock, self.db:
            self.db.executescript(
                """
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS users (
                    user_id TEXT PRIMARY KEY,
                    apple_user_id TEXT UNIQUE,
                    display_name TEXT NOT NULL DEFAULT '',
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS auth_tokens (
                    access_token TEXT PRIMARY KEY,
                    refresh_token TEXT NOT NULL UNIQUE,
                    user_id TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS rooms (
                    room_id TEXT PRIMARY KEY,
                    room_code TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    owner_user_id TEXT NOT NULL,
                    max_members INTEGER NOT NULL DEFAULT 7,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS room_members (
                    room_code TEXT NOT NULL,
                    member_id TEXT NOT NULL,
                    user_id TEXT NOT NULL,
                    display_name TEXT NOT NULL DEFAULT '',
                    role TEXT NOT NULL DEFAULT 'member',
                    joined_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    PRIMARY KEY (room_code, member_id)
                );
                CREATE TABLE IF NOT EXISTS room_invites (
                    invite_code TEXT PRIMARY KEY,
                    room_code TEXT NOT NULL,
                    created_by TEXT NOT NULL,
                    expires_at INTEGER,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS devices (
                    device_id TEXT PRIMARY KEY,
                    owner_user_id TEXT NOT NULL,
                    device_short_id TEXT NOT NULL,
                    name TEXT NOT NULL DEFAULT '',
                    device_token TEXT NOT NULL UNIQUE,
                    pairing_challenge TEXT NOT NULL,
                    pairing_response TEXT NOT NULL,
                    revoked_at INTEGER,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS audit_events (
                    event_id TEXT PRIMARY KEY,
                    event_type TEXT NOT NULL,
                    room_code TEXT NOT NULL DEFAULT '',
                    actor_id TEXT NOT NULL DEFAULT '',
                    actor_role TEXT NOT NULL DEFAULT '',
                    group_id TEXT NOT NULL DEFAULT '',
                    detail_json TEXT NOT NULL DEFAULT '{}',
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS diagnostics_reports (
                    report_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    room_code TEXT NOT NULL DEFAULT '',
                    report_json TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS push_subscriptions (
                    device_token TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    platform TEXT NOT NULL DEFAULT 'ios',
                    environment TEXT NOT NULL DEFAULT 'sandbox',
                    enabled INTEGER NOT NULL DEFAULT 1,
                    app_version TEXT NOT NULL DEFAULT '',
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                """
            )
            try:
                self.db.execute("ALTER TABLE users ADD COLUMN apple_user_id TEXT UNIQUE")
            except sqlite3.OperationalError:
                try:
                    self.db.execute("ALTER TABLE users ADD COLUMN apple_user_id TEXT")
                except sqlite3.OperationalError:
                    pass

    def register_device_challenge(
        self,
        user_id: str,
        pairing_challenge: str,
        name: str = "",
    ) -> dict[str, Any]:
        clean_challenge = " ".join(pairing_challenge.strip().split())[:160]
        if not clean_challenge or clean_challenge == "未读取":
            raise ValueError("pairing_challenge_required")
        clean_name = name.strip()[:40] or "ESP Radar"
        short_id = device_short_id_from_challenge(clean_challenge)
        with self.lock:
            existing = self.db.execute(
                """
                SELECT device_id, owner_user_id, device_short_id, name, device_token, pairing_response, created_at, updated_at
                FROM devices
                WHERE pairing_challenge = ? AND revoked_at IS NULL
                ORDER BY updated_at DESC
                LIMIT 1
                """,
                (clean_challenge,),
            ).fetchone()
        if existing is not None:
            if existing["owner_user_id"] != user_id:
                raise PermissionError("device_already_bound")
            return self.device_dict(existing)

        device_id = "dev_" + secrets.token_urlsafe(12)
        device_token = "ddt_" + secrets.token_urlsafe(32)
        pairing_nonce = secrets.token_urlsafe(18)
        pairing_response = make_pairing_response(clean_challenge, device_id, pairing_nonce)
        now = int(time.time())
        self.ensure_user(user_id)
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO devices (
                    device_id, owner_user_id, device_short_id, name, device_token,
                    pairing_challenge, pairing_response, revoked_at, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                """,
                (
                    device_id,
                    user_id,
                    short_id,
                    clean_name,
                    device_token,
                    clean_challenge,
                    pairing_response,
                    now,
                    now,
                ),
            )
        return self.get_device_for_user(user_id, device_id) or {
            "device_id": device_id,
            "device_short_id": short_id,
            "name": clean_name,
            "device_token": device_token,
            "pairing_response": pairing_response,
            "created_at": now,
            "updated_at": now,
        }

    def list_devices(self, user_id: str) -> list[dict[str, Any]]:
        self.ensure_user(user_id)
        with self.lock:
            rows = self.db.execute(
                """
                SELECT device_id, device_short_id, name, device_token, pairing_response, created_at, updated_at
                FROM devices
                WHERE owner_user_id = ? AND revoked_at IS NULL
                ORDER BY updated_at DESC
                """,
                (user_id,),
            ).fetchall()
        return [self.device_dict(row) for row in rows]

    def get_device_for_user(self, user_id: str, device_id: str) -> dict[str, Any] | None:
        with self.lock:
            row = self.db.execute(
                """
                SELECT device_id, device_short_id, name, device_token, pairing_response, created_at, updated_at
                FROM devices
                WHERE owner_user_id = ? AND device_id = ? AND revoked_at IS NULL
                """,
                (user_id, device_id),
            ).fetchone()
        return self.device_dict(row) if row is not None else None

    def validate_device_token(self, device_token: str) -> dict[str, Any] | None:
        token = device_token.strip()
        if not token:
            return None
        with self.lock:
            row = self.db.execute(
                """
                SELECT device_id, owner_user_id, device_short_id, name, device_token, pairing_response, created_at, updated_at
                FROM devices
                WHERE device_token = ? AND revoked_at IS NULL
                """,
                (token,),
            ).fetchone()
        if row is None:
            return None
        device = self.device_dict(row)
        device["owner_user_id"] = row["owner_user_id"]
        return device

    def device_token_revoked(self, device_token: str) -> bool:
        token = device_token.strip()
        if not token:
            return False
        with self.lock:
            row = self.db.execute(
                "SELECT revoked_at FROM devices WHERE device_token = ?",
                (token,),
            ).fetchone()
        return row is not None and int(row["revoked_at"] or 0) > 0

    def revoke_device(self, user_id: str, device_id: str) -> dict[str, Any]:
        clean_id = device_id.strip()
        if not clean_id:
            raise ValueError("device_id_required")
        device = self.get_device_for_user(user_id, clean_id)
        if device is None:
            raise KeyError("invalid_device")
        now = int(time.time())
        with self.lock, self.db:
            self.db.execute(
                "UPDATE devices SET revoked_at = ?, updated_at = ? WHERE owner_user_id = ? AND device_id = ?",
                (now, now, user_id, clean_id),
            )
        device["revoked_at"] = now
        return device

    def device_dict(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "device_id": row["device_id"],
            "device_short_id": row["device_short_id"],
            "name": row["name"],
            "device_token": row["device_token"],
            "pairing_response": row["pairing_response"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def audit_event(
        self,
        event_type: str,
        room_code: str = "",
        actor_id: str = "",
        actor_role: str = "",
        group_id: str = "",
        detail: dict[str, Any] | None = None,
    ) -> None:
        clean_type = event_type.strip()[:64]
        if not clean_type:
            return
        now = int(time.time())
        payload = json.dumps(detail or {}, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO audit_events (
                    event_id, event_type, room_code, actor_id, actor_role, group_id, detail_json, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "evt_" + secrets.token_urlsafe(14),
                    clean_type,
                    room_code.strip()[:64],
                    actor_id.strip()[:160],
                    actor_role.strip()[:32],
                    group_id.strip()[:160],
                    payload[:4000],
                    now,
                ),
            )

    def list_audit_events(self, limit: int = 100, room_code: str = "") -> list[dict[str, Any]]:
        clean_limit = min(200, max(1, limit))
        clean_room = room_code.strip()
        params: tuple[Any, ...]
        where = ""
        if clean_room:
            where = "WHERE room_code = ?"
            params = (clean_room, clean_limit)
        else:
            params = (clean_limit,)
        with self.lock:
            rows = self.db.execute(
                f"""
                SELECT event_id, event_type, room_code, actor_id, actor_role, group_id, detail_json, created_at
                FROM audit_events
                {where}
                ORDER BY created_at DESC
                LIMIT ?
                """,
                params,
            ).fetchall()
        return [self.audit_event_dict(row) for row in rows]

    def save_diagnostics_report(self, user_id: str, report: dict[str, Any]) -> dict[str, Any]:
        room_code = str(report.get("room", {}).get("room_code") or report.get("room_code") or "")[:64]
        payload = json.dumps(report, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        if len(payload.encode("utf-8")) > 128 * 1024:
            raise ValueError("diagnostics_too_large")
        now = int(time.time())
        report_id = "diag_" + secrets.token_urlsafe(14)
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO diagnostics_reports (report_id, user_id, room_code, report_json, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (report_id, user_id, room_code, payload, now),
            )
        self.audit_event(
            "diagnostics_submit",
            room_code=room_code,
            actor_id=user_id,
            actor_role="user",
            group_id=user_id,
            detail={"report_id": report_id, "bytes": len(payload.encode("utf-8"))},
        )
        return {"report_id": report_id, "created_at": now}

    def register_push_subscription(
        self,
        user_id: str,
        device_token: str,
        platform: str = "ios",
        environment: str = "sandbox",
        app_version: str = "",
    ) -> dict[str, Any]:
        token = clean_push_device_token(device_token)
        clean_platform = platform.strip().lower()[:24] or "ios"
        if clean_platform != "ios":
            raise ValueError("unsupported_push_platform")
        clean_environment = environment.strip().lower()[:24] or "sandbox"
        if clean_environment not in {"sandbox", "production"}:
            raise ValueError("invalid_push_environment")
        clean_version = " ".join(app_version.strip().split())[:40]
        now = int(time.time())
        self.ensure_user(user_id)
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO push_subscriptions (
                    device_token, user_id, platform, environment, enabled, app_version, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, 1, ?, ?, ?)
                ON CONFLICT(device_token) DO UPDATE SET
                  user_id = excluded.user_id,
                  platform = excluded.platform,
                  environment = excluded.environment,
                  enabled = 1,
                  app_version = excluded.app_version,
                  updated_at = excluded.updated_at
                """,
                (token, user_id, clean_platform, clean_environment, clean_version, now, now),
            )
        return {
            "device_token": token,
            "user_id": user_id,
            "platform": clean_platform,
            "environment": clean_environment,
            "enabled": True,
            "app_version": clean_version,
            "updated_at": now,
        }

    def list_push_subscriptions(self, user_id: str) -> list[dict[str, Any]]:
        with self.lock:
            rows = self.db.execute(
                """
                SELECT device_token, user_id, platform, environment, enabled, app_version, created_at, updated_at
                FROM push_subscriptions
                WHERE user_id = ? AND enabled = 1
                ORDER BY updated_at DESC
                """,
                (user_id,),
            ).fetchall()
        return [self.push_subscription_dict(row) for row in rows]

    def push_subscription_dict(self, row: sqlite3.Row) -> dict[str, Any]:
        return {
            "device_token": row["device_token"],
            "user_id": row["user_id"],
            "platform": row["platform"],
            "environment": row["environment"],
            "enabled": bool(row["enabled"]),
            "app_version": row["app_version"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def audit_event_dict(self, row: sqlite3.Row) -> dict[str, Any]:
        try:
            detail = json.loads(row["detail_json"] or "{}")
        except json.JSONDecodeError:
            detail = {}
        return {
            "event_id": row["event_id"],
            "event_type": row["event_type"],
            "room_code": row["room_code"],
            "actor_id": row["actor_id"],
            "actor_role": row["actor_role"],
            "group_id": row["group_id"],
            "detail": detail,
            "created_at": row["created_at"],
        }

    def ensure_user(self, user_id: str, display_name: str = "", apple_user_id: str = "") -> None:
        now = int(time.time())
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO users (user_id, apple_user_id, display_name, created_at, updated_at)
                VALUES (?, NULLIF(?, ''), ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                  apple_user_id = COALESCE(NULLIF(excluded.apple_user_id, ''), users.apple_user_id),
                  display_name = COALESCE(NULLIF(excluded.display_name, ''), users.display_name),
                  updated_at = excluded.updated_at
                """,
                (user_id, apple_user_id, display_name, now, now),
            )

    def create_auth_session(self, apple_user_id: str, display_name: str = "") -> dict[str, Any]:
        clean_apple_id = apple_user_id.strip()[:128]
        if not clean_apple_id:
            raise ValueError("apple_user_id_required")
        user_id = f"apple:{clean_apple_id}"
        clean_name = display_name.strip()[:40] or "Dragon Radar User"
        self.ensure_user(user_id, clean_name, apple_user_id=clean_apple_id)
        return self.issue_tokens(user_id, clean_name, clean_apple_id)

    def refresh_auth_session(self, refresh_token: str) -> dict[str, Any]:
        token = refresh_token.strip()
        if not token:
            raise PermissionError("unauthorized")
        with self.lock:
            row = self.db.execute(
                """
                SELECT u.user_id, u.apple_user_id, u.display_name
                FROM auth_tokens t
                JOIN users u ON u.user_id = t.user_id
                WHERE t.refresh_token = ?
                """,
                (token,),
            ).fetchone()
        if row is None:
            raise PermissionError("unauthorized")
        return self.issue_tokens(row["user_id"], row["display_name"], row["apple_user_id"] or "")

    def validate_access_token(self, access_token: str) -> str | None:
        token = access_token.strip()
        if not token:
            return None
        now = int(time.time())
        with self.lock:
            row = self.db.execute(
                """
                SELECT user_id
                FROM auth_tokens
                WHERE access_token = ? AND expires_at > ?
                """,
                (token, now),
            ).fetchone()
        return str(row["user_id"]) if row is not None else None

    def issue_tokens(self, user_id: str, display_name: str, apple_user_id: str) -> dict[str, Any]:
        now = int(time.time())
        expires_at = now + 7 * 24 * 60 * 60
        access_token = "dra_" + secrets.token_urlsafe(32)
        refresh_token = "drr_" + secrets.token_urlsafe(32)
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO auth_tokens (access_token, refresh_token, user_id, expires_at, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (access_token, refresh_token, user_id, expires_at, now),
            )
        return {
            "session": {
                "user_id": user_id,
                "display_name": display_name,
                "apple_user_id": apple_user_id,
                "access_token": access_token,
                "refresh_token": refresh_token,
                "expires_at": expires_at,
            }
        }

    def ensure_room(self, room_code: str, name: str | None = None, owner_user_id: str = "system") -> dict[str, Any]:
        room_code = normalize_room_code(room_code)
        now = int(time.time())
        clean_name = clean_room_name(name) or f"远程雷达房 {room_code}"
        self.ensure_user(owner_user_id)
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO rooms (room_id, room_code, name, owner_user_id, max_members, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(room_code) DO NOTHING
                """,
                (f"room-{room_code}", room_code, clean_name, owner_user_id, MAX_ROOM_MEMBERS, now, now),
            )
        return self.get_room(room_code) or {}

    def create_room(self, name: str, owner_user_id: str) -> dict[str, Any]:
        clean_name = clean_room_name(name)
        if not clean_name:
            raise ValueError("room_name_required")
        existing_room = self.find_room_by_owner_and_name(owner_user_id, clean_name)
        if existing_room is not None:
            self.upsert_member(existing_room["room_code"], owner_user_id, owner_user_id, clean_name, role="owner")
            return existing_room
        for _ in range(16):
            room_code = make_room_code()
            with self.lock:
                if self.get_room(room_code) is None:
                    break
        else:
            raise RuntimeError("room_code_exhausted")
        room = self.ensure_room(room_code, clean_name, owner_user_id)
        self.upsert_member(room_code, owner_user_id, owner_user_id, clean_name, role="owner")
        return self.get_room(room_code) or room

    def find_room_by_owner_and_name(self, owner_user_id: str, name: str) -> dict[str, Any] | None:
        clean_name = clean_room_name(name)
        if not clean_name:
            return None
        self.ensure_user(owner_user_id)
        with self.lock:
            row = self.db.execute(
                """
                SELECT room_id, room_code, name, owner_user_id, max_members, created_at, updated_at
                FROM rooms
                WHERE owner_user_id = ? AND lower(trim(name)) = lower(trim(?))
                ORDER BY updated_at DESC
                LIMIT 1
                """,
                (owner_user_id, clean_name),
            ).fetchone()
            if row is None:
                return None
            return self.room_dict(row)

    def get_room(self, room_code: str) -> dict[str, Any] | None:
        room_code = normalize_room_code(room_code)
        with self.lock:
            row = self.db.execute(
                """
                SELECT room_id, room_code, name, owner_user_id, max_members, created_at, updated_at
                FROM rooms
                WHERE room_code = ?
                """,
                (room_code,),
            ).fetchone()
            if row is None:
                return None
            return self.room_dict(row)

    def list_rooms(self, user_id: str) -> list[dict[str, Any]]:
        self.ensure_user(user_id)
        with self.lock:
            rows = self.db.execute(
                """
                SELECT r.room_id, r.room_code, r.name, r.owner_user_id, r.max_members, r.created_at, r.updated_at
                FROM rooms r
                LEFT JOIN room_members m ON m.room_code = r.room_code AND m.user_id = ?
                WHERE r.owner_user_id = ? OR m.user_id IS NOT NULL
                ORDER BY r.updated_at DESC
                """,
                (user_id, user_id),
            ).fetchall()
            return [self.room_dict(row) for row in rows]

    def join_room(self, room_code: str, user_id: str, member_id: str | None = None, display_name: str = "") -> dict[str, Any]:
        room_code = normalize_room_code(room_code)
        room = self.get_room(room_code)
        if room is None:
            raise KeyError("invalid_room")
        member_id = member_id or user_id
        members = self.list_room_members(room_code)
        existing_member_ids = {member["member_id"] for member in members}
        if member_id not in existing_member_ids and len(existing_member_ids) >= int(room["max_members"]):
            raise OverflowError("room_full")
        self.upsert_member(room_code, member_id, user_id, display_name, role="member")
        return self.get_room(room_code) or room

    def rename_room(self, room_code: str, name: str, user_id: str) -> dict[str, Any]:
        room_code = normalize_room_code(room_code)
        clean_name = clean_room_name(name)
        if not clean_name:
            raise ValueError("room_name_required")
        room = self.get_room(room_code)
        if room is None:
            raise KeyError("invalid_room")
        now = int(time.time())
        with self.lock, self.db:
            self.db.execute(
                "UPDATE rooms SET name = ?, updated_at = ? WHERE room_code = ?",
                (clean_name, now, room_code),
            )
        return self.get_room(room_code) or room

    def remove_member(self, room_code: str, member_id: str, user_id: str) -> dict[str, Any]:
        room_code = normalize_room_code(room_code)
        clean_member_id = member_id.strip()
        if not clean_member_id:
            raise ValueError("member_id_required")
        room = self.get_room(room_code)
        if room is None:
            raise KeyError("invalid_room")
        requester = self.get_room_member(room_code, user_id)
        target = self.get_room_member(room_code, clean_member_id)
        if requester is None:
            raise PermissionError("not_room_member")
        if target is None:
            raise KeyError("invalid_member")
        if requester["role"] != "owner" and requester["member_id"] != clean_member_id:
            raise PermissionError("forbidden")
        if target["role"] == "owner" and requester["role"] != "owner":
            raise PermissionError("forbidden")
        with self.lock, self.db:
            self.db.execute(
                "DELETE FROM room_members WHERE room_code = ? AND member_id = ?",
                (room_code, clean_member_id),
            )
        return self.get_room(room_code) or room

    def delete_room(self, room_code: str, user_id: str) -> None:
        room_code = normalize_room_code(room_code)
        room = self.get_room(room_code)
        if room is None:
            raise KeyError("invalid_room")
        if room["owner_user_id"] != user_id:
            owner_member = self.get_room_member(room_code, user_id)
            if owner_member is None or owner_member["role"] != "owner":
                raise PermissionError("forbidden")
        with self.lock, self.db:
            self.db.execute("DELETE FROM room_invites WHERE room_code = ?", (room_code,))
            self.db.execute("DELETE FROM room_members WHERE room_code = ?", (room_code,))
            self.db.execute("DELETE FROM rooms WHERE room_code = ?", (room_code,))

    def upsert_member(
        self,
        room_code: str,
        member_id: str,
        user_id: str,
        display_name: str = "",
        role: str = "member",
    ) -> None:
        room_code = normalize_room_code(room_code)
        now = int(time.time())
        self.ensure_user(user_id, display_name)
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO room_members (room_code, member_id, user_id, display_name, role, joined_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(room_code, member_id) DO UPDATE SET
                  user_id = excluded.user_id,
                  display_name = COALESCE(NULLIF(excluded.display_name, ''), room_members.display_name),
                  role = CASE
                    WHEN room_members.role = 'owner' THEN room_members.role
                    ELSE excluded.role
                  END,
                  updated_at = excluded.updated_at
                """,
                (room_code, member_id, user_id, display_name, role, now, now),
            )

    def list_room_members(self, room_code: str) -> list[dict[str, Any]]:
        room_code = normalize_room_code(room_code)
        with self.lock:
            rows = self.db.execute(
                """
                SELECT room_code, member_id, user_id, display_name, role, joined_at, updated_at
                FROM room_members
                WHERE room_code = ?
                ORDER BY joined_at ASC
                """,
                (room_code,),
            ).fetchall()
            return [dict(row) for row in rows]

    def get_room_member(self, room_code: str, member_id: str) -> dict[str, Any] | None:
        room_code = normalize_room_code(room_code)
        with self.lock:
            row = self.db.execute(
                """
                SELECT room_code, member_id, user_id, display_name, role, joined_at, updated_at
                FROM room_members
                WHERE room_code = ? AND member_id = ?
                """,
                (room_code, member_id),
            ).fetchone()
            return dict(row) if row is not None else None

    def create_invite(self, room_code: str, user_id: str, expires_at: int | None = None) -> dict[str, Any]:
        room_code = normalize_room_code(room_code)
        if self.get_room(room_code) is None:
            raise KeyError("invalid_room")
        now = int(time.time())
        invite_code = room_code
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO room_invites (invite_code, room_code, created_by, expires_at, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(invite_code) DO UPDATE SET
                  created_by = excluded.created_by,
                  expires_at = excluded.expires_at,
                  created_at = excluded.created_at
                """,
                (invite_code, room_code, user_id, expires_at, now),
            )
        return {
            "invite_code": invite_code,
            "room_code": room_code,
            "expires_at": expires_at,
            "created_at": now,
        }

    def room_dict(self, row: sqlite3.Row) -> dict[str, Any]:
        room_code = row["room_code"]
        members = self.list_room_members(room_code)
        return {
            "room_id": row["room_id"],
            "room_code": room_code,
            "name": row["name"],
            "owner_user_id": row["owner_user_id"],
            "max_members": row["max_members"],
            "member_count": len(members),
            "members": members,
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }


store: RelayStore | None = None


@dataclass
class Peer:
    socket: WebSocketServerProtocol
    role: str
    room: str
    member_id: str
    group_id: str
    user_id: str = ""
    device_id: str = ""
    app_id: str = ""
    connected_at: float = field(default_factory=time.time)
    last_seen_at: float = field(default_factory=time.time)
    last_location_at: float = 0.0
    last_payload: dict[str, Any] = field(default_factory=dict)
    message_window_started_at: float = field(default_factory=time.time)
    message_window_count: int = 0

    @property
    def peer_id(self) -> str:
        return self.device_id or self.app_id or self.member_id


@dataclass
class Room:
    code: str
    peers: dict[str, Peer] = field(default_factory=dict)
    speaker_group_id: str = ""
    speaker_peer_id: str = ""
    speaker_until: float = 0.0

    def expire_voice_floor(self) -> None:
        if self.speaker_group_id and time.time() >= self.speaker_until:
            self.speaker_group_id = ""
            self.speaker_peer_id = ""
            self.speaker_until = 0.0

    def voice_floor(self) -> dict[str, Any]:
        self.expire_voice_floor()
        active = bool(self.speaker_group_id)
        return {
            "active": active,
            "speaker_group_id": self.speaker_group_id if active else None,
            "speaker_peer_id": self.speaker_peer_id if active else None,
            "expires_in_ms": max(0, int((self.speaker_until - time.time()) * 1000)) if active else 0,
        }

    def members(self) -> list[dict[str, Any]]:
        values = []
        now = time.time()
        self.expire_voice_floor()
        speaker_group_id = self.speaker_group_id
        groups: dict[str, list[Peer]] = {}
        for peer in self.peers.values():
            groups.setdefault(peer.group_id, []).append(peer)

        for group_id, peers in sorted(groups.items(), key=lambda item: min(peer.connected_at for peer in item[1])):
            app_peer = newest_peer((peer for peer in peers if peer.role == "app"), want_location=True)
            device_peer = newest_peer((peer for peer in peers if peer.role == "device"), want_voice=True)
            status_peer = newest_peer(peers)
            location_peer = app_peer or newest_peer(peers, want_location=True)
            display_peer = app_peer or device_peer or status_peer
            connected_at = min(peer.connected_at for peer in peers)
            last_seen_at = max(peer.last_seen_at for peer in peers)
            voice_status = device_peer.last_payload.get("voice_status") if device_peer else None
            location_paused = any(bool_value(peer.last_payload.get("location_paused")) for peer in peers)
            location_payload = location_peer.last_payload.get("location") if location_peer else None
            location_timestamp = (
                location_peer.last_location_at
                if location_peer and location_peer.last_location_at > 0
                else (location_peer.last_seen_at if location_peer and location_payload else 0.0)
            )
            location_age_ms = int((now - location_timestamp) * 1000) if location_timestamp else None
            location_stale = (
                location_age_ms is not None
                and location_age_ms > LOCATION_STALE_AFTER_SECONDS * 1000
            )
            if isinstance(voice_status, dict):
                voice_status = dict(voice_status)
                if group_id == speaker_group_id:
                    voice_status["floor_granted"] = True
                    voice_status["speaker"] = True
                else:
                    voice_status["ptt"] = False
                    voice_status["vad"] = False
                    voice_status["floor_granted"] = False
                    voice_status["speaker"] = False
            values.append(
                {
                    "role": "app" if app_peer else display_peer.role,
                    "member_id": group_id,
                    "peer_id": display_peer.peer_id,
                    "app_peer_id": app_peer.peer_id if app_peer else None,
                    "device_peer_id": device_peer.peer_id if device_peer else None,
                    "group_id": group_id,
                    "name": group_name(app_peer, device_peer, display_peer),
                    "online": True,
                    "age_ms": int((now - connected_at) * 1000),
                    "last_seen_ms": int((now - last_seen_at) * 1000),
                    "last_type": status_peer.last_payload.get("type", "hello"),
                    "protocol_version": max(message_protocol_version(peer.last_payload) for peer in peers),
                    "firmware": device_peer.last_payload.get("firmware") if device_peer else None,
                    "device_status": device_peer.last_payload.get("device_status") if device_peer else None,
                    "voice_status": voice_status,
                    "location": None if location_paused else location_payload,
                    "location_paused": location_paused,
                    "location_stale": location_stale,
                    "location_age_ms": location_age_ms,
                    "app_online": app_peer is not None,
                    "device_online": device_peer is not None,
                    "connection_count": len(peers),
                }
            )
        return values


rooms: dict[str, Room] = {}
pending_room_switches: dict[str, dict[str, Any]] = {}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Minimal Dragon Radar WebSocket Relay.")
    parser.add_argument("--host", default="0.0.0.0", help="Bind host, default: 0.0.0.0")
    parser.add_argument("--port", type=int, default=8787, help="Bind port, default: 8787")
    parser.add_argument("--http-port", type=int, default=8788, help="HTTP API port, default: 8788")
    parser.add_argument("--db-path", default="dragon-radar-relay.sqlite3", help="SQLite database path.")
    return parser.parse_args()


def json_message(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True)


def relay_protocol_payload() -> dict[str, int]:
    return {
        "relay": RELAY_PROTOCOL_VERSION,
        "min_app": MIN_APP_PROTOCOL_VERSION,
        "min_device": MIN_DEVICE_PROTOCOL_VERSION,
        "location_frame": LOCATION_FRAME_PROTOCOL_VERSION,
        "voice": VOICE_PROTOCOL_VERSION,
    }


def base64url_decode(value: str) -> bytes:
    clean = value.encode("ascii")
    clean += b"=" * (-len(clean) % 4)
    return base64.urlsafe_b64decode(clean)


def base64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def make_room_code() -> str:
    suffix = "".join(secrets.choice(ROOM_CODE_ALPHABET) for _ in range(4))
    return f"KAME-{suffix}"


def normalize_room_code(value: str) -> str:
    clean = value.strip().upper()
    if not clean:
        raise ValueError("room_code_required")
    return clean


def clean_room_name(value: str | None) -> str:
    if value is None:
        return ""
    return " ".join(value.strip().split())[:40]


def device_short_id_from_challenge(value: str) -> str:
    clean = "".join(ch for ch in value.upper() if ch in string.ascii_uppercase + string.digits)
    if len(clean) >= 4:
        return clean[-4:]
    suffix = "".join(secrets.choice(ROOM_CODE_ALPHABET) for _ in range(4 - len(clean)))
    return (clean + suffix)[:4]


def user_id_from_headers(headers: Any) -> str:
    authorization = headers.get("Authorization", "")
    if authorization.startswith("Bearer "):
        token = authorization.removeprefix("Bearer ").strip()
        if token and store is not None:
            user_id = store.validate_access_token(token)
            if user_id:
                return user_id
    return ""


def display_name_from_payload(payload: dict[str, Any], fallback: str) -> str:
    for key in ("display_name", "name", "room_name"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()[:40]
    return fallback


def clean_push_device_token(value: str) -> str:
    token = value.strip()
    allowed = set(string.ascii_letters + string.digits + "._:-")
    if len(token) < 32 or len(token) > 256 or any(ch not in allowed for ch in token):
        raise ValueError("invalid_push_device_token")
    return token


def live_room_counts(room_code: str) -> dict[str, int]:
    room = rooms.get(normalize_room_code(room_code))
    if room is None:
        return {"online_groups": 0, "connections": 0}
    groups = {peer.group_id for peer in room.peers.values()}
    return {"online_groups": len(groups), "connections": len(room.peers)}


@dataclass
class APNsConfig:
    mode: str
    team_id: str
    key_id: str
    key_path: str
    topic: str

    @classmethod
    def from_env(cls) -> "APNsConfig":
        mode = os.environ.get("DRAGON_RADAR_APNS_MODE", "disabled").strip().lower() or "disabled"
        if mode not in {"disabled", "dry_run", "live"}:
            mode = "disabled"
        return cls(
            mode=mode,
            team_id=os.environ.get("DRAGON_RADAR_APNS_TEAM_ID", "").strip(),
            key_id=os.environ.get("DRAGON_RADAR_APNS_KEY_ID", "").strip(),
            key_path=os.environ.get("DRAGON_RADAR_APNS_KEY_PATH", "").strip(),
            topic=os.environ.get("DRAGON_RADAR_APNS_TOPIC", "").strip(),
        )

    def live_ready(self) -> bool:
        return bool(self.team_id and self.key_id and self.key_path and self.topic and os.path.exists(self.key_path))

    def health_payload(self) -> dict[str, Any]:
        return {
            "mode": self.mode,
            "live_ready": self.live_ready(),
            "topic_configured": bool(self.topic),
            "team_configured": bool(self.team_id),
            "key_id_configured": bool(self.key_id),
            "key_path_configured": bool(self.key_path),
        }


class PushNotificationService:
    def __init__(self, config: APNsConfig) -> None:
        self.config = config
        self.lock = threading.RLock()
        self.cached_jwt = ""
        self.cached_jwt_issued_at = 0

    def health_payload(self) -> dict[str, Any]:
        return self.config.health_payload()

    def send_to_user(
        self,
        relay_store: RelayStore,
        target_user_id: str,
        notification_type: str,
        room_code: str,
        title: str,
        body: str,
        data: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        clean_target = target_user_id.strip()[:160]
        clean_type = notification_type.strip()[:64] or "notification"
        clean_room = normalize_room_code(room_code) if room_code.strip() else ""
        if not clean_target:
            return {"status": "skipped", "reason": "target_user_missing", "mode": self.config.mode}
        if self.config.mode == "disabled":
            return {"status": "skipped", "reason": "notifications_disabled", "mode": self.config.mode}

        subscriptions = relay_store.list_push_subscriptions(clean_target)
        if not subscriptions:
            result = {
                "status": "skipped",
                "reason": "no_push_subscription",
                "mode": self.config.mode,
                "target_user_id": clean_target,
            }
            self.audit_delivery(relay_store, clean_type, clean_room, clean_target, result)
            return result

        attempts = [
            self.deliver_to_subscription(subscription, clean_type, clean_room, title, body, data or {})
            for subscription in subscriptions
        ]
        if all(attempt.get("status") == "dry_run" for attempt in attempts):
            status = "dry_run"
        elif any(attempt.get("status") == "sent" for attempt in attempts):
            status = "sent" if all(attempt.get("status") == "sent" for attempt in attempts) else "partial"
        else:
            status = "failed"
        result = {
            "status": status,
            "mode": self.config.mode,
            "target_user_id": clean_target,
            "attempt_count": len(attempts),
            "attempts": attempts,
        }
        self.audit_delivery(relay_store, clean_type, clean_room, clean_target, result)
        return result

    def deliver_to_subscription(
        self,
        subscription: dict[str, Any],
        notification_type: str,
        room_code: str,
        title: str,
        body: str,
        data: dict[str, Any],
    ) -> dict[str, Any]:
        token = str(subscription.get("device_token") or "")
        environment = str(subscription.get("environment") or "sandbox")
        base = {
            "device_token_suffix": token[-8:],
            "environment": environment,
            "status": self.config.mode,
        }
        if self.config.mode == "dry_run":
            return base
        if not self.config.live_ready():
            return {**base, "status": "failed", "reason": "apns_not_configured"}
        try:
            status_code, response_body = self.post_apns(token, environment, notification_type, room_code, title, body, data)
        except Exception as exc:
            return {**base, "status": "failed", "reason": str(exc)[:160]}
        if 200 <= status_code < 300:
            return {**base, "status": "sent", "apns_status": status_code}
        return {**base, "status": "failed", "apns_status": status_code, "reason": response_body[:240]}

    def post_apns(
        self,
        device_token: str,
        environment: str,
        notification_type: str,
        room_code: str,
        title: str,
        body: str,
        data: dict[str, Any],
    ) -> tuple[int, str]:
        host = "api.push.apple.com" if environment == "production" else "api.sandbox.push.apple.com"
        payload = {
            "aps": {
                "alert": {"title": title[:80], "body": body[:160]},
                "sound": "default",
            },
            "type": notification_type,
            "room_code": room_code,
            "data": data,
        }
        jwt = self.apns_jwt()
        command = [
            "curl",
            "--silent",
            "--show-error",
            "--http2",
            "--request",
            "POST",
            "--max-time",
            "8",
            "--header",
            f"authorization: bearer {jwt}",
            "--header",
            f"apns-topic: {self.config.topic}",
            "--header",
            "apns-push-type: alert",
            "--header",
            "apns-priority: 10",
            "--header",
            "content-type: application/json",
            "--data-binary",
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
            "--write-out",
            "\n%{http_code}",
            f"https://{host}/3/device/{device_token}",
        ]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=10, check=False)
        output = (completed.stdout or "").rstrip("\n")
        if completed.returncode != 0:
            raise RuntimeError((completed.stderr or "apns_curl_failed").strip())
        body_text, _, status_text = output.rpartition("\n")
        try:
            status_code = int(status_text)
        except ValueError:
            status_code = 0
        return status_code, body_text

    def apns_jwt(self) -> str:
        now = int(time.time())
        with self.lock:
            if self.cached_jwt and now - self.cached_jwt_issued_at < 50 * 60:
                return self.cached_jwt
        header = {"alg": "ES256", "kid": self.config.key_id}
        claims = {"iss": self.config.team_id, "iat": now}
        signed_input = (
            f"{base64url_encode(json.dumps(header, separators=(',', ':')).encode('utf-8'))}."
            f"{base64url_encode(json.dumps(claims, separators=(',', ':')).encode('utf-8'))}"
        ).encode("ascii")
        completed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.config.key_path],
            input=signed_input,
            capture_output=True,
            timeout=5,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError((completed.stderr.decode("utf-8", "ignore") or "apns_sign_failed").strip())
        signature = base64url_encode(ecdsa_der_to_raw_rs(completed.stdout))
        jwt = f"{signed_input.decode('ascii')}.{signature}"
        with self.lock:
            self.cached_jwt = jwt
            self.cached_jwt_issued_at = now
        return jwt

    def audit_delivery(
        self,
        relay_store: RelayStore,
        notification_type: str,
        room_code: str,
        target_user_id: str,
        result: dict[str, Any],
    ) -> None:
        relay_store.audit_event(
            "push_delivery",
            room_code=room_code,
            actor_id=target_user_id,
            actor_role="user",
            group_id=target_user_id,
            detail={
                "notification_type": notification_type,
                "status": result.get("status"),
                "mode": result.get("mode"),
                "attempt_count": result.get("attempt_count", 0),
                "reason": result.get("reason", ""),
            },
        )


def ecdsa_der_to_raw_rs(signature: bytes) -> bytes:
    def read_length(offset: int) -> tuple[int, int]:
        length = signature[offset]
        offset += 1
        if length & 0x80:
            length_bytes = length & 0x7F
            length = int.from_bytes(signature[offset : offset + length_bytes], "big")
            offset += length_bytes
        return length, offset

    def read_integer(offset: int) -> tuple[bytes, int]:
        if signature[offset] != 0x02:
            raise ValueError("invalid_ecdsa_signature")
        length, offset = read_length(offset + 1)
        value = signature[offset : offset + length]
        offset += length
        value = value.lstrip(b"\x00")
        if len(value) > 32:
            raise ValueError("invalid_ecdsa_signature")
        return value.rjust(32, b"\x00"), offset

    if len(signature) < 8 or signature[0] != 0x30:
        raise ValueError("invalid_ecdsa_signature")
    _, cursor = read_length(1)
    r_value, cursor = read_integer(cursor)
    s_value, _ = read_integer(cursor)
    return r_value + s_value


push_notifications = PushNotificationService(APNsConfig.from_env())


def enrich_room(room: dict[str, Any]) -> dict[str, Any]:
    enriched = dict(room)
    enriched.update(live_room_counts(str(room["room_code"])))
    return enriched


def relay_health_payload() -> dict[str, Any]:
    connection_count = sum(len(room.peers) for room in rooms.values())
    return {
        "ok": True,
        "service": "dragon-radar-relay",
        "rooms": len(rooms),
        "connections": connection_count,
        "notifications": push_notifications.health_payload(),
        "protocol": relay_protocol_payload(),
        "limits": {
            "http_max_body_bytes": HTTP_MAX_BODY_BYTES,
            "http_rate_limit_per_minute": HTTP_RATE_LIMIT_PER_MINUTE,
            "ws_max_message_bytes": WS_MAX_MESSAGE_BYTES,
            "ws_message_rate_limit_per_second": WS_MESSAGE_RATE_LIMIT_PER_SECOND,
            "ws_idle_timeout_seconds": WS_IDLE_TIMEOUT_SECONDS,
            "ws_ping_interval_seconds": WS_PING_INTERVAL_SECONDS,
            "ws_ping_timeout_seconds": WS_PING_TIMEOUT_SECONDS,
            "location_stale_after_seconds": LOCATION_STALE_AFTER_SECONDS,
        },
    }


class RelayHTTPHandler(BaseHTTPRequestHandler):
    server_version = "DragonRadarRelayHTTP/0.1"

    def do_GET(self) -> None:
        self.handle_request("GET")

    def do_POST(self) -> None:
        self.handle_request("POST")

    def do_PATCH(self) -> None:
        self.handle_request("PATCH")

    def do_DELETE(self) -> None:
        self.handle_request("DELETE")

    def log_message(self, format: str, *args: Any) -> None:
        print(f"http {self.address_string()} {format % args}", flush=True)

    def handle_request(self, method: str) -> None:
        try:
            parsed = urlparse(self.path)
            path = parsed.path.rstrip("/") or "/"
            client_ip = self.client_address[0] if self.client_address else "unknown"
            if not http_rate_limiter.allow(f"{client_ip}:{method}:{path}"):
                self.send_error_json(HTTPStatus.TOO_MANY_REQUESTS, "rate_limited")
                return
            payload = self.read_json_body()

            if path == "/healthz" and method == "GET":
                self.send_json(HTTPStatus.OK, relay_health_payload())
                return

            if path == "/v1/auth/apple" and method == "POST":
                self.require_store()
                assert store is not None
                requested_apple_user_id = str(payload.get("apple_user_id") or "")
                identity_token = str(payload.get("identity_token") or "")
                verified_identity = apple_identity_verifier.verify(identity_token, requested_apple_user_id)
                display_name = display_name_from_payload(payload, "Dragon Radar User")
                self.send_json(HTTPStatus.OK, store.create_auth_session(verified_identity.apple_user_id, display_name))
                return

            if path == "/v1/auth/refresh" and method == "POST":
                self.require_store()
                assert store is not None
                refresh_token = str(payload.get("refresh_token") or "")
                self.send_json(HTTPStatus.OK, store.refresh_auth_session(refresh_token))
                return

            user_id = user_id_from_headers(self.headers)
            if not user_id:
                self.send_error_json(HTTPStatus.UNAUTHORIZED, "unauthorized")
                return

            if path == "/v1/devices" and method == "GET":
                self.require_store()
                assert store is not None
                self.send_json(HTTPStatus.OK, {"devices": store.list_devices(user_id)})
                return

            if path == "/v1/audit/events" and method == "GET":
                self.require_store()
                assert store is not None
                parsed_query = parse_qs(parsed.query)
                limit = int((parsed_query.get("limit") or ["100"])[0] or "100")
                room_code = (parsed_query.get("room") or [""])[0]
                self.send_json(HTTPStatus.OK, {"events": store.list_audit_events(limit=limit, room_code=room_code)})
                return

            if path == "/v1/diagnostics" and method == "POST":
                self.require_store()
                assert store is not None
                report = payload.get("report") if isinstance(payload.get("report"), dict) else payload
                self.send_json(HTTPStatus.CREATED, {"diagnostics": store.save_diagnostics_report(user_id, report)})
                return

            if path == "/v1/push/register" and method == "POST":
                self.require_store()
                assert store is not None
                subscription = store.register_push_subscription(
                    user_id,
                    str(payload.get("device_token") or ""),
                    platform=str(payload.get("platform") or "ios"),
                    environment=str(payload.get("environment") or "sandbox"),
                    app_version=str(payload.get("app_version") or ""),
                )
                store.audit_event(
                    "push_register",
                    actor_id=user_id,
                    actor_role="user",
                    group_id=user_id,
                    detail={
                        "platform": subscription.get("platform"),
                        "environment": subscription.get("environment"),
                        "device_token_suffix": str(subscription.get("device_token") or "")[-8:],
                    },
                )
                self.send_json(HTTPStatus.CREATED, {"subscription": subscription})
                return

            if path == "/v1/devices/register-challenge" and method == "POST":
                self.require_store()
                assert store is not None
                challenge = str(payload.get("pairing_challenge") or payload.get("challenge") or "")
                name = str(payload.get("name") or "")
                device = store.register_device_challenge(user_id, challenge, name=name)
                store.audit_event(
                    "device_register",
                    actor_id=user_id,
                    actor_role="user",
                    group_id=device.get("device_token", ""),
                    detail={"device_id": device.get("device_id"), "device_short_id": device.get("device_short_id")},
                )
                self.send_json(HTTPStatus.CREATED, {"device": device})
                return

            device_prefix = "/v1/devices/"
            if path.startswith(device_prefix):
                self.require_store()
                assert store is not None
                device_id = path.removeprefix(device_prefix).strip("/")
                if device_id and method == "DELETE":
                    device = store.revoke_device(user_id, device_id)
                    store.audit_event(
                        "device_revoke",
                        actor_id=user_id,
                        actor_role="user",
                        group_id=device.get("device_token", ""),
                        detail={"device_id": device.get("device_id"), "device_short_id": device.get("device_short_id")},
                    )
                    self.send_json(HTTPStatus.OK, {"device": device})
                    return

            if path == "/v1/rooms" and method == "GET":
                self.require_store()
                assert store is not None
                self.send_json(HTTPStatus.OK, {"rooms": [enrich_room(room) for room in store.list_rooms(user_id)]})
                return

            if path == "/v1/rooms" and method == "POST":
                self.require_store()
                assert store is not None
                room = store.create_room(str(payload.get("name") or ""), user_id)
                store.audit_event(
                    "room_create",
                    room_code=str(room.get("room_code", "")),
                    actor_id=user_id,
                    actor_role="user",
                    group_id=user_id,
                    detail={"name": room.get("name")},
                )
                self.send_json(HTTPStatus.CREATED, {"room": enrich_room(room)})
                return

            if path == "/v1/rooms/join" and method == "POST":
                self.require_store()
                assert store is not None
                room_code = str(payload.get("room_code") or payload.get("code") or "")
                member_id = str(payload.get("member_id") or user_id)
                display_name = display_name_from_payload(payload, user_id)
                room = store.join_room(room_code, user_id, member_id=member_id, display_name=display_name)
                store.audit_event(
                    "room_join",
                    room_code=str(room.get("room_code", normalize_room_code(room_code))),
                    actor_id=user_id,
                    actor_role="user",
                    group_id=member_id,
                    detail={"display_name": display_name},
                )
                self.send_json(HTTPStatus.OK, {"room": enrich_room(room)})
                return

            room_prefix = "/v1/rooms/"
            if path.startswith(room_prefix):
                self.require_store()
                assert store is not None
                remainder = path.removeprefix(room_prefix)
                parts = [part for part in remainder.split("/") if part]
                if not parts:
                    self.send_error_json(HTTPStatus.NOT_FOUND, "not_found")
                    return
                room_code = parts[0]

                if len(parts) == 1 and method == "GET":
                    room = store.get_room(room_code)
                    if room is None:
                        self.send_error_json(HTTPStatus.NOT_FOUND, "invalid_room")
                        return
                    self.send_json(HTTPStatus.OK, {"room": enrich_room(room)})
                    return

                if len(parts) == 1 and method == "PATCH":
                    room = store.rename_room(room_code, str(payload.get("name") or ""), user_id)
                    store.audit_event(
                        "room_rename",
                        room_code=str(room.get("room_code", normalize_room_code(room_code))),
                        actor_id=user_id,
                        actor_role="user",
                        group_id=user_id,
                        detail={"name": room.get("name")},
                    )
                    self.send_json(HTTPStatus.OK, {"room": enrich_room(room)})
                    return

                if len(parts) == 2 and parts[1] == "invite" and method == "POST":
                    invite = store.create_invite(room_code, user_id, int(payload["expires_at"]) if "expires_at" in payload else None)
                    target_user_id = str(payload.get("target_user_id") or "")
                    store.audit_event(
                        "room_invite",
                        room_code=normalize_room_code(room_code),
                        actor_id=user_id,
                        actor_role="user",
                        group_id=target_user_id or user_id,
                        detail={"invite_code": invite.get("invite_code"), "target_user_id": target_user_id},
                    )
                    notification = push_notifications.send_to_user(
                        store,
                        target_user_id,
                        "room_invite",
                        normalize_room_code(room_code),
                        "Dragon Radar 房间邀请",
                        f"有人邀请你加入房间 {normalize_room_code(room_code)}",
                        {"invite_code": invite.get("invite_code"), "created_by": user_id},
                    )
                    self.send_json(HTTPStatus.CREATED, {"invite": invite, "notification": notification})
                    return

                if len(parts) == 3 and parts[1] == "members" and method == "DELETE":
                    room = store.remove_member(room_code, parts[2], user_id)
                    store.audit_event(
                        "room_member_remove",
                        room_code=normalize_room_code(room_code),
                        actor_id=user_id,
                        actor_role="user",
                        group_id=parts[2],
                    )
                    self.send_json(HTTPStatus.OK, {"room": enrich_room(room)})
                    return

                if len(parts) == 1 and method == "DELETE":
                    store.delete_room(room_code, user_id)
                    store.audit_event(
                        "room_delete",
                        room_code=normalize_room_code(room_code),
                        actor_id=user_id,
                        actor_role="user",
                        group_id=user_id,
                    )
                    self.send_json(HTTPStatus.OK, {"ok": True, "room_code": normalize_room_code(room_code)})
                    return

            self.send_error_json(HTTPStatus.NOT_FOUND, "not_found")
        except ValueError as exc:
            self.send_error_json(HTTPStatus.BAD_REQUEST, str(exc))
        except KeyError as exc:
            self.send_error_json(HTTPStatus.NOT_FOUND, str(exc).strip("'"))
        except PayloadTooLarge as exc:
            self.send_error_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, str(exc))
        except OverflowError as exc:
            self.send_error_json(HTTPStatus.CONFLICT, str(exc))
        except PermissionError as exc:
            self.send_error_json(HTTPStatus.FORBIDDEN, str(exc))
        except Exception as exc:
            self.send_error_json(HTTPStatus.INTERNAL_SERVER_ERROR, "internal_error", detail=str(exc))

    def read_json_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        if length > HTTP_MAX_BODY_BYTES:
            raise PayloadTooLarge("request_too_large")
        raw = self.rfile.read(length)
        if not raw:
            return {}
        decoded = json.loads(raw.decode("utf-8"))
        if not isinstance(decoded, dict):
            raise ValueError("json_object_required")
        return decoded

    def require_store(self) -> None:
        if store is None:
            raise RuntimeError("store_not_ready")

    def send_json(self, status: HTTPStatus, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_error_json(self, status: HTTPStatus, code: str, detail: str | None = None) -> None:
        payload: dict[str, Any] = {"ok": False, "code": code}
        if detail:
            payload["detail"] = detail
        self.send_json(status, payload)


def start_http_server(host: str, port: int) -> ThreadingHTTPServer:
    httpd = ThreadingHTTPServer((host, port), RelayHTTPHandler)
    thread = threading.Thread(target=httpd.serve_forever, name="relay-http", daemon=True)
    thread.start()
    print(f"Dragon Radar HTTP API listening on http://{host}:{port}", flush=True)
    return httpd


def member_name(peer: Peer) -> str:
    payload_name = peer.last_payload.get("name")
    if isinstance(payload_name, str) and payload_name.strip():
        return payload_name.strip()

    device_status = peer.last_payload.get("device_status")
    if isinstance(device_status, dict):
        status_name = device_status.get("name")
        if isinstance(status_name, str) and status_name.strip():
            return status_name.strip()

    if peer.role == "device":
        return peer.device_id or peer.peer_id
    return peer.app_id or peer.peer_id


def newest_peer(peers: Any, want_location: bool = False, want_voice: bool = False) -> Peer | None:
    candidates = list(peers)
    if want_location:
        with_location = [peer for peer in candidates if peer.last_payload.get("location")]
        if with_location:
            candidates = with_location
    if want_voice:
        with_voice = [peer for peer in candidates if peer.last_payload.get("voice_status")]
        if with_voice:
            candidates = with_voice
    if not candidates:
        return None
    return max(candidates, key=lambda peer: peer.last_seen_at)


def group_name(app_peer: Peer | None, device_peer: Peer | None, fallback_peer: Peer) -> str:
    for peer in (app_peer, device_peer, fallback_peer):
        if peer is None:
            continue
        name = member_name(peer)
        if name:
            return name.replace(" iPhone", "").replace(" ESP", "")
    return fallback_peer.group_id


async def send_json(peer: Peer, payload: dict[str, Any]) -> None:
    await peer.socket.send(json_message(payload))


async def safe_send_json(peer: Peer, payload: dict[str, Any]) -> None:
    try:
        await send_json(peer, payload)
    except Exception:
        pass


def role_for_path(path: str) -> str:
    if path == APP_PATH:
        return "app"
    if path == DEVICE_PATH:
        return "device"
    raise ValueError(f"unsupported path: {path}")


def room_state(room: Room) -> dict[str, Any]:
    return {
        "type": "room_state",
        "room": room.code,
        "server_time": int(time.time()),
        "max_members": MAX_ROOM_MEMBERS,
        "voice_floor": room.voice_floor(),
        "members": room.members(),
    }


async def broadcast_room(room: Room, payload: dict[str, Any], exclude: str | None = None) -> None:
    peers = [peer for member_id, peer in room.peers.items() if member_id != exclude]
    await asyncio.gather(*(safe_send_json(peer, payload) for peer in peers), return_exceptions=True)


async def broadcast_room_state(room: Room) -> None:
    await broadcast_room(room, room_state(room))


def room_switch_event(peer: Peer, message: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "relay_event",
        "room": peer.room,
        "from": peer.peer_id,
        "role": peer.role,
        "event": "room_switch",
        "payload": message,
        "server_time": int(time.time()),
    }


def notify_user(
    target_user_id: str,
    notification_type: str,
    room_code: str,
    title: str,
    body: str,
    data: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if store is None:
        return {"status": "skipped", "reason": "store_not_ready", "mode": push_notifications.config.mode}
    return push_notifications.send_to_user(
        store,
        target_user_id,
        notification_type,
        room_code,
        title,
        body,
        data or {},
    )


def connected_device_peers_for_group(group_id: str) -> list[Peer]:
    peers: list[Peer] = []
    for room in rooms.values():
        for candidate in room.peers.values():
            if candidate.role == "device" and candidate.group_id == group_id:
                peers.append(candidate)
    return peers


async def deliver_room_switch_to_group(group_id: str, payload: dict[str, Any]) -> int:
    targets = connected_device_peers_for_group(group_id)
    await asyncio.gather(*(safe_send_json(peer, payload) for peer in targets), return_exceptions=True)
    return len(targets)


def value_from_query(query: dict[str, list[str]], key: str, fallback: str) -> str:
    values = query.get(key)
    if not values:
        return fallback
    return values[0] or fallback


def make_peer(socket: WebSocketServerProtocol, path: str) -> Peer:
    parsed = urlparse(path)
    role = role_for_path(parsed.path)
    query = parse_qs(parsed.query)
    user_id = ""
    if role == "app":
        token = value_from_query(query, "token", "")
        user_id = store.validate_access_token(token) if store is not None else None
        if not user_id:
            raise PermissionError("unauthorized")
    room = value_from_query(query, "room", "DRGN-0001")
    device_id = value_from_query(query, "device_id", "")
    app_id = value_from_query(query, "app_id", "")
    explicit_group_id = value_from_query(query, "group_id", "")
    if role == "device":
        device = store.validate_device_token(device_id) if store is not None else None
        if not device:
            if store is not None and store.device_token_revoked(device_id):
                raise PermissionError("device_revoked")
            raise PermissionError("unauthorized")
        user_id = str(device.get("owner_user_id") or "")
    if role == "device":
        member_id = device_id or f"device-{id(socket):x}"
    else:
        member_id = app_id or f"app-{id(socket):x}"
    group_id = explicit_group_id or group_id_for_peer(role, device_id, app_id, member_id)
    return Peer(
        socket=socket,
        role=role,
        room=room,
        member_id=member_id,
        group_id=group_id,
        user_id=user_id or "",
        device_id=device_id,
        app_id=app_id,
    )


def group_id_for_peer(role: str, device_id: str, app_id: str, fallback: str) -> str:
    if role == "device" and device_id:
        return device_id
    if role == "app" and app_id:
        return app_id[4:] if app_id.startswith("app-") and len(app_id) > 4 else app_id
    return fallback


def normalize_last_payload(message: dict[str, Any]) -> dict[str, Any]:
    message_type = message.get("type")
    normalized = dict(message)
    if message_type == "device_status":
        normalized["device_status"] = message.get("device_status") or message.get("status")
    if message_type == "app_location":
        normalized["location"] = message.get("location") or {
            key: message[key]
            for key in ("lat", "lon", "accuracy_m", "speed_mps", "course_deg", "timestamp")
            if key in message
        }
        if isinstance(normalized["location"], dict) and "sequence" in message:
            normalized["location"] = dict(normalized["location"])
            normalized["location"]["sequence"] = message["sequence"]
        normalized["location_paused"] = False
    if message_type == "location_paused":
        normalized["location_paused"] = True
        normalized.pop("location", None)
    if message_type in {"voice_frame", "audio_frame", "voice_state", "mute_update"}:
        normalized["voice_status"] = message.get("voice_status") or {
            key: message[key]
            for key in ("muted", "ptt", "vad", "codec", "sample_rate", "frame_ms", "sequence")
            if key in message
        }
    return normalized


def merge_last_payload(previous: dict[str, Any], message: dict[str, Any]) -> dict[str, Any]:
    normalized = normalize_last_payload(message)
    merged = dict(previous)
    merged.update(normalized)
    if normalized.get("location_paused") is True:
        merged.pop("location", None)
    for durable_key in ("location", "device_status", "voice_status"):
        if durable_key not in normalized and durable_key in previous:
            merged[durable_key] = previous[durable_key]
    return merged


def voice_status_from_message(message: dict[str, Any]) -> dict[str, Any]:
    status = message.get("voice_status")
    if isinstance(status, dict):
        return dict(status)
    return {
        key: message[key]
        for key in ("muted", "ptt", "vad", "codec", "sample_rate", "frame_ms", "sequence")
        if key in message
    }


def bool_value(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def int_value(value: Any, default: int = 0) -> int:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        try:
            return int(value.strip())
        except ValueError:
            return default
    return default


def message_protocol_version(message: dict[str, Any]) -> int:
    for key in ("protocol_version", "protocol"):
        value = message.get(key)
        if isinstance(value, dict):
            value = value.get("version") or value.get("device") or value.get("app")
        version = int_value(value)
        if version > 0:
            return version
    return 1


def minimum_protocol_for_role(role: str) -> int:
    if role == "device":
        return MIN_DEVICE_PROTOCOL_VERSION
    return MIN_APP_PROTOCOL_VERSION


def protocol_compatible(peer: Peer, message: dict[str, Any]) -> tuple[bool, int, int]:
    version = message_protocol_version(message)
    minimum = minimum_protocol_for_role(peer.role)
    return version >= minimum, version, minimum


def raw_message_size(raw: Any) -> int:
    if isinstance(raw, bytes):
        return len(raw)
    if isinstance(raw, str):
        return len(raw.encode("utf-8"))
    return len(str(raw).encode("utf-8"))


def websocket_message_allowed(peer: Peer, now: float | None = None) -> bool:
    if WS_MESSAGE_RATE_LIMIT_PER_SECOND <= 0:
        return True
    timestamp = time.time() if now is None else now
    if timestamp - peer.message_window_started_at >= 1.0:
        peer.message_window_started_at = timestamp
        peer.message_window_count = 0
    peer.message_window_count += 1
    return peer.message_window_count <= WS_MESSAGE_RATE_LIMIT_PER_SECOND


def validate_websocket_raw(peer: Peer, raw: Any) -> None:
    if raw_message_size(raw) > WS_MAX_MESSAGE_BYTES:
        raise PayloadTooLarge("message_too_large")
    if not websocket_message_allowed(peer):
        raise RateLimitExceeded("rate_limited")


def voice_message_wants_floor(message: dict[str, Any]) -> bool:
    status = voice_status_from_message(message)
    return (
        bool_value(status.get("ptt"))
        or bool_value(status.get("vad"))
        or bool_value(message.get("ptt"))
        or bool_value(message.get("vad"))
        or bool(message.get("audio_b64"))
    )


def voice_message_releases_floor(message: dict[str, Any]) -> bool:
    status = voice_status_from_message(message)
    return not (
        bool_value(status.get("ptt"))
        or bool_value(status.get("vad"))
        or bool_value(message.get("ptt"))
        or bool_value(message.get("vad"))
        or bool(message.get("audio_b64"))
    )


async def handle_voice_message(peer: Peer, room: Room, message: dict[str, Any]) -> None:
    now = time.time()
    room.expire_voice_floor()
    wants_floor = voice_message_wants_floor(message)
    releases_floor = voice_message_releases_floor(message)

    if wants_floor:
        if room.speaker_group_id and room.speaker_group_id != peer.group_id:
            if store is not None:
                store.audit_event(
                    "voice_busy",
                    room_code=room.code,
                    actor_id=peer.peer_id,
                    actor_role=peer.role,
                    group_id=peer.group_id,
                    detail={"speaker_group_id": room.speaker_group_id, "speaker_peer_id": room.speaker_peer_id},
                )
            notify_user(
                peer.user_id,
                "voice_busy",
                room.code,
                "Dragon Radar 抢麦失败",
                "当前房间已有成员正在说话",
                {
                    "speaker_group_id": room.speaker_group_id,
                    "speaker_peer_id": room.speaker_peer_id,
                    "requester_group_id": peer.group_id,
                },
            )
            await send_json(
                peer,
                {
                    "type": "voice_busy",
                    "room": room.code,
                    "speaker_group_id": room.speaker_group_id,
                    "speaker_peer_id": room.speaker_peer_id,
                    "server_time": int(now),
                },
            )
            await broadcast_room_state(room)
            return
        room.speaker_group_id = peer.group_id
        room.speaker_peer_id = peer.peer_id
        room.speaker_until = now + VOICE_FLOOR_TTL_SECONDS
    elif releases_floor and room.speaker_group_id == peer.group_id:
        room.speaker_group_id = ""
        room.speaker_peer_id = ""
        room.speaker_until = 0.0

    normalized = normalize_last_payload(message)
    normalized = merge_last_payload(peer.last_payload, normalized)
    voice_status = normalized.get("voice_status")
    if isinstance(voice_status, dict):
        voice_status = dict(voice_status)
        voice_status["floor_granted"] = wants_floor and room.speaker_group_id == peer.group_id
        voice_status["speaker"] = wants_floor and room.speaker_group_id == peer.group_id
        normalized["voice_status"] = voice_status
    peer.last_payload = normalized

    event = {
        "type": "relay_event",
        "room": room.code,
        "from": peer.peer_id,
        "role": peer.role,
        "event": message.get("type"),
        "payload": message,
        "server_time": int(now),
    }
    await broadcast_room(room, event, exclude=peer.member_id)
    await broadcast_room_state(room)


async def handle_message(peer: Peer, room: Room, raw: str | bytes) -> None:
    if isinstance(raw, bytes):
        await send_json(peer, {"type": "error", "code": "binary_not_supported"})
        return

    try:
        message = json.loads(raw)
    except json.JSONDecodeError:
        await send_json(peer, {"type": "error", "code": "invalid_json"})
        return

    message_type = message.get("type")
    peer.last_seen_at = time.time()
    if message_type == "hello":
        compatible, client_protocol, required_protocol = protocol_compatible(peer, message)
        if not compatible:
            if store is not None:
                store.audit_event(
                    "protocol_unsupported",
                    room_code=peer.room,
                    actor_id=peer.peer_id,
                    actor_role=peer.role,
                    group_id=peer.group_id,
                    detail={
                        "client_protocol": client_protocol,
                        "required_protocol": required_protocol,
                        "relay_protocol": RELAY_PROTOCOL_VERSION,
                    },
                )
            await send_json(
                peer,
                {
                    "type": "error",
                    "code": "protocol_unsupported",
                    "role": peer.role,
                    "client_protocol": client_protocol,
                    "required_protocol": required_protocol,
                    "relay_protocol": RELAY_PROTOCOL_VERSION,
                    "protocol": relay_protocol_payload(),
                },
            )
            await peer.socket.close(code=1008)
            return

    if store is not None and message_type in {"hello", "heartbeat", "device_status", "app_location", "location_paused"}:
        display_name = display_name_from_payload(message, member_name(peer))
        store.upsert_member(peer.room, peer.group_id, peer.user_id or peer.group_id, display_name, role="member")

    if message_type == "ping":
        peer.last_payload = merge_last_payload(peer.last_payload, message)
        await send_json(peer, {"type": "pong", "server_time": int(time.time())})
        return

    if message_type == "room_switch":
        peer.last_payload = merge_last_payload(peer.last_payload, message)
        event = room_switch_event(peer, message)
        delivered = 0
        if peer.group_id:
            pending_room_switches[peer.group_id] = event
            delivered = await deliver_room_switch_to_group(peer.group_id, event)
        if store is not None:
            store.audit_event(
                "room_switch",
                room_code=room.code,
                actor_id=peer.peer_id,
                actor_role=peer.role,
                group_id=peer.group_id,
                detail={
                    "request_id": message.get("request_id"),
                    "target_room": message.get("room_token"),
                    "delivered_devices": delivered,
                },
            )
        await send_json(
            peer,
            {
                "type": "room_switch_ack",
                "request_id": message.get("request_id"),
                "room": room.code,
                "target_group_id": peer.group_id,
                "delivered_devices": delivered,
                "server_time": int(time.time()),
            },
        )
        await broadcast_room(room, event, exclude=peer.member_id)
        await broadcast_room_state(room)
        return

    if message_type in {"voice_frame", "audio_frame", "voice_state", "mute_update"}:
        await handle_voice_message(peer, room, message)
        return

    if message_type in {
        "hello",
        "heartbeat",
        "device_status",
        "app_location",
        "location_paused",
    }:
        if message_type == "app_location" and (message.get("location") or "lat" in message or "lat_e7" in message):
            peer.last_location_at = time.time()
        peer.last_payload = merge_last_payload(peer.last_payload, message)
        if message_type == "app_location":
            await send_json(
                peer,
                {
                    "type": "app_location_ack",
                    "room": room.code,
                    "sequence": message.get("sequence"),
                    "server_time": int(time.time()),
                },
            )
        if message_type == "location_paused":
            if store is not None:
                store.audit_event(
                    "location_paused",
                    room_code=room.code,
                    actor_id=peer.peer_id,
                    actor_role=peer.role,
                    group_id=peer.group_id,
                )
            await send_json(
                peer,
                {
                    "type": "location_paused_ack",
                    "room": room.code,
                    "server_time": int(time.time()),
                },
            )
        event = {
            "type": "relay_event",
            "room": room.code,
            "from": peer.peer_id,
            "role": peer.role,
            "event": message_type,
            "payload": message,
            "server_time": int(time.time()),
        }
        await broadcast_room(room, event, exclude=peer.member_id)
        await broadcast_room_state(room)
        return

    await send_json(peer, {"type": "error", "code": "unsupported_type", "message_type": message_type})


async def handler(socket: WebSocketServerProtocol, path: str) -> None:
    try:
        peer = make_peer(socket, path)
    except ValueError as exc:
        await socket.send(json_message({"type": "error", "code": "unsupported_path", "detail": str(exc)}))
        await socket.close(code=1008)
        return
    except PermissionError as exc:
        await socket.send(json_message({"type": "error", "code": str(exc)}))
        await socket.close(code=1008)
        return

    if store is not None:
        store.ensure_room(peer.room)
        store.upsert_member(peer.room, peer.group_id, peer.user_id or peer.group_id, peer.group_id, role="member")

    room = rooms.setdefault(peer.room, Room(code=peer.room))
    existing_groups = {p.group_id for p in room.peers.values()}
    if peer.group_id not in existing_groups and len(existing_groups) >= MAX_ROOM_MEMBERS:
        if store is not None:
            store.audit_event(
                "room_full",
                room_code=peer.room,
                actor_id=peer.peer_id,
                actor_role=peer.role,
                group_id=peer.group_id,
                detail={"max_members": MAX_ROOM_MEMBERS},
            )
        await socket.send(json_message({"type": "error", "code": "room_full", "max_members": MAX_ROOM_MEMBERS}))
        await socket.close(code=1008)
        return

    room.peers[peer.member_id] = peer
    print(f"join role={peer.role} room={peer.room} group={peer.group_id} peer={peer.peer_id}", flush=True)
    if store is not None:
        store.audit_event(
            "ws_join",
            room_code=peer.room,
            actor_id=peer.peer_id,
            actor_role=peer.role,
            group_id=peer.group_id,
        )
    await send_json(
        peer,
        {
            "type": "hello_ack",
            "role": peer.role,
            "room": peer.room,
            "peer_id": peer.peer_id,
            "server_time": int(time.time()),
            "relay_protocol_version": RELAY_PROTOCOL_VERSION,
            "min_app_protocol_version": MIN_APP_PROTOCOL_VERSION,
            "min_device_protocol_version": MIN_DEVICE_PROTOCOL_VERSION,
            "protocol": relay_protocol_payload(),
        },
    )
    await broadcast_room_state(room)
    if peer.role == "device" and peer.group_id in pending_room_switches:
        await safe_send_json(peer, pending_room_switches[peer.group_id])

    try:
        while True:
            try:
                raw = await asyncio.wait_for(socket.recv(), timeout=WS_IDLE_TIMEOUT_SECONDS)
                validate_websocket_raw(peer, raw)
            except asyncio.TimeoutError:
                if store is not None:
                    store.audit_event(
                        "ws_idle_timeout",
                        room_code=peer.room,
                        actor_id=peer.peer_id,
                        actor_role=peer.role,
                        group_id=peer.group_id,
                        detail={"timeout_seconds": WS_IDLE_TIMEOUT_SECONDS},
                    )
                await safe_send_json(peer, {"type": "error", "code": "heartbeat_timeout", "timeout_seconds": WS_IDLE_TIMEOUT_SECONDS})
                await socket.close(code=1001)
                break
            except PayloadTooLarge as exc:
                if store is not None:
                    store.audit_event(
                        "ws_message_too_large",
                        room_code=peer.room,
                        actor_id=peer.peer_id,
                        actor_role=peer.role,
                        group_id=peer.group_id,
                        detail={"max_message_bytes": WS_MAX_MESSAGE_BYTES},
                    )
                await safe_send_json(peer, {"type": "error", "code": str(exc), "max_message_bytes": WS_MAX_MESSAGE_BYTES})
                await socket.close(code=1009)
                break
            except RateLimitExceeded as exc:
                if store is not None:
                    store.audit_event(
                        "ws_rate_limited",
                        room_code=peer.room,
                        actor_id=peer.peer_id,
                        actor_role=peer.role,
                        group_id=peer.group_id,
                        detail={"limit_per_second": WS_MESSAGE_RATE_LIMIT_PER_SECOND},
                    )
                await safe_send_json(peer, {"type": "error", "code": str(exc), "limit_per_second": WS_MESSAGE_RATE_LIMIT_PER_SECOND})
                await socket.close(code=1008)
                break
            await handle_message(peer, room, raw)
    except websockets.ConnectionClosed:
        pass
    finally:
        if room.speaker_group_id == peer.group_id:
            room.speaker_group_id = ""
            room.speaker_peer_id = ""
            room.speaker_until = 0.0
        current = room.peers.get(peer.member_id)
        if current is peer:
            del room.peers[peer.member_id]
        device_still_online = any(
            candidate.role == "device" and candidate.group_id == peer.group_id
            for candidate in room.peers.values()
        )
        if peer.role == "device" and not device_still_online:
            notify_user(
                peer.user_id,
                "device_offline",
                peer.room,
                "Dragon Radar 设备离线",
                "ESP 已从当前房间断开",
                {"device_id": peer.device_id, "group_id": peer.group_id},
            )
        if not room.peers:
            rooms.pop(room.code, None)
        else:
            await broadcast_room_state(room)
        print(f"leave role={peer.role} room={peer.room} group={peer.group_id} peer={peer.peer_id}", flush=True)
        if store is not None:
            store.audit_event(
                "ws_leave",
                room_code=peer.room,
                actor_id=peer.peer_id,
                actor_role=peer.role,
                group_id=peer.group_id,
            )


async def main_async(args: argparse.Namespace) -> None:
    global store
    store = RelayStore(args.db_path)
    httpd = start_http_server(args.host, args.http_port)
    stop = asyncio.Future()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set_result, None)

    try:
        async with websockets.serve(
            handler,
            args.host,
            args.port,
            ping_interval=WS_PING_INTERVAL_SECONDS,
            ping_timeout=WS_PING_TIMEOUT_SECONDS,
            max_size=WS_MAX_MESSAGE_BYTES,
            close_timeout=5,
        ):
            print(f"Dragon Radar Relay listening on ws://{args.host}:{args.port}", flush=True)
            await stop
    finally:
        httpd.shutdown()


def main() -> int:
    args = parse_args()
    asyncio.run(main_async(args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
