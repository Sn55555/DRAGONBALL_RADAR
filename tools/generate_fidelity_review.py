#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]

CORE_CONTRACT_CHECKS = (
    "radar.grid.rectangular-lines",
    "radar.grid.no-ring-drawcircle",
    "radar.grid.debug-title-gated",
    "status.no-text-before-clean-return",
    "controls.brightness-audio-flashes.rectangular",
    "startup.acquire.no-text",
    "boot.private-logo-hook",
    "boot.grid-backdrop",
    "boot.default-logo.capsule-body",
    "boot.private-example.rich-logo",
    "audio.boot-cue-table",
    "targets.snap.grid-rounding",
    "targets.acquisition-echo.square-grid",
    "summon.gather.square-paths",
    "summon.core.square-pulse",
)

CORE_PARITY_CHECKS = (
    "constant.boot.duration",
    "array.grid.pitch",
    "array.map.scale",
    "array.audio.presets",
    "grid.no-concentric-rings-both-surfaces",
    "boot.logo-staged-both-surfaces",
    "startup.acquire-overlay-both-surfaces",
    "controls.flash-overlays-both-surfaces",
    "targets.acquisition-echo-both-surfaces",
    "summon.core-pulse-both-surfaces",
    "mode.field.parity",
    "mode.sim.parity",
)

CORE_MOTION_CHECKS = (
    "boot stage 0 grid wake has no blue logo",
    "boot stage 1 logo scan blue appears",
    "boot stage 2 ready logo blue grows",
    "boot stage 3 handoff keeps radar green",
    "radar stage 2 acquisition shows target",
    "radar stage 6 control overlay is dense green",
    "summon orbit stage 1 has center balls",
)

KEY_FRAMES = (
    ("boot-grid-wake.png", "绿色矩形网格开机唤醒，没有提前显示 logo。"),
    ("boot-logo-scan.png", "扫描线揭示胶囊风格开机标志。"),
    ("boot-logo-ready.png", "标志完成，七个小矩形进度格完整点亮。"),
    ("boot-handoff.png", "无文字 acquisition 扫描接入雷达界面。"),
    ("radar-field.png", "真实游玩空场，没有模拟球、debug HUD 或中心文字。"),
    ("radar-idle-search.png", "空场时仍有矩形搜索边线和中心搜索几何。"),
    ("radar-zoom-map.png", "缩放地图保持密集矩形网格，不变成圆环雷达。"),
    ("radar-control-flashes.png", "缩放、亮度、音量反馈使用短矩形闪烁。"),
    ("summon-gather.png", "七球沿横竖网格路径向中心聚集。"),
    ("summon-orbit.png", "完成后中心七球脉冲和环绕，仍保留方格能量感。"),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a Chinese Dragon Radar UI fidelity review report.")
    parser.add_argument("--output", default="output/fidelity-review.zh.md", help="Output Markdown path.")
    parser.add_argument("--visual-audit", default="output/preview-visual-audit.json")
    parser.add_argument("--motion-audit", default="output/motion-gif-audit.json")
    parser.add_argument("--firmware-contract", default="output/firmware-ui-contract.json")
    parser.add_argument("--parity", default="output/firmware-preview-parity.json")
    parser.add_argument("--private-logo", default="output/private-boot-logo-audit.json")
    parser.add_argument("--project-status", default="output/project-status.md")
    parser.add_argument(
        "--image-prefix",
        default="playwright",
        help="Relative prefix used for screenshot links in the generated report.",
    )
    return parser.parse_args()


def load_json(path: str) -> dict[str, Any]:
    item = Path(path)
    if not item.is_absolute():
        item = ROOT / item
    try:
        data = json.loads(item.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def read_text(path: str) -> str:
    item = Path(path)
    if not item.is_absolute():
        item = ROOT / item
    try:
        return item.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def checks_by_name(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    checks = report.get("checks", [])
    if not isinstance(checks, list):
        return {}
    return {
        str(item.get("name")): item
        for item in checks
        if isinstance(item, dict) and item.get("name")
    }


def checks_by_label(report: dict[str, Any]) -> dict[str, dict[str, Any]]:
    checks = report.get("checks", [])
    if not isinstance(checks, list):
        return {}
    return {
        str(item.get("label")): item
        for item in checks
        if isinstance(item, dict) and item.get("label")
    }


def visual_metric(report: dict[str, Any], frame: str, group: str, key: str) -> Any:
    value = report.get("metrics", {}).get(frame, {}).get(group, {})
    if isinstance(value, dict):
        return value.get(key, "-")
    return "-"


def motion_metric(report: dict[str, Any], gif: str, frame: int, group: str, key: str) -> Any:
    frames = report.get("metrics", {}).get(gif, {}).get("frames", [])
    if not isinstance(frames, list) or frame >= len(frames):
        return "-"
    value = frames[frame].get(group, {}) if isinstance(frames[frame], dict) else {}
    if isinstance(value, dict):
        return value.get(key, "-")
    return "-"


def progress_ticks(report: dict[str, Any]) -> list[int]:
    ticks = report.get("metrics", {}).get("boot-logo-ready.png", {}).get("progressTicks", [])
    return [int(item) for item in ticks] if isinstance(ticks, list) else []


def project_hardware_status(text: str) -> str:
    for line in text.splitlines():
        if line.startswith("- Hardware completion:"):
            return line.split(":", 1)[1].strip()
    return "UNKNOWN"


def passfail(ok: bool) -> str:
    return "PASS" if ok else "FAIL"


def check_named(
    checks: dict[str, dict[str, Any]],
    required_names: tuple[str, ...],
) -> tuple[bool, str]:
    missing = [name for name in required_names if checks.get(name, {}).get("status") != "passed"]
    if missing:
        return False, "缺失或失败: " + ", ".join(missing)
    return True, f"{len(required_names)} 项核心检查通过"


def check_labeled(
    checks: dict[str, dict[str, Any]],
    required_labels: tuple[str, ...],
) -> tuple[bool, str]:
    missing = [label for label in required_labels if checks.get(label, {}).get("status") != "passed"]
    if missing:
        return False, "缺失或失败: " + ", ".join(missing)
    return True, f"{len(required_labels)} 项运动检查通过"


def build_items(
    visual: dict[str, Any],
    motion: dict[str, Any],
    contract: dict[str, Any],
    parity: dict[str, Any],
    private_logo: dict[str, Any],
) -> list[tuple[str, bool, str]]:
    contract_checks = checks_by_name(contract)
    parity_checks = checks_by_name(parity)
    motion_checks = checks_by_label(motion)
    ticks = progress_ticks(visual)
    ring_values = visual.get("ringCoverage", {})
    max_ring = max(ring_values.values()) if isinstance(ring_values, dict) and ring_values else None
    contract_ok, contract_detail = check_named(contract_checks, CORE_CONTRACT_CHECKS)
    parity_ok, parity_detail = check_named(parity_checks, CORE_PARITY_CHECKS)
    motion_ok, motion_detail = check_labeled(motion_checks, CORE_MOTION_CHECKS)
    private_summary = private_logo.get("summary", {})

    return [
        (
            "胶囊风格开机标志",
            visual_metric(visual, "boot-logo-ready.png", "logo", "blue") != "-"
            and visual_metric(visual, "boot-logo-ready.png", "logo", "blue") > 7000
            and visual_metric(visual, "boot-logo-ready.png", "logo", "white") > 1500
            and len(ticks) == 7
            and min(ticks) > 12,
            (
                f"blue={visual_metric(visual, 'boot-logo-ready.png', 'logo', 'blue')}; "
                f"white={visual_metric(visual, 'boot-logo-ready.png', 'logo', 'white')}; "
                f"ticks={ticks}"
            ),
        ),
        (
            "开机动画运动顺序",
            motion.get("status") == "passed"
            and motion_ok
            and motion_metric(motion, "boot-motion.gif", 0, "logo", "blue") != "-"
            and motion_metric(motion, "boot-motion.gif", 0, "logo", "blue") <= 100
            and motion_metric(motion, "boot-motion.gif", 2, "logo", "blue") > 7500
            and motion_metric(motion, "boot-motion.gif", 3, "screen", "green") > 3000,
            (
                f"wakeBlue={motion_metric(motion, 'boot-motion.gif', 0, 'logo', 'blue')}; "
                f"readyBlue={motion_metric(motion, 'boot-motion.gif', 2, 'logo', 'blue')}; "
                f"handoffGreen={motion_metric(motion, 'boot-motion.gif', 3, 'screen', 'green')}; "
                f"{motion_detail}"
            ),
        ),
        (
            "矩形网格而非圆环雷达",
            max_ring is not None
            and max_ring < 0.14
            and contract_checks.get("radar.grid.no-ring-drawcircle", {}).get("status") == "passed",
            f"max green ring coverage={max_ring}; source check=radar.grid.no-ring-drawcircle",
        ),
        (
            "真实游玩空场干净",
            visual_metric(visual, "radar-field.png", "screen", "orange") != "-"
            and visual_metric(visual, "radar-field.png", "screen", "orange") <= 50
            and contract_checks.get("status.no-text-before-clean-return", {}).get("status") == "passed",
            (
                f"field orange={visual_metric(visual, 'radar-field.png', 'screen', 'orange')}; "
                "clean field/sim source return verified"
            ),
        ),
        (
            "缩放地图仍是矩形坐标系",
            visual_metric(visual, "radar-zoom-map.png", "zoomGrid", "green") != "-"
            and visual_metric(visual, "radar-zoom-map.png", "zoomGrid", "green") > 3200,
            (
                f"zoom green={visual_metric(visual, 'radar-zoom-map.png', 'screen', 'green')}; "
                f"denseGrid={visual_metric(visual, 'radar-zoom-map.png', 'zoomGrid', 'green')}"
            ),
        ),
        (
            "触控/亮度/音量反馈无文字 HUD",
            contract_checks.get("controls.brightness-audio-flashes.rectangular", {}).get("status") == "passed"
            and visual_metric(visual, "radar-control-flashes.png", "audio", "green") != "-"
            and visual_metric(visual, "radar-control-flashes.png", "audio", "green") > 70,
            (
                f"audio flash green={visual_metric(visual, 'radar-control-flashes.png', 'audio', 'green')}; "
                "rectangular source overlays verified"
            ),
        ),
        (
            "七球完成动画",
            visual_metric(visual, "summon-gather.png", "screen", "orange") != "-"
            and visual_metric(visual, "summon-gather.png", "screen", "orange") > 250
            and visual_metric(visual, "summon-orbit.png", "center", "orange") > 300
            and motion_metric(motion, "summon-motion.gif", 1, "center", "orange") != "-"
            and motion_metric(motion, "summon-motion.gif", 1, "center", "orange") > 300
            and contract_checks.get("summon.gather.square-paths", {}).get("status") == "passed",
            (
                f"gather orange={visual_metric(visual, 'summon-gather.png', 'screen', 'orange')}; "
                f"orbit center orange={visual_metric(visual, 'summon-orbit.png', 'center', 'orange')}; "
                f"motion orbit center={motion_metric(motion, 'summon-motion.gif', 1, 'center', 'orange')}"
            ),
        ),
        (
            "固件 UI 合约",
            contract.get("status") == "passed" and contract_ok,
            contract_detail,
        ),
        (
            "浏览器预览/固件一致性",
            parity.get("status") == "passed" and parity_ok,
            parity_detail,
        ),
        (
            "私有开机标志边界",
            private_logo.get("status") == "passed"
            and private_summary.get("localPrivateSource") == "present"
            and private_summary.get("releasePrivateSourceLeaked") is False,
            (
                f"local={private_summary.get('localPrivateSource', '-')}; "
                f"ignored={private_summary.get('privateSourceIgnored', '-')}; "
                f"releaseLeak={private_summary.get('releasePrivateSourceLeaked', '-')}"
            ),
        ),
    ]


def render(args: argparse.Namespace) -> str:
    visual = load_json(args.visual_audit)
    motion = load_json(args.motion_audit)
    contract = load_json(args.firmware_contract)
    parity = load_json(args.parity)
    private_logo = load_json(args.private_logo)
    project_status = read_text(args.project_status)
    hardware_status = project_hardware_status(project_status)
    items = build_items(visual, motion, contract, parity, private_logo)
    software_ok = (
        visual.get("status") == "passed"
        and len(visual.get("checks", [])) >= 79
        and motion.get("status") == "passed"
        and len(motion.get("checks", [])) >= 40
        and contract.get("status") == "passed"
        and parity.get("status") == "passed"
        and private_logo.get("status") == "passed"
        and all(ok for _, ok, _ in items)
    )

    lines = [
        "# 龙珠雷达 UI 还原度评审",
        "",
        f"- Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- 软件 UI 还原度: {passfail(software_ok)}",
        f"- 硬件完成度: {hardware_status}",
        f"- 视觉检查: {visual.get('status', 'missing')}; checks={len(visual.get('checks', []))}; failures={len(visual.get('failures', []))}",
        f"- 运动 GIF 检查: {motion.get('status', 'missing')}; checks={len(motion.get('checks', []))}; failures={len(motion.get('failures', []))}",
        f"- 固件合约: {contract.get('status', 'missing')}; checks={len(contract.get('checks', []))}; failures={len(contract.get('failures', []))}",
        f"- 预览/固件一致性: {parity.get('status', 'missing')}; checks={len(parity.get('checks', []))}; failures={len(parity.get('failures', []))}",
        "",
        "## 自动验收项",
        "",
        "| 项目 | 状态 | 证据 |",
        "| --- | --- | --- |",
    ]
    for label, ok, detail in items:
        lines.append(f"| {label} | {passfail(ok)} | {detail} |")

    lines.extend(
        [
            "",
            "## 关键分镜复核",
            "",
            "| 分镜 | 文件 | 复核重点 |",
            "| --- | --- | --- |",
        ]
    )
    prefix = args.image_prefix.strip("/")
    for filename, note in KEY_FRAMES:
        link = f"{prefix}/{filename}" if prefix else filename
        lines.append(f"| {filename} | [{filename}]({link}) | {note} |")

    lines.extend(
        [
            "",
            "## 人工评审口径",
            "",
            "- 先看 `boot-logo-scan.png` 和 `boot-logo-ready.png`：开机应该是绿色网格、扫描线、胶囊风格标志、七个矩形进度格，不应该出现解释文字。",
            "- 再看 `boot-motion.gif`：运动顺序应该是网格唤醒、标志扫描、标志完成、交接雷达；不能只靠静态图证明开机动画。",
            "- 然后看 `radar-field.png`、`radar-idle-search.png`、`radar-zoom-map.png`：主体必须是矩形坐标网格，圆形 AMOLED 只作为裁切边界，不能变成同心圆雷达。",
            "- 最后看 `summon-gather.png`、`summon-orbit.png` 和 `summon-motion.gif`：七球完成后要从网格路径聚集到中心，并保持方格能量视觉。",
            "- 这份报告只证明软件 UI 还原度；真实完成仍要以上板硬件验收报告为准。",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    output = Path(args.output)
    if not output.is_absolute():
        output = ROOT / output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(args), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
