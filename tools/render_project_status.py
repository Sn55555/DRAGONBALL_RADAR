#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]

CORE_FILES = [
    "firmware/DragonRadar/DragonRadar.ino",
    "firmware/DragonRadar/pin_config.h",
    "firmware/DragonRadar/private_boot_logo.h.example",
    "firmware/DragonBallBeacon/DragonBallBeacon.ino",
    "docs/board-sim-test.zh.md",
    "docs/product-design.zh.md",
    "docs/beacon-build.zh.md",
    "preview/radar_ui.html",
    "tools/build_radar.sh",
    "tools/list_radar_ports.py",
    "tools/wait_for_radar_port.py",
    "tools/flash_release_firmware.sh",
    "tools/smoke_release_board.sh",
    "tools/run_board_sim_test.py",
    "tools/run_preboard_acceptance.py",
    "tools/selftest_release.py",
    "tools/first_run_zh.py",
    "tools/run_release_acceptance.sh",
    "tools/simulate_diag_feed.py",
    "tools/diagnose_usb_serial.py",
    "tools/diagnose_board_runtime.py",
    "tools/recover_board_runtime.py",
    "tools/send_diag_command.py",
    "tools/run_no_reset_display_check.py",
    "tools/analyze_board_photo.py",
    "tools/generate_usb_bringup_card.py",
    "tools/generate_refresh_perf_card.py",
    "tools/bench_sim.sh",
    "tools/record_field_hunt.sh",
    "tools/run_hardware_acceptance.sh",
    "tools/package_release.sh",
    "tools/generate_field_kit.py",
    "tools/generate_play_cards.py",
    "tools/generate_quickstart_zh.py",
    "tools/generate_visual_qa_sheet.py",
    "tools/generate_motion_gifs.py",
    "tools/verify_motion_gifs.py",
    "tools/generate_motion_qa_sheet.py",
    "tools/generate_release_index.py",
    "tools/generate_fidelity_review.py",
    "tools/verify_firmware_ui_contract.py",
    "tools/verify_ui_parity.py",
    "tools/verify_private_boot_logo.py",
    "tools/install_private_boot_logo.py",
    "tools/verify_release_package.py",
    "tools/smoke_preview_interactions.sh",
    "tools/render_hunt_report.py",
    "tools/render_goal_completion_audit.py",
    "tools/render_hardware_proof_packet.py",
    "tools/run_missing_hardware_gates.py",
    "tools/verify_project.sh",
    "tools/render_playtest_rehearsal.py",
    "tools/recommend_field_tuning.py",
]

PREVIEW_SHOTS = [
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
]

MOTION_GIFS = [
    "boot-motion.gif",
    "radar-motion.gif",
    "summon-motion.gif",
]

FIRMWARE_ENVS = {
    "field": ".pio/build/esp32-s3-touch-amoled-175c-field/firmware.elf",
    "fielddiag": ".pio/build/esp32-s3-touch-amoled-175c-fielddiag/firmware.elf",
    "diag": ".pio/build/esp32-s3-touch-amoled-175c-diag/firmware.elf",
    "sim": ".pio/build/esp32-s3-touch-amoled-175c-sim/firmware.elf",
}

RELEASE_PACKAGES = [
    ("Default release", "output/release-current/RELEASE_AUDIT.json", ("field", "fielddiag", "diag", "sim")),
    ("Near release", "output/release-near-current/RELEASE_AUDIT.json", ("near",)),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render Dragon Radar project acceptance status.")
    parser.add_argument(
        "--output",
        default="output/project-status.md",
        help="Output Markdown path. Use '-' to print to stdout.",
    )
    return parser.parse_args()


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def exists(path: str) -> bool:
    return (ROOT / path).exists()


def load_json(path: str) -> dict[str, Any] | None:
    report_path = ROOT / path
    if not report_path.exists():
        return None
    try:
        data = json.loads(report_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    return data if isinstance(data, dict) else None


def read_text(path: str) -> str:
    item = ROOT / path
    if not item.exists():
        return ""
    try:
        return item.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def mark(ok: bool) -> str:
    return "PASS" if ok else "TODO"


def file_mtime(path: str) -> str:
    item = ROOT / path
    if not item.exists():
        return "-"
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(item.stat().st_mtime))


def report_row(name: str, path: str) -> str:
    report = load_json(path)
    if not report:
        return f"| {name} | TODO | {path} | missing |"
    status = str(report.get("status", "unknown")).upper()
    collected = report.get("collected", 0)
    collections = report.get("collectionCount", 0)
    beacons = report.get("beaconCount", 0)
    summon = "yes" if report.get("summon") else "no"
    summary = f"{status}; beacons={beacons}; collected={collected}; collectionEvents={collections}; summon={summon}"
    return f"| {name} | {status} | {path} | {summary} |"


def release_package_ok(report: dict[str, Any] | None, expected_modes: tuple[str, ...]) -> bool:
    if not report or report.get("status") != "passed":
        return False
    return (
        report.get("previewFrameCount") == len(PREVIEW_SHOTS)
        and report.get("motionGifCount") == len(MOTION_GIFS)
        and tuple(report.get("factoryModes", [])) == expected_modes
    )


def release_package_row(name: str, path: str, expected_modes: tuple[str, ...]) -> tuple[str, bool]:
    report = load_json(path)
    if not report:
        return f"| {name} | TODO | {path} | missing |", False
    ok = release_package_ok(report, expected_modes)
    status = str(report.get("status", "unknown")).upper()
    modes = ",".join(str(item) for item in report.get("factoryModes", [])) or "-"
    summary = (
        f"{status}; modes={modes}; preview={report.get('previewFrameCount', '-')}/{len(PREVIEW_SHOTS)}; "
        f"gifs={report.get('motionGifCount', '-')}/{len(MOTION_GIFS)}; files={report.get('fileCount', '-')}"
    )
    return f"| {name} | {mark(ok)} | {path} | {summary} |", ok


def usb_diagnosis_row() -> str:
    report = load_json("output/usb-serial-diagnosis.json")
    if not report:
        return "| USB serial diagnosis | TODO | output/usb-serial-diagnosis.json | missing |"
    status = str(report.get("status", "unknown"))
    selected = report.get("selectedPort") or "-"
    summary = str(report.get("summary", ""))
    usb_layer = str(report.get("usbLayerStatus", "missing"))
    return f"| USB serial diagnosis | {status.upper()} | output/usb-serial-diagnosis.json | selected={selected}; usbLayer={usb_layer}; {summary} |"


def preboard_acceptance_row() -> tuple[str, bool]:
    path = "output/preboard-acceptance-current/preboard-acceptance-summary.json"
    report = load_json(path)
    if not report:
        return f"| Pre-board acceptance | TODO | {path} | missing |", False
    checks = report.get("checks", {})
    mock = checks.get("mockBoardSimulation", {}) if isinstance(checks, dict) else {}
    diag = checks.get("diagSevenBallReplay", {}) if isinstance(checks, dict) else {}
    ok = (
        report.get("status") == "passed"
        and report.get("hardwareProof") is False
        and mock.get("collectionCount") == 7
        and mock.get("summon") is True
        and diag.get("beaconCount") == 7
        and diag.get("collectionCount") == 7
        and diag.get("summon") is True
    )
    status = str(report.get("status", "unknown")).upper()
    summary = (
        f"{status}; hardwareProof={report.get('hardwareProof')}; "
        f"mockCollections={mock.get('collectionCount', '-')}; "
        f"diagBeacons={diag.get('beaconCount', '-')}; diagCollections={diag.get('collectionCount', '-')}; "
        f"summon={diag.get('summon', '-')}"
    )
    return f"| Pre-board acceptance | {mark(ok)} | {path} | {summary} |", ok


def refresh_performance_row() -> tuple[str, bool]:
    path = "output/diag-simulator-report.json"
    report = load_json(path)
    if not report:
        return f"| Refresh performance diagnostics | TODO | {path} | missing |", False
    frame_ms = int(report.get("frameMs") or 0)
    draw_avg_ms = int(report.get("drawAvgMs") or 0)
    draw_max_ms = int(report.get("drawMaxMs") or 0)
    over_budget = int(report.get("overBudgetFrames") or 0)
    frame_samples = int(report.get("frameSamples") or 0)
    ok = (
        report.get("status") == "passed"
        and frame_ms == 25
        and draw_avg_ms > 0
        and draw_max_ms >= draw_avg_ms
        and over_budget == 0
        and frame_samples > 0
    )
    summary = (
        f"frameMs={frame_ms or '-'}; drawAvgMs={draw_avg_ms or '-'}; "
        f"drawMaxMs={draw_max_ms or '-'}; overBudget={over_budget}/{frame_samples or '-'}"
    )
    return f"| Refresh performance diagnostics | {mark(ok)} | {path} | {summary} |", ok


def refresh_card_row() -> tuple[str, bool]:
    path = "output/refresh-performance-card.zh.md"
    text = read_text(path)
    if not text:
        return f"| Refresh performance card | TODO | {path} | missing |", False
    required = (
        "龙珠雷达刷新率排障卡",
        "tools/send_diag_command.py turbo",
        "drawAvgMs",
        "drawMaxMs",
        "overBudget",
        "硬件证明: `false`",
    )
    ok = all(item in text for item in required)
    return f"| Refresh performance card | {mark(ok)} | {path} | turbo/frame and proof boundary documented |", ok


def no_reset_display_row() -> tuple[str, bool]:
    path = "output/no-reset-display-check.json"
    report = load_json(path)
    if not report:
        return f"| No-Reset display check | TODO | {path} | missing |", False
    parsed = report.get("parsed", {})
    ok = (
        report.get("status") == "refresh-ready"
        and report.get("hardwareProof") is False
        and report.get("commandConfirmed") is True
        and int(parsed.get("frameMs") or 0) == 25
        and int(parsed.get("overBudgetFrames") or 0) == 0
    )
    summary = (
        f"{report.get('status')}; hardwareProof={report.get('hardwareProof')}; "
        f"commandConfirmed={report.get('commandConfirmed')}; "
        f"frameMs={parsed.get('frameMs') or '-'}; overBudget={parsed.get('overBudgetFrames') or 0}/{parsed.get('frameSamples') or '-'}"
    )
    return f"| No-Reset display check | {mark(ok)} | {path} | {summary} |", ok


def board_photo_qa_row() -> tuple[str, bool]:
    path = "output/board-photo-qa-sample.json"
    report = load_json(path)
    if not report:
        return f"| Board photo QA sample | TODO | {path} | missing |", False
    metrics = report.get("metrics", {})
    artifacts = report.get("visualArtifacts", {})
    crop_path = "output/board-photo-qa-sample-crop.png"
    overlay_path = "output/board-photo-qa-sample-overlay.png"
    ok = (
        report.get("status") in {"passed", "warn"}
        and report.get("hardwareProof") is False
        and int(metrics.get("greenPixels") or 0) >= 2_000
        and int(metrics.get("orangePixels") or 0) >= 4
        and exists(crop_path)
        and exists(overlay_path)
    )
    summary = (
        f"{report.get('status')}; hardwareProof={report.get('hardwareProof')}; "
        f"green={metrics.get('greenPixels', '-')}; orange={metrics.get('orangePixels', '-')}; "
        f"bandingScore={metrics.get('bandingScore', '-')}; "
        f"crop={Path(str(artifacts.get('crop', crop_path))).name}; overlay={Path(str(artifacts.get('overlay', overlay_path))).name}"
    )
    return f"| Board photo QA sample | {mark(ok)} | {path} | {summary} |", ok


def hardware_proof_packet_row() -> tuple[str, bool]:
    path = "output/hardware-proof-packet.json"
    report = load_json(path)
    if not report:
        return f"| Hardware proof packet | TODO | {path} | missing |", False
    ok = (
        report.get("status") == "not-complete"
        and report.get("hardwareProof") is False
        and {"seven_beacons", "field_hunt"}.issubset(set(report.get("missingGateKeys", [])))
    )
    missing = ",".join(str(item) for item in report.get("missingGateKeys", [])) or "-"
    summary = f"{report.get('status')}; hardwareProof={report.get('hardwareProof')}; missing={missing}"
    return f"| Hardware proof packet | {mark(ok)} | {path} | {summary} |", ok


def missing_hardware_gates_plan_row() -> tuple[str, bool]:
    path = "output/missing-hardware-gates-plan.json"
    report = load_json(path)
    if not report:
        return f"| Missing hardware gate plan | TODO | {path} | missing |", False
    selected = set(report.get("selectedGateKeys", []))
    ok = (
        report.get("status") == "planned"
        and report.get("execute") is False
        and report.get("hardwareProof") is False
        and {"seven_beacons", "field_hunt"}.issubset(selected)
    )
    summary = (
        f"{report.get('status')}; execute={report.get('execute')}; "
        f"hardwareProof={report.get('hardwareProof')}; selected={','.join(sorted(selected)) or '-'}"
    )
    return f"| Missing hardware gate plan | {mark(ok)} | {path} | {summary} |", ok


def field_tuning_row() -> tuple[str, bool]:
    path = "output/field-tuning-report.md"
    text = read_text(path)
    if not text:
        return f"| Field tuning recommendation | TODO | {path} | missing |", False
    ok = (
        "Dragon Radar Field Tuning" in text
        and "Recommended `COLLECT_RSSI`" in text
        and "Recommended `COLLECT_HOLD_MS`" in text
    )
    hardware_proof = "-"
    for line in text.splitlines():
        if line.startswith("- Hardware proof:"):
            hardware_proof = line.split(":", 1)[1].strip()
            break
    summary = f"COLLECT_RSSI/COLLECT_HOLD_MS present; hardwareProof={hardware_proof}"
    return f"| Field tuning recommendation | {mark(ok)} | {path} | {summary} |", ok


def mock_board_sim_row() -> tuple[str, bool]:
    candidates = (
        (
            "output/preboard-acceptance-current/release-selftest/board-sim-mock/bench-sim-report.json",
            "output/preboard-acceptance-current/release-selftest/board-sim-mock/board-sim-summary.json",
        ),
        (
            "output/release-selftest-current/board-sim-mock/bench-sim-report.json",
            "output/release-selftest-current/board-sim-mock/board-sim-summary.json",
        ),
    )
    for bench_path, summary_path in candidates:
        bench = load_json(bench_path)
        if not bench:
            continue
        summary = load_json(summary_path) or {}
        ok = (
            bench.get("status") == "passed"
            and bench.get("collectionCount") == 7
            and bench.get("summon") is True
            and bench.get("simulatedBle") is True
            and summary.get("hardwareProof") is False
        )
        status = str(bench.get("status", "unknown")).upper()
        details = (
            f"{status}; hardwareProof={summary.get('hardwareProof', '-')}; "
            f"collectionEvents={bench.get('collectionCount', '-')}; "
            f"summon={bench.get('summon', '-')}; simulatedBle={bench.get('simulatedBle', '-')}"
        )
        return f"| Mock one-board simulation | {mark(ok)} | {bench_path} | {details} |", ok
    return (
        "| Mock one-board simulation | TODO | "
        "output/preboard-acceptance-current/release-selftest/board-sim-mock/bench-sim-report.json | missing |",
        False,
    )


def hardware_status(report_path: str) -> tuple[bool, str]:
    report = load_json(report_path)
    if not report:
        return False, "missing report"
    hardware = report.get("hardware", {})
    required = ("touch", "imu", "ble", "audio")
    missing = [name for name in required if hardware.get(name) != "online"]
    if missing:
        return False, "offline: " + ", ".join(missing)
    return True, "touch/imu/ble/audio online"


def render() -> str:
    core_ok = all(exists(path) for path in CORE_FILES)
    preview_ok = all(exists(f"output/playwright/{name}") for name in PREVIEW_SHOTS)
    motion_ok = all(exists(f"output/playwright/{name}") for name in MOTION_GIFS)
    motion_gif_audit = load_json("output/motion-gif-audit.json")
    motion_gif_audit_ok = bool(
        motion_gif_audit
        and motion_gif_audit.get("status") == "passed"
        and len(motion_gif_audit.get("checks", [])) >= 40
    )
    firmware_ok = {name: exists(path) for name, path in FIRMWARE_ENVS.items()}
    firmware_contract = load_json("output/firmware-ui-contract.json")
    firmware_contract_ok = bool(
        firmware_contract
        and firmware_contract.get("status") == "passed"
        and len(firmware_contract.get("checks", [])) >= 40
    )
    firmware_preview_parity = load_json("output/firmware-preview-parity.json")
    firmware_preview_parity_ok = bool(
        firmware_preview_parity
        and firmware_preview_parity.get("status") == "passed"
        and len(firmware_preview_parity.get("checks", [])) >= 20
    )
    fidelity_review_text = read_text("output/fidelity-review.zh.md")
    fidelity_review_ok = (
        "龙珠雷达 UI 还原度评审" in fidelity_review_text
        and "软件 UI 还原度: PASS" in fidelity_review_text
        and "矩形网格而非圆环雷达" in fidelity_review_text
    )
    private_logo_audit = load_json("output/private-boot-logo-audit.json")
    private_logo_setup = load_json("output/private-boot-logo-setup.json")
    goal_completion = load_json("output/goal-completion-audit.json")
    goal_completion_status = str(goal_completion.get("status", "missing")) if goal_completion else "missing"
    preboard_row, preboard_ok = preboard_acceptance_row()
    refresh_perf_row, refresh_perf_ok = refresh_performance_row()
    refresh_card, refresh_card_ok = refresh_card_row()
    no_reset_display, no_reset_display_ok = no_reset_display_row()
    board_photo_qa, board_photo_qa_ok = board_photo_qa_row()
    hardware_packet, hardware_packet_ok = hardware_proof_packet_row()
    missing_hardware_plan, missing_hardware_plan_ok = missing_hardware_gates_plan_row()
    tuning_row, tuning_ok = field_tuning_row()
    mock_board_row, mock_board_ok = mock_board_sim_row()
    private_logo_ok = bool(
        private_logo_audit
        and private_logo_audit.get("status") == "passed"
        and private_logo_audit.get("summary", {}).get("localPrivateSource") == "present"
        and private_logo_audit.get("summary", {}).get("releasePrivateSourceLeaked") is False
    )
    private_logo_setup_ok = bool(
        private_logo_setup
        and private_logo_setup.get("status") == "passed"
        and private_logo_setup.get("summary", {}).get("privateSourceExists") is True
        and private_logo_setup.get("summary", {}).get("privateSourceIgnored") is True
        and private_logo_setup.get("summary", {}).get("safeToShare") is True
    )
    release_rows: list[str] = []
    release_package_flags: list[bool] = []
    for name, path, expected_modes in RELEASE_PACKAGES:
        row, ok = release_package_row(name, path, expected_modes)
        release_rows.append(row)
        release_package_flags.append(ok)
    release_packages_ok = all(release_package_flags)

    sim_report = load_json("output/bench-sim-report.json")
    field_report = load_json("output/field-hunt-report.json")
    beacon_report = load_json("output/beacon-set-verify-report.json")
    bringup_report = load_json("output/bringup-diag-report.json")
    quick_evidence = (
        exists("output/diag-simulator-report.json")
        and preview_ok
        and motion_ok
        and motion_gif_audit_ok
        and firmware_contract_ok
        and firmware_preview_parity_ok
        and fidelity_review_ok
        and private_logo_ok
        and private_logo_setup_ok
        and preboard_ok
        and refresh_perf_ok
        and refresh_card_ok
        and no_reset_display_ok
        and board_photo_qa_ok
        and hardware_packet_ok
        and missing_hardware_plan_ok
        and tuning_ok
        and mock_board_ok
        and release_packages_ok
    )

    bringup_hw_ok, bringup_hw_summary = hardware_status("output/bringup-diag-report.json")
    sim_hw_ok, sim_hw_summary = hardware_status("output/bench-sim-report.json")
    beacon_hw_ok, beacon_hw_summary = hardware_status("output/beacon-set-verify-report.json")
    field_hw_ok, field_hw_summary = hardware_status("output/field-hunt-report.json")

    hardware_complete = bool(
        bringup_hw_ok
        and sim_hw_ok
        and beacon_hw_ok
        and field_hw_ok
        and sim_report
        and sim_report.get("status") == "passed"
        and sim_report.get("collectionCount", 0) >= 7
        and beacon_report
        and beacon_report.get("status") == "passed"
        and beacon_report.get("beaconCount", 0) >= 7
        and field_report
        and field_report.get("collectionCount", 0) >= 7
        and field_report.get("summon")
    )

    lines: list[str] = [
        "# Dragon Radar Project Status",
        "",
        f"- Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- Core source files: {mark(core_ok)}",
        f"- Preview visual evidence: {mark(preview_ok)}",
        f"- Motion GIF evidence: {mark(motion_ok)}",
        f"- Motion GIF audit: {mark(motion_gif_audit_ok)}",
        f"- Release package evidence: {mark(release_packages_ok)}",
        f"- Firmware UI contract: {mark(firmware_contract_ok)}",
        f"- Firmware/preview parity: {mark(firmware_preview_parity_ok)}",
        f"- UI fidelity review: {mark(fidelity_review_ok)}",
        f"- Pre-board acceptance: {mark(preboard_ok)}",
        f"- Refresh performance diagnostics: {mark(refresh_perf_ok)}",
        f"- Refresh performance card: {mark(refresh_card_ok)}",
        f"- No-Reset display check: {mark(no_reset_display_ok)}",
        f"- Board photo QA sample: {mark(board_photo_qa_ok)}",
        f"- Hardware proof packet: {mark(hardware_packet_ok)}",
        f"- Missing hardware gate plan: {mark(missing_hardware_plan_ok)}",
        f"- Goal completion audit: {goal_completion_status.upper()}",
        f"- Private boot logo chain: {mark(private_logo_ok)}",
        f"- Private boot logo setup: {mark(private_logo_setup_ok)}",
        f"- Local quick evidence: {mark(quick_evidence)}",
        f"- Hardware completion: {'PASS' if hardware_complete else 'NOT PROVEN'}",
        "",
        "## Software Artifacts",
        "",
        "| Artifact | Status | Evidence |",
        "| --- | --- | --- |",
    ]
    for path in CORE_FILES:
        lines.append(f"| {path} | {mark(exists(path))} | mtime {file_mtime(path)} |")

    lines.extend(["", "## Preview Frames", "", "| Frame | Status | Evidence |", "| --- | --- | --- |"])
    for name in PREVIEW_SHOTS:
        path = f"output/playwright/{name}"
        lines.append(f"| {name} | {mark(exists(path))} | {path if exists(path) else 'missing'} |")

    lines.extend(["", "## Motion GIFs", "", "| GIF | Status | Evidence |", "| --- | --- | --- |"])
    for name in MOTION_GIFS:
        path = f"output/playwright/{name}"
        lines.append(f"| {name} | {mark(exists(path))} | {path if exists(path) else 'missing'} |")
    if motion_gif_audit:
        checks = motion_gif_audit.get("checks", [])
        failures = motion_gif_audit.get("failures", [])
        status = str(motion_gif_audit.get("status", "unknown")).upper()
        lines.append(
            f"| Motion GIF sequence audit | {status} | output/motion-gif-audit.json; checks={len(checks)}; failures={len(failures)} |"
        )
    else:
        lines.append("| Motion GIF sequence audit | TODO | output/motion-gif-audit.json missing |")

    lines.extend(["", "## Release Packages", "", "| Package | Status | Evidence | Summary |", "| --- | --- | --- | --- |"])
    lines.extend(release_rows)

    lines.extend(["", "## Firmware UI Contract", "", "| Audit | Status | Evidence |", "| --- | --- | --- |"])
    if firmware_contract:
        checks = firmware_contract.get("checks", [])
        failures = firmware_contract.get("failures", [])
        status = str(firmware_contract.get("status", "unknown")).upper()
        summary = f"checks={len(checks)}; failures={len(failures)}"
        lines.append(f"| Source UI contract | {status} | output/firmware-ui-contract.json; {summary} |")
    else:
        lines.append("| Source UI contract | TODO | output/firmware-ui-contract.json missing |")

    lines.extend(["", "## Firmware/Preview Parity", "", "| Audit | Status | Evidence |", "| --- | --- | --- |"])
    if firmware_preview_parity:
        checks = firmware_preview_parity.get("checks", [])
        failures = firmware_preview_parity.get("failures", [])
        status = str(firmware_preview_parity.get("status", "unknown")).upper()
        summary = f"checks={len(checks)}; failures={len(failures)}"
        lines.append(f"| Cross-surface UI parity | {status} | output/firmware-preview-parity.json; {summary} |")
    else:
        lines.append("| Cross-surface UI parity | TODO | output/firmware-preview-parity.json missing |")

    lines.extend(["", "## UI Fidelity Review", "", "| Report | Status | Evidence |", "| --- | --- | --- |"])
    if fidelity_review_text:
        lines.append(
            f"| Chinese software fidelity review | {mark(fidelity_review_ok)} | output/fidelity-review.zh.md |"
        )
    else:
        lines.append("| Chinese software fidelity review | TODO | output/fidelity-review.zh.md missing |")

    lines.extend(["", "## Goal Completion Audit", "", "| Audit | Status | Evidence |", "| --- | --- | --- |"])
    if goal_completion:
        requirements = goal_completion.get("requirements", [])
        lines.append(
            f"| Full objective completion | {goal_completion_status.upper()} | output/goal-completion-audit.json; requirements={len(requirements)} |"
        )
    else:
        lines.append("| Full objective completion | TODO | output/goal-completion-audit.json missing |")

    lines.extend(["", "## Private Boot Logo", "", "| Audit | Status | Evidence |", "| --- | --- | --- |"])
    if private_logo_audit:
        checks = private_logo_audit.get("checks", [])
        failures = private_logo_audit.get("failures", [])
        status = str(private_logo_audit.get("status", "unknown")).upper()
        summary = private_logo_audit.get("summary", {})
        evidence = (
            f"output/private-boot-logo-audit.json; checks={len(checks)}; "
            f"failures={len(failures)}; local={summary.get('localPrivateSource', '-')}; "
            f"releaseLeak={summary.get('releasePrivateSourceLeaked', '-')}"
        )
        lines.append(f"| Capsule-style private source and release boundary | {status} | {evidence} |")
    else:
        lines.append("| Capsule-style private source and release boundary | TODO | output/private-boot-logo-audit.json missing |")
    if private_logo_setup:
        checks = private_logo_setup.get("checks", [])
        failures = private_logo_setup.get("failures", [])
        status = str(private_logo_setup.get("status", "unknown")).upper()
        summary = private_logo_setup.get("summary", {})
        evidence = (
            f"output/private-boot-logo-setup.json; checks={len(checks)}; "
            f"failures={len(failures)}; local={summary.get('privateSourceExists', '-')}; "
            f"ignored={summary.get('privateSourceIgnored', '-')}; safeToShare={summary.get('safeToShare', '-')}"
        )
        lines.append(f"| Local private logo setup helper | {status} | {evidence} |")
    else:
        lines.append("| Local private logo setup helper | TODO | output/private-boot-logo-setup.json missing |")

    lines.extend(["", "## Firmware Builds", "", "| Mode | Status | Evidence |", "| --- | --- | --- |"])
    for name, path in FIRMWARE_ENVS.items():
        lines.append(f"| {name} | {mark(firmware_ok[name])} | {path if firmware_ok[name] else 'missing'} |")

    lines.extend(["", "## Diagnostic Reports", "", "| Report | Status | Path | Summary |", "| --- | --- | --- | --- |"])
    lines.append(usb_diagnosis_row())
    lines.append(preboard_row)
    lines.append(refresh_perf_row)
    lines.append(refresh_card)
    lines.append(no_reset_display)
    lines.append(board_photo_qa)
    lines.append(hardware_packet)
    lines.append(missing_hardware_plan)
    lines.append(tuning_row)
    lines.append(mock_board_row)
    lines.append(report_row("DIAG simulator", "output/diag-simulator-report.json"))
    lines.append(report_row("Real one-board simulated bench", "output/bench-sim-report.json"))
    lines.append(report_row("Hardware bring-up", "output/bringup-diag-report.json"))
    lines.append(report_row("Seven-beacon verification", "output/beacon-set-verify-report.json"))
    lines.append(report_row("Clean field hunt", "output/field-hunt-report.json"))

    lines.extend(["", "## Hardware Gates", "", "| Gate | Status | Evidence |", "| --- | --- | --- |"])
    lines.append(f"| Board touch/IMU/BLE/audio bring-up | {mark(bringup_hw_ok)} | {bringup_hw_summary} |")
    lines.append(f"| One-board sim on real board | {mark(sim_hw_ok)} | {sim_hw_summary} |")
    lines.append(f"| Seven physical beacons visible | {mark(bool(beacon_report and beacon_report.get('beaconCount', 0) >= 7))} | output/beacon-set-verify-report.json |")
    lines.append(f"| Seven collection events in real hunt | {mark(bool(field_report and field_report.get('collectionCount', 0) >= 7))} | output/field-hunt-report.json |")
    lines.append(f"| Summon observed in real hunt | {mark(bool(field_report and field_report.get('summon')))} | output/field-hunt-report.json |")

    lines.extend([
        "",
        "## Remaining Before Goal Complete",
        "",
    ])
    if hardware_complete:
        lines.append("- No missing hardware gates detected by this status report.")
    else:
        lines.extend([
            "- From the source tree, run `RADAR_PORT=/dev/cu.usbmodem101 tools/run_hardware_acceptance.sh all` for the full hardware proof sequence.",
            "- From a copied release package, run `RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh all` for the same proof gates without rebuilding firmware.",
            "- If the board was just reset, run `RADAR_PORT=/dev/cu.usbmodem101 tools/run_missing_hardware_gates.py --execute` to close only the missing gates.",
            "- Run `RADAR_PORT=/dev/cu.usbmodem101 tools/bringup_diag.sh all` on the real board.",
            "- Run `RADAR_PORT=/dev/cu.usbmodem101 tools/bench_sim.sh all` to prove screen/touch/IMU/BLE/audio plus seven simulated collection events.",
            "- Flash and power all seven physical beacons, then run `RADAR_PORT=/dev/cu.usbmodem101 tools/verify_beacon_set.sh all`.",
            "- Record a real clean UI round with `RADAR_PORT=/dev/cu.usbmodem101 tools/record_field_hunt.sh all` and verify seven collection events plus summon.",
        ])
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    markdown = render()
    if args.output == "-":
        print(markdown, end="")
        return 0
    output = ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(markdown, encoding="utf-8")
    print(rel(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
