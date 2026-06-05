#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path
from typing import Any, Callable

try:
    from PIL import Image
except ImportError as exc:
    raise SystemExit("Pillow is required: python3 -m pip install pillow") from exc


REQUIRED = [
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


PixelTest = Callable[[int, int, int], bool]
Region = Callable[[Image.Image], Any]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify Dragon Radar preview screenshots against UI invariants.")
    parser.add_argument("out_dir", nargs="?", default="output/playwright", help="Directory containing preview PNGs.")
    parser.add_argument("--json", dest="json_path", help="Optional machine-readable visual audit JSON path.")
    parser.add_argument("--md", dest="md_path", help="Optional human-readable visual audit Markdown path.")
    return parser.parse_args()


def is_green(r: int, g: int, b: int) -> bool:
    return g > 90 and g > r * 1.35 and g > b * 1.2


def is_orange(r: int, g: int, b: int) -> bool:
    return r > 150 and 50 < g < 210 and b < 80 and r > g * 1.2


def is_red(r: int, g: int, b: int) -> bool:
    return r > 150 and g < 90 and b < 90 and r > g * 1.8


def is_blue(r: int, g: int, b: int) -> bool:
    return b > 120 and b > r * 1.25 and b > g * 1.05


def is_white(r: int, g: int, b: int) -> bool:
    return r > 215 and g > 215 and b > 215


def is_trail_phosphor(r: int, g: int, b: int) -> bool:
    return r > 45 and g > 30 and b < 50 and r > g * 1.08


def is_trace_signal(r: int, g: int, b: int) -> bool:
    return 70 < r < 180 and 60 < g < 170 and b < 85 and r > g * 0.85 and r < g * 1.45


def load(name: str, out_dir: Path) -> Image.Image:
    path = out_dir / name
    if not path.exists():
        raise AssertionError(f"missing {path}")
    image = Image.open(path).convert("RGB")
    w, h = image.size
    if w < 400 or h < 400 or abs(w - h) > 2:
        raise AssertionError(f"{name}: expected square screenshot around 400px+, got {w}x{h}")
    return image


def screen_pixels(image: Image.Image):
    w, h = image.size
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


def logo_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.26)
    right = int(w * 0.74)
    top = int(h * 0.35)
    bottom = int(h * 0.61)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def center_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.36)
    right = int(w * 0.64)
    top = int(h * 0.36)
    bottom = int(h * 0.64)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def home_marker_pixels(image: Image.Image):
    w, h = image.size
    cx = w / 2
    cy = h / 2
    for y in range(int(cy - 36), int(cy + 30)):
        for x in range(int(cx - 34), int(cx + 35)):
            if 0 <= x < w and 0 <= y < h:
                yield image.getpixel((x, y))


def boot_progress_tick_counts(image: Image.Image) -> list[int]:
    w, h = image.size
    cx = w / 2
    cy = h / 2
    tick_counts: list[int] = []
    for i in range(7):
        center_x = int(round(cx - 72 + i * 24))
        left = center_x - 8
        right = center_x + 9
        top = int(round(cy + 92))
        bottom = int(round(cy + 108))
        hits = 0
        for y in range(top, bottom):
            for x in range(left, right):
                if 0 <= x < w and 0 <= y < h and is_green(*image.getpixel((x, y))):
                    hits += 1
        tick_counts.append(hits)
    return tick_counts


def startup_acquire_pixels(image: Image.Image):
    w, h = image.size
    regions = (
        (0.10, 0.25, 0.10, 0.25),
        (0.75, 0.90, 0.10, 0.25),
        (0.10, 0.25, 0.75, 0.90),
        (0.75, 0.90, 0.75, 0.90),
        (0.35, 0.43, 0.12, 0.88),
        (0.36, 0.64, 0.88, 0.95),
    )
    for left_f, right_f, top_f, bottom_f in regions:
        for y in range(int(h * top_f), int(h * bottom_f)):
            for x in range(int(w * left_f), int(w * right_f)):
                yield image.getpixel((x, y))


def idle_search_pixels(image: Image.Image):
    w, h = image.size
    regions = (
        (0.16, 0.84, 0.16, 0.25),
        (0.16, 0.84, 0.75, 0.84),
        (0.16, 0.25, 0.16, 0.84),
        (0.75, 0.84, 0.16, 0.84),
        (0.40, 0.60, 0.40, 0.60),
    )
    for left_f, right_f, top_f, bottom_f in regions:
        for y in range(int(h * top_f), int(h * bottom_f)):
            for x in range(int(w * left_f), int(w * right_f)):
                yield image.getpixel((x, y))


def touch_echo_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.50)
    right = int(w * 0.67)
    top = int(h * 0.34)
    bottom = int(h * 0.53)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def capture_burst_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.54)
    right = int(w * 0.73)
    top = int(h * 0.36)
    bottom = int(h * 0.55)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def acquisition_echo_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.29)
    right = int(w * 0.49)
    top = int(h * 0.27)
    bottom = int(h * 0.47)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def proximity_lock_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.56)
    right = int(w * 0.73)
    top = int(h * 0.33)
    bottom = int(h * 0.50)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def target_trail_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.44)
    right = int(w * 0.64)
    top = int(h * 0.52)
    bottom = int(h * 0.63)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def trace_blip_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.27)
    right = int(w * 0.43)
    top = int(h * 0.52)
    bottom = int(h * 0.68)
    for y in range(top, bottom):
        for x in range(left, right):
                yield image.getpixel((x, y))


def zoom_grid_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.18)
    right = int(w * 0.82)
    top = int(h * 0.18)
    bottom = int(h * 0.82)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def control_zoom_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.32)
    right = int(w * 0.68)
    top = int(h * 0.055)
    bottom = int(h * 0.14)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def control_brightness_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.055)
    right = int(w * 0.18)
    top = int(h * 0.42)
    bottom = int(h * 0.58)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def control_audio_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.83)
    right = int(w * 0.96)
    top = int(h * 0.38)
    bottom = int(h * 0.58)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def control_reset_pixels(image: Image.Image):
    w, h = image.size
    left = int(w * 0.47)
    right = int(w * 0.52)
    top = int(h * 0.08)
    bottom = int(h * 0.92)
    for y in range(top, bottom):
        for x in range(left, right):
            yield image.getpixel((x, y))


def inertia_corner_pixels(image: Image.Image):
    w, h = image.size
    regions = (
        (0.17, 0.36, 0.17, 0.36),
        (0.64, 0.83, 0.17, 0.36),
        (0.17, 0.36, 0.64, 0.83),
        (0.64, 0.83, 0.64, 0.83),
    )
    for left_f, right_f, top_f, bottom_f in regions:
        for y in range(int(h * top_f), int(h * bottom_f)):
            for x in range(int(w * left_f), int(w * right_f)):
                yield image.getpixel((x, y))


def count(pixels, test: PixelTest) -> int:
    return sum(1 for r, g, b in pixels if test(r, g, b))


def counts(image: Image.Image, region: Region) -> dict[str, int]:
    region_pixels = list(region(image))
    return {
        "green": count(region_pixels, is_green),
        "orange": count(region_pixels, is_orange),
        "red": count(region_pixels, is_red),
        "trail": count(region_pixels, is_trail_phosphor),
        "trace": count(region_pixels, is_trace_signal),
        "blue": count(region_pixels, is_blue),
        "white": count(region_pixels, is_white),
    }


def max_green_ring_coverage(image: Image.Image) -> float:
    w, h = image.size
    cx = w / 2
    cy = h / 2
    max_coverage = 0.0
    for radius in (55, 80, 105, 130, 155, 180):
        hits = 0
        total = 0
        for deg in range(360):
            angle = math.radians(deg)
            x = round(cx + math.cos(angle) * radius)
            y = round(cy + math.sin(angle) * radius)
            if 0 <= x < w and 0 <= y < h:
                total += 1
                if is_green(*image.getpixel((x, y))):
                    hits += 1
        max_coverage = max(max_coverage, hits / max(total, 1))
    return max_coverage


def compare(actual: int | float, op: str, expected: int | float) -> bool:
    return {
        ">": actual > expected,
        ">=": actual >= expected,
        "<": actual < expected,
        "<=": actual <= expected,
    }[op]


def rounded(value: int | float) -> int | float:
    if isinstance(value, float):
        return round(value, 6)
    return value


def add_check(
    audit: dict[str, Any],
    label: str,
    actual: int | float,
    op: str,
    expected: int | float,
) -> None:
    passed = compare(actual, op, expected)
    record = {
        "label": label,
        "actual": rounded(actual),
        "op": op,
        "expected": expected,
        "status": "passed" if passed else "failed",
    }
    audit["checks"].append(record)
    if not passed:
        audit["failures"].append(f"{label}: expected {op} {expected}, got {actual}")


def build_audit(out_dir: Path) -> dict[str, Any]:
    audit: dict[str, Any] = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "imageDir": str(out_dir),
        "status": "passed",
        "requiredFrames": REQUIRED,
        "frames": {},
        "metrics": {},
        "ringCoverage": {},
        "checks": [],
        "failures": [],
    }

    images: dict[str, Image.Image] = {}
    for name in REQUIRED:
        image = load(name, out_dir)
        images[name] = image
        audit["frames"][name] = {
            "width": image.size[0],
            "height": image.size[1],
        }

    boot_grid_screen = counts(images["boot-grid-wake.png"], screen_pixels)
    boot_grid_logo = counts(images["boot-grid-wake.png"], logo_pixels)
    audit["metrics"]["boot-grid-wake.png"] = {"screen": boot_grid_screen, "logo": boot_grid_logo}
    add_check(audit, "boot-grid-wake green screen pixels", boot_grid_screen["green"], ">", 700)
    add_check(audit, "boot-grid-wake blue logo pixels", boot_grid_logo["blue"], "<=", 100)

    boot_scan_logo = counts(images["boot-logo-scan.png"], logo_pixels)
    audit["metrics"]["boot-logo-scan.png"] = {"logo": boot_scan_logo}
    add_check(audit, "boot-logo-scan blue logo pixels", boot_scan_logo["blue"], ">", 4000)
    add_check(audit, "boot-logo-scan white logo pixels", boot_scan_logo["white"], ">", 3000)

    boot_ready_logo = counts(images["boot-logo-ready.png"], logo_pixels)
    boot_ready_ticks = boot_progress_tick_counts(images["boot-logo-ready.png"])
    audit["metrics"]["boot-logo-ready.png"] = {
        "logo": boot_ready_logo,
        "progressTicks": boot_ready_ticks,
    }
    add_check(audit, "boot-logo-ready blue logo pixels", boot_ready_logo["blue"], ">", 7000)
    add_check(audit, "boot-logo-ready white logo pixels", boot_ready_logo["white"], ">", 1500)
    add_check(audit, "boot-logo-ready seven progress ticks", min(boot_ready_ticks), ">", 12)

    boot_handoff = counts(images["boot-handoff.png"], screen_pixels)
    audit["metrics"]["boot-handoff.png"] = {"screen": boot_handoff}
    add_check(audit, "boot-handoff green screen pixels", boot_handoff["green"], ">", 3000)
    add_check(audit, "boot-handoff blue screen pixels", boot_handoff["blue"], ">", 7000)

    field = counts(images["radar-field.png"], screen_pixels)
    audit["metrics"]["radar-field.png"] = {"screen": field}
    add_check(audit, "radar-field green grid pixels", field["green"], ">", 2500)
    add_check(audit, "radar-field orange target pixels", field["orange"], "<=", 50)
    add_check(audit, "radar-field blue logo pixels", field["blue"], "<=", 50)

    sim = counts(images["radar-sim.png"], screen_pixels)
    audit["metrics"]["radar-sim.png"] = {"screen": sim}
    add_check(audit, "radar-sim green grid pixels", sim["green"], ">", 2500)
    add_check(audit, "radar-sim orange target pixels", sim["orange"], ">", 300)
    add_check(audit, "radar-sim blue logo pixels", sim["blue"], "<=", 50)

    default = counts(images["radar-default.png"], screen_pixels)
    audit["metrics"]["radar-default.png"] = {"screen": default}
    add_check(audit, "radar-default green grid pixels", default["green"], ">", 2500)
    add_check(audit, "radar-default orange target pixels", default["orange"], ">", 300)

    debug = counts(images["radar-debug.png"], screen_pixels)
    audit["metrics"]["radar-debug.png"] = {"screen": debug}
    add_check(audit, "radar-debug green HUD/grid pixels", debug["green"], ">", 4500)
    add_check(audit, "radar-debug orange target pixels", debug["orange"], ">", 800)

    startup = counts(images["radar-startup-acquire.png"], screen_pixels)
    startup_region = counts(images["radar-startup-acquire.png"], startup_acquire_pixels)
    audit["metrics"]["radar-startup-acquire.png"] = {
        "screen": startup,
        "startupAcquire": startup_region,
    }
    add_check(audit, "radar-startup-acquire green screen pixels", startup["green"], ">", 3500)
    add_check(audit, "radar-startup-acquire overlay pixels", startup_region["green"], ">", 600)
    add_check(audit, "radar-startup-acquire orange target pixels", startup["orange"], "<=", 50)
    add_check(audit, "radar-startup-acquire blue logo pixels", startup["blue"], "<=", 50)

    idle = counts(images["radar-idle-search.png"], screen_pixels)
    idle_region = counts(images["radar-idle-search.png"], idle_search_pixels)
    audit["metrics"]["radar-idle-search.png"] = {"screen": idle, "idleSearch": idle_region}
    add_check(audit, "radar-idle-search green screen pixels", idle["green"], ">", 3500)
    add_check(audit, "radar-idle-search local search pixels", idle_region["green"], ">", 2500)
    add_check(audit, "radar-idle-search orange target pixels", idle["orange"], "<=", 50)
    add_check(audit, "radar-idle-search blue logo pixels", idle["blue"], "<=", 50)

    acquisition = counts(images["radar-acquisition-echo.png"], screen_pixels)
    acquisition_region = counts(images["radar-acquisition-echo.png"], acquisition_echo_pixels)
    audit["metrics"]["radar-acquisition-echo.png"] = {
        "screen": acquisition,
        "acquisitionEcho": acquisition_region,
    }
    add_check(audit, "radar-acquisition-echo green screen pixels", acquisition["green"], ">", 3000)
    add_check(audit, "radar-acquisition-echo local echo pixels", acquisition_region["green"], ">", 220)
    add_check(audit, "radar-acquisition-echo local orange target pixels", acquisition_region["orange"], ">", 80)
    add_check(audit, "radar-acquisition-echo blue logo pixels", acquisition["blue"], "<=", 50)

    trail = counts(images["radar-target-trail.png"], screen_pixels)
    trail_region = counts(images["radar-target-trail.png"], target_trail_pixels)
    audit["metrics"]["radar-target-trail.png"] = {"screen": trail, "targetTrail": trail_region}
    add_check(audit, "radar-target-trail green screen pixels", trail["green"], ">", 3000)
    add_check(audit, "radar-target-trail local afterimage pixels", trail_region["trail"], ">", 45)
    add_check(audit, "radar-target-trail local orange target pixels", trail_region["orange"], ">", 60)
    add_check(audit, "radar-target-trail blue logo pixels", trail["blue"], "<=", 50)

    trace = counts(images["radar-trace-blip.png"], screen_pixels)
    trace_region = counts(images["radar-trace-blip.png"], trace_blip_pixels)
    audit["metrics"]["radar-trace-blip.png"] = {"screen": trace, "traceBlip": trace_region}
    add_check(audit, "radar-trace-blip green screen pixels", trace["green"], ">", 3000)
    add_check(audit, "radar-trace-blip local weak signal pixels", trace_region["trace"], ">", 60)
    add_check(audit, "radar-trace-blip bright orange target pixels", trace_region["orange"], "<=", 40)
    add_check(audit, "radar-trace-blip blue logo pixels", trace["blue"], "<=", 50)

    zoom_map = counts(images["radar-zoom-map.png"], screen_pixels)
    zoom_grid = counts(images["radar-zoom-map.png"], zoom_grid_pixels)
    audit["metrics"]["radar-zoom-map.png"] = {"screen": zoom_map, "zoomGrid": zoom_grid}
    add_check(audit, "radar-zoom-map green screen pixels", zoom_map["green"], ">", 5500)
    add_check(audit, "radar-zoom-map fixed grid pixels", zoom_grid["green"], ">", 3200)
    add_check(audit, "radar-zoom-map orange target pixels", zoom_map["orange"], ">", 500)
    add_check(audit, "radar-zoom-map blue logo pixels", zoom_map["blue"], "<=", 50)

    for marker_name in (
        "radar-default.png",
        "radar-field.png",
        "radar-sim.png",
        "radar-idle-search.png",
        "radar-zoom-map.png",
    ):
        marker = counts(images[marker_name], home_marker_pixels)
        audit["metrics"].setdefault(marker_name, {})["homeMarker"] = marker
        add_check(audit, f"{marker_name} red home triangle pixels", marker["red"], ">", 90)

    lock = counts(images["radar-proximity-lock.png"], screen_pixels)
    lock_region = counts(images["radar-proximity-lock.png"], proximity_lock_pixels)
    audit["metrics"]["radar-proximity-lock.png"] = {"screen": lock, "proximityLock": lock_region}
    add_check(audit, "radar-proximity-lock green screen pixels", lock["green"], ">", 3000)
    add_check(audit, "radar-proximity-lock local lock pixels", lock_region["green"], ">", 180)
    add_check(audit, "radar-proximity-lock local orange progress pixels", lock_region["orange"], ">", 80)
    add_check(audit, "radar-proximity-lock blue logo pixels", lock["blue"], "<=", 50)

    capture = counts(images["radar-capture-burst.png"], screen_pixels)
    capture_region = counts(images["radar-capture-burst.png"], capture_burst_pixels)
    audit["metrics"]["radar-capture-burst.png"] = {"screen": capture, "captureBurst": capture_region}
    add_check(audit, "radar-capture-burst green screen pixels", capture["green"], ">", 3000)
    add_check(audit, "radar-capture-burst local square pixels", capture_region["green"], ">", 220)
    add_check(audit, "radar-capture-burst orange target pixels", capture["orange"], "<=", 50)

    controls = counts(images["radar-control-flashes.png"], screen_pixels)
    control_zoom = counts(images["radar-control-flashes.png"], control_zoom_pixels)
    control_brightness = counts(images["radar-control-flashes.png"], control_brightness_pixels)
    control_audio = counts(images["radar-control-flashes.png"], control_audio_pixels)
    control_reset = counts(images["radar-control-flashes.png"], control_reset_pixels)
    audit["metrics"]["radar-control-flashes.png"] = {
        "screen": controls,
        "zoom": control_zoom,
        "brightness": control_brightness,
        "audio": control_audio,
        "reset": control_reset,
    }
    add_check(audit, "radar-control-flashes green screen pixels", controls["green"], ">", 3400)
    add_check(audit, "radar-control-flashes zoom bar pixels", control_zoom["green"], ">", 120)
    add_check(audit, "radar-control-flashes brightness bar pixels", control_brightness["green"], ">", 90)
    add_check(audit, "radar-control-flashes audio tick pixels", control_audio["green"], ">", 70)
    add_check(audit, "radar-control-flashes reset scan pixels", control_reset["green"], ">", 650)
    add_check(audit, "radar-control-flashes orange target pixels", controls["orange"], "<=", 50)

    touch = counts(images["radar-touch-echo.png"], screen_pixels)
    touch_region = counts(images["radar-touch-echo.png"], touch_echo_pixels)
    audit["metrics"]["radar-touch-echo.png"] = {"screen": touch, "touchEcho": touch_region}
    add_check(audit, "radar-touch-echo green screen pixels", touch["green"], ">", 3000)
    add_check(audit, "radar-touch-echo local square pixels", touch_region["green"], ">", 250)
    add_check(audit, "radar-touch-echo orange target pixels", touch["orange"], "<=", 50)

    tilt = counts(images["radar-tilt-inertia.png"], screen_pixels)
    tilt_corners = counts(images["radar-tilt-inertia.png"], inertia_corner_pixels)
    audit["metrics"]["radar-tilt-inertia.png"] = {"screen": tilt, "inertiaCorners": tilt_corners}
    add_check(audit, "radar-tilt-inertia green screen pixels", tilt["green"], ">", 3000)
    add_check(audit, "radar-tilt-inertia corner tick pixels", tilt_corners["green"], ">", 900)
    add_check(audit, "radar-tilt-inertia orange target pixels", tilt["orange"], "<=", 50)

    summon_gather = counts(images["summon-gather.png"], screen_pixels)
    audit["metrics"]["summon-gather.png"] = {"screen": summon_gather}
    add_check(audit, "summon-gather green path pixels", summon_gather["green"], ">", 5000)
    add_check(audit, "summon-gather orange moving balls", summon_gather["orange"], ">", 250)

    summon_orbit = counts(images["summon-orbit.png"], screen_pixels)
    summon_orbit_center = counts(images["summon-orbit.png"], center_pixels)
    audit["metrics"]["summon-orbit.png"] = {"screen": summon_orbit, "center": summon_orbit_center}
    add_check(audit, "summon-orbit green pulse pixels", summon_orbit["green"], ">", 5000)
    add_check(audit, "summon-orbit orange orbit balls", summon_orbit["orange"], ">", 350)
    add_check(audit, "summon-orbit center orange balls", summon_orbit_center["orange"], ">", 300)

    for name in (
        "radar-default.png",
        "radar-field.png",
        "radar-sim.png",
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
    ):
        coverage = max_green_ring_coverage(images[name])
        audit["ringCoverage"][name] = rounded(coverage)
        add_check(audit, f"{name} max green ring coverage", coverage, "<", 0.14)

    if audit["failures"]:
        audit["status"] = "failed"
    return audit


def write_json(path: Path, audit: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(audit, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"preview-visual-audit {path}")


def metric_value(audit: dict[str, Any], frame: str, group: str, key: str) -> Any:
    value = audit.get("metrics", {}).get(frame, {}).get(group, {})
    if key == "":
        return value if value != {} else "-"
    if isinstance(value, dict):
        return value.get(key, "-")
    return "-"


def write_markdown(path: Path, audit: dict[str, Any]) -> None:
    checks = audit.get("checks", [])
    failures = audit.get("failures", [])
    lines = [
        "# Dragon Radar Preview Visual Audit",
        "",
        f"- Generated: {audit.get('generated', '-')}",
        f"- Status: {str(audit.get('status', 'unknown')).upper()}",
        f"- Required frames: {len(audit.get('requiredFrames', []))}",
        f"- Checks: {len(checks)}",
        f"- Failures: {len(failures)}",
        "",
        "## UI Fidelity Summary",
        "",
        "| Invariant | Evidence |",
        "| --- | --- |",
        f"| Capsule-style boot logo | blue={metric_value(audit, 'boot-logo-ready.png', 'logo', 'blue')}; white={metric_value(audit, 'boot-logo-ready.png', 'logo', 'white')}; ticks={metric_value(audit, 'boot-logo-ready.png', 'progressTicks', '')} |",
        f"| Clean field mode | green={metric_value(audit, 'radar-field.png', 'screen', 'green')}; orange={metric_value(audit, 'radar-field.png', 'screen', 'orange')}; blue={metric_value(audit, 'radar-field.png', 'screen', 'blue')} |",
        f"| Empty-field search motion | localGreen={metric_value(audit, 'radar-idle-search.png', 'idleSearch', 'green')}; orange={metric_value(audit, 'radar-idle-search.png', 'screen', 'orange')} |",
        f"| Zoomed rectangular map | green={metric_value(audit, 'radar-zoom-map.png', 'screen', 'green')}; denseGrid={metric_value(audit, 'radar-zoom-map.png', 'zoomGrid', 'green')}; orange={metric_value(audit, 'radar-zoom-map.png', 'screen', 'orange')} |",
        f"| Summon completion | gatherOrange={metric_value(audit, 'summon-gather.png', 'screen', 'orange')}; orbitCenterOrange={metric_value(audit, 'summon-orbit.png', 'center', 'orange')} |",
        "",
        "## Ring Coverage",
        "",
        "| Frame | Max Green Ring Coverage |",
        "| --- | --- |",
    ]
    for frame, coverage in sorted(audit.get("ringCoverage", {}).items()):
        lines.append(f"| {frame} | {coverage} |")
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
    print(f"preview-visual-audit-md {path}")


def main() -> int:
    args = parse_args()
    out_dir = Path(args.out_dir)
    try:
        audit = build_audit(out_dir)
    except AssertionError as exc:
        audit = {
            "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
            "imageDir": str(out_dir),
            "status": "failed",
            "requiredFrames": REQUIRED,
            "frames": {},
            "metrics": {},
            "ringCoverage": {},
            "checks": [],
            "failures": [str(exc)],
        }

    if args.json_path:
        write_json(Path(args.json_path), audit)
    if args.md_path:
        write_markdown(Path(args.md_path), audit)

    if audit["status"] != "passed":
        for failure in audit["failures"]:
            print(f"preview-visuals-failed: {failure}", file=sys.stderr)
        return 1

    print("preview-visuals-ok")
    for name in REQUIRED:
        print(f"  {name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
