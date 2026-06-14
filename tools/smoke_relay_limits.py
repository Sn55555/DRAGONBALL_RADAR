#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / "relay" / "server.py"


def load_server_module():
    spec = importlib.util.spec_from_file_location("dragon_radar_relay_server", SERVER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("server_module_unavailable")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def main() -> int:
    server = load_server_module()

    limiter = server.FixedWindowRateLimiter(limit=2, window_seconds=10)
    assert limiter.allow("client-a", now=100.0)
    assert limiter.allow("client-a", now=101.0)
    assert not limiter.allow("client-a", now=102.0)
    assert limiter.allow("client-a", now=111.0)
    assert limiter.allow("client-b", now=102.0)

    class PeerStub:
        message_window_started_at = 200.0
        message_window_count = 0

    peer = PeerStub()
    assert server.raw_message_size("abc") == 3
    assert server.raw_message_size("雷达") == len("雷达".encode("utf-8"))
    assert server.websocket_message_allowed(peer, now=200.1)

    print("relay-limits-smoke-ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
