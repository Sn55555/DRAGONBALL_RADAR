#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


SEQUENCES = {
    "boot-motion.gif": [
        ("boot-grid-wake.png", 360),
        ("boot-logo-scan.png", 440),
        ("boot-logo-ready.png", 520),
        ("boot-handoff.png", 420),
    ],
    "radar-motion.gif": [
        ("radar-startup-acquire.png", 360),
        ("radar-idle-search.png", 420),
        ("radar-acquisition-echo.png", 360),
        ("radar-target-trail.png", 360),
        ("radar-proximity-lock.png", 420),
        ("radar-capture-burst.png", 360),
        ("radar-control-flashes.png", 420),
    ],
    "summon-motion.gif": [
        ("summon-gather.png", 520),
        ("summon-orbit.png", 760),
        ("summon-gather.png", 420),
        ("summon-orbit.png", 760),
    ],
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build lightweight GIF motion previews from verified Dragon Radar keyframes.")
    parser.add_argument("--image-dir", default="output/playwright", help="Directory containing verified PNG keyframes.")
    parser.add_argument("--output-dir", default="output/motion", help="Directory for generated GIFs.")
    parser.add_argument("--max-size", type=int, default=466, help="Maximum GIF frame width/height in pixels.")
    return parser.parse_args()


def load_frame(path: Path, max_size: int) -> Image.Image:
    if not path.exists():
        raise SystemExit(f"missing frame: {path}")
    image = Image.open(path).convert("RGB")
    if max(image.size) > max_size:
        image.thumbnail((max_size, max_size), Image.Resampling.LANCZOS)
    return image


def write_gif(image_dir: Path, output: Path, frames: list[tuple[str, int]], max_size: int) -> None:
    images = [load_frame(image_dir / filename, max_size) for filename, _ in frames]
    durations = [duration for _, duration in frames]
    output.parent.mkdir(parents=True, exist_ok=True)
    images[0].save(
        output,
        format="GIF",
        save_all=True,
        append_images=images[1:],
        duration=durations,
        loop=0,
        optimize=False,
        disposal=2,
    )
    print(output)


def main() -> int:
    args = parse_args()
    image_dir = Path(args.image_dir)
    output_dir = Path(args.output_dir)
    for filename, frames in SEQUENCES.items():
        write_gif(image_dir, output_dir / filename, frames, args.max_size)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
