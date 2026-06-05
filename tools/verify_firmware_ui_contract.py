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
PLATFORMIO = ROOT / "platformio.ini"
BUILD_HELPER = ROOT / "tools" / "build_radar.sh"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify the firmware-side UI contract for the Dragon Radar."
    )
    parser.add_argument(
        "--json",
        default=None,
        help="Optional JSON audit output path.",
    )
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


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


def section_text(text: str, section: str) -> str:
    pattern = re.compile(
        rf"^\[{re.escape(section)}\]\s*\n(?P<body>.*?)(?=^\[|\Z)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(text)
    return match.group("body") if match else ""


def case_arm(text: str, label: str) -> str:
    pattern = re.compile(
        rf"^\s*{re.escape(label)}\)\s*\n(?P<body>.*?)(?=^\s*;;)",
        re.MULTILINE | re.DOTALL,
    )
    match = pattern.search(text)
    return match.group("body") if match else ""


def line_number(text: str, needle: str) -> int | None:
    index = text.find(needle)
    if index < 0:
        return None
    return text.count("\n", 0, index) + 1


def has_all(text: str, needles: tuple[str, ...]) -> bool:
    return all(needle in text for needle in needles)


def build_audit() -> dict[str, Any]:
    firmware = read_text(FIRMWARE)
    platformio = read_text(PLATFORMIO)
    build_helper = read_text(BUILD_HELPER)
    checks: list[dict[str, Any]] = []
    failures: list[str] = []

    def add(name: str, passed: bool, detail: str, source: Path, needle: str | None = None) -> None:
        record: dict[str, Any] = {
            "name": name,
            "status": "passed" if passed else "failed",
            "detail": detail,
            "source": source.relative_to(ROOT).as_posix(),
        }
        if needle:
            record["line"] = line_number(read_text(source), needle)
        checks.append(record)
        if not passed:
            failures.append(name + ": " + detail)

    functions = {
        name: function_body(firmware, name)
        for name in (
            "drawRadarGrid",
            "drawCoordinateGridAccents",
            "drawStatus",
            "drawStartupAcquireOverlay",
            "drawZoomFlash",
            "drawResetFlash",
            "drawBrightnessFlash",
            "drawAudioFlash",
            "drawSweep",
            "drawBootFrame",
            "drawDefaultBootLogo",
            "drawPhosphorMask",
            "drawIdleSearchLattice",
            "drawTiltInertiaGrid",
            "armTouchEcho",
            "handleTouch",
            "pollTouch",
            "drawTouchEcho",
            "drawCaptureGlyph",
            "drawProximityLock",
            "drawAcquisitionEcho",
            "drawOrbPhosphorBloom",
            "drawOrb",
            "drawProximityEdgePulse",
            "resetTargetTrail",
            "updateTargetTrail",
            "drawTargetTrail",
            "drawTargets",
            "playBootAudioCues",
            "runBootAnimation",
            "snapPointToGrid",
            "drawSummonGathering",
            "drawSummonCorePulse",
            "drawSummonOverlay",
            "initRadarChordHalfCache",
            "circleChordHalf",
            "currentFrameMs",
            "framePresetForMs",
            "loadRuntimeSettings",
            "saveRuntimeSettings",
            "serialDiagnosticsTick",
            "loop",
        )
    }

    for name, body in functions.items():
        add(
            f"function.{name}.exists",
            body is not None,
            f"{name} function is present",
            FIRMWARE,
            name,
        )

    radar_grid = functions["drawRadarGrid"] or ""
    debug_index = radar_grid.find("if (kShowDebugHud)")
    title_index = radar_grid.find('drawCenteredText("DRAGON RADAR"')
    add(
        "radar.grid.rectangular-lines",
        has_all(radar_grid, ("drawFastHLine", "drawFastVLine", "currentGridPitch")),
        "main radar grid is drawn with rectangular horizontal and vertical grid lines",
        FIRMWARE,
        "void drawRadarGrid",
    )
    add(
        "radar.grid.no-ring-drawcircle",
        "drawCircle(" not in radar_grid,
        "main radar grid does not draw circular rings",
        FIRMWARE,
        "void drawRadarGrid",
    )
    add(
        "radar.grid.circular-clip-only",
        "fillCircle(kCx, kCy, kRadarRadius + 7, kScreenBg)" in radar_grid,
        "circular AMOLED crop is a background mask, not a ring radar",
        FIRMWARE,
        "fillCircle(kCx, kCy, kRadarRadius + 7, kScreenBg)",
    )
    add(
        "radar.grid.debug-title-gated",
        debug_index >= 0 and title_index > debug_index,
        "DRAGON RADAR text appears only inside the debug HUD branch",
        FIRMWARE,
        'drawCenteredText("DRAGON RADAR"',
    )

    accents = functions["drawCoordinateGridAccents"] or ""
    add(
        "radar.accents.rectangular-axis",
        has_all(accents, ("drawFastHLine", "drawFastVLine")),
        "coordinate accents use rectangular axes and ticks",
        FIRMWARE,
        "void drawCoordinateGridAccents",
    )
    add(
        "radar.accents.no-ring-drawcircle",
        "drawCircle(" not in accents,
        "coordinate accents do not add concentric rings",
        FIRMWARE,
        "void drawCoordinateGridAccents",
    )

    status = functions["drawStatus"] or ""
    touch_echo = functions["drawTouchEcho"] or ""
    handle_touch = functions["handleTouch"] or ""
    poll_touch = functions["pollTouch"] or ""
    no_hud_index = status.find("if (!kShowDebugHud)")
    first_return_index = status.find("return;")
    first_print_index = min(
        [index for index in (status.find("gfx->print"), status.find("snprintf")) if index >= 0],
        default=-1,
    )
    add(
        "status.clean-mode-early-return",
        no_hud_index >= 0 and first_return_index > no_hud_index,
        "non-debug mode exits after transient icon flashes",
        FIRMWARE,
        "void drawStatus",
    )
    add(
        "status.no-text-before-clean-return",
        first_print_index < 0 or first_return_index < first_print_index,
        "clean field/sim UI does not print HUD text before returning",
        FIRMWARE,
        "void drawStatus",
    )
    add(
        "status.debug-strips-gated",
        all(status.find(call) > first_return_index for call in (
            "drawRssiCalibrationStrip",
            "drawCollectionStrip",
            "drawBearingCalibrationStrip",
        )),
        "RSSI, collection, and bearing calibration strips are debug-HUD only",
        FIRMWARE,
        "drawRssiCalibrationStrip",
    )
    add(
        "status.debug-heading-gated",
        status.find('"HDG %03d"') > first_return_index and status.find('"ORB %d/7"') > first_return_index,
        "heading and orb counters are debug-HUD only",
        FIRMWARE,
        '"HDG %03d"',
    )
    add(
        "touch.echo.clean-rectangular",
        has_all(touch_echo, (
            "kTouchEchoMs",
            "kShowDebugHud",
            "drawRect",
            "fillRect",
            "drawFastHLine",
            "drawFastVLine",
            "circleChordHalf",
        ))
        and "drawCircle(" not in touch_echo
        and "gfx->print" not in touch_echo,
        "touch input creates a text-free square contact echo instead of rings or labels",
        FIRMWARE,
        "void drawTouchEcho",
    )
    add(
        "touch.echo.armed-from-touch",
        "armTouchEcho(x, y, now)" in handle_touch
        and "armTouchEcho(touchLastX, touchLastY, now)" in poll_touch,
        "tap and long-press touch paths both arm the same contact echo",
        FIRMWARE,
        "armTouchEcho",
    )
    add(
        "status.clean-mode-touch-echo",
        0 <= status.find("drawTouchEcho();") < first_return_index,
        "clean prop mode draws touch contact echo before returning from HUD rendering",
        FIRMWARE,
        "drawTouchEcho();",
    )
    zoom_flash = functions["drawZoomFlash"] or ""
    reset_flash = functions["drawResetFlash"] or ""
    brightness_flash = functions["drawBrightnessFlash"] or ""
    audio_flash = functions["drawAudioFlash"] or ""
    add(
        "status.clean-mode-control-flashes",
        all(0 <= status.find(call) < first_return_index for call in (
            "drawZoomFlash();",
            "drawResetFlash();",
            "drawBrightnessFlash();",
            "drawAudioFlash();",
            "drawTouchEcho();",
        )),
        "clean prop mode allows only transient rectangular control flashes before returning from HUD rendering",
        FIRMWARE,
        "drawZoomFlash();",
    )
    add(
        "controls.zoom-flash.rectangular",
        has_all(zoom_flash, ("zoomFlashUntilMs", "kZoomLevelCount", "drawRect", "fillRect", "drawFastHLine"))
        and "drawCircle(" not in zoom_flash
        and "gfx->print" not in zoom_flash,
        "zoom feedback is a compact text-free rectangular scale indicator",
        FIRMWARE,
        "void drawZoomFlash",
    )
    add(
        "controls.reset-flash.rectangular-scanline",
        has_all(reset_flash, ("resetFlashUntilMs", "kResetFlashMs", "drawThickLine", "circleChordHalf"))
        and "drawCircle(" not in reset_flash
        and "gfx->print" not in reset_flash,
        "reset feedback is a vertical scanline wipe through the circular screen crop",
        FIRMWARE,
        "void drawResetFlash",
    )
    add(
        "controls.brightness-audio-flashes.rectangular",
        has_all(brightness_flash, ("brightnessFlashUntilMs", "kBrightnessPresetCount", "drawRect", "fillRect"))
        and has_all(audio_flash, ("audioFlashUntilMs", "kAudioPresetCount", "drawFastHLine", "drawFastVLine"))
        and "drawCircle(" not in brightness_flash + audio_flash
        and "gfx->print" not in brightness_flash + audio_flash,
        "brightness and audio feedback use small rectangular bars rather than text HUD labels",
        FIRMWARE,
        "void drawBrightnessFlash",
    )

    current_frame = functions["currentFrameMs"] or ""
    frame_migrate = functions["framePresetForMs"] or ""
    load_settings = functions["loadRuntimeSettings"] or ""
    save_settings = functions["saveRuntimeSettings"] or ""
    diagnostics = functions["serialDiagnosticsTick"] or ""
    loop_body = functions["loop"] or ""
    chord_init = functions["initRadarChordHalfCache"] or ""
    chord_lookup = functions["circleChordHalf"] or ""
    sweep = functions["drawSweep"] or ""
    summon_overlay = functions["drawSummonOverlay"] or ""
    add(
        "performance.refresh-presets-fast-diagnostic",
        "#define DRAGON_RADAR_FRAME_MS 25" in firmware
        and "constexpr uint8_t kFramePresetCount = 6;" in firmware
        and "constexpr uint32_t kFrameRuntimeMs[kFramePresetCount] = {kFrameMs, 33, 50, 65, 80, 120}" in firmware
        and "static_assert(DRAGON_RADAR_FRAME_MS >= 20" in firmware
        and "FRAME_MS          Override display frame interval, 20-180 ms" in build_helper,
        "firmware defaults to a 25ms turbo refresh target while keeping 33/50/65/80/120ms rollback presets",
        FIRMWARE,
        "kFrameRuntimeMs",
    )
    add(
        "performance.display-bus-fast-configurable",
        "#define DRAGON_RADAR_DISPLAY_BUS_HZ 80000000" in firmware
        and "static_assert(DRAGON_RADAR_DISPLAY_BUS_HZ >= 20000000" in firmware
        and "constexpr int32_t kDisplayBusHz = DRAGON_RADAR_DISPLAY_BUS_HZ;" in firmware
        and "gfx->begin(kDisplayBusHz)" in firmware
        and "DISPLAY_BUS_HZ    Override CO5300 QSPI display bus" in build_helper
        and 'append_override "${DISPLAY_BUS_HZ:-}" "DRAGON_RADAR_DISPLAY_BUS_HZ"' in build_helper,
        "CO5300 QSPI write speed defaults to 80MHz and can be lowered by build helper override",
        FIRMWARE,
        "DRAGON_RADAR_DISPLAY_BUS_HZ",
    )
    add(
        "performance.refresh-current-preset-used",
        "return kFrameRuntimeMs[framePreset];" in current_frame
        and "currentFrameMs()" in diagnostics
        and "currentFrameMs()" in loop_body,
        "main loop and DIAG both use the active runtime frame preset",
        FIRMWARE,
        "uint32_t currentFrameMs",
    )
    add(
        "performance.draw-cost-diag",
        has_all(firmware, (
            "uint32_t lastDrawMs",
            "recordFramePerformance(lastDrawMs, currentFrameMs(), millis())",
            "lastDrawAvgMs",
            "lastDrawMaxMs",
            "lastDrawOverBudgetFrames",
        ))
        and has_all(diagnostics, (
            'Serial.print(" drawMs=")',
            'Serial.print(" drawAvgMs=")',
            'Serial.print(" drawMaxMs=")',
            'Serial.print(" overBudget=")',
            'Serial.print(" frames=")',
        )),
        "DIAG tick reports last and rolling draw cost so refresh complaints can be measured on the real board",
        FIRMWARE,
        'Serial.print(" drawMs=")',
    )
    add(
        "performance.frame-turbo-command",
        has_all(firmware, (
            "void setFrameTurbo()",
            "case 't':",
            'printFrameRateCommandResult(command, "frame_turbo")',
            "tools/send_diag_command.py turbo",
        ))
        or (
            "void setFrameTurbo()" in firmware
            and "case 't':" in firmware
            and 'printFrameRateCommandResult(command, "frame_turbo")' in firmware
            and '"turbo": "t"' in read_text(ROOT / "tools" / "send_diag_command.py")
        ),
        "hidden serial command can force the runtime back to the 25ms turbo preset when old NVS still stores 33ms",
        FIRMWARE,
        "void setFrameTurbo",
    )
    add(
        "performance.frame-prefs-ms-migration",
        has_all(frame_migrate, ("kFrameRuntimeMs", "bestDelta", "return best"))
        and has_all(load_settings, ("prefs.isKey(\"frameMs\")", "framePresetForMs(prefs.getUInt(\"frameMs\"", "kLegacyFrameRuntimeMs"))
        and has_all(save_settings, ("prefs.putUInt(\"frameMs\", currentFrameMs())", "prefs.putUChar(\"frameSchema\", kFramePrefsSchema)")),
        "runtime frame preset persistence is saved as milliseconds and migrates old index-based NVS values",
        FIRMWARE,
        "framePresetForMs",
    )
    add(
        "performance.circle-chord-cache",
        has_all(firmware, ("kRadarChordCacheSize", "radarChordHalfCache", "radarChordHalfCacheReady"))
        and has_all(chord_init, ("for (int offset = -kRadarRadius", "sqrtf(kRadarRadius * kRadarRadius - offset * offset)", "radarChordHalfCacheReady = true"))
        and has_all(chord_lookup, ("radius == kRadarRadius", "radarChordHalfCacheReady", "radarChordHalfCache[offset + kRadarRadius]"))
        and "initRadarChordHalfCache();" in firmware,
        "default-radius circle chord geometry is cached once before boot/radar rendering",
        FIRMWARE,
        "initRadarChordHalfCache",
    )
    add(
        "performance.high-frequency-chord-cache-use",
        "sqrtf(" not in radar_grid
        and "sqrtf(" not in sweep
        and "sqrtf(" not in summon_overlay
        and radar_grid.count("circleChordHalf(") >= 2
        and has_all(sweep, ("drawRotatingScan", "kScan", "kGridDim"))
        and "circleChordHalf(offset)" in summon_overlay,
        "per-frame grid and summon overlay use cached chord lookups while the sweep is a lightweight rotating ray",
        FIRMWARE,
        "void drawRadarGrid",
    )

    startup = functions["drawStartupAcquireOverlay"] or ""
    idle_search = functions["drawIdleSearchLattice"] or ""
    tilt_inertia = functions["drawTiltInertiaGrid"] or ""
    add(
        "startup.acquire.rectangular-corners",
        has_all(startup, ("drawFastHLine", "drawFastVLine", "drawRect", "fillRect")),
        "startup acquisition overlay uses rectangular corner and tick geometry",
        FIRMWARE,
        "void drawStartupAcquireOverlay",
    )
    add(
        "startup.acquire.no-text",
        not any(token in startup for token in ("gfx->print", "drawCenteredText", "setCursor")),
        "startup acquisition overlay stays text-free",
        FIRMWARE,
        "void drawStartupAcquireOverlay",
    )
    add(
        "idle-search.clean-empty-rectangular",
        has_all(idle_search, (
            "kIdleSearchTickCount",
            "kShowDebugHud || kShowStarBlips",
            "demoMode",
            "summonMode",
            "activeTargetCount() > 0",
            "drawRect",
            "fillRect",
            "drawRotatingScan",
            "drawHomeMarker",
        ))
        and "drawCircle(" not in idle_search
        and "gfx->print" not in idle_search,
        "empty field mode has a text-free rectangular search lattice, clockwise scan ray, and red home marker without fake targets or rings",
        FIRMWARE,
        "void drawIdleSearchLattice",
    )
    add(
        "idle-search.draw-frame-after-targets",
        "drawTargets();\n  drawIdleSearchLattice(millis());" in firmware,
        "empty-search lattice draws only after normal target rendering has had a chance to show real beacons",
        FIRMWARE,
        "drawIdleSearchLattice(millis())",
    )
    add(
        "imu.tilt-inertia.clean-rectangular",
        has_all(tilt_inertia, (
            "kTiltInertiaTickCount",
            "kShowDebugHud || kShowStarBlips",
            "tiltEnergy",
            "tiltVectorX",
            "tiltVectorY",
            "drawRect",
            "fillRect",
            "drawFastHLine",
            "drawFastVLine",
        ))
        and "drawCircle(" not in tilt_inertia
        and "gfx->print" not in tilt_inertia,
        "IMU motion creates a text-free rectangular inertia overlay instead of labels or rings",
        FIRMWARE,
        "void drawTiltInertiaGrid",
    )
    add(
        "imu.tilt-vector-from-accelerometer",
        has_all(firmware, (
            "tiltVectorX = lerpf(tiltVectorX, acc.x",
            "tiltVectorY = lerpf(tiltVectorY, acc.y",
            "tiltEnergy = clampf(lerpf(tiltEnergy, mag",
        )),
        "accelerometer readings feed the clean-mode inertia overlay",
        FIRMWARE,
        "tiltVectorX = lerpf",
    )
    add(
        "imu.tilt-inertia.draw-frame-after-search",
        "drawIdleSearchLattice(millis());\n  drawTiltInertiaGrid(millis());" in firmware,
        "tilt inertia overlays the grid after target/search rendering without changing target logic",
        FIRMWARE,
        "drawTiltInertiaGrid(millis())",
    )

    boot = functions["drawBootFrame"] or ""
    default_logo = functions["drawDefaultBootLogo"] or ""
    phosphor = functions["drawPhosphorMask"] or ""
    boot_audio = functions["playBootAudioCues"] or ""
    boot_animation = functions["runBootAnimation"] or ""
    add(
        "boot.private-logo-hook",
        has_all(boot, ("USE_PRIVATE_BOOT_LOGO", '__has_include("private_boot_logo.h")', "drawPrivateBootLogo", "drawDefaultBootLogo")),
        "boot animation keeps the private Capsule-style logo hook with fallback art",
        FIRMWARE,
        "void drawBootFrame",
    )
    add(
        "boot.logo-include-guard",
        has_all(firmware, ("#ifndef USE_PRIVATE_BOOT_LOGO", '#include "private_boot_logo.h"')),
        "private boot logo is optional and source-local",
        FIRMWARE,
        "USE_PRIVATE_BOOT_LOGO",
    )
    add(
        "boot.grid-backdrop",
        "drawBootGridBackdrop" in boot and "drawRect" in boot and "fillRect" in boot,
        "boot frame includes grid wakeup and rectangular progress ticks",
        FIRMWARE,
        "drawBootGridBackdrop",
    )
    add(
        "boot.default-logo.capsule-body",
        has_all(default_logo, (
            "drawCapsuleShape",
            "118.0f * body",
            "34.0f * body",
            "drawFastVLine(scanX",
            "gfx->print(\"CAPSULE\")",
            "gfx->print(\"CORP.\")",
        )),
        "public fallback boot logo keeps the same capsule body, scan reveal, and Capsule-style text as the local/private logo path",
        FIRMWARE,
        "void drawDefaultBootLogo",
    )
    add(
        "boot.default-logo.c-mark-placement",
        has_all(default_logo, ("kCx - 58", "gfx->print(\"C\")", "deepBlue")),
        "fallback boot logo keeps the blue side mark and white C in the same placement family as the preview/private mark",
        FIRMWARE,
        "kCx - 58",
    )
    private_example_path = ROOT / "firmware" / "DragonRadar" / "private_boot_logo.h.example"
    private_example = read_text(private_example_path)
    add(
        "boot.private-example.rich-logo",
        has_all(private_example, (
            "drawPrivateCapsuleShape",
            "118.0f * body",
            "34.0f * body",
            "drawFastVLine(scanX",
            "gfx->print(\"CAPSULE\")",
            "gfx->print(\"CORP.\")",
        )),
        "the copied private-logo example matches the richer capsule boot mark instead of the old circle placeholder",
        private_example_path,
        "drawPrivateCapsuleShape",
    )
    add(
        "screen.phosphor-mask.scanlines",
        has_all(phosphor, ("kPhosphorLine", "drawFastHLine", "kPhosphorScanlineStep", "circleChordHalf")),
        "prop screen has sparse horizontal phosphor scanlines clipped to the round AMOLED",
        FIRMWARE,
        "void drawPhosphorMask",
    )
    add(
        "screen.phosphor-mask.edge-shadow",
        has_all(phosphor, ("kPhosphorEdge", "drawFastVLine", "kPhosphorEdgeInsetLimit")),
        "prop screen has subtle rectangular edge darkening without drawing radar rings",
        FIRMWARE,
        "kPhosphorEdge",
    )
    add(
        "audio.boot-cue-table",
        has_all(firmware, (
            "constexpr BootAudioCue kBootAudioCues[]",
            "{0.08f, 523.25f",
            "{0.94f, 1975.5f",
            "kBootAudioCueCount",
        )),
        "boot audio has a staged scan/logo/handoff cue table instead of ad hoc beeps",
        FIRMWARE,
        "kBootAudioCues",
    )
    add(
        "audio.boot-cues-stage-bound",
        has_all(boot_audio, (
            "while (nextCue < kBootAudioCueCount",
            "phase >= kBootAudioCues[nextCue].phase",
            "startTone(cue.frequency",
            "++nextCue",
        )),
        "boot audio cues advance by animation phase and play each cue once",
        FIRMWARE,
        "void playBootAudioCues",
    )
    add(
        "audio.boot-animation-uses-cues",
        has_all(boot_animation, ("uint8_t nextBootCue = 0", "playBootAudioCues(phase, nextBootCue)", "audioTick()")),
        "boot animation drives the staged cue sequence while streaming audio samples",
        FIRMWARE,
        "void runBootAnimation",
    )

    snap = functions["snapPointToGrid"] or ""
    add(
        "targets.snap.disabled-in-debug",
        "!kSnapTargetsToGrid || kShowDebugHud" in snap,
        "target snapping is active for clean UI but bypassed in debug HUD",
        FIRMWARE,
        "void snapPointToGrid",
    )
    add(
        "targets.snap.grid-rounding",
        "roundf" in snap and "currentGridPitch()" in snap,
        "target blips snap to the rectangular grid pitch",
        FIRMWARE,
        "roundf",
    )
    acquisition_echo = functions["drawAcquisitionEcho"] or ""
    capture_glyph = functions["drawCaptureGlyph"] or ""
    proximity_lock = functions["drawProximityLock"] or ""
    orb_bloom = functions["drawOrbPhosphorBloom"] or ""
    draw_orb = functions["drawOrb"] or ""
    proximity_edge = functions["drawProximityEdgePulse"] or ""
    reset_trail = functions["resetTargetTrail"] or ""
    update_trail = functions["updateTargetTrail"] or ""
    draw_trail = functions["drawTargetTrail"] or ""
    targets_body = functions["drawTargets"] or ""
    add(
        "targets.orb-bloom.scanline-bars",
        has_all(orb_bloom, (
            "drawFastHLine",
            "kAmber",
            "kOrange",
            "fresh",
            "trace",
        ))
        and "drawCircle(" not in orb_bloom,
        "clean target blips get short horizontal orange phosphor bars, not radar rings",
        FIRMWARE,
        "void drawOrbPhosphorBloom",
    )
    add(
        "targets.clean-orb-uses-bloom",
        "drawOrbPhosphorBloom(x, y, fresh, trace, pulse)" in draw_orb
        and "(void)star;" in draw_orb,
        "clean prop-mode orbs layer the scanline bloom under the plain orange blip while keeping star marks out of clean mode",
        FIRMWARE,
        "drawOrbPhosphorBloom(x, y, fresh, trace, pulse)",
    )
    star_gate_index = draw_orb.find("if (kShowStarBlips)")
    star_call_index = draw_orb.find("drawStarMark")
    star_return_index = draw_orb.find("return;")
    star_ring_index = draw_orb.find("drawCircle")
    bloom_index = draw_orb.find("drawOrbPhosphorBloom")
    void_star_index = draw_orb.find("(void)star")
    add(
        "targets.clean-orb-starless",
        star_gate_index >= 0
        and star_gate_index < star_call_index < star_return_index < bloom_index < void_star_index
        and star_gate_index < star_ring_index < star_return_index
        and "gfx->print" not in draw_orb,
        "Dragon Ball star marks and outline rings are confined to the debug/star-blip branch; clean mode stays as plain orange phosphor blips",
        FIRMWARE,
        "if (kShowStarBlips)",
    )
    add(
        "targets.trail.state-in-target",
        has_all(firmware, (
            "constexpr uint8_t kTargetTrailCount = 3",
            "constexpr uint32_t kTargetTrailFadeMs = 1280",
            "trailX[kTargetTrailCount]",
            "trailY[kTargetTrailCount]",
            "trailMs[kTargetTrailCount]",
        )),
        "targets keep a small fixed-size screen afterimage stack with no dynamic allocation",
        FIRMWARE,
        "kTargetTrailCount",
    )
    add(
        "targets.trail.reset-on-session",
        has_all(reset_trail, ("lastScreenX", "lastScreenY", "lastTrailMs", "memset(target.trailX"))
        and "resetTargetTrail(target);" in firmware
        and "resetAllTargetTrails();" in firmware,
        "target trails reset with hunt state and zoom changes so old screen coordinates do not linger",
        FIRMWARE,
        "void resetTargetTrail",
    )
    add(
        "targets.trail.clean-mode-only",
        "kShowDebugHud || kShowStarBlips" in update_trail
        and "kShowDebugHud || kShowStarBlips" in draw_trail,
        "afterimage trails are hidden in debug/star-blip modes",
        FIRMWARE,
        "void updateTargetTrail",
    )
    add(
        "targets.trail.motion-threshold",
        has_all(update_trail, ("kTargetTrailMovePx", "pushTargetTrail", "lastScreenX", "lastScreenY")),
        "afterimage trails are pushed only when snapped target screen positions move enough",
        FIRMWARE,
        "kTargetTrailMovePx",
    )
    add(
        "targets.trail.horizontal-decay",
        has_all(draw_trail, ("kTargetTrailFadeMs", "drawFastHLine", "target.trailMs", "RGB565(132, 86, 18)"))
        and "drawCircle(" not in draw_trail,
        "afterimage trails fade as short horizontal phosphor marks, not circles",
        FIRMWARE,
        "void drawTargetTrail",
    )
    add(
        "targets.trail.draws-before-orb",
        0 <= targets_body.find("updateTargetTrail(target, x, y, now);")
        < targets_body.find("drawOrb(x, y, target.star"),
        "target afterimages are drawn under the active orange blip",
        FIRMWARE,
        "drawTargetTrail(target, now)",
    )
    add(
        "targets.acquisition-echo.square-grid",
        has_all(acquisition_echo, (
            "kAcquisitionEchoMs",
            "currentGridPitch()",
            "drawRect",
            "drawFastHLine",
            "drawFastVLine",
        )),
        "fresh targets get a text-free square acquisition echo tied to the rectangular grid",
        FIRMWARE,
        "void drawAcquisitionEcho",
    )
    add(
        "targets.acquisition-echo.fresh-beacon",
        has_all(targets_body, (
            "now - target.revealedAtMs < kAcquisitionEchoMs",
            "echoAgeMs = now - target.revealedAtMs",
            "drawAcquisitionEcho(x, y, echoAgeMs)",
        )),
        "newly discovered or reacquired BLE beacons trigger the square acquisition echo before the orb is drawn",
        FIRMWARE,
        "target.revealedAtMs",
    )
    add(
        "targets.acquisition-echo.demo-next",
        has_all(targets_body, (
            "i == collectedTargetCount()",
            "phaseMs < kAcquisitionEchoMs",
            "echoAgeMs = phaseMs",
        )),
        "default demo mode previews the same acquisition echo on the next uncollected target",
        FIRMWARE,
        "collectedTargetCount()",
    )
    add(
        "targets.capture-glyph.square-burst",
        has_all(capture_glyph, (
            "kCaptureFlashMs",
            "drawRect",
            "drawFastHLine",
            "drawFastVLine",
            "kAmber",
        ))
        and "drawCircle(" not in capture_glyph
        and "gfx->print" not in capture_glyph,
        "collected targets flash as a text-free square capture burst",
        FIRMWARE,
        "void drawCaptureGlyph",
    )
    add(
        "targets.capture-glyph.collected-targets",
        has_all(targets_body, (
            "target.collectedAtMs > 0",
            "now - target.collectedAtMs < kCaptureFlashMs",
            "drawCaptureGlyph(x, y, now - target.collectedAtMs)",
        )),
        "recently collected targets render the square capture burst before disappearing",
        FIRMWARE,
        "drawCaptureGlyph(x, y, now - target.collectedAtMs)",
    )
    add(
        "targets.proximity-lock.square-progress",
        has_all(proximity_lock, (
            "kCollectHoldMs",
            "drawRectProgressFrame",
            "drawFastHLine",
            "drawFastVLine",
            "drawRect",
            "kAmber",
        ))
        and "drawCircle(" not in proximity_lock
        and "gfx->print" not in proximity_lock,
        "close targets render a text-free square lock frame with a rectangular hold-progress edge",
        FIRMWARE,
        "void drawProximityLock",
    )
    add(
        "targets.proximity-lock.clean-targets",
        has_all(targets_body, (
            "!trace && target.closeSinceMs > 0",
            "drawProximityLock(x, y, now - target.closeSinceMs)",
        )),
        "clean target rendering shows the square proximity lock only while the collection hold is active",
        FIRMWARE,
        "drawProximityLock(x, y, now - target.closeSinceMs)",
    )
    add(
        "targets.proximity-edge-pulse.rectangular",
        has_all(proximity_edge, (
            "kProximityEdgeTickCount",
            "kShowDebugHud || kShowStarBlips",
            "drawRect",
            "fillRect",
            "drawFastHLine",
            "drawFastVLine",
        ))
        and "drawCircle(" not in proximity_edge
        and "gfx->print" not in proximity_edge,
        "nearby targets add a text-free rectangular edge pulse instead of a ring or label",
        FIRMWARE,
        "void drawProximityEdgePulse",
    )
    add(
        "targets.proximity-edge-pulse.clean-targets",
        has_all(targets_body, (
            "proximityNear",
            "(0.96f - range)",
            "drawProximityEdgePulse(proximityX, proximityY, proximityNear, now)",
        )),
        "clean target rendering chooses the nearest visible uncollected target for the edge pulse",
        FIRMWARE,
        "drawProximityEdgePulse(proximityX, proximityY, proximityNear, now)",
    )

    summon = functions["drawSummonGathering"] or ""
    summon_core = functions["drawSummonCorePulse"] or ""
    summon_overlay = functions["drawSummonOverlay"] or ""
    add(
        "summon.gather.square-paths",
        has_all(summon, ("drawFastHLine", "drawFastVLine", "drawRect")),
        "summon gathering animation uses square-grid paths into center",
        FIRMWARE,
        "void drawSummonGathering",
    )
    add(
        "summon.gather.from-snapped-points",
        "summonStartPoint" in summon and "roundf" in summon,
        "summon animation starts from grid-aligned target positions",
        FIRMWARE,
        "summonStartPoint",
    )
    add(
        "summon.core.square-pulse",
        has_all(summon_core, (
            "kSummonCoreTickCount",
            "drawRect",
            "drawFastHLine",
            "drawFastVLine",
            "fillRect",
        ))
        and "drawCircle(" not in summon_core,
        "completed-hunt summon has a text-free square center pulse with seven rectangular ticks",
        FIRMWARE,
        "void drawSummonCorePulse",
    )
    add(
        "summon.overlay.uses-core-pulse",
        summon_overlay.count("drawSummonCorePulse(elapsed)") >= 2,
        "summon overlay draws the square core pulse during gather and orbit phases",
        FIRMWARE,
        "drawSummonCorePulse(elapsed)",
    )

    constants = (
        "constexpr bool kShowDebugHud = DRAGON_RADAR_DEBUG_HUD;",
        "constexpr bool kSnapTargetsToGrid = DRAGON_RADAR_GRID_SNAP;",
        "constexpr bool kSerialDiagnostics = DRAGON_RADAR_SERIAL_DIAG;",
        "constexpr bool kDemoOnBoot = DRAGON_RADAR_DEMO_ON_BOOT;",
        "constexpr bool kDemoTouchEnabled = DRAGON_RADAR_DEMO_TOUCH;",
        "constexpr bool kSimulatedBle = DRAGON_RADAR_SIMULATED_BLE;",
    )
    add(
        "macros.compile-time-mode-switches",
        has_all(firmware, constants),
        "UI, demo, diagnostic, snap, and simulated-BLE modes are compile-time switches",
        FIRMWARE,
        "constexpr bool kShowDebugHud",
    )
    add(
        "macros.safe-defaults",
        has_all(firmware, (
            "#define DRAGON_RADAR_DEBUG_HUD 0",
            "#define DRAGON_RADAR_GRID_SNAP 1",
            "#define DRAGON_RADAR_SERIAL_DIAG 0",
            "#define DRAGON_RADAR_DEMO_ON_BOOT 1",
            "#define DRAGON_RADAR_DEMO_TOUCH 1",
            "#define DRAGON_RADAR_SIMULATED_BLE 0",
        )),
        "default build remains demo-friendly while field builds override clean-play macros",
        FIRMWARE,
        "#define DRAGON_RADAR_GRID_SNAP 1",
    )

    base_section = section_text(platformio, "env:esp32-s3-touch-amoled-175c")
    field_section = section_text(platformio, "env:esp32-s3-touch-amoled-175c-field")
    fielddiag_section = section_text(platformio, "env:esp32-s3-touch-amoled-175c-fielddiag")
    debug_section = section_text(platformio, "env:esp32-s3-touch-amoled-175c-debug")
    diag_section = section_text(platformio, "env:esp32-s3-touch-amoled-175c-diag")
    sim_section = section_text(platformio, "env:esp32-s3-touch-amoled-175c-sim")
    near_section = section_text(platformio, "env:esp32-s3-touch-amoled-175c-near")

    add(
        "platformio.base.private-logo",
        "-DUSE_PRIVATE_BOOT_LOGO=1" in base_section,
        "PlatformIO base build enables the local private boot logo when present",
        PLATFORMIO,
        "-DUSE_PRIVATE_BOOT_LOGO=1",
    )
    add(
        "platformio.field.clean-ui",
        has_all(field_section, ("-DDRAGON_RADAR_DEMO_ON_BOOT=0", "-DDRAGON_RADAR_DEMO_TOUCH=0")),
        "field mode disables boot demo and center-tap demo collection",
        PLATFORMIO,
        "[env:esp32-s3-touch-amoled-175c-field]",
    )
    add(
        "platformio.fielddiag.clean-recorder",
        "extends = env:esp32-s3-touch-amoled-175c-field" in fielddiag_section
        and "-DDRAGON_RADAR_SERIAL_DIAG=1" in fielddiag_section,
        "fielddiag inherits clean field UI and adds hidden serial diagnostics",
        PLATFORMIO,
        "[env:esp32-s3-touch-amoled-175c-fielddiag]",
    )
    add(
        "platformio.debug.hud-enabled",
        has_all(debug_section, ("-DDRAGON_RADAR_DEBUG_HUD=1", "-DDRAGON_RADAR_SCAN_LINE=1", "-DDRAGON_RADAR_STAR_BLIPS=1")),
        "debug mode explicitly enables HUD, scan line, and star blips",
        PLATFORMIO,
        "[env:esp32-s3-touch-amoled-175c-debug]",
    )
    add(
        "platformio.diag.debug-with-clean-demo",
        has_all(diag_section, (
            "-DDRAGON_RADAR_DEBUG_HUD=1",
            "-DDRAGON_RADAR_SCAN_LINE=1",
            "-DDRAGON_RADAR_STAR_BLIPS=1",
            "-DDRAGON_RADAR_SERIAL_DIAG=1",
            "-DDRAGON_RADAR_DEMO_ON_BOOT=0",
            "-DDRAGON_RADAR_DEMO_TOUCH=0",
        )),
        "diag mode has debug diagnostics but no demo collection path",
        PLATFORMIO,
        "[env:esp32-s3-touch-amoled-175c-diag]",
    )
    add(
        "platformio.sim.clean-simulated-ble",
        has_all(sim_section, (
            "-DDRAGON_RADAR_SERIAL_DIAG=1",
            "-DDRAGON_RADAR_DEMO_ON_BOOT=0",
            "-DDRAGON_RADAR_DEMO_TOUCH=0",
            "-DDRAGON_RADAR_SIMULATED_BLE=1",
        )),
        "sim mode uses clean UI with deterministic simulated BLE diagnostics",
        PLATFORMIO,
        "[env:esp32-s3-touch-amoled-175c-sim]",
    )
    add(
        "platformio.near.extends-field",
        "extends = env:esp32-s3-touch-amoled-175c-field" in near_section
        and "-DDRAGON_RADAR_COLLECT_RSSI=-45" in near_section,
        "near mode keeps clean field UI and tightens collection threshold",
        PLATFORMIO,
        "[env:esp32-s3-touch-amoled-175c-near]",
    )

    base_flags = build_helper[build_helper.find("BASE_FLAGS=(") : build_helper.find("BUILD_FLAGS=", build_helper.find("BASE_FLAGS=("))]
    field_case = case_arm(build_helper, "field")
    fielddiag_case = case_arm(build_helper, "fielddiag")
    debug_case = case_arm(build_helper, "debug")
    diag_case = case_arm(build_helper, "diag")
    sim_case = case_arm(build_helper, "sim")
    near_case = case_arm(build_helper, "near")

    add(
        "build-helper.base.private-logo",
        "-DUSE_PRIVATE_BOOT_LOGO=1" in base_flags,
        "build helper base flags compile with private boot logo support",
        BUILD_HELPER,
        "BASE_FLAGS",
    )
    add(
        "build-helper.field.clean-ui",
        has_all(field_case, ("-DDRAGON_RADAR_DEMO_ON_BOOT=0", "-DDRAGON_RADAR_DEMO_TOUCH=0")),
        "field helper disables demo boot and touch collection by default",
        BUILD_HELPER,
        "field)",
    )
    add(
        "build-helper.fielddiag.clean-diagnostics",
        has_all(fielddiag_case, (
            "-DDRAGON_RADAR_SERIAL_DIAG=1",
            "-DDRAGON_RADAR_DEMO_ON_BOOT=0",
            "-DDRAGON_RADAR_DEMO_TOUCH=0",
        )),
        "fielddiag helper keeps clean UI while enabling serial diagnostics",
        BUILD_HELPER,
        "fielddiag)",
    )
    add(
        "build-helper.debug.hud-enabled",
        has_all(debug_case, ("-DDRAGON_RADAR_DEBUG_HUD=1", "-DDRAGON_RADAR_SCAN_LINE=1", "-DDRAGON_RADAR_STAR_BLIPS=1")),
        "debug helper enables the visible debug HUD features",
        BUILD_HELPER,
        "debug)",
    )
    add(
        "build-helper.diag.debug-no-demo",
        has_all(diag_case, (
            "-DDRAGON_RADAR_DEBUG_HUD=1",
            "-DDRAGON_RADAR_SCAN_LINE=1",
            "-DDRAGON_RADAR_STAR_BLIPS=1",
            "-DDRAGON_RADAR_SERIAL_DIAG=1",
            "-DDRAGON_RADAR_DEMO_ON_BOOT=0",
            "-DDRAGON_RADAR_DEMO_TOUCH=0",
        )),
        "diag helper combines debug diagnostics with no demo collection",
        BUILD_HELPER,
        "diag)",
    )
    add(
        "build-helper.sim.clean-simulated-ble",
        has_all(sim_case, (
            "-DDRAGON_RADAR_SERIAL_DIAG=1",
            "-DDRAGON_RADAR_DEMO_ON_BOOT=0",
            "-DDRAGON_RADAR_DEMO_TOUCH=0",
            "-DDRAGON_RADAR_SIMULATED_BLE=1",
        )),
        "sim helper builds a clean simulated-BLE acceptance image",
        BUILD_HELPER,
        "sim)",
    )
    add(
        "build-helper.near.clean-close-threshold",
        has_all(near_case, ("-DDRAGON_RADAR_DEMO_ON_BOOT=0", "-DDRAGON_RADAR_DEMO_TOUCH=0", "-DDRAGON_RADAR_COLLECT_RSSI=-45")),
        "near helper preserves clean UI and tightens collection threshold",
        BUILD_HELPER,
        "near)",
    )

    audit: dict[str, Any] = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "status": "failed" if failures else "passed",
        "failures": failures,
        "checks": checks,
        "sourceFiles": {
            path.relative_to(ROOT).as_posix(): {
                "size": path.stat().st_size,
                "mtime": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(path.stat().st_mtime)),
            }
            for path in (FIRMWARE, PLATFORMIO, BUILD_HELPER)
        },
    }
    return audit


def main() -> int:
    args = parse_args()
    audit = build_audit()
    if args.json:
        output = Path(args.json)
        if not output.is_absolute():
            output = ROOT / output
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(audit, indent=2) + "\n", encoding="utf-8")
    print(f"firmware-ui-contract-{audit['status']}")
    print(f"checks {len(audit['checks'])}")
    if args.json:
        print(f"json {args.json}")
    for failure in audit["failures"]:
        print(f"FAIL {failure}")
    return 0 if audit["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
