#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

from diagnose_board_runtime import classify, esptool_path, parse_lines, sample_serial
from list_radar_ports import collect_ports


ROOT = Path(__file__).resolve().parents[1]


READY_SAMPLE_LINES = [
    "DIAG enabled",
    "DIAG touch=online imu=online ble=online audio=online",
    "DIAG tick ms=1000 active=0 collected=7 zoom=0 brightPreset=1 audioPreset=2 "
    "frameMs=25 drawMs=16 drawAvgMs=16 drawMaxMs=18 overBudget=0 frames=40 heading=20.0 tilt=0.01 strongest=none online=TIBA summon=yes",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Try safe DTR/RTS reset sequences to recover a visible Dragon Radar serial port."
    )
    parser.add_argument("--port", default=os.environ.get("RADAR_PORT"), help="Serial port, e.g. /dev/cu.usbmodem101.")
    parser.add_argument("--baud", default=os.environ.get("DIAG_BAUD", "115200"), help="Baud rate, default: 115200.")
    parser.add_argument("--timeout", type=float, default=4.0, help="Seconds to sample DIAG output per stage.")
    parser.add_argument("--json-output", default="output/board-runtime-recovery.json", help="JSON report path.")
    parser.add_argument("--md-output", default="output/board-runtime-recovery.zh.md", help="Chinese Markdown report path.")
    parser.add_argument("--print-json", action="store_true", help="Print JSON report.")
    parser.add_argument("--dry-run", action="store_true", help="Write the planned sequence without opening serial.")
    parser.add_argument(
        "--skip-bootloader",
        action="store_true",
        help="Skip the BOOT/Reset-style DTR/RTS sequence and esptool probe.",
    )
    parser.add_argument(
        "--sample-ready-stage",
        choices=("none", "initial", "release-lines", "app-reset", "bootloader-reset"),
        default="none",
        help="Use deterministic sample data instead of live serial I/O.",
    )
    parser.add_argument(
        "--sample-esptool",
        choices=("skipped", "connected", "no-data"),
        default="skipped",
        help="Sample esptool result for tests when sample mode is used.",
    )
    return parser.parse_args()


def normalize(path: str | Path) -> Path:
    item = Path(path)
    return item if item.is_absolute() else ROOT / item


def resolve_port(requested: str | None) -> tuple[str | None, str]:
    if requested:
        return requested, "provided"
    ports = [port.device for port in collect_ports() if port.likely]
    if len(ports) == 1:
        return ports[0], "auto"
    if not ports:
        return None, "none"
    return None, "multiple"


def line_sequence(port: str, baud: str, sequence: list[tuple[bool, bool, float]]) -> str | None:
    try:
        import serial  # type: ignore
    except ImportError as exc:
        return f"pyserial unavailable: {exc}"
    try:
        with serial.Serial(port=port, baudrate=int(baud), timeout=0.05) as serial_port:
            for dtr, rts, pause in sequence:
                serial_port.dtr = dtr
                serial_port.rts = rts
                time.sleep(pause)
            serial_port.dtr = False
            serial_port.rts = False
    except OSError as exc:
        return f"cannot toggle serial lines: {exc}"
    return None


def release_lines(port: str, baud: str) -> str | None:
    return line_sequence(port, baud, [(False, False, 0.25)])


def app_reset(port: str, baud: str) -> str | None:
    return line_sequence(
        port,
        baud,
        [
            (False, False, 0.05),
            (False, True, 0.16),
            (False, False, 0.70),
        ],
    )


def bootloader_reset(port: str, baud: str) -> str | None:
    return line_sequence(
        port,
        baud,
        [
            (False, False, 0.05),
            (True, True, 0.14),
            (True, False, 0.55),
            (False, False, 0.25),
        ],
    )


def run_esptool_probe(port: str) -> dict[str, Any]:
    cmd = [
        esptool_path(),
        "--chip",
        "esp32s3",
        "--port",
        port,
        "--baud",
        "115200",
        "--before",
        "default-reset",
        "--after",
        "hard-reset",
        "read-mac",
    ]
    try:
        proc = subprocess.run(cmd, text=True, capture_output=True, timeout=12, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"status": "error", "summary": str(exc), "command": cmd}
    text = "\n".join(part for part in (proc.stdout.strip(), proc.stderr.strip()) if part)
    if proc.returncode == 0:
        return {"status": "connected", "summary": "esptool reached ESP32-S3", "command": cmd}
    if "No serial data received" in text:
        return {"status": "no-data", "summary": "esptool could not receive serial data from ESP32-S3", "command": cmd}
    return {"status": "failed", "summary": text[-500:] if text else f"esptool exited {proc.returncode}", "command": cmd}


def sample_esptool(status: str) -> dict[str, Any]:
    if status == "connected":
        return {"status": "connected", "summary": "sample esptool connected"}
    if status == "no-data":
        return {"status": "no-data", "summary": "sample esptool no data"}
    return {"status": "skipped", "summary": "sample esptool skipped"}


def stage_report(
    name: str,
    summary: str,
    lines: list[str],
    serial_error: str | None,
    esptool: dict[str, Any] | None = None,
) -> dict[str, Any]:
    probe = esptool or {"status": "skipped", "summary": "not requested"}
    parsed = parse_lines(lines)
    status, status_summary, recommendations = classify(parsed, lines, serial_error, probe)
    return {
        "stage": name,
        "summary": summary,
        "status": status,
        "statusSummary": status_summary,
        "serialError": serial_error,
        "parsed": parsed,
        "esptool": probe,
        "recommendations": recommendations,
        "lines": lines,
    }


def sample_lines_for_stage(args: argparse.Namespace, stage: str) -> list[str]:
    return READY_SAMPLE_LINES if args.sample_ready_stage == stage else []


def sample_mode(args: argparse.Namespace) -> bool:
    return args.sample_ready_stage != "none" or args.sample_esptool != "skipped"


def collect_stage(args: argparse.Namespace, port: str, name: str, summary: str) -> dict[str, Any]:
    if sample_mode(args):
        return stage_report(name, summary, sample_lines_for_stage(args, name), None)
    lines, serial_error = sample_serial(port, args.baud, args.timeout)
    return stage_report(name, summary, lines, serial_error)


def try_action(args: argparse.Namespace, port: str, name: str, summary: str, action) -> dict[str, Any]:
    if sample_mode(args):
        return stage_report(name, summary, sample_lines_for_stage(args, name), None)
    serial_error = action(port, args.baud)
    if serial_error:
        return stage_report(name, summary, [], serial_error)
    lines, read_error = sample_serial(port, args.baud, args.timeout)
    return stage_report(name, summary, lines, read_error)


def terminal_status(stages: list[dict[str, Any]]) -> tuple[str, str, list[str]]:
    for stage in stages:
        if stage["status"] in {"runtime-ready", "runtime-degraded"}:
            if stage["stage"] == "initial":
                return "already-ready", "板子已经在输出 DIAG。", ["继续上板模拟或刷新率实测。"]
            return (
                "recovered",
                f"通过 `{stage['stage']}` 后恢复了 DIAG 输出。",
                ["继续运行 `tools/monitor_diag.py` 或 `tools/smoke_release_board.sh all`。"],
            )
    for stage in stages:
        if stage["status"] == "bootloader-reachable-no-diag":
            return (
                "bootloader-reachable",
                "esptool 可以握手，但应用仍没有 DIAG；下一步应重刷 sim/diag factory。",
                ["运行 `RADAR_PORT=<端口> tools/flash_release_firmware.sh sim`。"],
            )
    return (
        "not-recovered",
        "自动释放 DTR/RTS 和复位序列后仍未恢复运行态。",
        [
            "按一下板子实体 Reset，或重新插拔 USB-C。",
            "若仍无输出，按住 BOOT 再点 Reset，松开 BOOT 后重跑本工具。",
            "确认没有串口监视器让 DTR/RTS 长时间保持在复位状态。",
        ],
    )


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    port, port_source = resolve_port(args.port)
    if args.dry_run:
        return {
            "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
            "status": "dry-run",
            "summary": "未打开串口，只输出将要执行的安全恢复序列。",
            "port": port,
            "portSource": port_source,
            "stages": [],
            "plannedActions": ["initial sample", "release-lines", "app-reset", "bootloader-reset/esptool"],
            "recommendations": ["连接板子后去掉 `--dry-run` 重跑。"],
        }
    if not port:
        return {
            "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
            "status": "no-port",
            "summary": f"无法解析唯一雷达串口：{port_source}",
            "port": None,
            "portSource": port_source,
            "stages": [],
            "recommendations": ["先运行 `tools/diagnose_usb_serial.py`。"],
        }

    stages: list[dict[str, Any]] = []
    stages.append(collect_stage(args, port, "initial", "初始采样，不改变串口控制线。"))
    if stages[-1]["status"] not in {"runtime-ready", "runtime-degraded"}:
        stages.append(try_action(args, port, "release-lines", "释放 DTR/RTS 后重新采样。", release_lines))
    if stages[-1]["status"] not in {"runtime-ready", "runtime-degraded"}:
        stages.append(try_action(args, port, "app-reset", "保持 BOOT 释放，短脉冲 Reset 后重新采样。", app_reset))
    if not args.skip_bootloader and stages[-1]["status"] not in {"runtime-ready", "runtime-degraded"}:
        stages.append(try_action(args, port, "bootloader-reset", "尝试 BOOT/Reset 进入下载路径后重新采样。", bootloader_reset))
        esptool = sample_esptool(args.sample_esptool) if sample_mode(args) else run_esptool_probe(port)
        stages.append(stage_report("esptool-probe", "探测 ESP32-S3 是否可被 esptool 握手。", [], None, esptool))

    status, summary, recommendations = terminal_status(stages)
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "summary": summary,
        "port": port,
        "portSource": port_source,
        "stages": stages,
        "recommendations": recommendations,
    }


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# 龙珠雷达板载运行态自动恢复报告",
        "",
        f"- 生成时间: {report['generated']}",
        f"- 状态: `{report['status']}`",
        f"- 结论: {report['summary']}",
        f"- 端口: `{report.get('port') or '-'}`",
        "",
        "## 阶段",
        "",
        "| 阶段 | 状态 | DIAG | frameMs | drawMs | drawAvg/drawMax | 超预算帧 | esptool |",
        "| --- | --- | --- | ---: | ---: | --- | --- | --- |",
    ]
    stages = report.get("stages", [])
    if not stages:
        lines.append("| - | - | - | - | - | - | - | - |")
    for stage in stages:
        parsed = stage.get("parsed", {})
        esptool = stage.get("esptool", {})
        perf = f"{parsed.get('drawAvgMs') or '-'}/{parsed.get('drawMaxMs') or '-'}"
        over_budget = f"{parsed.get('overBudgetFrames') or 0}/{parsed.get('frameSamples') or '-'}"
        lines.append(
            f"| {stage.get('stage')} | `{stage.get('status')}` | `{parsed.get('sawDiag', False)}` | "
            f"{parsed.get('frameMs') or '-'} | {parsed.get('drawMs') or '-'} | {perf} | {over_budget} | `{esptool.get('status', 'skipped')}` |"
        )
    lines.extend(["", "## 建议动作", ""])
    lines.extend(f"{idx}. {item}" for idx, item in enumerate(report.get("recommendations", []), start=1))
    lines.extend(["", "## 串口样本", ""])
    any_lines = False
    for stage in stages:
        sample = stage.get("lines", [])[:8]
        if not sample:
            continue
        any_lines = True
        lines.append(f"### {stage.get('stage')}")
        lines.extend(f"- `{line}`" for line in sample)
        lines.append("")
    if not any_lines:
        lines.append("- 没有捕捉到串口文本。")
    return "\n".join(lines) + "\n"


def write_report(args: argparse.Namespace, report: dict[str, Any]) -> None:
    json_path = normalize(args.json_output)
    md_path = normalize(args.md_output)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(report), encoding="utf-8")
    if args.print_json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"STATUS {report['status']}")
        print(f"SUMMARY {report['summary']}")
        print(f"JSON {json_path}")
        print(f"MARKDOWN {md_path}")


def main() -> int:
    args = parse_args()
    report = build_report(args)
    write_report(args, report)
    return 1 if report["status"] in {"no-port"} else 0


if __name__ == "__main__":
    raise SystemExit(main())
