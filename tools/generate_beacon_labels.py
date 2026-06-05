#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import os
import time
from pathlib import Path


PROFILES = {
    "fast": (60, 120),
    "balanced": (100, 200),
    "battery": (400, 900),
}

STAR_POINTS = {
    1: [(50, 50)],
    2: [(38, 42), (62, 58)],
    3: [(50, 32), (36, 60), (64, 60)],
    4: [(36, 36), (64, 36), (36, 64), (64, 64)],
    5: [(50, 28), (30, 44), (70, 44), (38, 68), (62, 68)],
    6: [(36, 30), (64, 30), (30, 50), (70, 50), (36, 70), (64, 70)],
    7: [(50, 24), (32, 36), (68, 36), (28, 58), (50, 54), (72, 58), (50, 76)],
}


def parse_args() -> argparse.Namespace:
    default_profile = os.environ.get("BEACON_PROFILE", "balanced")
    parser = argparse.ArgumentParser(description="Generate printable DBALL beacon labels as a static HTML sheet.")
    parser.add_argument("--output", default=os.environ.get("BEACON_LABELS_OUTPUT", "output/beacon-labels.html"), help="Output HTML path.")
    parser.add_argument("--profile", default=default_profile, help="Beacon advertising profile: fast, balanced, or battery.")
    parser.add_argument("--adv-min-ms", type=int, default=env_int("BEACON_ADV_MIN_MS"), help="Advertising minimum interval override.")
    parser.add_argument("--adv-max-ms", type=int, default=env_int("BEACON_ADV_MAX_MS"), help="Advertising maximum interval override.")
    parser.add_argument("--board", default=os.environ.get("BEACON_BOARD", "esp32-s3-devkitc1-n8r8"), help="Beacon board identifier.")
    parser.add_argument("--title", default="Dragon Ball Beacon Set", help="Printable sheet title.")
    return parser.parse_args()


def env_int(name: str) -> int | None:
    value = os.environ.get(name)
    if value in (None, ""):
        return None
    try:
        return int(value)
    except ValueError as exc:
        raise SystemExit(f"{name} must be an integer, got: {value}") from exc


def validate_intervals(min_ms: int, max_ms: int) -> None:
    if min_ms < 20 or max_ms < min_ms or max_ms > 10240:
        raise SystemExit("advertising interval must satisfy 20 <= min <= max <= 10240 ms")


def star_spans(index: int) -> str:
    spans = []
    for left, top in STAR_POINTS[index]:
        spans.append(f'<span style="left:{left}%;top:{top}%"></span>')
    return "".join(spans)


def label_card(index: int, profile: str, adv_min: int, adv_max: int, board: str) -> str:
    return f"""
      <article class="label">
        <div class="topline">
          <div class="ball" aria-label="DBALL-{index} star marker">{star_spans(index)}</div>
          <div>
            <h2>DBALL-{index}</h2>
            <p>BLE name: DBALL-{index}</p>
          </div>
        </div>
        <dl>
          <div><dt>Board</dt><dd>{html.escape(board)}</dd></div>
          <div><dt>Profile</dt><dd>{html.escape(profile)}</dd></div>
          <div><dt>Advertise</dt><dd>{adv_min}-{adv_max} ms</dd></div>
        </dl>
        <div class="checks">
          <span>flashed</span>
          <span>verified</span>
          <span>hidden</span>
          <span>found</span>
        </div>
      </article>
    """


def render(args: argparse.Namespace) -> str:
    if args.profile not in PROFILES:
        raise SystemExit("profile must be fast, balanced, or battery")
    default_min, default_max = PROFILES[args.profile]
    adv_min = args.adv_min_ms if args.adv_min_ms is not None else default_min
    adv_max = args.adv_max_ms if args.adv_max_ms is not None else default_max
    validate_intervals(adv_min, adv_max)
    generated = time.strftime("%Y-%m-%d %H:%M:%S")
    cards = "\n".join(label_card(i, args.profile, adv_min, adv_max, args.board) for i in range(1, 8))
    title = html.escape(args.title)
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <style>
    :root {{
      color-scheme: light;
      --ink: #102018;
      --muted: #52635a;
      --grid: #9ed8aa;
      --orange: #f28b17;
      --orange-dark: #b6530d;
      --star: #a01110;
      --paper: #ffffff;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      padding: 18mm;
      background: #ecefe9;
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    header {{
      display: flex;
      justify-content: space-between;
      align-items: end;
      gap: 12px;
      margin-bottom: 8mm;
    }}
    h1 {{
      margin: 0;
      font-size: 18pt;
      font-weight: 800;
      letter-spacing: 0;
    }}
    header p {{
      margin: 2px 0 0;
      color: var(--muted);
      font-size: 8pt;
    }}
    .sheet {{
      display: grid;
      grid-template-columns: repeat(2, minmax(72mm, 1fr));
      gap: 5mm;
    }}
    .label {{
      min-height: 45mm;
      padding: 5mm;
      border: 0.35mm dashed #64866f;
      border-radius: 2mm;
      background:
        linear-gradient(90deg, rgba(20, 150, 75, 0.09) 1px, transparent 1px),
        linear-gradient(0deg, rgba(20, 150, 75, 0.09) 1px, transparent 1px),
        var(--paper);
      background-size: 8mm 8mm;
      break-inside: avoid;
    }}
    .topline {{
      display: grid;
      grid-template-columns: 19mm 1fr;
      align-items: center;
      gap: 4mm;
    }}
    .ball {{
      position: relative;
      width: 18mm;
      height: 18mm;
      border-radius: 50%;
      background: radial-gradient(circle at 36% 28%, #ffd482 0 18%, var(--orange) 42%, var(--orange-dark) 100%);
      border: 0.45mm solid #7a2e08;
      box-shadow: inset -1.2mm -1.2mm 2mm rgba(78, 20, 0, 0.38);
    }}
    .ball span {{
      position: absolute;
      width: 2.2mm;
      height: 2.2mm;
      margin: -1.1mm 0 0 -1.1mm;
      border-radius: 50%;
      background: var(--star);
    }}
    h2 {{
      margin: 0;
      font-size: 17pt;
      font-weight: 900;
      letter-spacing: 0;
    }}
    .topline p {{
      margin: 1mm 0 0;
      color: var(--muted);
      font-size: 8pt;
    }}
    dl {{
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 2mm 4mm;
      margin: 4mm 0 0;
      font-size: 7.5pt;
    }}
    dl div {{ min-width: 0; }}
    dt {{
      color: var(--muted);
      font-size: 6.7pt;
      text-transform: uppercase;
    }}
    dd {{
      margin: 0.5mm 0 0;
      font-weight: 700;
      overflow-wrap: anywhere;
    }}
    .checks {{
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 2mm;
      margin-top: 4mm;
      color: var(--muted);
      font-size: 6.8pt;
    }}
    .checks span::before {{
      content: "";
      display: inline-block;
      width: 2.6mm;
      height: 2.6mm;
      margin-right: 1mm;
      border: 0.25mm solid var(--muted);
      vertical-align: -0.5mm;
      background: #fff;
    }}
    @media print {{
      body {{ padding: 10mm; background: white; }}
      header {{ margin-bottom: 5mm; }}
      .label {{ box-shadow: none; }}
    }}
  </style>
</head>
<body>
  <header>
    <div>
      <h1>{title}</h1>
      <p>Print, cut, and tape one label to each beacon enclosure or battery lead.</p>
    </div>
    <p>Generated {generated}</p>
  </header>
  <main class="sheet">
{cards}
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
