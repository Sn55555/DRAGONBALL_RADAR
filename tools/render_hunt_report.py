#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


BALL_SET = set(range(1, 8))
COMPONENTS = ("touch", "imu", "ble", "audio")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render a friend-facing Dragon Radar hunt report.")
    parser.add_argument("report_json", help="Input report JSON from tools/monitor_diag.py --report-json.")
    parser.add_argument("report_md", nargs="?", help="Output Markdown path. Omit to print to stdout.")
    parser.add_argument("--title", default="Dragon Radar Hunt Report", help="Markdown report title.")
    return parser.parse_args()


def yes_no(value: Any) -> str:
    return "yes" if bool(value) else "no"


def elapsed_label(ms: int | None) -> str:
    if ms is None:
        return "-"
    if ms < 0:
        return f"{ms} ms"
    total_seconds = ms / 1000.0
    minutes = int(total_seconds // 60)
    seconds = total_seconds - minutes * 60
    if minutes:
        return f"{minutes}m {seconds:04.1f}s"
    return f"{seconds:.1f}s"


def current_session_start(report: dict[str, Any]) -> int | None:
    session = report.get("huntSession", 0)
    events = report.get("huntEvents", [])
    starts = [
        int(event.get("ms", 0))
        for event in events
        if event.get("session") == session and event.get("event") in {"start", "reset"}
    ]
    if starts:
        return starts[-1]
    collections = report.get("collections", [])
    if collections:
        return int(collections[0].get("ms", 0))
    return None


def collection_indexes(report: dict[str, Any]) -> list[int]:
    indexes: list[int] = []
    for event in report.get("collections", []):
        try:
            indexes.append(int(event.get("index")))
        except (TypeError, ValueError):
            continue
    return indexes


def hunt_result(report: dict[str, Any]) -> str:
    seen = set(collection_indexes(report))
    complete = seen == BALL_SET
    if complete and report.get("summon"):
        return "Complete: all seven balls collected and summon mode reported."
    if complete:
        return "Collected all seven balls; summon mode was not reported before monitoring ended."
    missing = sorted(BALL_SET - seen)
    if seen:
        return "In progress: missing " + ", ".join(f"DBALL-{index}" for index in missing) + "."
    return "No collection events recorded in the current hunt session."


def render_overview(report: dict[str, Any]) -> list[str]:
    hardware = report.get("hardware", {})
    hardware_text = ", ".join(
        f"{name}={hardware.get(name, 'unknown')}" for name in COMPONENTS
    )
    indexes = collection_indexes(report)
    unique = sorted(set(indexes))
    duplicates = [index for index in unique if indexes.count(index) > 1]
    duplicate_text = ", ".join(f"DBALL-{index}" for index in duplicates) or "none"
    return [
        f"- Result: {hunt_result(report)}",
        f"- Parser status: {str(report.get('status', 'unknown')).upper()}",
        f"- Hunt session: {report.get('huntSession', 0)}",
        f"- Collected count: {report.get('collected', 0)}",
        f"- Collection events: {report.get('collectionCount', 0)}",
        f"- Unique balls: {len(unique)}/7",
        f"- Duplicate collection events: {duplicate_text}",
        f"- Summon: {yes_no(report.get('summon'))}",
        f"- Hardware: {hardware_text}",
        f"- Raw log: {report.get('logFile') or 'not captured'}",
    ]


def render_timeline(report: dict[str, Any]) -> list[str]:
    start_ms = current_session_start(report)
    collections = report.get("collections", [])
    lines = [
        "| Order | Time | Ball | RSSI | Range | Bearing |",
        "| ---: | --- | --- | ---: | ---: | ---: |",
    ]
    if not collections:
        lines.append("| 0 | - | none | - | - | - |")
        return lines
    for order, event in enumerate(collections, start=1):
        ms = int(event.get("ms", 0))
        elapsed = elapsed_label(ms - start_ms) if start_ms is not None else elapsed_label(None)
        lines.append(
            f"| {order} | {elapsed} | DBALL-{event.get('index', '-')} | "
            f"{event.get('filtered', '-')} | {event.get('range', '-')} | "
            f"{event.get('bearing', '-')} deg |"
        )
    return lines


def render_missing(report: dict[str, Any]) -> list[str]:
    seen = set(collection_indexes(report))
    missing = sorted(BALL_SET - seen)
    if not missing:
        return ["- None. All seven collection events are present."]
    return [f"- DBALL-{index}" for index in missing]


def render_hunt_events(report: dict[str, Any]) -> list[str]:
    events = report.get("huntEvents", [])
    lines = ["| Session | Event | Time |", "| ---: | --- | ---: |"]
    if not events:
        lines.append("| - | none | - |")
        return lines
    for event in events:
        lines.append(f"| {event.get('session', '-')} | {event.get('event', '-')} | {elapsed_label(int(event.get('ms', 0)))} |")
    return lines


def render(report: dict[str, Any], title: str) -> str:
    lines: list[str] = [
        f"# {title}",
        "",
        "## Overview",
        "",
    ]
    lines.extend(render_overview(report))
    lines.extend(["", "## Collection Timeline", ""])
    lines.extend(render_timeline(report))
    lines.extend(["", "## Missing Balls", ""])
    lines.extend(render_missing(report))
    lines.extend(["", "## Hunt Events", ""])
    lines.extend(render_hunt_events(report))
    if report.get("failures"):
        lines.extend(["", "## Failed Checks", ""])
        for failure in report["failures"]:
            lines.append(f"- {failure}")
    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    report = json.loads(Path(args.report_json).read_text(encoding="utf-8"))
    markdown = render(report, args.title)
    if args.report_md:
        output = Path(args.report_md)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(markdown, encoding="utf-8")
        print(output)
    else:
        print(markdown, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
