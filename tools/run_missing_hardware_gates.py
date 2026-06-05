#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
HARDWARE_GATE_ORDER = ("seven_beacons", "field_hunt")


def in_release_root() -> bool:
    return (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir()


def default_packet() -> str:
    return "evidence/hardware-proof-packet.json" if in_release_root() else "output/hardware-proof-packet.json"


def default_json() -> str:
    return "evidence/missing-hardware-gates-plan.json" if in_release_root() else "output/missing-hardware-gates-plan.json"


def default_md() -> str:
    return "docs/missing-hardware-gates-plan.zh.md" if in_release_root() else "output/missing-hardware-gates-plan.zh.md"


def default_hardware_packet_md() -> str:
    return "docs/hardware-proof-packet.zh.md" if in_release_root() else "output/hardware-proof-packet.zh.md"


def default_usb_diagnosis() -> Path:
    return ROOT / ("evidence/usb-serial-diagnosis.json" if in_release_root() else "output/usb-serial-diagnosis.json")


def default_radar_port() -> str:
    env_port = os.environ.get("RADAR_PORT")
    if env_port:
        return env_port
    diagnosis = default_usb_diagnosis()
    if diagnosis.exists():
        try:
            data = json.loads(diagnosis.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = {}
        selected = data.get("selectedPort") if isinstance(data, dict) else None
        if isinstance(selected, str) and selected.startswith("/dev/"):
            return selected
    return "/dev/cu.usbmodem101"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plan or execute only the missing Dragon Radar hardware proof gates.")
    parser.add_argument(
        "--gate",
        choices=("missing", "all", "seven_beacons", "field_hunt", "status"),
        default="missing",
        help="Which gate(s) to plan. Default: missing gates from hardware proof packet.",
    )
    parser.add_argument("--execute", action="store_true", help="Actually run the selected hardware commands.")
    parser.add_argument("--packet", default=default_packet(), help="Hardware proof packet JSON path.")
    parser.add_argument("--json-output", default=default_json(), help="Plan/report JSON output path.")
    parser.add_argument("--md-output", default=default_md(), help="Chinese Markdown output path.")
    parser.add_argument("--radar-port", default=default_radar_port())
    parser.add_argument("--beacon-timeout", default=os.environ.get("BEACON_VERIFY_TIMEOUT", "90"))
    parser.add_argument("--hunt-timeout", default=os.environ.get("HUNT_TIMEOUT", "600"))
    parser.add_argument("--mode", choices=("all", "monitor"), default="all", help="Child gate mode. Default uploads then monitors.")
    parser.add_argument("--print-json", action="store_true", help="Print JSON report.")
    return parser.parse_args()


def norm(path: str | Path) -> Path:
    item = Path(path)
    return item if item.is_absolute() else ROOT / item


def load_json(path: str | Path) -> dict[str, Any]:
    item = norm(path)
    if not item.exists():
        return {}
    try:
        data = json.loads(item.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def script_path(name: str) -> str:
    return str(ROOT / "tools" / name)


def selected_gates(args: argparse.Namespace, packet: dict[str, Any]) -> list[str]:
    if args.gate == "all":
        return list(HARDWARE_GATE_ORDER)
    if args.gate in HARDWARE_GATE_ORDER:
        return [args.gate]
    if args.gate == "status":
        return ["status"]
    missing = [key for key in packet.get("missingGateKeys", []) if key in HARDWARE_GATE_ORDER]
    return missing or list(HARDWARE_GATE_ORDER)


def command_for(gate: str, args: argparse.Namespace) -> list[str]:
    if gate == "seven_beacons":
        return [
            "env",
            f"RADAR_PORT={args.radar_port}",
            f"BEACON_VERIFY_TIMEOUT={args.beacon_timeout}",
            "BEACON_VERIFY_REQUIRE_ONLINE=touch,imu,ble,audio",
            "BEACON_VERIFY_MIN_BEACONS=7",
            f"BEACON_VERIFY_DRY_RUN={'0' if args.execute else '1'}",
            script_path("verify_beacon_set.sh"),
            args.mode,
        ]
    if gate == "field_hunt":
        return [
            "env",
            f"RADAR_PORT={args.radar_port}",
            f"HUNT_TIMEOUT={args.hunt_timeout}",
            "HUNT_REQUIRE_ONLINE=touch,imu,ble,audio",
            "HUNT_MIN_BEACONS=7",
            "HUNT_MIN_COLLECTED=7",
            "HUNT_MIN_COLLECTIONS=7",
            "HUNT_REQUIRE_COLLECTION_SET=1",
            "HUNT_REQUIRE_SUMMON=1",
            f"HUNT_DRY_RUN={'0' if args.execute else '1'}",
            script_path("record_field_hunt.sh"),
            args.mode,
        ]
    if gate == "status":
        return [script_path("render_hardware_proof_packet.py"), "--json", default_packet(), "--md", default_hardware_packet_md()]
    raise ValueError(f"unknown gate {gate}")


def shell_join(command: list[str]) -> str:
    import shlex

    return " ".join(shlex.quote(part) for part in command)


def run_command(command: list[str], execute: bool) -> dict[str, Any]:
    if not execute:
        return {"status": "planned", "returnCode": None, "stdout": "", "stderr": ""}
    proc = subprocess.run(command, text=True, capture_output=True, check=False)
    return {
        "status": "passed" if proc.returncode == 0 else "failed",
        "returnCode": proc.returncode,
        "stdout": proc.stdout[-4000:],
        "stderr": proc.stderr[-4000:],
    }


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    packet = load_json(args.packet)
    gates = selected_gates(args, packet)
    steps: list[dict[str, Any]] = []
    for gate in gates:
        command = command_for(gate, args)
        result = run_command(command, args.execute)
        steps.append(
            {
                "gate": gate,
                "label": {
                    "seven_beacons": "7 个实体信标可见",
                    "field_hunt": "干净 UI 实战收集和召唤",
                    "status": "刷新硬件证明包",
                }.get(gate, gate),
                "command": command,
                "commandText": shell_join(command),
                "execute": args.execute,
                "result": result,
            }
        )
        if args.execute and result["status"] != "passed":
            break
    failed = [step for step in steps if step["result"]["status"] == "failed"]
    status = "failed" if failed else ("executed" if args.execute else "planned")
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "execute": args.execute,
        "hardwareProof": False,
        "packet": str(norm(args.packet)),
        "packetStatus": packet.get("status", "missing"),
        "packetMissingGateKeys": packet.get("missingGateKeys", []),
        "selectedGateKeys": gates,
        "steps": steps,
        "summary": "已执行缺失硬件 gate。" if args.execute else "仅生成缺失硬件 gate 执行计划；没有触碰硬件。",
    }


def render_markdown(report: dict[str, Any]) -> str:
    lines = [
        "# 龙珠雷达缺失硬件 Gate 收口计划",
        "",
        f"- 生成时间: {report['generated']}",
        f"- 状态: `{report['status']}`",
        f"- 执行模式: `{'execute' if report['execute'] else 'dry-run'}`",
        f"- 硬件证明: `{str(report['hardwareProof']).lower()}`",
        f"- 来源证明包: `{report['packet']}`",
        f"- 证明包状态: `{report['packetStatus']}`",
        f"- 证明包缺失项: `{','.join(report['packetMissingGateKeys']) or '-'}`",
        f"- 结论: {report['summary']}",
        "",
        "## 步骤",
        "",
        "| Gate | 状态 | 命令 |",
        "| --- | --- | --- |",
    ]
    for step in report["steps"]:
        lines.append(f"| {step['label']} | `{step['result']['status']}` | `{step['commandText']}` |")
    lines.extend(
        [
            "",
            "## 使用说明",
            "",
            "- 默认只生成计划，不会打开串口、上传固件或读取真板。",
            "- 真要收口时，确认 7 个实体 DBALL 信标已经上电，再追加 `--execute`。",
            "- 如果雷达已经刷好对应固件，可加 `--mode monitor`，避免重新上传。",
            "- 执行后重新生成 `tools/render_hardware_proof_packet.py` 和 `tools/render_goal_completion_audit.py`。",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    report = build_report(args)
    json_path = norm(args.json_output)
    md_path = norm(args.md_output)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(report), encoding="utf-8")
    if args.print_json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(json_path)
        print(md_path)
        print(f"STATUS {report['status']}")
    return 1 if report["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
