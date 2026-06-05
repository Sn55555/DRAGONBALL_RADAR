#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify the Dragon Radar private boot logo asset chain.")
    parser.add_argument("--json", default=None, help="Write JSON audit report.")
    parser.add_argument("--md", default=None, help="Write Markdown audit report.")
    parser.add_argument(
        "--release-dir",
        default=None,
        help="Optional release folder to verify for no private-source leak and packaged logo evidence.",
    )
    return parser.parse_args()


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def has_all(text: str, snippets: tuple[str, ...]) -> bool:
    return all(snippet in text for snippet in snippets)


def add_check(checks: list[dict[str, Any]], name: str, passed: bool, evidence: str) -> None:
    checks.append({
        "name": name,
        "status": "passed" if passed else "failed",
        "evidence": evidence,
    })


def firmware_blobs_contain(root: Path, needles: tuple[bytes, ...]) -> bool:
    firmware_dir = root / "firmware"
    if not firmware_dir.exists():
        return False
    for item in firmware_dir.glob("dragon-radar-*"):
        if not item.is_file() or item.suffix not in {".bin", ".elf"}:
            continue
        try:
            data = item.read_bytes()
        except OSError:
            continue
        if all(needle in data for needle in needles):
            return True
    return False


def build_audit(release_dir: Path | None) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []
    private_logo = ROOT / "firmware" / "DragonRadar" / "private_boot_logo.h"
    private_example = ROOT / "firmware" / "DragonRadar" / "private_boot_logo.h.example"
    sketch = ROOT / "firmware" / "DragonRadar" / "DragonRadar.ino"
    platformio = ROOT / "platformio.ini"
    build_helper = ROOT / "tools" / "build_radar.sh"
    installer = ROOT / "tools" / "install_private_boot_logo.py"
    gitignore = ROOT / ".gitignore"

    private_text = read_text(private_logo)
    example_text = read_text(private_example)
    sketch_text = read_text(sketch)
    platformio_text = read_text(platformio)
    build_helper_text = read_text(build_helper)
    installer_text = read_text(installer)
    gitignore_text = read_text(gitignore)

    add_check(
        checks,
        "local.private-logo-source-present",
        private_logo.exists(),
        rel(private_logo) if private_logo.exists() else "missing",
    )
    add_check(
        checks,
        "local.private-logo-rich-mark",
        has_all(private_text, (
            "drawPrivateBootLogo",
            "drawPrivateCapsuleShape",
            "CAPSULE",
            "CORP.",
            "privateLogoStep",
            "RGB565(0, 86, 220)",
        )),
        rel(private_logo),
    )
    add_check(
        checks,
        "local.private-logo-ignored",
        "firmware/DragonRadar/private_boot_logo.h" in gitignore_text,
        rel(gitignore),
    )
    add_check(
        checks,
        "public.private-logo-example-rich",
        has_all(example_text, (
            "drawPrivateBootLogo",
            "drawPrivateCapsuleShape",
            "CAPSULE",
            "CORP.",
            "Copy this file to private_boot_logo.h",
        )),
        rel(private_example),
    )
    add_check(
        checks,
        "firmware.private-logo-hook",
        has_all(sketch_text, (
            "USE_PRIVATE_BOOT_LOGO",
            '__has_include("private_boot_logo.h")',
            "drawPrivateBootLogo(gfx, kCx, kCy, logoPhase)",
            "drawDefaultBootLogo(logoPhase)",
        )),
        rel(sketch),
    )
    add_check(
        checks,
        "build.private-logo-enabled",
        "-DUSE_PRIVATE_BOOT_LOGO=1" in platformio_text and "-DUSE_PRIVATE_BOOT_LOGO=1" in build_helper_text,
        f"{rel(platformio)}, {rel(build_helper)}",
    )
    add_check(
        checks,
        "local.private-logo-installer",
        has_all(installer_text, (
            "install-example",
            "private.source-ignored",
            "report.private-content-not-included",
            "private_boot_logo.h.example",
        )),
        rel(installer),
    )

    release_summary: dict[str, Any] | None = None
    if release_dir is not None:
        if not release_dir.is_absolute():
            release_dir = ROOT / release_dir
        leaked = sorted(path for path in release_dir.rglob("private_boot_logo.h") if path.is_file()) if release_dir.exists() else []
        example_in_release = release_dir / "docs" / "private_boot_logo.h.example"
        release_example_text = read_text(example_in_release)
        release_has_logo_strings = firmware_blobs_contain(release_dir, (b"CAPSULE", b"CORP."))
        manifest_text = read_text(release_dir / "MANIFEST.md")
        release_summary = {
            "path": str(release_dir),
            "exists": release_dir.exists(),
            "privateSourceLeaked": bool(leaked),
            "leakedPaths": [path.relative_to(release_dir).as_posix() for path in leaked] if release_dir.exists() else [],
            "examplePresent": example_in_release.exists(),
            "firmwareContainsLogoText": release_has_logo_strings,
        }
        add_check(
            checks,
            "release.folder-present",
            release_dir.exists(),
            str(release_dir),
        )
        add_check(
            checks,
            "release.private-source-not-copied",
            release_dir.exists() and not leaked,
            ", ".join(release_summary["leakedPaths"]) if leaked else "no private_boot_logo.h found in release",
        )
        add_check(
            checks,
            "release.private-logo-example-present",
            has_all(release_example_text, ("drawPrivateBootLogo", "CAPSULE", "CORP.")),
            example_in_release.relative_to(release_dir).as_posix() if example_in_release.exists() else "missing",
        )
        add_check(
            checks,
            "release.firmware-logo-text-present",
            release_has_logo_strings,
            "one packaged firmware binary/ELF contains CAPSULE and CORP. boot-logo text",
        )
        add_check(
            checks,
            "release.manifest-logo-boundary",
            "private Capsule-style boot artwork source is intentionally not copied" in manifest_text,
            "MANIFEST.md documents private-source boundary",
        )

    status = "passed" if all(item["status"] == "passed" for item in checks) else "failed"
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "sourceRoot": str(ROOT),
        "release": release_summary,
        "summary": {
            "localPrivateSource": "present" if private_logo.exists() else "missing",
            "privateSourceIgnored": "firmware/DragonRadar/private_boot_logo.h" in gitignore_text,
            "buildFlagEnabled": "-DUSE_PRIVATE_BOOT_LOGO=1" in platformio_text and "-DUSE_PRIVATE_BOOT_LOGO=1" in build_helper_text,
            "installerPresent": installer.exists(),
            "releasePrivateSourceLeaked": bool(release_summary and release_summary["privateSourceLeaked"]),
        },
        "checks": checks,
        "failures": [item for item in checks if item["status"] != "passed"],
    }


def render_markdown(audit: dict[str, Any]) -> str:
    lines = [
        "# Dragon Radar Private Boot Logo Audit",
        "",
        f"- Generated: {audit['generated']}",
        f"- Status: {audit['status'].upper()}",
        f"- Local private source: {audit['summary']['localPrivateSource']}",
        f"- Private source ignored by git: {audit['summary']['privateSourceIgnored']}",
        f"- Build flag enabled: {audit['summary']['buildFlagEnabled']}",
        f"- Installer present: {audit['summary']['installerPresent']}",
        f"- Release private source leaked: {audit['summary']['releasePrivateSourceLeaked']}",
        "",
        "| Check | Status | Evidence |",
        "| --- | --- | --- |",
    ]
    for item in audit["checks"]:
        lines.append(f"| {item['name']} | {item['status'].upper()} | {item['evidence']} |")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    release_dir = Path(args.release_dir) if args.release_dir else None
    audit = build_audit(release_dir)

    if args.json:
        json_path = Path(args.json)
        if not json_path.is_absolute():
            json_path = ROOT / json_path
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")
    if args.md:
        md_path = Path(args.md)
        if not md_path.is_absolute():
            md_path = ROOT / md_path
        md_path.parent.mkdir(parents=True, exist_ok=True)
        md_path.write_text(render_markdown(audit), encoding="utf-8")

    print(f"PRIVATE_BOOT_LOGO {audit['status']}")
    print(f"CHECKS {len(audit['checks'])}")
    for failure in audit["failures"]:
        print(f"FAIL {failure['name']}: {failure['evidence']}")
    return 0 if audit["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
