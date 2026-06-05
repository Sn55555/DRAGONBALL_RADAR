#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
import time
from dataclasses import asdict
from pathlib import Path
from typing import Any

from list_radar_ports import PortInfo, collect_ports


ROOT = Path(__file__).resolve().parents[1]
USB_POSITIVE_HINTS = (
    "esp32",
    "esp",
    "espressif",
    "usb jtag",
    "jtag/serial",
    "usb-to-uart",
    "usb uart",
    "cdc",
    "serial",
    "uart",
    "cp210",
    "silicon labs",
    "ch340",
    "wch",
    "303a",
    "10c4",
    "1a86",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Diagnose Dragon Radar USB serial readiness and write a Chinese report."
    )
    parser.add_argument("--json-output", default="output/usb-serial-diagnosis.json", help="JSON report path.")
    parser.add_argument("--md-output", default="output/usb-serial-diagnosis.zh.md", help="Chinese Markdown report path.")
    parser.add_argument("--print-json", action="store_true", help="Print JSON to stdout instead of the text summary.")
    parser.add_argument("--require-port", action="store_true", help="Exit nonzero unless exactly one likely radar port is found.")
    parser.add_argument(
        "--sample",
        action="append",
        default=[],
        metavar="DEVICE|DESCRIPTION|HWID",
        help="Use sample port data instead of live serial ports. May be passed more than once.",
    )
    parser.add_argument(
        "--sample-usb",
        action="append",
        default=[],
        metavar="NAME|VENDOR_ID|PRODUCT_ID|SERIAL|LOCATION",
        help="Use sample USB device rows instead of system_profiler. May be passed more than once.",
    )
    parser.add_argument("--skip-usb-layer", action="store_true", help="Skip macOS USB device-layer inspection.")
    return parser.parse_args()


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def normalize_path(value: str) -> Path:
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def port_status(port: PortInfo) -> str:
    if port.likely:
        return "likely"
    if port.score < 0:
        return "ignored"
    return "unknown"


def sample_usb_device(row: str) -> dict[str, Any]:
    parts = (row.split("|") + ["", "", "", "", ""])[:5]
    return {
        "name": parts[0] or "USB device",
        "vendorId": parts[1],
        "productId": parts[2],
        "serialNumber": parts[3],
        "locationId": parts[4],
    }


def usb_reason(device: dict[str, Any]) -> tuple[str, bool]:
    text = " ".join(str(device.get(key, "")) for key in ("name", "vendorId", "productId", "serialNumber")).lower()
    hits = [hint for hint in USB_POSITIVE_HINTS if hint in text]
    if hits:
        return "likely ESP32/USB-serial USB device: " + ", ".join(hits[:3]), True
    return "USB device not radar-specific", False


def normalize_usb_device(raw: dict[str, Any]) -> dict[str, Any]:
    name = str(raw.get("_name") or raw.get("name") or raw.get("manufacturer") or "USB device")
    device = {
        "name": name,
        "vendorId": str(raw.get("vendor_id") or raw.get("vendorId") or ""),
        "productId": str(raw.get("product_id") or raw.get("productId") or ""),
        "serialNumber": str(raw.get("serial_num") or raw.get("serialNumber") or raw.get("serial_num_str") or ""),
        "locationId": str(raw.get("location_id") or raw.get("locationId") or ""),
    }
    reason, likely = usb_reason(device)
    device["status"] = "likely" if likely else "unknown"
    device["likely"] = likely
    device["reason"] = reason
    return device


def walk_usb_items(items: Any) -> list[dict[str, Any]]:
    devices: list[dict[str, Any]] = []
    if isinstance(items, list):
        for item in items:
            devices.extend(walk_usb_items(item))
        return devices
    if not isinstance(items, dict):
        return devices
    if items.get("_name") or items.get("vendor_id") or items.get("product_id"):
        devices.append(normalize_usb_device(items))
    children = items.get("_items")
    if children:
        devices.extend(walk_usb_items(children))
    return devices


def collect_usb_devices(sample_usb: list[str], skip: bool) -> tuple[list[dict[str, Any]], str | None]:
    if skip:
        return [], "USB device-layer inspection skipped"
    if sample_usb:
        devices = [sample_usb_device(row) for row in sample_usb]
        return [normalize_usb_device(device) for device in devices], None
    try:
        proc = subprocess.run(
            ["system_profiler", "SPUSBDataType", "-json"],
            text=True,
            capture_output=True,
            timeout=8,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return [], f"cannot run system_profiler SPUSBDataType -json: {exc}"
    if proc.returncode != 0:
        message = proc.stderr.strip() or proc.stdout.strip() or f"system_profiler exited {proc.returncode}"
        return [], message
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return [], f"invalid system_profiler JSON: {exc}"
    return walk_usb_items(payload.get("SPUSBDataType", [])), None


def classify_usb_layer(devices: list[dict[str, Any]], error: str | None) -> tuple[str, str]:
    if error:
        return "unavailable", error
    likely = [device for device in devices if device.get("likely")]
    if likely:
        names = ", ".join(str(device.get("name", "USB device")) for device in likely[:3])
        return "radar-usb-present", f"系统 USB 层看到了疑似 ESP32/USB 串口设备：{names}"
    if not devices:
        return "no-usb-devices", "系统 USB 设备层没有列出任何 USB 设备。"
    return "no-radar-usb-device", "系统 USB 设备层没有看到疑似 ESP32-S3、USB-JTAG、CP210、CH340 或 WCH 设备。"


def classify(ports: list[PortInfo]) -> tuple[str, str, list[str]]:
    likely = [port for port in ports if port.likely]
    ignored = [port for port in ports if port.score < 0]

    if len(likely) == 1:
        return (
            "ready",
            f"找到唯一 ESP32-S3 串口候选：{likely[0].device}",
            [
                f"运行 `export RADAR_PORT={likely[0].device}`。",
                f"继续执行 `RADAR_PORT={likely[0].device} tools/first_run_zh.py auto`。",
                "如果刷机失败，先关闭其他串口监视器，再重试 `--erase`。",
            ],
        )
    if len(likely) > 1:
        joined = ", ".join(port.device for port in likely)
        return (
            "multiple-candidates",
            f"发现多个可能的 ESP32-S3 串口：{joined}",
            [
                "先只保留龙珠雷达主板连接，拔掉其他 ESP32/USB 串口设备。",
                "或者显式指定端口：`RADAR_PORT=/dev/cu.usbmodem101 tools/first_run_zh.py auto`。",
                "重新运行 `tools/diagnose_usb_serial.py` 确认可用候选只剩一个。",
            ],
        )
    if not ports:
        return (
            "no-ports",
            "系统没有列出任何串口设备。",
            [
                "确认 USB 线是数据线，不是只能充电的线。",
                "换电脑直连 USB 口，暂时避开扩展坞。",
                "确认开发板上电；按一次 Reset 后重新插拔。",
                "重新运行 `tools/diagnose_usb_serial.py`。",
            ],
        )
    if len(ignored) == len(ports):
        return (
            "only-ignored",
            "只看到了蓝牙、耳机或 debug-console 这类应忽略端口。",
            [
                "当前电脑还没识别到 ESP32-S3 的 USB CDC/JTAG 串口。",
                "优先换一根明确支持数据传输的 USB-C 线。",
                "换 USB 口或去掉扩展坞后重新运行 `tools/run_board_sim_test.py port-check`。",
                "按住 BOOT 再点 Reset 进入下载模式后重试刷机。",
            ],
        )
    return (
        "no-likely",
        "发现了串口，但没有足够证据判断哪个是 ESP32-S3。",
        [
            "拔掉无关串口设备，只保留雷达主板。",
            "如果你确认某个端口就是主板，显式设置 `RADAR_PORT=/dev/cu.xxx`。",
            "再运行 `RADAR_PORT=/dev/cu.xxx tools/first_run_zh.py auto --dry-run` 检查命令链。",
        ],
    )


def enrich_recommendations(status: str, recommendations: list[str], usb_layer_status: str) -> list[str]:
    extra: list[str] = []
    if status != "ready":
        if usb_layer_status == "radar-usb-present":
            extra.extend(
                [
                    "系统 USB 层看到了疑似雷达板，但串口层还没有可用端口；重点排查 USB CDC/JTAG 驱动、权限或串口占用。",
                    "按住 BOOT 再点 Reset，松开 BOOT 后重新运行 `tools/diagnose_usb_serial.py`。",
                ]
            )
        elif usb_layer_status in {"no-usb-devices", "no-radar-usb-device"}:
            extra.extend(
                [
                    "系统 USB 层也没有看到疑似 ESP32-S3；优先换数据线、直连电脑 USB 口，并确认主板供电。",
                    "如果换线后 USB 层出现设备但仍没有串口，再按 BOOT/Reset 进入下载模式。",
                ]
            )
        elif usb_layer_status == "unavailable":
            extra.append("无法读取 macOS USB 设备层；用 `system_profiler SPUSBDataType` 手动确认是否出现 ESP32-S3。")
    return extra + recommendations


def build_report(ports: list[PortInfo], usb_devices: list[dict[str, Any]], usb_error: str | None) -> dict[str, Any]:
    status, summary, recommendations = classify(ports)
    usb_layer_status, usb_layer_summary = classify_usb_layer(usb_devices, usb_error)
    likely = [port.device for port in ports if port.likely]
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "summary": summary,
        "usbLayerStatus": usb_layer_status,
        "usbLayerSummary": usb_layer_summary,
        "likelyPorts": likely,
        "selectedPort": likely[0] if len(likely) == 1 else None,
        "recommendations": enrich_recommendations(status, recommendations, usb_layer_status),
        "usbDevices": usb_devices,
        "ports": [
            {
                **asdict(port),
                "status": port_status(port),
                "likely": port.likely,
            }
            for port in ports
        ],
    }


def render_markdown(report: dict[str, Any]) -> str:
    selected = report.get("selectedPort") or "未选择"
    lines = [
        "# 龙珠雷达 USB 串口诊断",
        "",
        f"- 生成时间: {report['generated']}",
        f"- 状态: `{report['status']}`",
        f"- 结论: {report['summary']}",
        f"- USB 设备层: `{report.get('usbLayerStatus', 'missing')}` - {report.get('usbLayerSummary', '')}",
        f"- 选中串口: `{selected}`",
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
    lines.extend(["", "## USB 设备层", ""])
    usb_devices = report.get("usbDevices", [])
    if not usb_devices:
        lines.append(f"- {report.get('usbLayerSummary', '没有 USB 设备层信息。')}")
    else:
        lines.extend(["| 状态 | 名称 | VID | PID | 序列号 | 原因 |", "| --- | --- | --- | --- | --- | --- |"])
        for device in usb_devices:
            label = "疑似雷达板" if device.get("likely") else "普通 USB"
            lines.append(
                f"| {label} | {device.get('name', 'USB device')} | `{device.get('vendorId', '')}` | "
                f"`{device.get('productId', '')}` | `{device.get('serialNumber', '')}` | {device.get('reason', '')} |"
            )
    lines.extend(["", "## 建议动作", ""])
    lines.extend(f"- {item}" for item in report.get("recommendations", []))
    lines.extend(
        [
            "",
            "## 验收边界",
            "",
            "- 这个诊断只证明电脑是否能看到可能的雷达串口。",
            "- 真正的硬件证明仍然需要 `tools/first_run_zh.py auto` 或 `tools/run_hardware_acceptance.sh all` 通过。",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    ports = collect_ports(args.sample)
    usb_devices, usb_error = collect_usb_devices(args.sample_usb, args.skip_usb_layer)
    report = build_report(ports, usb_devices, usb_error)

    json_path = normalize_path(args.json_output)
    md_path = normalize_path(args.md_output)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(report), encoding="utf-8")

    if args.print_json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"STATUS {report['status']}")
        print(f"SUMMARY {report['summary']}")
        print(f"JSON {rel(json_path)}")
        print(f"MARKDOWN {rel(md_path)}")

    if args.require_port and report.get("selectedPort") is None:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
