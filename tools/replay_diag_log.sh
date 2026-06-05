#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: tools/replay_diag_log.sh RAW_LOG [REPORT_JSON] [REPORT_MD]

Replays a saved Dragon Radar DIAG raw log through the same monitor/parser used
during bring-up, then renders a fresh Markdown report.

Environment:
  REPLAY_REQUIRE_ONLINE         Comma-separated required components, e.g. touch,imu,ble,audio
  REPLAY_MIN_BEACONS            Minimum distinct DBALL beacons that must be seen
  REPLAY_MIN_COLLECTED          Minimum collected Dragon Balls that must be reported
  REPLAY_MIN_COLLECTIONS        Minimum DIAG collect events that must be seen
  REPLAY_REQUIRE_COLLECTION_SET 1 to require collect events for DBALL-1..7
  REPLAY_REQUIRE_SIMULATED_BLE  1 to require DIAG simulatedBle=enabled
  REPLAY_REQUIRE_SUMMON         1 to require summon=yes
  REPLAY_CALIBRATE              1 to print aggregate RSSI/bearing stats, default: 1
  REPLAY_RAW                    1 to also echo raw log lines
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -lt 1 || $# -gt 3 ]]; then
  usage >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_LOG="$1"
REPORT_JSON="${2:-${REPLAY_REPORT_JSON:-$ROOT_DIR/output/replay-diag-report.json}}"
REPORT_MD="${3:-${REPLAY_REPORT_MD:-$ROOT_DIR/output/replay-diag-report.md}}"

if [[ ! -f "$RAW_LOG" ]]; then
  echo "raw log not found: $RAW_LOG" >&2
  exit 2
fi

monitor_cmd=(
  "$ROOT_DIR/tools/monitor_diag.py"
  --stdin
  --report-json "$REPORT_JSON"
  --report-log-file "$RAW_LOG"
)

if [[ -n "${REPLAY_REQUIRE_ONLINE:-}" ]]; then
  monitor_cmd+=(--require-online "$REPLAY_REQUIRE_ONLINE")
fi
if [[ -n "${REPLAY_MIN_BEACONS:-}" ]]; then
  monitor_cmd+=(--min-beacons "$REPLAY_MIN_BEACONS")
fi
if [[ -n "${REPLAY_MIN_COLLECTED:-}" ]]; then
  monitor_cmd+=(--min-collected "$REPLAY_MIN_COLLECTED")
fi
if [[ -n "${REPLAY_MIN_COLLECTIONS:-}" ]]; then
  monitor_cmd+=(--min-collections "$REPLAY_MIN_COLLECTIONS")
fi
if [[ "${REPLAY_REQUIRE_COLLECTION_SET:-0}" == "1" ]]; then
  monitor_cmd+=(--require-collection-set)
fi
if [[ "${REPLAY_REQUIRE_SIMULATED_BLE:-0}" == "1" ]]; then
  monitor_cmd+=(--require-simulated-ble)
fi
if [[ "${REPLAY_REQUIRE_SUMMON:-0}" == "1" ]]; then
  monitor_cmd+=(--require-summon)
fi
if [[ "${REPLAY_CALIBRATE:-1}" == "1" ]]; then
  monitor_cmd+=(--calibrate)
fi
if [[ "${REPLAY_RAW:-0}" == "1" ]]; then
  monitor_cmd+=(--raw)
fi

printf '+'
printf ' %q' "${monitor_cmd[@]}"
printf ' < %q\n' "$RAW_LOG"
set +e
"${monitor_cmd[@]}" < "$RAW_LOG"
rc=$?
set -e

if [[ -n "$REPORT_JSON" && -f "$REPORT_JSON" && -n "$REPORT_MD" ]]; then
  printf '+ %q %q %q\n' "$ROOT_DIR/tools/render_bench_report.py" "$REPORT_JSON" "$REPORT_MD"
  "$ROOT_DIR/tools/render_bench_report.py" "$REPORT_JSON" "$REPORT_MD"
fi

exit "$rc"
