#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODES = ("field", "fielddiag", "diag", "sim")
VALID_MODES = DEFAULT_MODES + ("near",)


def in_release_root() -> bool:
    return (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir()


def default_release_dir() -> Path:
    return ROOT if in_release_root() else ROOT / "output" / "release-current"


def default_output() -> Path:
    return ROOT / "docs" / "playtest-rehearsal.zh.md" if in_release_root() else ROOT / "output" / "playtest-rehearsal.zh.md"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render a Chinese Dragon Radar playtest rehearsal report.")
    parser.add_argument("--release-dir", default=None, help="Release folder to summarize. Default: output/release-current or copied release root.")
    parser.add_argument("--output", default=None, help="Output Markdown path. Default: output/playtest-rehearsal.zh.md or docs/playtest-rehearsal.zh.md in a release.")
    parser.add_argument("--selftest-summary", default=None, help="Optional release-selftest-summary.json path.")
    parser.add_argument("--bench-report", default=None, help="Optional mock bench-sim-report.json path.")
    parser.add_argument("--usb-diagnosis", default=None, help="Optional usb-serial-diagnosis.json path.")
    parser.add_argument("--tuning-report", default=None, help="Optional field-tuning-report.md path.")
    parser.add_argument("--radar-port", default="/dev/cu.usbmodem101", help="Port shown in commands when no live port is selected.")
    return parser.parse_args()


def normalize_path(value: str | None, fallback: Path) -> Path:
    path = Path(value) if value else fallback
    return path if path.is_absolute() else ROOT / path


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def load_json(path: Path | None) -> dict[str, Any] | None:
    if not path or not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return data if isinstance(data, dict) else None


def parse_modes(value: str) -> tuple[str, ...]:
    modes = tuple(item.strip("`") for item in value.replace(",", " ").split() if item)
    unknown = [mode for mode in modes if mode not in VALID_MODES]
    if unknown:
        raise SystemExit("unknown release mode(s): " + ", ".join(unknown))
    return modes or DEFAULT_MODES


def release_modes(release_dir: Path) -> tuple[str, ...]:
    audit = load_json(release_dir / "RELEASE_AUDIT.json")
    if audit:
        expected = audit.get("expectedModes")
        if isinstance(expected, list) and all(isinstance(item, str) for item in expected):
            return parse_modes(" ".join(expected))

    manifest = release_dir / "MANIFEST.md"
    if manifest.exists():
        for line in manifest.read_text(encoding="utf-8", errors="replace").splitlines():
            prefix = "- Requested radar modes:"
            if line.startswith(prefix):
                return parse_modes(line[len(prefix):].strip())
    return DEFAULT_MODES


def selftest_candidates() -> list[Path]:
    patterns = (
        "output/release-selftest*/release-selftest-summary.json",
        "evidence/release-selftest*/release-selftest-summary.json",
    )
    candidates: list[Path] = []
    for pattern in patterns:
        candidates.extend(ROOT.glob(pattern))
    return sorted(candidates, key=lambda path: path.stat().st_mtime, reverse=True)


def same_path(left: str | None, right: Path) -> bool:
    if not left:
        return False
    try:
        return Path(left).resolve() == right.resolve()
    except OSError:
        return False


def choose_selftest_summary(explicit: str | None, modes: tuple[str, ...], release_dir: Path) -> Path | None:
    if explicit:
        return normalize_path(explicit, Path(explicit))
    preferred_name = "release-selftest-near-current" if modes == ("near",) else "release-selftest-current"
    for candidate in (
        ROOT / "output" / preferred_name / "release-selftest-summary.json",
        ROOT / "evidence" / "release-selftest" / "release-selftest-summary.json",
    ):
        data = load_json(candidate)
        expected = data.get("expectedModes") if data else None
        if isinstance(expected, list) and tuple(expected) == modes:
            if same_path(data.get("releaseDir") if data else None, release_dir) or candidate.exists():
                return candidate
    latest_matching_modes: Path | None = None
    for candidate in selftest_candidates():
        data = load_json(candidate)
        expected = data.get("expectedModes") if data else None
        if isinstance(expected, list) and tuple(expected) == modes:
            latest_matching_modes = latest_matching_modes or candidate
            if same_path(data.get("releaseDir") if data else None, release_dir):
                return candidate
    return latest_matching_modes


def choose_bench_report(explicit: str | None, selftest: dict[str, Any] | None) -> Path | None:
    if explicit:
        return normalize_path(explicit, Path(explicit))
    if selftest:
        output_dir = selftest.get("outputDir")
        if isinstance(output_dir, str):
            candidate = Path(output_dir) / "board-sim-mock" / "bench-sim-report.json"
            if candidate.exists():
                return candidate
    candidates = sorted(
        list(ROOT.glob("output/**/board-sim-mock/bench-sim-report.json"))
        + list(ROOT.glob("evidence/**/board-sim-mock/bench-sim-report.json")),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


def choose_usb_diagnosis(explicit: str | None, release_dir: Path) -> Path | None:
    if explicit:
        return normalize_path(explicit, Path(explicit))
    for candidate in (
        ROOT / "output" / "usb-serial-diagnosis.json",
        release_dir / "evidence" / "usb-serial-diagnosis.json",
        ROOT / "evidence" / "usb-serial-diagnosis.json",
    ):
        if candidate.exists():
            return candidate
    return None


def choose_tuning_report(explicit: str | None, release_dir: Path) -> Path | None:
    if explicit:
        return normalize_path(explicit, Path(explicit))
    for candidate in (
        release_dir / "docs" / "field-tuning-report.md",
        ROOT / "output" / "field-tuning-report.md",
        ROOT / "docs" / "field-tuning-report.md",
    ):
        if candidate.exists():
            return candidate
    return None


def read_text(path: Path | None) -> str:
    if not path or not path.exists():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def tuning_summary(path: Path | None) -> dict[str, str] | None:
    text = read_text(path)
    if not text:
        return None
    def match(pattern: str, default: str = "-") -> str:
        found = re.search(pattern, text)
        return found.group(1) if found else default
    return {
        "path": rel(path) if path else "-",
        "rssi": match(r"Recommended `COLLECT_RSSI`: `([^`]+)`"),
        "holdMs": match(r"Recommended `COLLECT_HOLD_MS`: `([^`]+)`"),
        "sourceKind": match(r"Source kind: `([^`]+)`"),
        "hardwareProof": match(r"Hardware proof: `([^`]+)`"),
    }


def status(value: Any) -> str:
    return str(value or "missing").upper()


def yes_no(value: Any) -> str:
    return "是" if bool(value) else "否"


def command(text: str) -> str:
    return f"`{text}`"


def firmware_mode_label(modes: tuple[str, ...]) -> str:
    labels = {
        "field": "正式游玩",
        "fielddiag": "正式记录",
        "diag": "硬件诊断",
        "sim": "一块板模拟",
        "near": "小场地近距离",
    }
    return "、".join(f"{mode}({labels[mode]})" for mode in modes)


def selected_port(usb: dict[str, Any] | None, fallback: str) -> str:
    if usb and usb.get("selectedPort"):
        return str(usb["selectedPort"])
    return fallback


def render_collection_rows(bench: dict[str, Any] | None) -> list[str]:
    rows = ["| 顺序 | 龙珠 | ms | 方位 bin | 角度 | 距离 | RSSI |", "| ---: | --- | ---: | ---: | ---: | ---: | ---: |"]
    collections = bench.get("collections", []) if bench else []
    if not isinstance(collections, list) or not collections:
        rows.append("| 0 | 未生成 | - | - | - | - | - |")
        return rows
    for order, item in enumerate(collections[:7], start=1):
        if not isinstance(item, dict):
            continue
        rows.append(
            f"| {order} | DBALL-{item.get('index', '-')} | {item.get('ms', '-')} | "
            f"{item.get('bearingBin', '-')} | {item.get('bearing', '-')} | "
            f"{item.get('range', '-')} | {item.get('filtered', item.get('raw', '-'))} |"
        )
    return rows


def render_recommendations(usb: dict[str, Any] | None) -> list[str]:
    if not usb:
        return ["- 还没有 USB 串口诊断报告，先运行 `tools/diagnose_usb_serial.py`。"]
    recommendations = usb.get("recommendations", [])
    if not isinstance(recommendations, list) or not recommendations:
        return [f"- USB 状态：{usb.get('summary', 'unknown')}"]
    return [f"- {item}" for item in recommendations if isinstance(item, str)]


def render(args: argparse.Namespace) -> str:
    release_dir = normalize_path(args.release_dir, default_release_dir())
    modes = release_modes(release_dir)
    selftest_path = choose_selftest_summary(args.selftest_summary, modes, release_dir)
    selftest = load_json(selftest_path)
    bench_path = choose_bench_report(args.bench_report, selftest)
    bench = load_json(bench_path)
    usb_path = choose_usb_diagnosis(args.usb_diagnosis, release_dir)
    usb = load_json(usb_path)
    tuning = tuning_summary(choose_tuning_report(args.tuning_report, release_dir))
    parity = load_json(ROOT / "output" / "firmware-preview-parity.json") or load_json(release_dir / "evidence" / "firmware-preview-parity.json")
    preview = load_json(ROOT / "output" / "preview-visual-audit.json") or load_json(release_dir / "evidence" / "preview-visual-audit.json")

    port = selected_port(usb, args.radar_port)
    playable_mode = "near" if modes == ("near",) else "field"
    selftest_passed = bool(selftest and selftest.get("status") == "passed")
    bench_passed = bool(
        bench
        and bench.get("status") == "passed"
        and bench.get("collectionCount", 0) >= 7
        and bench.get("summon") is True
    )
    ui_passed = bool(parity and parity.get("status") == "passed" and preview and preview.get("status") == "passed")
    usb_status = str(usb.get("status", "missing")) if usb else "missing"

    lines: list[str] = [
        "# 龙珠雷达试玩演练报告",
        "",
        f"- 生成时间: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- 发布包: `{rel(release_dir)}`",
        f"- 固件模式: {firmware_mode_label(modes)}",
        f"- 发布包自检: {status(selftest.get('status') if selftest else None)}",
        f"- mock 七球演练: {'PASS' if bench_passed else 'TODO'}",
        f"- 开局采集阈值建议: {'PASS' if tuning else 'TODO'}",
        f"- UI 一致性/视觉审计: {'PASS' if ui_passed else 'TODO'}",
        f"- USB 串口状态: {usb_status}",
        f"- 硬件证明: `false`",
        "",
        "这份报告用于朋友试玩前的无板演练和上板前检查。它能证明软件包、UI 证据、DIAG 解析和七球流程已经连通；它不能替代真板 OLED、触摸、IMU、BLE、音频和实体信标验收。",
        "",
        "## 当前可证明",
        "",
        f"- 发布包结构和校验: {'通过' if selftest_passed else '未证明'}"
        + (f" ({rel(selftest_path)})" if selftest_path else ""),
        f"- mock DIAG 七球流程: {'通过' if bench_passed else '未证明'}"
        + (f" ({rel(bench_path)})" if bench_path else ""),
        f"- 固件/预览 UI 同步: {'通过' if ui_passed else '未证明'}"
        + (f"; parity checks={len(parity.get('checks', []))}" if parity else ""),
        f"- 真实硬件闭环: 未证明，必须等 ESP32-S3 串口可见后再跑上板验收。",
        "",
        "## mock 七球路线",
        "",
    ]
    lines.extend(render_collection_rows(bench))
    lines.extend(
        [
            "",
            "## 开局采集阈值建议",
            "",
        ]
    )
    if tuning:
        lines.extend(
            [
                f"- 报告: `{tuning['path']}`",
                f"- 建议 `COLLECT_RSSI={tuning['rssi']}`，`COLLECT_HOLD_MS={tuning['holdMs']}`。",
                f"- 来源: `{tuning['sourceKind']}`; hardwareProof=`{tuning['hardwareProof']}`。",
                "- 这只是朋友试玩的开局参数，真板到手后仍要用实体信标重新校准。",
            ]
        )
    else:
        lines.append("- 尚未生成。可先运行 `tools/recommend_field_tuning.py`，无真板时会使用 mock 上板前证据给出开局值。")
    lines.extend(
        [
            "",
            "## 试玩当天流程卡",
            "",
            "1. 先开 `docs/visual-qa.html` 和 `docs/motion-qa.html`，确认开机扫描、矩形网格、召唤动画符合预期。",
            f"2. 无板时运行 {command('tools/selftest_release.py')}，只看发布包和 mock 流程。",
            f"3. 插上主板后运行 {command('tools/run_board_sim_test.py port-check')} 找 ESP32-S3 串口。",
            f"4. 换线或按 BOOT/Reset 时运行 {command('tools/wait_for_radar_port.py --run-auto')}，等串口出现后自动跑一块板烟测。",
            f"5. 试玩固件刷 {command(f'RADAR_PORT={port} tools/flash_release_firmware.sh {playable_mode}')}。",
            f"6. 7 个实体信标上电后运行 {command(f'RADAR_PORT={port} tools/run_release_acceptance.sh all')} 做最终证明。",
            "",
            "## 当前阻塞项",
            "",
        ]
    )
    lines.extend(render_recommendations(usb))
    lines.extend(
        [
            "",
            "## 验收边界",
            "",
            f"- mock 报告里的 `hardwareProof` 必须保持 `false`: {yes_no(selftest and selftest.get('hardwareProof') is False)}。",
            "- 目标完成需要真实板子通过 bring-up、一块板 sim、7 个实体信标、干净 field/near 实战收集和召唤。",
            "- 发布包不会复制 `private_boot_logo.h` 私有源文件；本机编译的二进制会保留本地开机图形。",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    output = normalize_path(args.output, default_output())
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(args), encoding="utf-8")
    print(rel(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
