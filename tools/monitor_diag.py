#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import selectors
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, TextIO


HARDWARE_RE = re.compile(
    r"DIAG touch=(?P<touch>\w+) imu=(?P<imu>\w+) ble=(?P<ble>\w+) audio=(?P<audio>\w+)"
)
TICK_RE = re.compile(
    r"DIAG tick ms=(?P<ms>\d+) active=(?P<active>\d+) collected=(?P<collected>\d+) "
    r"zoom=(?P<zoom>\d+) brightPreset=(?P<bright>\d+) audioPreset=(?P<audio>\d+) "
    r"(?:frameMs=(?P<frame_ms>\d+) )?"
    r"(?:drawMs=(?P<draw_ms>\d+) )?"
    r"(?:drawAvgMs=(?P<draw_avg_ms>\d+) )?"
    r"(?:drawMaxMs=(?P<draw_max_ms>\d+) )?"
    r"(?:overBudget=(?P<over_budget>\d+) )?"
    r"(?:frames=(?P<frame_samples>\d+) )?"
    r"heading=(?P<heading>-?\d+(?:\.\d+)?) tilt=(?P<tilt>-?\d+(?:\.\d+)?) "
    r"strongest=(?P<strongest>\S+) online=(?P<online>\S+)(?: summon=(?P<summon>yes|no))?"
)
BEACON_RE = re.compile(
    r"DIAG BLE DBALL-(?P<index>[1-7]) raw=(?P<raw>-?\d+) filtered=(?P<filtered>-?\d+) "
    r"range=(?P<range>-?\d+(?:\.\d+)?) bearingBin=(?P<bin>\d+) "
    r"bearing=(?P<bearing>-?\d+(?:\.\d+)?) close=(?P<close>yes|no)"
)
COLLECT_RE = re.compile(
    r"DIAG collect DBALL-(?P<index>[1-7])(?: session=(?P<session>\d+))? ms=(?P<ms>\d+) raw=(?P<raw>-?\d+) "
    r"filtered=(?P<filtered>-?\d+) range=(?P<range>-?\d+(?:\.\d+)?) "
    r"bearingBin=(?P<bin>\d+) bearing=(?P<bearing>-?\d+(?:\.\d+)?)"
)
HUNT_RE = re.compile(r"DIAG hunt session=(?P<session>\d+) event=(?P<event>\w+) ms=(?P<ms>\d+)")
TOUCH_RE = re.compile(r"DIAG touch x=(?P<x>\d+) y=(?P<y>\d+) action=(?P<action>\w+)")
SIMULATED_BLE_RE = re.compile(r"DIAG simulatedBle=(?P<state>enabled|disabled)")
COMMAND_RE = re.compile(r"DIAG command (?P<command>.) action=(?P<action>\w+)")
COMPONENT_FLAGS = {
    "touch": "T",
    "imu": "I",
    "ble": "B",
    "audio": "A",
}


@dataclass
class BeaconState:
    raw: int = -99
    filtered: int = -99
    range_norm: float = 1.0
    bearing_bin: int = 0
    bearing: float = 0.0
    close: bool = False
    seen_at: float = 0.0


@dataclass
class BeaconStats:
    raw_values: list[int] = field(default_factory=list)
    filtered_values: list[int] = field(default_factory=list)
    close_hits: int = 0
    bearing_bins: dict[int, int] = field(default_factory=dict)

    def record(self, raw: int, filtered: int, bearing_bin: int, close: bool) -> None:
        self.raw_values.append(raw)
        self.filtered_values.append(filtered)
        if close:
            self.close_hits += 1
        self.bearing_bins[bearing_bin] = self.bearing_bins.get(bearing_bin, 0) + 1

    @property
    def samples(self) -> int:
        return len(self.filtered_values)


@dataclass
class CollectionEvent:
    index: int
    ms: int
    raw: int
    filtered: int
    range_norm: float
    bearing_bin: int
    bearing: float
    session: int = 0


@dataclass
class HuntEvent:
    session: int
    event: str
    ms: int


@dataclass
class DiagState:
    hardware: dict[str, str] = field(default_factory=dict)
    online_code: str = "----"
    active: int = 0
    collected: int = 0
    strongest: str = "none"
    heading: float = 0.0
    tilt: float = 0.0
    frame_ms: int = 0
    draw_ms: int = 0
    draw_avg_ms: int = 0
    draw_max_ms: int = 0
    over_budget_frames: int = 0
    frame_samples: int = 0
    beacons: dict[int, BeaconState] = field(default_factory=dict)
    beacon_stats: dict[int, BeaconStats] = field(default_factory=dict)
    collections: list[CollectionEvent] = field(default_factory=list)
    hunt_events: list[HuntEvent] = field(default_factory=list)
    hunt_session: int = 0
    last_touch: str = ""
    last_command: str = ""
    simulated_ble: bool = False
    summon: bool = False
    saw_diag: bool = False
    last_summary_at: float = 0.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Monitor Dragon Radar DIAG serial output and print concise hardware/beacon status."
    )
    parser.add_argument("--stdin", action="store_true", help="Read diagnostic lines from stdin instead of pio monitor.")
    parser.add_argument("--port", help="Serial port passed to PlatformIO monitor, e.g. /dev/cu.usbmodem101.")
    parser.add_argument("--baud", default="115200", help="Serial baud rate, default: 115200.")
    parser.add_argument("--pio-bin", default=None, help="PlatformIO executable, default: pio.")
    parser.add_argument("--use-pio-monitor", action="store_true", help="Use `pio device monitor` instead of direct pyserial.")
    parser.add_argument("--summary-interval", type=float, default=2.0, help="Seconds between tick summaries.")
    parser.add_argument("--timeout", type=float, default=0.0, help="Exit after this many seconds; 0 means run until EOF/Ctrl-C.")
    parser.add_argument(
        "--require-online",
        default="",
        help="Comma-separated components that must be online before exit, e.g. touch,imu,ble,audio.",
    )
    parser.add_argument("--min-beacons", type=int, default=0, help="Minimum distinct DBALL beacons that must be seen.")
    parser.add_argument("--min-collected", type=int, default=0, help="Minimum collected Dragon Balls reported by DIAG tick.")
    parser.add_argument("--min-collections", type=int, default=0, help="Minimum DIAG collect events that must be seen.")
    parser.add_argument("--require-collection-set", action="store_true", help="Require collection events for every DBALL-1..7 index.")
    parser.add_argument("--calibrate", action="store_true", help="Print aggregate RSSI and bearing-bin calibration stats on exit.")
    parser.add_argument("--require-simulated-ble", action="store_true", help="Require the radar to report DIAG simulatedBle=enabled.")
    parser.add_argument("--require-summon", action="store_true", help="Require DIAG tick to report summon=yes.")
    parser.add_argument("--report-json", help="Write a machine-readable final diagnostic report to this path.")
    parser.add_argument("--log-file", help="Write raw DIAG serial lines to this path for later replay/debugging.")
    parser.add_argument("--report-log-file", help="Log path to record in the report without writing raw lines.")
    parser.add_argument("--raw", action="store_true", help="Also echo raw serial lines.")
    return parser.parse_args()


def monitor_command(args: argparse.Namespace) -> list[str]:
    cmd = [args.pio_bin or "pio", "device", "monitor", "-b", str(args.baud)]
    if args.port:
        cmd.extend(["-p", args.port])
    return cmd


def iter_process_lines(args: argparse.Namespace) -> Iterable[str]:
    cmd = monitor_command(args)
    print(f"Starting {' '.join(cmd)}", file=sys.stderr)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    assert proc.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    deadline = time.monotonic() + args.timeout if args.timeout else None
    try:
        while True:
            timeout = None
            if deadline is not None:
                timeout = max(0.0, deadline - time.monotonic())
                if timeout == 0.0:
                    break

            events = selector.select(timeout)
            if not events:
                if deadline is not None:
                    break
                continue

            for key, _ in events:
                line = key.fileobj.readline()
                if not line:
                    return
                yield line
    finally:
        selector.close()
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


def iter_serial_lines(args: argparse.Namespace) -> Iterable[str]:
    if not args.port:
        yield from iter_process_lines(args)
        return
    try:
        import serial
    except ImportError as exc:
        print(f"pyserial unavailable, falling back to PlatformIO monitor: {exc}", file=sys.stderr)
        yield from iter_process_lines(args)
        return

    baud = int(args.baud)
    print(f"Starting direct serial monitor -b {baud} -p {args.port}", file=sys.stderr)
    deadline = time.monotonic() + args.timeout if args.timeout else None
    with serial.Serial(args.port, baudrate=baud, timeout=0.2) as serial_port:
        serial_port.dtr = False
        serial_port.rts = False
        time.sleep(0.05)
        serial_port.reset_input_buffer()
        pending = b""
        while True:
            if deadline is not None and time.monotonic() >= deadline:
                if pending:
                    yield pending.decode("utf-8", errors="replace")
                return
            chunk = serial_port.read(256)
            if not chunk:
                continue
            pending += chunk
            while b"\n" in pending:
                raw_line, pending = pending.split(b"\n", 1)
                yield raw_line.decode("utf-8", errors="replace") + "\n"


def online_label(code: str) -> str:
    labels = [(name, flag in code) for name, flag in COMPONENT_FLAGS.items()]
    return " ".join(f"{name}={'ok' if ok else 'off'}" for name, ok in labels)


def hardware_label(hardware: dict[str, str]) -> str:
    if not hardware:
        return "hardware=pending"
    return " ".join(f"{name}={value}" for name, value in hardware.items())


def print_summary(state: DiagState) -> None:
    beacon_parts = []
    now = time.monotonic()
    for index in sorted(state.beacons):
        beacon = state.beacons[index]
        age = max(0.0, now - beacon.seen_at)
        beacon_parts.append(
            f"{index}:F{beacon.filtered} raw{beacon.raw} bin{beacon.bearing_bin} "
            f"{beacon.bearing:.0f}deg range{beacon.range_norm:.2f} age{age:.1f}s"
            f"{' close' if beacon.close else ''}"
        )
    beacon_text = "; ".join(beacon_parts) if beacon_parts else "no beacons"
    touch_text = f" lastTouch={state.last_touch}" if state.last_touch else ""
    command_text = f" lastCommand={state.last_command}" if state.last_command else ""
    sim_text = " simulatedBle=enabled" if state.simulated_ble else ""
    summon_text = " summon=yes" if state.summon else ""
    collection_text = f" collections={len(state.collections)}" if state.collections else ""
    hunt_text = f" session={state.hunt_session}" if state.hunt_session else ""
    frame_text = f" frameMs={state.frame_ms}" if state.frame_ms else ""
    draw_text = f" drawMs={state.draw_ms}" if state.draw_ms else ""
    perf_text = ""
    if state.frame_samples:
        perf_text = (
            f" avgDrawMs={state.draw_avg_ms} maxDrawMs={state.draw_max_ms}"
            f" overBudget={state.over_budget_frames}/{state.frame_samples}"
        )
    print(
        f"SUMMARY {hardware_label(state.hardware)} online={state.online_code} "
        f"({online_label(state.online_code)}) active={state.active} collected={state.collected} "
        f"strongest={state.strongest} heading={state.heading:.1f} tilt={state.tilt:.2f} "
        f"beacons=[{beacon_text}]{hunt_text}{collection_text}{touch_text}{command_text}{frame_text}{draw_text}{perf_text}{sim_text}{summon_text}",
        flush=True,
    )


def percentile(values: list[int], ratio: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    position = (len(ordered) - 1) * ratio
    lower = int(position)
    upper = min(lower + 1, len(ordered) - 1)
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def average(values: list[int]) -> float:
    return sum(values) / len(values) if values else 0.0


def print_calibration(state: DiagState) -> None:
    if not state.beacon_stats:
        print("CALIBRATION no beacon samples", flush=True)
        return

    print("CALIBRATION RSSI report", flush=True)
    for index in sorted(state.beacon_stats):
        stats = state.beacon_stats[index]
        if not stats.filtered_values:
            continue
        raw_min = min(stats.raw_values)
        raw_max = max(stats.raw_values)
        filtered_min = min(stats.filtered_values)
        filtered_max = max(stats.filtered_values)
        filtered_p75 = percentile(stats.filtered_values, 0.75)
        candidate = int(round(filtered_p75))
        top_bin, top_count = max(stats.bearing_bins.items(), key=lambda item: item[1])
        bins = ",".join(str(bin_index) for bin_index in sorted(stats.bearing_bins))
        print(
            f"CAL DBALL-{index} samples={stats.samples} "
            f"raw={raw_min}..{raw_max} avg={average(stats.raw_values):.1f} "
            f"filtered={filtered_min}..{filtered_max} avg={average(stats.filtered_values):.1f} "
            f"p75={filtered_p75:.1f} candidateCollect={candidate} "
            f"closeHits={stats.close_hits} topBin={top_bin}:{top_count} bins={bins}",
            flush=True,
        )
    print(
        "CALIBRATION hint: use candidateCollect as a starting COLLECT_RSSI after sweeping "
        "from far range into the intended collection distance; raise it for a closer trigger, "
        "lower it for an easier trigger.",
        flush=True,
    )


def beacon_report(index: int, state: DiagState) -> dict[str, object]:
    beacon = state.beacons.get(index)
    stats = state.beacon_stats.get(index)
    report: dict[str, object] = {
        "seen": beacon is not None,
    }
    if beacon:
        report.update({
            "raw": beacon.raw,
            "filtered": beacon.filtered,
            "range": round(beacon.range_norm, 2),
            "bearingBin": beacon.bearing_bin,
            "bearing": round(beacon.bearing, 1),
            "close": beacon.close,
        })
    if stats and stats.filtered_values:
        top_bin, top_count = max(stats.bearing_bins.items(), key=lambda item: item[1])
        filtered_p75 = percentile(stats.filtered_values, 0.75)
        report.update({
            "samples": stats.samples,
            "rawMin": min(stats.raw_values),
            "rawMax": max(stats.raw_values),
            "rawAvg": round(average(stats.raw_values), 1),
            "filteredMin": min(stats.filtered_values),
            "filteredMax": max(stats.filtered_values),
            "filteredAvg": round(average(stats.filtered_values), 1),
            "filteredP75": round(filtered_p75, 1),
            "candidateCollect": int(round(filtered_p75)),
            "closeHits": stats.close_hits,
            "topBearingBin": top_bin,
            "topBearingBinSamples": top_count,
            "bearingBins": sorted(stats.bearing_bins),
        })
    return report


def collection_report(event: CollectionEvent) -> dict[str, object]:
    return {
        "index": event.index,
        "session": event.session,
        "ms": event.ms,
        "raw": event.raw,
        "filtered": event.filtered,
        "range": round(event.range_norm, 2),
        "bearingBin": event.bearing_bin,
        "bearing": round(event.bearing, 1),
    }


def hunt_event_report(event: HuntEvent) -> dict[str, object]:
    return {
        "session": event.session,
        "event": event.event,
        "ms": event.ms,
    }


def build_report(state: DiagState, args: argparse.Namespace, failures: list[str]) -> dict[str, object]:
    return {
        "status": "failed" if failures else "passed",
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "failures": failures,
        "logFile": args.report_log_file or args.log_file or "",
        "requirements": {
            "requireOnline": sorted(parse_required_components(args.require_online)),
            "minBeacons": args.min_beacons,
            "minCollected": args.min_collected,
            "minCollections": args.min_collections,
            "requireCollectionSet": args.require_collection_set,
            "requireSimulatedBle": args.require_simulated_ble,
            "requireSummon": args.require_summon,
        },
        "sawDiag": state.saw_diag,
        "hardware": state.hardware,
        "onlineCode": state.online_code,
        "simulatedBle": state.simulated_ble,
        "summon": state.summon,
        "active": state.active,
        "collected": state.collected,
        "strongest": state.strongest,
        "heading": round(state.heading, 1),
        "tilt": round(state.tilt, 2),
        "frameMs": state.frame_ms,
        "drawMs": state.draw_ms,
        "drawAvgMs": state.draw_avg_ms,
        "drawMaxMs": state.draw_max_ms,
        "overBudgetFrames": state.over_budget_frames,
        "frameSamples": state.frame_samples,
        "lastTouch": state.last_touch,
        "lastCommand": state.last_command,
        "huntSession": state.hunt_session,
        "huntEvents": [hunt_event_report(event) for event in state.hunt_events],
        "beaconCount": len(state.beacons),
        "collectionCount": len(state.collections),
        "collections": [collection_report(event) for event in state.collections],
        "beacons": {str(index): beacon_report(index, state) for index in range(1, 8)},
    }


def write_report(path: str, report: dict[str, object]) -> None:
    report_path = Path(path)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"REPORT {report_path}", flush=True)


def open_log_file(path: str | None) -> TextIO | None:
    if not path:
        return None
    log_path = Path(path)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    return log_path.open("w", encoding="utf-8", buffering=1)


def parse_required_components(value: str) -> set[str]:
    if not value:
        return set()
    components = {part.strip().lower() for part in value.split(",") if part.strip()}
    unknown = components - set(COMPONENT_FLAGS)
    if unknown:
        raise SystemExit(f"unknown --require-online component(s): {', '.join(sorted(unknown))}")
    return components


def component_online(state: DiagState, component: str) -> bool:
    hardware_value = state.hardware.get(component)
    if hardware_value:
        return hardware_value == "online"
    return COMPONENT_FLAGS[component] in state.online_code


def validate_requirements(state: DiagState, args: argparse.Namespace) -> list[str]:
    failures: list[str] = []
    for component in sorted(parse_required_components(args.require_online)):
        if not component_online(state, component):
            failures.append(f"{component} not online")
    if len(state.beacons) < args.min_beacons:
        failures.append(f"only saw {len(state.beacons)} beacon(s), need {args.min_beacons}")
    if state.collected < args.min_collected:
        failures.append(f"only collected {state.collected}, need {args.min_collected}")
    if len(state.collections) < args.min_collections:
        failures.append(f"only saw {len(state.collections)} collection event(s), need {args.min_collections}")
    if args.require_collection_set:
        seen = {event.index for event in state.collections}
        missing = sorted(set(range(1, 8)) - seen)
        extras = sorted(index for index in seen if index < 1 or index > 7)
        if missing:
            failures.append(f"missing collection event(s) for DBALL-{','.join(str(index) for index in missing)}")
        if extras:
            failures.append(f"unexpected collection event index(es): {','.join(str(index) for index in extras)}")
    if args.require_simulated_ble and not state.simulated_ble:
        failures.append("simulated BLE mode not reported")
    if args.require_summon and not state.summon:
        failures.append("summon mode not reported")
    return failures


def handle_line(line: str, state: DiagState, args: argparse.Namespace) -> None:
    line = line.strip()
    if not line:
        return
    if args.raw:
        print(line)

    if line == "DIAG enabled":
        state.saw_diag = True
        print("DIAG stream detected", flush=True)
        return

    match = HARDWARE_RE.search(line)
    if match:
        state.saw_diag = True
        state.hardware = match.groupdict()
        print(f"HARDWARE {hardware_label(state.hardware)}", flush=True)
        return

    match = SIMULATED_BLE_RE.search(line)
    if match:
        state.saw_diag = True
        state.simulated_ble = match.group("state") == "enabled"
        print(f"SIMULATED_BLE {'enabled' if state.simulated_ble else 'disabled'}", flush=True)
        return

    match = TICK_RE.search(line)
    if match:
        state.saw_diag = True
        state.active = int(match.group("active"))
        state.collected = int(match.group("collected"))
        state.strongest = match.group("strongest")
        state.heading = float(match.group("heading"))
        state.tilt = float(match.group("tilt"))
        state.frame_ms = int(match.group("frame_ms") or 0)
        state.draw_ms = int(match.group("draw_ms") or 0)
        state.draw_avg_ms = int(match.group("draw_avg_ms") or 0)
        state.draw_max_ms = int(match.group("draw_max_ms") or 0)
        state.over_budget_frames = int(match.group("over_budget") or 0)
        state.frame_samples = int(match.group("frame_samples") or 0)
        state.online_code = match.group("online")
        if match.group("summon"):
            state.summon = match.group("summon") == "yes"
        now = time.monotonic()
        if now - state.last_summary_at >= args.summary_interval:
            state.last_summary_at = now
            print_summary(state)
        return

    match = BEACON_RE.search(line)
    if match:
        index = int(match.group("index"))
        raw = int(match.group("raw"))
        filtered = int(match.group("filtered"))
        bearing_bin = int(match.group("bin"))
        close = match.group("close") == "yes"
        state.beacons[index] = BeaconState(
            raw=raw,
            filtered=filtered,
            range_norm=float(match.group("range")),
            bearing_bin=bearing_bin,
            bearing=float(match.group("bearing")),
            close=close,
            seen_at=time.monotonic(),
        )
        state.beacon_stats.setdefault(index, BeaconStats()).record(raw, filtered, bearing_bin, close)
        beacon = state.beacons[index]
        print(
            f"BEACON DBALL-{index} raw={beacon.raw} filtered={beacon.filtered} "
            f"range={beacon.range_norm:.2f} bearingBin={beacon.bearing_bin} "
            f"bearing={beacon.bearing:.1f} close={'yes' if beacon.close else 'no'}",
            flush=True,
        )
        return

    match = HUNT_RE.search(line)
    if match:
        event = HuntEvent(
            session=int(match.group("session")),
            event=match.group("event"),
            ms=int(match.group("ms")),
        )
        state.hunt_session = event.session
        state.hunt_events.append(event)
        if event.event in {"start", "reset"}:
            state.collections.clear()
        print(f"HUNT session={event.session} event={event.event} ms={event.ms}", flush=True)
        return

    match = COLLECT_RE.search(line)
    if match:
        event = CollectionEvent(
            index=int(match.group("index")),
            ms=int(match.group("ms")),
            raw=int(match.group("raw")),
            filtered=int(match.group("filtered")),
            range_norm=float(match.group("range")),
            bearing_bin=int(match.group("bin")),
            bearing=float(match.group("bearing")),
            session=int(match.group("session") or state.hunt_session or 0),
        )
        state.collections.append(event)
        print(
            f"COLLECT DBALL-{event.index} session={event.session} ms={event.ms} raw={event.raw} "
            f"filtered={event.filtered} range={event.range_norm:.2f} "
            f"bearingBin={event.bearing_bin} bearing={event.bearing:.1f}",
            flush=True,
        )
        return

    match = TOUCH_RE.search(line)
    if match:
        state.last_touch = f"{match.group('x')},{match.group('y')}:{match.group('action')}"
        print(f"TOUCH {state.last_touch}", flush=True)
        return

    match = COMMAND_RE.search(line)
    if match:
        state.last_command = f"{match.group('command')}:{match.group('action')}"
        print(f"COMMAND {state.last_command}", flush=True)


def main() -> int:
    args = parse_args()
    if args.min_beacons < 0:
        print("--min-beacons must be >= 0", file=sys.stderr)
        return 2
    if args.min_collected < 0 or args.min_collected > 7:
        print("--min-collected must be in 0..7", file=sys.stderr)
        return 2
    if args.min_collections < 0 or args.min_collections > 7:
        print("--min-collections must be in 0..7", file=sys.stderr)
        return 2
    state = DiagState()
    source: Iterable[str] | TextIO
    if args.stdin:
        source = sys.stdin
    elif args.use_pio_monitor:
        source = iter_process_lines(args)
    else:
        source = iter_serial_lines(args)
    started = time.monotonic()
    log_file = open_log_file(args.log_file)

    try:
        for line in source:
            if log_file:
                log_file.write(line if line.endswith("\n") else f"{line}\n")
            handle_line(line, state, args)
            if args.timeout and time.monotonic() - started >= args.timeout:
                break
    except KeyboardInterrupt:
        pass
    finally:
        if log_file:
            log_file.close()
            print(f"LOG {args.log_file}", flush=True)

    print_summary(state)
    if args.calibrate:
        print_calibration(state)
    failures: list[str] = []
    if not state.saw_diag and not state.hardware:
        failures.append("no DIAG lines seen")
    else:
        failures = validate_requirements(state, args)

    if args.report_json:
        write_report(args.report_json, build_report(state, args, failures))

    if failures:
        for failure in failures:
            if failure == "no DIAG lines seen":
                print("No DIAG lines seen. Confirm the radar is flashed with the expected diag or sim firmware.", file=sys.stderr)
            print(f"CHECK failed: {failure}", file=sys.stderr)
        return 1
    if (args.require_online or args.min_beacons or args.min_collected or
            args.min_collections or args.require_collection_set or
            args.require_simulated_ble or args.require_summon):
        print("CHECK passed", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
