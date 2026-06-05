#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def in_release_root() -> bool:
    return (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir()


def default_json() -> str:
    return "evidence/hardware-proof-packet.json" if in_release_root() else "output/hardware-proof-packet.json"


def default_md() -> str:
    return "docs/hardware-proof-packet.zh.md" if in_release_root() else "output/hardware-proof-packet.zh.md"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render a Dragon Radar hardware proof packet and missing-gate checklist.")
    parser.add_argument("--json", default=default_json(), help="Machine-readable report output path.")
    parser.add_argument("--md", default=default_md(), help="Chinese Markdown report output path.")
    parser.add_argument("--radar-port", default="/dev/cu.usbmodem101", help="Example RADAR_PORT for next commands.")
    parser.add_argument("--photo-json", default=None, help="Optional board photo QA JSON. Default uses the safe packaged sample.")
    return parser.parse_args()


def norm(path: str | Path) -> Path:
    item = Path(path)
    return item if item.is_absolute() else ROOT / item


def load_json(paths: tuple[str, ...]) -> tuple[dict[str, Any], str | None]:
    for path in paths:
        item = norm(path)
        if not item.exists():
            continue
        try:
            data = json.loads(item.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}, str(item)
        return (data if isinstance(data, dict) else {}), str(item)
    return {}, None


def proof_status(ok: bool, weak: bool = False) -> str:
    if ok:
        return "PASS"
    return "WEAK" if weak else "MISSING"


def hardware_online(report: dict[str, Any]) -> bool:
    hardware = report.get("hardware", {})
    if not isinstance(hardware, dict):
        return False
    return all(hardware.get(name) == "online" for name in ("touch", "imu", "ble", "audio"))


def gate(
    key: str,
    label: str,
    ok: bool,
    weak: bool,
    source: str | None,
    evidence: str,
    missing: str,
    command: str,
    proof_level: str,
) -> dict[str, Any]:
    return {
        "key": key,
        "label": label,
        "status": proof_status(ok, weak),
        "passed": ok,
        "source": source or "missing",
        "evidence": evidence,
        "missing": missing,
        "nextCommand": command,
        "proofLevel": proof_level,
    }


def build_packet(args: argparse.Namespace) -> dict[str, Any]:
    bringup, bringup_source = load_json(("output/bringup-diag-report.json", "evidence/bringup-diag-report.json"))
    bench, bench_source = load_json(("output/bench-sim-report.json", "evidence/bench-sim-report.json"))
    beacons, beacons_source = load_json(("output/beacon-set-verify-report.json", "evidence/beacon-set-verify-report.json"))
    hunt, hunt_source = load_json(("output/field-hunt-report.json", "evidence/field-hunt-report.json"))
    no_reset, no_reset_source = load_json(("output/no-reset-display-check.json", "evidence/no-reset-display-check.json"))
    photo_paths = (args.photo_json,) if args.photo_json else ("output/board-photo-qa-sample.json", "evidence/board-photo-qa-sample.json")
    photo, photo_source = load_json(tuple(path for path in photo_paths if path))
    release, release_source = load_json(("output/release-current/RELEASE_AUDIT.json", "RELEASE_AUDIT.json"))
    near_release, near_source = load_json(("output/release-near-current/RELEASE_AUDIT.json",))
    goal, goal_source = load_json(("output/goal-completion-audit.json", "evidence/goal-completion-audit.json"))

    bringup_ok = bringup.get("status") == "passed" and hardware_online(bringup)
    bench_ok = (
        bench.get("status") == "passed"
        and hardware_online(bench)
        and int(bench.get("collectionCount") or 0) >= 7
        and bench.get("summon") is True
    )
    beacons_ok = beacons.get("status") == "passed" and int(beacons.get("beaconCount") or 0) >= 7
    hunt_ok = (
        hunt.get("status") == "passed"
        and int(hunt.get("collectionCount") or 0) >= 7
        and hunt.get("summon") is True
    )
    no_reset_ok = (
        no_reset.get("status") == "refresh-ready"
        and no_reset.get("hardwareProof") is False
        and no_reset.get("commandConfirmed") is True
    )
    photo_ok = (
        photo.get("status") in {"passed", "warn"}
        and photo.get("hardwareProof") is False
        and int(photo.get("metrics", {}).get("greenPixels") or 0) >= 2_000
        and int(photo.get("metrics", {}).get("orangePixels") or 0) >= 4
    )
    release_ok = (
        release.get("status") == "passed"
        and release.get("previewFrameCount") == 21
        and release.get("motionGifCount") == 3
        and tuple(release.get("factoryModes", [])) == ("field", "fielddiag", "diag", "sim")
    )
    near_ok = near_release.get("status") == "passed" and tuple(near_release.get("factoryModes", [])) == ("near",)

    gates = [
        gate(
            "release",
            "release 包可交付",
            release_ok and near_ok,
            release_ok or near_ok,
            f"{release_source or '-'}; {near_source or '-'}",
            f"default={release.get('status', 'missing')} modes={','.join(release.get('factoryModes', []) or []) or '-'}; near={near_release.get('status', 'missing')}",
            "需要 default 和 near release verifier 都通过。",
            "tools/verify_release_package.py output/release-current --write && tools/verify_release_package.py output/release-near-current --write --modes near",
            "software",
        ),
        gate(
            "bringup",
            "真板 bring-up",
            bringup_ok,
            bringup.get("status") == "passed",
            bringup_source,
            f"status={bringup.get('status', 'missing')}; hardware={bringup.get('hardware', {})}",
            "需要 touch/IMU/BLE/audio 全部 online。",
            f"RADAR_PORT={args.radar_port} tools/bringup_diag.sh all",
            "hardware",
        ),
        gate(
            "sim_bench",
            "真板一块板 sim",
            bench_ok,
            bench.get("status") == "passed",
            bench_source,
            f"status={bench.get('status', 'missing')}; collectionCount={bench.get('collectionCount', '-')}; summon={bench.get('summon', '-')}; hardware={bench.get('hardware', {})}",
            "需要真板触摸/IMU/BLE/audio online，并完成 7 次模拟收集和 summon。",
            f"RADAR_PORT={args.radar_port} tools/bench_sim.sh all",
            "hardware",
        ),
        gate(
            "no_reset_display",
            "无 Reset 显示刷新检查",
            no_reset_ok,
            no_reset.get("status") is not None,
            no_reset_source,
            f"status={no_reset.get('status', 'missing')}; hardwareProof={no_reset.get('hardwareProof', '-')}; liveSerialEvidence={no_reset.get('liveSerialEvidence', '-')}",
            "需要真板实时串口时可重跑；当前样本不能单独证明 goal。",
            f"RADAR_PORT={args.radar_port} tools/run_no_reset_display_check.py --command turbo",
            "supporting",
        ),
        gate(
            "photo_qa",
            "实拍屏幕 QA",
            photo_ok,
            photo.get("status") is not None,
            photo_source,
            f"status={photo.get('status', 'missing')}; hardwareProof={photo.get('hardwareProof', '-')}; region={photo.get('screenRegion', {})}",
            "需要现场照片/视频帧辅助确认画面，但照片 QA 不能代替 DIAG 和实体信标。",
            "tools/analyze_board_photo.py /path/to/board-photo.png --crop-output output/board-photo-crop.png --overlay-output output/board-photo-overlay.png",
            "supporting",
        ),
        gate(
            "seven_beacons",
            "7 个实体信标可见",
            beacons_ok,
            beacons.get("status") == "passed",
            beacons_source,
            f"status={beacons.get('status', 'missing')}; beaconCount={beacons.get('beaconCount', '-')}",
            "需要 7 个实体 DBALL BLE 信标都被真板看到。",
            f"RADAR_PORT={args.radar_port} tools/verify_beacon_set.sh all",
            "hardware",
        ),
        gate(
            "field_hunt",
            "干净 UI 实战收集和召唤",
            hunt_ok,
            hunt.get("status") == "passed",
            hunt_source,
            f"status={hunt.get('status', 'missing')}; collectionCount={hunt.get('collectionCount', '-')}; summon={hunt.get('summon', '-')}",
            "需要真实朋友试玩/现场 clean UI 记录达到 7 次收集并出现 summon。",
            f"RADAR_PORT={args.radar_port} tools/record_field_hunt.sh all",
            "hardware",
        ),
        gate(
            "goal_audit",
            "goal 完成度审计",
            goal.get("complete") is True,
            goal.get("status") == "not-complete",
            goal_source,
            f"status={goal.get('status', 'missing')}; complete={goal.get('complete', '-')}",
            "只有所有硬件 gate 通过后才能把 goal 标记完成。",
            "tools/render_goal_completion_audit.py --json output/goal-completion-audit.json --md output/goal-completion-audit.zh.md",
            "audit",
        ),
    ]
    required_hardware = [item for item in gates if item["key"] in {"bringup", "sim_bench", "seven_beacons", "field_hunt"}]
    complete = all(item["passed"] for item in required_hardware)
    missing = [item for item in gates if item["status"] in {"MISSING", "WEAK"}]
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": "complete" if complete else "not-complete",
        "complete": complete,
        "hardwareProof": complete,
        "summary": "完整硬件证明已闭合。" if complete else "硬件证明未闭合；至少实体信标或实战 hunt 仍缺。",
        "gates": gates,
        "missingGateKeys": [item["key"] for item in missing],
    }


def render_markdown(packet: dict[str, Any]) -> str:
    lines = [
        "# 龙珠雷达硬件证明包",
        "",
        f"- 生成时间: {packet['generated']}",
        f"- 总状态: `{packet['status']}`",
        f"- 硬件证明: `{str(packet['hardwareProof']).lower()}`",
        f"- 结论: {packet['summary']}",
        "",
        "## Gate 明细",
        "",
        "| Gate | 状态 | 证明级别 | 证据 | 缺口 | 下一步命令 |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for item in packet["gates"]:
        lines.append(
            f"| {item['label']} | `{item['status']}` | {item['proofLevel']} | {item['evidence']} | {item['missing']} | `{item['nextCommand']}` |"
        )
    lines.extend(["", "## 收口顺序", ""])
    for item in packet["gates"]:
        if item["status"] in {"MISSING", "WEAK"}:
            lines.append(f"- {item['label']}: `{item['nextCommand']}`")
    if not packet["missingGateKeys"]:
        lines.append("- 没有缺失 gate。")
    lines.extend(
        [
            "",
            "## 边界",
            "",
            "- `software` 和 `supporting` 证据能帮助定位问题，但不能单独结束 goal。",
            "- goal 完成必须由 `hardware` gate 闭合：真板 bring-up、一块板 sim、7 个实体信标、干净 UI 实战收集和召唤。",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    packet = build_packet(args)
    json_path = norm(args.json)
    md_path = norm(args.md)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(packet, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(packet), encoding="utf-8")
    print(json_path)
    print(md_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
