#!/usr/bin/env python3
from __future__ import annotations

import base64
import binascii
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
from typing import Any


CANONICAL_FIELDS = (
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
CANONICAL_PREFIX = "dragon-radar-ota-v1"
SIGNATURE_ALGORITHM = "ecdsa-p256-sha256"
KEY_ID = "local-2026-01"
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$")
SAFE_IDENTIFIER = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
VERSION_COMPONENT_MAX = 0xFFFFFFFF


class OTAReleaseError(ValueError):
    pass


def numeric_version_valid(value: object) -> bool:
    return (
        isinstance(value, str)
        and SEMVER.fullmatch(value) is not None
        and all(int(component) <= VERSION_COMPONENT_MAX for component in value.split("."))
    )


def require_manifest_fields(manifest: dict[str, Any]) -> None:
    for field_name in CANONICAL_FIELDS:
        if field_name not in manifest:
            raise OTAReleaseError(f"manifest missing {field_name}")
    if manifest["schema"] != 1:
        raise OTAReleaseError("schema must be 1")
    for field_name in ("schema", "build", "security_counter", "size"):
        value = manifest[field_name]
        if isinstance(value, bool) or not isinstance(value, int):
            raise OTAReleaseError(f"{field_name} must be an integer")
    if not 1 <= manifest["build"] <= VERSION_COMPONENT_MAX:
        raise OTAReleaseError("build must be in 1...4294967295")
    if not 1 <= manifest["security_counter"] <= VERSION_COMPONENT_MAX:
        raise OTAReleaseError("security_counter must be in 1...4294967295")
    if manifest["size"] <= 0:
        raise OTAReleaseError("size must be greater than zero")
    for field_name in ("product", "hardware"):
        value = manifest[field_name]
        if not isinstance(value, str) or not SAFE_IDENTIFIER.fullmatch(value):
            raise OTAReleaseError(f"invalid {field_name}")
    for field_name in ("version", "minimum_version"):
        value = manifest[field_name]
        if not numeric_version_valid(value):
            raise OTAReleaseError(f"invalid {field_name}")
    version_tuple = tuple(int(component) for component in manifest["version"].split("."))
    minimum_tuple = tuple(int(component) for component in manifest["minimum_version"].split("."))
    if version_tuple < minimum_tuple:
        raise OTAReleaseError("version must not be lower than minimum_version")
    digest = manifest["sha256"]
    if not isinstance(digest, str) or not SHA256.fullmatch(digest):
        raise OTAReleaseError("sha256 must be 64 lowercase hexadecimal characters")


def canonical_payload(manifest: dict[str, Any]) -> bytes:
    require_manifest_fields(manifest)
    lines = [CANONICAL_PREFIX]
    for field_name in CANONICAL_FIELDS:
        value = manifest[field_name]
        text = str(value)
        if "\n" in text or "\r" in text or "=" in text:
            raise OTAReleaseError(f"invalid canonical value for {field_name}")
        lines.append(f"{field_name}={text}")
    return "\n".join(lines).encode("utf-8")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_esp_image(path: Path) -> None:
    try:
        with path.open("rb") as handle:
            magic = handle.read(1)
    except OSError as exc:
        raise OTAReleaseError(f"cannot read firmware image: {exc}") from exc
    if magic != b"\xe9":
        raise OTAReleaseError("firmware image does not start with the ESP image magic byte 0xe9")


def check_p256_key(path: Path, *, public: bool) -> None:
    command = ["openssl", "pkey"]
    if public:
        command.append("-pubin")
    command.extend(["-in", str(path), "-text_pub", "-noout"])
    try:
        completed = subprocess.run(command, capture_output=True, check=False)
    except OSError as exc:
        raise OTAReleaseError("openssl is required for OTA signing and verification") from exc
    if completed.returncode != 0:
        raise OTAReleaseError(f"invalid {'public' if public else 'private'} key: {path}")
    if b"prime256v1" not in completed.stdout and b"NIST CURVE: P-256" not in completed.stdout:
        raise OTAReleaseError(f"OTA {'public' if public else 'private'} key must use P-256/prime256v1")


def public_key_spki_sha256(path: Path) -> str:
    check_p256_key(path, public=True)
    try:
        completed = subprocess.run(
            ["openssl", "pkey", "-pubin", "-in", str(path), "-pubout", "-outform", "DER"],
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        raise OTAReleaseError("openssl is required for OTA signing and verification") from exc
    if completed.returncode != 0 or not completed.stdout:
        raise OTAReleaseError(f"cannot normalize OTA public key as DER SPKI: {path}")
    return hashlib.sha256(completed.stdout).hexdigest()


def sign_payload(payload: bytes, private_key: Path) -> bytes:
    check_p256_key(private_key, public=False)
    try:
        completed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(private_key)],
            input=payload,
            capture_output=True,
            check=False,
        )
    except OSError as exc:
        raise OTAReleaseError("openssl is required for OTA signing and verification") from exc
    if completed.returncode != 0 or not completed.stdout:
        detail = completed.stderr.decode("utf-8", errors="replace").strip()
        raise OTAReleaseError(f"failed to sign OTA manifest: {detail or 'openssl error'}")
    return completed.stdout


def signature_bytes(manifest: dict[str, Any]) -> bytes:
    if manifest.get("signature_algorithm") != SIGNATURE_ALGORITHM:
        raise OTAReleaseError(f"signature_algorithm must be {SIGNATURE_ALGORITHM}")
    if manifest.get("key_id") != KEY_ID:
        raise OTAReleaseError(f"key_id must be {KEY_ID}")
    encoded = manifest.get("signature")
    if not isinstance(encoded, str):
        raise OTAReleaseError("signature must be standard base64 text")
    try:
        signature = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise OTAReleaseError("signature must be valid standard base64") from exc
    if not signature:
        raise OTAReleaseError("signature must not be empty")
    return signature


def verify_signature(payload: bytes, signature: bytes, public_key: Path) -> None:
    check_p256_key(public_key, public=True)
    signature_path = ""
    try:
        with tempfile.NamedTemporaryFile(prefix="dragon-radar-ota-", suffix=".sig", delete=False) as handle:
            handle.write(signature)
            signature_path = handle.name
        try:
            completed = subprocess.run(
                [
                    "openssl",
                    "dgst",
                    "-sha256",
                    "-verify",
                    str(public_key),
                    "-signature",
                    signature_path,
                ],
                input=payload,
                capture_output=True,
                check=False,
            )
        except OSError as exc:
            raise OTAReleaseError("openssl is required for OTA signing and verification") from exc
    finally:
        if signature_path:
            Path(signature_path).unlink(missing_ok=True)
    if completed.returncode != 0:
        raise OTAReleaseError("OTA manifest signature verification failed")


def load_manifest(path: Path) -> dict[str, Any]:
    try:
        decoded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise OTAReleaseError(f"cannot read manifest: {exc}") from exc
    if not isinstance(decoded, dict):
        raise OTAReleaseError("manifest must be a JSON object")
    return decoded


def resolve_artifact(release_dir: Path, manifest: dict[str, Any]) -> Path:
    artifact = manifest.get("artifact")
    if not isinstance(artifact, str) or not SAFE_NAME.fullmatch(artifact):
        raise OTAReleaseError("manifest artifact must be a safe basename")
    release_dir = release_dir.resolve()
    path = (release_dir / artifact).resolve()
    if path.parent != release_dir or path.name != artifact:
        raise OTAReleaseError("manifest artifact escapes the release directory")
    if not path.is_file():
        raise OTAReleaseError(f"firmware artifact is missing: {artifact}")
    return path
