#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import os
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate printable Dragon Radar host and player cards.")
    parser.add_argument("--output", default="output/game-cards.html", help="Output HTML path.")
    parser.add_argument("--release-dir", default="output/release-current", help="Release folder used for links and commands.")
    parser.add_argument("--radar-port", default=os.environ.get("RADAR_PORT", "/dev/cu.usbmodem101"))
    parser.add_argument("--area", default=os.environ.get("FIELD_AREA", ""))
    parser.add_argument("--players", default=os.environ.get("FIELD_PLAYERS", ""), help="Optional comma-separated player names.")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def release_modes(release_dir: Path) -> tuple[str, ...]:
    audit = load_json(release_dir / "RELEASE_AUDIT.json")
    modes = audit.get("expectedModes")
    if isinstance(modes, list) and all(isinstance(item, str) for item in modes):
        return tuple(modes)
    return ("field", "fielddiag", "diag", "sim")


def hardware_status(release_dir: Path) -> str:
    status = release_dir / "evidence/project-status.md"
    if not status.exists():
        return "UNKNOWN"
    for line in status.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("- Hardware completion:"):
            return line.split(":", 1)[1].strip()
    return "UNKNOWN"


def usb_summary(release_dir: Path) -> str:
    report = load_json(release_dir / "evidence/usb-serial-diagnosis.json")
    return str(report.get("summary") or report.get("status") or "missing")


def playable_mode(modes: tuple[str, ...]) -> str:
    return "near" if modes == ("near",) else "field"


def player_names(raw: str) -> list[str]:
    names = [name.strip() for name in raw.split(",") if name.strip()]
    while len(names) < 4:
        names.append("________________")
    return names[:8]


def card(title: str, body: str, classes: str = "") -> str:
    class_attr = f' class="card {classes}"' if classes else ' class="card"'
    return f"""
      <section{class_attr}>
        <h2>{html.escape(title)}</h2>
{body}
      </section>"""


def checklist(items: list[str]) -> str:
    return "\n".join(f'          <li><span class="box"></span><span>{item}</span></li>' for item in items)


def command(text: str) -> str:
    return f"<code>{html.escape(text)}</code>"


def dball_cards() -> str:
    blocks = []
    for index in range(1, 8):
        blocks.append(
            f"""
      <section class="ball-card">
        <div class="ball-id">DBALL-{index}</div>
        <div class="ball-core">{index}</div>
        <p>藏点</p>
        <div class="write-line"></div>
        <p>线索</p>
        <div class="write-line"></div>
        <p>找到时间</p>
        <div class="write-line"></div>
      </section>"""
        )
    return "\n".join(blocks)


def player_table(players: list[str]) -> str:
    rows = []
    for index, name in enumerate(players, start=1):
        rows.append(
            "<tr>"
            f"<td>{index}</td>"
            f"<td>{html.escape(name)}</td>"
            '<td><span class="write-line small-line"></span></td>'
            '<td><span class="write-line small-line"></span></td>'
            "</tr>"
        )
    return "\n".join(rows)


def rel_link(output: Path, target: Path, label: str) -> str:
    if target.exists():
        relative = os.path.relpath(target, output.parent)
        return f'<a href="{html.escape(Path(relative).as_posix())}">{html.escape(label)}</a>'
    return f'<span class="missing">{html.escape(label)} 缺失</span>'


def render(args: argparse.Namespace) -> str:
    output = Path(args.output)
    release_dir = Path(args.release_dir)
    if not output.is_absolute():
        output = ROOT / output
    if not release_dir.is_absolute():
        release_dir = ROOT / release_dir
    modes = release_modes(release_dir)
    mode = playable_mode(modes)
    generated = time.strftime("%Y-%m-%d %H:%M:%S")
    area = args.area or "________________"
    players = player_names(args.players)
    hardware = hardware_status(release_dir)
    usb = usb_summary(release_dir)
    port = args.radar_port

    host = card(
        "主持人开局卡",
        f"""
        <ul>
{checklist([
            "确认 7 个 DBALL 信标已充电、贴号、上电。",
            "打开视觉验收和 UI 还原度报告，确认开机和雷达界面没有跑偏。",
            "先做发布包自检，再找串口；没有真板时只能当 mock 演练。",
            "刷正式游玩固件后，把电脑放旁边记录，不要把 debug HUD 给玩家看。",
            "七颗都找到并进入召唤动画后，才算本轮完成。",
        ])}
        </ul>
        {command("tools/selftest_release.py")}
        {command("tools/first_run_zh.py check")}
        {command(f"RADAR_PORT={port} tools/flash_release_firmware.sh {mode}")}
        {command(f"RADAR_PORT={port} tools/run_release_acceptance.sh all")}
        """,
        "host",
    )

    player = card(
        "玩家规则卡",
        f"""
        <ol>
          <li>只能看雷达屏幕和主持人给的起点，不看藏点表。</li>
          <li>拿稳雷达，慢慢转身；橙色光点越稳定，方向越可信。</li>
          <li>靠近目标时保持几秒，等待收集反馈；不要疯狂摇晃。</li>
          <li>找到一个 DBALL 后交给主持人记录，再继续找下一个。</li>
          <li>七颗全部收集后，看召唤动画完成本轮。</li>
        </ol>
        <p class="note">场地：{html.escape(area)}</p>
        """,
        "player",
    )

    proof = card(
        "验收边界卡",
        f"""
        <ul>
{checklist([
            f"硬件完成度当前状态：{hardware}",
            f"USB 串口诊断：{usb}",
            "mock 自检只能证明发布包和软件流程，不能证明真板完成。",
            "真正完成需要真板屏幕、触摸、IMU、BLE、音频、7 个实体信标和真实 field/near 记录全通过。",
        ])}
        </ul>
        <p>{rel_link(output, release_dir / "docs/fidelity-review.zh.md", "UI 还原度评审")}</p>
        <p>{rel_link(output, release_dir / "docs/visual-qa.html", "视觉验收图")}</p>
        <p>{rel_link(output, release_dir / "docs/motion-qa.html", "动画验收图")}</p>
        """,
        "proof",
    )

    players_card = card(
        "玩家记录卡",
        f"""
        <table>
          <thead><tr><th>#</th><th>玩家</th><th>用时</th><th>找到数</th></tr></thead>
          <tbody>
{player_table(players)}
          </tbody>
        </table>
        """,
        "players",
    )

    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>龙珠雷达试玩卡</title>
  <style>
    :root {{
      color-scheme: light;
      --ink: #102017;
      --muted: #526458;
      --line: #b8cabd;
      --panel: #ffffff;
      --green: #168b4b;
      --grid: #dcebe0;
      --orange: #ef8a17;
      --red: #d83f2b;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      padding: 12mm;
      background: #edf2ec;
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", sans-serif;
      font-size: 9pt;
    }}
    header {{
      display: grid;
      gap: 2mm;
      margin-bottom: 5mm;
      border-bottom: 0.5mm solid var(--green);
      padding-bottom: 3mm;
    }}
    h1 {{
      margin: 0;
      font-size: 23pt;
      line-height: 1;
      letter-spacing: 0;
    }}
    h2 {{
      margin: 0 0 3mm;
      font-size: 13pt;
      letter-spacing: 0;
    }}
    p {{
      margin: 2mm 0;
      color: var(--muted);
      line-height: 1.35;
    }}
    a {{
      color: #064b28;
      text-decoration: none;
      border-bottom: 0.25mm solid rgba(6, 75, 40, 0.35);
    }}
    .missing {{ color: var(--red); font-weight: 700; }}
    .deck {{
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 4mm;
    }}
    .card, .ball-card {{
      break-inside: avoid;
      min-height: 70mm;
      border: 0.3mm solid var(--line);
      border-radius: 2mm;
      background:
        linear-gradient(90deg, rgba(22, 139, 75, 0.08) 1px, transparent 1px),
        linear-gradient(0deg, rgba(22, 139, 75, 0.08) 1px, transparent 1px),
        var(--panel);
      background-size: 7mm 7mm;
      padding: 4mm;
    }}
    .host {{ border-left: 1.6mm solid var(--green); }}
    .player {{ border-left: 1.6mm solid var(--orange); }}
    .proof {{ border-left: 1.6mm solid var(--red); }}
    ul, ol {{
      margin: 0;
      padding-left: 0;
    }}
    ol {{ padding-left: 5mm; }}
    li {{
      margin: 1.8mm 0;
      line-height: 1.28;
    }}
    ul li {{
      list-style: none;
      display: grid;
      grid-template-columns: 4.5mm 1fr;
      gap: 2mm;
      align-items: start;
    }}
    .box {{
      width: 3.6mm;
      height: 3.6mm;
      border: 0.3mm solid #536d5b;
      background: #fff;
      display: inline-block;
    }}
    code {{
      display: block;
      margin: 1.5mm 0;
      padding: 2mm;
      border: 0.25mm solid #bfd5c5;
      border-radius: 1.4mm;
      background: #f7fbf8;
      color: #073b24;
      font: 7.2pt/1.35 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      background: rgba(255, 255, 255, 0.84);
    }}
    th, td {{
      border: 0.25mm solid var(--line);
      padding: 2mm;
      text-align: left;
    }}
    th {{
      color: #173c27;
      background: #e5f2e8;
      font-size: 7.5pt;
    }}
    .write-line {{
      display: block;
      height: 7mm;
      border-bottom: 0.3mm solid #8aa093;
    }}
    .small-line {{
      height: 4mm;
    }}
    .ball-grid {{
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 4mm;
      margin-top: 5mm;
    }}
    .ball-card {{
      min-height: 55mm;
      position: relative;
    }}
    .ball-id {{
      font-weight: 800;
      color: #173c27;
    }}
    .ball-core {{
      position: absolute;
      right: 4mm;
      top: 4mm;
      width: 15mm;
      height: 15mm;
      border-radius: 50%;
      display: grid;
      place-items: center;
      border: 0.4mm solid #9d4a00;
      background: radial-gradient(circle at 35% 28%, #ffe3a3, #f28b20 60%, #c45f0c);
      color: #401b00;
      font-size: 17pt;
      font-weight: 800;
    }}
    .meta {{
      color: var(--muted);
      display: flex;
      flex-wrap: wrap;
      gap: 5mm;
    }}
    @media print {{
      body {{ background: #fff; padding: 9mm; }}
      .card, .ball-card {{ background-color: #fff; }}
    }}
  </style>
</head>
<body>
  <header>
    <h1>龙珠雷达试玩卡</h1>
    <div class="meta">
      <span>生成：{html.escape(generated)}</span>
      <span>场地：{html.escape(area)}</span>
      <span>模式：{html.escape(mode)}</span>
      <span>硬件：{html.escape(hardware)}</span>
    </div>
  </header>
  <main>
    <div class="deck">
{host}
{player}
{proof}
{players_card}
    </div>
    <div class="ball-grid">
{dball_cards()}
    </div>
  </main>
</body>
</html>
"""


def main() -> int:
    args = parse_args()
    output = Path(args.output)
    if not output.is_absolute():
        output = ROOT / output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(args), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
