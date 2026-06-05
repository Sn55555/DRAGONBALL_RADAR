#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODES = ("field", "fielddiag", "diag", "sim")
VALID_MODES = DEFAULT_MODES + ("near",)


def in_release_root() -> bool:
    return (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir()


def default_release_dir() -> Path:
    return ROOT if in_release_root() else ROOT / "output" / "release-current"


def default_output_dir() -> Path:
    return ROOT / "evidence" / "preboard-acceptance" if in_release_root() else ROOT / "output" / "preboard-acceptance-current"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run the no-hardware Dragon Radar pre-board acceptance suite.")
    parser.add_argument("--release-dir", default=os.environ.get("RELEASE_DIR"), help="Release folder to validate.")
    parser.add_argument("--output-dir", default=None, help="Output folder for logs and machine-readable reports.")
    parser.add_argument("--json-output", default=None, help="Summary JSON path.")
    parser.add_argument("--md-output", default=None, help="Chinese Markdown summary path.")
    parser.add_argument("--modes", default=None, help="Expected release modes. Defaults to release audit or field fielddiag diag sim.")
    parser.add_argument("--mock-timeout", default=os.environ.get("PREBOARD_MOCK_TIMEOUT", "8"), help="Mock board-sim timeout seconds.")
    parser.add_argument("--samples", type=int, default=48, help="DIAG replay samples before the seven collection events.")
    parser.add_argument("--skip-release-verify", action="store_true", help="Skip the release verifier step when a package is still being assembled.")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without writing reports.")
    return parser.parse_args()


def normalize_path(value: str | None, fallback: Path) -> Path:
    path = Path(value) if value else fallback
    return path if path.is_absolute() else ROOT / path


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def command_line(command: list[str]) -> str:
    return shlex.join(command)


def pipeline_line(left: list[str], right: list[str]) -> str:
    return f"{command_line(left)} | {command_line(right)}"


def packaged_tool(release_dir: Path, name: str) -> Path:
    candidate = release_dir / "tools" / name
    if candidate.exists():
        return candidate
    return ROOT / "tools" / name


def load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def parse_modes(value: str) -> tuple[str, ...]:
    modes = tuple(item.strip("`") for item in value.replace(",", " ").split() if item)
    unknown = [mode for mode in modes if mode not in VALID_MODES]
    if unknown:
        raise SystemExit("unknown release mode(s): " + ", ".join(unknown))
    if not modes:
        raise SystemExit("--modes must include at least one mode")
    return modes


def infer_modes(release_dir: Path, explicit_modes: str | None) -> tuple[str, ...]:
    if explicit_modes:
        return parse_modes(explicit_modes)
    audit = load_json(release_dir / "RELEASE_AUDIT.json")
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


def run_step(name: str, command: list[str], log_file: Path, dry_run: bool) -> dict[str, Any]:
    print("+ " + command_line(command), flush=True)
    record: dict[str, Any] = {
        "name": name,
        "command": command_line(command),
        "status": "dry-run" if dry_run else "pending",
        "returnCode": 0 if dry_run else None,
        "logFile": str(log_file),
    }
    if dry_run:
        return record

    proc = subprocess.run(command, text=True, capture_output=True, check=False)
    output = proc.stdout
    if proc.stderr:
        output += ("\n" if output else "") + proc.stderr
    log_file.parent.mkdir(parents=True, exist_ok=True)
    log_file.write_text(output, encoding="utf-8")
    record["returnCode"] = proc.returncode
    record["status"] = "passed" if proc.returncode == 0 else "failed"
    return record


def run_diag_replay(output_dir: Path, samples: int, dry_run: bool) -> dict[str, Any]:
    raw_log = output_dir / "diag-replay-raw.log"
    monitor_log = output_dir / "diag-replay-monitor.log"
    report_json = output_dir / "diag-replay-report.json"
    simulate = [
        str(ROOT / "tools" / "simulate_diag_feed.py"),
        "--beacons",
        "7",
        "--samples",
        str(samples),
        "--touch-events",
        "--simulated-ble",
        "--hunt-session",
        "1",
        "--collect-all",
        "--summon",
    ]
    monitor = [
        str(ROOT / "tools" / "monitor_diag.py"),
        "--stdin",
        "--calibrate",
        "--require-online",
        "touch,imu,ble,audio",
        "--min-beacons",
        "7",
        "--min-collected",
        "7",
        "--min-collections",
        "7",
        "--require-collection-set",
        "--require-simulated-ble",
        "--require-summon",
        "--report-json",
        str(report_json),
        "--report-log-file",
        str(raw_log),
    ]
    print("+ " + pipeline_line(simulate, monitor), flush=True)
    record: dict[str, Any] = {
        "name": "diag-seven-ball-replay",
        "command": pipeline_line(simulate, monitor),
        "status": "dry-run" if dry_run else "pending",
        "returnCode": 0 if dry_run else None,
        "logFile": str(monitor_log),
        "rawLog": str(raw_log),
        "reportJson": str(report_json),
    }
    if dry_run:
        return record

    output_dir.mkdir(parents=True, exist_ok=True)
    generated = subprocess.run(simulate, text=True, capture_output=True, check=False)
    raw = generated.stdout
    raw_log.write_text(raw, encoding="utf-8")
    if generated.returncode != 0:
        text = raw
        if generated.stderr:
            text += ("\n" if text else "") + generated.stderr
        monitor_log.write_text(text, encoding="utf-8")
        record["returnCode"] = generated.returncode
        record["status"] = "failed"
        return record

    monitored = subprocess.run(monitor, input=raw, text=True, capture_output=True, check=False)
    text = monitored.stdout
    if monitored.stderr:
        text += ("\n" if text else "") + monitored.stderr
    monitor_log.write_text(text, encoding="utf-8")
    record["returnCode"] = monitored.returncode
    record["status"] = "passed" if monitored.returncode == 0 else "failed"
    return record


def write_assembly_selftest_summary(
    output_dir: Path,
    release_dir: Path,
    modes: tuple[str, ...],
    mock_step: dict[str, Any],
) -> None:
    summary = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": "passed" if mock_step.get("status") == "passed" else "failed",
        "releaseDir": str(release_dir),
        "outputDir": str(output_dir / "release-selftest"),
        "expectedModes": list(modes),
        "hardwareProof": False,
        "steps": [mock_step],
        "failures": [] if mock_step.get("status") == "passed" else ["board-sim-mock command failed"],
    }
    target = output_dir / "release-selftest" / "release-selftest-summary.json"
    markdown = output_dir / "release-selftest" / "release-selftest-summary.md"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    markdown.write_text(
        "# Dragon Radar Release Self-Test\n\n"
        f"- Generated: {summary['generated']}\n"
        f"- Status: {summary['status'].upper()}\n"
        "- Hardware proof: `false`\n\n"
        "This package-assembly self-test runs the mock board simulation only; "
        "the final release verifier runs after this report is generated.\n",
        encoding="utf-8",
    )


def check_preboard_outputs(output_dir: Path) -> tuple[dict[str, Any], list[str]]:
    failures: list[str] = []
    release_selftest = load_json(output_dir / "release-selftest" / "release-selftest-summary.json")
    mock_summary = load_json(output_dir / "release-selftest" / "board-sim-mock" / "board-sim-summary.json")
    mock_bench = load_json(output_dir / "release-selftest" / "board-sim-mock" / "bench-sim-report.json")
    diag = load_json(output_dir / "diag-replay-report.json")
    checks: dict[str, Any] = {
        "releaseSelftest": {
            "status": release_selftest.get("status", "missing"),
            "hardwareProof": release_selftest.get("hardwareProof"),
        },
        "mockBoardSimulation": {
            "status": mock_bench.get("status", "missing"),
            "summaryStatus": mock_summary.get("status", "missing"),
            "hardwareProof": mock_summary.get("hardwareProof"),
            "collectionCount": mock_bench.get("collectionCount"),
            "summon": mock_bench.get("summon"),
            "simulatedBle": mock_bench.get("simulatedBle"),
        },
        "diagSevenBallReplay": {
            "status": diag.get("status", "missing"),
            "beaconCount": diag.get("beaconCount"),
            "collectionCount": diag.get("collectionCount"),
            "collected": diag.get("collected"),
            "summon": diag.get("summon"),
            "simulatedBle": diag.get("simulatedBle"),
        },
    }

    if release_selftest.get("status") != "passed":
        failures.append("release self-test did not pass")
    if release_selftest.get("hardwareProof") is not False:
        failures.append("release self-test must keep hardwareProof=false")
    if mock_summary.get("status") != "passed":
        failures.append("mock board-sim summary did not pass")
    if mock_summary.get("hardwareProof") is not False:
        failures.append("mock board-sim must not claim hardware proof")
    if mock_bench.get("status") != "passed":
        failures.append("mock bench report did not pass")
    if mock_bench.get("collectionCount") != 7:
        failures.append("mock bench did not collect seven simulated balls")
    if mock_bench.get("summon") is not True:
        failures.append("mock bench did not reach summon")
    if mock_bench.get("simulatedBle") is not True:
        failures.append("mock bench did not prove simulated BLE mode")
    if diag.get("status") != "passed":
        failures.append("DIAG replay did not pass")
    if diag.get("beaconCount") != 7:
        failures.append("DIAG replay did not see seven beacons")
    if diag.get("collectionCount") != 7:
        failures.append("DIAG replay did not emit seven collection events")
    if diag.get("collected") != 7:
        failures.append("DIAG replay final collected count was not seven")
    if diag.get("summon") is not True:
        failures.append("DIAG replay did not reach summon")
    if diag.get("simulatedBle") is not True:
        failures.append("DIAG replay did not report simulated BLE")
    return checks, failures


def render_markdown(summary: dict[str, Any]) -> str:
    lines = [
        "# 龙珠雷达上板前模拟验收报告",
        "",
        f"- 生成时间: {summary['generated']}",
        f"- 总状态: `{summary['status']}`",
        f"- Release: `{summary['releaseDir']}`",
        f"- 输出目录: `{summary['outputDir']}`",
        "- 硬件证明: `false`",
        "",
        "这份报告只证明上板前软件链路：发布包结构、mock 一块板流程、七球 DIAG 回放和召唤条件。它不能替代 ESP32-S3 真板、屏幕、触摸、IMU、BLE、音频或实体信标验收。",
        "",
        "## 步骤",
        "",
        "| 步骤 | 状态 | 日志 |",
        "| --- | --- | --- |",
    ]
    for step in summary["steps"]:
        lines.append(f"| {step['name']} | {step['status']} | `{step.get('logFile', '')}` |")

    checks = summary["checks"]
    mock = checks["mockBoardSimulation"]
    diag = checks["diagSevenBallReplay"]
    lines.extend(
        [
            "",
            "## 关键断言",
            "",
            f"- Release self-test: `{checks['releaseSelftest']['status']}`; hardwareProof=`{checks['releaseSelftest']['hardwareProof']}`。",
            f"- Mock 一块板: `{mock['status']}`; collectionCount=`{mock['collectionCount']}`; summon=`{mock['summon']}`; simulatedBle=`{mock['simulatedBle']}`。",
            f"- DIAG 七球回放: `{diag['status']}`; beaconCount=`{diag['beaconCount']}`; collectionCount=`{diag['collectionCount']}`; collected=`{diag['collected']}`; summon=`{diag['summon']}`。",
            "",
            "## 下一步",
            "",
            "- 接上 Waveshare ESP32-S3-Touch-AMOLED-1.75C 后，运行 `tools/diagnose_usb_serial.py` 确认串口。",
            "- 串口可见后运行 `RADAR_PORT=/dev/cu.usbmodem101 tools/run_board_sim_test.py auto`。",
            "- 完整硬件闭环仍以 `RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh all` 为准。",
        ]
    )
    if summary["failures"]:
        lines.extend(["", "## 失败项", ""])
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
    if args.samples < 1:
        raise SystemExit("--samples must be >= 1")

    release_dir = normalize_path(args.release_dir, default_release_dir())
    output_dir = normalize_path(args.output_dir, default_output_dir())
    json_output = normalize_path(args.json_output, output_dir / "preboard-acceptance-summary.json")
    md_output = normalize_path(args.md_output, output_dir / "preboard-acceptance.zh.md")
    modes = infer_modes(release_dir, args.modes)
    logs_dir = output_dir / "logs"

    if not args.dry_run:
        output_dir.mkdir(parents=True, exist_ok=True)

    if args.skip_release_verify:
        release_step = {
            "name": "release-package",
            "command": "skipped while assembling release package",
            "status": "skipped",
            "returnCode": 0,
            "logFile": str(logs_dir / "verify-release-package.log"),
        }
        print("+ skip release-package verifier while assembling release package", flush=True)
    else:
        release_step = run_step(
            "release-package",
            [
                str(packaged_tool(release_dir, "verify_release_package.py")),
                str(release_dir),
                "--allow-missing-links",
                "--modes",
                " ".join(modes),
            ],
            logs_dir / "verify-release-package.log",
            args.dry_run,
        )
    if args.skip_release_verify:
        selftest_step = run_step(
            "board-sim-mock",
            [
                str(packaged_tool(release_dir, "run_board_sim_test.py")),
                "mock",
                "--release-dir",
                str(release_dir),
                "--output-dir",
                str(output_dir / "release-selftest" / "board-sim-mock"),
                "--timeout",
                str(mock_timeout),
            ],
            logs_dir / "board-sim-mock.log",
            args.dry_run,
        )
    else:
        selftest_step = run_step(
            "release-selftest-mock",
            [
                str(packaged_tool(release_dir, "selftest_release.py")),
                str(release_dir),
                "--output-dir",
                str(output_dir / "release-selftest"),
                "--modes",
                " ".join(modes),
                "--mock-timeout",
                str(mock_timeout),
            ],
            logs_dir / "release-selftest.log",
            args.dry_run,
        )
    steps = [
        release_step,
        selftest_step,
        run_diag_replay(output_dir, args.samples, args.dry_run),
    ]

    step_failures = [f"{step['name']} command failed" for step in steps if step["status"] == "failed"]
    checks: dict[str, Any] = {
        "releaseSelftest": {"status": "dry-run", "hardwareProof": False},
        "mockBoardSimulation": {"status": "dry-run", "hardwareProof": False},
        "diagSevenBallReplay": {"status": "dry-run"},
    }
    output_failures: list[str] = []
    if not args.dry_run:
        if args.skip_release_verify:
            write_assembly_selftest_summary(output_dir, release_dir, modes, selftest_step)
        checks, output_failures = check_preboard_outputs(output_dir)

    failures = step_failures + output_failures
    status = "dry-run" if args.dry_run else ("passed" if not failures else "failed")
    summary: dict[str, Any] = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "releaseDir": str(release_dir),
        "outputDir": str(output_dir),
        "expectedModes": list(modes),
        "hardwareProof": False,
        "steps": steps,
        "checks": checks,
        "failures": failures,
    }

    if not args.dry_run:
        json_output.parent.mkdir(parents=True, exist_ok=True)
        md_output.parent.mkdir(parents=True, exist_ok=True)
        json_output.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        md_output.write_text(render_markdown(summary), encoding="utf-8")
        print(f"summary {rel(json_output)}")
        print(f"report {rel(md_output)}")

    print(f"preboard-acceptance-{status}")
    for failure in failures:
        print(f"FAIL {failure}")
    return 0 if status in {"passed", "dry-run"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
