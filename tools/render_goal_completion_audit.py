#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
OBJECTIVE = "个人和朋友玩的龙珠雷达软件，动漫 UI 高还原，带胶囊公司风格开机动画，并最终通过真板验收。"


def in_release_root() -> bool:
    return (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir()


def default_json() -> str:
    return "evidence/goal-completion-audit.json" if in_release_root() else "output/goal-completion-audit.json"


def default_md() -> str:
    return "docs/goal-completion-audit.zh.md" if in_release_root() else "output/goal-completion-audit.zh.md"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render a Dragon Radar goal-completion audit.")
    parser.add_argument("--json", default=default_json(), help="Machine-readable audit JSON output path.")
    parser.add_argument("--md", default=default_md(), help="Chinese Markdown audit output path.")
    return parser.parse_args()


def norm(path: str | Path) -> Path:
    item = Path(path)
    return item if item.is_absolute() else ROOT / item


def exists(path: str | Path) -> bool:
    return norm(path).exists()


def first_existing(paths: tuple[str, ...]) -> Path | None:
    for path in paths:
        item = norm(path)
        if item.exists():
            return item
    return None


def load_json(paths: tuple[str, ...]) -> dict[str, Any]:
    item = first_existing(paths)
    if not item:
        return {}
    try:
        data = json.loads(item.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def read_text(paths: tuple[str, ...]) -> str:
    item = first_existing(paths)
    if not item:
        return ""
    try:
        return item.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def status(ok: bool, weak: bool = False) -> str:
    if ok:
        return "PASS"
    return "WEAK" if weak else "NOT PROVEN"


def requirement(key: str, label: str, ok: bool, evidence: str, missing: str, weak: bool = False) -> dict[str, Any]:
    return {
        "key": key,
        "label": label,
        "status": status(ok, weak),
        "passed": bool(ok),
        "evidence": evidence,
        "missing": missing,
    }


def release_ok(report: dict[str, Any], modes: tuple[str, ...] | None = None) -> bool:
    if not report or report.get("status") != "passed":
        return False
    if report.get("previewFrameCount") != 21 or report.get("motionGifCount") != 3:
        return False
    if modes is not None and tuple(report.get("factoryModes", [])) != modes:
        return False
    return True


def build_audit() -> dict[str, Any]:
    source_release = load_json(("output/release-current/RELEASE_AUDIT.json", "RELEASE_AUDIT.json"))
    near_release = load_json(("output/release-near-current/RELEASE_AUDIT.json",))
    visual = load_json(("output/preview-visual-audit.json", "evidence/preview-visual-audit.json"))
    motion = load_json(("output/motion-gif-audit.json", "evidence/motion-gif-audit.json"))
    contract = load_json(("output/firmware-ui-contract.json", "evidence/firmware-ui-contract.json"))
    parity = load_json(("output/firmware-preview-parity.json", "evidence/firmware-preview-parity.json"))
    private_logo = load_json(("output/private-boot-logo-audit.json", "evidence/private-boot-logo-audit.json"))
    private_logo_setup = load_json(("output/private-boot-logo-setup.json", "evidence/private-boot-logo-setup.json"))
    usb = load_json(("output/usb-serial-diagnosis.json", "evidence/usb-serial-diagnosis.json"))
    project_status = read_text(("output/project-status.md", "evidence/project-status.md"))
    fidelity = read_text(("output/fidelity-review.zh.md", "docs/fidelity-review.zh.md"))

    firmware_sources = all(
        exists(path)
        for path in (
            "firmware/DragonRadar/DragonRadar.ino",
            "firmware/DragonBallBeacon/DragonBallBeacon.ino",
            "preview/radar_ui.html",
        )
    )
    firmware_builds = all(
        exists(path)
        for path in (
            ".pio/build/esp32-s3-touch-amoled-175c-field/firmware.elf",
            ".pio/build/esp32-s3-touch-amoled-175c-fielddiag/firmware.elf",
            ".pio/build/esp32-s3-touch-amoled-175c-diag/firmware.elf",
            ".pio/build/esp32-s3-touch-amoled-175c-sim/firmware.elf",
        )
    ) or all(
        exists(path)
        for path in (
            "firmware/dragon-radar-field-factory.bin",
            "firmware/dragon-radar-fielddiag-factory.bin",
            "firmware/dragon-radar-diag-factory.bin",
            "firmware/dragon-radar-sim-factory.bin",
        )
    )

    software_ok = firmware_sources and firmware_builds
    motion_ok = (
        motion.get("status") == "passed"
        and len(motion.get("checks", [])) >= 40
        and len(motion.get("metrics", {}).get("boot-motion.gif", {}).get("frames", [])) == 4
        and len(motion.get("metrics", {}).get("radar-motion.gif", {}).get("frames", [])) == 7
        and len(motion.get("metrics", {}).get("summon-motion.gif", {}).get("frames", [])) == 4
    )
    visual_ok = (
        visual.get("status") == "passed"
        and len(visual.get("checks", [])) >= 79
        and motion_ok
        and contract.get("status") == "passed"
        and parity.get("status") == "passed"
        and "软件 UI 还原度: PASS" in fidelity
    )
    private_summary = private_logo.get("summary", {})
    setup_summary = private_logo_setup.get("summary", {})
    capsule_ok = (
        private_logo.get("status") == "passed"
        and private_logo_setup.get("status") == "passed"
        and private_summary.get("localPrivateSource") == "present"
        and setup_summary.get("privateSourceExists") is True
        and setup_summary.get("privateSourceIgnored") is True
        and setup_summary.get("safeToShare") is True
        and private_summary.get("releasePrivateSourceLeaked") is False
        and motion_ok
        and (exists("output/playwright/boot-motion.gif") or exists("preview/boot-motion.gif"))
    )
    friends_ok = all(
        first_existing(paths)
        for paths in (
            ("docs/beacon-build.zh.md",),
            ("output/game-cards.html", "docs/game-cards.html"),
            ("output/release-current/docs/field-kit.html", "docs/field-kit.html"),
            ("output/release-current/docs/playtest-rehearsal.zh.md", "docs/playtest-rehearsal.zh.md"),
        )
    )
    handoff_ok = (
        release_ok(source_release, ("field", "fielddiag", "diag", "sim"))
        and (
            release_ok(near_release, ("near",))
            or (
                tuple(source_release.get("expectedModes", [])) == ("near",)
                and release_ok(source_release, ("near",))
            )
        )
    )
    hardware_ok = "Hardware completion: PASS" in project_status
    usb_ready = usb.get("status") in {"ready", "multiple-candidates"}

    requirements = [
        requirement(
            "software",
            "软件主体和固件构建",
            software_ok,
            "DragonRadar/Beacon 源码、浏览器预览、field/fielddiag/diag/sim 构建或 release factory 镜像存在。",
            "需要源码和可刷写固件镜像都存在。",
        ),
        requirement(
            "anime_ui",
            "动漫 UI 高还原",
            visual_ok,
            f"visual={visual.get('status', 'missing')}; checks={len(visual.get('checks', []))}; motion={motion.get('status', 'missing')}; motionChecks={len(motion.get('checks', []))}; contract={contract.get('status', 'missing')}; parity={parity.get('status', 'missing')}",
            "需要视觉审计、运动 GIF 审计、固件合约、预览/固件一致性、中文还原度评审全部通过。",
        ),
        requirement(
            "capsule_boot",
            "胶囊公司风格开机动画",
            capsule_ok,
            f"privateLogo={private_logo.get('status', 'missing')}; setup={private_logo_setup.get('status', 'missing')}; motion={motion.get('status', 'missing')}; local={private_summary.get('localPrivateSource', '-')}; ignored={setup_summary.get('privateSourceIgnored', '-')}; releaseLeak={private_summary.get('releasePrivateSourceLeaked', '-')}",
            "需要私有开机标志链路和本地 setup 报告通过、运动 GIF 审计通过、release 不泄漏私有源、boot motion 存在。",
        ),
        requirement(
            "friends_play",
            "个人和朋友试玩交付",
            friends_ok,
            "beacon guide、field kit、host/player cards、playtest rehearsal 已生成。",
            "需要可打印现场资料和试玩演练报告。",
        ),
        requirement(
            "release_handoff",
            "可复制 release 交付包",
            handoff_ok,
            f"defaultRelease={source_release.get('status', 'missing')}; nearRelease={near_release.get('status', 'missing')}; files={source_release.get('fileCount', '-')}/{near_release.get('fileCount', '-')}",
            "需要默认包和 near 包通过 release verifier/selftest。",
        ),
        requirement(
            "hardware",
            "真实上板硬件证明",
            hardware_ok,
            f"projectStatus={'PASS' if hardware_ok else 'NOT PROVEN'}; usb={usb.get('status', 'missing')}; selectedPort={usb.get('selectedPort') or '-'}",
            "需要真板 bring-up、一块板 sim、7 个实体信标、干净 UI 实战收集和召唤报告全部通过。",
            weak=usb_ready,
        ),
    ]
    complete = all(item["passed"] for item in requirements)
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "objective": OBJECTIVE,
        "status": "complete" if complete else "not-complete",
        "complete": complete,
        "requirements": requirements,
    }


def render_markdown(audit: dict[str, Any]) -> str:
    lines = [
        "# 龙珠雷达 Goal 完成度审计",
        "",
        f"- 生成时间: {audit['generated']}",
        f"- 目标: {audit['objective']}",
        f"- 总状态: `{audit['status']}`",
        "",
        "## 逐项结论",
        "",
        "| 要求 | 状态 | 当前证据 | 缺口 |",
        "| --- | --- | --- | --- |",
    ]
    for item in audit["requirements"]:
        lines.append(
            f"| {item['label']} | {item['status']} | {item['evidence']} | {item['missing']} |"
        )
    lines.extend(
        [
            "",
            "## 结论",
            "",
        ]
    )
    if audit["complete"]:
        lines.append("- 当前证据足以证明 goal 完成。")
    else:
        lines.extend(
            [
                "- 当前不能结束 goal：真实上板硬件证明仍未完成。",
                "- 软件、UI、开机动画、release 交付和朋友试玩资料可以继续作为已通过证据使用。",
                "- 下一步必须让 ESP32-S3 串口可见，并跑 `tools/run_hardware_acceptance.sh all` 或 release 内 `tools/run_release_acceptance.sh all`。",
            ]
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    audit = build_audit()
    json_path = norm(args.json)
    md_path = norm(args.md)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(audit, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(render_markdown(audit), encoding="utf-8")
    print(json_path)
    print(md_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
