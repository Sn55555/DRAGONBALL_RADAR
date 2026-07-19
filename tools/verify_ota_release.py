#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re

from ota_release_common import (
    KEY_ID,
    OTAReleaseError,
    canonical_payload,
    check_esp_image,
    load_manifest,
    public_key_spki_sha256,
    resolve_artifact,
    sha256_file,
    signature_bytes,
    verify_signature,
)


ROOT = Path(__file__).resolve().parents[1]
RETAINED_RELEASES_DIR = "retained"
SAFE_RELEASE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$")
REQUIRED_NOTICE_FILES = frozenset(
    {
        "ARDUINO-ESP32-BLE-NOTICE.txt",
        "Apache-2.0.txt",
        "Arduino_GFX-BSD.txt",
        "Arduino_GFX-FONT-LICENSES.md",
        "COPYING-UNIFONT.txt",
        "LGPL-2.1.txt",
        "LIBB64-PUBLIC-DOMAIN.txt",
        "OFL-1.1.txt",
        "SensorLib-MIT.txt",
    }
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify a signed Capsule OTA release directory.")
    parser.add_argument("release_dir", nargs="?", type=Path, default=ROOT / "output/ota-current")
    parser.add_argument(
        "--public-key",
        type=Path,
        default=Path(os.environ.get("DRAGON_RADAR_OTA_PUBLIC_KEY", ROOT / ".secrets/ota-signing-public.pem")),
    )
    parser.add_argument("--max-size", type=int, default=int(os.environ.get("DRAGON_RADAR_OTA_SLOT_SIZE", 8 * 1024 * 1024)))
    parser.add_argument("--json", type=Path, default=None, help="Optional verification report path.")
    return parser.parse_args()


def verify(
    release_dir: Path,
    public_key: Path,
    max_size: int,
    *,
    include_retained: bool = True,
) -> dict[str, object]:
    release_dir = release_dir.expanduser().resolve()
    manifest_path = release_dir / "manifest.json"
    build_metadata_path = release_dir / "build-metadata.json"
    if manifest_path.is_symlink() or build_metadata_path.is_symlink():
        raise OTAReleaseError("release metadata files must not be symlinks")
    manifest = load_manifest(manifest_path)
    artifact = resolve_artifact(release_dir, manifest)
    if (release_dir / artifact.name).is_symlink():
        raise OTAReleaseError("firmware artifact must not be a symlink")
    check_esp_image(artifact)
    canonical = canonical_payload(manifest)
    if manifest.get("signed_payload") != canonical.decode("utf-8"):
        raise OTAReleaseError("signed_payload does not match the canonical fields")
    if artifact.stat().st_size != manifest["size"]:
        raise OTAReleaseError("artifact size does not match manifest")
    if max_size <= 0 or manifest["size"] > max_size:
        raise OTAReleaseError(f"artifact exceeds OTA slot limit of {max_size} bytes")
    if sha256_file(artifact) != manifest["sha256"]:
        raise OTAReleaseError("artifact sha256 does not match manifest")
    if artifact.name != f"{manifest['sha256']}.bin":
        raise OTAReleaseError("artifact name must be the full content SHA-256")
    signature = signature_bytes(manifest)
    verify_signature(canonical, signature, public_key.expanduser().resolve())
    canonical_file = release_dir / "canonical.txt"
    if canonical_file.exists() and canonical_file.read_bytes() != canonical:
        raise OTAReleaseError("canonical.txt does not match the manifest canonical payload")
    signature_file = release_dir / "signature.der"
    if signature_file.exists() and signature_file.read_bytes() != signature:
        raise OTAReleaseError("signature.der does not match the manifest signature")
    build_metadata = load_manifest(build_metadata_path)
    notice_path = release_dir / "THIRD_PARTY_NOTICES.md"
    licenses_path = release_dir / "licenses"
    if not notice_path.is_file() or notice_path.is_symlink() or notice_path.stat().st_size == 0:
        raise OTAReleaseError("release is missing THIRD_PARTY_NOTICES.md")
    if not licenses_path.is_dir() or licenses_path.is_symlink():
        raise OTAReleaseError("release is missing its licenses directory")
    license_entries = {
        entry.name
        for entry in licenses_path.iterdir()
        if entry.is_file() and not entry.is_symlink() and entry.stat().st_size > 0
    }
    if not REQUIRED_NOTICE_FILES.issubset(license_entries):
        missing = sorted(REQUIRED_NOTICE_FILES - license_entries)
        raise OTAReleaseError(f"release is missing required license files: {', '.join(missing)}")
    expected_metadata: dict[str, object] = {
        "schema": 1,
        "product": manifest["product"],
        "hardware": manifest["hardware"],
        "version": manifest["version"],
        "build": manifest["build"],
        "security_counter": manifest["security_counter"],
        "artifact": "firmware.bin",
        "size": manifest["size"],
        "sha256": manifest["sha256"],
        "ota_key_id": KEY_ID,
        "ota_public_key_sha256": public_key_spki_sha256(public_key.expanduser().resolve()),
    }
    for field_name, expected_value in expected_metadata.items():
        if build_metadata.get(field_name) != expected_value:
            raise OTAReleaseError(f"build-metadata.json mismatch for {field_name}")
    release_build = build_metadata.get("release_build")
    ota_allow_http = build_metadata.get("ota_allow_http")
    root_ca_configured = build_metadata.get("ota_root_ca_configured")
    root_ca_sha256 = build_metadata.get("ota_root_ca_sha256")
    environment = build_metadata.get("environment")
    if not all(isinstance(value, bool) for value in (release_build, ota_allow_http, root_ca_configured)):
        raise OTAReleaseError("build-metadata.json has invalid boolean policy fields")
    if not isinstance(root_ca_sha256, str) or not isinstance(environment, str):
        raise OTAReleaseError("build-metadata.json has invalid transport/environment fields")
    stable = (
        release_build is True
        and ota_allow_http is False
        and root_ca_configured is True
        and len(root_ca_sha256) == 64
        and all(character in "0123456789abcdef" for character in root_ca_sha256)
        and environment == "field"
    )
    development = (
        release_build is False
        and ota_allow_http is True
        and (
            (root_ca_configured is False and root_ca_sha256 == "")
            or (
                root_ca_configured is True
                and len(root_ca_sha256) == 64
                and all(character in "0123456789abcdef" for character in root_ca_sha256)
            )
        )
    )
    if not stable and not development:
        raise OTAReleaseError("build-metadata.json is neither a stable nor development OTA policy")
    retained_reports: list[dict[str, object]] = []
    retained_root = release_dir / RETAINED_RELEASES_DIR
    if include_retained and retained_root.exists():
        if not retained_root.is_dir() or retained_root.is_symlink():
            raise OTAReleaseError("retained release store must be a regular directory")
        for entry in sorted(retained_root.iterdir(), key=lambda path: path.name):
            if entry.name.startswith("."):
                continue
            if not SAFE_RELEASE_NAME.fullmatch(entry.name) or not entry.is_dir() or entry.is_symlink():
                raise OTAReleaseError(f"invalid retained release entry: {entry.name}")
            retained_report = verify(
                entry,
                public_key,
                max_size,
                include_retained=False,
            )
            if retained_report["artifact"] != entry.name:
                raise OTAReleaseError(
                    f"retained release directory does not match artifact: {entry.name}"
                )
            retained_reports.append(retained_report)

    return {
        "ok": True,
        "release_dir": str(release_dir),
        "artifact": artifact.name,
        "product": manifest["product"],
        "hardware": manifest["hardware"],
        "version": manifest["version"],
        "build": manifest["build"],
        "minimum_version": manifest["minimum_version"],
        "security_counter": manifest["security_counter"],
        "size": manifest["size"],
        "sha256": manifest["sha256"],
        "key_id": manifest["key_id"],
        "development": development,
        "third_party_notices": True,
        "retained_releases": retained_reports,
    }


def main() -> int:
    args = parse_args()
    try:
        report = verify(args.release_dir, args.public_key, args.max_size)
    except OTAReleaseError as exc:
        print(f"ota-verify-error: {exc}", file=os.sys.stderr)
        return 1
    if args.json is not None:
        output = args.json.expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "ota-release-ok"
        f" version={report['version']} build={report['build']}"
        f" security_counter={report['security_counter']} sha256={report['sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
