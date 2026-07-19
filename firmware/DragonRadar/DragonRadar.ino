#include <Arduino.h>
#include <Arduino_GFX_Library.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLESecurity.h>
#include <Network.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <WebSocketsClient.h>
#include <ESP_I2S.h>
#include <Preferences.h>
#include <Wire.h>
#include <base64.h>
#include <esp_sleep.h>
#include <esp_system.h>
#include <host/ble_store.h>
#include <math.h>
#include <mbedtls/md.h>
#include <string.h>
#include <time.h>

#include "SensorQMI8658.hpp"
#include "TouchDrvCSTXXX.hpp"
#include "DisplayOrientation.h"
#include "FirmwareVersion.h"
#include "HeadingAlignment.h"
#include "OtaManager.h"
#include "bulma_boot_badge.h"
#include "boot_audio_pcm.h"
#include "pin_config.h"

#ifndef DRAGON_RADAR_DEBUG_HUD
#define DRAGON_RADAR_DEBUG_HUD 0
#endif

#ifndef DRAGON_RADAR_SCAN_LINE
#define DRAGON_RADAR_SCAN_LINE 0
#endif

#ifndef DRAGON_RADAR_GRID_SNAP
#define DRAGON_RADAR_GRID_SNAP 1
#endif

#ifndef DRAGON_RADAR_SERIAL_DIAG
#define DRAGON_RADAR_SERIAL_DIAG 0
#endif

#ifndef DRAGON_RADAR_REMOTE_BLE
#define DRAGON_RADAR_REMOTE_BLE 1
#endif

#ifndef DRAGON_RADAR_PAIRING_HMAC_KEY
#define DRAGON_RADAR_PAIRING_HMAC_KEY "dragon-radar-dev-pairing-key"
#endif

#ifndef DRAGON_RADAR_ALLOW_LEGACY_PAIRING
#define DRAGON_RADAR_ALLOW_LEGACY_PAIRING 0
#endif

#ifndef DRAGON_RADAR_PROTOCOL_VERSION
#define DRAGON_RADAR_PROTOCOL_VERSION 2
#endif

#ifndef DRAGON_RADAR_MIN_RELAY_PROTOCOL_VERSION
#define DRAGON_RADAR_MIN_RELAY_PROTOCOL_VERSION 2
#endif

#ifndef DRAGON_RADAR_BRIGHTNESS
#define DRAGON_RADAR_BRIGHTNESS 184
#endif

#ifndef DRAGON_RADAR_AUDIO_GAIN
#define DRAGON_RADAR_AUDIO_GAIN 100
#endif

#ifndef DRAGON_RADAR_SOUND_EFFECTS
#define DRAGON_RADAR_SOUND_EFFECTS 1
#endif

#ifndef DRAGON_RADAR_FRAME_MS
#define DRAGON_RADAR_FRAME_MS 25
#endif

#ifndef DRAGON_RADAR_DISPLAY_BUS_HZ
#define DRAGON_RADAR_DISPLAY_BUS_HZ 80000000
#endif

#ifndef DRAGON_RADAR_BOOT_FRAME_DELAY_MS
#define DRAGON_RADAR_BOOT_FRAME_DELAY_MS 45
#endif

static_assert(DRAGON_RADAR_BRIGHTNESS >= 0 && DRAGON_RADAR_BRIGHTNESS <= 255,
              "DRAGON_RADAR_BRIGHTNESS must be in 0..255");
static_assert(DRAGON_RADAR_AUDIO_GAIN >= 0 && DRAGON_RADAR_AUDIO_GAIN <= 200,
              "DRAGON_RADAR_AUDIO_GAIN must be in 0..200");
static_assert(DRAGON_RADAR_SOUND_EFFECTS == 0 || DRAGON_RADAR_SOUND_EFFECTS == 1,
              "DRAGON_RADAR_SOUND_EFFECTS must be 0 or 1");
static_assert(DRAGON_RADAR_GRID_SNAP == 0 || DRAGON_RADAR_GRID_SNAP == 1,
              "DRAGON_RADAR_GRID_SNAP must be 0 or 1");
static_assert(DRAGON_RADAR_SERIAL_DIAG == 0 || DRAGON_RADAR_SERIAL_DIAG == 1,
              "DRAGON_RADAR_SERIAL_DIAG must be 0 or 1");
static_assert(DRAGON_RADAR_REMOTE_BLE == 0 || DRAGON_RADAR_REMOTE_BLE == 1,
              "DRAGON_RADAR_REMOTE_BLE must be 0 or 1");
static_assert(DRAGON_RADAR_ALLOW_LEGACY_PAIRING == 0 || DRAGON_RADAR_ALLOW_LEGACY_PAIRING == 1,
              "DRAGON_RADAR_ALLOW_LEGACY_PAIRING must be 0 or 1");
static_assert(DRAGON_RADAR_PROTOCOL_VERSION >= 1,
              "DRAGON_RADAR_PROTOCOL_VERSION must be >= 1");
static_assert(DRAGON_RADAR_MIN_RELAY_PROTOCOL_VERSION >= 1,
              "DRAGON_RADAR_MIN_RELAY_PROTOCOL_VERSION must be >= 1");
static_assert(DRAGON_RADAR_FRAME_MS >= 20 && DRAGON_RADAR_FRAME_MS <= 180,
              "DRAGON_RADAR_FRAME_MS must be in 20..180");
static_assert(DRAGON_RADAR_DISPLAY_BUS_HZ >= 20000000 && DRAGON_RADAR_DISPLAY_BUS_HZ <= 80000000,
              "DRAGON_RADAR_DISPLAY_BUS_HZ must be in 20000000..80000000");
static_assert(DRAGON_RADAR_BOOT_FRAME_DELAY_MS >= 30 && DRAGON_RADAR_BOOT_FRAME_DELAY_MS <= 140,
              "DRAGON_RADAR_BOOT_FRAME_DELAY_MS must be in 30..140");

namespace {

using DragonRadarDisplayOrientation::ScreenDirection;

constexpr int kScreenW = LCD_WIDTH;
constexpr int kScreenH = LCD_HEIGHT;
constexpr int kCx = LCD_WIDTH / 2;
constexpr int kCy = LCD_HEIGHT / 2;
constexpr int kRadarRadius = 214;
constexpr int kRadarGridRadius = min(kCx, kCy);
constexpr int kTargetMaxRadius = kRadarRadius - 28;
constexpr uint8_t kRadarGridCellsAcross = 8;
constexpr int kFixedRadarGridPitch = (kRadarGridRadius * 2) / kRadarGridCellsAcross;
constexpr int kRadarGridXOffsetHalfPx = -1;
constexpr int kRadarGridYOffsetHalfPx = -1;
constexpr float kPi = 3.14159265358979323846f;
constexpr float kPttRippleOriginDeg = 42.0f;
constexpr float kAltButtonOriginDeg = kPttRippleOriginDeg + 180.0f;
constexpr uint32_t kFrameMs = DRAGON_RADAR_FRAME_MS;
constexpr int32_t kDisplayBusHz = DRAGON_RADAR_DISPLAY_BUS_HZ;
constexpr uint32_t kBootFrameDelayMs = DRAGON_RADAR_BOOT_FRAME_DELAY_MS;
constexpr uint32_t kBootDurationMs = 3600;
constexpr uint32_t kMainFadeInMs = 720;
constexpr uint32_t kBootFadeInMs = kMainFadeInMs;
constexpr uint32_t kBootFadeOutMs = kMainFadeInMs;
constexpr uint32_t kSettingsFadeOutMs = kMainFadeInMs;
constexpr uint32_t kSettingsFadeInMs = kMainFadeInMs;
constexpr uint32_t kStartupAcquireMs = 980;
constexpr uint32_t kBlePairingCodeDisplayMs = 45000;
constexpr uint32_t kBlePairingResultDisplayMs = 1800;
constexpr uint32_t kTouchEchoMs = 520;
constexpr uint32_t kPttRippleArchRiseMs = 180;
constexpr uint32_t kPttRippleReleaseMs = 860;
constexpr uint32_t kButtonTapPressMs = 220;
constexpr uint32_t kButtonTapReleaseMs = 360;
constexpr uint32_t kButtonDebounceMs = 45;
constexpr uint32_t kButtonLongPressMs = 900;
constexpr uint32_t kHeadingCalibrationHoldMs = 1200;
constexpr int16_t kHeadingCalibrationMoveTolerancePx = 32;
constexpr int16_t kEdgeGestureActivationPx = 10;
constexpr uint32_t kSystemMenuTimeoutMs = 8000;
constexpr uint32_t kSystemMenuControlFeedbackMs = 220;
constexpr uint32_t kSystemMenuPageTransitionMs = 180;
constexpr uint32_t kStandbyTouchWakeMs = 600;
constexpr uint32_t kPowerConfirmHoldMs = 1500;
constexpr uint32_t kFactoryResetConfirmHoldMs = 4000;
constexpr int16_t kSystemMenuSwipeThresholdPx = 52;
constexpr int16_t kSystemMenuEdgeTapWidthPx = 104;
constexpr int16_t kSystemMenuActionCenterY = 342;
constexpr int16_t kSystemMenuActionRadius = 70;
constexpr uint8_t kAxp2101Address = 0x34;
constexpr uint8_t kAxpStatus1Reg = 0x00;
constexpr uint8_t kAxpStatus2Reg = 0x01;
constexpr uint8_t kAxpChargerFuelGaugeReg = 0x18;
constexpr uint8_t kAxpIrqEnable1Reg = 0x41;
constexpr uint8_t kAxpIrqStatus1Reg = 0x49;
constexpr uint8_t kAxpBatteryVoltageHighReg = 0x34;
constexpr uint8_t kAxpBatteryVoltageLowReg = 0x35;
constexpr uint8_t kAxpBatteryPercentReg = 0xA4;
constexpr uint8_t kAxpGaugeEnableBit = 0x08;
constexpr uint8_t kAxpBatteryPresentBit = 0x08;
constexpr uint8_t kAxpPowerKeyLongPressBit = 0x04;
constexpr uint8_t kAxpPowerKeyShortPressBit = 0x08;
constexpr int kAudioSampleRate = 16000;
constexpr int kBootAudioSampleRate = 44100;
constexpr uint8_t kBootAudioChannels = 2;
constexpr uint8_t kBootAudioVolumePercent = 38;
constexpr uint8_t kBootCodecOutputVolumePercent = 76;
constexpr int16_t kBootAudioPeakLimit = 19000;
constexpr uint16_t kBootAudioFadeInMs = 18;
constexpr uint16_t kBootAudioFadeOutMs = 220;
constexpr uint8_t kDisplayBrightness = DRAGON_RADAR_BRIGHTNESS;
constexpr int kAudioGainPercent = DRAGON_RADAR_AUDIO_GAIN;
constexpr bool kSoundEffectsEnabled = DRAGON_RADAR_SOUND_EFFECTS;
constexpr bool kShowDebugHud = DRAGON_RADAR_DEBUG_HUD;
constexpr bool kShowScanLine = DRAGON_RADAR_SCAN_LINE;
constexpr bool kSnapTargetsToGrid = DRAGON_RADAR_GRID_SNAP;
constexpr bool kSerialDiagnostics = DRAGON_RADAR_SERIAL_DIAG;
constexpr bool kRemoteBleEnabled = DRAGON_RADAR_REMOTE_BLE;
constexpr bool kAllowLegacyPairing = DRAGON_RADAR_ALLOW_LEGACY_PAIRING;
constexpr const char *kPairingHmacKey = DRAGON_RADAR_PAIRING_HMAC_KEY;
constexpr uint8_t kZoomLevelCount = 3;
constexpr float kZoomBaseScales[kZoomLevelCount] = {1.0f, 1.48f, 2.12f};
constexpr uint8_t kFocusNone = 255;
constexpr uint8_t kRemoteAppSlotCount = 6;
constexpr uint32_t kFocusFlashMs = 900;
constexpr int kFocusEdgeMarginPx = 18;
constexpr uint8_t kIdleSearchTickCount = 7;
constexpr uint8_t kTiltInertiaTickCount = 5;
constexpr int kPhosphorScanlineStep = 14;
constexpr int kPhosphorEdgeInsetLimit = 24;

constexpr uint16_t kBlack = RGB565_BLACK;
constexpr uint16_t kScreenBg = RGB565(3, 36, 17);
constexpr uint16_t kGrid = RGB565(20, 220, 84);
constexpr uint16_t kGridBright = RGB565(120, 255, 102);
constexpr uint16_t kGridDim = RGB565(0, 86, 44);
constexpr uint16_t kGridDeep = RGB565(0, 36, 25);
constexpr uint16_t kRippleHead = RGB565(56, 190, 74);
constexpr uint16_t kRippleMid = RGB565(18, 125, 56);
constexpr uint16_t kRippleDim = RGB565(0, 64, 34);
constexpr uint16_t kPhosphorLine = RGB565(4, 42, 18);
constexpr uint16_t kPhosphorEdge = RGB565(0, 20, 10);
constexpr uint16_t kScan = RGB565(128, 255, 112);
constexpr uint16_t kScanTrail1 = RGB565(98, 255, 120);
constexpr uint16_t kScanTrail2 = RGB565(69, 239, 100);
constexpr uint16_t kScanTrail3 = RGB565(43, 217, 84);
constexpr uint16_t kScanTrail4 = RGB565(23, 184, 73);
constexpr uint16_t kScanTrail5 = RGB565(12, 133, 57);
constexpr uint16_t kAmber = RGB565(255, 184, 36);
constexpr uint16_t kOrange = RGB565(255, 111, 20);
constexpr uint16_t kRed = RGB565(255, 44, 32);
constexpr uint16_t kBlue = RGB565(0, 102, 255);
constexpr uint16_t kWhite = RGB565_WHITE;
constexpr uint8_t kMajorGridEvery = 4;
constexpr uint8_t kBrightnessPresetCount = 5;
constexpr uint8_t kAudioPresetCount = 6;
constexpr size_t kBleCharacteristicMaxValueBytes = 512;
constexpr size_t kBleDeviceStatusLastEventMaxBytes = 64;
constexpr size_t kFirmwareStatusNotifySafeBytes = 180;
constexpr uint8_t kFramePresetCount = 6;
constexpr uint8_t kTouchInitAttempts = 3;
constexpr uint8_t kFramePrefsSchema = 3;
constexpr uint8_t kAudioPrefsSchema = 2;
constexpr size_t kRadarChordCacheSize = kRadarRadius * 2 + 1;
constexpr uint8_t kBrightnessPercents[kBrightnessPresetCount] = {35, 55, 80, 105, 125};
constexpr uint8_t kAudioRuntimePercents[kAudioPresetCount] = {0, 12, 32, 52, 72, 92};
constexpr uint8_t kCodecRuntimePercents[kAudioPresetCount] = {0, 65, 65, 65, 65, 65};
constexpr uint32_t kFrameRuntimeMs[kFramePresetCount] = {kFrameMs, 33, 50, 65, 80, 120};
constexpr uint32_t kLegacyFrameRuntimeMs[] = {80, 65, 50, 120};
constexpr const char *kRadarBleServiceUuid = "7d540100-f82d-4b2f-91c6-4f0f88aa5a11";
constexpr const char *kPairingChallengeUuid = "7d540101-f82d-4b2f-91c6-4f0f88aa5a11";
constexpr const char *kPairingResponseUuid = "7d540102-f82d-4b2f-91c6-4f0f88aa5a11";
constexpr const char *kWifiConfigUuid = "7d540103-f82d-4b2f-91c6-4f0f88aa5a11";
constexpr const char *kLocalLocationUuid = "7d540104-f82d-4b2f-91c6-4f0f88aa5a11";
constexpr const char *kDeviceStatusUuid = "7d540105-f82d-4b2f-91c6-4f0f88aa5a11";
constexpr const char *kServerConfigUuid = "7d540106-f82d-4b2f-91c6-4f0f88aa5a11";
constexpr const char *kFirmwareControlUuid = "7d540107-f82d-4b2f-91c6-4f0f88aa5a11";
constexpr const char *kFirmwareStatusUuid = "7d540108-f82d-4b2f-91c6-4f0f88aa5a11";
constexpr uint32_t kDeviceStatusNotifyMs = 2000;
constexpr uint32_t kFirmwareStatusNotifyMs = 500;
constexpr uint32_t kRelayReconnectMs = 5000;
constexpr uint32_t kRelayHeartbeatMs = 15000;
constexpr uint32_t kRelayStatusMs = 5000;
constexpr uint32_t kRelayTimeSyncTimeoutMs = 10000;
constexpr uint32_t kRelayTimeSyncRetryMs = 30000;
constexpr time_t kMinimumRelayTlsEpoch = 1704067200;  // 2024-01-01 UTC
constexpr uint32_t kBatteryPollMs = 10000;
constexpr int8_t kLowBatteryPercent = 20;
constexpr uint32_t kRemoteAppMarkerTtlMs = 30000;
constexpr uint32_t kLocationReceiveBlinkMs = 180;
// The physical iPhone currently publishes its own location about every 10s.
// Keep two publish intervals while still honoring Relay's explicit stale flag.
constexpr uint32_t kHeadingAlignmentFeedbackMs = 1600;
constexpr float kHeadingAlignmentMaxYawRateDps = 3.0f;
constexpr uint32_t kHeadingAlignmentMaxClockSkewS = 5;
constexpr uint32_t kRemoteSpeakingHoldMs = 1300;
constexpr uint8_t kDistanceLabelTextSize = 2;
constexpr uint32_t kVoiceSampleTickMs = 20;
constexpr uint32_t kVoiceFrameTickMs = 20;
constexpr uint16_t kVoiceFrameDurationMs = 20;
constexpr uint16_t kVoiceVadRmsThreshold = 650;
constexpr uint16_t kVoiceVadPeakThreshold = 1600;
constexpr uint16_t kVoiceFrameSamples = (kAudioSampleRate * kVoiceFrameDurationMs) / 1000;
constexpr size_t kVoicePcmBytes = kVoiceFrameSamples * sizeof(int16_t);
constexpr uint8_t kEs7210Address = 0x40;
constexpr float kEarthRadiusM = 6371000.0f;
constexpr float kRemoteRadarFullScaleM = 5000.0f;
constexpr uint32_t kSelfLocationPersistMinIntervalMs = 20000;
constexpr uint8_t kLocationFlagValid = 0x01;
constexpr uint8_t kLocationFlagHeadingValid = 0x04;
constexpr uint8_t kGyroBiasPrefsSchema = 2;
constexpr float kGyroBiasMaxAbsDps = 20.0f;
constexpr float kGyroBiasPersistDeltaDps = 0.015f;
constexpr float kGyroBiasPersistTempDeltaC = 2.0f;
constexpr float kGyroBiasTemperatureTrustDeltaC = 6.0f;
// The first estimate has already passed the strict stationary time, sample,
// acceleration and variance gates. Persist it immediately so picking the radar
// up after calibration cannot make every later boot repeat IMU WAIT.
constexpr uint32_t kGyroBiasFirstPersistDelayMs = 0;
constexpr uint32_t kGyroBiasPersistMinIntervalMs = 5UL * 60UL * 1000UL;
constexpr uint32_t kGyroStationaryWindowMs = 1800;
// AMOLED rendering occupies about 65 ms on the physical radar, so runtime IMU
// polling is roughly 15 Hz despite the sensor's 250 Hz ODR. Twenty-four samples
// preserve a useful variance estimate while allowing the 1.8 s time gate—not
// an accidental 4.5 s sample gate—to define startup verification latency.
constexpr uint16_t kGyroStationaryMinSamples = 24;
// Uncalibrated QMI8658 parts can have a larger constant zero-rate offset than
// the first physical radar. The second production board measures about
// 6.4 dps while motionless, so bootstrap must admit that stable offset and let
// the variance gate decide whether the board is actually being held still.
constexpr float kGyroStationaryBootstrapDps = 8.0f;
constexpr float kGyroStationaryWarmStartDps = 1.5f;
constexpr float kGyroStationaryCorrectedDps = 0.35f;
constexpr float kGyroStationaryStdDevDps = 0.18f;
constexpr float kGyroBiasBackgroundBlend = 0.12f;
// Board-to-board accelerometer scale error is also visible at rest (the second
// board reports about 1.073 g). Keep the gate tight enough to reject handling
// motion while allowing stationary sensors with normal production tolerance.
constexpr float kStationaryAccelToleranceG = 0.10f;
constexpr float kGravityUpdateToleranceG = 0.18f;
constexpr float kGravityReliableToleranceG = 0.12f;
constexpr float kGravityAccelCorrectionTimeConstantS = 1.5f;
constexpr uint32_t kGravityReliableHoldMs = 300;
constexpr uint32_t kImuSampleFreshMs = 250;
constexpr uint32_t kImuTemperaturePollMs = 30000;
constexpr uint32_t kImuTemperatureRetryMs = 500;
constexpr float kImuMaxIntegrationDtS = 0.20f;
constexpr uint32_t kImuMaxIntegrationGapMs = 200;
constexpr uint32_t kImuUnavailableAfterMs = 5000;
constexpr uint32_t kRelativeHeadingDisplayHoldMs = kImuUnavailableAfterMs;
constexpr float kRelativeYawRateDeadbandDps = 0.05f;

enum class RadarGattWriteRole : uint8_t {
  PairingResponse,
  WifiConfig,
  LocalLocation,
  ServerConfig,
  FirmwareControl,
};

enum class RadarUiMode : uint8_t {
  Main,
  SystemMenu,
  Info,
  PowerConfirm,
  FactoryResetConfirm,
  ScreenOff,
  Standby,
  ShutdownPending,
};

enum class SystemMenuItem : uint8_t {
  Sleep,
  Standby,
  Off,
  Info,
  Reset,
  Volume,
  Brightness,
  Direction,
  None = 255,
};

enum class SystemMenuFeedbackTarget : uint8_t {
  None,
  Previous,
  Next,
  Action,
};

enum class HeadingQuality : uint8_t {
  Unavailable,
  Calibrating,
  RelativeDegraded,
  RelativeStable,
};

enum class HeadingAlignmentFeedback : uint8_t {
  None,
  Success,
  ImuWait,
  HoldStill,
  Realign,
};

struct RemoteLocationFrame {
  bool valid = false;
  // This is an externally reported heading whose alignment with the physical radar
  // has not been established. It is retained for wire compatibility and diagnostics only.
  bool reportedHeadingValid = false;
  int32_t latE7 = 0;
  int32_t lonE7 = 0;
  uint16_t horizontalAccuracyCm = 0;
  uint16_t speedCms = 0;
  uint16_t courseDeg100 = 0;
  uint16_t reportedHeadingDeg100 = 0;
  uint32_t unixTime = 0;
  uint32_t receivedMs = 0;
  // Relay room_state can replay an old location while receivedMs is new. These
  // source-age fields keep calibration from treating replayed or persisted GPS
  // as a live observation from this session.
  bool sourceAgeKnown = false;
  bool sourceStale = true;
  uint32_t sourceAgeMs = 0;
};

struct HeadingAlignmentState {
  bool valid = false;
  float screenOffsetDeg = 0.0f;
  uint32_t calibratedAtMs = 0;
};

struct HeadingEstimatorState {
  HeadingQuality quality = HeadingQuality::Unavailable;
  bool biasValid = false;
  bool biasLoaded = false;
  bool biasDirty = false;
  bool forceBiasPersistAfterStrictVerification = false;
  bool gravityValid = false;
  bool stationary = false;
  bool relativeYawValid = false;
  bool sessionStationaryVerified = false;
  bool sessionTrustFromStoredBias = false;
  float biasX = 0.0f;
  float biasY = 0.0f;
  float biasZ = 0.0f;
  float savedBiasX = 0.0f;
  float savedBiasY = 0.0f;
  float savedBiasZ = 0.0f;
  float biasTemperatureC = NAN;
  float savedBiasTemperatureC = NAN;
  float currentTemperatureC = NAN;
  float gravityX = 0.0f;
  float gravityY = 0.0f;
  float gravityZ = 1.0f;
  float verticalRateDps = 0.0f;
  float accelMagnitudeG = 0.0f;
  float correctedGyroMagnitudeDps = 0.0f;
  float stationaryGyroLimitDps = 0.0f;
  float lastStationaryMaxStdDevDps = NAN;
  bool stationaryCandidate = false;
  uint32_t lastSampleMs = 0;
  uint32_t lastTemperatureReadMs = 0;
  uint32_t lastGravityReliableMs = 0;
  uint32_t stationaryWindowStartedMs = 0;
  uint16_t stationarySamples = 0;
  double gyroSumX = 0.0;
  double gyroSumY = 0.0;
  double gyroSumZ = 0.0;
  double gyroSumSqX = 0.0;
  double gyroSumSqY = 0.0;
  double gyroSumSqZ = 0.0;
  uint32_t biasDirtySinceMs = 0;
  uint32_t lastBiasPersistMs = 0;
};

enum class ImuGapCause : uint8_t {
  None,
  DataNotReady,
  MainLoopDelay,
  GyroscopeRead,
  AccelerometerRead,
  GyroscopeAndAccelerometerRead,
};

struct ImuDiagnosticsState {
  uint32_t gapStartedMs = 0;
  uint32_t currentGapMs = 0;
  uint32_t maxSampleGapMs = 0;
  uint32_t dataNotReadyCount = 0;
  uint32_t gyroscopeReadFailureCount = 0;
  uint32_t accelerometerReadFailureCount = 0;
  ImuGapCause lastGapCause = ImuGapCause::None;
  bool integrationAnchorReset = false;
  bool realignmentPrompted = false;
};

struct RemoteMarkerDrawState {
  bool visible = false;
  bool distanceKnown = false;
  bool fresh = false;
  bool speaking = false;
  uint8_t slot = 0;
  uint8_t pulse = 0;
  int x = 0;
  int y = 0;
  float distanceM = 0.0f;
  bool motionKnown = false;
  float courseDeg = 0.0f;
  float speedMps = 0.0f;
};

struct RemoteGeoFilterState {
  bool initialized = false;
  bool snapInitialized = false;
  int32_t sourceSelfLatE7 = 0;
  int32_t sourceSelfLonE7 = 0;
  int32_t sourceRemoteLatE7 = 0;
  int32_t sourceRemoteLonE7 = 0;
  float eastM = 0.0f;
  float northM = 0.0f;
  float targetEastM = 0.0f;
  float targetNorthM = 0.0f;
  float combinedAccuracyM = 12.0f;
  float sourceSpeedMps = 0.0f;
  int16_t snappedWorldX = 0;
  int16_t snappedWorldY = 0;
  uint32_t lastStepMs = 0;
};

struct FocusCandidate {
  uint8_t slot = kFocusNone;
  float angle = 0.0f;
  float range = 0.0f;
};

struct RemoteProvisioningState {
  bool serviceOnline = false;
  bool appConnected = false;
  bool paired = false;
  bool ownerSessionAuthorized = false;
  bool wifiConnectRequested = false;
  bool wifiConnectInFlight = false;
  bool serverConfigured = false;
  bool relaySocketConfigured = false;
  bool relayConnected = false;
  bool locationReceived = false;
  char deviceName[28] = {0};
  char challenge[48] = {0};
  String pairingResponse;
  String wifiSsid;
  String wifiPassword;
  String relayUrl;
  String httpApiUrl;
  String roomToken;
  String deviceToken;
  String lastWrite = "none";
  String relayState = "idle";
  uint32_t lastStatusNotifyMs = 0;
};

struct AudioTone {
  bool active = false;
  float phase = 0.0f;
  float frequency = 880.0f;
  int remainingSamples = 0;
  int totalSamples = 0;
  int16_t level = 3200;
};

struct VoiceCaptureState {
  bool captureOnline = false;
  bool muted = false;
  bool pttActive = false;
  bool vadActive = false;
  bool playbackActive = false;
  uint16_t rms = 0;
  uint16_t peak = 0;
  uint32_t sequence = 0;
  uint32_t receivedSequence = 0;
  uint32_t lastSampleMs = 0;
  uint32_t lastFrameMs = 0;
  uint32_t lastPlaybackMs = 0;
};

struct BatteryStatus {
  bool online = false;
  bool present = false;
  bool charging = false;
  bool discharging = false;
  bool low = false;
  int8_t percent = -1;
  uint16_t voltageMv = 0;
  uint32_t lastReadMs = 0;
};

struct BootAudioCue {
  float phase = 0.0f;
  float frequency = 0.0f;
  uint16_t durationMs = 0;
  int16_t level = 0;
};

// Original programmatic startup cue. It is synthesized at runtime and contains
// no sampled music, recording, or third-party audio asset.
constexpr BootAudioCue kBootAudioCues[] = {
    {0.08f, 523.25f, 46, 2600},
    {0.18f, 659.25f, 48, 2800},
    {0.34f, 783.99f, 52, 3000},
    {0.55f, 1046.5f, 58, 3200},
    {0.76f, 1318.5f, 70, 3500},
    {0.94f, 1975.5f, 92, 4100},
};
constexpr uint8_t kBootAudioCueCount = sizeof(kBootAudioCues) / sizeof(kBootAudioCues[0]);

Arduino_DataBus *bus = new Arduino_ESP32QSPI(
    LCD_CS, LCD_SCLK, LCD_SDIO0, LCD_SDIO1, LCD_SDIO2, LCD_SDIO3);

Arduino_CO5300 *panel = new Arduino_CO5300(
    bus, GFX_NOT_DEFINED, 0, LCD_WIDTH, LCD_HEIGHT, 6, 0, 0, 0);
Arduino_Canvas *gfx = new Arduino_Canvas(LCD_WIDTH, LCD_HEIGHT, panel);

TouchDrvCST92xx touch;
SensorQMI8658 qmi;
IMUdata acc;
IMUdata gyr;
HeadingEstimatorState headingEstimator;
ImuDiagnosticsState imuDiagnostics;
HeadingAlignmentState headingAlignment;
I2SClass i2s;

BLEServer *provisioningServer = nullptr;
BLECharacteristic *pairingChallengeCharacteristic = nullptr;
BLECharacteristic *deviceStatusCharacteristic = nullptr;
BLECharacteristic *firmwareStatusCharacteristic = nullptr;
constexpr uint16_t kInvalidBleConnectionHandle = UINT16_MAX;
uint16_t activeProvisioningConnectionHandle = kInvalidBleConnectionHandle;
uint16_t ownerSessionConnectionHandle = kInvalidBleConnectionHandle;
volatile uint32_t blePairingPasskey = 0;
volatile uint32_t blePairingPasskeyUntilMs = 0;
volatile uint32_t blePairingResultUntilMs = 0;
volatile uint32_t bleSecurityEventSerial = 0;
volatile int8_t bleSecurityEventResult = 0;
volatile bool bleLinkAuthenticated = false;
WebSocketsClient relaySocket;
String relayRootCaPem;
DragonRadarOta::Manager otaManager;
AudioTone tone;
VoiceCaptureState voiceCapture;
BatteryStatus batteryStatus;
RemoteProvisioningState provisioning;
RemoteLocationFrame selfLocationFrame;
RemoteLocationFrame remoteAppLocationFrame;
String remoteAppPeerName;
RemoteLocationFrame remoteAppLocationFrames[kRemoteAppSlotCount];
RemoteGeoFilterState remoteGeoFilterStates[kRemoteAppSlotCount];
String remoteAppPeerIds[kRemoteAppSlotCount];
String remoteAppPeerNames[kRemoteAppSlotCount];
uint32_t remoteAppBlinkStartedSlotsMs[kRemoteAppSlotCount] = {0};
uint32_t remoteAppSpeakingUntilMs[kRemoteAppSlotCount] = {0};
bool lastRelayAppLocationWasSelf = false;
bool remoteRoomSpeakerActive = false;
uint32_t remoteRoomSpeakerUntilMs = 0;
uint32_t remoteAppBlinkStartedMs = 0;
size_t bootAudioPcmOffset = 0;
bool bootAudioPlaying = false;
uint8_t nextBootAudioCue = 0;
bool audioTxConfigured = false;
bool audioRxConfigured = false;
bool audioTxFailureLogged = false;
bool audioRxFailureLogged = false;
bool speakerMutedForCapture = false;
uint32_t audioTxSampleRate = 0;

volatile bool touchIrq = false;
bool touchOnline = false;
bool imuOnline = false;
bool bleOnline = false;
bool displayOnline = false;
bool audioOnline = false;
bool voiceInputOnline = false;
bool powerButtonOnline = false;
bool scanning = true;
RadarUiMode radarUiMode = RadarUiMode::Main;
SystemMenuItem systemMenuFlashItem = SystemMenuItem::None;
SystemMenuItem systemMenuSelectedItem = SystemMenuItem::Sleep;
uint8_t zoomLevel = 0;
uint8_t focusedMemberSlot = kFocusNone;
uint8_t brightnessPreset = 2;
uint8_t audioPreset = 4;
uint8_t framePreset = 0;
ScreenDirection screenDirection = ScreenDirection::SixOClock;

uint32_t bootStartedMs = 0;
uint32_t mainFadeStartedMs = 0;
uint32_t lastFrameMs = 0;
uint32_t lastDrawMs = 0;
uint32_t frameStatsStartedMs = 0;
uint32_t drawStatsTotalMs = 0;
uint32_t drawStatsMaxMs = 0;
uint32_t lastDrawAvgMs = 0;
uint32_t lastDrawMaxMs = 0;
uint16_t frameStatsSamples = 0;
uint16_t drawStatsOverBudget = 0;
uint16_t lastDrawOverBudgetFrames = 0;
uint16_t lastDrawSamples = 0;
uint32_t lastTouchMs = 0;
uint32_t touchPressedAtMs = 0;
uint32_t lastButtonMs = 0;
uint32_t lastBleKickMs = 0;
uint32_t lastWifiAttemptMs = 0;
uint32_t lastWifiStatusLogMs = 0;
uint32_t lastRelayAttemptMs = 0;
uint32_t lastRelayHeartbeatMs = 0;
uint32_t lastRelayStatusMs = 0;
uint32_t relayTimeSyncStartedMs = 0;
uint32_t lastRelayTimeSyncAttemptMs = 0;
bool relayTimeSyncInFlight = false;
bool relayTimeSyncAttempted = false;
uint32_t relayServerUnixTime = 0;
uint32_t relayServerTimeReceivedMs = 0;
uint32_t lastFirmwareStatusNotifyMs = 0;
uint32_t lastSelfLocationPersistMs = 0;
uint32_t lastImuMicros = 0;
uint32_t lastScanChirpMs = 0;
uint32_t lastSignalLostBeepPhase = UINT32_MAX;
uint32_t radarStartedMs = 0;
uint32_t zoomFlashUntilMs = 0;
uint32_t focusFlashUntilMs = 0;
uint32_t headingAlignmentFeedbackUntilMs = 0;
HeadingAlignmentFeedback headingAlignmentFeedback = HeadingAlignmentFeedback::None;
bool headingCalibrationPromptVisible = true;
uint32_t brightnessFlashUntilMs = 0;
uint32_t audioFlashUntilMs = 0;
uint32_t frameFlashUntilMs = 0;
uint32_t touchEchoUntilMs = 0;
uint32_t bootButtonPressedAtMs = 0;
uint32_t pttRippleStartedMs = 0;
uint32_t pttRippleEndedMs = 0;
uint32_t bootTapPressedMs = 0;
uint32_t bootTapReleasedMs = 0;
uint32_t altButtonPressedAtMs = 0;
uint32_t altTapPressedMs = 0;
uint32_t altTapReleasedMs = 0;
uint32_t settingsFlashUntilMs = 0;
uint32_t systemMenuLastInteractionMs = 0;
uint32_t systemMenuControlFeedbackStartedMs = 0;
uint32_t systemMenuControlFeedbackUntilMs = 0;
uint32_t systemMenuPageTransitionStartedMs = 0;
uint32_t systemMenuPageTransitionUntilMs = 0;
uint32_t lastUserInputMs = 0;
uint32_t powerConfirmPressedAtMs = 0;
uint32_t displaySelfTestUntilMs = 0;
uint32_t lastDiagMs = 0;
int16_t radarChordHalfCache[kRadarChordCacheSize] = {0};
bool radarChordHalfCacheReady = false;
// IMU-only relative yaw. It is never treated as north-referenced heading.
float headingDeg = 0.0f;
// Captured once per rendered frame so the grid and every marker use one transform.
float renderedRadarRotationDeg = 0.0f;
float sweepDeg = 0.0f;
float tiltEnergy = 0.0f;
float tiltVectorX = 0.0f;
float tiltVectorY = 0.0f;
String serialCommandLine;
bool bootButtonWasPressed = false;
bool bootButtonLongHandled = false;
bool altButtonWasPressed = false;
bool altButtonLongHandled = false;
bool touchWasPressed = false;
bool touchLongHandled = false;
bool headingCalibrationGestureCancelled = false;
HeadingAlignmentFeedback headingCalibrationHoldWaitFeedback = HeadingAlignmentFeedback::None;
bool ignoreTouchUntilRelease = false;
bool edgeGestureActive = false;
bool edgeGestureConsumed = false;
int16_t touchStartX = 0;
int16_t touchStartY = 0;
int16_t touchLastX = 0;
int16_t touchLastY = 0;
int16_t touchEchoX = kCx;
int16_t touchEchoY = kCy;
int8_t systemMenuPageTransitionDirection = 0;
SystemMenuFeedbackTarget systemMenuFeedbackTarget = SystemMenuFeedbackTarget::None;
float gridGestureScale = 1.0f;
float edgeGestureLastAngle = 0.0f;
wl_status_t lastLoggedWifiStatus = WL_IDLE_STATUS;
String lastFirmwareStatusJson;

void startTone(float frequency, uint16_t durationMs, int16_t level, bool force);
void setupProvisioningBle();
void provisioningTick();
void cloudRelayTick();
void voiceCaptureTick();
void beginPushToTalk();
void endPushToTalk();
void cancelPushToTalkDueToBusy(const char *reason);
void loadProvisioningState();
void persistSelfLocationFrame(bool force);
void notifyDeviceStatus(bool force);
void notifyFirmwareStatus(bool force);
void firmwareOtaTick();
void sendRelayDeviceStatus();
String localRelayPeerId();
String localAppRelayPeerId();
void printHardwareSummary();
void printSerialCommandHelp();
void serialDiagnosticsTick();
int circleChordHalf(int offset, int radius = kRadarRadius);
void resetEdgeGesture();
void runBootAnimation();
void setupImu();
void readImu();
void invalidateRelativeHeading(bool clearSessionTrust = true);
bool imuTemperaturePlausible(float value);
bool gyroBiasTemperatureCompatible();
void setRadarUiMode(RadarUiMode mode);
void toggleSystemMenu();
void wakeRadarDisplay();
void systemUiTick();
void beginShutdownFallback();
void clearProvisioningAndRestart();
void drawCurrentModeFrame();
void handleBootShortPress();
void setupPowerButton();
void pollPowerButton();

float degToRad(float deg) {
  return deg * kPi / 180.0f;
}

float radToDeg(float rad) {
  return rad * 180.0f / kPi;
}

float wrap360(float v) {
  while (v < 0.0f) {
    v += 360.0f;
  }
  while (v >= 360.0f) {
    v -= 360.0f;
  }
  return v;
}

float shortestAngleDelta(float fromDeg, float toDeg) {
  float delta = wrap360(toDeg - fromDeg);
  if (delta > 180.0f) {
    delta -= 360.0f;
  }
  return delta;
}

float lerpAngleDeg(float fromDeg, float toDeg, float t) {
  return wrap360(fromDeg + shortestAngleDelta(fromDeg, toDeg) * t);
}

float clampf(float v, float lo, float hi) {
  if (v < lo) {
    return lo;
  }
  if (v > hi) {
    return hi;
  }
  return v;
}

float latE7ToDeg(int32_t value) {
  return static_cast<float>(value) / 10000000.0f;
}

float geoDistanceMeters(const RemoteLocationFrame &from, const RemoteLocationFrame &to) {
  const float fromLatDeg = latE7ToDeg(from.latE7);
  const float fromLonDeg = latE7ToDeg(from.lonE7);
  const float toLatDeg = latE7ToDeg(to.latE7);
  const float toLonDeg = latE7ToDeg(to.lonE7);
  const float lat1 = degToRad(fromLatDeg);
  const float lat2 = degToRad(toLatDeg);
  const float dLat = lat2 - lat1;
  const float dLon = degToRad(toLonDeg - fromLonDeg);
  const float sinLat = sinf(dLat * 0.5f);
  const float sinLon = sinf(dLon * 0.5f);
  const float a = sinLat * sinLat + cosf(lat1) * cosf(lat2) * sinLon * sinLon;
  const float c = 2.0f * atan2f(sqrtf(a), sqrtf(fmaxf(0.0f, 1.0f - a)));
  return kEarthRadiusM * c;
}

float geoBearingDeg(const RemoteLocationFrame &from, const RemoteLocationFrame &to) {
  const float fromLonDeg = latE7ToDeg(from.lonE7);
  const float toLonDeg = latE7ToDeg(to.lonE7);
  const float lat1 = degToRad(latE7ToDeg(from.latE7));
  const float lat2 = degToRad(latE7ToDeg(to.latE7));
  const float dLon = degToRad(toLonDeg - fromLonDeg);
  const float y = sinf(dLon) * cosf(lat2);
  const float x = cosf(lat1) * sinf(lat2) - sinf(lat1) * cosf(lat2) * cosf(dLon);
  return wrap360(radToDeg(atan2f(y, x)));
}

float locationAccuracyMeters(const RemoteLocationFrame &frame) {
  if (frame.horizontalAccuracyCm == 0) {
    return 12.0f;
  }
  return clampf(static_cast<float>(frame.horizontalAccuracyCm) / 100.0f, 1.0f, 100.0f);
}

bool filteredRemoteGeometry(uint8_t slot, const RemoteLocationFrame &self,
                            const RemoteLocationFrame &remote, uint32_t nowMs,
                            float &bearingDeg, float &distanceM) {
  if (slot >= kRemoteAppSlotCount) {
    return false;
  }

  RemoteGeoFilterState &filter = remoteGeoFilterStates[slot];
  const bool sourceChanged =
      !filter.initialized ||
      filter.sourceSelfLatE7 != self.latE7 ||
      filter.sourceSelfLonE7 != self.lonE7 ||
      filter.sourceRemoteLatE7 != remote.latE7 ||
      filter.sourceRemoteLonE7 != remote.lonE7;
  if (sourceChanged) {
    const float rawDistanceM = geoDistanceMeters(self, remote);
    const float rawBearingRad = degToRad(geoBearingDeg(self, remote));
    const float rawEastM = sinf(rawBearingRad) * rawDistanceM;
    const float rawNorthM = cosf(rawBearingRad) * rawDistanceM;
    if (!isfinite(rawDistanceM) || !isfinite(rawEastM) || !isfinite(rawNorthM)) {
      return false;
    }

    filter.sourceSelfLatE7 = self.latE7;
    filter.sourceSelfLonE7 = self.lonE7;
    filter.sourceRemoteLatE7 = remote.latE7;
    filter.sourceRemoteLonE7 = remote.lonE7;
    filter.targetEastM = rawEastM;
    filter.targetNorthM = rawNorthM;
    const float selfAccuracyM = locationAccuracyMeters(self);
    const float remoteAccuracyM = locationAccuracyMeters(remote);
    filter.combinedAccuracyM = sqrtf(
        selfAccuracyM * selfAccuracyM + remoteAccuracyM * remoteAccuracyM);
    filter.sourceSpeedMps =
        (static_cast<float>(self.speedCms) + static_cast<float>(remote.speedCms)) / 100.0f;

    if (!filter.initialized) {
      filter.eastM = rawEastM;
      filter.northM = rawNorthM;
      filter.lastStepMs = nowMs;
      filter.initialized = true;
    }
  }

  if (!filter.initialized) {
    return false;
  }

  const uint32_t elapsedMs = filter.lastStepMs == 0 ? 0 : nowMs - filter.lastStepMs;
  filter.lastStepMs = nowMs;
  const float dtS = clampf(static_cast<float>(elapsedMs) / 1000.0f, 0.0f, 0.25f);
  if (dtS > 0.0f) {
    float timeConstantS = clampf(1.0f + filter.combinedAccuracyM * 0.16f, 1.5f, 5.0f);
    if (filter.sourceSpeedMps > 0.4f) {
      timeConstantS = clampf(
          timeConstantS / (1.0f + filter.sourceSpeedMps * 0.45f), 0.65f, timeConstantS);
    }
    const float alpha = 1.0f - expf(-dtS / timeConstantS);
    const float deltaEastM = filter.targetEastM - filter.eastM;
    const float deltaNorthM = filter.targetNorthM - filter.northM;
    const float residualM = sqrtf(deltaEastM * deltaEastM + deltaNorthM * deltaNorthM);
    if (residualM > 0.001f) {
      const float maxSlewMps = fmaxf(4.0f, 2.0f + filter.sourceSpeedMps * 2.5f);
      const float requestedStepM = residualM * alpha;
      const float stepScale = requestedStepM > maxSlewMps * dtS
                                  ? (maxSlewMps * dtS) / requestedStepM
                                  : 1.0f;
      filter.eastM += deltaEastM * alpha * stepScale;
      filter.northM += deltaNorthM * alpha * stepScale;
    }
  }

  distanceM = sqrtf(filter.eastM * filter.eastM + filter.northM * filter.northM);
  bearingDeg = wrap360(radToDeg(atan2f(filter.eastM, filter.northM)));
  return isfinite(distanceM) && isfinite(bearingDeg);
}

bool relativeHeadingReadyForDisplay(uint32_t nowMs) {
  return
      imuOnline &&
      headingEstimator.biasValid &&
      headingEstimator.relativeYawValid &&
      headingEstimator.sessionStationaryVerified &&
      gyroBiasTemperatureCompatible() &&
      headingEstimator.lastSampleMs > 0 &&
      nowMs - headingEstimator.lastSampleMs <= kRelativeHeadingDisplayHoldMs;
}

void setHeadingAlignmentFeedback(HeadingAlignmentFeedback feedback, uint32_t nowMs) {
  headingAlignmentFeedback = feedback;
  headingAlignmentFeedbackUntilMs =
      feedback == HeadingAlignmentFeedback::None ? 0 : nowMs + kHeadingAlignmentFeedbackMs;
}

void invalidateHeadingAlignment(HeadingAlignmentFeedback feedback = HeadingAlignmentFeedback::None) {
  const bool wasValid = headingAlignment.valid;
  headingAlignment = HeadingAlignmentState{};
  if (feedback != HeadingAlignmentFeedback::None) {
    setHeadingAlignmentFeedback(feedback, millis());
  }
  if (wasValid && kSerialDiagnostics) {
    Serial.println("DIAG heading_align result=invalidated reason=heading_reset");
  }
}

const char *imuGapCauseText(ImuGapCause cause) {
  switch (cause) {
    case ImuGapCause::DataNotReady: return "data_not_ready";
    case ImuGapCause::MainLoopDelay: return "main_loop_delay";
    case ImuGapCause::GyroscopeRead: return "gyro_read";
    case ImuGapCause::AccelerometerRead: return "accel_read";
    case ImuGapCause::GyroscopeAndAccelerometerRead: return "gyro_accel_read";
    default: return "none";
  }
}

uint32_t noteImuGap(uint32_t nowMs, ImuGapCause cause) {
  if (imuDiagnostics.gapStartedMs == 0) {
    imuDiagnostics.gapStartedMs = nowMs == 0 ? 1 : nowMs;
  }
  const uint32_t gapMs = headingEstimator.lastSampleMs > 0
                             ? nowMs - headingEstimator.lastSampleMs
                             : nowMs - imuDiagnostics.gapStartedMs;
  imuDiagnostics.currentGapMs = gapMs;
  imuDiagnostics.maxSampleGapMs = max(imuDiagnostics.maxSampleGapMs, gapMs);
  imuDiagnostics.lastGapCause = cause;

  if (DragonRadarHeadingAlignment::imuGapRequiresIntegrationReset(
          gapMs, kImuMaxIntegrationGapMs)) {
    lastImuMicros = 0;
    imuDiagnostics.integrationAnchorReset = true;
  }

  if (DragonRadarHeadingAlignment::imuGapRequiresRealignmentPrompt(
          gapMs, kImuUnavailableAfterMs)) {
    headingEstimator.quality = HeadingQuality::Unavailable;
    headingEstimator.relativeYawValid = false;
    if (!imuDiagnostics.realignmentPrompted) {
      imuDiagnostics.realignmentPrompted = true;
      if (headingAlignment.valid) {
        // Retain screenOffsetDeg: the prompt asks for a fresh manual capture,
        // but recovery never destroys the user's previous calibration.
        headingCalibrationPromptVisible = true;
        setHeadingAlignmentFeedback(HeadingAlignmentFeedback::Realign, nowMs);
      }
      if (kSerialDiagnostics) {
        Serial.print("DIAG imu result=unavailable gapMs=");
        Serial.print(gapMs);
        Serial.print(" cause=");
        Serial.print(imuGapCauseText(cause));
        Serial.print(" alignmentRetained=");
        Serial.println(headingAlignment.valid ? "yes" : "no");
      }
    }
  }
  return gapMs;
}

void noteHealthyImuSample(uint32_t nowMs) {
  const uint32_t sampleGapMs = headingEstimator.lastSampleMs > 0
                                   ? nowMs - headingEstimator.lastSampleMs
                                   : imuDiagnostics.currentGapMs;
  imuDiagnostics.maxSampleGapMs = max(imuDiagnostics.maxSampleGapMs, sampleGapMs);
  imuDiagnostics.gapStartedMs = 0;
  imuDiagnostics.currentGapMs = 0;
  imuDiagnostics.integrationAnchorReset = false;
  imuDiagnostics.realignmentPrompted = false;
  headingEstimator.lastSampleMs = nowMs;
}

float radarDisplayRotationDeg() {
  if (!headingAlignment.valid || !relativeHeadingReadyForDisplay(millis())) {
    return 0.0f;
  }
  return DragonRadarHeadingAlignment::wrap360(
      headingDeg + headingAlignment.screenOffsetDeg);
}

float remoteDistanceToRange(float meters) {
  if (meters <= 0.0f) {
    return 0.12f;
  }
  const float normalized = log1pf(meters / 25.0f) / log1pf(kRemoteRadarFullScaleM / 25.0f);
  return clampf(0.14f + normalized * 0.78f, 0.14f, 0.92f);
}

float smoothStep(float edge0, float edge1, float x) {
  const float t = clampf((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
  return t * t * (3.0f - 2.0f * t);
}

float lerpf(float a, float b, float t) {
  return a + (b - a) * t;
}

float clampGridGestureScale(float scale) {
  return clampf(scale, 0.55f, 1.9f);
}

void polarToPoint(float angleDeg, float radius, int &x, int &y) {
  const float a = degToRad(angleDeg - 90.0f);
  x = kCx + static_cast<int>(cosf(a) * radius);
  y = kCy + static_cast<int>(sinf(a) * radius);
}

int currentGridPitch() {
  return max(10, kFixedRadarGridPitch);
}

void initRadarChordHalfCache() {
  for (int offset = -kRadarRadius; offset <= kRadarRadius; ++offset) {
    radarChordHalfCache[offset + kRadarRadius] =
        static_cast<int16_t>(sqrtf(kRadarRadius * kRadarRadius - offset * offset));
  }
  radarChordHalfCacheReady = true;
}

void armTouchEcho(int16_t x, int16_t y, uint32_t now) {
  const int edge = kRadarRadius - 14;
  int px = constrain(x, kCx - edge, kCx + edge);
  int py = constrain(y, kCy - edge, kCy + edge);
  const int dx = px - kCx;
  const int dy = py - kCy;
  const int d2 = dx * dx + dy * dy;
  if (d2 > edge * edge) {
    const float scale = static_cast<float>(edge) / sqrtf(static_cast<float>(d2));
    px = kCx + static_cast<int>(dx * scale);
    py = kCy + static_cast<int>(dy * scale);
  }
  touchEchoX = px;
  touchEchoY = py;
  touchEchoUntilMs = now + kTouchEchoMs;
}

float currentMapScale() {
  const uint8_t idx = zoomLevel < kZoomLevelCount ? zoomLevel : kZoomLevelCount - 1;
  return kZoomBaseScales[idx] * gridGestureScale;
}

int16_t scaledAudioLevel(int16_t level) {
  const int32_t scaled = (static_cast<int32_t>(level) * kAudioGainPercent *
                          kAudioRuntimePercents[audioPreset]) /
                         10000;
  return static_cast<int16_t>(constrain(scaled, 0L, 12000L));
}

int16_t scaledAlertAudioLevel(int16_t level) {
  (void)level;
  constexpr int32_t kAlertMaxLevel = 26000;
  constexpr int32_t kAlertMaxRuntimePercent = kAudioRuntimePercents[kAudioPresetCount - 1];
  if (audioPreset == 0) {
    return 0;
  }
  const int32_t scaled =
      (kAlertMaxLevel * kAudioRuntimePercents[audioPreset]) / kAlertMaxRuntimePercent;
  return static_cast<int16_t>(constrain(scaled, 9000L, kAlertMaxLevel));
}

int16_t scaledBootAudioLevel(int16_t level) {
  const int32_t scaled =
      (static_cast<int32_t>(level) * kAudioGainPercent *
       kAudioRuntimePercents[kAudioPresetCount - 1]) /
      10000;
  return static_cast<int16_t>(constrain(scaled, 0L, 32000L));
}

uint8_t currentBrightness() {
  if (kDisplayBrightness == 0) {
    return 0;
  }
  const int scaled = (static_cast<int>(kDisplayBrightness) *
                      kBrightnessPercents[brightnessPreset]) /
                     100;
  return static_cast<uint8_t>(constrain(scaled, 12, 255));
}

uint32_t currentFrameMs() {
  return kFrameRuntimeMs[framePreset];
}

void recordFramePerformance(uint32_t drawMs, uint32_t frameBudgetMs, uint32_t now) {
  if (frameStatsStartedMs == 0) {
    frameStatsStartedMs = now;
  }

  ++frameStatsSamples;
  drawStatsTotalMs += drawMs;
  if (drawMs > drawStatsMaxMs) {
    drawStatsMaxMs = drawMs;
  }
  if (drawMs > frameBudgetMs) {
    ++drawStatsOverBudget;
  }

  if (now - frameStatsStartedMs < 1000 || frameStatsSamples == 0) {
    return;
  }

  lastDrawAvgMs = (drawStatsTotalMs + frameStatsSamples / 2) / frameStatsSamples;
  lastDrawMaxMs = drawStatsMaxMs;
  lastDrawOverBudgetFrames = drawStatsOverBudget;
  lastDrawSamples = frameStatsSamples;

  frameStatsStartedMs = now;
  frameStatsSamples = 0;
  drawStatsTotalMs = 0;
  drawStatsMaxMs = 0;
  drawStatsOverBudget = 0;
}

uint8_t framePresetForMs(uint32_t frameMs) {
  uint8_t best = 0;
  uint32_t bestDelta = UINT32_MAX;
  for (uint8_t i = 0; i < kFramePresetCount; ++i) {
    const uint32_t presetMs = kFrameRuntimeMs[i];
    const uint32_t delta = presetMs > frameMs ? presetMs - frameMs : frameMs - presetMs;
    if (delta < bestDelta) {
      bestDelta = delta;
      best = i;
    }
  }
  return best;
}

void loadRuntimeSettings() {
  Preferences prefs;
  if (!prefs.begin("dragonRadar", true)) {
    return;
  }
  const bool hasFrame = prefs.isKey("frame");
  const bool hasFrameMs = prefs.isKey("frameMs");
  const bool hasAudio = prefs.isKey("audio");
  const uint8_t frameSchema = prefs.getUChar("frameSchema", 0);
  const uint8_t audioSchema = prefs.getUChar("audioSchema", 0);
  brightnessPreset = prefs.getUChar("bright", brightnessPreset);
  audioPreset = prefs.getUChar("audio", audioPreset);
  screenDirection = DragonRadarDisplayOrientation::sanitize(
      prefs.getUChar(
          "screenDir",
          DragonRadarDisplayOrientation::persistedValue(screenDirection)));
  if (hasFrameMs) {
    framePreset = framePresetForMs(prefs.getUInt("frameMs", kFrameMs));
  } else if (hasFrame) {
    const uint8_t savedFrame = prefs.getUChar("frame", framePreset);
    if (frameSchema >= kFramePrefsSchema) {
      framePreset = savedFrame;
    } else if (savedFrame < sizeof(kLegacyFrameRuntimeMs) / sizeof(kLegacyFrameRuntimeMs[0])) {
      framePreset = framePresetForMs(kLegacyFrameRuntimeMs[savedFrame]);
    } else {
      framePreset = 0;
    }
  }
  prefs.end();

  if (brightnessPreset >= kBrightnessPresetCount) {
    brightnessPreset = 2;
  }
  if (audioPreset >= kAudioPresetCount) {
    audioPreset = 4;
  } else if (hasAudio && audioSchema < kAudioPrefsSchema && audioPreset < kAudioPresetCount - 1) {
    ++audioPreset;
  }
  if (framePreset >= kFramePresetCount) {
    framePreset = 0;
  }
}

void saveRuntimeSettings() {
  Preferences prefs;
  if (!prefs.begin("dragonRadar", false)) {
    return;
  }
  prefs.putUChar("bright", brightnessPreset);
  prefs.putUChar("audio", audioPreset);
  prefs.putUChar("audioSchema", kAudioPrefsSchema);
  prefs.putUChar("frame", framePreset);
  prefs.putUInt("frameMs", currentFrameMs());
  prefs.putUChar("frameSchema", kFramePrefsSchema);
  prefs.putUChar(
      "screenDir",
      DragonRadarDisplayOrientation::persistedValue(screenDirection));
  prefs.end();
}

void applyScreenDirection() {
  gfx->setRotation(DragonRadarDisplayOrientation::inverted(screenDirection) ? 2 : 0);
}

void toggleScreenDirection() {
  screenDirection =
      screenDirection == ScreenDirection::SixOClock
          ? ScreenDirection::TwelveOClock
          : ScreenDirection::SixOClock;
  applyScreenDirection();
  saveRuntimeSettings();
  settingsFlashUntilMs = millis() + 700;
  if (kSerialDiagnostics) {
    Serial.print("DIAG screen_direction value=");
    Serial.println(DragonRadarDisplayOrientation::persistedValue(screenDirection));
  }
}

void setFrameTurbo() {
  framePreset = 0;
  frameFlashUntilMs = millis() + 700;
  saveRuntimeSettings();
  startTone(720.0f, 48, 2600, true);
}

void cycleMapScale() {
  zoomLevel = (zoomLevel + 1) % kZoomLevelCount;
  zoomFlashUntilMs = millis() + 700;
  startTone(820.0f + zoomLevel * 220.0f, 64, 2800, true);
}

bool remoteAppDisplayCandidate(uint8_t remoteSlot, uint32_t now, float &angle, float &range,
                               float &distanceM, bool &distanceKnown) {
  if (remoteSlot >= kRemoteAppSlotCount) {
    return false;
  }
  const RemoteLocationFrame &frame = remoteAppLocationFrames[remoteSlot];
  if (!frame.valid ||
      frame.receivedMs == 0 ||
      now - frame.receivedMs > kRemoteAppMarkerTtlMs) {
    return false;
  }

  distanceM = 0.0f;
  distanceKnown = false;
  if (selfLocationFrame.valid && selfLocationFrame.receivedMs > 0) {
    float geographicBearingDeg = 0.0f;
    distanceKnown = filteredRemoteGeometry(
        remoteSlot, selfLocationFrame, frame, now, geographicBearingDeg, distanceM);
    if (!distanceKnown) {
      return false;
    }
    // Keep this in geographic/world space. The marker is snapped to the same
    // north-up grid first, then both marker and grid are rotated together.
    angle = geographicBearingDeg;
    range = remoteDistanceToRange(distanceM);
  } else {
    const float t = now / 1000.0f;
    angle = wrap360(42.0f + remoteSlot * 38.0f + sinf(t * 0.52f + remoteSlot) * 10.0f);
    range = 0.35f + remoteSlot * 0.13f + 0.04f * sinf(t * 0.8f + remoteSlot);
    range = clampf(range, 0.22f, 0.88f);
  }
  return true;
}

void printHeadingAlignmentAttempt(const char *result, const char *reason,
                                  float offsetDeg,
                                  float screenAngleDeg) {
  if (!kSerialDiagnostics) {
    return;
  }
  Serial.print("DIAG heading_align result=");
  Serial.print(result);
  Serial.print(" reason=");
  Serial.print(reason);
  Serial.print(" gyroYaw=");
  Serial.print(headingDeg, 1);
  Serial.print(" offset=");
  Serial.print(offsetDeg, 1);
  Serial.print(" screen=");
  Serial.println(screenAngleDeg, 1);
}

bool rejectHeadingAlignment(HeadingAlignmentFeedback feedback, const char *reason) {
  setHeadingAlignmentFeedback(feedback, millis());
  printHeadingAlignmentAttempt("reject", reason,
                               headingAlignment.valid ? headingAlignment.screenOffsetDeg : NAN,
                               NAN);
  return false;
}

bool headingCalibrationImuReady(uint32_t now) {
  return relativeHeadingReadyForDisplay(now) &&
         headingEstimator.quality == HeadingQuality::RelativeStable &&
         headingEstimator.lastSampleMs > 0 &&
         now - headingEstimator.lastSampleMs <= kImuSampleFreshMs;
}

HeadingAlignmentFeedback headingCalibrationNotReadyFeedback(uint32_t now) {
  const bool freshImuSample = imuOnline && headingEstimator.lastSampleMs > 0 &&
                              now - headingEstimator.lastSampleMs <= kImuSampleFreshMs;
  // A live IMU that is still learning or revalidating its bias needs the radar
  // held still, not an opaque IMU WAIT. Reserve IMU WAIT for an offline or stale
  // sensor path that user posture cannot immediately fix.
  return freshImuSample ? HeadingAlignmentFeedback::HoldStill
                        : HeadingAlignmentFeedback::ImuWait;
}

const char *headingCalibrationNotReadyReason(uint32_t now) {
  return headingCalibrationNotReadyFeedback(now) == HeadingAlignmentFeedback::HoldStill
             ? "stationary_bias_pending"
             : "imu_not_ready";
}

bool attemptNorthHeadingAlignment() {
  const uint32_t now = millis();
  if (!headingCalibrationImuReady(now)) {
    return rejectHeadingAlignment(headingCalibrationNotReadyFeedback(now),
                                  headingCalibrationNotReadyReason(now));
  }
  if (fabsf(headingEstimator.verticalRateDps) > kHeadingAlignmentMaxYawRateDps) {
    return rejectHeadingAlignment(HeadingAlignmentFeedback::HoldStill,
                                  "motion");
  }

  const float offsetDeg = DragonRadarHeadingAlignment::northCalibrationOffsetDeg(
      headingDeg);
  const float screenAngleDeg = DragonRadarHeadingAlignment::screenAngleDeg(
      0.0f, headingDeg, offsetDeg);
  headingAlignment.valid = true;
  headingAlignment.screenOffsetDeg = offsetDeg;
  headingAlignment.calibratedAtMs = now;
  headingCalibrationPromptVisible = false;
  setHeadingAlignmentFeedback(HeadingAlignmentFeedback::Success, now);
  startTone(1240.0f, 70, 3300, true);
  printHeadingAlignmentAttempt("success", "north_screen_hold",
                               offsetDeg, screenAngleDeg);
  return true;
}

bool focusSlotAvailable(uint8_t slot, uint32_t now, float &angle, float &range) {
  float distanceM = 0.0f;
  bool distanceKnown = false;
  return remoteAppDisplayCandidate(slot, now, angle, range, distanceM, distanceKnown);
}

void applyFocusMapScale(float range, uint32_t now) {
  const float safeRange = max(0.05f, range);
  const float allowedScale =
      static_cast<float>(kTargetMaxRadius - kFocusEdgeMarginPx) /
      (safeRange * static_cast<float>(kTargetMaxRadius));

  uint8_t bestZoom = 0;
  float bestGesture = 1.0f;
  float bestTotalScale = 0.0f;
  for (uint8_t i = 0; i < kZoomLevelCount; ++i) {
    const float base = kZoomBaseScales[i];
    const float minTotal = base * 0.55f;
    const float maxTotal = base * 1.9f;
    const float total = min(allowedScale, maxTotal);
    if (total >= minTotal && total >= bestTotalScale) {
      bestZoom = i;
      bestGesture = clampGridGestureScale(total / base);
      bestTotalScale = base * bestGesture;
    }
  }

  if (bestTotalScale <= 0.0f) {
    bestZoom = 0;
    bestGesture = clampGridGestureScale(allowedScale / kZoomBaseScales[0]);
  }

  zoomLevel = bestZoom;
  gridGestureScale = bestGesture;
  zoomFlashUntilMs = now + 700;
  focusFlashUntilMs = now + kFocusFlashMs;
  startTone(900.0f + bestZoom * 180.0f, 58, 2800, true);
}

bool focusCandidateLess(const FocusCandidate &a, const FocusCandidate &b) {
  const float delta = a.range - b.range;
  if (fabsf(delta) > 0.001f) {
    return delta < 0.0f;
  }
  return a.slot < b.slot;
}

uint8_t collectFocusCandidates(uint32_t now, FocusCandidate *candidates, uint8_t maxCandidates) {
  uint8_t count = 0;
  for (uint8_t slot = 0; slot < kRemoteAppSlotCount && count < maxCandidates; ++slot) {
    FocusCandidate candidate;
    candidate.slot = slot;
    if (!focusSlotAvailable(slot, now, candidate.angle, candidate.range)) {
      continue;
    }

    uint8_t insertAt = count;
    while (insertAt > 0 && focusCandidateLess(candidate, candidates[insertAt - 1])) {
      candidates[insertAt] = candidates[insertAt - 1];
      --insertAt;
    }
    candidates[insertAt] = candidate;
    ++count;
  }
  return count;
}

bool focusNextMember() {
  const uint32_t now = millis();
  FocusCandidate candidates[kRemoteAppSlotCount];
  const uint8_t count = collectFocusCandidates(now, candidates, kRemoteAppSlotCount);
  if (count == 0) {
    focusedMemberSlot = kFocusNone;
    return false;
  }

  uint8_t currentIndex = count;
  for (uint8_t i = 0; i < count; ++i) {
    if (candidates[i].slot == focusedMemberSlot) {
      currentIndex = i;
      break;
    }
  }

  const uint8_t nextIndex = currentIndex < count ? static_cast<uint8_t>((currentIndex + 1) % count) : 0;
  focusedMemberSlot = candidates[nextIndex].slot;
  applyFocusMapScale(candidates[nextIndex].range, now);
  return true;
}

void cycleBrightness() {
  brightnessPreset = (brightnessPreset + 1) % kBrightnessPresetCount;
  saveRuntimeSettings();
  brightnessFlashUntilMs = millis() + 700;
  if (gfx) {
    panel->setBrightness(currentBrightness());
  }
}

void cycleAudioGain() {
  audioPreset = (audioPreset + 1) % kAudioPresetCount;
  saveRuntimeSettings();
  applyCodecOutputVolume();
  audioFlashUntilMs = millis() + 700;
}

bool radarUiDisplayActive() {
  return radarUiMode != RadarUiMode::ScreenOff &&
         radarUiMode != RadarUiMode::Standby &&
         radarUiMode != RadarUiMode::ShutdownPending;
}

bool radarUiOverlayActive() {
  return radarUiMode == RadarUiMode::SystemMenu ||
         radarUiMode == RadarUiMode::Info ||
         radarUiMode == RadarUiMode::PowerConfirm ||
         radarUiMode == RadarUiMode::FactoryResetConfirm;
}

bool northCalibrationInteractive(uint32_t now) {
  return radarUiMode == RadarUiMode::Main &&
         !otaManager.shouldShowOverlay() &&
         !voiceCapture.pttActive &&
         now >= displaySelfTestUntilMs;
}

const char *radarUiModeText(RadarUiMode mode) {
  switch (mode) {
    case RadarUiMode::Main: return "main";
    case RadarUiMode::SystemMenu: return "system_menu";
    case RadarUiMode::Info: return "info";
    case RadarUiMode::PowerConfirm: return "power_confirm";
    case RadarUiMode::FactoryResetConfirm: return "factory_reset_confirm";
    case RadarUiMode::ScreenOff: return "screen_off";
    case RadarUiMode::Standby: return "standby";
    case RadarUiMode::ShutdownPending: return "shutdown_pending";
    default: return "unknown";
  }
}

const char *systemMenuItemText(SystemMenuItem item) {
  switch (item) {
    case SystemMenuItem::Sleep: return "sleep";
    case SystemMenuItem::Standby: return "standby";
    case SystemMenuItem::Off: return "off";
    case SystemMenuItem::Info: return "info";
    case SystemMenuItem::Reset: return "reset";
    case SystemMenuItem::Volume: return "volume";
    case SystemMenuItem::Brightness: return "brightness";
    case SystemMenuItem::Direction: return "direction";
    default: return "none";
  }
}

void resetUiInputState() {
  resetEdgeGesture();
  touchWasPressed = false;
  touchPressedAtMs = 0;
  touchLongHandled = false;
  headingCalibrationGestureCancelled = false;
  headingCalibrationHoldWaitFeedback = HeadingAlignmentFeedback::None;
  powerConfirmPressedAtMs = 0;
  edgeGestureConsumed = false;
}

void setRadarUiMode(RadarUiMode mode) {
  const RadarUiMode previousMode = radarUiMode;
  radarUiMode = mode;
  lastUserInputMs = millis();
  systemMenuLastInteractionMs = lastUserInputMs;
  systemMenuFlashItem = SystemMenuItem::None;
  if (mode == RadarUiMode::SystemMenu && systemMenuSelectedItem == SystemMenuItem::None) {
    systemMenuSelectedItem = SystemMenuItem::Sleep;
  }
  settingsFlashUntilMs = 0;
  resetUiInputState();

  if (!radarUiDisplayActive()) {
    panel->setBrightness(0);
    notifyDeviceStatus(true);
    if (provisioning.relayConnected) {
      sendRelayDeviceStatus();
    }
    if (kSerialDiagnostics) {
      Serial.print("DIAG ui transition from=");
      Serial.print(radarUiModeText(previousMode));
      Serial.print(" to=");
      Serial.println(radarUiModeText(radarUiMode));
    }
    return;
  }

  panel->setBrightness(currentBrightness());
  mainFadeStartedMs = 0;
  drawCurrentModeFrame();
  notifyDeviceStatus(true);
  if (provisioning.relayConnected) {
    sendRelayDeviceStatus();
  }
  if (kSerialDiagnostics) {
    Serial.print("DIAG ui transition from=");
    Serial.print(radarUiModeText(previousMode));
    Serial.print(" to=");
    Serial.println(radarUiModeText(radarUiMode));
  }
}

void wakeRadarDisplay() {
  const bool resumingFromStandby = radarUiMode == RadarUiMode::Standby;
  if (resumingFromStandby) {
    // Standby stops sampling, so yaw/alignment must restart, but a previously
    // trusted gyro bias remains valid for this powered session.
    invalidateRelativeHeading(false);
  }
  setRadarUiMode(RadarUiMode::Main);
  panel->setBrightness(currentBrightness());
}

void toggleSystemMenu() {
  if (voiceCapture.pttActive) {
    return;
  }
  if (radarUiMode == RadarUiMode::ScreenOff || radarUiMode == RadarUiMode::Standby) {
    wakeRadarDisplay();
    return;
  }
  setRadarUiMode(radarUiMode == RadarUiMode::Main ? RadarUiMode::SystemMenu
                                                  : RadarUiMode::Main);
}

void enterScreenOff() {
  setRadarUiMode(RadarUiMode::ScreenOff);
}

void enterStandby() {
  tone.active = false;
  tone.remainingSamples = 0;
  voiceCapture.playbackActive = false;
  invalidateRelativeHeading(false);
  setRadarUiMode(RadarUiMode::Standby);
}

void beginShutdownFallback() {
  if (otaManager.blocksPowerAndVoice()) {
    provisioning.lastWrite = "ota_power_blocked";
    notifyDeviceStatus(true);
    return;
  }
  if (radarUiMode == RadarUiMode::ShutdownPending) {
    return;
  }
  if (voiceCapture.pttActive) {
    endPushToTalk();
  }
  tone.active = false;
  tone.remainingSamples = 0;
  bootAudioPlaying = false;
  voiceCapture.playbackActive = false;
  saveRuntimeSettings();
  radarUiMode = RadarUiMode::ShutdownPending;
  provisioning.lastWrite = "shutdown_pending";
  drawCurrentModeFrame();
  sendRelayDeviceStatus();
  notifyDeviceStatus(true);
  relaySocket.disconnect();
  delay(180);
  panel->setBrightness(0);
#if BUTTON_BOOT >= 0
  esp_sleep_enable_ext0_wakeup(static_cast<gpio_num_t>(BUTTON_BOOT), 0);
#endif
  esp_deep_sleep_start();
}

void systemUiTick() {
  if (!radarUiOverlayActive()) {
    return;
  }
  const uint32_t now = millis();
  if (systemMenuLastInteractionMs > 0 && now - systemMenuLastInteractionMs >= kSystemMenuTimeoutMs) {
    setRadarUiMode(RadarUiMode::Main);
  }
}

void handleBootShortPress() {
  if (radarUiMode == RadarUiMode::ScreenOff || radarUiMode == RadarUiMode::Standby) {
    wakeRadarDisplay();
    return;
  }
  if (radarUiOverlayActive()) {
    setRadarUiMode(RadarUiMode::Main);
    return;
  }
  // The startup north guide is informational. A BOOT tap dismisses it and
  // performs only its normal member-switch action; it must never request or
  // attempt heading calibration.
  if (headingCalibrationPromptVisible && kSerialDiagnostics) {
    Serial.println("DIAG heading_prompt action=dismiss reason=boot_short");
  }
  headingCalibrationPromptVisible = false;
  focusNextMember();
}

void replayBootAnimation() {
  radarUiMode = RadarUiMode::Main;
  resetEdgeGesture();
  runBootAnimation();
  const uint32_t now = millis();
  radarStartedMs = now;
  lastFrameMs = now;
}

void cycleFrameRate() {
  framePreset = (framePreset + 1) % kFramePresetCount;
  saveRuntimeSettings();
  const uint32_t now = millis();
  lastFrameMs = now;
  frameFlashUntilMs = now + 700;
  startTone(720.0f + framePreset * 180.0f, 48, 2600, true);
}

void drawThickLine(int x0, int y0, int x1, int y1, uint16_t color, int thick) {
  const int r = max(0, thick / 2);
  for (int dx = -r; dx <= r; ++dx) {
    for (int dy = -r; dy <= r; ++dy) {
      if (dx * dx + dy * dy <= r * r) {
        gfx->drawLine(x0 + dx, y0 + dy, x1 + dx, y1 + dy, color);
      }
    }
  }
}

void drawCenteredText(const char *text, int y, uint8_t size, uint16_t color) {
  const int charW = 6 * size;
  const int width = strlen(text) * charW;
  gfx->setTextSize(size);
  gfx->setTextColor(color);
  gfx->setCursor((kScreenW - width) / 2, y);
  gfx->print(text);
}

int circleChordHalf(int offset, int radius) {
  if (abs(offset) > radius) {
    return 0;
  }
  if (radius == kRadarRadius && radarChordHalfCacheReady) {
    return radarChordHalfCache[offset + kRadarRadius];
  }
  return static_cast<int>(sqrtf(radius * radius - offset * offset));
}

void drawScreenNoise(uint32_t seed, uint8_t count, uint16_t color) {
  uint32_t state = seed ? seed : 1;
  for (uint8_t i = 0; i < count; ++i) {
    state = state * 1664525UL + 1013904223UL;
    const int x = kCx - kRadarRadius + (state % (kRadarRadius * 2 + 1));
    state = state * 1664525UL + 1013904223UL;
    const int y = kCy - kRadarRadius + (state % (kRadarRadius * 2 + 1));
    const int dx = x - kCx;
    const int dy = y - kCy;
    if (dx * dx + dy * dy <= kRadarRadius * kRadarRadius) {
      gfx->drawPixel(x, y, color);
    }
  }
}

void drawPhosphorMask() {
  for (int offset = -kRadarRadius + 2; offset <= kRadarRadius; offset += kPhosphorScanlineStep) {
    const int half = circleChordHalf(offset);
    if (half > 3) {
      gfx->drawFastHLine(kCx - half + 2, kCy + offset, half * 2 - 4, kPhosphorLine);
    }
  }

  for (int inset = 0; inset < kPhosphorEdgeInsetLimit; inset += 4) {
    const int offset = kRadarRadius - inset;
    const int half = circleChordHalf(offset);
    if (half <= 0) {
      continue;
    }
    gfx->drawFastHLine(kCx - half, kCy - offset, half * 2, kPhosphorEdge);
    gfx->drawFastHLine(kCx - half, kCy + offset, half * 2, kPhosphorEdge);
    gfx->drawFastVLine(kCx - offset, kCy - half, half * 2, kPhosphorEdge);
    gfx->drawFastVLine(kCx + offset, kCy - half, half * 2, kPhosphorEdge);
  }
}

void drawCoordinateGridAccents(int pitch, uint16_t axisColor, uint16_t tickColor,
                               uint16_t sparkColor, uint32_t now) {
  (void)pitch;
  (void)axisColor;
  (void)tickColor;
  (void)sparkColor;
  (void)now;
}

void drawHomeMarker(uint32_t now) {
  const float pulse = (sinf(now / 180.0f) + 1.0f) * 0.5f;
  const int size = 17 + static_cast<int>(pulse * 7.0f);
  const int half = static_cast<int>(size * 0.866f);
  gfx->fillTriangle(kCx, kCy - size, kCx - half, kCy + size / 2,
                    kCx + half, kCy + size / 2, kRed);
  gfx->drawTriangle(kCx, kCy - size, kCx - half, kCy + size / 2,
                    kCx + half, kCy + size / 2, kRed);
}

void drawCalibratedNorthMarker() {
  if (!headingAlignment.valid) {
    return;
  }

  // Geographic north belongs to the calibrated world-space grid. Keep the
  // glyph upright for readability, but move it around the rim with the same
  // calibrated rotation used by the grid and remote markers.
  constexpr int kMarkerRadius = kRadarRadius - 18;
  constexpr int kMarkerWidth = 24;
  constexpr int kMarkerHeight = 22;
  int markerX = kCx;
  int markerY = kCy;
  polarToPoint(renderedRadarRotationDeg, kMarkerRadius, markerX, markerY);
  gfx->fillRect(markerX - kMarkerWidth / 2,
                markerY - kMarkerHeight / 2,
                kMarkerWidth, kMarkerHeight, kScreenBg);
  drawCenteredText("N", markerX, markerY, 2, kWhite);
}

void drawRotatingScan(uint32_t now, uint16_t activeColor, uint16_t trailColor,
                      uint8_t radiusInset = 8) {
  if (!scanning) {
    return;
  }
  const float angle = degToRad(wrap360(sweepDeg) - 90.0f);
  const int radius = kRadarRadius - radiusInset;
  const int x = kCx + static_cast<int>(cosf(angle) * radius);
  const int y = kCy + static_cast<int>(sinf(angle) * radius);

  for (uint8_t step = 34; step >= 2; step -= 2) {
    const float trailAngle = degToRad(wrap360(sweepDeg - step) - 90.0f);
    const int trailRadius = radius - 1 - step / 3;
    uint16_t color = kScanTrail5;
    if (step <= 6) {
      color = kScanTrail1;
    } else if (step <= 12) {
      color = kScanTrail2;
    } else if (step <= 20) {
      color = kScanTrail3;
    } else if (step <= 28) {
      color = kScanTrail4;
    }
    const int tx = kCx + static_cast<int>(cosf(trailAngle) * trailRadius);
    const int ty = kCy + static_cast<int>(sinf(trailAngle) * trailRadius);
    drawThickLine(kCx, kCy, tx, ty, color, 1);
  }
  drawThickLine(kCx, kCy, x, y, activeColor, 2);
}

void drawBootGridBackdrop(float phase) {
  gfx->fillCircle(kCx, kCy, kRadarRadius + 7, kScreenBg);

  const float gridWake = smoothStep(0.05f, 0.30f, phase);
  const uint16_t minorColor = gridWake > 0.75f ? kGridDim : kGridDeep;
  const uint16_t majorColor = gridWake > 0.45f ? kGrid : kGridDim;
  for (int offset = -224; offset <= 224; offset += 32) {
    const int half = circleChordHalf(offset);
    if (half > 0) {
      gfx->drawFastHLine(kCx - half, kCy + offset, half * 2, minorColor);
    }
  }

  for (int offset = -224; offset <= 224; offset += 32) {
    const int half = circleChordHalf(offset);
    if (half > 0) {
      gfx->drawFastVLine(kCx + offset, kCy - half, half * 2, minorColor);
    }
  }

  if (gridWake > 0.25f) {
    const int axisPulse = (static_cast<int>(phase * 26.0f) & 1) ? 1 : 0;
    drawCoordinateGridAccents(32, axisPulse ? kGridBright : majorColor, kGridDim, kGridDim, millis());
  }

  const float scanPhase = smoothStep(0.12f, 0.88f, phase);
  const float scanAngle = degToRad(scanPhase * 360.0f - 90.0f);
  const float trailAngle = degToRad(scanPhase * 360.0f - 97.0f);
  const int scanRadius = kRadarRadius - 8;
  const int trailRadius = kRadarRadius - 32;
  drawThickLine(kCx, kCy, kCx + static_cast<int>(cosf(scanAngle) * scanRadius),
                kCy + static_cast<int>(sinf(scanAngle) * scanRadius), kGrid, 2);
  drawThickLine(kCx, kCy, kCx + static_cast<int>(cosf(trailAngle) * trailRadius),
                kCy + static_cast<int>(sinf(trailAngle) * trailRadius), kGridDim, 1);

  if (phase < 0.82f) {
    const uint32_t seed = static_cast<uint32_t>(phase * 100000.0f) ^ millis();
    drawScreenNoise(seed, 24 + static_cast<uint8_t>((1.0f - phase) * 30.0f), kGridDeep);
  }
}

void drawDefaultBootLogo(float phase) {
  const uint16_t deepGreen = RGB565(5, 36, 30);
  const uint16_t radarGreen = RGB565(35, 190, 116);
  const uint16_t gold = RGB565(244, 184, 52);
  const uint16_t cream = RGB565(255, 248, 218);
  const float ring = smoothStep(0.02f, 0.32f, phase);
  const float target = smoothStep(0.18f, 0.68f, phase);
  const float word = smoothStep(0.62f, 0.94f, phase);
  const int logoY = kCy - 24;

  if (ring > 0.0f) {
    const int innerRadius = static_cast<int>(82.0f * ring);
    const int outerRadius = static_cast<int>(120.0f * ring);
    gfx->drawCircle(kCx, logoY, innerRadius, radarGreen);
    gfx->drawCircle(kCx, logoY, outerRadius, kGridDim);
    gfx->drawCircle(kCx, logoY, max(1, outerRadius - 2), deepGreen);
    const float scanAngle = degToRad(-48.0f + phase * 210.0f);
    drawThickLine(kCx, logoY,
                  kCx + static_cast<int>(cosf(scanAngle) * max(1, outerRadius - 8)),
                  logoY + static_cast<int>(sinf(scanAngle) * max(1, outerRadius - 8)),
                  radarGreen, 2);

    const int tick = max(1, static_cast<int>(10.0f * ring));
    gfx->drawFastVLine(kCx, logoY - outerRadius - tick, tick, radarGreen);
    gfx->drawFastVLine(kCx, logoY + outerRadius + 1, tick, radarGreen);
    gfx->drawFastHLine(kCx - outerRadius - tick, logoY, tick, radarGreen);
    gfx->drawFastHLine(kCx + outerRadius + 1, logoY, tick, radarGreen);
  }

  if (target > 0.0f) {
    const float targetAngle = degToRad(-32.0f);
    const int targetRadius = static_cast<int>(72.0f * target);
    const int targetX = kCx + static_cast<int>(cosf(targetAngle) * targetRadius);
    const int targetY = logoY + static_cast<int>(sinf(targetAngle) * targetRadius);
    const int haloRadius = 3 + static_cast<int>(5.0f * target);
    gfx->drawCircle(targetX, targetY, haloRadius + 3, gold);
    gfx->fillCircle(targetX, targetY, haloRadius, cream);
    gfx->fillCircle(targetX, targetY, 2, gold);
  }

  if (word > 0.0f) {
    drawCenteredText("CAPSULE", kCy + 112, 2, word > 0.65f ? cream : kGridDim);
    drawCenteredText("RADAR", kCy + 139, 1, word > 0.82f ? gold : kGridDim);
  }
}

void drawRoundBadgeFrame(const uint16_t *pixels, int width, int maskRadius) {
  gfx->fillScreen(kScreenBg);

  const int r2 = maskRadius * maskRadius;
  for (int y = 0; y < kScreenH; ++y) {
    const int dy = y - kCy;
    const int half = static_cast<int>(sqrtf(max(0, r2 - dy * dy)));
    const int x0 = max(0, kCx - half);
    const int x1 = min(kScreenW - 1, kCx + half);
    for (int x = x0; x <= x1; ++x) {
      const uint16_t color = pgm_read_word(&pixels[y * width + x]);
      gfx->drawPixel(x, y, color);
    }
  }
}

void drawBulmaBadgeFrame() {
  drawRoundBadgeFrame(kBulmaBootBadge565, kBulmaBootBadgeW, kBulmaBootBadgeMaskR);
}

void drawBootFrame(float phase) {
  (void)phase;
  drawBulmaBadgeFrame();
}

bool codecWrite(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(0x18);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool codecRead(uint8_t reg, uint8_t &value) {
  Wire.beginTransmission(0x18);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }
  if (Wire.requestFrom(0x18, 1) != 1) {
    return false;
  }
  value = Wire.read();
  return true;
}

bool es7210Write(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(kEs7210Address);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool es7210Read(uint8_t reg, uint8_t &value) {
  Wire.beginTransmission(kEs7210Address);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }
  if (Wire.requestFrom(kEs7210Address, static_cast<uint8_t>(1)) != 1) {
    return false;
  }
  value = Wire.read();
  return true;
}

bool es7210Update(uint8_t reg, uint8_t mask, uint8_t value) {
  uint8_t current = 0;
  if (!es7210Read(reg, current)) {
    return false;
  }
  current = (current & ~mask) | (value & mask);
  return es7210Write(reg, current);
}

bool axpRead(uint8_t reg, uint8_t &value) {
  Wire.beginTransmission(kAxp2101Address);
  Wire.write(reg);
  if (Wire.endTransmission(false) != 0) {
    return false;
  }
  if (Wire.requestFrom(kAxp2101Address, static_cast<uint8_t>(1)) != 1) {
    return false;
  }
  value = Wire.read();
  return true;
}

bool axpWrite(uint8_t reg, uint8_t value) {
  Wire.beginTransmission(kAxp2101Address);
  Wire.write(reg);
  Wire.write(value);
  return Wire.endTransmission() == 0;
}

bool axpReadAdc14(uint8_t highReg, uint8_t lowReg, uint16_t &value) {
  uint8_t high = 0;
  uint8_t low = 0;
  if (!axpRead(highReg, high) || !axpRead(lowReg, low)) {
    return false;
  }
  value = (static_cast<uint16_t>(high & 0x3f) << 8) | low;
  return true;
}

bool batteryLevelLow() {
  return batteryStatus.present && batteryStatus.percent >= 0 &&
         batteryStatus.percent <= kLowBatteryPercent;
}

void updateBatteryStatus(bool force) {
  const uint32_t now = millis();
  if (!force && now - batteryStatus.lastReadMs < kBatteryPollMs) {
    return;
  }
  batteryStatus.lastReadMs = now;

  uint8_t status1 = 0;
  uint8_t status2 = 0;
  uint8_t percent = 0;
  uint16_t voltageMv = 0;
  const bool status1Ok = axpRead(kAxpStatus1Reg, status1);
  const bool status2Ok = axpRead(kAxpStatus2Reg, status2);
  const bool percentOk = axpRead(kAxpBatteryPercentReg, percent);
  const bool voltageOk = axpReadAdc14(kAxpBatteryVoltageHighReg, kAxpBatteryVoltageLowReg, voltageMv);

  batteryStatus.online = status1Ok || status2Ok || percentOk || voltageOk;
  batteryStatus.present = status1Ok && ((status1 & kAxpBatteryPresentBit) != 0);
  const uint8_t currentDirection = status2Ok ? ((status2 >> 5) & 0x03) : 0;
  batteryStatus.charging = currentDirection == 0x01;
  batteryStatus.discharging = currentDirection == 0x02;
  batteryStatus.percent = (percentOk && percent <= 100) ? static_cast<int8_t>(percent) : -1;
  batteryStatus.voltageMv = voltageOk ? voltageMv : 0;
  batteryStatus.low = batteryLevelLow();
}

void setupBatteryGauge() {
  uint8_t control = 0;
  if (axpRead(kAxpChargerFuelGaugeReg, control) &&
      (control & kAxpGaugeEnableBit) == 0) {
    axpWrite(kAxpChargerFuelGaugeReg, control | kAxpGaugeEnableBit);
  }
  updateBatteryStatus(true);
}

void setupPowerButton() {
  uint8_t enable = 0;
  if (!axpRead(kAxpIrqEnable1Reg, enable)) {
    powerButtonOnline = false;
    Serial.println("AXP2101 power button offline.");
    return;
  }

  enable |= kAxpPowerKeyShortPressBit | kAxpPowerKeyLongPressBit;
  powerButtonOnline = axpWrite(kAxpIrqEnable1Reg, enable) &&
                      axpWrite(kAxpIrqStatus1Reg, kAxpPowerKeyShortPressBit | kAxpPowerKeyLongPressBit);
  Serial.println(powerButtonOnline ? "AXP2101 power button online." : "AXP2101 power button setup failed.");
}

void pollPowerButton() {
  if (!powerButtonOnline) {
    return;
  }

  static uint32_t lastPowerPollMs = 0;
  const uint32_t now = millis();
  if (now - lastPowerPollMs < 80) {
    return;
  }
  lastPowerPollMs = now;

  uint8_t status = 0;
  if (!axpRead(kAxpIrqStatus1Reg, status)) {
    return;
  }

  const uint8_t keyStatus = status & (kAxpPowerKeyShortPressBit | kAxpPowerKeyLongPressBit);
  if (keyStatus == 0) {
    return;
  }
  axpWrite(kAxpIrqStatus1Reg, keyStatus);

  lastUserInputMs = now;
  if ((keyStatus & kAxpPowerKeyLongPressBit) != 0) {
    if (voiceCapture.pttActive) {
      return;
    }
    if (radarUiMode == RadarUiMode::PowerConfirm) {
      beginShutdownFallback();
    } else if (radarUiMode == RadarUiMode::ScreenOff || radarUiMode == RadarUiMode::Standby) {
      wakeRadarDisplay();
    } else {
      setRadarUiMode(RadarUiMode::PowerConfirm);
    }
    return;
  }

  if ((keyStatus & kAxpPowerKeyShortPressBit) != 0) {
    toggleSystemMenu();
  }
}

uint8_t codecVolumeRegister(uint8_t percent) {
  if (percent == 0) {
    return 0;
  }
  const int reg = (static_cast<int>(min<uint8_t>(percent, 100)) * 256 / 100) - 1;
  return static_cast<uint8_t>(constrain(reg, 0, 255));
}

uint8_t currentCodecOutputVolumePercent() {
  if (audioPreset >= kAudioPresetCount) {
    return kCodecRuntimePercents[4];
  }
  return kCodecRuntimePercents[audioPreset];
}

bool applyCodecOutputVolume() {
  if (!audioOnline) {
    return false;
  }
  return codecWrite(0x32, codecVolumeRegister(currentCodecOutputVolumePercent()));
}

bool applyCodecOutputVolumePercent(uint8_t percent) {
  if (!audioOnline) {
    return false;
  }
  return codecWrite(0x32, codecVolumeRegister(percent));
}

bool setCodecOutputMuted(bool muted) {
  uint8_t reg = 0;
  if (!codecRead(0x31, reg)) {
    return false;
  }
  if (muted) {
    reg |= 0x60;
  } else {
    reg &= ~0x60;
  }
  return codecWrite(0x31, reg);
}

void setSpeakerMutedForCapture(bool muted) {
  speakerMutedForCapture = muted;
  if (muted) {
    tone.active = false;
    tone.remainingSamples = 0;
    bootAudioPlaying = false;
  }
  if (audioOnline) {
    setCodecOutputMuted(muted);
  }
  digitalWrite(PA, muted ? LOW : HIGH);
}

bool beginI2sBus(uint32_t sampleRate) {
  i2s.end();
  audioTxConfigured = false;
  audioRxConfigured = false;
  audioTxSampleRate = 0;
  audioTxFailureLogged = false;
  audioRxFailureLogged = false;

  i2s.setPins(PIN_ES7210_BCLK, PIN_ES7210_LRCK, PIN_ES8311_DOUT, PIN_ES7210_DIN, PIN_ES7210_MCLK);
  if (!i2s.begin(I2S_MODE_STD, sampleRate, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO, I2S_STD_SLOT_BOTH)) {
    return false;
  }
  i2s.setTimeout(1);
  return true;
}

bool setupCodecForSampleRate(uint32_t sampleRate) {
  (void)sampleRate;
  uint8_t reg = 0;
  bool ok = true;

  ok &= codecWrite(0x00, 0x1F);
  ok &= codecWrite(0x00, 0x00);
  ok &= codecWrite(0x00, 0x80);
  ok &= codecWrite(0x01, 0x3F);
  ok &= codecRead(0x06, reg);
  reg &= 0xE0;
  reg |= 0x03;
  ok &= codecWrite(0x06, reg);
  ok &= codecWrite(0x02, 0x00);
  ok &= codecWrite(0x03, 0x10);
  ok &= codecWrite(0x04, 0x10);
  ok &= codecWrite(0x05, 0x00);
  ok &= codecWrite(0x07, 0x00);
  ok &= codecWrite(0x08, 0xFF);

  ok &= codecRead(0x00, reg);
  reg &= 0xBF;
  ok &= codecWrite(0x00, reg);
  ok &= codecWrite(0x09, 0x0C);
  ok &= codecWrite(0x0A, 0x0C);
  ok &= codecWrite(0x0D, 0x01);
  ok &= codecWrite(0x0E, 0x02);
  ok &= codecWrite(0x12, 0x00);
  ok &= codecWrite(0x13, 0x10);
  ok &= codecWrite(0x1C, 0x6A);
  ok &= codecWrite(0x37, 0x08);
  ok &= codecWrite(0x17, 0xC8);
  ok &= codecWrite(0x14, 0x1A);
  ok &= codecWrite(0x16, 0x03);
  ok &= codecWrite(0x32, codecVolumeRegister(currentCodecOutputVolumePercent()));
  ok &= codecRead(0x31, reg);
  reg &= ~(0x60);
  ok &= codecWrite(0x31, reg);

  return ok;
}

bool setupEs7210Adc16k() {
  bool ok = true;

  ok &= es7210Write(0x00, 0xff);
  ok &= es7210Write(0x00, 0x41);
  ok &= es7210Write(0x01, 0x1f);
  ok &= es7210Write(0x09, 0x30);
  ok &= es7210Write(0x0a, 0x30);
  ok &= es7210Write(0x40, 0xc3);
  ok &= es7210Write(0x41, 0x70);
  ok &= es7210Write(0x42, 0x70);

  ok &= es7210Write(0x02, 0xc1);
  ok &= es7210Write(0x07, 0x20);
  ok &= es7210Write(0x04, 0x01);
  ok &= es7210Write(0x05, 0x00);
  // 0xC1 is only the ES7210 clock-state reset value. For a 4.096 MHz
  // MCLK and 16 kHz LRCK the running divider must be 0x01; leaving the
  // reset bits enabled produces near-zero PCM even though the ADC responds.
  ok &= es7210Write(0x02, 0x01);

  for (uint8_t reg = 0x43; reg <= 0x46; ++reg) {
    ok &= es7210Update(reg, 0x10, 0x00);
  }
  ok &= es7210Write(0x4b, 0xff);
  ok &= es7210Write(0x4c, 0xff);

  ok &= es7210Update(0x01, 0x0b, 0x00);
  ok &= es7210Write(0x4b, 0x00);
  ok &= es7210Update(0x43, 0x10, 0x10);
  ok &= es7210Update(0x01, 0x0b, 0x00);
  ok &= es7210Write(0x4b, 0x00);
  ok &= es7210Update(0x44, 0x10, 0x10);
  ok &= es7210Update(0x01, 0x15, 0x00);
  ok &= es7210Write(0x4c, 0x00);
  ok &= es7210Update(0x45, 0x10, 0x10);
  ok &= es7210Update(0x01, 0x15, 0x00);
  ok &= es7210Write(0x4c, 0x00);
  ok &= es7210Update(0x46, 0x10, 0x10);

  ok &= es7210Update(0x11, 0xe0, 0x60);
  ok &= es7210Update(0x11, 0x03, 0x00);
  ok &= es7210Write(0x12, 0x00);

  ok &= es7210Update(0x43, 0x0f, 0x00);
  ok &= es7210Update(0x44, 0x0f, 0x00);
  ok &= es7210Update(0x45, 0x0f, 0x0e);
  ok &= es7210Update(0x46, 0x0f, 0x0e);

  ok &= es7210Write(0x01, 0x00);
  ok &= es7210Write(0x06, 0x00);
  ok &= es7210Write(0x47, 0x00);
  ok &= es7210Write(0x48, 0x00);
  ok &= es7210Write(0x49, 0x00);
  ok &= es7210Write(0x4a, 0x00);
  ok &= es7210Write(0x4b, 0x00);
  ok &= es7210Write(0x4c, 0x00);

  if (kSerialDiagnostics) {
    uint8_t chipState = 0;
    if (es7210Read(0x01, chipState)) {
      Serial.print("DIAG es7210 clock=");
      Serial.println(chipState, HEX);
    }
  }
  return ok;
}

bool configureAudioTx(uint32_t sampleRate) {
  if (!audioOnline) {
    return false;
  }
  if (sampleRate == kAudioSampleRate || sampleRate == kBootAudioSampleRate) {
    if (i2s.txSampleRate() != sampleRate &&
        !i2s.configureTX(sampleRate, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO, I2S_STD_SLOT_BOTH)) {
      if (!audioTxFailureLogged) {
        Serial.println("I2S TX configure failed.");
        audioTxFailureLogged = true;
      }
      return false;
    }
    audioTxConfigured = true;
    audioRxConfigured = false;
    audioTxSampleRate = sampleRate;
    audioTxFailureLogged = false;
    return true;
  }

  if (!audioTxFailureLogged) {
    Serial.println("I2S TX sample-rate switch disabled.");
    audioTxFailureLogged = true;
  }
  return false;
}

bool configureAudioRx() {
  if (!voiceInputOnline) {
    return false;
  }
  audioRxConfigured = true;
  audioRxFailureLogged = false;
  return true;
}

void startTone(float frequency, uint16_t durationMs, int16_t level, bool force = false) {
  (void)frequency;
  (void)durationMs;
  (void)level;
  (void)force;
  tone.active = false;
  tone.remainingSamples = 0;
}

void startAlertTone(float frequency, uint16_t durationMs, int16_t level, bool force = false) {
  if (!kSoundEffectsEnabled) {
    tone.active = false;
    tone.remainingSamples = 0;
    return;
  }
  if (voiceCapture.pttActive || voiceCapture.playbackActive || speakerMutedForCapture) {
    tone.active = false;
    tone.remainingSamples = 0;
    return;
  }
  if (!audioOnline) {
    return;
  }
  if (audioPreset == 0) {
    tone.active = false;
    tone.remainingSamples = 0;
    return;
  }
  if (tone.active && !force) {
    return;
  }
  applyCodecOutputVolume();
  setCodecOutputMuted(false);
  digitalWrite(PA, HIGH);
  tone.active = true;
  tone.frequency = frequency;
  tone.phase = 0.0f;
  tone.totalSamples = (kAudioSampleRate * durationMs) / 1000;
  tone.remainingSamples = tone.totalSamples;
  tone.level = scaledAlertAudioLevel(level);
}

void startBootTone(float frequency, uint16_t durationMs, int16_t level) {
  if (!kSoundEffectsEnabled || !audioOnline || voiceCapture.pttActive || speakerMutedForCapture) {
    return;
  }
  if (!configureAudioTx(kAudioSampleRate)) {
    return;
  }
  applyCodecOutputVolumePercent(kBootCodecOutputVolumePercent);
  setCodecOutputMuted(false);
  digitalWrite(PA, HIGH);
  tone.active = true;
  tone.frequency = frequency;
  tone.phase = 0.0f;
  tone.totalSamples = (kAudioSampleRate * durationMs) / 1000;
  tone.remainingSamples = tone.totalSamples;
  tone.level = scaledBootAudioLevel(level);
}

void playBootAudioCues(float phase, uint8_t &nextCue) {
  while (nextCue < kBootAudioCueCount && phase >= kBootAudioCues[nextCue].phase) {
    const BootAudioCue &cue = kBootAudioCues[nextCue];
    startBootTone(cue.frequency, cue.durationMs, cue.level);
    ++nextCue;
  }
}

void startBootBackgroundAudio() {
  bootAudioPcmOffset = 0;
  bootAudioPlaying = kSoundEffectsEnabled && audioOnline &&
                     kBootAudioPcm_len >= kBootAudioChannels * sizeof(int16_t) &&
                     configureAudioTx(kBootAudioSampleRate);
  if (bootAudioPlaying) {
    applyCodecOutputVolumePercent(kBootCodecOutputVolumePercent);
    setCodecOutputMuted(false);
    digitalWrite(PA, HIGH);
    tone.active = false;
    tone.remainingSamples = 0;
  }
}

void stopBootBackgroundAudio() {
  if (bootAudioPlaying && audioOnline) {
    if (configureAudioTx(kBootAudioSampleRate)) {
      int16_t silence[96 * kBootAudioChannels] = {0};
      i2s.write(reinterpret_cast<uint8_t *>(silence), sizeof(silence));
    }
    setCodecOutputMuted(true);
    digitalWrite(PA, LOW);
  }
  bootAudioPlaying = false;
}

void bootBackgroundAudioTick() {
  if (!bootAudioPlaying || !audioOnline) {
    return;
  }
  if (voiceCapture.pttActive || speakerMutedForCapture) {
    stopBootBackgroundAudio();
    return;
  }
  if (!configureAudioTx(kBootAudioSampleRate)) {
    bootAudioPlaying = false;
    return;
  }

  constexpr size_t kBootAudioFramesPerTick = 768;
  int16_t stereo[kBootAudioFramesPerTick * kBootAudioChannels];
  const size_t frameBytes = kBootAudioChannels * sizeof(int16_t);
  const size_t totalFrames = kBootAudioPcm_len / frameBytes;
  const size_t remainingFrames = (kBootAudioPcm_len - bootAudioPcmOffset) / frameBytes;
  const size_t count = min(kBootAudioFramesPerTick, remainingFrames);
  constexpr uint8_t volumePercent = kBootAudioVolumePercent;
  const size_t fadeInFrames = (static_cast<size_t>(kBootAudioSampleRate) * kBootAudioFadeInMs) / 1000;
  const size_t fadeOutFrames = (static_cast<size_t>(kBootAudioSampleRate) * kBootAudioFadeOutMs) / 1000;
  const size_t startFrame = bootAudioPcmOffset / frameBytes;

  for (size_t i = 0; i < count; ++i) {
    const size_t frameIndex = startFrame + i;
    float envelope = 1.0f;
    if (fadeInFrames > 0 && frameIndex < fadeInFrames) {
      envelope = min(envelope, static_cast<float>(frameIndex) / static_cast<float>(fadeInFrames));
    }
    if (fadeOutFrames > 0 && frameIndex + fadeOutFrames > totalFrames) {
      const size_t framesLeft = totalFrames > frameIndex ? totalFrames - frameIndex : 0;
      envelope = min(envelope, static_cast<float>(framesLeft) / static_cast<float>(fadeOutFrames));
    }
    envelope = smoothStep(0.0f, 1.0f, clampf(envelope, 0.0f, 1.0f));
    for (uint8_t ch = 0; ch < kBootAudioChannels; ++ch) {
      const size_t byteOffset = bootAudioPcmOffset + i * frameBytes + ch * sizeof(int16_t);
      const uint16_t raw = static_cast<uint16_t>(kBootAudioPcm[byteOffset]) |
                           (static_cast<uint16_t>(kBootAudioPcm[byteOffset + 1]) << 8);
      const int16_t source = static_cast<int16_t>(raw);
      const int32_t scaled = static_cast<int32_t>(
          (static_cast<float>(source) * static_cast<float>(volumePercent) * envelope) / 100.0f);
      stereo[i * kBootAudioChannels + ch] =
          static_cast<int16_t>(constrain(scaled,
                                         -static_cast<long>(kBootAudioPeakLimit),
                                         static_cast<long>(kBootAudioPeakLimit)));
    }
  }

  if (count > 0) {
    i2s.write(reinterpret_cast<uint8_t *>(stereo), count * frameBytes);
    bootAudioPcmOffset += count * frameBytes;
  }
  if (bootAudioPcmOffset >= kBootAudioPcm_len || count == 0) {
    stopBootBackgroundAudio();
  }
}

void audioTick() {
  if (!audioOnline || !tone.active) {
    return;
  }
  if (voiceCapture.pttActive || voiceCapture.playbackActive || speakerMutedForCapture) {
    tone.active = false;
    tone.remainingSamples = 0;
    return;
  }
  if (!configureAudioTx(kAudioSampleRate)) {
    return;
  }

  constexpr int kChunkSamples = 96;
  int16_t samples[kChunkSamples * 2];
  const int count = min(kChunkSamples, tone.remainingSamples);

  for (int i = 0; i < count; ++i) {
    const int played = tone.totalSamples - tone.remainingSamples + i;
    const float attack = clampf(played / 80.0f, 0.0f, 1.0f);
    const float release = clampf((tone.remainingSamples - i) / 120.0f, 0.0f, 1.0f);
    const float envelope = min(attack, release);
    const int16_t sample = static_cast<int16_t>(sinf(tone.phase) * tone.level * envelope);
    tone.phase += (2.0f * kPi * tone.frequency) / kAudioSampleRate;
    if (tone.phase > 2.0f * kPi) {
      tone.phase -= 2.0f * kPi;
    }
    samples[i * 2] = sample;
    samples[i * 2 + 1] = sample;
  }

  i2s.write(reinterpret_cast<uint8_t *>(samples), count * 2 * sizeof(int16_t));
  tone.remainingSamples -= count;
  if (tone.remainingSamples <= 0) {
    tone.active = false;
  }
}

void resetPanelAndTouch() {
  pinMode(LCD_RESET, OUTPUT);
  digitalWrite(LCD_RESET, HIGH);
#if TP_RST != LCD_RESET
  pinMode(TP_RST, OUTPUT);
  digitalWrite(TP_RST, HIGH);
#endif
  delay(10);

  digitalWrite(LCD_RESET, LOW);
#if TP_RST != LCD_RESET
  digitalWrite(TP_RST, LOW);
#endif
  delay(120);

  digitalWrite(LCD_RESET, HIGH);
#if TP_RST != LCD_RESET
  digitalWrite(TP_RST, HIGH);
#endif
  delay(120);
}

void setupBootAudio() {
  pinMode(PA, OUTPUT);
  digitalWrite(PA, LOW);
  speakerMutedForCapture = false;

  voiceInputOnline = false;
  voiceCapture.captureOnline = false;
  if (!beginI2sBus(kBootAudioSampleRate)) {
    audioOnline = false;
    Serial.println("I2S boot audio offline.");
    return;
  }

  audioOnline = setupCodecForSampleRate(kBootAudioSampleRate);
  configureAudioTx(kBootAudioSampleRate);
  if (audioOnline) {
    applyCodecOutputVolumePercent(kBootCodecOutputVolumePercent);
    setCodecOutputMuted(false);
    digitalWrite(PA, HIGH);
  }
  Serial.println(audioOnline ? "ES8311 boot audio online." : "ES8311 boot codec offline.");
}

void setupAudio() {
  pinMode(PA, OUTPUT);
  digitalWrite(PA, LOW);
  speakerMutedForCapture = false;

  if (!beginI2sBus(kAudioSampleRate)) {
    audioOnline = false;
    voiceInputOnline = false;
    voiceCapture.captureOnline = false;
    Serial.println("I2S audio offline.");
    return;
  }

  audioOnline = setupCodecForSampleRate(kAudioSampleRate);
  voiceInputOnline = setupEs7210Adc16k();
  voiceCapture.captureOnline = voiceInputOnline;
  configureAudioTx(kAudioSampleRate);
  if (audioOnline) {
    applyCodecOutputVolume();
    setCodecOutputMuted(false);
    digitalWrite(PA, HIGH);
  }
  Serial.println(audioOnline ? "ES8311 audio online." : "ES8311 codec offline.");
  Serial.println(voiceInputOnline ? "ES7210 mic online." : "ES7210 mic offline.");
}

void runBootAnimation() {
  bootStartedMs = millis();
  const uint8_t targetBrightness = currentBrightness();
  panel->setBrightness(0);
  drawBootFrame(1.0f);
  gfx->flush();
  startBootBackgroundAudio();

  while (millis() - bootStartedMs < kBootDurationMs) {
    const uint32_t elapsedMs = millis() - bootStartedMs;
    const float phase = clampf(elapsedMs / static_cast<float>(kBootDurationMs), 0.0f, 1.0f);
    const float fadeIn = smoothStep(0.0f, static_cast<float>(kBootFadeInMs), static_cast<float>(elapsedMs));
    const float fadeOut = 1.0f - smoothStep(static_cast<float>(kBootDurationMs - kBootFadeOutMs),
                                            static_cast<float>(kBootDurationMs),
                                            static_cast<float>(elapsedMs));
    const float brightness = clampf(fadeIn * fadeOut, 0.0f, 1.0f);
    panel->setBrightness(static_cast<uint8_t>(targetBrightness * brightness));
    readImu();
    bootBackgroundAudioTick();
    delay(18);
  }
  stopBootBackgroundAudio();
  panel->setBrightness(0);
  gfx->fillScreen(kBlack);
  gfx->flush();
  mainFadeStartedMs = millis();
}

void updateMainFadeBrightness(uint32_t now) {
  if (mainFadeStartedMs == 0) {
    return;
  }

  const float phase = clampf((now - mainFadeStartedMs) / static_cast<float>(kMainFadeInMs), 0.0f, 1.0f);
  const uint8_t targetBrightness = currentBrightness();
  if (phase >= 1.0f) {
    panel->setBrightness(targetBrightness);
    mainFadeStartedMs = 0;
    return;
  }

  const float brightness = smoothStep(0.0f, 1.0f, phase);
  panel->setBrightness(static_cast<uint8_t>(targetBrightness * brightness));
}

void setupBle() {
  if (kRemoteBleEnabled && provisioning.deviceName[0] == '\0') {
    buildProvisioningIdentity();
  }
  const char *bleName = kRemoteBleEnabled && provisioning.deviceName[0] != '\0'
                            ? provisioning.deviceName
                            : "CapsuleRadar";
  BLEDevice::init(bleName);
  if (BLEDevice::setMTU(517) != ESP_OK) {
    Serial.println("BLE MTU 517 configuration failed; OTA status will use read fallback.");
  }
  setupProvisioningBle();
  bleOnline = provisioning.serviceOnline;
  Serial.println("BLE provisioning online.");
}

void onTouchInterrupt() {
  touchIrq = true;
}

void setupTouch() {
  touch.setPins(GFX_NOT_DEFINED, TP_INT);
  for (uint8_t attempt = 0; attempt < kTouchInitAttempts; ++attempt) {
    touchOnline = touch.begin(Wire, 0x5A, -1, -1);
    if (touchOnline) {
      break;
    }
    Serial.print("Touch init retry ");
    Serial.print(attempt + 1);
    Serial.println(" failed.");
    if (attempt + 1 < kTouchInitAttempts) {
      resetPanelAndTouch();
      Wire.begin(IIC_SDA, IIC_SCL);
      delay(80);
    }
  }
  if (!touchOnline) {
    Serial.println("Touch offline; continuing without touch.");
    return;
  }

  touch.setMaxCoordinates(LCD_WIDTH, LCD_HEIGHT);
  touch.setMirrorXY(true, true);
  pinMode(TP_INT, INPUT_PULLUP);
  touchIrq = true;
  Serial.print("Touch online: ");
  Serial.println(touch.getModelName());
}

const char *headingQualityText(HeadingQuality quality) {
  switch (quality) {
    case HeadingQuality::Unavailable: return "unavailable";
    case HeadingQuality::Calibrating: return "calibrating";
    case HeadingQuality::RelativeDegraded: return "relative_degraded";
    case HeadingQuality::RelativeStable: return "relative_stable";
    default: return "unknown";
  }
}

bool gyroBiasPlausible(float x, float y, float z) {
  return isfinite(x) && isfinite(y) && isfinite(z) &&
         fabsf(x) <= kGyroBiasMaxAbsDps &&
         fabsf(y) <= kGyroBiasMaxAbsDps &&
         fabsf(z) <= kGyroBiasMaxAbsDps;
}

bool imuTemperaturePlausible(float value) {
  // QMI8658 can expose an all-zero temperature register briefly after enable.
  // Exact 0.0 is therefore treated as unavailable, not as a real board temperature.
  return isfinite(value) && value >= -40.0f && value <= 100.0f && fabsf(value) > 0.001f;
}

bool gyroBiasTemperatureCompatible() {
  return !imuTemperaturePlausible(headingEstimator.currentTemperatureC) ||
         !imuTemperaturePlausible(headingEstimator.biasTemperatureC) ||
         fabsf(headingEstimator.currentTemperatureC - headingEstimator.biasTemperatureC) <=
             kGyroBiasTemperatureTrustDeltaC;
}

bool persistedGyroBiasTrustedForSession() {
  return DragonRadarHeadingAlignment::persistedGyroBiasTrusted(
      headingEstimator.biasValid,
      headingEstimator.biasLoaded,
      imuTemperaturePlausible(headingEstimator.currentTemperatureC),
      headingEstimator.currentTemperatureC,
      imuTemperaturePlausible(headingEstimator.biasTemperatureC),
      headingEstimator.biasTemperatureC,
      kGyroBiasTemperatureTrustDeltaC);
}

void trustLoadedGyroBiasIfSafe() {
  if (headingEstimator.sessionStationaryVerified ||
      !persistedGyroBiasTrustedForSession()) {
    return;
  }
  headingEstimator.sessionStationaryVerified = true;
  headingEstimator.sessionTrustFromStoredBias = true;
  Serial.println("QMI8658 stored gyro bias trusted for warm start.");
}

void updateImuTemperature(uint32_t nowMs, bool force) {
  const uint32_t pollIntervalMs = imuTemperaturePlausible(headingEstimator.currentTemperatureC)
                                      ? kImuTemperaturePollMs
                                      : kImuTemperatureRetryMs;
  if (!imuOnline || (!force && headingEstimator.lastTemperatureReadMs > 0 &&
                     nowMs - headingEstimator.lastTemperatureReadMs < pollIntervalMs)) {
    return;
  }
  const float temperatureC = qmi.getTemperature_C();
  headingEstimator.lastTemperatureReadMs = nowMs;
  if (imuTemperaturePlausible(temperatureC)) {
    headingEstimator.currentTemperatureC = temperatureC;
    // The sensor can briefly return 0 C after enable. Promote a loaded bias as
    // soon as a real temperature sample proves it is safe, without making the
    // user wait for a new stationary window.
    trustLoadedGyroBiasIfSafe();
  }
}

void resetGyroStationaryWindow(bool clearStationary) {
  headingEstimator.stationaryWindowStartedMs = 0;
  headingEstimator.stationarySamples = 0;
  headingEstimator.gyroSumX = 0.0;
  headingEstimator.gyroSumY = 0.0;
  headingEstimator.gyroSumZ = 0.0;
  headingEstimator.gyroSumSqX = 0.0;
  headingEstimator.gyroSumSqY = 0.0;
  headingEstimator.gyroSumSqZ = 0.0;
  if (clearStationary) {
    headingEstimator.stationary = false;
  }
}

void loadGyroBias() {
  Preferences prefs;
  if (!prefs.begin("radarImu", true)) {
    Serial.println("QMI8658 gyro bias store unavailable; background calibration enabled.");
    return;
  }

  const uint32_t schema = prefs.getUInt("schema", 0);
  const float x = prefs.getFloat("biasX", NAN);
  const float y = prefs.getFloat("biasY", NAN);
  const float z = prefs.getFloat("biasZ", NAN);
  const float biasTemperatureC = prefs.getFloat("biasTemp", NAN);
  prefs.end();
  if (schema != kGyroBiasPrefsSchema || !gyroBiasPlausible(x, y, z) ||
      !imuTemperaturePlausible(biasTemperatureC)) {
    Serial.println("QMI8658 gyro bias missing; learning silently while stationary.");
    return;
  }

  headingEstimator.biasX = x;
  headingEstimator.biasY = y;
  headingEstimator.biasZ = z;
  headingEstimator.savedBiasX = x;
  headingEstimator.savedBiasY = y;
  headingEstimator.savedBiasZ = z;
  headingEstimator.biasTemperatureC = biasTemperatureC;
  headingEstimator.savedBiasTemperatureC = biasTemperatureC;
  headingEstimator.biasValid = true;
  headingEstimator.biasLoaded = true;
  headingEstimator.lastBiasPersistMs = millis();
  headingEstimator.quality = HeadingQuality::RelativeDegraded;
  trustLoadedGyroBiasIfSafe();
  Serial.print("QMI8658 gyro bias loaded x=");
  Serial.print(x, 4);
  Serial.print(" y=");
  Serial.print(y, 4);
  Serial.print(" z=");
  Serial.print(z, 4);
  Serial.print(" tempC=");
  Serial.print(biasTemperatureC, 1);
  if (imuTemperaturePlausible(headingEstimator.currentTemperatureC)) {
    Serial.print(" deltaC=");
    Serial.print(headingEstimator.currentTemperatureC - biasTemperatureC, 1);
  }
  Serial.println();
}

void markGyroBiasDirty(uint32_t nowMs) {
  const float delta = fmaxf(
      fabsf(headingEstimator.biasX - headingEstimator.savedBiasX),
      fmaxf(fabsf(headingEstimator.biasY - headingEstimator.savedBiasY),
            fabsf(headingEstimator.biasZ - headingEstimator.savedBiasZ)));
  const float temperatureDelta =
      imuTemperaturePlausible(headingEstimator.biasTemperatureC) &&
              imuTemperaturePlausible(headingEstimator.savedBiasTemperatureC)
          ? fabsf(headingEstimator.biasTemperatureC - headingEstimator.savedBiasTemperatureC)
          : 0.0f;
  if (delta < kGyroBiasPersistDeltaDps &&
      temperatureDelta < kGyroBiasPersistTempDeltaC &&
      headingEstimator.biasLoaded) {
    return;
  }
  headingEstimator.biasDirty = true;
  if (headingEstimator.biasDirtySinceMs == 0) {
    headingEstimator.biasDirtySinceMs = nowMs;
  }
}

void persistGyroBiasIfDue(uint32_t nowMs) {
  if (!headingEstimator.biasValid || !headingEstimator.biasDirty ||
      !headingEstimator.stationary || headingEstimator.biasDirtySinceMs == 0) {
    return;
  }

  const uint32_t requiredDelay = headingEstimator.forceBiasPersistAfterStrictVerification
                                     ? 0
                                     : (headingEstimator.biasLoaded
                                            ? kGyroBiasPersistMinIntervalMs
                                            : kGyroBiasFirstPersistDelayMs);
  const uint32_t elapsed = headingEstimator.biasLoaded
                               ? nowMs - headingEstimator.lastBiasPersistMs
                               : nowMs - headingEstimator.biasDirtySinceMs;
  if (elapsed < requiredDelay) {
    return;
  }

  Preferences prefs;
  if (!imuTemperaturePlausible(headingEstimator.biasTemperatureC)) {
    return;
  }
  if (!prefs.begin("radarImu", false)) {
    return;
  }
  bool stored = prefs.putUInt("schema", kGyroBiasPrefsSchema) > 0;
  stored &= prefs.putFloat("biasX", headingEstimator.biasX) > 0;
  stored &= prefs.putFloat("biasY", headingEstimator.biasY) > 0;
  stored &= prefs.putFloat("biasZ", headingEstimator.biasZ) > 0;
  stored &= prefs.putFloat("biasTemp", headingEstimator.biasTemperatureC) > 0;
  prefs.end();
  if (!stored) {
    return;
  }

  headingEstimator.savedBiasX = headingEstimator.biasX;
  headingEstimator.savedBiasY = headingEstimator.biasY;
  headingEstimator.savedBiasZ = headingEstimator.biasZ;
  headingEstimator.savedBiasTemperatureC = headingEstimator.biasTemperatureC;
  headingEstimator.biasDirty = false;
  headingEstimator.biasDirtySinceMs = 0;
  headingEstimator.forceBiasPersistAfterStrictVerification = false;
  headingEstimator.biasLoaded = true;
  headingEstimator.lastBiasPersistMs = nowMs;
  Serial.println("QMI8658 gyro bias persisted.");
}

bool applyGyroBiasEstimate(float x, float y, float z, uint32_t nowMs) {
  if (!gyroBiasPlausible(x, y, z)) {
    return false;
  }

  const bool firstEstimate = !headingEstimator.biasValid;
  if (firstEstimate) {
    headingEstimator.biasX = x;
    headingEstimator.biasY = y;
    headingEstimator.biasZ = z;
    headingEstimator.biasValid = true;
    headingEstimator.relativeYawValid = false;
    headingDeg = 0.0f;
    Serial.print("QMI8658 gyro bias learned x=");
    Serial.print(x, 4);
    Serial.print(" y=");
    Serial.print(y, 4);
    Serial.print(" z=");
    Serial.println(z, 4);
  } else {
    headingEstimator.biasX = lerpf(headingEstimator.biasX, x, kGyroBiasBackgroundBlend);
    headingEstimator.biasY = lerpf(headingEstimator.biasY, y, kGyroBiasBackgroundBlend);
    headingEstimator.biasZ = lerpf(headingEstimator.biasZ, z, kGyroBiasBackgroundBlend);
  }
  if (imuTemperaturePlausible(headingEstimator.currentTemperatureC)) {
    headingEstimator.biasTemperatureC = headingEstimator.currentTemperatureC;
  }
  markGyroBiasDirty(nowMs);
  return true;
}

void updateGyroBiasEstimator(float accelMagnitudeG, uint32_t nowMs) {
  const float correctedX = gyr.x - (headingEstimator.biasValid ? headingEstimator.biasX : 0.0f);
  const float correctedY = gyr.y - (headingEstimator.biasValid ? headingEstimator.biasY : 0.0f);
  const float correctedZ = gyr.z - (headingEstimator.biasValid ? headingEstimator.biasZ : 0.0f);
  const float correctedMagnitude =
      sqrtf(correctedX * correctedX + correctedY * correctedY + correctedZ * correctedZ);
  const bool biasVerifiedForTemperature =
      headingEstimator.sessionStationaryVerified && gyroBiasTemperatureCompatible();
  const float gyroLimit = !headingEstimator.biasValid
                              ? kGyroStationaryBootstrapDps
                              : (biasVerifiedForTemperature
                                     ? kGyroStationaryCorrectedDps
                                     : kGyroStationaryWarmStartDps);
  headingEstimator.correctedGyroMagnitudeDps = correctedMagnitude;
  headingEstimator.stationaryGyroLimitDps = gyroLimit;
  const bool stationaryCandidate =
      isfinite(accelMagnitudeG) && isfinite(correctedMagnitude) &&
      fabsf(accelMagnitudeG - 1.0f) <= kStationaryAccelToleranceG &&
      correctedMagnitude <= gyroLimit;
  headingEstimator.stationaryCandidate = stationaryCandidate;
  if (!stationaryCandidate) {
    resetGyroStationaryWindow(true);
    return;
  }

  if (headingEstimator.stationaryWindowStartedMs == 0) {
    headingEstimator.stationaryWindowStartedMs = nowMs;
  }
  ++headingEstimator.stationarySamples;
  headingEstimator.gyroSumX += gyr.x;
  headingEstimator.gyroSumY += gyr.y;
  headingEstimator.gyroSumZ += gyr.z;
  headingEstimator.gyroSumSqX += static_cast<double>(gyr.x) * gyr.x;
  headingEstimator.gyroSumSqY += static_cast<double>(gyr.y) * gyr.y;
  headingEstimator.gyroSumSqZ += static_cast<double>(gyr.z) * gyr.z;

  if (nowMs - headingEstimator.stationaryWindowStartedMs < kGyroStationaryWindowMs ||
      headingEstimator.stationarySamples < kGyroStationaryMinSamples) {
    return;
  }

  const double inverseCount = 1.0 / headingEstimator.stationarySamples;
  const float meanX = static_cast<float>(headingEstimator.gyroSumX * inverseCount);
  const float meanY = static_cast<float>(headingEstimator.gyroSumY * inverseCount);
  const float meanZ = static_cast<float>(headingEstimator.gyroSumZ * inverseCount);
  const float stdDevX = sqrtf(fmaxf(
      0.0f, static_cast<float>(headingEstimator.gyroSumSqX * inverseCount - meanX * meanX)));
  const float stdDevY = sqrtf(fmaxf(
      0.0f, static_cast<float>(headingEstimator.gyroSumSqY * inverseCount - meanY * meanY)));
  const float stdDevZ = sqrtf(fmaxf(
      0.0f, static_cast<float>(headingEstimator.gyroSumSqZ * inverseCount - meanZ * meanZ)));
  const float maxStdDev = fmaxf(stdDevX, fmaxf(stdDevY, stdDevZ));
  headingEstimator.lastStationaryMaxStdDevDps = maxStdDev;
  headingEstimator.stationary = maxStdDev <= kGyroStationaryStdDevDps;
  if (headingEstimator.stationary) {
    const bool firstSessionVerification = !headingEstimator.sessionStationaryVerified;
    // Capture this before applyGyroBiasEstimate updates biasTemperatureC. A
    // loaded bias rejected for temperature must persist its first strict
    // replacement immediately; later background refinements keep the normal
    // five-minute NVS wear guard.
    const bool persistTemperatureRevalidatedBiasImmediately =
        firstSessionVerification && headingEstimator.biasLoaded &&
        !gyroBiasTemperatureCompatible();
    headingEstimator.stationary = applyGyroBiasEstimate(meanX, meanY, meanZ, nowMs);
    if (headingEstimator.stationary) {
      headingEstimator.forceBiasPersistAfterStrictVerification =
          headingEstimator.forceBiasPersistAfterStrictVerification ||
          persistTemperatureRevalidatedBiasImmediately;
      headingEstimator.sessionStationaryVerified = true;
      headingEstimator.sessionTrustFromStoredBias = false;
      if (firstSessionVerification) {
        headingDeg = 0.0f;
        headingEstimator.relativeYawValid = false;
      }
    }
  }
  resetGyroStationaryWindow(!headingEstimator.stationary);
}

bool normalizeGravityEstimate() {
  const float magnitude = sqrtf(
      headingEstimator.gravityX * headingEstimator.gravityX +
      headingEstimator.gravityY * headingEstimator.gravityY +
      headingEstimator.gravityZ * headingEstimator.gravityZ);
  if (!isfinite(magnitude) || magnitude < 0.25f) {
    headingEstimator.gravityValid = false;
    return false;
  }
  headingEstimator.gravityX /= magnitude;
  headingEstimator.gravityY /= magnitude;
  headingEstimator.gravityZ /= magnitude;
  headingEstimator.gravityValid = true;
  return true;
}

bool updateGravityEstimate(float dtS, uint32_t nowMs) {
  const float accelMagnitude = sqrtf(acc.x * acc.x + acc.y * acc.y + acc.z * acc.z);
  headingEstimator.accelMagnitudeG = accelMagnitude;
  const bool accelFinite = isfinite(accelMagnitude) && accelMagnitude >= 0.25f;
  const bool suitableForGravity = accelFinite &&
                                  fabsf(accelMagnitude - 1.0f) <= kGravityUpdateToleranceG;

  // Propagate the world-gravity direction in body coordinates using
  // g_dot = g x omega. This follows fast tilt without accelerometer lag.
  if (headingEstimator.gravityValid && headingEstimator.biasValid &&
      dtS > 0.0f && dtS <= kImuMaxIntegrationDtS) {
    const float omegaX = degToRad(gyr.x - headingEstimator.biasX);
    const float omegaY = degToRad(gyr.y - headingEstimator.biasY);
    const float omegaZ = degToRad(gyr.z - headingEstimator.biasZ);
    const float oldX = headingEstimator.gravityX;
    const float oldY = headingEstimator.gravityY;
    const float oldZ = headingEstimator.gravityZ;
    headingEstimator.gravityX += (oldY * omegaZ - oldZ * omegaY) * dtS;
    headingEstimator.gravityY += (oldZ * omegaX - oldX * omegaZ) * dtS;
    headingEstimator.gravityZ += (oldX * omegaY - oldY * omegaX) * dtS;
    normalizeGravityEstimate();
  }

  // Accelerometer only supplies a low-gain correction when its magnitude is
  // gravity-like, so linear acceleration cannot immediately rotate the estimate.
  if (suitableForGravity) {
    const float measuredX = acc.x / accelMagnitude;
    const float measuredY = acc.y / accelMagnitude;
    const float measuredZ = acc.z / accelMagnitude;
    if (!headingEstimator.gravityValid) {
      headingEstimator.gravityX = measuredX;
      headingEstimator.gravityY = measuredY;
      headingEstimator.gravityZ = measuredZ;
      headingEstimator.gravityValid = true;
    } else {
      const float safeDt = dtS > 0.0f && dtS <= kImuMaxIntegrationDtS ? dtS : 0.018f;
      const float alpha = clampf(
          safeDt / (kGravityAccelCorrectionTimeConstantS + safeDt), 0.002f, 0.05f);
      headingEstimator.gravityX = lerpf(headingEstimator.gravityX, measuredX, alpha);
      headingEstimator.gravityY = lerpf(headingEstimator.gravityY, measuredY, alpha);
      headingEstimator.gravityZ = lerpf(headingEstimator.gravityZ, measuredZ, alpha);
      normalizeGravityEstimate();
    }
  }

  if (accelFinite && fabsf(accelMagnitude - 1.0f) <= kGravityReliableToleranceG) {
    headingEstimator.lastGravityReliableMs = nowMs;
  }
  return headingEstimator.gravityValid &&
         headingEstimator.lastGravityReliableMs > 0 &&
         nowMs - headingEstimator.lastGravityReliableMs <= kGravityReliableHoldMs;
}

void refreshHeadingQuality(uint32_t nowMs, bool sampleHealthy) {
  if (!imuOnline) {
    headingEstimator.quality = HeadingQuality::Unavailable;
  } else if (imuDiagnostics.currentGapMs >= kImuUnavailableAfterMs) {
    headingEstimator.quality = HeadingQuality::Unavailable;
  } else if (!headingEstimator.biasValid) {
    headingEstimator.quality = HeadingQuality::Calibrating;
  } else if (!headingEstimator.sessionStationaryVerified ||
             !gyroBiasTemperatureCompatible() ||
             !headingEstimator.relativeYawValid || !sampleHealthy ||
             headingEstimator.lastSampleMs == 0 ||
             nowMs - headingEstimator.lastSampleMs > kImuSampleFreshMs) {
    headingEstimator.quality = HeadingQuality::RelativeDegraded;
  } else {
    headingEstimator.quality = HeadingQuality::RelativeStable;
  }
}

void invalidateRelativeHeading(bool clearSessionTrust) {
  invalidateHeadingAlignment();
  headingDeg = 0.0f;
  lastImuMicros = 0;
  headingEstimator.relativeYawValid = false;
  if (clearSessionTrust) {
    headingEstimator.sessionStationaryVerified = false;
    headingEstimator.sessionTrustFromStoredBias = false;
  }
  headingEstimator.gravityValid = false;
  headingEstimator.verticalRateDps = 0.0f;
  headingEstimator.lastSampleMs = 0;
  headingEstimator.lastGravityReliableMs = 0;
  resetGyroStationaryWindow(true);
  headingEstimator.quality = HeadingQuality::Unavailable;
}

void setupImu() {
  imuOnline = qmi.begin(Wire, QMI8658_L_SLAVE_ADDRESS, -1, -1);
  if (!imuOnline) {
    invalidateRelativeHeading();
    Serial.println("QMI8658 offline; radar remains north-up.");
    return;
  }

  qmi.configAccelerometer(SensorQMI8658::ACC_RANGE_4G,
                          SensorQMI8658::ACC_ODR_250Hz,
                          SensorQMI8658::LPF_MODE_0);
  qmi.configGyroscope(SensorQMI8658::GYR_RANGE_512DPS,
                      SensorQMI8658::GYR_ODR_224_2Hz,
                      SensorQMI8658::LPF_MODE_0);
  qmi.enableAccelerometer();
  qmi.enableGyroscope();
  updateImuTemperature(millis(), true);
  loadGyroBias();
  imuDiagnostics.gapStartedMs = millis();
  lastImuMicros = micros();
  refreshHeadingQuality(millis(), false);
}

void readImu() {
  const uint32_t nowMs = millis();
  if (!imuOnline) {
    refreshHeadingQuality(nowMs, false);
    return;
  }
  if (!qmi.getDataReady()) {
    ++imuDiagnostics.dataNotReadyCount;
    const uint32_t gapMs = noteImuGap(nowMs, ImuGapCause::DataNotReady);
    if (gapMs > kImuSampleFreshMs) {
      refreshHeadingQuality(nowMs, false);
    }
    persistGyroBiasIfDue(nowMs);
    return;
  }

  const uint32_t nowMicros = micros();
  const uint32_t elapsedMicros = lastImuMicros == 0 ? 0 : nowMicros - lastImuMicros;
  lastImuMicros = nowMicros;
  const float dtS = elapsedMicros / 1000000.0f;
  const bool integrationDtValid = dtS > 0.0f && dtS <= kImuMaxIntegrationDtS;
  if (elapsedMicros > kImuMaxIntegrationGapMs * 1000U) {
    // This also catches a blocked main loop when the first resumed call already
    // has a ready sample. Record and evaluate the outage before clearing it as
    // healthy below, then anchor the next interval at this resumed sample.
    noteImuGap(nowMs, ImuGapCause::MainLoopDelay);
    lastImuMicros = nowMicros;
  }

  const bool gyroRead = qmi.getGyroscope(gyr.x, gyr.y, gyr.z);
  const bool accelRead = qmi.getAccelerometer(acc.x, acc.y, acc.z);
  if (!gyroRead || !accelRead) {
    imuDiagnostics.gyroscopeReadFailureCount += gyroRead ? 0 : 1;
    imuDiagnostics.accelerometerReadFailureCount += accelRead ? 0 : 1;
    const ImuGapCause cause = !gyroRead && !accelRead
                                  ? ImuGapCause::GyroscopeAndAccelerometerRead
                              : !gyroRead ? ImuGapCause::GyroscopeRead
                                          : ImuGapCause::AccelerometerRead;
    noteImuGap(nowMs, cause);
    refreshHeadingQuality(nowMs, false);
    return;
  }
  noteHealthyImuSample(nowMs);

  tiltVectorX = lerpf(tiltVectorX, acc.x, 0.12f);
  tiltVectorY = lerpf(tiltVectorY, acc.y, 0.12f);
  const float motionEnergy = fabsf(acc.x) + fabsf(acc.y) + fabsf(acc.z - 1.0f);
  tiltEnergy = clampf(lerpf(tiltEnergy, motionEnergy, 0.12f), 0.0f, 3.0f);

  const bool gravityReliable = updateGravityEstimate(dtS, nowMs);
  updateGyroBiasEstimator(headingEstimator.accelMagnitudeG, nowMs);

  bool integrated = false;
  if (headingEstimator.biasValid && headingEstimator.gravityValid && integrationDtValid) {
    const float correctedX = gyr.x - headingEstimator.biasX;
    const float correctedY = gyr.y - headingEstimator.biasY;
    const float correctedZ = gyr.z - headingEstimator.biasZ;
    float verticalRate = correctedX * headingEstimator.gravityX +
                         correctedY * headingEstimator.gravityY +
                         correctedZ * headingEstimator.gravityZ;
    if (fabsf(verticalRate) < kRelativeYawRateDeadbandDps) {
      verticalRate = 0.0f;
    }
    headingEstimator.verticalRateDps = verticalRate;
    headingDeg = wrap360(headingDeg + verticalRate * dtS);
    headingEstimator.relativeYawValid = true;
    integrated = true;
  }

  refreshHeadingQuality(nowMs, integrated && gravityReliable);
  updateImuTemperature(nowMs, false);
  persistGyroBiasIfDue(nowMs);
}

void printTouchDiagnostic(int16_t x, int16_t y, const char *action) {
  if (!kSerialDiagnostics) {
    return;
  }
  Serial.print("DIAG touch x=");
  Serial.print(x);
  Serial.print(" y=");
  Serial.print(y);
  Serial.print(" action=");
  Serial.println(action);
}

void handleTouch(int16_t x, int16_t y) {
  printTouchDiagnostic(x, y, "ignored");
}

constexpr SystemMenuItem kSystemMenuItems[] = {
    SystemMenuItem::Sleep,
    SystemMenuItem::Standby,
    SystemMenuItem::Off,
    SystemMenuItem::Info,
    SystemMenuItem::Reset,
    SystemMenuItem::Volume,
    SystemMenuItem::Brightness,
    SystemMenuItem::Direction,
};
constexpr uint8_t kSystemMenuItemCount = sizeof(kSystemMenuItems) / sizeof(kSystemMenuItems[0]);

uint8_t systemMenuItemIndex(SystemMenuItem item) {
  for (uint8_t index = 0; index < kSystemMenuItemCount; ++index) {
    if (kSystemMenuItems[index] == item) {
      return index;
    }
  }
  return 0;
}

void stepSystemMenu(int8_t direction) {
  const uint32_t now = millis();
  const int currentIndex = systemMenuItemIndex(systemMenuSelectedItem);
  const int nextIndex = (currentIndex + direction + kSystemMenuItemCount) % kSystemMenuItemCount;
  systemMenuSelectedItem = kSystemMenuItems[nextIndex];
  systemMenuFlashItem = systemMenuSelectedItem;
  settingsFlashUntilMs = now + 360;
  systemMenuLastInteractionMs = now;
  systemMenuPageTransitionDirection = direction < 0 ? -1 : 1;
  systemMenuPageTransitionStartedMs = now;
  systemMenuPageTransitionUntilMs = now + kSystemMenuPageTransitionMs;
}

SystemMenuFeedbackTarget systemMenuFeedbackTargetAt(int16_t x, int16_t y) {
  if (x <= kSystemMenuEdgeTapWidthPx) {
    return SystemMenuFeedbackTarget::Previous;
  }
  if (x >= kScreenW - kSystemMenuEdgeTapWidthPx) {
    return SystemMenuFeedbackTarget::Next;
  }
  const int dx = x - kCx;
  const int dy = y - kSystemMenuActionCenterY;
  if (dx * dx + dy * dy <= kSystemMenuActionRadius * kSystemMenuActionRadius) {
    return SystemMenuFeedbackTarget::Action;
  }
  return SystemMenuFeedbackTarget::None;
}

void startSystemMenuControlFeedback(SystemMenuFeedbackTarget target, uint32_t now) {
  systemMenuFeedbackTarget = target;
  systemMenuControlFeedbackStartedMs = now;
  systemMenuControlFeedbackUntilMs = target == SystemMenuFeedbackTarget::None
                                       ? 0
                                       : now + kSystemMenuControlFeedbackMs;
}

bool handleSystemMenuSwipe(int16_t startX, int16_t startY, int16_t endX, int16_t endY) {
  const int dx = endX - startX;
  const int dy = endY - startY;
  if (abs(dx) < kSystemMenuSwipeThresholdPx || abs(dx) <= abs(dy) + 16) {
    return false;
  }
  const int8_t direction = dx < 0 ? 1 : -1;
  stepSystemMenu(direction);
  startSystemMenuControlFeedback(direction < 0 ? SystemMenuFeedbackTarget::Previous
                                                : SystemMenuFeedbackTarget::Next,
                                 millis());
  return true;
}

bool touchInPowerConfirmControl(int16_t x, int16_t y) {
  const int dx = x - kCx;
  const int dy = y - kCy;
  constexpr int kConfirmRadius = 92;
  return dx * dx + dy * dy <= kConfirmRadius * kConfirmRadius;
}

void activateSystemMenuItem(SystemMenuItem item) {
  systemMenuFlashItem = item;
  settingsFlashUntilMs = millis() + 620;
  switch (item) {
    case SystemMenuItem::Sleep:
      enterScreenOff();
      break;
    case SystemMenuItem::Standby:
      enterStandby();
      break;
    case SystemMenuItem::Off:
      setRadarUiMode(RadarUiMode::PowerConfirm);
      break;
    case SystemMenuItem::Info:
      setRadarUiMode(RadarUiMode::Info);
      break;
    case SystemMenuItem::Reset:
      setRadarUiMode(RadarUiMode::FactoryResetConfirm);
      break;
    case SystemMenuItem::Volume:
      cycleAudioGain();
      systemMenuFlashItem = item;
      systemMenuLastInteractionMs = millis();
      break;
    case SystemMenuItem::Brightness:
      cycleBrightness();
      systemMenuFlashItem = item;
      systemMenuLastInteractionMs = millis();
      break;
    case SystemMenuItem::Direction:
      toggleScreenDirection();
      systemMenuFlashItem = item;
      systemMenuLastInteractionMs = millis();
      break;
    default:
      break;
  }
}

void handleSystemMenuTap(int16_t x, int16_t y) {
  lastUserInputMs = millis();
  systemMenuLastInteractionMs = lastUserInputMs;
  if (x <= kSystemMenuEdgeTapWidthPx) {
    stepSystemMenu(-1);
    return;
  }
  if (x >= kScreenW - kSystemMenuEdgeTapWidthPx) {
    stepSystemMenu(1);
    return;
  }

  const int actionDx = x - kCx;
  const int actionDy = y - kSystemMenuActionCenterY;
  if (actionDx * actionDx + actionDy * actionDy <=
      kSystemMenuActionRadius * kSystemMenuActionRadius) {
    activateSystemMenuItem(systemMenuSelectedItem);
    return;
  }
}

float touchAngleDeg(int16_t x, int16_t y) {
  return atan2f(static_cast<float>(y - kCy), static_cast<float>(x - kCx)) * 180.0f / kPi;
}

bool touchInEdgeGestureRing(int16_t x, int16_t y) {
  const int dx = x - kCx;
  const int dy = y - kCy;
  const int d2 = dx * dx + dy * dy;
  constexpr int kInner = 142;
  const int outer = kRadarGridRadius + 18;
  return d2 >= kInner * kInner && d2 <= outer * outer;
}

void resetEdgeGesture() {
  edgeGestureActive = false;
  edgeGestureLastAngle = 0.0f;
}

void handleEdgeGesture(int16_t x, int16_t y, uint32_t now) {
  if (!touchInEdgeGestureRing(x, y)) {
    if (edgeGestureActive && touchWasPressed) {
      const int totalDx = x - touchStartX;
      const int totalDy = y - touchStartY;
      if (totalDx * totalDx + totalDy * totalDy >=
          kEdgeGestureActivationPx * kEdgeGestureActivationPx) {
        headingCalibrationGestureCancelled = true;
      }
    }
    if (!edgeGestureConsumed) {
      resetEdgeGesture();
    }
    return;
  }

  if (bootStartedMs > 0 && now - bootStartedMs < kBootDurationMs) {
    bootStartedMs = now - kBootDurationMs;
    radarStartedMs = now;
  }

  const float angle = touchAngleDeg(x, y);
  if (touchWasPressed) {
    const int totalDx = x - touchStartX;
    const int totalDy = y - touchStartY;
    if (totalDx * totalDx + totalDy * totalDy >=
        kEdgeGestureActivationPx * kEdgeGestureActivationPx) {
      // Crossing the edge-drag threshold cancels calibration even before the
      // angular delta is large enough to alter the zoom.
      headingCalibrationGestureCancelled = true;
    }
  }
  if (!edgeGestureActive) {
    edgeGestureActive = true;
    edgeGestureLastAngle = angle;
    return;
  }

  if (!edgeGestureConsumed && touchWasPressed) {
    const int totalDx = x - touchStartX;
    const int totalDy = y - touchStartY;
    if (totalDx * totalDx + totalDy * totalDy <
        kEdgeGestureActivationPx * kEdgeGestureActivationPx) {
      return;
    }
  }

  const float delta = shortestAngleDelta(edgeGestureLastAngle, angle);
  edgeGestureLastAngle = angle;
  if (fabsf(delta) < 0.6f || fabsf(delta) > 55.0f) {
    return;
  }

  edgeGestureConsumed = true;
  headingCalibrationGestureCancelled = true;
  touchLongHandled = true;
  const float oldScale = gridGestureScale;
  gridGestureScale = clampGridGestureScale(gridGestureScale * expf(delta * 0.007f));
  if (fabsf(gridGestureScale - oldScale) > 0.01f) {
    zoomFlashUntilMs = now + 260;
  }
}

void setupButtons() {
#if BUTTON_BOOT >= 0
  pinMode(BUTTON_BOOT, INPUT_PULLUP);
#endif
#if BUTTON_ALT >= 0
  pinMode(BUTTON_ALT, INPUT_PULLUP);
#endif
}

void pollButtons() {
  const uint32_t now = millis();
#if BUTTON_BOOT >= 0
  const bool pressed = digitalRead(BUTTON_BOOT) == LOW;

  if (pressed && !bootButtonWasPressed) {
    lastUserInputMs = now;
    bootButtonPressedAtMs = now;
    bootButtonLongHandled = false;
    bootTapPressedMs = now;
    bootTapReleasedMs = 0;
  }

  if (pressed && !bootButtonLongHandled && bootButtonPressedAtMs > 0 &&
      now - bootButtonPressedAtMs >= kButtonLongPressMs) {
    bootButtonLongHandled = true;
    lastButtonMs = now;
    if (radarUiMode == RadarUiMode::Standby) {
      wakeRadarDisplay();
    } else {
      if (radarUiMode == RadarUiMode::ScreenOff || radarUiOverlayActive()) {
        wakeRadarDisplay();
      }
      beginPushToTalk();
    }
  }

  if (!pressed && bootButtonWasPressed) {
    const uint32_t heldMs = bootButtonPressedAtMs > 0 ? now - bootButtonPressedAtMs : 0;
    if (bootButtonLongHandled && voiceCapture.pttActive) {
      endPushToTalk();
      lastButtonMs = now;
    } else if (!bootButtonLongHandled && heldMs >= kButtonDebounceMs && now - lastButtonMs > 160) {
      lastButtonMs = now;
      bootTapReleasedMs = now;
      handleBootShortPress();
    }
    bootButtonPressedAtMs = 0;
    bootButtonLongHandled = false;
  }

  bootButtonWasPressed = pressed;
#endif

#if BUTTON_ALT >= 0
  const bool altPressed = digitalRead(BUTTON_ALT) == LOW;

  if (altPressed && !altButtonWasPressed) {
    altButtonPressedAtMs = now;
    altButtonLongHandled = false;
    altTapPressedMs = now;
    altTapReleasedMs = 0;
  }

  if (altPressed && !altButtonLongHandled && altButtonPressedAtMs > 0 &&
      now - altButtonPressedAtMs >= kButtonLongPressMs) {
    altButtonLongHandled = true;
    lastButtonMs = now;
  }

  if (!altPressed && altButtonWasPressed) {
    const uint32_t heldMs = altButtonPressedAtMs > 0 ? now - altButtonPressedAtMs : 0;
    if (!altButtonLongHandled && heldMs >= kButtonDebounceMs && now - lastButtonMs > 160) {
      lastButtonMs = now;
      altTapReleasedMs = now;
      toggleSystemMenu();
    }
    altButtonPressedAtMs = 0;
    altButtonLongHandled = false;
  }

  altButtonWasPressed = altPressed;
#endif
}

void handleNorthCalibrationTouch(int16_t x, int16_t y, uint32_t now) {
  if (!touchWasPressed) {
    touchWasPressed = true;
    touchPressedAtMs = now;
    touchLongHandled = false;
    headingCalibrationGestureCancelled = false;
    headingCalibrationHoldWaitFeedback = HeadingAlignmentFeedback::None;
    if (headingAlignmentFeedback == HeadingAlignmentFeedback::ImuWait ||
        headingAlignmentFeedback == HeadingAlignmentFeedback::HoldStill) {
      setHeadingAlignmentFeedback(HeadingAlignmentFeedback::None, now);
    }
    touchStartX = x;
    touchStartY = y;
    lastUserInputMs = now;
  }

  touchLastX = x;
  touchLastY = y;
  const int dx = touchLastX - touchStartX;
  const int dy = touchLastY - touchStartY;
  if (dx * dx + dy * dy >
      kHeadingCalibrationMoveTolerancePx * kHeadingCalibrationMoveTolerancePx) {
    // A drag is not a calibration gesture. Keep it cancelled until release so
    // an edge-scale gesture cannot become a calibration after it stops moving.
    headingCalibrationGestureCancelled = true;
  }

  // Physical hold time must never be reset by IMU readiness. Otherwise a real
  // long hold during startup is later misclassified as a dismissing tap.
  if (!headingCalibrationGestureCancelled && !touchLongHandled &&
      touchPressedAtMs > 0 && now - touchPressedAtMs >= kHeadingCalibrationHoldMs) {
    touchLongHandled = true;
  }

  if (!headingCalibrationGestureCancelled && touchLongHandled) {
    HeadingAlignmentFeedback waitFeedback = HeadingAlignmentFeedback::None;
    const char *waitReason = nullptr;
    if (!headingCalibrationImuReady(now)) {
      waitFeedback = headingCalibrationNotReadyFeedback(now);
      waitReason = waitFeedback == HeadingAlignmentFeedback::HoldStill
                       ? "stationary_bias_pending_hold"
                       : "imu_not_ready_hold";
    } else if (fabsf(headingEstimator.verticalRateDps) > kHeadingAlignmentMaxYawRateDps) {
      waitFeedback = HeadingAlignmentFeedback::HoldStill;
      waitReason = "motion_hold";
    }

    if (waitFeedback != HeadingAlignmentFeedback::None) {
      if (headingCalibrationHoldWaitFeedback != waitFeedback) {
        rejectHeadingAlignment(waitFeedback, waitReason);
        headingCalibrationHoldWaitFeedback = waitFeedback;
      } else {
        // Keep the user-visible wait state alive for as long as this same
        // consumed long hold remains on screen, without repeating DIAG logs.
        setHeadingAlignmentFeedback(waitFeedback, now);
      }
      return;
    }

    headingCalibrationHoldWaitFeedback = HeadingAlignmentFeedback::None;
    if (attemptNorthHeadingAlignment()) {
      ignoreTouchUntilRelease = true;
      touchWasPressed = false;
      touchPressedAtMs = 0;
      headingCalibrationGestureCancelled = false;
      headingCalibrationHoldWaitFeedback = HeadingAlignmentFeedback::None;
      resetEdgeGesture();
    }
  }
}

void pollTouch() {
  if (!touchOnline) {
    return;
  }

  static uint32_t lastPoll = 0;
  const uint32_t now = millis();
  if (!touchIrq && now - lastPoll < 80) {
    return;
  }
  lastPoll = now;
  touchIrq = false;

  int16_t x[5] = {0};
  int16_t y[5] = {0};
  const uint8_t count = touch.getPoint(x, y, touch.getSupportTouchPoint());
  for (uint8_t index = 0; index < count; ++index) {
    x[index] = DragonRadarDisplayOrientation::logicalTouchCoordinate(
        x[index], kScreenW, screenDirection);
    y[index] = DragonRadarDisplayOrientation::logicalTouchCoordinate(
        y[index], kScreenH, screenDirection);
  }

  if (ignoreTouchUntilRelease) {
    if (count == 0) {
      ignoreTouchUntilRelease = false;
    }
    return;
  }

  if (radarUiMode == RadarUiMode::ScreenOff) {
    if (count > 0) {
      wakeRadarDisplay();
      ignoreTouchUntilRelease = true;
    }
    return;
  }

  if (radarUiMode == RadarUiMode::Standby) {
    if (count > 0) {
      touchLastX = x[0];
      touchLastY = y[0];
      if (!touchWasPressed) {
        touchWasPressed = true;
        touchPressedAtMs = now;
      } else if (touchPressedAtMs > 0 && now - touchPressedAtMs >= kStandbyTouchWakeMs) {
        wakeRadarDisplay();
        ignoreTouchUntilRelease = true;
      }
    } else {
      touchWasPressed = false;
      touchPressedAtMs = 0;
    }
    return;
  }

  if (radarUiMode == RadarUiMode::PowerConfirm ||
      radarUiMode == RadarUiMode::FactoryResetConfirm) {
    const bool factoryReset = radarUiMode == RadarUiMode::FactoryResetConfirm;
    if (count > 0) {
      touchLastX = x[0];
      touchLastY = y[0];
      if (!touchInPowerConfirmControl(touchLastX, touchLastY)) {
        powerConfirmPressedAtMs = 0;
        touchWasPressed = true;
        return;
      }
      if (!touchWasPressed || powerConfirmPressedAtMs == 0) {
        touchWasPressed = true;
        touchPressedAtMs = now;
        powerConfirmPressedAtMs = now;
        lastUserInputMs = now;
      }
      const uint32_t requiredHoldMs = factoryReset ? kFactoryResetConfirmHoldMs
                                                   : kPowerConfirmHoldMs;
      if (now - powerConfirmPressedAtMs >= requiredHoldMs) {
        if (factoryReset) {
          clearProvisioningAndRestart();
        } else {
          beginShutdownFallback();
        }
      }
      return;
    }

    if (touchWasPressed) {
      setRadarUiMode(RadarUiMode::SystemMenu);
    }
    return;
  }

  if (radarUiMode == RadarUiMode::Main) {
    if (!northCalibrationInteractive(now)) {
      resetUiInputState();
      return;
    }
    if (count > 0) {
      if (!touchWasPressed) {
        // Establish the touch origin first; one fresh sample cannot satisfy
        // the 1.2-second calibration hold.
        handleNorthCalibrationTouch(x[0], y[0], now);
      } else {
        touchLastX = x[0];
        touchLastY = y[0];
      }
      handleEdgeGesture(x[0], y[0], now);
      if (ignoreTouchUntilRelease || headingCalibrationGestureCancelled ||
          edgeGestureConsumed) {
        return;
      }
      handleNorthCalibrationTouch(x[0], y[0], now);
      return;
    }

    const uint32_t releasedHeldMs =
        touchWasPressed && touchPressedAtMs > 0 ? now - touchPressedAtMs : 0;
    if (touchWasPressed && !touchLongHandled && !edgeGestureConsumed &&
        !headingCalibrationGestureCancelled &&
        releasedHeldMs >= kHeadingCalibrationHoldMs) {
      // Touch sampling is not continuous. A release can arrive just after the
      // 1.2 s boundary but before another positive sample had a chance to arm
      // the hold. Consume it as a long hold and evaluate the final posture.
      touchLongHandled = true;
      if (!headingCalibrationImuReady(now)) {
        const HeadingAlignmentFeedback feedback =
            headingCalibrationNotReadyFeedback(now);
        rejectHeadingAlignment(
            feedback,
            feedback == HeadingAlignmentFeedback::HoldStill
                ? "stationary_bias_pending_release"
                : "imu_not_ready_release");
      } else if (fabsf(headingEstimator.verticalRateDps) >
                 kHeadingAlignmentMaxYawRateDps) {
        rejectHeadingAlignment(HeadingAlignmentFeedback::HoldStill,
                               "motion_release");
      } else {
        attemptNorthHeadingAlignment();
      }
    }

    if (touchWasPressed && !touchLongHandled && !edgeGestureConsumed &&
        !headingCalibrationGestureCancelled) {
      // The only startup guide is dismissible by a normal tap. Recalibration
      // remains available on every later stationary 1.2-second screen hold.
      if (headingCalibrationPromptVisible && kSerialDiagnostics) {
        Serial.println("DIAG heading_prompt action=dismiss reason=screen_tap");
      }
      headingCalibrationPromptVisible = false;
    }
    resetEdgeGesture();
    edgeGestureConsumed = false;
    touchWasPressed = false;
    touchPressedAtMs = 0;
    touchLongHandled = false;
    headingCalibrationGestureCancelled = false;
    headingCalibrationHoldWaitFeedback = HeadingAlignmentFeedback::None;
    return;
  }

  if (count > 0) {
    if (radarUiMode == RadarUiMode::SystemMenu || radarUiMode == RadarUiMode::Info) {
      touchLastX = x[0];
      touchLastY = y[0];
      if (!touchWasPressed) {
        touchWasPressed = true;
        touchPressedAtMs = now;
        touchStartX = touchLastX;
        touchStartY = touchLastY;
        lastUserInputMs = now;
        systemMenuLastInteractionMs = now;
      }
      return;
    }

    handleEdgeGesture(x[0], y[0], now);
    if (edgeGestureConsumed || edgeGestureActive) {
      return;
    }
    touchLastX = x[0];
    touchLastY = y[0];
    if (!touchWasPressed) {
      touchWasPressed = true;
      touchPressedAtMs = now;
      touchLongHandled = false;
      touchStartX = touchLastX;
      touchStartY = touchLastY;
    }
    return;
  }

  resetEdgeGesture();
  if (radarUiMode == RadarUiMode::SystemMenu || radarUiMode == RadarUiMode::Info) {
    if (touchWasPressed) {
      const uint32_t heldMs = touchPressedAtMs > 0 ? now - touchPressedAtMs : 0;
      if (heldMs >= kButtonDebounceMs) {
        if (radarUiMode == RadarUiMode::SystemMenu) {
          if (!handleSystemMenuSwipe(touchStartX, touchStartY, touchLastX, touchLastY)) {
            startSystemMenuControlFeedback(systemMenuFeedbackTargetAt(touchLastX, touchLastY), now);
            handleSystemMenuTap(touchLastX, touchLastY);
          }
        } else {
          setRadarUiMode(RadarUiMode::SystemMenu);
        }
      }
    }
    touchWasPressed = false;
    touchPressedAtMs = 0;
    touchLongHandled = false;
    edgeGestureConsumed = false;
    return;
  }

  if (edgeGestureConsumed) {
    edgeGestureConsumed = false;
    touchWasPressed = false;
    touchPressedAtMs = 0;
    touchLongHandled = false;
    return;
  }

  if (touchWasPressed) {
    const uint32_t heldMs = touchPressedAtMs > 0 ? now - touchPressedAtMs : 0;
    if (!touchLongHandled && heldMs >= kButtonDebounceMs) {
      handleTouch(touchLastX, touchLastY);
    }
    touchWasPressed = false;
    touchPressedAtMs = 0;
    touchLongHandled = false;
  }
}

String jsonEscape(const String &value) {
  String out;
  out.reserve(value.length() + 8);
  for (size_t i = 0; i < value.length(); ++i) {
    const char c = value[i];
    if (c == '"' || c == '\\') {
      out += '\\';
    }
    if (c == '\n' || c == '\r') {
      out += ' ';
    } else {
      out += c;
    }
  }
  return out;
}

bool extractJsonStringValue(const String &json, const char *key, String &out) {
  const String needle = String("\"") + key + "\"";
  int pos = json.indexOf(needle);
  if (pos < 0) {
    return false;
  }
  pos = json.indexOf(':', pos + needle.length());
  if (pos < 0) {
    return false;
  }
  pos = json.indexOf('"', pos + 1);
  if (pos < 0) {
    return false;
  }

  out = "";
  bool escaped = false;
  for (int i = pos + 1; i < json.length(); ++i) {
    const char c = json[i];
    if (escaped) {
      out += c;
      escaped = false;
      continue;
    }
    if (c == '\\') {
      escaped = true;
      continue;
    }
    if (c == '"') {
      return true;
    }
    out += c;
  }
  return false;
}

bool extractJsonIntValue(const String &json, const char *key, int32_t &out) {
  const String needle = String("\"") + key + "\"";
  int pos = json.indexOf(needle);
  if (pos < 0) {
    return false;
  }
  pos = json.indexOf(':', pos + needle.length());
  if (pos < 0) {
    return false;
  }
  ++pos;
  while (pos < json.length() && (json[pos] == ' ' || json[pos] == '\t')) {
    ++pos;
  }

  bool negative = false;
  if (pos < json.length() && json[pos] == '-') {
    negative = true;
    ++pos;
  }

  int64_t value = 0;
  bool foundDigit = false;
  while (pos < json.length() && json[pos] >= '0' && json[pos] <= '9') {
    foundDigit = true;
    value = value * 10 + (json[pos] - '0');
    ++pos;
  }
  if (!foundDigit) {
    return false;
  }

  if (negative) {
    value = -value;
  }
  out = static_cast<int32_t>(value);
  return true;
}

bool extractJsonBoolValue(const String &json, const char *key, bool &out) {
  const String needle = String("\"") + key + "\"";
  int pos = json.indexOf(needle);
  if (pos < 0) {
    return false;
  }
  pos = json.indexOf(':', pos + needle.length());
  if (pos < 0) {
    return false;
  }
  ++pos;
  while (pos < json.length() &&
         (json[pos] == ' ' || json[pos] == '\t' || json[pos] == '\n' || json[pos] == '\r')) {
    ++pos;
  }
  if (json.startsWith("true", pos) || json.startsWith("1", pos)) {
    out = true;
    return true;
  }
  if (json.startsWith("false", pos) || json.startsWith("0", pos)) {
    out = false;
    return true;
  }
  return false;
}

void noteRelayServerTime(const String &json) {
  int32_t serverTime = 0;
  if (!extractJsonIntValue(json, "server_time", serverTime) || serverTime <= 0) {
    return;
  }
  relayServerUnixTime = static_cast<uint32_t>(serverTime);
  relayServerTimeReceivedMs = millis();
}

bool sourceAgeFromUnixTime(uint32_t sampleUnixTime, uint32_t nowMs,
                           uint32_t &sourceAgeMs) {
  if (sampleUnixTime == 0 || relayServerUnixTime == 0 ||
      relayServerTimeReceivedMs == 0) {
    return false;
  }
  const uint32_t elapsedServerS =
      static_cast<uint32_t>(nowMs - relayServerTimeReceivedMs) / 1000U;
  const uint64_t estimatedServerUnix =
      static_cast<uint64_t>(relayServerUnixTime) + elapsedServerS;
  if (static_cast<uint64_t>(sampleUnixTime) >
      estimatedServerUnix + kHeadingAlignmentMaxClockSkewS) {
    return false;
  }
  const uint64_t ageS = estimatedServerUnix > sampleUnixTime
                            ? estimatedServerUnix - sampleUnixTime
                            : 0;
  sourceAgeMs = ageS > UINT32_MAX / 1000ULL
                    ? UINT32_MAX
                    : static_cast<uint32_t>(ageS * 1000ULL);
  return true;
}

bool currentFrameSourceAgeMs(const RemoteLocationFrame &frame, uint32_t nowMs,
                             uint32_t &sourceAgeMs) {
  if (!frame.sourceAgeKnown || frame.receivedMs == 0) {
    return false;
  }
  const uint64_t currentAgeMs =
      static_cast<uint64_t>(frame.sourceAgeMs) +
      static_cast<uint32_t>(nowMs - frame.receivedMs);
  sourceAgeMs = currentAgeMs > UINT32_MAX
                    ? UINT32_MAX
                    : static_cast<uint32_t>(currentAgeMs);
  return true;
}

String characteristicValueAsString(BLECharacteristic *characteristic) {
  const uint8_t *data = characteristic->getData();
  const size_t len = characteristic->getLength();
  String text;
  text.reserve(len);
  for (size_t i = 0; i < len; ++i) {
    text += static_cast<char>(data[i]);
  }
  return text;
}

int32_t readLeInt32(const uint8_t *data) {
  const uint32_t raw = static_cast<uint32_t>(data[0]) |
                       (static_cast<uint32_t>(data[1]) << 8) |
                       (static_cast<uint32_t>(data[2]) << 16) |
                       (static_cast<uint32_t>(data[3]) << 24);
  return static_cast<int32_t>(raw);
}

uint16_t readLeUInt16(const uint8_t *data) {
  return static_cast<uint16_t>(data[0]) |
         (static_cast<uint16_t>(data[1]) << 8);
}

uint32_t readLeUInt32(const uint8_t *data) {
  return static_cast<uint32_t>(data[0]) |
         (static_cast<uint32_t>(data[1]) << 8) |
         (static_cast<uint32_t>(data[2]) << 16) |
         (static_cast<uint32_t>(data[3]) << 24);
}

bool parseLocationFrame(const uint8_t *data, size_t len) {
  if (len < 28 || data[0] != 1) {
    return false;
  }

  const uint8_t flags = data[1];
  const uint16_t reportedHeadingDeg100 = readLeUInt16(data + 22);
  selfLocationFrame.valid = (flags & kLocationFlagValid) != 0;
  selfLocationFrame.reportedHeadingValid =
      (flags & kLocationFlagHeadingValid) != 0 && reportedHeadingDeg100 < 36000;
  selfLocationFrame.latE7 = readLeInt32(data + 2);
  selfLocationFrame.lonE7 = readLeInt32(data + 6);
  selfLocationFrame.horizontalAccuracyCm = readLeUInt16(data + 14);
  selfLocationFrame.speedCms = readLeUInt16(data + 18);
  selfLocationFrame.courseDeg100 = readLeUInt16(data + 20);
  selfLocationFrame.reportedHeadingDeg100 =
      selfLocationFrame.reportedHeadingValid ? reportedHeadingDeg100 : 0;
  selfLocationFrame.unixTime = readLeUInt32(data + 24);
  selfLocationFrame.receivedMs = millis();
  selfLocationFrame.sourceAgeKnown = sourceAgeFromUnixTime(
      selfLocationFrame.unixTime, selfLocationFrame.receivedMs,
      selfLocationFrame.sourceAgeMs);
  selfLocationFrame.sourceStale = !selfLocationFrame.sourceAgeKnown;
  provisioning.locationReceived = true;
  persistSelfLocationFrame(true);
  return true;
}

void copyLocationFrame(RemoteLocationFrame &dst, const RemoteLocationFrame &src) {
  dst.valid = src.valid;
  dst.reportedHeadingValid = src.reportedHeadingValid;
  dst.latE7 = src.latE7;
  dst.lonE7 = src.lonE7;
  dst.horizontalAccuracyCm = src.horizontalAccuracyCm;
  dst.speedCms = src.speedCms;
  dst.courseDeg100 = src.courseDeg100;
  dst.reportedHeadingDeg100 = src.reportedHeadingDeg100;
  dst.unixTime = src.unixTime;
  dst.receivedMs = src.receivedMs;
  dst.sourceAgeKnown = src.sourceAgeKnown;
  dst.sourceStale = src.sourceStale;
  dst.sourceAgeMs = src.sourceAgeMs;
}

bool parseRelayLocationObject(const String &json, RemoteLocationFrame &frame) {
  noteRelayServerTime(json);
  int32_t latE7 = 0;
  int32_t lonE7 = 0;
  int32_t hAccCm = 0;
  int32_t speedCms = 0;
  int32_t courseDeg100 = 0;
  int32_t reportedHeadingDeg100 = 0;
  int32_t unixTime = 0;
  int32_t locationAgeMs = 0;
  bool reportedHeadingValid = false;
  bool locationStale = true;
  if (!extractJsonIntValue(json, "lat_e7", latE7) ||
      !extractJsonIntValue(json, "lon_e7", lonE7)) {
    return false;
  }

  extractJsonIntValue(json, "h_acc_cm", hAccCm);
  extractJsonIntValue(json, "speed_cms", speedCms);
  extractJsonIntValue(json, "course_deg100", courseDeg100);
  const bool hasReportedHeading =
      extractJsonIntValue(json, "heading_deg100", reportedHeadingDeg100);
  const bool hasReportedHeadingValidity =
      extractJsonBoolValue(json, "heading_valid", reportedHeadingValid);
  extractJsonIntValue(json, "unix_time", unixTime);
  const bool hasLocationAge =
      extractJsonIntValue(json, "location_age_ms", locationAgeMs) && locationAgeMs >= 0;
  const bool hasLocationStale =
      extractJsonBoolValue(json, "location_stale", locationStale);

  frame.valid = true;
  frame.reportedHeadingValid = hasReportedHeading && hasReportedHeadingValidity &&
                               reportedHeadingValid &&
                               reportedHeadingDeg100 >= 0 && reportedHeadingDeg100 < 36000;
  frame.latE7 = latE7;
  frame.lonE7 = lonE7;
  frame.horizontalAccuracyCm = static_cast<uint16_t>(constrain(hAccCm, 0, 65535));
  frame.speedCms = static_cast<uint16_t>(constrain(speedCms, 0, 65535));
  frame.courseDeg100 = static_cast<uint16_t>(constrain(courseDeg100, 0, 65535));
  frame.reportedHeadingDeg100 = frame.reportedHeadingValid
                                    ? static_cast<uint16_t>(reportedHeadingDeg100)
                                    : 0;
  frame.unixTime = unixTime > 0 ? static_cast<uint32_t>(unixTime) : 0;
  frame.receivedMs = millis();
  uint32_t timestampAgeMs = 0;
  const bool timestampAgeKnown = sourceAgeFromUnixTime(
      frame.unixTime, frame.receivedMs, timestampAgeMs);
  frame.sourceAgeKnown = timestampAgeKnown;
  frame.sourceAgeMs = timestampAgeKnown ? timestampAgeMs : 0;
  if (timestampAgeKnown && hasLocationAge) {
    frame.sourceAgeMs = max(frame.sourceAgeMs, static_cast<uint32_t>(locationAgeMs));
  }
  frame.sourceStale = !timestampAgeKnown || (hasLocationStale && locationStale);
  return true;
}

bool isLocalAppRelayPeer(const String &peerId) {
  return peerId.length() > 0 &&
         (peerId == localAppRelayPeerId() || peerId == localRelayPeerId());
}

bool relayMemberBelongsToLocalGroup(const String &member) {
  String groupId;
  String peerId;
  String appPeerId;
  String devicePeerId;
  extractJsonStringValue(member, "group_id", groupId);
  extractJsonStringValue(member, "peer_id", peerId);
  extractJsonStringValue(member, "app_peer_id", appPeerId);
  extractJsonStringValue(member, "device_peer_id", devicePeerId);
  const String localDevice = localRelayPeerId();
  const String localApp = localAppRelayPeerId();
  return groupId == localDevice ||
         peerId == localDevice ||
         peerId == localApp ||
         appPeerId == localApp ||
         appPeerId == localDevice ||
         devicePeerId == localDevice;
}

uint8_t remoteAppSlotForPeer(const String &peerId) {
  const uint32_t now = millis();
  for (uint8_t i = 0; i < kRemoteAppSlotCount; ++i) {
    if (remoteAppPeerIds[i] == peerId && remoteAppLocationFrames[i].valid) {
      return i;
    }
  }
  for (uint8_t i = 0; i < kRemoteAppSlotCount; ++i) {
    if (remoteAppPeerIds[i].length() == 0 || !remoteAppLocationFrames[i].valid ||
        now - remoteAppLocationFrames[i].receivedMs > kRemoteAppMarkerTtlMs) {
      return i;
    }
  }

  uint8_t oldest = 0;
  uint32_t oldestMs = remoteAppLocationFrames[0].receivedMs;
  for (uint8_t i = 1; i < kRemoteAppSlotCount; ++i) {
    if (remoteAppLocationFrames[i].receivedMs < oldestMs) {
      oldest = i;
      oldestMs = remoteAppLocationFrames[i].receivedMs;
    }
  }
  return oldest;
}

void storeRemoteAppLocation(const String &peerId, const String &name, const RemoteLocationFrame &frame) {
  const uint8_t slot = remoteAppSlotForPeer(peerId);
  const uint32_t now = millis();
  const bool sameLivePeer =
      remoteAppPeerIds[slot] == peerId &&
      remoteAppLocationFrames[slot].valid &&
      remoteAppLocationFrames[slot].receivedMs > 0 &&
      now - remoteAppLocationFrames[slot].receivedMs <= kRemoteAppMarkerTtlMs;
  if (!sameLivePeer) {
    if (focusedMemberSlot == slot) {
      focusedMemberSlot = kFocusNone;
    }
    remoteGeoFilterStates[slot] = RemoteGeoFilterState{};
    remoteAppBlinkStartedSlotsMs[slot] = now;
    remoteAppBlinkStartedMs = now;
  }
  copyLocationFrame(remoteAppLocationFrames[slot], frame);
  remoteAppPeerIds[slot] = peerId;
  remoteAppPeerNames[slot] = name.length() > 0 ? name : peerId;

  copyLocationFrame(remoteAppLocationFrame, frame);
  remoteAppPeerName = remoteAppPeerNames[slot];
}

void storeRemoteAppSpeaking(const String &peerId, bool speaking) {
  const uint8_t slot = remoteAppSlotForPeer(peerId);
  if (slot >= kRemoteAppSlotCount) {
    return;
  }
  if (speaking) {
    remoteAppSpeakingUntilMs[slot] = millis() + kRemoteSpeakingHoldMs;
  } else if (remoteAppSpeakingUntilMs[slot] < millis() + 180) {
    remoteAppSpeakingUntilMs[slot] = 0;
  }
}

bool relayMemberSpeaking(const String &member) {
  if (member.indexOf("\"voice_status\"") < 0) {
    return false;
  }
  bool vad = false;
  bool ptt = false;
  extractJsonBoolValue(member, "vad", vad);
  extractJsonBoolValue(member, "ptt", ptt);
  return vad || ptt;
}

bool remoteRoomVoiceBusy() {
  if (!remoteRoomSpeakerActive) {
    return false;
  }
  if (remoteRoomSpeakerUntilMs != 0 && millis() > remoteRoomSpeakerUntilMs) {
    remoteRoomSpeakerActive = false;
    remoteRoomSpeakerUntilMs = 0;
    return false;
  }
  return true;
}

uint8_t activeRemoteAppLocationCount(uint32_t now) {
  uint8_t count = 0;
  for (uint8_t i = 0; i < kRemoteAppSlotCount; ++i) {
    if (remoteAppLocationFrames[i].valid &&
        remoteAppLocationFrames[i].receivedMs > 0 &&
        now - remoteAppLocationFrames[i].receivedMs <= kRemoteAppMarkerTtlMs) {
      ++count;
    }
  }
  return count;
}

void clearRemoteRoomState() {
  focusedMemberSlot = kFocusNone;
  remoteAppLocationFrame = RemoteLocationFrame{};
  remoteAppPeerName = "";
  for (uint8_t slot = 0; slot < kRemoteAppSlotCount; ++slot) {
    remoteAppLocationFrames[slot] = RemoteLocationFrame{};
    remoteGeoFilterStates[slot] = RemoteGeoFilterState{};
    remoteAppPeerIds[slot] = "";
    remoteAppPeerNames[slot] = "";
    remoteAppBlinkStartedSlotsMs[slot] = 0;
    remoteAppSpeakingUntilMs[slot] = 0;
  }
  remoteAppBlinkStartedMs = 0;
  remoteRoomSpeakerActive = false;
  remoteRoomSpeakerUntilMs = 0;
}

bool parseRelayAppLocation(const String &json) {
  noteRelayServerTime(json);
  RemoteLocationFrame frame;
  if (!parseRelayLocationObject(json, frame)) {
    return false;
  }

  String from;
  extractJsonStringValue(json, "from", from);
  String name;
  extractJsonStringValue(json, "name", name);
  lastRelayAppLocationWasSelf = isLocalAppRelayPeer(from);
  if (lastRelayAppLocationWasSelf) {
    copyLocationFrame(selfLocationFrame, frame);
    persistSelfLocationFrame(false);
    provisioning.lastWrite = "relay_self_location";
  } else {
    storeRemoteAppLocation(from, name, frame);
    provisioning.lastWrite = "relay_app_location";
  }
  provisioning.locationReceived = true;
  return true;
}

bool parseRelayRoomState(const String &json) {
  if (json.indexOf("\"type\":\"room_state\"") < 0) {
    return false;
  }
  noteRelayServerTime(json);

  const int membersKey = json.indexOf("\"members\"");
  if (membersKey < 0) {
    return false;
  }
  const int arrayStart = json.indexOf('[', membersKey);
  if (arrayStart < 0) {
    return false;
  }

  bool inString = false;
  bool escaped = false;
  int depth = 0;
  int objectStart = -1;
  bool updatedSelf = false;
  bool updatedRemote = false;
  bool remoteSpeakerSeen = false;

  for (int i = arrayStart + 1; i < json.length(); ++i) {
    const char c = json[i];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (c == '\\') {
      escaped = inString;
      continue;
    }
    if (c == '"') {
      inString = !inString;
      continue;
    }
    if (inString) {
      continue;
    }
    if (c == '{') {
      if (depth == 0) {
        objectStart = i;
      }
      ++depth;
      continue;
    }
    if (c == '}') {
      if (depth > 0) {
        --depth;
      }
      if (depth == 0 && objectStart >= 0) {
        const String member = json.substring(objectStart, i + 1);
        objectStart = -1;

        String role;
        String peerId;
        String name;
        extractJsonStringValue(member, "role", role);
        extractJsonStringValue(member, "peer_id", peerId);
        extractJsonStringValue(member, "name", name);
        const bool localMember = relayMemberBelongsToLocalGroup(member);
        const bool memberSpeaking = relayMemberSpeaking(member);
        if (!localMember && memberSpeaking) {
          remoteSpeakerSeen = true;
        }
        if (role != "app") {
          continue;
        }

        RemoteLocationFrame frame;
        if (!parseRelayLocationObject(member, frame)) {
          continue;
        }

        if (localMember || isLocalAppRelayPeer(peerId)) {
          copyLocationFrame(selfLocationFrame, frame);
          persistSelfLocationFrame(false);
          updatedSelf = true;
        } else {
          storeRemoteAppLocation(peerId, name, frame);
          storeRemoteAppSpeaking(peerId, memberSpeaking);
          updatedRemote = true;
        }
      }
      continue;
    }
    if (c == ']' && depth == 0) {
      break;
    }
  }

  remoteRoomSpeakerActive = remoteSpeakerSeen;
  remoteRoomSpeakerUntilMs = remoteSpeakerSeen ? millis() + kRemoteSpeakingHoldMs : 0;
  if (remoteRoomVoiceBusy() && voiceCapture.pttActive) {
    cancelPushToTalkDueToBusy("room_state_busy");
  }

  if (updatedSelf || updatedRemote) {
    provisioning.locationReceived =
        selfLocationFrame.valid || activeRemoteAppLocationCount(millis()) > 0;
    provisioning.lastWrite = updatedSelf ? "room_state_self_location" : "room_state_remote_location";
  }
  return updatedSelf || updatedRemote;
}

void saveProvisioningState() {
  Preferences prefs;
  if (!prefs.begin("radarNet", false)) {
    return;
  }
  prefs.putBool("paired", provisioning.paired);
  prefs.putString("ssid", provisioning.wifiSsid);
  prefs.putString("pass", provisioning.wifiPassword);
  prefs.putString("relay", provisioning.relayUrl);
  prefs.putString("httpApi", provisioning.httpApiUrl);
  prefs.putString("room", provisioning.roomToken);
  prefs.putString("device", provisioning.deviceToken);
  prefs.end();
}

void clearProvisioningAndRestart() {
  if (otaManager.blocksPowerAndVoice()) {
    provisioning.lastWrite = "ota_factory_reset_blocked";
    notifyDeviceStatus(true);
    return;
  }

  relaySocket.disconnect();
  WiFi.disconnect(true, false);

#if defined(CONFIG_NIMBLE_ENABLED)
  ble_store_clear();
#endif

  Preferences prefs;
  if (prefs.begin("radarNet", false)) {
    prefs.clear();
    prefs.end();
  }

  gfx->fillScreen(kScreenBg);
  drawCenteredText("BINDING RESET", kCx, kCy - 18, 2, kAmber);
  drawCenteredText("RESTARTING", kCx, kCy + 22, 1, kGrid);
  gfx->flush();
  Serial.println("BLE provisioning physically reset by local hold");
  delay(700);
  ESP.restart();
}

bool loadPersistedSelfLocationFrame(Preferences &prefs) {
  if (!prefs.getBool("slocValid", false)) {
    return false;
  }

  const int32_t latE7 = prefs.getInt("slocLat", 0);
  const int32_t lonE7 = prefs.getInt("slocLon", 0);
  if (latE7 == 0 && lonE7 == 0) {
    return false;
  }

  selfLocationFrame.valid = true;
  selfLocationFrame.reportedHeadingValid = false;
  selfLocationFrame.latE7 = latE7;
  selfLocationFrame.lonE7 = lonE7;
  selfLocationFrame.horizontalAccuracyCm =
      static_cast<uint16_t>(prefs.getUInt("slocAcc", 0) & 0xffff);
  selfLocationFrame.speedCms =
      static_cast<uint16_t>(prefs.getUInt("slocSpeed", 0) & 0xffff);
  selfLocationFrame.courseDeg100 =
      static_cast<uint16_t>(prefs.getUInt("slocCourse", 0) & 0xffff);
  selfLocationFrame.reportedHeadingDeg100 = 0;
  selfLocationFrame.unixTime = prefs.getUInt("slocTime", 0);
  selfLocationFrame.receivedMs = millis();
  selfLocationFrame.sourceAgeKnown = false;
  selfLocationFrame.sourceStale = true;
  selfLocationFrame.sourceAgeMs = 0;
  provisioning.locationReceived = true;
  provisioning.lastWrite = "stored_self_location";
  return true;
}

void persistSelfLocationFrame(bool force) {
  if (!selfLocationFrame.valid || (selfLocationFrame.latE7 == 0 && selfLocationFrame.lonE7 == 0)) {
    return;
  }

  const uint32_t now = millis();
  if (!force && lastSelfLocationPersistMs > 0 &&
      now - lastSelfLocationPersistMs < kSelfLocationPersistMinIntervalMs) {
    return;
  }

  Preferences prefs;
  if (!prefs.begin("radarNet", false)) {
    return;
  }
  prefs.putBool("slocValid", true);
  prefs.putInt("slocLat", selfLocationFrame.latE7);
  prefs.putInt("slocLon", selfLocationFrame.lonE7);
  prefs.putUInt("slocAcc", selfLocationFrame.horizontalAccuracyCm);
  prefs.putUInt("slocSpeed", selfLocationFrame.speedCms);
  prefs.putUInt("slocCourse", selfLocationFrame.courseDeg100);
  prefs.putUInt("slocTime", selfLocationFrame.unixTime);
  prefs.end();
  lastSelfLocationPersistMs = now;
}

void loadProvisioningState() {
  Preferences prefs;
  if (!prefs.begin("radarNet", false)) {
    return;
  }
  provisioning.paired = prefs.getBool("paired", false);
  provisioning.wifiSsid = prefs.isKey("ssid") ? prefs.getString("ssid", "") : "";
  provisioning.wifiPassword = prefs.isKey("pass") ? prefs.getString("pass", "") : "";
  provisioning.relayUrl = prefs.isKey("relay") ? prefs.getString("relay", "") : "";
  provisioning.httpApiUrl = prefs.isKey("httpApi") ? prefs.getString("httpApi", "") : "";
  provisioning.roomToken = prefs.isKey("room") ? prefs.getString("room", "") : "";
  provisioning.deviceToken = prefs.isKey("device") ? prefs.getString("device", "") : "";
  loadPersistedSelfLocationFrame(prefs);
  prefs.end();

  provisioning.serverConfigured =
      provisioning.relayUrl.length() > 0 && provisioning.deviceToken.length() > 0;
  provisioning.wifiConnectRequested = provisioning.wifiSsid.length() > 0;
  provisioning.relayState = provisioning.serverConfigured ? "configured" : "unconfigured";
}

void rotateProvisioningChallenge() {
  const uint64_t mac = ESP.getEfuseMac();
  const uint16_t suffix = static_cast<uint16_t>(mac & 0xffff);
  const uint32_t random0 = esp_random();
  const uint32_t random1 = esp_random();
  const uint32_t random2 = esp_random();
  const uint32_t random3 = esp_random();
  snprintf(provisioning.challenge, sizeof(provisioning.challenge),
           "CR-%04X-%08lX%08lX%08lX%08lX", suffix,
           static_cast<unsigned long>(random0), static_cast<unsigned long>(random1),
           static_cast<unsigned long>(random2), static_cast<unsigned long>(random3));
}

void buildProvisioningIdentity() {
  const uint64_t mac = ESP.getEfuseMac();
  const uint16_t suffix = static_cast<uint16_t>(mac & 0xffff);
  snprintf(provisioning.deviceName, sizeof(provisioning.deviceName), "CapsuleRadar-%04X", suffix);
  rotateProvisioningChallenge();
}

const char *wifiStatusText() {
  if (provisioning.wifiConnectInFlight && WiFi.status() != WL_CONNECTED) {
    return "connecting";
  }
  switch (WiFi.status()) {
    case WL_CONNECTED:
      return "connected";
    case WL_NO_SSID_AVAIL:
      return "missing";
    case WL_CONNECT_FAILED:
      return "failed";
    case WL_CONNECTION_LOST:
      return "lost";
    case WL_DISCONNECTED:
      return "disconnected";
    default:
      return "connecting";
  }
}

const char *relayStatusText() {
  if (!provisioning.serverConfigured) {
    return "unconfigured";
  }
  if (WiFi.status() != WL_CONNECTED) {
    return "waiting_wifi";
  }
  if (provisioning.relayConnected) {
    return "connected";
  }
  return provisioning.relayState.c_str();
}

const char *powerStateText() {
  switch (radarUiMode) {
    case RadarUiMode::ScreenOff:
      return "screen_off";
    case RadarUiMode::Standby:
      return "standby";
    case RadarUiMode::ShutdownPending:
      return "shutdown_pending";
    default:
      return "active";
  }
}

const char *displayStateText() {
  switch (radarUiMode) {
    case RadarUiMode::ScreenOff:
    case RadarUiMode::Standby:
    case RadarUiMode::ShutdownPending:
      return "off";
    default:
      return "on";
  }
}

String buildDeviceStatusJson(bool includeExtendedState = false, bool compactBleState = false) {
  updateBatteryStatus(false);
  String status = "{";
  status += "\"v\":1";
  status += ",\"fw\":\"";
  status += DragonRadarFirmware::kVersion;
  status += "\",\"build\":";
  status += String(DragonRadarFirmware::kBuild);
  status += ",\"hw\":\"";
  status += DragonRadarFirmware::kHardware;
  status += "\",\"ota\":1";
  status += ",\"security_counter\":";
  status += String(DragonRadarFirmware::kSecurityCounter);
  status += ",\"ota_origin\":";
  status += provisioning.httpApiUrl.length() > 0 ? "1" : "0";
  if (includeExtendedState) {
    status += ",\"protocol_version\":";
    status += String(DRAGON_RADAR_PROTOCOL_VERSION);
    status += ",\"min_relay_protocol_version\":";
    status += String(DRAGON_RADAR_MIN_RELAY_PROTOCOL_VERSION);
  }
  status += ",\"name\":\"";
  status += jsonEscape(provisioning.deviceName);
  status += "\"";
  status += ",\"ble\":";
  status += provisioning.appConnected ? "1" : "0";
  status += ",\"ble_secure\":";
  status += bleLinkAuthenticated ? "1" : "0";
  status += ",\"paired\":";
  status += provisioning.paired ? "1" : "0";
  status += ",\"owner_auth_required\":1";
  status += ",\"owner_auth\":";
  status += provisioning.ownerSessionAuthorized ? "1" : "0";
  status += ",\"wifi\":\"";
  status += wifiStatusText();
  status += "\"";
  status += ",\"rssi\":";
  status += WiFi.status() == WL_CONNECTED ? String(WiFi.RSSI()) : String(0);
  status += ",\"ip\":\"";
  status += WiFi.status() == WL_CONNECTED ? WiFi.localIP().toString() : "";
  status += "\"";
  status += ",\"server\":";
  status += provisioning.serverConfigured ? "1" : "0";
  if (!compactBleState) {
    status += ",\"relay\":\"";
    status += jsonEscape(String(relayStatusText()));
    status += "\"";
  }
  status += ",\"loc\":";
  status += provisioning.locationReceived ? "1" : "0";
  if (!compactBleState) {
    status += ",\"power_state\":\"";
    status += powerStateText();
    status += "\"";
    status += ",\"display_state\":\"";
    status += displayStateText();
    status += "\"";
  }
  if (includeExtendedState) {
    status += ",\"last_user_input_ms\":";
    status += String(lastUserInputMs);
    status += ",\"battery_percent\":";
    status += String(batteryStatus.percent);
    status += ",\"battery_voltage_mv\":";
    status += String(batteryStatus.voltageMv);
  }
  status += ",\"battery\":{";
  status += "\"present\":";
  status += batteryStatus.present ? "true" : "false";
  status += ",\"percent\":";
  status += String(batteryStatus.percent);
  status += ",\"voltage_mv\":";
  status += String(batteryStatus.voltageMv);
  status += ",\"charging\":";
  status += batteryStatus.charging ? "true" : "false";
  status += ",\"discharging\":";
  status += batteryStatus.discharging ? "true" : "false";
  status += ",\"low\":";
  status += batteryStatus.low ? "true" : "false";
  status += "}";
  if (includeExtendedState) {
    status += ",\"voice\":{";
    status += "\"capture\":";
    status += voiceCapture.captureOnline ? "1" : "0";
    status += ",\"muted\":";
    status += voiceCapture.muted ? "1" : "0";
    status += ",\"ptt\":";
    status += voiceCapture.pttActive ? "1" : "0";
    status += ",\"vad\":";
    status += voiceCapture.vadActive ? "1" : "0";
    status += ",\"playback\":";
    status += voiceCapture.playbackActive ? "1" : "0";
    status += ",\"rms\":";
    status += String(voiceCapture.rms);
    status += ",\"peak\":";
    status += String(voiceCapture.peak);
    status += ",\"seq\":";
    status += String(voiceCapture.sequence);
    status += ",\"rx_seq\":";
    status += String(voiceCapture.receivedSequence);
    status += "}";
  }
  String escapedLastWrite = jsonEscape(provisioning.lastWrite);
  if (compactBleState && escapedLastWrite.length() > kBleDeviceStatusLastEventMaxBytes) {
    escapedLastWrite = "status_event_truncated";
  }
  status += ",\"last\":\"";
  status += escapedLastWrite;
  status += "\"";
  status += "}";
  return status;
}

void notifyDeviceStatus(bool force) {
  if (!deviceStatusCharacteristic) {
    return;
  }
  const uint32_t now = millis();
  if (!force && now - provisioning.lastStatusNotifyMs < kDeviceStatusNotifyMs) {
    return;
  }
  provisioning.lastStatusNotifyMs = now;
  String status = buildDeviceStatusJson();
  if (status.length() > kBleCharacteristicMaxValueBytes) {
    const size_t originalLength = status.length();
    status = buildDeviceStatusJson(false, true);
    Serial.print("BLE device status compacted: ");
    Serial.print(originalLength);
    Serial.print(" -> ");
    Serial.print(status.length());
    Serial.println(" bytes.");
  }
  if (status.length() > kBleCharacteristicMaxValueBytes) {
    Serial.print("BLE device status dropped: ");
    Serial.print(status.length());
    Serial.println(" bytes exceeds 512-byte characteristic limit.");
    return;
  }
  deviceStatusCharacteristic->setValue(status);
  if (provisioning.appConnected) {
    deviceStatusCharacteristic->notify();
  }
}

void notifyFirmwareStatus(bool force) {
  if (!firmwareStatusCharacteristic) {
    return;
  }
  const uint32_t now = millis();
  const String status = otaManager.statusJson();
  const bool changed = status != lastFirmwareStatusJson;
  if (!force && !changed && now - lastFirmwareStatusNotifyMs < kFirmwareStatusNotifyMs) {
    return;
  }
  if (status.length() > kBleCharacteristicMaxValueBytes) {
    Serial.println("BLE firmware status exceeds 512-byte characteristic limit.");
    return;
  }
  lastFirmwareStatusNotifyMs = now;
  lastFirmwareStatusJson = status;
  firmwareStatusCharacteristic->setValue(status);
  if (provisioning.appConnected && (force || changed)) {
    if (status.length() <= kFirmwareStatusNotifySafeBytes) {
      firmwareStatusCharacteristic->notify();
    } else {
      Serial.println("BLE firmware status exceeds safe notification MTU; waiting for long read.");
    }
  }
}

void firmwareOtaTick() {
  static bool previouslyBlocking = false;
  otaManager.setBootHealth(displayOnline, provisioning.serviceOnline);
  otaManager.tick();
  const bool blocking = otaManager.blocksPowerAndVoice();
  if (blocking && !previouslyBlocking) {
    tone.active = false;
    tone.remainingSamples = 0;
    bootAudioPlaying = false;
    voiceCapture.playbackActive = false;
    if (voiceCapture.pttActive || speakerMutedForCapture) {
      voiceCapture.pttActive = false;
      voiceCapture.vadActive = false;
      setSpeakerMutedForCapture(false);
    }
    radarUiMode = RadarUiMode::Main;
    if (displayOnline) {
      panel->setBrightness(currentBrightness());
    }
    lastFrameMs = 0;
  }
  previouslyBlocking = blocking;
  notifyFirmwareStatus(false);
}

bool hmacSha256HexWithKey(const String &message, const String &key, String &outHex) {
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (!info || key.length() == 0) {
    return false;
  }

  uint8_t digest[32] = {0};
  const int rc = mbedtls_md_hmac(
      info,
      reinterpret_cast<const unsigned char *>(key.c_str()),
      key.length(),
      reinterpret_cast<const unsigned char *>(message.c_str()),
      message.length(),
      digest);
  if (rc != 0) {
    return false;
  }

  outHex = "";
  outHex.reserve(64);
  static constexpr char kHex[] = "0123456789abcdef";
  for (uint8_t byte : digest) {
    outHex += kHex[(byte >> 4) & 0x0f];
    outHex += kHex[byte & 0x0f];
  }
  return true;
}

bool sha256Hex(const String &message, String &outHex) {
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (!info) {
    return false;
  }
  uint8_t digest[32] = {0};
  const int rc = mbedtls_md(
      info,
      reinterpret_cast<const unsigned char *>(message.c_str()),
      message.length(),
      digest);
  if (rc != 0) {
    return false;
  }
  outHex = "";
  outHex.reserve(64);
  static constexpr char kHex[] = "0123456789abcdef";
  for (uint8_t byte : digest) {
    outHex += kHex[(byte >> 4) & 0x0f];
    outHex += kHex[byte & 0x0f];
  }
  return true;
}

String stableRelayIdentifier(const String &secret, const String &fallback) {
  String digest;
  if (secret.length() == 0 || !sha256Hex(secret, digest)) {
    return fallback;
  }
  return digest.substring(0, 24);
}

bool hmacSha256Hex(const String &message, String &outHex) {
  if (!kPairingHmacKey || strlen(kPairingHmacKey) == 0) {
    return false;
  }
  return hmacSha256HexWithKey(message, String(kPairingHmacKey), outHex);
}

bool isHexSha256(const String &value) {
  if (value.length() != 64) {
    return false;
  }
  for (size_t i = 0; i < value.length(); ++i) {
    const char c = value.charAt(i);
    const bool hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    if (!hex) {
      return false;
    }
  }
  return true;
}

bool constantTimeHexEquals(const String &lhs, const String &rhs) {
  if (lhs.length() != rhs.length()) {
    return false;
  }
  uint8_t difference = 0;
  for (size_t i = 0; i < lhs.length(); ++i) {
    char left = lhs.charAt(i);
    char right = rhs.charAt(i);
    if (left >= 'A' && left <= 'F') {
      left = static_cast<char>(left - 'A' + 'a');
    }
    if (right >= 'A' && right <= 'F') {
      right = static_cast<char>(right - 'A' + 'a');
    }
    difference |= static_cast<uint8_t>(left ^ right);
  }
  return difference == 0;
}

bool verifyPairingResponse(const String &response) {
  static const String prefix = "dra-pair:v2:";
  if (!response.startsWith(prefix)) {
    return kAllowLegacyPairing && response.length() > 0;
  }

  const int deviceStart = prefix.length();
  const int nonceStart = response.indexOf(':', deviceStart);
  if (nonceStart < 0) {
    return false;
  }
  const int signatureStart = response.indexOf(':', nonceStart + 1);
  if (signatureStart < 0) {
    return false;
  }

  const String deviceId = response.substring(deviceStart, nonceStart);
  const String nonce = response.substring(nonceStart + 1, signatureStart);
  const String signature = response.substring(signatureStart + 1);
  if (deviceId.length() == 0 || nonce.length() == 0 || !isHexSha256(signature)) {
    return false;
  }

  String expected;
  const String message = String("v2|") + provisioning.challenge + "|" + deviceId + "|" + nonce;
  if (!hmacSha256Hex(message, expected)) {
    return false;
  }
  return constantTimeHexEquals(signature, expected);
}

bool verifyOwnerSessionResponse(const String &response) {
  static const String prefix = "dra-auth:v1:";
  if (!response.startsWith(prefix) || !provisioning.paired || provisioning.deviceToken.length() == 0) {
    return false;
  }

  const int modeStart = prefix.length();
  const int nonceStart = response.indexOf(':', modeStart);
  if (nonceStart < 0) {
    return false;
  }
  const int signatureStart = response.indexOf(':', nonceStart + 1);
  if (signatureStart < 0 || response.indexOf(':', signatureStart + 1) >= 0) {
    return false;
  }

  const String mode = response.substring(modeStart, nonceStart);
  const String nonce = response.substring(nonceStart + 1, signatureStart);
  const String signature = response.substring(signatureStart + 1);
  if (mode != "t" || nonce.length() < 16 || nonce.length() > 64 || !isHexSha256(signature)) {
    return false;
  }

  String expected;
  const String message = String("v1|") + provisioning.challenge + "|t|" + nonce;
  if (!hmacSha256HexWithKey(message, provisioning.deviceToken, expected)) {
    return false;
  }
  return constantTimeHexEquals(signature, expected);
}

void handlePairingResponseWrite(BLECharacteristic *characteristic, uint16_t connectionHandle) {
  const String response = characteristicValueAsString(characteristic);
  if (response.startsWith("dra-auth:v1:")) {
    if (!verifyOwnerSessionResponse(response)) {
      provisioning.ownerSessionAuthorized = false;
      provisioning.lastWrite = "owner_session_invalid";
      notifyDeviceStatus(true);
      Serial.println("BLE owner session proof invalid");
      return;
    }
    provisioning.ownerSessionAuthorized = true;
    ownerSessionConnectionHandle = connectionHandle;
    provisioning.lastWrite = "owner_session_authorized";
    notifyDeviceStatus(true);
    Serial.println("BLE owner session authorized");
    return;
  }

  if (provisioning.paired && provisioning.deviceToken.length() > 0) {
    provisioning.lastWrite = "pairing_response locked";
    notifyDeviceStatus(true);
    Serial.println("BLE provisioning pairing_response rejected for configured device");
    return;
  }
  if (!verifyPairingResponse(response)) {
    provisioning.lastWrite = "pairing_response invalid";
    notifyDeviceStatus(true);
    Serial.println("BLE provisioning pairing_response invalid");
    return;
  }
  provisioning.pairingResponse = response;
  provisioning.paired = true;
  provisioning.ownerSessionAuthorized = true;
  ownerSessionConnectionHandle = connectionHandle;
  provisioning.lastWrite = "pairing_response_verified";
  saveProvisioningState();
  notifyDeviceStatus(true);
  Serial.println("BLE provisioning pairing_response verified");
}

void handleWifiConfigWrite(BLECharacteristic *characteristic) {
  const String json = characteristicValueAsString(characteristic);
  String ssid;
  String password;
  if (!extractJsonStringValue(json, "ssid", ssid)) {
    provisioning.lastWrite = "wifi_config invalid:ssid";
    notifyDeviceStatus(true);
    Serial.println("BLE provisioning wifi_config missing ssid");
    return;
  }
  extractJsonStringValue(json, "password", password);
  provisioning.wifiSsid = ssid;
  provisioning.wifiPassword = password;
  provisioning.wifiConnectRequested = true;
  provisioning.wifiConnectInFlight = false;
  lastWifiAttemptMs = 0;
  provisioning.lastWrite = "wifi_config";
  saveProvisioningState();
  notifyDeviceStatus(true);
  Serial.print("BLE provisioning wifi_config ssid=");
  Serial.println(provisioning.wifiSsid);
}

bool applyServerConfigJson(const String &json, const char *source) {
  String relayUrl;
  String httpApiUrl = provisioning.httpApiUrl;
  String roomToken;
  String deviceToken = provisioning.deviceToken;
  extractJsonStringValue(json, "relay_url", relayUrl);
  if (strcmp(source, "ble") == 0) {
    extractJsonStringValue(json, "http_api_url", httpApiUrl);
  }
  extractJsonStringValue(json, "room_token", roomToken);
  extractJsonStringValue(json, "device_token", deviceToken);
  if (relayUrl.length() == 0 || roomToken.length() == 0 || deviceToken.length() == 0) {
    provisioning.lastWrite = String(source) + " invalid:server_config";
    notifyDeviceStatus(true);
    Serial.print(source);
    Serial.println(" server_config invalid");
    return false;
  }
  const bool roomChanged = provisioning.roomToken != roomToken;
  if (roomChanged) {
    clearRemoteRoomState();
  }
  provisioning.relayUrl = relayUrl;
  provisioning.httpApiUrl = httpApiUrl;
  provisioning.roomToken = roomToken;
  provisioning.deviceToken = deviceToken;
  provisioning.serverConfigured = relayUrl.length() > 0 && deviceToken.length() > 0;
  provisioning.relayConnected = false;
  provisioning.relaySocketConfigured = false;
  provisioning.relayState = provisioning.serverConfigured ? "configured" : "unconfigured";
  lastRelayAttemptMs = 0;
  lastRelayHeartbeatMs = 0;
  relayTimeSyncStartedMs = 0;
  lastRelayTimeSyncAttemptMs = 0;
  relayTimeSyncInFlight = false;
  relayTimeSyncAttempted = false;
  provisioning.lastWrite = String(source) + "_server_config";
  saveProvisioningState();
  notifyDeviceStatus(true);
  relaySocket.disconnect();
  Serial.print(source);
  Serial.print(" server_config accepted ota_origin=");
  Serial.println(provisioning.httpApiUrl.length() > 0 ? "configured" : "missing");
  return true;
}

void handleServerConfigWrite(BLECharacteristic *characteristic) {
  const String json = characteristicValueAsString(characteristic);
  applyServerConfigJson(json, "ble");
}

void handleLocalLocationWrite(BLECharacteristic *characteristic) {
  const uint8_t *data = characteristic->getData();
  const size_t len = characteristic->getLength();
  if (!parseLocationFrame(data, len)) {
    provisioning.lastWrite = "local_location invalid";
    notifyDeviceStatus(true);
    Serial.print("BLE provisioning local_location invalid len=");
    Serial.println(len);
    return;
  }

  provisioning.lastWrite = "local_location";
  notifyDeviceStatus(true);
  Serial.print("BLE provisioning self_location latE7=");
  Serial.print(selfLocationFrame.latE7);
  Serial.print(" lonE7=");
  Serial.print(selfLocationFrame.lonE7);
  Serial.print(" hAccCm=");
  Serial.print(selfLocationFrame.horizontalAccuracyCm);
  Serial.print(" reportedHeading=");
  if (selfLocationFrame.reportedHeadingValid) {
    Serial.println(selfLocationFrame.reportedHeadingDeg100 / 100.0f, 2);
  } else {
    Serial.println("invalid");
  }
}

void handleFirmwareControlWrite(BLECharacteristic *characteristic) {
  const String control = characteristicValueAsString(characteristic);
  updateBatteryStatus(false);
  const bool accepted = otaManager.handleControlJson(
      control,
      provisioning.paired,
      batteryStatus.percent,
      batteryStatus.charging,
      voiceCapture.pttActive,
      WiFi.status() == WL_CONNECTED,
      provisioning.deviceToken,
      provisioning.httpApiUrl);
  const DragonRadarOta::Snapshot ota = otaManager.snapshot();
  provisioning.lastWrite = accepted
                               ? String("ota_") + DragonRadarOta::phaseText(ota.phase)
                               : String("ota_rejected_") +
                                     (ota.error.length() > 0 ? ota.error : "busy");
  notifyFirmwareStatus(true);
  notifyDeviceStatus(true);
}

bool authorizeGattWrite(RadarGattWriteRole role, uint16_t connectionHandle) {
  if (role == RadarGattWriteRole::PairingResponse &&
      connectionHandle == activeProvisioningConnectionHandle) {
    return true;
  }
  if (provisioning.ownerSessionAuthorized &&
      connectionHandle == activeProvisioningConnectionHandle &&
      connectionHandle == ownerSessionConnectionHandle) {
    return true;
  }
  provisioning.lastWrite = "owner_auth_required";
  notifyDeviceStatus(true);
  if (role == RadarGattWriteRole::FirmwareControl) {
    notifyFirmwareStatus(true);
  }
  Serial.println("BLE protected write rejected: owner session required");
  return false;
}

void handleGattWrite(
    RadarGattWriteRole role,
    BLECharacteristic *characteristic,
    uint16_t connectionHandle) {
  if (!authorizeGattWrite(role, connectionHandle)) {
    return;
  }
  switch (role) {
    case RadarGattWriteRole::PairingResponse:
      handlePairingResponseWrite(characteristic, connectionHandle);
      break;
    case RadarGattWriteRole::WifiConfig:
      handleWifiConfigWrite(characteristic);
      break;
    case RadarGattWriteRole::LocalLocation:
      handleLocalLocationWrite(characteristic);
      break;
    case RadarGattWriteRole::ServerConfig:
      handleServerConfigWrite(characteristic);
      break;
    case RadarGattWriteRole::FirmwareControl:
      handleFirmwareControlWrite(characteristic);
      break;
  }
}

void beginProvisioningConnection(BLEServer *server, uint16_t connectionHandle) {
  if (activeProvisioningConnectionHandle != kInvalidBleConnectionHandle &&
      activeProvisioningConnectionHandle != connectionHandle) {
    server->disconnect(connectionHandle);
    Serial.println("BLE extra central rejected while owner channel is active");
    return;
  }
  activeProvisioningConnectionHandle = connectionHandle;
  ownerSessionConnectionHandle = kInvalidBleConnectionHandle;
  bleLinkAuthenticated = false;
  provisioning.appConnected = true;
  provisioning.ownerSessionAuthorized = false;
  rotateProvisioningChallenge();
  if (pairingChallengeCharacteristic) {
    pairingChallengeCharacteristic->setValue(provisioning.challenge);
  }
  notifyDeviceStatus(true);
  notifyFirmwareStatus(true);
  Serial.println("BLE provisioning app connected");
}

void endProvisioningConnection(uint16_t connectionHandle) {
  if (connectionHandle != activeProvisioningConnectionHandle) {
    return;
  }
  activeProvisioningConnectionHandle = kInvalidBleConnectionHandle;
  ownerSessionConnectionHandle = kInvalidBleConnectionHandle;
  bleLinkAuthenticated = false;
  blePairingPasskeyUntilMs = 0;
  blePairingResultUntilMs = 0;
  provisioning.appConnected = false;
  provisioning.ownerSessionAuthorized = false;
  provisioning.lastWrite = "owner_session_closed";
  notifyDeviceStatus(true);
  BLEDevice::startAdvertising();
  Serial.println("BLE provisioning app disconnected");
}

void queueBleSecurityEvent(int8_t result, uint32_t passkey = 0) {
  const uint32_t now = millis();
  bleSecurityEventResult = result;
  if (result == 0) {
    blePairingPasskey = passkey % 1000000UL;
    blePairingPasskeyUntilMs = now + kBlePairingCodeDisplayMs;
    blePairingResultUntilMs = 0;
  } else {
    bleLinkAuthenticated = result > 0;
    blePairingPasskeyUntilMs = 0;
    blePairingResultUntilMs = now + kBlePairingResultDisplayMs;
  }
  bleSecurityEventSerial = static_cast<uint32_t>(bleSecurityEventSerial + 1U);
}

class RadarSecurityCallbacks : public BLESecurityCallbacks {
 public:
  uint32_t onPassKeyRequest() override {
    const uint32_t passkey = BLESecurity::getPassKey();
    queueBleSecurityEvent(0, passkey);
    return passkey;
  }

  void onPassKeyNotify(uint32_t passkey) override {
    queueBleSecurityEvent(0, passkey);
  }

  bool onSecurityRequest() override {
    return true;
  }

  bool onConfirmPIN(uint32_t pin) override {
    (void)pin;
    // This radar advertises DisplayOnly. Numeric-comparison requests indicate
    // that the negotiated IO model is not the one this UI can confirm safely.
    return false;
  }

#if defined(CONFIG_NIMBLE_ENABLED)
  void onAuthenticationComplete(ble_gap_conn_desc *desc) override {
    const bool authenticated = desc && desc->sec_state.encrypted &&
                               desc->sec_state.authenticated && desc->sec_state.bonded;
    queueBleSecurityEvent(authenticated ? 1 : -1);
  }
#elif defined(CONFIG_BLUEDROID_ENABLED)
  void onAuthenticationComplete(esp_ble_auth_cmpl_t desc) override {
    queueBleSecurityEvent(desc.success ? 1 : -1);
  }
#endif
};

class ProvisioningServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    (void)server;
  }

  void onDisconnect(BLEServer *server) override {
    (void)server;
  }

#if defined(CONFIG_NIMBLE_ENABLED)
  void onConnect(BLEServer *server, ble_gap_conn_desc *desc) override {
    if (desc) {
      beginProvisioningConnection(server, desc->conn_handle);
    }
  }

  void onDisconnect(BLEServer *server, ble_gap_conn_desc *desc) override {
    (void)server;
    if (desc) {
      endProvisioningConnection(desc->conn_handle);
    }
  }
#elif defined(CONFIG_BLUEDROID_ENABLED)
  void onConnect(BLEServer *server, esp_ble_gatts_cb_param_t *param) override {
    if (param) {
      beginProvisioningConnection(server, param->connect.conn_id);
    }
  }

  void onDisconnect(BLEServer *server, esp_ble_gatts_cb_param_t *param) override {
    (void)server;
    if (param) {
      endProvisioningConnection(param->disconnect.conn_id);
    }
  }
#endif
};

class RadarGattWriteCallbacks : public BLECharacteristicCallbacks {
 public:
  explicit RadarGattWriteCallbacks(RadarGattWriteRole role) : role_(role) {}

  void onWrite(BLECharacteristic *characteristic) override {
    handleGattWrite(role_, characteristic, activeProvisioningConnectionHandle);
  }

#if defined(CONFIG_NIMBLE_ENABLED)
  void onWrite(BLECharacteristic *characteristic, ble_gap_conn_desc *desc) override {
    handleGattWrite(
        role_, characteristic, desc ? desc->conn_handle : kInvalidBleConnectionHandle);
  }
#elif defined(CONFIG_BLUEDROID_ENABLED)
  void onWrite(BLECharacteristic *characteristic, esp_ble_gatts_cb_param_t *param) override {
    handleGattWrite(
        role_, characteristic, param ? param->write.conn_id : kInvalidBleConnectionHandle);
  }
#endif

 private:
  RadarGattWriteRole role_;
};

BLECharacteristic *createProvisioningCharacteristic(
    BLEService *service,
    const char *uuid,
    uint32_t properties,
    BLECharacteristicCallbacks *callbacks = nullptr) {
  const bool readable = (properties & BLECharacteristic::PROPERTY_READ) != 0;
  const bool writable = (properties & (BLECharacteristic::PROPERTY_WRITE |
                                       BLECharacteristic::PROPERTY_WRITE_NR)) != 0;
  uint32_t protectedProperties = properties;
  if (readable) {
    protectedProperties |= BLECharacteristic::PROPERTY_READ_AUTHEN;
  }
  if (writable) {
    protectedProperties |= BLECharacteristic::PROPERTY_WRITE_AUTHEN;
  }

  BLECharacteristic *characteristic = service->createCharacteristic(uuid, protectedProperties);
  uint16_t permissions = 0;
  if (readable) {
    permissions |= ESP_GATT_PERM_READ_ENC_MITM;
  }
  if (writable) {
    permissions |= ESP_GATT_PERM_WRITE_ENC_MITM;
  }
  if (permissions != 0) {
    characteristic->setAccessPermissions(permissions);
  }
  if (callbacks) {
    characteristic->setCallbacks(callbacks);
  }
  return characteristic;
}

void setupProvisioningBle() {
  if (!kRemoteBleEnabled) {
    return;
  }

  buildProvisioningIdentity();
  BLESecurity *security = new BLESecurity();
  security->setKeySize(16);
  security->setPassKey(false);
  security->regenPassKeyOnConnect(true);
  security->setCapability(ESP_IO_CAP_OUT);
  security->setAuthenticationMode(true, true, true);
  security->setForceAuthentication(true);
  BLEDevice::setSecurityCallbacks(new RadarSecurityCallbacks());

  provisioningServer = BLEDevice::createServer();
  provisioningServer->setCallbacks(new ProvisioningServerCallbacks());

  BLEService *service = provisioningServer->createService(kRadarBleServiceUuid);
  pairingChallengeCharacteristic = createProvisioningCharacteristic(
      service,
      kPairingChallengeUuid,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  pairingChallengeCharacteristic->setValue(provisioning.challenge);

  createProvisioningCharacteristic(
      service,
      kPairingResponseUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR,
      new RadarGattWriteCallbacks(RadarGattWriteRole::PairingResponse));
  createProvisioningCharacteristic(
      service,
      kWifiConfigUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR,
      new RadarGattWriteCallbacks(RadarGattWriteRole::WifiConfig));
  createProvisioningCharacteristic(
      service,
      kLocalLocationUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR,
      new RadarGattWriteCallbacks(RadarGattWriteRole::LocalLocation));
  deviceStatusCharacteristic = createProvisioningCharacteristic(
      service,
      kDeviceStatusUuid,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  createProvisioningCharacteristic(
      service,
      kServerConfigUuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR,
      new RadarGattWriteCallbacks(RadarGattWriteRole::ServerConfig));
  createProvisioningCharacteristic(
      service,
      kFirmwareControlUuid,
      BLECharacteristic::PROPERTY_WRITE,
      new RadarGattWriteCallbacks(RadarGattWriteRole::FirmwareControl));
  firmwareStatusCharacteristic = createProvisioningCharacteristic(
      service,
      kFirmwareStatusUuid,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kRadarBleServiceUuid);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  provisioning.serviceOnline = true;
  notifyDeviceStatus(true);
  notifyFirmwareStatus(true);
  Serial.print("BLE provisioning service online name=");
  Serial.print(provisioning.deviceName);
  Serial.print(" service=");
  Serial.println(kRadarBleServiceUuid);
}

void provisioningTick() {
  if (!kRemoteBleEnabled) {
    return;
  }

  const uint32_t now = millis();
  static uint32_t handledSecurityEventSerial = 0;
  const uint32_t securityEventSerial = bleSecurityEventSerial;
  if (securityEventSerial != handledSecurityEventSerial) {
    handledSecurityEventSerial = securityEventSerial;
    const int8_t result = bleSecurityEventResult;
    if (result == 0) {
      provisioning.lastWrite = "ble_pairing_code_displayed";
      if (displayOnline && !radarUiDisplayActive()) {
        wakeRadarDisplay();
      }
      Serial.println("BLE secure pairing code displayed on radar");
    } else if (result > 0) {
      provisioning.lastWrite = "ble_link_authenticated";
      Serial.println("BLE link authenticated with bonding, MITM and Secure Connections");
    } else {
      provisioning.lastWrite = "ble_link_authentication_failed";
      Serial.println("BLE link authentication failed");
    }
    notifyDeviceStatus(true);
  }

  const wl_status_t wifiStatus = WiFi.status();
  if (wifiStatus == WL_CONNECTED && provisioning.wifiConnectInFlight) {
    provisioning.wifiConnectInFlight = false;
    Serial.print("Wi-Fi connected ip=");
    Serial.print(WiFi.localIP());
    Serial.print(" rssi=");
    Serial.println(WiFi.RSSI());
    notifyDeviceStatus(true);
  }

  if (wifiStatus != lastLoggedWifiStatus || now - lastWifiStatusLogMs > 10000) {
    lastLoggedWifiStatus = wifiStatus;
    lastWifiStatusLogMs = now;
    Serial.print("Wi-Fi status=");
    Serial.print(wifiStatusText());
    Serial.print(" raw=");
    Serial.println(static_cast<int>(wifiStatus));
  }

  if (provisioning.wifiConnectRequested && provisioning.wifiSsid.length() > 0 &&
      wifiStatus != WL_CONNECTED &&
      (!provisioning.wifiConnectInFlight || now - lastWifiAttemptMs > 45000)) {
    lastWifiAttemptMs = now;
    if (provisioning.wifiConnectInFlight) {
      WiFi.disconnect(false, false);
      delay(80);
    }
    WiFi.mode(WIFI_STA);
    WiFi.begin(provisioning.wifiSsid.c_str(), provisioning.wifiPassword.c_str());
    provisioning.wifiConnectInFlight = true;
    Serial.print("Wi-Fi connect requested ssid=");
    Serial.println(provisioning.wifiSsid);
  }

  notifyDeviceStatus(false);
}

String urlEncode(const String &value) {
  const char *hex = "0123456789ABCDEF";
  String encoded;
  encoded.reserve(value.length() + 8);
  for (size_t i = 0; i < value.length(); ++i) {
    const uint8_t c = static_cast<uint8_t>(value[i]);
    if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
      encoded += static_cast<char>(c);
    } else {
      encoded += '%';
      encoded += hex[(c >> 4) & 0x0f];
      encoded += hex[c & 0x0f];
    }
  }
  return encoded;
}

bool parseRelayBaseUrl(const String &url, String &host, uint16_t &port, String &path, bool &secure) {
  String trimmed = url;
  trimmed.trim();
  secure = false;
  port = 0;
  path = "";

  int offset = 0;
  if (trimmed.startsWith("ws://")) {
    offset = 5;
    port = 80;
  } else if (trimmed.startsWith("wss://")) {
    offset = 6;
    port = 443;
    secure = true;
  } else {
    return false;
  }

  int pathStart = trimmed.indexOf('/', offset);
  String authority = pathStart >= 0 ? trimmed.substring(offset, pathStart) : trimmed.substring(offset);
  path = pathStart >= 0 ? trimmed.substring(pathStart) : "";
  if (path.endsWith("/")) {
    path.remove(path.length() - 1);
  }

  const int portSep = authority.lastIndexOf(':');
  if (portSep > 0) {
    host = authority.substring(0, portSep);
    const int parsedPort = authority.substring(portSep + 1).toInt();
    if (parsedPort <= 0 || parsedPort > 65535) {
      return false;
    }
    port = static_cast<uint16_t>(parsedPort);
  } else {
    host = authority;
  }

  host.trim();
  return host.length() > 0;
}

String relaySocketPath() {
  String path = "/v1/radar/device/ws?room=";
  path += urlEncode(provisioning.roomToken.length() > 0 ? provisioning.roomToken : "DRGN-LOCAL");
  path += "&device_id=";
  path += urlEncode(stableRelayIdentifier(provisioning.deviceToken, provisioning.deviceName));
  return path;
}

String localRelayPeerId() {
  return stableRelayIdentifier(provisioning.deviceToken, String(provisioning.deviceName));
}

String localAppRelayPeerId() {
  String peer = "app-";
  peer += localRelayPeerId();
  return peer;
}

int base64Value(char c) {
  if (c >= 'A' && c <= 'Z') {
    return c - 'A';
  }
  if (c >= 'a' && c <= 'z') {
    return c - 'a' + 26;
  }
  if (c >= '0' && c <= '9') {
    return c - '0' + 52;
  }
  if (c == '+') {
    return 62;
  }
  if (c == '/') {
    return 63;
  }
  return -1;
}

size_t decodeBase64Bytes(const String &encoded, uint8_t *out, size_t outCapacity) {
  uint32_t accumulator = 0;
  uint8_t bits = 0;
  size_t outLen = 0;
  for (size_t i = 0; i < encoded.length(); ++i) {
    const char c = encoded[i];
    if (c == '=') {
      break;
    }
    const int value = base64Value(c);
    if (value < 0) {
      continue;
    }
    accumulator = (accumulator << 6) | static_cast<uint32_t>(value);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      if (outLen >= outCapacity) {
        return outLen;
      }
      out[outLen++] = static_cast<uint8_t>((accumulator >> bits) & 0xff);
    }
  }
  return outLen;
}

bool ensureRelayRootCa() {
  if (relayRootCaPem.length() > 0) {
    return true;
  }
  const String encoded = DragonRadarFirmware::kOtaRootCaPemBase64;
  if (encoded.length() == 0) {
    return false;
  }
  static uint8_t decoded[4096];
  const size_t decodedLength = decodeBase64Bytes(encoded, decoded, sizeof(decoded) - 1);
  if (decodedLength == 0 || decodedLength >= sizeof(decoded)) {
    return false;
  }
  decoded[decodedLength] = 0;
  relayRootCaPem = String(reinterpret_cast<const char *>(decoded));
  return relayRootCaPem.indexOf("-----BEGIN CERTIFICATE-----") >= 0;
}

bool relayTlsClockReady() {
  if (time(nullptr) >= kMinimumRelayTlsEpoch) {
    if (relayTimeSyncInFlight) {
      Serial.println("Relay TLS clock synchronized");
    }
    relayTimeSyncInFlight = false;
    return true;
  }

  const uint32_t now = millis();
  if (relayTimeSyncInFlight) {
    if (now - relayTimeSyncStartedMs < kRelayTimeSyncTimeoutMs) {
      return false;
    }
    relayTimeSyncInFlight = false;
    if (provisioning.relayState != "time_sync_retry") {
      provisioning.relayState = "time_sync_retry";
      provisioning.lastWrite = "relay_time_sync_timeout";
      Serial.println("Relay TLS clock sync timed out; UI remains active and retry is scheduled");
      notifyDeviceStatus(true);
    }
    return false;
  }

  if (relayTimeSyncAttempted &&
      now - lastRelayTimeSyncAttemptMs < kRelayTimeSyncRetryMs) {
    return false;
  }

  // configTime starts ESP SNTP asynchronously. Never wait here: the main loop
  // must keep rendering and sampling the IMU while network time is acquired.
  configTime(0, 0, "time.cloudflare.com", "pool.ntp.org", "time.google.com");
  relayTimeSyncAttempted = true;
  relayTimeSyncInFlight = true;
  relayTimeSyncStartedMs = now;
  lastRelayTimeSyncAttemptMs = now;
  provisioning.relayState = "time_sync";
  provisioning.lastWrite = "relay_time_sync_started";
  Serial.println("Relay TLS clock sync started asynchronously");
  notifyDeviceStatus(true);
  return false;
}

void playRemoteVoicePcm(const uint8_t *pcmBytes, size_t byteLen) {
  if (!audioOnline || byteLen < sizeof(int16_t)) {
    return;
  }
  if (radarUiMode == RadarUiMode::Standby ||
      radarUiMode == RadarUiMode::ShutdownPending) {
    voiceCapture.playbackActive = false;
    return;
  }
  if (voiceCapture.pttActive || speakerMutedForCapture) {
    cancelPushToTalkDueToBusy("remote_voice_preempted");
  }
  tone.active = false;
  tone.remainingSamples = 0;
  bootAudioPlaying = false;
  digitalWrite(PA, HIGH);
  setCodecOutputMuted(false);
  if (!configureAudioTx(kAudioSampleRate)) {
    return;
  }

  const size_t monoSamples = min<size_t>(byteLen / sizeof(int16_t), kVoiceFrameSamples);
  int16_t stereo[kVoiceFrameSamples * 2];
  for (size_t i = 0; i < monoSamples; ++i) {
    const uint16_t raw = static_cast<uint16_t>(pcmBytes[i * 2]) |
                         (static_cast<uint16_t>(pcmBytes[i * 2 + 1]) << 8);
    const int16_t sample = static_cast<int16_t>(raw);
    stereo[i * 2] = sample;
    stereo[i * 2 + 1] = sample;
  }
  i2s.write(reinterpret_cast<uint8_t *>(stereo), monoSamples * 2 * sizeof(int16_t));
  voiceCapture.playbackActive = true;
  voiceCapture.lastPlaybackMs = millis();
}

bool handleRelayVoiceFrame(const String &json) {
  if (json.indexOf("\"type\":\"relay_event\"") < 0 ||
      json.indexOf("\"event\":\"voice_frame\"") < 0) {
    return false;
  }

  String from;
  if (extractJsonStringValue(json, "from", from) && from == localRelayPeerId()) {
    return true;
  }

  String audioB64;
  if (!extractJsonStringValue(json, "audio_b64", audioB64) || audioB64.length() == 0) {
    return true;
  }

  int32_t sequence = 0;
  extractJsonIntValue(json, "sequence", sequence);
  uint8_t pcm[kVoicePcmBytes];
  const size_t decodedBytes = decodeBase64Bytes(audioB64, pcm, sizeof(pcm));
  if (decodedBytes < sizeof(int16_t)) {
    return true;
  }

  voiceCapture.receivedSequence = sequence > 0 ? static_cast<uint32_t>(sequence) : voiceCapture.receivedSequence + 1;
  remoteRoomSpeakerActive = true;
  remoteRoomSpeakerUntilMs = millis() + kRemoteSpeakingHoldMs;
  playRemoteVoicePcm(pcm, decodedBytes);
  if (kSerialDiagnostics) {
    Serial.print("DIAG voice_rx from=");
    Serial.print(from.length() > 0 ? from : "peer");
    Serial.print(" seq=");
    Serial.print(voiceCapture.receivedSequence);
    Serial.print(" bytes=");
    Serial.println(decodedBytes);
  }
  notifyDeviceStatus(true);
  return true;
}

bool handleRelayVoiceBusy(const String &json) {
  if (json.indexOf("\"type\":\"voice_busy\"") < 0) {
    return false;
  }
  remoteRoomSpeakerActive = true;
  remoteRoomSpeakerUntilMs = millis() + kRemoteSpeakingHoldMs;
  cancelPushToTalkDueToBusy("voice_busy");
  provisioning.lastWrite = "voice_busy";
  notifyDeviceStatus(true);
  if (kSerialDiagnostics) {
    Serial.println("DIAG voice=busy");
  }
  return true;
}

bool handleRelayRoomSwitch(const String &json) {
  if (json.indexOf("\"type\":\"relay_event\"") < 0 ||
      json.indexOf("\"event\":\"room_switch\"") < 0) {
    return false;
  }

  String from;
  extractJsonStringValue(json, "from", from);
  if (from.length() > 0 && from != localAppRelayPeerId()) {
    return true;
  }

  String relayUrl;
  String roomToken;
  extractJsonStringValue(json, "relay_url", relayUrl);
  extractJsonStringValue(json, "room_token", roomToken);
  if (relayUrl == provisioning.relayUrl &&
      roomToken == provisioning.roomToken) {
    provisioning.lastWrite = "relay_room_switch_same";
    notifyDeviceStatus(true);
    return true;
  }

  return applyServerConfigJson(json, "relay");
}

void sendRelayJson(String payload) {
  if (!provisioning.relayConnected) {
    return;
  }
  relaySocket.sendTXT(payload);
}

void sendRelayHello() {
  String payload = "{\"type\":\"hello\",\"device_id\":\"";
  payload += jsonEscape(localRelayPeerId());
  payload += "\",\"name\":\"";
  payload += jsonEscape(provisioning.deviceName);
  payload += "\",\"firmware\":\"";
  payload += DragonRadarFirmware::kVersion;
  payload += "\",\"firmware_build\":";
  payload += String(DragonRadarFirmware::kBuild);
  payload += ",\"hardware\":\"";
  payload += DragonRadarFirmware::kHardware;
  payload += "\",\"security_counter\":";
  payload += String(DragonRadarFirmware::kSecurityCounter);
  payload += ",\"protocol_version\":";
  payload += String(DRAGON_RADAR_PROTOCOL_VERSION);
  payload += ",\"min_relay_protocol_version\":";
  payload += String(DRAGON_RADAR_MIN_RELAY_PROTOCOL_VERSION);
  payload += ",\"capabilities\":[\"display\",\"ble\",\"wifi\",\"location\",\"ptt_voice\",\"ota_pull\",\"ota_confirm\"]";
  payload += ",\"room\":\"";
  payload += jsonEscape(provisioning.roomToken);
  payload += "\"}";
  sendRelayJson(payload);
}

void sendRelayDeviceStatus() {
  String payload = "{\"type\":\"device_status\",\"device_id\":\"";
  payload += jsonEscape(localRelayPeerId());
  payload += "\",\"status\":";
  payload += buildDeviceStatusJson(true);
  payload += "}";
  sendRelayJson(payload);
}

void sendRelayVoiceFrame(const int16_t *pcm, size_t sampleCount, bool includeAudio) {
  if (!provisioning.relayConnected) {
    return;
  }

  includeAudio = includeAudio && pcm != nullptr && sampleCount > 0 &&
                 voiceCapture.pttActive && !voiceCapture.muted;
  const size_t pcmBytes = min<size_t>(sampleCount, kVoiceFrameSamples) * sizeof(int16_t);
  String payload = "{\"type\":\"voice_frame\",\"device_id\":\"";
  payload += jsonEscape(localRelayPeerId());
  payload += "\",\"voice_status\":{";
  payload += "\"muted\":";
  payload += voiceCapture.muted ? "true" : "false";
  payload += ",\"ptt\":";
  payload += voiceCapture.pttActive ? "true" : "false";
  payload += ",\"vad\":";
  payload += voiceCapture.vadActive ? "true" : "false";
  payload += ",\"codec\":\"";
  payload += includeAudio ? "pcm16" : "status-only";
  payload += "\"";
  payload += ",\"sample_rate\":";
  payload += String(kAudioSampleRate);
  payload += ",\"frame_ms\":";
  payload += String(kVoiceFrameDurationMs);
  payload += ",\"sequence\":";
  payload += String(voiceCapture.sequence);
  payload += ",\"rms\":";
  payload += String(voiceCapture.rms);
  payload += ",\"peak\":";
  payload += String(voiceCapture.peak);
  payload += "},\"muted\":";
  payload += voiceCapture.muted ? "true" : "false";
  payload += ",\"ptt\":";
  payload += voiceCapture.pttActive ? "true" : "false";
  payload += ",\"vad\":";
  payload += voiceCapture.vadActive ? "true" : "false";
  payload += ",\"codec\":\"";
  payload += includeAudio ? "pcm16" : "status-only";
  payload += "\",\"sample_rate\":";
  payload += String(kAudioSampleRate);
  payload += ",\"frame_ms\":";
  payload += String(kVoiceFrameDurationMs);
  payload += ",\"sequence\":";
  payload += String(voiceCapture.sequence);
  if (includeAudio) {
    payload += ",\"audio_b64\":\"";
    payload += base64::encode(reinterpret_cast<const uint8_t *>(pcm), pcmBytes);
    payload += "\"";
  }
  payload += "}";
  sendRelayJson(payload);
}

void sendRelayHeartbeat() {
  String payload = "{\"type\":\"heartbeat\",\"device_id\":\"";
  payload += jsonEscape(localRelayPeerId());
  payload += "\",\"uptime_ms\":";
  payload += String(millis());
  payload += "}";
  sendRelayJson(payload);
}

void cloudRelayEvent(WStype_t type, uint8_t *payload, size_t length) {
  switch (type) {
    case WStype_CONNECTED:
      provisioning.relayConnected = true;
      provisioning.relayState = "connected";
      provisioning.lastWrite = "relay_connected";
      lastRelayHeartbeatMs = 0;
      Serial.println("Relay connected");
      sendRelayHello();
      sendRelayDeviceStatus();
      notifyDeviceStatus(true);
      break;
    case WStype_DISCONNECTED:
      if (provisioning.relayConnected) {
        Serial.println("Relay disconnected");
      }
      provisioning.relayConnected = false;
      provisioning.relayState = "disconnected";
      notifyDeviceStatus(true);
      break;
    case WStype_TEXT: {
      String text;
      text.reserve(length);
      for (size_t i = 0; i < length; ++i) {
        text += static_cast<char>(payload[i]);
      }
      Serial.print("Relay event received bytes=");
      Serial.println(length);
      noteRelayServerTime(text);
      handleRelayVoiceBusy(text);
      handleRelayVoiceFrame(text);
      handleRelayRoomSwitch(text);
      if (text.indexOf("\"type\":\"relay_event\"") >= 0 &&
          text.indexOf("\"event\":\"app_location\"") >= 0 &&
          parseRelayAppLocation(text)) {
        notifyDeviceStatus(true);
        const RemoteLocationFrame &loggedFrame =
            lastRelayAppLocationWasSelf ? selfLocationFrame : remoteAppLocationFrame;
        Serial.print(lastRelayAppLocationWasSelf ? "Relay self_location latE7=" : "Relay app_location latE7=");
        Serial.print(loggedFrame.latE7);
        Serial.print(" lonE7=");
        Serial.print(loggedFrame.lonE7);
        Serial.print(" accCm=");
        Serial.print(loggedFrame.horizontalAccuracyCm);
        if (!lastRelayAppLocationWasSelf && selfLocationFrame.valid && selfLocationFrame.receivedMs > 0) {
          Serial.print(" distanceM=");
          Serial.print(geoDistanceMeters(selfLocationFrame, remoteAppLocationFrame), 1);
          Serial.print(" bearing=");
          Serial.print(geoBearingDeg(selfLocationFrame, remoteAppLocationFrame), 1);
        }
        Serial.println();
      }
      if (text.indexOf("\"type\":\"room_state\"") >= 0) {
        if (parseRelayRoomState(text)) {
          Serial.print("Relay room_state locations self=");
          Serial.print(selfLocationFrame.valid ? "yes" : "no");
          Serial.print(" remoteCount=");
          Serial.println(activeRemoteAppLocationCount(millis()));
        }
        provisioning.relayState = "room_state";
        notifyDeviceStatus(true);
      }
      break;
    }
    case WStype_ERROR:
      provisioning.relayConnected = false;
      provisioning.relayState = "error";
      Serial.println("Relay error");
      notifyDeviceStatus(true);
      break;
    default:
      break;
  }
}

void connectCloudRelay() {
  String host;
  String basePath;
  uint16_t port = 0;
  bool secure = false;
  if (!parseRelayBaseUrl(provisioning.relayUrl, host, port, basePath, secure)) {
    provisioning.relayState = "invalid_url";
    Serial.println("Relay invalid configured URL");
    notifyDeviceStatus(true);
    return;
  }
  if (!secure && !DragonRadarFirmware::kAllowInsecureRelay) {
    if (provisioning.relayState != "insecure_relay_blocked") {
      provisioning.relayState = "insecure_relay_blocked";
      provisioning.lastWrite = "relay_ws_blocked";
      Serial.println("Relay insecure WS blocked; explicit development HTTP build is required");
      notifyDeviceStatus(true);
    }
    return;
  }
  if (secure && !relayTlsClockReady()) {
    return;
  }

  String path = basePath;
  path += relaySocketPath();
  relaySocket.disconnect();
  relaySocket.onEvent(cloudRelayEvent);
  relaySocket.setReconnectInterval(kRelayReconnectMs);
  if (secure) {
    if (!ensureRelayRootCa()) {
      provisioning.relayState = "tls_ca_missing";
      provisioning.relaySocketConfigured = false;
      provisioning.relayConnected = false;
      Serial.println("Relay TLS CA missing; refusing insecure WSS connection");
      notifyDeviceStatus(true);
      return;
    }
    relaySocket.beginSslWithCA(host.c_str(), port, path.c_str(), relayRootCaPem.c_str());
  } else {
    relaySocket.begin(host.c_str(), port, path.c_str());
  }
  String authorization = "Bearer ";
  authorization += provisioning.deviceToken;
  relaySocket.setAuthorization(authorization.c_str());
  provisioning.relaySocketConfigured = true;
  provisioning.relayConnected = false;
  provisioning.relayState = "connecting";
  Serial.print("Relay connect endpoint=");
  Serial.print(secure ? "wss://" : "ws://");
  Serial.print(host);
  Serial.print(":");
  Serial.print(port);
  Serial.println("/<redacted>");
  notifyDeviceStatus(true);
}

void cloudRelayTick() {
  if (!kRemoteBleEnabled || !provisioning.serverConfigured) {
    return;
  }
  if (otaManager.blocksPowerAndVoice()) {
    if (provisioning.relaySocketConfigured || provisioning.relayConnected) {
      relaySocket.disconnect();
      provisioning.relaySocketConfigured = false;
      provisioning.relayConnected = false;
    }
    if (provisioning.relayState != "ota") {
      provisioning.relayState = "ota";
      notifyDeviceStatus(true);
    }
    return;
  }
  const uint32_t now = millis();
  if (WiFi.status() != WL_CONNECTED) {
    if (provisioning.relaySocketConfigured) {
      relaySocket.disconnect();
      provisioning.relaySocketConfigured = false;
      provisioning.relayConnected = false;
      provisioning.relayState = "waiting_wifi";
      notifyDeviceStatus(true);
    }
    return;
  }

  if (!provisioning.relaySocketConfigured && now - lastRelayAttemptMs > kRelayReconnectMs) {
    lastRelayAttemptMs = now;
    connectCloudRelay();
  }

  if (provisioning.relaySocketConfigured) {
    relaySocket.loop();
  }

  if (provisioning.relayConnected && now - lastRelayHeartbeatMs > kRelayHeartbeatMs) {
    lastRelayHeartbeatMs = now;
    sendRelayHeartbeat();
    sendRelayDeviceStatus();
  }

  if (now - lastRelayStatusMs > kRelayStatusMs) {
    lastRelayStatusMs = now;
    notifyDeviceStatus(false);
  }
}

void beginPushToTalk() {
  if (otaManager.blocksPowerAndVoice()) {
    provisioning.lastWrite = "ota_ptt_blocked";
    notifyDeviceStatus(true);
    return;
  }
  if (voiceCapture.pttActive) {
    return;
  }
  if (remoteRoomVoiceBusy()) {
    provisioning.lastWrite = "ptt_busy";
    notifyDeviceStatus(true);
    if (kSerialDiagnostics) {
      Serial.println("DIAG ptt=busy");
    }
    return;
  }
  pttRippleStartedMs = millis();
  pttRippleEndedMs = 0;
  tone.active = false;
  tone.remainingSamples = 0;
  bootAudioPlaying = false;
  voiceCapture.playbackActive = false;
  voiceCapture.pttActive = true;
  voiceCapture.vadActive = false;
  voiceCapture.lastFrameMs = 0;
  setSpeakerMutedForCapture(true);
  provisioning.lastWrite = "ptt_start";
  notifyDeviceStatus(true);
  if (kSerialDiagnostics) {
    Serial.println("DIAG ptt=start");
  }
}

void cancelPushToTalkDueToBusy(const char *reason) {
  if (!voiceCapture.pttActive && !speakerMutedForCapture) {
    return;
  }
  voiceCapture.pttActive = false;
  voiceCapture.vadActive = false;
  voiceCapture.playbackActive = false;
  pttRippleEndedMs = millis();
  setSpeakerMutedForCapture(false);
  provisioning.lastWrite = reason;
  if (provisioning.relayConnected) {
    ++voiceCapture.sequence;
    sendRelayVoiceFrame(nullptr, 0, false);
  }
  notifyDeviceStatus(true);
  if (kSerialDiagnostics) {
    Serial.print("DIAG ptt=cancel reason=");
    Serial.println(reason);
  }
}

void endPushToTalk() {
  if (!voiceCapture.pttActive) {
    return;
  }
  voiceCapture.pttActive = false;
  voiceCapture.vadActive = false;
  pttRippleEndedMs = millis();
  setSpeakerMutedForCapture(false);
  provisioning.lastWrite = "ptt_stop";
  if (provisioning.relayConnected) {
    ++voiceCapture.sequence;
    sendRelayVoiceFrame(nullptr, 0, false);
  }
  notifyDeviceStatus(true);
  if (kSerialDiagnostics) {
    Serial.println("DIAG ptt=stop");
  }
}

void voiceCaptureTick() {
  if (!voiceInputOnline) {
    voiceCapture.captureOnline = false;
    voiceCapture.vadActive = false;
    return;
  }

  const uint32_t now = millis();
  if (voiceCapture.playbackActive && now - voiceCapture.lastPlaybackMs > 120) {
    voiceCapture.playbackActive = false;
  }
  if (now - voiceCapture.lastSampleMs < kVoiceSampleTickMs) {
    return;
  }
  voiceCapture.lastSampleMs = now;
  voiceCapture.captureOnline = true;

  if (tone.active || bootAudioPlaying) {
    voiceCapture.vadActive = false;
    voiceCapture.rms = 0;
    voiceCapture.peak = 0;
    return;
  }
  if (!configureAudioRx()) {
    voiceCapture.captureOnline = false;
    voiceCapture.vadActive = false;
    voiceCapture.rms = 0;
    voiceCapture.peak = 0;
    return;
  }

  int16_t stereoSamples[kVoiceFrameSamples * 2];
  int16_t monoPcm[kVoiceFrameSamples];
  const bool rxMono = i2s.rxSlotMode() == I2S_SLOT_MODE_MONO;
  const size_t requestedBytes = (rxMono ? kVoiceFrameSamples : kVoiceFrameSamples * 2) * sizeof(int16_t);
  const size_t readBytes = i2s.readBytes(reinterpret_cast<char *>(stereoSamples), requestedBytes);
  const size_t sampleCount = readBytes / sizeof(int16_t);
  if (sampleCount == 0) {
    voiceCapture.vadActive = false;
    voiceCapture.rms = 0;
    voiceCapture.peak = 0;
    return;
  }

  uint64_t sumSquares = 0;
  uint16_t peak = 0;
  size_t monoSamples = 0;
  for (size_t i = 0; i < sampleCount && monoSamples < kVoiceFrameSamples; i += rxMono ? 1 : 2) {
    const int32_t first = stereoSamples[i];
    const int32_t second = (!rxMono && i + 1 < sampleCount) ? stereoSamples[i + 1] : first;
    const uint32_t firstMagnitude = static_cast<uint32_t>(first < 0 ? -first : first);
    const uint32_t secondMagnitude = static_cast<uint32_t>(second < 0 ? -second : second);
    const int32_t sample = secondMagnitude > firstMagnitude ? second : first;
    monoPcm[monoSamples++] = static_cast<int16_t>(sample);
    const uint32_t magnitude = max<uint32_t>(firstMagnitude, secondMagnitude);
    peak = max<uint16_t>(peak, static_cast<uint16_t>(min<uint32_t>(magnitude, UINT16_MAX)));
    const int64_t signedSample = sample;
    sumSquares += static_cast<uint64_t>(signedSample * signedSample);
  }

  if (monoSamples == 0) {
    voiceCapture.vadActive = false;
    voiceCapture.rms = 0;
    voiceCapture.peak = 0;
    return;
  }

  const uint32_t meanSquare = monoSamples > 0 ? static_cast<uint32_t>(sumSquares / monoSamples) : 0;
  const uint16_t rms = static_cast<uint16_t>(min<uint32_t>(sqrtf(static_cast<float>(meanSquare)), UINT16_MAX));
  voiceCapture.rms = rms;
  voiceCapture.peak = peak;
  voiceCapture.vadActive = voiceCapture.pttActive && !voiceCapture.muted &&
                           (rms >= kVoiceVadRmsThreshold || peak >= kVoiceVadPeakThreshold);

  const uint32_t voiceFrameIntervalMs = voiceCapture.pttActive ? kVoiceFrameTickMs : 200;
  if (provisioning.relayConnected && now - voiceCapture.lastFrameMs >= voiceFrameIntervalMs) {
    voiceCapture.lastFrameMs = now;
    ++voiceCapture.sequence;
    sendRelayVoiceFrame(monoPcm, monoSamples, voiceCapture.pttActive);
    if (kSerialDiagnostics) {
      Serial.print("DIAG voice seq=");
      Serial.print(voiceCapture.sequence);
      Serial.print(" ptt=");
      Serial.print(voiceCapture.pttActive ? 1 : 0);
      Serial.print(" vad=");
      Serial.print(voiceCapture.vadActive ? 1 : 0);
      Serial.print(" rms=");
      Serial.print(voiceCapture.rms);
      Serial.print(" peak=");
      Serial.print(voiceCapture.peak);
      Serial.print(" audio=");
      Serial.println(voiceCapture.pttActive ? "pcm16" : "status");
    }
  }
}

int halfPixelFloorOffset(int halfPx) {
  if (halfPx >= 0) {
    return halfPx / 2;
  }
  return -(((-halfPx) + 1) / 2);
}

void drawGridHLineHalfOffset(int x, int y, int width, uint16_t color, uint16_t halfColor) {
  const int xBase = halfPixelFloorOffset(kRadarGridXOffsetHalfPx);
  const int yBase = halfPixelFloorOffset(kRadarGridYOffsetHalfPx);
  const bool splitY = (kRadarGridYOffsetHalfPx & 1) != 0;
  if (splitY) {
    gfx->drawFastHLine(x + xBase, y + yBase, width, halfColor);
    gfx->drawFastHLine(x + xBase, y + yBase + 1, width, halfColor);
  } else {
    gfx->drawFastHLine(x + xBase, y + yBase, width, color);
  }
}

void drawGridVLineHalfOffset(int x, int y, int height, uint16_t color, uint16_t halfColor) {
  const int xBase = halfPixelFloorOffset(kRadarGridXOffsetHalfPx);
  const int yBase = halfPixelFloorOffset(kRadarGridYOffsetHalfPx);
  const bool splitX = (kRadarGridXOffsetHalfPx & 1) != 0;
  if (splitX) {
    gfx->drawFastVLine(x + xBase, y + yBase, height, halfColor);
    gfx->drawFastVLine(x + xBase + 1, y + yBase, height, halfColor);
  } else {
    gfx->drawFastVLine(x + xBase, y + yBase, height, color);
  }
}

void rotateRadarGridPoint(float worldX, float worldY,
                          float cosRotation, float sinRotation,
                          int &screenX, int &screenY) {
  screenX = kCx + static_cast<int>(roundf(worldX * cosRotation - worldY * sinRotation));
  screenY = kCy + static_cast<int>(roundf(worldX * sinRotation + worldY * cosRotation));
}

void drawRadarGrid() {
  gfx->fillScreen(kBlack);
  gfx->fillCircle(kCx, kCy, kRadarGridRadius, kScreenBg);

  const int pitch = currentGridPitch();
  const uint16_t gridColor = RGB565(12, 157, 71);
  const uint16_t gridHalfColor = RGB565(7, 104, 50);
  const int start = -((kRadarGridRadius / pitch) * pitch);
  const float rotationDeg = renderedRadarRotationDeg;
  const bool rotated = fabsf(shortestAngleDelta(0.0f, rotationDeg)) >= 0.05f;
  const float rotationRad = degToRad(rotationDeg);
  const float cosRotation = cosf(rotationRad);
  const float sinRotation = sinf(rotationRad);

  for (int offset = start; offset <= -start; offset += pitch) {
    const int half = circleChordHalf(offset, kRadarGridRadius);
    if (half <= 0) {
      continue;
    }
    if (!rotated) {
      drawGridHLineHalfOffset(kCx - half, kCy + offset, half * 2, gridColor, gridHalfColor);
      drawGridVLineHalfOffset(kCx + offset, kCy - half, half * 2, gridColor, gridHalfColor);
      continue;
    }

    int x0;
    int y0;
    int x1;
    int y1;
    rotateRadarGridPoint(-half, offset, cosRotation, sinRotation, x0, y0);
    rotateRadarGridPoint(half, offset, cosRotation, sinRotation, x1, y1);
    gfx->drawLine(x0, y0, x1, y1, gridColor);

    rotateRadarGridPoint(offset, -half, cosRotation, sinRotation, x0, y0);
    rotateRadarGridPoint(offset, half, cosRotation, sinRotation, x1, y1);
    gfx->drawLine(x0, y0, x1, y1, gridColor);
  }

  if (kShowDebugHud) {
    gfx->fillCircle(kCx, kCy, 5, kGridBright);
    gfx->drawFastHLine(kCx - 15, kCy, 30, kGridBright);
    gfx->drawFastVLine(kCx, kCy - 15, 30, kGridBright);

    drawCenteredText("CAPSULE RADAR", 22, 2, kGridBright);
    gfx->setTextSize(1);
    gfx->setTextColor(kGridDim);
    gfx->setCursor(46, 424);
    gfx->print(provisioning.relayConnected ? "ROOM" : "BLE");
    gfx->setCursor(360, 424);
    gfx->print(scanning ? "SCAN" : "HOLD");
  }
}

void drawDisplaySelfTest() {
  gfx->fillScreen(kBlack);
  gfx->drawCircle(kCx, kCy, kRadarRadius, kGridBright);
  gfx->drawCircle(kCx, kCy, kRadarRadius - 1, kGridDim);
  gfx->drawFastHLine(kCx - kRadarRadius, kCy, kRadarRadius * 2, kRed);
  gfx->drawFastVLine(kCx, kCy - kRadarRadius, kRadarRadius * 2, kBlue);

  for (int offset = -192; offset <= 192; offset += 48) {
    const int half = circleChordHalf(offset);
    if (half > 0) {
      gfx->drawFastHLine(kCx - half, kCy + offset, half * 2, kGridDim);
      gfx->drawFastVLine(kCx + offset, kCy - half, half * 2, kGridDim);
    }
  }

  gfx->fillRect(34, 34, 26, 26, kRed);
  gfx->fillRect(kScreenW - 60, 34, 26, 26, kGridBright);
  gfx->fillRect(34, kScreenH - 60, 26, 26, kBlue);
  gfx->fillRect(kScreenW - 60, kScreenH - 60, 26, 26, kAmber);
  gfx->fillCircle(kCx, kCy, 7, kWhite);
  gfx->setTextSize(2);
  gfx->setTextColor(kWhite);
  gfx->setCursor(kCx - 72, kCy - 36);
  gfx->print("DISPLAY");
  gfx->setCursor(kCx - 42, kCy + 28);
  gfx->print("TEST");
}

void drawSweep() {
  if (!scanning) {
    return;
  }
  drawRotatingScan(millis(), kScan, kGrid);
}

void drawIdleSearchLattice(uint32_t now) {
  if (kShowDebugHud || activeRemoteAppLocationCount(now) > 0) {
    return;
  }

  const int left = kCx - kRadarRadius + 42;
  const int right = kCx + kRadarRadius - 42;
  const int top = kCy - kRadarRadius + 42;
  const int bottom = kCy + kRadarRadius - 42;
  const uint8_t phase = (now / 118) % kIdleSearchTickCount;
  const bool flash = ((now / 94) & 1) == 0;
  const uint16_t active = flash ? kGridBright : kGrid;
  const uint16_t dim = flash ? kGridDim : kGridDeep;

  for (uint8_t i = 0; i < kIdleSearchTickCount; ++i) {
    const int x = left + (right - left) * i / (kIdleSearchTickCount - 1);
    const int y = top + (bottom - top) * i / (kIdleSearchTickCount - 1);
    const bool on = i == phase || ((i + 1) % kIdleSearchTickCount) == phase;
    gfx->drawRect(x - 4, top, 8, 4, on ? active : dim);
    gfx->drawRect(x - 4, bottom - 4, 8, 4, on ? active : dim);
    gfx->drawRect(left, y - 4, 4, 8, on ? active : dim);
    gfx->drawRect(right - 4, y - 4, 4, 8, on ? active : dim);
    if (on && flash) {
      gfx->fillRect(x - 2, top + 1, 4, 2, active);
      gfx->fillRect(x - 2, bottom - 3, 4, 2, active);
      gfx->fillRect(left + 1, y - 2, 2, 4, active);
      gfx->fillRect(right - 3, y - 2, 2, 4, active);
    }
  }

  drawRotatingScan(now, active, dim, 8);

  const int box = 22 + static_cast<int>((now / 180) % 3) * 4;
  gfx->drawRect(kCx - box, kCy - box, box * 2, box * 2, dim);
  drawHomeMarker(now);
}

void drawTiltInertiaGrid(uint32_t now) {
  if (kShowDebugHud || tiltEnergy < 0.16f) {
    return;
  }

  const float energy = clampf(tiltEnergy / 1.35f, 0.0f, 1.0f);
  const int skewX = static_cast<int>(clampf(tiltVectorX, -0.8f, 0.8f) * 22.0f);
  const int skewY = static_cast<int>(clampf(tiltVectorY, -0.8f, 0.8f) * 22.0f);
  const int left = kCx - 132 + skewX;
  const int right = kCx + 132 + skewX;
  const int top = kCy - 132 + skewY;
  const int bottom = kCy + 132 + skewY;
  const bool flash = ((now / 74) & 1) == 0;
  const uint16_t active = flash ? kGridBright : kGrid;
  const uint16_t dim = flash ? kGrid : kGridDim;
  const uint8_t lit = 1 + static_cast<uint8_t>(energy * (kTiltInertiaTickCount - 1));

  gfx->drawRect(left - 3, top - 3, 6, 6, dim);
  gfx->drawRect(right - 3, top - 3, 6, 6, dim);
  gfx->drawRect(left - 3, bottom - 3, 6, 6, dim);
  gfx->drawRect(right - 3, bottom - 3, 6, 6, dim);
  gfx->drawFastHLine(left, top, 48, active);
  gfx->drawFastVLine(left, top, 48, active);
  gfx->drawFastHLine(right - 48, top, 48, active);
  gfx->drawFastVLine(right, top, 48, active);
  gfx->drawFastHLine(left, bottom, 48, active);
  gfx->drawFastVLine(left, bottom - 48, 48, active);
  gfx->drawFastHLine(right - 48, bottom, 48, active);
  gfx->drawFastVLine(right, bottom - 48, 48, active);

  for (uint8_t i = 0; i < kTiltInertiaTickCount; ++i) {
    const bool on = i < lit;
    const uint16_t c = on ? active : dim;
    const int offset = 8 + i * 9;
    gfx->drawRect(left + offset, top - 7, 6, 4, c);
    gfx->drawRect(right - offset - 6, bottom + 3, 6, 4, c);
    gfx->drawRect(left - 7, bottom - offset - 6, 4, 6, c);
    gfx->drawRect(right + 3, top + offset, 4, 6, c);
    if (on && flash) {
      gfx->fillRect(left + offset + 1, top - 6, 4, 2, active);
      gfx->fillRect(right - offset - 5, bottom + 4, 4, 2, active);
      gfx->fillRect(left - 6, bottom - offset - 5, 2, 4, active);
      gfx->fillRect(right + 4, top + offset + 1, 2, 4, active);
    }
  }
}

void drawStartupAcquireOverlay() {
  if (radarStartedMs == 0) {
    return;
  }

  const uint32_t now = millis();
  const uint32_t elapsed = now - radarStartedMs;
  if (elapsed > kStartupAcquireMs) {
    return;
  }

  const float t = clampf(elapsed / static_cast<float>(kStartupAcquireMs), 0.0f, 1.0f);
  const bool flash = ((elapsed / 72) & 1) == 0;
  const uint16_t c = flash ? kGridBright : kGrid;
  const int left = kCx - kRadarRadius + 38;
  const int right = kCx + kRadarRadius - 38;
  const int top = kCy - kRadarRadius + 38;
  const int bottom = kCy + kRadarRadius - 38;
  const int corner = 34;
  const int inset = static_cast<int>(smoothStep(0.0f, 0.55f, t) * 10.0f);

  gfx->drawFastHLine(left + inset, top, corner, c);
  gfx->drawFastVLine(left, top + inset, corner, c);
  gfx->drawFastHLine(right - corner - inset, top, corner, c);
  gfx->drawFastVLine(right, top + inset, corner, c);
  gfx->drawFastHLine(left + inset, bottom, corner, c);
  gfx->drawFastVLine(left, bottom - corner - inset, corner, c);
  gfx->drawFastHLine(right - corner - inset, bottom, corner, c);
  gfx->drawFastVLine(right, bottom - corner - inset, corner, c);

  const float scanPhase = smoothStep(0.08f, 0.92f, t);
  const float scanAngle = degToRad(scanPhase * 360.0f - 90.0f);
  const float trailAngle = degToRad(scanPhase * 360.0f - 97.0f);
  const int scanRadius = kRadarRadius - 10;
  const int trailRadius = kRadarRadius - 34;
  drawThickLine(kCx, kCy, kCx + static_cast<int>(cosf(scanAngle) * scanRadius),
                kCy + static_cast<int>(sinf(scanAngle) * scanRadius), c, 2);
  drawThickLine(kCx, kCy, kCx + static_cast<int>(cosf(trailAngle) * trailRadius),
                kCy + static_cast<int>(sinf(trailAngle) * trailRadius), kGridDim, 1);

  const int tickY = bottom + 13;
  const int startX = kCx - 54;
  for (int i = 0; i < 7; ++i) {
    const bool on = t * 7.0f >= i + 0.32f;
    gfx->drawRect(startX + i * 18, tickY, 8, 4, on ? c : kGridDim);
    if (on && flash) {
      gfx->fillRect(startX + i * 18 + 2, tickY + 1, 4, 2, c);
    }
  }
}

void drawMemberMarker(int x, int y, int memberIndex, bool fresh, bool trace, uint8_t pulse) {
  // A location refresh must never make an existing member disappear. The
  // first-arrival state is kept for optional decoration, while the marker remains solid.
  (void)fresh;
  constexpr int radius = 7;
  const uint16_t outer = trace ? RGB565(78, 54, 18) : RGB565(138, 42, 0);
  const uint16_t body = trace ? RGB565(132, 112, 28) : RGB565(255, 122, 22);

  gfx->fillCircle(x, y, radius + 2, outer);
  gfx->fillCircle(x, y, radius, body);
  gfx->fillCircle(x - 2, y - 2, 2, kAmber);
  gfx->drawPixel(x - 3, y - 3, kWhite);
  (void)memberIndex;
  (void)pulse;
}

void formatDistanceLabel(float meters, char *buf, size_t len) {
  if (meters < 995.0f) {
    snprintf(buf, len, "%dm", static_cast<int>(roundf(meters)));
  } else if (meters < 9950.0f) {
    snprintf(buf, len, "%.1fkm", meters / 1000.0f);
  } else {
    snprintf(buf, len, "%.0fkm", meters / 1000.0f);
  }
}

void drawDistanceLabel(int x, int y, float meters) {
  if (!isfinite(meters) || meters < 0.0f) {
    return;
  }

  char buf[12];
  formatDistanceLabel(meters, buf, sizeof(buf));
  const int textW = static_cast<int>(strlen(buf)) * 6 * kDistanceLabelTextSize;
  const int textH = 8 * kDistanceLabelTextSize;
  int tx = constrain(x - textW / 2, kCx - kRadarGridRadius + 18,
                     kCx + kRadarGridRadius - textW - 18);
  int ty = y + 18;
  if (ty + textH > kCy + kRadarGridRadius - 16) {
    ty = y - textH - 12;
  }
  ty = constrain(ty, kCy - kRadarGridRadius + 16,
                 kCy + kRadarGridRadius - textH - 16);

  gfx->fillRect(tx - 5, ty - 4, textW + 10, textH + 7, kBlack);
  gfx->drawRect(tx - 6, ty - 5, textW + 12, textH + 9, kGridDeep);
  gfx->setTextSize(kDistanceLabelTextSize);
  gfx->setTextColor(kGridBright);
  gfx->setCursor(tx, ty);
  gfx->print(buf);
}

void drawMotionBadge(int x, int y, float courseDeg, float speedMps) {
  if (!isfinite(courseDeg) || !isfinite(speedMps)) {
    return;
  }

  constexpr int kMarkerRadius = 7;
  constexpr int kHiddenBoxSide = kMarkerRadius * 2;
  constexpr int kHiddenBoxGap = 4;
  constexpr int kCellOffset = 5;
  const int boxCx = x - kMarkerRadius - kHiddenBoxGap - kHiddenBoxSide / 2;
  const int boxCy = y;

  int cellX = 0;
  int cellY = 0;
  if (speedMps >= 0.05f) {
    const int bin = static_cast<int>(floorf((wrap360(courseDeg) + 22.5f) / 45.0f)) & 7;
    static const int8_t kDirCells[8][2] = {
        {0, -1}, {1, -1}, {1, 0}, {1, 1},
        {0, 1}, {-1, 1}, {-1, 0}, {-1, -1},
    };
    cellX = kDirCells[bin][0];
    cellY = kDirCells[bin][1];
  }

  const uint16_t color = speedMps >= 1.4f ? kGridBright : (speedMps >= 0.45f ? kGrid : kGridDim);
  const int px = boxCx + cellX * kCellOffset;
  const int py = boxCy + cellY * kCellOffset;

  if (cellX == 0 && cellY == 0) {
    const int dotR = speedMps >= 1.4f ? 2 : 1;
    gfx->fillCircle(px + 1, py + 1, dotR + 1, kBlack);
    gfx->fillCircle(px, py, dotR + 1, kGridDeep);
    gfx->fillCircle(px, py, dotR, color);
    return;
  }

  const int tailX = boxCx - cellX * 2;
  const int tailY = boxCy - cellY * 2;
  const int headX = boxCx + cellX * 6;
  const int headY = boxCy + cellY * 6;
  const int sideX = cellY;
  const int sideY = -cellX;
  const bool fast = speedMps >= 1.4f;

  gfx->drawLine(tailX + 1, tailY + 1, headX + 1, headY + 1, kBlack);
  gfx->drawLine(headX + 1, headY + 1, headX - cellX * 3 + sideX * 3 + 1,
                headY - cellY * 3 + sideY * 3 + 1, kBlack);
  gfx->drawLine(headX + 1, headY + 1, headX - cellX * 3 - sideX * 3 + 1,
                headY - cellY * 3 - sideY * 3 + 1, kBlack);

  gfx->drawLine(tailX, tailY, headX, headY, color);
  gfx->drawLine(headX, headY, headX - cellX * 3 + sideX * 3,
                headY - cellY * 3 + sideY * 3, color);
  gfx->drawLine(headX, headY, headX - cellX * 3 - sideX * 3,
                headY - cellY * 3 - sideY * 3, color);
  if (fast) {
    gfx->drawLine(tailX + sideX, tailY + sideY, headX + sideX, headY + sideY, color);
  }
}

void drawSpeakingBadge(int x, int y, uint32_t now) {
  const bool flash = ((now / 170) & 1) == 0;
  const uint16_t color = flash ? kGridBright : kGrid;
  const uint16_t dim = flash ? kGrid : kGridDim;
  const int bx = x + 12;
  const int by = y - 11;
  gfx->drawPixel(bx, by, color);
  gfx->drawFastVLine(bx + 2, by - 2, 5, color);
  gfx->drawFastVLine(bx + 5, by - 4, 9, dim);
  gfx->drawPixel(bx + 7, by - 5, dim);
  gfx->drawPixel(bx + 7, by + 5, dim);
}

bool targetScreenPoint(uint8_t remoteSlot, float worldAngle, float range, int &x, int &y) {
  float radius = range * currentMapScale() * kTargetMaxRadius;
  if (remoteSlot >= kRemoteAppSlotCount || radius > static_cast<float>(kTargetMaxRadius)) {
    return false;
  }

  // Snap in the unrotated geographic grid so the marker stays attached to a
  // grid cell. Hysteresis prevents GPS noise near a cell boundary from toggling
  // the marker between adjacent cells.
  polarToPoint(wrap360(worldAngle), radius, x, y);
  if (kSnapTargetsToGrid && !kShowDebugHud) {
    RemoteGeoFilterState &filter = remoteGeoFilterStates[remoteSlot];
    const int step = max(8, currentGridPitch() / 2);
    constexpr float kCellSwitchThreshold = 0.65f;
    const int thresholdPx = static_cast<int>(ceilf(step * kCellSwitchThreshold));
    int snappedX = filter.snapInitialized
                       ? filter.snappedWorldX
                       : kCx + static_cast<int>(roundf((x - kCx) / static_cast<float>(step))) * step;
    int snappedY = filter.snapInitialized
                       ? filter.snappedWorldY
                       : kCy + static_cast<int>(roundf((y - kCy) / static_cast<float>(step))) * step;
    while (x - snappedX > thresholdPx) {
      snappedX += step;
    }
    while (x - snappedX < -thresholdPx) {
      snappedX -= step;
    }
    while (y - snappedY > thresholdPx) {
      snappedY += step;
    }
    while (y - snappedY < -thresholdPx) {
      snappedY -= step;
    }

    const int snappedDx = snappedX - kCx;
    const int snappedDy = snappedY - kCy;
    constexpr int kEdgeMargin = 14;
    constexpr int kLimit = kTargetMaxRadius - kEdgeMargin;
    if (snappedDx * snappedDx + snappedDy * snappedDy <= kLimit * kLimit) {
      filter.snappedWorldX = static_cast<int16_t>(snappedX);
      filter.snappedWorldY = static_cast<int16_t>(snappedY);
      filter.snapInitialized = true;
      x = snappedX;
      y = snappedY;
    }
  }

  const float rotationRad = degToRad(renderedRadarRotationDeg);
  const float cosRotation = cosf(rotationRad);
  const float sinRotation = sinf(rotationRad);
  const float dx = static_cast<float>(x - kCx);
  const float dy = static_cast<float>(y - kCy);
  x = kCx + static_cast<int>(roundf(dx * cosRotation - dy * sinRotation));
  y = kCy + static_cast<int>(roundf(dx * sinRotation + dy * cosRotation));
  return true;
}

void drawFocusedMemberFrame(int x, int y, uint32_t now) {
  if (focusedMemberSlot == kFocusNone || now > focusFlashUntilMs) {
    return;
  }

  const bool flash = ((focusFlashUntilMs - now) / 84) & 1;
  const uint16_t color = flash ? kGridBright : kAmber;
  const int r = 18 + static_cast<int>(((focusFlashUntilMs - now) / 110) % 3);
  gfx->drawFastHLine(x - r, y - r, 10, color);
  gfx->drawFastVLine(x - r, y - r, 10, color);
  gfx->drawFastHLine(x + r - 9, y - r, 10, color);
  gfx->drawFastVLine(x + r, y - r, 10, color);
  gfx->drawFastHLine(x - r, y + r, 10, color);
  gfx->drawFastVLine(x - r, y + r - 9, 10, color);
  gfx->drawFastHLine(x + r - 9, y + r, 10, color);
  gfx->drawFastVLine(x + r, y + r - 9, 10, color);
}

const char *headingAlignmentFeedbackText(HeadingAlignmentFeedback feedback) {
  switch (feedback) {
    case HeadingAlignmentFeedback::Success: return "NORTH ALIGNED";
    case HeadingAlignmentFeedback::ImuWait: return "IMU WAIT";
    case HeadingAlignmentFeedback::HoldStill: return "HOLD STILL";
    case HeadingAlignmentFeedback::Realign: return "REALIGN NORTH";
    default: return "";
  }
}

void drawHeadingCalibrationPrompt(uint32_t now) {
  if (!headingCalibrationPromptVisible || !northCalibrationInteractive(now)) {
    return;
  }

  constexpr int kPanelX = kCx - 150;
  constexpr int kPanelY = kCy - 104;
  constexpr int kPanelW = 300;
  constexpr int kPanelH = 208;
  gfx->fillRect(kPanelX, kPanelY, kPanelW, kPanelH, kScreenBg);
  gfx->drawRect(kPanelX, kPanelY, kPanelW, kPanelH, kGridDim);
  gfx->drawRect(kPanelX + 5, kPanelY + 5, kPanelW - 10, kPanelH - 10, kGridDeep);

  const uint16_t northColor = ((now / 260) & 1) == 0 ? kGridBright : kGrid;
  gfx->drawFastVLine(kCx, kPanelY + 18, 31, northColor);
  gfx->drawLine(kCx, kPanelY + 14, kCx - 8, kPanelY + 26, northColor);
  gfx->drawLine(kCx, kPanelY + 14, kCx + 8, kPanelY + 26, northColor);
  drawCenteredText("N", kPanelY + 53, 3, northColor);
  drawCenteredText("POINT ZERO TO N", kPanelY + 94, 2, kWhite);

  const bool imuReady = headingCalibrationImuReady(now) &&
                        fabsf(headingEstimator.verticalRateDps) <=
                            kHeadingAlignmentMaxYawRateDps;
  drawCenteredText(imuReady ? "HOLD SCREEN" : "KEEP RADAR STILL",
                   kPanelY + 132, 1, imuReady ? kGrid : kAmber);

  constexpr int kProgressX = kCx - 104;
  constexpr int kProgressY = kPanelY + 163;
  constexpr int kProgressW = 208;
  constexpr int kProgressH = 12;
  gfx->drawRect(kProgressX, kProgressY, kProgressW, kProgressH, kGridDim);
  uint32_t heldMs = 0;
  if (touchWasPressed && !headingCalibrationGestureCancelled &&
      touchPressedAtMs > 0) {
    heldMs = min<uint32_t>(now - touchPressedAtMs, kHeadingCalibrationHoldMs);
  }
  const int filled = static_cast<int>(
      (heldMs * static_cast<uint32_t>(kProgressW - 4)) / kHeadingCalibrationHoldMs);
  if (filled > 0) {
    gfx->fillRect(kProgressX + 2, kProgressY + 2, filled, kProgressH - 4,
                  imuReady ? kGridBright : kAmber);
  }
  drawCenteredText("TRUE NORTH", kPanelY + 184, 1, kGridDim);
}

void drawHeadingAlignmentFeedback(uint32_t now) {
  if (headingAlignmentFeedback == HeadingAlignmentFeedback::None ||
      now > headingAlignmentFeedbackUntilMs) {
    return;
  }
  const bool success = headingAlignmentFeedback == HeadingAlignmentFeedback::Success;
  const uint16_t color = success ? kGridBright : kAmber;
  constexpr int kBannerY = 54;
  gfx->fillRect(kCx - 112, kBannerY - 8, 224, 28, kScreenBg);
  gfx->drawFastHLine(kCx - 108, kBannerY - 6, 216, success ? kGrid : kOrange);
  drawCenteredText(headingAlignmentFeedbackText(headingAlignmentFeedback),
                   kBannerY, 2, color);
}

bool drawBlePairingOverlay(uint32_t now) {
  const uint32_t passkeyUntil = blePairingPasskeyUntilMs;
  if (passkeyUntil != 0 && static_cast<int32_t>(passkeyUntil - now) > 0) {
    constexpr int kPanelX = kCx - 158;
    constexpr int kPanelY = kCy - 92;
    constexpr int kPanelW = 316;
    constexpr int kPanelH = 184;
    gfx->fillRect(kPanelX, kPanelY, kPanelW, kPanelH, kScreenBg);
    gfx->drawRect(kPanelX, kPanelY, kPanelW, kPanelH, kGridBright);
    gfx->drawRect(kPanelX + 5, kPanelY + 5, kPanelW - 10, kPanelH - 10, kGridDim);
    drawCenteredText("BLUETOOTH PAIRING", kPanelY + 28, 2, kGridBright);

    char passkeyText[7];
    snprintf(passkeyText, sizeof(passkeyText), "%06lu",
             static_cast<unsigned long>(blePairingPasskey % 1000000UL));
    drawCenteredText(passkeyText, kPanelY + 76, 4, kWhite);
    drawCenteredText("ENTER CODE ON IPHONE", kPanelY + 128, 1, kAmber);
    drawCenteredText("CODE EXPIRES SOON", kPanelY + 151, 1, kGridDim);
    return true;
  }

  const uint32_t resultUntil = blePairingResultUntilMs;
  if (resultUntil != 0 && static_cast<int32_t>(resultUntil - now) > 0) {
    constexpr int kBannerY = kCy - 34;
    const bool success = bleLinkAuthenticated;
    const uint16_t color = success ? kGridBright : kAmber;
    gfx->fillRect(kCx - 126, kBannerY - 18, 252, 68, kScreenBg);
    gfx->drawRect(kCx - 126, kBannerY - 18, 252, 68, color);
    drawCenteredText(success ? "BLE SECURE" : "PAIRING FAILED", kBannerY, 2, color);
    drawCenteredText(success ? "IPHONE BONDED" : "TRY AGAIN", kBannerY + 28, 1, kWhite);
    return true;
  }
  return false;
}

void drawTargets() {
  return;
}

void drawRemoteAppMarker() {
  const uint32_t now = millis();
  RemoteMarkerDrawState markers[kRemoteAppSlotCount];
  for (uint8_t slot = 0; slot < kRemoteAppSlotCount; ++slot) {
    float angle = 42.0f;
    float range = 0.42f;
    float distanceM = 0.0f;
    bool distanceKnown = false;
    if (!remoteAppDisplayCandidate(slot, now, angle, range, distanceM, distanceKnown)) {
      continue;
    }

    int x;
    int y;
    if (!targetScreenPoint(slot, angle, range, x, y)) {
      continue;
    }

    const bool fresh = remoteAppBlinkStartedSlotsMs[slot] > 0 &&
                       now - remoteAppBlinkStartedSlotsMs[slot] < kLocationReceiveBlinkMs;
    const float pulseF = (sinf(now / 130.0f + slot) + 1.0f) * 0.5f;
    markers[slot].visible = true;
    markers[slot].distanceKnown = distanceKnown;
    markers[slot].fresh = fresh;
    markers[slot].speaking = remoteAppSpeakingUntilMs[slot] > now;
    markers[slot].slot = slot;
    markers[slot].pulse = static_cast<uint8_t>(pulseF * 2.0f);
    markers[slot].x = x;
    markers[slot].y = y;
    markers[slot].distanceM = distanceM;
    const RemoteLocationFrame &frame = remoteAppLocationFrames[slot];
    markers[slot].speedMps = static_cast<float>(frame.speedCms) / 100.0f;
    markers[slot].courseDeg = static_cast<float>(frame.courseDeg100) / 100.0f;
    markers[slot].motionKnown = frame.speedCms > 5;
  }

  for (uint8_t slot = 0; slot < kRemoteAppSlotCount; ++slot) {
    if (!markers[slot].visible || !markers[slot].distanceKnown) {
      continue;
    }
    drawDistanceLabel(markers[slot].x, markers[slot].y, markers[slot].distanceM);
  }

  for (uint8_t slot = 0; slot < kRemoteAppSlotCount; ++slot) {
    if (!markers[slot].visible) {
      continue;
    }
    if (markers[slot].motionKnown) {
      drawMotionBadge(markers[slot].x, markers[slot].y,
                      wrap360(markers[slot].courseDeg + renderedRadarRotationDeg),
                      markers[slot].speedMps);
    }
    drawMemberMarker(markers[slot].x, markers[slot].y, 1 + slot,
                     markers[slot].fresh, false, markers[slot].pulse);
    if (markers[slot].speaking) {
      drawSpeakingBadge(markers[slot].x, markers[slot].y, now);
    }
    if (focusedMemberSlot == slot) {
      drawFocusedMemberFrame(markers[slot].x, markers[slot].y, now);
    }
  }
}

void drawSignalStatusBanner(uint32_t now) {
  updateBatteryStatus(false);
  const bool networkLost = !radarRelayOnline();
  const bool lowBattery = !networkLost && batteryLevelLow();
  const bool noRemoteGps = !networkLost && !lowBattery && activeRemoteAppLocationCount(now) == 0;
  if (!networkLost && !lowBattery && !noRemoteGps) {
    lastSignalLostBeepPhase = UINT32_MAX;
    return;
  }
  const uint32_t blinkPhase = now / 320;
  if ((blinkPhase & 1) != 0) {
    return;
  }
  if ((networkLost || noRemoteGps) && blinkPhase != lastSignalLostBeepPhase) {
    startAlertTone(networkLost ? 1320.0f : 2200.0f, networkLost ? 52 : 28, 11000, true);
    lastSignalLostBeepPhase = blinkPhase;
    if (kSerialDiagnostics) {
      Serial.println("DIAG signal_lost_beep");
    }
  } else if (lowBattery) {
    lastSignalLostBeepPhase = UINT32_MAX;
  }

  const char *text = networkLost ? "SIGNAL LOST" : (lowBattery ? "LOW BATTERY" : "NO SIGNAL");
  const int textSize = 2;
  const int textW = static_cast<int>(strlen(text)) * 6 * textSize;
  const int textH = 8 * textSize;
  const int x = kCx - textW / 2;
  const int y = kCy - (kRadarGridRadius / 2);
  gfx->fillRect(x - 8, y - 6, textW + 16, textH + 12, kBlack);
  gfx->drawRect(x - 9, y - 7, textW + 18, textH + 14, kGridDeep);
  gfx->setTextSize(textSize);
  gfx->setTextColor(RGB565(74, 52, 0));
  gfx->setCursor(x + 1, y + 1);
  gfx->print(text);
  gfx->setTextColor(kAmber);
  gfx->setCursor(x, y);
  gfx->print(text);
}

void drawSignalLostBanner(uint32_t now) {
  drawSignalStatusBanner(now);
}

void drawZoomFlash() {
  const uint32_t now = millis();
  if (now > zoomFlashUntilMs) {
    return;
  }

  const bool flash = ((zoomFlashUntilMs - now) / 88) & 1;
  const int startX = kCx - 34;
  const int y = 36;
  for (uint8_t i = 0; i < kZoomLevelCount; ++i) {
    const int x = startX + i * 26;
    const bool on = i <= zoomLevel;
    gfx->drawRect(x, y, 14, 6, on ? kGridBright : kGridDim);
    if (on && flash) {
      gfx->fillRect(x + 2, y + 2, 10, 2, kGridBright);
    } else if (on) {
      gfx->fillRect(x + 3, y + 2, 8, 2, kGrid);
    }
  }
  gfx->drawFastHLine(kCx - 48, y + 14, 96, flash ? kGrid : kGridDim);
}

void drawTouchEcho() {
  const uint32_t now = millis();
  if (kShowDebugHud || now > touchEchoUntilMs) {
    return;
  }

  const uint32_t remaining = touchEchoUntilMs - now;
  const uint32_t age = kTouchEchoMs - remaining;
  int grow = static_cast<int>(age / 18);
  if (grow > 18) {
    grow = 18;
  }
  const int side = 10 + grow;
  const int x = touchEchoX;
  const int half = circleChordHalf(x - kCx);
  if (half <= side + 6) {
    return;
  }
  const int y = constrain(touchEchoY, kCy - half + side + 6, kCy + half - side - 6);
  const bool flash = ((remaining / 64) & 1) == 0;
  const uint16_t active = flash ? kGridBright : kGrid;
  const uint16_t dim = flash ? kGrid : kGridDim;

  gfx->drawRect(x - side, y - side, side * 2, side * 2, dim);
  gfx->drawRect(x - side + 4, y - side + 4, side * 2 - 8, side * 2 - 8, active);
  gfx->drawFastHLine(x - side - 12, y, 10, active);
  gfx->drawFastHLine(x + side + 2, y, 10, active);
  gfx->drawFastVLine(x, y - side - 12, 10, active);
  gfx->drawFastVLine(x, y + side + 2, 10, active);
  if (flash) {
    gfx->fillRect(x - 2, y - 2, 4, 4, active);
  }
}

int normalizeAngleDeg(float degrees) {
  int value = static_cast<int>(roundf(degrees)) % 360;
  if (value < 0) {
    value += 360;
  }
  return value;
}

void drawPttRippleArc(float centerDeg, float spanDeg, int radius, uint16_t color, uint8_t thickness) {
  if (radius <= 0 || spanDeg <= 0.0f) {
    return;
  }

  const int startDeg = normalizeAngleDeg(centerDeg - spanDeg * 0.5f);
  const int endDeg = normalizeAngleDeg(centerDeg + spanDeg * 0.5f);
  for (uint8_t i = 0; i < thickness; ++i) {
    const int r = radius - i;
    if (r > 0) {
      gfx->drawArc(kCx, kCy, r, r - 1, startDeg, endDeg, color);
    }
  }
}

void drawButtonTapEffect(uint32_t now, float originDeg, uint32_t &pressStartedMs,
                         uint32_t &releaseStartedMs, bool pressed) {
  if (pressStartedMs > 0) {
    const uint32_t age = now - pressStartedMs;
    if (age >= kButtonTapPressMs && !pressed) {
      pressStartedMs = 0;
    } else if (age < kButtonTapPressMs) {
      const float phase = static_cast<float>(age) / static_cast<float>(kButtonTapPressMs);
      const float rise = smoothStep(0.0f, 1.0f, phase);
      const float settle = pressed ? 1.0f : (1.0f - phase);
      const float span = 10.0f + rise * 18.0f;
      drawPttRippleArc(originDeg, span, kRadarGridRadius - 2, kRippleHead, 2);
      drawPttRippleArc(originDeg, span + 12.0f * settle, kRadarGridRadius - 10, kRippleMid, 1);
      drawPttRippleArc(originDeg - span * 0.48f, 6.0f, kRadarGridRadius - 7, kRippleDim, 1);
      drawPttRippleArc(originDeg + span * 0.48f, 6.0f, kRadarGridRadius - 7, kRippleDim, 1);
    }
  }

  if (releaseStartedMs == 0) {
    return;
  }

  const uint32_t releasedAge = now - releaseStartedMs;
  if (releasedAge >= kButtonTapReleaseMs) {
    releaseStartedMs = 0;
    return;
  }

  const float phase = static_cast<float>(releasedAge) / static_cast<float>(kButtonTapReleaseMs);
  const float fade = 1.0f - phase;
  const float travel = 8.0f + smoothStep(0.0f, 1.0f, phase) * 46.0f;
  const float span = max(5.0f, 15.0f * fade);
  const uint16_t headColor = fade > 0.44f ? kRippleHead : kRippleMid;
  for (int dir = -1; dir <= 1; dir += 2) {
    drawPttRippleArc(originDeg + static_cast<float>(dir) * travel,
                     span, kRadarGridRadius - 5, headColor, 1);
    drawPttRippleArc(originDeg + static_cast<float>(dir) * (travel - 11.0f),
                     max(4.0f, span - 4.0f), kRadarGridRadius - 13, kRippleDim, 1);
  }
}

void drawButtonTapEffects(uint32_t now) {
  drawButtonTapEffect(now, kPttRippleOriginDeg, bootTapPressedMs, bootTapReleasedMs,
                      bootButtonWasPressed);
  drawButtonTapEffect(now, kAltButtonOriginDeg, altTapPressedMs, altTapReleasedMs,
                      altButtonWasPressed);
}

void drawPttEdgeRipple(uint32_t now) {
  if (pttRippleStartedMs == 0) {
    return;
  }

  const float originDeg = kPttRippleOriginDeg;
  const uint32_t holdMs = now - pttRippleStartedMs;
  const float voiceBoost = clampf(static_cast<float>(voiceCapture.peak) / 4200.0f, 0.0f, 1.0f);
  const float rise = smoothStep(0.0f, static_cast<float>(kPttRippleArchRiseMs),
                                static_cast<float>(min<uint32_t>(holdMs, kPttRippleArchRiseMs)));

  if (voiceCapture.pttActive) {
    const float pulse = (sinf(static_cast<float>(holdMs) / 150.0f) + 1.0f) * 0.5f;
    const float archSpan = 16.0f + rise * 22.0f + pulse * 4.0f + voiceBoost * 8.0f;
    drawPttRippleArc(originDeg, archSpan, kRadarGridRadius - 3, kRippleHead, 3);
    drawPttRippleArc(originDeg, archSpan + 12.0f, kRadarGridRadius - 11, kRippleMid, 2);
    drawPttRippleArc(originDeg, archSpan + 24.0f, kRadarGridRadius - 20, kRippleDim, 1);
    drawPttRippleArc(originDeg - archSpan * 0.58f, 8.0f, kRadarGridRadius - 8, kRippleMid, 1);
    drawPttRippleArc(originDeg + archSpan * 0.58f, 8.0f, kRadarGridRadius - 8, kRippleMid, 1);
    return;
  }

  if (pttRippleEndedMs == 0) {
    return;
  }

  const uint32_t releasedMs = now - pttRippleEndedMs;
  if (releasedMs >= kPttRippleReleaseMs) {
    pttRippleStartedMs = 0;
    pttRippleEndedMs = 0;
    return;
  }

  const float releasePhase = static_cast<float>(releasedMs) /
                             static_cast<float>(kPttRippleReleaseMs);
  const float eased = 1.0f - (1.0f - releasePhase) * (1.0f - releasePhase) *
                      (1.0f - releasePhase);
  const float fade = 1.0f - releasePhase;
  const float originFade = max(0.0f, 1.0f - releasePhase * 2.1f);
  const float travelDeg = 12.0f + eased * 182.0f;
  const float headSpan = 24.0f * fade + voiceBoost * 8.0f;
  const uint16_t headColor = fade > 0.55f ? kRippleHead : (fade > 0.28f ? kRippleMid : kRippleDim);
  const uint16_t midColor = fade > 0.38f ? kRippleMid : kRippleDim;

  if (originFade > 0.0f) {
    drawPttRippleArc(originDeg, 38.0f * originFade, kRadarGridRadius - 4, headColor, 2);
    drawPttRippleArc(originDeg, 52.0f * originFade, kRadarGridRadius - 13, midColor, 1);
  }

  for (int dir = -1; dir <= 1; dir += 2) {
    for (uint8_t trail = 0; trail < 4; ++trail) {
      const float lag = static_cast<float>(trail) * 19.0f;
      if (travelDeg <= lag) {
        continue;
      }
      const float center = originDeg + static_cast<float>(dir) * (travelDeg - lag);
      const float span = max(7.0f, headSpan - static_cast<float>(trail) * 4.0f);
      const int radius = kRadarGridRadius - 5 - static_cast<int>(trail) * 7;
      const uint16_t color = trail == 0 ? headColor :
                             (trail == 1 ? midColor :
                              (trail == 2 ? kRippleDim : kGridDeep));
      drawPttRippleArc(center, span, radius, color, trail == 0 ? 2 : 1);
    }

    if (releasePhase > 0.68f) {
      const float arrive = (releasePhase - 0.68f) / 0.32f;
      const float farSpan = (10.0f + arrive * 26.0f) * fade;
      drawPttRippleArc(originDeg + static_cast<float>(dir) * 180.0f, farSpan,
                       kRadarGridRadius - 19, midColor, 1);
    }
  }
}

void drawBrightnessFlash() {
  const uint32_t now = millis();
  if (now > brightnessFlashUntilMs) {
    return;
  }

  const bool flash = ((brightnessFlashUntilMs - now) / 88) & 1;
  const int x = 36;
  const int baseY = kCy + 24;
  for (uint8_t i = 0; i < kBrightnessPresetCount; ++i) {
    const int h = 9 + i * 8;
    const int bx = x + i * 12;
    const bool on = i <= brightnessPreset;
    gfx->drawRect(bx, baseY - h, 7, h, on ? kGridBright : kGridDim);
    if (on) {
      gfx->fillRect(bx + 2, baseY - h + 2, 3, h - 4, flash ? kGridBright : kGrid);
    }
  }
}

void drawAudioFlash() {
  const uint32_t now = millis();
  if (now > audioFlashUntilMs) {
    return;
  }

  const bool flash = ((audioFlashUntilMs - now) / 88) & 1;
  const int x = kScreenW - 44;
  const int y = kCy - 18;
  const uint16_t c = flash ? kAmber : kGrid;
  if (audioPreset == 0) {
    gfx->drawRect(x - 4, y + 8, 24, 24, kGridDim);
    gfx->drawLine(x - 2, y + 30, x + 18, y + 10, c);
    return;
  }

  for (uint8_t i = 0; i < kAudioPresetCount - 1; ++i) {
    const int len = 8 + i * 8;
    const int yy = y + i * 12;
    const bool on = i < audioPreset;
    gfx->drawFastHLine(x - len / 2, yy, len, on ? c : kGridDim);
    if (on) {
      gfx->drawFastVLine(x + len / 2 + 4, yy - 3, 7, c);
    }
  }
}

void drawFrameRateFlash() {
  const uint32_t now = millis();
  if (now > frameFlashUntilMs) {
    return;
  }

  const bool flash = ((frameFlashUntilMs - now) / 88) & 1;
  const int startX = kCx - 45;
  const int y = 58;
  for (uint8_t i = 0; i < kFramePresetCount; ++i) {
    const int x = startX + i * 30;
    const bool on = i <= framePreset;
    const int len = 13 + i * 3;
    gfx->drawFastHLine(x, y, len, on ? kGridBright : kGridDim);
    gfx->drawFastVLine(x + len + 3, y - 3, 7, on ? kGrid : kGridDim);
    if (on && flash) {
      gfx->fillRect(x + 2, y - 1, len - 4, 3, kGridBright);
    }
  }
}

void drawStatus() {
  if (!kShowDebugHud) {
    drawZoomFlash();
    drawBrightnessFlash();
    drawAudioFlash();
    drawFrameRateFlash();
    drawTouchEcho();
    return;
  }

  char buf[36];

  gfx->setTextSize(1);
  gfx->setTextColor(kGrid);
  gfx->setCursor(42, 54);
  snprintf(buf, sizeof(buf), "YAW %03d", static_cast<int>(headingDeg) % 360);
  gfx->print(buf);

  gfx->setCursor(330, 54);
  const int active = activeRemoteAppLocationCount(millis());
  snprintf(buf, sizeof(buf), "LINK %d", active);
  gfx->print(buf);

  const int energy = static_cast<int>(clampf(tiltEnergy, 0.0f, 2.0f) * 36.0f);
  gfx->drawRect(kCx - 44, 398, 88, 8, kGridDim);
  gfx->fillRect(kCx - 42, 400, energy, 4, kGrid);
  drawBrightnessFlash();
  drawAudioFlash();
  drawTouchEcho();
}

bool radarRelayOnline() {
  return WiFi.status() == WL_CONNECTED && provisioning.relayConnected;
}

bool radarNetworkOnline() {
  return WiFi.status() == WL_CONNECTED;
}

const uint8_t *networkStatusGlyph(char ch) {
  static const uint8_t glyphA[7] = {
      0b01110,
      0b10001,
      0b10001,
      0b11111,
      0b10001,
      0b10001,
      0b10001,
  };
  static const uint8_t glyphC[7] = {
      0b01111,
      0b10000,
      0b10000,
      0b10000,
      0b10000,
      0b10000,
      0b01111,
  };
  static const uint8_t glyphD[7] = {
      0b11110,
      0b10001,
      0b10001,
      0b10001,
      0b10001,
      0b10001,
      0b11110,
  };
  static const uint8_t glyphE[7] = {
      0b11111,
      0b10000,
      0b10000,
      0b11110,
      0b10000,
      0b10000,
      0b11111,
  };
  static const uint8_t glyphF[7] = {
      0b11111,
      0b10000,
      0b10000,
      0b11110,
      0b10000,
      0b10000,
      0b10000,
  };
  static const uint8_t glyphG[7] = {
      0b01110,
      0b10001,
      0b10000,
      0b10111,
      0b10001,
      0b10001,
      0b01110,
  };
  static const uint8_t glyphI[7] = {
      0b11111,
      0b00100,
      0b00100,
      0b00100,
      0b00100,
      0b00100,
      0b11111,
  };
  static const uint8_t glyphL[7] = {
      0b10000,
      0b10000,
      0b10000,
      0b10000,
      0b10000,
      0b10000,
      0b11111,
  };
  static const uint8_t glyphN[7] = {
      0b10001,
      0b11001,
      0b10101,
      0b10011,
      0b10001,
      0b10001,
      0b10001,
  };
  static const uint8_t glyphO[7] = {
      0b01110,
      0b10001,
      0b10001,
      0b10001,
      0b10001,
      0b10001,
      0b01110,
  };
  static const uint8_t glyphR[7] = {
      0b11110,
      0b10001,
      0b10001,
      0b11110,
      0b10100,
      0b10010,
      0b10001,
  };
  static const uint8_t glyphT[7] = {
      0b11111,
      0b00100,
      0b00100,
      0b00100,
      0b00100,
      0b00100,
      0b00100,
  };
  static const uint8_t glyphW[7] = {
      0b10001,
      0b10001,
      0b10001,
      0b10101,
      0b10101,
      0b11011,
      0b10001,
  };
  static const uint8_t glyphY[7] = {
      0b10001,
      0b10001,
      0b01010,
      0b00100,
      0b00100,
      0b00100,
      0b00100,
  };

  switch (ch) {
    case 'A':
      return glyphA;
    case 'C':
      return glyphC;
    case 'D':
      return glyphD;
    case 'E':
      return glyphE;
    case 'F':
      return glyphF;
    case 'G':
      return glyphG;
    case 'I':
      return glyphI;
    case 'L':
      return glyphL;
    case 'N':
      return glyphN;
    case 'O':
      return glyphO;
    case 'R':
      return glyphR;
    case 'T':
      return glyphT;
    case 'W':
      return glyphW;
    case 'Y':
      return glyphY;
    default:
      return nullptr;
  }
}

void drawRotatedNetworkGlyph(char ch, float cx, float cy, float angle, int scale, uint16_t color) {
  const uint8_t *glyph = networkStatusGlyph(ch);
  if (!glyph) {
    return;
  }

  const float xAxisX = cosf(angle);
  const float xAxisY = sinf(angle);
  const float yAxisX = -sinf(angle);
  const float yAxisY = cosf(angle);
  const float halfW = 2.0f;
  const float halfH = 3.0f;
  const int dotR = max(1, scale / 2);

  for (int row = 0; row < 7; ++row) {
    for (int col = 0; col < 5; ++col) {
      if ((glyph[row] & (1 << (4 - col))) == 0) {
        continue;
      }
      const float localX = (static_cast<float>(col) - halfW) * scale;
      const float localY = (static_cast<float>(row) - halfH) * scale;
      const int px = static_cast<int>(roundf(cx + localX * xAxisX + localY * yAxisX));
      const int py = static_cast<int>(roundf(cy + localX * xAxisY + localY * yAxisY));
      gfx->fillCircle(px, py, dotR, color);
    }
  }
}

void drawRotatedNetworkText(const char *text, float baseTheta, int textSize, float stepDeg,
                            uint16_t textColor, uint16_t shadowColor) {
  const int charH = 7 * textSize;
  const int textLen = strlen(text);
  const int radius = kRadarGridRadius - (charH / 2) - 5;

  for (int i = 0; i < textLen; ++i) {
    const float theta = baseTheta +
                        (static_cast<float>(i) - static_cast<float>(textLen - 1) * 0.5f) *
                            stepDeg * kPi / 180.0f;
    const float x = static_cast<float>(kCx) + sinf(theta) * radius;
    const float y = static_cast<float>(kCy) - cosf(theta) * radius;
    drawRotatedNetworkGlyph(text[i], x + 1.0f, y + 1.0f, theta, textSize, shadowColor);
    drawRotatedNetworkGlyph(text[i], x, y, theta, textSize, textColor);
  }
}

void drawNetworkErrorBanner() {
  static uint32_t offlineSinceMs = 0;
  static uint32_t connectedSinceMs = 0;
  static uint32_t connectedUntilMs = 0;
  static float lastErrorTheta = 0.0f;

  const uint32_t now = millis();
  const bool wifiOnline = radarNetworkOnline();
  const bool relayOnline = radarRelayOnline();
  if (relayOnline) {
    if (offlineSinceMs != 0) {
      connectedSinceMs = now;
      connectedUntilMs = now + 880;
      offlineSinceMs = 0;
    }
    if (connectedUntilMs != 0 && now < connectedUntilMs) {
      const uint32_t flashSegment = (now - connectedSinceMs) / 220;
      if ((flashSegment & 1) == 0) {
        drawRotatedNetworkText("CONNECTED", lastErrorTheta, 2, 7.4f, kGridBright, RGB565(0, 66, 28));
      }
    } else {
      connectedSinceMs = 0;
      connectedUntilMs = 0;
    }
    return;
  }

  connectedUntilMs = 0;
  if (offlineSinceMs == 0) {
    offlineSinceMs = now;
  }
}

void handleAudioEvents() {
  const uint32_t now = millis();
  if (otaManager.blocksPowerAndVoice()) {
    tone.active = false;
    tone.remainingSamples = 0;
    return;
  }
  if (radarUiMode == RadarUiMode::Standby ||
      radarUiMode == RadarUiMode::SystemMenu ||
      radarUiMode == RadarUiMode::Info ||
      radarUiMode == RadarUiMode::PowerConfirm ||
      radarUiMode == RadarUiMode::ShutdownPending) {
    tone.active = false;
    tone.remainingSamples = 0;
    return;
  }
  const bool signalLost = !radarRelayOnline() || activeRemoteAppLocationCount(now) == 0;

  if (signalLost && now - lastScanChirpMs > 1800) {
    startAlertTone(760.0f, 48, 9000, false);
    lastScanChirpMs = now;
  }
}

void printHardwareSummary() {
  if (!kSerialDiagnostics) {
    return;
  }

  Serial.println("DIAG enabled");
  Serial.print("DIAG display=");
  Serial.print(kScreenW);
  Serial.print("x");
  Serial.print(kScreenH);
  Serial.print(" brightness=");
  Serial.println(currentBrightness());
  Serial.print("DIAG touch=");
  Serial.print(touchOnline ? "online" : "offline");
  Serial.print(" imu=");
  Serial.print(imuOnline ? "online" : "offline");
  Serial.print(" ble=");
  Serial.print(bleOnline ? "online" : "offline");
  Serial.print(" remoteBle=");
  Serial.print(provisioning.serviceOnline ? "online" : "offline");
  Serial.print(" wifi=");
  Serial.print(wifiStatusText());
  Serial.print(" paired=");
  Serial.print(provisioning.paired ? "yes" : "no");
  Serial.print(" audio=");
  Serial.println(audioOnline ? "online" : "offline");
  Serial.print("DIAG pwrButton=");
  Serial.println(powerButtonOnline ? "online" : "offline");
  Serial.print("DIAG battery=");
  if (!batteryStatus.online) {
    Serial.println("offline");
  } else if (!batteryStatus.present) {
    Serial.println("absent");
  } else {
    Serial.print(static_cast<int>(batteryStatus.percent));
    Serial.print("% ");
    Serial.print(batteryStatus.voltageMv);
    Serial.println("mV");
  }
  Serial.print("DIAG heap=");
  Serial.print(ESP.getFreeHeap());
  Serial.print(" psram=");
  Serial.println(ESP.getPsramSize());
}

char normalizedSerialCommand(char command) {
  if (command >= 'A' && command <= 'Z') {
    return static_cast<char>(command - 'A' + 'a');
  }
  return command;
}

void printSerialCommandHelp() {
  if (!kSerialDiagnostics) {
    return;
  }

  Serial.println("DIAG commands: ? help, h hardware, d display_test, z zoom, c align_north, b brightness, a audio, f frame_rate, t frame_turbo, p ping");
  Serial.println("DIAG line: relay <ws_url> <http_api_url> <room_token> <device_token>");
  Serial.println("DIAG line: ui <main|menu|info|confirm|pending|sleep|standby|wake|status|select ITEM|activate>");
}

void printSerialCommandResult(char command, const char *action) {
  Serial.print("DIAG command ");
  Serial.print(command);
  Serial.print(" action=");
  Serial.println(action);
}

void printFrameRateCommandResult(char command, const char *action) {
  Serial.print("DIAG command ");
  Serial.print(command);
  Serial.print(" action=");
  Serial.print(action);
  Serial.print(" frameMs=");
  Serial.print(currentFrameMs());
  Serial.print(" framePreset=");
  Serial.println(framePreset);
}

void handleSerialCommand(char rawCommand) {
  if (!kSerialDiagnostics) {
    return;
  }

  const char command = normalizedSerialCommand(rawCommand);
  switch (command) {
    case '?':
      printSerialCommandResult(command, "help");
      printSerialCommandHelp();
      break;
    case 'h':
      printSerialCommandResult(command, "hardware");
      printHardwareSummary();
      break;
    case 'd':
      displaySelfTestUntilMs = millis() + 15000;
      printSerialCommandResult(command, "display_test");
      break;
    case 'z':
      cycleMapScale();
      printSerialCommandResult(command, "zoom");
      break;
    case 'c':
      attemptNorthHeadingAlignment();
      printSerialCommandResult(command, "align_north");
      break;
    case 'b':
      cycleBrightness();
      printSerialCommandResult(command, "brightness");
      break;
    case 'a':
      cycleAudioGain();
      printSerialCommandResult(command, "audio");
      break;
    case 'f':
      cycleFrameRate();
      printFrameRateCommandResult(command, "frame_rate");
      break;
    case 't':
      setFrameTurbo();
      printFrameRateCommandResult(command, "frame_turbo");
      break;
    case 'p':
      startTone(1568.0f, 120, 4200, true);
      printSerialCommandResult(command, "ping");
      break;
    default:
      printSerialCommandResult(command, "unknown");
      break;
  }
}

bool nextSerialToken(const String &line, int &offset, String &token) {
  while (offset < line.length() && line[offset] == ' ') {
    ++offset;
  }
  if (offset >= line.length()) {
    return false;
  }
  const int start = offset;
  while (offset < line.length() && line[offset] != ' ') {
    ++offset;
  }
  token = line.substring(start, offset);
  return true;
}

SystemMenuItem parseSystemMenuItem(String token) {
  token.toLowerCase();
  if (token == "sleep") {
    return SystemMenuItem::Sleep;
  }
  if (token == "standby" || token == "stby") {
    return SystemMenuItem::Standby;
  }
  if (token == "off") {
    return SystemMenuItem::Off;
  }
  if (token == "info") {
    return SystemMenuItem::Info;
  }
  if (token == "reset" || token == "rst") {
    return SystemMenuItem::Reset;
  }
  if (token == "volume" || token == "vol") {
    return SystemMenuItem::Volume;
  }
  if (token == "brightness" || token == "lux") {
    return SystemMenuItem::Brightness;
  }
  if (token == "direction" || token == "dir" || token == "orientation") {
    return SystemMenuItem::Direction;
  }
  return SystemMenuItem::None;
}

void printSystemUiDiagnostic() {
  const String bleStatus = buildDeviceStatusJson(false);
  const String relayStatus = buildDeviceStatusJson(true);
  Serial.print("DIAG ui mode=");
  Serial.print(radarUiModeText(radarUiMode));
  Serial.print(" selected=");
  Serial.print(systemMenuItemText(systemMenuSelectedItem));
  Serial.print(" power=");
  Serial.print(powerStateText());
  Serial.print(" display=");
  Serial.print(displayStateText());
  Serial.print(" brightPreset=");
  Serial.print(brightnessPreset);
  Serial.print(" audioPreset=");
  Serial.print(audioPreset);
  Serial.print(" screenDir=");
  Serial.print(DragonRadarDisplayOrientation::persistedValue(screenDirection));
  Serial.print(" bleStatusBytes=");
  Serial.print(bleStatus.length());
  Serial.print(" relayStatusBytes=");
  Serial.println(relayStatus.length());
}

void handleUiSerialCommand(const String &line) {
  int offset = 0;
  String command;
  String action;
  nextSerialToken(line, offset, command);
  if (!nextSerialToken(line, offset, action)) {
    printSystemUiDiagnostic();
    return;
  }
  action.toLowerCase();

  if (action == "status") {
    printSystemUiDiagnostic();
    return;
  }
  if (action == "main" || action == "wake") {
    wakeRadarDisplay();
  } else if (action == "menu") {
    setRadarUiMode(RadarUiMode::SystemMenu);
  } else if (action == "info") {
    setRadarUiMode(RadarUiMode::Info);
  } else if (action == "confirm") {
    setRadarUiMode(RadarUiMode::PowerConfirm);
  } else if (action == "reset_confirm") {
    setRadarUiMode(RadarUiMode::FactoryResetConfirm);
  } else if (action == "pending") {
    setRadarUiMode(RadarUiMode::ShutdownPending);
  } else if (action == "sleep") {
    enterScreenOff();
  } else if (action == "standby" || action == "stby") {
    enterStandby();
  } else if (action == "select") {
    String itemToken;
    if (!nextSerialToken(line, offset, itemToken)) {
      Serial.println("DIAG ui usage: ui select <sleep|standby|off|info|reset|volume|brightness|direction>");
      return;
    }
    const SystemMenuItem item = parseSystemMenuItem(itemToken);
    if (item == SystemMenuItem::None) {
      Serial.println("DIAG ui error=unknown_item");
      return;
    }
    systemMenuSelectedItem = item;
    setRadarUiMode(RadarUiMode::SystemMenu);
  } else if (action == "activate") {
    if (radarUiMode != RadarUiMode::SystemMenu) {
      Serial.println("DIAG ui error=activate_requires_menu");
      printSystemUiDiagnostic();
      return;
    }
    activateSystemMenuItem(systemMenuSelectedItem);
  } else {
    Serial.println("DIAG ui error=unknown_action");
    return;
  }

  printSystemUiDiagnostic();
}

void handleRelaySerialCommand(const String &line) {
  int offset = 0;
  String command;
  String relayUrl;
  String httpApiUrl;
  String roomToken;
  String deviceToken;
  nextSerialToken(line, offset, command);
  if (!nextSerialToken(line, offset, relayUrl) ||
      !nextSerialToken(line, offset, httpApiUrl) ||
      !nextSerialToken(line, offset, roomToken) ||
      !nextSerialToken(line, offset, deviceToken)) {
    Serial.println("DIAG relay usage: relay <ws_url> <http_api_url> <room_token> <device_token>");
    return;
  }

  const bool roomChanged = provisioning.roomToken != roomToken;
  if (roomChanged) {
    clearRemoteRoomState();
  }
  provisioning.relayUrl = relayUrl;
  provisioning.httpApiUrl = httpApiUrl;
  provisioning.roomToken = roomToken;
  provisioning.deviceToken = deviceToken;
  provisioning.serverConfigured = provisioning.relayUrl.length() > 0 && provisioning.deviceToken.length() > 0;
  provisioning.relayConnected = false;
  provisioning.relaySocketConfigured = false;
  provisioning.relayState = provisioning.serverConfigured ? "configured" : "unconfigured";
  provisioning.lastWrite = "serial_relay";
  lastRelayAttemptMs = 0;
  lastRelayHeartbeatMs = 0;
  relayTimeSyncStartedMs = 0;
  lastRelayTimeSyncAttemptMs = 0;
  relayTimeSyncInFlight = false;
  relayTimeSyncAttempted = false;
  relaySocket.disconnect();
  saveProvisioningState();
  notifyDeviceStatus(true);

  Serial.println("DIAG relay configured (credentials redacted)");
}

void handleSerialLine(String line) {
  line.trim();
  while (line.indexOf("  ") >= 0) {
    line.replace("  ", " ");
  }
  if (line.length() == 0) {
    return;
  }
  String lower = line;
  lower.toLowerCase();
  if (lower == "ui" || lower.startsWith("ui ")) {
    handleUiSerialCommand(lower);
    return;
  }
  if (lower.startsWith("relay ")) {
    handleRelaySerialCommand(line);
    return;
  }
  if (line.length() == 1) {
    handleSerialCommand(line[0]);
    return;
  }
  Serial.print("DIAG command ");
  Serial.print(line);
  Serial.println(" action=unknown");
}

void serialCommandTick() {
  if (!kSerialDiagnostics) {
    return;
  }

  while (Serial.available() > 0) {
    const char c = static_cast<char>(Serial.read());
    if (c == '\n' || c == '\r') {
      handleSerialLine(serialCommandLine);
      serialCommandLine = "";
      continue;
    }
    if (serialCommandLine.length() < 160) {
      serialCommandLine += c;
    }
  }
}

void serialDiagnosticsTick() {
  if (!kSerialDiagnostics) {
    return;
  }

  const uint32_t now = millis();
  if (now - lastDiagMs < 1000) {
    return;
  }
  lastDiagMs = now;

  Serial.print("DIAG tick ms=");
  Serial.print(now);
  Serial.print(" zoom=");
  Serial.print(zoomLevel);
  Serial.print(" screenDir=");
  Serial.print(DragonRadarDisplayOrientation::persistedValue(screenDirection));
  Serial.print(" brightPreset=");
  Serial.print(brightnessPreset);
  Serial.print(" audioPreset=");
  Serial.print(audioPreset);
  Serial.print(" frameMs=");
  Serial.print(currentFrameMs());
  Serial.print(" drawMs=");
  Serial.print(lastDrawMs);
  Serial.print(" drawAvgMs=");
  Serial.print(lastDrawAvgMs);
  Serial.print(" drawMaxMs=");
  Serial.print(lastDrawMaxMs);
  Serial.print(" overBudget=");
  Serial.print(lastDrawOverBudgetFrames);
  Serial.print(" frames=");
  Serial.print(lastDrawSamples);
  Serial.print(" heading=");
  Serial.print(headingDeg, 1);
  Serial.print(" aligned=");
  Serial.print(headingAlignment.valid ? "yes" : "no");
  Serial.print(" alignPrompt=");
  Serial.print(headingCalibrationPromptVisible ? "shown" : "hidden");
  Serial.print(" alignOffset=");
  if (headingAlignment.valid) {
    Serial.print(headingAlignment.screenOffsetDeg, 1);
  } else {
    Serial.print("none");
  }
  Serial.print(" radarRotation=");
  Serial.print(radarDisplayRotationDeg(), 1);
  Serial.print(" headingQuality=");
  Serial.print(headingQualityText(headingEstimator.quality));
  Serial.print(" yawRate=");
  Serial.print(headingEstimator.verticalRateDps, 2);
  Serial.print(" gyroBias=");
  Serial.print(headingEstimator.biasX, 3);
  Serial.print("/");
  Serial.print(headingEstimator.biasY, 3);
  Serial.print("/");
  Serial.print(headingEstimator.biasZ, 3);
  Serial.print(" biasVerified=");
  Serial.print(headingEstimator.sessionStationaryVerified ? "yes" : "no");
  Serial.print(" biasTrust=");
  Serial.print(!headingEstimator.sessionStationaryVerified
                   ? "none"
                   : (headingEstimator.sessionTrustFromStoredBias ? "stored" : "stationary"));
  Serial.print(" imuTempC=");
  if (imuTemperaturePlausible(headingEstimator.currentTemperatureC)) {
    Serial.print(headingEstimator.currentTemperatureC, 1);
  } else {
    Serial.print("unknown");
  }
  Serial.print(" biasTempC=");
  if (imuTemperaturePlausible(headingEstimator.biasTemperatureC)) {
    Serial.print(headingEstimator.biasTemperatureC, 1);
  } else {
    Serial.print("unknown");
  }
  Serial.print(" biasTempDeltaC=");
  if (imuTemperaturePlausible(headingEstimator.currentTemperatureC) &&
      imuTemperaturePlausible(headingEstimator.biasTemperatureC)) {
    Serial.print(headingEstimator.currentTemperatureC - headingEstimator.biasTemperatureC, 1);
  } else {
    Serial.print("unknown");
  }
  Serial.print(" stationary=");
  Serial.print(headingEstimator.stationary ? "yes" : "no");
  Serial.print(" accelG=");
  Serial.print(headingEstimator.accelMagnitudeG, 3);
  Serial.print(" gyroMag=");
  Serial.print(headingEstimator.correctedGyroMagnitudeDps, 3);
  Serial.print(" gyroLimit=");
  Serial.print(headingEstimator.stationaryGyroLimitDps, 2);
  Serial.print(" stationaryCandidate=");
  Serial.print(headingEstimator.stationaryCandidate ? "yes" : "no");
  Serial.print(" stationarySamples=");
  Serial.print(headingEstimator.stationarySamples);
  Serial.print(" stationaryWindowMs=");
  Serial.print(headingEstimator.stationaryWindowStartedMs > 0
                   ? millis() - headingEstimator.stationaryWindowStartedMs
                   : 0);
  Serial.print(" stationaryStdDev=");
  if (isfinite(headingEstimator.lastStationaryMaxStdDevDps)) {
    Serial.print(headingEstimator.lastStationaryMaxStdDevDps, 3);
  } else {
    Serial.print("unknown");
  }
  Serial.print(" imuGapMs=");
  Serial.print(imuDiagnostics.currentGapMs);
  Serial.print(" imuMaxGapMs=");
  Serial.print(imuDiagnostics.maxSampleGapMs);
  Serial.print(" imuNotReady=");
  Serial.print(imuDiagnostics.dataNotReadyCount);
  Serial.print(" imuGyroReadFail=");
  Serial.print(imuDiagnostics.gyroscopeReadFailureCount);
  Serial.print(" imuAccelReadFail=");
  Serial.print(imuDiagnostics.accelerometerReadFailureCount);
  Serial.print(" imuGapCause=");
  Serial.print(imuGapCauseText(imuDiagnostics.lastGapCause));
  Serial.print(" imuAnchorReset=");
  Serial.print(imuDiagnostics.integrationAnchorReset ? "yes" : "no");
  Serial.print(" reportedHeading=");
  if (selfLocationFrame.reportedHeadingValid) {
    Serial.print(selfLocationFrame.reportedHeadingDeg100 / 100.0f, 1);
  } else {
    Serial.print("invalid");
  }
  Serial.print(" tilt=");
  Serial.print(tiltEnergy, 2);
  Serial.print(" online=");
  Serial.print(touchOnline ? "T" : "-");
  Serial.print(imuOnline ? "I" : "-");
  Serial.print(bleOnline ? "B" : "-");
  Serial.print(audioOnline ? "A" : "-");
  Serial.print(" remoteBle=");
  Serial.print(provisioning.serviceOnline ? "online" : "offline");
  Serial.print(" app=");
  Serial.print(provisioning.appConnected ? "connected" : "idle");
  Serial.print(" wifi=");
  Serial.print(wifiStatusText());
  Serial.print(" loc=");
  Serial.print(provisioning.locationReceived ? "yes" : "no");
  Serial.print(" relay=");
  Serial.print(provisioning.relayConnected ? "connected" : "idle");
  Serial.print(" ui=");
  Serial.print(radarUiModeText(radarUiMode));
  Serial.print(" menu=");
  Serial.print(systemMenuItemText(systemMenuSelectedItem));
  Serial.print(" power=");
  Serial.print(powerStateText());
  Serial.print(" ptt=");
  Serial.print(voiceCapture.pttActive ? "active" : "idle");
  Serial.print(" muted=");
  Serial.print(voiceCapture.muted ? "yes" : "no");
  Serial.print(" voiceTx=");
  Serial.print(voiceCapture.sequence);
  Serial.print(" voiceRx=");
  Serial.println(voiceCapture.receivedSequence);
}

void drawCenteredText(const char *text, int x, int y, uint8_t size, uint16_t color) {
  const int width = static_cast<int>(strlen(text)) * 6 * size;
  gfx->setTextSize(size);
  gfx->setTextColor(color);
  gfx->setCursor(x - width / 2, y - 4 * size);
  gfx->print(text);
}

void drawSystemBackdrop() {
  gfx->fillScreen(kScreenBg);
  for (int offset = -kRadarGridRadius; offset <= kRadarGridRadius; offset += kFixedRadarGridPitch) {
    const int x = kCx + offset;
    const int y = kCy + offset;
    const int halfX = circleChordHalf(offset, kRadarGridRadius - 7);
    const int halfY = circleChordHalf(offset, kRadarGridRadius - 7);
    gfx->drawFastVLine(x, kCy - halfX, halfX * 2 + 1, kGridDeep);
    gfx->drawFastHLine(kCx - halfY, y, halfY * 2 + 1, kGridDeep);
  }
  gfx->drawCircle(kCx, kCy, kRadarGridRadius - 2, kGrid);
  gfx->drawCircle(kCx, kCy, kRadarGridRadius - 8, kGridDim);
}

const char *systemMenuItemLabel(SystemMenuItem item) {
  switch (item) {
    case SystemMenuItem::Sleep: return "SLP";
    case SystemMenuItem::Standby: return "STB";
    case SystemMenuItem::Off: return "OFF";
    case SystemMenuItem::Info: return "INF";
    case SystemMenuItem::Reset: return "RST";
    case SystemMenuItem::Volume: return "VOL";
    case SystemMenuItem::Brightness: return "LUX";
    case SystemMenuItem::Direction: return "DIR";
    default: return "";
  }
}

int systemMenuControlFeedbackPulse(SystemMenuFeedbackTarget target, uint32_t now) {
  if (systemMenuFeedbackTarget != target ||
      systemMenuControlFeedbackUntilMs == 0 ||
      now >= systemMenuControlFeedbackUntilMs) {
    return 0;
  }
  const float progress = clampf((now - systemMenuControlFeedbackStartedMs) /
                                    static_cast<float>(kSystemMenuControlFeedbackMs),
                                0.0f,
                                1.0f);
  return static_cast<int>(roundf(sinf(progress * kPi) * 4.0f));
}

int systemMenuPageOffsetX(uint32_t now) {
  if (systemMenuPageTransitionDirection == 0 ||
      systemMenuPageTransitionUntilMs == 0 ||
      now >= systemMenuPageTransitionUntilMs) {
    return 0;
  }
  const float progress = clampf((now - systemMenuPageTransitionStartedMs) /
                                    static_cast<float>(kSystemMenuPageTransitionMs),
                                0.0f,
                                1.0f);
  const float remaining = 1.0f - smoothStep(0.0f, 1.0f, progress);
  return systemMenuPageTransitionDirection * static_cast<int>(roundf(remaining * 34.0f));
}

void drawSystemMenuChevron(bool left, int motion) {
  const int x = left ? 48 : kScreenW - 48;
  const int y = kCy;
  const int direction = left ? -1 : 1;
  const int pressOffset = direction * motion;
  const uint16_t color = motion > 0 ? kWhite : kGridBright;
  const int tipX = x + pressOffset + direction * 13;
  const int tailX = x + pressOffset - direction * 10;
  drawThickLine(tailX, y - 22, tipX, y, color, motion > 0 ? 7 : 5);
  drawThickLine(tipX, y, tailX, y + 22, color, motion > 0 ? 7 : 5);
}

void drawSystemMenuBars(int centerX,
                        uint8_t activeCount,
                        bool ascending,
                        int pressDepth,
                        bool flashed) {
  constexpr int kBarCount = 5;
  constexpr int kBarWidth = 28;
  constexpr int kBarGap = 12;
  constexpr int kBottom = 294;
  const int totalWidth = kBarCount * kBarWidth + (kBarCount - 1) * kBarGap;
  const int startX = centerX - totalWidth / 2;
  const int pressOffset = max(0, pressDepth);

  for (int index = 0; index < kBarCount; ++index) {
    const int height = ascending ? 34 + index * 11 : 74;
    const int x = startX + index * (kBarWidth + kBarGap);
    const int y = kBottom - height + pressOffset;
    const bool active = index < activeCount;
    const uint16_t color = active ? (flashed ? kWhite : kGridBright) : kGridDeep;
    gfx->fillRect(x, y, kBarWidth, max(10, height - pressOffset), color);
    if (!active) {
      gfx->drawRect(x, y, kBarWidth, max(10, height - pressOffset), kGridDim);
    }
  }
}

void drawSystemMenuCheck(int centerX, int centerY, uint16_t color, int motion) {
  const int radius = 43 - motion;
  const int y = centerY + max(0, motion);
  if (motion > 0) {
    gfx->fillCircle(centerX, y, radius, kGridDeep);
  }
  gfx->drawCircle(centerX, y, radius, color);
  gfx->drawCircle(centerX, y, radius - 4, kGridDim);
  drawThickLine(centerX - 17, y, centerX - 4, y + 13, color, 5);
  drawThickLine(centerX - 4, y + 13, centerX + 22, y - 16, color, 5);
}

void drawSystemMenuValue(int centerX, uint8_t value, uint16_t color, int motion) {
  const int centerY = kSystemMenuActionCenterY + max(0, motion);
  const int radius = 43 - motion;
  if (motion > 0) {
    gfx->fillCircle(centerX, centerY, radius, kGridDeep);
  }
  gfx->drawCircle(centerX, centerY, radius, color);
  gfx->drawCircle(centerX, centerY, radius - 4, kGridDim);
  char valueText[4];
  snprintf(valueText, sizeof(valueText), "%u", value);
  drawCenteredText(valueText, centerX, centerY, 6, color);
}

void drawScreenDirectionPreview(int centerX, uint16_t color, int pressDepth) {
  const int offsetY = max(0, pressDepth);
  const int centerY = 250 + offsetY;
  const bool twelveOClock =
      screenDirection == ScreenDirection::TwelveOClock;
  const int direction = twelveOClock ? -1 : 1;
  const int tailY = centerY - direction * 31;
  const int headY = centerY + direction * 31;
  drawThickLine(centerX, tailY, centerX, headY, color, 6);
  drawThickLine(centerX, headY,
                centerX - 13, headY - direction * 16,
                color, 6);
  drawThickLine(centerX, headY,
                centerX + 13, headY - direction * 16,
                color, 6);
}

void drawSystemMenuCommandPreview(int centerX,
                                  SystemMenuItem item,
                                  uint16_t color,
                                  int pressDepth) {
  const int offsetY = max(0, pressDepth);
  const int centerY = 250 + offsetY;
  switch (item) {
    case SystemMenuItem::Sleep:
      gfx->fillCircle(centerX - 8, centerY, 38, color);
      gfx->fillCircle(centerX + 10, centerY - 10, 38, kScreenBg);
      gfx->drawCircle(centerX - 8, centerY, 38, color);
      break;
    case SystemMenuItem::Standby:
      gfx->fillRect(centerX - 34, centerY - 38, 24, 76, color);
      gfx->fillRect(centerX + 10, centerY - 38, 24, 76, color);
      break;
    case SystemMenuItem::Off:
      gfx->drawArc(centerX, centerY + 3, 48, 44, 42, 318, color);
      drawThickLine(centerX, centerY - 55, centerX, centerY + 3, color, 7);
      break;
    case SystemMenuItem::Info: {
      const bool wifiOk = WiFi.status() == WL_CONNECTED;
      const bool roomOk = provisioning.relayConnected && provisioning.roomToken.length() > 0;
      const bool voiceOk = audioOnline && voiceInputOnline && provisioning.relayConnected;
      const bool batteryOk = batteryStatus.percent >= 0 && !batteryStatus.low;
      const bool states[4] = {wifiOk, roomOk, voiceOk, batteryOk};
      constexpr int kLampGap = 42;
      const int startX = centerX - (3 * kLampGap) / 2;
      for (int index = 0; index < 4; ++index) {
        const int x = startX + index * kLampGap;
        const uint16_t lampColor = states[index] ? kGridBright : kAmber;
        gfx->drawCircle(x, centerY, 13, kGridDim);
        gfx->fillCircle(x, centerY, 8, lampColor);
      }
      break;
    }
    case SystemMenuItem::Reset:
      gfx->drawCircle(centerX, centerY, 46, color);
      gfx->drawCircle(centerX, centerY, 36, kGridDim);
      drawThickLine(centerX - 22, centerY - 22, centerX + 22, centerY + 22, color, 6);
      drawThickLine(centerX + 22, centerY - 22, centerX - 22, centerY + 22, color, 6);
      break;
    default:
      break;
  }
}

void drawSystemMenuPositionTicks(uint8_t selectedIndex) {
  constexpr int kGap = 42;
  const int startX = kCx - ((kSystemMenuItemCount - 1) * kGap) / 2;
  for (uint8_t index = 0; index < kSystemMenuItemCount; ++index) {
    const int x = startX + index * kGap;
    const uint16_t color = index == selectedIndex ? kGridBright : kGridDeep;
    drawThickLine(x, 412, x, 427, color, index == selectedIndex ? 7 : 5);
  }
}

void drawSystemMenuScreen() {
  drawSystemBackdrop();
  const uint32_t now = millis();
  const bool touchingMenu = touchWasPressed && radarUiMode == RadarUiMode::SystemMenu;
  const SystemMenuFeedbackTarget pressedTarget = touchingMenu
                                                      ? systemMenuFeedbackTargetAt(touchLastX, touchLastY)
                                                      : SystemMenuFeedbackTarget::None;
  const int leftMotion = pressedTarget == SystemMenuFeedbackTarget::Previous
                             ? 4
                             : systemMenuControlFeedbackPulse(SystemMenuFeedbackTarget::Previous, now);
  const int rightMotion = pressedTarget == SystemMenuFeedbackTarget::Next
                              ? 4
                              : systemMenuControlFeedbackPulse(SystemMenuFeedbackTarget::Next, now);
  const int actionMotion = pressedTarget == SystemMenuFeedbackTarget::Action
                               ? 4
                               : -systemMenuControlFeedbackPulse(SystemMenuFeedbackTarget::Action, now);
  const int contentX = kCx + systemMenuPageOffsetX(now);
  const bool flashed = systemMenuFlashItem == systemMenuSelectedItem && now < settingsFlashUntilMs;
  const bool destructiveItem = systemMenuSelectedItem == SystemMenuItem::Off ||
                               systemMenuSelectedItem == SystemMenuItem::Reset;
  const uint16_t activeColor = destructiveItem ? kAmber : kGridBright;
  const uint16_t labelColor = destructiveItem ? kAmber : kWhite;
  const int labelOffsetY = max(0, actionMotion) / 2;

  drawSystemMenuChevron(true, leftMotion);
  drawSystemMenuChevron(false, rightMotion);
  drawCenteredText(systemMenuItemLabel(systemMenuSelectedItem),
                   contentX,
                   118 + labelOffsetY,
                   11,
                   flashed ? activeColor : labelColor);

  if (systemMenuSelectedItem == SystemMenuItem::Volume) {
    drawSystemMenuBars(contentX,
                       min<uint8_t>(audioPreset, 5),
                       false,
                       max(0, actionMotion),
                       flashed);
    drawSystemMenuValue(contentX, min<uint8_t>(audioPreset, 5), activeColor, actionMotion);
  } else if (systemMenuSelectedItem == SystemMenuItem::Brightness) {
    const uint8_t level = min<uint8_t>(brightnessPreset + 1, 5);
    drawSystemMenuBars(contentX, level, true, max(0, actionMotion), flashed);
    drawSystemMenuValue(contentX, level, activeColor, actionMotion);
  } else if (systemMenuSelectedItem == SystemMenuItem::Direction) {
    drawScreenDirectionPreview(
        contentX, activeColor, max(0, actionMotion));
    drawSystemMenuValue(
        contentX,
        DragonRadarDisplayOrientation::persistedValue(screenDirection),
        activeColor,
        actionMotion);
  } else {
    drawSystemMenuCommandPreview(contentX,
                                 systemMenuSelectedItem,
                                 activeColor,
                                 max(0, actionMotion));
    drawSystemMenuCheck(contentX,
                        kSystemMenuActionCenterY,
                        activeColor,
                        actionMotion);
  }

  drawSystemMenuPositionTicks(systemMenuItemIndex(systemMenuSelectedItem));
  gfx->flush();
}

void drawInfoScreen() {
  drawSystemBackdrop();
  drawCenteredText("INFO", kCx, 63, 2, kGridBright);

  const bool wifiOk = WiFi.status() == WL_CONNECTED;
  const bool roomOk = provisioning.relayConnected && provisioning.roomToken.length() > 0;
  const bool voiceBusy = remoteRoomVoiceBusy();
  const bool voiceOk = audioOnline && voiceInputOnline && provisioning.relayConnected;
  char versionText[48];
  snprintf(versionText, sizeof(versionText), "VERSION %s", DragonRadarFirmware::kVersion);
  const char *rows[5] = {
      wifiOk ? "WIFI OK" : "WIFI LOST",
      roomOk ? "ROOM OK" : "ROOM LOST",
      voiceBusy ? "VOICE BUSY" : (voiceOk ? "VOICE OK" : "VOICE LOST"),
      nullptr,
      versionText,
  };
  char batteryText[24];
  if (batteryStatus.percent >= 0) {
    snprintf(batteryText, sizeof(batteryText), "BAT %d%%", batteryStatus.percent);
  } else {
    snprintf(batteryText, sizeof(batteryText), "BAT UNKNOWN");
  }
  rows[3] = batteryText;

  for (uint8_t i = 0; i < 5; ++i) {
    const int y = 130 + i * 50;
    gfx->drawFastHLine(104, y + 22, kScreenW - 208, i == 4 ? kGridDim : kGridDeep);
    drawCenteredText(rows[i], kCx, y, 2,
                     strstr(rows[i], "LOST") ? kAmber : kGrid);
  }
  drawCenteredText("INFO", kCx, 409, 1, kGridDim);
  gfx->flush();
}

void drawPowerConfirmScreen() {
  drawSystemBackdrop();
  drawCenteredText("HOLD TO OFF", kCx, 66, 2, kAmber);
  gfx->fillCircle(kCx + 6, kCy + 7, 92, kPhosphorEdge);
  gfx->fillCircle(kCx, kCy, 92, kScreenBg);
  gfx->drawCircle(kCx, kCy, 92, kAmber);
  gfx->drawCircle(kCx, kCy, 84, kGridDim);
  gfx->drawArc(kCx, kCy - 8, 37, 34, 42, 318, kAmber);
  gfx->drawFastVLine(kCx, kCy - 62, 45, kAmber);
  drawCenteredText("OFF", kCx, kCy + 52, 2, kAmber);

  if (powerConfirmPressedAtMs > 0) {
    const uint32_t heldMs = min<uint32_t>(millis() - powerConfirmPressedAtMs, kPowerConfirmHoldMs);
    constexpr uint8_t kProgressTicks = 30;
    const uint8_t activeTicks = static_cast<uint8_t>((heldMs * kProgressTicks) / kPowerConfirmHoldMs);
    for (uint8_t i = 0; i < kProgressTicks; ++i) {
      const float angle = degToRad(-90.0f + i * (360.0f / kProgressTicks));
      const int x0 = kCx + static_cast<int>(cosf(angle) * 103.0f);
      const int y0 = kCy + static_cast<int>(sinf(angle) * 103.0f);
      const int x1 = kCx + static_cast<int>(cosf(angle) * 112.0f);
      const int y1 = kCy + static_cast<int>(sinf(angle) * 112.0f);
      gfx->drawLine(x0, y0, x1, y1, i < activeTicks ? kGridBright : kGridDeep);
    }
  }
  drawCenteredText("CANCEL", kCx, 403, 1, kGridDim);
  gfx->flush();
}

void drawFactoryResetConfirmScreen() {
  drawSystemBackdrop();
  drawCenteredText("HOLD TO RESET", kCx, 66, 2, kAmber);
  gfx->fillCircle(kCx + 6, kCy + 7, 92, kPhosphorEdge);
  gfx->fillCircle(kCx, kCy, 92, kScreenBg);
  gfx->drawCircle(kCx, kCy, 92, kAmber);
  gfx->drawCircle(kCx, kCy, 84, kGridDim);
  drawThickLine(kCx - 28, kCy - 28, kCx + 28, kCy + 28, kAmber, 7);
  drawThickLine(kCx + 28, kCy - 28, kCx - 28, kCy + 28, kAmber, 7);
  drawCenteredText("BIND", kCx, kCy + 58, 2, kAmber);

  if (powerConfirmPressedAtMs > 0) {
    const uint32_t heldMs = min<uint32_t>(millis() - powerConfirmPressedAtMs,
                                          kFactoryResetConfirmHoldMs);
    constexpr uint8_t kProgressTicks = 30;
    const uint8_t activeTicks = static_cast<uint8_t>(
        (heldMs * kProgressTicks) / kFactoryResetConfirmHoldMs);
    for (uint8_t i = 0; i < kProgressTicks; ++i) {
      const float angle = degToRad(-90.0f + i * (360.0f / kProgressTicks));
      const int x0 = kCx + static_cast<int>(cosf(angle) * 103.0f);
      const int y0 = kCy + static_cast<int>(sinf(angle) * 103.0f);
      const int x1 = kCx + static_cast<int>(cosf(angle) * 112.0f);
      const int y1 = kCy + static_cast<int>(sinf(angle) * 112.0f);
      gfx->drawLine(x0, y0, x1, y1, i < activeTicks ? kAmber : kGridDeep);
    }
  }
  drawCenteredText("CLEARS WIFI + OWNER", kCx, 403, 1, kGridDim);
  gfx->flush();
}

void drawShutdownPendingScreen() {
  gfx->fillScreen(kBlack);
  gfx->drawCircle(kCx, kCy, 96, kGridDim);
  gfx->drawCircle(kCx + 4, kCy + 5, 102, kPhosphorEdge);
  drawCenteredText("POWERING", kCx, kCy - 15, 2, kGrid);
  drawCenteredText("OFF", kCx, kCy + 20, 2, kGridBright);
  gfx->flush();
}

void drawFirmwareUpdateScreen() {
  const DragonRadarOta::Snapshot ota = otaManager.snapshot();
  drawSystemBackdrop();
  drawCenteredText("FIRMWARE", kCx, 62, 2, kGridBright);

  const char *phase = "UPDATE";
  uint16_t phaseColor = kGrid;
  switch (ota.phase) {
    case DragonRadarOta::Phase::Validating: phase = "CHECKING"; break;
    case DragonRadarOta::Phase::Downloading: phase = "DOWNLOADING"; break;
    case DragonRadarOta::Phase::Verifying: phase = "VERIFYING"; break;
    case DragonRadarOta::Phase::Rebooting: phase = "REBOOTING"; break;
    case DragonRadarOta::Phase::PendingVerify: phase = "BOOT CHECK"; break;
    case DragonRadarOta::Phase::Success: phase = "SUCCESS"; phaseColor = kGridBright; break;
    case DragonRadarOta::Phase::Error: phase = "UPDATE ERROR"; phaseColor = kAmber; break;
    case DragonRadarOta::Phase::RolledBack: phase = "ROLLED BACK"; phaseColor = kAmber; break;
    case DragonRadarOta::Phase::Cancelled: phase = "CANCELLED"; phaseColor = kAmber; break;
    default: break;
  }
  drawCenteredText(phase, kCx, 145, 2, phaseColor);

  constexpr int kBarX = 76;
  constexpr int kBarY = 214;
  constexpr int kBarW = kScreenW - kBarX * 2;
  constexpr int kBarH = 24;
  gfx->drawRect(kBarX, kBarY, kBarW, kBarH, kGridDim);
  const int filled = static_cast<int>((static_cast<uint32_t>(kBarW - 6) * ota.progress) / 100U);
  if (filled > 0) {
    gfx->fillRect(kBarX + 3, kBarY + 3, filled, kBarH - 6, phaseColor);
  }

  char progressText[24];
  snprintf(progressText, sizeof(progressText), "%u%%", ota.progress);
  drawCenteredText(progressText, kCx, 270, 3, kWhite);
  if (ota.targetVersion.length() > 0) {
    char targetText[48];
    snprintf(targetText, sizeof(targetText), "TARGET %s", ota.targetVersion.c_str());
    drawCenteredText(targetText, kCx, 329, 1, kGrid);
  }
  if (ota.error.length() > 0) {
    drawCenteredText(ota.error.c_str(), kCx, 370, 1, kAmber);
  } else if (ota.phase == DragonRadarOta::Phase::PendingVerify) {
    drawCenteredText("DISPLAY + BLE", kCx, 370, 1, kGridDim);
  }
  gfx->flush();
}

void drawCurrentModeFrame() {
  if (otaManager.shouldShowOverlay()) {
    drawFirmwareUpdateScreen();
    return;
  }
  if (radarUiMode == RadarUiMode::ScreenOff || radarUiMode == RadarUiMode::Standby) {
    return;
  }
  if (radarUiMode == RadarUiMode::SystemMenu) {
    drawSystemMenuScreen();
    return;
  }
  if (radarUiMode == RadarUiMode::Info) {
    drawInfoScreen();
    return;
  }
  if (radarUiMode == RadarUiMode::PowerConfirm) {
    drawPowerConfirmScreen();
    return;
  }
  if (radarUiMode == RadarUiMode::FactoryResetConfirm) {
    drawFactoryResetConfirmScreen();
    return;
  }
  if (radarUiMode == RadarUiMode::ShutdownPending) {
    drawShutdownPendingScreen();
    return;
  }

  if (millis() < displaySelfTestUntilMs) {
    drawDisplaySelfTest();
    gfx->flush();
    return;
  }

  const uint32_t now = millis();
  renderedRadarRotationDeg = radarDisplayRotationDeg();
  drawRadarGrid();
  if (!radarNetworkOnline() || activeRemoteAppLocationCount(now) == 0) {
    drawTargets();
  }
  drawRemoteAppMarker();
  drawButtonTapEffects(now);
  drawPttEdgeRipple(now);
  drawHomeMarker(now);
  drawCalibratedNorthMarker();
  drawSignalLostBanner(now);
  drawNetworkErrorBanner();
  drawHeadingCalibrationPrompt(now);
  drawHeadingAlignmentFeedback(now);
  gfx->flush();
}

void drawFrame() {
  drawCurrentModeFrame();
  const uint32_t now = millis();
  if (drawBlePairingOverlay(now)) {
    gfx->flush();
  }
  if (radarUiMode == RadarUiMode::Main && now >= displaySelfTestUntilMs) {
    updateMainFadeBrightness(now);
  }
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("Capsule Radar firmware boot");
  Serial.println("AUDIO_PATH_FULL_DUPLEX_20260609_01");
  otaManager.begin();

  loadRuntimeSettings();
  loadProvisioningState();
  initRadarChordHalfCache();
  randomSeed(esp_random());
  Wire.begin(IIC_SDA, IIC_SCL);
  setupImu();

  setupBatteryGauge();
  setupPowerButton();
  setupButtons();
  resetPanelAndTouch();
  setupTouch();
  setupBootAudio();

  displayOnline = gfx->begin(kDisplayBusHz);
  if (!displayOnline) {
    Serial.println("Display init failed.");
  }
  applyScreenDirection();
  panel->setBrightness(currentBrightness());
  gfx->fillScreen(kBlack);
  gfx->flush();

  runBootAnimation();
  setupAudio();

  setupBle();
  otaManager.setBootHealth(displayOnline, provisioning.serviceOnline);
  printHardwareSummary();
  printSerialCommandHelp();
  radarStartedMs = millis();
}

void loop() {
  if (radarUiMode != RadarUiMode::Standby &&
      radarUiMode != RadarUiMode::ShutdownPending) {
    readImu();
  }
  pollPowerButton();
  pollButtons();
  pollTouch();
  systemUiTick();
  provisioningTick();
  firmwareOtaTick();
  cloudRelayTick();
  if (radarUiMode != RadarUiMode::Standby && !otaManager.blocksPowerAndVoice()) {
    voiceCaptureTick();
  }
  serialCommandTick();
  serialDiagnosticsTick();
  handleAudioEvents();
  audioTick();

  const uint32_t now = millis();
  if ((radarUiDisplayActive() || otaManager.shouldShowOverlay()) &&
      now - lastFrameMs >= currentFrameMs()) {
    const float dt = (now - lastFrameMs) / 1000.0f;
    lastFrameMs = now;
    if (scanning) {
      sweepDeg = wrap360(sweepDeg + 185.0f * dt);
    }
    const uint32_t drawStartedMs = millis();
    drawFrame();
    lastDrawMs = millis() - drawStartedMs;
    recordFramePerformance(lastDrawMs, currentFrameMs(), millis());
  }

  delay(1);
}
