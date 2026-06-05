#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]


def default_release_dir() -> Path:
    if (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir():
        return ROOT
    return ROOT / "output" / "release-current"


def default_output_dir() -> Path:
    if (ROOT / "MANIFEST.md").exists() and (ROOT / "firmware").is_dir():
        return ROOT / "evidence" / "first-run"
    return ROOT / "output" / "first-run-current"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="中文首跑向导：校验发布包、检查串口，并启动 mock 或真板上板模拟。")
    parser.add_argument(
        "mode",
        nargs="?",
        choices=("check", "mock", "auto", "live", "commands"),
        default="check",
        help="check 只检查发布包和串口；mock 跑无硬件自检；auto 跑真板一块板模拟；live 跑现场一键助手；commands 打印手动命令。",
    )
    parser.add_argument("--release-dir", default=os.environ.get("RELEASE_DIR"), help="发布包目录，默认 output/release-current 或当前 release 根目录。")
    parser.add_argument("--output-dir", default=None, help="输出目录，默认 output/first-run-current 或 release/evidence/first-run。")
    parser.add_argument("--port", default=os.environ.get("RADAR_PORT"), help="雷达串口，例如 /dev/cu.usbmodem101。")
    parser.add_argument("--timeout", default=os.environ.get("FIRST_RUN_TIMEOUT", "45"), help="真板 sim 监控秒数，默认 45。")
    parser.add_argument("--mock-timeout", default=os.environ.get("FIRST_RUN_MOCK_TIMEOUT", "8"), help="mock 自检秒数，默认 8。")
    parser.add_argument("--wait-timeout", default=os.environ.get("FIRST_RUN_WAIT_TIMEOUT", "300"), help="live 模式等待串口秒数，默认 300。")
    parser.add_argument("--wait-interval", default=os.environ.get("FIRST_RUN_WAIT_INTERVAL", "2"), help="live 模式串口轮询间隔秒数，默认 2。")
    parser.add_argument("--erase", action="store_true", help="auto 模式刷机前擦除 flash。")
    parser.add_argument("--raw", action="store_true", help="auto 模式显示原始 DIAG 串口行。")
    parser.add_argument(
        "--recover-runtime",
        action="store_true",
        help="live 模式下，如果已有串口，先运行 recover_board_runtime.py 尝试自动 DTR/RTS 恢复。",
    )
    parser.add_argument("--dry-run", action="store_true", help="只打印将要运行的命令，不刷机、不写报告。")
    parser.add_argument("--require-port", action="store_true", help="check 模式下如果没有唯一 ESP32-S3 串口则返回非零。")
    parser.add_argument("--json-output", default=None, help="摘要 JSON 路径，默认 <output-dir>/first-run-summary.json。")
    parser.add_argument("--md-output", default=None, help="中文摘要 Markdown 路径，默认 <output-dir>/first-run-summary.zh.md。")
    parser.add_argument(
        "--sample-port",
        action="append",
        default=[],
        metavar="DEVICE|DESCRIPTION|HWID",
        help="使用样例串口数据，便于 dry-run/自动测试。可传多次。",
    )
    parser.add_argument(
        "--sample-usb",
        action="append",
        default=[],
        metavar="NAME|VENDOR_ID|PRODUCT_ID|SERIAL|LOCATION",
        help="使用样例 USB 设备层数据，便于 dry-run/自动测试。可传多次。",
    )
    return parser.parse_args()


def rel(path: Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return str(path)


def normalize_path(value: str | None, fallback: Path) -> Path:
    path = Path(value) if value else fallback
    return path if path.is_absolute() else ROOT / path


def tool(name: str) -> Path:
    return ROOT / "tools" / name


def packaged_tool(release_dir: Path, name: str) -> Path:
    candidate = release_dir / "tools" / name
    if candidate.exists():
        return candidate
    return tool(name)


def command_line(command: list[str]) -> str:
    return shlex.join(command)


def run_step(
    name: str,
    command: list[str],
    log_file: Path | None,
    dry_run: bool,
    allowed_return_codes: set[int] | None = None,
) -> dict[str, Any]:
    print("+ " + command_line(command), flush=True)
    allowed = allowed_return_codes or {0}
    record: dict[str, Any] = {
        "name": name,
        "command": command_line(command),
        "status": "dry-run" if dry_run else "pending",
        "returnCode": 0 if dry_run else None,
    }
    if dry_run:
        return record

    proc = subprocess.run(command, text=True, capture_output=True, check=False)
    output = proc.stdout
    if proc.stderr:
        output += ("\n" if output else "") + proc.stderr
    if log_file:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log_file.write_text(output, encoding="utf-8")
        record["logFile"] = str(log_file)
    record["returnCode"] = proc.returncode
    record["status"] = "passed" if proc.returncode in allowed else "failed"
    if proc.returncode not in allowed:
        print(output[-4000:], file=sys.stderr)
    return record


def load_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def load_ports(samples: list[str]) -> tuple[list[dict[str, Any]], str | None]:
    command = [str(tool("list_radar_ports.py")), "--json"]
    for sample in samples:
        command += ["--sample", sample]
    proc = subprocess.run(command, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        return [], proc.stderr.strip() or proc.stdout.strip() or "串口工具失败"
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return [], f"串口 JSON 无法解析: {exc}"
    ports = data.get("ports", [])
    return ports if isinstance(ports, list) else [], None


def select_port(ports: list[dict[str, Any]], explicit: str | None) -> tuple[str | None, str]:
    likely = [str(port.get("device", "")) for port in ports if int(port.get("score", 0)) >= 2]
    if explicit:
        return explicit, "explicit"
    if len(likely) == 1:
        return likely[0], "auto"
    if len(likely) > 1:
        return None, "multiple"
    return None, "none"


def project_status_text(release_dir: Path) -> str:
    candidates = [
        release_dir / "evidence" / "project-status.md",
        ROOT / "output" / "project-status.md",
    ]
    for path in candidates:
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        for line in text.splitlines():
            if line.startswith("- Hardware completion:"):
                return line.split(":", 1)[1].strip()
    return "unknown"


def print_port_table(ports: list[dict[str, Any]], error: str | None) -> None:
    print()
    print("## 串口检查")
    if error:
        print(f"串口检查失败：{error}")
        return
    if not ports:
        print("没有发现串口。请接上 ESP32-S3 主板，确认 USB 线支持数据传输，然后重试。")
        return
    print("| 状态 | 端口 | 描述 | 原因 |")
    print("| --- | --- | --- | --- |")
    for port in ports:
        score = int(port.get("score", 0))
        status = "可用候选" if score >= 2 else "跳过"
        device = str(port.get("device", ""))
        description = str(port.get("description", "n/a"))
        reason = str(port.get("reason", "n/a"))
        print(f"| {status} | `{device}` | {description} | {reason} |")


def manual_commands(port: str | None) -> str:
    radar_port = port or "/dev/cu.usbmodem101"
    lines = [
        "推荐手动顺序：",
        "",
        "```sh",
        "tools/first_run_zh.py check",
        "tools/diagnose_usb_serial.py",
        f"RADAR_PORT={radar_port} tools/recover_board_runtime.py",
        f"RADAR_PORT={radar_port} FLASH_DRY_RUN=1 tools/flash_release_firmware.sh sim",
        f"RADAR_PORT={radar_port} tools/flash_release_firmware.sh sim",
        "tools/first_run_zh.py live --recover-runtime",
        "tools/wait_for_radar_port.py --run-auto",
        "tools/selftest_release.py output/release-current",
        "tools/run_board_sim_test.py port-check",
        f"RADAR_PORT={radar_port} tools/run_board_sim_test.py auto",
        f"RADAR_PORT={radar_port} tools/verify_beacon_set.sh all",
        f"RADAR_PORT={radar_port} tools/run_release_acceptance.sh all",
        "```",
    ]
    return "\n".join(lines)


def render_markdown(summary: dict[str, Any]) -> str:
    ports = summary["ports"]
    selected = summary.get("selectedPort") or "未选择"
    lines = [
        "# 龙珠雷达首跑验收摘要",
        "",
        f"- 生成时间: {summary['generated']}",
        f"- 状态: {summary['status']}",
        f"- 发布包: `{summary['releaseDir']}`",
        f"- 输出目录: `{summary['outputDir']}`",
        f"- 硬件完成度: `{summary['hardwareCompletion']}`",
        f"- 硬件证明: `{str(summary['hardwareProof']).lower()}`",
        f"- 选中串口: `{selected}`",
    ]
    if summary.get("usbLayerStatus"):
        lines.append(f"- USB 设备层: `{summary['usbLayerStatus']}` - {summary.get('usbLayerSummary', '')}")
    lines.extend(["", "## 串口", ""])
    if summary.get("portError"):
        lines.append(f"- 串口检查失败: {summary['portError']}")
    elif not ports:
        lines.append("- 未发现串口。")
    else:
        lines.extend(["| 状态 | 端口 | 描述 | 原因 |", "| --- | --- | --- | --- |"])
        for port in ports:
            score = int(port.get("score", 0))
            status = "可用候选" if score >= 2 else "跳过"
            lines.append(
                f"| {status} | `{port.get('device', '')}` | {port.get('description', 'n/a')} | {port.get('reason', 'n/a')} |"
            )
    lines.extend(["", "## 步骤", "", "| 步骤 | 状态 | 日志 |", "| --- | --- | --- |"])
    for step in summary["steps"]:
        lines.append(f"| {step['name']} | {step['status']} | `{step.get('logFile', '')}` |")
    if summary["failures"]:
        lines.extend(["", "## 失败项", ""])
        lines.extend(f"- {failure}" for failure in summary["failures"])
    lines.extend(["", "## 下一步", ""])
    lines.extend(next_steps(summary))
    return "\n".join(lines) + "\n"


def next_steps(summary: dict[str, Any]) -> list[str]:
    if summary["hardwareProof"]:
        port = summary.get("selectedPort") or "/dev/cu.usbmodem101"
        return [
            "- 一块板模拟已经产生硬件证明。下一步制作并上电 7 个实体 `DBALL-*` 信标。",
            f"- 运行 `RADAR_PORT={port} tools/verify_beacon_set.sh all` 验证 7 个实体信标。",
            f"- 最后运行 `RADAR_PORT={port} tools/run_release_acceptance.sh all` 做完整验收。",
        ]
    if summary.get("selectedPort"):
        port = summary["selectedPort"]
        return [
            "- 已找到一个可能的 ESP32-S3 串口，可以直接跑真板一块板模拟。",
            f"- 运行 `RADAR_PORT={port} tools/first_run_zh.py auto`。",
            f"- 如果串口可见但没有 DIAG，先运行 `RADAR_PORT={port} tools/recover_board_runtime.py`，或在 live 模式加 `--recover-runtime`。",
            "- 如果只是无硬件自检，运行 `tools/first_run_zh.py mock`，但它不会改变硬件完成度。",
        ]
    return [
        "- 当前还没有唯一 ESP32-S3 串口，先接上主板并确认 USB 数据线可用。",
        "- 运行 `tools/diagnose_usb_serial.py` 生成 USB 串口诊断报告。",
        "- 如果串口可见但没有 DIAG，运行 `RADAR_PORT=/dev/cu.usbmodem101 tools/recover_board_runtime.py`。",
        "- 换线或按 BOOT/Reset 时，可以运行 `tools/first_run_zh.py live` 等串口出现后自动跑一块板模拟。",
        "- 也可以只运行 `tools/wait_for_radar_port.py --run-auto` 等串口出现。",
        "- 重新运行 `tools/first_run_zh.py check`。",
        "- 无硬件时可以运行 `tools/first_run_zh.py mock` 校验发布包和本地模拟工具。",
    ]


def write_outputs(summary: dict[str, Any], json_path: Path, md_path: Path, dry_run: bool) -> None:
    if dry_run:
        return
    json_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    md_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.write_text(render_markdown(summary), encoding="utf-8")
    print(f"摘要 JSON: {rel(json_path)}")
    print(f"中文报告: {rel(md_path)}")


def main() -> int:
    args = parse_args()
    try:
        timeout = int(args.timeout)
        mock_timeout = int(args.mock_timeout)
        wait_timeout = int(args.wait_timeout)
        wait_interval = float(args.wait_interval)
    except ValueError:
        raise SystemExit("--timeout、--mock-timeout、--wait-timeout 和 --wait-interval 必须是数字")
    if timeout < 0 or mock_timeout < 0 or wait_timeout < 0 or wait_interval < 0:
        raise SystemExit("--timeout、--mock-timeout、--wait-timeout 和 --wait-interval 必须大于等于 0")

    release_dir = normalize_path(args.release_dir, default_release_dir())
    output_dir = normalize_path(args.output_dir, default_output_dir())
    json_output = normalize_path(args.json_output, output_dir / "first-run-summary.json")
    md_output = normalize_path(args.md_output, output_dir / "first-run-summary.zh.md")
    logs_dir = output_dir / "logs"
    steps: list[dict[str, Any]] = []
    failures: list[str] = []
    usb_diagnosis: dict[str, Any] = {}
    watch_report: dict[str, Any] = {}

    if args.mode == "commands":
        print(manual_commands(args.port))
        return 0

    print("龙珠雷达中文首跑向导")
    print(f"模式：{args.mode}")
    print(f"发布包：{rel(release_dir)}")

    verifier = packaged_tool(release_dir, "verify_release_package.py")
    steps.append(run_step("发布包校验", [str(verifier), str(release_dir)], logs_dir / "verify-release-package.log", args.dry_run))

    ports, port_error = load_ports(args.sample_port)
    selected_port, port_source = select_port(ports, args.port)
    print_port_table(ports, port_error)
    if selected_port:
        print(f"选中串口：{selected_port} ({port_source})")
    elif port_source == "multiple":
        print("发现多个可能串口，请用 --port 或 RADAR_PORT 指定。")
    else:
        print("没有唯一 ESP32-S3 串口。")

    if args.mode == "mock":
        selftest = packaged_tool(release_dir, "selftest_release.py")
        mock_dir = output_dir / "release-selftest"
        steps.append(
            run_step(
                "无硬件自检",
                [str(selftest), str(release_dir), "--output-dir", str(mock_dir), "--mock-timeout", str(mock_timeout)],
                logs_dir / "release-selftest.log",
                args.dry_run,
            )
        )
    elif args.mode == "auto":
        board_sim = packaged_tool(release_dir, "run_board_sim_test.py")
        sim_dir = output_dir / "board-sim"
        command = [
            str(board_sim),
            "auto",
            "--release-dir",
            str(release_dir),
            "--output-dir",
            str(sim_dir),
            "--timeout",
            str(timeout),
        ]
        if selected_port:
            command += ["--port", selected_port]
        if args.erase:
            command.append("--erase")
        if args.raw:
            command.append("--raw")
        if args.dry_run:
            command.append("--dry-run")
        for sample in args.sample_port:
            command += ["--sample-port", sample]
        if not selected_port and not args.sample_port:
            failures.append("auto 模式需要唯一 ESP32-S3 串口")
        else:
            steps.append(run_step("真板一块板模拟", command, logs_dir / "board-sim-auto.log", args.dry_run))
    elif args.mode == "live":
        preboard_dir = output_dir / "preboard-acceptance"
        preboard = packaged_tool(release_dir, "run_preboard_acceptance.py")
        steps.append(
            run_step(
                "上板前模拟验收",
                [
                    str(preboard),
                    "--release-dir",
                    str(release_dir),
                    "--output-dir",
                    str(preboard_dir),
                    "--mock-timeout",
                    str(mock_timeout),
                ],
                logs_dir / "preboard-acceptance.log",
                args.dry_run,
            )
        )

        usb_json = output_dir / "usb-serial-diagnosis.json"
        usb_md = output_dir / "usb-serial-diagnosis.zh.md"
        diagnose = packaged_tool(release_dir, "diagnose_usb_serial.py")
        diagnose_command = [
            str(diagnose),
            "--json-output",
            str(usb_json),
            "--md-output",
            str(usb_md),
        ]
        for sample in args.sample_port:
            diagnose_command += ["--sample", sample]
        for sample in args.sample_usb:
            diagnose_command += ["--sample-usb", sample]
        steps.append(run_step("USB 串口诊断", diagnose_command, logs_dir / "usb-serial-diagnosis.log", args.dry_run))
        if not args.dry_run:
            usb_diagnosis = load_json(usb_json)

        if args.recover_runtime and selected_port:
            recover_json = output_dir / "board-runtime-recovery.json"
            recover_md = output_dir / "board-runtime-recovery.zh.md"
            recover = packaged_tool(release_dir, "recover_board_runtime.py")
            recover_command = [
                str(recover),
                "--port",
                selected_port,
                "--timeout",
                "4",
                "--json-output",
                str(recover_json),
                "--md-output",
                str(recover_md),
            ]
            steps.append(
                run_step(
                    "运行态自动恢复",
                    recover_command,
                    logs_dir / "board-runtime-recovery.log",
                    args.dry_run,
                )
            )

        watch_json = output_dir / "radar-port-watch" / "radar-port-watch.json"
        watch_md = output_dir / "radar-port-watch" / "radar-port-watch.zh.md"
        wait = packaged_tool(release_dir, "wait_for_radar_port.py")
        wait_command = [
            str(wait),
            "--timeout",
            str(wait_timeout),
            "--interval",
            str(wait_interval),
            "--run-auto",
            "--release-dir",
            str(release_dir),
            "--output-dir",
            str(output_dir / "board-sim"),
            "--json-output",
            str(watch_json),
            "--md-output",
            str(watch_md),
        ]
        if selected_port:
            wait_command += ["--sample", f"{selected_port}|explicit RADAR_PORT|manual"]
        if args.erase:
            wait_command.append("--erase")
        if args.raw:
            wait_command.append("--raw")
        if args.dry_run:
            wait_command.append("--dry-run")
        for sample in args.sample_port:
            wait_command += ["--sample", sample]
        for sample in args.sample_usb:
            wait_command += ["--sample-usb", sample]
        wait_allowed = {0, 2, 3} if not args.require_port else {0}
        wait_step = run_step("等待串口并自动一块板模拟", wait_command, logs_dir / "radar-port-watch.log", args.dry_run, wait_allowed)
        if not args.dry_run and wait_step.get("returnCode") in {2, 3}:
            wait_step["status"] = "needs-hardware"
        steps.append(wait_step)
        if not args.dry_run:
            watch_report = load_json(watch_json)
            selected_port = watch_report.get("selectedPort") or selected_port

    for step in steps:
        if step["status"] == "failed":
            failures.append(f"{step['name']} 失败")
    if port_error:
        failures.append(f"串口检查失败: {port_error}")
    if args.require_port and not selected_port:
        failures.append("没有唯一 ESP32-S3 串口")

    auto_step_passed = any(step["name"] == "真板一块板模拟" and step["status"] == "passed" for step in steps)
    live_hardware_proof = bool(watch_report.get("hardwareProof")) if watch_report else False
    hardware_proof = (
        (args.mode == "auto" and auto_step_passed and not args.dry_run)
        or (args.mode == "live" and live_hardware_proof and not args.dry_run)
    )
    if failures:
        status = "failed"
    elif args.mode in {"check", "live"} and not selected_port and not hardware_proof:
        status = "needs-hardware"
    else:
        status = "passed"

    summary: dict[str, Any] = {
        "generated": time.strftime("%Y-%m-%d %H:%M:%S"),
        "mode": args.mode,
        "status": status,
        "releaseDir": str(release_dir),
        "outputDir": str(output_dir),
        "hardwareCompletion": project_status_text(release_dir),
        "hardwareProof": hardware_proof,
        "selectedPort": selected_port,
        "usbLayerStatus": (watch_report.get("usbLayerStatus") or usb_diagnosis.get("usbLayerStatus")),
        "usbLayerSummary": (watch_report.get("usbLayerSummary") or usb_diagnosis.get("usbLayerSummary")),
        "watchStatus": watch_report.get("status"),
        "watchReport": str(output_dir / "radar-port-watch" / "radar-port-watch.json") if args.mode == "live" else "",
        "usbDiagnosis": str(output_dir / "usb-serial-diagnosis.json") if args.mode == "live" else "",
        "portSource": port_source,
        "portError": port_error,
        "ports": ports,
        "steps": steps,
        "failures": failures,
    }
    write_outputs(summary, json_output, md_output, args.dry_run)
    print()
    print(render_markdown(summary))
    if failures:
        return 2
    if args.require_port and not selected_port:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
