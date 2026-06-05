#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import statistics
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DIFFICULTY_OFFSETS = {
    "easy": -4,
    "normal": 0,
    "strict": 4,
}
AUTO_REPORTS = (
    "output/bringup-diag-report.json",
    "output/beacon-set-verify-report.json",
    "output/field-hunt-report.json",
    "output/bench-sim-report.json",
    "output/preboard-acceptance-current/release-selftest/board-sim-mock/bench-sim-report.json",
    "output/release-selftest-current/board-sim-mock/bench-sim-report.json",
    "evidence/bringup-diag-report.json",
    "evidence/beacon-set-verify-report.json",
    "evidence/field-hunt-report.json",
    "evidence/bench-sim-report.json",
    "evidence/preboard-acceptance/release-selftest/board-sim-mock/bench-sim-report.json",
    "evidence/release-selftest/board-sim-mock/bench-sim-report.json",
)


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if value in (None, ""):
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise SystemExit(f"{name} must be an integer, got: {value}") from exc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Recommend Dragon Radar field build flags from a DIAG JSON report."
    )
    parser.add_argument(
        "report",
        nargs="?",
        default=os.environ.get("TUNING_REPORT_JSON", "auto"),
        help="DIAG JSON report path. Default: auto-pick hardware reports first, then mock pre-board evidence.",
    )
    parser.add_argument(
        "--output-md",
        default=os.environ.get("TUNING_REPORT_MD", "output/field-tuning-report.md"),
        help="Markdown recommendation output path.",
    )
    parser.add_argument(
        "--difficulty",
        default=os.environ.get("TUNING_DIFFICULTY", "normal"),
        choices=sorted(DIFFICULTY_OFFSETS),
        help="easy collects a little earlier, strict requires a stronger signal.",
    )
    parser.add_argument(
        "--hold-ms",
        type=int,
        default=env_int("TUNING_HOLD_MS", 1200),
        help="Recommended close-hold time in milliseconds.",
    )
    parser.add_argument(
        "--mode",
        default=os.environ.get("TUNING_BUILD_MODE", "field"),
        choices=["field", "near"],
        help="Radar build mode to show in generated commands.",
    )
    parser.add_argument(
        "--min-samples",
        type=int,
        default=env_int("TUNING_MIN_SAMPLES", 3),
        help="Ignore beacons with fewer samples than this.",
    )
    return parser.parse_args()


def norm(path: str | Path) -> Path:
    item = Path(path)
    return item if item.is_absolute() else ROOT / item


def resolve_report(path: str) -> Path:
    if path != "auto":
        return norm(path)
    for candidate in AUTO_REPORTS:
        item = norm(candidate)
        if item.exists():
            return item
    raise SystemExit(
        "no usable DIAG report found; run tools/run_preboard_acceptance.py for a "
        "mock starting point, or run hardware bring-up/beacon verification for real tuning"
    )


def load_report(path: Path) -> dict[str, Any]:
    report_path = path
    if not report_path.exists():
        raise SystemExit(f"report not found: {report_path}")
    data = json.loads(report_path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise SystemExit("report JSON must be an object")
    return data


def clamp_rssi(value: int) -> int:
    return max(-85, min(-35, value))


def beacon_candidates(report: dict[str, Any], min_samples: int) -> list[dict[str, Any]]:
    beacons = report.get("beacons", {})
    if not isinstance(beacons, dict):
        raise SystemExit("report is missing a beacons object")

    candidates: list[dict[str, Any]] = []
    for key in sorted(beacons, key=lambda item: int(item) if item.isdigit() else item):
        beacon = beacons[key]
        if not isinstance(beacon, dict) or not beacon.get("seen"):
            continue
        samples = int(beacon.get("samples", 0) or 0)
        candidate = beacon.get("candidateCollect")
        if samples < min_samples or candidate is None:
            continue
        candidates.append({
            "index": int(key),
            "samples": samples,
            "candidate": int(candidate),
            "filteredMin": beacon.get("filteredMin", "-"),
            "filteredMax": beacon.get("filteredMax", "-"),
            "filteredAvg": beacon.get("filteredAvg", "-"),
            "closeHits": int(beacon.get("closeHits", 0) or 0),
            "topBearingBin": beacon.get("topBearingBin", "-"),
        })
    return candidates


def source_metadata(path: Path, report: dict[str, Any]) -> dict[str, Any]:
    rel_path = path.as_posix()
    mock_source = any(marker in rel_path for marker in ("/board-sim-mock/", "preboard-acceptance", "release-acceptance-mock"))
    hardware_proof = report.get("hardwareProof")
    if mock_source or hardware_proof is False:
        return {
            "sourceKind": "mock-preboard",
            "hardwareProof": False,
            "boundary": "这只是无硬件开局建议，不能当作真板校准或验收证明。",
        }
    if hardware_proof is True:
        return {
            "sourceKind": "hardware-proven",
            "hardwareProof": True,
            "boundary": "该报告声明 hardwareProof=true，仍建议结合实体信标实测复核。",
        }
    return {
        "sourceKind": "hardware-report",
        "hardwareProof": None,
        "boundary": "该报告来自硬件/现场路径，但没有显式 hardwareProof 字段；请结合验收报告判断。",
    }


def recommend_rssi(candidates: list[dict[str, Any]], difficulty: str) -> int:
    base = int(round(statistics.median(item["candidate"] for item in candidates)))
    return clamp_rssi(base + DIFFICULTY_OFFSETS[difficulty])


def render_markdown(
    report_path: Path,
    report: dict[str, Any],
    candidates: list[dict[str, Any]],
    rssi: int,
    args: argparse.Namespace,
) -> str:
    source = source_metadata(report_path, report)
    command = f"COLLECT_RSSI={rssi} COLLECT_HOLD_MS={args.hold_ms} tools/build_radar.sh {args.mode}"
    upload_command = f"COLLECT_RSSI={rssi} COLLECT_HOLD_MS={args.hold_ms} tools/build_radar.sh {args.mode} upload"
    status = str(report.get("status", "unknown")).upper()
    hardware = report.get("hardware", {})
    online = ", ".join(
        f"{name}={state}" for name, state in sorted(hardware.items())
    ) if isinstance(hardware, dict) and hardware else "unknown"
    beacons_used = ", ".join(f"DBALL-{item['index']}" for item in candidates)

    lines = [
        "# Dragon Radar Field Tuning",
        "",
        f"- Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- Source report: `{report_path}`",
        f"- Source kind: `{source['sourceKind']}`",
        f"- Hardware proof: `{str(source['hardwareProof']).lower() if source['hardwareProof'] is not None else 'unverified'}`",
        f"- Report status: {status}",
        f"- Hardware: {online}",
        f"- Difficulty: {args.difficulty}",
        f"- Beacons used: {beacons_used}",
        f"- Recommended `COLLECT_RSSI`: `{rssi}`",
        f"- Recommended `COLLECT_HOLD_MS`: `{args.hold_ms}`",
        "",
        f"{source['boundary']}",
        "",
        "## Build Commands",
        "",
        "```sh",
        command,
        upload_command,
        "```",
        "",
        "Less negative RSSI values require the radar to get closer before a ball is collected.",
        "If friends collect too easily, raise `COLLECT_RSSI` by 2-4 dB. If they must touch the",
        "beacon enclosure to collect, lower it by 2-4 dB.",
        "",
        "## Beacon Samples",
        "",
        "| Ball | Samples | Candidate | Filtered | Avg | Close Hits | Top Bearing Bin |",
        "| --- | ---: | ---: | --- | ---: | ---: | --- |",
    ]
    for item in candidates:
        lines.append(
            f"| DBALL-{item['index']} | {item['samples']} | {item['candidate']} | "
            f"{item['filteredMin']}..{item['filteredMax']} | {item['filteredAvg']} | "
            f"{item['closeHits']} | {item['topBearingBin']} |"
        )
    lines.extend([
        "",
        "Use this after a slow sweep from far range into your intended collection distance.",
        "The recommendation is for GPS-free play: BLE RSSI estimates distance while IMU",
        "heading bins make the blip settle toward the strongest direction during a turn.",
        "",
    ])
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    if args.hold_ms < 300 or args.hold_ms > 5000:
        raise SystemExit("--hold-ms must be in 300..5000")
    if args.min_samples < 1:
        raise SystemExit("--min-samples must be >= 1")

    report_path = resolve_report(args.report)
    report = load_report(report_path)
    candidates = beacon_candidates(report, args.min_samples)
    if not candidates:
        raise SystemExit(
            f"no usable beacon calibration samples in {args.report}; "
            "rerun DIAG_CALIBRATE=1 with more movement near the desired collection distance"
        )

    rssi = recommend_rssi(candidates, args.difficulty)
    markdown = render_markdown(report_path, report, candidates, rssi, args)
    output = norm(args.output_md)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(markdown, encoding="utf-8")
    print(output)
    print(f"COLLECT_RSSI={rssi} COLLECT_HOLD_MS={args.hold_ms} tools/build_radar.sh {args.mode} upload")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
