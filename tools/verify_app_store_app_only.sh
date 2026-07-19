#!/usr/bin/env bash
set -euo pipefail

# Legacy filename retained so existing local/CI callers keep working. This now
# verifies the full iOS Release, including the user-facing radar device flow.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/ios/DragonRadarMVP/DragonRadarMVP.xcodeproj"
DERIVED_DATA="${APP_STORE_DERIVED_DATA_PATH:-${APP_ONLY_DERIVED_DATA_PATH:-${TMPDIR:-/tmp}/capsule-app-store-release}}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ALLOW_PLACEHOLDERS="${APP_STORE_ALLOW_PLACEHOLDERS:-${APP_ONLY_ALLOW_PLACEHOLDERS:-0}}"

cd "$ROOT"
rm -rf "$DERIVED_DATA"

DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -quiet \
  -project "$PROJECT" \
  -scheme DragonRadarMVP \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  clean build

APP="$DERIVED_DATA/Build/Products/Release-iphoneos/DragonRadarMVP.app"
EXECUTABLE="$APP/DragonRadarMVP"
INFO="$APP/Info.plist"
PRIVACY_MANIFEST="$APP/PrivacyInfo.xcprivacy"

[[ -x "$EXECUTABLE" ]] || {
  echo "Missing Release executable: $EXECUTABLE" >&2
  exit 1
}
[[ -f "$PRIVACY_MANIFEST" ]] || {
  echo "Release bundle is missing PrivacyInfo.xcprivacy" >&2
  exit 1
}

PRIVACY_JSON="$(plutil -convert json -o - "$PRIVACY_MANIFEST")"
if ! jq -e '.NSPrivacyTracking == false and (.NSPrivacyTrackingDomains | length) == 0' \
  >/dev/null <<<"$PRIVACY_JSON"; then
  echo "Release privacy manifest must disable tracking and contain no tracking domains" >&2
  exit 1
fi

required_privacy_types=(
  NSPrivacyCollectedDataTypeName
  NSPrivacyCollectedDataTypeUserID
  NSPrivacyCollectedDataTypeDeviceID
  NSPrivacyCollectedDataTypePreciseLocation
  NSPrivacyCollectedDataTypeCoarseLocation
  NSPrivacyCollectedDataTypeProductInteraction
  NSPrivacyCollectedDataTypeOtherUserContent
  NSPrivacyCollectedDataTypePerformanceData
  NSPrivacyCollectedDataTypeOtherDiagnosticData
)

for privacy_type in "${required_privacy_types[@]}"; do
  match_count="$(jq --arg type "$privacy_type" '[
      .NSPrivacyCollectedDataTypes[]
      | select(
          .NSPrivacyCollectedDataType == $type
          and .NSPrivacyCollectedDataTypeLinked == true
          and .NSPrivacyCollectedDataTypeTracking == false
          and .NSPrivacyCollectedDataTypePurposes == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
        )
    ] | length' <<<"$PRIVACY_JSON")"
  [[ "$match_count" == "1" ]] || {
    echo "Release privacy manifest is missing or misconfigures: $privacy_type" >&2
    exit 1
  }
done

declared_type_count="$(jq '.NSPrivacyCollectedDataTypes | length' <<<"$PRIVACY_JSON")"
[[ "$declared_type_count" == "${#required_privacy_types[@]}" ]] || {
  echo "Release privacy manifest data types differ from the reviewed nine-type declaration" >&2
  exit 1
}

[[ "$(plutil -extract CFBundleDisplayName raw -o - "$INFO")" == "Capsule Radar" ]] || {
  echo "Unexpected App Store display name" >&2
  exit 1
}
[[ "$(plutil -extract DragonRadarEnvironment raw -o - "$INFO")" == "Production" ]] || {
  echo "Release is not using the Production environment" >&2
  exit 1
}
[[ "$(plutil -extract NSBluetoothAlwaysUsageDescription raw -o - "$INFO")" == "蓝牙用于扫描、绑定和配置 Capsule Radar。" ]] || {
  echo "Release is missing the reviewed Bluetooth permission explanation" >&2
  exit 1
}

if plutil -extract NSMicrophoneUsageDescription raw -o - "$INFO" >/dev/null 2>&1; then
  echo "Release unexpectedly requests microphone access" >&2
  exit 1
fi

if ! otool -L "$EXECUTABLE" | rg -q 'CoreBluetooth\.framework/CoreBluetooth'; then
  echo "Release does not link CoreBluetooth; device scanning cannot work" >&2
  exit 1
fi

if strings "$EXECUTABLE" | rg -n -i \
  '(tamagotchi|拓麻歌子|pixel[ _-]?pet|beach[ _-]?scene|summon|bulma|goku|krillin|popo|七龙珠|龙珠)'; then
  echo "Retired pet or character code entered the App Store executable" >&2
  exit 1
fi

SYMBOL_DUMP="$DERIVED_DATA/app-store-release-symbols.txt"
DEVELOPER_DIR="$DEVELOPER_DIR" nm -j "$EXECUTABLE" | \
  DEVELOPER_DIR="$DEVELOPER_DIR" xcrun swift-demangle > "$SYMBOL_DUMP"

required_device_symbols=(
  'DragonRadarMVP.BLEDeviceBridge.startScan()'
  'DragonRadarMVP.DevicesView.body.getter'
  'DragonRadarMVP.DevicesRepository.listDevices()'
  'DragonRadarMVP.DiagnosticsRepository.submit(report:'
  'DragonRadarMVP.FirmwareUpdateView.'
)

for symbol_pattern in "${required_device_symbols[@]}"; do
  if ! rg -Fq "$symbol_pattern" "$SYMBOL_DUMP"; then
    echo "Release is missing required device implementation: $symbol_pattern" >&2
    exit 1
  fi
done

SWIFT_FILE_LIST="$(find "$DERIVED_DATA/Build/Intermediates.noindex" -path '*Release-iphoneos*' -name 'DragonRadarMVP.SwiftFileList' -print -quit)"
[[ -n "$SWIFT_FILE_LIST" ]] || {
  echo "Release Swift source list not found" >&2
  exit 1
}

required_device_sources=(
  BLEDeviceBridge.swift
  DevicesView.swift
  DiagnosticPackage.swift
  FirmwareReconnectPolicy.swift
  FirmwareUpdate.swift
  FirmwareUpdateView.swift
  PhysicalOTAAcceptanceCoordinator.swift
  SetupView.swift
)

for source_name in "${required_device_sources[@]}"; do
  if ! rg -Fq "/$source_name" "$SWIFT_FILE_LIST"; then
    echo "Device capability source is missing from Release: $source_name" >&2
    exit 1
  fi
done

if [[ "$ALLOW_PLACEHOLDERS" != "1" ]]; then
  for url_key in DragonRadarHTTPBaseURL DragonRadarRelayBaseURL DragonRadarPrivacyPolicyURL DragonRadarSupportURL; do
    value="$(plutil -extract "$url_key" raw -o - "$INFO")"
    if [[ -z "$value" || "$value" == *'.example'* || "$value" == *'[['* ]]; then
      echo "Release URL is missing or still a placeholder: $url_key" >&2
      exit 1
    fi
  done
fi

echo "app-store-release-ok"
