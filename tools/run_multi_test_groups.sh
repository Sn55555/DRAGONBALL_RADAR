#!/usr/bin/env bash
set -euo pipefail

URL="${1:-ws://139.224.41.192:8787}"
ROOM="${2:-CAPS-07}"
LOCAL_GROUP="${3:-A17C}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIM="${ROOT}/tools/simulate_mac_room_member.py"

# Do not simulate app-${LOCAL_GROUP}; the real iPhone owns that app peer id.

eval "$(
python3 - "$URL" "$ROOM" "$LOCAL_GROUP" <<'PY'
import asyncio
import json
import math
import sys
from urllib.parse import urlencode

import websockets

url, room, local_group = sys.argv[1:4]


def offset(lat_e7: int, lon_e7: int, north_m: float, east_m: float) -> tuple[int, int]:
    lat = lat_e7 / 10_000_000
    lon = lon_e7 / 10_000_000
    next_lat = lat + north_m / 111_320.0
    lon_scale = max(0.01, math.cos(math.radians(lat)))
    next_lon = lon + east_m / (111_320.0 * lon_scale)
    return round(next_lat * 10_000_000), round(next_lon * 10_000_000)


async def read_anchor() -> tuple[int, int]:
    base = url.rstrip("/")
    query = urlencode({"room": room, "app_id": "app-anchor-probe", "group_id": local_group})
    async with websockets.connect(f"{base}/v1/radar/app/ws?{query}", ping_interval=20, ping_timeout=20) as socket:
        for _ in range(8):
            message = json.loads(await asyncio.wait_for(socket.recv(), timeout=4))
            if message.get("type") != "room_state":
                continue
            for member in message.get("members", []):
                if member.get("group_id") != local_group and member.get("member_id") != local_group:
                    continue
                location = member.get("location") or {}
                lat_e7 = int(location.get("lat_e7") or 0)
                lon_e7 = int(location.get("lon_e7") or 0)
                if lat_e7 and lon_e7:
                    return lat_e7, lon_e7
    raise RuntimeError(f"no live location for {local_group} in room {room}")


lat_e7, lon_e7 = asyncio.run(read_anchor())
points = {
    "NEAR": offset(lat_e7, lon_e7, 30, 65),
    "EAST": offset(lat_e7, lon_e7, 30, 260),
    "MID": offset(lat_e7, lon_e7, 360, 300),
    "NORTH": offset(lat_e7, lon_e7, 650, 0),
    "FAR": offset(lat_e7, lon_e7, 1200, 900),
    "KM500": offset(lat_e7, lon_e7, 500_000, 0),
}
print(f"BASE_LAT_E7={lat_e7}")
print(f"BASE_LON_E7={lon_e7}")
for name, (point_lat_e7, point_lon_e7) in points.items():
    print(f"{name}_LAT_E7={point_lat_e7}")
    print(f"{name}_LON_E7={point_lon_e7}")
PY
)"

echo "Anchored test groups to ${LOCAL_GROUP}: ${BASE_LAT_E7},${BASE_LON_E7}" >&2

python3 -u "${SIM}" --url "${URL}" --room "${ROOM}" --group-id "sim-near" --app-id "app-sim-near" --device-id "sim-near" --name "近距对照" --mode circle --lat-e7 "${NEAR_LAT_E7}" --lon-e7 "${NEAR_LON_E7}" --radius-m 45 --period-s 90 --interval 2 --speaking --speak-period-s 8 --speak-duty-s 2 &

python3 -u "${SIM}" --url "${URL}" --room "${ROOM}" --group-id "sim-east" --app-id "app-sim-east" --device-id "sim-east" --name "东侧对照" --mode circle --lat-e7 "${EAST_LAT_E7}" --lon-e7 "${EAST_LON_E7}" --radius-m 90 --period-s 130 --interval 2 &

python3 -u "${SIM}" --url "${URL}" --room "${ROOM}" --group-id "sim-mid" --app-id "app-sim-mid" --device-id "sim-mid" --name "中距对照" --mode circle --lat-e7 "${MID_LAT_E7}" --lon-e7 "${MID_LON_E7}" --radius-m 140 --period-s 160 --interval 2 &

python3 -u "${SIM}" --url "${URL}" --room "${ROOM}" --group-id "sim-north" --app-id "app-sim-north" --device-id "sim-north" --name "北侧对照" --mode circle --lat-e7 "${NORTH_LAT_E7}" --lon-e7 "${NORTH_LON_E7}" --radius-m 180 --period-s 190 --interval 2 &

python3 -u "${SIM}" --url "${URL}" --room "${ROOM}" --group-id "sim-far" --app-id "app-sim-far" --device-id "sim-far" --name "远距对照" --mode circle --lat-e7 "${FAR_LAT_E7}" --lon-e7 "${FAR_LON_E7}" --radius-m 260 --period-s 220 --interval 2 &

python3 -u "${SIM}" --url "${URL}" --room "${ROOM}" --group-id "sim-500km" --app-id "app-sim-500km" --device-id "sim-500km" --name "500KM对照" --mode fixed --lat-e7 "${KM500_LAT_E7}" --lon-e7 "${KM500_LON_E7}" --interval 2 &

wait
