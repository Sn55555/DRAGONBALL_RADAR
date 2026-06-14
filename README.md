# Dragon Radar

Dragon Radar is now a room-based multi-device project: each member uses one
iPhone and one Waveshare ESP32-S3-Touch-AMOLED-1.75C. The iPhone provides
location, room management, and device provisioning. The ESP renders the radar
screen, connects to the Relay over Wi-Fi/WebSocket, and acts as the push-to-talk
voice terminal.

The old physical `DBALL-*` beacon hunt is removed from the product direction.
Beacon firmware, beacon flashing, beacon verification, collection, and field
hunt gates are no longer part of the target.

## Current Goal

- Up to 7 members in one room.
- One `iPhone + ESP` pair per member.
- iPhone uploads live location to the Relay.
- ESP receives room state and displays remote members on the round radar UI.
- ESP captures and plays voice.
- Relay manages room state, member presence, location forwarding, and push-to-talk
  floor control.

## Main Paths

- `firmware/DragonRadar/DragonRadar.ino` - ESP radar firmware.
- `firmware/DragonRadar/pin_config.h` - Waveshare board pin map.
- `relay/server.py` - minimal WebSocket Relay.
- `ios/DragonRadarMVP/` - iOS app project.
- `docs/product-design.zh.md` - current product target and scope.
- `docs/remote-multi-radar-architecture.zh.md` - room-based architecture.
- `docs/ios-app-information-architecture.zh.md` - iOS IA, pages, interactions, states.
- `preview/radar_ui.html` - browser visual preview for the radar UI.
- `tools/build_radar.sh` - firmware build/upload helper.
- `tools/smoke_relay.py` - Relay protocol smoke test.
- `tools/smoke_esp_provisioning_ble.py` - ESP BLE provisioning smoke support.
- `tools/run_multi_test_groups.sh` - multi-group Relay simulation helper.
- `tools/simulate_mac_room_member.py` - simulated room member sender.

## ESP Firmware

The ESP firmware initializes:

- 466x466 AMOLED radar UI.
- CST9217 touch.
- QMI8658 IMU.
- ES7210/ES8311 audio path.
- BLE provisioning service named `CapsuleRadar-<shortId>`.
- Wi-Fi STA connection from App-provided credentials.
- WebSocket connection to `/v1/radar/device/ws`.

Build:

```sh
tools/build_radar.sh field
tools/build_radar.sh fielddiag
tools/build_radar.sh diag
```

Release pairing key preflight:

```sh
export DRAGON_RADAR_PAIRING_HMAC_KEY='<production key>'
tools/prepare_release_pairing_key.sh check
tools/prepare_release_pairing_key.sh write-env output/release-current/secrets
PAIRING_HMAC_KEY="$DRAGON_RADAR_PAIRING_HMAC_KEY" RADAR_RELEASE=1 tools/build_radar.sh field
```

The release preflight rejects the default development key, short keys, and
server/firmware key mismatches. It prints only a redacted fingerprint.

Upload when a board is connected:

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/build_radar.sh field upload
```

The `field` firmware is now the room radar firmware. It does not scan physical
DBALL beacons.

## Relay

Install dependencies:

```sh
python3 -m pip install -r relay/requirements.txt
```

Run locally:

```sh
python3 relay/server.py --host 127.0.0.1 --port 8787
```

Smoke test:

```sh
python3 tools/smoke_relay.py --url ws://127.0.0.1:8787 --room DRGN-SMOKE
```

The current Relay is intentionally minimal: it keeps rooms in memory, merges App
and ESP peers by group, broadcasts `room_state`, forwards locations, and enforces
a push-to-talk floor with `voice_busy`.

## iOS App

Open:

```sh
open ios/DragonRadarMVP/DragonRadarMVP.xcodeproj
```

Build from CLI:

```sh
xcodebuild \
  -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
  -scheme DragonRadarMVP \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The app currently handles:

- Room tabs: Radar, Rooms, Devices, Account.
- CoreLocation live location publishing.
- Simulated-location filtering.
- CoreBluetooth scan/connect/read/write for the ESP provisioning service.
- Relay App WebSocket connection.
- `room_state` parsing into member distance, bearing, online, and voice state.

## Runtime Chain

1. iPhone joins or creates a room.
2. iPhone scans `CapsuleRadar-*` over BLE.
3. App writes `wifi_config`, `server_config`, and `local_location` to ESP.
4. ESP connects Wi-Fi and then the Relay device WebSocket.
5. App connects the Relay app WebSocket and uploads location.
6. Relay broadcasts `room_state`.
7. ESP displays remote members on the radar grid.
8. ESP push-to-talk sends `voice_frame`; Relay grants or rejects the floor.
9. Other ESP devices receive voice events and playback remote audio.

## Verification

Current software checks:

```sh
tools/build_radar.sh field
python3 tools/smoke_relay.py --url ws://127.0.0.1:8787 --room DRGN-SMOKE
xcodebuild -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
  -scheme DragonRadarMVP \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Current missing proof:

- Real `2+` member hardware run with separate iPhones and ESP boards.
- Real ESP Wi-Fi provisioning through App.
- Real room-state rendering on the ESP screen.
- Real push-to-talk voice capture/playback across two ESP devices.
- Production Relay hardening still needs TLS/domain rollout and real deployment
  rollback drills. Authentication, device token validation, SQLite persistence,
  audit logs, HTTP/WS limits, `/healthz` limit reporting, and deploy-time
  backup/health-check/rollback scripting are implemented.
