#!/usr/bin/env bash
set -euo pipefail

PORT="${PREVIEW_PORT:-$((8767 + RANDOM % 1000))}"
BASE_URL="http://127.0.0.1:${PORT}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PWCLI="${PWCLI:-$CODEX_HOME/skills/playwright/scripts/playwright_cli.sh}"
HTTP_LOG="${TMPDIR:-/tmp}/dragon-radar-preview-interactions-${PORT}.log"
OUT_DIR="${PREVIEW_INTERACTION_OUT_DIR:-output/playwright}"
REPORT_JSON="${PREVIEW_INTERACTION_JSON:-output/preview-interactions.json}"

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required for the Playwright CLI wrapper." >&2
  exit 1
fi

if [[ ! -x "$PWCLI" ]]; then
  echo "Playwright CLI wrapper not found: $PWCLI" >&2
  exit 1
fi

"$PWCLI" close-all >/dev/null 2>&1 || true

mkdir -p "$OUT_DIR" "$(dirname "$REPORT_JSON")"

python3 -m http.server "$PORT" >"$HTTP_LOG" 2>&1 &
SERVER_PID=$!
BROWSER_OPENED=0
SERVER_READY=0
CHECKS=()

cleanup() {
  if [[ "$BROWSER_OPENED" == "1" ]]; then
    "$PWCLI" close >/dev/null 2>&1 || true
  fi
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in {1..30}; do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "Preview HTTP server failed to start on port $PORT." >&2
    cat "$HTTP_LOG" >&2
    exit 1
  fi
  if curl -fsS "$BASE_URL/preview/radar_ui.html" >/dev/null 2>&1; then
    SERVER_READY=1
    break
  fi
  sleep 0.1
done

if [[ "$SERVER_READY" != "1" ]]; then
  echo "Preview HTTP server did not become ready on port $PORT." >&2
  exit 1
fi

open_preview() {
  "$PWCLI" open "$BASE_URL/preview/radar_ui.html?run=$$" >/dev/null
  "$PWCLI" resize 900 760 >/dev/null
  "$PWCLI" goto "$BASE_URL/preview/radar_ui.html?run=$$" >/dev/null
  BROWSER_OPENED=1
  short_wait 0.35
}

state_json() {
  "$PWCLI" eval "() => JSON.stringify(window.__dragonRadarPreview ? window.__dragonRadarPreview.state() : {...document.documentElement.dataset})"
}

state_has() {
  local state="$1"
  local key="$2"
  local value="$3"
  local raw="\"${key}\":\"${value}\""
  local escaped="\\\"${key}\\\":\\\"${value}\\\""
  [[ "$state" == *"$raw"* || "$state" == *"$escaped"* ]]
}

record_check() {
  local name="$1"
  local status="$2"
  CHECKS+=("{\"name\":\"$name\",\"status\":\"$status\"}")
}

short_wait() {
  local seconds="$1"
  sleep "$seconds"
}

expect_state() {
  local name="$1"
  local key="$2"
  local value="$3"
  local state
  local passed=0
  for _ in {1..20}; do
    state="$(state_json)"
    if state_has "$state" "$key" "$value"; then
      passed=1
      break
    fi
    short_wait 0.05
  done
  if [[ "$passed" != "1" ]]; then
    echo "preview interaction check failed: $name" >&2
    echo "expected ${key}=${value}" >&2
    echo "state: $state" >&2
    record_check "$name" "failed"
    return 1
  fi
  record_check "$name" "passed"
}

press_key() {
  local key="$1"
  "$PWCLI" eval "() => window.__dragonRadarPreview.press('$key')" >/dev/null
  short_wait 0.05
}

ensure_radar_ready() {
  local state
  state="$(state_json)"
  if state_has "$state" "boot" "1"; then
    press_key "Space"
  fi
  expect_state "keyboard-enters-radar" "boot" "0"
}

open_preview
press_key "2"
expect_state "number-two-field-mode" "previewMode" "field"

press_key "4"
expect_state "number-four-debug-mode" "previewMode" "debug"

press_key "1"
expect_state "number-one-default-mode" "previewMode" "default"
ensure_radar_ready

collect_state="$("$PWCLI" eval "() => JSON.stringify(window.__dragonRadarPreview.collectSeven())")"
if state_has "$collect_state" "collected" "7"; then
  record_check "keyboard-collects-seven" "passed"
else
  echo "preview interaction check failed: keyboard-collects-seven" >&2
  echo "expected collected=7" >&2
  echo "state: $collect_state" >&2
  record_check "keyboard-collects-seven" "failed"
  exit 1
fi
if state_has "$collect_state" "summon" "1"; then
  record_check "keyboard-enters-summon" "passed"
else
  echo "preview interaction check failed: keyboard-enters-summon" >&2
  echo "expected summon=1" >&2
  echo "state: $collect_state" >&2
  record_check "keyboard-enters-summon" "failed"
  exit 1
fi

press_key "z"
expect_state "keyboard-zooms" "zoom" "1"
press_key "b"
expect_state "keyboard-brightness" "brightness" "2"
press_key "a"
expect_state "keyboard-audio" "audio" "3"

"$PWCLI" screenshot canvas --filename "$OUT_DIR/preview-interaction-final.png" >/dev/null

{
  printf '{\n'
  printf '  "status": "passed",\n'
  printf '  "port": "%s",\n' "$PORT"
  printf '  "screenshot": "%s",\n' "$OUT_DIR/preview-interaction-final.png"
  printf '  "checks": [\n'
  local_count="${#CHECKS[@]}"
  for ((i = 0; i < local_count; i++)); do
    comma=","
    if (( i == local_count - 1 )); then
      comma=""
    fi
    printf '    %s%s\n' "${CHECKS[$i]}" "$comma"
  done
  printf '  ]\n'
  printf '}\n'
} > "$REPORT_JSON"

echo "preview-interactions-ok"
echo "$REPORT_JSON"
