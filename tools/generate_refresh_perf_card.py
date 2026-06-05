#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a Chinese refresh-rate troubleshooting card for Dragon Radar.")
    parser.add_argument("--output", default="output/refresh-performance-card.zh.md", help="Output Markdown path.")
    parser.add_argument("--release-dir", default=os.environ.get("RELEASE_DIR", "output/release-current"))
    parser.add_argument(
        "--diag-json",
        default=None,
        help="DIAG report JSON path. Default: release evidence or output/diag-simulator-report.json.",
    )
    parser.add_argument(
        "--runtime-json",
        default=None,
        help="Optional board runtime diagnosis JSON path. Default: output/board-runtime-diagnosis.json when present.",
    )
    parser.add_argument("--radar-port", default=os.environ.get("RADAR_PORT", "/dev/cu.usbmodem101"))
    return parser.parse_args()


def normalize(path: str | Path) -> Path:
    item = Path(path)
    return item if item.is_absolute() else ROOT / item


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def choose_diag(args: argparse.Namespace, release_dir: Path) -> Path:
    if args.diag_json:
        return normalize(args.diag_json)
    for candidate in (
        release_dir / "evidence" / "diag-simulator-report.json",
        ROOT / "output" / "diag-simulator-report.json",
    ):
        if candidate.exists():
            return candidate
    return ROOT / "output" / "diag-simulator-report.json"


def choose_runtime(args: argparse.Namespace) -> Path:
    if args.runtime_json:
        return normalize(args.runtime_json)
    return ROOT / "output" / "board-runtime-diagnosis.json"


def number(report: dict[str, Any], key: str) -> int | None:
    value = report.get(key)
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def text_value(value: Any) -> str:
    if value is None or value == "":
        return "-"
    return str(value)


def perf_status(report: dict[str, Any]) -> tuple[str, str]:
    frame_ms = number(report, "frameMs")
    draw_avg = number(report, "drawAvgMs")
    draw_max = number(report, "drawMaxMs")
    over_budget = number(report, "overBudgetFrames")
    samples = number(report, "frameSamples")
    if not report:
        return "UNKNOWN", "没有可用 DIAG 报告，先跑 `tools/monitor_diag.py` 或 DIAG 模拟。"
    if frame_ms == 25 and draw_avg and draw_max and over_budget == 0 and samples:
        return "PASS", "当前软件 DIAG 证据显示 25ms 刷新目标下绘制没有超预算。"
    if frame_ms and draw_max and draw_max > frame_ms:
        return "WARN", "drawMaxMs 已经高于 frameMs，显示绘制或总线传输可能拖慢刷新。"
    if over_budget and over_budget > 0:
        return "WARN", "存在超预算帧，先降低刷新目标或总线压力，再判断屏闪。"
    return "UNKNOWN", "证据不足，先采集含 drawAvgMs、drawMaxMs、overBudget 的 DIAG。"


def runtime_summary(runtime: dict[str, Any]) -> list[str]:
    if not runtime:
        return ["- 板载运行态诊断: `未提供`。"]
    parsed = runtime.get("parsed", {})
    if not isinstance(parsed, dict):
        parsed = {}
    return [
        f"- 板载运行态诊断: `{text_value(runtime.get('status'))}`。",
        f"- 运行态 frameMs: `{text_value(parsed.get('frameMs'))}`；drawAvg/drawMax: `{text_value(parsed.get('drawAvgMs'))}` / `{text_value(parsed.get('drawMaxMs'))}` ms。",
        f"- 运行态超预算帧: `{text_value(parsed.get('overBudgetFrames'))}` / `{text_value(parsed.get('frameSamples'))}`。",
    ]


def render(args: argparse.Namespace) -> str:
    release_dir = normalize(args.release_dir)
    diag_path = choose_diag(args, release_dir)
    runtime_path = choose_runtime(args)
    diag = load_json(diag_path)
    runtime = load_json(runtime_path) if runtime_path.exists() else {}
    status, verdict = perf_status(diag)
    generated = time.strftime("%Y-%m-%d %H:%M:%S")
    frame_ms = number(diag, "frameMs")
    draw_ms = number(diag, "drawMs")
    draw_avg = number(diag, "drawAvgMs")
    draw_max = number(diag, "drawMaxMs")
    over_budget = number(diag, "overBudgetFrames")
    samples = number(diag, "frameSamples")
    port = args.radar_port

    lines = [
        "# 龙珠雷达刷新率排障卡",
        "",
        f"- 生成时间: {generated}",
        f"- 诊断来源: `{diag_path}`",
        f"- 刷新状态: `{status}`",
        f"- 结论: {verdict}",
        f"- 硬件证明: `false`，这张卡不能单独证明 goal 完成。",
        "",
        "## 当前刷新证据",
        "",
        "| 指标 | 当前值 | 判断 |",
        "| --- | --- | --- |",
        f"| frameMs | `{text_value(frame_ms)}` | 目标刷新间隔；当前软件默认应为 `25` ms |",
        f"| drawMs | `{text_value(draw_ms)}` | 最近一次绘制成本 |",
        f"| drawAvgMs | `{text_value(draw_avg)}` | 约 1 秒滚动平均绘制成本 |",
        f"| drawMaxMs | `{text_value(draw_max)}` | 约 1 秒滚动最大绘制成本 |",
        f"| overBudget | `{text_value(over_budget)}/{text_value(samples)}` | 超过 frameMs 的帧数，理想值是 `0` |",
        "",
        "## 板载运行态参考",
        "",
    ]
    lines.extend(runtime_summary(runtime))
    lines.extend(
        [
            "",
            "## 如何判断卡在哪里",
            "",
            "1. 如果 `frameMs=25`、`drawMaxMs <= frameMs` 且 `overBudget=0`，固件绘制路径基本健康；肉眼觉得刷新低，优先检查相机快门/曝光、旧设置未切到 turbo，或浏览器预览与真板感受差异。",
            "2. 如果 `frameMs` 不是 `25`，先发送 turbo 命令恢复最快预设。",
            "3. 如果 `drawMaxMs > frameMs` 或 `overBudget > 0`，说明绘制或显示总线超预算；先退到 `33ms` 或 `50ms`，再逐步找屏闪和流畅度平衡。",
            "4. 如果刷新正常但仍屏闪，优先尝试降低显示总线到 `DISPLAY_BUS_HZ=40000000`，再看屏闪是否消失。",
            "5. 如果打开 debug/fielddiag 后变慢，切回干净 UI 的 `field` 或 `sim` 模式复测，因为 HUD 文本和诊断输出会增加绘制压力。",
            "",
            "## 串口命令",
            "",
            f"- 直接切最快刷新：`RADAR_PORT={port} tools/send_diag_command.py turbo`。",
            f"- 循环刷新档位：`RADAR_PORT={port} tools/send_diag_command.py frame`。",
            f"- 采集 12 秒 DIAG：`RADAR_PORT={port} tools/monitor_diag.py --timeout 12 --report-json output/bench-sim-report.json --log-file output/bench-sim-raw.log`。",
            f"- 看板载运行态：`RADAR_PORT={port} tools/diagnose_board_runtime.py`。",
            "",
            "## 无法手动 Reset 时",
            "",
            f"1. 先不刷机，尝试恢复运行态：`RADAR_PORT={port} tools/recover_board_runtime.py`。",
            f"2. 首跑助手自动恢复：`RADAR_PORT={port} tools/first_run_zh.py live --recover-runtime`。",
            f"3. 只有报告显示 `bootloader-reachable` 且确认端口后，再考虑 `RADAR_PORT={port} tools/flash_release_firmware.sh sim`。",
            "4. 如果自动 reset 线序失败，再进入实体 Reset/BOOT；当前软件排障不要求你手动 Reset。",
            "",
            "## 编译侧回退",
            "",
            "- 回退刷新目标：`FRAME_MS=33 tools/build_radar.sh sim`。",
            "- 更保守刷新：`FRAME_MS=50 tools/build_radar.sh sim`。",
            "- 降低显示总线排查屏闪：`DISPLAY_BUS_HZ=40000000 tools/build_radar.sh sim`。",
            "- 如果屏闪消失但刷新仍低，再用 DIAG 的 `drawAvgMs` / `drawMaxMs` / `overBudget` 决定是否恢复 25ms。",
            "",
            "## 验收边界",
            "",
            "- 这张卡只证明软件链路能解释刷新率和屏闪问题，不能代替真实 ESP32-S3 真板验收。",
            "- goal 结束仍需要真板 bring-up、一块板 sim、7 个实体信标、干净 UI 实战收集和召唤报告。",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    output = normalize(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(args), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
