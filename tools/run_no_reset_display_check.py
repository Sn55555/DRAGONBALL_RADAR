#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any

from diagnose_board_runtime import parse_lines, sample_serial
from list_radar_ports import collect_ports
from send_diag_command import COMMANDS


ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Check Dragon Radar display refresh over DIAG without flashing or requiring manual Reset."
    )
    parser.add_argument("--port", default=os.environ.get("RADAR_PORT"), help="Serial port, e.g. /dev/cu.usbmodem101.")
    parser.add_argument("--baud", default=os.environ.get("DIAG_BAUD", "115200"), help="Baud rate, default: 115200.")
    parser.add_argument("--timeout", type=float, default=6.0, help="Seconds to sample after each step.")
    parser.add_argument("--command", default="turbo", help="DIAG command to send after initial sample. Default: turbo.")
    parser.add_argument("--passive", action="store_true", help="Only sample DIAG; do not send a command.")
    parser.add_argument("--dry-run", action="store_true", help="Write the planned sequence without opening serial.")
    parser.add_argument("--json-output", default="output/no-reset-display-check.json", help="JSON report path.")
    parser.add_argument("--md-output", default="output/no-reset-display-check.zh.md", help="Chinese Markdown report path.")
    parser.add_argument("--sample-line", action="append", default=[], help="Use sample serial lines instead of live I/O.")
    parser.add_argument("--sample-report", default=None, help="Build sample lines from a DIAG report JSON.")
    parser.add_argument("--print-json", action="store_true", help="Print JSON report.")
    return parser.parse_args()


def normalize(path: str | Path) -> Path:
    item = Path(path)
    return item if item.is_absolute() else ROOT / item


def resolve_port(requested: str | None) -> tuple[str | None, str]:
    if requested:
        return requested, "provided"
    ports = [port.device for port in collect_ports([]) if port.likely]
    if len(ports) == 1:
        return ports[0], "auto"
    if not ports:
        return None, "none"
    return None, "multiple"


def load_json(path: str | Path) -> dict[str, Any]:
    try:
        data = json.loads(normalize(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def command_char(value: str) -> str:
    if value in COMMANDS:
        return COMMANDS[value]
    if len(value) == 1:
        return value
    raise SystemExit(f"unknown command: {value}")


def command_action(command: str) -> str:
    return {
        "t": "frame_turbo",
        "f": "frame_rate",
        "p": "ping",
        "h": "hardware",
        "z": "zoom",
        "b": "brightness",
        "a": "audio",
        "r": "reset",
    }.get(command, "unknown")


def sample_lines_from_report(report: dict[str, Any], command: str | None) -> list[str]:
    hardware = report.get("hardware", {})
    if not isinstance(hardware, dict):
        hardware = {}
    frame_ms = int(report.get("frameMs") or 25)
    draw_ms = int(report.get("drawMs") or 18)
    draw_avg = int(report.get("drawAvgMs") or 18)
    draw_max = int(report.get("drawMaxMs") or 20)
    over_budget = int(report.get("overBudgetFrames") or 0)
    frames = int(report.get("frameSamples") or 40)
    collected = int(report.get("collected") or 0)
    summon = "yes" if report.get("summon") else "no"
    touch = hardware.get("touch", "online")
    imu = hardware.get("imu", "online")
    ble = hardware.get("ble", "online")
    audio = hardware.get("audio", "online")
    lines = [
        "DIAG enabled",
        f"DIAG touch={touch} imu={imu} ble={ble} audio={audio}",
    ]
    if command:
        action = command_action(command)
        if action == "frame_turbo":
            lines.append("DIAG command t action=frame_turbo frameMs=25 framePreset=0")
        elif action == "frame_rate":
            lines.append(f"DIAG command f action=frame_rate frameMs={frame_ms or 33} framePreset=1")
        else:
            lines.append(f"DIAG command {command} action={action}")
    lines.append(
        "DIAG tick ms=1000 active=0 "
        f"collected={collected} zoom=0 brightPreset=2 audioPreset=2 "
        f"frameMs={frame_ms} drawMs={draw_ms} drawAvgMs={draw_avg} "
        f"drawMaxMs={draw_max} overBudget={over_budget} frames={frames} "
        "heading=20.0 tilt=0.01 strongest=none online=TIBA "
        f"summon={summon}"
    )
    return lines


def send_command_and_capture(port: str, baud: str, command: str, timeout: float) -> tuple[list[str], str | None]:
    try:
        import serial  # type: ignore
    except ImportError as exc:
        return [], f"pyserial unavailable: {exc}"
    lines: list[str] = []
    pending = b""
    deadline = time.monotonic() + timeout
    try:
        with serial.Serial(port=port, baudrate=int(baud), timeout=0.1, write_timeout=1) as serial_port:
            serial_port.dtr = False
            serial_port.rts = False
            time.sleep(0.05)
            serial_port.write(command.encode("ascii") + b"\n")
            serial_port.flush()
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


def command_confirmed(lines: list[str], command: str | None) -> bool:
    if not command:
        return False
    expected = f"DIAG command {command.lower()} action="
    return any(expected in line for line in lines)


def classify_refresh(parsed: dict[str, Any], serial_error: str | None, confirmed: bool, command: str | None) -> tuple[str, str, list[str]]:
    if serial_error:
        return (
            "serial-open-failed",
            serial_error,
            [
                "关闭 Arduino Serial Monitor、PlatformIO monitor、screen、minicom 等占用串口的程序。",
                "重新运行 `tools/diagnose_usb_serial.py` 确认端口仍存在。",
            ],
        )
    if not parsed.get("sawDiag"):
        return (
            "no-diag",
            "采样窗口内没有 DIAG 输出；不建议继续发送刷新命令。",
            [
                "先运行 `tools/recover_board_runtime.py`，它会尝试不依赖手动 Reset 的运行态恢复。",
                "也可以运行 `tools/first_run_zh.py live --recover-runtime` 让首跑助手自动处理。",
            ],
        )
    frame_ms = int(parsed.get("frameMs") or 0)
    draw_avg = int(parsed.get("drawAvgMs") or 0)
    draw_max = int(parsed.get("drawMaxMs") or 0)
    over_budget = int(parsed.get("overBudgetFrames") or 0)
    frame_samples = int(parsed.get("frameSamples") or 0)
    if command and not confirmed:
        return (
            "command-not-confirmed",
            "已经看到 DIAG，但没有看到命令确认回显。",
            [
                "确认固件是 diag/sim/fielddiag 或带 DIAG 命令的版本。",
                "重跑 `tools/send_diag_command.py turbo` 单独确认命令链路。",
            ],
        )
    if frame_ms == 25 and draw_avg > 0 and draw_max <= frame_ms and over_budget == 0 and frame_samples > 0:
        return (
            "refresh-ready",
            "不需要手动 Reset；当前 DIAG 显示 25ms 刷新目标下没有绘制超预算。",
            [
                "如果肉眼仍觉得刷新低，优先排查相机快门/曝光、旧设置和屏幕总线稳定性。",
                "如仍屏闪，使用 `DISPLAY_BUS_HZ=40000000 tools/build_radar.sh sim` 做总线降速对照。",
            ],
        )
    if frame_ms and frame_ms != 25:
        return (
            "refresh-not-turbo",
            f"当前 frameMs={frame_ms}，不是最快 25ms 预设。",
            [
                "运行 `tools/send_diag_command.py turbo`，再跑本工具复查。",
                "如果 NVS 旧设置反复恢复慢档，保留 turbo 命令作为上板前固定动作。",
            ],
        )
    if frame_ms and (draw_max > frame_ms or over_budget > 0):
        return (
            "refresh-over-budget",
            "绘制成本超过目标刷新间隔，刷新低是固件绘制/显示传输压力导致。",
            [
                "先退到 `FRAME_MS=33 tools/build_radar.sh sim` 或 `FRAME_MS=50 tools/build_radar.sh sim`。",
                "如果伴随屏闪，同时测试 `DISPLAY_BUS_HZ=40000000 tools/build_radar.sh sim`。",
            ],
        )
    return (
        "refresh-unknown",
        "DIAG 可见，但缺少完整 drawAvgMs/drawMaxMs/overBudget 刷新字段。",
        [
            "确认固件已经包含刷新性能 DIAG 字段。",
            "运行 `tools/monitor_diag.py --timeout 12` 采集更长窗口。",
        ],
    )


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    command = None if args.passive else command_char(args.command)
    sample_lines = list(args.sample_line)
    if args.sample_report:
        sample_lines.extend(sample_lines_from_report(load_json(args.sample_report), command))
    sample_mode = bool(sample_lines)
    if args.dry_run or sample_mode:
        port = args.port or os.environ.get("RADAR_PORT") or "/dev/cu.usbmodem101"
        port_source = "sample" if sample_mode else "dry-run"
    else:
        port, port_source = resolve_port(args.port)
    if args.dry_run:
        return {
            "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
            "status": "dry-run",
            "summary": "未打开串口；只记录无手动 Reset 显示检查计划。",
            "hardwareProof": False,
            "liveSerialEvidence": False,
            "sampleMode": False,
            "port": port,
            "portSource": port_source,
            "command": command,
            "commandConfirmed": False,
            "parsed": {},
            "recommendations": [
                "连接板子后去掉 `--dry-run` 重跑。",
                "如果串口无 DIAG，先运行 `tools/recover_board_runtime.py`。",
            ],
            "lines": [],
        }
    serial_error = None
    initial_lines: list[str] = []
    command_lines: list[str] = []
    if sample_mode:
        command_lines = sample_lines
    elif not port:
        serial_error = f"cannot resolve a unique radar serial port ({port_source})"
    else:
        initial_lines, serial_error = sample_serial(port, args.baud, args.timeout)
        if not serial_error and command:
            command_lines, serial_error = send_command_and_capture(port, args.baud, command, args.timeout)
    lines = initial_lines + command_lines
    parsed = parse_lines(lines)
    confirmed = command_confirmed(lines, command)
    status, summary, recommendations = classify_refresh(parsed, serial_error, confirmed, command)
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "summary": summary,
        "hardwareProof": False,
        "liveSerialEvidence": bool(not sample_mode and port and not args.dry_run),
        "sampleMode": sample_mode,
        "port": port,
        "portSource": port_source,
        "command": command,
        "commandAction": command_action(command) if command else "passive",
        "commandConfirmed": confirmed,
        "serialError": serial_error,
        "parsed": parsed,
        "recommendations": recommendations,
        "initialLines": initial_lines,
        "commandLines": command_lines,
        "lines": lines,
    }


def render_markdown(report: dict[str, Any]) -> str:
    parsed = report.get("parsed", {})
    lines = [
        "# 龙珠雷达无 Reset 显示检查报告",
        "",
        f"- 生成时间: {report['generated']}",
        f"- 状态: `{report['status']}`",
        f"- 结论: {report['summary']}",
        f"- 端口: `{report.get('port') or '-'}`",
        f"- 命令: `{report.get('command') or 'passive'}` / `{report.get('commandAction', '-')}`",
        f"- 命令确认: `{report.get('commandConfirmed')}`",
        f"- 硬件证明: `{str(report.get('hardwareProof')).lower()}`；本报告不能单独证明 goal 完成。",
        f"- 实时串口证据: `{str(report.get('liveSerialEvidence')).lower()}`",
        f"- 样本模式: `{str(report.get('sampleMode')).lower()}`",
        "",
        "## 刷新指标",
        "",
        "| 指标 | 当前值 |",
        "| --- | --- |",
        f"| frameMs | `{parsed.get('frameMs') or '-'}` |",
        f"| drawMs | `{parsed.get('drawMs') or '-'}` |",
        f"| drawAvgMs | `{parsed.get('drawAvgMs') or '-'}` |",
        f"| drawMaxMs | `{parsed.get('drawMaxMs') or '-'}` |",
        f"| overBudget | `{parsed.get('overBudgetFrames') or 0}/{parsed.get('frameSamples') or '-'}` |",
        f"| collected | `{parsed.get('collected') or 0}` |",
        f"| summon | `{parsed.get('summon', False)}` |",
        "",
        "## 建议动作",
        "",
    ]
    lines.extend(f"{idx}. {item}" for idx, item in enumerate(report.get("recommendations", []), start=1))
    lines.extend(
        [
            "",
            "## 无手动 Reset 路径",
            "",
            "- 被动诊断：`RADAR_PORT=/dev/cu.usbmodem101 tools/run_no_reset_display_check.py --passive`。",
            "- 切最快刷新并检查：`RADAR_PORT=/dev/cu.usbmodem101 tools/run_no_reset_display_check.py --command turbo`。",
            "- 单独发命令：`RADAR_PORT=/dev/cu.usbmodem101 tools/send_diag_command.py turbo`。",
            "- 无 DIAG 时恢复运行态：`RADAR_PORT=/dev/cu.usbmodem101 tools/recover_board_runtime.py`。",
            "",
            "## 串口样本",
            "",
        ]
    )
    sample = report.get("lines", [])[:30]
    if sample:
        lines.extend(f"- `{line}`" for line in sample)
    else:
        lines.append("- 没有串口样本。")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    report = build_report(args)
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
    return 1 if report["status"] in {"serial-open-failed", "no-diag"} else 0


if __name__ == "__main__":
    raise SystemExit(main())
