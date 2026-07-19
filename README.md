# 胶囊（Capsule Radar）

Capsule Radar is a room-based multi-device project: each member uses one
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
- `docs/location-integration-stage-report-2026-07-20.zh.md` - two-radar
  location integration checkpoint and remaining gates.
- `docs/ios-app-information-architecture.zh.md` - iOS IA, pages, interactions, states.
- `docs/firmware-ota.zh.md` - signed firmware OTA, Relay API, and release runbook.
- `preview/radar_ui.html` - browser visual preview for the radar UI.
- `tools/build_radar.sh` - firmware build/upload helper.
- `tools/package_ota_release.py` - signed OTA release packager.
- `tools/verify_ota_release.py` - offline OTA manifest/artifact verifier.
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

### Signed firmware OTA

Build, package, and verify a release:

```sh
export DRAGON_RADAR_FIRMWARE_VERSION=1.2.0
export DRAGON_RADAR_FIRMWARE_BUILD=120
export DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER=12
export DRAGON_RADAR_OTA_ROOT_CA_PEM_B64="$(openssl base64 -A -in /path/to/relay-root-ca.pem)"
export PAIRING_HMAC_KEY='<production pairing key>'
export RADAR_RELEASE=1
unset DRAGON_RADAR_OTA_ALLOW_HTTP
tools/build_radar.sh field
python3 tools/package_ota_release.py \
  --version "$DRAGON_RADAR_FIRMWARE_VERSION" \
  --build "$DRAGON_RADAR_FIRMWARE_BUILD" \
  --minimum-version 1.0.0 \
  --security-counter "$DRAGON_RADAR_FIRMWARE_SECURITY_COUNTER" \
  --force
python3 tools/verify_ota_release.py output/ota-current
```

The build writes a SHA-256-bound `firmware-metadata.json` beside `firmware.bin`;
packaging fails if the compiled version/build/security counter, embedded OTA
public key, TLS transport readiness, or binary digest does not exactly match the
release inputs. Stable packages require a configured root CA and reject firmware
compiled to allow HTTP or built without the production pairing-key preflight.
The package is signed with ECDSA P-256/SHA-256. The
private key stays on the release machine; Relay, App, and ESP only receive the public key. See
`docs/firmware-ota.zh.md` for the canonical signed bytes, key handling,
anti-downgrade rule, Relay environment, first USB bootstrap, and rollback gates.
Artifact basenames include their full SHA-256. On `--force`, packaging atomically
promotes the new current manifest while retaining the three newest verified old
releases by default, so an ESP can continue an authenticated Range download from
its original immutable URL. Adjust the bounded history with `--retain-releases`;
do not discard `output/ota-current/retained/` during production promotion.

## Relay

Install dependencies:

```sh
python3 -m pip install -r relay/requirements.txt
```

Run locally:

```sh
export DRAGON_RADAR_FIRMWARE_RELEASE_DIR="$PWD/output/ota-current"
export DRAGON_RADAR_OTA_PUBLIC_KEY="$PWD/.secrets/ota-signing-public.pem"
python3 relay/server.py --host 127.0.0.1 --port 8787
```

A real ESP connecting to a local plain-HTTP Relay needs a separately compiled
development image with `DRAGON_RADAR_OTA_ALLOW_HTTP=1` and packaging with
`--allow-development-http`; that local Relay must also explicitly set
`DRAGON_RADAR_ALLOW_DEVELOPMENT_OTA=1`. Production must never set this switch,
ship that image, or replace certificate checks with an insecure TLS client.

Smoke test:

```sh
python3 tools/smoke_relay.py --url ws://127.0.0.1:8787 --room DRGN-SMOKE
```

The Relay persists auth, rooms, devices, diagnostics, and audit events in SQLite;
merges live App and ESP peers by group; broadcasts `room_state`; forwards
locations; enforces a push-to-talk floor; and exposes only signed firmware
releases that pass manifest, signature, size, and SHA-256 validation.

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

For OTA, the signed manifest comes from Relay, App validates it and sends an
absolute same-origin artifact URL over BLE, and ESP downloads with its device
Bearer token into the inactive OTA partition before verified reboot. ESP repeats
the origin/path check against its persisted HTTP API URL before attaching that
token; older devices without this config must be resynchronized by the App.

## Verification

Current software checks:

```sh
tools/verify_project.sh quick
tools/build_radar.sh field
python3 tools/smoke_relay.py --url ws://127.0.0.1:8787 --room DRGN-SMOKE
xcodebuild -project ios/DragonRadarMVP/DragonRadarMVP.xcodeproj \
  -scheme DragonRadarMVP \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Location integration checkpoint:

- Two separate `iPhone + ESP` member pairs have completed real-room provisioning,
  live location forwarding, member rendering, reconnect, and stationary keepalive
  verification. See `docs/location-integration-stage-report-2026-07-20.zh.md`.

Current missing proof:

- Real push-to-talk voice capture/playback across two ESP devices.
- Long-running mobile, weak-network, hotspot-switching, and background-location
  soak tests across the two physical member pairs.
- Real OTA interruption, power-loss, anti-downgrade, and boot rollback tests on
  an OTA-capable factory-flashed board.
- Production Relay hardening still needs TLS/domain rollout and real deployment
  rollback drills. Authentication, device token validation, SQLite persistence,
  audit logs, HTTP/WS limits, `/healthz` limit reporting, and deploy-time
  backup/health-check/rollback scripting are implemented.
