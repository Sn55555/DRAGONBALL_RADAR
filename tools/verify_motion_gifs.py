#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path
from typing import Any, Callable

from PIL import Image, ImageSequence


EXPECTED = {
    "boot-motion.gif": {
        "frames": 4,
        "durations": [360, 440, 520, 420],
    },
    "radar-motion.gif": {
        "frames": 7,
        "durations": [360, 420, 360, 360, 420, 360, 420],
    },
    "summon-motion.gif": {
        "frames": 4,
        "durations": [520, 760, 420, 760],
    },
}

PixelTest = Callable[[int, int, int], bool]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify Dragon Radar motion GIFs preserve the intended UI animation sequence."
    )
    parser.add_argument("out_dir", nargs="?", default="output/playwright", help="Directory containing motion GIFs.")
    parser.add_argument("--json", dest="json_path", help="Optional machine-readable audit JSON path.")
    parser.add_argument("--md", dest="md_path", help="Optional human-readable audit Markdown path.")
    return parser.parse_args()


def is_green(r: int, g: int, b: int) -> bool:
    return g > 90 and g > r * 1.35 and g > b * 1.2


def is_orange(r: int, g: int, b: int) -> bool:
    return r > 150 and 50 < g < 210 and b < 80 and r > g * 1.2


def is_blue(r: int, g: int, b: int) -> bool:
    return b > 120 and b > r * 1.25 and b > g * 1.05


def is_white(r: int, g: int, b: int) -> bool:
    return r > 215 and g > 215 and b > 215


def iter_region(image: Image.Image, region: str):
    w, h = image.size
    if region == "screen":
        cx = w / 2
        cy = h / 2
        radius = min(w, h) * 0.47
        radius2 = radius * radius
        for y in range(h):
            for x in range(w):
                dx = x + 0.5 - cx
                dy = y + 0.5 - cy
                if dx * dx + dy * dy <= radius2:
                    yield image.getpixel((x, y))
    elif region == "logo":
        for y in range(int(h * 0.35), int(h * 0.61)):
            for x in range(int(w * 0.26), int(w * 0.74)):
                yield image.getpixel((x, y))
    elif region == "center":
        for y in range(int(h * 0.36), int(h * 0.64)):
            for x in range(int(w * 0.36), int(w * 0.64)):
                yield image.getpixel((x, y))
    else:
        raise ValueError(f"unknown region: {region}")


def count(pixels, test: PixelTest) -> int:
    return sum(1 for r, g, b in pixels if test(r, g, b))


def counts(image: Image.Image, region: str) -> dict[str, int]:
    pixels = list(iter_region(image, region))
    return {
        "green": count(pixels, is_green),
        "orange": count(pixels, is_orange),
        "blue": count(pixels, is_blue),
        "white": count(pixels, is_white),
    }


def load_gif(path: Path) -> tuple[list[Image.Image], list[int]]:
    with Image.open(path) as image:
        frames = [frame.copy().convert("RGB") for frame in ImageSequence.Iterator(image)]
        durations = [int(frame.info.get("duration", 0)) for frame in ImageSequence.Iterator(image)]
    return frames, durations


def compare(actual: int | float, op: str, expected: int | float) -> bool:
    return {
        ">": actual > expected,
        ">=": actual >= expected,
        "<": actual < expected,
        "<=": actual <= expected,
        "==": actual == expected,
    }[op]


def add_check(
    audit: dict[str, Any],
    label: str,
    actual: int | float | str,
    op: str,
    expected: int | float | str,
) -> None:
    passed = actual == expected if op == "==" else compare(float(actual), op, float(expected))
    record = {
        "label": label,
        "actual": actual,
        "op": op,
        "expected": expected,
        "status": "passed" if passed else "failed",
    }
    audit["checks"].append(record)
    if not passed:
        audit["failures"].append(f"{label}: expected {op} {expected}, got {actual}")


def add_frame_checks(audit: dict[str, Any], name: str, path: Path, frames: list[Image.Image], durations: list[int]) -> None:
    expected = EXPECTED[name]
    add_check(audit, f"{name} frame count", len(frames), "==", expected["frames"])
    add_check(audit, f"{name} duration sequence", ",".join(str(item) for item in durations), "==", ",".join(str(item) for item in expected["durations"]))
    add_check(audit, f"{name} file size", path.stat().st_size, ">", 10_000)
    if frames:
        width, height = frames[0].size
        add_check(audit, f"{name} width", width, ">=", 400)
        add_check(audit, f"{name} height", height, ">=", 400)


def add_boot_sequence_checks(audit: dict[str, Any]) -> None:
    metrics = audit["metrics"]["boot-motion.gif"]["frames"]
    add_check(audit, "boot stage 0 grid wake has no blue logo", metrics[0]["logo"]["blue"], "<=", 100)
    add_check(audit, "boot stage 1 logo scan blue appears", metrics[1]["logo"]["blue"], ">", 4000)
    add_check(audit, "boot stage 1 logo scan white body appears", metrics[1]["logo"]["white"], ">", 3000)
    add_check(audit, "boot stage 2 ready logo blue grows", metrics[2]["logo"]["blue"], ">", 7500)
    add_check(audit, "boot stage 2 ready logo remains white", metrics[2]["logo"]["white"], ">", 1500)
    add_check(audit, "boot stage 3 handoff keeps radar green", metrics[3]["screen"]["green"], ">", 3000)
    add_check(audit, "boot stage 3 handoff keeps logo blue", metrics[3]["screen"]["blue"], ">", 7500)
    add_check(audit, "boot logo blue increases after wake", metrics[1]["logo"]["blue"] - metrics[0]["logo"]["blue"], ">", 3500)
    add_check(audit, "boot ready blue exceeds scan blue", metrics[2]["logo"]["blue"] - metrics[1]["logo"]["blue"], ">", 2000)


def add_radar_sequence_checks(audit: dict[str, Any]) -> None:
    metrics = audit["metrics"]["radar-motion.gif"]["frames"]
    add_check(audit, "radar stage 0 acquire is target-free", metrics[0]["screen"]["orange"], "<=", 50)
    add_check(audit, "radar stage 1 idle search is target-free", metrics[1]["screen"]["orange"], "<=", 50)
    add_check(audit, "radar stage 2 acquisition shows target", metrics[2]["screen"]["orange"], ">", 300)
    add_check(audit, "radar stage 3 trail keeps target", metrics[3]["screen"]["orange"], ">", 120)
    add_check(audit, "radar stage 4 proximity keeps target", metrics[4]["screen"]["orange"], ">", 200)
    add_check(audit, "radar stage 5 capture clears target", metrics[5]["screen"]["orange"], "<=", 50)
    add_check(audit, "radar stage 6 control overlay is dense green", metrics[6]["screen"]["green"], ">", 6000)
    for index, frame in enumerate(metrics):
        add_check(audit, f"radar stage {index} has no boot blue", frame["screen"]["blue"], "<=", 50)


def add_summon_sequence_checks(audit: dict[str, Any]) -> None:
    metrics = audit["metrics"]["summon-motion.gif"]["frames"]
    for index in (0, 2):
        add_check(audit, f"summon gather stage {index} has path green", metrics[index]["screen"]["green"], ">", 10_000)
        add_check(audit, f"summon gather stage {index} has moving balls", metrics[index]["screen"]["orange"], ">", 250)
    for index in (1, 3):
        add_check(audit, f"summon orbit stage {index} has center balls", metrics[index]["center"]["orange"], ">", 300)
        add_check(audit, f"summon orbit stage {index} has orbit balls", metrics[index]["screen"]["orange"], ">", 350)
    add_check(audit, "summon orbit center orange exceeds gather", metrics[1]["center"]["orange"] - metrics[0]["center"]["orange"], ">", 150)
    for index, frame in enumerate(metrics):
        add_check(audit, f"summon stage {index} has no boot blue", frame["screen"]["blue"], "<=", 50)


def build_audit(out_dir: Path) -> dict[str, Any]:
    audit: dict[str, Any] = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "gifDir": str(out_dir),
        "status": "passed",
        "requiredGifs": list(EXPECTED),
        "metrics": {},
        "checks": [],
        "failures": [],
    }

    loaded: dict[str, list[Image.Image]] = {}
    for name in EXPECTED:
        path = out_dir / name
        if not path.exists():
            audit["failures"].append(f"missing {path}")
            continue
        frames, durations = load_gif(path)
        loaded[name] = frames
        audit["metrics"][name] = {
            "size": path.stat().st_size,
            "durations": durations,
            "frames": [
                {
                    "screen": counts(frame, "screen"),
                    "logo": counts(frame, "logo"),
                    "center": counts(frame, "center"),
                }
                for frame in frames
            ],
        }
        add_frame_checks(audit, name, path, frames, durations)

    if all(name in loaded and len(loaded[name]) == EXPECTED[name]["frames"] for name in EXPECTED):
        add_boot_sequence_checks(audit)
        add_radar_sequence_checks(audit)
        add_summon_sequence_checks(audit)

    if audit["failures"]:
        audit["status"] = "failed"
    return audit


def write_json(path: Path, audit: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(audit, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"motion-gif-audit {path}")


def write_markdown(path: Path, audit: dict[str, Any]) -> None:
    checks = audit.get("checks", [])
    failures = audit.get("failures", [])
    lines = [
        "# Dragon Radar Motion GIF Audit",
        "",
        f"- Generated: {audit.get('generated', '-')}",
        f"- Status: {str(audit.get('status', 'unknown')).upper()}",
        f"- Required GIFs: {len(audit.get('requiredGifs', []))}",
        f"- Checks: {len(checks)}",
        f"- Failures: {len(failures)}",
        "",
        "## Motion Summary",
        "",
        "| GIF | Frames | Durations | Size |",
        "| --- | --- | --- | --- |",
    ]
    for name in audit.get("requiredGifs", []):
        metric = audit.get("metrics", {}).get(name, {})
        lines.append(
            f"| {name} | {len(metric.get('frames', []))} | {metric.get('durations', '-')} | {metric.get('size', '-')} |"
        )
    lines.extend([
        "",
        "## Checks",
        "",
        "| Status | Check | Actual | Expectation |",
        "| --- | --- | --- | --- |",
    ])
    for check in checks:
        lines.append(
            f"| {str(check.get('status', 'unknown')).upper()} | {check.get('label', '-')} | "
            f"{check.get('actual', '-')} | {check.get('op', '')} {check.get('expected', '')} |"
        )
    if failures:
        lines.extend(["", "## Failures", ""])
        lines.extend(f"- {failure}" for failure in failures)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"motion-gif-audit-md {path}")


def main() -> int:
    args = parse_args()
    audit = build_audit(Path(args.out_dir))
    if args.json_path:
        write_json(Path(args.json_path), audit)
    if args.md_path:
        write_markdown(Path(args.md_path), audit)
    if audit["status"] != "passed":
        for failure in audit["failures"]:
            print(f"motion-gifs-failed: {failure}")
        return 1
    print("motion-gifs-ok")
    for name in EXPECTED:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
