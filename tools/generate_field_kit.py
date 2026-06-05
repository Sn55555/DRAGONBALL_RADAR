#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import os
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a printable Dragon Radar field setup kit.")
    parser.add_argument("--output", default=os.environ.get("FIELD_KIT_OUTPUT", "output/field-kit.html"), help="Output HTML path.")
    parser.add_argument("--radar-port", default=os.environ.get("RADAR_PORT", "/dev/cu.usbmodem101"), help="Expected radar serial port.")
    parser.add_argument("--release-dir", default=os.environ.get("RELEASE_DIR", "output/release-current"), help="Release folder used for factory images.")
    parser.add_argument("--players", default=os.environ.get("FIELD_PLAYERS", ""), help="Optional comma-separated player names.")
    parser.add_argument("--area", default=os.environ.get("FIELD_AREA", ""), help="Optional play area name.")
    parser.add_argument("--profile", default=os.environ.get("BEACON_PROFILE", "balanced"), help="Beacon profile label.")
    parser.add_argument("--collect-rssi", default=os.environ.get("COLLECT_RSSI", "-50"), help="Collection RSSI threshold shown on the sheet.")
    parser.add_argument("--hold-ms", default=os.environ.get("COLLECT_HOLD_MS", "1200"), help="Collection hold time shown on the sheet.")
    return parser.parse_args()


def command(text: str) -> str:
    return f"<code>{html.escape(text)}</code>"


def checklist(items: list[str]) -> str:
    return "\n".join(f'<li><span class="box"></span>{item}</li>' for item in items)


def beacon_rows() -> str:
    rows = []
    for index in range(1, 8):
        rows.append(
            "<tr>"
            f"<td>DBALL-{index}</td>"
            '<td><span class="box"></span> flashed</td>'
            '<td><span class="box"></span> verified</td>'
            '<td><span class="box"></span> hidden</td>'
            '<td><span class="line"></span></td>'
            '<td><span class="box"></span> found</td>'
            "</tr>"
        )
    return "\n".join(rows)


def player_rows(players: str) -> str:
    names = [name.strip() for name in players.split(",") if name.strip()]
    while len(names) < 4:
        names.append("")
    rows = []
    for idx, name in enumerate(names[:8], start=1):
        rows.append(
            "<tr>"
            f"<td>{idx}</td>"
            f"<td>{html.escape(name)}</td>"
            '<td><span class="line"></span></td>'
            '<td><span class="line"></span></td>'
            '<td><span class="line"></span></td>'
            "</tr>"
        )
    return "\n".join(rows)


def render(args: argparse.Namespace) -> str:
    generated = time.strftime("%Y-%m-%d %H:%M:%S")
    radar_port = html.escape(args.radar_port)
    release_dir = html.escape(args.release_dir)
    area = html.escape(args.area or "________________")
    profile = html.escape(args.profile)
    collect_rssi = html.escape(args.collect_rssi)
    hold_ms = html.escape(args.hold_ms)

    smoke_cmd = f"RADAR_PORT={args.radar_port} tools/smoke_release_board.sh all"
    board_sim_cmd = f"RADAR_PORT={args.radar_port} tools/run_board_sim_test.py auto"
    acceptance_cmd = f"RADAR_PORT={args.radar_port} tools/run_release_acceptance.sh all"
    field_cmd = f"RADAR_PORT={args.radar_port} tools/flash_release_firmware.sh field"
    hunt_cmd = (
        "HUNT_MIN_COLLECTIONS=7 HUNT_REQUIRE_COLLECTION_SET=1 HUNT_REQUIRE_SUMMON=1 "
        f"RADAR_PORT={args.radar_port} tools/record_field_hunt.sh monitor"
    )

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Dragon Radar Field Kit</title>
  <style>
    :root {{
      color-scheme: light;
      --ink: #102018;
      --muted: #52635a;
      --grid: #8fc99d;
      --panel: #ffffff;
      --orange: #e97f16;
      --green: #1b8b4c;
      --line: #b6c8ba;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      padding: 14mm;
      background: #edf1ec;
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      font-size: 9pt;
    }}
    header {{
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 8mm;
      align-items: end;
      margin-bottom: 6mm;
      border-bottom: 0.4mm solid var(--green);
      padding-bottom: 4mm;
    }}
    h1 {{
      margin: 0;
      font-size: 22pt;
      letter-spacing: 0;
      line-height: 1;
    }}
    h2 {{
      margin: 0 0 3mm;
      font-size: 12pt;
      letter-spacing: 0;
    }}
    p {{
      margin: 0 0 2mm;
      color: var(--muted);
    }}
    code {{
      display: block;
      margin: 1.5mm 0;
      padding: 2mm;
      border: 0.25mm solid #bdd3c3;
      border-radius: 1.5mm;
      background: #f7fbf8;
      color: #073b24;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 7.2pt;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }}
    .meta {{
      min-width: 60mm;
      border: 0.3mm solid var(--line);
      padding: 3mm;
      background: var(--panel);
    }}
    .grid {{
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 5mm;
    }}
    section {{
      break-inside: avoid;
      border: 0.3mm solid var(--line);
      border-radius: 2mm;
      background:
        linear-gradient(90deg, rgba(27, 139, 76, 0.07) 1px, transparent 1px),
        linear-gradient(0deg, rgba(27, 139, 76, 0.07) 1px, transparent 1px),
        var(--panel);
      background-size: 8mm 8mm;
      padding: 4mm;
      margin-bottom: 5mm;
    }}
    ul {{
      list-style: none;
      margin: 0;
      padding: 0;
    }}
    li {{
      display: grid;
      grid-template-columns: 5mm 1fr;
      gap: 2mm;
      align-items: start;
      margin: 2mm 0;
      line-height: 1.25;
    }}
    .box {{
      display: inline-block;
      width: 3.8mm;
      height: 3.8mm;
      border: 0.3mm solid #51705b;
      background: #fff;
      vertical-align: -0.8mm;
    }}
    .line {{
      display: inline-block;
      width: 100%;
      min-width: 18mm;
      border-bottom: 0.3mm solid #8ca394;
      height: 4mm;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      background: rgba(255, 255, 255, 0.85);
    }}
    th, td {{
      border: 0.25mm solid var(--line);
      padding: 1.8mm;
      text-align: left;
      vertical-align: middle;
    }}
    th {{
      color: #173c27;
      background: #e5f2e8;
      font-size: 7.6pt;
      text-transform: uppercase;
    }}
    .pass {{
      border-left: 1.5mm solid var(--orange);
    }}
    .small {{
      font-size: 7.5pt;
    }}
    @media print {{
      body {{ background: #fff; padding: 10mm; }}
      section, .meta {{ box-shadow: none; }}
    }}
  </style>
</head>
<body>
  <header>
    <div>
      <h1>Dragon Radar Field Kit</h1>
      <p>One-page setup, smoke test, and game-day record for the ESP32-S3 AMOLED radar.</p>
    </div>
    <div class="meta">
      <p><strong>Generated:</strong> {generated}</p>
      <p><strong>Area:</strong> {area}</p>
      <p><strong>Radar port:</strong> {radar_port}</p>
      <p><strong>Release:</strong> {release_dir}</p>
      <p><strong>Beacon profile:</strong> {profile}</p>
      <p><strong>Collect:</strong> {collect_rssi} dBm for {hold_ms} ms</p>
    </div>
  </header>

  <main class="grid">
    <div>
      <section>
        <h2>Preflight</h2>
        <ul>
          {checklist([
              "Charge radar board and all seven beacon batteries.",
              "Find the ESP32-S3 serial port with tools/list_radar_ports.py --shell.",
              "Confirm only one ESP32-S3 radar is connected before flashing.",
              "Open output/release-current/MANIFEST.md and confirm field, fielddiag, diag, and sim are packaged.",
              "Print beacon labels and attach one DBALL number to each enclosure.",
              "Keep the private boot logo source off shared packages; binaries already include the local artwork.",
          ])}
        </ul>
      </section>

      <section>
        <h2>Fast Board Smoke</h2>
        <p>Use the packaged sim image before hiding beacons.</p>
        {command(board_sim_cmd)}
        {command(smoke_cmd)}
        <ul>
          {checklist([
              "Board boots to the green grid and logo sequence.",
              "Touch, IMU, BLE, and audio report online.",
              "Seven simulated DBALL targets are collected.",
              "Final summon state appears in the report.",
          ])}
        </ul>
      </section>

      <section>
        <h2>Full Acceptance</h2>
        {command(acceptance_cmd)}
        <p class="small">Completion is proven only when output/project-status.md says Hardware completion: PASS.</p>
        <ul class="pass">
          {checklist([
              "Hardware bring-up report passed.",
              "One-board sim report passed.",
              "Seven physical beacons visible.",
              "Clean field hunt has seven collection events.",
              "Clean field hunt records summon=yes.",
          ])}
        </ul>
      </section>

      <section>
        <h2>Real Play Flash</h2>
        {command(field_cmd)}
        <p>Use fielddiag instead when you want hidden serial recording with the clean UI.</p>
        {command("RADAR_PORT=" + args.radar_port + " tools/flash_release_firmware.sh fielddiag")}
      </section>
    </div>

    <div>
      <section>
        <h2>Beacon Tracking</h2>
        <table>
          <thead>
            <tr><th>Beacon</th><th>Flash</th><th>Verify</th><th>Hide</th><th>Location</th><th>Found</th></tr>
          </thead>
          <tbody>
            {beacon_rows()}
          </tbody>
        </table>
      </section>

      <section>
        <h2>Strict Hunt Record</h2>
        {command(hunt_cmd)}
        <table>
          <thead>
            <tr><th>#</th><th>Player</th><th>Start</th><th>Finish</th><th>Notes</th></tr>
          </thead>
          <tbody>
            {player_rows(args.players)}
          </tbody>
        </table>
      </section>

      <section>
        <h2>Failure Notes</h2>
        <ul>
          {checklist([
              "No DIAG lines: confirm sim/diag/fielddiag firmware is flashed and USB CDC is visible.",
              "Touch offline: reseat board, check shared reset line, rerun bring-up.",
              "BLE offline or no DBALL: power-cycle beacons, reduce distance, avoid phone BLE clutter.",
              "Collections too early or late: run calibration and regenerate COLLECT_RSSI recommendation.",
              "Audio distorted: lower AUDIO_GAIN and rebuild field firmware.",
          ])}
        </ul>
      </section>
    </div>
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
