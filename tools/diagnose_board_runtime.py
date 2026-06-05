#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any

from list_radar_ports import collect_ports


ROOT = Path(__file__).resolve().parents[1]
HARDWARE_RE = re.compile(
    r"DIAG touch=(?P<touch>\w+) imu=(?P<imu>\w+) ble=(?P<ble>\w+) audio=(?P<audio>\w+)"
)
TICK_RE = re.compile(
    r"DIAG tick ms=(?P<ms>\d+) active=(?P<active>\d+) collected=(?P<collected>\d+) "
    r"zoom=(?P<zoom>\d+) brightPreset=(?P<bright>\d+) audioPreset=(?P<audio>\d+) "
    r"(?:frameMs=(?P<frame_ms>\d+) )?"
    r"(?:drawMs=(?P<draw_ms>\d+) )?"
    r"(?:drawAvgMs=(?P<draw_avg_ms>\d+) )?"
    r"(?:drawMaxMs=(?P<draw_max_ms>\d+) )?"
    r"(?:overBudget=(?P<over_budget>\d+) )?"
    r"(?:frames=(?P<frame_samples>\d+) )?"
    r"heading=(?P<heading>-?\d+(?:\.\d+)?) tilt=(?P<tilt>-?\d+(?:\.\d+)?) "
    r"strongest=(?P<strongest>\S+) online=(?P<online>\S+)(?: summon=(?P<summon>yes|no))?"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Diagnose whether a visible Dragon Radar serial port is running firmware and DIAG output."
    )
    parser.add_argument("--port", default=os.environ.get("RADAR_PORT"), help="Serial port, e.g. /dev/cu.usbmodem101.")
    parser.add_argument("--baud", default=os.environ.get("DIAG_BAUD", "115200"), help="Baud rate, default: 115200.")
    parser.add_argument("--timeout", type=float, default=6.0, help="Seconds to sample serial output.")
    parser.add_argument("--json-output", default="output/board-runtime-diagnosis.json", help="JSON report path.")
    parser.add_argument("--md-output", default="output/board-runtime-diagnosis.zh.md", help="Chinese Markdown report path.")
    parser.add_argument("--print-json", action="store_true", help="Print the JSON report.")
    parser.add_argument("--esptool-probe", action="store_true", help="If no DIAG output is seen, try an esptool reset/read-mac probe.")
    parser.add_argument(
        "--sample-line",
        action="append",
        default=[],
        help="Use sample serial lines instead of opening a live serial port. May be passed more than once.",
    )
    parser.add_argument(
        "--sample-esptool",
        choices=("skipped", "connected", "no-data"),
        default="skipped",
        help="Sample esptool result for tests when --sample-line is used.",
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


def sample_serial(port: str, baud: str, timeout: float) -> tuple[list[str], str | None]:
    try:
        import serial  # type: ignore
    except ImportError as exc:
        return [], f"pyserial unavailable: {exc}"

    lines: list[str] = []
    pending = b""
    deadline = time.monotonic() + timeout
    try:
        with serial.Serial(port=port, baudrate=int(baud), timeout=0.2) as serial_port:
            serial_port.dtr = False
            serial_port.rts = False
            time.sleep(0.05)
            while time.monotonic() < deadline:
                chunk = serial_port.read(256)
                if not chunk:
                    continue
                pending += chunk
                while b"\n" in pending:
                    raw, pending = pending.split(b"\n", 1)
                    line = raw.decode("utf-8", errors="replace").strip()
                    if line:
                        lines.append(line)
    except OSError as exc:
        return lines, f"cannot open serial port: {exc}"
    if pending:
        line = pending.decode("utf-8", errors="replace").strip()
        if line:
            lines.append(line)
    return lines, None


def esptool_path() -> str:
    candidates = (
        os.environ.get("ESPTOOL_BIN"),
        str(Path.home() / ".platformio" / "penv" / "bin" / "esptool.py"),
        "esptool.py",
        "esptool",
    )
    for candidate in candidates:
        if not candidate:
            continue
        if candidate in {"esptool.py", "esptool"} or Path(candidate).exists():
            return candidate
    return "esptool.py"


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
        return {"status": "connected", "summary": "esptool reached ESP32-S3 bootloader/application reset path", "command": cmd}
    if "No serial data received" in text:
        return {"status": "no-data", "summary": "esptool could not receive serial data from ESP32-S3", "command": cmd}
    return {"status": "failed", "summary": text[-500:] if text else f"esptool exited {proc.returncode}", "command": cmd}


def parse_lines(lines: list[str]) -> dict[str, Any]:
    hardware: dict[str, str] = {}
    frame_ms = 0
    draw_ms = 0
    draw_avg_ms = 0
    draw_max_ms = 0
    over_budget = 0
    frame_samples = 0
    collected = 0
    summon = False
    saw_diag = False
    saw_boot = False
    for line in lines:
        if "Dragon Radar firmware boot" in line:
            saw_boot = True
        if line == "DIAG enabled":
            saw_diag = True
        match = HARDWARE_RE.search(line)
        if match:
            saw_diag = True
            hardware = match.groupdict()
        match = TICK_RE.search(line)
        if match:
            saw_diag = True
            collected = int(match.group("collected"))
            frame_ms = int(match.group("frame_ms") or 0)
            draw_ms = int(match.group("draw_ms") or 0)
            draw_avg_ms = int(match.group("draw_avg_ms") or 0)
            draw_max_ms = int(match.group("draw_max_ms") or 0)
            over_budget = int(match.group("over_budget") or 0)
            frame_samples = int(match.group("frame_samples") or 0)
            if match.group("summon"):
                summon = match.group("summon") == "yes"
    all_online = bool(hardware) and all(value == "online" for value in hardware.values())
    return {
        "sawDiag": saw_diag,
        "sawBoot": saw_boot,
        "hardware": hardware,
        "hardwareAllOnline": all_online,
        "frameMs": frame_ms,
        "drawMs": draw_ms,
        "drawAvgMs": draw_avg_ms,
        "drawMaxMs": draw_max_ms,
        "overBudgetFrames": over_budget,
        "frameSamples": frame_samples,
        "collected": collected,
        "summon": summon,
    }


def classify(parsed: dict[str, Any], lines: list[str], serial_error: str | None, esptool: dict[str, Any]) -> tuple[str, str, list[str]]:
    if serial_error:
        return (
            "serial-open-failed",
            serial_error,
            [
                "确认没有 Arduino Serial Monitor、PlatformIO monitor、screen、cat 或其他程序占用串口。",
                "重新运行 `tools/diagnose_usb_serial.py` 确认端口仍存在。",
            ],
        )
    if parsed["sawDiag"] and parsed["hardwareAllOnline"]:
        return (
            "runtime-ready",
            "串口正在输出 DIAG，且 touch/IMU/BLE/audio 全部 online。",
            [
                "可以继续一块板模拟或 release smoke。",
                "需要调刷新率时运行 `tools/send_diag_command.py frame`；如果旧设置停在 33ms，运行 `tools/send_diag_command.py turbo` 强制 25ms。",
            ],
        )
    if parsed["sawDiag"]:
        return (
            "runtime-degraded",
            "串口正在输出 DIAG，但部分硬件没有 online。",
            [
                "查看 JSON 中 hardware 字段，优先处理 offline 的模块。",
                "如果 touch 偶发 offline，按 Reset 后重试；固件已经包含触摸初始化重试。",
            ],
        )
    if lines:
        return (
            "boot-only",
            "串口有输出，但没有进入 DIAG；可能仍在启动、固件不是 diag/sim/fielddiag，或初始化卡住。",
            [
                "等待 10 秒后重跑本工具。",
                "如果仍无 DIAG，刷入 `sim` 或 `diag` factory 固件后重试。",
            ],
        )
    if esptool.get("status") == "connected":
        return (
            "bootloader-reachable-no-diag",
            "应用没有 DIAG 输出，但 esptool 可以握手；优先重刷 sim/diag 固件。",
            [
                "运行 `RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh sim`。",
                "刷完后运行 `RADAR_PORT=/dev/cu.usbmodem101 tools/smoke_release_board.sh all`。",
            ],
        )
    if esptool.get("status") in {"no-data", "failed", "error"}:
        return (
            "usb-serial-present-no-runtime",
            "USB 串口设备存在，但应用无 DIAG 输出，esptool 也未收到芯片数据。",
            [
                "按一下板子 Reset，或重新插拔 USB-C。",
                "若仍无输出，按住 BOOT 再点 Reset，松开 BOOT 后重跑本工具或重刷 sim factory。",
                "确认没有让 DTR/RTS 长时间保持在复位状态的串口工具。",
            ],
        )
    return (
        "no-diag",
        "USB 串口设备存在，但采样窗口内没有 DIAG 输出。",
        [
            "按一下 Reset 后重跑本工具。",
            "如果继续无输出，加 `--esptool-probe` 区分是应用没跑还是芯片握手也失败。",
        ],
    )


def build_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# 龙珠雷达板载运行态诊断",
        "",
        f"- 生成时间: {report['generated']}",
        f"- 状态: `{report['status']}`",
        f"- 结论: {report['summary']}",
        f"- 端口: `{report.get('port') or '-'}`",
        f"- DIAG: `{report['parsed']['sawDiag']}`",
        f"- Boot 日志: `{report['parsed']['sawBoot']}`",
        f"- frameMs: `{report['parsed']['frameMs'] or '-'}`",
        f"- drawMs: `{report['parsed']['drawMs'] or '-'}`",
        f"- drawAvg/drawMax: `{report['parsed'].get('drawAvgMs') or '-'}` / `{report['parsed'].get('drawMaxMs') or '-'}` ms",
        f"- Over-budget frames: `{report['parsed'].get('overBudgetFrames') or 0}` / `{report['parsed'].get('frameSamples') or '-'}`",
        f"- collected: `{report['parsed']['collected']}`",
        f"- summon: `{report['parsed']['summon']}`",
        "",
        "## 硬件状态",
        "",
    ]
    hardware = report["parsed"].get("hardware") or {}
    if hardware:
        lines.extend(f"- {name}: `{value}`" for name, value in sorted(hardware.items()))
    else:
        lines.append("- 未捕捉到 `DIAG touch=...` 硬件汇总。")
    lines.extend(["", "## esptool 探测", ""])
    esptool = report.get("esptool") or {}
    lines.append(f"- 状态: `{esptool.get('status', 'skipped')}`")
    lines.append(f"- 说明: {esptool.get('summary', '未运行 esptool 探测。')}")
    lines.extend(["", "## 建议动作", ""])
    lines.extend(f"{idx}. {item}" for idx, item in enumerate(report["recommendations"], start=1))
    lines.extend(["", "## 串口样本", ""])
    sample = report.get("lines", [])[:20]
    if sample:
        lines.extend(f"- `{line}`" for line in sample)
    else:
        lines.append("- 采样窗口内没有收到串口文本。")
    return "\n".join(lines) + "\n"


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    port, port_source = resolve_port(args.port)
    if args.sample_line or args.sample_esptool != "skipped":
        lines = list(args.sample_line)
        serial_error = None
        esptool = {"status": args.sample_esptool, "summary": "sample esptool result"}
    elif port:
        lines, serial_error = sample_serial(port, args.baud, args.timeout)
        esptool = run_esptool_probe(port) if args.esptool_probe and not lines else {"status": "skipped", "summary": "esptool probe not requested"}
    else:
        lines = []
        serial_error = f"cannot resolve a unique radar serial port ({port_source})"
        esptool = {"status": "skipped", "summary": "no serial port"}

    parsed = parse_lines(lines)
    status, summary, recommendations = classify(parsed, lines, serial_error, esptool)
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "summary": summary,
        "port": port,
        "portSource": port_source,
        "serialError": serial_error,
        "parsed": parsed,
        "esptool": esptool,
        "recommendations": recommendations,
        "lines": lines,
    }


def main() -> int:
    args = parse_args()
    report = build_report(args)
    json_path = normalize(args.json_output)
    md_path = normalize(args.md_output)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(build_markdown(report), encoding="utf-8")
    if args.print_json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"STATUS {report['status']}")
        print(f"SUMMARY {report['summary']}")
        print(f"JSON {json_path}")
        print(f"MARKDOWN {md_path}")
    return 0 if report["status"] in {"runtime-ready", "runtime-degraded", "bootloader-reachable-no-diag", "no-diag", "usb-serial-present-no-runtime"} else 1


if __name__ == "__main__":
    raise SystemExit(main())
