#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import sys
import time


COMMANDS = {
    "help": "?",
    "hardware": "h",
    "zoom": "z",
    "reset": "r",
    "brightness": "b",
    "audio": "a",
    "frame": "f",
    "frame_rate": "f",
    "turbo": "t",
    "frame_turbo": "t",
    "collect": "c",
    "ping": "p",
    "scan": "s",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Send a single hidden DIAG command to Dragon Radar over USB serial."
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="help",
        help="Command name or raw one-character command. Names: " + ", ".join(sorted(COMMANDS)),
    )
    parser.add_argument("--port", default=os.environ.get("RADAR_PORT"), help="Serial port, e.g. /dev/cu.usbmodem101.")
    parser.add_argument("--baud", default=os.environ.get("DIAG_BAUD", "115200"), help="Baud rate, default: 115200.")
    parser.add_argument("--timeout", type=float, default=8.0, help="Seconds to wait for DIAG command echo.")
    parser.add_argument("--no-wait", action="store_true", help="Send command without waiting for confirmation.")
    parser.add_argument("--list-ports", action="store_true", help="List serial ports and exit.")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be sent without opening serial.")
    return parser.parse_args()


def command_char(value: str) -> str:
    if value in COMMANDS:
        return COMMANDS[value]
    if len(value) == 1:
        return value
    raise SystemExit(f"unknown command: {value}")


def load_serial_modules():
    try:
        import serial  # type: ignore
        from serial.tools import list_ports  # type: ignore
    except ImportError as exc:
        raise SystemExit("pyserial is required; install it or run through the PlatformIO Python environment") from exc
    return serial, list_ports


def candidate_ports(list_ports_module) -> list[str]:
    preferred_prefixes = (
        "/dev/cu.usbmodem",
        "/dev/cu.usbserial",
        "/dev/cu.wchusbserial",
        "/dev/ttyACM",
        "/dev/ttyUSB",
        "COM",
    )
    ports = [port.device for port in list_ports_module.comports()]
    preferred = [port for port in ports if port.startswith(preferred_prefixes)]
    return preferred or ports


def resolve_port(args: argparse.Namespace, list_ports_module) -> str:
    if args.port:
        return args.port
    ports = candidate_ports(list_ports_module)
    if not ports:
        raise SystemExit("no serial ports found; set RADAR_PORT=/dev/cu.usbmodem101")
    if len(ports) > 1:
        joined = "\n  ".join(ports)
        raise SystemExit(f"multiple serial ports found; pass --port or RADAR_PORT:\n  {joined}")
    return ports[0]


def print_ports(list_ports_module) -> None:
    for port in list_ports_module.comports():
        label = f"{port.device}"
        if port.description:
            label += f"  {port.description}"
        if port.hwid:
            label += f"  {port.hwid}"
        print(label)


def send_command(serial_module, port: str, baud: str, command: str, timeout: float, wait: bool) -> int:
    expected = f"DIAG command {command.lower()} action="
    started = time.monotonic()
    seen = False

    with serial_module.Serial(port=port, baudrate=int(baud), timeout=0.05, write_timeout=1) as ser:
        ser.dtr = False
        ser.rts = False
        time.sleep(0.05)
        ser.reset_input_buffer()
        ser.write(command.encode("ascii"))
        ser.write(b"\n")
        ser.flush()

        if not wait:
            print(f"SENT {command} to {port}")
            return 0

        buffer = b""
        while time.monotonic() - started < timeout:
            chunk = ser.read(256)
            if not chunk:
                continue
            buffer += chunk
            while b"\n" in buffer:
                raw, buffer = buffer.split(b"\n", 1)
                line = raw.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                print(line)
                if expected in line:
                    seen = True
                    break
            if seen:
                break

    if not seen:
        print(
            f"CHECK failed: did not see '{expected}' within {timeout:.1f}s. "
            "Confirm the radar is running a diag/sim firmware build.",
            file=sys.stderr,
        )
        return 1
    print("CHECK passed")
    return 0


def main() -> int:
    args = parse_args()
    serial_module, list_ports_module = load_serial_modules()

    if args.list_ports:
        print_ports(list_ports_module)
        return 0

    command = command_char(args.command)
    port = resolve_port(args, list_ports_module)
    if args.dry_run:
        print(f"PORT {port}")
        print(f"COMMAND {command}")
        return 0
    return send_command(serial_module, port, args.baud, command, args.timeout, not args.no_wait)


if __name__ == "__main__":
    raise SystemExit(main())
