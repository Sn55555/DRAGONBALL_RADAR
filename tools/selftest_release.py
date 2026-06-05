#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODES = ("field", "fielddiag", "diag", "sim")
VALID_MODES = DEFAULT_MODES + ("near",)


def default_release_dir() -> Path:
    if (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir():
        return ROOT
    return ROOT / "output" / "release-current"


def default_output_dir() -> Path:
    if (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir():
        return ROOT / "evidence" / "release-selftest"
    return ROOT / "output" / "release-selftest-current"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Self-test a packaged Dragon Radar release without hardware.")
    parser.add_argument("release_dir", nargs="?", default=None, help="Release folder. Default: output/release-current or the copied release root.")
    parser.add_argument("--output-dir", default=None, help="Self-test output folder.")
    parser.add_argument("--modes", default=None, help="Expected firmware modes. Defaults to RELEASE_AUDIT.json or MANIFEST.md when available.")
    parser.add_argument("--mock-timeout", default=os.environ.get("RELEASE_SELFTEST_TIMEOUT", "8"), help="Mock DIAG timeout seconds, default: 8.")
    parser.add_argument("--skip-mock", action="store_true", help="Only verify package structure; do not run the mock board simulation.")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without writing reports.")
    return parser.parse_args()


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def normalize_path(value: str | None, fallback: Path) -> Path:
    path = Path(value) if value else fallback
    return path if path.is_absolute() else ROOT / path


def command_line(command: list[str]) -> str:
    return shlex.join(command)


def packaged_tool(release_dir: Path, name: str) -> Path:
    candidate = release_dir / "tools" / name
    if candidate.exists():
        return candidate
    return ROOT / "tools" / name


def run_step(name: str, command: list[str], log_file: Path | None, dry_run: bool) -> dict[str, Any]:
    print(f"+ {command_line(command)}", flush=True)
    record: dict[str, Any] = {
        "name": name,
        "command": command_line(command),
        "status": "dry-run" if dry_run else "pending",
        "returnCode": 0 if dry_run else None,
    }
    if dry_run:
        return record

    proc = subprocess.run(command, text=True, capture_output=True, check=False)
    output = proc.stdout
    if proc.stderr:
        output += ("\n" if output else "") + proc.stderr
    if log_file:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log_file.write_text(output, encoding="utf-8")
        record["logFile"] = str(log_file)
    record["returnCode"] = proc.returncode
    record["status"] = "passed" if proc.returncode == 0 else "failed"
    if proc.returncode != 0:
        print(output[-4000:], file=sys.stderr)
    return record


def load_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def parse_modes(value: str) -> tuple[str, ...]:
    modes = tuple(item.strip("`") for item in value.replace(",", " ").split() if item)
    unknown = [mode for mode in modes if mode not in VALID_MODES]
    if unknown:
        raise SystemExit("unknown release mode(s): " + ", ".join(unknown))
    if not modes:
        raise SystemExit("--modes must include at least one mode")
    return modes


def infer_release_modes(release_dir: Path, explicit_modes: str | None) -> tuple[str, ...]:
    if explicit_modes:
        return parse_modes(explicit_modes)

    audit = load_json(release_dir / "RELEASE_AUDIT.json")
    if audit:
        expected = audit.get("expectedModes")
        if isinstance(expected, list) and all(isinstance(item, str) for item in expected):
            return parse_modes(" ".join(expected))

    manifest = release_dir / "MANIFEST.md"
    if manifest.exists():
        for line in manifest.read_text(encoding="utf-8", errors="replace").splitlines():
            prefix = "- Requested radar modes:"
            if line.startswith(prefix):
                return parse_modes(line[len(prefix):].strip())

    return DEFAULT_MODES


def check_mock_outputs(output_dir: Path) -> list[str]:
    failures: list[str] = []
    summary = load_json(output_dir / "board-sim-mock" / "board-sim-summary.json")
    bench = load_json(output_dir / "board-sim-mock" / "bench-sim-report.json")
    if not summary:
        failures.append("missing board-sim mock summary")
    else:
        if summary.get("status") != "passed":
            failures.append("board-sim mock summary did not pass")
        if summary.get("hardwareProof") is not False:
            failures.append("board-sim mock summary must keep hardwareProof=false")
    if not bench:
        failures.append("missing board-sim mock bench report")
    else:
        if bench.get("status") != "passed":
            failures.append("board-sim mock bench report did not pass")
        if bench.get("collectionCount") != 7:
            failures.append("board-sim mock bench report must contain seven collection events")
        if bench.get("summon") is not True:
            failures.append("board-sim mock bench report must show summon=true")
        if bench.get("simulatedBle") is not True:
            failures.append("board-sim mock bench report must show simulatedBle=true")
    return failures


def render_markdown(summary: dict[str, Any]) -> str:
    lines = [
        "# Dragon Radar Release Self-Test",
        "",
        f"- Generated: {summary['generated']}",
        f"- Status: {summary['status'].upper()}",
        f"- Release: `{summary['releaseDir']}`",
        f"- Output: `{summary['outputDir']}`",
        f"- Hardware proof: `{str(summary['hardwareProof']).lower()}`",
        "",
        "This self-test validates packaged files and local mock DIAG tooling only.",
        "It does not prove the ESP32-S3 display, touch, IMU, BLE radio, audio path, or physical beacons.",
        "",
        "## Steps",
        "",
        "| Step | Status | Log |",
        "| --- | --- | --- |",
    ]
    for step in summary["steps"]:
        log_file = step.get("logFile", "")
        lines.append(f"| {step['name']} | {step['status']} | `{log_file}` |")
    if summary["failures"]:
        lines.extend(["", "## Failures", ""])
        lines.extend(f"- {failure}" for failure in summary["failures"])
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    try:
        mock_timeout = int(args.mock_timeout)
    except ValueError:
        raise SystemExit(f"--mock-timeout must be an integer, got: {args.mock_timeout}")
    if mock_timeout < 0:
        raise SystemExit("--mock-timeout must be non-negative")

    release_dir = normalize_path(args.release_dir, default_release_dir())
    output_dir = normalize_path(args.output_dir, default_output_dir())
    modes = infer_release_modes(release_dir, args.modes)
    logs_dir = output_dir / "logs"
    steps: list[dict[str, Any]] = []
    failures: list[str] = []

    if not args.dry_run:
        output_dir.mkdir(parents=True, exist_ok=True)

    verifier = packaged_tool(release_dir, "verify_release_package.py")
    steps.append(
        run_step(
            "release-package",
            [str(verifier), str(release_dir), "--modes", " ".join(modes)],
            logs_dir / "verify-release-package.log",
            args.dry_run,
        )
    )

    if not args.skip_mock:
        board_sim = packaged_tool(release_dir, "run_board_sim_test.py")
        mock_dir = output_dir / "board-sim-mock"
        steps.append(
            run_step(
                "board-sim-mock",
                [
                    str(board_sim),
                    "mock",
                    "--release-dir",
                    str(release_dir),
                    "--output-dir",
                    str(mock_dir),
                    "--timeout",
                    str(mock_timeout),
                ],
                logs_dir / "board-sim-mock.log",
                args.dry_run,
            )
        )
        if not args.dry_run and steps[-1]["status"] == "passed":
            failures.extend(check_mock_outputs(output_dir))

    for step in steps:
        if step["status"] == "failed":
            failures.append(f"{step['name']} command failed")

    status = "passed" if not failures else "failed"
    summary: dict[str, Any] = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "releaseDir": str(release_dir),
        "outputDir": str(output_dir),
        "expectedModes": list(modes),
        "hardwareProof": False,
        "steps": steps,
        "failures": failures,
    }

    if not args.dry_run:
        summary_path = output_dir / "release-selftest-summary.json"
        markdown_path = output_dir / "release-selftest-summary.md"
        summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
        markdown_path.write_text(render_markdown(summary), encoding="utf-8")
        print(f"summary {rel(summary_path)}")
        print(f"report {rel(markdown_path)}")

    print(f"release-selftest-{status}")
    for failure in failures:
        print(f"FAIL {failure}")
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
