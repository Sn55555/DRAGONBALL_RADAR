#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  tools/deploy_relay_update.sh [deploy] [user@host]
  tools/deploy_relay_update.sh rollback [user@host] /remote/path/server.py.bak.YYYYMMDDHHMMSS

Deploy uploads relay/server.py, backs up the current remote file, restarts the
Relay, checks /healthz, and automatically restores the backup if health fails.
Rollback restores a named remote backup and performs the same health check.
USAGE
}

DEFAULT_HOST="root@139.224.41.192"
MODE="deploy"
HOST="$DEFAULT_HOST"
ROLLBACK_BACKUP=""

case "${1:-}" in
  ""|deploy)
    MODE="deploy"
    HOST="${2:-$DEFAULT_HOST}"
    ;;
  rollback)
    MODE="rollback"
    HOST="${2:-$DEFAULT_HOST}"
    ROLLBACK_BACKUP="${3:-}"
    if [[ -z "$ROLLBACK_BACKUP" ]]; then
      usage >&2
      exit 64
    fi
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    MODE="deploy"
    HOST="$1"
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"
if [[ "$MODE" == "deploy" ]]; then
  python3 -m py_compile relay/server.py
fi

remote_script="$(cat <<'REMOTE'
set -euo pipefail

MODE="${MODE:-deploy}"
ROLLBACK_BACKUP="${ROLLBACK_BACKUP:-}"
TMP_DIR=""

cleanup() {
  if [ -n "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

find_relay_pid() {
  local found
  found="$(
    ss -ltnp 2>/dev/null |
      awk '$4 ~ /:8787$/ || $4 ~ /\[::\]:8787$/ { print }' |
      sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' |
      head -n 1
  )"
  if [ -z "$found" ]; then
    found="$(fuser 8787/tcp 2>/dev/null | awk '{print $1}' | head -n 1 || true)"
  fi
  printf '%s\n' "$found"
}

detect_script() {
  local pid="$1"
  local cwd detected
  cwd="$(readlink -f "/proc/$pid/cwd")"
  detected="$(
    tr '\0' '\n' < "/proc/$pid/cmdline" |
      awk '/server\.py$/ || /relay.*\.py$/ { print; exit }'
  )"
  if [ -n "$detected" ] && [ ! -f "$detected" ] && [ -f "$cwd/$detected" ]; then
    detected="$cwd/$detected"
  fi
  printf '%s\n' "$detected"
}

detect_http_port() {
  local pid="$1"
  tr '\0' '\n' < "/proc/$pid/cmdline" |
    awk '
      /^--http-port=/ { split($0, parts, "="); print parts[2]; found=1; exit }
      prev == "--http-port" { print $0; found=1; exit }
      { prev=$0 }
      END { if (!found) print "8788" }
    '
}

detect_systemd_unit() {
  local pid="$1"
  local maybe_unit main_pid
  while read -r maybe_unit _; do
    [ -n "$maybe_unit" ] || continue
    main_pid="$(systemctl show -p MainPID --value "$maybe_unit" 2>/dev/null || true)"
    if [ "$main_pid" = "$pid" ]; then
      printf '%s\n' "$maybe_unit"
      return 0
    fi
  done < <(systemctl list-units --type=service --all --no-legend --no-pager 2>/dev/null || true)
}

restart_relay() {
  local pid="$1"
  local script="$2"
  local cwd="$3"
  local unit="$4"
  if [ -n "$unit" ]; then
    echo "RESTART systemd unit $unit"
    systemctl restart "$unit"
  else
    echo "RESTART pid $pid with original Python executable"
    local python_exe
    python_exe="$(readlink -f "/proc/$pid/exe")"
    kill -TERM "$pid"
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid"
    fi
    cd "$cwd"
    nohup "$python_exe" "$script" --host 0.0.0.0 --port 8787 >/tmp/dragon-radar-relay.log 2>&1 &
  fi
}

health_check() {
  local http_port="$1"
  python3 - "$http_port" <<'PY'
import json
import sys
from urllib import request

port = sys.argv[1]
with request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=4) as response:
    payload = json.loads(response.read().decode("utf-8"))
if payload.get("ok") is not True or payload.get("service") != "dragon-radar-relay":
    raise SystemExit(f"bad health payload: {payload!r}")
PY
}

pid="$(find_relay_pid)"
if [ -z "$pid" ]; then
  echo "ERROR: no process is listening on TCP 8787" >&2
  exit 2
fi

cwd="$(readlink -f "/proc/$pid/cwd")"
script="$(detect_script "$pid")"
if [ -z "$script" ] || [ ! -f "$script" ]; then
  echo "ERROR: cannot detect relay server.py from pid $pid" >&2
  tr '\0' ' ' < "/proc/$pid/cmdline" >&2
  echo >&2
  exit 3
fi
http_port="$(detect_http_port "$pid")"
unit="$(detect_systemd_unit "$pid" || true)"

backup=""
if [ "$MODE" = "deploy" ]; then
  TMP_DIR="/tmp/dragon-radar-relay-deploy-$$"
  mkdir -p "$TMP_DIR"
  tar -xf - -C "$TMP_DIR"
  upload="$TMP_DIR/relay/server.py"
  python3 -m py_compile "$upload"
  backup="$script.bak.$(date +%Y%m%d%H%M%S)"
  cp "$script" "$backup"
  cp "$upload" "$script"
  python3 -m py_compile "$script"
  echo "UPDATED $script"
  echo "BACKUP  $backup"
elif [ "$MODE" = "rollback" ]; then
  if [ -z "$ROLLBACK_BACKUP" ] || [ ! -f "$ROLLBACK_BACKUP" ]; then
    echo "ERROR: rollback backup not found: $ROLLBACK_BACKUP" >&2
    exit 5
  fi
  python3 -m py_compile "$ROLLBACK_BACKUP"
  backup="$script.bak.before-rollback.$(date +%Y%m%d%H%M%S)"
  cp "$script" "$backup"
  cp "$ROLLBACK_BACKUP" "$script"
  python3 -m py_compile "$script"
  echo "ROLLBACK_FROM $ROLLBACK_BACKUP"
  echo "BACKUP_BEFORE_ROLLBACK $backup"
else
  echo "ERROR: unsupported mode $MODE" >&2
  exit 64
fi

restart_relay "$pid" "$script" "$cwd" "$unit"

sleep 1
ss -ltnp 2>/dev/null | grep ':8787' || {
  echo "ERROR: relay is not listening on 8787 after restart" >&2
  if [ -n "$backup" ] && [ -f "$backup" ]; then
    echo "ROLLBACK restore $backup"
    cp "$backup" "$script"
    new_pid="$(find_relay_pid || true)"
    [ -n "$new_pid" ] || new_pid="$pid"
    restart_relay "$new_pid" "$script" "$cwd" "$unit"
  fi
  exit 4
}

if ! health_check "$http_port"; then
  echo "ERROR: /healthz failed on port $http_port" >&2
  if [ -n "$backup" ] && [ -f "$backup" ]; then
    echo "ROLLBACK restore $backup"
    cp "$backup" "$script"
    new_pid="$(find_relay_pid || true)"
    [ -n "$new_pid" ] || new_pid="$pid"
    restart_relay "$new_pid" "$script" "$cwd" "$unit"
    sleep 1
    health_check "$http_port"
    echo "ROLLBACK_OK"
  fi
  exit 6
fi

if [ "$MODE" = "rollback" ]; then
  echo "ROLLBACK_OK"
else
  echo "HEALTH_OK http://127.0.0.1:$http_port/healthz"
  echo "DEPLOY_OK"
fi
REMOTE
)"

if [[ "$MODE" == "deploy" ]]; then
  tar -cf - relay/server.py | ssh "$HOST" "MODE=deploy bash -lc $(printf '%q' "$remote_script")"
else
  ssh "$HOST" "MODE=rollback ROLLBACK_BACKUP=$(printf '%q' "$ROLLBACK_BACKUP") bash -lc $(printf '%q' "$remote_script")"
fi
