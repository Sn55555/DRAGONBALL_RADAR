#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a Chinese USB bring-up card for Dragon Radar hardware.")
    parser.add_argument("--output", default="output/usb-bringup-card.zh.md", help="Output Markdown path.")
    parser.add_argument("--release-dir", default=os.environ.get("RELEASE_DIR", "output/release-current"))
    parser.add_argument("--diagnosis-json", default=None, help="USB diagnosis JSON path. Default: release evidence or output/usb-serial-diagnosis.json.")
    parser.add_argument("--radar-port", default=os.environ.get("RADAR_PORT", "/dev/cu.usbmodem101"))
    return parser.parse_args()


def normalize(path: str | Path) -> Path:
    item = Path(path)
    return item if item.is_absolute() else ROOT / item


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def choose_diagnosis(args: argparse.Namespace, release_dir: Path) -> Path:
    if args.diagnosis_json:
        return normalize(args.diagnosis_json)
    for candidate in (
        release_dir / "evidence" / "usb-serial-diagnosis.json",
        ROOT / "output" / "usb-serial-diagnosis.json",
    ):
        if candidate.exists():
            return candidate
    return ROOT / "output" / "usb-serial-diagnosis.json"


def port_rows(report: dict[str, Any]) -> list[str]:
    ports = report.get("ports", [])
    if not isinstance(ports, list) or not ports:
        return ["| - | 未发现 | - | - |"]
    rows: list[str] = []
    for item in ports:
        if not isinstance(item, dict):
            continue
        rows.append(
            f"| {item.get('status', 'unknown')} | `{item.get('device', '-')}` | "
            f"{item.get('description', 'n/a')} | {item.get('reason', 'n/a')} |"
        )
    return rows


def usb_rows(report: dict[str, Any]) -> list[str]:
    devices = report.get("usbDevices", [])
    if not isinstance(devices, list) or not devices:
        return ["| - | 未发现 | - | - | - |"]
    rows: list[str] = []
    for item in devices:
        if not isinstance(item, dict):
            continue
        rows.append(
            f"| {item.get('status', 'unknown')} | {item.get('name', 'USB device')} | "
            f"`{item.get('vendorId', '')}` | `{item.get('productId', '')}` | {item.get('reason', 'n/a')} |"
        )
    return rows


def recovery_steps(status: str, radar_port: str, usb_layer_status: str) -> list[str]:
    if status == "ready":
        return [
            f"设置端口：`export RADAR_PORT={radar_port}`。",
            f"跑一块板模拟：`RADAR_PORT={radar_port} tools/first_run_zh.py auto`。",
            f"准备 7 个实体信标后跑完整验收：`RADAR_PORT={radar_port} tools/run_release_acceptance.sh all`。",
        ]
    if usb_layer_status == "radar-usb-present":
        return [
            "系统 USB 层已经看到疑似 ESP32/USB-JTAG，但串口层没有可用端口，先处理下载模式或驱动/权限问题。",
            "按住 BOOT，再点 Reset，松开 BOOT 后运行 `tools/diagnose_usb_serial.py`。",
            "关闭 Arduino Serial Monitor、PlatformIO monitor、esptool 或其他可能占用串口的程序。",
            "运行 `tools/wait_for_radar_port.py --timeout 300 --interval 2 --run-auto`，边按 Reset/BOOT 边等串口出现。",
            "如果 USB 层一直有设备但 `/dev/cu.usbmodem*` 不出现，换一台电脑交叉验证，或检查 USB CDC/JTAG、CP210/CH340 驱动。",
        ]
    if status == "multiple-candidates":
        return [
            "拔掉其他 ESP32、USB-TTL、串口模块，只保留龙珠雷达主板。",
            "重新运行 `tools/diagnose_usb_serial.py`，直到只剩一个 likely 端口。",
            f"如果你确认端口，显式运行：`RADAR_PORT={radar_port} tools/first_run_zh.py auto --dry-run`。",
        ]
    if status in {"only-ignored", "no-ports", "no-likely"}:
        return [
            "换一根明确支持数据传输的 USB-C 线，优先直连电脑，不走扩展坞。",
            "按一下 Reset 后重新插拔；仍不可见时按住 BOOT，再点 Reset，松开 BOOT 后重试。",
            "运行 `tools/list_radar_ports.py --shell` 看是否出现 `/dev/cu.usbmodem*`、`/dev/cu.usbserial*` 或 `/dev/cu.wchusbserial*`。",
            "运行 `tools/wait_for_radar_port.py --timeout 300 --interval 2 --run-auto`，边换线/按键边等串口出现。",
            "如果系统 USB 信息能看到 ESP32-S3 但没有串口，检查驱动、权限或换一台电脑交叉验证。",
        ]
    return [
        "先运行 `tools/diagnose_usb_serial.py` 生成最新诊断。",
        "再运行 `tools/wait_for_radar_port.py --run-auto` 等待串口并自动上板模拟。",
    ]


def no_manual_reset_steps(radar_port: str) -> list[str]:
    return [
        "先关闭 Arduino Serial Monitor、PlatformIO monitor、esptool、screen、minicom 等占用串口的程序。",
        f"如果已有串口但没有 DIAG，运行：`RADAR_PORT={radar_port} tools/recover_board_runtime.py`。它会尝试释放 DTR/RTS、app reset、BOOT/Reset 线序和 esptool 探测。",
        f"如果想让首跑助手自动执行这步，运行：`RADAR_PORT={radar_port} tools/first_run_zh.py live --recover-runtime`。",
        f"如果恢复报告显示 `bootloader-reachable`，先 dry-run 确认命令：`RADAR_PORT={radar_port} FLASH_DRY_RUN=1 tools/flash_release_firmware.sh sim`。",
        f"确认端口无误后重刷 sim factory：`RADAR_PORT={radar_port} tools/flash_release_firmware.sh sim`。这个脚本使用 esptool 的自动 reset 线序，不要求先手按 Reset。",
        "如果串口会消失/重现，运行：`tools/wait_for_radar_port.py --timeout 300 --interval 2 --run-auto`，让工具等端口出现后继续跑一块板模拟。",
        "只有上述自动路径都失败时，才进入实体 Reset/BOOT 或重新插拔 USB-C。",
    ]


def render(args: argparse.Namespace) -> str:
    release_dir = normalize(args.release_dir)
    diagnosis_path = choose_diagnosis(args, release_dir)
    report = load_json(diagnosis_path)
    selected = report.get("selectedPort") or args.radar_port
    status = str(report.get("status", "missing"))
    summary = str(report.get("summary", "没有可用 USB 诊断报告。"))
    usb_layer_status = str(report.get("usbLayerStatus", "missing"))
    usb_layer_summary = str(report.get("usbLayerSummary", "没有 USB 设备层诊断。"))
    generated = time.strftime("%Y-%m-%d %H:%M:%S")

    lines = [
        "# 龙珠雷达 USB 上板排障卡",
        "",
        f"- 生成时间: {generated}",
        f"- 当前诊断: `{status}`",
        f"- 结论: {summary}",
        f"- USB 设备层: `{usb_layer_status}` - {usb_layer_summary}",
        f"- 建议端口占位: `{selected}`",
        f"- 诊断来源: `{diagnosis_path}`",
        "",
        "## 当前端口",
        "",
        "| 状态 | 端口 | 描述 | 原因 |",
        "| --- | --- | --- | --- |",
    ]
    lines.extend(port_rows(report))
    lines.extend(
        [
            "",
            "## USB 设备层",
            "",
            "| 状态 | 名称 | VID | PID | 原因 |",
            "| --- | --- | --- | --- | --- |",
        ]
    )
    lines.extend(usb_rows(report))
    lines.extend(["", "## 现场排障顺序", ""])
    lines.extend(f"{idx}. {step}" for idx, step in enumerate(recovery_steps(status, str(selected), usb_layer_status), start=1))
    lines.extend(["", "## 无法手动 Reset 时", ""])
    lines.extend(f"{idx}. {step}" for idx, step in enumerate(no_manual_reset_steps(str(selected)), start=1))
    lines.extend(
        [
            "",
            "## macOS 快速判断",
            "",
            "- `ls /dev/cu.*`：确认是否出现新的 `usbmodem`、`usbserial`、`wchusbserial` 端口。",
            "- `system_profiler SPUSBDataType`：确认系统 USB 层是否看到了 ESP32-S3、USB JTAG、CP210、CH340 或 WCH 设备。",
            "- 如果 USB 层能看到设备但没有串口，优先换线/换口，再考虑驱动或系统权限。",
            "",
            "## 串口出现后",
            "",
            f"- 等待并自动跑一块板模拟：`RADAR_PORT={selected} tools/wait_for_radar_port.py --run-auto`。",
            f"- 一块板模拟：`RADAR_PORT={selected} tools/first_run_zh.py auto`。",
            f"- 完整硬件验收：`RADAR_PORT={selected} tools/run_hardware_acceptance.sh all`。",
            f"- release 内完整验收：`RADAR_PORT={selected} tools/run_release_acceptance.sh all`。",
            "",
            "## 验收边界",
            "",
            "- 这张卡只帮助电脑识别真板串口，不能单独证明项目完成。",
            "- goal 完成仍需要真板 bring-up、一块板 sim、7 个实体信标、干净 UI 实战收集和召唤全部有报告。",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    output = normalize(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(args), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
