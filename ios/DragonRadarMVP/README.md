# DragonRadarMVP

Native SwiftUI MVP for the Dragon Radar companion iOS app.

## Scope

This MVP implements the app structure from:

- `../../docs/ios-app-information-architecture.zh.md`
- `../../docs/remote-multi-radar-architecture.zh.md`

Current capabilities:

- 4 native SwiftUI tabs: `雷达`, `房间`, `设备`, `我的`
- Real CoreLocation capture and automatic Relay location upload
- Real Relay/WSS client for `hello`, `app_location`, `heartbeat`, `room_switch`, and `room_state`
- Real CoreBluetooth scan/connect/write path for the ESP provisioning characteristics
- Room state mapping from Relay, including member distance, bearing, location freshness, and voice floor display state
- ESP binding and iPhone hotspot / Wi-Fi config sheets
- Member detail view
- Device diagnostics view
- Sign in with Apple entry, Apple identity token server verification, development login gate, Keychain session restore, and token refresh
- Server-backed room list, room creation, join, invite, rename, and membership persistence
- Server-issued HMAC-verified ESP pairing response and revocable device tokens
- Debug/Release environment split: Debug can use the test IP, Release is gated to `https://` and `wss://`
- Launch diagnostics package copy/upload flow with token/password/precise-location-history redaction
- Black-and-white early manga visual direction
- Toy-like mechanical casing, screws, screentone, ink panels
- Liquid Glass on iOS 26+ with material fallback on older iOS

Still missing for launch readiness:

- Production pairing key management and rotation process
- Production Relay domain, TLS termination, rate limits, and deployment rollback
- ESP voice frame capture/playback integration and room-level voice floor hardening
- Privacy copy, TestFlight packaging, and background-location field matrix

## Build

```sh
cd ios/DragonRadarMVP
xcodegen generate
xcodebuild -project DragonRadarMVP.xcodeproj -scheme DragonRadarMVP -destination 'generic/platform=iOS Simulator' build
```

## Open

```sh
open ios/DragonRadarMVP/DragonRadarMVP.xcodeproj
```
