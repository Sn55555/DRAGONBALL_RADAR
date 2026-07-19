#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

from ota_release_common import (
    KEY_ID,
    SIGNATURE_ALGORITHM,
    OTAReleaseError,
    canonical_payload,
    check_esp_image,
    public_key_spki_sha256,
    sha256_file,
    sign_payload,
    verify_signature,
)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_FIRMWARE = ROOT / ".pio/build/radar-custom/firmware.bin"
DEFAULT_OUTPUT = ROOT / "output/ota-current"
DEFAULT_PRIVATE_KEY = ROOT / ".secrets/ota-signing-private.pem"
DEFAULT_PUBLIC_KEY = ROOT / ".secrets/ota-signing-public.pem"
DEFAULT_HARDWARE = "esp32-s3-touch-amoled-1.75c"
DEFAULT_MAX_SIZE = 8 * 1024 * 1024
DEFAULT_RETAIN_RELEASES = 3
RETAINED_RELEASES_DIR = "retained"
SAFE_RELEASE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,159}$")
PUBLIC_BUILD_METADATA_FIELDS = (
    "schema",
    "product",
    "hardware",
    "version",
    "build",
    "security_counter",
    "artifact",
    "size",
    "sha256",
    "ota_key_id",
    "ota_public_key_sha256",
    "ota_allow_http",
    "ota_root_ca_configured",
    "ota_root_ca_sha256",
    "release_build",
    "environment",
)
NOTICE_SOURCES = {
    "Arduino_GFX-BSD.txt": ROOT / "lib/GFX_Library_for_Arduino/license.txt",
    "Arduino_GFX-FONT-LICENSES.md": ROOT / "lib/GFX_Library_for_Arduino/FONT-LICENSES.md",
    "OFL-1.1.txt": ROOT / "lib/GFX_Library_for_Arduino/OFL-1.1.txt",
    "COPYING-UNIFONT.txt": ROOT / "lib/GFX_Library_for_Arduino/COPYING-UNIFONT.txt",
    "SensorLib-MIT.txt": ROOT / "lib/SensorLib/LICENSE",
    "LGPL-2.1.txt": ROOT / "lib/PLATFORMIO-RUNTIME-LICENSES/LGPL-2.1.txt",
    "Apache-2.0.txt": ROOT / "lib/PLATFORMIO-RUNTIME-LICENSES/Apache-2.0.txt",
    "ARDUINO-ESP32-BLE-NOTICE.txt": ROOT / "lib/PLATFORMIO-RUNTIME-LICENSES/ARDUINO-ESP32-BLE-NOTICE.txt",
    "LIBB64-PUBLIC-DOMAIN.txt": ROOT / "lib/PLATFORMIO-RUNTIME-LICENSES/LIBB64-PUBLIC-DOMAIN.txt",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build a signed Capsule OTA release directory.")
    parser.add_argument("--firmware", type=Path, default=DEFAULT_FIRMWARE, help="PlatformIO firmware.bin to package.")
    parser.add_argument(
        "--firmware-metadata",
        type=Path,
        default=None,
        help="Build sidecar JSON. Defaults to firmware-metadata.json beside firmware.bin.",
    )
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT, help="Release directory to create.")
    parser.add_argument("--private-key", type=Path, default=Path(os.environ.get("DRAGON_RADAR_OTA_PRIVATE_KEY", DEFAULT_PRIVATE_KEY)))
    parser.add_argument("--public-key", type=Path, default=Path(os.environ.get("DRAGON_RADAR_OTA_PUBLIC_KEY", DEFAULT_PUBLIC_KEY)))
    parser.add_argument("--product", default="dragon-radar")
    parser.add_argument("--hardware", default=DEFAULT_HARDWARE)
    parser.add_argument("--version", required=True, help="Numeric x.y.z version, for example 1.2.0.")
    parser.add_argument("--build", required=True, type=int, help="Monotonically increasing build number.")
    parser.add_argument(
        "--minimum-version",
        default="0.0.0",
        help="Oldest firmware allowed to install this release, in numeric x.y.z form.",
    )
    parser.add_argument(
        "--security-counter",
        required=True,
        type=int,
        help="Monotonic anti-downgrade counter; must be at least 1.",
    )
    parser.add_argument("--max-size", type=int, default=int(os.environ.get("DRAGON_RADAR_OTA_SLOT_SIZE", DEFAULT_MAX_SIZE)))
    parser.add_argument(
        "--retain-releases",
        type=int,
        default=int(os.environ.get("DRAGON_RADAR_OTA_RETAIN_RELEASES", DEFAULT_RETAIN_RELEASES)),
        help="Number of previous immutable releases to retain for in-flight Range retries (default: 3).",
    )
    parser.add_argument(
        "--allow-development-http",
        action="store_true",
        help="Allow packaging firmware compiled for HTTP development OTA. Stable releases reject it.",
    )
    parser.add_argument("--force", action="store_true", help="Atomically replace an existing output directory.")
    return parser.parse_args()


def safe_artifact_name(sha256: str) -> str:
    # Keep the BLE control envelope compact while making the URL fully
    # content-addressed. Version/build remain in the signed manifest.
    return f"{sha256}.bin"


def retained_release_sources(
    output_dir: Path,
    *,
    public_key: Path,
    max_size: int,
) -> list[tuple[str, Path, dict[str, object]]]:
    """Return validated previous releases that may safely be copied forward."""
    if not output_dir.exists():
        return []
    if not output_dir.is_dir() or output_dir.is_symlink():
        raise OTAReleaseError(f"existing output is not a regular directory: {output_dir}")

    # Import locally so the command-line verifier remains the single definition of
    # the offline archive checks without creating an import cycle at module load.
    from verify_ota_release import verify

    sources: list[tuple[str, Path, dict[str, object]]] = []
    if (output_dir / "manifest.json").exists():
        report = verify(output_dir, public_key, max_size)
        artifact_name = str(report["artifact"])
        if not SAFE_RELEASE_NAME.fullmatch(artifact_name):
            raise OTAReleaseError("existing release has an unsafe artifact name")
        sources.append((artifact_name, output_dir, report))

    retained_root = output_dir / RETAINED_RELEASES_DIR
    if not retained_root.exists():
        return sources
    if not retained_root.is_dir() or retained_root.is_symlink():
        raise OTAReleaseError(f"retained release store is not a regular directory: {retained_root}")
    for entry in retained_root.iterdir():
        if entry.name.startswith("."):
            continue
        if not SAFE_RELEASE_NAME.fullmatch(entry.name) or not entry.is_dir() or entry.is_symlink():
            raise OTAReleaseError(f"invalid retained release entry: {entry}")
        report = verify(entry, public_key, max_size)
        artifact_name = str(report["artifact"])
        if artifact_name != entry.name:
            raise OTAReleaseError(
                f"retained release directory must match its immutable artifact name: {entry.name}"
            )
        sources.append((artifact_name, entry, report))
    return sources


def copy_release_snapshot(source: Path, destination: Path, artifact_name: str) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    required_names = ("manifest.json", "build-metadata.json", artifact_name)
    optional_names = ("canonical.txt", "signature.der")
    for name in (*required_names, *optional_names):
        source_file = source / name
        if name in optional_names and not source_file.exists():
            continue
        if not source_file.is_file() or source_file.is_symlink():
            raise OTAReleaseError(f"release snapshot contains an unsafe or missing file: {source_file}")
        shutil.copyfile(source_file, destination / name)
    notice = source / "THIRD_PARTY_NOTICES.md"
    licenses = source / "licenses"
    if not notice.is_file() or notice.is_symlink() or not licenses.is_dir() or licenses.is_symlink():
        raise OTAReleaseError("release snapshot is missing its third-party notice bundle")
    shutil.copyfile(notice, destination / notice.name)
    shutil.copytree(licenses, destination / licenses.name)


def copy_notice_bundle(destination: Path) -> None:
    notice = ROOT / "THIRD_PARTY_NOTICES.md"
    if not notice.is_file() or notice.is_symlink():
        raise OTAReleaseError(f"third-party notice is missing or unsafe: {notice}")
    licenses = destination / "licenses"
    licenses.mkdir()
    shutil.copyfile(notice, destination / notice.name)
    for output_name, source in NOTICE_SOURCES.items():
        if not source.is_file() or source.is_symlink() or source.stat().st_size == 0:
            raise OTAReleaseError(f"required license is missing or unsafe: {source}")
        shutil.copyfile(source, licenses / output_name)


def load_firmware_metadata(path: Path) -> dict[str, object]:
    try:
        decoded = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise OTAReleaseError(
            f"firmware build metadata is required and must be valid JSON: {path}: {exc}"
        ) from exc
    if not isinstance(decoded, dict):
        raise OTAReleaseError("firmware build metadata must be a JSON object")
    return decoded


def verify_compiled_metadata(
    metadata: dict[str, object],
    *,
    metadata_path: Path,
    firmware: Path,
    product: str,
    hardware: str,
    version: str,
    build: int,
    security_counter: int,
    size: int,
    sha256: str,
    ota_public_key_sha256: str,
    allow_development_http: bool,
) -> None:
    expected: dict[str, object] = {
        "schema": 1,
        "product": product,
        "hardware": hardware,
        "version": version,
        "build": build,
        "security_counter": security_counter,
        "artifact": firmware.name,
        "size": size,
        "sha256": sha256,
        "ota_key_id": KEY_ID,
        "ota_public_key_sha256": ota_public_key_sha256,
    }
    for field_name, expected_value in expected.items():
        actual = metadata.get(field_name)
        if isinstance(expected_value, int) and isinstance(actual, bool):
            actual = None
        if actual != expected_value:
            raise OTAReleaseError(
                "firmware build metadata mismatch for "
                f"{field_name}: compiled={actual!r} release={expected_value!r} ({metadata_path})"
            )
    ota_allow_http = metadata.get("ota_allow_http")
    release_build = metadata.get("release_build")
    root_ca_configured = metadata.get("ota_root_ca_configured")
    root_ca_sha256 = metadata.get("ota_root_ca_sha256")
    if not isinstance(ota_allow_http, bool):
        raise OTAReleaseError("firmware build metadata ota_allow_http must be boolean")
    if not isinstance(release_build, bool):
        raise OTAReleaseError("firmware build metadata release_build must be boolean")
    if not isinstance(root_ca_configured, bool):
        raise OTAReleaseError("firmware build metadata ota_root_ca_configured must be boolean")
    if not isinstance(root_ca_sha256, str):
        raise OTAReleaseError("firmware build metadata ota_root_ca_sha256 must be text")
    environment = metadata.get("environment")
    if not isinstance(environment, str) or not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", environment):
        raise OTAReleaseError("firmware build metadata environment must be a safe identifier")
    if root_ca_configured:
        if not re.fullmatch(r"[0-9a-f]{64}", root_ca_sha256):
            raise OTAReleaseError("configured OTA root CA must have a lowercase SHA-256 fingerprint")
    elif root_ca_sha256:
        raise OTAReleaseError("OTA root CA fingerprint must be empty when no root CA is configured")
    if not root_ca_configured and not ota_allow_http:
        raise OTAReleaseError("firmware cannot use OTA: neither a root CA nor development HTTP is configured")
    if ota_allow_http and not allow_development_http:
        raise OTAReleaseError(
            "firmware enables development HTTP; pass --allow-development-http only for local testing"
        )
    if allow_development_http:
        if release_build:
            raise OTAReleaseError("development HTTP packaging requires a non-release firmware build")
        if not ota_allow_http:
            raise OTAReleaseError("--allow-development-http requires firmware compiled with HTTP enabled")
    elif not release_build:
        raise OTAReleaseError("stable OTA packaging requires firmware built with RADAR_RELEASE=1")
    elif environment != "field":
        raise OTAReleaseError("stable OTA packaging requires the field firmware environment")


def package(args: argparse.Namespace) -> Path:
    firmware = args.firmware.expanduser().resolve()
    configured_metadata = getattr(args, "firmware_metadata", None)
    metadata_path = (
        configured_metadata.expanduser().resolve()
        if configured_metadata is not None
        else firmware.with_name("firmware-metadata.json")
    )
    output_dir = args.output_dir.expanduser().resolve()
    private_key = args.private_key.expanduser().resolve()
    public_key = args.public_key.expanduser().resolve()
    if not firmware.is_file():
        raise OTAReleaseError(f"firmware image is missing: {firmware}")
    check_esp_image(firmware)
    size = firmware.stat().st_size
    if args.max_size <= 0 or size > args.max_size:
        raise OTAReleaseError(f"firmware image is {size} bytes; OTA slot limit is {args.max_size} bytes")
    firmware_sha256 = sha256_file(firmware)
    ota_public_key_sha256 = public_key_spki_sha256(public_key)
    compiled_metadata = load_firmware_metadata(metadata_path)
    verify_compiled_metadata(
        compiled_metadata,
        metadata_path=metadata_path,
        firmware=firmware,
        product=args.product,
        hardware=args.hardware,
        version=args.version,
        build=args.build,
        security_counter=args.security_counter,
        size=size,
        sha256=firmware_sha256,
        ota_public_key_sha256=ota_public_key_sha256,
        allow_development_http=bool(getattr(args, "allow_development_http", False)),
    )
    retain_releases = int(getattr(args, "retain_releases", DEFAULT_RETAIN_RELEASES))
    if retain_releases < 0:
        raise OTAReleaseError("--retain-releases must be at least 0")
    artifact_name = safe_artifact_name(firmware_sha256)
    metadata = {
        "schema": 1,
        "product": args.product,
        "hardware": args.hardware,
        "version": args.version,
        "build": args.build,
        "minimum_version": args.minimum_version,
        "security_counter": args.security_counter,
        "size": size,
        "sha256": firmware_sha256,
    }
    canonical = canonical_payload(metadata)
    signature = sign_payload(canonical, private_key)
    verify_signature(canonical, signature, public_key)
    manifest = {
        **metadata,
        "artifact": artifact_name,
        "created_at": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "signature_algorithm": SIGNATURE_ALGORITHM,
        "key_id": KEY_ID,
        "signed_payload": canonical.decode("utf-8"),
        "signature": base64.b64encode(signature).decode("ascii"),
    }
    public_build_metadata = {field: compiled_metadata[field] for field in PUBLIC_BUILD_METADATA_FIELDS}

    previous_sources = retained_release_sources(
        output_dir,
        public_key=public_key,
        max_size=args.max_size,
    )
    for _, _, report in previous_sources:
        if report.get("sha256") != firmware_sha256:
            continue
        expected_identity = (
            args.product,
            args.hardware,
            args.version,
            args.build,
            args.security_counter,
        )
        published_identity = (
            report.get("product"),
            report.get("hardware"),
            report.get("version"),
            report.get("build"),
            report.get("security_counter"),
        )
        if published_identity != expected_identity:
            raise OTAReleaseError(
                "an immutable firmware digest is already bound to a different release identity"
            )
    different_previous = [
        report
        for _, _, report in previous_sources
        if report.get("sha256") != firmware_sha256
    ]
    if different_previous:
        highest_build = max(int(report["build"]) for report in different_previous)
        if args.build <= highest_build:
            raise OTAReleaseError(
                f"new build must be greater than every published build ({args.build} <= {highest_build})"
            )
        highest_security_counter = max(
            int(report["security_counter"]) for report in different_previous
        )
        if args.security_counter < highest_security_counter:
            raise OTAReleaseError(
                "new security_counter must not be lower than any published release "
                f"({args.security_counter} < {highest_security_counter})"
            )
        new_version = tuple(int(component) for component in args.version.split("."))
        highest_version = max(
            tuple(int(component) for component in str(report["version"]).split("."))
            for report in different_previous
        )
        if new_version < highest_version:
            raise OTAReleaseError(
                "new version must not be lower than any published release "
                f"({args.version} < {'.'.join(map(str, highest_version))})"
            )
    unique_previous: dict[str, tuple[Path, dict[str, object]]] = {}
    for previous_name, previous_source, previous_report in previous_sources:
        if previous_name == artifact_name:
            if previous_report.get("sha256") != firmware_sha256:
                raise OTAReleaseError(
                    f"immutable artifact name collision with a different digest: {artifact_name}"
                )
            continue
        existing = unique_previous.get(previous_name)
        if existing is not None and existing[1].get("sha256") != previous_report.get("sha256"):
            raise OTAReleaseError(
                f"retained immutable artifact collision with a different digest: {previous_name}"
            )
        unique_previous[previous_name] = (previous_source, previous_report)
    retained = sorted(
        unique_previous.items(),
        key=lambda item: (
            int(item[1][1].get("build") or 0),
            int(item[1][1].get("security_counter") or 0),
            item[0],
        ),
        reverse=True,
    )[:retain_releases]

    if output_dir.exists() and not args.force:
        raise OTAReleaseError(f"output directory exists; pass --force to replace it: {output_dir}")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.", dir=output_dir.parent))
    previous = output_dir.with_name(output_dir.name + ".previous")
    moved_previous = False
    try:
        shutil.copyfile(firmware, temporary / artifact_name)
        (temporary / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        (temporary / "canonical.txt").write_bytes(canonical)
        (temporary / "signature.der").write_bytes(signature)
        (temporary / "build-metadata.json").write_text(
            json.dumps(public_build_metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        copy_notice_bundle(temporary)
        if retained:
            retained_root = temporary / RETAINED_RELEASES_DIR
            retained_root.mkdir()
            for retained_name, (retained_source, _) in retained:
                copy_release_snapshot(
                    retained_source,
                    retained_root / retained_name,
                    retained_name,
                )
        if previous.exists():
            shutil.rmtree(previous)
        if output_dir.exists():
            output_dir.replace(previous)
            moved_previous = True
        try:
            temporary.replace(output_dir)
        except Exception:
            if moved_previous and previous.exists() and not output_dir.exists():
                previous.replace(output_dir)
            raise
        if previous.exists():
            shutil.rmtree(previous)
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
    return output_dir


def main() -> int:
    args = parse_args()
    try:
        output = package(args)
    except OTAReleaseError as exc:
        print(f"ota-package-error: {exc}", file=os.sys.stderr)
        return 1
    print(f"ota-release-packaged {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
