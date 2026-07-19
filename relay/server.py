#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
import hashlib
import hmac
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import signal
import secrets
import sqlite3
import string
import subprocess
import tempfile
import threading
import time
import unicodedata
from dataclasses import dataclass, field
from typing import Any
from urllib import error as urlerror
from urllib import request as urlrequest
from urllib.parse import parse_qs, quote, urlencode, urlparse

from cryptography.fernet import Fernet, InvalidToken
import websockets
from websockets.server import WebSocketServerProtocol


MAX_ROOM_MEMBERS = 7
VOICE_FLOOR_TTL_SECONDS = 1.2
WS_AUTH_TICKET_TTL_SECONDS = 30
APP_PATH = "/v1/radar/app/ws"
DEVICE_PATH = "/v1/radar/device/ws"
ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
APPLE_ISSUER = "https://appleid.apple.com"
APPLE_JWKS_URL = "https://appleid.apple.com/auth/keys"
APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token"
APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke"
DEFAULT_APPLE_AUDIENCE = "com.sn5.DragonRadarMVP"
SHA256_DIGEST_INFO_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")
DEFAULT_PAIRING_HMAC_KEY = "dragon-radar-dev-pairing-key"
DEFAULT_MODERATION_HMAC_KEY = "dragon-radar-dev-moderation-key"
OTA_CANONICAL_FIELDS = (
    "schema",
    "product",
    "hardware",
    "version",
    "build",
    "minimum_version",
    "security_counter",
    "size",
    "sha256",
)
OTA_PRODUCT = "dragon-radar"
OTA_HARDWARE = "esp32-s3-touch-amoled-1.75c"
OTA_KEY_ID = os.environ.get("DRAGON_RADAR_OTA_KEY_ID", "local-2026-01")
OTA_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$")
OTA_SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
OTA_SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
OTA_SHA256 = re.compile(r"^[0-9a-f]{64}$")
OTA_VERSION_COMPONENT_MAX = 0xFFFFFFFF
OTA_RETAINED_RELEASES_DIR = "retained"


class FirmwareReleaseUnavailable(Exception):
    pass


@dataclass(frozen=True)
class FirmwareRelease:
    manifest: dict[str, Any]
    build_metadata: dict[str, Any]
    artifact_path: Path
    artifact_name: str
    fingerprint: tuple[int, ...]


def firmware_release_root() -> Path:
    configured = os.environ.get("DRAGON_RADAR_FIRMWARE_RELEASE_DIR", "output/ota-current")
    return Path(configured).expanduser().resolve()


def firmware_public_key_path() -> Path:
    configured = os.environ.get("DRAGON_RADAR_OTA_PUBLIC_KEY", ".secrets/ota-signing-public.pem")
    return Path(configured).expanduser().resolve()


def ota_development_releases_allowed() -> bool:
    return os.environ.get("DRAGON_RADAR_ALLOW_DEVELOPMENT_OTA", "").strip().lower() in {
        "1",
        "true",
        "yes",
    }


def ota_canonical_payload(manifest: dict[str, Any]) -> bytes:
    values: dict[str, str] = {}
    for field_name in OTA_CANONICAL_FIELDS:
        if field_name not in manifest:
            raise FirmwareReleaseUnavailable(f"manifest_missing_{field_name}")
        value = manifest[field_name]
        if field_name in {"schema", "build", "size", "security_counter"}:
            if isinstance(value, bool) or not isinstance(value, int):
                raise FirmwareReleaseUnavailable(f"manifest_invalid_{field_name}")
            values[field_name] = str(value)
        elif isinstance(value, str):
            if "\n" in value or "\r" in value or "=" in value:
                raise FirmwareReleaseUnavailable(f"manifest_invalid_{field_name}")
            values[field_name] = value
        else:
            raise FirmwareReleaseUnavailable(f"manifest_invalid_{field_name}")
    lines = ["dragon-radar-ota-v1"]
    lines.extend(f"{name}={values[name]}" for name in OTA_CANONICAL_FIELDS)
    return "\n".join(lines).encode("utf-8")


def ota_numeric_version_valid(value: object) -> bool:
    return (
        isinstance(value, str)
        and OTA_SEMVER.fullmatch(value) is not None
        and all(int(component) <= OTA_VERSION_COMPONENT_MAX for component in value.split("."))
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class FirmwareReleaseStore:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.cached: FirmwareRelease | None = None
        self.retained_cache: dict[str, FirmwareRelease] = {}

    def current(self) -> FirmwareRelease:
        root = firmware_release_root()
        return self._load(root, cache_key=None)

    def artifact(self, artifact_name: str) -> FirmwareRelease | None:
        if not OTA_SAFE_NAME.fullmatch(artifact_name):
            return None
        current = self.current()
        if artifact_name == current.artifact_name:
            return current

        root = firmware_release_root()
        retained_root = root / OTA_RETAINED_RELEASES_DIR
        candidate = retained_root / artifact_name
        try:
            resolved_retained_root = retained_root.resolve(strict=True)
            resolved_candidate = candidate.resolve(strict=True)
        except OSError:
            return None
        if (
            retained_root.is_symlink()
            or candidate.is_symlink()
            or not resolved_candidate.is_dir()
            or resolved_candidate.parent != resolved_retained_root
            or resolved_candidate.name != artifact_name
        ):
            return None
        release = self._load(resolved_candidate, cache_key=artifact_name)
        if release.artifact_name != artifact_name:
            raise FirmwareReleaseUnavailable("retained_artifact_name_mismatch")
        return release

    def _load(self, root: Path, cache_key: str | None) -> FirmwareRelease:
        manifest_path = root / "manifest.json"
        build_metadata_path = root / "build-metadata.json"
        public_key = firmware_public_key_path()
        try:
            if (
                manifest_path.is_symlink()
                or build_metadata_path.is_symlink()
                or not manifest_path.is_file()
                or not build_metadata_path.is_file()
            ):
                raise OSError("unsafe release metadata path")
            manifest_stat = manifest_path.stat()
            build_metadata_stat = build_metadata_path.stat()
            public_key_stat = public_key.stat()
            raw_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            raw_build_metadata = json.loads(build_metadata_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise FirmwareReleaseUnavailable("firmware_release_not_configured") from exc
        if not isinstance(raw_manifest, dict):
            raise FirmwareReleaseUnavailable("manifest_object_required")
        if not isinstance(raw_build_metadata, dict):
            raise FirmwareReleaseUnavailable("build_metadata_object_required")

        artifact_name = raw_manifest.get("artifact")
        if not isinstance(artifact_name, str) or not OTA_SAFE_NAME.fullmatch(artifact_name):
            raise FirmwareReleaseUnavailable("manifest_invalid_artifact")
        artifact_candidate = root / artifact_name
        if artifact_candidate.is_symlink():
            raise FirmwareReleaseUnavailable("manifest_invalid_artifact")
        artifact_path = artifact_candidate.resolve()
        if artifact_path.parent != root or artifact_path.name != artifact_name:
            raise FirmwareReleaseUnavailable("manifest_invalid_artifact")
        try:
            artifact_stat = artifact_path.stat()
        except OSError as exc:
            raise FirmwareReleaseUnavailable("firmware_artifact_missing") from exc
        if not artifact_path.is_file():
            raise FirmwareReleaseUnavailable("firmware_artifact_missing")

        fingerprint = (
            manifest_stat.st_ino,
            manifest_stat.st_mtime_ns,
            manifest_stat.st_size,
            build_metadata_stat.st_ino,
            build_metadata_stat.st_mtime_ns,
            build_metadata_stat.st_size,
            artifact_stat.st_ino,
            artifact_stat.st_mtime_ns,
            artifact_stat.st_size,
            public_key_stat.st_ino,
            public_key_stat.st_mtime_ns,
            public_key_stat.st_size,
        )
        with self.lock:
            cached = self.cached if cache_key is None else self.retained_cache.get(cache_key)
            if cached is not None and cached.fingerprint == fingerprint:
                return cached
            release = self._validate(
                raw_manifest,
                raw_build_metadata,
                artifact_path,
                public_key,
                fingerprint,
            )
            if cache_key is None:
                self.cached = release
            else:
                self.retained_cache[cache_key] = release
            return release

    def _validate(
        self,
        manifest: dict[str, Any],
        build_metadata: dict[str, Any],
        artifact_path: Path,
        public_key: Path,
        fingerprint: tuple[int, ...],
    ) -> FirmwareRelease:
        canonical = ota_canonical_payload(manifest)
        if manifest.get("schema") != 1:
            raise FirmwareReleaseUnavailable("manifest_schema_unsupported")
        if (
            not OTA_SAFE_IDENTIFIER.fullmatch(str(manifest.get("product") or ""))
            or manifest.get("product") != OTA_PRODUCT
        ):
            raise FirmwareReleaseUnavailable("manifest_invalid_product")
        if (
            not OTA_SAFE_IDENTIFIER.fullmatch(str(manifest.get("hardware") or ""))
            or manifest.get("hardware") != OTA_HARDWARE
        ):
            raise FirmwareReleaseUnavailable("manifest_invalid_hardware")
        if not ota_numeric_version_valid(manifest.get("version")):
            raise FirmwareReleaseUnavailable("manifest_invalid_version")
        if not ota_numeric_version_valid(manifest.get("minimum_version")):
            raise FirmwareReleaseUnavailable("manifest_invalid_minimum_version")
        build = manifest.get("build", 0)
        security_counter = manifest.get("security_counter", 0)
        if (
            not 1 <= build <= OTA_VERSION_COMPONENT_MAX
            or not 1 <= security_counter <= OTA_VERSION_COMPONENT_MAX
        ):
            raise FirmwareReleaseUnavailable("manifest_invalid_counter")
        version_tuple = tuple(int(component) for component in manifest["version"].split("."))
        minimum_tuple = tuple(int(component) for component in manifest["minimum_version"].split("."))
        if version_tuple < minimum_tuple:
            raise FirmwareReleaseUnavailable("manifest_invalid_version_range")
        if manifest.get("size", 0) <= 0 or manifest.get("size") != artifact_path.stat().st_size:
            raise FirmwareReleaseUnavailable("manifest_size_mismatch")
        expected_sha256 = str(manifest.get("sha256") or "").lower()
        if not OTA_SHA256.fullmatch(expected_sha256) or sha256_file(artifact_path) != expected_sha256:
            raise FirmwareReleaseUnavailable("manifest_sha256_mismatch")
        if artifact_path.name != f"{expected_sha256}.bin":
            raise FirmwareReleaseUnavailable("manifest_artifact_not_content_addressed")
        if manifest.get("signature_algorithm") != "ecdsa-p256-sha256":
            raise FirmwareReleaseUnavailable("manifest_signature_algorithm_unsupported")
        if manifest.get("signed_payload") != canonical.decode("utf-8"):
            raise FirmwareReleaseUnavailable("manifest_canonical_payload_mismatch")

        signature_text = manifest.get("signature")
        if not isinstance(signature_text, str):
            raise FirmwareReleaseUnavailable("manifest_signature_missing")
        try:
            signature = base64.b64decode(signature_text, validate=True)
        except (ValueError, binascii.Error) as exc:
            raise FirmwareReleaseUnavailable("manifest_signature_invalid") from exc
        if not signature:
            raise FirmwareReleaseUnavailable("manifest_signature_invalid")

        try:
            key_info = subprocess.run(
                ["openssl", "pkey", "-pubin", "-in", str(public_key), "-text_pub", "-noout"],
                capture_output=True,
                check=False,
            )
        except OSError as exc:
            raise FirmwareReleaseUnavailable("ota_signature_verifier_unavailable") from exc
        if key_info.returncode != 0 or (
            b"prime256v1" not in key_info.stdout and b"NIST CURVE: P-256" not in key_info.stdout
        ):
            raise FirmwareReleaseUnavailable("ota_public_key_must_be_p256")
        if manifest.get("key_id") != OTA_KEY_ID:
            raise FirmwareReleaseUnavailable("manifest_key_id_mismatch")
        try:
            normalized_key = subprocess.run(
                [
                    "openssl",
                    "pkey",
                    "-pubin",
                    "-in",
                    str(public_key),
                    "-pubout",
                    "-outform",
                    "DER",
                ],
                capture_output=True,
                check=False,
            )
        except OSError as exc:
            raise FirmwareReleaseUnavailable("ota_signature_verifier_unavailable") from exc
        if normalized_key.returncode != 0 or not normalized_key.stdout:
            raise FirmwareReleaseUnavailable("ota_public_key_invalid")
        self._validate_build_metadata(
            manifest,
            build_metadata,
            hashlib.sha256(normalized_key.stdout).hexdigest(),
        )

        signature_path = ""
        try:
            with tempfile.NamedTemporaryFile(prefix="dragon-radar-ota-", suffix=".sig", delete=False) as handle:
                handle.write(signature)
                signature_path = handle.name
            verified = subprocess.run(
                [
                    "openssl",
                    "dgst",
                    "-sha256",
                    "-verify",
                    str(public_key),
                    "-signature",
                    signature_path,
                ],
                input=canonical,
                capture_output=True,
                check=False,
            )
        except OSError as exc:
            raise FirmwareReleaseUnavailable("ota_signature_verifier_unavailable") from exc
        finally:
            if signature_path:
                try:
                    os.unlink(signature_path)
                except OSError:
                    pass
        if verified.returncode != 0:
            raise FirmwareReleaseUnavailable("manifest_signature_invalid")

        return FirmwareRelease(
            manifest=dict(manifest),
            build_metadata=dict(build_metadata),
            artifact_path=artifact_path,
            artifact_name=artifact_path.name,
            fingerprint=fingerprint,
        )

    @staticmethod
    def _validate_build_metadata(
        manifest: dict[str, Any],
        metadata: dict[str, Any],
        public_key_sha256: str,
    ) -> None:
        expected: dict[str, Any] = {
            "schema": 1,
            "product": manifest["product"],
            "hardware": manifest["hardware"],
            "version": manifest["version"],
            "build": manifest["build"],
            "security_counter": manifest["security_counter"],
            "artifact": "firmware.bin",
            "size": manifest["size"],
            "sha256": manifest["sha256"],
            "ota_key_id": OTA_KEY_ID,
            "ota_public_key_sha256": public_key_sha256,
        }
        for field_name, expected_value in expected.items():
            actual = metadata.get(field_name)
            if isinstance(expected_value, int) and isinstance(actual, bool):
                actual = None
            if actual != expected_value:
                raise FirmwareReleaseUnavailable(f"build_metadata_mismatch_{field_name}")

        release_build = metadata.get("release_build")
        ota_allow_http = metadata.get("ota_allow_http")
        root_ca_configured = metadata.get("ota_root_ca_configured")
        root_ca_sha256 = metadata.get("ota_root_ca_sha256")
        environment = metadata.get("environment")
        if not all(isinstance(value, bool) for value in (release_build, ota_allow_http, root_ca_configured)):
            raise FirmwareReleaseUnavailable("build_metadata_invalid_policy")
        if not isinstance(root_ca_sha256, str) or not isinstance(environment, str):
            raise FirmwareReleaseUnavailable("build_metadata_invalid_policy")
        stable = (
            release_build is True
            and ota_allow_http is False
            and root_ca_configured is True
            and OTA_SHA256.fullmatch(root_ca_sha256) is not None
            and environment == "field"
        )
        development = (
            release_build is False
            and ota_allow_http is True
            and (
                (root_ca_configured is False and root_ca_sha256 == "")
                or (root_ca_configured is True and OTA_SHA256.fullmatch(root_ca_sha256) is not None)
            )
        )
        if not stable and not (development and ota_development_releases_allowed()):
            raise FirmwareReleaseUnavailable("firmware_release_policy_rejected")

    def health_payload(self) -> dict[str, Any]:
        try:
            release = self.current()
        except FirmwareReleaseUnavailable:
            return {"available": False}
        return {
            "available": True,
            "product": release.manifest["product"],
            "hardware": release.manifest["hardware"],
            "version": release.manifest["version"],
            "build": release.manifest["build"],
            "security_counter": release.manifest["security_counter"],
            "development": release.build_metadata.get("release_build") is False,
        }


firmware_releases = FirmwareReleaseStore()


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
# A 16 kHz/20 ms PCM voice stream produces 50 messages per second. Keep
# enough headroom for status and heartbeat frames without disabling the guard.
WS_MESSAGE_RATE_LIMIT_PER_SECOND = env_int("DRAGON_RADAR_WS_MESSAGE_RATE_LIMIT_PER_SECOND", 80, 0)
WS_IDLE_TIMEOUT_SECONDS = env_int("DRAGON_RADAR_WS_IDLE_TIMEOUT_SECONDS", 90, 10)
WS_PING_INTERVAL_SECONDS = env_int("DRAGON_RADAR_WS_PING_INTERVAL_SECONDS", 20, 5)
WS_PING_TIMEOUT_SECONDS = env_int("DRAGON_RADAR_WS_PING_TIMEOUT_SECONDS", 20, 5)
LOCATION_STALE_AFTER_SECONDS = env_int("DRAGON_RADAR_LOCATION_STALE_SECONDS", 30, 1)
RELAY_PROTOCOL_VERSION = env_int("DRAGON_RADAR_RELAY_PROTOCOL_VERSION", 2, 1)
MIN_APP_PROTOCOL_VERSION = env_int("DRAGON_RADAR_MIN_APP_PROTOCOL_VERSION", 2, 1)
MIN_DEVICE_PROTOCOL_VERSION = env_int("DRAGON_RADAR_MIN_DEVICE_PROTOCOL_VERSION", 2, 1)
LOCATION_FRAME_PROTOCOL_VERSION = 1
VOICE_PROTOCOL_VERSION = 1
RADAR_REMINDER_COOLDOWN_SECONDS = env_int("DRAGON_RADAR_REMINDER_COOLDOWN_SECONDS", 30, 1)
RADAR_REMINDER_WINDOW_SECONDS = env_int("DRAGON_RADAR_REMINDER_WINDOW_SECONDS", 10 * 60, 1)
RADAR_REMINDER_WINDOW_LIMIT = env_int("DRAGON_RADAR_REMINDER_WINDOW_LIMIT", 5, 1)
RADAR_REMINDER_REQUEST_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{7,95}$")
MODERATION_REF_PATTERN = re.compile(r"^mod_v1_[A-Za-z0-9_-]{43}$")
BLOCK_ID_PATTERN = re.compile(r"^blk_[A-Za-z0-9_-]{12,64}$")
CONTENT_REPORT_DETAIL_MAX_CHARS = env_int("DRAGON_RADAR_REPORT_DETAIL_MAX_CHARS", 1000, 0)
CONTENT_REPORT_WINDOW_SECONDS = env_int("DRAGON_RADAR_REPORT_WINDOW_SECONDS", 60 * 60, 60)
CONTENT_REPORT_WINDOW_LIMIT = env_int("DRAGON_RADAR_REPORT_WINDOW_LIMIT", 5, 1)
DIAGNOSTICS_RETENTION_DAYS = env_int("DRAGON_RADAR_DIAGNOSTICS_RETENTION_DAYS", 30, 1)
AUDIT_RETENTION_DAYS = env_int("DRAGON_RADAR_AUDIT_RETENTION_DAYS", 90, 1)
RADAR_REMINDER_RETENTION_DAYS = env_int("DRAGON_RADAR_REMINDER_RETENTION_DAYS", 90, 1)
CONTENT_REPORT_RETENTION_DAYS = env_int("DRAGON_RADAR_CONTENT_REPORT_RETENTION_DAYS", 365, 1)
RETENTION_CLEANUP_INTERVAL_SECONDS = env_int(
    "DRAGON_RADAR_RETENTION_CLEANUP_INTERVAL_SECONDS",
    60 * 60,
    60,
)
CONTENT_REPORT_TYPES = frozenset({"profile_name", "room_name", "voice", "behavior", "other"})
CONTENT_REPORT_CATEGORIES = frozenset(
    {
        "harassment",
        "hate_speech",
        "sexual_content",
        "violence",
        "spam",
        "impersonation",
        "privacy",
        "other",
    }
)
DEFAULT_BLOCKED_TERMS = (
    "支那",
    "黑鬼",
    "杀了你",
    "nigger",
    "kill yourself",
)


class RateLimitExceeded(Exception):
    pass


class PayloadTooLarge(Exception):
    pass


class RadarReminderRateLimited(Exception):
    def __init__(self, retry_after: int) -> None:
        super().__init__("radar_reminder_rate_limited")
        self.retry_after = max(1, int(retry_after))


class ContentReportRateLimited(Exception):
    def __init__(self, retry_after: int) -> None:
        super().__init__("content_report_rate_limited")
        self.retry_after = max(1, int(retry_after))


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

    def verify(
        self,
        identity_token: str,
        requested_apple_user_id: str = "",
        requested_nonce: str = "",
    ) -> VerifiedAppleIdentity:
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
        expected_nonce = hashlib.sha256(requested_nonce.encode("utf-8")).hexdigest()
        token_nonce = str(payload.get("nonce") or "")
        if not requested_nonce or not secrets.compare_digest(token_nonce, expected_nonce):
            raise PermissionError("invalid_apple_identity_nonce")
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


class AppleOAuthService:
    """Exchanges the one-time Apple authorization code and revokes access on deletion."""

    @property
    def team_id(self) -> str:
        return os.environ.get("DRAGON_RADAR_APPLE_TEAM_ID", "").strip()

    @property
    def key_id(self) -> str:
        return os.environ.get("DRAGON_RADAR_APPLE_SIGNIN_KEY_ID", "").strip()

    @property
    def key_path(self) -> str:
        return os.environ.get("DRAGON_RADAR_APPLE_SIGNIN_KEY_PATH", "").strip()

    @property
    def client_id(self) -> str:
        return (
            os.environ.get("DRAGON_RADAR_APPLE_CLIENT_ID")
            or os.environ.get("DRAGON_RADAR_APPLE_AUDIENCE")
            or DEFAULT_APPLE_AUDIENCE
        ).strip()

    def configured(self) -> bool:
        return bool(
            self.team_id
            and self.key_id
            and self.client_id
            and self.key_path
            and Path(self.key_path).is_file()
        )

    def health_payload(self) -> dict[str, Any]:
        return {
            "identity_token_validation": True,
            "authorization_code_exchange": self.configured(),
            "account_deletion_revocation": self.configured(),
            "refresh_token_encryption": secret_cipher.configured(),
            "client_id": self.client_id,
        }

    def exchange_authorization_code(self, authorization_code: str) -> str:
        code = authorization_code.strip()
        if not code or not self.configured():
            return ""
        if len(code) > 4096:
            raise PermissionError("invalid_apple_authorization_code")
        payload = self.post_form(
            APPLE_TOKEN_URL,
            {
                "client_id": self.client_id,
                "client_secret": self.client_secret(),
                "code": code,
                "grant_type": "authorization_code",
            },
        )
        refresh_token = str(payload.get("refresh_token") or "").strip()
        if not refresh_token:
            raise PermissionError("apple_authorization_code_exchange_failed")
        return refresh_token[:4096]

    def revoke_refresh_token(self, refresh_token: str) -> dict[str, str]:
        token = refresh_token.strip()
        if not token:
            return {"status": "manual_required", "reason": "refresh_token_unavailable"}
        if not self.configured():
            return {"status": "manual_required", "reason": "server_not_configured"}
        try:
            self.post_form(
                APPLE_REVOKE_URL,
                {
                    "client_id": self.client_id,
                    "client_secret": self.client_secret(),
                    "token": token,
                    "token_type_hint": "refresh_token",
                },
                expect_json=False,
            )
            return {"status": "revoked"}
        except Exception:
            # Account deletion must not be held hostage by an Apple/network outage.
            # The response tells the app to show Apple's manual revocation path.
            return {"status": "manual_required", "reason": "revocation_failed"}

    def client_secret(self) -> str:
        now = int(time.time())
        header = {"alg": "ES256", "kid": self.key_id}
        claims = {
            "iss": self.team_id,
            "iat": now,
            "exp": now + 5 * 60,
            "aud": APPLE_ISSUER,
            "sub": self.client_id,
        }
        signed_input = (
            f"{base64url_encode(json.dumps(header, separators=(',', ':')).encode('utf-8'))}."
            f"{base64url_encode(json.dumps(claims, separators=(',', ':')).encode('utf-8'))}"
        ).encode("ascii")
        completed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", self.key_path],
            input=signed_input,
            capture_output=True,
            timeout=5,
            check=False,
        )
        if completed.returncode != 0:
            raise RuntimeError("apple_client_secret_sign_failed")
        signature = base64url_encode(ecdsa_der_to_raw_rs(completed.stdout))
        return f"{signed_input.decode('ascii')}.{signature}"

    @staticmethod
    def post_form(url: str, fields: dict[str, str], expect_json: bool = True) -> dict[str, Any]:
        body = urlencode(fields).encode("utf-8")
        request = urlrequest.Request(
            url,
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            method="POST",
        )
        try:
            with urlrequest.urlopen(request, timeout=8) as response:
                response_body = response.read().decode("utf-8")
        except (urlerror.HTTPError, urlerror.URLError, TimeoutError) as exc:
            raise PermissionError("apple_oauth_request_failed") from exc
        if not expect_json:
            return {}
        try:
            parsed = json.loads(response_body)
        except json.JSONDecodeError as exc:
            raise PermissionError("apple_oauth_response_invalid") from exc
        if not isinstance(parsed, dict) or parsed.get("error"):
            raise PermissionError("apple_oauth_request_failed")
        return parsed


apple_oauth_service = AppleOAuthService()


class SecretCipher:
    def __init__(self) -> None:
        key = os.environ.get("DRAGON_RADAR_DATA_ENCRYPTION_KEY", "").strip().encode("ascii", "ignore")
        try:
            self.fernet = Fernet(key) if key else None
        except (ValueError, TypeError):
            self.fernet = None

    def configured(self) -> bool:
        return self.fernet is not None

    def encrypt(self, value: str) -> str:
        clean_value = value.strip()
        if not clean_value:
            return ""
        if self.fernet is None:
            raise RuntimeError("data_encryption_key_not_configured")
        return self.fernet.encrypt(clean_value.encode("utf-8")).decode("ascii")

    def decrypt(self, value: str) -> str:
        encrypted = value.strip()
        if not encrypted:
            return ""
        if not encrypted.startswith("gAAAA"):
            # One-time compatibility path for a pre-encryption local database.
            return encrypted
        if self.fernet is None:
            return ""
        try:
            return self.fernet.decrypt(encrypted.encode("ascii")).decode("utf-8")
        except (InvalidToken, UnicodeDecodeError):
            return ""


secret_cipher = SecretCipher()


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
        self.last_retention_cleanup_at = 0
        self.last_retention_cleanup_counts: dict[str, int] = {}
        self.setup()
        self.prune_retained_data(force=True)

    def setup(self) -> None:
        with self.lock, self.db:
            self.db.executescript(
                """
                PRAGMA journal_mode = WAL;
                CREATE TABLE IF NOT EXISTS users (
                    user_id TEXT PRIMARY KEY,
                    apple_user_id TEXT UNIQUE,
                    apple_refresh_token TEXT NOT NULL DEFAULT '',
                    display_name TEXT NOT NULL DEFAULT '',
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS auth_tokens (
                    access_token TEXT PRIMARY KEY,
                    refresh_token TEXT NOT NULL UNIQUE,
                    user_id TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    refresh_expires_at INTEGER NOT NULL,
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
                CREATE TABLE IF NOT EXISTS radar_reminders (
                    event_id TEXT PRIMARY KEY,
                    request_id TEXT NOT NULL,
                    room_code TEXT NOT NULL,
                    sender_user_id TEXT NOT NULL,
                    recipient_count INTEGER NOT NULL DEFAULT 0,
                    online_delivered INTEGER NOT NULL DEFAULT 0,
                    push_status TEXT NOT NULL DEFAULT 'pending',
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (room_code, sender_user_id, request_id)
                );
                CREATE TABLE IF NOT EXISTS content_reports (
                    report_id TEXT PRIMARY KEY,
                    case_number TEXT NOT NULL UNIQUE,
                    reporter_user_id TEXT NOT NULL,
                    reported_user_id TEXT NOT NULL,
                    room_code TEXT NOT NULL,
                    content_type TEXT NOT NULL,
                    category TEXT NOT NULL,
                    details TEXT NOT NULL DEFAULT '',
                    status TEXT NOT NULL DEFAULT 'received',
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS user_blocks (
                    block_id TEXT PRIMARY KEY,
                    blocker_user_id TEXT NOT NULL,
                    blocked_user_id TEXT NOT NULL,
                    room_code TEXT NOT NULL,
                    moderation_ref TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    UNIQUE (blocker_user_id, blocked_user_id)
                );
                CREATE INDEX IF NOT EXISTS radar_reminders_sender_room_created_idx
                ON radar_reminders (sender_user_id, room_code, created_at DESC);
                CREATE INDEX IF NOT EXISTS content_reports_reporter_created_idx
                ON content_reports (reporter_user_id, created_at DESC);
                CREATE INDEX IF NOT EXISTS content_reports_room_created_idx
                ON content_reports (room_code, created_at DESC);
                CREATE INDEX IF NOT EXISTS user_blocks_blocker_created_idx
                ON user_blocks (blocker_user_id, created_at DESC);
                CREATE INDEX IF NOT EXISTS user_blocks_blocked_idx
                ON user_blocks (blocked_user_id);
                """
            )
            try:
                self.db.execute("ALTER TABLE users ADD COLUMN apple_user_id TEXT UNIQUE")
            except sqlite3.OperationalError:
                try:
                    self.db.execute("ALTER TABLE users ADD COLUMN apple_user_id TEXT")
                except sqlite3.OperationalError:
                    pass
            try:
                self.db.execute("ALTER TABLE users ADD COLUMN apple_refresh_token TEXT NOT NULL DEFAULT ''")
            except sqlite3.OperationalError:
                pass
            try:
                self.db.execute("ALTER TABLE auth_tokens ADD COLUMN refresh_expires_at INTEGER NOT NULL DEFAULT 0")
            except sqlite3.OperationalError:
                pass
            self.db.execute(
                """
                UPDATE auth_tokens
                SET refresh_expires_at = created_at + ?
                WHERE refresh_expires_at <= 0
                """,
                (30 * 24 * 60 * 60,),
            )

    def prune_retained_data(self, force: bool = False, now: int | None = None) -> dict[str, int]:
        current = int(time.time()) if now is None else int(now)
        with self.lock:
            if (
                not force
                and self.last_retention_cleanup_at > 0
                and current - self.last_retention_cleanup_at < RETENTION_CLEANUP_INTERVAL_SECONDS
            ):
                return dict(self.last_retention_cleanup_counts)

            retention_days = {
                "diagnostics_reports": DIAGNOSTICS_RETENTION_DAYS,
                "audit_events": AUDIT_RETENTION_DAYS,
                "radar_reminders": RADAR_REMINDER_RETENTION_DAYS,
                "content_reports": CONTENT_REPORT_RETENTION_DAYS,
            }
            deleted: dict[str, int] = {}
            with self.db:
                for table, days in retention_days.items():
                    cutoff = current - days * 24 * 60 * 60
                    cursor = self.db.execute(
                        f"DELETE FROM {table} WHERE created_at < ?",
                        (cutoff,),
                    )
                    deleted[table] = max(0, int(cursor.rowcount))
                expired_tokens = self.db.execute(
                    "DELETE FROM auth_tokens WHERE refresh_expires_at < ?",
                    (current,),
                )
                deleted["auth_tokens"] = max(0, int(expired_tokens.rowcount))
                expired_invites = self.db.execute(
                    "DELETE FROM room_invites WHERE expires_at IS NOT NULL AND expires_at < ?",
                    (current,),
                )
                deleted["room_invites"] = max(0, int(expired_invites.rowcount))
            self.last_retention_cleanup_at = current
            self.last_retention_cleanup_counts = deleted
            return dict(deleted)

    def retention_health_payload(self) -> dict[str, Any]:
        return {
            "retention_days": {
                "diagnostics_reports": DIAGNOSTICS_RETENTION_DAYS,
                "audit_events": AUDIT_RETENTION_DAYS,
                "radar_reminders": RADAR_REMINDER_RETENTION_DAYS,
                "content_reports": CONTENT_REPORT_RETENTION_DAYS,
            },
            "cleanup_interval_seconds": RETENTION_CLEANUP_INTERVAL_SECONDS,
            "last_cleanup_at": self.last_retention_cleanup_at,
            "last_cleanup_deleted": dict(self.last_retention_cleanup_counts),
        }

    def register_device_challenge(
        self,
        user_id: str,
        pairing_challenge: str,
        name: str = "",
    ) -> dict[str, Any]:
        clean_challenge = " ".join(pairing_challenge.strip().split())[:160]
        if not clean_challenge or clean_challenge == "未读取":
            raise ValueError("pairing_challenge_required")
        clean_name = clean_display_name(name) or "胶囊设备"
        short_id = device_short_id_from_challenge(clean_challenge)
        with self.lock:
            existing = self.db.execute(
                """
                SELECT device_id, owner_user_id, device_short_id, name, device_token,
                       pairing_challenge, pairing_response, created_at, updated_at
                FROM devices
                WHERE pairing_challenge = ? AND revoked_at IS NULL
                ORDER BY updated_at DESC
                LIMIT 1
                """,
                (clean_challenge,),
            ).fetchone()
            hardware_id = pairing_hardware_id_from_challenge(clean_challenge)
            if existing is None and hardware_id:
                candidates = self.db.execute(
                    """
                    SELECT device_id, owner_user_id, device_short_id, name, device_token,
                           pairing_challenge, pairing_response, created_at, updated_at
                    FROM devices
                    WHERE owner_user_id = ? AND revoked_at IS NULL
                    ORDER BY updated_at DESC
                    """,
                    (user_id,),
                ).fetchall()
                existing = next(
                    (
                        row
                        for row in candidates
                        if pairing_hardware_id_from_challenge(str(row["pairing_challenge"] or ""))
                        == hardware_id
                    ),
                    None,
                )
        if existing is not None:
            if existing["owner_user_id"] != user_id:
                raise PermissionError("device_already_bound")
            if str(existing["pairing_challenge"] or "") != clean_challenge:
                pairing_nonce = secrets.token_urlsafe(18)
                pairing_response = make_pairing_response(
                    clean_challenge,
                    str(existing["device_id"]),
                    pairing_nonce,
                )
                now = int(time.time())
                with self.lock, self.db:
                    self.db.execute(
                        """
                        UPDATE devices
                        SET device_short_id = ?, name = ?, pairing_challenge = ?,
                            pairing_response = ?, updated_at = ?
                        WHERE device_id = ? AND owner_user_id = ? AND revoked_at IS NULL
                        """,
                        (
                            hardware_id or existing["device_short_id"],
                            clean_name,
                            clean_challenge,
                            pairing_response,
                            now,
                            existing["device_id"],
                            user_id,
                        ),
                    )
                    existing = self.db.execute(
                        """
                        SELECT device_id, owner_user_id, device_short_id, name, device_token,
                               pairing_challenge, pairing_response, created_at, updated_at
                        FROM devices
                        WHERE device_id = ? AND owner_user_id = ? AND revoked_at IS NULL
                        """,
                        (existing["device_id"], user_id),
                    ).fetchone()
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

    def user_owns_relay_identifier(self, user_id: str, relay_identifier: str) -> bool:
        clean_identifier = relay_identifier.strip().lower()
        if not clean_identifier:
            return False
        return clean_identifier in self.active_relay_identifiers_for_user(user_id)

    def active_relay_identifiers_for_user(self, user_id: str) -> list[str]:
        with self.lock:
            rows = self.db.execute(
                """
                SELECT device_token
                FROM devices
                WHERE owner_user_id = ? AND revoked_at IS NULL
                """,
                (user_id,),
            ).fetchall()
        identifiers = {
            stable_relay_identifier(str(row["device_token"]))
            for row in rows
            if str(row["device_token"] or "").strip()
        }
        return sorted(identifier for identifier in identifiers if identifier)

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
            "name": safe_existing_display_name(str(row["name"] or ""), "胶囊设备"),
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
        self.prune_retained_data()
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

    def list_audit_events(
        self,
        limit: int = 100,
        room_code: str = "",
        user_id: str = "",
    ) -> list[dict[str, Any]]:
        clean_limit = min(200, max(1, limit))
        clean_room = room_code.strip()
        clean_user = user_id.strip()
        if not clean_user:
            raise PermissionError("unauthorized")
        params: tuple[Any, ...]
        where: str
        if clean_room:
            if self.get_room_member_for_user(clean_room, clean_user) is None:
                raise PermissionError("not_room_member")
            where = "WHERE room_code = ?"
            params = (clean_room, clean_limit)
        else:
            where = """
                WHERE actor_id = ?
                   OR room_code IN (
                       SELECT DISTINCT room_code
                       FROM room_members
                       WHERE user_id = ?
                   )
            """
            params = (clean_user, clean_user, clean_limit)
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

    def unregister_push_subscription(self, user_id: str, device_token: str) -> None:
        token = clean_push_device_token(device_token)
        now = int(time.time())
        with self.lock, self.db:
            cursor = self.db.execute(
                """
                UPDATE push_subscriptions
                SET enabled = 0, updated_at = ?
                WHERE device_token = ? AND user_id = ? AND enabled = 1
                """,
                (now, token, user_id),
            )
        if cursor.rowcount != 1:
            # Do not reveal whether a token is registered to a different account.
            raise KeyError("push_subscription_not_found")

    def disable_invalid_push_subscription(self, device_token: str) -> None:
        token = clean_push_device_token(device_token)
        now = int(time.time())
        with self.lock, self.db:
            self.db.execute(
                """
                UPDATE push_subscriptions
                SET enabled = 0, updated_at = ?
                WHERE device_token = ? AND enabled = 1
                """,
                (now, token),
            )

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

    def ensure_user(
        self,
        user_id: str,
        display_name: str = "",
        apple_user_id: str = "",
        apple_refresh_token: str = "",
    ) -> None:
        now = int(time.time())
        clean_name = clean_display_name(display_name) if display_name.strip() else ""
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO users (
                    user_id, apple_user_id, apple_refresh_token, display_name, created_at, updated_at
                )
                VALUES (?, NULLIF(?, ''), ?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                  apple_user_id = COALESCE(NULLIF(excluded.apple_user_id, ''), users.apple_user_id),
                  apple_refresh_token = COALESCE(
                    NULLIF(excluded.apple_refresh_token, ''), users.apple_refresh_token
                  ),
                  display_name = COALESCE(NULLIF(excluded.display_name, ''), users.display_name),
                  updated_at = excluded.updated_at
                """,
                (user_id, apple_user_id, apple_refresh_token, clean_name, now, now),
            )

    def user_display_name(self, user_id: str) -> str:
        with self.lock:
            row = self.db.execute(
                "SELECT display_name FROM users WHERE user_id = ?",
                (user_id,),
            ).fetchone()
        return safe_existing_display_name(
            str(row["display_name"] or ""),
            "Capsule Radar 用户",
        ) if row is not None else ""

    def update_user_display_name(self, user_id: str, display_name: str) -> str:
        clean_name = clean_display_name(display_name)
        if (
            not clean_name
            or clean_name in {"胶囊用户", "Dragon Radar User"}
            or clean_name.startswith("apple:")
        ):
            return ""
        now = int(time.time())
        with self.lock, self.db:
            row = self.db.execute(
                "SELECT display_name FROM users WHERE user_id = ?",
                (user_id,),
            ).fetchone()
            if row is not None and str(row["display_name"] or "").strip() == clean_name:
                return clean_name
            self.db.execute(
                "UPDATE users SET display_name = ?, updated_at = ? WHERE user_id = ?",
                (clean_name, now, user_id),
            )
            self.db.execute(
                "UPDATE room_members SET display_name = ?, updated_at = ? WHERE user_id = ?",
                (clean_name, now, user_id),
            )
        return clean_name

    def create_auth_session(
        self,
        apple_user_id: str,
        display_name: str = "",
        apple_refresh_token: str = "",
    ) -> dict[str, Any]:
        clean_apple_id = apple_user_id.strip()[:128]
        if not clean_apple_id:
            raise ValueError("apple_user_id_required")
        user_id = f"apple:{clean_apple_id}"
        clean_name = clean_display_name(display_name) or "Capsule Radar 用户"
        self.ensure_user(
            user_id,
            clean_name,
            apple_user_id=clean_apple_id,
            apple_refresh_token=secret_cipher.encrypt(apple_refresh_token)[:8192]
            if apple_refresh_token.strip()
            else "",
        )
        return self.issue_tokens(user_id, clean_name, clean_apple_id)

    def apple_refresh_token_for_user(self, user_id: str) -> str:
        with self.lock:
            row = self.db.execute(
                "SELECT apple_refresh_token FROM users WHERE user_id = ?",
                (user_id,),
            ).fetchone()
        return secret_cipher.decrypt(str(row["apple_refresh_token"] or "")) if row is not None else ""

    def delete_account(self, user_id: str) -> dict[str, int]:
        """Permanently delete account-linked data in one SQLite transaction."""
        clean_user_id = user_id.strip()
        if not clean_user_id:
            raise PermissionError("unauthorized")
        with self.lock, self.db:
            user_row = self.db.execute(
                "SELECT user_id FROM users WHERE user_id = ?",
                (clean_user_id,),
            ).fetchone()
            if user_row is None:
                raise KeyError("account_not_found")

            owned_room_rows = self.db.execute(
                "SELECT room_code FROM rooms WHERE owner_user_id = ?",
                (clean_user_id,),
            ).fetchall()
            owned_room_codes = [str(row["room_code"]) for row in owned_room_rows]
            device_identifier_rows = self.db.execute(
                """
                SELECT device_id, device_short_id, device_token
                FROM devices
                WHERE owner_user_id = ?
                """,
                (clean_user_id,),
            ).fetchall()
            access_token_rows = self.db.execute(
                "SELECT access_token FROM auth_tokens WHERE user_id = ?",
                (clean_user_id,),
            ).fetchall()
            audit_identifiers = {clean_user_id}
            for row in device_identifier_rows:
                device_token = str(row["device_token"] or "")
                audit_identifiers.update(
                    {
                        str(row["device_id"] or ""),
                        str(row["device_short_id"] or ""),
                        device_token,
                        stable_relay_identifier(device_token),
                    }
                )
            for row in access_token_rows:
                app_identifier = stable_relay_identifier(str(row["access_token"] or ""))
                audit_identifiers.update({app_identifier, f"app-{app_identifier}"})
            audit_identifiers.discard("")

            deleted_room_data = 0
            for room_code in owned_room_codes:
                self.db.execute("DELETE FROM radar_reminders WHERE room_code = ?", (room_code,))
                self.db.execute("DELETE FROM room_invites WHERE room_code = ?", (room_code,))
                self.db.execute("DELETE FROM room_members WHERE room_code = ?", (room_code,))
                self.db.execute("DELETE FROM diagnostics_reports WHERE room_code = ?", (room_code,))
                self.db.execute("DELETE FROM audit_events WHERE room_code = ?", (room_code,))
                deleted_room_data += self.db.execute(
                    "DELETE FROM rooms WHERE room_code = ?",
                    (room_code,),
                ).rowcount

            self.db.execute("DELETE FROM room_invites WHERE created_by = ?", (clean_user_id,))
            self.db.execute("DELETE FROM radar_reminders WHERE sender_user_id = ?", (clean_user_id,))
            memberships = self.db.execute(
                "DELETE FROM room_members WHERE user_id = ? OR member_id = ?",
                (clean_user_id, clean_user_id),
            ).rowcount
            push_subscriptions = self.db.execute(
                "DELETE FROM push_subscriptions WHERE user_id = ?",
                (clean_user_id,),
            ).rowcount
            diagnostics = self.db.execute(
                "DELETE FROM diagnostics_reports WHERE user_id = ?",
                (clean_user_id,),
            ).rowcount
            content_reports = self.db.execute(
                """
                DELETE FROM content_reports
                WHERE reporter_user_id = ? OR reported_user_id = ?
                """,
                (clean_user_id, clean_user_id),
            ).rowcount
            user_blocks = self.db.execute(
                """
                DELETE FROM user_blocks
                WHERE blocker_user_id = ? OR blocked_user_id = ?
                """,
                (clean_user_id, clean_user_id),
            ).rowcount
            devices = self.db.execute(
                "DELETE FROM devices WHERE owner_user_id = ?",
                (clean_user_id,),
            ).rowcount
            for identifier in audit_identifiers:
                self.db.execute(
                    """
                    DELETE FROM audit_events
                    WHERE actor_id = ? OR group_id = ? OR instr(detail_json, ?) > 0
                    """,
                    (identifier, identifier, identifier),
                )
            sessions = self.db.execute(
                "DELETE FROM auth_tokens WHERE user_id = ?",
                (clean_user_id,),
            ).rowcount
            users = self.db.execute(
                "DELETE FROM users WHERE user_id = ?",
                (clean_user_id,),
            ).rowcount

        return {
            "users": users,
            "sessions": sessions,
            "owned_rooms": deleted_room_data,
            "other_room_memberships": memberships,
            "devices": devices,
            "push_subscriptions": push_subscriptions,
            "diagnostics": diagnostics,
            "content_reports": content_reports,
            "user_blocks": user_blocks,
        }

    def refresh_auth_session(self, refresh_token: str) -> dict[str, Any]:
        token = refresh_token.strip()
        if not token:
            raise PermissionError("unauthorized")
        hashed_token = token_digest(token)
        now = int(time.time())
        with self.lock, self.db:
            row = self.db.execute(
                """
                SELECT t.refresh_token AS stored_refresh_token, t.refresh_expires_at,
                       u.user_id, u.apple_user_id, u.display_name
                FROM auth_tokens t
                JOIN users u ON u.user_id = t.user_id
                WHERE t.refresh_token IN (?, ?)
                """,
                (hashed_token, token),
            ).fetchone()
            if row is None or int(row["refresh_expires_at"] or 0) <= now:
                if row is not None:
                    self.db.execute(
                        "DELETE FROM auth_tokens WHERE refresh_token = ?",
                        (row["stored_refresh_token"],),
                    )
                raise PermissionError("unauthorized")
            self.db.execute(
                "DELETE FROM auth_tokens WHERE refresh_token = ?",
                (row["stored_refresh_token"],),
            )
        if row is None:
            raise PermissionError("unauthorized")
        return self.issue_tokens(row["user_id"], row["display_name"], row["apple_user_id"] or "")

    def validate_access_token(self, access_token: str) -> str | None:
        token = access_token.strip()
        if not token:
            return None
        now = int(time.time())
        hashed_token = token_digest(token)
        with self.lock:
            row = self.db.execute(
                """
                SELECT user_id
                FROM auth_tokens
                WHERE access_token IN (?, ?) AND expires_at > ?
                """,
                (hashed_token, token, now),
            ).fetchone()
        return str(row["user_id"]) if row is not None else None

    def revoke_access_session(self, access_token: str) -> bool:
        token = access_token.strip()
        if not token:
            raise PermissionError("unauthorized")
        with self.lock, self.db:
            deleted = self.db.execute(
                "DELETE FROM auth_tokens WHERE access_token IN (?, ?)",
                (token_digest(token), token),
            ).rowcount
        return deleted > 0

    def issue_tokens(self, user_id: str, display_name: str, apple_user_id: str) -> dict[str, Any]:
        now = int(time.time())
        expires_at = now + 60 * 60
        refresh_expires_at = now + 30 * 24 * 60 * 60
        access_token = "dra_" + secrets.token_urlsafe(32)
        refresh_token = "drr_" + secrets.token_urlsafe(32)
        with self.lock, self.db:
            self.db.execute(
                """
                INSERT INTO auth_tokens (
                    access_token, refresh_token, user_id, expires_at, refresh_expires_at, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                (
                    token_digest(access_token),
                    token_digest(refresh_token),
                    user_id,
                    expires_at,
                    refresh_expires_at,
                    now,
                ),
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
        owner_display_name = self.user_display_name(owner_user_id)
        existing_room = self.find_room_by_owner_and_name(owner_user_id, clean_name)
        if existing_room is not None:
            self.upsert_member(
                existing_room["room_code"],
                owner_user_id,
                owner_user_id,
                owner_display_name,
                role="owner",
            )
            return existing_room
        for _ in range(16):
            room_code = make_room_code()
            with self.lock:
                if self.get_room(room_code) is None:
                    break
        else:
            raise RuntimeError("room_code_exhausted")
        room = self.ensure_room(room_code, clean_name, owner_user_id)
        self.upsert_member(room_code, owner_user_id, owner_user_id, owner_display_name, role="owner")
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
        if self.room_has_block_conflict(room_code, user_id):
            raise PermissionError("blocked_relationship")
        # HTTP callers never choose their persistent member identity. Allowing a
        # client-supplied value here could overwrite another member's row.
        member_id = user_id
        clean_display = (
            clean_display_name(display_name)
            or self.user_display_name(user_id)
            or "Capsule Radar 用户"
        )
        members = self.list_room_members(room_code)
        existing_member_ids = {member["member_id"] for member in members}
        if member_id not in existing_member_ids and len(existing_member_ids) >= int(room["max_members"]):
            raise OverflowError("room_full")
        self.upsert_member(room_code, member_id, user_id, clean_display, role="member")
        return self.get_room(room_code) or room

    def rename_room(self, room_code: str, name: str, user_id: str) -> dict[str, Any]:
        room_code = normalize_room_code(room_code)
        clean_name = clean_room_name(name)
        if not clean_name:
            raise ValueError("room_name_required")
        room = self.get_room(room_code)
        if room is None:
            raise KeyError("invalid_room")
        requester = self.get_room_member_for_user(room_code, user_id)
        if requester is None:
            raise PermissionError("not_room_member")
        if requester["role"] != "owner" or room["owner_user_id"] != user_id:
            raise PermissionError("forbidden")
        now = int(time.time())
        with self.lock, self.db:
            self.db.execute(
                "UPDATE rooms SET name = ?, updated_at = ? WHERE room_code = ?",
                (clean_name, now, room_code),
            )
        return self.get_room(room_code) or room

    def remove_member(self, room_code: str, member_id: str, user_id: str) -> tuple[dict[str, Any], str]:
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
        if target["role"] == "owner":
            raise PermissionError("owner_cannot_be_removed")
        with self.lock, self.db:
            self.db.execute(
                "DELETE FROM room_members WHERE room_code = ? AND member_id = ?",
                (room_code, clean_member_id),
            )
        return self.get_room(room_code) or room, str(target["user_id"])

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
        clean_name = clean_display_name(display_name) if display_name.strip() else ""
        # A room-scoped alias must not overwrite the account profile name.
        self.ensure_user(user_id)
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
                (room_code, member_id, user_id, clean_name, role, now, now),
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

    def get_room_member_for_user(self, room_code: str, user_id: str) -> dict[str, Any] | None:
        room_code = normalize_room_code(room_code)
        clean_user_id = user_id.strip()
        if not clean_user_id:
            return None
        with self.lock:
            row = self.db.execute(
                """
                SELECT room_code, member_id, user_id, display_name, role, joined_at, updated_at
                FROM room_members
                WHERE room_code = ? AND user_id = ?
                ORDER BY CASE WHEN role = 'owner' THEN 0 ELSE 1 END, updated_at DESC
                LIMIT 1
                """,
                (room_code, clean_user_id),
            ).fetchone()
        return dict(row) if row is not None else None

    def users_blocked(self, first_user_id: str, second_user_id: str) -> bool:
        first = first_user_id.strip()
        second = second_user_id.strip()
        if not first or not second or first == second:
            return False
        with self.lock:
            row = self.db.execute(
                """
                SELECT 1
                FROM user_blocks
                WHERE (blocker_user_id = ? AND blocked_user_id = ?)
                   OR (blocker_user_id = ? AND blocked_user_id = ?)
                LIMIT 1
                """,
                (first, second, second, first),
            ).fetchone()
        return row is not None

    def room_has_block_conflict(self, room_code: str, user_id: str) -> bool:
        clean_room = normalize_room_code(room_code)
        clean_user = user_id.strip()
        with self.lock:
            row = self.db.execute(
                """
                SELECT 1
                FROM room_members member
                JOIN user_blocks block
                  ON (
                       block.blocker_user_id = ?
                       AND block.blocked_user_id = member.user_id
                     )
                  OR (
                       block.blocked_user_id = ?
                       AND block.blocker_user_id = member.user_id
                     )
                WHERE member.room_code = ?
                  AND member.user_id <> ?
                LIMIT 1
                """,
                (clean_user, clean_user, clean_room, clean_user),
            ).fetchone()
        return row is not None

    def resolve_moderation_ref(
        self,
        room_code: str,
        requester_user_id: str,
        moderation_ref: str,
    ) -> str:
        clean_room = normalize_room_code(room_code)
        clean_requester = requester_user_id.strip()
        clean_ref = moderation_ref.strip()
        if MODERATION_REF_PATTERN.fullmatch(clean_ref) is None:
            raise ValueError("invalid_moderation_ref")
        if self.get_room_member_for_user(clean_room, clean_requester) is None:
            raise PermissionError("not_room_member")
        with self.lock:
            rows = self.db.execute(
                """
                SELECT DISTINCT user_id
                FROM room_members
                WHERE room_code = ? AND trim(user_id) <> ''
                """,
                (clean_room,),
            ).fetchall()
        for row in rows:
            candidate = str(row["user_id"] or "")
            expected = moderation_ref_for_user(clean_room, candidate)
            if expected and hmac.compare_digest(clean_ref, expected):
                return candidate
        raise KeyError("moderation_target_not_found")

    def create_content_report(
        self,
        reporter_user_id: str,
        room_code: str,
        moderation_ref: str,
        content_type: str,
        category: str,
        details: str = "",
    ) -> dict[str, Any]:
        clean_reporter = reporter_user_id.strip()
        clean_room = normalize_room_code(room_code)
        clean_type = content_type.strip().lower()
        clean_category = category.strip().lower()
        if clean_type not in CONTENT_REPORT_TYPES:
            raise ValueError("invalid_report_type")
        if clean_category not in CONTENT_REPORT_CATEGORIES:
            raise ValueError("invalid_report_category")
        clean_details = clean_report_details(details)
        reported_user_id = self.resolve_moderation_ref(
            clean_room,
            clean_reporter,
            moderation_ref,
        )
        if reported_user_id == clean_reporter:
            raise ValueError("cannot_report_self")

        now = int(time.time())
        window_start = now - CONTENT_REPORT_WINDOW_SECONDS
        with self.lock, self.db:
            recent_rows = self.db.execute(
                """
                SELECT created_at
                FROM content_reports
                WHERE reporter_user_id = ? AND created_at > ?
                ORDER BY created_at ASC
                """,
                (clean_reporter, window_start),
            ).fetchall()
            if len(recent_rows) >= CONTENT_REPORT_WINDOW_LIMIT:
                retry_after = (
                    int(recent_rows[0]["created_at"])
                    + CONTENT_REPORT_WINDOW_SECONDS
                    - now
                )
                raise ContentReportRateLimited(retry_after)
            report_id = "rpt_" + secrets.token_urlsafe(16)
            case_number = f"DR-{time.strftime('%Y%m%d', time.gmtime(now))}-{secrets.token_hex(4).upper()}"
            self.db.execute(
                """
                INSERT INTO content_reports (
                    report_id, case_number, reporter_user_id, reported_user_id,
                    room_code, content_type, category, details, status, created_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'received', ?)
                """,
                (
                    report_id,
                    case_number,
                    clean_reporter,
                    reported_user_id,
                    clean_room,
                    clean_type,
                    clean_category,
                    clean_details,
                    now,
                ),
            )
        return {
            "case_number": case_number,
            "status": "received",
            "created_at": now,
        }

    @staticmethod
    def public_block_payload(row: sqlite3.Row | dict[str, Any]) -> dict[str, Any]:
        return {
            "block_id": str(row["block_id"]),
            "room_code": str(row["room_code"]),
            "moderation_ref": str(row["moderation_ref"]),
            "created_at": int(row["created_at"]),
        }

    def list_user_blocks(self, blocker_user_id: str) -> list[dict[str, Any]]:
        clean_blocker = blocker_user_id.strip()
        with self.lock:
            rows = self.db.execute(
                """
                SELECT block_id, room_code, moderation_ref, created_at
                FROM user_blocks
                WHERE blocker_user_id = ?
                ORDER BY created_at DESC
                """,
                (clean_blocker,),
            ).fetchall()
        return [self.public_block_payload(row) for row in rows]

    def create_user_block(
        self,
        blocker_user_id: str,
        room_code: str,
        moderation_ref: str,
    ) -> tuple[dict[str, Any], list[dict[str, str]]]:
        clean_blocker = blocker_user_id.strip()
        clean_room = normalize_room_code(room_code)
        clean_ref = moderation_ref.strip()
        blocked_user_id = self.resolve_moderation_ref(clean_room, clean_blocker, clean_ref)
        if blocked_user_id == clean_blocker:
            raise ValueError("cannot_block_self")
        now = int(time.time())
        with self.lock, self.db:
            existing = self.db.execute(
                """
                SELECT block_id, created_at
                FROM user_blocks
                WHERE blocker_user_id = ? AND blocked_user_id = ?
                """,
                (clean_blocker, blocked_user_id),
            ).fetchone()
            block_id = str(existing["block_id"]) if existing is not None else "blk_" + secrets.token_urlsafe(16)
            created_at = int(existing["created_at"]) if existing is not None else now
            self.db.execute(
                """
                INSERT INTO user_blocks (
                    block_id, blocker_user_id, blocked_user_id, room_code,
                    moderation_ref, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(blocker_user_id, blocked_user_id) DO UPDATE SET
                  room_code = excluded.room_code,
                  moderation_ref = excluded.moderation_ref,
                  updated_at = excluded.updated_at
                """,
                (
                    block_id,
                    clean_blocker,
                    blocked_user_id,
                    clean_room,
                    clean_ref,
                    created_at,
                    now,
                ),
            )
            shared_rooms = self.db.execute(
                """
                SELECT DISTINCT room.room_code, room.owner_user_id
                FROM rooms room
                JOIN room_members blocker
                  ON blocker.room_code = room.room_code AND blocker.user_id = ?
                JOIN room_members blocked
                  ON blocked.room_code = room.room_code AND blocked.user_id = ?
                ORDER BY room.room_code
                """,
                (clean_blocker, blocked_user_id),
            ).fetchall()
            effects: list[dict[str, str]] = []
            for shared_room in shared_rooms:
                shared_room_code = str(shared_room["room_code"])
                if str(shared_room["owner_user_id"]) == clean_blocker:
                    disconnected_user_id = blocked_user_id
                    action = "blocked_user_removed"
                else:
                    disconnected_user_id = clean_blocker
                    action = "blocker_left"
                self.db.execute(
                    "DELETE FROM room_members WHERE room_code = ? AND user_id = ?",
                    (shared_room_code, disconnected_user_id),
                )
                effects.append(
                    {
                        "room_code": shared_room_code,
                        "action": action,
                        "disconnected_user_id": disconnected_user_id,
                    }
                )
            block = {
                "block_id": block_id,
                "room_code": clean_room,
                "moderation_ref": clean_ref,
                "created_at": created_at,
            }
        return self.public_block_payload(block), effects

    def delete_user_block(
        self,
        blocker_user_id: str,
        block_id: str = "",
        room_code: str = "",
        moderation_ref: str = "",
    ) -> dict[str, Any]:
        clean_blocker = blocker_user_id.strip()
        clean_block_id = block_id.strip()
        clean_ref = moderation_ref.strip()
        if clean_block_id:
            if BLOCK_ID_PATTERN.fullmatch(clean_block_id) is None:
                raise ValueError("invalid_block_id")
            where = "blocker_user_id = ? AND block_id = ?"
            params: tuple[str, ...] = (clean_blocker, clean_block_id)
        else:
            clean_room = normalize_room_code(room_code)
            if MODERATION_REF_PATTERN.fullmatch(clean_ref) is None:
                raise ValueError("invalid_moderation_ref")
            where = "blocker_user_id = ? AND room_code = ? AND moderation_ref = ?"
            params = (clean_blocker, clean_room, clean_ref)
        with self.lock, self.db:
            row = self.db.execute(
                f"SELECT block_id, room_code, moderation_ref, created_at FROM user_blocks WHERE {where}",
                params,
            ).fetchone()
            if row is None:
                raise KeyError("block_not_found")
            self.db.execute(
                "DELETE FROM user_blocks WHERE blocker_user_id = ? AND block_id = ?",
                (clean_blocker, row["block_id"]),
            )
        return self.public_block_payload(row)

    def create_radar_reminder(
        self,
        room_code: str,
        sender_user_id: str,
        request_id: str,
    ) -> tuple[dict[str, Any], bool, list[str], str, str]:
        clean_room = normalize_room_code(room_code)
        clean_sender = sender_user_id.strip()
        clean_request = request_id.strip()
        if not clean_request:
            raise ValueError("request_id_required")
        if RADAR_REMINDER_REQUEST_ID.fullmatch(clean_request) is None:
            raise ValueError("invalid_request_id")

        now = int(time.time())
        with self.lock, self.db:
            room_row = self.db.execute(
                "SELECT name FROM rooms WHERE room_code = ?",
                (clean_room,),
            ).fetchone()
            if room_row is None:
                raise KeyError("invalid_room")

            sender_row = self.db.execute(
                """
                SELECT m.display_name AS member_display_name, u.display_name AS user_display_name
                FROM room_members m
                LEFT JOIN users u ON u.user_id = m.user_id
                WHERE m.room_code = ? AND m.user_id = ?
                ORDER BY CASE WHEN m.role = 'owner' THEN 0 ELSE 1 END, m.updated_at DESC
                LIMIT 1
                """,
                (clean_room, clean_sender),
            ).fetchone()
            if sender_row is None:
                raise PermissionError("not_room_member")

            existing = self.db.execute(
                """
                SELECT event_id, request_id, room_code, recipient_count,
                       online_delivered, push_status, created_at
                FROM radar_reminders
                WHERE room_code = ? AND sender_user_id = ? AND request_id = ?
                """,
                (clean_room, clean_sender, clean_request),
            ).fetchone()
            sender_name = safe_existing_display_name(
                str(sender_row["user_display_name"] or sender_row["member_display_name"] or "房间成员"),
                "房间成员",
            ) or "房间成员"
            room_name = safe_existing_room_name(
                str(room_row["name"] or clean_room),
                clean_room,
            ) or clean_room
            if existing is not None:
                return self.radar_reminder_dict(existing), False, [], sender_name, room_name

            latest = self.db.execute(
                """
                SELECT created_at
                FROM radar_reminders
                WHERE room_code = ? AND sender_user_id = ?
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (clean_room, clean_sender),
            ).fetchone()
            if latest is not None:
                elapsed = now - int(latest["created_at"])
                if elapsed < RADAR_REMINDER_COOLDOWN_SECONDS:
                    raise RadarReminderRateLimited(RADAR_REMINDER_COOLDOWN_SECONDS - elapsed)

            recent_rows = self.db.execute(
                """
                SELECT created_at
                FROM radar_reminders
                WHERE room_code = ? AND sender_user_id = ? AND created_at > ?
                ORDER BY created_at ASC
                """,
                (clean_room, clean_sender, now - RADAR_REMINDER_WINDOW_SECONDS),
            ).fetchall()
            if len(recent_rows) >= RADAR_REMINDER_WINDOW_LIMIT:
                retry_after = (
                    int(recent_rows[0]["created_at"])
                    + RADAR_REMINDER_WINDOW_SECONDS
                    - now
                )
                raise RadarReminderRateLimited(retry_after)

            recipient_rows = self.db.execute(
                """
                SELECT DISTINCT member.user_id
                FROM room_members member
                WHERE member.room_code = ?
                  AND member.user_id <> ?
                  AND trim(member.user_id) <> ''
                  AND NOT EXISTS (
                      SELECT 1
                      FROM user_blocks block
                      WHERE (block.blocker_user_id = ? AND block.blocked_user_id = member.user_id)
                         OR (block.blocked_user_id = ? AND block.blocker_user_id = member.user_id)
                  )
                ORDER BY member.user_id
                """,
                (clean_room, clean_sender, clean_sender, clean_sender),
            ).fetchall()
            recipient_user_ids = [str(row["user_id"]) for row in recipient_rows]
            event_id = "rr_" + secrets.token_urlsafe(14)
            self.db.execute(
                """
                INSERT INTO radar_reminders (
                    event_id, request_id, room_code, sender_user_id, recipient_count,
                    online_delivered, push_status, created_at, updated_at
                )
                VALUES (?, ?, ?, ?, ?, 0, 'pending', ?, ?)
                """,
                (
                    event_id,
                    clean_request,
                    clean_room,
                    clean_sender,
                    len(recipient_user_ids),
                    now,
                    now,
                ),
            )
            reminder = {
                "event_id": event_id,
                "request_id": clean_request,
                "room_code": clean_room,
                "recipient_count": len(recipient_user_ids),
                "online_delivered": 0,
                "push_status": "pending",
                "cooldown_seconds": RADAR_REMINDER_COOLDOWN_SECONDS,
                "server_time": now,
            }
        return reminder, True, recipient_user_ids, sender_name, room_name

    def update_radar_reminder_delivery(
        self,
        event_id: str,
        online_delivered: int,
        push_status: str,
    ) -> dict[str, Any]:
        now = int(time.time())
        clean_status = push_status.strip()[:32] or "unknown"
        with self.lock, self.db:
            self.db.execute(
                """
                UPDATE radar_reminders
                SET online_delivered = ?, push_status = ?, updated_at = ?
                WHERE event_id = ?
                """,
                (max(0, int(online_delivered)), clean_status, now, event_id),
            )
            row = self.db.execute(
                """
                SELECT event_id, request_id, room_code, recipient_count,
                       online_delivered, push_status, created_at
                FROM radar_reminders
                WHERE event_id = ?
                """,
                (event_id,),
            ).fetchone()
        if row is None:
            raise KeyError("radar_reminder_not_found")
        return self.radar_reminder_dict(row)

    @staticmethod
    def radar_reminder_dict(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "event_id": row["event_id"],
            "request_id": row["request_id"],
            "room_code": row["room_code"],
            "recipient_count": int(row["recipient_count"]),
            "online_delivered": int(row["online_delivered"]),
            "push_status": row["push_status"],
            "cooldown_seconds": RADAR_REMINDER_COOLDOWN_SECONDS,
            "server_time": int(row["created_at"]),
        }

    def create_invite(self, room_code: str, user_id: str, expires_at: int | None = None) -> dict[str, Any]:
        room_code = normalize_room_code(room_code)
        if self.get_room(room_code) is None:
            raise KeyError("invalid_room")
        if self.get_room_member_for_user(room_code, user_id) is None:
            raise PermissionError("not_room_member")
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

    def members(self, include_moderation_refs: bool = False) -> list[dict[str, Any]]:
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
            member = {
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
            if include_moderation_refs and display_peer.user_id:
                member["moderation_ref"] = moderation_ref_for_user(
                    self.code,
                    display_peer.user_id,
                )
            values.append(member)
        return values


rooms: dict[str, Room] = {}
pending_room_switches: dict[tuple[str, str, str], dict[str, Any]] = {}
relay_asyncio_loop: asyncio.AbstractEventLoop | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Minimal Capsule WebSocket Relay.")
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
    return f"CAPS-{suffix}"


def normalize_room_code(value: str) -> str:
    clean = value.strip().upper()
    if not clean:
        raise ValueError("room_code_required")
    # Older physical devices persist the room token in NVS. Accept the retired
    # prefix only as an input alias so those devices reconnect after the public
    # brand migration without ever returning the legacy code to clients.
    if clean.startswith("KAME-"):
        clean = "CAPS-" + clean[5:]
    return clean


def configured_blocked_terms() -> tuple[str, ...]:
    configured = os.environ.get("DRAGON_RADAR_BLOCKED_TERMS", "")
    extra = re.split(r"[,;|\n\r]+", configured) if configured else []
    unique: dict[str, str] = {}
    for value in (*DEFAULT_BLOCKED_TERMS, *extra):
        clean = sanitize_unicode_text(value, collapse_whitespace=True).strip()
        match_key = moderation_text_match_key(clean)
        if clean and match_key:
            unique[match_key] = clean
    return tuple(unique.values())


def sanitize_unicode_text(value: str, collapse_whitespace: bool = True) -> str:
    normalized = unicodedata.normalize("NFKC", value)
    without_controls = "".join(
        character
        for character in normalized
        if unicodedata.category(character) not in {"Cc", "Cf", "Cs"}
    )
    if collapse_whitespace:
        return " ".join(without_controls.strip().split())
    return without_controls.strip()


def moderation_text_match_key(value: str) -> str:
    normalized = sanitize_unicode_text(value, collapse_whitespace=True).casefold()
    return "".join(character for character in normalized if character.isalnum())


def clean_public_name(
    value: str | None,
    *,
    max_length: int = 40,
    enforce_blocked_terms: bool = True,
) -> str:
    if value is None:
        return ""
    clean = sanitize_unicode_text(str(value), collapse_whitespace=True)[:max_length]
    if clean and enforce_blocked_terms:
        match_key = moderation_text_match_key(clean)
        if any(moderation_text_match_key(term) in match_key for term in configured_blocked_terms()):
            raise ValueError("prohibited_name")
    return clean


def clean_display_name(value: str | None, *, enforce_blocked_terms: bool = True) -> str:
    return clean_public_name(
        value,
        max_length=40,
        enforce_blocked_terms=enforce_blocked_terms,
    )


def clean_room_name(value: str | None, *, enforce_blocked_terms: bool = True) -> str:
    return clean_public_name(
        value,
        max_length=40,
        enforce_blocked_terms=enforce_blocked_terms,
    )


def safe_existing_display_name(value: str | None, fallback: str = "") -> str:
    try:
        return clean_display_name(value)
    except ValueError:
        return fallback


def safe_existing_room_name(value: str | None, fallback: str = "") -> str:
    try:
        return clean_room_name(value)
    except ValueError:
        return fallback


def clean_report_details(value: str | None) -> str:
    clean = sanitize_unicode_text(str(value or ""), collapse_whitespace=True)
    if len(clean) > CONTENT_REPORT_DETAIL_MAX_CHARS:
        raise ValueError("report_details_too_long")
    return clean


def moderation_hmac_key() -> bytes:
    return (
        os.environ.get("DRAGON_RADAR_MODERATION_HMAC_KEY")
        or DEFAULT_MODERATION_HMAC_KEY
    ).encode("utf-8")


def moderation_ref_for_user(room_code: str, user_id: str) -> str:
    clean_room = normalize_room_code(room_code)
    clean_user = user_id.strip()
    if not clean_user:
        return ""
    message = f"dragon-radar-moderation-v1|{clean_room}|{clean_user}".encode("utf-8")
    digest = hmac.new(moderation_hmac_key(), message, hashlib.sha256).digest()
    return "mod_v1_" + base64url_encode(digest)


def sanitize_relay_message_names(message: dict[str, Any]) -> dict[str, Any]:
    sanitized = dict(message)
    if "name" in sanitized:
        name = sanitized.get("name")
        sanitized["name"] = clean_display_name(name if isinstance(name, str) else "")
    for key in ("device_status", "status"):
        nested = sanitized.get(key)
        if isinstance(nested, dict) and "name" in nested:
            clean_nested = dict(nested)
            name = clean_nested.get("name")
            clean_nested["name"] = clean_display_name(name if isinstance(name, str) else "")
            sanitized[key] = clean_nested
    return sanitized


def pairing_hardware_id_from_challenge(value: str) -> str:
    clean = value.strip().upper()
    match = re.fullmatch(r"CR-([0-9A-F]{4})-[0-9A-F]{32}", clean)
    return match.group(1) if match else ""


def device_short_id_from_challenge(value: str) -> str:
    hardware_id = pairing_hardware_id_from_challenge(value)
    if hardware_id:
        return hardware_id
    clean = "".join(ch for ch in value.upper() if ch in string.ascii_uppercase + string.digits)
    if len(clean) >= 4:
        return clean[-4:]
    suffix = "".join(secrets.choice(ROOM_CODE_ALPHABET) for _ in range(4 - len(clean)))
    return (clean + suffix)[:4]


def stable_relay_identifier(secret: str) -> str:
    clean_secret = secret.strip()
    if not clean_secret:
        return ""
    return hashlib.sha256(clean_secret.encode("utf-8")).hexdigest()[:24]


def token_digest(token: str) -> str:
    clean_token = token.strip()
    if not clean_token:
        return ""
    return "sha256:" + hashlib.sha256(clean_token.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class WebSocketAuthTicket:
    user_id: str
    expires_at: int


class WebSocketAuthTicketStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._tickets: dict[str, WebSocketAuthTicket] = {}

    def issue(self, user_id: str) -> tuple[str, int]:
        clean_user_id = user_id.strip()
        if not clean_user_id:
            raise PermissionError("unauthorized")
        ticket = secrets.token_urlsafe(32)
        expires_at = int(time.time()) + WS_AUTH_TICKET_TTL_SECONDS
        digest = token_digest(ticket)
        with self._lock:
            self._remove_expired_locked(int(time.time()))
            self._tickets[digest] = WebSocketAuthTicket(
                user_id=clean_user_id,
                expires_at=expires_at,
            )
        return ticket, expires_at

    def consume(self, ticket: str) -> str:
        digest = token_digest(ticket)
        if not digest:
            return ""
        now = int(time.time())
        with self._lock:
            self._remove_expired_locked(now)
            entry = self._tickets.pop(digest, None)
        if entry is None or entry.expires_at < now:
            return ""
        return entry.user_id

    def _remove_expired_locked(self, now: int) -> None:
        expired = [
            digest
            for digest, entry in self._tickets.items()
            if entry.expires_at < now
        ]
        for digest in expired:
            self._tickets.pop(digest, None)


websocket_auth_tickets = WebSocketAuthTicketStore()


def user_id_from_headers(headers: Any) -> str:
    token = bearer_token_from_headers(headers)
    if token and store is not None:
        user_id = store.validate_access_token(token)
        if user_id:
            return user_id
    return ""


def bearer_token_from_headers(headers: Any) -> str:
    authorization = str(headers.get("Authorization", "") or "")
    if not authorization.startswith("Bearer "):
        return ""
    return authorization.removeprefix("Bearer ").strip()


def legacy_websocket_query_auth_allowed() -> bool:
    return os.environ.get("DRAGON_RADAR_ALLOW_LEGACY_QUERY_AUTH", "").strip().lower() in {
        "1",
        "true",
        "yes",
    }


def display_name_from_payload(payload: dict[str, Any], fallback: str) -> str:
    for key in ("display_name", "name", "room_name"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return clean_display_name(value)
    return clean_display_name(fallback)


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
        audit_delivery: bool = True,
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
            if audit_delivery:
                self.audit_delivery(relay_store, clean_type, clean_room, clean_target, result)
            return result

        attempts: list[dict[str, Any]] = []
        for subscription in subscriptions:
            attempt = self.deliver_to_subscription(
                subscription,
                clean_type,
                clean_room,
                title,
                body,
                data or {},
            )
            if attempt.pop("disable_subscription", False):
                relay_store.disable_invalid_push_subscription(str(subscription.get("device_token") or ""))
            attempts.append(attempt)
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
        if audit_delivery:
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
        reason = response_body[:240]
        try:
            reason_code = str(json.loads(response_body).get("reason") or "")
        except (json.JSONDecodeError, AttributeError):
            reason_code = ""
        permanently_invalid = status_code == 410 or reason_code in {
            "BadDeviceToken",
            "DeviceTokenNotForTopic",
            "Unregistered",
        }
        return {
            **base,
            "status": "failed",
            "apns_status": status_code,
            "reason": reason,
            "disable_subscription": permanently_invalid,
        }

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
        aps: dict[str, Any] = {
            "alert": {"title": title[:80], "body": body[:160]},
            "sound": "default",
        }
        if notification_type == "radar_reminder":
            aps["category"] = "RADAR_REMINDER"
        payload = {
            "aps": aps,
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


def public_room_payload(room: dict[str, Any]) -> dict[str, Any]:
    """Return the room contract without exposing account or persistent member IDs."""
    members = room.get("members") if isinstance(room.get("members"), list) else []
    public_members = [
        {
            "display_name": safe_existing_display_name(
                str(member.get("display_name") or ""),
                "Capsule Radar 用户",
            ),
            "role": str(member.get("role") or "member")[:32],
            "joined_at": int(member.get("joined_at") or 0),
            "updated_at": int(member.get("updated_at") or 0),
        }
        for member in members
        if isinstance(member, dict)
    ]
    return {
        "room_id": str(room.get("room_id") or ""),
        "room_code": str(room.get("room_code") or ""),
        "name": safe_existing_room_name(
            str(room.get("name") or ""),
            f"远程雷达房 {str(room.get('room_code') or '')}",
        ),
        "max_members": int(room.get("max_members") or MAX_ROOM_MEMBERS),
        "member_count": int(room.get("member_count") or len(public_members)),
        "members": public_members,
        "created_at": int(room.get("created_at") or 0),
        "updated_at": int(room.get("updated_at") or 0),
    }


def enrich_room(room: dict[str, Any]) -> dict[str, Any]:
    enriched = public_room_payload(room)
    enriched.update(live_room_counts(str(room["room_code"])))
    return enriched


def relay_health_payload() -> dict[str, Any]:
    connection_count = sum(len(room.peers) for room in rooms.values())
    moderation_key = os.environ.get("DRAGON_RADAR_MODERATION_HMAC_KEY", "")
    retention: dict[str, Any] = {"configured": False}
    if store is not None:
        store.prune_retained_data()
        retention = {"configured": True, **store.retention_health_payload()}
    return {
        "ok": True,
        "service": "dragon-radar-relay",
        "rooms": len(rooms),
        "connections": connection_count,
        "notifications": push_notifications.health_payload(),
        "sign_in_with_apple": apple_oauth_service.health_payload(),
        "firmware": firmware_releases.health_payload(),
        "protocol": relay_protocol_payload(),
        "security": {
            "websocket_authorization_header": True,
            "legacy_query_auth": legacy_websocket_query_auth_allowed(),
        },
        "moderation": {
            "enabled": True,
            "hmac_key_configured": bool(moderation_key),
            "hmac_key_strong": len(moderation_key.encode("utf-8")) >= 32,
            "using_development_key": not bool(moderation_key),
            "production_ready": len(moderation_key.encode("utf-8")) >= 32,
            "blocked_terms_count": len(configured_blocked_terms()),
            "report_types": sorted(CONTENT_REPORT_TYPES),
            "report_categories": sorted(CONTENT_REPORT_CATEGORIES),
            "report_detail_max_chars": CONTENT_REPORT_DETAIL_MAX_CHARS,
            "report_window_seconds": CONTENT_REPORT_WINDOW_SECONDS,
            "report_window_limit": CONTENT_REPORT_WINDOW_LIMIT,
        },
        "retention": retention,
        "limits": {
            "http_max_body_bytes": HTTP_MAX_BODY_BYTES,
            "http_rate_limit_per_minute": HTTP_RATE_LIMIT_PER_MINUTE,
            "ws_max_message_bytes": WS_MAX_MESSAGE_BYTES,
            "ws_message_rate_limit_per_second": WS_MESSAGE_RATE_LIMIT_PER_SECOND,
            "ws_idle_timeout_seconds": WS_IDLE_TIMEOUT_SECONDS,
            "ws_ping_interval_seconds": WS_PING_INTERVAL_SECONDS,
            "ws_ping_timeout_seconds": WS_PING_TIMEOUT_SECONDS,
            "location_stale_after_seconds": LOCATION_STALE_AFTER_SECONDS,
            "radar_reminder_cooldown_seconds": RADAR_REMINDER_COOLDOWN_SECONDS,
            "radar_reminder_window_seconds": RADAR_REMINDER_WINDOW_SECONDS,
            "radar_reminder_window_limit": RADAR_REMINDER_WINDOW_LIMIT,
        },
    }


class RelayHTTPHandler(BaseHTTPRequestHandler):
    server_version = "CapsuleRelayHTTP/0.1"

    def do_GET(self) -> None:
        self.handle_request("GET")

    def do_HEAD(self) -> None:
        self.handle_request("HEAD")

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
                requested_nonce = str(payload.get("nonce") or "")
                verified_identity = apple_identity_verifier.verify(
                    identity_token,
                    requested_apple_user_id,
                    requested_nonce,
                )
                display_name = display_name_from_payload(payload, "Capsule Radar 用户")
                authorization_code = str(payload.get("authorization_code") or "")
                apple_refresh_token = (
                    ""
                    if verified_identity.development
                    else apple_oauth_service.exchange_authorization_code(authorization_code)
                )
                self.send_json(
                    HTTPStatus.OK,
                    store.create_auth_session(
                        verified_identity.apple_user_id,
                        display_name,
                        apple_refresh_token=apple_refresh_token,
                    ),
                )
                return

            if path == "/v1/auth/refresh" and method == "POST":
                self.require_store()
                assert store is not None
                refresh_token = str(payload.get("refresh_token") or "")
                self.send_json(HTTPStatus.OK, store.refresh_auth_session(refresh_token))
                return

            if path == "/v1/auth/logout" and method == "POST":
                self.require_store()
                assert store is not None
                access_token = bearer_token_from_headers(self.headers)
                if not access_token:
                    self.send_error_json(HTTPStatus.UNAUTHORIZED, "unauthorized")
                    return
                revoked = store.revoke_access_session(access_token)
                self.send_json(
                    HTTPStatus.OK,
                    {"ok": True, "revoked": revoked},
                    headers={"Cache-Control": "no-store"},
                )
                return

            artifact_prefix = "/v1/firmware/artifacts/"
            if path.startswith(artifact_prefix) and method in {"GET", "HEAD"}:
                self.require_store()
                assert store is not None
                token = bearer_token_from_headers(self.headers)
                user_id = store.validate_access_token(token) if token else None
                device = store.validate_device_token(token) if token else None
                if not user_id and not device:
                    if token and store.device_token_revoked(token):
                        self.send_error_json(HTTPStatus.FORBIDDEN, "device_revoked")
                    else:
                        self.send_error_json(HTTPStatus.UNAUTHORIZED, "unauthorized")
                    return
                requested_name = path.removeprefix(artifact_prefix)
                try:
                    release = firmware_releases.artifact(requested_name)
                except FirmwareReleaseUnavailable:
                    self.send_error_json(HTTPStatus.SERVICE_UNAVAILABLE, "firmware_release_unavailable")
                    return
                if release is None:
                    self.send_error_json(HTTPStatus.NOT_FOUND, "firmware_artifact_not_found")
                    return
                self.send_firmware_artifact(release, head_only=method == "HEAD")
                return

            user_id = user_id_from_headers(self.headers)
            if not user_id:
                self.send_error_json(HTTPStatus.UNAUTHORIZED, "unauthorized")
                return

            if path == "/v1/auth/ws-ticket" and method == "POST":
                ticket, expires_at = websocket_auth_tickets.issue(user_id)
                self.send_json(
                    HTTPStatus.CREATED,
                    {
                        "ticket": ticket,
                        "expires_at": expires_at,
                    },
                    headers={"Cache-Control": "no-store"},
                )
                return

            if path == "/v1/account" and method == "DELETE":
                self.require_store()
                assert store is not None
                revocation = apple_oauth_service.revoke_refresh_token(
                    store.apple_refresh_token_for_user(user_id)
                )
                deletion = store.delete_account(user_id)
                run_on_relay_loop(disconnect_user_sessions(user_id), None)
                self.send_json(
                    HTTPStatus.OK,
                    {
                        "ok": True,
                        "deletion": deletion,
                        "apple_access_revocation": revocation,
                    },
                    headers={"Cache-Control": "no-store"},
                )
                return

            if path == "/v1/firmware/manifest" and method == "GET":
                try:
                    release = firmware_releases.current()
                except FirmwareReleaseUnavailable:
                    self.send_error_json(HTTPStatus.SERVICE_UNAVAILABLE, "firmware_release_unavailable")
                    return
                requested_hardware = str((parse_qs(parsed.query).get("hardware") or [""])[0] or "")
                requested_channel = str((parse_qs(parsed.query).get("channel") or ["stable"])[0] or "stable")
                if (
                    requested_channel != "stable"
                    or (requested_hardware and requested_hardware != release.manifest["hardware"])
                ):
                    self.send_error_json(HTTPStatus.NOT_FOUND, "firmware_release_not_found")
                    return
                response_manifest = dict(release.manifest)
                response_manifest.pop("artifact", None)
                response_manifest["artifact_url"] = (
                    "/v1/firmware/artifacts/" + quote(release.artifact_name, safe="")
                )
                self.send_json(
                    HTTPStatus.OK,
                    response_manifest,
                    headers={"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"},
                )
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
                self.send_json(
                    HTTPStatus.OK,
                    {
                        "events": store.list_audit_events(
                            limit=limit,
                            room_code=room_code,
                            user_id=user_id,
                        )
                    },
                )
                return

            if path == "/v1/diagnostics" and method == "POST":
                self.require_store()
                assert store is not None
                report = payload.get("report") if isinstance(payload.get("report"), dict) else payload
                self.send_json(HTTPStatus.CREATED, {"diagnostics": store.save_diagnostics_report(user_id, report)})
                return

            if path == "/v1/reports" and method == "POST":
                self.require_store()
                assert store is not None
                report = store.create_content_report(
                    user_id,
                    str(payload.get("room_code") or ""),
                    str(payload.get("moderation_ref") or ""),
                    str(payload.get("content_type") or payload.get("type") or ""),
                    str(payload.get("category") or ""),
                    str(payload.get("details") or ""),
                )
                store.audit_event(
                    "content_report",
                    room_code=normalize_room_code(str(payload.get("room_code") or "")),
                    actor_role="user",
                    detail={
                        "case_number": report["case_number"],
                        "content_type": str(payload.get("content_type") or payload.get("type") or "")[:32],
                        "category": str(payload.get("category") or "")[:32],
                    },
                )
                self.send_json(
                    HTTPStatus.CREATED,
                    {"report": report},
                    headers={"Cache-Control": "no-store"},
                )
                return

            if path == "/v1/blocks" and method == "GET":
                self.require_store()
                assert store is not None
                self.send_json(
                    HTTPStatus.OK,
                    {"blocks": store.list_user_blocks(user_id)},
                    headers={"Cache-Control": "no-store"},
                )
                return

            if path == "/v1/blocks" and method == "POST":
                self.require_store()
                assert store is not None
                block, effects = store.create_user_block(
                    user_id,
                    str(payload.get("room_code") or ""),
                    str(payload.get("moderation_ref") or ""),
                )
                public_effects = list(
                    run_on_relay_loop(
                        disconnect_block_effect_sessions(effects),
                        [],
                    )
                    or []
                )
                store.audit_event(
                    "user_block",
                    room_code=str(block.get("room_code") or ""),
                    actor_role="user",
                    detail={
                        "block_id": block.get("block_id"),
                        "affected_rooms": len(public_effects),
                        "disconnected_connections": sum(
                            int(effect.get("disconnected_connections") or 0)
                            for effect in public_effects
                        ),
                    },
                )
                self.send_json(
                    HTTPStatus.CREATED,
                    {"block": block, "effects": public_effects},
                    headers={"Cache-Control": "no-store"},
                )
                return

            if path == "/v1/blocks" and method == "DELETE":
                self.require_store()
                assert store is not None
                block = store.delete_user_block(
                    user_id,
                    room_code=str(payload.get("room_code") or ""),
                    moderation_ref=str(payload.get("moderation_ref") or ""),
                )
                store.audit_event(
                    "user_unblock",
                    room_code=str(block.get("room_code") or ""),
                    actor_role="user",
                    detail={"block_id": block.get("block_id")},
                )
                self.send_json(HTTPStatus.OK, {"ok": True, "block": block})
                return

            block_prefix = "/v1/blocks/"
            if path.startswith(block_prefix) and method == "DELETE":
                self.require_store()
                assert store is not None
                block_id = path.removeprefix(block_prefix).strip("/")
                block = store.delete_user_block(user_id, block_id=block_id)
                store.audit_event(
                    "user_unblock",
                    room_code=str(block.get("room_code") or ""),
                    actor_role="user",
                    detail={"block_id": block.get("block_id")},
                )
                self.send_json(HTTPStatus.OK, {"ok": True, "block": block})
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

            if path == "/v1/push/register" and method == "DELETE":
                self.require_store()
                assert store is not None
                store.unregister_push_subscription(
                    user_id,
                    str(payload.get("device_token") or ""),
                )
                store.audit_event(
                    "push_unregister",
                    actor_id=user_id,
                    actor_role="user",
                    group_id=user_id,
                )
                self.send_json(HTTPStatus.OK, {"ok": True})
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
                member_id = user_id
                display_name = display_name_from_payload(
                    payload,
                    store.user_display_name(user_id) or "Capsule Radar 用户",
                )
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

                if len(parts) == 2 and parts[1] == "radar-reminders" and method == "POST":
                    try:
                        reminder, created, recipient_user_ids, sender_name, room_name = store.create_radar_reminder(
                            room_code,
                            user_id,
                            str(payload.get("request_id") or ""),
                        )
                    except RadarReminderRateLimited as exc:
                        self.send_json(
                            HTTPStatus.TOO_MANY_REQUESTS,
                            {
                                "ok": False,
                                "code": "radar_reminder_rate_limited",
                                "retry_after": exc.retry_after,
                            },
                            headers={"Retry-After": str(exc.retry_after)},
                        )
                        return

                    if not created:
                        self.send_json(
                            HTTPStatus.OK,
                            {"reminder": reminder_response_fields(reminder, duplicate=True)},
                        )
                        return

                    recipient_set = set(recipient_user_ids)
                    reminder_for_event = {
                        **reminder,
                        "push_status": planned_radar_reminder_push_status(),
                    }
                    delivered_user_ids = set(
                        run_on_relay_loop(
                            deliver_radar_reminder_to_users(
                                str(reminder["room_code"]),
                                recipient_set,
                                reminder_for_event,
                                sender_name,
                            ),
                            set(),
                        )
                    )
                    online_delivered = len(delivered_user_ids)
                    notification_fields = reminder_response_fields(
                        {**reminder, "online_delivered": online_delivered},
                        duplicate=False,
                    )
                    notification_data = {
                        **notification_fields,
                        "sender_name": sender_name,
                        "action": "open_radar",
                    }
                    push_target_user_ids = (
                        recipient_user_ids
                        if push_notifications.config.mode == "dry_run"
                        else [
                            target_user_id
                            for target_user_id in recipient_user_ids
                            if target_user_id not in delivered_user_ids
                        ]
                    )
                    push_results = [
                        push_notifications.send_to_user(
                            store,
                            target_user_id,
                            "radar_reminder",
                            str(reminder["room_code"]),
                            "胶囊查看提醒",
                            f"{sender_name} 提醒你查看「{room_name}」雷达",
                            notification_data,
                            audit_delivery=False,
                        )
                        for target_user_id in push_target_user_ids
                    ]
                    push_status = aggregate_radar_reminder_push_status(push_results)
                    reminder = store.update_radar_reminder_delivery(
                        str(reminder["event_id"]),
                        online_delivered,
                        push_status,
                    )
                    store.audit_event(
                        "radar_reminder",
                        room_code=str(reminder["room_code"]),
                        actor_role="user",
                        detail={
                            "event_id": reminder["event_id"],
                            "request_id": reminder["request_id"],
                            "recipient_count": reminder["recipient_count"],
                            "online_delivered": reminder["online_delivered"],
                            "push_status": reminder["push_status"],
                        },
                    )
                    self.send_json(
                        HTTPStatus.ACCEPTED,
                        {"reminder": reminder_response_fields(reminder, duplicate=False)},
                    )
                    return

                if len(parts) == 1 and method == "GET":
                    room = store.get_room(room_code)
                    if room is None:
                        self.send_error_json(HTTPStatus.NOT_FOUND, "invalid_room")
                        return
                    if store.get_room_member_for_user(room_code, user_id) is None:
                        raise PermissionError("not_room_member")
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
                    target_user_id = str(payload.get("target_user_id") or "")
                    target_moderation_ref = str(payload.get("target_moderation_ref") or "")
                    if target_moderation_ref:
                        target_user_id = store.resolve_moderation_ref(
                            room_code,
                            user_id,
                            target_moderation_ref,
                        )
                    if target_user_id and store.users_blocked(user_id, target_user_id):
                        raise PermissionError("blocked_relationship")
                    invite = store.create_invite(room_code, user_id, int(payload["expires_at"]) if "expires_at" in payload else None)
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
                        "胶囊房间邀请",
                        f"有人邀请你加入房间 {normalize_room_code(room_code)}",
                        {"invite_code": invite.get("invite_code"), "created_by": user_id},
                    )
                    self.send_json(HTTPStatus.CREATED, {"invite": invite, "notification": notification})
                    return

                if len(parts) == 3 and parts[1] == "members" and method == "DELETE":
                    room, removed_user_id = store.remove_member(room_code, parts[2], user_id)
                    disconnected = int(
                        run_on_relay_loop(
                            disconnect_room_user_sessions(room_code, removed_user_id),
                            0,
                        )
                        or 0
                    )
                    store.audit_event(
                        "room_member_remove",
                        room_code=normalize_room_code(room_code),
                        actor_id=user_id,
                        actor_role="user",
                        detail={"disconnected_connections": disconnected},
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
        except ContentReportRateLimited as exc:
            self.send_json(
                HTTPStatus.TOO_MANY_REQUESTS,
                {
                    "ok": False,
                    "code": "content_report_rate_limited",
                    "retry_after": exc.retry_after,
                },
                headers={"Retry-After": str(exc.retry_after)},
            )
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

    def send_firmware_artifact(self, release: FirmwareRelease, head_only: bool = False) -> None:
        size = release.manifest["size"]
        start = 0
        end = size - 1
        status = HTTPStatus.OK
        range_header = str(self.headers.get("Range", "") or "").strip()
        if range_header:
            try:
                start, end = self.parse_byte_range(range_header, size)
            except ValueError:
                self.send_response(int(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE))
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", "0")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                return
            status = HTTPStatus.PARTIAL_CONTENT

        content_length = end - start + 1
        self.send_response(int(status))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(content_length))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", f'"{release.manifest["sha256"]}"')
        self.send_header("Cache-Control", "private, max-age=86400, immutable")
        self.send_header("Content-Disposition", f'attachment; filename="{release.artifact_name}"')
        self.send_header("X-Content-Type-Options", "nosniff")
        if status == HTTPStatus.PARTIAL_CONTENT:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return

        remaining = content_length
        try:
            with release.artifact_path.open("rb") as handle:
                handle.seek(start)
                while remaining > 0:
                    chunk = handle.read(min(64 * 1024, remaining))
                    if not chunk:
                        raise OSError("firmware_artifact_short_read")
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return

    @staticmethod
    def parse_byte_range(value: str, size: int) -> tuple[int, int]:
        if not value.startswith("bytes=") or "," in value:
            raise ValueError("invalid_range")
        spec = value.removeprefix("bytes=").strip()
        if "-" not in spec:
            raise ValueError("invalid_range")
        start_text, end_text = spec.split("-", 1)
        if not start_text:
            if not end_text.isdigit():
                raise ValueError("invalid_range")
            suffix = int(end_text)
            if suffix <= 0:
                raise ValueError("invalid_range")
            start = max(0, size - suffix)
            return start, size - 1
        if not start_text.isdigit() or (end_text and not end_text.isdigit()):
            raise ValueError("invalid_range")
        start = int(start_text)
        if start >= size:
            raise ValueError("range_not_satisfiable")
        end = int(end_text) if end_text else size - 1
        if end < start:
            raise ValueError("invalid_range")
        return start, min(end, size - 1)

    def send_json(
        self,
        status: HTTPStatus,
        payload: dict[str, Any],
        headers: dict[str, str] | None = None,
    ) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
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
    print(f"胶囊 HTTP API listening on http://{host}:{port}", flush=True)
    return httpd


def member_name(peer: Peer) -> str:
    payload_name = peer.last_payload.get("name")
    if isinstance(payload_name, str) and payload_name.strip():
        return safe_existing_display_name(payload_name)

    device_status = peer.last_payload.get("device_status")
    if isinstance(device_status, dict):
        status_name = device_status.get("name")
        if isinstance(status_name, str) and status_name.strip():
            return safe_existing_display_name(status_name)

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
    if app_peer is not None:
        app_name = app_peer.last_payload.get("name")
        if (
            isinstance(app_name, str)
            and app_name.strip()
            and app_name.strip() not in {"胶囊用户", "Dragon Radar User"}
            and not app_name.strip().startswith("apple:")
        ):
            return safe_existing_display_name(app_name)
    if store is not None:
        for peer in (app_peer, device_peer, fallback_peer):
            if peer is None or not peer.user_id:
                continue
            user_name = store.user_display_name(peer.user_id)
            if user_name:
                return user_name
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


def room_state(room: Room, include_moderation_refs: bool = False) -> dict[str, Any]:
    return {
        "type": "room_state",
        "room": room.code,
        "server_time": int(time.time()),
        "max_members": MAX_ROOM_MEMBERS,
        "voice_floor": room.voice_floor(),
        "members": room.members(include_moderation_refs=include_moderation_refs),
    }


async def broadcast_room(room: Room, payload: dict[str, Any], exclude: str | None = None) -> None:
    peers = [peer for member_id, peer in room.peers.items() if member_id != exclude]
    await asyncio.gather(*(safe_send_json(peer, payload) for peer in peers), return_exceptions=True)


async def broadcast_room_state(room: Room) -> None:
    await asyncio.gather(
        *(
            safe_send_json(
                peer,
                room_state(room, include_moderation_refs=peer.role == "app"),
            )
            for peer in list(room.peers.values())
        ),
        return_exceptions=True,
    )


def reminder_response_fields(reminder: dict[str, Any], duplicate: bool) -> dict[str, Any]:
    return {
        "event_id": str(reminder.get("event_id") or ""),
        "request_id": str(reminder.get("request_id") or ""),
        "room_code": str(reminder.get("room_code") or ""),
        "recipient_count": int(reminder.get("recipient_count") or 0),
        "online_delivered": int(reminder.get("online_delivered") or 0),
        "push_status": str(reminder.get("push_status") or "unknown"),
        "cooldown_seconds": RADAR_REMINDER_COOLDOWN_SECONDS,
        "server_time": int(reminder.get("server_time") or time.time()),
        "duplicate": duplicate,
    }


def aggregate_radar_reminder_push_status(results: list[dict[str, Any]]) -> str:
    statuses = [str(result.get("status") or "failed") for result in results]
    if not statuses or all(status == "skipped" for status in statuses):
        return "skipped"
    if all(status == "dry_run" for status in statuses):
        return "dry_run"
    if all(status == "sent" for status in statuses):
        return "sent"
    if any(status in {"sent", "partial"} for status in statuses):
        return "partial"
    if all(status == "failed" for status in statuses):
        return "failed"
    return "partial"


def planned_radar_reminder_push_status() -> str:
    if push_notifications.config.mode == "disabled":
        return "skipped"
    if push_notifications.config.mode == "dry_run":
        return "dry_run"
    return "pending"


async def deliver_radar_reminder_to_users(
    room_code: str,
    target_user_ids: set[str],
    reminder: dict[str, Any],
    sender_name: str,
) -> set[str]:
    room = rooms.get(room_code)
    if room is None or not target_user_ids:
        return set()
    targets = [
        peer
        for peer in room.peers.values()
        if peer.role == "app" and peer.user_id in target_user_ids
    ]
    anticipated_users = {peer.user_id for peer in targets}
    event = {
        "type": "radar_reminder",
        **reminder_response_fields(reminder, duplicate=False),
        "online_delivered": len(anticipated_users),
        "sender_name": sender_name[:40],
        "action": "open_radar",
    }
    results = await asyncio.gather(
        *(send_json(peer, event) for peer in targets),
        return_exceptions=True,
    )
    delivered_users = {
        peer.user_id
        for peer, result in zip(targets, results)
        if not isinstance(result, BaseException)
    }
    return delivered_users


async def disconnect_user_sessions(user_id: str) -> int:
    clean_user_id = user_id.strip()
    if not clean_user_id:
        return 0
    targets = [
        peer
        for room in rooms.values()
        for peer in room.peers.values()
        if peer.user_id == clean_user_id
    ]
    if not targets:
        return 0
    await asyncio.gather(
        *(peer.socket.close(code=1000, reason="account_deleted") for peer in targets),
        return_exceptions=True,
    )
    return len(targets)


async def disconnect_room_user_sessions(
    room_code: str,
    user_id: str,
    reason: str = "room_membership_removed",
) -> int:
    clean_room_code = normalize_room_code(room_code)
    clean_user_id = user_id.strip()
    live_room = rooms.get(clean_room_code)
    if not clean_user_id or live_room is None:
        return 0

    targets = [peer for peer in live_room.peers.values() if peer.user_id == clean_user_id]
    if not targets:
        return 0

    close_reason = reason.strip()[:120] or "room_membership_removed"
    close_tasks = [
        asyncio.create_task(peer.socket.close(code=1008, reason=close_reason))
        for peer in targets
    ]
    target_member_ids = {peer.member_id for peer in targets}
    target_group_ids = {peer.group_id for peer in targets}
    for member_id in target_member_ids:
        live_room.peers.pop(member_id, None)
    if live_room.speaker_group_id in target_group_ids:
        live_room.speaker_group_id = ""
        live_room.speaker_peer_id = ""
        live_room.speaker_until = 0.0
    for pending_key in list(pending_room_switches):
        if pending_key[0] == clean_room_code and pending_key[2] == clean_user_id:
            pending_room_switches.pop(pending_key, None)

    if live_room.peers:
        await broadcast_room_state(live_room)
    else:
        rooms.pop(clean_room_code, None)
    await asyncio.gather(*close_tasks, return_exceptions=True)
    return len(targets)


async def disconnect_block_effect_sessions(
    effects: list[dict[str, str]],
) -> list[dict[str, Any]]:
    public_effects: list[dict[str, Any]] = []
    for effect in effects:
        room_code = normalize_room_code(str(effect.get("room_code") or ""))
        disconnected = await disconnect_room_user_sessions(
            room_code,
            str(effect.get("disconnected_user_id") or ""),
            reason="blocked_relationship",
        )
        public_effects.append(
            {
                "room_code": room_code,
                "action": str(effect.get("action") or ""),
                "disconnected_connections": disconnected,
            }
        )
    return public_effects


def run_on_relay_loop(coroutine: Any, default: Any) -> Any:
    loop = relay_asyncio_loop
    if loop is None or not loop.is_running():
        close = getattr(coroutine, "close", None)
        if callable(close):
            close()
        return default
    future = asyncio.run_coroutine_threadsafe(coroutine, loop)
    try:
        return future.result(timeout=2.0)
    except Exception:
        future.cancel()
        return default


def room_switch_event(peer: Peer, message: dict[str, Any]) -> dict[str, Any]:
    request_id = str(message.get("request_id") or "").strip()[:96]
    target_room = normalize_room_code(str(message.get("room_token") or ""))
    configured_relay_url = os.environ.get("DRAGON_RADAR_PUBLIC_RELAY_URL", "").strip().rstrip("/")
    requested_relay_url = str(message.get("relay_url") or "").strip().rstrip("/")
    relay_url = configured_relay_url
    if not relay_url and apple_identity_verifier.development_auth_allowed():
        parsed_relay_url = urlparse(requested_relay_url)
        if parsed_relay_url.scheme in {"ws", "wss"} and parsed_relay_url.hostname:
            relay_url = requested_relay_url
    if not relay_url:
        raise PermissionError("relay_public_url_not_configured")
    return {
        "type": "relay_event",
        "room": peer.room,
        "from": peer.peer_id,
        "role": peer.role,
        "event": "room_switch",
        "payload": {
            "type": "room_switch",
            "request_id": request_id,
            "relay_url": relay_url,
            "room_token": target_room,
        },
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


def connected_device_peers_for_group(room_code: str, group_id: str, user_id: str) -> list[Peer]:
    room = rooms.get(normalize_room_code(room_code))
    if room is None:
        return []
    return [
        candidate
        for candidate in room.peers.values()
        if candidate.role == "device"
        and candidate.group_id == group_id
        and candidate.user_id == user_id
    ]


async def deliver_room_switch_to_group(
    room_code: str,
    group_id: str,
    user_id: str,
    payload: dict[str, Any],
) -> int:
    targets = connected_device_peers_for_group(room_code, group_id, user_id)
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
    if store is None:
        raise PermissionError("store_not_ready")
    user_id = ""
    credential = bearer_token_from_headers(socket.request_headers)
    if not credential and legacy_websocket_query_auth_allowed():
        credential = value_from_query(query, "token", "") or value_from_query(query, "device_token", "")
    room = normalize_room_code(value_from_query(query, "room", "DRGN-0001"))
    requested_app_id = value_from_query(query, "app_id", "")
    if role == "app":
        user_id = store.validate_access_token(credential) if credential else ""
        if not user_id:
            user_id = websocket_auth_tickets.consume(value_from_query(query, "ticket", ""))
        if not user_id:
            raise PermissionError("unauthorized")
        requested_identifier = (
            requested_app_id.removeprefix("app-")
            if requested_app_id.startswith("app-")
            else requested_app_id
        ).lower()
        owned_identifiers = store.active_relay_identifiers_for_user(user_id)
        if store.user_owns_relay_identifier(user_id, requested_identifier):
            group_id = requested_identifier
        elif len(owned_identifiers) == 1:
            # A stale Keychain token must not create a second room member when
            # the signed-in account has exactly one active radar binding.
            group_id = owned_identifiers[0]
        else:
            group_id = stable_relay_identifier(credential or user_id)
        app_id = f"app-{group_id}"
        device_id = ""
    else:
        device = store.validate_device_token(credential)
        if not device:
            if store.device_token_revoked(credential):
                raise PermissionError("device_revoked")
            raise PermissionError("unauthorized")
        user_id = str(device.get("owner_user_id") or "")
        group_id = stable_relay_identifier(credential)
        device_id = group_id
        app_id = ""
    if store.get_room(room) is None:
        raise PermissionError("invalid_room")
    if store.get_room_member_for_user(room, str(user_id or "")) is None:
        raise PermissionError("not_room_member")
    if store.room_has_block_conflict(room, str(user_id or "")):
        raise PermissionError("blocked_relationship")
    if role == "device":
        member_id = device_id or f"device-{id(socket):x}"
    else:
        member_id = app_id or f"app-{id(socket):x}"
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
                    actor_id=peer.user_id,
                    actor_role=peer.role,
                    group_id=peer.group_id,
                    detail={"speaker_group_id": room.speaker_group_id, "speaker_peer_id": room.speaker_peer_id},
                )
            notify_user(
                peer.user_id,
                "voice_busy",
                room.code,
                "胶囊抢麦失败",
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

    if store is None or store.get_room_member_for_user(peer.room, peer.user_id) is None:
        await safe_send_json(peer, {"type": "error", "code": "room_membership_removed"})
        await peer.socket.close(code=1008, reason="room_membership_removed")
        return

    try:
        message = sanitize_relay_message_names(message)
    except ValueError as exc:
        await send_json(peer, {"type": "error", "code": str(exc)})
        return

    message_type = message.get("type")
    peer.last_seen_at = time.time()
    if message_type in {"hello", "heartbeat"} and peer.role == "app" and store is not None:
        presence_name = message.get("name")
        if isinstance(presence_name, str):
            store.update_user_display_name(peer.user_id, presence_name)
    if message_type == "hello":
        compatible, client_protocol, required_protocol = protocol_compatible(peer, message)
        if not compatible:
            if store is not None:
                store.audit_event(
                    "protocol_unsupported",
                    room_code=peer.room,
                    actor_id=peer.user_id,
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

    if message_type == "ping":
        peer.last_payload = merge_last_payload(peer.last_payload, message)
        await send_json(peer, {"type": "pong", "server_time": int(time.time())})
        return

    if message_type == "room_switch":
        peer.last_payload = merge_last_payload(peer.last_payload, message)
        event = room_switch_event(peer, message)
        target_room = str((event.get("payload") or {}).get("room_token") or "")
        if store is None or store.get_room_member_for_user(target_room, peer.user_id) is None:
            await send_json(peer, {"type": "error", "code": "not_target_room_member"})
            return
        delivered = 0
        if peer.group_id:
            pending_key = (peer.room, peer.group_id, peer.user_id)
            pending_room_switches[pending_key] = event
            delivered = await deliver_room_switch_to_group(
                peer.room,
                peer.group_id,
                peer.user_id,
                event,
            )
            if delivered > 0:
                pending_room_switches.pop(pending_key, None)
        if store is not None:
            store.audit_event(
                "room_switch",
                room_code=room.code,
                actor_id=peer.user_id,
                actor_role=peer.role,
                group_id=peer.group_id,
                detail={
                    "request_id": message.get("request_id"),
                    "target_room": target_room,
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
            print(
                f"location room={room.code} group={peer.group_id} "
                f"peer={peer.peer_id} sequence={message.get('sequence')}",
                flush=True,
            )
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
                    actor_id=peer.user_id,
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

    room = rooms.setdefault(peer.room, Room(code=peer.room))
    existing_groups = {p.group_id for p in room.peers.values()}
    if peer.group_id not in existing_groups and len(existing_groups) >= MAX_ROOM_MEMBERS:
        if store is not None:
            store.audit_event(
                "room_full",
                room_code=peer.room,
                actor_id=peer.user_id,
                actor_role=peer.role,
                group_id=peer.group_id,
                detail={"max_members": MAX_ROOM_MEMBERS},
            )
        await socket.send(json_message({"type": "error", "code": "room_full", "max_members": MAX_ROOM_MEMBERS}))
        await socket.close(code=1008)
        return

    replaced_peer = room.peers.get(peer.member_id)
    if (
        replaced_peer is not None
        and replaced_peer is not peer
        and replaced_peer.role == peer.role
        and replaced_peer.group_id == peer.group_id
    ):
        # A foreground transition or overlapping reconnect can briefly create
        # two sockets with the same authenticated member id. Keep the newest
        # socket canonical, but carry the last trusted state forward so the
        # group does not lose its location while the replacement connects.
        peer.last_payload = dict(replaced_peer.last_payload)
        peer.last_location_at = replaced_peer.last_location_at
    room.peers[peer.member_id] = peer
    if replaced_peer is not None and replaced_peer is not peer:
        await safe_send_json(
            replaced_peer,
            {
                "type": "error",
                "code": "connection_replaced",
                "detail": "A newer connection for this member is active.",
            },
        )
        await replaced_peer.socket.close(code=1000, reason="connection_replaced")
        print(
            f"replace role={peer.role} room={peer.room} "
            f"group={peer.group_id} peer={peer.peer_id}",
            flush=True,
        )
    print(f"join role={peer.role} room={peer.room} group={peer.group_id} peer={peer.peer_id}", flush=True)
    if store is not None:
        store.audit_event(
            "ws_join",
            room_code=peer.room,
            actor_id=peer.user_id,
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
    pending_key = (peer.room, peer.group_id, peer.user_id)
    if peer.role == "device" and pending_key in pending_room_switches:
        pending_event = pending_room_switches.pop(pending_key)
        await safe_send_json(peer, pending_event)

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
                        actor_id=peer.user_id,
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
                        actor_id=peer.user_id,
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
                        actor_id=peer.user_id,
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
                "胶囊设备离线",
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
                actor_id=peer.user_id,
                actor_role=peer.role,
                group_id=peer.group_id,
            )


async def main_async(args: argparse.Namespace) -> None:
    global store, relay_asyncio_loop
    relay_asyncio_loop = asyncio.get_running_loop()
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
            print(f"胶囊 Relay listening on ws://{args.host}:{args.port}", flush=True)
            await stop
    finally:
        httpd.shutdown()
        relay_asyncio_loop = None


def main() -> int:
    args = parse_args()
    asyncio.run(main_async(args))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
