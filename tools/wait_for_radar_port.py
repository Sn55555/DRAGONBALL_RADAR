#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any

from diagnose_usb_serial import classify_usb_layer, collect_usb_devices
from list_radar_ports import PortInfo, collect_ports


ROOT = Path(__file__).resolve().parents[1]


def in_release_root() -> bool:
    return (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir()


def default_release_dir() -> Path:
    return ROOT if in_release_root() else ROOT / "output" / "release-current"


def default_watch_dir() -> Path:
    return ROOT / "evidence" / "radar-port-watch" if in_release_root() else ROOT / "output" / "radar-port-watch"


def default_auto_output_dir() -> Path:
    return ROOT / "evidence" / "board-sim" if in_release_root() else ROOT / "output" / "board-sim-current"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Wait for a likely ESP32-S3 Capsule serial port and optionally run the one-board smoke test."
    )
    parser.add_argument("--timeout", default=os.environ.get("RADAR_PORT_WAIT_TIMEOUT", "300"), help="Seconds to wait, default: 300.")
    parser.add_argument("--interval", default=os.environ.get("RADAR_PORT_WAIT_INTERVAL", "2"), help="Polling interval seconds, default: 2.")
    parser.add_argument("--run-auto", action="store_true", help="Run tools/run_board_sim_test.py auto after exactly one likely port appears.")
    parser.add_argument("--release-dir", default=os.environ.get("RELEASE_DIR"), help="Release folder for the auto run.")
    parser.add_argument("--output-dir", default=None, help="Output folder for the auto board-sim reports.")
    parser.add_argument("--json-output", default=None, help="Watch JSON path. Default: output/radar-port-watch/radar-port-watch.json.")
    parser.add_argument("--md-output", default=None, help="Watch Markdown path. Default: output/radar-port-watch/radar-port-watch.zh.md.")
    parser.add_argument("--erase", action="store_true", help="Pass --erase to run_board_sim_test.py auto.")
    parser.add_argument("--raw", action="store_true", help="Pass --raw to run_board_sim_test.py auto.")
    parser.add_argument("--dry-run", action="store_true", help="Print commands and write reports without flashing or monitoring.")
    parser.add_argument("--print-json", action="store_true", help="Print the JSON report to stdout.")
    parser.add_argument(
        "--sample",
        action="append",
        default=[],
        metavar="DEVICE|DESCRIPTION|HWID",
        help="Use sample port rows instead of live serial ports. Useful for deterministic checks.",
    )
    parser.add_argument(
        "--sample-usb",
        action="append",
        default=[],
        metavar="NAME|VENDOR_ID|PRODUCT_ID|SERIAL|LOCATION",
        help="Use sample USB device rows instead of system_profiler. Useful for deterministic checks.",
    )
    parser.add_argument("--skip-usb-layer", action="store_true", help="Skip macOS USB device-layer inspection.")
    return parser.parse_args()


def normalize_path(value: str | None, fallback: Path) -> Path:
    path = Path(value) if value else fallback
    return path if path.is_absolute() else ROOT / path


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def tool(name: str) -> Path:
    return ROOT / "tools" / name


def parse_int(value: str, name: str) -> int:
    try:
        parsed = int(value)
    except ValueError:
        raise SystemExit(f"{name} must be an integer, got: {value}") from None
    if parsed < 0:
        raise SystemExit(f"{name} must be non-negative")
    return parsed


def parse_float(value: str, name: str) -> float:
    try:
        parsed = float(value)
    except ValueError:
        raise SystemExit(f"{name} must be a number, got: {value}") from None
    if parsed < 0:
        raise SystemExit(f"{name} must be non-negative")
    return parsed


def command_line(command: list[str], env: dict[str, str] | None = None) -> str:
    if env:
        return shlex.join(["env"] + [f"{key}={value}" for key, value in env.items()] + command)
    return shlex.join(command)


def port_record(port: PortInfo) -> dict[str, Any]:
    data = asdict(port)
    data["likely"] = port.likely
    data["status"] = "likely" if port.likely else "ignored" if port.score < 0 else "unknown"
    return data


def print_attempt(attempt: int, ports: list[PortInfo], usb_status: str, usb_summary: str) -> None:
    usb_text = f"; usbLayer={usb_status}"
    likely = [port.device for port in ports if port.likely]
    if len(likely) == 1:
        print(f"[{attempt}] ready: {likely[0]}{usb_text}", flush=True)
    elif len(likely) > 1:
        print(f"[{attempt}] multiple candidates: {', '.join(likely)}{usb_text}", flush=True)
    elif not ports:
        print(f"[{attempt}] no serial ports{usb_text}; {usb_summary}", flush=True)
    else:
        visible = ", ".join(port.device for port in ports)
        print(f"[{attempt}] no likely radar port; visible: {visible}{usb_text}; {usb_summary}", flush=True)


def build_auto_command(args: argparse.Namespace, selected_port: str, release_dir: Path, output_dir: Path) -> list[str]:
    command = [
        str(tool("run_board_sim_test.py")),
        "auto",
        "--port",
        selected_port,
        "--release-dir",
        str(release_dir),
        "--output-dir",
        str(output_dir),
    ]
    if args.erase:
        command.append("--erase")
    if args.raw:
        command.append("--raw")
    if args.dry_run:
        command.append("--dry-run")
    return command


def run_auto(command: list[str], dry_run: bool) -> int:
    print("+ " + command_line(command), flush=True)
    if dry_run:
        return 0
    return subprocess.run(command, check=False).returncode


def write_report(json_path: Path, md_path: Path, report: dict[str, Any]) -> None:
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(report), encoding="utf-8")
    print(f"summary {rel(json_path)}")
    print(f"report {rel(md_path)}")


def usb_rows(devices: list[dict[str, Any]]) -> list[str]:
    if not devices:
        return ["| - | 未发现 | - | - | - |"]
    rows: list[str] = []
    for device in devices:
        rows.append(
            f"| {device.get('status', 'unknown')} | {device.get('name', 'USB device')} | "
            f"`{device.get('vendorId', '')}` | `{device.get('productId', '')}` | {device.get('reason', 'n/a')} |"
        )
    return rows


def render_markdown(report: dict[str, Any]) -> str:
    selected = report.get("selectedPort") or "未选择"
    auto = report.get("autoCommand") or "未运行"
    lines = [
        "# 胶囊串口等待报告",
        "",
        f"- 生成时间: {report['generated']}",
        f"- 状态: `{report['status']}`",
        f"- 尝试次数: {report['attempts']}",
        f"- 选中串口: `{selected}`",
        f"- USB 设备层: `{report.get('usbLayerStatus', 'missing')}` - {report.get('usbLayerSummary', '')}",
        f"- 自动上板模拟: `{report.get('autoStatus', 'not-run')}`",
        f"- 硬件证明: `{str(report.get('hardwareProof', False)).lower()}`",
        f"- 自动命令: `{auto}`",
        "",
        "## 端口列表",
        "",
    ]
    ports = report.get("ports", [])
    if not ports:
        lines.append("- 未发现任何串口。")
    else:
        lines.extend(["| 状态 | 端口 | 描述 | 原因 |", "| --- | --- | --- | --- |"])
        for port in ports:
            label = {
                "likely": "可用候选",
                "ignored": "跳过",
                "unknown": "未知",
            }.get(str(port.get("status")), "未知")
            lines.append(
                f"| {label} | `{port.get('device', '')}` | {port.get('description', 'n/a')} | {port.get('reason', 'n/a')} |"
            )
    lines.extend(
        [
            "",
            "## USB 设备层",
            "",
            "| 状态 | 名称 | VID | PID | 原因 |",
            "| --- | --- | --- | --- | --- |",
        ]
    )
    lines.extend(usb_rows(report.get("usbDevices", [])))
    lines.extend(["", "## 轮询记录", "", "| 次数 | 串口状态 | USB 设备层 |", "| --- | --- | --- |"])
    for attempt in report.get("attemptLog", []):
        likely = attempt.get("likelyPorts") or []
        if len(likely) == 1:
            port_text = f"ready: {likely[0]}"
        elif len(likely) > 1:
            port_text = "multiple: " + ", ".join(str(item) for item in likely)
        else:
            port_text = f"visible={attempt.get('portCount', 0)}"
        lines.append(f"| {attempt.get('attempt')} | {port_text} | {attempt.get('usbLayerStatus', '-')} |")
    lines.extend(
        [
            "",
            "## 下一步",
            "",
        ]
    )
    status = str(report.get("status"))
    if status in ("auto-passed", "ready"):
        lines.append("- 继续做完整验收：`RADAR_PORT=<选中串口> tools/run_release_acceptance.sh all`。")
    elif status == "multiple-candidates":
        lines.append("- 拔掉其他 ESP32/USB 串口设备，只保留胶囊主板后重跑。")
    elif report.get("usbLayerStatus") == "radar-usb-present":
        lines.extend(
            [
                "- USB 设备层已经看到疑似主板，但串口还没出现；按住 BOOT 再点 Reset，松开 BOOT 后继续等待。",
                "- 关闭 Arduino Serial Monitor、PlatformIO monitor 或其他可能占用串口的程序。",
            ]
        )
    else:
        lines.extend(
            [
                "- 换一根明确支持数据传输的 USB-C 线。",
                "- 换 USB 口或去掉扩展坞。",
                "- 按住 BOOT 再点 Reset 进入下载模式后重跑本工具。",
            ]
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    timeout = parse_int(args.timeout, "--timeout")
    interval = parse_float(args.interval, "--interval")
    watch_dir = default_watch_dir()
    json_path = normalize_path(args.json_output, watch_dir / "radar-port-watch.json")
    md_path = normalize_path(args.md_output, watch_dir / "radar-port-watch.zh.md")
    release_dir = normalize_path(args.release_dir, default_release_dir())
    output_dir = normalize_path(args.output_dir, default_auto_output_dir())
    deadline = time.monotonic() + timeout

    selected_port: str | None = None
    last_ports: list[PortInfo] = []
    last_usb_devices: list[dict[str, Any]] = []
    usb_layer_status = "unavailable"
    usb_layer_summary = "USB 设备层尚未检查。"
    attempt_log: list[dict[str, Any]] = []
    status = "timeout"
    attempts = 0

    while True:
        attempts += 1
        last_ports = collect_ports(args.sample)
        last_usb_devices, usb_error = collect_usb_devices(args.sample_usb, args.skip_usb_layer)
        usb_layer_status, usb_layer_summary = classify_usb_layer(last_usb_devices, usb_error)
        print_attempt(attempts, last_ports, usb_layer_status, usb_layer_summary)
        likely = [port.device for port in last_ports if port.likely]
        attempt_log.append(
            {
                "attempt": attempts,
                "timestamp": time.strftime("%Y-%m-%d %H:%M:%S"),
                "portCount": len(last_ports),
                "likelyPorts": likely,
                "usbLayerStatus": usb_layer_status,
                "usbLayerSummary": usb_layer_summary,
                "usbDeviceCount": len(last_usb_devices),
            }
        )
        if len(likely) == 1:
            selected_port = likely[0]
            status = "ready"
            break
        if len(likely) > 1:
            status = "multiple-candidates"
        if time.monotonic() >= deadline:
            break
        time.sleep(interval)

    auto_command: list[str] | None = None
    auto_rc: int | None = None
    auto_status = "not-run"
    hardware_proof = False
    if selected_port and args.run_auto:
        auto_command = build_auto_command(args, selected_port, release_dir, output_dir)
        auto_rc = run_auto(auto_command, args.dry_run)
        if args.dry_run:
            auto_status = "dry-run"
            status = "auto-dry-run"
        elif auto_rc == 0:
            auto_status = "passed"
            status = "auto-passed"
            hardware_proof = True
        else:
            auto_status = "failed"
            status = "auto-failed"

    report = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "timeout": timeout,
        "interval": interval,
        "attempts": attempts,
        "releaseDir": str(release_dir),
        "outputDir": str(output_dir),
        "selectedPort": selected_port,
        "usbLayerStatus": usb_layer_status,
        "usbLayerSummary": usb_layer_summary,
        "usbDevices": last_usb_devices,
        "attemptLog": attempt_log,
        "likelyPorts": [port.device for port in last_ports if port.likely],
        "ports": [port_record(port) for port in last_ports],
        "autoCommand": command_line(auto_command) if auto_command else None,
        "autoReturnCode": auto_rc,
        "autoStatus": auto_status,
        "hardwareProof": hardware_proof,
    }
    write_report(json_path, md_path, report)
    if args.print_json:
        print(json.dumps(report, indent=2))

    if status in ("ready", "auto-passed", "auto-dry-run"):
        return 0
    if status == "multiple-candidates":
        return 3
    if status == "auto-failed":
        return auto_rc or 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
