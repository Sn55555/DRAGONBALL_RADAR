#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import os
import time
from pathlib import Path


SEQUENCES = [
    {
        "title": "Boot Animation",
        "titleZh": "开机动画",
        "intent": "Grid wake, vertical logo scan, seven rectangular ticks, and text-free handoff.",
        "intentZh": "矩形网格唤醒、竖向 Logo 扫描、七格进度 tick，以及无文字交接到雷达界面。",
        "frames": [
            ("boot-grid-wake.png", "0.18", "Grid wake", "只出现绿色矩形网格，不应提前出现蓝白 Logo。"),
            ("boot-logo-scan.png", "0.48", "Logo scan", "扫描带切过中心，蓝白胶囊风格标志开始显现。"),
            ("boot-logo-ready.png", "0.96", "Logo ready", "标志完整，下面七个小矩形 tick 清晰。"),
            ("boot-handoff.png", "1.00", "Handoff", "Logo 让位给雷达，出现无文字矩形获取扫线。"),
        ],
    },
    {
        "title": "Playable Radar Modes",
        "titleZh": "可玩雷达模式",
        "intent": "Clean field UI stays prop-like, while debug tools remain isolated.",
        "intentZh": "正式游玩界面保持道具感；调试信息只出现在 debug/diag 相关入口。",
        "frames": [
            ("radar-default.png", "demo", "Default", "矩形坐标网格和橙色 blip 可见，无同心圆雷达环。"),
            ("radar-field.png", "field", "Field", "正式 field 开局为空网格，无调试文字、无模拟目标。"),
            ("radar-sim.png", "sim", "Sim", "一块板模拟显示确定性目标，但仍保持干净 UI。"),
            ("radar-debug.png", "debug", "Debug", "调试 HUD、RSSI 条和方位分箱只在 debug 中出现。"),
            ("radar-startup-acquire.png", "startup", "Startup", "开机后雷达接管时显示矩形获取扫线，无文字、无 Logo 残留。"),
            ("radar-idle-search.png", "idle", "Idle", "空场正式模式保留矩形边缘 tick 和中心搜索框，不显示假目标或调试文字。"),
            ("radar-acquisition-echo.png", "acquire", "Acquire", "新目标出现时先显示方形 acquisition echo，不用圆环或文字提示。"),
            ("radar-target-trail.png", "trail", "Trail", "移动目标留下短横向磷光残影，强化扫描道具感。"),
            ("radar-trace-blip.png", "trace", "Trace", "信号过期后目标变成弱化 trace blip，再从雷达上消失。"),
            ("radar-zoom-map.png", "zoom", "Zoom", "缩放后网格变密、目标位置按比例放大，仍无圆环。"),
            ("radar-proximity-lock.png", "near", "Lock", "靠近目标时出现方角锁定框和矩形进度边，而不是圆环提示。"),
            ("radar-capture-burst.png", "collect", "Capture", "收集瞬间显示方形爆闪，避免文字提示和圆环特效。"),
            ("radar-control-flashes.png", "controls", "Controls", "缩放、重置、亮度、音量反馈都是短暂矩形闪烁，无 HUD 文字。"),
            ("radar-touch-echo.png", "tap", "Touch", "触摸反馈是短暂方形 echo，无文字、无圆环。"),
            ("radar-tilt-inertia.png", "tilt", "Tilt", "倾斜/晃动反馈是边缘矩形 tick，不改变雷达网格语义。"),
        ],
    },
    {
        "title": "Summon Completion",
        "titleZh": "七球完成动画",
        "intent": "Collected balls move through square-grid energy paths and gather at center.",
        "intentZh": "七颗已收集目标沿矩形网格路径汇聚到中心，进入最终脉冲状态。",
        "frames": [
            ("summon-gather.png", "0.18", "Gather", "七球开始沿横竖网格路径向中心汇聚。"),
            ("summon-orbit.png", "1.00", "Orbit", "七球在中心完成汇聚并产生绿色方格能量。"),
        ],
    },
]

MOTION_GIFS = [
    ("boot-motion.gif", "Boot motion GIF", "开机动画 GIF"),
    ("radar-motion.gif", "Radar motion GIF", "雷达游玩流程 GIF"),
    ("summon-motion.gif", "Summon motion GIF", "召唤动画 GIF"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a motion/storyboard QA page for Dragon Radar preview frames.")
    parser.add_argument("--output", default="output/motion-qa.html", help="Output HTML path.")
    parser.add_argument("--image-dir", default="output/playwright", help="Directory containing preview PNG frames.")
    parser.add_argument("--title", default="Dragon Radar Motion QA", help="Document title.")
    return parser.parse_args()


def rel_url(output: Path, image: Path) -> str:
    return Path(os.path.relpath(image, output.parent)).as_posix()


def frame_card(output: Path, image_dir: Path, frame: tuple[str, str, str, str]) -> tuple[str, bool]:
    filename, phase, label, note = frame
    image = image_dir / filename
    exists = image.exists()
    image_markup = (
        f'<img src="{html.escape(rel_url(output, image))}" alt="{html.escape(label)}">'
        if exists
        else '<div class="placeholder">missing frame</div>'
    )
    return (
        f"""
          <article class="frame">
            <div class="shot">{image_markup}</div>
            <div class="copy">
              <div class="line">
                <strong>{html.escape(label)}</strong>
                <span>{html.escape(phase)}</span>
              </div>
              <p>{html.escape(note)}</p>
              <code>{html.escape(filename)}</code>
            </div>
          </article>""",
        exists,
    )


def render(args: argparse.Namespace) -> str:
    output = Path(args.output)
    image_dir = Path(args.image_dir)
    generated = time.strftime("%Y-%m-%d %H:%M:%S")
    missing: list[str] = []
    sections: list[str] = []
    gif_cards: list[str] = []

    for filename, label, label_zh in MOTION_GIFS:
        image = image_dir / filename
        if image.exists():
            gif_cards.append(
                f"""
          <article class="frame motion">
            <div class="shot"><img src="{html.escape(rel_url(output, image))}" alt="{html.escape(label)}"></div>
            <div class="copy">
              <div class="line">
                <strong>{html.escape(label_zh)}</strong>
                <span>GIF</span>
              </div>
              <p>用于快速肉眼检查动作节奏；像素级约束仍由 PNG 视觉审计负责。</p>
              <code>{html.escape(filename)}</code>
            </div>
          </article>"""
            )

    for sequence in SEQUENCES:
        cards: list[str] = []
        for frame in sequence["frames"]:
            markup, exists = frame_card(output, image_dir, frame)
            cards.append(markup)
            if not exists:
                missing.append(frame[0])
        sections.append(
            f"""
      <section>
        <div class="section-head">
          <div>
            <h2>{html.escape(sequence["titleZh"])}</h2>
            <p>{html.escape(sequence["intentZh"])}</p>
          </div>
          <span>{html.escape(sequence["title"])}</span>
        </div>
        <div class="strip">{"".join(cards)}
        </div>
      </section>"""
        )

    status = "PASS" if not missing else "MISSING FRAMES"
    missing_text = "None" if not missing else ", ".join(missing)
    status_class = "pass" if not missing else "missing"

    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(args.title)}</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg: #07110e;
      --panel: #10221a;
      --panel2: #142e22;
      --ink: #e9f8ea;
      --muted: #a4c7ae;
      --line: #2a5a3e;
      --green: #19dc58;
      --orange: #f48b1b;
      --red: #ff654f;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background:
        linear-gradient(90deg, rgba(25, 220, 88, 0.07) 1px, transparent 1px),
        linear-gradient(0deg, rgba(25, 220, 88, 0.07) 1px, transparent 1px),
        var(--bg);
      background-size: 30px 30px;
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", sans-serif;
    }}
    header, main {{
      max-width: 1260px;
      margin: 0 auto;
      padding: 22px;
    }}
    header {{
      border-bottom: 1px solid var(--line);
      display: grid;
      gap: 10px;
    }}
    h1 {{
      margin: 0;
      font-size: clamp(30px, 5vw, 52px);
      line-height: 1;
      letter-spacing: 0;
    }}
    .meta {{
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
    }}
    .badge {{
      border: 1px solid var(--line);
      border-radius: 6px;
      padding: 6px 9px;
      background: rgba(16, 34, 26, 0.9);
      color: var(--muted);
      font-size: 13px;
    }}
    .badge.pass {{ color: #06110d; background: var(--green); border-color: var(--green); }}
    .badge.missing {{ color: #180602; background: var(--red); border-color: var(--red); }}
    main {{
      display: grid;
      gap: 18px;
    }}
    section {{
      border: 1px solid var(--line);
      border-radius: 8px;
      background: rgba(16, 34, 26, 0.94);
      overflow: hidden;
    }}
    .section-head {{
      display: flex;
      justify-content: space-between;
      gap: 14px;
      padding: 14px;
      border-bottom: 1px solid var(--line);
      background: rgba(20, 46, 34, 0.9);
    }}
    h2 {{
      margin: 0 0 5px;
      font-size: 20px;
      letter-spacing: 0;
    }}
    p {{
      margin: 0;
      color: var(--muted);
      line-height: 1.45;
      font-size: 14px;
    }}
    .section-head > span {{
      color: var(--orange);
      font: 700 12px/1.2 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      text-transform: uppercase;
      white-space: nowrap;
    }}
    .strip {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(190px, 1fr));
      gap: 1px;
      background: var(--line);
    }}
    .frame {{
      min-width: 0;
      background: var(--panel);
    }}
    .shot {{
      aspect-ratio: 1;
      display: grid;
      place-items: center;
      background: #04100b;
    }}
    img {{
      width: 100%;
      height: 100%;
      object-fit: contain;
      display: block;
    }}
    .copy {{
      padding: 10px;
      display: grid;
      gap: 7px;
    }}
    .line {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 8px;
    }}
    strong {{
      font-size: 14px;
    }}
    .line span, code {{
      color: #c9ffd7;
      font: 12px/1.35 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }}
    code {{
      color: var(--muted);
      overflow-wrap: anywhere;
    }}
    .placeholder {{
      color: var(--red);
      font: 700 13px/1 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }}
    @media print {{
      body {{ background: #fff; color: #111; }}
      section, .frame {{ background: #fff; break-inside: avoid; }}
      p, .badge, code {{ color: #333; }}
    }}
  </style>
</head>
<body>
  <header>
    <h1>Dragon Radar Motion QA</h1>
    <div class="meta">
      <span class="badge">Generated: {html.escape(generated)}</span>
      <span class="badge {status_class}">Status: {html.escape(status)}</span>
      <span class="badge">Missing: {html.escape(missing_text)}</span>
    </div>
  </header>
  <main>
    <section>
      <div class="section-head">
        <div>
          <h2>可播放动画预览</h2>
          <p>由已通过视觉审计的关键帧生成，方便快速检查开机扫描和七球完成动作。</p>
        </div>
        <span>Motion GIFs</span>
      </div>
      <div class="strip">{"".join(gif_cards) if gif_cards else '<article class="frame"><div class="shot"><div class="placeholder">motion GIFs not generated</div></div><div class="copy"><p>Run tools/generate_motion_gifs.py first.</p></div></article>'}
      </div>
    </section>
{"".join(sections)}
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
