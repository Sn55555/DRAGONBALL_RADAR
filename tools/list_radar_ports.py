#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
from dataclasses import asdict, dataclass
from typing import Iterable


LIKELY_PREFIXES = (
    "/dev/cu.usbmodem",
    "/dev/cu.usbserial",
    "/dev/cu.wchusbserial",
    "/dev/ttyACM",
    "/dev/ttyUSB",
)
EXCLUDE_HINTS = ("bluetooth", "buds", "debug-console", "wireless", "headset")
POSITIVE_HINTS = ("esp32", "esp", "usb jtag", "usb-to-uart", "uart", "serial", "cdc", "modem", "cp210", "ch340", "wch")


@dataclass
class PortInfo:
    device: str
    description: str
    hwid: str
    score: int
    reason: str

    @property
    def likely(self) -> bool:
        return self.score >= 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="List serial ports and identify likely Dragon Radar ESP32-S3 ports.")
    parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    parser.add_argument("--shell", action="store_true", help="Print an export command when one likely port is found.")
    parser.add_argument("--require", action="store_true", help="Exit nonzero unless exactly one likely port is found.")
    parser.add_argument(
        "--sample",
        action="append",
        default=[],
        metavar="DEVICE|DESCRIPTION|HWID",
        help="Use sample port data instead of live serial ports. May be passed more than once.",
    )
    return parser.parse_args()


def load_live_ports() -> list[tuple[str, str, str]]:
    try:
        from serial.tools import list_ports  # type: ignore
    except ImportError as exc:
        raise SystemExit("pyserial is required; run through the PlatformIO Python environment") from exc
    return [(port.device, port.description or "", port.hwid or "") for port in list_ports.comports()]


def parse_sample(rows: Iterable[str]) -> list[tuple[str, str, str]]:
    ports: list[tuple[str, str, str]] = []
    for row in rows:
        parts = row.split("|", 2)
        while len(parts) < 3:
            parts.append("")
        ports.append((parts[0], parts[1], parts[2]))
    return ports


def score_port(device: str, description: str, hwid: str) -> tuple[int, str]:
    haystack = " ".join((device, description, hwid)).lower()
    reasons: list[str] = []
    score = 0

    if any(hint in haystack for hint in EXCLUDE_HINTS):
        return -2, "excluded consumer/debug port"
    if device.startswith(LIKELY_PREFIXES):
        score += 3
        reasons.append("USB serial prefix")
    if re.match(r"^COM\d+$", device, flags=re.IGNORECASE):
        score += 2
        reasons.append("Windows COM port")
    for hint in POSITIVE_HINTS:
        if hint in haystack:
            score += 1
            reasons.append(hint)
            break
    if "303a" in haystack or "1a86" in haystack or "10c4" in haystack:
        score += 1
        reasons.append("known USB VID")
    if not reasons:
        reasons.append("no ESP32 hint")
    return score, ", ".join(reasons)


def collect_ports(samples: list[str]) -> list[PortInfo]:
    rows = parse_sample(samples) if samples else load_live_ports()
    ports = []
    for device, description, hwid in rows:
        score, reason = score_port(device, description, hwid)
        ports.append(PortInfo(device=device, description=description or "n/a", hwid=hwid or "n/a", score=score, reason=reason))
    return sorted(ports, key=lambda item: (-item.score, item.device))


def print_text(ports: list[PortInfo]) -> None:
    print("Dragon Radar Serial Ports")
    if not ports:
        print("No serial ports found.")
        print("Connect the ESP32-S3 board, then rerun: tools/list_radar_ports.py")
        return

    print("| Status | Port | Description | Reason |")
    print("| --- | --- | --- | --- |")
    for port in ports:
        status = "LIKELY" if port.likely else "skip"
        print(f"| {status} | `{port.device}` | {port.description} | {port.reason} |")

    likely = [port for port in ports if port.likely]
    print()
    if len(likely) == 1:
        print(f"Use: export RADAR_PORT={likely[0].device}")
    elif len(likely) > 1:
        print("Multiple likely ports found; unplug extras or set RADAR_PORT manually.")
    else:
        print("No likely ESP32-S3 port found. Avoid Bluetooth/headset/debug-console ports.")


def main() -> int:
    args = parse_args()
    ports = collect_ports(args.sample)
    likely = [port for port in ports if port.likely]

    if args.json:
        print(json.dumps({"ports": [asdict(port) for port in ports], "likely": [port.device for port in likely]}, indent=2))
    elif args.shell:
        if len(likely) == 1:
            print(f"export RADAR_PORT={likely[0].device}")
        else:
            print_text(ports)
    else:
        print_text(ports)

    if args.require and len(likely) != 1:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
