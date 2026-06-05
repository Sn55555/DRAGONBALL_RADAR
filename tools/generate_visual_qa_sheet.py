#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import os
import time
from pathlib import Path


FRAMES = [
    (
        "boot-grid-wake.png",
        "Boot Grid Wake",
        "Green rectangular coordinate grid wakes up inside the circular AMOLED crop; no logo yet.",
    ),
    (
        "boot-logo-scan.png",
        "Boot Logo Scan",
        "Vertical scan band reveals the private Capsule-style boot mark over the grid.",
    ),
    (
        "boot-logo-ready.png",
        "Boot Logo Ready",
        "Logo is fully staged with seven small rectangular progress ticks below it.",
    ),
    (
        "boot-handoff.png",
        "Boot Handoff",
        "Text-free acquisition sweep hands off from boot to the playable radar.",
    ),
    (
        "radar-default.png",
        "Default Radar",
        "Clean rectangular grid with orange target blips for demo review.",
    ),
    (
        "radar-field.png",
        "Field Radar",
        "Real-play field mode starts empty; no debug text, logo, or simulated target clutter.",
    ),
    (
        "radar-sim.png",
        "Sim Radar",
        "Clean field UI with deterministic simulated DBALL targets for one-board bench tests.",
    ),
    (
        "radar-debug.png",
        "Debug Radar",
        "Debug-only HUD, bearing bins, RSSI strip, scan line, and star-marked targets.",
    ),
    (
        "radar-startup-acquire.png",
        "Startup Acquire",
        "After boot, the logo hands off to a text-free rectangular acquire sweep.",
    ),
    (
        "radar-idle-search.png",
        "Idle Search",
        "Empty field mode stays alive with rectangular edge ticks and center search geometry.",
    ),
    (
        "radar-acquisition-echo.png",
        "Acquisition Echo",
        "A newly found ball appears with a square acquisition echo before the proximity lock.",
    ),
    (
        "radar-target-trail.png",
        "Target Trail",
        "A moving ball leaves short horizontal phosphor afterimages under the active blip.",
    ),
    (
        "radar-trace-blip.png",
        "Trace Blip",
        "A stale beacon fades into a weak yellow-green signal trace before disappearing.",
    ),
    (
        "radar-zoom-map.png",
        "Zoom Map",
        "Zoomed radar view uses a denser rectangular grid and scaled target positions.",
    ),
    (
        "radar-proximity-lock.png",
        "Proximity Lock",
        "A nearby uncollected ball gets a square lock frame and rectangular progress edge.",
    ),
    (
        "radar-capture-burst.png",
        "Capture Burst",
        "A collected ball flashes as a text-free square burst on the rectangular grid.",
    ),
    (
        "radar-control-flashes.png",
        "Control Flashes",
        "Zoom, reset, brightness, and audio feedback use short rectangular flashes without HUD text.",
    ),
    (
        "radar-touch-echo.png",
        "Touch Echo",
        "A tap produces a text-free square contact echo over the rectangular grid.",
    ),
    (
        "radar-tilt-inertia.png",
        "Tilt Inertia",
        "IMU-style motion feedback appears as rectangular edge ticks, not rings or labels.",
    ),
    (
        "summon-gather.png",
        "Summon Gather",
        "Collected balls travel along square grid paths toward the center.",
    ),
    (
        "summon-orbit.png",
        "Summon Orbit",
        "All seven balls pulse/orbit at the center after collection is complete.",
    ),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a visual QA contact sheet for Dragon Radar preview frames.")
    parser.add_argument("--output", default="output/visual-qa.html", help="Output HTML path.")
    parser.add_argument("--image-dir", default="output/playwright", help="Directory containing preview PNG frames.")
    parser.add_argument("--title", default="Dragon Radar Visual QA", help="Document title.")
    return parser.parse_args()


def rel_url(output: Path, image: Path) -> str:
    relative = os.path.relpath(image, output.parent)
    return Path(relative).as_posix()


def render(args: argparse.Namespace) -> str:
    output = Path(args.output)
    image_dir = Path(args.image_dir)
    generated = time.strftime("%Y-%m-%d %H:%M:%S")
    cards: list[str] = []
    missing: list[str] = []

    for filename, label, note in FRAMES:
        image = image_dir / filename
        exists = image.exists()
        if not exists:
            missing.append(filename)
        status = "PASS" if exists else "MISSING"
        status_class = "pass" if exists else "missing"
        image_markup = (
            f'<img src="{html.escape(rel_url(output, image))}" alt="{html.escape(label)}">'
            if exists
            else '<div class="placeholder">missing frame</div>'
        )
        cards.append(
            f"""
      <article class="frame">
        <div class="shot">{image_markup}</div>
        <div class="frame-copy">
          <div class="frame-head">
            <h2>{html.escape(label)}</h2>
            <span class="{status_class}">{status}</span>
          </div>
          <p>{html.escape(note)}</p>
          <code>{html.escape(filename)}</code>
        </div>
      </article>"""
        )

    overall = "PASS" if not missing else "MISSING FRAMES"
    overall_class = "pass" if not missing else "missing"
    missing_text = "None" if not missing else ", ".join(missing)

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(args.title)}</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg: #09120f;
      --panel: #101f18;
      --panel-2: #14291f;
      --ink: #e8f7e9;
      --muted: #9fbea8;
      --line: #27513b;
      --grid: #18d95a;
      --orange: #f68a1a;
      --bad: #ff6b4a;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background:
        linear-gradient(90deg, rgba(24, 217, 90, 0.08) 1px, transparent 1px),
        linear-gradient(0deg, rgba(24, 217, 90, 0.08) 1px, transparent 1px),
        var(--bg);
      background-size: 28px 28px;
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    header {{
      max-width: 1160px;
      margin: 0 auto;
      padding: 28px 18px 18px;
      display: grid;
      gap: 10px;
      border-bottom: 1px solid var(--line);
    }}
    h1 {{
      margin: 0;
      font-size: clamp(26px, 5vw, 46px);
      letter-spacing: 0;
      line-height: 1;
    }}
    .meta {{
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      color: var(--muted);
      font-size: 13px;
    }}
    .badge {{
      color: var(--ink);
      border: 1px solid var(--line);
      background: rgba(20, 41, 31, 0.9);
      padding: 5px 8px;
      border-radius: 6px;
    }}
    main {{
      max-width: 1160px;
      margin: 0 auto;
      padding: 18px;
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
      gap: 14px;
    }}
    .frame {{
      border: 1px solid var(--line);
      background: linear-gradient(180deg, rgba(20, 41, 31, 0.94), rgba(16, 31, 24, 0.94));
      border-radius: 8px;
      overflow: hidden;
      min-width: 0;
    }}
    .shot {{
      aspect-ratio: 1;
      display: grid;
      place-items: center;
      background: #05100c;
      border-bottom: 1px solid var(--line);
    }}
    img {{
      width: 100%;
      height: 100%;
      object-fit: contain;
      display: block;
      image-rendering: auto;
    }}
    .placeholder {{
      color: var(--bad);
      font: 700 13px/1 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }}
    .frame-copy {{
      padding: 12px;
      display: grid;
      gap: 8px;
    }}
    .frame-head {{
      display: flex;
      gap: 8px;
      align-items: center;
      justify-content: space-between;
    }}
    h2 {{
      margin: 0;
      font-size: 15px;
      letter-spacing: 0;
    }}
    p {{
      margin: 0;
      color: var(--muted);
      font-size: 13px;
      line-height: 1.35;
    }}
    code {{
      color: #bbffd0;
      font: 12px/1.3 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      overflow-wrap: anywhere;
    }}
    .pass, .missing {{
      border-radius: 5px;
      padding: 3px 6px;
      font: 700 11px/1 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      letter-spacing: 0;
    }}
    .pass {{
      color: #031009;
      background: var(--grid);
    }}
    .missing {{
      color: #1e0805;
      background: var(--bad);
    }}
    @media print {{
      body {{ background: #fff; color: #111; }}
      header, main {{ max-width: none; }}
      .frame {{ break-inside: avoid; background: #fff; }}
      p, .meta {{ color: #333; }}
    }}
  </style>
</head>
<body>
  <header>
    <h1>{html.escape(args.title)}</h1>
    <div class="meta">
      <span class="badge {overall_class}">Status: {overall}</span>
      <span class="badge">Generated: {html.escape(generated)}</span>
      <span class="badge">Missing: {html.escape(missing_text)}</span>
    </div>
  </header>
  <main>
{''.join(cards)}
  </main>
</body>
</html>
"""


def main() -> int:
    args = parse_args()
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(args), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
