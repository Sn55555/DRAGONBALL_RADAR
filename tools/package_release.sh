#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/package_release.sh

Creates a release folder with built radar firmware artifacts, preview evidence,
diagnostic reports, labels, and a manifest for flashing and field validation.

Environment:
  RELEASE_DIR        Output folder, default: output/release/dragon-radar-<timestamp>
  RELEASE_MODES      Radar modes to package, default: field fielddiag diag sim
  RELEASE_BUILD      1 to build RELEASE_MODES before packaging, default: 0
  RELEASE_STRICT     1 to fail when any requested firmware mode is missing.
                     Defaults to RELEASE_BUILD.
  RELEASE_DRY_RUN    1 to print actions without writing files, default: 0
  RELEASE_TAR        1 to create <RELEASE_DIR>.tar.gz after packaging, default: 0
  PIO_BIN            PlatformIO executable, forwarded to tools/build_radar.sh

Examples:
  tools/package_release.sh
  RELEASE_BUILD=1 tools/package_release.sh
  RELEASE_DIR=output/release/fielddiag RELEASE_MODES=fielddiag tools/package_release.sh
  RELEASE_DRY_RUN=1 RELEASE_BUILD=1 tools/package_release.sh
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 0 ]]; then
  usage >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/output/release/dragon-radar-$TIMESTAMP}"
RELEASE_MODES="${RELEASE_MODES:-field fielddiag diag sim}"
RELEASE_BUILD="${RELEASE_BUILD:-0}"
RELEASE_STRICT="${RELEASE_STRICT:-$RELEASE_BUILD}"
RELEASE_DRY_RUN="${RELEASE_DRY_RUN:-0}"
RELEASE_TAR="${RELEASE_TAR:-0}"

if [[ "$RELEASE_DIR" != /* ]]; then
  RELEASE_DIR="$ROOT_DIR/$RELEASE_DIR"
fi

for flag in RELEASE_BUILD RELEASE_STRICT RELEASE_DRY_RUN RELEASE_TAR; do
  value="${!flag}"
  if [[ "$value" != "0" && "$value" != "1" ]]; then
    echo "$flag must be 0 or 1, got: $value" >&2
    exit 2
  fi
done

mode_env() {
  case "$1" in
    default) printf '%s\n' "esp32-s3-touch-amoled-175c" ;;
    field) printf '%s\n' "esp32-s3-touch-amoled-175c-field" ;;
    fielddiag) printf '%s\n' "esp32-s3-touch-amoled-175c-fielddiag" ;;
    near) printf '%s\n' "esp32-s3-touch-amoled-175c-near" ;;
    debug) printf '%s\n' "esp32-s3-touch-amoled-175c-debug" ;;
    diag) printf '%s\n' "esp32-s3-touch-amoled-175c-diag" ;;
    sim) printf '%s\n' "esp32-s3-touch-amoled-175c-sim" ;;
    *)
      echo "Unknown radar mode: $1" >&2
      exit 2
      ;;
  esac
}

run_cmd() {
  if [[ "$RELEASE_DRY_RUN" == "1" ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

copy_file() {
  local source="$1"
  local target="$2"
  if [[ ! -f "$source" ]]; then
    return 1
  fi
  if [[ "$RELEASE_DRY_RUN" == "1" ]]; then
    printf 'copy %s -> %s\n' "$source" "$target"
  else
    mkdir -p "$(dirname "$target")"
    cp "$source" "$target"
  fi
  return 0
}

write_manifest_line() {
  if [[ "$RELEASE_DRY_RUN" == "1" ]]; then
    printf 'manifest %s\n' "$1"
  else
    printf '%s\n' "$1" >> "$MANIFEST"
  fi
}

mkdir_release() {
  if [[ "$RELEASE_DRY_RUN" == "1" ]]; then
    printf 'package release into %s\n' "$RELEASE_DIR"
  else
    rm -rf "$RELEASE_DIR"
    mkdir -p "$RELEASE_DIR/firmware" "$RELEASE_DIR/evidence" "$RELEASE_DIR/preview" "$RELEASE_DIR/docs" "$RELEASE_DIR/tools"
  fi
}

IFS=' ' read -r -a MODES <<< "$RELEASE_MODES"
if [[ "${#MODES[@]}" -eq 0 ]]; then
  echo "RELEASE_MODES must name at least one radar mode" >&2
  exit 2
fi
PLAYABLE_MODE="field"
if [[ "${#MODES[@]}" -eq 1 && "${MODES[0]}" == "near" ]]; then
  PLAYABLE_MODE="near"
fi

cd "$ROOT_DIR"

if [[ "$RELEASE_BUILD" == "1" ]]; then
  for mode in "${MODES[@]}"; do
    mode_env "$mode" >/dev/null
    run_cmd env PIO_BIN="${PIO_BIN:-}" "$ROOT_DIR/tools/build_radar.sh" "$mode"
  done
fi

if [[ "$RELEASE_DRY_RUN" == "1" ]]; then
  printf '+ %q --json %q --md %q\n' "$ROOT_DIR/tools/verify_preview_visuals.py" "output/preview-visual-audit.json" "output/preview-visual-audit.md"
  printf '+ %q --json %q\n' "$ROOT_DIR/tools/verify_firmware_ui_contract.py" "output/firmware-ui-contract.json"
  printf '+ %q --json %q\n' "$ROOT_DIR/tools/verify_ui_parity.py" "output/firmware-preview-parity.json"
  printf '+ %q --json %q --md %q\n' "$ROOT_DIR/tools/verify_private_boot_logo.py" "output/private-boot-logo-audit.json" "output/private-boot-logo-audit.md"
  printf '+ %q status --json-output %q --md-output %q\n' "$ROOT_DIR/tools/install_private_boot_logo.py" "output/private-boot-logo-setup.json" "output/private-boot-logo-setup.md"
  printf '+ %q --json-output %q --md-output %q\n' "$ROOT_DIR/tools/diagnose_usb_serial.py" "output/usb-serial-diagnosis.json" "output/usb-serial-diagnosis.zh.md"
  printf '+ %q --output %q --diagnosis-json %q --release-dir %q\n' "$ROOT_DIR/tools/generate_usb_bringup_card.py" "output/usb-bringup-card.zh.md" "output/usb-serial-diagnosis.json" "output/release-current"
  printf '+ %q --output %q --diag-json %q --runtime-json %q --release-dir %q\n' "$ROOT_DIR/tools/generate_refresh_perf_card.py" "output/refresh-performance-card.zh.md" "output/diag-simulator-report.json" "output/board-runtime-diagnosis.json" "output/release-current"
  printf '+ %q --sample-report %q --json-output %q --md-output %q\n' "$ROOT_DIR/tools/run_no_reset_display_check.py" "output/diag-simulator-report.json" "output/no-reset-display-check.json" "output/no-reset-display-check.zh.md"
  printf '+ %q %q --json-output %q --md-output %q --crop-output %q --overlay-output %q\n' "$ROOT_DIR/tools/analyze_board_photo.py" "output/playwright/radar-default.png" "output/board-photo-qa-sample.json" "output/board-photo-qa-sample.zh.md" "output/board-photo-qa-sample-crop.png" "output/board-photo-qa-sample-overlay.png"
  printf '+ %q --json %q --md %q\n' "$ROOT_DIR/tools/render_hardware_proof_packet.py" "output/hardware-proof-packet.json" "output/hardware-proof-packet.zh.md"
  printf '+ %q --json-output %q --md-output %q\n' "$ROOT_DIR/tools/run_missing_hardware_gates.py" "output/missing-hardware-gates-plan.json" "output/missing-hardware-gates-plan.zh.md"
  printf '+ %q --output %q\n' "$ROOT_DIR/tools/render_project_status.py" "output/project-status.md"
  printf '+ %q --output %q --image-prefix %q\n' "$ROOT_DIR/tools/generate_fidelity_review.py" "output/fidelity-review.zh.md" "playwright"
  printf '+ %q --output %q\n' "$ROOT_DIR/tools/render_project_status.py" "output/project-status.md"
  printf '+ %q --json %q --md %q\n' "$ROOT_DIR/tools/render_goal_completion_audit.py" "output/goal-completion-audit.json" "output/goal-completion-audit.zh.md"
  printf '+ %q --output %q\n' "$ROOT_DIR/tools/render_project_status.py" "output/project-status.md"
  printf '+ %q --output %q --release-dir %q\n' "$ROOT_DIR/tools/render_playtest_rehearsal.py" "output/playtest-rehearsal.zh.md" "$RELEASE_DIR"
else
  "$ROOT_DIR/tools/verify_preview_visuals.py" --json output/preview-visual-audit.json --md output/preview-visual-audit.md >/dev/null
  "$ROOT_DIR/tools/verify_firmware_ui_contract.py" --json output/firmware-ui-contract.json >/dev/null
  "$ROOT_DIR/tools/verify_ui_parity.py" --json output/firmware-preview-parity.json >/dev/null
  "$ROOT_DIR/tools/verify_private_boot_logo.py" --json output/private-boot-logo-audit.json --md output/private-boot-logo-audit.md >/dev/null
  "$ROOT_DIR/tools/install_private_boot_logo.py" status --json-output output/private-boot-logo-setup.json --md-output output/private-boot-logo-setup.md >/dev/null
  "$ROOT_DIR/tools/diagnose_usb_serial.py" --json-output output/usb-serial-diagnosis.json --md-output output/usb-serial-diagnosis.zh.md >/dev/null
  "$ROOT_DIR/tools/generate_usb_bringup_card.py" --output output/usb-bringup-card.zh.md --diagnosis-json output/usb-serial-diagnosis.json --release-dir output/release-current >/dev/null
  "$ROOT_DIR/tools/generate_refresh_perf_card.py" --output output/refresh-performance-card.zh.md --diag-json output/diag-simulator-report.json --runtime-json output/board-runtime-diagnosis.json --release-dir output/release-current >/dev/null
  "$ROOT_DIR/tools/run_no_reset_display_check.py" --sample-report output/diag-simulator-report.json --json-output output/no-reset-display-check.json --md-output output/no-reset-display-check.zh.md >/dev/null
  "$ROOT_DIR/tools/analyze_board_photo.py" output/playwright/radar-default.png --json-output output/board-photo-qa-sample.json --md-output output/board-photo-qa-sample.zh.md --crop-output output/board-photo-qa-sample-crop.png --overlay-output output/board-photo-qa-sample-overlay.png >/dev/null
  "$ROOT_DIR/tools/render_hardware_proof_packet.py" --json output/hardware-proof-packet.json --md output/hardware-proof-packet.zh.md >/dev/null
  "$ROOT_DIR/tools/run_missing_hardware_gates.py" --json-output output/missing-hardware-gates-plan.json --md-output output/missing-hardware-gates-plan.zh.md >/dev/null
  "$ROOT_DIR/tools/render_project_status.py" --output output/project-status.md >/dev/null
  "$ROOT_DIR/tools/generate_fidelity_review.py" --output output/fidelity-review.zh.md --image-prefix playwright >/dev/null
  "$ROOT_DIR/tools/render_project_status.py" --output output/project-status.md >/dev/null
  "$ROOT_DIR/tools/render_goal_completion_audit.py" --json output/goal-completion-audit.json --md output/goal-completion-audit.zh.md >/dev/null
  "$ROOT_DIR/tools/render_project_status.py" --output output/project-status.md >/dev/null
fi

mkdir_release
MANIFEST="$RELEASE_DIR/MANIFEST.md"
if [[ "$RELEASE_DRY_RUN" == "0" ]]; then
  : > "$MANIFEST"
fi

write_manifest_line "# Dragon Radar Release"
write_manifest_line ""
write_manifest_line "- Generated: $(date '+%Y-%m-%d %H:%M:%S')"
write_manifest_line "- Source: $ROOT_DIR"
write_manifest_line "- Release folder: $RELEASE_DIR"
write_manifest_line "- Requested radar modes: $RELEASE_MODES"
write_manifest_line "- Built before package: $RELEASE_BUILD"
write_manifest_line "- Strict firmware check: $RELEASE_STRICT"
write_manifest_line ""
write_manifest_line "## Radar Firmware"
write_manifest_line ""
write_manifest_line "| Mode | PlatformIO env | firmware.bin | factory bin | ELF | Status |"
write_manifest_line "| --- | --- | --- | --- | --- | --- |"

copied_firmware=0
missing_modes=0
for mode in "${MODES[@]}"; do
  env_name="$(mode_env "$mode")"
  build_dir="$ROOT_DIR/.pio/build/$env_name"
  bin_source="$build_dir/firmware.bin"
  factory_source="$build_dir/firmware.factory.bin"
  elf_source="$build_dir/firmware.elf"
  bin_target="$RELEASE_DIR/firmware/dragon-radar-$mode.bin"
  factory_target="$RELEASE_DIR/firmware/dragon-radar-$mode-factory.bin"
  elf_target="$RELEASE_DIR/firmware/dragon-radar-$mode.elf"

  bin_cell="missing"
  factory_cell="missing"
  elf_cell="missing"
  status="missing"

  if copy_file "$bin_source" "$bin_target"; then
    bin_cell="firmware/$(basename "$bin_target")"
    copied_firmware=$((copied_firmware + 1))
    status="packaged"
  fi
  if copy_file "$factory_source" "$factory_target"; then
    factory_cell="firmware/$(basename "$factory_target")"
  fi
  if copy_file "$elf_source" "$elf_target"; then
    elf_cell="firmware/$(basename "$elf_target")"
  fi
  if [[ "$status" == "missing" ]]; then
    missing_modes=$((missing_modes + 1))
  fi

  write_manifest_line "| $mode | $env_name | $bin_cell | $factory_cell | $elf_cell | $status |"
done

write_manifest_line ""
write_manifest_line "## Included Evidence"
write_manifest_line ""

include_evidence() {
  local source="$1"
  local target="$2"
  local label="$3"
  if copy_file "$ROOT_DIR/$source" "$RELEASE_DIR/$target"; then
    write_manifest_line "- $label: \`$target\`"
  else
    write_manifest_line "- $label: missing"
  fi
}

include_evidence "README.md" "docs/README.md" "README"
include_evidence "docs/board-sim-test.zh.md" "docs/board-sim-test.zh.md" "Chinese one-board simulation test guide"
include_evidence "docs/product-design.zh.md" "docs/product-design.zh.md" "Chinese product design and feasibility guide"
include_evidence "docs/beacon-build.zh.md" "docs/beacon-build.zh.md" "Chinese BLE beacon build and deployment guide"
include_evidence "firmware/DragonRadar/private_boot_logo.h.example" "docs/private_boot_logo.h.example" "Private logo hook example"
include_evidence "output/private-boot-logo-audit.json" "evidence/private-boot-logo-audit.json" "Private boot logo audit JSON"
include_evidence "output/private-boot-logo-audit.md" "evidence/private-boot-logo-audit.md" "Private boot logo audit Markdown"
include_evidence "output/private-boot-logo-setup.json" "evidence/private-boot-logo-setup.json" "Private boot logo setup JSON"
include_evidence "output/private-boot-logo-setup.md" "evidence/private-boot-logo-setup.md" "Private boot logo setup Markdown"
include_evidence "tools/flash_release_firmware.sh" "tools/flash_release_firmware.sh" "Factory-bin flash helper"
include_evidence "tools/smoke_release_board.sh" "tools/smoke_release_board.sh" "Release smoke-test helper"
include_evidence "tools/run_board_sim_test.py" "tools/run_board_sim_test.py" "One-board simulation test wizard"
include_evidence "tools/run_preboard_acceptance.py" "tools/run_preboard_acceptance.py" "Pre-board acceptance helper"
include_evidence "tools/selftest_release.py" "tools/selftest_release.py" "Release self-test helper"
include_evidence "tools/first_run_zh.py" "tools/first_run_zh.py" "Chinese first-run wizard"
include_evidence "tools/run_release_acceptance.sh" "tools/run_release_acceptance.sh" "Release hardware acceptance helper"
include_evidence "tools/bench_sim.sh" "tools/bench_sim.sh" "Sim bench helper"
include_evidence "tools/list_radar_ports.py" "tools/list_radar_ports.py" "Radar serial port helper"
include_evidence "tools/wait_for_radar_port.py" "tools/wait_for_radar_port.py" "Radar serial port wait-and-auto-test helper"
include_evidence "tools/diagnose_usb_serial.py" "tools/diagnose_usb_serial.py" "USB serial diagnosis helper"
include_evidence "tools/diagnose_board_runtime.py" "tools/diagnose_board_runtime.py" "Board runtime diagnosis helper"
include_evidence "tools/recover_board_runtime.py" "tools/recover_board_runtime.py" "Board runtime recovery helper"
include_evidence "tools/send_diag_command.py" "tools/send_diag_command.py" "DIAG command sender"
include_evidence "tools/run_no_reset_display_check.py" "tools/run_no_reset_display_check.py" "No-Reset display check helper"
include_evidence "tools/analyze_board_photo.py" "tools/analyze_board_photo.py" "Board photo screen QA helper"
include_evidence "tools/generate_usb_bringup_card.py" "tools/generate_usb_bringup_card.py" "USB bring-up card generator"
include_evidence "tools/generate_refresh_perf_card.py" "tools/generate_refresh_perf_card.py" "Refresh performance card generator"
include_evidence "tools/monitor_diag.py" "tools/monitor_diag.py" "DIAG monitor"
include_evidence "tools/simulate_diag_feed.py" "tools/simulate_diag_feed.py" "Mock DIAG feed generator"
include_evidence "tools/render_bench_report.py" "tools/render_bench_report.py" "Bench report renderer"
include_evidence "tools/render_hunt_report.py" "tools/render_hunt_report.py" "Hunt report renderer"
include_evidence "tools/render_goal_completion_audit.py" "tools/render_goal_completion_audit.py" "Goal completion audit renderer"
include_evidence "tools/render_hardware_proof_packet.py" "tools/render_hardware_proof_packet.py" "Hardware proof packet renderer"
include_evidence "tools/run_missing_hardware_gates.py" "tools/run_missing_hardware_gates.py" "Missing hardware gate closure helper"
include_evidence "tools/render_playtest_rehearsal.py" "tools/render_playtest_rehearsal.py" "Playtest rehearsal renderer"
include_evidence "tools/recommend_field_tuning.py" "tools/recommend_field_tuning.py" "Field tuning recommendation helper"
include_evidence "tools/generate_field_kit.py" "tools/generate_field_kit.py" "Field kit generator"
include_evidence "tools/generate_play_cards.py" "tools/generate_play_cards.py" "Printable host/player cards generator"
include_evidence "tools/generate_quickstart_zh.py" "tools/generate_quickstart_zh.py" "Chinese quickstart generator"
include_evidence "tools/generate_visual_qa_sheet.py" "tools/generate_visual_qa_sheet.py" "Visual QA sheet generator"
include_evidence "tools/generate_motion_gifs.py" "tools/generate_motion_gifs.py" "Motion GIF generator"
include_evidence "tools/verify_motion_gifs.py" "tools/verify_motion_gifs.py" "Motion GIF verifier"
include_evidence "tools/generate_motion_qa_sheet.py" "tools/generate_motion_qa_sheet.py" "Motion QA storyboard generator"
include_evidence "tools/generate_release_index.py" "tools/generate_release_index.py" "Release index generator"
include_evidence "tools/generate_fidelity_review.py" "tools/generate_fidelity_review.py" "UI fidelity review generator"
include_evidence "tools/verify_firmware_ui_contract.py" "tools/verify_firmware_ui_contract.py" "Firmware UI contract verifier"
include_evidence "tools/verify_ui_parity.py" "tools/verify_ui_parity.py" "Firmware/preview UI parity verifier"
include_evidence "tools/verify_private_boot_logo.py" "tools/verify_private_boot_logo.py" "Private boot logo verifier"
include_evidence "tools/install_private_boot_logo.py" "tools/install_private_boot_logo.py" "Private boot logo local setup helper"
include_evidence "tools/verify_release_package.py" "tools/verify_release_package.py" "Release package verifier"
include_evidence "tools/smoke_preview_interactions.sh" "tools/smoke_preview_interactions.sh" "Preview keyboard interaction smoke test"
include_evidence "output/project-status.md" "evidence/project-status.md" "Project status"
include_evidence "output/goal-completion-audit.json" "evidence/goal-completion-audit.json" "Goal completion audit JSON"
include_evidence "output/goal-completion-audit.zh.md" "docs/goal-completion-audit.zh.md" "Goal completion audit Markdown"
include_evidence "output/preview-visual-audit.json" "evidence/preview-visual-audit.json" "Preview visual audit JSON"
include_evidence "output/preview-visual-audit.md" "evidence/preview-visual-audit.md" "Preview visual audit Markdown"
include_evidence "output/preview-interactions.json" "evidence/preview-interactions.json" "Preview keyboard interaction JSON"
include_evidence "output/firmware-ui-contract.json" "evidence/firmware-ui-contract.json" "Firmware UI contract JSON"
include_evidence "output/firmware-preview-parity.json" "evidence/firmware-preview-parity.json" "Firmware/preview UI parity JSON"
include_evidence "output/usb-serial-diagnosis.json" "evidence/usb-serial-diagnosis.json" "USB serial diagnosis JSON"
include_evidence "output/usb-serial-diagnosis.zh.md" "evidence/usb-serial-diagnosis.zh.md" "USB serial diagnosis Markdown"
include_evidence "output/usb-bringup-card.zh.md" "docs/usb-bringup-card.zh.md" "USB bring-up card"
include_evidence "output/refresh-performance-card.zh.md" "docs/refresh-performance-card.zh.md" "Refresh performance troubleshooting card"
include_evidence "output/no-reset-display-check.json" "evidence/no-reset-display-check.json" "No-Reset display check JSON"
include_evidence "output/no-reset-display-check.zh.md" "docs/no-reset-display-check.zh.md" "No-Reset display check Markdown"
include_evidence "output/board-photo-qa-sample.json" "evidence/board-photo-qa-sample.json" "Board photo QA sample JSON"
include_evidence "output/board-photo-qa-sample.zh.md" "docs/board-photo-qa-sample.zh.md" "Board photo QA sample Markdown"
include_evidence "output/board-photo-qa-sample-crop.png" "evidence/board-photo-qa-sample-crop.png" "Board photo QA sample crop"
include_evidence "output/board-photo-qa-sample-overlay.png" "evidence/board-photo-qa-sample-overlay.png" "Board photo QA sample overlay"
include_evidence "output/diag-simulator-report.json" "evidence/diag-simulator-report.json" "DIAG simulator JSON"
include_evidence "output/diag-simulator-report.md" "evidence/diag-simulator-report.md" "DIAG simulator Markdown"
include_evidence "output/diag-simulator-raw.log" "evidence/diag-simulator-raw.log" "DIAG simulator raw log"
include_evidence "output/hardware-acceptance-report.md" "evidence/hardware-acceptance-report.md" "Hardware acceptance summary"
include_evidence "output/missing-hardware-gates-plan.json" "evidence/missing-hardware-gates-plan.json" "Missing hardware gate plan JSON"
include_evidence "output/missing-hardware-gates-plan.zh.md" "docs/missing-hardware-gates-plan.zh.md" "Missing hardware gate plan Markdown"
include_evidence "output/bench-sim-report.json" "evidence/bench-sim-report.json" "One-board sim JSON"
include_evidence "output/bringup-diag-report.json" "evidence/bringup-diag-report.json" "Hardware bring-up JSON"
include_evidence "output/beacon-set-verify-report.json" "evidence/beacon-set-verify-report.json" "Seven-beacon verification JSON"
include_evidence "output/field-hunt-report.json" "evidence/field-hunt-report.json" "Field hunt JSON"
include_evidence "output/field-hunt-report.md" "evidence/field-hunt-report.md" "Friend-facing hunt report"

if [[ "$RELEASE_DRY_RUN" == "1" ]]; then
  printf '+ %q --output %q\n' "$ROOT_DIR/tools/generate_beacon_labels.py" "$RELEASE_DIR/docs/beacon-labels.html"
  printf '+ %q --output %q --release-dir %q\n' "$ROOT_DIR/tools/generate_field_kit.py" "$RELEASE_DIR/docs/field-kit.html" "$RELEASE_DIR"
  printf '+ %q --output %q --release-dir %q\n' "$ROOT_DIR/tools/render_playtest_rehearsal.py" "$RELEASE_DIR/docs/playtest-rehearsal.zh.md" "$RELEASE_DIR"
  printf '+ %q --output %q --release-dir %q --modes %q\n' "$ROOT_DIR/tools/generate_quickstart_zh.py" "$RELEASE_DIR/docs/quickstart.zh.html" "$RELEASE_DIR" "$RELEASE_MODES"
else
  "$ROOT_DIR/tools/generate_beacon_labels.py" --output "$RELEASE_DIR/docs/beacon-labels.html" >/dev/null
  write_manifest_line "- Printable beacon labels: \`docs/beacon-labels.html\`"
  "$ROOT_DIR/tools/generate_field_kit.py" --output "$RELEASE_DIR/docs/field-kit.html" --release-dir "$RELEASE_DIR" >/dev/null
write_manifest_line "- Printable field kit: \`docs/field-kit.html\`"
  "$ROOT_DIR/tools/render_playtest_rehearsal.py" --output "$RELEASE_DIR/docs/playtest-rehearsal.zh.md" --release-dir "$RELEASE_DIR" >/dev/null
write_manifest_line "- Playtest rehearsal report: \`docs/playtest-rehearsal.zh.md\`"
  "$ROOT_DIR/tools/generate_quickstart_zh.py" --output "$RELEASE_DIR/docs/quickstart.zh.html" --release-dir "$RELEASE_DIR" --modes "$RELEASE_MODES" >/dev/null
write_manifest_line "- Chinese quickstart: \`docs/quickstart.zh.html\`"
fi

shopt -s nullglob
preview_count=0
for preview in "$ROOT_DIR"/output/playwright/*.png; do
  target="$RELEASE_DIR/preview/$(basename "$preview")"
  if copy_file "$preview" "$target"; then
    preview_count=$((preview_count + 1))
  fi
done
shopt -u nullglob
write_manifest_line "- Preview screenshots: $preview_count PNG file(s) in \`preview/\`"
if [[ "$RELEASE_DRY_RUN" == "1" ]]; then
  printf '+ %q --image-dir %q --output-dir %q\n' "$ROOT_DIR/tools/generate_motion_gifs.py" "$RELEASE_DIR/preview" "$RELEASE_DIR/preview"
  printf '+ %q %q --json %q --md %q\n' "$ROOT_DIR/tools/verify_motion_gifs.py" "$RELEASE_DIR/preview" "$RELEASE_DIR/evidence/motion-gif-audit.json" "$RELEASE_DIR/evidence/motion-gif-audit.md"
  printf '+ %q --output %q --image-dir %q\n' "$ROOT_DIR/tools/generate_visual_qa_sheet.py" "$RELEASE_DIR/docs/visual-qa.html" "$RELEASE_DIR/preview"
  printf '+ %q --output %q --image-dir %q\n' "$ROOT_DIR/tools/generate_motion_qa_sheet.py" "$RELEASE_DIR/docs/motion-qa.html" "$RELEASE_DIR/preview"
  printf '+ %q --output %q --image-prefix %q --visual-audit %q --motion-audit %q --firmware-contract %q --parity %q --private-logo %q --project-status %q\n' "$ROOT_DIR/tools/generate_fidelity_review.py" "$RELEASE_DIR/docs/fidelity-review.zh.md" "../preview" "$RELEASE_DIR/evidence/preview-visual-audit.json" "$RELEASE_DIR/evidence/motion-gif-audit.json" "$RELEASE_DIR/evidence/firmware-ui-contract.json" "$RELEASE_DIR/evidence/firmware-preview-parity.json" "$RELEASE_DIR/evidence/private-boot-logo-audit.json" "$RELEASE_DIR/evidence/project-status.md"
  printf '+ %q --output %q --release-dir %q --diagnosis-json %q\n' "$ROOT_DIR/tools/generate_usb_bringup_card.py" "$RELEASE_DIR/docs/usb-bringup-card.zh.md" "$RELEASE_DIR" "$RELEASE_DIR/evidence/usb-serial-diagnosis.json"
  printf '+ %q --output %q --release-dir %q --diag-json %q\n' "$ROOT_DIR/tools/generate_refresh_perf_card.py" "$RELEASE_DIR/docs/refresh-performance-card.zh.md" "$RELEASE_DIR" "$RELEASE_DIR/evidence/diag-simulator-report.json"
  printf '+ %q --sample-report %q --json-output %q --md-output %q\n' "$ROOT_DIR/tools/run_no_reset_display_check.py" "$RELEASE_DIR/evidence/diag-simulator-report.json" "$RELEASE_DIR/evidence/no-reset-display-check.json" "$RELEASE_DIR/docs/no-reset-display-check.zh.md"
  printf '+ %q %q --json-output %q --md-output %q --crop-output %q --overlay-output %q\n' "$ROOT_DIR/tools/analyze_board_photo.py" "$RELEASE_DIR/preview/radar-default.png" "$RELEASE_DIR/evidence/board-photo-qa-sample.json" "$RELEASE_DIR/docs/board-photo-qa-sample.zh.md" "$RELEASE_DIR/evidence/board-photo-qa-sample-crop.png" "$RELEASE_DIR/evidence/board-photo-qa-sample-overlay.png"
  printf '+ %q --json %q --md %q\n' "$RELEASE_DIR/tools/render_hardware_proof_packet.py" "$RELEASE_DIR/evidence/hardware-proof-packet.json" "$RELEASE_DIR/docs/hardware-proof-packet.zh.md"
  printf '+ %q --json-output %q --md-output %q\n' "$RELEASE_DIR/tools/run_missing_hardware_gates.py" "$RELEASE_DIR/evidence/missing-hardware-gates-plan.json" "$RELEASE_DIR/docs/missing-hardware-gates-plan.zh.md"
  printf '+ %q --output %q --release-dir %q\n' "$ROOT_DIR/tools/generate_play_cards.py" "$RELEASE_DIR/docs/game-cards.html" "$RELEASE_DIR"
  printf '+ %q --release-dir %q --output %q --modes %q\n' "$ROOT_DIR/tools/generate_release_index.py" "$RELEASE_DIR" "$RELEASE_DIR/index.html" "$RELEASE_MODES"
  printf '+ %q --output %q --release-dir %q --modes %q\n' "$ROOT_DIR/tools/generate_quickstart_zh.py" "$RELEASE_DIR/docs/quickstart.zh.html" "$RELEASE_DIR" "$RELEASE_MODES"
  printf '+ %q --release-dir %q --output-dir %q --md-output %q --modes %q --skip-release-verify\n' "$ROOT_DIR/tools/run_preboard_acceptance.py" "$RELEASE_DIR" "$RELEASE_DIR/evidence/preboard-acceptance" "$RELEASE_DIR/docs/preboard-acceptance.zh.md" "$RELEASE_MODES"
  printf '+ %q %q --output-md %q --mode %q\n' "$ROOT_DIR/tools/recommend_field_tuning.py" "$RELEASE_DIR/evidence/preboard-acceptance/release-selftest/board-sim-mock/bench-sim-report.json" "$RELEASE_DIR/docs/field-tuning-report.md" "$PLAYABLE_MODE"
  printf '+ %q --output %q --release-dir %q --tuning-report %q\n' "$ROOT_DIR/tools/render_playtest_rehearsal.py" "$RELEASE_DIR/docs/playtest-rehearsal.zh.md" "$RELEASE_DIR" "$RELEASE_DIR/docs/field-tuning-report.md"
else
  "$ROOT_DIR/tools/generate_motion_gifs.py" --image-dir "$RELEASE_DIR/preview" --output-dir "$RELEASE_DIR/preview" >/dev/null
  write_manifest_line "- Motion GIF previews: \`preview/boot-motion.gif\`, \`preview/radar-motion.gif\`, \`preview/summon-motion.gif\`"
  "$ROOT_DIR/tools/verify_motion_gifs.py" "$RELEASE_DIR/preview" --json "$RELEASE_DIR/evidence/motion-gif-audit.json" --md "$RELEASE_DIR/evidence/motion-gif-audit.md" >/dev/null
  write_manifest_line "- Motion GIF sequence audit: \`evidence/motion-gif-audit.json\`, \`evidence/motion-gif-audit.md\`"
  "$ROOT_DIR/tools/generate_visual_qa_sheet.py" --output "$RELEASE_DIR/docs/visual-qa.html" --image-dir "$RELEASE_DIR/preview" >/dev/null
  write_manifest_line "- Visual QA contact sheet: \`docs/visual-qa.html\`"
  "$ROOT_DIR/tools/generate_motion_qa_sheet.py" --output "$RELEASE_DIR/docs/motion-qa.html" --image-dir "$RELEASE_DIR/preview" >/dev/null
  write_manifest_line "- Motion QA storyboard: \`docs/motion-qa.html\`"
  "$ROOT_DIR/tools/generate_fidelity_review.py" --output "$RELEASE_DIR/docs/fidelity-review.zh.md" --image-prefix ../preview --visual-audit "$RELEASE_DIR/evidence/preview-visual-audit.json" --motion-audit "$RELEASE_DIR/evidence/motion-gif-audit.json" --firmware-contract "$RELEASE_DIR/evidence/firmware-ui-contract.json" --parity "$RELEASE_DIR/evidence/firmware-preview-parity.json" --private-logo "$RELEASE_DIR/evidence/private-boot-logo-audit.json" --project-status "$RELEASE_DIR/evidence/project-status.md" >/dev/null
  write_manifest_line "- UI fidelity review: \`docs/fidelity-review.zh.md\`"
  "$ROOT_DIR/tools/generate_usb_bringup_card.py" --output "$RELEASE_DIR/docs/usb-bringup-card.zh.md" --release-dir "$RELEASE_DIR" --diagnosis-json "$RELEASE_DIR/evidence/usb-serial-diagnosis.json" >/dev/null
  write_manifest_line "- USB bring-up card: \`docs/usb-bringup-card.zh.md\`"
  "$ROOT_DIR/tools/generate_refresh_perf_card.py" --output "$RELEASE_DIR/docs/refresh-performance-card.zh.md" --release-dir "$RELEASE_DIR" --diag-json "$RELEASE_DIR/evidence/diag-simulator-report.json" >/dev/null
  write_manifest_line "- Refresh performance troubleshooting card: \`docs/refresh-performance-card.zh.md\`"
  "$ROOT_DIR/tools/run_no_reset_display_check.py" --sample-report "$RELEASE_DIR/evidence/diag-simulator-report.json" --json-output "$RELEASE_DIR/evidence/no-reset-display-check.json" --md-output "$RELEASE_DIR/docs/no-reset-display-check.zh.md" >/dev/null
  write_manifest_line "- No-Reset display check report: \`docs/no-reset-display-check.zh.md\`, \`evidence/no-reset-display-check.json\`"
  "$ROOT_DIR/tools/analyze_board_photo.py" "$RELEASE_DIR/preview/radar-default.png" --json-output "$RELEASE_DIR/evidence/board-photo-qa-sample.json" --md-output "$RELEASE_DIR/docs/board-photo-qa-sample.zh.md" --crop-output "$RELEASE_DIR/evidence/board-photo-qa-sample-crop.png" --overlay-output "$RELEASE_DIR/evidence/board-photo-qa-sample-overlay.png" >/dev/null
  write_manifest_line "- Board photo QA sample: \`docs/board-photo-qa-sample.zh.md\`, \`evidence/board-photo-qa-sample.json\`, \`evidence/board-photo-qa-sample-crop.png\`, \`evidence/board-photo-qa-sample-overlay.png\`"
  "$RELEASE_DIR/tools/render_hardware_proof_packet.py" --json "$RELEASE_DIR/evidence/hardware-proof-packet.json" --md "$RELEASE_DIR/docs/hardware-proof-packet.zh.md" >/dev/null
  write_manifest_line "- Hardware proof packet: \`docs/hardware-proof-packet.zh.md\`, \`evidence/hardware-proof-packet.json\`"
  "$RELEASE_DIR/tools/run_missing_hardware_gates.py" --json-output "$RELEASE_DIR/evidence/missing-hardware-gates-plan.json" --md-output "$RELEASE_DIR/docs/missing-hardware-gates-plan.zh.md" >/dev/null
  write_manifest_line "- Missing hardware gate plan: \`docs/missing-hardware-gates-plan.zh.md\`, \`evidence/missing-hardware-gates-plan.json\`"
  "$ROOT_DIR/tools/generate_play_cards.py" --output "$RELEASE_DIR/docs/game-cards.html" --release-dir "$RELEASE_DIR" >/dev/null
  write_manifest_line "- Printable host/player cards: \`docs/game-cards.html\`"
  "$ROOT_DIR/tools/generate_release_index.py" --release-dir "$RELEASE_DIR" --output "$RELEASE_DIR/index.html" --modes "$RELEASE_MODES" >/dev/null
  write_manifest_line "- Release index: \`index.html\`"
  "$ROOT_DIR/tools/generate_quickstart_zh.py" --output "$RELEASE_DIR/docs/quickstart.zh.html" --release-dir "$RELEASE_DIR" --modes "$RELEASE_MODES" >/dev/null
  write_manifest_line "- Chinese quickstart refresh: \`docs/quickstart.zh.html\`"
  "$ROOT_DIR/tools/run_preboard_acceptance.py" --release-dir "$RELEASE_DIR" --output-dir "$RELEASE_DIR/evidence/preboard-acceptance" --md-output "$RELEASE_DIR/docs/preboard-acceptance.zh.md" --modes "$RELEASE_MODES" --skip-release-verify >/dev/null
  write_manifest_line "- Pre-board acceptance report: \`docs/preboard-acceptance.zh.md\`"
  "$ROOT_DIR/tools/recommend_field_tuning.py" "$RELEASE_DIR/evidence/preboard-acceptance/release-selftest/board-sim-mock/bench-sim-report.json" --output-md "$RELEASE_DIR/docs/field-tuning-report.md" --mode "$PLAYABLE_MODE" >/dev/null
  write_manifest_line "- Field tuning starting-point report: \`docs/field-tuning-report.md\`"
  "$ROOT_DIR/tools/render_playtest_rehearsal.py" --output "$RELEASE_DIR/docs/playtest-rehearsal.zh.md" --release-dir "$RELEASE_DIR" --tuning-report "$RELEASE_DIR/docs/field-tuning-report.md" >/dev/null
fi
write_manifest_line "- Release audit: \`RELEASE_AUDIT.json\`"
write_manifest_line "- SHA256 checksums: \`CHECKSUMS.sha256\`"

write_manifest_line ""
write_manifest_line "## Flashing"
write_manifest_line ""
write_manifest_line "- Find port: \`tools/list_radar_ports.py --shell\`"
write_manifest_line "- Wait for port and auto-test: \`tools/wait_for_radar_port.py --run-auto\`"
write_manifest_line "- Diagnose missing USB serial: \`tools/diagnose_usb_serial.py\`"
write_manifest_line "- Recover visible serial with no runtime: \`RADAR_PORT=/dev/cu.usbmodem101 tools/recover_board_runtime.py\`"
write_manifest_line "- Chinese first-run wizard: \`tools/first_run_zh.py check\`"
write_manifest_line "- No-hardware pre-board acceptance: \`tools/run_preboard_acceptance.py\`"
write_manifest_line "- Packaged real play: \`RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh field\`"
write_manifest_line "- Packaged clean UI recorder: \`RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh fielddiag\`"
write_manifest_line "- Packaged hardware diagnostics: \`RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh diag\`"
write_manifest_line "- Packaged one-board simulated bench: \`RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh sim\`"
write_manifest_line "- Packaged one-board smoke: \`RADAR_PORT=/dev/cu.usbmodem101 tools/smoke_release_board.sh all\`"
write_manifest_line "- Packaged full acceptance: \`RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh all\`"
write_manifest_line ""
write_manifest_line "Use the packaged \`firmware/*-factory.bin\` files for external ESP32 flash tools when present. The copied \`tools/flash_release_firmware.sh\` helper flashes those factory images at offset \`0x0\` without rebuilding. The copied \`tools/smoke_release_board.sh\` helper flashes the packaged \`sim\` image and runs the strict one-board simulated seven-ball monitor. The copied \`tools/run_release_acceptance.sh\` helper runs the full packaged hardware proof sequence: diag bring-up, sim bench, seven physical beacons, and clean field hunt. The private Capsule-style boot artwork source is intentionally not copied; the binaries contain whatever logo was compiled locally."
write_manifest_line ""
write_manifest_line "## Hardware Proof Gates"
write_manifest_line ""
write_manifest_line "- \`RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh all\`"
write_manifest_line "- \`RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh bringup\`"
write_manifest_line "- \`RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh sim\`"
write_manifest_line "- \`RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh beacons\`"
write_manifest_line "- \`RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh hunt\`"
write_manifest_line "- Dry-run missing gates: \`tools/run_missing_hardware_gates.py\`"
write_manifest_line "- Execute missing gates after reset/beacon power: \`RADAR_PORT=/dev/cu.usbmodem101 tools/run_missing_hardware_gates.py --execute\`"

if [[ "$copied_firmware" -eq 0 && "$RELEASE_DRY_RUN" == "0" ]]; then
  echo "No firmware artifacts were packaged. Run RELEASE_BUILD=1 tools/package_release.sh or build a radar mode first." >&2
  exit 1
fi

if [[ "$missing_modes" -gt 0 && "$RELEASE_STRICT" == "1" && "$RELEASE_DRY_RUN" == "0" ]]; then
  echo "Missing $missing_modes requested firmware mode(s). Re-run with RELEASE_BUILD=1 or set RELEASE_STRICT=0." >&2
  exit 1
fi

if [[ "$RELEASE_DRY_RUN" == "1" ]]; then
  printf '+ %q --release-dir %q --json %q --md %q\n' "$ROOT_DIR/tools/verify_private_boot_logo.py" "$RELEASE_DIR" "$RELEASE_DIR/evidence/private-boot-logo-audit.json" "$RELEASE_DIR/evidence/private-boot-logo-audit.md"
  printf '+ %q %q --write --allow-missing-links --modes %q\n' "$ROOT_DIR/tools/verify_release_package.py" "$RELEASE_DIR" "$RELEASE_MODES"
  printf '+ %q --json %q --md %q\n' "$RELEASE_DIR/tools/render_hardware_proof_packet.py" "$RELEASE_DIR/evidence/hardware-proof-packet.json" "$RELEASE_DIR/docs/hardware-proof-packet.zh.md"
  printf '+ %q --json-output %q --md-output %q\n' "$RELEASE_DIR/tools/run_missing_hardware_gates.py" "$RELEASE_DIR/evidence/missing-hardware-gates-plan.json" "$RELEASE_DIR/docs/missing-hardware-gates-plan.zh.md"
  printf '+ %q --release-dir %q --output %q\n' "$ROOT_DIR/tools/generate_release_index.py" "$RELEASE_DIR" "$RELEASE_DIR/index.html"
  printf '+ %q --output %q --release-dir %q\n' "$ROOT_DIR/tools/generate_quickstart_zh.py" "$RELEASE_DIR/docs/quickstart.zh.html" "$RELEASE_DIR"
  printf '+ %q %q --write --modes %q\n' "$ROOT_DIR/tools/verify_release_package.py" "$RELEASE_DIR" "$RELEASE_MODES"
else
  "$ROOT_DIR/tools/verify_private_boot_logo.py" --release-dir "$RELEASE_DIR" --json "$RELEASE_DIR/evidence/private-boot-logo-audit.json" --md "$RELEASE_DIR/evidence/private-boot-logo-audit.md" >/dev/null
  "$ROOT_DIR/tools/verify_release_package.py" "$RELEASE_DIR" --write --allow-missing-links --modes "$RELEASE_MODES" >/dev/null
  "$RELEASE_DIR/tools/render_hardware_proof_packet.py" --json "$RELEASE_DIR/evidence/hardware-proof-packet.json" --md "$RELEASE_DIR/docs/hardware-proof-packet.zh.md" >/dev/null
  "$RELEASE_DIR/tools/run_missing_hardware_gates.py" --json-output "$RELEASE_DIR/evidence/missing-hardware-gates-plan.json" --md-output "$RELEASE_DIR/docs/missing-hardware-gates-plan.zh.md" >/dev/null
  "$ROOT_DIR/tools/generate_release_index.py" --release-dir "$RELEASE_DIR" --output "$RELEASE_DIR/index.html" --modes "$RELEASE_MODES" >/dev/null
  "$ROOT_DIR/tools/generate_quickstart_zh.py" --output "$RELEASE_DIR/docs/quickstart.zh.html" --release-dir "$RELEASE_DIR" --modes "$RELEASE_MODES" >/dev/null
  "$ROOT_DIR/tools/verify_release_package.py" "$RELEASE_DIR" --write --modes "$RELEASE_MODES" >/dev/null
fi

if [[ "$RELEASE_TAR" == "1" ]]; then
  if [[ "$RELEASE_DRY_RUN" == "1" ]]; then
    printf '+ tar -czf %q -C %q %q\n' "$RELEASE_DIR.tar.gz" "$(dirname "$RELEASE_DIR")" "$(basename "$RELEASE_DIR")"
  else
    tar -czf "$RELEASE_DIR.tar.gz" -C "$(dirname "$RELEASE_DIR")" "$(basename "$RELEASE_DIR")"
  fi
fi

if [[ "$RELEASE_DRY_RUN" == "0" ]]; then
  echo "$RELEASE_DIR"
  if [[ "$missing_modes" -gt 0 ]]; then
    echo "Packaged $copied_firmware firmware image(s); $missing_modes requested mode(s) are missing and listed in MANIFEST.md."
  else
    echo "Packaged $copied_firmware firmware image(s)."
  fi
fi
