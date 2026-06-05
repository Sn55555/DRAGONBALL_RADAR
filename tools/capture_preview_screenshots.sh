#!/usr/bin/env bash
set -euo pipefail

PORT="${PREVIEW_PORT:-8765}"
WAIT_MS="${PREVIEW_WAIT_MS:-4300}"
SHOT_WAIT_MS="${PREVIEW_SHOT_WAIT_MS:-350}"
OUT_DIR="${PREVIEW_OUT_DIR:-output/playwright}"
BASE_URL="http://127.0.0.1:${PORT}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PWCLI="${PWCLI:-$CODEX_HOME/skills/playwright/scripts/playwright_cli.sh}"
HTTP_LOG="${TMPDIR:-/tmp}/dragon-radar-preview-http-${PORT}.log"

if ! command -v npx >/dev/null 2>&1; then
  echo "npx is required for the Playwright CLI wrapper." >&2
  exit 1
fi

if [[ ! -x "$PWCLI" ]]; then
  echo "Playwright CLI wrapper not found: $PWCLI" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

python3 -m http.server "$PORT" >"$HTTP_LOG" 2>&1 &
SERVER_PID=$!
BROWSER_OPENED=0
SERVER_READY=0

cleanup() {
  if [[ "$BROWSER_OPENED" == "1" ]]; then
    "$PWCLI" close >/dev/null 2>&1 || true
  fi
  kill "$SERVER_PID" >/dev/null 2>&1 || true
  wait "$SERVER_PID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for _ in {1..30}; do
  if curl -fsS "$BASE_URL/preview/radar_ui.html" >/dev/null 2>&1; then
    SERVER_READY=1
    break
  fi
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    echo "Preview HTTP server failed to start on port $PORT." >&2
    cat "$HTTP_LOG" >&2
    exit 1
  fi
  sleep 0.1
done

if [[ "$SERVER_READY" != "1" ]]; then
  echo "Preview HTTP server did not become ready on port $PORT." >&2
  exit 1
fi

capture_canvas() {
  local name="$1"
  local url="$2"
  local wait_ms="$3"

  if [[ "$BROWSER_OPENED" == "0" ]]; then
    "$PWCLI" open "$url" >/dev/null
    "$PWCLI" resize 900 760 >/dev/null
    BROWSER_OPENED=1
  else
    "$PWCLI" goto "$url" >/dev/null
  fi

  "$PWCLI" eval "() => new Promise(resolve => setTimeout(resolve, $wait_ms))" >/dev/null
  "$PWCLI" screenshot canvas --filename "$OUT_DIR/$name.png" >/dev/null
  echo "$OUT_DIR/$name.png"
}

capture_mode() {
  local mode="$1"
  local query=""
  if [[ "$mode" != "default" ]]; then
    query="?mode=$mode"
  fi
  capture_canvas "radar-$mode" "$BASE_URL/preview/radar_ui.html$query" "$WAIT_MS"
}

capture_boot_phase() {
  local name="$1"
  local phase="$2"
  capture_canvas "boot-$name" "$BASE_URL/preview/radar_ui.html?shot=boot&phase=$phase" "$SHOT_WAIT_MS"
}

capture_summon_phase() {
  local name="$1"
  local phase="$2"
  capture_canvas "summon-$name" "$BASE_URL/preview/radar_ui.html?shot=summon&phase=$phase" "$SHOT_WAIT_MS"
}

capture_transient_shot() {
  local name="$1"
  local shot="$2"
  capture_canvas "radar-$name" "$BASE_URL/preview/radar_ui.html?mode=field&shot=$shot" "$SHOT_WAIT_MS"
}

capture_boot_phase grid-wake 0.18
capture_boot_phase logo-scan 0.48
capture_boot_phase logo-ready 0.96
capture_boot_phase handoff 1
capture_mode default
capture_mode field
capture_mode sim
capture_mode debug
capture_transient_shot startup-acquire startup
capture_transient_shot idle-search idle
capture_transient_shot acquisition-echo acquire
capture_transient_shot target-trail trail
capture_transient_shot trace-blip trace
capture_transient_shot zoom-map zoom
capture_transient_shot proximity-lock lock
capture_transient_shot capture-burst capture
capture_transient_shot control-flashes controls
capture_transient_shot touch-echo touch
capture_transient_shot tilt-inertia tilt
capture_summon_phase gather 0.18
capture_summon_phase orbit 1
