#!/usr/bin/env python3
from __future__ import annotations

import argparse
import math
import random
import sys
import time


COMPONENT_FLAGS = {
    "touch": "T",
    "imu": "I",
    "ble": "B",
    "audio": "A",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate deterministic Dragon Radar DIAG serial lines for monitor/calibration tests."
    )
    parser.add_argument("--beacons", type=int, default=2, help="Number of simulated DBALL beacons, 1..7.")
    parser.add_argument("--samples", type=int, default=32, help="Number of DIAG sample ticks to emit.")
    parser.add_argument("--seed", type=int, default=7, help="Deterministic jitter seed.")
    parser.add_argument("--sleep", type=float, default=0.0, help="Delay between sample ticks, in seconds.")
    parser.add_argument("--collect-rssi", type=int, default=-50, help="RSSI threshold used to mark close=yes.")
    parser.add_argument("--simulated-ble", action="store_true", help="Emit the simulated BLE firmware marker.")
    parser.add_argument("--hunt-session", type=int, default=0, help="Emit a DIAG hunt start event for this session id.")
    parser.add_argument("--collect-all", action="store_true", help="Emit one DIAG collect event for every simulated beacon.")
    parser.add_argument("--summon", action="store_true", help="Emit a final tick with summon=yes.")
    parser.add_argument(
        "--final-collected",
        type=int,
        default=None,
        help="Final collected count for the closing tick. Defaults to the beacon count when --collect-all is used.",
    )
    parser.add_argument(
        "--offline",
        default="",
        help="Comma-separated components to mark offline, e.g. touch,audio.",
    )
    parser.add_argument("--touch-events", action="store_true", help="Emit occasional simulated touch lines.")
    return parser.parse_args()


def validate_args(args: argparse.Namespace) -> set[str]:
    if args.beacons < 1 or args.beacons > 7:
        raise SystemExit("--beacons must be in 1..7")
    if args.samples < 1:
        raise SystemExit("--samples must be >= 1")
    if args.sleep < 0:
        raise SystemExit("--sleep must be >= 0")
    if args.hunt_session < 0:
        raise SystemExit("--hunt-session must be >= 0")
    if args.final_collected is not None and not 0 <= args.final_collected <= 7:
        raise SystemExit("--final-collected must be in 0..7")

    offline = {part.strip().lower() for part in args.offline.split(",") if part.strip()}
    unknown = offline - set(COMPONENT_FLAGS)
    if unknown:
        raise SystemExit(f"unknown --offline component(s): {', '.join(sorted(unknown))}")
    return offline


def emit(line: str) -> None:
    print(line, flush=True)


def bearing_bin(degrees: float) -> int:
    return int(((degrees % 360.0) + 11.25) // 22.5) % 16


def bin_center(bin_index: int) -> float:
    return (bin_index % 16) * 22.5


def angular_delta(a: float, b: float) -> float:
    return abs(((a - b + 180.0) % 360.0) - 180.0)


def rssi_to_range(filtered: int) -> float:
    return max(0.05, min(1.0, (-38 - filtered) / 46.0))


def online_code(offline: set[str]) -> str:
    return "".join(flag if name not in offline else "-" for name, flag in COMPONENT_FLAGS.items())


def component_state(name: str, offline: set[str]) -> str:
    return "offline" if name in offline else "online"


def simulate(args: argparse.Namespace) -> int:
    offline = validate_args(args)
    rng = random.Random(args.seed)
    filtered_by_beacon = {index: -76.0 - index for index in range(1, args.beacons + 1)}
    beacon_bearings = {
        index: (index - 1) * (360.0 / args.beacons) + 18.0
        for index in range(1, args.beacons + 1)
    }

    emit("DIAG enabled")
    emit(
        "DIAG "
        f"touch={component_state('touch', offline)} "
        f"imu={component_state('imu', offline)} "
        f"ble={component_state('ble', offline)} "
        f"audio={component_state('audio', offline)}"
    )
    emit("DIAG display=466x466 brightness=184")
    emit("DIAG heap=192000 psram=8200000")
    if args.simulated_ble:
        emit("DIAG simulatedBle=enabled")
    if args.hunt_session:
        emit(f"DIAG hunt session={args.hunt_session} event=start ms=100")

    for sample in range(args.samples):
        ms = (sample + 1) * 1000
        heading = (sample * 360.0 / max(1, args.samples)) % 360.0
        tilt = math.sin(sample / 5.0) * 0.04
        readings: list[tuple[int, int, int, float, int, float, bool]] = []

        for index in range(1, args.beacons + 1):
            target_bearing = beacon_bearings[index]
            sweep_gain = max(0.0, 1.0 - angular_delta(heading, target_bearing) / 105.0) * 22.0
            distance_wave = 9.0 * math.sin((sample + index * 2.2) / 4.0)
            raw = int(round(-72 + sweep_gain + distance_wave + rng.uniform(-2.5, 2.5)))
            filtered = int(round(filtered_by_beacon[index] * 0.58 + raw * 0.42))
            filtered_by_beacon[index] = filtered
            bin_index = bearing_bin(target_bearing)
            close = filtered >= args.collect_rssi
            readings.append((index, raw, filtered, rssi_to_range(filtered), bin_index, bin_center(bin_index), close))

        strongest = max(readings, key=lambda item: item[2])
        active = 0 if "ble" in offline else args.beacons
        emit(
            f"DIAG tick ms={ms} active={active} collected=0 zoom=0 brightPreset=2 audioPreset=2 "
            f"frameMs=25 drawMs=18 drawAvgMs=18 drawMaxMs=20 overBudget=0 frames=40 "
            f"heading={heading:.1f} tilt={tilt:.2f} strongest=DBALL-{strongest[0]} online={online_code(offline)}"
        )

        if "ble" not in offline:
            for index, raw, filtered, range_norm, bin_index, bearing, close in readings:
                emit(
                    f"DIAG BLE DBALL-{index} raw={raw} filtered={filtered} "
                    f"range={range_norm:.2f} bearingBin={bin_index} "
                    f"bearing={bearing:.1f} close={'yes' if close else 'no'}"
                )

        if args.touch_events and "touch" not in offline and sample % 9 == 4:
            x = 80 + (sample * 37) % 300
            y = 80 + (sample * 53) % 300
            emit(f"DIAG touch x={x} y={y} action=scale")

        if args.sleep:
            time.sleep(args.sleep)

    if args.collect_all:
        for index in range(1, args.beacons + 1):
            ms = (args.samples + 1) * 1000 + index * 120
            target_bearing = beacon_bearings[index]
            bin_index = bearing_bin(target_bearing)
            bearing = bin_center(bin_index)
            filtered = max(args.collect_rssi + 5, -48)
            raw = filtered + 2
            session = f" session={args.hunt_session}" if args.hunt_session else ""
            emit(
                f"DIAG collect DBALL-{index}{session} ms={ms} raw={raw} filtered={filtered} "
                f"range=0.12 bearingBin={bin_index} bearing={bearing:.1f}"
            )

    if args.summon or args.final_collected is not None:
        final_collected = args.final_collected
        if final_collected is None:
            final_collected = args.beacons if args.collect_all else 0
        final_ms = (args.samples + 3) * 1000
        active = 0 if final_collected >= args.beacons else args.beacons
        summon = "yes" if args.summon else "no"
        emit(
            f"DIAG tick ms={final_ms} active={active} collected={final_collected} "
            "zoom=0 brightPreset=2 audioPreset=2 frameMs=25 drawMs=18 drawAvgMs=18 drawMaxMs=20 overBudget=0 frames=40 heading=0.0 tilt=0.00 "
            f"strongest=none online={online_code(offline)} summon={summon}"
        )

    return 0


def main() -> int:
    try:
        args = parse_args()
        return simulate(args)
    except BrokenPipeError:
        sys.stderr.close()
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
