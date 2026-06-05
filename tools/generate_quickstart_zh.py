#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import os
import time
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a Chinese quickstart page for a Dragon Radar release.")
    parser.add_argument("--release-dir", default=os.environ.get("RELEASE_DIR", "output/release-current"), help="Release folder to summarize.")
    parser.add_argument("--output", default=None, help="Output HTML path. Default: <release-dir>/docs/quickstart.zh.html")
    parser.add_argument("--radar-port", default=os.environ.get("RADAR_PORT", "/dev/cu.usbmodem101"))
    parser.add_argument("--modes", default="field fielddiag diag sim", help="Space- or comma-separated firmware modes to list.")
    return parser.parse_args()


def rel_url(output: Path, target: Path) -> str:
    return Path(os.path.relpath(target, output.parent)).as_posix()


def link(output: Path, target: Path, label: str) -> str:
    if target.exists():
        return f'<a href="{html.escape(rel_url(output, target))}">{html.escape(label)}</a>'
    return f'<span class="missing">{html.escape(label)} 缺失</span>'


def status_text(path: Path) -> str:
    if not path.exists():
        return "missing"
    text = path.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        if line.startswith("- Hardware completion:"):
            return line.split(":", 1)[1].strip()
    return "unknown"


def command(text: str) -> str:
    return f"<code>{html.escape(text)}</code>"


def file_size(path: Path) -> str:
    if not path.exists():
        return "missing"
    size = path.stat().st_size
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.1f} MB"
    if size >= 1024:
        return f"{size / 1024:.1f} KB"
    return f"{size} B"


def parse_modes(value: str) -> tuple[str, ...]:
    valid = ("field", "fielddiag", "diag", "sim", "near")
    modes = tuple(item for item in value.replace(",", " ").split() if item)
    unknown = [mode for mode in modes if mode not in valid]
    if unknown:
        raise SystemExit("unknown release mode(s): " + ", ".join(unknown))
    return modes or valid


def firmware_rows(release_dir: Path, output: Path, modes: tuple[str, ...]) -> str:
    rows = []
    labels = {
        "field": "正式游玩：干净 UI",
        "fielddiag": "正式记录：干净 UI + 隐藏串口诊断",
        "diag": "硬件诊断：带调试 HUD",
        "sim": "一块板模拟：内置 7 个模拟龙珠",
        "near": "小场地近距离：干净 UI + 更严格收集阈值",
    }
    for mode in modes:
        label = labels[mode]
        factory = release_dir / "firmware" / f"dragon-radar-{mode}-factory.bin"
        rows.append(
            "<tr>"
            f"<td>{html.escape(mode)}</td>"
            f"<td>{html.escape(label)}</td>"
            f"<td>{link(output, factory, factory.name)}</td>"
            f"<td>{html.escape(file_size(factory))}</td>"
            "</tr>"
        )
    return "\n".join(rows)


def render(args: argparse.Namespace) -> str:
    release_dir = Path(args.release_dir)
    output = Path(args.output) if args.output else release_dir / "docs" / "quickstart.zh.html"
    generated = time.strftime("%Y-%m-%d %H:%M:%S")
    project_status = release_dir / "evidence" / "project-status.md"
    hardware_status = status_text(project_status)
    hardware_class = "pass" if hardware_status == "PASS" else "warn"
    modes = parse_modes(args.modes)

    refs = {
        "总入口": release_dir / "index.html",
        "产品设计说明": release_dir / "docs" / "product-design.zh.md",
        "信标制作指南": release_dir / "docs" / "beacon-build.zh.md",
        "上板模拟指南": release_dir / "docs" / "board-sim-test.zh.md",
        "视觉验收图": release_dir / "docs" / "visual-qa.html",
        "动画验收图": release_dir / "docs" / "motion-qa.html",
        "USB 上板排障卡": release_dir / "docs" / "usb-bringup-card.zh.md",
        "上板前模拟验收": release_dir / "docs" / "preboard-acceptance.zh.md",
        "游玩现场清单": release_dir / "docs" / "field-kit.html",
        "主持人/玩家试玩卡": release_dir / "docs" / "game-cards.html",
        "信标标签": release_dir / "docs" / "beacon-labels.html",
        "项目状态": project_status,
        "Goal 完成度审计": release_dir / "docs" / "goal-completion-audit.zh.md",
        "发布清单": release_dir / "MANIFEST.md",
        "自检报告": release_dir / "RELEASE_AUDIT.json",
    }
    parity = release_dir / "evidence" / "firmware-preview-parity.json"
    if parity.exists():
        refs["固件/预览一致性审计"] = parity
    usb_diagnosis = release_dir / "evidence" / "usb-serial-diagnosis.zh.md"
    if usb_diagnosis.exists():
        refs["USB 串口诊断"] = usb_diagnosis
    playtest = release_dir / "docs" / "playtest-rehearsal.zh.md"
    if playtest.exists():
        refs["试玩演练报告"] = playtest
    tuning = release_dir / "docs" / "field-tuning-report.md"
    if tuning.exists():
        refs["开局采集阈值建议"] = tuning
    if tuning.exists():
        tuning_step = f"打开 {link(output, tuning, '开局采集阈值建议')}，先用 mock/DIAG 建议值开局，真板到手后再复校。"
    else:
        tuning_step = f"运行 {command('tools/recommend_field_tuning.py')} 生成开局采集阈值建议，真板到手后再复校。"
    ref_links = "\n".join(
        f"<li>{link(output, path, label)}</li>"
        for label, path in refs.items()
    )

    return f"""<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>龙珠雷达快速开始</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg: #06110d;
      --panel: #10241a;
      --ink: #eaf8ec;
      --muted: #a6c8ad;
      --line: #2a5b3d;
      --green: #18db58;
      --orange: #f08a19;
      --red: #ff644d;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background:
        linear-gradient(90deg, rgba(24, 219, 88, 0.07) 1px, transparent 1px),
        linear-gradient(0deg, rgba(24, 219, 88, 0.07) 1px, transparent 1px),
        var(--bg);
      background-size: 32px 32px;
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", sans-serif;
    }}
    header, main {{
      max-width: 1120px;
      margin: 0 auto;
      padding: 22px;
    }}
    header {{
      border-bottom: 1px solid var(--line);
      display: grid;
      gap: 12px;
    }}
    h1 {{
      margin: 0;
      font-size: clamp(30px, 6vw, 56px);
      letter-spacing: 0;
      line-height: 1.05;
    }}
    h2 {{
      margin: 0 0 10px;
      font-size: 20px;
      letter-spacing: 0;
    }}
    p, li {{
      color: var(--muted);
      line-height: 1.55;
    }}
    p {{ margin: 0 0 10px; }}
    main {{
      display: grid;
      gap: 16px;
    }}
    section {{
      border: 1px solid var(--line);
      border-radius: 8px;
      background: rgba(16, 36, 26, 0.94);
      padding: 16px;
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
      color: var(--muted);
      background: rgba(6, 17, 13, 0.82);
      font-size: 13px;
    }}
    .badge.pass {{ background: var(--green); color: #06110d; border-color: var(--green); }}
    .badge.warn {{ background: var(--orange); color: #160b02; border-color: var(--orange); }}
    .cols {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
      gap: 14px;
    }}
    code {{
      display: block;
      margin: 8px 0;
      padding: 10px;
      border: 1px solid #2e6d48;
      border-radius: 6px;
      background: #07150f;
      color: #d6ffe2;
      font: 13px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      font-size: 14px;
    }}
    th, td {{
      border-top: 1px solid var(--line);
      padding: 9px 8px;
      text-align: left;
      vertical-align: top;
    }}
    th {{ color: var(--muted); }}
    a {{
      color: #c7ffd7;
      text-decoration: none;
      border-bottom: 1px solid rgba(199, 255, 215, 0.35);
    }}
    a:hover {{ border-bottom-color: #c7ffd7; }}
    .missing {{ color: var(--red); font-weight: 700; }}
  </style>
</head>
<body>
  <header>
    <h1>龙珠雷达快速开始</h1>
    <div class="meta">
      <span class="badge">生成时间：{html.escape(generated)}</span>
      <span class="badge {hardware_class}">硬件完成度：{html.escape(hardware_status)}</span>
      <span class="badge">示例串口：{html.escape(args.radar_port)}</span>
    </div>
  </header>
  <main>
    <section>
      <h2>先看结论</h2>
      <p>这个包已经包含雷达固件、模拟验收、中文上板说明、视觉截图证据和现场清单。当前如果状态还是 <strong>NOT PROVEN</strong>，说明软件包通过了本地验证，但真板、7 个实体信标和真实场地还没有完成闭环。</p>
      <div class="cols">
        <div>
          <p>无硬件时先跑发布包自检：</p>
          {command("tools/first_run_zh.py mock")}
        </div>
        <div>
          <p>接上开发板后跑一块板模拟：</p>
          {command("tools/first_run_zh.py live")}
        </div>
      </div>
    </section>

    <section>
      <h2>推荐顺序</h2>
      <ol>
        <li>打开 {link(output, release_dir / "docs" / "visual-qa.html", "视觉验收图")} 和 {link(output, release_dir / "docs" / "motion-qa.html", "动画验收图")}，确认开机动画、矩形网格、召唤画面符合预期。</li>
        <li>如果串口不可见，先按 {link(output, release_dir / "docs" / "usb-bringup-card.zh.md", "USB 上板排障卡")} 换线、BOOT/Reset、等待串口。</li>
        <li>打印 {link(output, release_dir / "docs" / "game-cards.html", "主持人/玩家试玩卡")}，把藏球记录和玩家规则准备好。</li>
        <li>结束项目之前，打开 {link(output, release_dir / "docs" / "goal-completion-audit.zh.md", "Goal 完成度审计")}，确认真实硬件证明也已通过。</li>
        <li>运行 {command("tools/first_run_zh.py check")} 查看发布包状态和串口候选。</li>
        <li>如果没看到 ESP32-S3 串口，运行 {command("tools/diagnose_usb_serial.py")} 生成 USB 串口诊断报告。</li>
        <li>如果你现在无法手动 Reset，但已有串口，先运行 {command(f"RADAR_PORT={args.radar_port} tools/recover_board_runtime.py")}；如果报告显示 bootloader 可达，再用 {command(f"RADAR_PORT={args.radar_port} tools/flash_release_firmware.sh sim")} 走 esptool 自动 reset 重刷 sim。</li>
        <li>如果你想让首跑助手自动尝试恢复，运行 {command(f"RADAR_PORT={args.radar_port} tools/first_run_zh.py live --recover-runtime")}。</li>
        <li>如果串口可见但没有 DIAG 输出，运行 {command(f"RADAR_PORT={args.radar_port} tools/recover_board_runtime.py")} 尝试安全释放 DTR/RTS 和复位序列。</li>
        <li>换线或按 BOOT/Reset 时，可以运行 {command("tools/wait_for_radar_port.py --run-auto")} 等串口出现后自动跑一块板模拟。</li>
        <li>运行 {command("tools/run_preboard_acceptance.py")} 做上板前模拟验收，确认发布包、mock 一块板和七球 DIAG 回放都通过。</li>
        <li>{tuning_step}</li>
        <li>接板时运行 {command("tools/first_run_zh.py live")}，它会先做软件预检，再诊断 USB，最后等待串口并自动跑一块板模拟。</li>
        <li>运行 {command("tools/first_run_zh.py mock")} 证明发布包自身完整，但它不是硬件证明。</li>
        <li>接入 ESP32-S3 主板后运行 {command("tools/run_board_sim_test.py port-check")} 找串口。</li>
        <li>运行 {command(f"RADAR_PORT={args.radar_port} tools/first_run_zh.py auto")} 验证屏幕、触摸、IMU、BLE、音频和 7 次模拟收集。</li>
        <li>7 个实体信标准备好后运行 {command(f"RADAR_PORT={args.radar_port} tools/run_release_acceptance.sh all")} 做完整验收。</li>
      </ol>
    </section>

    <section>
      <h2>固件模式</h2>
      <table>
        <thead><tr><th>模式</th><th>用途</th><th>Factory 镜像</th><th>大小</th></tr></thead>
        <tbody>
{firmware_rows(release_dir, output, modes)}
        </tbody>
      </table>
    </section>

    <section>
      <h2>关键文件</h2>
      <ul>
{ref_links}
      </ul>
    </section>
  </main>
</body>
</html>
"""


def main() -> int:
    args = parse_args()
    output = Path(args.output) if args.output else Path(args.release_dir) / "docs" / "quickstart.zh.html"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(args), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
