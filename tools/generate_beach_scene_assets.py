#!/usr/bin/env python3
from __future__ import annotations

from collections import Counter
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SRC_DIR = ROOT / "assets" / "pixel_sprites" / "source_refs"
OUT_DIR = ROOT / "assets" / "pixel_sprites"
HEADER = ROOT / "firmware" / "DragonRadar" / "beach_scene_assets.h"

W, H = 64, 72
TILE = 5
ALPHA_THRESHOLD = 32


SPRITES = [
    {
        "id": "pixel_boy",
        "symbol": "PixelBoy",
        "source": "pixel_boy_grid.png",
        "origin": (62, 67),
        "cell": 45,
        "cols": 11,
        "rows": 12,
        "palette": {
            "outline": (22, 80, 126),
            "skin": (246, 236, 194),
            "accent": (239, 183, 188),
        },
        "classify": "boy",
    },
    {
        "id": "pixel_girl",
        "symbol": "PixelGirl",
        "source": "pixel_girl_grid.png",
        "origin": (47, 37),
        "cell": 40,
        "cols": 11,
        "rows": 14,
        "palette": {
            "outline": (40, 65, 150),
            "skin": (244, 181, 50),
            "accent": (250, 133, 92),
        },
        "classify": "girl",
    },
]


def rgb565(rgb: tuple[int, int, int]) -> int:
    r, g, b = rgb
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def center_sample(im: Image.Image, x0: int, y0: int, cell: int) -> tuple[int, int, int]:
    # Avoid grid lines and most overlaid cell-label text by sampling the tile corners
    # plus a broad center crop, then using the most common quantized color.
    rgb = im.convert("RGB")
    samples: list[tuple[int, int, int]] = []
    pads = [(9, 9), (cell - 10, 9), (9, cell - 10), (cell - 10, cell - 10)]
    for px, py in pads:
        samples.append(rgb.getpixel((x0 + px, y0 + py)))
    crop = rgb.crop((x0 + 8, y0 + 8, x0 + cell - 8, y0 + cell - 8))
    for r, g, b in crop.getdata():
        if max(r, g, b) - min(r, g, b) > 35 or max(r, g, b) < 210:
            samples.append((r, g, b))
    counts: Counter[tuple[int, int, int]] = Counter()
    for r, g, b in samples:
        counts[(r // 16 * 16, g // 16 * 16, b // 16 * 16)] += 1
    return counts.most_common(1)[0][0]


def classify_tile(rgb: tuple[int, int, int], kind: str) -> str | None:
    r, g, b = rgb
    if max(rgb) - min(rgb) < 32 and max(rgb) > 150:
        return None
    if kind == "boy":
        if b > 80 and r < 115 and g < 145:
            return "outline"
        if r > 170 and g > 155 and b > 105:
            return "skin"
        if r > 155 and b > 115 and g < 180:
            return "accent"
    else:
        if b > 80 and r < 105:
            return "outline"
        if r > 170 and g > 100 and b < 105:
            return "skin"
        if r > 190 and g > 100 and b > 65:
            return "accent"
    return None


def logical_grid(sprite: dict) -> list[list[str | None]]:
    src = Image.open(SRC_DIR / sprite["source"]).convert("RGBA")
    x0, y0 = sprite["origin"]
    cell = sprite["cell"]
    grid: list[list[str | None]] = []
    for row in range(sprite["rows"]):
        out_row: list[str | None] = []
        for col in range(sprite["cols"]):
            sample = center_sample(src, x0 + col * cell, y0 + row * cell, cell)
            out_row.append(classify_tile(sample, sprite["classify"]))
        grid.append(out_row)
    return trim_grid(grid)


def trim_grid(grid: list[list[str | None]]) -> list[list[str | None]]:
    rows = [i for i, row in enumerate(grid) if any(row)]
    cols = [i for i in range(len(grid[0])) if any(row[i] for row in grid)]
    if not rows or not cols:
        raise ValueError("sprite grid has no occupied tiles")
    return [row[min(cols) : max(cols) + 1] for row in grid[min(rows) : max(rows) + 1]]


def draw_grid_sprite(sprite: dict, grid: list[list[str | None]]) -> Image.Image:
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(im)
    grid_w = len(grid[0]) * TILE
    grid_h = len(grid) * TILE
    ox = (W - grid_w) // 2
    oy = H - grid_h - 1
    for row, values in enumerate(grid):
        for col, role in enumerate(values):
            if not role:
                continue
            color = sprite["palette"][role]
            draw.rectangle(
                (ox + col * TILE, oy + row * TILE, ox + (col + 1) * TILE - 1, oy + (row + 1) * TILE - 1),
                fill=color + (255,),
            )
    return im


def make_step_frame(im: Image.Image, direction: int) -> Image.Image:
    arr = Image.new("RGBA", im.size, (0, 0, 0, 0))
    arr.alpha_composite(im)
    px = arr.load()
    source = im.load()
    y0 = H // 2 + 4
    y1 = H - 6
    shift = direction * 3
    for y in range(y0, y1):
        for x in range(W):
            sx = x - shift
            if 0 <= sx < W:
                px[x, y] = source[sx, y]
            else:
                px[x, y] = (0, 0, 0, 0)
    return arr


def mirror(im: Image.Image) -> Image.Image:
    return im.transpose(Image.Transpose.FLIP_LEFT_RIGHT)


def collect_palette(images: Iterable[Image.Image]) -> list[int]:
    counts: Counter[int] = Counter()
    for im in images:
        for r, g, b, a in im.convert("RGBA").getdata():
            if a < ALPHA_THRESHOLD:
                continue
            counts[rgb565((r, g, b))] += 1
    palette = [0x0000]
    for color, _ in counts.most_common():
        if color not in palette:
            palette.append(color)
    return palette


def nearest_palette_index(color: tuple[int, int, int], palette: list[int]) -> int:
    r, g, b = color
    best = 1
    best_dist = 10**9
    for idx, p in enumerate(palette[1:], start=1):
        pr = ((p >> 11) & 0x1F) << 3
        pg = ((p >> 5) & 0x3F) << 2
        pb = (p & 0x1F) << 3
        d = (r - pr) * (r - pr) + (g - pg) * (g - pg) + (b - pb) * (b - pb)
        if d < best_dist:
            best = idx
            best_dist = d
    return best


def image_to_indices(im: Image.Image, palette: list[int]) -> list[int]:
    out: list[int] = []
    for r, g, b, a in im.convert("RGBA").getdata():
        out.append(0 if a < ALPHA_THRESHOLD else nearest_palette_index((r, g, b), palette))
    return out


def c_array(name: str, values: list[int], per_line: int = 20) -> str:
    lines = [f"constexpr uint8_t {name}[] PROGMEM = {{"]
    for i in range(0, len(values), per_line):
        lines.append("  " + ", ".join(str(v) for v in values[i : i + per_line]) + ",")
    lines.append("};")
    return "\n".join(lines)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    frames: dict[str, list[Image.Image]] = {}
    preview_rows: list[tuple[str, list[Image.Image]]] = []

    for sprite in SPRITES:
        base = draw_grid_sprite(sprite, logical_grid(sprite))
        right = [base, make_step_frame(base, 1)]
        left = [mirror(right[0]), mirror(right[1])]
        frames[sprite["symbol"]] = right
        preview_rows.append((sprite["id"], [*right, *left]))
        for idx, im in enumerate(right):
            im.save(OUT_DIR / f"{sprite['id']}_walk_right_{idx}.png")
        for idx, im in enumerate(left):
            im.save(OUT_DIR / f"{sprite['id']}_walk_left_{idx}.png")

    palette = collect_palette(im for imgs in frames.values() for im in imgs)
    header = [
        "#pragma once",
        "",
        "#include <Arduino.h>",
        "#include <pgmspace.h>",
        "",
        "namespace BeachSceneAssets {",
        "",
        f"constexpr uint8_t kSpriteW = {W};",
        f"constexpr uint8_t kSpriteH = {H};",
        f"constexpr uint8_t kPaletteSize = {len(palette)};",
        "",
        "constexpr uint16_t kPalette[] PROGMEM = {",
    ]
    for i in range(0, len(palette), 10):
        header.append("  " + ", ".join(f"0x{v:04X}" for v in palette[i : i + 10]) + ",")
    header.extend(["};", ""])
    for symbol, imgs in frames.items():
        for frame_idx, im in enumerate(imgs):
            header.append(c_array(f"k{symbol}Walk{frame_idx}", image_to_indices(im, palette)))
            header.append("")
    header.extend(
        [
            "struct SpriteFrames {",
            "  const uint8_t *frame0;",
            "  const uint8_t *frame1;",
            "};",
            "",
            "constexpr SpriteFrames kPixelBoy = {kPixelBoyWalk0, kPixelBoyWalk1};",
            "constexpr SpriteFrames kPixelGirl = {kPixelGirlWalk0, kPixelGirlWalk1};",
            "",
            "}  // namespace BeachSceneAssets",
            "",
        ]
    )
    HEADER.write_text("\n".join(header), encoding="utf-8")

    contact = Image.new("RGBA", (W * 4 + 30, H * 2 + 28), (96, 202, 232, 255))
    draw = ImageDraw.Draw(contact)
    draw.rectangle((0, H - 2, contact.width, contact.height), fill=(232, 196, 120, 255))
    for row, (_, imgs) in enumerate(preview_rows):
        for col, im in enumerate(imgs):
            contact.alpha_composite(im, (8 + col * (W + 6), 8 + row * (H + 8)))
    contact.save(OUT_DIR / "beach_walk_contact_sheet.png")

    preview = Image.new("RGBA", (466, 466), (0, 0, 0, 255))
    draw = ImageDraw.Draw(preview)
    draw.rectangle((18, 18, 448, 150), fill=(84, 196, 226, 255))
    draw.rectangle((18, 151, 448, 205), fill=(40, 146, 204, 255))
    draw.rectangle((18, 206, 448, 236), fill=(22, 100, 176, 255))
    draw.rectangle((18, 237, 448, 448), fill=(232, 196, 120, 255))
    draw.rectangle((76, 64, 112, 72), fill=(255, 226, 92, 255))
    draw.rectangle((84, 52, 104, 84), fill=(255, 216, 70, 255))
    draw.rectangle((68, 72, 120, 80), fill=(255, 236, 118, 255))
    for x in range(20, 466, 48):
        draw.rectangle((x, 202, x + 30, 206), fill=(230, 250, 240, 255))
        draw.rectangle((x + 12, 222, x + 50, 226), fill=(116, 205, 222, 255))
    draw.rectangle((36, 260, 56, 372), fill=(146, 92, 48, 255))
    draw.rectangle((46, 264, 54, 368), fill=(188, 124, 64, 255))
    for box, color in [
        ((22, 244, 104, 258), (18, 104, 58, 255)),
        ((56, 224, 72, 282), (28, 154, 74, 255)),
        ((50, 236, 114, 249), (28, 154, 74, 255)),
        ((12, 236, 70, 249), (28, 154, 74, 255)),
        ((28, 218, 86, 229), (28, 154, 74, 255)),
        ((74, 250, 122, 261), (18, 104, 58, 255)),
        ((16, 252, 62, 262), (18, 104, 58, 255)),
    ]:
        draw.rectangle(box, fill=color)
    draw.rectangle((332, 286, 340, 368), fill=(104, 76, 46, 255))
    draw.rectangle((286, 278, 386, 290), fill=(230, 72, 66, 255))
    draw.rectangle((298, 266, 374, 278), fill=(255, 238, 176, 255))
    draw.rectangle((314, 254, 358, 266), fill=(230, 72, 66, 255))
    draw.rectangle((324, 242, 346, 254), fill=(255, 238, 176, 255))
    draw.rectangle((286, 374, 358, 402), fill=(62, 116, 216, 255))
    draw.rectangle((294, 382, 350, 386), fill=(112, 184, 246, 255))
    draw.rectangle((294, 394, 350, 398), fill=(112, 184, 246, 255))
    for x, y, color in [
        (70, 410, (246, 118, 82, 255)),
        (142, 402, (118, 112, 106, 255)),
        (370, 380, (118, 112, 106, 255)),
        (224, 318, (248, 218, 146, 255)),
    ]:
        draw.rectangle((x, y, x + 22, y + 8), fill=color)
    preview.alpha_composite(frames["PixelBoy"][0], (96, 338))
    preview.alpha_composite(frames["PixelGirl"][1], (246, 350))
    preview.save(OUT_DIR / "beach_scene_preview.png")
    print(f"generated {HEADER}")
    print(f"generated previews in {OUT_DIR}")


if __name__ == "__main__":
    main()
