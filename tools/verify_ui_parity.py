#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
FIRMWARE = ROOT / "firmware" / "DragonRadar" / "DragonRadar.ino"
PREVIEW = ROOT / "preview" / "radar_ui.html"
PLATFORMIO = ROOT / "platformio.ini"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify that the browser preview and firmware keep the same Dragon Radar UI contract."
    )
    parser.add_argument("--json", default=None, help="Optional JSON audit output path.")
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def line_number(text: str, needle: str) -> int | None:
    index = text.find(needle)
    if index < 0:
        return None
    return text.count("\n", 0, index) + 1


def find_matching(text: str, start: int, open_char: str, close_char: str) -> int:
    depth = 0
    index = start
    in_string: str | None = None
    escaped = False
    in_line_comment = False
    in_block_comment = False

    while index < len(text):
        ch = text[index]
        nxt = text[index + 1] if index + 1 < len(text) else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
            index += 1
            continue
        if in_block_comment:
            if ch == "*" and nxt == "/":
                in_block_comment = False
                index += 2
            else:
                index += 1
            continue
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == in_string:
                in_string = None
            index += 1
            continue

        if ch == "/" and nxt == "/":
            in_line_comment = True
            index += 2
            continue
        if ch == "/" and nxt == "*":
            in_block_comment = True
            index += 2
            continue
        if ch in ('"', "'"):
            in_string = ch
            index += 1
            continue
        if ch == open_char:
            depth += 1
        elif ch == close_char:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return -1


def function_body(source: str, name: str) -> str | None:
    pattern = re.compile(rf"\b{re.escape(name)}\s*\(")
    for match in pattern.finditer(source):
        open_paren = source.find("(", match.start())
        close_paren = find_matching(source, open_paren, "(", ")")
        if close_paren < 0:
            continue
        tail = close_paren + 1
        while tail < len(source) and source[tail].isspace():
            tail += 1
        if tail >= len(source) or source[tail] != "{":
            continue
        close_brace = find_matching(source, tail, "{", "}")
        if close_brace < 0:
            continue
        return source[tail + 1 : close_brace]
    return None


def js_function_body(source: str, name: str) -> str | None:
    return function_body(source, name)


def normalize_number(value: str) -> float | int:
    cleaned = value.strip().rstrip("fF")
    number = float(cleaned)
    return int(number) if number.is_integer() else number


def c_scalar(source: str, name: str) -> float | int | None:
    pattern = re.compile(rf"\b{name}\s*=\s*([-+]?\d+(?:\.\d+)?f?)\s*;")
    match = pattern.search(source)
    return normalize_number(match.group(1)) if match else None


def js_scalar(source: str, name: str) -> float | int | None:
    pattern = re.compile(rf"\b{name}\s*=\s*([-+]?\d+(?:\.\d+)?)\s*;")
    match = pattern.search(source)
    return normalize_number(match.group(1)) if match else None


def parse_number_list(raw: str) -> list[float | int]:
    values: list[float | int] = []
    for item in raw.split(","):
        cleaned = item.strip()
        if not cleaned:
            continue
        values.append(normalize_number(cleaned))
    return values


def c_array(source: str, name: str) -> list[float | int] | None:
    pattern = re.compile(rf"\b{name}\s*\[[^\]]*\]\s*=\s*\{{([^}}]+)\}}")
    match = pattern.search(source)
    return parse_number_list(match.group(1)) if match else None


def js_array(source: str, name: str) -> list[float | int] | None:
    pattern = re.compile(rf"\b{name}\s*=\s*\[([^\]]+)\]")
    match = pattern.search(source)
    return parse_number_list(match.group(1)) if match else None


def build_audit() -> dict[str, Any]:
    firmware = read_text(FIRMWARE)
    preview = read_text(PREVIEW)
    platformio = read_text(PLATFORMIO)
    checks: list[dict[str, Any]] = []
    failures: list[str] = []

    def add(
        name: str,
        passed: bool,
        detail: str,
        source: Path,
        needle: str | None = None,
        extra: dict[str, Any] | None = None,
    ) -> None:
        record: dict[str, Any] = {
            "name": name,
            "status": "passed" if passed else "failed",
            "detail": detail,
            "source": source.relative_to(ROOT).as_posix(),
        }
        if needle:
            record["line"] = line_number(read_text(source), needle)
        if extra:
            record.update(extra)
        checks.append(record)
        if not passed:
            failures.append(name + ": " + detail)

    scalar_pairs = (
        ("boot.duration", "kBootDurationMs", "bootDurationMs"),
        ("capture.flash", "kCaptureFlashMs", "captureFlashMs"),
        ("reset.flash", "kResetFlashMs", "resetFlashMs"),
        ("summon.gather", "kSummonGatherMs", "summonGatherMs"),
        ("startup.acquire", "kStartupAcquireMs", "startupAcquireMs"),
        ("acquisition.echo", "kAcquisitionEchoMs", "acquisitionEchoMs"),
        ("touch.echo", "kTouchEchoMs", "touchEchoMs"),
        ("button.longpress", "kButtonLongPressMs", "longPressMs"),
        ("grid.major-step", "kMajorGridEvery", "majorGridEvery"),
        ("target.trail-count", "kTargetTrailCount", "targetTrailCount"),
        ("target.trail-fade", "kTargetTrailFadeMs", "targetTrailFadeMs"),
        ("target.trail-move", "kTargetTrailMovePx", "targetTrailMovePx"),
        ("summon.core-ticks", "kSummonCoreTickCount", "summonCoreTickCount"),
        ("proximity.edge-ticks", "kProximityEdgeTickCount", "proximityEdgeTickCount"),
        ("idle.search-ticks", "kIdleSearchTickCount", "idleSearchTickCount"),
        ("tilt.inertia-ticks", "kTiltInertiaTickCount", "tiltInertiaTickCount"),
    )
    for label, fw_name, preview_name in scalar_pairs:
        firmware_value = c_scalar(firmware, fw_name)
        preview_value = js_scalar(preview, preview_name)
        add(
            f"constant.{label}",
            firmware_value == preview_value and firmware_value is not None,
            f"{fw_name}={firmware_value}; {preview_name}={preview_value}",
            FIRMWARE,
            fw_name,
            {"firmwareValue": firmware_value, "previewValue": preview_value},
        )

    array_pairs = (
        ("grid.pitch", "pitches", "gridPitch"),
        ("map.scale", "scales", "mapScale"),
        ("brightness.presets", "kBrightnessPercents", "brightnessPercents"),
        ("audio.presets", "kAudioRuntimePercents", "audioPercents"),
    )
    for label, fw_name, preview_name in array_pairs:
        firmware_values = c_array(firmware, fw_name)
        preview_values = js_array(preview, preview_name)
        add(
            f"array.{label}",
            firmware_values == preview_values and firmware_values is not None,
            f"{fw_name}={firmware_values}; {preview_name}={preview_values}",
            FIRMWARE,
            fw_name,
            {"firmwareValue": firmware_values, "previewValue": preview_values},
        )

    firmware_grid = function_body(firmware, "drawRadarGrid") or ""
    preview_grid = js_function_body(preview, "drawGrid") or ""
    add(
        "grid.firmware-and-preview-exist",
        bool(firmware_grid and preview_grid),
        "drawRadarGrid and drawGrid are both present",
        PREVIEW,
        "function drawGrid",
    )
    add(
        "grid.rectangular-lines-both-surfaces",
        all(
            snippet in firmware_grid
            for snippet in ("drawFastHLine", "drawFastVLine", "currentGridPitch")
        )
        and all(snippet in preview_grid for snippet in ("lineTo", "gridPitch", "majorGridEvery")),
        "both surfaces draw rectangular horizontal/vertical coordinate lines",
        FIRMWARE,
        "void drawRadarGrid",
    )
    add(
        "grid.no-concentric-rings-both-surfaces",
        "drawCircle(" not in firmware_grid and ".arc(" not in preview_grid,
        "main grid functions avoid concentric ring primitives",
        FIRMWARE,
        "void drawRadarGrid",
    )
    add(
        "grid.circular-clip-only-in-preview",
        "function clipCircle" in preview and "ctx.arc(CX, CY, R" in preview and ".clip()" in preview,
        "preview uses circular clipping for the AMOLED crop",
        PREVIEW,
        "function clipCircle",
    )

    firmware_boot = function_body(firmware, "drawBootFrame") or ""
    preview_boot = js_function_body(preview, "drawBoot") or ""
    preview_logo = js_function_body(preview, "drawCapsuleLogo") or ""
    firmware_logo = function_body(firmware, "drawDefaultBootLogo") or ""
    firmware_mask = function_body(firmware, "drawPhosphorMask") or ""
    preview_mask = js_function_body(preview, "phosphorMask") or ""
    firmware_startup_acquire = function_body(firmware, "drawStartupAcquireOverlay") or ""
    preview_startup_acquire = js_function_body(preview, "startupAcquireOverlay") or ""
    firmware_idle_search = function_body(firmware, "drawIdleSearchLattice") or ""
    preview_idle_search = js_function_body(preview, "drawIdleSearchLattice") or ""
    firmware_tilt_inertia = function_body(firmware, "drawTiltInertiaGrid") or ""
    preview_tilt_inertia = js_function_body(preview, "drawTiltInertiaGrid") or ""
    firmware_touch_echo = function_body(firmware, "drawTouchEcho") or ""
    preview_touch_echo = js_function_body(preview, "drawTouchEcho") or ""
    firmware_handle_touch = function_body(firmware, "handleTouch") or ""
    preview_handle_touch = js_function_body(preview, "handlePreviewTouch") or ""
    preview_arm_touch = js_function_body(preview, "armTouchEcho") or ""
    firmware_zoom_flash = function_body(firmware, "drawZoomFlash") or ""
    firmware_reset_flash = function_body(firmware, "drawResetFlash") or ""
    firmware_brightness_flash = function_body(firmware, "drawBrightnessFlash") or ""
    firmware_audio_flash = function_body(firmware, "drawAudioFlash") or ""
    preview_reset_flash = js_function_body(preview, "resetFlash") or ""
    preview_brightness_flash = js_function_body(preview, "brightnessFlash") or ""
    preview_audio_flash = js_function_body(preview, "audioFlash") or ""
    firmware_capture = function_body(firmware, "drawCaptureGlyph") or ""
    preview_capture = js_function_body(preview, "captureGlyph") or ""
    firmware_proximity_lock = function_body(firmware, "drawProximityLock") or ""
    preview_proximity_lock = js_function_body(preview, "lockGlyph") or ""
    firmware_acquisition = function_body(firmware, "drawAcquisitionEcho") or ""
    preview_acquisition = js_function_body(preview, "acquisitionEcho") or ""
    firmware_orb_bloom = function_body(firmware, "drawOrbPhosphorBloom") or ""
    preview_orb_bloom = js_function_body(preview, "orbPhosphorBloom") or ""
    firmware_orb = function_body(firmware, "drawOrb") or ""
    preview_orb = js_function_body(preview, "orb") or ""
    firmware_proximity_edge = function_body(firmware, "drawProximityEdgePulse") or ""
    preview_proximity_edge = js_function_body(preview, "drawProximityEdgePulse") or ""
    firmware_update_trail = function_body(firmware, "updateTargetTrail") or ""
    preview_update_trail = js_function_body(preview, "updateTargetTrail") or ""
    firmware_draw_trail = function_body(firmware, "drawTargetTrail") or ""
    preview_draw_trail = js_function_body(preview, "drawTargetTrail") or ""
    firmware_summon_core = function_body(firmware, "drawSummonCorePulse") or ""
    preview_summon_core = js_function_body(preview, "drawSummonCorePulse") or ""
    firmware_summon_overlay = function_body(firmware, "drawSummonOverlay") or ""
    preview_summon_overlay = js_function_body(preview, "drawSummonOverlay") or ""
    firmware_targets = function_body(firmware, "drawTargets") or ""
    preview_radar = js_function_body(preview, "drawRadar") or ""
    add(
        "boot.logo-staged-both-surfaces",
        all(snippet in firmware_boot + firmware_logo for snippet in ("CAPSULE", "CORP", "smoothStep"))
        and all(snippet in preview_boot + preview_logo for snippet in ("CAPSULE", "CORP", "smoothStep")),
        "firmware and preview both keep staged Capsule-style boot logo animation",
        FIRMWARE,
        "drawDefaultBootLogo",
    )
    add(
        "boot.private-hook-firmware-only",
        "USE_PRIVATE_BOOT_LOGO" in firmware_boot and "drawPrivateBootLogo" in firmware_boot,
        "firmware keeps the private local logo hook while preview remains public fallback art",
        FIRMWARE,
        "USE_PRIVATE_BOOT_LOGO",
    )
    add(
        "screen.phosphor-mask-both-surfaces",
        all(snippet in firmware_mask for snippet in ("drawFastHLine", "drawFastVLine", "kPhosphorLine", "kPhosphorEdge"))
        and all(snippet in preview_mask for snippet in ("fillRect", "clipCircle", "rgba(4, 42, 18")),
        "firmware and preview both apply a subtle scanline/edge phosphor mask without adding radar rings",
        FIRMWARE,
        "void drawPhosphorMask",
    )
    add(
        "startup.acquire-overlay-both-surfaces",
        all(snippet in firmware_startup_acquire for snippet in ("kStartupAcquireMs", "drawFastHLine", "drawFastVLine", "drawThickLine", "drawRect"))
        and all(snippet in preview_startup_acquire for snippet in ("startupAcquireMs", "lineTo", "stroke", "clipCircle"))
        and "drawStartupAcquireOverlay();" in firmware
        and "startupAcquireOverlay(now)" in preview_radar,
        "firmware and preview both hand off from boot into a text-free rectangular acquire sweep",
        FIRMWARE,
        "void drawStartupAcquireOverlay",
    )
    add(
        "idle-search-lattice-both-surfaces",
        all(snippet in firmware_idle_search for snippet in ("kIdleSearchTickCount", "drawRect", "fillRect", "drawRotatingScan", "drawHomeMarker", "activeTargetCount() > 0"))
        and all(snippet in preview_idle_search for snippet in ("idleSearchTickCount", "strokeRect", "fillRect", "drawRotatingScan", "drawHomeMarker", "demoMode"))
        and "drawIdleSearchLattice(millis())" in firmware
        and "drawIdleSearchLattice(now)" in preview_radar,
        "firmware and preview both render the empty-field search lattice with a clockwise scan ray and red home marker",
        FIRMWARE,
        "void drawIdleSearchLattice",
    )
    add(
        "tilt-inertia-grid-both-surfaces",
        all(snippet in firmware_tilt_inertia for snippet in ("kTiltInertiaTickCount", "tiltEnergy", "tiltVectorX", "drawRect", "fillRect", "drawFastHLine", "drawFastVLine"))
        and all(snippet in preview_tilt_inertia for snippet in ("tiltInertiaTickCount", "strokeRect", "fillRect", "lineTo", "previewTiltKickUntil"))
        and "drawTiltInertiaGrid(millis())" in firmware
        and "drawTiltInertiaGrid(now)" in preview_radar,
        "firmware and preview both render IMU/motion feedback as rectangular grid-edge inertia ticks",
        FIRMWARE,
        "void drawTiltInertiaGrid",
    )
    add(
        "touch.echo-both-surfaces",
        all(snippet in firmware_touch_echo for snippet in ("kTouchEchoMs", "drawRect", "fillRect", "drawFastHLine", "drawFastVLine"))
        and all(snippet in preview_touch_echo for snippet in ("touchEchoMs", "strokeRect", "fillRect", "lineTo", "clipCircle"))
        and "armTouchEcho(x, y, now)" in firmware_handle_touch
        and "armTouchEcho(point.x, point.y, now)" in preview_handle_touch
        and all(snippet in preview_arm_touch for snippet in ("touchEchoUntil", "Math.sqrt", "touchEcho =")),
        "firmware and preview both render a text-free square contact echo for touch input",
        FIRMWARE,
        "void drawTouchEcho",
    )
    add(
        "controls.flash-overlays-both-surfaces",
        all(snippet in firmware_zoom_flash for snippet in ("zoomFlashUntilMs", "drawRect", "fillRect", "drawFastHLine"))
        and all(snippet in firmware_reset_flash for snippet in ("resetFlashUntilMs", "drawThickLine", "circleChordHalf"))
        and all(snippet in firmware_brightness_flash for snippet in ("brightnessFlashUntilMs", "drawRect", "fillRect"))
        and all(snippet in firmware_audio_flash for snippet in ("audioFlashUntilMs", "drawFastHLine", "drawFastVLine"))
        and all(snippet in preview_radar for snippet in ("zoomFlashUntil", "strokeRect", "fillRect", "lineTo"))
        and all(snippet in preview_reset_flash for snippet in ("resetFlashUntil", "resetFlashMs", "lineTo"))
        and all(snippet in preview_brightness_flash for snippet in ("brightnessFlashUntil", "brightnessPercents", "strokeRect", "fillRect"))
        and all(snippet in preview_audio_flash for snippet in ("audioFlashUntil", "audioPercents", "lineTo")),
        "firmware and preview both render zoom/reset/brightness/audio feedback as text-free rectangular flashes",
        FIRMWARE,
        "void drawZoomFlash",
    )
    add(
        "targets.capture-burst-both-surfaces",
        all(snippet in firmware_capture for snippet in ("kCaptureFlashMs", "drawRect", "drawFastHLine", "drawFastVLine"))
        and all(snippet in preview_capture for snippet in ("captureFlashMs", "strokeRect", "lineTo"))
        and "drawCaptureGlyph(x, y, now - target.collectedAtMs)" in firmware_targets
        and "captureGlyph(x, y, age)" in preview_radar,
        "firmware and preview both render collection feedback as a square capture burst",
        FIRMWARE,
        "void drawCaptureGlyph",
    )
    add(
        "targets.proximity-lock-both-surfaces",
        all(snippet in firmware_proximity_lock for snippet in ("kCollectHoldMs", "drawRectProgressFrame", "drawFastHLine", "drawFastVLine"))
        and all(snippet in preview_proximity_lock for snippet in ("strokeRect", "lineTo", "progress", "flash"))
        and "drawProximityLock(x, y, now - target.closeSinceMs)" in firmware_targets
        and "lockGlyph(x, y, progress, now)" in preview_radar,
        "firmware and preview both render close-target collection hold as a square lock with rectangular progress",
        FIRMWARE,
        "void drawProximityLock",
    )
    add(
        "targets.acquisition-echo-both-surfaces",
        all(snippet in firmware_acquisition for snippet in ("drawRect", "drawFastHLine", "drawFastVLine", "kAcquisitionEchoMs"))
        and all(snippet in preview_acquisition for snippet in ("strokeRect", "lineTo", "acquisitionEchoMs", "gridPitch"))
        and "drawAcquisitionEcho(x, y, echoAgeMs)" in firmware_targets
        and "acquisitionEcho(x, y, echoPhase)" in preview_radar,
        "firmware and preview both render a text-free square acquisition echo before the active target orb",
        FIRMWARE,
        "void drawAcquisitionEcho",
    )
    add(
        "targets.orb-phosphor-bloom-both-surfaces",
        all(snippet in firmware_orb_bloom for snippet in ("drawFastHLine", "kAmber", "kOrange", "trace"))
        and all(snippet in preview_orb_bloom for snippet in ("fillRect", "#ffb824", "#ff6f14", "trace"))
        and "drawOrbPhosphorBloom(x, y, fresh, trace, pulse)" in firmware_orb
        and "orbPhosphorBloom(x, y, fresh, trace" in preview_orb,
        "firmware and preview both add horizontal orange scanline bloom under clean target blips",
        FIRMWARE,
        "void drawOrbPhosphorBloom",
    )
    fw_star_gate = firmware_orb.find("if (kShowStarBlips)")
    fw_star_call = firmware_orb.find("drawStarMark")
    fw_star_return = firmware_orb.find("return;")
    fw_bloom_call = firmware_orb.find("drawOrbPhosphorBloom")
    fw_void_star = firmware_orb.find("(void)star")
    preview_bloom_call = preview_orb.find("orbPhosphorBloom")
    preview_star_gate = preview_orb.find("if (showStars)")
    preview_star_call = preview_orb.find("starMark")
    add(
        "targets.clean-orb-starless-both-surfaces",
        fw_star_gate >= 0
        and fw_star_gate < fw_star_call < fw_star_return < fw_bloom_call < fw_void_star
        and preview_bloom_call >= 0
        and preview_bloom_call < preview_star_gate < preview_star_call
        and "orb(x, y, ball.star, false, false, config().starBlips)" in preview_radar
        and "drawOrb(x, y, target.star, fresh, trace" in firmware_targets,
        "firmware and preview both keep Dragon Ball star marks behind the explicit star-blip/debug gate; clean mode renders plain orange phosphor blips",
        FIRMWARE,
        "if (kShowStarBlips)",
    )
    add(
        "targets.afterimage-trails-both-surfaces",
        all(snippet in firmware for snippet in ("kTargetTrailCount", "kTargetTrailFadeMs", "kTargetTrailMovePx"))
        and all(snippet in preview for snippet in ("targetTrailCount", "targetTrailFadeMs", "targetTrailMovePx"))
        and all(snippet in firmware_update_trail for snippet in ("pushTargetTrail", "kTargetTrailMovePx", "lastScreenX"))
        and all(snippet in preview_update_trail for snippet in ("pushTargetTrail", "targetTrailMovePx", "lastX"))
        and all(snippet in firmware_draw_trail for snippet in ("drawFastHLine", "kTargetTrailFadeMs"))
        and all(snippet in preview_draw_trail for snippet in ("fillRect", "targetTrailFadeMs"))
        and "drawTargetTrail(target, now)" in firmware_targets
        and "drawTargetTrail(ball, now)" in preview_radar,
        "firmware and preview both render short horizontal afterimage trails under moving target blips",
        FIRMWARE,
        "void drawTargetTrail",
    )
    add(
        "targets.proximity-edge-pulse-both-surfaces",
        all(snippet in firmware_proximity_edge for snippet in ("kProximityEdgeTickCount", "drawRect", "fillRect", "drawFastHLine", "drawFastVLine"))
        and all(snippet in preview_proximity_edge for snippet in ("proximityEdgeTickCount", "strokeRect", "fillRect", "lineTo"))
        and "drawProximityEdgePulse(proximityX, proximityY, proximityNear, now)" in firmware_targets
        and "drawProximityEdgePulse(proximityX, proximityY, proximityNear, now)" in preview_radar,
        "firmware and preview both render a text-free rectangular edge pulse for the nearest clean target",
        FIRMWARE,
        "void drawProximityEdgePulse",
    )
    add(
        "summon.core-pulse-both-surfaces",
        all(snippet in firmware_summon_core for snippet in ("kSummonCoreTickCount", "drawRect", "drawFastHLine", "drawFastVLine", "fillRect"))
        and all(snippet in preview_summon_core for snippet in ("summonCoreTickCount", "strokeRect", "lineTo", "fillRect"))
        and firmware_summon_overlay.count("drawSummonCorePulse(elapsed)") >= 2
        and preview_summon_overlay.count("drawSummonCorePulse(elapsed)") >= 2,
        "firmware and preview both render a square seven-tick summon core pulse",
        FIRMWARE,
        "void drawSummonCorePulse",
    )

    mode_expectations = {
        "field": (
            "field: { demoOnBoot: false, demoTouch: false, debugHud: false",
            "-DDRAGON_RADAR_DEMO_ON_BOOT=0",
            "-DDRAGON_RADAR_DEMO_TOUCH=0",
        ),
        "sim": (
            "sim: { demoOnBoot: false, demoTouch: false, debugHud: false",
            "-DDRAGON_RADAR_SIMULATED_BLE=1",
            "-DDRAGON_RADAR_SERIAL_DIAG=1",
        ),
        "debug": (
            "debug: { demoOnBoot: true, demoTouch: true, debugHud: true",
            "-DDRAGON_RADAR_DEBUG_HUD=1",
            "-DDRAGON_RADAR_SCAN_LINE=1",
        ),
        "diag": (
            "debugHud: true",
            "[env:esp32-s3-touch-amoled-175c-diag]",
            "-DDRAGON_RADAR_SERIAL_DIAG=1",
        ),
    }
    for mode, snippets in mode_expectations.items():
        preview_snippet = snippets[0]
        platform_snippets = snippets[1:]
        add(
            f"mode.{mode}.parity",
            preview_snippet in preview and all(snippet in platformio for snippet in platform_snippets),
            f"{mode} preview preset and PlatformIO flags match clean/debug/sim intent",
            PREVIEW if mode != "diag" else PLATFORMIO,
            preview_snippet if mode != "diag" else "[env:esp32-s3-touch-amoled-175c-diag]",
        )

    preview_state_snippets = (
        "dataset.previewMode",
        "dataset.boot",
        "dataset.collected",
        "dataset.zoom",
        "dataset.brightness",
        "dataset.audio",
        "dataset.summon",
    )
    add(
        "preview.automation-state",
        all(snippet in preview for snippet in preview_state_snippets),
        "preview exposes stable hidden state for interaction smoke tests",
        PREVIEW,
        "function syncPreviewState",
    )
    add(
        "controls.same-runtime-actions",
        all(snippet in firmware for snippet in ("cycleMapScale", "resetHuntSession", "cycleBrightness", "cycleAudioGain", "collectNextDemoTarget"))
        and all(snippet in preview for snippet in ("cycleZoom", "resetPreviewSession", "brightnessPreset", "audioPreset", "collectDemo")),
        "firmware and preview expose matching zoom/reset/brightness/audio/collect actions",
        PREVIEW,
        "window.addEventListener",
    )
    add(
        "controls.touch-longpress-reset-both-surfaces",
        all(snippet in firmware for snippet in ("touchPressedAtMs", "touchLongHandled", "long_reset", "kButtonLongPressMs"))
        and all(snippet in preview for snippet in ("longPressTimer", "longPressHandled", "resetPreviewSession", "longPressMs")),
        "firmware and preview both treat long touch/press as a hunt reset",
        FIRMWARE,
        "void pollTouch",
    )
    firmware_demo_collect = function_body(firmware, "collectNextDemoTarget") or ""
    preview_demo_collect = js_function_body(preview, "collectDemo") or ""
    add(
        "controls.demo-collect-overflow-resets-both-surfaces",
        "resetHuntSession();" in firmware_demo_collect and "resetPreviewSession(now);" in preview_demo_collect,
        "after seven demo collects, firmware and preview both reset the hunt with visible reset feedback",
        FIRMWARE,
        "void collectNextDemoTarget",
    )

    return {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": "failed" if failures else "passed",
        "checks": checks,
        "failures": failures,
    }


def main() -> int:
    args = parse_args()
    audit = build_audit()
    if args.json:
        output = Path(args.json)
        if not output.is_absolute():
            output = ROOT / output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")
    print(f"STATUS {audit['status']}")
    print(f"CHECKS {len(audit['checks'])}")
    for failure in audit["failures"]:
        print(f"FAIL {failure}")
    return 0 if audit["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
