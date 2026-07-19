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


def default_release_dir() -> Path:
    if (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir():
        return ROOT
    return ROOT / "output" / "release-current"


def default_output_dir(mode: str) -> Path:
    if (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir():
        return ROOT / "evidence" / ("board-sim-mock" if mode == "mock" else "board-sim")
    return ROOT / "output" / ("board-sim-mock" if mode == "mock" else "board-sim-current")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run or preview the one-board simulated Capsule hardware test."
    )
    parser.add_argument(
        "mode",
        nargs="?",
        choices=("auto", "port-check", "mock", "commands"),
        default="auto",
        help=(
            "auto flashes the packaged sim image and monitors the board; "
            "port-check only lists candidate serial ports; mock validates local tools; "
            "commands prints the manual flow."
        ),
    )
    parser.add_argument("--port", default=os.environ.get("RADAR_PORT"), help="Serial port, e.g. /dev/cu.usbmodem101.")
    parser.add_argument("--release-dir", default=os.environ.get("RELEASE_DIR"), help="Release folder. Default: output/release-current or the copied release root.")
    parser.add_argument("--output-dir", default=None, help="Report folder. Default: output/board-sim-current or evidence/board-sim.")
    parser.add_argument("--timeout", default=os.environ.get("BOARD_SIM_TIMEOUT", "45"), help="Monitor timeout seconds, default: 45.")
    parser.add_argument("--erase", action="store_true", help="Erase flash before writing the packaged sim image.")
    parser.add_argument("--raw", action="store_true", help="Show raw DIAG lines during monitor.")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without flashing or monitoring.")
    parser.add_argument("--require-port", action="store_true", help="Fail port-check unless exactly one likely ESP32-S3 port is found.")
    parser.add_argument("--json-output", default=None, help="Summary JSON path for real auto/mock runs. Default: <output-dir>/board-sim-summary.json.")
    parser.add_argument(
        "--sample-port",
        action="append",
        default=[],
        metavar="DEVICE|DESCRIPTION|HWID",
        help="Use sample serial port rows for deterministic tests. May be passed more than once.",
    )
    return parser.parse_args()


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def tool(name: str) -> Path:
    return ROOT / "tools" / name


def normalize_path(value: str | None, fallback: Path) -> Path:
    path = Path(value) if value else fallback
    return path if path.is_absolute() else ROOT / path


def command_line(cmd: list[str], env: dict[str, str] | None = None) -> str:
    if env:
        parts = ["env"] + [f"{key}={value}" for key, value in env.items()] + cmd
    else:
        parts = cmd
    return shlex.join(parts)


def run(cmd: list[str], *, env: dict[str, str] | None = None, dry_run: bool = False) -> int:
    print("+ " + command_line(cmd, env), flush=True)
    if dry_run:
        return 0
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(cmd, env=merged, check=False).returncode


def load_ports(sample_ports: list[str]) -> tuple[list[dict[str, Any]], str | None]:
    cmd = [str(tool("list_radar_ports.py")), "--json"]
    for sample in sample_ports:
        cmd += ["--sample", sample]
    proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        return [], proc.stderr.strip() or proc.stdout.strip() or "port helper failed"
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return [], f"invalid port helper JSON: {exc}"
    ports = data.get("ports", [])
    return ports if isinstance(ports, list) else [], None


def print_ports(ports: list[dict[str, Any]], error: str | None = None) -> list[str]:
    print("Capsule board simulation port check")
    if error:
        print(f"Port helper error: {error}")
        return []
    if not ports:
        print("No serial ports found.")
        print("Connect the ESP32-S3 board by USB, use a data-capable cable, then rerun this command.")
        return []

    likely: list[str] = []
    print("| Status | Port | Description | Reason |")
    print("| --- | --- | --- | --- |")
    for port in ports:
        device = str(port.get("device", ""))
        description = str(port.get("description", "n/a"))
        reason = str(port.get("reason", "n/a"))
        is_likely = bool(port.get("score", 0) >= 2)
        if is_likely:
            likely.append(device)
        print(f"| {'LIKELY' if is_likely else 'skip'} | `{device}` | {description} | {reason} |")
    if len(likely) == 1:
        print(f"Selected RADAR_PORT={likely[0]}")
    elif len(likely) > 1:
        print("Multiple likely ESP32-S3 ports found; pass --port or unplug extra boards.")
    else:
        print("No likely ESP32-S3 port found. Ignore Bluetooth, headset, and debug-console ports.")
    return likely


def resolve_port(args: argparse.Namespace) -> tuple[str | None, list[dict[str, Any]], str | None]:
    ports, error = load_ports(args.sample_port)
    likely = print_ports(ports, error)
    if args.port:
        print(f"Using explicit RADAR_PORT={args.port}")
        return args.port, ports, error
    if len(likely) == 1:
        return likely[0], ports, error
    return None, ports, error


def print_commands(release_dir: Path, output_dir: Path, port: str | None) -> None:
    port_text = port or "/dev/cu.usbmodem101"
    print("Recommended one-board simulation flow:")
    print(f"  tools/list_radar_ports.py --shell")
    print(f"  RADAR_PORT={port_text} tools/run_board_sim_test.py auto")
    print(f"  RADAR_PORT={port_text} tools/smoke_release_board.sh all")
    print(f"  RELEASE_ACCEPTANCE_MOCK=1 tools/run_board_sim_test.py mock")
    print()
    print("Expected report outputs:")
    print(f"  {rel(output_dir / 'bench-sim-report.json')}")
    print(f"  {rel(output_dir / 'bench-sim-report.md')}")
    print(f"  {rel(output_dir / 'bench-sim-raw.log')}")
    print()
    print(f"Release folder: {rel(release_dir)}")


def verify_release(release_dir: Path, dry_run: bool) -> int:
    verifier = tool("verify_release_package.py")
    if not verifier.exists():
        print("Release verifier is missing; cannot prove packaged sim firmware exists.", file=sys.stderr)
        return 1
    if not release_dir.exists():
        print(f"Release folder missing: {release_dir}", file=sys.stderr)
        print("Build it first: RELEASE_DIR=output/release-current RELEASE_TAR=1 tools/package_release.sh", file=sys.stderr)
        return 1
    return run([str(verifier), str(release_dir)], dry_run=dry_run)


def write_summary(path: Path | None, data: dict[str, Any]) -> None:
    if not path:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    print(f"summary {rel(path)}")


def main() -> int:
    args = parse_args()
    try:
        timeout = int(args.timeout)
    except ValueError:
        raise SystemExit(f"--timeout must be an integer, got: {args.timeout}")
    if timeout < 0:
        raise SystemExit("--timeout must be non-negative")

    release_dir = normalize_path(args.release_dir, default_release_dir())
    output_dir = normalize_path(args.output_dir, default_output_dir(args.mode))
    json_output = normalize_path(args.json_output, output_dir / "board-sim-summary.json")

    if args.mode == "commands":
        print_commands(release_dir, output_dir, args.port)
        return 0

    selected_port: str | None = None
    ports: list[dict[str, Any]] = []
    port_error: str | None = None
    if args.mode in ("auto", "port-check"):
        selected_port, ports, port_error = resolve_port(args)
        if args.mode == "port-check":
            if args.require_port and not selected_port:
                return 2
            return 0

    if args.mode == "mock":
        if not args.dry_run:
            output_dir.mkdir(parents=True, exist_ok=True)
        env = {
            "RELEASE_DIR": str(release_dir),
            "RELEASE_ACCEPTANCE_MOCK": "1",
            "RELEASE_ACCEPTANCE_DIR": str(output_dir),
            "ACCEPTANCE_SIM_TIMEOUT": str(timeout),
        }
        rc = run([str(tool("run_release_acceptance.sh")), "sim"], env=env, dry_run=args.dry_run)
        write_summary(
            None if args.dry_run else json_output,
            {
                "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
                "mode": "mock",
                "status": "passed" if rc == 0 else "failed",
                "releaseDir": str(release_dir),
                "outputDir": str(output_dir),
                "hardwareProof": False,
            },
        )
        return rc

    if not selected_port:
        print("Cannot run the board simulation without a single ESP32-S3 serial port.", file=sys.stderr)
        print("Run `tools/run_board_sim_test.py port-check` after plugging in the board.", file=sys.stderr)
        print("For tool-only validation without hardware, run `tools/run_board_sim_test.py mock`.", file=sys.stderr)
        return 2 if not port_error else 1

    rc = verify_release(release_dir, args.dry_run)
    if rc != 0:
        return rc

    env = {
        "RELEASE_DIR": str(release_dir),
        "RADAR_PORT": selected_port,
        "SMOKE_OUTPUT_DIR": str(output_dir),
        "SMOKE_TIMEOUT": str(timeout),
        "SMOKE_ERASE": "1" if args.erase else "0",
        "SMOKE_RAW": "1" if args.raw else "0",
        "SMOKE_DRY_RUN": "1" if args.dry_run else "0",
    }
    rc = run([str(tool("smoke_release_board.sh")), "all"], env=env, dry_run=args.dry_run)
    write_summary(
        None if args.dry_run else json_output,
        {
            "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
            "mode": "auto",
            "status": "passed" if rc == 0 else "failed",
            "releaseDir": str(release_dir),
            "outputDir": str(output_dir),
            "radarPort": selected_port,
            "hardwareProof": rc == 0,
        },
    )
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
