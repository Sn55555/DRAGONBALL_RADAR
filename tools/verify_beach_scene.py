#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
SPRITE_DIR = ROOT / "assets" / "pixel_sprites"
INO = ROOT / "firmware" / "DragonRadar" / "DragonRadar.ino"
PLATFORMIO = ROOT / "platformio.ini"
BUILD_SCRIPT = ROOT / "tools" / "build_radar.sh"
HEADER = ROOT / "firmware" / "DragonRadar" / "beach_scene_assets.h"


def fail(msg: str, details: dict | None = None) -> None:
    payload = {"status": "failed", "error": msg}
    if details:
        payload["details"] = details
    print(json.dumps(payload, ensure_ascii=False, indent=2))
    raise SystemExit(1)


def require(condition: bool, msg: str, details: dict | None = None) -> None:
    if not condition:
        fail(msg, details)


def read_text(path: Path) -> str:
    require(path.exists(), f"missing {path}")
    return path.read_text(encoding="utf-8")


def extract_int(pattern: str, text: str, name: str) -> int:
    match = re.search(pattern, text)
    require(match is not None, f"missing {name}")
    return int(match.group(1))


def verify_sprite(path: Path) -> dict:
    require(path.exists(), f"missing sprite {path}")
    im = Image.open(path).convert("RGBA")
    require(im.size == (64, 72), f"sprite has wrong size: {path}", {"size": im.size})
    pixels = list(im.getdata())
    opaque = sum(1 for *_, a in pixels if a >= 32)
    transparent = sum(1 for *_, a in pixels if a < 32)
    require(opaque > 100, f"sprite appears empty: {path}", {"opaque": opaque})
    require(transparent > 1200, f"sprite is not cleanly transparent: {path}", {"transparent": transparent})
    colors = {tuple(rgb) for *rgb, a in pixels if a >= 32}
    require(len(colors) >= 2, f"sprite has too few colors: {path}", {"colors": len(colors)})
    return {"path": str(path.relative_to(ROOT)), "opaque": opaque, "transparent": transparent, "colors": len(colors)}


def main() -> None:
    ino = read_text(INO)
    platformio = read_text(PLATFORMIO)
    build_script = read_text(BUILD_SCRIPT)
    header = read_text(HEADER)

    expected = [
        "pixel_boy_walk_right_0.png",
        "pixel_boy_walk_right_1.png",
        "pixel_boy_walk_left_0.png",
        "pixel_boy_walk_left_1.png",
        "pixel_girl_walk_right_0.png",
        "pixel_girl_walk_right_1.png",
        "pixel_girl_walk_left_0.png",
        "pixel_girl_walk_left_1.png",
    ]
    sprites = [verify_sprite(SPRITE_DIR / name) for name in expected]
    for name in ("beach_walk_contact_sheet.png", "beach_scene_preview.png"):
        require((SPRITE_DIR / name).exists(), f"missing preview {name}")

    safe_min = extract_int(r"kSafeMinX\s*=\s*(\d+)", ino, "kSafeMinX")
    safe_max_margin = extract_int(
        r"kSafeMaxX\s*=\s*kScreenW\s*-\s*BeachSceneAssets::kSpriteW\s*-\s*(\d+)",
        ino,
        "kSafeMaxX margin",
    )
    min_gap = extract_int(r"kMinGap\s*=\s*(\d+)", ino, "kMinGap")
    sprite_w = extract_int(r"kSpriteW\s*=\s*(\d+)", header, "kSpriteW")
    sprite_h = extract_int(r"kSpriteH\s*=\s*(\d+)", header, "kSpriteH")
    screen_w = 466
    safe_max = screen_w - sprite_w - safe_max_margin

    require(sprite_w == 64 and sprite_h == 72, "unexpected firmware sprite dimensions")
    require(safe_min >= 80, "left safety margin is too small", {"safeMin": safe_min})
    require(screen_w - (safe_max + sprite_w) >= 80, "right safety margin is too small", {"safeMax": safe_max})
    require(min_gap > sprite_w + 36, "minimum walker gap can still look overlapped",
            {"minGap": min_gap, "spriteW": sprite_w})
    require(safe_max - safe_min >= min_gap, "safe range cannot hold two separated walkers",
            {"safeMin": safe_min, "safeMax": safe_max, "minGap": min_gap})
    require("handleBeachSwipeGesture" in ino and "touchStartX" in ino,
            "touch swipe path is not wired")
    require("drawBeachScene();" in ino and "DRAGON_RADAR_BEACH_SCENE" in ino,
            "beach scene draw mode is not wired")
    require("esp32-s3-touch-amoled-175c-beach" in platformio,
            "platformio beach environment is missing")
    require("-DDRAGON_RADAR_AUDIO_GAIN=180" in platformio,
            "platformio beach audio gain is not 180")
    require("-DDRAGON_RADAR_SERIAL_DIAG=1" in platformio,
            "platformio beach serial diagnostics are not enabled")
    require("-DDRAGON_RADAR_AUDIO_GAIN=180" in build_script,
            "build helper beach audio gain is not 180")
    require("-DDRAGON_RADAR_SERIAL_DIAG=1" in build_script,
            "build helper beach serial diagnostics are not enabled")

    print(json.dumps({
        "status": "passed",
        "sprites": sprites,
        "safeBounds": {
            "safeMinX": safe_min,
            "safeMaxX": safe_max,
            "rightMargin": screen_w - (safe_max + sprite_w),
            "minGap": min_gap,
        },
        "audioGain": 180,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
