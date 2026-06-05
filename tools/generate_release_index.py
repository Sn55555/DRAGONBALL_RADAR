#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import os
import time
from pathlib import Path


DEFAULT_MODES = ("field", "fielddiag", "diag", "sim")
VALID_MODES = DEFAULT_MODES + ("near",)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate the top-level Dragon Radar release index page.")
    parser.add_argument("--release-dir", default="output/release-current", help="Release folder to summarize.")
    parser.add_argument("--output", default=None, help="Output HTML path. Default: <release-dir>/index.html")
    parser.add_argument("--radar-port", default=os.environ.get("RADAR_PORT", "/dev/cu.usbmodem101"))
    parser.add_argument("--modes", default=" ".join(DEFAULT_MODES), help="Space- or comma-separated firmware modes to list.")
    return parser.parse_args()


def rel_url(output: Path, target: Path) -> str:
    return Path(os.path.relpath(target, output.parent)).as_posix()


def file_size(path: Path) -> str:
    if not path.exists():
        return "missing"
    size = path.stat().st_size
    if size >= 1024 * 1024:
        return f"{size / (1024 * 1024):.1f} MB"
    if size >= 1024:
        return f"{size / 1024:.1f} KB"
    return f"{size} B"


def link(output: Path, target: Path, label: str) -> str:
    if target.exists():
        return f'<a href="{html.escape(rel_url(output, target))}">{html.escape(label)}</a>'
    return f'<span class="missing">{html.escape(label)} missing</span>'


def parse_modes(value: str) -> tuple[str, ...]:
    modes = tuple(item for item in value.replace(",", " ").split() if item)
    unknown = [mode for mode in modes if mode not in VALID_MODES]
    if unknown:
        raise SystemExit("unknown release mode(s): " + ", ".join(unknown))
    return modes or DEFAULT_MODES


def firmware_rows(release_dir: Path, output: Path, modes: tuple[str, ...]) -> str:
    rows: list[str] = []
    for mode in modes:
        factory = release_dir / "firmware" / f"dragon-radar-{mode}-factory.bin"
        rows.append(
            "<tr>"
            f"<td>{html.escape(mode)}</td>"
            f"<td>{link(output, factory, factory.name)}</td>"
            f"<td>{html.escape(file_size(factory))}</td>"
            f"<td><code>RADAR_PORT={html.escape(args_port_placeholder())} tools/flash_release_firmware.sh {html.escape(mode)}</code></td>"
            "</tr>"
        )
    return "\n".join(rows)


def args_port_placeholder() -> str:
    return "${RADAR_PORT:-/dev/cu.usbmodem101}"


def status_text(path: Path) -> str:
    if not path.exists():
        return "missing"
    text = path.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        if line.startswith("- Hardware completion:"):
            return line.split(":", 1)[1].strip()
    return "unknown"


def render(args: argparse.Namespace) -> str:
    release_dir = Path(args.release_dir)
    output = Path(args.output) if args.output else release_dir / "index.html"
    generated = time.strftime("%Y-%m-%d %H:%M:%S")
    project_status = release_dir / "evidence" / "project-status.md"
    hardware_status = status_text(project_status)
    hardware_class = "pass" if hardware_status == "PASS" else "warn"
    modes = parse_modes(args.modes)

    docs = {
        "中文快速开始": release_dir / "docs" / "quickstart.zh.html",
        "产品设计说明": release_dir / "docs" / "product-design.zh.md",
        "信标制作指南": release_dir / "docs" / "beacon-build.zh.md",
        "Visual QA": release_dir / "docs" / "visual-qa.html",
        "Motion QA": release_dir / "docs" / "motion-qa.html",
        "UI 还原度评审": release_dir / "docs" / "fidelity-review.zh.md",
        "Visual Audit": release_dir / "evidence" / "preview-visual-audit.json",
        "Visual Audit Markdown": release_dir / "evidence" / "preview-visual-audit.md",
        "Firmware UI Contract": release_dir / "evidence" / "firmware-ui-contract.json",
        "USB Serial Diagnosis": release_dir / "evidence" / "usb-serial-diagnosis.zh.md",
        "USB Bring-up Card": release_dir / "docs" / "usb-bringup-card.zh.md",
        "刷新率排障卡": release_dir / "docs" / "refresh-performance-card.zh.md",
        "无 Reset 显示检查": release_dir / "docs" / "no-reset-display-check.zh.md",
        "实拍屏幕 QA 样本": release_dir / "docs" / "board-photo-qa-sample.zh.md",
        "硬件证明包": release_dir / "docs" / "hardware-proof-packet.zh.md",
        "待收口硬件 Gate 计划": release_dir / "docs" / "missing-hardware-gates-plan.zh.md",
        "Field Kit": release_dir / "docs" / "field-kit.html",
        "Host/Player Cards": release_dir / "docs" / "game-cards.html",
        "Playtest Rehearsal": release_dir / "docs" / "playtest-rehearsal.zh.md",
        "Field Tuning": release_dir / "docs" / "field-tuning-report.md",
        "Pre-board Acceptance": release_dir / "docs" / "preboard-acceptance.zh.md",
        "上板模拟指南": release_dir / "docs" / "board-sim-test.zh.md",
        "Beacon Labels": release_dir / "docs" / "beacon-labels.html",
        "README": release_dir / "docs" / "README.md",
        "Manifest": release_dir / "MANIFEST.md",
        "Project Status": project_status,
        "Goal Completion Audit": release_dir / "docs" / "goal-completion-audit.zh.md",
        "Audit": release_dir / "RELEASE_AUDIT.json",
        "Checksums": release_dir / "CHECKSUMS.sha256",
    }
    parity = release_dir / "evidence" / "firmware-preview-parity.json"
    if parity.exists():
        docs["Firmware/Preview Parity"] = parity

    doc_cards = "\n".join(
        f"""
        <article class="card">
          <h2>{html.escape(label)}</h2>
          <p>{description(label)}</p>
          <div>{link(output, path, label)}</div>
        </article>"""
        for label, path in docs.items()
    )

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Dragon Radar Release</title>
  <style>
    :root {{
      color-scheme: dark;
      --bg: #07120f;
      --panel: #10231a;
      --panel-2: #122b20;
      --ink: #e9f8e9;
      --muted: #9bc0a6;
      --line: #2b5b3f;
      --green: #17dc58;
      --orange: #f38b1c;
      --red: #ff6348;
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background:
        linear-gradient(90deg, rgba(23, 220, 88, 0.07) 1px, transparent 1px),
        linear-gradient(0deg, rgba(23, 220, 88, 0.07) 1px, transparent 1px),
        var(--bg);
      background-size: 30px 30px;
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    header, main {{
      max-width: 1180px;
      margin: 0 auto;
      padding: 22px;
    }}
    header {{
      display: grid;
      gap: 12px;
      border-bottom: 1px solid var(--line);
    }}
    h1 {{
      margin: 0;
      font-size: clamp(32px, 6vw, 58px);
      letter-spacing: 0;
      line-height: 1;
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
      background: rgba(16, 35, 26, 0.88);
      color: var(--muted);
      font-size: 13px;
    }}
    .badge.pass {{ color: #07120f; background: var(--green); border-color: var(--green); }}
    .badge.warn {{ color: #160b02; background: var(--orange); border-color: var(--orange); }}
    main {{
      display: grid;
      gap: 18px;
    }}
    .grid {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(230px, 1fr));
      gap: 12px;
    }}
    .card, .panel {{
      border: 1px solid var(--line);
      border-radius: 8px;
      background: linear-gradient(180deg, rgba(18, 43, 32, 0.95), rgba(16, 35, 26, 0.95));
    }}
    .card {{
      padding: 14px;
      display: grid;
      gap: 10px;
      align-content: start;
    }}
    .panel {{
      overflow: hidden;
    }}
    .panel h2, .card h2 {{
      margin: 0;
      font-size: 17px;
      letter-spacing: 0;
    }}
    .panel h2 {{
      padding: 14px 14px 0;
    }}
    p {{
      margin: 0;
      color: var(--muted);
      line-height: 1.4;
      font-size: 14px;
    }}
    a {{
      color: #bbffd1;
      text-decoration: none;
      border-bottom: 1px solid rgba(187, 255, 209, 0.35);
    }}
    a:hover {{ border-bottom-color: #bbffd1; }}
    .missing {{
      color: var(--red);
      font-weight: 700;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      margin-top: 10px;
      font-size: 13px;
    }}
    th, td {{
      border-top: 1px solid var(--line);
      padding: 9px 10px;
      text-align: left;
      vertical-align: top;
    }}
    th {{
      color: var(--muted);
      font-size: 12px;
      text-transform: uppercase;
    }}
    code {{
      color: #d3fbe0;
      font: 12px/1.35 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      overflow-wrap: anywhere;
    }}
    .commands {{
      display: grid;
      gap: 8px;
      padding: 14px;
    }}
    @media print {{
      body {{ background: #fff; color: #111; }}
      .card, .panel {{ break-inside: avoid; background: #fff; }}
      p, .badge, th {{ color: #333; }}
    }}
  </style>
</head>
<body>
  <header>
    <h1>Dragon Radar Release</h1>
    <div class="meta">
      <span class="badge">Generated: {html.escape(generated)}</span>
      <span class="badge {hardware_class}">Hardware completion: {html.escape(hardware_status)}</span>
      <span class="badge">Radar port example: {html.escape(args.radar_port)}</span>
    </div>
  </header>
  <main>
    <section class="grid">
{doc_cards}
    </section>

    <section class="panel">
      <h2>Factory Firmware</h2>
      <table>
        <thead><tr><th>Mode</th><th>Factory Image</th><th>Size</th><th>Flash Command</th></tr></thead>
        <tbody>
{firmware_rows(release_dir, output, modes)}
        </tbody>
      </table>
    </section>

    <section class="panel">
      <h2>Acceptance Commands</h2>
      <div class="commands">
        <code>tools/list_radar_ports.py --shell</code>
        <code>tools/first_run_zh.py check</code>
        <code>tools/first_run_zh.py live</code>
        <code>tools/first_run_zh.py mock</code>
        <code>tools/run_preboard_acceptance.py</code>
        <code>tools/selftest_release.py</code>
        <code>tools/run_board_sim_test.py port-check</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/send_diag_command.py turbo</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/send_diag_command.py frame</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/run_no_reset_display_check.py --command turbo</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/run_no_reset_display_check.py --passive</code>
        <code>tools/analyze_board_photo.py /path/to/board-photo.png</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/monitor_diag.py --timeout 12</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/first_run_zh.py auto</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/run_board_sim_test.py auto</code>
        <code>RELEASE_ACCEPTANCE_MOCK=1 tools/run_release_acceptance.sh all</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/smoke_release_board.sh all</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/run_missing_hardware_gates.py --execute</code>
        <code>RADAR_PORT={html.escape(args.radar_port)} tools/run_release_acceptance.sh all</code>
      </div>
    </section>
  </main>
</body>
</html>
"""


def description(label: str) -> str:
    return {
        "中文快速开始": "中文步骤：先看状态、自检发布包、上板模拟、再做完整验收。",
        "产品设计说明": "中文产品方案、无 GPS 可行性、BLE 信标玩法、创新点和风险。",
        "信标制作指南": "中文步骤：制作 7 个 DBALL BLE 信标、烧录、贴标签、摆放和验收。",
        "Visual QA": "Contact sheet for boot, radar, and summon frames.",
        "Motion QA": "Storyboard review for boot reveal, playable modes, and summon completion.",
        "UI 还原度评审": "中文还原度评审：胶囊开机、矩形网格、无圆环、召唤动画和一致性证据。",
        "Visual Audit": "Machine-readable pixel thresholds and ring-coverage checks.",
        "Visual Audit Markdown": "Human-readable pixel audit summary with key UI metrics.",
        "Firmware UI Contract": "Static source audit for rectangular-grid UI and clean field modes.",
        "Firmware/Preview Parity": "Cross-checks firmware and browser preview timing, grid, controls, and mode semantics.",
        "USB Serial Diagnosis": "Current machine serial-port diagnosis and next actions before flashing.",
        "USB Bring-up Card": "Chinese checklist for cable, BOOT/Reset, port waiting, and first hardware proof.",
        "刷新率排障卡": "中文刷新率和屏闪排障：turbo/frame 命令、drawAvg/drawMax、overBudget 和无手动 Reset 路径。",
        "无 Reset 显示检查": "中文报告：不刷机、不手动 Reset，用 DIAG 采样或 turbo 命令确认刷新状态。",
        "实拍屏幕 QA 样本": "中文照片/视频帧 QA：识别矩形网格、橙色目标点、屏幕区域和条纹风险。",
        "硬件证明包": "中文收口报告：汇总 release、bring-up、sim bench、照片 QA、7 信标和 field hunt 缺口。",
        "待收口硬件 Gate 计划": "中文 dry-run 计划：只针对剩余的 7 信标和真实 field hunt gate，追加 --execute 才触碰硬件。",
        "Field Kit": "Printable setup sheet for game-day checks and player records.",
        "Host/Player Cards": "Printable host flow, player rules, DBALL hiding cards, and proof boundary card.",
        "Playtest Rehearsal": "Chinese pre-play rehearsal report using mock collection flow, UI audits, and USB status.",
        "Field Tuning": "Starting COLLECT_RSSI and hold-time recommendation from current DIAG evidence, marked with its proof boundary.",
        "Pre-board Acceptance": "No-hardware acceptance report for release structure, mock board flow, DIAG replay, and proof boundary.",
        "上板模拟指南": "中文步骤：找串口、刷 sim 固件、看报告、区分 mock 与硬件证明。",
        "Beacon Labels": "Printable DBALL labels for the seven physical beacons.",
        "README": "Full build, flash, tuning, and acceptance documentation.",
        "Manifest": "Packaged firmware, evidence, tools, and proof gates.",
        "Project Status": "Current software evidence and remaining hardware gates.",
        "Goal Completion Audit": "Requirement-by-requirement audit for whether the full goal can be ended.",
        "Audit": "Machine-readable release verification record.",
        "Checksums": "SHA256 checksums for packaged files.",
    }.get(label, "")


def main() -> int:
    args = parse_args()
    output = Path(args.output) if args.output else Path(args.release_dir) / "index.html"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render(args), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
