#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import statistics
import time
from collections import deque
from pathlib import Path
from typing import Any

try:
    from PIL import Image, ImageDraw
except ImportError as exc:
    raise SystemExit("Pillow is required: python3 -m pip install pillow") from exc


ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze a real Dragon Radar screen photo or preview frame.")
    parser.add_argument("image", help="Photo or preview PNG to analyze.")
    parser.add_argument("--json-output", default="output/board-photo-qa-sample.json", help="JSON report path.")
    parser.add_argument("--md-output", default="output/board-photo-qa-sample.zh.md", help="Chinese Markdown report path.")
    parser.add_argument("--crop-output", default=None, help="Optional PNG crop of the detected screen region.")
    parser.add_argument("--overlay-output", default=None, help="Optional PNG with the detected region marked on the source image.")
    parser.add_argument("--max-dimension", type=int, default=900, help="Downsample max dimension for analysis.")
    parser.add_argument("--print-json", action="store_true", help="Print JSON report.")
    return parser.parse_args()


def normalize(path: str | Path) -> Path:
    item = Path(path)
    return item if item.is_absolute() else ROOT / item


def is_green(r: int, g: int, b: int) -> bool:
    return g > 70 and g > r * 1.25 and g > b * 1.08


def is_orange(r: int, g: int, b: int) -> bool:
    return r > 145 and 45 < g < 220 and b < 95 and r > g * 1.08


def is_dark(r: int, g: int, b: int) -> bool:
    return r < 45 and g < 55 and b < 45


def luminance(rgb: tuple[int, int, int]) -> float:
    r, g, b = rgb
    return 0.299 * r + 0.587 * g + 0.114 * b


def resize_for_analysis(image: Image.Image, max_dimension: int) -> tuple[Image.Image, float]:
    width, height = image.size
    scale = min(1.0, max_dimension / max(width, height))
    if scale >= 0.999:
        return image.copy(), 1.0
    resized = image.resize((max(1, round(width * scale)), max(1, round(height * scale))), Image.Resampling.LANCZOS)
    return resized, scale


def active_bin_components(mask: bytearray, width: int, height: int, bin_size: int) -> tuple[tuple[int, int, int, int], int]:
    bins_x = math.ceil(width / bin_size)
    bins_y = math.ceil(height / bin_size)
    counts = [[0 for _ in range(bins_x)] for _ in range(bins_y)]
    for y in range(height):
        row = y * width
        by = y // bin_size
        for x in range(width):
            if mask[row + x]:
                counts[by][x // bin_size] += 1

    active = [[False for _ in range(bins_x)] for _ in range(bins_y)]
    threshold = max(3, int(bin_size * bin_size * 0.08))
    for by in range(bins_y):
        for bx in range(bins_x):
            active[by][bx] = counts[by][bx] >= threshold

    best_bbox = (0, 0, width - 1, height - 1)
    best_count = 0
    visited = [[False for _ in range(bins_x)] for _ in range(bins_y)]
    for start_y in range(bins_y):
        for start_x in range(bins_x):
            if visited[start_y][start_x] or not active[start_y][start_x]:
                continue
            queue: deque[tuple[int, int]] = deque([(start_x, start_y)])
            visited[start_y][start_x] = True
            min_x = max_x = start_x
            min_y = max_y = start_y
            total = 0
            while queue:
                bx, by = queue.popleft()
                total += counts[by][bx]
                min_x = min(min_x, bx)
                max_x = max(max_x, bx)
                min_y = min(min_y, by)
                max_y = max(max_y, by)
                for nx, ny in ((bx - 1, by), (bx + 1, by), (bx, by - 1), (bx, by + 1)):
                    if 0 <= nx < bins_x and 0 <= ny < bins_y and active[ny][nx] and not visited[ny][nx]:
                        visited[ny][nx] = True
                        queue.append((nx, ny))
            if total > best_count:
                best_count = total
                best_bbox = (
                    max(0, min_x * bin_size),
                    max(0, min_y * bin_size),
                    min(width - 1, (max_x + 1) * bin_size - 1),
                    min(height - 1, (max_y + 1) * bin_size - 1),
                )
    return best_bbox, best_count


def detect_region(image: Image.Image) -> tuple[tuple[int, int, int, int], int, int]:
    width, height = image.size
    pixels = image.load()
    mask = bytearray(width * height)
    candidate_count = 0
    for y in range(height):
        for x in range(width):
            rgb = pixels[x, y]
            if is_green(*rgb) or is_orange(*rgb):
                mask[y * width + x] = 1
                candidate_count += 1
    bin_size = max(8, min(width, height) // 52)
    bbox, component_count = active_bin_components(mask, width, height, bin_size)
    if component_count <= 0 and candidate_count > 0:
        xs: list[int] = []
        ys: list[int] = []
        for y in range(height):
            row = y * width
            for x in range(width):
                if mask[row + x]:
                    xs.append(x)
                    ys.append(y)
        bbox = (min(xs), min(ys), max(xs), max(ys))
        component_count = candidate_count
    return bbox, component_count, candidate_count


def clamp_bbox(bbox: tuple[int, int, int, int], image: Image.Image, pad: int = 4) -> tuple[int, int, int, int]:
    width, height = image.size
    left, top, right, bottom = bbox
    return max(0, left - pad), max(0, top - pad), min(width - 1, right + pad), min(height - 1, bottom + pad)


def analyze_region(image: Image.Image, bbox: tuple[int, int, int, int]) -> dict[str, Any]:
    left, top, right, bottom = bbox
    width = max(1, right - left + 1)
    height = max(1, bottom - top + 1)
    total = width * height
    green = orange = dark = 0
    pixels = image.load()
    column_green: list[float] = []
    row_green_totals = [0 for _ in range(height)]
    edge_x = 0.0
    edge_y = 0.0
    edge_x_count = 0
    edge_y_count = 0

    for x in range(left, right + 1):
        hits = 0
        for y in range(top, bottom + 1):
            rgb = pixels[x, y]
            if is_green(*rgb):
                green += 1
                hits += 1
                row_green_totals[y - top] += 1
            if is_orange(*rgb):
                orange += 1
            if is_dark(*rgb):
                dark += 1
            if x > left:
                edge_x += abs(luminance(rgb) - luminance(pixels[x - 1, y]))
                edge_x_count += 1
            if y > top:
                edge_y += abs(luminance(rgb) - luminance(pixels[x, y - 1]))
                edge_y_count += 1
        column_green.append(hits / height)

    row_green = [value / width for value in row_green_totals]
    column_mean = statistics.fmean(column_green) if column_green else 0.0
    row_mean = statistics.fmean(row_green) if row_green else 0.0
    column_std = statistics.pstdev(column_green) if len(column_green) > 1 else 0.0
    row_std = statistics.pstdev(row_green) if len(row_green) > 1 else 0.0
    column_variation = column_std / max(column_mean, 0.001)
    row_variation = row_std / max(row_mean, 0.001)
    edge_x_avg = edge_x / max(edge_x_count, 1)
    edge_y_avg = edge_y / max(edge_y_count, 1)
    vertical_dominance = edge_x_avg / max(edge_y_avg, 0.001)
    banding_score = max(0.0, column_variation - row_variation)

    return {
        "bbox": {"left": left, "top": top, "right": right, "bottom": bottom, "width": width, "height": height},
        "greenPixels": green,
        "orangePixels": orange,
        "darkPixels": dark,
        "totalPixels": total,
        "greenRatio": green / total,
        "orangeRatio": orange / total,
        "darkRatio": dark / total,
        "columnGreenVariation": column_variation,
        "rowGreenVariation": row_variation,
        "edgeX": edge_x_avg,
        "edgeY": edge_y_avg,
        "verticalDominance": vertical_dominance,
        "bandingScore": banding_score,
    }


def make_check(name: str, status: str, summary: str, evidence: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"name": name, "status": status, "summary": summary, "evidence": evidence or {}}


def checks_for(metrics: dict[str, Any], component_count: int, candidate_count: int) -> list[dict[str, Any]]:
    bbox = metrics["bbox"]
    region_area = bbox["width"] * bbox["height"]
    checks: list[dict[str, Any]] = []
    checks.append(
        make_check(
            "photo.screen-region.detected",
            "passed" if component_count >= 80 and region_area >= 1_500 else "failed",
            "找到由绿色网格/橙色目标组成的主要屏幕区域。",
            {"componentPixels": component_count, "candidatePixels": candidate_count, "regionArea": region_area},
        )
    )
    checks.append(
        make_check(
            "photo.rectangular-grid.present",
            "passed" if metrics["greenRatio"] >= 0.035 or metrics["greenPixels"] >= 2_000 else "failed",
            "绿色矩形网格/网格面可见。",
            {"greenRatio": round(metrics["greenRatio"], 4), "greenPixels": metrics["greenPixels"]},
        )
    )
    checks.append(
        make_check(
            "photo.orange-targets.present",
            "passed" if metrics["orangePixels"] >= 4 else "failed",
            "橙色目标点可见。",
            {"orangePixels": metrics["orangePixels"]},
        )
    )
    stripe_warn = metrics["bandingScore"] > 0.38 or metrics["verticalDominance"] > 2.8
    checks.append(
        make_check(
            "photo.banding-risk",
            "warn" if stripe_warn else "passed",
            "评估实拍中是否出现明显列向条纹/刷新拍摄条纹。",
            {
                "bandingScore": round(metrics["bandingScore"], 4),
                "verticalDominance": round(metrics["verticalDominance"], 4),
                "columnGreenVariation": round(metrics["columnGreenVariation"], 4),
                "rowGreenVariation": round(metrics["rowGreenVariation"], 4),
            },
        )
    )
    checks.append(
        make_check(
            "photo.goal-proof-boundary",
            "passed",
            "照片 QA 只能证明屏幕画面特征，不能单独证明完整硬件验收。",
            {"hardwareProof": False},
        )
    )
    return checks


def overall_status(checks: list[dict[str, Any]]) -> str:
    if any(check["status"] == "failed" for check in checks):
        return "failed"
    if any(check["status"] == "warn" for check in checks):
        return "warn"
    return "passed"


def recommendations(status: str, metrics: dict[str, Any]) -> list[str]:
    items: list[str] = []
    if status == "failed":
        items.append("重新拍一张只包含圆形屏幕的照片，避免 iOS 照片 UI、键盘和电脑屏幕进入画面。")
    if metrics["orangePixels"] < 4:
        items.append("当前画面没有足够橙色目标点；切到 sim/diag 或让目标靠近后再拍。")
    if metrics["bandingScore"] > 0.38 or metrics["verticalDominance"] > 2.8:
        items.append("实拍条纹较明显：先用 `tools/run_no_reset_display_check.py --command turbo` 确认 drawAvg/drawMax/overBudget。")
        items.append("若 DIAG 显示绘制不过预算但照片仍有条纹，优先对照 `DISPLAY_BUS_HZ=40000000 tools/build_radar.sh sim` 或调整相机快门/曝光。")
    if not items:
        items.append("画面特征通过；下一步仍需要真板 DIAG、实体 7 信标和实战收集报告证明完整 goal。")
    return items


def build_report(args: argparse.Namespace) -> dict[str, Any]:
    source = normalize(args.image)
    image = Image.open(source).convert("RGB")
    small, scale = resize_for_analysis(image, args.max_dimension)
    bbox, component_count, candidate_count = detect_region(small)
    bbox = clamp_bbox(bbox, small)
    metrics = analyze_region(small, bbox)
    checks = checks_for(metrics, component_count, candidate_count)
    status = overall_status(checks)
    scale_back = 1 / scale
    original_bbox = {
        key: round(value * scale_back)
        for key, value in metrics["bbox"].items()
        if key in {"left", "top", "right", "bottom", "width", "height"}
    }
    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": status,
        "sourceImage": str(source),
        "imageSize": {"width": image.size[0], "height": image.size[1]},
        "analysisSize": {"width": small.size[0], "height": small.size[1], "scale": scale},
        "hardwareProof": False,
        "photoEvidence": True,
        "screenRegion": original_bbox,
        "metrics": metrics,
        "checks": checks,
        "recommendations": recommendations(status, metrics),
        "visualArtifacts": {},
    }


def save_visual_artifacts(args: argparse.Namespace, report: dict[str, Any]) -> None:
    artifacts: dict[str, str] = {}
    if not args.crop_output and not args.overlay_output:
        report["visualArtifacts"] = artifacts
        return
    source = normalize(args.image)
    image = Image.open(source).convert("RGB")
    bbox = report["screenRegion"]
    left = int(bbox["left"])
    top = int(bbox["top"])
    right = int(bbox["right"])
    bottom = int(bbox["bottom"])
    if args.crop_output:
        crop_path = normalize(args.crop_output)
        crop_path.parent.mkdir(parents=True, exist_ok=True)
        image.crop((left, top, right + 1, bottom + 1)).save(crop_path)
        artifacts["crop"] = str(crop_path)
    if args.overlay_output:
        overlay_path = normalize(args.overlay_output)
        overlay_path.parent.mkdir(parents=True, exist_ok=True)
        overlay = image.copy()
        draw = ImageDraw.Draw(overlay)
        line_width = max(3, round(min(image.size) * 0.006))
        draw.rectangle((left, top, right, bottom), outline=(255, 139, 28), width=line_width)
        corner = max(18, round(min(right - left + 1, bottom - top + 1) * 0.10))
        for x1, y1, x2, y2 in (
            (left, top, left + corner, top),
            (left, top, left, top + corner),
            (right - corner, top, right, top),
            (right, top, right, top + corner),
            (left, bottom, left + corner, bottom),
            (left, bottom - corner, left, bottom),
            (right - corner, bottom, right, bottom),
            (right, bottom - corner, right, bottom),
        ):
            draw.line((x1, y1, x2, y2), fill=(23, 220, 88), width=line_width)
        overlay.save(overlay_path)
        artifacts["overlay"] = str(overlay_path)
    report["visualArtifacts"] = artifacts


def build_markdown(report: dict[str, Any]) -> str:
    metrics = report["metrics"]
    bbox = report["screenRegion"]
    lines = [
        "# 龙珠雷达实拍屏幕 QA",
        "",
        f"- 生成时间: {report['generated']}",
        f"- 状态: `{report['status']}`",
        f"- 来源图片: `{report['sourceImage']}`",
        f"- 图片尺寸: `{report['imageSize']['width']}x{report['imageSize']['height']}`",
        f"- 屏幕区域: `x={bbox['left']} y={bbox['top']} w={bbox['width']} h={bbox['height']}`",
        f"- 硬件证明: `false`；照片 QA 不能单独证明 goal 完成。",
        "",
        "## 指标",
        "",
        "| 指标 | 当前值 |",
        "| --- | --- |",
        f"| greenRatio | `{metrics['greenRatio']:.4f}` |",
        f"| orangePixels | `{metrics['orangePixels']}` |",
        f"| bandingScore | `{metrics['bandingScore']:.4f}` |",
        f"| verticalDominance | `{metrics['verticalDominance']:.4f}` |",
        f"| columnGreenVariation | `{metrics['columnGreenVariation']:.4f}` |",
        f"| rowGreenVariation | `{metrics['rowGreenVariation']:.4f}` |",
        "",
        "## 检查",
        "",
        "| 检查 | 状态 | 说明 |",
        "| --- | --- | --- |",
    ]
    for check in report["checks"]:
        lines.append(f"| {check['name']} | `{check['status']}` | {check['summary']} |")
    artifacts = report.get("visualArtifacts") or {}
    if artifacts:
        lines.extend(["", "## 可视化产物", ""])
        if artifacts.get("crop"):
            lines.append(f"- 屏幕裁切: `{artifacts['crop']}`")
        if artifacts.get("overlay"):
            lines.append(f"- 区域标注: `{artifacts['overlay']}`")
    lines.extend(["", "## 建议动作", ""])
    lines.extend(f"{idx}. {item}" for idx, item in enumerate(report["recommendations"], start=1))
    lines.extend(
        [
            "",
            "## 边界",
            "",
            "- 这份报告用于判断实拍屏幕是否有矩形网格、橙色目标点和条纹风险。",
            "- 它不是完整硬件验收；goal 结束仍需要真板 bring-up、7 个实体信标、干净 UI 实战收集和召唤证明。",
        ]
    )
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    report = build_report(args)
    save_visual_artifacts(args, report)
    json_path = normalize(args.json_output)
    md_path = normalize(args.md_output)
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.write_text(build_markdown(report), encoding="utf-8")
    if args.print_json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"STATUS {report['status']}")
        print(f"JSON {json_path}")
        print(f"MARKDOWN {md_path}")
    return 1 if report["status"] == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main())
