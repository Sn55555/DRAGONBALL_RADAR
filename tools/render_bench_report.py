#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


COMPONENTS = ("touch", "imu", "ble", "audio")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Render a Dragon Radar bench JSON report as Markdown.")
    parser.add_argument("report_json", help="Input report JSON from tools/monitor_diag.py --report-json.")
    parser.add_argument("report_md", nargs="?", help="Output Markdown path. Omit to print to stdout.")
    return parser.parse_args()


def yes_no(value: Any) -> str:
    return "yes" if bool(value) else "no"


def status_mark(ok: bool) -> str:
    return "PASS" if ok else "FAIL"


def render_hardware(report: dict[str, Any]) -> list[str]:
    hardware = report.get("hardware", {})
    lines = ["| Component | State |", "| --- | --- |"]
    for component in COMPONENTS:
        state = hardware.get(component, "unknown")
        lines.append(f"| {component} | {state} |")
    return lines


def render_requirements(report: dict[str, Any]) -> list[str]:
    requirements = report.get("requirements", {})
    required_online = ", ".join(requirements.get("requireOnline", [])) or "none"
    lines = ["| Requirement | Value |", "| --- | --- |"]
    lines.append(f"| Required online | {required_online} |")
    lines.append(f"| Minimum beacons | {requirements.get('minBeacons', 0)} |")
    lines.append(f"| Minimum collected | {requirements.get('minCollected', 0)} |")
    lines.append(f"| Minimum collection events | {requirements.get('minCollections', 0)} |")
    lines.append(f"| Require full collection set | {yes_no(requirements.get('requireCollectionSet'))} |")
    lines.append(f"| Require simulated BLE | {yes_no(requirements.get('requireSimulatedBle'))} |")
    lines.append(f"| Require summon | {yes_no(requirements.get('requireSummon'))} |")
    return lines


def render_beacons(report: dict[str, Any]) -> list[str]:
    beacons = report.get("beacons", {})
    lines = [
        "| Ball | Seen | Samples | Filtered | Candidate | Close Hits | Bearing Bin |",
        "| --- | --- | ---: | --- | ---: | ---: | --- |",
    ]
    for index in range(1, 8):
        beacon = beacons.get(str(index), {})
        seen = bool(beacon.get("seen"))
        samples = beacon.get("samples", 0)
        filtered = "-"
        if "filteredMin" in beacon and "filteredMax" in beacon:
            filtered = f"{beacon['filteredMin']}..{beacon['filteredMax']}"
        elif "filtered" in beacon:
            filtered = str(beacon["filtered"])
        candidate = beacon.get("candidateCollect", "-")
        close_hits = beacon.get("closeHits", 0)
        bearing_bin = beacon.get("topBearingBin", beacon.get("bearingBin", "-"))
        lines.append(
            f"| DBALL-{index} | {yes_no(seen)} | {samples} | {filtered} | "
            f"{candidate} | {close_hits} | {bearing_bin} |"
        )
    return lines


def render_collections(report: dict[str, Any]) -> list[str]:
    collections = report.get("collections", [])
    lines = [
        "| Order | Session | Ball | ms | Raw | Filtered | Range | Bearing Bin | Bearing |",
        "| ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    if not collections:
        lines.append("| 0 | - | none | - | - | - | - | - | - |")
        return lines
    for order, event in enumerate(collections, start=1):
        lines.append(
            f"| {order} | {event.get('session', '-')} | DBALL-{event.get('index', '-')} | {event.get('ms', '-')} | "
            f"{event.get('raw', '-')} | {event.get('filtered', '-')} | "
            f"{event.get('range', '-')} | {event.get('bearingBin', '-')} | "
            f"{event.get('bearing', '-')} |"
        )
    return lines


def render_hunt_events(report: dict[str, Any]) -> list[str]:
    events = report.get("huntEvents", [])
    lines = ["| Session | Event | ms |", "| ---: | --- | ---: |"]
    if not events:
        lines.append("| - | none | - |")
        return lines
    for event in events:
        lines.append(f"| {event.get('session', '-')} | {event.get('event', '-')} | {event.get('ms', '-')} |")
    return lines


def render(report: dict[str, Any]) -> str:
    status = str(report.get("status", "unknown")).upper()
    failures = report.get("failures", [])
    frame_ms = int(report.get("frameMs") or 0)
    draw_ms = int(report.get("drawMs") or 0)
    draw_avg_ms = int(report.get("drawAvgMs") or 0)
    draw_max_ms = int(report.get("drawMaxMs") or 0)
    over_budget = int(report.get("overBudgetFrames") or 0)
    frame_samples = int(report.get("frameSamples") or 0)
    if frame_ms and draw_max_ms:
        perf_status = "PASS" if over_budget == 0 and draw_max_ms <= frame_ms else "WARN"
    elif frame_ms and draw_ms:
        perf_status = "PASS" if draw_ms <= frame_ms else "WARN"
    else:
        perf_status = "UNKNOWN"
    lines: list[str] = [
        "# Dragon Radar Bench Report",
        "",
        f"- Status: {status}",
        f"- Generated: {report.get('generatedAt', 'unknown')}",
        f"- Saw DIAG: {yes_no(report.get('sawDiag'))}",
        f"- Online code: {report.get('onlineCode', '----')}",
        f"- Simulated BLE: {yes_no(report.get('simulatedBle'))}",
        f"- Summon: {yes_no(report.get('summon'))}",
        f"- Hunt session: {report.get('huntSession', 0)}",
        f"- Active targets: {report.get('active', 0)}",
        f"- Collected: {report.get('collected', 0)}",
        f"- Frame target: {frame_ms or '-'} ms",
        f"- Last draw cost: {draw_ms or '-'} ms",
        f"- Draw average/max: {draw_avg_ms or '-'}/{draw_max_ms or '-'} ms",
        f"- Over-budget frames: {over_budget}/{frame_samples or '-'}",
        f"- Frame performance: {perf_status}",
        f"- Collection events: {report.get('collectionCount', 0)}",
        f"- Beacons seen: {report.get('beaconCount', 0)}",
        f"- Raw log: {report.get('logFile') or 'not captured'}",
        "",
        "## Checks",
        "",
    ]
    if failures:
        for failure in failures:
            lines.append(f"- {status_mark(False)} {failure}")
    else:
        lines.append("- PASS all requested checks passed")

    lines.extend(["", "## Requirements", ""])
    lines.extend(render_requirements(report))
    lines.extend(["", "## Hardware", ""])
    lines.extend(render_hardware(report))
    lines.extend(["", "## Hunt Events", ""])
    lines.extend(render_hunt_events(report))
    lines.extend(["", "## Beacons", ""])
    lines.extend(render_beacons(report))
    lines.extend(["", "## Collections", ""])
    lines.extend(render_collections(report))

    if report.get("lastTouch"):
        lines.extend(["", f"Last touch: `{report['lastTouch']}`"])
    if report.get("lastCommand"):
        lines.extend(["", f"Last command: `{report['lastCommand']}`"])

    return "\n".join(lines) + "\n"


def main() -> int:
    args = parse_args()
    report = json.loads(Path(args.report_json).read_text(encoding="utf-8"))
    markdown = render(report)
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
