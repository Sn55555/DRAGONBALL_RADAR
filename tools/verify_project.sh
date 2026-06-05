#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/verify_project.sh [quick|firmware|full]

Modes:
  quick     Script syntax, diagnostic simulator, preview JavaScript, screenshots, visual checks.
  firmware  quick + field/debug/diag/sim radar firmware builds.
  full      firmware + all seven BLE beacon builds.

Environment:
  PIO_BIN   PlatformIO executable. If omitted, the script checks PATH and a
            common macOS user install location.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

MODE="${1:-quick}"
case "$MODE" in
  quick|firmware|full)
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

find_pio() {
  if [[ -n "${PIO_BIN:-}" ]]; then
    printf '%s\n' "$PIO_BIN"
  elif command -v pio >/dev/null 2>&1; then
    command -v pio
  elif [[ -x "$HOME/Library/Python/3.11/bin/pio" ]]; then
    printf '%s\n' "$HOME/Library/Python/3.11/bin/pio"
  else
    printf '%s\n' "pio"
  fi
}

log_step() {
  printf '\n==> %s\n' "$1"
}

log_step "Checking shell script syntax"
bash -n \
  tools/build_radar.sh \
  tools/flash_release_firmware.sh \
  tools/smoke_release_board.sh \
  tools/build_beacons.sh \
  tools/upload_beacon.sh \
  tools/flash_beacon_set.sh \
  tools/verify_beacon_set.sh \
  tools/record_field_hunt.sh \
  tools/run_hardware_acceptance.sh \
  tools/bringup_diag.sh \
  tools/bench_sim.sh \
  tools/replay_diag_log.sh \
  tools/package_release.sh \
  tools/run_release_acceptance.sh \
  tools/capture_preview_screenshots.sh \
  tools/smoke_preview_interactions.sh \
  tools/verify_project.sh

log_step "Checking Python verifier syntax"
python3 -m py_compile tools/verify_preview_visuals.py tools/verify_firmware_ui_contract.py tools/verify_ui_parity.py tools/verify_private_boot_logo.py tools/install_private_boot_logo.py tools/run_board_sim_test.py tools/run_preboard_acceptance.py tools/selftest_release.py tools/first_run_zh.py tools/monitor_diag.py tools/simulate_diag_feed.py tools/render_bench_report.py tools/render_hunt_report.py tools/render_goal_completion_audit.py tools/render_hardware_proof_packet.py tools/run_missing_hardware_gates.py tools/render_project_status.py tools/render_playtest_rehearsal.py tools/generate_beacon_labels.py tools/generate_field_kit.py tools/generate_play_cards.py tools/generate_quickstart_zh.py tools/generate_visual_qa_sheet.py tools/generate_motion_gifs.py tools/verify_motion_gifs.py tools/generate_motion_qa_sheet.py tools/generate_release_index.py tools/generate_fidelity_review.py tools/generate_usb_bringup_card.py tools/generate_refresh_perf_card.py tools/list_radar_ports.py tools/wait_for_radar_port.py tools/diagnose_usb_serial.py tools/diagnose_board_runtime.py tools/recover_board_runtime.py tools/run_no_reset_display_check.py tools/analyze_board_photo.py tools/verify_release_package.py tools/recommend_field_tuning.py tools/send_diag_command.py

log_step "Checking firmware UI contract"
rm -f output/firmware-ui-contract.json
tools/verify_firmware_ui_contract.py --json output/firmware-ui-contract.json
python3 - <<'PY'
import json
from pathlib import Path
audit = json.loads(Path("output/firmware-ui-contract.json").read_text())
assert audit["status"] == "passed"
assert len(audit["checks"]) >= 40
names = {item["name"] for item in audit["checks"]}
for required in (
    "radar.grid.no-ring-drawcircle",
    "radar.grid.debug-title-gated",
    "status.clean-mode-early-return",
    "status.clean-mode-control-flashes",
    "targets.acquisition-echo.square-grid",
    "targets.orb-bloom.scanline-bars",
    "boot.private-logo-hook",
    "platformio.field.clean-ui",
    "build-helper.sim.clean-simulated-ble",
):
    assert required in names
PY
echo "firmware-ui-contract-ok"

log_step "Checking firmware and preview UI parity"
rm -f output/firmware-preview-parity.json
tools/verify_ui_parity.py --json output/firmware-preview-parity.json
python3 - <<'PY'
import json
from pathlib import Path
audit = json.loads(Path("output/firmware-preview-parity.json").read_text())
assert audit["status"] == "passed"
assert len(audit["checks"]) >= 20
names = {item["name"] for item in audit["checks"]}
for required in (
    "constant.boot.duration",
    "array.grid.pitch",
    "array.map.scale",
    "grid.no-concentric-rings-both-surfaces",
    "boot.logo-staged-both-surfaces",
    "startup.acquire-overlay-both-surfaces",
    "controls.flash-overlays-both-surfaces",
    "targets.acquisition-echo-both-surfaces",
    "targets.orb-phosphor-bloom-both-surfaces",
    "mode.sim.parity",
):
    assert required in names
PY
echo "firmware-preview-parity-ok"

log_step "Checking private Capsule-style boot logo chain"
rm -f output/private-boot-logo-audit.json output/private-boot-logo-audit.md output/private-boot-logo-setup.json output/private-boot-logo-setup.md
tools/install_private_boot_logo.py status --json-output output/private-boot-logo-setup.json --md-output output/private-boot-logo-setup.md
private_logo_install_dry_run="$(tools/install_private_boot_logo.py install-example --dry-run)"
if [[ "$private_logo_install_dry_run" != *"PRIVATE_BOOT_LOGO_SETUP passed"* ]]; then
  echo "expected private boot logo install dry-run to pass" >&2
  exit 1
fi
tools/verify_private_boot_logo.py --release-dir output/release-current --json output/private-boot-logo-audit.json --md output/private-boot-logo-audit.md
python3 - <<'PY'
import json
from pathlib import Path
audit = json.loads(Path("output/private-boot-logo-audit.json").read_text())
setup = json.loads(Path("output/private-boot-logo-setup.json").read_text())
assert audit["status"] == "passed"
assert len(audit["checks"]) >= 11
summary = audit["summary"]
assert summary["localPrivateSource"] == "present"
assert summary["privateSourceIgnored"] is True
assert summary["buildFlagEnabled"] is True
assert summary["installerPresent"] is True
assert summary["releasePrivateSourceLeaked"] is False
names = {item["name"] for item in audit["checks"]}
for required in (
    "local.private-logo-source-present",
    "local.private-logo-rich-mark",
    "local.private-logo-ignored",
    "firmware.private-logo-hook",
    "build.private-logo-enabled",
    "local.private-logo-installer",
    "release.private-source-not-copied",
    "release.firmware-logo-text-present",
):
    assert required in names
setup_summary = setup["summary"]
assert setup["status"] == "passed"
assert setup_summary["privateSourceExists"] is True
assert setup_summary["privateSourceIgnored"] is True
assert setup_summary["safeToShare"] is True
assert setup_summary["installCommand"] == "tools/install_private_boot_logo.py install-example"
assert len(setup["checks"]) >= 5
markdown = Path("output/private-boot-logo-audit.md").read_text()
assert "Dragon Radar Private Boot Logo Audit" in markdown
assert "local.private-logo-rich-mark" in markdown
setup_markdown = Path("output/private-boot-logo-setup.md").read_text()
assert "Dragon Radar Private Boot Logo Setup" in setup_markdown
assert "This report intentionally omits the private boot-logo source contents" in setup_markdown
PY
echo "private-boot-logo-ok"

log_step "Checking radar serial port helper"
port_helper_output="$(
  tools/list_radar_ports.py \
    --sample '/dev/cu.Bluetooth-Incoming-Port|Bluetooth Incoming Port|n/a' \
    --sample '/dev/cu.usbmodem101|USB JTAG/serial debug unit|USB VID:PID=303A:1001' \
    --shell
)"
if [[ "$port_helper_output" != *"export RADAR_PORT=/dev/cu.usbmodem101"* ]]; then
  echo "expected radar port helper to select the ESP32-S3 USB modem port" >&2
  exit 1
fi
port_helper_json="$(
  tools/list_radar_ports.py \
    --sample '/dev/cu.usbmodem101|USB JTAG/serial debug unit|USB VID:PID=303A:1001' \
    --json
)"
if [[ "$port_helper_json" != *'"/dev/cu.usbmodem101"'* ]]; then
  echo "expected radar port helper JSON to include the sample ESP32-S3 port" >&2
  exit 1
fi
echo "radar-port-helper-ok"

log_step "Checking radar port wait helper"
rm -f output/radar-port-watch-test.json output/radar-port-watch-test.zh.md output/radar-port-watch-none.json output/radar-port-watch-none.zh.md
tools/wait_for_radar_port.py \
  --timeout 0 \
  --interval 0 \
  --sample '/dev/cu.usbmodem101|USB JTAG/serial debug unit|USB VID:PID=303A:1001' \
  --sample-usb 'USB JTAG/serial debug unit|0x303a|0x1001|RADARTEST|0x00100000' \
  --json-output output/radar-port-watch-test.json \
  --md-output output/radar-port-watch-test.zh.md >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
report = json.loads(Path("output/radar-port-watch-test.json").read_text())
assert report["status"] == "ready"
assert report["selectedPort"] == "/dev/cu.usbmodem101"
assert report["hardwareProof"] is False
assert report["usbLayerStatus"] == "radar-usb-present"
assert report["attemptLog"][0]["usbLayerStatus"] == "radar-usb-present"
markdown = Path("output/radar-port-watch-test.zh.md").read_text()
assert "龙珠雷达串口等待报告" in markdown
assert "/dev/cu.usbmodem101" in markdown
assert "USB 设备层" in markdown
PY
if tools/wait_for_radar_port.py \
  --timeout 0 \
  --interval 0 \
  --sample '/dev/cu.Bluetooth-Incoming-Port|Bluetooth Incoming Port|n/a' \
  --sample-usb 'USB JTAG/serial debug unit|0x303a|0x1001|RADARTEST|0x00100000' \
  --json-output output/radar-port-watch-none.json \
  --md-output output/radar-port-watch-none.zh.md >/dev/null; then
  echo "expected wait helper to fail when no likely ESP32-S3 port exists" >&2
  exit 1
fi
python3 - <<'PY'
import json
from pathlib import Path
report = json.loads(Path("output/radar-port-watch-none.json").read_text())
markdown = Path("output/radar-port-watch-none.zh.md").read_text()
assert report["usbLayerStatus"] == "radar-usb-present"
assert report["attemptLog"][0]["usbLayerStatus"] == "radar-usb-present"
assert "USB 设备层" in markdown
assert "BOOT" in markdown
PY
echo "radar-port-wait-ok"

log_step "Checking USB serial diagnosis helper"
rm -f output/usb-doctor-test.json output/usb-doctor-test.zh.md output/usb-doctor-ok.json output/usb-doctor-ok.zh.md
tools/diagnose_usb_serial.py \
  --sample '/dev/cu.Bluetooth-Incoming-Port|Bluetooth Incoming Port|n/a' \
  --sample '/dev/cu.Buds2|Earbuds|n/a' \
  --sample-usb 'USB JTAG/serial debug unit|0x303a|0x1001|RADARTEST|0x00100000' \
  --json-output output/usb-doctor-test.json \
  --md-output output/usb-doctor-test.zh.md >/dev/null
tools/diagnose_usb_serial.py \
  --sample '/dev/cu.usbmodem101|USB JTAG/serial debug unit|USB VID:PID=303A:1001' \
  --sample-usb 'USB JTAG/serial debug unit|0x303a|0x1001|RADARTEST|0x00100000' \
  --require-port \
  --json-output output/usb-doctor-ok.json \
  --md-output output/usb-doctor-ok.zh.md >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
missing = json.loads(Path("output/usb-doctor-test.json").read_text())
ready = json.loads(Path("output/usb-doctor-ok.json").read_text())
assert missing["status"] == "only-ignored"
assert missing["selectedPort"] is None
assert missing["usbLayerStatus"] == "radar-usb-present"
assert "USB 层看到了疑似雷达板" in "\n".join(missing["recommendations"])
assert "USB 串口诊断" in Path("output/usb-doctor-test.zh.md").read_text()
assert "USB 设备层" in Path("output/usb-doctor-test.zh.md").read_text()
assert ready["status"] == "ready"
assert ready["selectedPort"] == "/dev/cu.usbmodem101"
assert ready["usbLayerStatus"] == "radar-usb-present"
assert any("first_run_zh.py auto" in item for item in ready["recommendations"])
PY
rm -f output/usb-bringup-card-test.zh.md
tools/generate_usb_bringup_card.py \
  --output output/usb-bringup-card-test.zh.md \
  --diagnosis-json output/usb-doctor-test.json \
  --release-dir output/release-current >/dev/null
python3 - <<'PY'
from pathlib import Path
card = Path("output/usb-bringup-card-test.zh.md").read_text()
assert "龙珠雷达 USB 上板排障卡" in card
assert "only-ignored" in card
assert "USB 设备层" in card
assert "USB JTAG/serial debug unit" in card
assert "现场排障顺序" in card
assert "无法手动 Reset 时" in card
assert "tools/first_run_zh.py live --recover-runtime" in card
assert "FLASH_DRY_RUN=1" in card
assert "tools/flash_release_firmware.sh sim" in card
assert "esptool 的自动 reset" in card
assert "tools/wait_for_radar_port.py" in card
assert "tools/run_hardware_acceptance.sh all" in card
assert "验收边界" in card
PY
echo "usb-serial-diagnosis-ok"

log_step "Checking board runtime diagnosis helper"
rm -f output/runtime-doctor-ready.json output/runtime-doctor-ready.zh.md output/runtime-doctor-stuck.json output/runtime-doctor-stuck.zh.md
tools/diagnose_board_runtime.py \
  --port /dev/cu.usbmodem101 \
  --sample-line "DIAG enabled" \
  --sample-line "DIAG touch=online imu=online ble=online audio=online" \
  --sample-line "DIAG tick ms=1000 active=0 collected=7 zoom=0 brightPreset=1 audioPreset=2 frameMs=25 drawMs=18 drawAvgMs=18 drawMaxMs=20 overBudget=0 frames=40 heading=20.0 tilt=0.01 strongest=none online=TIBA summon=yes" \
  --sample-esptool skipped \
  --json-output output/runtime-doctor-ready.json \
  --md-output output/runtime-doctor-ready.zh.md >/dev/null
tools/diagnose_board_runtime.py \
  --port /dev/cu.usbmodem101 \
  --sample-esptool no-data \
  --json-output output/runtime-doctor-stuck.json \
  --md-output output/runtime-doctor-stuck.zh.md >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
ready = json.loads(Path("output/runtime-doctor-ready.json").read_text())
stuck = json.loads(Path("output/runtime-doctor-stuck.json").read_text())
ready_md = Path("output/runtime-doctor-ready.zh.md").read_text()
stuck_md = Path("output/runtime-doctor-stuck.zh.md").read_text()
assert ready["status"] == "runtime-ready"
assert ready["parsed"]["frameMs"] == 25
assert ready["parsed"]["drawMs"] == 18
assert ready["parsed"]["drawAvgMs"] == 18
assert ready["parsed"]["drawMaxMs"] == 20
assert ready["parsed"]["overBudgetFrames"] == 0
assert ready["parsed"]["frameSamples"] == 40
assert ready["parsed"]["hardwareAllOnline"] is True
assert "龙珠雷达板载运行态诊断" in ready_md
assert stuck["status"] == "usb-serial-present-no-runtime"
assert stuck["esptool"]["status"] == "no-data"
assert "按一下板子 Reset" in "\n".join(stuck["recommendations"])
assert "esptool 探测" in stuck_md
PY
echo "board-runtime-diagnosis-ok"

log_step "Checking board runtime recovery helper"
rm -f output/runtime-recovery-ready.json output/runtime-recovery-ready.zh.md output/runtime-recovery-stuck.json output/runtime-recovery-stuck.zh.md
tools/recover_board_runtime.py \
  --port /dev/cu.usbmodem101 \
  --sample-ready-stage app-reset \
  --json-output output/runtime-recovery-ready.json \
  --md-output output/runtime-recovery-ready.zh.md >/dev/null
tools/recover_board_runtime.py \
  --port /dev/cu.usbmodem101 \
  --sample-esptool no-data \
  --json-output output/runtime-recovery-stuck.json \
  --md-output output/runtime-recovery-stuck.zh.md >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
ready = json.loads(Path("output/runtime-recovery-ready.json").read_text())
stuck = json.loads(Path("output/runtime-recovery-stuck.json").read_text())
ready_md = Path("output/runtime-recovery-ready.zh.md").read_text()
stuck_md = Path("output/runtime-recovery-stuck.zh.md").read_text()
assert ready["status"] == "recovered"
assert ready["stages"][-1]["stage"] == "app-reset"
assert ready["stages"][-1]["parsed"]["frameMs"] == 25
assert ready["stages"][-1]["parsed"]["drawMs"] == 16
assert ready["stages"][-1]["parsed"]["drawAvgMs"] == 16
assert ready["stages"][-1]["parsed"]["drawMaxMs"] == 18
assert ready["stages"][-1]["parsed"]["overBudgetFrames"] == 0
assert "龙珠雷达板载运行态自动恢复报告" in ready_md
assert stuck["status"] == "not-recovered"
assert stuck["stages"][-1]["stage"] == "esptool-probe"
assert stuck["stages"][-1]["esptool"]["status"] == "no-data"
assert "按一下板子实体 Reset" in "\n".join(stuck["recommendations"])
assert "按住 BOOT" in stuck_md
PY
echo "board-runtime-recovery-ok"

log_step "Checking helper dry-run commands"
bringup_dry_run="$(
  BRINGUP_DRY_RUN=1 \
  RADAR_PORT=/dev/cu.test \
  DIAG_TIMEOUT=1 \
  DIAG_REQUIRE_ONLINE=touch,imu \
  DIAG_MIN_BEACONS=1 \
  DIAG_REPORT_JSON=output/bringup-dry-run.json \
  DIAG_REPORT_MD=output/bringup-dry-run.md \
  DIAG_LOG=output/bringup-dry-run.log \
  tools/bringup_diag.sh monitor
)"
if [[ "$bringup_dry_run" != *"--report-json output/bringup-dry-run.json"* ]]; then
  echo "expected bringup dry-run to pass --report-json to monitor" >&2
  exit 1
fi
if [[ "$bringup_dry_run" != *"--log-file output/bringup-dry-run.log"* ]]; then
  echo "expected bringup dry-run to pass --log-file to monitor" >&2
  exit 1
fi
if [[ "$bringup_dry_run" != *"tools/render_bench_report.py output/bringup-dry-run.json output/bringup-dry-run.md"* ]]; then
  echo "expected bringup dry-run to render Markdown report" >&2
  exit 1
fi
bringup_collection_dry_run="$(
  BRINGUP_DRY_RUN=1 \
  DIAG_MIN_COLLECTIONS=7 \
  DIAG_REQUIRE_COLLECTION_SET=1 \
  tools/bringup_diag.sh monitor
)"
if [[ "$bringup_collection_dry_run" != *"--min-collections 7"* ]]; then
  echo "expected bringup dry-run to pass --min-collections to monitor" >&2
  exit 1
fi
if [[ "$bringup_collection_dry_run" != *"--require-collection-set"* ]]; then
  echo "expected bringup dry-run to pass --require-collection-set to monitor" >&2
  exit 1
fi
bench_dry_run="$(
  BENCH_DRY_RUN=1 \
  RADAR_PORT=/dev/cu.test \
  SIM_TIMEOUT=3 \
  tools/bench_sim.sh monitor
)"
if [[ "$bench_dry_run" != *"--min-collections 7"* ]]; then
  echo "expected bench sim dry-run to require seven collection events" >&2
  exit 1
fi
if [[ "$bench_dry_run" != *"--require-collection-set"* ]]; then
  echo "expected bench sim dry-run to require the full collection set" >&2
  exit 1
fi
hunt_dry_run="$(
  HUNT_DRY_RUN=1 \
  RADAR_PORT=/dev/cu.test \
  HUNT_TIMEOUT=3 \
  HUNT_MIN_COLLECTIONS=7 \
  HUNT_REQUIRE_COLLECTION_SET=1 \
  HUNT_REQUIRE_SUMMON=1 \
  tools/record_field_hunt.sh monitor
)"
if [[ "$hunt_dry_run" != *"--min-collections 7"* ]]; then
  echo "expected field hunt dry-run to pass --min-collections to monitor" >&2
  exit 1
fi
if [[ "$hunt_dry_run" != *"--require-collection-set"* ]]; then
  echo "expected field hunt dry-run to pass --require-collection-set to monitor" >&2
  exit 1
fi
if [[ "$hunt_dry_run" != *"--require-summon"* ]]; then
  echo "expected field hunt dry-run to pass --require-summon to monitor" >&2
  exit 1
fi
if [[ "$hunt_dry_run" != *"tools/render_hunt_report.py"* ]]; then
  echo "expected field hunt dry-run to render the friend-facing hunt report" >&2
  exit 1
fi
echo "helper-dry-run-ok"

log_step "Checking serial command helper dry-run"
serial_command_dry_run="$(tools/send_diag_command.py zoom --port /dev/cu.test --dry-run)"
if [[ "$serial_command_dry_run" != *"PORT /dev/cu.test"* ]]; then
  echo "expected serial command dry-run to show selected port" >&2
  exit 1
fi
if [[ "$serial_command_dry_run" != *"COMMAND z"* ]]; then
  echo "expected serial command dry-run to map zoom to z" >&2
  exit 1
fi
serial_turbo_dry_run="$(tools/send_diag_command.py turbo --port /dev/cu.test --dry-run)"
if [[ "$serial_turbo_dry_run" != *"COMMAND t"* ]]; then
  echo "expected serial command dry-run to map turbo to t" >&2
  exit 1
fi
echo "serial-command-dry-run-ok"

log_step "Checking prebuilt factory flash dry-run"
factory_flash_dry_run="$(
  FLASH_DRY_RUN=1 \
  RADAR_PORT=/dev/cu.test \
  RELEASE_DIR=output/release-current \
  tools/flash_release_firmware.sh field
)"
if [[ "$factory_flash_dry_run" != *"dragon-radar-field-factory.bin"* ]]; then
  echo "expected factory flash dry-run to select the field factory image" >&2
  exit 1
fi
if [[ "$factory_flash_dry_run" != *"--chip esp32s3"* ]]; then
  echo "expected factory flash dry-run to target ESP32-S3" >&2
  exit 1
fi
if [[ "$factory_flash_dry_run" != *"--port /dev/cu.test"* ]]; then
  echo "expected factory flash dry-run to pass RADAR_PORT to esptool" >&2
  exit 1
fi
if [[ "$factory_flash_dry_run" != *"write_flash"* || "$factory_flash_dry_run" != *"0x0"* ]]; then
  echo "expected factory flash dry-run to write the factory image at 0x0" >&2
  exit 1
fi
if [[ "$factory_flash_dry_run" != *"--flash_mode dio"* ]]; then
  echo "expected factory flash dry-run to preserve ESP32-S3 factory image DIO flash mode" >&2
  exit 1
fi
echo "factory-flash-dry-run-ok"

log_step "Checking prebuilt sim smoke dry-run"
release_smoke_dry_run="$(
  SMOKE_DRY_RUN=1 \
  RADAR_PORT=/dev/cu.test \
  RELEASE_DIR=output/release-current \
  SMOKE_OUTPUT_DIR=output/release-smoke-dry-run \
  tools/smoke_release_board.sh all
)"
if [[ "$release_smoke_dry_run" != *"tools/flash_release_firmware.sh sim"* ]]; then
  echo "expected release smoke dry-run to flash the sim factory image" >&2
  exit 1
fi
if [[ "$release_smoke_dry_run" != *"SIM_REPORT_JSON=output/release-smoke-dry-run/bench-sim-report.json"* ]]; then
  echo "expected release smoke dry-run to route the sim report into the smoke folder" >&2
  exit 1
fi
if [[ "$release_smoke_dry_run" != *"SIM_MIN_COLLECTIONS=7"* ]]; then
  echo "expected release smoke dry-run to require seven collection events" >&2
  exit 1
fi
if [[ "$release_smoke_dry_run" != *"SIM_REQUIRE_SUMMON=1"* ]]; then
  echo "expected release smoke dry-run to require summon mode" >&2
  exit 1
fi
echo "release-smoke-dry-run-ok"

log_step "Checking guided board simulation helper"
board_sim_port_check="$(
  tools/run_board_sim_test.py port-check \
    --sample-port '/dev/cu.usbmodem101|USB JTAG/serial debug unit|USB VID:PID=303A:1001'
)"
if [[ "$board_sim_port_check" != *"Selected RADAR_PORT=/dev/cu.usbmodem101"* ]]; then
  echo "expected board sim helper to auto-select the sample ESP32-S3 port" >&2
  exit 1
fi
board_sim_dry_run="$(
  tools/run_board_sim_test.py auto --dry-run \
    --sample-port '/dev/cu.usbmodem101|USB JTAG/serial debug unit|USB VID:PID=303A:1001'
)"
if [[ "$board_sim_dry_run" != *"tools/verify_release_package.py"* ]]; then
  echo "expected board sim dry-run to verify the release package first" >&2
  exit 1
fi
if [[ "$board_sim_dry_run" != *"tools/smoke_release_board.sh all"* ]]; then
  echo "expected board sim dry-run to run the packaged smoke helper" >&2
  exit 1
fi
if [[ "$board_sim_dry_run" != *"RADAR_PORT=/dev/cu.usbmodem101"* ]]; then
  echo "expected board sim dry-run to pass the selected radar port" >&2
  exit 1
fi
board_sim_mock_dry_run="$(tools/run_board_sim_test.py mock --dry-run --timeout 3)"
if [[ "$board_sim_mock_dry_run" != *"RELEASE_ACCEPTANCE_MOCK=1"* ]]; then
  echo "expected board sim mock dry-run to use release acceptance mock mode" >&2
  exit 1
fi
if [[ "$board_sim_mock_dry_run" != *"tools/run_release_acceptance.sh sim"* ]]; then
  echo "expected board sim mock dry-run to run the sim acceptance gate" >&2
  exit 1
fi
echo "board-sim-helper-ok"

log_step "Checking release self-test helper"
release_selftest_dry_run="$(tools/selftest_release.py output/release-current --dry-run --mock-timeout 3)"
if [[ "$release_selftest_dry_run" != *"tools/verify_release_package.py"* ]]; then
  echo "expected release self-test dry-run to verify the release package" >&2
  exit 1
fi
if [[ "$release_selftest_dry_run" != *"tools/run_board_sim_test.py mock"* ]]; then
  echo "expected release self-test dry-run to run the board simulation mock" >&2
  exit 1
fi
if [[ "$release_selftest_dry_run" != *"release-selftest-passed"* ]]; then
  echo "expected release self-test dry-run to pass" >&2
  exit 1
fi
rm -rf output/release-selftest-smoke
tools/selftest_release.py output/release-current --output-dir output/release-selftest-smoke --mock-timeout 8 >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
root = Path("output/release-selftest-smoke")
summary = json.loads((root / "release-selftest-summary.json").read_text())
bench = json.loads((root / "board-sim-mock" / "bench-sim-report.json").read_text())
assert summary["status"] == "passed"
assert summary["hardwareProof"] is False
assert len(summary["steps"]) == 2
assert bench["status"] == "passed"
assert bench["collectionCount"] == 7
assert bench["summon"] is True
assert bench["simulatedBle"] is True
assert (root / "release-selftest-summary.md").exists()
PY
echo "release-selftest-ok"

log_step "Checking pre-board acceptance helper"
preboard_dry_run="$(tools/run_preboard_acceptance.py --dry-run --mock-timeout 3 --samples 8)"
if [[ "$preboard_dry_run" != *"tools/verify_release_package.py"* ]]; then
  echo "expected pre-board acceptance dry-run to verify the release package" >&2
  exit 1
fi
if [[ "$preboard_dry_run" != *"tools/selftest_release.py"* ]]; then
  echo "expected pre-board acceptance dry-run to run the release self-test" >&2
  exit 1
fi
if [[ "$preboard_dry_run" != *"tools/simulate_diag_feed.py"* ]]; then
  echo "expected pre-board acceptance dry-run to generate a DIAG feed" >&2
  exit 1
fi
if [[ "$preboard_dry_run" != *"tools/monitor_diag.py"* ]]; then
  echo "expected pre-board acceptance dry-run to monitor the DIAG feed" >&2
  exit 1
fi
if [[ "$preboard_dry_run" != *"--require-collection-set"* ]]; then
  echo "expected pre-board acceptance dry-run to require all seven collection events" >&2
  exit 1
fi
rm -rf output/preboard-acceptance-smoke
tools/run_preboard_acceptance.py \
  --release-dir output/release-current \
  --output-dir output/preboard-acceptance-smoke \
  --mock-timeout 8 \
  --samples 16 >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
root = Path("output/preboard-acceptance-smoke")
summary = json.loads((root / "preboard-acceptance-summary.json").read_text())
markdown = (root / "preboard-acceptance.zh.md").read_text()
assert summary["status"] == "passed"
assert summary["hardwareProof"] is False
assert summary["checks"]["mockBoardSimulation"]["collectionCount"] == 7
assert summary["checks"]["mockBoardSimulation"]["summon"] is True
assert summary["checks"]["diagSevenBallReplay"]["beaconCount"] == 7
assert summary["checks"]["diagSevenBallReplay"]["collectionCount"] == 7
assert summary["checks"]["diagSevenBallReplay"]["summon"] is True
assert "龙珠雷达上板前模拟验收报告" in markdown
assert "硬件证明: `false`" in markdown
assert "不能替代 ESP32-S3 真板" in markdown
assert (root / "diag-replay-raw.log").exists()
assert (root / "diag-replay-report.json").exists()
PY
echo "preboard-acceptance-ok"

log_step "Checking Chinese first-run wizard"
rm -rf output/first-run-zh-test
tools/first_run_zh.py check \
  --release-dir output/release-current \
  --output-dir output/first-run-zh-test \
  --sample-port '/dev/cu.Bluetooth-Incoming-Port|Bluetooth Incoming Port|n/a' \
  --sample-port '/dev/cu.usbmodem101|USB JTAG/serial debug unit|USB VID:PID=303A:1001' >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
root = Path("output/first-run-zh-test")
summary = json.loads((root / "first-run-summary.json").read_text())
markdown = (root / "first-run-summary.zh.md").read_text()
assert summary["status"] == "passed"
assert summary["hardwareProof"] is False
assert summary["selectedPort"] == "/dev/cu.usbmodem101"
assert summary["hardwareCompletion"] in ("NOT PROVEN", "PASS")
assert "龙珠雷达首跑验收摘要" in markdown
assert "RADAR_PORT=/dev/cu.usbmodem101 tools/first_run_zh.py auto" in markdown
commands = __import__("subprocess").run(["tools/first_run_zh.py", "commands"], text=True, capture_output=True, check=True).stdout
assert "tools/diagnose_usb_serial.py" in commands
assert "tools/recover_board_runtime.py" in commands
assert "tools/first_run_zh.py live --recover-runtime" in commands
assert "tools/wait_for_radar_port.py --run-auto" in commands
PY
first_run_live_dry_run="$(
  tools/first_run_zh.py live \
    --dry-run \
    --recover-runtime \
    --wait-timeout 0 \
    --wait-interval 0 \
    --release-dir output/release-current \
    --output-dir output/first-run-zh-live-dry-run \
    --sample-port '/dev/cu.usbmodem101|USB JTAG/serial debug unit|USB VID:PID=303A:1001' \
    --sample-usb 'USB JTAG/serial debug unit|0x303a|0x1001|RADARTEST|0x00100000'
)"
if [[ "$first_run_live_dry_run" != *"tools/run_preboard_acceptance.py"* ]]; then
  echo "expected first-run live dry-run to call pre-board acceptance" >&2
  exit 1
fi
if [[ "$first_run_live_dry_run" != *"tools/diagnose_usb_serial.py"* ]]; then
  echo "expected first-run live dry-run to run USB diagnosis" >&2
  exit 1
fi
if [[ "$first_run_live_dry_run" != *"tools/recover_board_runtime.py"* ]]; then
  echo "expected first-run live dry-run with --recover-runtime to call runtime recovery" >&2
  exit 1
fi
if [[ "$first_run_live_dry_run" != *"运行态自动恢复"* ]]; then
  echo "expected first-run live dry-run to name the runtime recovery step" >&2
  exit 1
fi
if [[ "$first_run_live_dry_run" != *"tools/wait_for_radar_port.py"* ]]; then
  echo "expected first-run live dry-run to wait for radar port" >&2
  exit 1
fi
if [[ "$first_run_live_dry_run" != *"--run-auto"* ]]; then
  echo "expected first-run live dry-run to pass --run-auto" >&2
  exit 1
fi
first_run_auto_dry_run="$(
  tools/first_run_zh.py auto \
    --dry-run \
    --release-dir output/release-current \
    --output-dir output/first-run-zh-dry-run \
    --sample-port '/dev/cu.usbmodem101|USB JTAG/serial debug unit|USB VID:PID=303A:1001'
)"
if [[ "$first_run_auto_dry_run" != *"tools/run_board_sim_test.py auto"* ]]; then
  echo "expected first-run auto dry-run to call the board simulation helper" >&2
  exit 1
fi
if [[ "$first_run_auto_dry_run" != *"--dry-run"* ]]; then
  echo "expected first-run auto dry-run to pass --dry-run through" >&2
  exit 1
fi
echo "first-run-zh-ok"

log_step "Checking beacon set dry-run"
rm -f output/beacon-set-dry-run.md output/beacon-set-dry-run.log
BEACON_SET_DRY_RUN=1 \
BEACON_SET_MANIFEST=output/beacon-set-dry-run.md \
BEACON_SET_LOG=output/beacon-set-dry-run.log \
tools/flash_beacon_set.sh 1 2 >/dev/null
python3 - <<'PY'
from pathlib import Path
manifest = Path("output/beacon-set-dry-run.md").read_text()
log = Path("output/beacon-set-dry-run.log").read_text()
assert "DBALL-1" in manifest
assert "DBALL-2" in manifest
assert "planned" in manifest
assert "DBALL-1 start" in log
assert "DBALL-2 planned" in log
PY
echo "beacon-set-dry-run-ok"

log_step "Checking beacon set verification dry-run"
beacon_verify_dry_run="$(
  BEACON_VERIFY_DRY_RUN=1 \
  RADAR_PORT=/dev/cu.test \
  BEACON_VERIFY_TIMEOUT=3 \
  BEACON_VERIFY_REPORT_JSON=output/beacon-verify-dry-run.json \
  BEACON_VERIFY_REPORT_MD=output/beacon-verify-dry-run.md \
  BEACON_VERIFY_LOG=output/beacon-verify-dry-run.log \
  tools/verify_beacon_set.sh monitor
)"
if [[ "$beacon_verify_dry_run" != *"--min-beacons 7"* ]]; then
  echo "expected beacon verify dry-run to require seven beacons" >&2
  exit 1
fi
if [[ "$beacon_verify_dry_run" != *"--require-online touch\\,imu\\,ble\\,audio"* ]]; then
  echo "expected beacon verify dry-run to require hardware modules online" >&2
  exit 1
fi
if [[ "$beacon_verify_dry_run" != *"--report-json output/beacon-verify-dry-run.json"* ]]; then
  echo "expected beacon verify dry-run to use its report path" >&2
  exit 1
fi
if [[ "$beacon_verify_dry_run" != *"--log-file output/beacon-verify-dry-run.log"* ]]; then
  echo "expected beacon verify dry-run to use its log path" >&2
  exit 1
fi
echo "beacon-set-verify-dry-run-ok"

log_step "Checking printable beacon labels"
rm -f output/beacon-labels-test.html
tools/generate_beacon_labels.py --output output/beacon-labels-test.html --profile battery >/dev/null
python3 - <<'PY'
from pathlib import Path
html = Path("output/beacon-labels-test.html").read_text()
assert "DBALL-1" in html
assert "DBALL-7" in html
assert "400-900 ms" in html
assert "flashed" in html
assert "verified" in html
assert html.count('class="label"') == 7
PY
echo "beacon-labels-ok"

log_step "Checking printable field kit"
rm -f output/field-kit-test.html
tools/generate_field_kit.py --output output/field-kit-test.html --radar-port /dev/cu.test --area "Room A" --players "Goku,Bulma" >/dev/null
python3 - <<'PY'
from pathlib import Path
html = Path("output/field-kit-test.html").read_text()
assert "Dragon Radar Field Kit" in html
assert "RADAR_PORT=/dev/cu.test tools/run_board_sim_test.py auto" in html
assert "RADAR_PORT=/dev/cu.test tools/smoke_release_board.sh all" in html
assert "RADAR_PORT=/dev/cu.test tools/run_release_acceptance.sh all" in html
assert "tools/list_radar_ports.py --shell" in html
assert "DBALL-1" in html
assert "DBALL-7" in html
assert "Goku" in html
assert "Bulma" in html
assert "Hardware completion: PASS" in html
PY
echo "field-kit-ok"

log_step "Checking field tuning recommendation"
rm -f output/field-tuning-report.md
tools/recommend_field_tuning.py \
  output/preboard-acceptance-smoke/release-selftest/board-sim-mock/bench-sim-report.json \
  --output-md output/field-tuning-report.md \
  --mode field >/dev/null
python3 - <<'PY'
from pathlib import Path
report = Path("output/field-tuning-report.md").read_text()
assert "Dragon Radar Field Tuning" in report
assert "Source kind: `mock-preboard`" in report
assert "Hardware proof: `false`" in report
assert "Recommended `COLLECT_RSSI`" in report
assert "Recommended `COLLECT_HOLD_MS`" in report
assert "无硬件开局建议" in report
PY
echo "field-tuning-ok"

log_step "Checking playtest rehearsal report"
rm -f output/playtest-rehearsal-test.zh.md
tools/render_playtest_rehearsal.py --output output/playtest-rehearsal-test.zh.md --release-dir output/release-current >/dev/null
python3 - <<'PY'
from pathlib import Path
report = Path("output/playtest-rehearsal-test.zh.md").read_text()
for required in (
    "龙珠雷达试玩演练报告",
    "mock 七球路线",
    "开局采集阈值建议",
    "COLLECT_RSSI",
    "试玩当天流程卡",
    "硬件证明: `false`",
    "tools/wait_for_radar_port.py --run-auto",
    "tools/run_release_acceptance.sh all",
):
    assert required in report
PY
echo "playtest-rehearsal-ok"

log_step "Checking Chinese quickstart"
rm -f output/quickstart-test.zh.html
tools/generate_quickstart_zh.py --output output/quickstart-test.zh.html --release-dir output/release-current --radar-port /dev/cu.test >/dev/null
python3 - <<'PY'
from pathlib import Path
html = Path("output/quickstart-test.zh.html").read_text()
assert "龙珠雷达快速开始" in html
assert "硬件完成度" in html
assert "tools/first_run_zh.py check" in html
assert "tools/first_run_zh.py live" in html
assert "tools/first_run_zh.py mock" in html
assert "tools/diagnose_usb_serial.py" in html
assert "tools/recover_board_runtime.py" in html
assert "无法手动 Reset" in html
assert "tools/first_run_zh.py live --recover-runtime" in html
assert "tools/flash_release_firmware.sh sim" in html
assert "tools/wait_for_radar_port.py --run-auto" in html
assert "RADAR_PORT=/dev/cu.test tools/first_run_zh.py auto" in html
assert "RADAR_PORT=/dev/cu.test tools/run_release_acceptance.sh all" in html
assert "sim" in html
assert "fielddiag" in html
assert "产品设计说明" in html
assert "信标制作指南" in html
assert "USB 上板排障卡" in html
assert "上板前模拟验收" in html
assert "tools/run_preboard_acceptance.py" in html
assert "开局采集阈值建议" in html or "tools/recommend_field_tuning.py" in html
assert "Goal 完成度审计" in html
assert "主持人/玩家试玩卡" in html
assert "动画验收图" in html
assert "缺失" not in html
PY
echo "quickstart-zh-ok"

log_step "Checking preview JavaScript syntax"
node - <<'NODE'
const fs = require('fs');
const html = fs.readFileSync('preview/radar_ui.html', 'utf8');
const match = html.match(/<script>([\s\S]*)<\/script>/);
if (!match) throw new Error('missing inline script');
new Function(match[1]);
if (!html.includes('grid-template-columns: repeat(4')) throw new Error('preview mode control must have four columns');
for (const required of [
  'window.addEventListener("keydown"',
  'applyMode("default"',
  'applyMode("field"',
  'applyMode("sim"',
  'applyMode("debug"',
  'collectDemo(now)',
  'cycleZoom(now)',
  'resetPreviewSession(now)',
  'brightnessPreset = (brightnessPreset + 1)',
  'audioPreset = (audioPreset + 1)',
]) {
  if (!html.includes(required)) throw new Error(`missing preview keyboard/control hook: ${required}`);
}
console.log('preview-js-ok');
NODE

log_step "Checking preview keyboard interactions"
rm -f output/preview-interactions.json output/playwright/preview-interaction-final.png
tools/smoke_preview_interactions.sh >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
report = json.loads(Path("output/preview-interactions.json").read_text())
assert report["status"] == "passed"
assert len(report["checks"]) >= 9
assert all(check["status"] == "passed" for check in report["checks"])
assert Path("output/playwright/preview-interaction-final.png").stat().st_size > 1000
PY
echo "preview-interactions-ok"

log_step "Checking release package verifier"
RELEASE_DIR=output/release-current RELEASE_TAR=1 tools/package_release.sh >/dev/null
release_verify_output="$(
  tools/verify_release_package.py output/release-current \
    --write \
    --json output/release-audit-test.json \
    --checksums output/release-checksums-test.sha256
)"
if [[ "$release_verify_output" != *"STATUS passed"* ]]; then
  echo "expected release package verifier to pass for output/release-current" >&2
  exit 1
fi
if [[ "$release_verify_output" != *"FACTORY field,fielddiag,diag,sim"* ]]; then
  echo "expected release package verifier to see all four factory images" >&2
  exit 1
fi
python3 - <<'PY'
import json
from pathlib import Path
audit = json.loads(Path("output/release-audit-test.json").read_text())
assert audit["status"] == "passed"
assert audit["previewFrameCount"] == 21
assert audit["previewExtraFrameCount"] == 1
assert audit["motionGifCount"] == 3
motion_gifs = {item["path"].split("/")[-1]: item for item in audit["motionGifs"]}
assert motion_gifs["boot-motion.gif"]["frameCount"] == 4
assert motion_gifs["radar-motion.gif"]["frameCount"] == 7
assert motion_gifs["summon-motion.gif"]["frameCount"] == 4
assert motion_gifs["radar-motion.gif"]["size"] > 10000
assert motion_gifs["radar-motion.gif"]["width"] >= 400
assert motion_gifs["radar-motion.gif"]["height"] >= 400
assert audit["factoryModes"] == ["field", "fielddiag", "diag", "sim"]
checksums = Path("output/release-checksums-test.sha256").read_text()
assert "firmware/dragon-radar-field-factory.bin" in checksums
assert "index.html" in checksums
assert "docs/board-sim-test.zh.md" in checksums
assert "docs/product-design.zh.md" in checksums
assert "docs/beacon-build.zh.md" in checksums
assert "docs/quickstart.zh.html" in checksums
assert "docs/fidelity-review.zh.md" in checksums
assert "docs/goal-completion-audit.zh.md" in checksums
assert "docs/hardware-proof-packet.zh.md" in checksums
assert "docs/missing-hardware-gates-plan.zh.md" in checksums
assert "docs/preboard-acceptance.zh.md" in checksums
assert "docs/usb-bringup-card.zh.md" in checksums
assert "docs/refresh-performance-card.zh.md" in checksums
assert "docs/no-reset-display-check.zh.md" in checksums
assert "docs/board-photo-qa-sample.zh.md" in checksums
assert "evidence/goal-completion-audit.json" in checksums
assert "evidence/hardware-proof-packet.json" in checksums
assert "evidence/missing-hardware-gates-plan.json" in checksums
assert "evidence/no-reset-display-check.json" in checksums
assert "evidence/board-photo-qa-sample.json" in checksums
assert "evidence/board-photo-qa-sample-crop.png" in checksums
assert "evidence/board-photo-qa-sample-overlay.png" in checksums
assert "evidence/preboard-acceptance/preboard-acceptance-summary.json" in checksums
assert "evidence/preview-visual-audit.json" in checksums
assert "evidence/preview-visual-audit.md" in checksums
assert "evidence/motion-gif-audit.json" in checksums
assert "evidence/motion-gif-audit.md" in checksums
assert "evidence/firmware-ui-contract.json" in checksums
assert "docs/field-kit.html" in checksums
assert "docs/game-cards.html" in checksums
assert "docs/playtest-rehearsal.zh.md" in checksums
assert "docs/field-tuning-report.md" in checksums
assert "docs/visual-qa.html" in checksums
assert "docs/motion-qa.html" in checksums
assert "preview/boot-motion.gif" in checksums
assert "preview/radar-motion.gif" in checksums
assert "preview/summon-motion.gif" in checksums
assert "preview/preview-interaction-final.png" in checksums
assert "preview/radar-startup-acquire.png" in checksums
assert "preview/radar-idle-search.png" in checksums
assert "preview/radar-acquisition-echo.png" in checksums
assert "preview/radar-target-trail.png" in checksums
assert "preview/radar-trace-blip.png" in checksums
assert "preview/radar-zoom-map.png" in checksums
assert "preview/radar-proximity-lock.png" in checksums
assert "preview/radar-capture-burst.png" in checksums
assert "preview/radar-control-flashes.png" in checksums
assert "preview/radar-touch-echo.png" in checksums
assert "preview/radar-tilt-inertia.png" in checksums
assert "private_boot_logo.h  " not in checksums
assert "tools/run_release_acceptance.sh" in checksums
assert "tools/run_board_sim_test.py" in checksums
assert "tools/run_preboard_acceptance.py" in checksums
assert "tools/selftest_release.py" in checksums
assert "tools/first_run_zh.py" in checksums
assert "tools/wait_for_radar_port.py" in checksums
assert "tools/diagnose_usb_serial.py" in checksums
assert "tools/diagnose_board_runtime.py" in checksums
assert "tools/recover_board_runtime.py" in checksums
assert "tools/send_diag_command.py" in checksums
assert "tools/run_no_reset_display_check.py" in checksums
assert "tools/analyze_board_photo.py" in checksums
assert "tools/generate_usb_bringup_card.py" in checksums
assert "tools/generate_refresh_perf_card.py" in checksums
assert "tools/simulate_diag_feed.py" in checksums
assert "tools/generate_quickstart_zh.py" in checksums
assert "tools/generate_visual_qa_sheet.py" in checksums
assert "tools/generate_motion_gifs.py" in checksums
assert "tools/verify_motion_gifs.py" in checksums
assert "tools/generate_motion_qa_sheet.py" in checksums
assert "tools/generate_release_index.py" in checksums
assert "tools/generate_fidelity_review.py" in checksums
assert "tools/generate_play_cards.py" in checksums
assert "tools/verify_firmware_ui_contract.py" in checksums
assert "tools/verify_ui_parity.py" in checksums
assert "tools/verify_private_boot_logo.py" in checksums
assert "tools/install_private_boot_logo.py" in checksums
assert "tools/render_hunt_report.py" in checksums
assert "tools/render_goal_completion_audit.py" in checksums
assert "tools/render_hardware_proof_packet.py" in checksums
assert "tools/run_missing_hardware_gates.py" in checksums
assert "tools/render_playtest_rehearsal.py" in checksums
assert "tools/recommend_field_tuning.py" in checksums
assert "tools/smoke_preview_interactions.sh" in checksums
assert "evidence/preview-interactions.json" in checksums
assert "evidence/firmware-preview-parity.json" in checksums
assert "evidence/private-boot-logo-audit.json" in checksums
assert "evidence/private-boot-logo-audit.md" in checksums
assert "evidence/private-boot-logo-setup.json" in checksums
assert "evidence/private-boot-logo-setup.md" in checksums
assert "evidence/usb-serial-diagnosis.json" in checksums
assert "evidence/usb-serial-diagnosis.zh.md" in checksums
PY
echo "release-verifier-ok"

log_step "Checking release tarball contents"
rm -rf output/release-tar-test output/release-tar-test.tar.gz
RELEASE_DIR=output/release-tar-test \
RELEASE_MODES=fielddiag \
RELEASE_TAR=1 \
tools/package_release.sh >/dev/null
tar -tzf output/release-tar-test.tar.gz > output/release-tar-test.contents
python3 - <<'PY'
from pathlib import Path
contents = Path("output/release-tar-test.contents").read_text()
assert "release-tar-test/RELEASE_AUDIT.json" in contents
assert "release-tar-test/CHECKSUMS.sha256" in contents
assert "release-tar-test/index.html" in contents
assert "release-tar-test/docs/board-sim-test.zh.md" in contents
assert "release-tar-test/docs/product-design.zh.md" in contents
assert "release-tar-test/docs/beacon-build.zh.md" in contents
assert "release-tar-test/docs/quickstart.zh.html" in contents
assert "release-tar-test/docs/fidelity-review.zh.md" in contents
assert "release-tar-test/docs/goal-completion-audit.zh.md" in contents
assert "release-tar-test/docs/hardware-proof-packet.zh.md" in contents
assert "release-tar-test/docs/missing-hardware-gates-plan.zh.md" in contents
assert "release-tar-test/docs/preboard-acceptance.zh.md" in contents
assert "release-tar-test/docs/usb-bringup-card.zh.md" in contents
assert "release-tar-test/docs/refresh-performance-card.zh.md" in contents
assert "release-tar-test/docs/no-reset-display-check.zh.md" in contents
assert "release-tar-test/docs/board-photo-qa-sample.zh.md" in contents
assert "release-tar-test/evidence/goal-completion-audit.json" in contents
assert "release-tar-test/evidence/hardware-proof-packet.json" in contents
assert "release-tar-test/evidence/missing-hardware-gates-plan.json" in contents
assert "release-tar-test/evidence/no-reset-display-check.json" in contents
assert "release-tar-test/evidence/board-photo-qa-sample.json" in contents
assert "release-tar-test/evidence/board-photo-qa-sample-crop.png" in contents
assert "release-tar-test/evidence/board-photo-qa-sample-overlay.png" in contents
assert "release-tar-test/evidence/preboard-acceptance/preboard-acceptance-summary.json" in contents
assert "release-tar-test/evidence/preview-visual-audit.json" in contents
assert "release-tar-test/evidence/preview-visual-audit.md" in contents
assert "release-tar-test/evidence/motion-gif-audit.json" in contents
assert "release-tar-test/evidence/motion-gif-audit.md" in contents
assert "release-tar-test/evidence/firmware-ui-contract.json" in contents
assert "release-tar-test/firmware/dragon-radar-fielddiag-factory.bin" in contents
assert "release-tar-test/docs/field-kit.html" in contents
assert "release-tar-test/docs/game-cards.html" in contents
assert "release-tar-test/docs/playtest-rehearsal.zh.md" in contents
assert "release-tar-test/docs/field-tuning-report.md" in contents
assert "release-tar-test/docs/visual-qa.html" in contents
assert "release-tar-test/docs/motion-qa.html" in contents
assert "release-tar-test/preview/radar-idle-search.png" in contents
assert "release-tar-test/preview/radar-zoom-map.png" in contents
assert "release-tar-test/preview/boot-motion.gif" in contents
assert "release-tar-test/preview/radar-motion.gif" in contents
assert "release-tar-test/preview/summon-motion.gif" in contents
assert "release-tar-test/tools/run_release_acceptance.sh" in contents
assert "release-tar-test/tools/run_board_sim_test.py" in contents
assert "release-tar-test/tools/run_preboard_acceptance.py" in contents
assert "release-tar-test/tools/selftest_release.py" in contents
assert "release-tar-test/tools/first_run_zh.py" in contents
assert "release-tar-test/tools/wait_for_radar_port.py" in contents
assert "release-tar-test/tools/diagnose_usb_serial.py" in contents
assert "release-tar-test/tools/diagnose_board_runtime.py" in contents
assert "release-tar-test/tools/recover_board_runtime.py" in contents
assert "release-tar-test/tools/send_diag_command.py" in contents
assert "release-tar-test/tools/run_no_reset_display_check.py" in contents
assert "release-tar-test/tools/analyze_board_photo.py" in contents
assert "release-tar-test/tools/generate_usb_bringup_card.py" in contents
assert "release-tar-test/tools/generate_refresh_perf_card.py" in contents
assert "release-tar-test/tools/simulate_diag_feed.py" in contents
assert "release-tar-test/tools/generate_quickstart_zh.py" in contents
assert "release-tar-test/tools/generate_visual_qa_sheet.py" in contents
assert "release-tar-test/tools/generate_motion_gifs.py" in contents
assert "release-tar-test/tools/verify_motion_gifs.py" in contents
assert "release-tar-test/tools/generate_motion_qa_sheet.py" in contents
assert "release-tar-test/tools/generate_release_index.py" in contents
assert "release-tar-test/tools/generate_fidelity_review.py" in contents
assert "release-tar-test/tools/generate_play_cards.py" in contents
assert "release-tar-test/tools/verify_firmware_ui_contract.py" in contents
assert "release-tar-test/tools/verify_ui_parity.py" in contents
assert "release-tar-test/tools/verify_private_boot_logo.py" in contents
assert "release-tar-test/tools/install_private_boot_logo.py" in contents
assert "release-tar-test/tools/render_hunt_report.py" in contents
assert "release-tar-test/tools/render_goal_completion_audit.py" in contents
assert "release-tar-test/tools/render_hardware_proof_packet.py" in contents
assert "release-tar-test/tools/render_playtest_rehearsal.py" in contents
assert "release-tar-test/tools/recommend_field_tuning.py" in contents
assert "release-tar-test/tools/smoke_preview_interactions.sh" in contents
assert "release-tar-test/evidence/preview-interactions.json" in contents
assert "release-tar-test/evidence/firmware-preview-parity.json" in contents
assert "release-tar-test/evidence/private-boot-logo-audit.json" in contents
assert "release-tar-test/evidence/private-boot-logo-audit.md" in contents
assert "release-tar-test/evidence/private-boot-logo-setup.json" in contents
assert "release-tar-test/evidence/private-boot-logo-setup.md" in contents
assert "release-tar-test/evidence/usb-serial-diagnosis.json" in contents
assert "release-tar-test/evidence/usb-serial-diagnosis.zh.md" in contents
assert "release-tar-test/firmware/dragon-radar-field-factory.bin" not in contents
PY
tools/verify_release_package.py output/release-tar-test --modes fielddiag >/dev/null
echo "release-tarball-ok"

log_step "Checking release acceptance dry-run"
release_acceptance_dry_run="$(
  RELEASE_ACCEPTANCE_DRY_RUN=1 \
  RELEASE_ACCEPTANCE_DIR=output/release-acceptance-dry-run \
  RADAR_PORT=/dev/cu.test \
  RELEASE_DIR=output/release-current \
  tools/run_release_acceptance.sh all
)"
if [[ "$release_acceptance_dry_run" != *"tools/flash_release_firmware.sh diag"* ]]; then
  echo "expected release acceptance dry-run to flash the packaged diag image" >&2
  exit 1
fi
if [[ "$release_acceptance_dry_run" != *"tools/flash_release_firmware.sh sim"* ]]; then
  echo "expected release acceptance dry-run to flash the packaged sim image" >&2
  exit 1
fi
if [[ "$release_acceptance_dry_run" != *"tools/flash_release_firmware.sh fielddiag"* ]]; then
  echo "expected release acceptance dry-run to flash the packaged fielddiag image" >&2
  exit 1
fi
if [[ "$release_acceptance_dry_run" != *"--require-simulated-ble"* ]]; then
  echo "expected release acceptance dry-run to require simulated BLE for the sim gate" >&2
  exit 1
fi
if [[ "$release_acceptance_dry_run" != *"--min-collections 7"* ]]; then
  echo "expected release acceptance dry-run to require seven collection events" >&2
  exit 1
fi
if [[ "$release_acceptance_dry_run" != *"tools/render_hunt_report.py"* ]]; then
  echo "expected release acceptance dry-run to render the field hunt report" >&2
  exit 1
fi
if [[ "$release_acceptance_dry_run" != *"field-hunt-report.json"* ]]; then
  echo "expected release acceptance dry-run to write the field hunt JSON report" >&2
  exit 1
fi
echo "release-acceptance-dry-run-ok"

log_step "Checking release acceptance mock self-test"
rm -rf output/release-acceptance-mock-test
RELEASE_ACCEPTANCE_MOCK=1 \
RELEASE_ACCEPTANCE_DIR=output/release-acceptance-mock-test \
RELEASE_DIR=output/release-current \
tools/run_release_acceptance.sh all >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
root = Path("output/release-acceptance-mock-test")
assert (root / "MOCK-NOT-HARDWARE.txt").exists()
bringup = json.loads((root / "bringup-diag-report.json").read_text())
sim = json.loads((root / "bench-sim-report.json").read_text())
beacons = json.loads((root / "beacon-set-verify-report.json").read_text())
hunt = json.loads((root / "field-hunt-report.json").read_text())
for report in (bringup, sim, beacons, hunt):
    assert report["status"] == "passed"
    assert report["hardware"] == {"audio": "online", "ble": "online", "imu": "online", "touch": "online"}
assert sim["simulatedBle"] is True
assert sim["collectionCount"] == 7
assert sim["summon"] is True
assert beacons["beaconCount"] == 7
assert hunt["collectionCount"] == 7
assert hunt["summon"] is True
assert (root / "field-hunt-report.md").exists()
assert (root / "field-hunt-bench-report.md").exists()
PY
echo "release-acceptance-mock-ok"

log_step "Checking hardware acceptance dry-run"
acceptance_dry_run="$(
  ACCEPTANCE_DRY_RUN=1 \
  ACCEPTANCE_DIR=output/hardware-acceptance-dry-run \
  RADAR_PORT=/dev/cu.test \
  tools/run_hardware_acceptance.sh all
)"
if [[ "$acceptance_dry_run" != *"DIAG_REPORT_JSON=output/hardware-acceptance-dry-run/bringup-diag-report.json"* ]]; then
  echo "expected acceptance dry-run to route bring-up report into the acceptance folder" >&2
  exit 1
fi
if [[ "$acceptance_dry_run" != *"SIM_REPORT_JSON=output/hardware-acceptance-dry-run/bench-sim-report.json"* ]]; then
  echo "expected acceptance dry-run to route sim report into the acceptance folder" >&2
  exit 1
fi
if [[ "$acceptance_dry_run" != *"BEACON_VERIFY_REPORT_JSON=output/hardware-acceptance-dry-run/beacon-set-verify-report.json"* ]]; then
  echo "expected acceptance dry-run to route beacon verification report into the acceptance folder" >&2
  exit 1
fi
if [[ "$acceptance_dry_run" != *"HUNT_MIN_COLLECTIONS=7"* ]]; then
  echo "expected acceptance dry-run to require seven field collection events" >&2
  exit 1
fi
if [[ "$acceptance_dry_run" != *"HUNT_REQUIRE_SUMMON=1"* ]]; then
  echo "expected acceptance dry-run to require summon in field hunt" >&2
  exit 1
fi
if [[ "$acceptance_dry_run" != *"tools/package_release.sh"* ]]; then
  echo "expected acceptance dry-run to refresh a release package" >&2
  exit 1
fi
echo "hardware-acceptance-dry-run-ok"

log_step "Checking release package dry-run"
release_dry_run="$(
  RELEASE_DRY_RUN=1 \
  RELEASE_BUILD=1 \
  RELEASE_DIR=output/release-dry-run \
  RELEASE_MODES="field fielddiag" \
  tools/package_release.sh
)"
if [[ "$release_dry_run" != *"package release into output/release-dry-run"* && "$release_dry_run" != *"package release into $ROOT_DIR/output/release-dry-run"* ]]; then
  echo "expected release dry-run to show the target release folder" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/build_radar.sh field"* ]]; then
  echo "expected release dry-run to build field firmware when RELEASE_BUILD=1" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/build_radar.sh fielddiag"* ]]; then
  echo "expected release dry-run to build fielddiag firmware when RELEASE_BUILD=1" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"Dragon Radar Release"* ]]; then
  echo "expected release dry-run to render a manifest" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"docs/board-sim-test.zh.md"* ]]; then
  echo "expected release dry-run to include the Chinese board simulation guide" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"docs/product-design.zh.md"* ]]; then
  echo "expected release dry-run to include the Chinese product design guide" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"docs/beacon-build.zh.md"* ]]; then
  echo "expected release dry-run to include the Chinese beacon build guide" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/generate_quickstart_zh.py"* ]]; then
  echo "expected release dry-run to generate the Chinese quickstart page" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/selftest_release.py"* ]]; then
  echo "expected release dry-run to include the release self-test helper" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/run_preboard_acceptance.py"* ]]; then
  echo "expected release dry-run to include and run the pre-board acceptance helper" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/first_run_zh.py"* ]]; then
  echo "expected release dry-run to include the Chinese first-run wizard" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/diagnose_usb_serial.py"* ]]; then
  echo "expected release dry-run to include the USB serial diagnosis helper" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/generate_usb_bringup_card.py"* ]]; then
  echo "expected release dry-run to generate the USB bring-up card" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/generate_refresh_perf_card.py"* ]]; then
  echo "expected release dry-run to generate the refresh performance card" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/send_diag_command.py"* ]]; then
  echo "expected release dry-run to include the DIAG command sender" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/run_no_reset_display_check.py"* ]]; then
  echo "expected release dry-run to include the no-Reset display check helper" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/analyze_board_photo.py"* ]]; then
  echo "expected release dry-run to include the board photo QA helper" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/wait_for_radar_port.py"* ]]; then
  echo "expected release dry-run to include the radar port wait helper" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/generate_field_kit.py"* ]]; then
  echo "expected release dry-run to generate the printable field kit" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/generate_play_cards.py"* ]]; then
  echo "expected release dry-run to generate the printable host/player cards" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/render_playtest_rehearsal.py"* ]]; then
  echo "expected release dry-run to generate the playtest rehearsal report" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/recommend_field_tuning.py"* ]]; then
  echo "expected release dry-run to generate the field tuning report" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/generate_motion_qa_sheet.py"* ]]; then
  echo "expected release dry-run to generate the motion QA storyboard" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/generate_motion_gifs.py"* ]]; then
  echo "expected release dry-run to generate the motion GIF previews" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/verify_motion_gifs.py"* ]]; then
  echo "expected release dry-run to verify the motion GIF sequence" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/generate_release_index.py"* ]]; then
  echo "expected release dry-run to generate the release index" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/generate_fidelity_review.py"* ]]; then
  echo "expected release dry-run to generate the UI fidelity review" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/render_goal_completion_audit.py"* ]]; then
  echo "expected release dry-run to render the goal completion audit" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/render_hardware_proof_packet.py"* ]]; then
  echo "expected release dry-run to render the hardware proof packet" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/verify_firmware_ui_contract.py"* ]]; then
  echo "expected release dry-run to verify the firmware UI contract" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/verify_ui_parity.py"* ]]; then
  echo "expected release dry-run to verify firmware/preview UI parity" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/verify_private_boot_logo.py"* ]]; then
  echo "expected release dry-run to verify the private boot logo boundary" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/install_private_boot_logo.py"* ]]; then
  echo "expected release dry-run to record private boot logo setup" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/verify_release_package.py"* ]]; then
  echo "expected release dry-run to verify the release package" >&2
  exit 1
fi
if [[ "$release_dry_run" != *"tools/smoke_preview_interactions.sh"* ]]; then
  echo "expected release dry-run to include the preview interaction smoke test" >&2
  exit 1
fi
echo "release-package-dry-run-ok"

log_step "Checking optional near release mode dry-run"
near_release_dry_run="$(
  RELEASE_DRY_RUN=1 \
  RELEASE_BUILD=1 \
  RELEASE_DIR=output/release-near-dry-run \
  RELEASE_MODES="near" \
  tools/package_release.sh
)"
if [[ "$near_release_dry_run" != *"tools/build_radar.sh near"* ]]; then
  echo "expected near release dry-run to build near firmware" >&2
  exit 1
fi
if [[ "$near_release_dry_run" != *"--modes near"* ]]; then
  echo "expected near release dry-run to verify with --modes near" >&2
  exit 1
fi
tools/generate_quickstart_zh.py --output output/quickstart-near-test.zh.html --release-dir output/release-current --modes near >/dev/null
tools/generate_release_index.py --output output/release-index-near-test.html --release-dir output/release-current --modes near >/dev/null
python3 - <<'PY'
import importlib.util
from pathlib import Path
spec = importlib.util.spec_from_file_location("verify_release_package", "tools/verify_release_package.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
assert module.parse_modes("near") == ("near",)
quickstart = Path("output/quickstart-near-test.zh.html").read_text()
index = Path("output/release-index-near-test.html").read_text()
assert "near" in quickstart
assert "小场地近距离" in quickstart
assert "dragon-radar-near-factory.bin" in quickstart
assert "tools/flash_release_firmware.sh near" in index
PY
echo "near-release-mode-ok"

log_step "Checking diagnostic simulator and monitor"
rm -f output/diag-simulator-report.json output/diag-simulator-report.md output/diag-simulator-raw.log
{
	  tools/simulate_diag_feed.py --beacons 2 --samples 10 --touch-events
	  printf '%s\n' "DIAG hunt session=1 event=start ms=100"
	  printf '%s\n' "DIAG collect DBALL-1 session=1 ms=4321 raw=-45 filtered=-48 range=0.20 bearingBin=2 bearing=56.2"
	  printf '%s\n' "DIAG command f action=frame_rate frameMs=33 framePreset=1"
	  printf '%s\n' "DIAG command t action=frame_turbo frameMs=25 framePreset=0"
	  printf '%s\n' "DIAG command z action=zoom"
	} | tools/monitor_diag.py --stdin --calibrate --require-online touch,imu,ble,audio --min-beacons 2 \
      --report-json output/diag-simulator-report.json --log-file output/diag-simulator-raw.log >/dev/null
tools/render_bench_report.py output/diag-simulator-report.json output/diag-simulator-report.md >/dev/null
rm -f output/diag-hunt-report.md
tools/render_hunt_report.py output/diag-simulator-report.json output/diag-hunt-report.md >/dev/null
rm -f output/field-tuning-test.md
tools/recommend_field_tuning.py output/diag-simulator-report.json --output-md output/field-tuning-test.md >/dev/null
rm -f output/diag-replay-report.json output/diag-replay-report.md
REPLAY_REQUIRE_ONLINE=touch,imu,ble,audio \
REPLAY_MIN_BEACONS=2 \
tools/replay_diag_log.sh output/diag-simulator-raw.log \
  output/diag-replay-report.json output/diag-replay-report.md >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
report = json.loads(Path("output/diag-simulator-report.json").read_text())
assert report["status"] == "passed"
assert report["beaconCount"] == 2
assert report["requirements"]["minBeacons"] == 2
assert report["requirements"]["minCollections"] == 0
assert report["requirements"]["requireCollectionSet"] is False
assert report["logFile"] == "output/diag-simulator-raw.log"
assert report["huntSession"] == 1
assert report["huntEvents"][0]["event"] == "start"
assert report["collectionCount"] == 1
assert report["collections"][0]["index"] == 1
assert report["collections"][0]["session"] == 1
assert report["collections"][0]["filtered"] == -48
assert report["frameMs"] == 25
assert report["drawMs"] == 18
assert report["drawAvgMs"] == 18
assert report["drawMaxMs"] == 20
assert report["overBudgetFrames"] == 0
assert report["frameSamples"] == 40
assert report["lastCommand"] == "z:zoom"
raw_log = Path("output/diag-simulator-raw.log").read_text()
assert "DIAG enabled" in raw_log
assert "DIAG BLE DBALL-1" in raw_log
assert "DIAG hunt session=1 event=start" in raw_log
assert "DIAG collect DBALL-1" in raw_log
assert "DIAG command f action=frame_rate frameMs=33 framePreset=1" in raw_log
assert "DIAG command t action=frame_turbo frameMs=25 framePreset=0" in raw_log
assert "DIAG command z action=zoom" in raw_log
markdown = Path("output/diag-simulator-report.md").read_text()
assert "Dragon Radar Bench Report" in markdown
assert "DBALL-1" in markdown
assert "Raw log: output/diag-simulator-raw.log" in markdown
assert "Frame performance: PASS" in markdown
assert "Over-budget frames: 0/40" in markdown
assert "Hunt session: 1" in markdown
assert "## Hunt Events" in markdown
assert "Minimum collection events" in markdown
assert "Collection events: 1" in markdown
assert "## Collections" in markdown
assert "Last command: `z:zoom`" in markdown
hunt_markdown = Path("output/diag-hunt-report.md").read_text()
assert "Dragon Radar Hunt Report" in hunt_markdown
assert "Collection Timeline" in hunt_markdown
assert "Missing Balls" in hunt_markdown
assert "DBALL-1" in hunt_markdown
tuning = Path("output/field-tuning-test.md").read_text()
assert "Dragon Radar Field Tuning" in tuning
assert "Recommended `COLLECT_RSSI`" in tuning
assert "tools/build_radar.sh field upload" in tuning
replay = json.loads(Path("output/diag-replay-report.json").read_text())
assert replay["status"] == "passed"
assert replay["beaconCount"] == 2
assert replay["logFile"] == "output/diag-simulator-raw.log"
assert replay["huntSession"] == 1
assert replay["collectionCount"] == 1
replay_markdown = Path("output/diag-replay-report.md").read_text()
assert "Raw log: output/diag-simulator-raw.log" in replay_markdown
assert "Hunt session: 1" in replay_markdown
assert "Collection events: 1" in replay_markdown
PY
rm -f output/refresh-performance-card-test.zh.md
tools/generate_refresh_perf_card.py \
  --output output/refresh-performance-card-test.zh.md \
  --diag-json output/diag-simulator-report.json \
  --runtime-json output/runtime-doctor-ready.json \
  --release-dir output/release-current >/dev/null
python3 - <<'PY'
from pathlib import Path
card = Path("output/refresh-performance-card-test.zh.md").read_text()
assert "龙珠雷达刷新率排障卡" in card
assert "刷新状态: `PASS`" in card
assert "frameMs" in card
assert "drawAvgMs" in card
assert "drawMaxMs" in card
assert "overBudget" in card
assert "tools/send_diag_command.py turbo" in card
assert "tools/send_diag_command.py frame" in card
assert "tools/monitor_diag.py" in card
assert "tools/recover_board_runtime.py" in card
assert "tools/first_run_zh.py live --recover-runtime" in card
assert "DISPLAY_BUS_HZ=40000000" in card
assert "硬件证明: `false`" in card
assert "不能单独证明 goal 完成" in card
PY
rm -f output/no-reset-display-check-test.json output/no-reset-display-check-test.zh.md output/no-reset-display-check-dry-run-test.json output/no-reset-display-check-dry-run-test.zh.md
tools/run_no_reset_display_check.py \
  --sample-report output/diag-simulator-report.json \
  --json-output output/no-reset-display-check-test.json \
  --md-output output/no-reset-display-check-test.zh.md >/dev/null
tools/run_no_reset_display_check.py \
  --dry-run \
  --json-output output/no-reset-display-check-dry-run-test.json \
  --md-output output/no-reset-display-check-dry-run-test.zh.md >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
report = json.loads(Path("output/no-reset-display-check-test.json").read_text())
dry = json.loads(Path("output/no-reset-display-check-dry-run-test.json").read_text())
markdown = Path("output/no-reset-display-check-test.zh.md").read_text()
dry_markdown = Path("output/no-reset-display-check-dry-run-test.zh.md").read_text()
assert report["status"] == "refresh-ready"
assert report["hardwareProof"] is False
assert report["liveSerialEvidence"] is False
assert report["sampleMode"] is True
assert report["command"] == "t"
assert report["commandConfirmed"] is True
assert report["parsed"]["frameMs"] == 25
assert report["parsed"]["drawAvgMs"] == 18
assert report["parsed"]["drawMaxMs"] == 20
assert report["parsed"]["overBudgetFrames"] == 0
assert "龙珠雷达无 Reset 显示检查报告" in markdown
assert "状态: `refresh-ready`" in markdown
assert "tools/run_no_reset_display_check.py --command turbo" in markdown
assert "tools/send_diag_command.py turbo" in markdown
assert "tools/recover_board_runtime.py" in markdown
assert "硬件证明: `false`" in markdown
assert "不能单独证明 goal 完成" in markdown
assert dry["status"] == "dry-run"
assert dry["hardwareProof"] is False
assert "未打开串口" in dry_markdown
PY
rm -f output/board-photo-qa-test.json output/board-photo-qa-test.zh.md
tools/analyze_board_photo.py output/playwright/radar-default.png \
  --json-output output/board-photo-qa-test.json \
  --md-output output/board-photo-qa-test.zh.md \
  --crop-output output/board-photo-qa-test-crop.png \
  --overlay-output output/board-photo-qa-test-overlay.png >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
from PIL import Image
report = json.loads(Path("output/board-photo-qa-test.json").read_text())
markdown = Path("output/board-photo-qa-test.zh.md").read_text()
assert report["status"] in {"passed", "warn"}
assert report["hardwareProof"] is False
assert report["photoEvidence"] is True
assert report["metrics"]["greenPixels"] >= 2000
assert report["metrics"]["orangePixels"] >= 4
names = {item["name"]: item["status"] for item in report["checks"]}
assert names["photo.screen-region.detected"] == "passed"
assert names["photo.rectangular-grid.present"] == "passed"
assert names["photo.orange-targets.present"] == "passed"
assert names["photo.goal-proof-boundary"] == "passed"
assert "board-photo-qa-test-crop.png" in report["visualArtifacts"]["crop"]
assert "board-photo-qa-test-overlay.png" in report["visualArtifacts"]["overlay"]
for path in ("output/board-photo-qa-test-crop.png", "output/board-photo-qa-test-overlay.png"):
    assert Path(path).stat().st_size > 1000
with Image.open("output/board-photo-qa-test-crop.png") as crop:
    assert crop.size[0] >= 250 and crop.size[1] >= 250
assert "龙珠雷达实拍屏幕 QA" in markdown
assert "可视化产物" in markdown
assert "board-photo-qa-test-crop.png" in markdown
assert "board-photo-qa-test-overlay.png" in markdown
assert "photo.rectangular-grid.present" in markdown
assert "photo.orange-targets.present" in markdown
assert "硬件证明: `false`" in markdown
assert "不能单独证明 goal 完成" in markdown
PY
rm -f output/hardware-proof-packet-test.json output/hardware-proof-packet-test.zh.md
tools/render_hardware_proof_packet.py \
  --json output/hardware-proof-packet-test.json \
  --md output/hardware-proof-packet-test.zh.md >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
packet = json.loads(Path("output/hardware-proof-packet-test.json").read_text())
markdown = Path("output/hardware-proof-packet-test.zh.md").read_text()
assert packet["status"] == "not-complete"
assert packet["hardwareProof"] is False
missing = set(packet["missingGateKeys"])
assert "seven_beacons" in missing
assert "field_hunt" in missing
gates = {item["key"]: item for item in packet["gates"]}
assert gates["release"]["status"] == "PASS"
assert gates["bringup"]["status"] in {"PASS", "WEAK", "MISSING"}
assert gates["sim_bench"]["status"] in {"PASS", "WEAK", "MISSING"}
assert gates["seven_beacons"]["status"] == "MISSING"
assert gates["field_hunt"]["status"] == "MISSING"
assert "龙珠雷达硬件证明包" in markdown
assert "总状态: `not-complete`" in markdown
assert "硬件证明: `false`" in markdown
assert "7 个实体信标可见" in markdown
assert "干净 UI 实战收集和召唤" in markdown
assert "tools/verify_beacon_set.sh all" in markdown
assert "tools/record_field_hunt.sh all" in markdown
assert "不能单独结束 goal" in markdown
PY
rm -f output/missing-hardware-gates-plan-test.json output/missing-hardware-gates-plan-test.zh.md
tools/run_missing_hardware_gates.py \
  --json-output output/missing-hardware-gates-plan-test.json \
  --md-output output/missing-hardware-gates-plan-test.zh.md \
  --radar-port /dev/cu.test >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
plan = json.loads(Path("output/missing-hardware-gates-plan-test.json").read_text())
markdown = Path("output/missing-hardware-gates-plan-test.zh.md").read_text()
assert plan["status"] == "planned"
assert plan["execute"] is False
assert plan["hardwareProof"] is False
selected = set(plan["selectedGateKeys"])
assert "seven_beacons" in selected
assert "field_hunt" in selected
commands = "\n".join(step["commandText"] for step in plan["steps"])
assert "RADAR_PORT=/dev/cu.test" in commands
assert "tools/verify_beacon_set.sh all" in commands
assert "tools/record_field_hunt.sh all" in commands
assert "BEACON_VERIFY_DRY_RUN=1" in commands
assert "HUNT_DRY_RUN=1" in commands
assert "龙珠雷达缺失硬件 Gate 收口计划" in markdown
assert "状态: `planned`" in markdown
assert "执行模式: `dry-run`" in markdown
assert "硬件证明: `false`" in markdown
assert "--execute" in markdown
assert "tools/verify_beacon_set.sh all" in markdown
assert "tools/record_field_hunt.sh all" in markdown
PY
{
  printf '%s\n' "DIAG enabled"
  printf '%s\n' "DIAG touch=online imu=online ble=online audio=online"
  printf '%s\n' "DIAG simulatedBle=enabled"
  printf '%s\n' "DIAG tick ms=1000 active=0 collected=7 zoom=0 brightPreset=1 audioPreset=2 heading=20.0 tilt=0.01 strongest=none online=TIBA summon=yes"
  printf '%s\n' "DIAG BLE DBALL-1 raw=-45 filtered=-48 range=0.20 bearingBin=2 bearing=56.2 close=yes"
} | tools/monitor_diag.py --stdin --require-simulated-ble --require-summon --min-collected 7 --min-beacons 1 >/dev/null
{
  printf '%s\n' "DIAG enabled"
  printf '%s\n' "DIAG touch=online imu=online ble=online audio=online"
  printf '%s\n' "DIAG tick ms=1000 active=0 collected=7 zoom=0 brightPreset=1 audioPreset=2 heading=20.0 tilt=0.01 strongest=none online=TIBA summon=yes"
  for i in 1 2 3 4 5 6 7; do
    printf 'DIAG collect DBALL-%s ms=%s raw=-45 filtered=-48 range=0.20 bearingBin=2 bearing=56.2\n' "$i" "$((1000 + i))"
  done
} | tools/monitor_diag.py --stdin --min-collections 7 --require-collection-set >/dev/null
if {
  printf '%s\n' "DIAG enabled"
  printf '%s\n' "DIAG touch=online imu=online ble=online audio=online"
  printf '%s\n' "DIAG hunt session=1 event=start ms=100"
  printf '%s\n' "DIAG collect DBALL-1 session=1 ms=1001 raw=-45 filtered=-48 range=0.20 bearingBin=2 bearing=56.2"
  printf '%s\n' "DIAG hunt session=2 event=reset ms=2000"
  printf '%s\n' "DIAG collect DBALL-2 session=2 ms=2001 raw=-45 filtered=-48 range=0.20 bearingBin=2 bearing=56.2"
} | tools/monitor_diag.py --stdin --min-collections 2 >/dev/null 2>&1; then
  echo "expected reset to clear previous-session collection events" >&2
  exit 1
fi
if {
  printf '%s\n' "DIAG enabled"
  printf '%s\n' "DIAG touch=online imu=online ble=online audio=online"
  printf '%s\n' "DIAG tick ms=1000 active=0 collected=6 zoom=0 brightPreset=1 audioPreset=2 heading=20.0 tilt=0.01 strongest=none online=TIBA summon=no"
  printf '%s\n' "DIAG collect DBALL-1 ms=1001 raw=-45 filtered=-48 range=0.20 bearingBin=2 bearing=56.2"
} | tools/monitor_diag.py --stdin --min-collections 7 --require-collection-set >/dev/null 2>&1; then
  echo "expected incomplete collection event set to fail" >&2
  exit 1
fi
if tools/simulate_diag_feed.py --beacons 1 --samples 4 --offline imu \
  | tools/monitor_diag.py --stdin --require-online touch,imu,ble,audio --min-beacons 1 >/dev/null 2>&1; then
  echo "expected offline IMU diagnostic simulation to fail" >&2
  exit 1
fi
if {
  printf '%s\n' "DIAG enabled"
  printf '%s\n' "DIAG touch=online imu=online ble=online audio=online"
  printf '%s\n' "DIAG BLE DBALL-1 raw=-45 filtered=-48 range=0.20 bearingBin=2 bearing=56.2 close=yes"
} | tools/monitor_diag.py --stdin --require-simulated-ble --min-beacons 1 >/dev/null 2>&1; then
  echo "expected missing simulated BLE marker to fail" >&2
  exit 1
fi
if {
  printf '%s\n' "DIAG enabled"
  printf '%s\n' "DIAG touch=online imu=online ble=online audio=online"
  printf '%s\n' "DIAG simulatedBle=enabled"
  printf '%s\n' "DIAG tick ms=1000 active=1 collected=6 zoom=0 brightPreset=1 audioPreset=2 heading=20.0 tilt=0.01 strongest=1/-45 online=TIBA summon=no"
} | tools/monitor_diag.py --stdin --require-summon --min-collected 7 >/dev/null 2>&1; then
  echo "expected incomplete simulated summon to fail" >&2
  exit 1
fi
echo "diag-simulator-ok"

log_step "Capturing and verifying visual QA frames"
tools/capture_preview_screenshots.sh
rm -f output/preview-visual-audit.json output/preview-visual-audit.md
tools/verify_preview_visuals.py --json output/preview-visual-audit.json --md output/preview-visual-audit.md
python3 - <<'PY'
import json
from pathlib import Path

def require(name, condition):
    if not condition:
        raise AssertionError(name)

audit = json.loads(Path("output/preview-visual-audit.json").read_text())
require("visual audit status passed", audit["status"] == "passed")
require("visual audit check count", len(audit["checks"]) >= 79)
md = Path("output/preview-visual-audit.md").read_text()
require("visual audit markdown title", "Dragon Radar Preview Visual Audit" in md)
require("visual audit markdown status", "Status: PASSED" in md)
require("visual audit markdown idle frame", "radar-idle-search.png" in md)
require("visual audit markdown zoom frame", "radar-zoom-map.png" in md)
require("visual audit markdown ring coverage", "max green ring coverage" in md)
require("field screen orange quiet", audit["metrics"]["radar-field.png"]["screen"]["orange"] <= 50)
require("startup acquire green", audit["metrics"]["radar-startup-acquire.png"]["startupAcquire"]["green"] > 600)
require("startup screen orange quiet", audit["metrics"]["radar-startup-acquire.png"]["screen"]["orange"] <= 50)
require("idle screen green", audit["metrics"]["radar-idle-search.png"]["screen"]["green"] > 3500)
require("idle search green", audit["metrics"]["radar-idle-search.png"]["idleSearch"]["green"] > 2500)
require("idle screen orange quiet", audit["metrics"]["radar-idle-search.png"]["screen"]["orange"] <= 50)
require("acquisition echo green", audit["metrics"]["radar-acquisition-echo.png"]["acquisitionEcho"]["green"] > 220)
require("acquisition echo orange", audit["metrics"]["radar-acquisition-echo.png"]["acquisitionEcho"]["orange"] > 80)
require("target trail pixels", audit["metrics"]["radar-target-trail.png"]["targetTrail"]["trail"] > 45)
require("target trail orange", audit["metrics"]["radar-target-trail.png"]["targetTrail"]["orange"] > 60)
require("trace blip pixels", audit["metrics"]["radar-trace-blip.png"]["traceBlip"]["trace"] > 60)
require("trace blip orange quiet", audit["metrics"]["radar-trace-blip.png"]["traceBlip"]["orange"] <= 40)
require("zoom screen green", audit["metrics"]["radar-zoom-map.png"]["screen"]["green"] > 5500)
require("zoom grid green", audit["metrics"]["radar-zoom-map.png"]["zoomGrid"]["green"] > 4500)
require("zoom screen orange", audit["metrics"]["radar-zoom-map.png"]["screen"]["orange"] > 500)
require("proximity lock green", audit["metrics"]["radar-proximity-lock.png"]["proximityLock"]["green"] > 180)
require("capture burst green", audit["metrics"]["radar-capture-burst.png"]["captureBurst"]["green"] > 220)
require("control zoom green", audit["metrics"]["radar-control-flashes.png"]["zoom"]["green"] > 120)
require("control brightness green", audit["metrics"]["radar-control-flashes.png"]["brightness"]["green"] > 90)
require("control audio green", audit["metrics"]["radar-control-flashes.png"]["audio"]["green"] > 70)
require("touch echo green", audit["metrics"]["radar-touch-echo.png"]["touchEcho"]["green"] > 250)
require("tilt inertia green", audit["metrics"]["radar-tilt-inertia.png"]["inertiaCorners"]["green"] > 900)
require("boot logo blue", audit["metrics"]["boot-logo-scan.png"]["logo"]["blue"] > 4000)
require("boot progress ticks", min(audit["metrics"]["boot-logo-ready.png"]["progressTicks"]) > 12)
require("field ring coverage", audit["ringCoverage"]["radar-field.png"] < 0.12)
PY
rm -f output/visual-qa.html
tools/generate_visual_qa_sheet.py --output output/visual-qa.html --image-dir output/playwright >/dev/null
rm -f output/playwright/boot-motion.gif output/playwright/radar-motion.gif output/playwright/summon-motion.gif
tools/generate_motion_gifs.py --image-dir output/playwright --output-dir output/playwright >/dev/null
rm -f output/motion-gif-audit.json output/motion-gif-audit.md
tools/verify_motion_gifs.py output/playwright --json output/motion-gif-audit.json --md output/motion-gif-audit.md >/dev/null
rm -f output/motion-qa.html
tools/generate_motion_qa_sheet.py --output output/motion-qa.html --image-dir output/playwright >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
html = Path("output/visual-qa.html").read_text()
assert "Dragon Radar Visual QA" in html
assert "Boot Logo Scan" in html
assert "Field Radar" in html
assert "Summon Orbit" in html
assert "Status: PASS" in html
assert "boot-logo-scan.png" in html
assert "radar-field.png" in html
assert "radar-startup-acquire.png" in html
assert "radar-idle-search.png" in html
assert "radar-acquisition-echo.png" in html
assert "radar-target-trail.png" in html
assert "radar-trace-blip.png" in html
assert "radar-zoom-map.png" in html
assert "radar-proximity-lock.png" in html
assert "radar-capture-burst.png" in html
assert "radar-control-flashes.png" in html
assert "radar-touch-echo.png" in html
assert "radar-tilt-inertia.png" in html
assert "summon-orbit.png" in html
assert Path("output/playwright/boot-motion.gif").stat().st_size > 10000
assert Path("output/playwright/radar-motion.gif").stat().st_size > 10000
assert Path("output/playwright/summon-motion.gif").stat().st_size > 10000
motion_audit = json.loads(Path("output/motion-gif-audit.json").read_text())
assert motion_audit["status"] == "passed"
assert len(motion_audit["checks"]) >= 40
assert motion_audit["metrics"]["boot-motion.gif"]["frames"][0]["logo"]["blue"] <= 100
assert motion_audit["metrics"]["boot-motion.gif"]["frames"][2]["logo"]["blue"] > 7500
assert motion_audit["metrics"]["radar-motion.gif"]["frames"][0]["screen"]["orange"] <= 50
assert motion_audit["metrics"]["radar-motion.gif"]["frames"][2]["screen"]["orange"] > 300
assert motion_audit["metrics"]["summon-motion.gif"]["frames"][1]["center"]["orange"] > 300
motion_audit_md = Path("output/motion-gif-audit.md").read_text()
assert "Dragon Radar Motion GIF Audit" in motion_audit_md
assert "Status: PASSED" in motion_audit_md
assert "boot stage 0 grid wake" in motion_audit_md
assert "radar stage 2 acquisition" in motion_audit_md
assert "summon orbit stage" in motion_audit_md
motion = Path("output/motion-qa.html").read_text()
assert "Dragon Radar Motion QA" in motion
assert "可播放动画预览" in motion
assert "开机动画" in motion
assert "可玩雷达模式" in motion
assert "七球完成动画" in motion
assert "Status: PASS" in motion
assert "boot-motion.gif" in motion
assert "radar-motion.gif" in motion
assert "summon-motion.gif" in motion
assert "boot-logo-ready.png" in motion
assert "summon-gather.png" in motion
PY
rm -f output/fidelity-review.zh.md
tools/generate_fidelity_review.py --output output/fidelity-review.zh.md --image-prefix playwright >/dev/null
python3 - <<'PY'
from pathlib import Path
review = Path("output/fidelity-review.zh.md").read_text()
assert "龙珠雷达 UI 还原度评审" in review
assert "软件 UI 还原度: PASS" in review
assert "运动 GIF 检查" in review
assert "开机动画运动顺序" in review
assert "胶囊风格开机标志" in review
assert "矩形网格而非圆环雷达" in review
assert "radar-zoom-map.png" in review
assert "summon-orbit.png" in review
PY
rm -f output/game-cards.html
tools/generate_play_cards.py --output output/game-cards.html --release-dir output/release-current --players 悟空,布玛 --area 西都公园 >/dev/null
python3 - <<'PY'
from pathlib import Path
cards = Path("output/game-cards.html").read_text()
assert "龙珠雷达试玩卡" in cards
assert "主持人开局卡" in cards
assert "玩家规则卡" in cards
assert "DBALL-7" in cards
assert "西都公园" in cards
assert "悟空" in cards
assert "UI 还原度评审" in cards
assert "缺失" not in cards
PY
rm -rf output/preboard-acceptance-current
tools/run_preboard_acceptance.py \
  --release-dir output/release-current \
  --output-dir output/preboard-acceptance-current \
  --mock-timeout 8 \
  --samples 16 >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
summary = json.loads(Path("output/preboard-acceptance-current/preboard-acceptance-summary.json").read_text())
markdown = Path("output/preboard-acceptance-current/preboard-acceptance.zh.md").read_text()
assert summary["status"] == "passed"
assert summary["hardwareProof"] is False
assert summary["checks"]["diagSevenBallReplay"]["beaconCount"] == 7
assert summary["checks"]["diagSevenBallReplay"]["collectionCount"] == 7
assert "龙珠雷达上板前模拟验收报告" in markdown
assert "不能替代 ESP32-S3 真板" in markdown
PY
rm -f output/goal-completion-audit.json output/goal-completion-audit.zh.md
tools/render_goal_completion_audit.py --json output/goal-completion-audit.json --md output/goal-completion-audit.zh.md >/dev/null
python3 - <<'PY'
import json
from pathlib import Path
audit = json.loads(Path("output/goal-completion-audit.json").read_text())
markdown = Path("output/goal-completion-audit.zh.md").read_text()
assert audit["status"] == "not-complete"
assert audit["complete"] is False
assert len(audit["requirements"]) >= 6
assert any(
    item["key"] == "hardware"
    and item["passed"] is False
    and item["status"] in ("NOT PROVEN", "WEAK")
    for item in audit["requirements"]
)
assert "龙珠雷达 Goal 完成度审计" in markdown
assert "真实上板硬件证明" in markdown
assert "当前不能结束 goal" in markdown
PY

log_step "Rendering project status"
tools/verify_private_boot_logo.py --release-dir output/release-current --json output/private-boot-logo-audit.json --md output/private-boot-logo-audit.md >/dev/null
tools/install_private_boot_logo.py status --json-output output/private-boot-logo-setup.json --md-output output/private-boot-logo-setup.md >/dev/null
tools/generate_refresh_perf_card.py --output output/refresh-performance-card.zh.md --diag-json output/diag-simulator-report.json --runtime-json output/runtime-doctor-ready.json --release-dir output/release-current >/dev/null
tools/run_no_reset_display_check.py --sample-report output/diag-simulator-report.json --json-output output/no-reset-display-check.json --md-output output/no-reset-display-check.zh.md >/dev/null
tools/analyze_board_photo.py output/playwright/radar-default.png --json-output output/board-photo-qa-sample.json --md-output output/board-photo-qa-sample.zh.md --crop-output output/board-photo-qa-sample-crop.png --overlay-output output/board-photo-qa-sample-overlay.png >/dev/null
tools/render_hardware_proof_packet.py --json output/hardware-proof-packet.json --md output/hardware-proof-packet.zh.md >/dev/null
tools/run_missing_hardware_gates.py --json-output output/missing-hardware-gates-plan.json --md-output output/missing-hardware-gates-plan.zh.md >/dev/null
tools/render_project_status.py --output output/project-status.md >/dev/null
python3 - <<'PY'
from pathlib import Path
status = Path("output/project-status.md").read_text()
assert "Dragon Radar Project Status" in status
assert "docs/board-sim-test.zh.md" in status
assert "docs/product-design.zh.md" in status
assert "docs/beacon-build.zh.md" in status
assert "tools/generate_quickstart_zh.py" in status
assert "tools/generate_play_cards.py" in status
assert "tools/generate_motion_gifs.py" in status
assert "tools/verify_motion_gifs.py" in status
assert "tools/generate_motion_qa_sheet.py" in status
assert "tools/generate_fidelity_review.py" in status
assert "tools/render_goal_completion_audit.py" in status
assert "tools/render_hardware_proof_packet.py" in status
assert "tools/run_missing_hardware_gates.py" in status
assert "tools/run_preboard_acceptance.py" in status
assert "tools/recommend_field_tuning.py" in status
assert "tools/first_run_zh.py" in status
assert "tools/diagnose_usb_serial.py" in status
assert "tools/recover_board_runtime.py" in status
assert "tools/send_diag_command.py" in status
assert "tools/run_no_reset_display_check.py" in status
assert "tools/analyze_board_photo.py" in status
assert "tools/generate_usb_bringup_card.py" in status
assert "tools/generate_refresh_perf_card.py" in status
assert "tools/wait_for_radar_port.py" in status
assert "tools/smoke_preview_interactions.sh" in status
assert "tools/verify_ui_parity.py" in status
assert "tools/verify_private_boot_logo.py" in status
assert "tools/install_private_boot_logo.py" in status
assert "Hardware completion: NOT PROVEN" in status or "Hardware completion: PASS" in status
assert "Firmware UI contract" in status
assert "Firmware/preview parity" in status
assert "Motion GIF evidence: PASS" in status
assert "Motion GIF audit: PASS" in status
assert "Motion GIFs" in status
assert "boot-motion.gif" in status
assert "radar-motion.gif" in status
assert "summon-motion.gif" in status
assert "Motion GIF sequence audit" in status
assert "output/motion-gif-audit.json" in status
assert "UI fidelity review: PASS" in status
assert "output/fidelity-review.zh.md" in status
assert "Pre-board acceptance: PASS" in status
assert "Refresh performance diagnostics: PASS" in status
assert "Refresh performance card: PASS" in status
assert "No-Reset display check: PASS" in status
assert "Board photo QA sample: PASS" in status
assert "Hardware proof packet: PASS" in status
assert "Missing hardware gate plan: PASS" in status
assert "output/preboard-acceptance-current/preboard-acceptance-summary.json" in status
assert "output/diag-simulator-report.json" in status
assert "output/refresh-performance-card.zh.md" in status
assert "output/no-reset-display-check.json" in status
assert "output/board-photo-qa-sample.json" in status
assert "output/hardware-proof-packet.json" in status
assert "output/missing-hardware-gates-plan.json" in status
assert "board-photo-qa-sample-crop.png" in status
assert "board-photo-qa-sample-overlay.png" in status
assert "frameMs=25" in status
assert "drawAvgMs=18" in status
assert "overBudget=0/40" in status
assert "Field tuning recommendation" in status
assert "output/field-tuning-report.md" in status
assert "Mock one-board simulation" in status
assert "output/preboard-acceptance-current/release-selftest/board-sim-mock/bench-sim-report.json" in status
assert "Real one-board simulated bench" in status
assert "Goal completion audit: NOT-COMPLETE" in status
assert "output/goal-completion-audit.json" in status
assert "Release package evidence: PASS" in status
assert "Release Packages" in status
assert "output/release-current/RELEASE_AUDIT.json" in status
assert "output/release-near-current/RELEASE_AUDIT.json" in status
assert "preview=21/21" in status
assert "gifs=3/3" in status
assert "Private boot logo" in status
assert "Private boot logo setup: PASS" in status
assert "output/private-boot-logo-setup.json" in status
assert "USB serial diagnosis" in status
assert "Remaining Before Goal Complete" in status
assert "tools/run_missing_hardware_gates.py --execute" in status
assert "tools/run_hardware_acceptance.sh all" in status
assert "tools/run_release_acceptance.sh all" in status
assert "tools/record_field_hunt.sh all" in status
PY

log_step "Checking README documents verifier chain"
python3 - <<'PY'
from pathlib import Path
readme = Path("README.md").read_text()
for required in (
	    "tools/verify_ui_parity.py",
	    "tools/install_private_boot_logo.py",
	    "output/firmware-preview-parity.json",
	    "output/private-boot-logo-setup.json",
	    "firmware/preview parity audit",
	    "evidence/private-boot-logo-setup.json",
    "evidence/firmware-preview-parity.json",
    "tools/diagnose_usb_serial.py",
    "tools/diagnose_board_runtime.py",
    "tools/recover_board_runtime.py",
    "tools/wait_for_radar_port.py",
    "tools/send_diag_command.py frame",
    "tools/send_diag_command.py turbo",
    "tools/run_no_reset_display_check.py",
    "tools/analyze_board_photo.py",
    "--crop-output",
    "--overlay-output",
    "frameMs=25",
    "drawMs",
    "drawAvgMs",
    "25/33/50/65/80/120ms",
    "DISPLAY_BUS_HZ=40000000",
    "usb-serial-present-no-runtime",
    "evidence/usb-serial-diagnosis.zh.md",
    "tools/generate_usb_bringup_card.py",
    "tools/generate_refresh_perf_card.py",
    "docs/usb-bringup-card.zh.md",
    "docs/refresh-performance-card.zh.md",
    "docs/no-reset-display-check.zh.md",
    "docs/board-photo-qa-sample.zh.md",
    "output/refresh-performance-card.zh.md",
    "output/no-reset-display-check.zh.md",
    "output/board-photo-qa-sample.zh.md",
    "output/board-photo-qa-sample-crop.png",
    "output/board-photo-qa-sample-overlay.png",
    "output/preview-visual-audit.md",
    "evidence/preview-visual-audit.md",
    "tools/generate_fidelity_review.py",
    "tools/generate_play_cards.py",
    "tools/render_goal_completion_audit.py",
    "tools/render_hardware_proof_packet.py",
    "tools/run_missing_hardware_gates.py",
    "tools/run_preboard_acceptance.py",
    "docs/fidelity-review.zh.md",
    "docs/game-cards.html",
    "docs/goal-completion-audit.zh.md",
    "docs/hardware-proof-packet.zh.md",
    "docs/missing-hardware-gates-plan.zh.md",
    "docs/preboard-acceptance.zh.md",
    "output/goal-completion-audit.json",
    "output/hardware-proof-packet.json",
    "output/missing-hardware-gates-plan.json",
    "output/preboard-acceptance-current/preboard-acceptance-summary.json",
):
    assert required in readme
PY
echo "readme-verifier-chain-ok"

if [[ "$MODE" == "firmware" || "$MODE" == "full" ]]; then
  export PIO_BIN="$(find_pio)"
  log_step "Building field radar firmware with $PIO_BIN"
  tools/build_radar.sh field
  log_step "Building field diagnostic recorder firmware with $PIO_BIN"
  tools/build_radar.sh fielddiag
  log_step "Building debug radar firmware with $PIO_BIN"
  tools/build_radar.sh debug
  log_step "Building diagnostic radar firmware with $PIO_BIN"
  tools/build_radar.sh diag
  log_step "Building simulated-beacon radar firmware with $PIO_BIN"
  tools/build_radar.sh sim
fi

if [[ "$MODE" == "full" ]]; then
  export PIO_BIN="$(find_pio)"
  log_step "Building all BLE beacon firmware images with $PIO_BIN"
  tools/build_beacons.sh
fi

log_step "Verification complete: $MODE"
