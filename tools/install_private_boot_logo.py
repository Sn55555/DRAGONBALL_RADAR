#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PRIVATE_LOGO = ROOT / "firmware" / "DragonRadar" / "private_boot_logo.h"
PRIVATE_EXAMPLE = ROOT / "firmware" / "DragonRadar" / "private_boot_logo.h.example"
GITIGNORE = ROOT / ".gitignore"
PLATFORMIO = ROOT / "platformio.ini"
BUILD_HELPER = ROOT / "tools" / "build_radar.sh"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Install or inspect the local-only Dragon Radar private boot logo hook."
    )
    parser.add_argument(
        "action",
        nargs="?",
        choices=("status", "install-example"),
        default="status",
        help="status only inspects; install-example copies the public example into the ignored private source.",
    )
    parser.add_argument("--force", action="store_true", help="Overwrite an existing private_boot_logo.h.")
    parser.add_argument("--dry-run", action="store_true", help="Report the intended copy without writing.")
    parser.add_argument("--json-output", default=None, help="Optional JSON report path.")
    parser.add_argument("--md-output", default=None, help="Optional Markdown report path.")
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


def add_check(checks: list[dict[str, Any]], name: str, passed: bool, evidence: str) -> None:
    checks.append({
        "name": name,
        "status": "passed" if passed else "failed",
        "evidence": evidence,
    })


def copy_private_example(args: argparse.Namespace) -> dict[str, Any]:
    result = {
        "changed": False,
        "planned": False,
        "message": "status only",
    }
    if args.action != "install-example":
        return result
    if not PRIVATE_EXAMPLE.exists():
        result["message"] = f"missing {rel(PRIVATE_EXAMPLE)}"
        return result
    if PRIVATE_LOGO.exists() and not args.force:
        result["message"] = "existing private_boot_logo.h preserved; pass --force to overwrite"
        return result

    result["planned"] = True
    result["message"] = f"copy {rel(PRIVATE_EXAMPLE)} -> {rel(PRIVATE_LOGO)}"
    if args.dry_run:
        return result

    PRIVATE_LOGO.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PRIVATE_EXAMPLE, PRIVATE_LOGO)
    result["changed"] = True
    result["message"] = f"installed {rel(PRIVATE_LOGO)} from example"
    return result


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    action_result = copy_private_example(args)
    checks: list[dict[str, Any]] = []
    gitignore_text = read_text(GITIGNORE)
    platformio_text = read_text(PLATFORMIO)
    build_helper_text = read_text(BUILD_HELPER)

    source_ignored = "firmware/DragonRadar/private_boot_logo.h" in gitignore_text
    build_flag_enabled = "-DUSE_PRIVATE_BOOT_LOGO=1" in platformio_text and "-DUSE_PRIVATE_BOOT_LOGO=1" in build_helper_text

    add_check(
        checks,
        "public.example-present",
        PRIVATE_EXAMPLE.exists(),
        rel(PRIVATE_EXAMPLE) if PRIVATE_EXAMPLE.exists() else "missing",
    )
    add_check(
        checks,
        "private.source-present",
        PRIVATE_LOGO.exists(),
        rel(PRIVATE_LOGO) if PRIVATE_LOGO.exists() else "missing; run tools/install_private_boot_logo.py install-example",
    )
    add_check(
        checks,
        "private.source-ignored",
        source_ignored,
        rel(GITIGNORE),
    )
    add_check(
        checks,
        "build.private-logo-enabled",
        build_flag_enabled,
        f"{rel(PLATFORMIO)}, {rel(BUILD_HELPER)}",
    )
    add_check(
        checks,
        "report.private-content-not-included",
        True,
        "report records paths/status only, not private source contents",
    )
    if args.action == "install-example":
        install_ok = bool(PRIVATE_EXAMPLE.exists() and (PRIVATE_LOGO.exists() or args.dry_run))
        add_check(checks, "action.install-example-safe", install_ok, str(action_result["message"]))

    status = "passed" if all(item["status"] == "passed" for item in checks) else "failed"
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "action": args.action,
        "sourceRoot": str(ROOT),
        "summary": {
            "privateSourcePath": rel(PRIVATE_LOGO),
            "privateSourceExists": PRIVATE_LOGO.exists(),
            "privateSourceIgnored": source_ignored,
            "examplePath": rel(PRIVATE_EXAMPLE),
            "exampleExists": PRIVATE_EXAMPLE.exists(),
            "buildFlagEnabled": build_flag_enabled,
            "changed": bool(action_result["changed"]),
            "planned": bool(action_result["planned"]),
            "dryRun": bool(args.dry_run),
            "force": bool(args.force),
            "safeToShare": True,
            "statusCommand": "tools/install_private_boot_logo.py status",
            "installCommand": "tools/install_private_boot_logo.py install-example",
        },
        "actionResult": action_result,
        "checks": checks,
        "failures": [item for item in checks if item["status"] != "passed"],
    }


def render_markdown(report: dict[str, Any]) -> str:
    summary = report["summary"]
    lines = [
        "# Dragon Radar Private Boot Logo Setup",
        "",
        f"- Generated: {report['generated']}",
        f"- Status: {report['status'].upper()}",
        f"- Action: {report['action']}",
        f"- Private source exists: {summary['privateSourceExists']}",
        f"- Private source ignored by git: {summary['privateSourceIgnored']}",
        f"- Build flag enabled: {summary['buildFlagEnabled']}",
        f"- Safe to share report: {summary['safeToShare']}",
        f"- Status command: `{summary['statusCommand']}`",
        f"- Install command: `{summary['installCommand']}`",
        "",
        "| Check | Status | Evidence |",
        "| --- | --- | --- |",
    ]
    for item in report["checks"]:
        lines.append(f"| {item['name']} | {item['status'].upper()} | {item['evidence']} |")
    lines.append("")
    lines.append("This report intentionally omits the private boot-logo source contents.")
    lines.append("")
    return "\n".join(lines)


def write_outputs(report: dict[str, Any], args: argparse.Namespace) -> None:
    if args.json_output:
        output = Path(args.json_output)
        if not output.is_absolute():
            output = ROOT / output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    if args.md_output:
        output = Path(args.md_output)
        if not output.is_absolute():
            output = ROOT / output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(render_markdown(report), encoding="utf-8")


def main() -> int:
    args = parse_args()
    report = build_report(args)
    write_outputs(report, args)
    print(f"PRIVATE_BOOT_LOGO_SETUP {report['status']}")
    print(f"ACTION {report['action']}")
    print(f"PRIVATE_SOURCE {report['summary']['privateSourceExists']}")
    print(f"CHANGED {report['summary']['changed']}")
    for failure in report["failures"]:
        print(f"FAIL {failure['name']}: {failure['evidence']}")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
