#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path
from typing import Any

from PIL import Image, ImageSequence


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODES = ("field", "fielddiag", "diag", "sim")
VALID_MODES = DEFAULT_MODES + ("near",)
PREVIEW_FRAMES = (
    "boot-grid-wake.png",
    "boot-logo-scan.png",
    "boot-logo-ready.png",
    "boot-handoff.png",
    "radar-default.png",
    "radar-field.png",
    "radar-sim.png",
    "radar-debug.png",
    "radar-startup-acquire.png",
    "radar-idle-search.png",
    "radar-acquisition-echo.png",
    "radar-target-trail.png",
    "radar-trace-blip.png",
    "radar-zoom-map.png",
    "radar-proximity-lock.png",
    "radar-capture-burst.png",
    "radar-control-flashes.png",
    "radar-touch-echo.png",
    "radar-tilt-inertia.png",
    "summon-gather.png",
    "summon-orbit.png",
)
PREVIEW_GIFS = (
    "boot-motion.gif",
    "radar-motion.gif",
    "summon-motion.gif",
)
EXPECTED_GIF_FRAMES = {
    "boot-motion.gif": 4,
    "radar-motion.gif": 7,
    "summon-motion.gif": 4,
}
PREVIEW_EXTRA_FRAMES = (
    "preview-interaction-final.png",
)
REQUIRED_TOOLS = (
    "flash_release_firmware.sh",
    "smoke_release_board.sh",
    "run_board_sim_test.py",
    "run_preboard_acceptance.py",
    "selftest_release.py",
    "first_run_zh.py",
    "run_release_acceptance.sh",
    "bench_sim.sh",
    "list_radar_ports.py",
    "wait_for_radar_port.py",
    "diagnose_usb_serial.py",
    "diagnose_board_runtime.py",
    "recover_board_runtime.py",
    "send_diag_command.py",
    "run_no_reset_display_check.py",
    "analyze_board_photo.py",
    "generate_usb_bringup_card.py",
    "generate_refresh_perf_card.py",
    "monitor_diag.py",
    "simulate_diag_feed.py",
    "render_bench_report.py",
    "render_hunt_report.py",
    "render_goal_completion_audit.py",
    "render_hardware_proof_packet.py",
    "run_missing_hardware_gates.py",
    "render_playtest_rehearsal.py",
    "recommend_field_tuning.py",
    "generate_field_kit.py",
    "generate_play_cards.py",
    "generate_quickstart_zh.py",
    "generate_visual_qa_sheet.py",
    "generate_motion_gifs.py",
    "verify_motion_gifs.py",
    "generate_motion_qa_sheet.py",
    "generate_release_index.py",
    "generate_fidelity_review.py",
    "verify_firmware_ui_contract.py",
    "verify_ui_parity.py",
    "verify_private_boot_logo.py",
    "install_private_boot_logo.py",
    "verify_release_package.py",
    "smoke_preview_interactions.sh",
)
REQUIRED_DOCS = (
    "README.md",
    "board-sim-test.zh.md",
    "product-design.zh.md",
    "beacon-build.zh.md",
    "beacon-labels.html",
    "field-kit.html",
    "game-cards.html",
    "playtest-rehearsal.zh.md",
    "field-tuning-report.md",
    "quickstart.zh.html",
    "visual-qa.html",
    "motion-qa.html",
    "fidelity-review.zh.md",
    "goal-completion-audit.zh.md",
    "hardware-proof-packet.zh.md",
    "missing-hardware-gates-plan.zh.md",
    "usb-bringup-card.zh.md",
    "refresh-performance-card.zh.md",
    "no-reset-display-check.zh.md",
    "board-photo-qa-sample.zh.md",
    "private_boot_logo.h.example",
)
OPTIONAL_EVIDENCE = (
    "hardware-acceptance-report.md",
    "bench-sim-report.json",
    "bringup-diag-report.json",
    "beacon-set-verify-report.json",
    "field-hunt-report.json",
)


def read_text_for_check(path: Path, failures: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        failures.append(f"cannot read {path}: {exc}")
        return ""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify a packaged Dragon Radar release folder.")
    parser.add_argument("release_dir", nargs="?", default="output/release-current", help="Release folder to verify.")
    parser.add_argument("--write", action="store_true", help="Write audit JSON and checksum files.")
    parser.add_argument("--json", default=None, help="Audit JSON output path. Default: <release_dir>/RELEASE_AUDIT.json")
    parser.add_argument("--checksums", default=None, help="Checksum output path. Default: <release_dir>/CHECKSUMS.sha256")
    parser.add_argument("--allow-missing-links", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument(
        "--modes",
        default=" ".join(DEFAULT_MODES),
        help="Space- or comma-separated radar modes expected in the package. Default: field fielddiag diag sim.",
    )
    return parser.parse_args()


def rel(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(root: Path, path: Path) -> dict[str, Any]:
    return {
        "path": rel(root, path),
        "size": path.stat().st_size,
        "sha256": sha256(path),
    }


def check_file(root: Path, relative: str, failures: list[str], min_size: int = 1) -> dict[str, Any] | None:
    path = root / relative
    if not path.exists():
        failures.append(f"missing {relative}")
        return None
    if not path.is_file():
        failures.append(f"not a file {relative}")
        return None
    size = path.stat().st_size
    if size < min_size:
        failures.append(f"too small {relative}: {size} bytes")
    return file_record(root, path)


def gif_record(root: Path, relative: str, expected_frames: int, failures: list[str]) -> dict[str, Any] | None:
    path = root / relative
    record = check_file(root, relative, failures, min_size=10_000)
    if not record:
        return None
    try:
        with Image.open(path) as image:
            frames = sum(1 for _ in ImageSequence.Iterator(image))
            width, height = image.size
    except OSError as exc:
        failures.append(f"invalid GIF {relative}: {exc}")
        return record
    record["frameCount"] = frames
    record["width"] = width
    record["height"] = height
    if frames != expected_frames:
        failures.append(f"wrong frame count {relative}: expected {expected_frames}, got {frames}")
    if width < 400 or height < 400:
        failures.append(f"too small GIF canvas {relative}: {width}x{height}")
    return record


def iter_checksum_files(root: Path) -> list[Path]:
    excluded = {"CHECKSUMS.sha256", "RELEASE_AUDIT.json"}
    return [
        path
        for path in sorted(root.rglob("*"))
        if path.is_file() and rel(root, path) not in excluded
    ]


def parse_modes(value: str) -> tuple[str, ...]:
    modes = tuple(item for item in value.replace(",", " ").split() if item)
    unknown = [mode for mode in modes if mode not in VALID_MODES]
    if unknown:
        raise SystemExit("unknown release mode(s): " + ", ".join(unknown))
    if not modes:
        raise SystemExit("--modes must include at least one mode")
    return modes


def build_audit(root: Path, modes: tuple[str, ...], allow_missing_links: bool = False) -> dict[str, Any]:
    failures: list[str] = []
    audit: dict[str, Any] = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "releaseDir": str(root),
        "status": "passed",
        "failures": failures,
        "firmware": {},
        "docs": [],
        "tools": [],
        "preview": [],
        "motionGifs": [],
        "evidence": {},
        "checksums": [],
    }

    check_file(root, "MANIFEST.md", failures)
    check_file(root, "index.html", failures)
    for private_logo in root.rglob("private_boot_logo.h"):
        failures.append(f"private logo source leaked into release: {rel(root, private_logo)}")
    if not allow_missing_links:
        for page in ("index.html", "docs/quickstart.zh.html"):
            page_path = root / page
            if page_path.exists():
                text = read_text_for_check(page_path, failures)
                if "缺失" in text or "missing</span>" in text:
                    failures.append(f"visible missing link marker in {page}")
                if page == "docs/quickstart.zh.html":
                    for required_text in (
                        "无法手动 Reset",
                        "tools/recover_board_runtime.py",
                        "tools/first_run_zh.py live --recover-runtime",
                        "tools/flash_release_firmware.sh sim",
                    ):
                        if required_text not in text:
                            failures.append(f"quickstart missing {required_text!r}")
    audit["expectedModes"] = list(modes)
    for mode in modes:
        audit["firmware"][mode] = {
            "bin": check_file(root, f"firmware/dragon-radar-{mode}.bin", failures, min_size=100_000),
            "factory": check_file(root, f"firmware/dragon-radar-{mode}-factory.bin", failures, min_size=100_000),
            "elf": check_file(root, f"firmware/dragon-radar-{mode}.elf", failures, min_size=100_000),
        }
    for doc in REQUIRED_DOCS:
        record = check_file(root, f"docs/{doc}", failures)
        if record:
            audit["docs"].append(record)
    fidelity_review = root / "docs/fidelity-review.zh.md"
    if fidelity_review.exists():
        text = read_text_for_check(fidelity_review, failures)
        for required_text in (
            "龙珠雷达 UI 还原度评审",
            "软件 UI 还原度: PASS",
            "运动 GIF 检查",
            "开机动画运动顺序",
            "矩形网格而非圆环雷达",
            "胶囊风格开机标志",
            "../preview/radar-zoom-map.png",
        ):
            if required_text not in text:
                failures.append(f"fidelity review missing {required_text!r}")
    game_cards = root / "docs/game-cards.html"
    if game_cards.exists():
        text = read_text_for_check(game_cards, failures)
        for required_text in (
            "龙珠雷达试玩卡",
            "主持人开局卡",
            "玩家规则卡",
            "DBALL-7",
            "UI 还原度评审",
        ):
            if required_text not in text:
                failures.append(f"game cards missing {required_text!r}")
    field_tuning = root / "docs/field-tuning-report.md"
    if field_tuning.exists():
        text = read_text_for_check(field_tuning, failures)
        for required_text in (
            "Dragon Radar Field Tuning",
            "Recommended `COLLECT_RSSI`",
            "Recommended `COLLECT_HOLD_MS`",
            "Hardware proof: `false`",
            "无硬件开局建议",
        ):
            if required_text not in text:
                failures.append(f"field tuning report missing {required_text!r}")
    usb_bringup = root / "docs/usb-bringup-card.zh.md"
    if usb_bringup.exists():
        text = read_text_for_check(usb_bringup, failures)
        for required_text in (
            "龙珠雷达 USB 上板排障卡",
            "现场排障顺序",
            "无法手动 Reset 时",
            "tools/first_run_zh.py live --recover-runtime",
            "tools/flash_release_firmware.sh sim",
            "esptool 的自动 reset",
            "tools/wait_for_radar_port.py",
            "tools/run_release_acceptance.sh all",
            "验收边界",
        ):
            if required_text not in text:
                failures.append(f"USB bring-up card missing {required_text!r}")
    refresh_card = root / "docs/refresh-performance-card.zh.md"
    if refresh_card.exists():
        text = read_text_for_check(refresh_card, failures)
        for required_text in (
            "龙珠雷达刷新率排障卡",
            "frameMs",
            "drawAvgMs",
            "drawMaxMs",
            "overBudget",
            "tools/send_diag_command.py turbo",
            "tools/send_diag_command.py frame",
            "tools/monitor_diag.py",
            "tools/recover_board_runtime.py",
            "DISPLAY_BUS_HZ=40000000",
            "硬件证明: `false`",
            "不能单独证明 goal 完成",
        ):
            if required_text not in text:
                failures.append(f"refresh performance card missing {required_text!r}")
    no_reset_check = root / "docs/no-reset-display-check.zh.md"
    if no_reset_check.exists():
        text = read_text_for_check(no_reset_check, failures)
        for required_text in (
            "龙珠雷达无 Reset 显示检查报告",
            "状态: `refresh-ready`",
            "frameMs",
            "drawAvgMs",
            "drawMaxMs",
            "overBudget",
            "tools/run_no_reset_display_check.py --command turbo",
            "tools/send_diag_command.py turbo",
            "tools/recover_board_runtime.py",
            "硬件证明: `false`",
            "不能单独证明 goal 完成",
        ):
            if required_text not in text:
                failures.append(f"no-reset display check missing {required_text!r}")
    board_photo_qa = root / "docs/board-photo-qa-sample.zh.md"
    if board_photo_qa.exists():
        text = read_text_for_check(board_photo_qa, failures)
        for required_text in (
            "龙珠雷达实拍屏幕 QA",
            "可视化产物",
            "board-photo-qa-sample-crop.png",
            "board-photo-qa-sample-overlay.png",
            "photo.screen-region.detected",
            "photo.rectangular-grid.present",
            "photo.orange-targets.present",
            "photo.banding-risk",
            "硬件证明: `false`",
            "不能单独证明 goal 完成",
        ):
            if required_text not in text:
                failures.append(f"board photo QA sample missing {required_text!r}")
    goal_completion = root / "docs/goal-completion-audit.zh.md"
    if goal_completion.exists():
        text = read_text_for_check(goal_completion, failures)
        for required_text in (
            "龙珠雷达 Goal 完成度审计",
            "总状态: `not-complete`",
            "真实上板硬件证明",
            "当前不能结束 goal",
        ):
            if required_text not in text:
                failures.append(f"goal completion audit missing {required_text!r}")
    hardware_packet = root / "docs/hardware-proof-packet.zh.md"
    if hardware_packet.exists():
        text = read_text_for_check(hardware_packet, failures)
        for required_text in (
            "龙珠雷达硬件证明包",
            "总状态: `not-complete`",
            "硬件证明: `false`",
            "7 个实体信标可见",
            "干净 UI 实战收集和召唤",
            "tools/verify_beacon_set.sh all",
            "tools/record_field_hunt.sh all",
            "不能单独结束 goal",
        ):
            if required_text not in text:
                failures.append(f"hardware proof packet missing {required_text!r}")
    missing_hardware_plan = root / "docs/missing-hardware-gates-plan.zh.md"
    if missing_hardware_plan.exists():
        text = read_text_for_check(missing_hardware_plan, failures)
        for required_text in (
            "龙珠雷达缺失硬件 Gate 收口计划",
            "状态: `planned`",
            "执行模式: `dry-run`",
            "硬件证明: `false`",
            "7 个实体信标可见",
            "干净 UI 实战收集和召唤",
            "tools/verify_beacon_set.sh all",
            "tools/record_field_hunt.sh all",
            "--execute",
        ):
            if required_text not in text:
                failures.append(f"missing hardware gate plan missing {required_text!r}")
    preboard_acceptance = root / "docs/preboard-acceptance.zh.md"
    if preboard_acceptance.exists():
        text = read_text_for_check(preboard_acceptance, failures)
        for required_text in (
            "龙珠雷达上板前模拟验收报告",
            "硬件证明: `false`",
            "Mock 一块板",
            "DIAG 七球回放",
            "不能替代 ESP32-S3 真板",
        ):
            if required_text not in text:
                failures.append(f"pre-board acceptance report missing {required_text!r}")
    for tool in REQUIRED_TOOLS:
        record = check_file(root, f"tools/{tool}", failures)
        if record:
            audit["tools"].append(record)
    for frame in PREVIEW_FRAMES:
        record = check_file(root, f"preview/{frame}", failures, min_size=1_000)
        if record:
            audit["preview"].append(record)
    for gif in PREVIEW_GIFS:
        record = gif_record(root, f"preview/{gif}", EXPECTED_GIF_FRAMES[gif], failures)
        if record:
            audit["preview"].append(record)
            audit["motionGifs"].append(record)
    for frame in PREVIEW_EXTRA_FRAMES:
        record = check_file(root, f"preview/{frame}", failures, min_size=1_000)
        if record:
            audit["preview"].append(record)

    project_status = check_file(root, "evidence/project-status.md", failures)
    audit["evidence"]["project-status.md"] = project_status
    goal_completion_json = check_file(root, "evidence/goal-completion-audit.json", failures)
    audit["evidence"]["goal-completion-audit.json"] = goal_completion_json
    if goal_completion_json:
        try:
            goal_data = json.loads((root / "evidence/goal-completion-audit.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/goal-completion-audit.json: {exc}")
        else:
            if goal_data.get("status") not in {"complete", "not-complete"}:
                failures.append("goal completion audit has unknown status")
            requirements = goal_data.get("requirements", [])
            if not isinstance(requirements, list) or len(requirements) < 6:
                failures.append("goal completion audit has too few requirements")
            if goal_data.get("status") == "complete":
                failures.append("goal completion audit should not be complete without hardware evidence")
    hardware_packet_json = check_file(root, "evidence/hardware-proof-packet.json", failures)
    audit["evidence"]["hardware-proof-packet.json"] = hardware_packet_json
    if hardware_packet_json:
        try:
            hardware_packet_data = json.loads((root / "evidence/hardware-proof-packet.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/hardware-proof-packet.json: {exc}")
        else:
            if hardware_packet_data.get("status") != "not-complete":
                failures.append("hardware proof packet should remain not-complete until all hardware gates pass")
            if hardware_packet_data.get("hardwareProof") is not False:
                failures.append("hardware proof packet must not claim hardware proof")
            missing_keys = set(hardware_packet_data.get("missingGateKeys", []))
            if not {"seven_beacons", "field_hunt"}.issubset(missing_keys):
                failures.append("hardware proof packet must list seven_beacons and field_hunt as missing")
            gate_keys = {item.get("key") for item in hardware_packet_data.get("gates", []) if isinstance(item, dict)}
            for required_key in ("release", "bringup", "sim_bench", "seven_beacons", "field_hunt", "goal_audit"):
                if required_key not in gate_keys:
                    failures.append(f"hardware proof packet missing gate {required_key}")
    missing_hardware_plan_json = check_file(root, "evidence/missing-hardware-gates-plan.json", failures)
    audit["evidence"]["missing-hardware-gates-plan.json"] = missing_hardware_plan_json
    if missing_hardware_plan_json:
        try:
            missing_plan_data = json.loads((root / "evidence/missing-hardware-gates-plan.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/missing-hardware-gates-plan.json: {exc}")
        else:
            if missing_plan_data.get("status") != "planned":
                failures.append("missing hardware gate plan should default to planned")
            if missing_plan_data.get("execute") is not False:
                failures.append("missing hardware gate plan must default to dry-run")
            if missing_plan_data.get("hardwareProof") is not False:
                failures.append("missing hardware gate plan must not claim hardware proof")
            selected_keys = set(missing_plan_data.get("selectedGateKeys", []))
            if not {"seven_beacons", "field_hunt"}.issubset(selected_keys):
                failures.append("missing hardware gate plan must select seven_beacons and field_hunt")
            command_texts = "\n".join(
                str(step.get("commandText", "")) for step in missing_plan_data.get("steps", []) if isinstance(step, dict)
            )
            for required_text in ("tools/verify_beacon_set.sh all", "tools/record_field_hunt.sh all"):
                if required_text not in command_texts:
                    failures.append(f"missing hardware gate plan commands missing {required_text!r}")
    preboard_json_path = root / "evidence/preboard-acceptance/preboard-acceptance-summary.json"
    preboard_json = file_record(root, preboard_json_path) if preboard_json_path.exists() and preboard_json_path.is_file() else None
    audit["evidence"]["preboard-acceptance-summary.json"] = preboard_json
    if preboard_json:
        try:
            preboard_data = json.loads((root / "evidence/preboard-acceptance/preboard-acceptance-summary.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/preboard-acceptance/preboard-acceptance-summary.json: {exc}")
        else:
            if preboard_data.get("status") != "passed":
                failures.append("pre-board acceptance did not pass")
            if preboard_data.get("hardwareProof") is not False:
                failures.append("pre-board acceptance must not claim hardware proof")
            checks = preboard_data.get("checks", {})
            mock = checks.get("mockBoardSimulation", {}) if isinstance(checks, dict) else {}
            diag = checks.get("diagSevenBallReplay", {}) if isinstance(checks, dict) else {}
            if mock.get("collectionCount") != 7 or mock.get("summon") is not True:
                failures.append("pre-board mock board simulation did not prove seven collections and summon")
            if diag.get("beaconCount") != 7 or diag.get("collectionCount") != 7 or diag.get("summon") is not True:
                failures.append("pre-board DIAG replay did not prove seven beacons, seven collections, and summon")
    preview_visual = check_file(root, "evidence/preview-visual-audit.json", failures)
    audit["evidence"]["preview-visual-audit.json"] = preview_visual
    if preview_visual:
        try:
            preview_data = json.loads((root / "evidence/preview-visual-audit.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/preview-visual-audit.json: {exc}")
        else:
            if preview_data.get("status") != "passed":
                failures.append("preview visual audit did not pass")
            if len(preview_data.get("checks", [])) < 25:
                failures.append("preview visual audit has too few checks")
    preview_visual_md = check_file(root, "evidence/preview-visual-audit.md", failures)
    audit["evidence"]["preview-visual-audit.md"] = preview_visual_md
    if preview_visual_md:
        text = read_text_for_check(root / "evidence/preview-visual-audit.md", failures)
        for required_text in (
            "Dragon Radar Preview Visual Audit",
            "Status: PASSED",
            "radar-idle-search.png",
            "radar-zoom-map.png",
            "max green ring coverage",
        ):
            if required_text not in text:
                failures.append(f"preview visual audit Markdown missing {required_text!r}")
    motion_gif_audit = check_file(root, "evidence/motion-gif-audit.json", failures)
    audit["evidence"]["motion-gif-audit.json"] = motion_gif_audit
    if motion_gif_audit:
        try:
            motion_data = json.loads((root / "evidence/motion-gif-audit.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/motion-gif-audit.json: {exc}")
        else:
            if motion_data.get("status") != "passed":
                failures.append("motion GIF audit did not pass")
            if len(motion_data.get("checks", [])) < 40:
                failures.append("motion GIF audit has too few checks")
            metrics = motion_data.get("metrics", {})
            if len(metrics.get("boot-motion.gif", {}).get("frames", [])) != EXPECTED_GIF_FRAMES["boot-motion.gif"]:
                failures.append("motion GIF audit does not cover all boot frames")
            if len(metrics.get("radar-motion.gif", {}).get("frames", [])) != EXPECTED_GIF_FRAMES["radar-motion.gif"]:
                failures.append("motion GIF audit does not cover all radar frames")
            if len(metrics.get("summon-motion.gif", {}).get("frames", [])) != EXPECTED_GIF_FRAMES["summon-motion.gif"]:
                failures.append("motion GIF audit does not cover all summon frames")
    motion_gif_audit_md = check_file(root, "evidence/motion-gif-audit.md", failures)
    audit["evidence"]["motion-gif-audit.md"] = motion_gif_audit_md
    if motion_gif_audit_md:
        text = read_text_for_check(root / "evidence/motion-gif-audit.md", failures)
        for required_text in (
            "Dragon Radar Motion GIF Audit",
            "Status: PASSED",
            "boot stage 0 grid wake",
            "radar stage 2 acquisition",
            "summon orbit stage",
        ):
            if required_text not in text:
                failures.append(f"motion GIF audit Markdown missing {required_text!r}")
    preview_interactions = check_file(root, "evidence/preview-interactions.json", failures)
    audit["evidence"]["preview-interactions.json"] = preview_interactions
    if preview_interactions:
        try:
            interaction_data = json.loads((root / "evidence/preview-interactions.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/preview-interactions.json: {exc}")
        else:
            if interaction_data.get("status") != "passed":
                failures.append("preview interaction smoke test did not pass")
            checks = interaction_data.get("checks", [])
            if not isinstance(checks, list) or len(checks) < 9:
                failures.append("preview interaction smoke test has too few checks")
            elif any(item.get("status") != "passed" for item in checks if isinstance(item, dict)):
                failures.append("preview interaction smoke test contains failed checks")
            screenshot = root / "preview" / "preview-interaction-final.png"
            if not screenshot.exists() or screenshot.stat().st_size < 1_000:
                failures.append("preview interaction final screenshot is missing or too small")
    firmware_contract = check_file(root, "evidence/firmware-ui-contract.json", failures)
    audit["evidence"]["firmware-ui-contract.json"] = firmware_contract
    if firmware_contract:
        try:
            contract_data = json.loads((root / "evidence/firmware-ui-contract.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/firmware-ui-contract.json: {exc}")
        else:
            if contract_data.get("status") != "passed":
                failures.append("firmware UI contract did not pass")
            if len(contract_data.get("checks", [])) < 40:
                failures.append("firmware UI contract has too few checks")
    firmware_preview_parity = check_file(root, "evidence/firmware-preview-parity.json", failures)
    audit["evidence"]["firmware-preview-parity.json"] = firmware_preview_parity
    if firmware_preview_parity:
        try:
            parity_data = json.loads((root / "evidence/firmware-preview-parity.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/firmware-preview-parity.json: {exc}")
        else:
            if parity_data.get("status") != "passed":
                failures.append("firmware/preview UI parity audit did not pass")
            if len(parity_data.get("checks", [])) < 20:
                failures.append("firmware/preview UI parity audit has too few checks")
    private_logo_audit = check_file(root, "evidence/private-boot-logo-audit.json", failures)
    audit["evidence"]["private-boot-logo-audit.json"] = private_logo_audit
    if private_logo_audit:
        try:
            private_logo_data = json.loads((root / "evidence/private-boot-logo-audit.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/private-boot-logo-audit.json: {exc}")
        else:
            if private_logo_data.get("status") != "passed":
                failures.append("private boot logo audit did not pass")
            summary = private_logo_data.get("summary", {})
            if summary.get("localPrivateSource") != "present":
                failures.append("private boot logo audit does not prove local private source")
            if summary.get("releasePrivateSourceLeaked") is not False:
                failures.append("private boot logo audit indicates private source leakage")
            if len(private_logo_data.get("checks", [])) < 10:
                failures.append("private boot logo audit has too few checks")
    audit["evidence"]["private-boot-logo-audit.md"] = check_file(
        root, "evidence/private-boot-logo-audit.md", failures
    )
    private_logo_setup = check_file(root, "evidence/private-boot-logo-setup.json", failures)
    audit["evidence"]["private-boot-logo-setup.json"] = private_logo_setup
    if private_logo_setup:
        try:
            private_logo_setup_data = json.loads((root / "evidence/private-boot-logo-setup.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/private-boot-logo-setup.json: {exc}")
        else:
            if private_logo_setup_data.get("status") != "passed":
                failures.append("private boot logo setup report did not pass")
            setup_summary = private_logo_setup_data.get("summary", {})
            if setup_summary.get("privateSourceExists") is not True:
                failures.append("private boot logo setup report does not prove local private source")
            if setup_summary.get("privateSourceIgnored") is not True:
                failures.append("private boot logo setup report does not prove gitignore boundary")
            if setup_summary.get("safeToShare") is not True:
                failures.append("private boot logo setup report is not marked safe to share")
            if setup_summary.get("installCommand") != "tools/install_private_boot_logo.py install-example":
                failures.append("private boot logo setup report has wrong install command")
            if len(private_logo_setup_data.get("checks", [])) < 5:
                failures.append("private boot logo setup report has too few checks")
    audit["evidence"]["private-boot-logo-setup.md"] = check_file(
        root, "evidence/private-boot-logo-setup.md", failures
    )
    usb_diagnosis = check_file(root, "evidence/usb-serial-diagnosis.json", failures)
    audit["evidence"]["usb-serial-diagnosis.json"] = usb_diagnosis
    if usb_diagnosis:
        try:
            usb_data = json.loads((root / "evidence/usb-serial-diagnosis.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/usb-serial-diagnosis.json: {exc}")
        else:
            valid_statuses = {"ready", "multiple-candidates", "no-ports", "only-ignored", "no-likely"}
            if usb_data.get("status") not in valid_statuses:
                failures.append("USB serial diagnosis has an unknown status")
            valid_usb_layer_statuses = {"radar-usb-present", "no-usb-devices", "no-radar-usb-device", "unavailable"}
            if usb_data.get("usbLayerStatus") not in valid_usb_layer_statuses:
                failures.append("USB serial diagnosis has an unknown USB layer status")
            if not isinstance(usb_data.get("recommendations"), list) or not usb_data.get("recommendations"):
                failures.append("USB serial diagnosis has no recommendations")
    audit["evidence"]["usb-serial-diagnosis.zh.md"] = check_file(
        root, "evidence/usb-serial-diagnosis.zh.md", failures
    )
    diag_sim = check_file(root, "evidence/diag-simulator-report.json", failures)
    audit["evidence"]["diag-simulator-report.json"] = diag_sim
    no_reset_json = check_file(root, "evidence/no-reset-display-check.json", failures)
    audit["evidence"]["no-reset-display-check.json"] = no_reset_json
    if no_reset_json:
        try:
            no_reset_data = json.loads((root / "evidence/no-reset-display-check.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/no-reset-display-check.json: {exc}")
        else:
            if no_reset_data.get("status") != "refresh-ready":
                failures.append("no-reset display check is not refresh-ready")
            if no_reset_data.get("hardwareProof") is not False:
                failures.append("no-reset display check must not claim hardware proof")
            parsed = no_reset_data.get("parsed", {})
            if parsed.get("frameMs") != 25 or parsed.get("overBudgetFrames") != 0:
                failures.append("no-reset display check does not prove 25ms zero-over-budget sample")
            if no_reset_data.get("commandConfirmed") is not True:
                failures.append("no-reset display check did not confirm turbo command")
    board_photo_json = check_file(root, "evidence/board-photo-qa-sample.json", failures)
    audit["evidence"]["board-photo-qa-sample.json"] = board_photo_json
    audit["evidence"]["board-photo-qa-sample-crop.png"] = check_file(
        root, "evidence/board-photo-qa-sample-crop.png", failures, min_size=1_000
    )
    audit["evidence"]["board-photo-qa-sample-overlay.png"] = check_file(
        root, "evidence/board-photo-qa-sample-overlay.png", failures, min_size=1_000
    )
    if board_photo_json:
        try:
            board_photo_data = json.loads((root / "evidence/board-photo-qa-sample.json").read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            failures.append(f"invalid evidence/board-photo-qa-sample.json: {exc}")
        else:
            if board_photo_data.get("status") not in {"passed", "warn"}:
                failures.append("board photo QA sample did not pass")
            if board_photo_data.get("hardwareProof") is not False:
                failures.append("board photo QA sample must not claim hardware proof")
            metrics = board_photo_data.get("metrics", {})
            if metrics.get("greenPixels", 0) < 2_000 or metrics.get("orangePixels", 0) < 4:
                failures.append("board photo QA sample did not detect green grid and orange targets")
            artifacts = board_photo_data.get("visualArtifacts", {})
            if "board-photo-qa-sample-crop.png" not in str(artifacts.get("crop", "")):
                failures.append("board photo QA sample missing crop artifact path")
            if "board-photo-qa-sample-overlay.png" not in str(artifacts.get("overlay", "")):
                failures.append("board photo QA sample missing overlay artifact path")
            checks = board_photo_data.get("checks", [])
            names = {item.get("name") for item in checks if isinstance(item, dict)}
            for required_name in (
                "photo.screen-region.detected",
                "photo.rectangular-grid.present",
                "photo.orange-targets.present",
                "photo.goal-proof-boundary",
            ):
                if required_name not in names:
                    failures.append(f"board photo QA sample missing check {required_name}")
    for optional in OPTIONAL_EVIDENCE:
        path = root / "evidence" / optional
        audit["evidence"][optional] = file_record(root, path) if path.exists() and path.is_file() else None

    audit["checksums"] = [file_record(root, path) for path in iter_checksum_files(root)]
    audit["fileCount"] = len(audit["checksums"])
    audit["factoryModes"] = [
        mode
        for mode in modes
        if (root / f"firmware/dragon-radar-{mode}-factory.bin").exists()
    ]
    preview_paths = {item["path"] for item in audit["preview"]}
    audit["previewFrameCount"] = len([frame for frame in PREVIEW_FRAMES if f"preview/{frame}" in preview_paths])
    audit["previewExtraFrameCount"] = len([frame for frame in PREVIEW_EXTRA_FRAMES if f"preview/{frame}" in preview_paths])
    audit["motionGifCount"] = len([item for item in audit["preview"] if item["path"].endswith(".gif")])
    if audit["previewFrameCount"] != len(PREVIEW_FRAMES):
        failures.append("not all required preview PNG frames are present")
    if audit["motionGifCount"] != len(PREVIEW_GIFS):
        failures.append("not all required motion GIFs are present")
    if audit["previewExtraFrameCount"] != len(PREVIEW_EXTRA_FRAMES):
        failures.append("not all required preview interaction screenshots are present")
    if failures:
        audit["status"] = "failed"
    return audit


def write_checksums(root: Path, audit: dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{item['sha256']}  {item['path']}" for item in audit["checksums"]]
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    release_dir = Path(args.release_dir)
    if not release_dir.is_absolute():
        release_dir = ROOT / release_dir
    if not release_dir.exists():
        raise SystemExit(f"release folder does not exist: {release_dir}")

    modes = parse_modes(args.modes)
    audit = build_audit(release_dir, modes, allow_missing_links=args.allow_missing_links)
    json_path = Path(args.json) if args.json else release_dir / "RELEASE_AUDIT.json"
    checksum_path = Path(args.checksums) if args.checksums else release_dir / "CHECKSUMS.sha256"
    if not json_path.is_absolute():
        json_path = ROOT / json_path
    if not checksum_path.is_absolute():
        checksum_path = ROOT / checksum_path

    if args.write:
        json_path.parent.mkdir(parents=True, exist_ok=True)
        json_path.write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")
        write_checksums(release_dir, audit, checksum_path)

    print(f"RELEASE {release_dir}")
    print(f"STATUS {audit['status']}")
    print(f"FILES {audit['fileCount']}")
    print("FACTORY " + ",".join(audit["factoryModes"]))
    print(f"PREVIEW {audit['previewFrameCount']}/{len(PREVIEW_FRAMES)}")
    if args.write:
        print(f"AUDIT {json_path}")
        print(f"CHECKSUMS {checksum_path}")
    for failure in audit["failures"]:
        print(f"FAIL {failure}")
    return 0 if audit["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
