#!/usr/bin/env python3
"""Convert the official Waveshare STEP model to STL for Blender."""

from pathlib import Path

import cadquery as cq


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("/tmp/dragon-radar-board/ESP32-S3-Touch-AMOLED-1_75.stp")
OUTPUT = ROOT / "artifacts" / "blender" / "waveshare_esp32_s3_touch_amoled_175c.stl"


def main() -> None:
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    model = cq.importers.importStep(str(SOURCE))
    cq.exporters.export(
        model,
        str(OUTPUT),
        tolerance=0.035,
        angularTolerance=0.08,
    )
    print(OUTPUT)


if __name__ == "__main__":
    main()
