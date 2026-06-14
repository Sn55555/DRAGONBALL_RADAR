#include <Arduino.h>
#include <Arduino_GFX_Library.h>
#include <BLEAdvertisedDevice.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <Network.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <WebSocketsClient.h>
#include <ESP_I2S.h>
#include <Preferences.h>
#include <Wire.h>
#include <base64.h>
#include <esp_system.h>
#include <math.h>
#include <mbedtls/md.h>
#include <string.h>

#include "SensorQMI8658.hpp"
#include "TouchDrvCSTXXX.hpp"
#include "beach_scene_assets.h"
#include "bulma_boot_badge.h"
#include "easter_badge.h"
#include "pin_config.h"

#ifndef USE_PRIVATE_BOOT_LOGO
#define USE_PRIVATE_BOOT_LOGO 0
#endif

#ifndef DRAGON_RADAR_DEBUG_HUD
#define DRAGON_RADAR_DEBUG_HUD 0
#endif

#ifndef DRAGON_RADAR_SCAN_LINE
#define DRAGON_RADAR_SCAN_LINE 0
#endif

#ifndef DRAGON_RADAR_STAR_BLIPS
#define DRAGON_RADAR_STAR_BLIPS 0
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

#ifndef DRAGON_RADAR_BEACH_SCENE
#define DRAGON_RADAR_BEACH_SCENE 0
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

#if USE_PRIVATE_BOOT_LOGO
#if __has_include("private_boot_logo.h")
#include "private_boot_logo.h"
#endif
#endif
#include "boot_audio_pcm.h"

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
static_assert(DRAGON_RADAR_BEACH_SCENE == 0 || DRAGON_RADAR_BEACH_SCENE == 1,
              "DRAGON_RADAR_BEACH_SCENE must be 0 or 1");
static_assert(DRAGON_RADAR_FRAME_MS >= 20 && DRAGON_RADAR_FRAME_MS <= 180,
              "DRAGON_RADAR_FRAME_MS must be in 20..180");
static_assert(DRAGON_RADAR_DISPLAY_BUS_HZ >= 20000000 && DRAGON_RADAR_DISPLAY_BUS_HZ <= 80000000,
              "DRAGON_RADAR_DISPLAY_BUS_HZ must be in 20000000..80000000");
static_assert(DRAGON_RADAR_BOOT_FRAME_DELAY_MS >= 30 && DRAGON_RADAR_BOOT_FRAME_DELAY_MS <= 140,
              "DRAGON_RADAR_BOOT_FRAME_DELAY_MS must be in 30..140");

namespace {

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
constexpr uint32_t kEasterDisplayMs = 1600;
constexpr uint32_t kScanKickMs = 30000;
constexpr uint32_t kRetiredTargetHoldMs = 1200;
constexpr int kRetiredTargetCloseRssi = -50;
constexpr uint32_t kCaptureFlashMs = 1100;
constexpr uint32_t kResetFlashMs = 640;
constexpr uint32_t kSummonGatherMs = 1600;
constexpr uint32_t kStartupAcquireMs = 980;
constexpr uint32_t kAcquisitionEchoMs = 760;
constexpr uint32_t kTouchEchoMs = 520;
constexpr uint32_t kPttRippleArchRiseMs = 180;
constexpr uint32_t kPttRippleReleaseMs = 860;
constexpr uint32_t kButtonTapPressMs = 220;
constexpr uint32_t kButtonTapReleaseMs = 360;
constexpr uint32_t kButtonDebounceMs = 45;
constexpr uint32_t kButtonLongPressMs = 900;
constexpr uint16_t kFarChirpIntervalMs = 820;
constexpr uint16_t kNearChirpIntervalMs = 260;
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
constexpr bool kShowStarBlips = DRAGON_RADAR_STAR_BLIPS;
constexpr bool kSnapTargetsToGrid = DRAGON_RADAR_GRID_SNAP;
constexpr bool kSerialDiagnostics = DRAGON_RADAR_SERIAL_DIAG;
constexpr bool kRemoteBleEnabled = DRAGON_RADAR_REMOTE_BLE;
constexpr bool kAllowLegacyPairing = DRAGON_RADAR_ALLOW_LEGACY_PAIRING;
constexpr const char *kPairingHmacKey = DRAGON_RADAR_PAIRING_HMAC_KEY;
constexpr bool kBeachSceneMode = DRAGON_RADAR_BEACH_SCENE;
constexpr uint8_t kZoomLevelCount = 3;
constexpr float kZoomBaseScales[kZoomLevelCount] = {1.0f, 1.48f, 2.12f};
constexpr uint8_t kFocusNone = 255;
constexpr uint8_t kFocusRemoteApp = 7;
constexpr uint8_t kRemoteAppSlotCount = 6;
constexpr uint32_t kFocusFlashMs = 900;
constexpr int kFocusEdgeMarginPx = 18;
constexpr uint8_t kTargetTrailCount = 3;
constexpr uint32_t kTargetTrailFadeMs = 1280;
constexpr uint8_t kTargetTrailMovePx = 8;
constexpr uint8_t kSummonCoreTickCount = 7;
constexpr uint8_t kProximityEdgeTickCount = 5;
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
constexpr uint8_t kBearingBinCount = 16;
constexpr uint8_t kBrightnessPresetCount = 5;
constexpr uint8_t kAudioPresetCount = 6;
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
constexpr uint32_t kDeviceStatusNotifyMs = 2000;
constexpr uint32_t kRelayReconnectMs = 5000;
constexpr uint32_t kRelayHeartbeatMs = 15000;
constexpr uint32_t kRelayStatusMs = 5000;
constexpr uint32_t kBatteryPollMs = 10000;
constexpr int8_t kLowBatteryPercent = 20;
constexpr uint32_t kRemoteAppMarkerTtlMs = 30000;
constexpr uint32_t kLocationReceiveBlinkMs = 180;
constexpr uint32_t kLocationReceiveBlinkIntervalMs = 2000;
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

enum class RadarGattWriteRole : uint8_t {
  PairingResponse,
  WifiConfig,
  LocalLocation,
  ServerConfig,
};

struct RemoteLocationFrame {
  bool valid = false;
  int32_t latE7 = 0;
  int32_t lonE7 = 0;
  uint16_t horizontalAccuracyCm = 0;
  uint16_t speedCms = 0;
  uint16_t courseDeg100 = 0;
  uint32_t unixTime = 0;
  uint32_t receivedMs = 0;
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

struct FocusCandidate {
  uint8_t slot = kFocusNone;
  float angle = 0.0f;
  float range = 0.0f;
};

struct RemoteProvisioningState {
  bool serviceOnline = false;
  bool appConnected = false;
  bool paired = false;
  bool wifiConnectRequested = false;
  bool wifiConnectInFlight = false;
  bool serverConfigured = false;
  bool relaySocketConfigured = false;
  bool relayConnected = false;
  bool locationReceived = false;
  char deviceName[28] = {0};
  char challenge[24] = {0};
  String pairingResponse;
  String wifiSsid;
  String wifiPassword;
  String relayUrl;
  String roomToken;
  String deviceToken;
  String lastWrite = "none";
  String relayState = "idle";
  uint32_t lastStatusNotifyMs = 0;
};

struct RetiredTarget {
  uint8_t star = 0;
  bool seen = false;
  bool demo = true;
  bool collected = false;
  int rssi = -99;
  int filteredRssi = -99;
  int bestRssi = -127;
  uint32_t lastSeenMs = 0;
  uint32_t revealedAtMs = 0;
  uint32_t closeSinceMs = 0;
  uint32_t collectedAtMs = 0;
  float worldAngleDeg = 0.0f;
  float rangeNorm = 0.9f;
  uint8_t bearingScores[kBearingBinCount] = {0};
  uint8_t bestBearingBin = 0;
  int16_t lastScreenX = 0;
  int16_t lastScreenY = 0;
  uint32_t lastTrailMs = 0;
  int16_t trailX[kTargetTrailCount] = {0};
  int16_t trailY[kTargetTrailCount] = {0};
  uint32_t trailMs[kTargetTrailCount] = {0};
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

struct BeachWalker {
  const BeachSceneAssets::SpriteFrames *frames = nullptr;
  int16_t x = 0;
  int16_t y = 0;
  int8_t dir = 1;
  uint16_t speed = 22;
  uint32_t nextTurnMs = 0;
  uint8_t gaitOffset = 0;
};

struct BootAudioCue {
  float phase = 0.0f;
  float frequency = 0.0f;
  uint16_t durationMs = 0;
  int16_t level = 0;
};

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
I2SClass i2s;

RetiredTarget targets[7];
BLEServer *provisioningServer = nullptr;
BLECharacteristic *pairingChallengeCharacteristic = nullptr;
BLECharacteristic *deviceStatusCharacteristic = nullptr;
WebSocketsClient relaySocket;
AudioTone tone;
VoiceCaptureState voiceCapture;
BatteryStatus batteryStatus;
RemoteProvisioningState provisioning;
RemoteLocationFrame selfLocationFrame;
RemoteLocationFrame remoteAppLocationFrame;
String remoteAppPeerName;
RemoteLocationFrame remoteAppLocationFrames[kRemoteAppSlotCount];
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
bool audioOnline = false;
bool voiceInputOnline = false;
bool powerButtonOnline = false;
bool demoMode = false;
bool scanning = true;
bool retiredTargetOverlayMode = false;
bool settingsMode = false;
bool easterMode = false;
uint8_t zoomLevel = 0;
uint8_t focusedTargetSlot = kFocusNone;
uint8_t brightnessPreset = 2;
uint8_t audioPreset = 4;
uint8_t framePreset = 0;

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
uint32_t lastSelfLocationPersistMs = 0;
uint32_t lastImuMicros = 0;
uint32_t lastScanChirpMs = 0;
uint32_t lastSignalLostBeepPhase = UINT32_MAX;
uint32_t retiredTargetOverlayStartedMs = 0;
uint32_t radarStartedMs = 0;
uint32_t zoomFlashUntilMs = 0;
uint32_t focusFlashUntilMs = 0;
uint32_t resetFlashUntilMs = 0;
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
uint32_t displaySelfTestUntilMs = 0;
uint32_t lastDiagMs = 0;
uint32_t lastBleDiagMs[7] = {0};
uint32_t lastSimulatedBleMs = 0;
int16_t radarChordHalfCache[kRadarChordCacheSize] = {0};
bool radarChordHalfCacheReady = false;
float headingDeg = 0.0f;
float sweepDeg = 0.0f;
float tiltEnergy = 0.0f;
float tiltVectorX = 0.0f;
float tiltVectorY = 0.0f;
uint8_t lastActiveCount = 0;
uint8_t lastCollectedCount = 0;
uint16_t radarSessionId = 1;
String serialCommandLine;
bool bootButtonWasPressed = false;
bool bootButtonLongHandled = false;
bool altButtonWasPressed = false;
bool altButtonLongHandled = false;
bool touchWasPressed = false;
bool touchLongHandled = false;
bool edgeGestureActive = false;
bool edgeGestureConsumed = false;
int16_t touchStartX = 0;
int16_t touchStartY = 0;
int16_t touchLastX = 0;
int16_t touchLastY = 0;
int16_t touchEchoX = kCx;
int16_t touchEchoY = kCy;
float gridGestureScale = 1.0f;
float edgeGestureLastAngle = 0.0f;
BeachWalker beachWalkers[2];
bool beachSceneReady = false;
uint32_t lastBeachUpdateMs = 0;
uint32_t beachControlUntilMs = 0;
int8_t beachControlDir = 1;
wl_status_t lastLoggedWifiStatus = WL_IDLE_STATUS;

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
String localRelayPeerId();
String localAppRelayPeerId();
void snapPointToGrid(int &x, int &y);
void printHardwareSummary();
void printSerialCommandHelp();
void printRadarEvent(const char *event, uint32_t now);
void serialDiagnosticsTick();
int circleChordHalf(int offset, int radius = kRadarRadius);
void resetEdgeGesture();
void runBootAnimation();
void toggleSettingsMode();
void drawCurrentModeFrame();
void showEasterEgg();
void handleBootShortPress();
void setupPowerButton();
void pollPowerButton();
void initBeachScene();
bool handleBeachSwipeGesture(int16_t startX, int16_t startY, int16_t endX, int16_t endY);
void updateBeachScene(uint32_t now);
void drawBeachScene();

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

uint8_t activeTargetCount() {
  return 0;
}

uint8_t collectedTargetCount() {
  return 0;
}

int strongestActiveTargetIndex() {
  return -1;
}

int rssiToBarWidth(int rssi, int width) {
  const int clamped = constrain(rssi, -95, -35);
  return ((clamped + 95) * width) / 60;
}

uint8_t headingToBearingBin(float heading) {
  const float normalized = wrap360(heading);
  int bin = static_cast<int>((normalized * kBearingBinCount) / 360.0f);
  if (bin < 0) {
    bin = 0;
  } else if (bin >= kBearingBinCount) {
    bin = kBearingBinCount - 1;
  }
  return static_cast<uint8_t>(bin);
}

float bearingBinCenter(uint8_t bin) {
  return wrap360((static_cast<float>(bin) + 0.5f) * (360.0f / kBearingBinCount));
}

uint8_t rssiToBearingScore(int rssi) {
  const int clamped = constrain(rssi, -95, -35);
  return static_cast<uint8_t>(constrain((clamped + 95) * 4, 1, 240));
}

void resetBearingScores(RetiredTarget &target) {
  memset(target.bearingScores, 0, sizeof(target.bearingScores));
  target.bestBearingBin = headingToBearingBin(target.worldAngleDeg);
}

void addBearingScore(RetiredTarget &target, uint8_t bin, uint8_t sample) {
  const uint16_t previous = target.bearingScores[bin];
  const uint16_t blended = (previous * 3 + sample) / 4;
  uint16_t next = blended > previous ? blended : previous;
  if (next > 255) {
    next = 255;
  }
  target.bearingScores[bin] = static_cast<uint8_t>(next);
}

void updateBearingEstimate(RetiredTarget &target, int rssi, bool reset) {
  if (reset) {
    resetBearingScores(target);
  }

  for (uint8_t i = 0; i < kBearingBinCount; ++i) {
    if (target.bearingScores[i] > 0) {
      --target.bearingScores[i];
    }
  }

  const uint8_t bin = headingToBearingBin(headingDeg);
  const uint8_t prevBin = (bin + kBearingBinCount - 1) % kBearingBinCount;
  const uint8_t nextBin = (bin + 1) % kBearingBinCount;
  const uint8_t score = rssiToBearingScore(rssi);
  addBearingScore(target, bin, score);
  addBearingScore(target, prevBin, static_cast<uint8_t>((score * 2) / 3));
  addBearingScore(target, nextBin, static_cast<uint8_t>((score * 2) / 3));

  uint8_t bestBin = target.bestBearingBin;
  uint8_t bestScore = target.bearingScores[bestBin];
  for (uint8_t i = 0; i < kBearingBinCount; ++i) {
    if (target.bearingScores[i] > bestScore) {
      bestScore = target.bearingScores[i];
      bestBin = i;
    }
  }

  if (bestScore > 0) {
    target.bestBearingBin = bestBin;
    const float targetAngle = bearingBinCenter(bestBin);
    const float lock = clampf((bestScore - 18.0f) / 150.0f, 0.12f, reset ? 1.0f : 0.42f);
    target.worldAngleDeg = lerpAngleDeg(target.worldAngleDeg, targetAngle, lock);
  }
}

float targetNearness(const RetiredTarget &target) {
  return clampf((0.96f - target.rangeNorm) / (0.96f - 0.13f), 0.0f, 1.0f);
}

uint16_t targetChirpIntervalMs(const RetiredTarget &target) {
  if (target.closeSinceMs > 0) {
    return 180;
  }
  const float near = targetNearness(target);
  return static_cast<uint16_t>(lerpf(kFarChirpIntervalMs, kNearChirpIntervalMs, near));
}

float targetChirpFrequency(const RetiredTarget &target, uint8_t activeCount) {
  const float near = targetNearness(target);
  float freq = lerpf(900.0f, 1540.0f, near) + activeCount * 24.0f;
  if (target.closeSinceMs > 0) {
    freq += 220.0f;
  }
  return freq;
}

uint16_t targetChirpDurationMs(const RetiredTarget &target) {
  return static_cast<uint16_t>(lerpf(26.0f, 48.0f, targetNearness(target)));
}

int16_t targetChirpLevel(const RetiredTarget &target) {
  return static_cast<int16_t>(lerpf(2200.0f, 3900.0f, targetNearness(target)));
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
  prefs.end();
}

void setFrameTurbo() {
  framePreset = 0;
  frameFlashUntilMs = millis() + 700;
  saveRuntimeSettings();
  startTone(720.0f, 48, 2600, true);
}

void resetTargetTrail(RetiredTarget &target) {
  target.lastScreenX = 0;
  target.lastScreenY = 0;
  target.lastTrailMs = 0;
  memset(target.trailX, 0, sizeof(target.trailX));
  memset(target.trailY, 0, sizeof(target.trailY));
  memset(target.trailMs, 0, sizeof(target.trailMs));
}

void resetAllTargetTrails() {
  for (auto &target : targets) {
    resetTargetTrail(target);
  }
}

void clearRetiredTargetState() {
  for (auto &target : targets) {
    target.seen = false;
    target.demo = true;
    target.collected = false;
    target.rssi = -99;
    target.filteredRssi = -99;
    target.bestRssi = -127;
    target.lastSeenMs = 0;
    target.revealedAtMs = 0;
    target.closeSinceMs = 0;
    target.collectedAtMs = 0;
    resetBearingScores(target);
    resetTargetTrail(target);
  }
  lastActiveCount = 0;
  lastCollectedCount = 0;
}

void resetRadarDisplayState() {
  clearRetiredTargetState();
  ++radarSessionId;
  resetFlashUntilMs = millis() + kResetFlashMs;
  startTone(620.0f, 70, 3000, true);
  printRadarEvent("reset", millis());
}

void printRadarEvent(const char *event, uint32_t now) {
  if (!kSerialDiagnostics) {
    return;
  }

  Serial.print("DIAG radar session=");
  Serial.print(radarSessionId);
  Serial.print(" event=");
  Serial.print(event);
  Serial.print(" ms=");
  Serial.println(now);
}

void cycleMapScale() {
  zoomLevel = (zoomLevel + 1) % kZoomLevelCount;
  resetAllTargetTrails();
  zoomFlashUntilMs = millis() + 700;
  startTone(820.0f + zoomLevel * 220.0f, 64, 2800, true);
}

bool targetDisplayCandidate(uint8_t slot, uint32_t now, float &angle, float &range) {
  (void)slot;
  (void)now;
  (void)angle;
  (void)range;
  return false;
}

uint8_t remoteSlotFromFocusSlot(uint8_t slot) {
  if (slot < kFocusRemoteApp || slot >= kFocusRemoteApp + kRemoteAppSlotCount) {
    return kRemoteAppSlotCount;
  }
  return static_cast<uint8_t>(slot - kFocusRemoteApp);
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
    distanceM = geoDistanceMeters(selfLocationFrame, frame);
    distanceKnown = true;
    angle = geoBearingDeg(selfLocationFrame, frame);
    range = remoteDistanceToRange(distanceM);
  } else {
    const float t = now / 1000.0f;
    angle = wrap360(42.0f + remoteSlot * 38.0f + sinf(t * 0.52f + remoteSlot) * 10.0f);
    range = 0.35f + remoteSlot * 0.13f + 0.04f * sinf(t * 0.8f + remoteSlot);
    range = clampf(range, 0.22f, 0.88f);
  }
  return true;
}

bool focusSlotAvailable(uint8_t slot, uint32_t now, float &angle, float &range) {
  if (slot >= kFocusRemoteApp && slot < kFocusRemoteApp + kRemoteAppSlotCount) {
    float distanceM = 0.0f;
    bool distanceKnown = false;
    return remoteAppDisplayCandidate(remoteSlotFromFocusSlot(slot), now, angle, range, distanceM, distanceKnown);
  }
  return targetDisplayCandidate(slot, now, angle, range);
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
  resetAllTargetTrails();
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
  constexpr uint8_t kFocusOrderCount = kRemoteAppSlotCount + 7;
  for (uint8_t index = 0; index < kFocusOrderCount && count < maxCandidates; ++index) {
    const uint8_t slot =
        index < kRemoteAppSlotCount ? static_cast<uint8_t>(kFocusRemoteApp + index)
                                    : static_cast<uint8_t>(index - kRemoteAppSlotCount);
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
  constexpr int kFocusOrderCount = kRemoteAppSlotCount + 7;
  FocusCandidate candidates[kFocusOrderCount];
  const uint8_t count = collectFocusCandidates(now, candidates, kFocusOrderCount);
  if (count == 0) {
    focusedTargetSlot = kFocusNone;
    return false;
  }

  uint8_t currentIndex = count;
  for (uint8_t i = 0; i < count; ++i) {
    if (candidates[i].slot == focusedTargetSlot) {
      currentIndex = i;
      break;
    }
  }

  const uint8_t nextIndex = currentIndex < count ? static_cast<uint8_t>((currentIndex + 1) % count) : 0;
  focusedTargetSlot = candidates[nextIndex].slot;
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
  startTone(620.0f + brightnessPreset * 160.0f, 48, 2200, true);
}

void cycleAudioGain() {
  audioPreset = (audioPreset + 1) % kAudioPresetCount;
  saveRuntimeSettings();
  applyCodecOutputVolume();
  audioFlashUntilMs = millis() + 700;
  startTone(540.0f + audioPreset * 180.0f, 56, 3000, true);
}

void toggleSettingsMode() {
  const bool nextSettingsMode = !settingsMode;
  const uint8_t targetBrightness = currentBrightness();
  uint32_t startedMs = millis();
  while (millis() - startedMs < kSettingsFadeOutMs) {
    const float phase = clampf((millis() - startedMs) / static_cast<float>(kSettingsFadeOutMs), 0.0f, 1.0f);
    const float brightness = 1.0f - smoothStep(0.0f, 1.0f, phase);
    panel->setBrightness(static_cast<uint8_t>(targetBrightness * brightness));
    audioTick();
    delay(18);
  }

  panel->setBrightness(0);
  settingsMode = nextSettingsMode;
  if (settingsMode) {
    easterMode = false;
  }
  settingsFlashUntilMs = millis() + 620;
  resetEdgeGesture();
  touchWasPressed = false;
  touchPressedAtMs = 0;
  touchLongHandled = false;
  edgeGestureConsumed = false;
  mainFadeStartedMs = 0;
  drawCurrentModeFrame();

  startedMs = millis();
  while (millis() - startedMs < kSettingsFadeInMs) {
    const float phase = clampf((millis() - startedMs) / static_cast<float>(kSettingsFadeInMs), 0.0f, 1.0f);
    const float brightness = smoothStep(0.0f, 1.0f, phase);
    panel->setBrightness(static_cast<uint8_t>(targetBrightness * brightness));
    audioTick();
    delay(18);
  }

  panel->setBrightness(currentBrightness());
  startTone(settingsMode ? 920.0f : 520.0f, 70, 2800, true);
}

void handleSettingsTap(int16_t x, int16_t y) {
  (void)x;
  settingsFlashUntilMs = millis() + 620;
  if (y < kCy) {
    cycleBrightness();
  } else {
    cycleAudioGain();
  }
}

void setEasterMode(bool nextEasterMode) {
  if (easterMode == nextEasterMode && !settingsMode) {
    return;
  }

  const uint8_t targetBrightness = currentBrightness();
  uint32_t startedMs = millis();
  while (millis() - startedMs < kSettingsFadeOutMs) {
    const float phase = clampf((millis() - startedMs) / static_cast<float>(kSettingsFadeOutMs), 0.0f, 1.0f);
    const float brightness = 1.0f - smoothStep(0.0f, 1.0f, phase);
    panel->setBrightness(static_cast<uint8_t>(targetBrightness * brightness));
    audioTick();
    delay(18);
  }

  panel->setBrightness(0);
  settingsMode = false;
  easterMode = nextEasterMode;
  retiredTargetOverlayMode = false;
  displaySelfTestUntilMs = 0;
  resetEdgeGesture();
  touchWasPressed = false;
  touchPressedAtMs = 0;
  touchLongHandled = false;
  edgeGestureConsumed = false;
  mainFadeStartedMs = 0;
  drawCurrentModeFrame();

  startedMs = millis();
  while (millis() - startedMs < kSettingsFadeInMs) {
    const float phase = clampf((millis() - startedMs) / static_cast<float>(kSettingsFadeInMs), 0.0f, 1.0f);
    const float brightness = smoothStep(0.0f, 1.0f, phase);
    panel->setBrightness(static_cast<uint8_t>(targetBrightness * brightness));
    audioTick();
    delay(18);
  }

  panel->setBrightness(currentBrightness());
  startTone(440.0f, 80, 2600, true);
}

void showEasterEgg() {
  setEasterMode(true);
  const uint32_t startedMs = millis();
  while (millis() - startedMs < kEasterDisplayMs) {
    audioTick();
    delay(18);
  }
  setEasterMode(false);
}

void handleBootShortPress() {
  if (settingsMode) {
    toggleSettingsMode();
    return;
  }
  if (!focusNextMember()) {
    cycleMapScale();
  }
}

void replayBootAnimation() {
  settingsMode = false;
  easterMode = false;
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

uint16_t beachPaletteColor(uint8_t index) {
  return pgm_read_word(&BeachSceneAssets::kPalette[index]);
}

void initBeachScene() {
  beachWalkers[0] = {&BeachSceneAssets::kPixelBoy, 116, 338, 1, 24, 0, 0};
  beachWalkers[1] = {&BeachSceneAssets::kPixelGirl, 286, 350, -1, 18, 0, 1};
  const uint32_t now = millis();
  beachWalkers[0].nextTurnMs = now + 2100;
  beachWalkers[1].nextTurnMs = now + 2800;
  beachSceneReady = true;
  lastBeachUpdateMs = now;
}

void handleBeachSwipe(int8_t direction) {
  const uint32_t now = millis();
  beachControlDir = direction;
  beachControlUntilMs = now + 4600;
  for (auto &walker : beachWalkers) {
    walker.dir = direction;
    walker.speed = 26;
    walker.nextTurnMs = beachControlUntilMs + random(900, 2600);
  }
  startTone(direction > 0 ? 980.0f : 740.0f, 60, 5200, true);
  if (kSerialDiagnostics) {
    Serial.print("DIAG beach swipe direction=");
    Serial.println(direction > 0 ? "right" : "left");
  }
}

bool handleBeachSwipeGesture(int16_t startX, int16_t startY, int16_t endX, int16_t endY) {
  if (!kBeachSceneMode) {
    return false;
  }
  const int16_t dx = endX - startX;
  const int16_t dy = endY - startY;
  if (abs(dx) < 42 || abs(dx) < abs(dy) + 18) {
    return false;
  }
  handleBeachSwipe(dx > 0 ? 1 : -1);
  return true;
}

void updateBeachScene(uint32_t now) {
  if (!beachSceneReady) {
    initBeachScene();
  }
  const uint32_t rawElapsed = lastBeachUpdateMs == 0 ? 0 : now - lastBeachUpdateMs;
  const uint32_t elapsed = rawElapsed > 120 ? 120 : rawElapsed;
  lastBeachUpdateMs = now;

  constexpr int16_t kSafeMinX = 92;
  constexpr int16_t kSafeMaxX = kScreenW - BeachSceneAssets::kSpriteW - 86;
  constexpr int16_t kMinGap = 108;

  if (now <= beachControlUntilMs) {
    const int16_t dx = static_cast<int16_t>((static_cast<int32_t>(beachControlDir) * 26 * elapsed) / 1000);
    for (auto &walker : beachWalkers) {
      walker.dir = beachControlDir;
      walker.x += dx;
    }

    BeachWalker *left = &beachWalkers[0];
    BeachWalker *right = &beachWalkers[1];
    if (left->x > right->x) {
      BeachWalker *tmp = left;
      left = right;
      right = tmp;
    }
    if (right->x - left->x < kMinGap) {
      right->x = left->x + kMinGap;
    }
    int16_t shift = 0;
    if (left->x < kSafeMinX) {
      shift = kSafeMinX - left->x;
    } else if (right->x > kSafeMaxX) {
      shift = kSafeMaxX - right->x;
    }
    if (shift != 0) {
      beachWalkers[0].x += shift;
      beachWalkers[1].x += shift;
    }
    return;
  }

  for (auto &walker : beachWalkers) {
    if (now > beachControlUntilMs && now >= walker.nextTurnMs) {
      walker.dir = random(0, 2) == 0 ? -1 : 1;
      walker.speed = random(14, 29);
      walker.nextTurnMs = now + random(1200, 3600);
    }
    walker.x += static_cast<int16_t>((static_cast<int32_t>(walker.dir) * walker.speed * elapsed) / 1000);
    if (walker.x <= kSafeMinX) {
      walker.x = kSafeMinX;
      walker.dir = 1;
      walker.nextTurnMs = now + random(1100, 2600);
    } else if (walker.x >= kSafeMaxX) {
      walker.x = kSafeMaxX;
      walker.dir = -1;
      walker.nextTurnMs = now + random(1100, 2600);
    }
  }

  BeachWalker *left = &beachWalkers[0];
  BeachWalker *right = &beachWalkers[1];
  if (left->x > right->x) {
    BeachWalker *tmp = left;
    left = right;
    right = tmp;
  }
  if (right->x - left->x < kMinGap) {
    int16_t lx = static_cast<int16_t>(
        constrain((left->x + right->x - kMinGap) / 2, kSafeMinX, kSafeMaxX - kMinGap));
    left->x = lx;
    right->x = lx + kMinGap;
    left->dir = -1;
    right->dir = 1;
    left->nextTurnMs = now + random(900, 2200);
    right->nextTurnMs = now + random(900, 2200);
  }
}

void drawBeachBand(int y0, int y1, uint16_t color) {
  y0 = constrain(y0, 0, kScreenH - 1);
  y1 = constrain(y1, 0, kScreenH - 1);
  for (int y = y0; y <= y1; ++y) {
    const int half = circleChordHalf(y - kCy, kRadarRadius + 5);
    if (half > 0) {
      gfx->drawFastHLine(kCx - half, y, half * 2, color);
    }
  }
}

void drawBeachPixelRect(int x, int y, int w, int h, uint16_t color) {
  for (int yy = y; yy < y + h; ++yy) {
    if (yy < 0 || yy >= kScreenH) {
      continue;
    }
    const int half = circleChordHalf(yy - kCy, kRadarRadius + 5);
    if (half <= 0) {
      continue;
    }
    const int left = max(x, kCx - half);
    const int right = min(x + w, kCx + half);
    if (right > left) {
      gfx->drawFastHLine(left, yy, right - left, color);
    }
  }
}

void drawPixelBeachBackground(uint32_t now) {
  gfx->fillScreen(kBlack);
  const uint16_t sky = RGB565(84, 196, 226);
  const uint16_t skyHi = RGB565(128, 220, 238);
  const uint16_t sea = RGB565(40, 146, 204);
  const uint16_t seaDeep = RGB565(22, 100, 176);
  const uint16_t foam = RGB565(230, 250, 240);
  const uint16_t sand = RGB565(232, 196, 120);
  const uint16_t sandDark = RGB565(198, 156, 84);
  const uint16_t sandLight = RGB565(248, 218, 146);
  const uint16_t shell = RGB565(246, 118, 82);
  const uint16_t trunk = RGB565(146, 92, 48);
  const uint16_t trunkHi = RGB565(188, 124, 64);
  const uint16_t leaf = RGB565(28, 154, 74);
  const uint16_t leafDark = RGB565(18, 104, 58);
  const uint16_t umbrellaRed = RGB565(230, 72, 66);
  const uint16_t umbrellaCream = RGB565(255, 238, 176);
  const uint16_t towel = RGB565(62, 116, 216);
  const uint16_t rock = RGB565(118, 112, 106);

  drawBeachBand(18, 150, sky);
  drawBeachBand(151, 205, sea);
  drawBeachBand(206, 236, seaDeep);
  drawBeachBand(237, 447, sand);

  const int wave = (now / 180) % 24;
  for (int x = 30 - wave; x < kScreenW; x += 48) {
    drawBeachPixelRect(x, 202, 30, 4, foam);
    drawBeachPixelRect(x + 12, 222, 38, 4, RGB565(116, 205, 222));
  }
  for (int x = 18 + (now / 260) % 32; x < kScreenW; x += 64) {
    drawBeachPixelRect(x, 296 + (x % 3) * 18, 11, 4, sandDark);
    drawBeachPixelRect(x + 26, 374 - (x % 5) * 9, 7, 5, shell);
  }

  drawBeachPixelRect(36, 260, 20, 112, trunk);
  drawBeachPixelRect(46, 264, 8, 104, trunkHi);
  for (int i = 0; i < 5; ++i) {
    drawBeachPixelRect(28 + i * 5, 270 + i * 18, 18, 5, sandDark);
  }
  drawBeachPixelRect(22, 244, 82, 14, leafDark);
  drawBeachPixelRect(56, 224, 16, 58, leaf);
  drawBeachPixelRect(50, 236, 64, 13, leaf);
  drawBeachPixelRect(12, 236, 58, 13, leaf);
  drawBeachPixelRect(28, 218, 58, 11, leaf);
  drawBeachPixelRect(74, 250, 48, 11, leafDark);
  drawBeachPixelRect(16, 252, 46, 10, leafDark);
  drawBeachPixelRect(58, 254, 8, 8, RGB565(112, 68, 32));
  drawBeachPixelRect(68, 258, 7, 7, RGB565(112, 68, 32));

  drawBeachPixelRect(332, 286, 8, 82, RGB565(104, 76, 46));
  drawBeachPixelRect(286, 278, 100, 12, umbrellaRed);
  drawBeachPixelRect(298, 266, 76, 12, umbrellaCream);
  drawBeachPixelRect(314, 254, 44, 12, umbrellaRed);
  drawBeachPixelRect(324, 242, 22, 12, umbrellaCream);
  drawBeachPixelRect(286, 290, 20, 8, umbrellaCream);
  drawBeachPixelRect(366, 290, 20, 8, umbrellaCream);

  drawBeachPixelRect(286, 374, 72, 28, towel);
  drawBeachPixelRect(294, 382, 56, 4, RGB565(112, 184, 246));
  drawBeachPixelRect(294, 394, 56, 4, RGB565(112, 184, 246));
  drawBeachPixelRect(370, 380, 22, 12, rock);
  drawBeachPixelRect(384, 372, 14, 9, RGB565(154, 148, 138));
  drawBeachPixelRect(142, 402, 18, 8, rock);
  drawBeachPixelRect(158, 396, 11, 8, RGB565(154, 148, 138));
  drawBeachPixelRect(196, 274, 48, 4, sandLight);
  drawBeachPixelRect(224, 318, 34, 4, sandLight);
  drawBeachPixelRect(94, 410, 32, 4, sandLight);

  drawBeachPixelRect(76, 64, 36, 8, RGB565(255, 226, 92));
  drawBeachPixelRect(84, 52, 20, 32, RGB565(255, 216, 70));
  drawBeachPixelRect(68, 72, 52, 8, RGB565(255, 236, 118));
  drawBeachPixelRect(54, 136, 70, 5, skyHi);
  drawBeachPixelRect(70, 126, 34, 5, skyHi);
  drawBeachPixelRect(298, 112, 86, 5, skyHi);
  drawBeachPixelRect(322, 102, 44, 5, skyHi);
}

void drawBeachSprite(const BeachSceneAssets::SpriteFrames &frames, int16_t x, int16_t y,
                     bool mirrorX, uint8_t frameIndex) {
  const uint8_t *data = frameIndex == 0 ? frames.frame0 : frames.frame1;
  for (uint8_t row = 0; row < BeachSceneAssets::kSpriteH; ++row) {
    const int yy = y + row;
    if (yy < 0 || yy >= kScreenH) {
      continue;
    }
    for (uint8_t col = 0; col < BeachSceneAssets::kSpriteW; ++col) {
      const uint8_t srcCol = mirrorX ? BeachSceneAssets::kSpriteW - 1 - col : col;
      const uint8_t index = pgm_read_byte(&data[row * BeachSceneAssets::kSpriteW + srcCol]);
      if (index == 0) {
        continue;
      }
      const int xx = x + col;
      if (xx >= 0 && xx < kScreenW) {
        gfx->drawPixel(xx, yy, beachPaletteColor(index));
      }
    }
  }
}

void drawBeachScene() {
  const uint32_t now = millis();
  updateBeachScene(now);
  drawPixelBeachBackground(now);

  const uint8_t boyFrame = ((now / 260) + beachWalkers[0].gaitOffset) & 1;
  const uint8_t girlFrame = ((now / 300) + beachWalkers[1].gaitOffset) & 1;
  BeachWalker *first = &beachWalkers[0];
  BeachWalker *second = &beachWalkers[1];
  if (first->y > second->y) {
    BeachWalker *tmp = first;
    first = second;
    second = tmp;
  }
  drawBeachSprite(*first->frames, first->x, first->y,
                  first->dir < 0, first == &beachWalkers[0] ? boyFrame : girlFrame);
  drawBeachSprite(*second->frames, second->x, second->y,
                  second->dir < 0, second == &beachWalkers[0] ? boyFrame : girlFrame);
  if (now < beachControlUntilMs) {
    const uint16_t c = RGB565(255, 238, 156);
    const int y = 424;
    const int x = beachWalkers[0].dir > 0 ? kCx + 20 : kCx - 50;
    drawBeachPixelRect(x, y, 30, 5, c);
    drawBeachPixelRect(x + (beachWalkers[0].dir > 0 ? 22 : 0), y - 7, 8, 19, c);
  }
  gfx->flush();
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

void drawCapsuleShape(int cx, int cy, int w, int h, uint16_t fill, uint16_t outline) {
  const int r = h / 2;
  gfx->fillRect(cx - w / 2 + r, cy - h / 2, w - h, h, fill);
  gfx->fillCircle(cx - w / 2 + r, cy, r, fill);
  gfx->fillCircle(cx + w / 2 - r, cy, r, fill);
  for (int i = 0; i < 3; ++i) {
    gfx->drawCircle(cx - w / 2 + r, cy, r - i, outline);
    gfx->drawCircle(cx + w / 2 - r, cy, r - i, outline);
    gfx->drawFastHLine(cx - w / 2 + r, cy - r + i, w - h, outline);
    gfx->drawFastHLine(cx - w / 2 + r, cy + r - i, w - h, outline);
  }
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
  const int logoY = kCy;
  const uint16_t logoBlue = RGB565(0, 86, 220);
  const uint16_t deepBlue = RGB565(0, 32, 126);
  const uint16_t glowColor = RGB565(78, 166, 255);
  const uint16_t frameDeep = RGB565(0, 42, 76);
  const uint16_t frameDim = RGB565(0, 64, 104);
  const int pulse = 6 + static_cast<int>(sinf(phase * kPi) * 12.0f);
  const float frame = smoothStep(0.0f, 0.26f, phase);
  const float body = smoothStep(0.16f, 0.54f, phase);
  const float mark = smoothStep(0.42f, 0.70f, phase);
  const float word = smoothStep(0.58f, 0.92f, phase);

  if (frame > 0.0f) {
    const int frameHalfW = static_cast<int>((117 + pulse / 2) * frame);
    const int frameHalfH = 53 + pulse / 3;
    gfx->drawRect(kCx - frameHalfW, logoY - frameHalfH, frameHalfW * 2, 106 + pulse / 2, frameDeep);
    gfx->drawFastHLine(kCx - static_cast<int>(128 * frame), logoY,
                       static_cast<int>(256 * frame), glowColor);
    if (frame > 0.55f) {
      gfx->drawFastVLine(kCx, logoY - static_cast<int>(62 * frame),
                         static_cast<int>(124 * frame), deepBlue);
      gfx->drawFastHLine(kCx - static_cast<int>(116 * frame), logoY - 50,
                         static_cast<int>(232 * frame), deepBlue);
      gfx->drawFastHLine(kCx - static_cast<int>(116 * frame), logoY + 50,
                         static_cast<int>(232 * frame), deepBlue);
    }
  }

  if (body > 0.0f) {
    const int capsuleW = 72 + static_cast<int>(118.0f * body);
    const int capsuleH = 40 + static_cast<int>(34.0f * body);
    drawCapsuleShape(kCx, logoY, capsuleW, capsuleH, body > 0.55f ? kWhite : RGB565(154, 214, 255), logoBlue);
    const int scanX = kCx - capsuleW / 2 + static_cast<int>(capsuleW * body);
    gfx->drawFastVLine(scanX, logoY - capsuleH / 2 - 8, capsuleH + 16, glowColor);
  }

  if (mark > 0.0f) {
    const int r = 10 + static_cast<int>(18.0f * mark);
    gfx->fillCircle(kCx - 58, logoY, r, logoBlue);
    gfx->drawCircle(kCx - 58, logoY, r + 1, deepBlue);
    if (mark > 0.62f) {
      gfx->setTextColor(kWhite);
      gfx->setTextSize(4);
      gfx->setCursor(kCx - 71, logoY - 17);
      gfx->print("C");
    }
  }

  if (word > 0.0f) {
    const int lineW = static_cast<int>(116.0f * word);
    gfx->drawLine(kCx - 38, logoY - 23, kCx - 38 + lineW, logoY - 23, word > 0.5f ? logoBlue : frameDim);
    gfx->drawLine(kCx - 38, logoY + 23, kCx - 38 + lineW, logoY + 23, word > 0.5f ? logoBlue : frameDim);
    if (word > 0.58f) {
      gfx->setTextColor(logoBlue);
      gfx->setTextSize(2);
      gfx->setCursor(kCx - 24, logoY - 15);
      gfx->print("CAPSULE");
    }
    if (word > 0.78f) {
      gfx->setCursor(kCx + 7, logoY + 6);
      gfx->print("CORP.");
    }
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

void drawEasterBadgeFrame() {
  drawRoundBadgeFrame(kEasterBadge565, kEasterBadgeW, kEasterBadgeMaskR);
  gfx->flush();
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

  if ((keyStatus & kAxpPowerKeyShortPressBit) != 0) {
    toggleSettingsMode();
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
  (void)frequency;
  (void)durationMs;
  (void)level;
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

void initTargets() {
  for (int i = 0; i < 7; ++i) {
    targets[i].star = i + 1;
    targets[i].seen = false;
    targets[i].demo = true;
    targets[i].collected = false;
    targets[i].rssi = -99;
    targets[i].filteredRssi = -99;
    targets[i].bestRssi = -127;
    targets[i].lastSeenMs = 0;
    targets[i].revealedAtMs = 0;
    targets[i].closeSinceMs = 0;
    targets[i].collectedAtMs = 0;
    targets[i].worldAngleDeg = wrap360(28.0f + i * 51.3f);
    targets[i].rangeNorm = 0.38f + (i % 4) * 0.13f;
    resetBearingScores(targets[i]);
    resetTargetTrail(targets[i]);
  }
}

float rssiToRangeNorm(int rssi) {
  const float raw = (abs(rssi) - 35.0f) / 55.0f;
  return clampf(raw, 0.13f, 0.96f);
}

int smoothRssi(int previous, int sample, bool reset) {
  if (reset || previous <= -98) {
    return sample;
  }
  const int weighted = previous * 3 + sample;
  return weighted / 4;
}

void setupBle() {
  if (kRemoteBleEnabled && provisioning.deviceName[0] == '\0') {
    buildProvisioningIdentity();
  }
  const char *bleName = kRemoteBleEnabled && provisioning.deviceName[0] != '\0'
                            ? provisioning.deviceName
                            : "CapsuleRadar";
  BLEDevice::init(bleName);
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

void setupImu() {
  imuOnline = qmi.begin(Wire, QMI8658_L_SLAVE_ADDRESS, -1, -1);
  if (!imuOnline) {
    Serial.println("QMI8658 offline; heading will use visual sweep only.");
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
  lastImuMicros = micros();
}

void readImu() {
  if (!imuOnline || !qmi.getDataReady()) {
    return;
  }

  const uint32_t now = micros();
  lastImuMicros = now;

  (void)qmi.getGyroscope(gyr.x, gyr.y, gyr.z);
  if (qmi.getAccelerometer(acc.x, acc.y, acc.z)) {
    tiltVectorX = lerpf(tiltVectorX, acc.x, 0.12f);
    tiltVectorY = lerpf(tiltVectorY, acc.y, 0.12f);
    const float mag = fabsf(acc.x) + fabsf(acc.y) + fabsf(acc.z - 1.0f);
    tiltEnergy = clampf(lerpf(tiltEnergy, mag, 0.12f), 0.0f, 3.0f);
  }
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
    resetEdgeGesture();
    return;
  }

  if (bootStartedMs > 0 && now - bootStartedMs < kBootDurationMs) {
    bootStartedMs = now - kBootDurationMs;
    radarStartedMs = now;
  }

  const float angle = touchAngleDeg(x, y);
  edgeGestureConsumed = true;
  touchWasPressed = false;
  touchLongHandled = false;

  if (!edgeGestureActive) {
    edgeGestureActive = true;
    edgeGestureLastAngle = angle;
    return;
  }

  const float delta = shortestAngleDelta(edgeGestureLastAngle, angle);
  edgeGestureLastAngle = angle;
  if (fabsf(delta) < 0.6f || fabsf(delta) > 55.0f) {
    return;
  }

  const float oldScale = gridGestureScale;
  gridGestureScale = clampGridGestureScale(gridGestureScale * expf(delta * 0.007f));
  if (fabsf(gridGestureScale - oldScale) > 0.01f) {
    resetAllTargetTrails();
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
    bootButtonPressedAtMs = now;
    bootButtonLongHandled = false;
    bootTapPressedMs = now;
    bootTapReleasedMs = 0;
  }

  if (pressed && !bootButtonLongHandled && bootButtonPressedAtMs > 0 &&
      now - bootButtonPressedAtMs >= kButtonLongPressMs) {
    bootButtonLongHandled = true;
    lastButtonMs = now;
    beginPushToTalk();
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
      toggleSettingsMode();
    }
    altButtonPressedAtMs = 0;
    altButtonLongHandled = false;
  }

  altButtonWasPressed = altPressed;
#endif
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
  if (count > 0) {
    if (settingsMode) {
      touchLastX = x[0];
      touchLastY = y[0];
      if (!touchWasPressed) {
        touchWasPressed = true;
        touchPressedAtMs = now;
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
  if (settingsMode) {
    if (touchWasPressed) {
      const uint32_t heldMs = touchPressedAtMs > 0 ? now - touchPressedAtMs : 0;
      if (heldMs >= kButtonDebounceMs) {
        handleSettingsTap(touchLastX, touchLastY);
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
      if (!handleBeachSwipeGesture(touchStartX, touchStartY, touchLastX, touchLastY)) {
        handleTouch(touchLastX, touchLastY);
      }
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

  selfLocationFrame.valid = (data[1] & 0x01) != 0;
  selfLocationFrame.latE7 = readLeInt32(data + 2);
  selfLocationFrame.lonE7 = readLeInt32(data + 6);
  selfLocationFrame.horizontalAccuracyCm = readLeUInt16(data + 14);
  selfLocationFrame.speedCms = readLeUInt16(data + 18);
  selfLocationFrame.courseDeg100 = readLeUInt16(data + 20);
  selfLocationFrame.unixTime = readLeUInt32(data + 24);
  selfLocationFrame.receivedMs = millis();
  provisioning.locationReceived = true;
  persistSelfLocationFrame(true);
  return true;
}

void copyLocationFrame(RemoteLocationFrame &dst, const RemoteLocationFrame &src) {
  dst.valid = src.valid;
  dst.latE7 = src.latE7;
  dst.lonE7 = src.lonE7;
  dst.horizontalAccuracyCm = src.horizontalAccuracyCm;
  dst.speedCms = src.speedCms;
  dst.courseDeg100 = src.courseDeg100;
  dst.unixTime = src.unixTime;
  dst.receivedMs = src.receivedMs;
}

bool parseRelayLocationObject(const String &json, RemoteLocationFrame &frame) {
  int32_t latE7 = 0;
  int32_t lonE7 = 0;
  int32_t hAccCm = 0;
  int32_t speedCms = 0;
  int32_t courseDeg100 = 0;
  int32_t unixTime = 0;
  if (!extractJsonIntValue(json, "lat_e7", latE7) ||
      !extractJsonIntValue(json, "lon_e7", lonE7)) {
    return false;
  }

  extractJsonIntValue(json, "h_acc_cm", hAccCm);
  extractJsonIntValue(json, "speed_cms", speedCms);
  extractJsonIntValue(json, "course_deg100", courseDeg100);
  extractJsonIntValue(json, "unix_time", unixTime);

  frame.valid = true;
  frame.latE7 = latE7;
  frame.lonE7 = lonE7;
  frame.horizontalAccuracyCm = static_cast<uint16_t>(constrain(hAccCm, 0, 65535));
  frame.speedCms = static_cast<uint16_t>(constrain(speedCms, 0, 65535));
  frame.courseDeg100 = static_cast<uint16_t>(constrain(courseDeg100, 0, 65535));
  frame.unixTime = unixTime > 0 ? static_cast<uint32_t>(unixTime) : 0;
  frame.receivedMs = millis();
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
  copyLocationFrame(remoteAppLocationFrames[slot], frame);
  remoteAppPeerIds[slot] = peerId;
  remoteAppPeerNames[slot] = name.length() > 0 ? name : peerId;

  copyLocationFrame(remoteAppLocationFrame, frame);
  remoteAppPeerName = remoteAppPeerNames[slot];
  const uint32_t now = millis();
  if (remoteAppBlinkStartedSlotsMs[slot] == 0 ||
      now - remoteAppBlinkStartedSlotsMs[slot] >= kLocationReceiveBlinkIntervalMs) {
    remoteAppBlinkStartedSlotsMs[slot] = now;
  }
  if (remoteAppBlinkStartedMs == 0 ||
      now - remoteAppBlinkStartedMs >= kLocationReceiveBlinkIntervalMs) {
    remoteAppBlinkStartedMs = now;
  }
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

bool parseRelayAppLocation(const String &json) {
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
  prefs.putString("room", provisioning.roomToken);
  prefs.putString("device", provisioning.deviceToken);
  prefs.end();
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
  selfLocationFrame.latE7 = latE7;
  selfLocationFrame.lonE7 = lonE7;
  selfLocationFrame.horizontalAccuracyCm =
      static_cast<uint16_t>(prefs.getUInt("slocAcc", 0) & 0xffff);
  selfLocationFrame.speedCms =
      static_cast<uint16_t>(prefs.getUInt("slocSpeed", 0) & 0xffff);
  selfLocationFrame.courseDeg100 =
      static_cast<uint16_t>(prefs.getUInt("slocCourse", 0) & 0xffff);
  selfLocationFrame.unixTime = prefs.getUInt("slocTime", 0);
  selfLocationFrame.receivedMs = millis();
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
  provisioning.roomToken = prefs.isKey("room") ? prefs.getString("room", "") : "";
  provisioning.deviceToken = prefs.isKey("device") ? prefs.getString("device", "") : "";
  loadPersistedSelfLocationFrame(prefs);
  prefs.end();

  provisioning.serverConfigured =
      provisioning.relayUrl.length() > 0 && provisioning.deviceToken.length() > 0;
  provisioning.wifiConnectRequested = provisioning.wifiSsid.length() > 0;
  provisioning.relayState = provisioning.serverConfigured ? "configured" : "unconfigured";
}

void buildProvisioningIdentity() {
  const uint64_t mac = ESP.getEfuseMac();
  const uint16_t suffix = static_cast<uint16_t>(mac & 0xffff);
  snprintf(provisioning.deviceName, sizeof(provisioning.deviceName), "CapsuleRadar-%04X", suffix);
  snprintf(provisioning.challenge, sizeof(provisioning.challenge), "CR-%04X-%08lX", suffix,
           static_cast<unsigned long>(esp_random()));
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

String buildDeviceStatusJson() {
  updateBatteryStatus(false);
  String status = "{";
  status += "\"v\":1";
  status += ",\"protocol_version\":";
  status += String(DRAGON_RADAR_PROTOCOL_VERSION);
  status += ",\"min_relay_protocol_version\":";
  status += String(DRAGON_RADAR_MIN_RELAY_PROTOCOL_VERSION);
  status += ",\"name\":\"";
  status += jsonEscape(provisioning.deviceName);
  status += "\"";
  status += ",\"ble\":";
  status += provisioning.appConnected ? "1" : "0";
  status += ",\"paired\":";
  status += provisioning.paired ? "1" : "0";
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
  status += ",\"relay\":\"";
  status += jsonEscape(String(relayStatusText()));
  status += "\"";
  status += ",\"loc\":";
  status += provisioning.locationReceived ? "1" : "0";
  status += ",\"battery_percent\":";
  status += String(batteryStatus.percent);
  status += ",\"battery_voltage_mv\":";
  status += String(batteryStatus.voltageMv);
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
  status += ",\"last\":\"";
  status += jsonEscape(provisioning.lastWrite);
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
  const String status = buildDeviceStatusJson();
  deviceStatusCharacteristic->setValue(status);
  if (provisioning.appConnected) {
    deviceStatusCharacteristic->notify();
  }
}

bool hmacSha256Hex(const String &message, String &outHex) {
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  if (!info || !kPairingHmacKey || strlen(kPairingHmacKey) == 0) {
    return false;
  }

  uint8_t digest[32] = {0};
  const int rc = mbedtls_md_hmac(
      info,
      reinterpret_cast<const unsigned char *>(kPairingHmacKey),
      strlen(kPairingHmacKey),
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
  return signature.equalsIgnoreCase(expected);
}

void handlePairingResponseWrite(BLECharacteristic *characteristic) {
  const String response = characteristicValueAsString(characteristic);
  if (!verifyPairingResponse(response)) {
    provisioning.lastWrite = "pairing_response invalid";
    notifyDeviceStatus(true);
    Serial.println("BLE provisioning pairing_response invalid");
    return;
  }
  provisioning.pairingResponse = response;
  provisioning.paired = true;
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
  String roomToken;
  String deviceToken;
  extractJsonStringValue(json, "relay_url", relayUrl);
  extractJsonStringValue(json, "room_token", roomToken);
  extractJsonStringValue(json, "device_token", deviceToken);
  if (relayUrl.length() == 0 || roomToken.length() == 0 || deviceToken.length() == 0) {
    provisioning.lastWrite = String(source) + " invalid:server_config";
    notifyDeviceStatus(true);
    Serial.print(source);
    Serial.println(" server_config invalid");
    return false;
  }
  provisioning.relayUrl = relayUrl;
  provisioning.roomToken = roomToken;
  provisioning.deviceToken = deviceToken;
  provisioning.serverConfigured = relayUrl.length() > 0 && deviceToken.length() > 0;
  provisioning.relayConnected = false;
  provisioning.relaySocketConfigured = false;
  provisioning.relayState = provisioning.serverConfigured ? "configured" : "unconfigured";
  lastRelayAttemptMs = 0;
  lastRelayHeartbeatMs = 0;
  provisioning.lastWrite = String(source) + "_server_config";
  saveProvisioningState();
  notifyDeviceStatus(true);
  relaySocket.disconnect();
  Serial.print(source);
  Serial.print(" server_config relay=");
  Serial.println(provisioning.relayUrl);
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
  Serial.println(selfLocationFrame.horizontalAccuracyCm);
}

void handleGattWrite(RadarGattWriteRole role, BLECharacteristic *characteristic) {
  switch (role) {
    case RadarGattWriteRole::PairingResponse:
      handlePairingResponseWrite(characteristic);
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
  }
}

class ProvisioningServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    (void)server;
    provisioning.appConnected = true;
    notifyDeviceStatus(true);
    Serial.println("BLE provisioning app connected");
  }

  void onDisconnect(BLEServer *server) override {
    (void)server;
    provisioning.appConnected = false;
    notifyDeviceStatus(true);
    BLEDevice::startAdvertising();
    Serial.println("BLE provisioning app disconnected");
  }
};

class RadarGattWriteCallbacks : public BLECharacteristicCallbacks {
 public:
  explicit RadarGattWriteCallbacks(RadarGattWriteRole role) : role_(role) {}

  void onWrite(BLECharacteristic *characteristic) override {
    handleGattWrite(role_, characteristic);
  }

 private:
  RadarGattWriteRole role_;
};

BLECharacteristic *createProvisioningCharacteristic(
    BLEService *service,
    const char *uuid,
    uint32_t properties,
    BLECharacteristicCallbacks *callbacks = nullptr) {
  BLECharacteristic *characteristic = service->createCharacteristic(uuid, properties);
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

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kRadarBleServiceUuid);
  advertising->setScanResponse(true);
  advertising->setMinPreferred(0x06);
  advertising->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  provisioning.serviceOnline = true;
  notifyDeviceStatus(true);
  Serial.print("BLE provisioning service online name=");
  Serial.print(provisioning.deviceName);
  Serial.print(" service=");
  Serial.println(kRadarBleServiceUuid);
}

void provisioningTick() {
  if (!kRemoteBleEnabled) {
    return;
  }

  if (provisioning.serviceOnline && pairingChallengeCharacteristic && provisioning.appConnected) {
    pairingChallengeCharacteristic->setValue(provisioning.challenge);
    pairingChallengeCharacteristic->notify();
  }

  const uint32_t now = millis();
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
  path += urlEncode(provisioning.deviceToken.length() > 0 ? provisioning.deviceToken : provisioning.deviceName);
  return path;
}

String localRelayPeerId() {
  return provisioning.deviceToken.length() > 0 ? provisioning.deviceToken : String(provisioning.deviceName);
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

void playRemoteVoicePcm(const uint8_t *pcmBytes, size_t byteLen) {
  if (!audioOnline || byteLen < sizeof(int16_t)) {
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
  String deviceToken;
  extractJsonStringValue(json, "relay_url", relayUrl);
  extractJsonStringValue(json, "room_token", roomToken);
  extractJsonStringValue(json, "device_token", deviceToken);
  if (relayUrl == provisioning.relayUrl &&
      roomToken == provisioning.roomToken &&
      deviceToken == provisioning.deviceToken) {
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
  payload += "\",\"firmware\":\"dragon-radar-field\"";
  payload += ",\"protocol_version\":";
  payload += String(DRAGON_RADAR_PROTOCOL_VERSION);
  payload += ",\"min_relay_protocol_version\":";
  payload += String(DRAGON_RADAR_MIN_RELAY_PROTOCOL_VERSION);
  payload += ",\"capabilities\":[\"display\",\"ble\",\"wifi\",\"location\",\"ptt_voice\"]";
  payload += ",\"room\":\"";
  payload += jsonEscape(provisioning.roomToken);
  payload += "\"}";
  sendRelayJson(payload);
}

void sendRelayDeviceStatus() {
  String payload = "{\"type\":\"device_status\",\"device_id\":\"";
  payload += jsonEscape(localRelayPeerId());
  payload += "\",\"status\":";
  payload += buildDeviceStatusJson();
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
      Serial.print("Relay event ");
      Serial.println(text);
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
    Serial.print("Relay invalid url=");
    Serial.println(provisioning.relayUrl);
    notifyDeviceStatus(true);
    return;
  }

  String path = basePath;
  path += relaySocketPath();
  relaySocket.disconnect();
  relaySocket.onEvent(cloudRelayEvent);
  relaySocket.setReconnectInterval(kRelayReconnectMs);
  if (secure) {
    relaySocket.beginSSL(host.c_str(), port, path.c_str());
  } else {
    relaySocket.begin(host.c_str(), port, path.c_str());
  }
  provisioning.relaySocketConfigured = true;
  provisioning.relayConnected = false;
  provisioning.relayState = "connecting";
  Serial.print("Relay connect url=");
  Serial.print(secure ? "wss://" : "ws://");
  Serial.print(host);
  Serial.print(":");
  Serial.print(port);
  Serial.println(path);
  notifyDeviceStatus(true);
}

void cloudRelayTick() {
  if (!kRemoteBleEnabled || !provisioning.serverConfigured) {
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

void drawRadarGrid() {
  gfx->fillScreen(kBlack);
  gfx->fillCircle(kCx, kCy, kRadarGridRadius, kScreenBg);

  const int pitch = currentGridPitch();
  const uint16_t gridColor = RGB565(12, 157, 71);
  const uint16_t gridHalfColor = RGB565(7, 104, 50);
  const int start = -((kRadarGridRadius / pitch) * pitch);

  for (int offset = start; offset <= -start; offset += pitch) {
    const int half = circleChordHalf(offset, kRadarGridRadius);
    if (half <= 0) {
      continue;
    }
    drawGridHLineHalfOffset(kCx - half, kCy + offset, half * 2, gridColor, gridHalfColor);
    drawGridVLineHalfOffset(kCx + offset, kCy - half, half * 2, gridColor, gridHalfColor);
  }

  if (kShowDebugHud) {
    gfx->fillCircle(kCx, kCy, 5, kGridBright);
    gfx->drawFastHLine(kCx - 15, kCy, 30, kGridBright);
    gfx->drawFastVLine(kCx, kCy - 15, 30, kGridBright);

    drawCenteredText("DRAGON RADAR", 22, 2, kGridBright);
    gfx->setTextSize(1);
    gfx->setTextColor(kGridDim);
    gfx->setCursor(46, 424);
    gfx->print(demoMode ? "SIM" : "BLE");
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
  if (kShowDebugHud || kShowStarBlips || demoMode || retiredTargetOverlayMode || activeTargetCount() > 0) {
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
  if (kShowDebugHud || kShowStarBlips || tiltEnergy < 0.16f) {
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

void drawStarMark(int x, int y, int count, uint16_t color) {
  const int spacing = 4;
  const int start = x - ((count - 1) * spacing) / 2;
  for (int i = 0; i < count; ++i) {
    const int sx = start + i * spacing;
    gfx->drawFastHLine(sx - 1, y, 3, color);
    gfx->drawFastVLine(sx, y - 1, 3, color);
  }
}

void drawOrbPhosphorBloom(int x, int y, bool fresh, bool trace, uint8_t pulse) {
  const int span = fresh ? 20 + pulse * 3 : (trace ? 10 : 14);
  const uint16_t hot = trace ? RGB565(132, 112, 28) : kAmber;
  const uint16_t mid = trace ? RGB565(86, 78, 22) : kOrange;
  const uint16_t dim = trace ? RGB565(38, 48, 18) : RGB565(92, 28, 0);

  for (int row = -2; row <= 2; ++row) {
    const int shrink = abs(row) * 4;
    const int half = max(2, span - shrink);
    const uint16_t c = row == 0 ? hot : (abs(row) == 1 ? mid : dim);
    gfx->drawFastHLine(x - half, y + row * 2, half * 2 + 1, c);
  }

}

void drawOrb(int x, int y, int star, bool fresh, bool trace, uint8_t pulse) {
  if (fresh) {
    return;
  }

  const int r = 7;
  const uint16_t outer = trace ? RGB565(78, 54, 18) : RGB565(138, 42, 0);
  const uint16_t body = trace ? RGB565(132, 112, 28) : RGB565(255, 122, 22);
  gfx->fillCircle(x, y, r + 2, outer);
  gfx->fillCircle(x, y, r, body);
  gfx->fillCircle(x - 2, y - 2, 2, kAmber);
  gfx->drawPixel(x - 3, y - 3, kWhite);
  (void)star;
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

  constexpr int kOrbRadius = 7;
  constexpr int kHiddenBoxSide = kOrbRadius * 2;
  constexpr int kHiddenBoxGap = 4;
  constexpr int kCellOffset = 5;
  const int boxCx = x - kOrbRadius - kHiddenBoxGap - kHiddenBoxSide / 2;
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

void drawCaptureGlyph(int x, int y, uint32_t ageMs) {
  const float t = clampf(static_cast<float>(ageMs) / kCaptureFlashMs, 0.0f, 1.0f);
  const int dx = x - kCx;
  const int dy = y - kCy;
  const int edgeRoom = kRadarRadius - static_cast<int>(sqrtf(dx * dx + dy * dy)) - 9;
  if (edgeRoom < 7) {
    return;
  }
  const int r = min(12 + static_cast<int>(t * 22.0f), edgeRoom);
  const bool flash = ((ageMs / 84) & 1) == 0;
  const uint16_t c = flash ? kGridBright : kAmber;
  gfx->drawRect(x - r, y - r, r * 2, r * 2, c);
  gfx->drawFastHLine(x - r - 6, y, 12, c);
  gfx->drawFastHLine(x + r - 5, y, 12, c);
  gfx->drawFastVLine(x, y - r - 6, 12, c);
  gfx->drawFastVLine(x, y + r - 5, 12, c);
  gfx->drawFastHLine(x - 6, y, 13, kGrid);
  gfx->drawFastVLine(x, y - 6, 13, kGrid);
}

void drawAcquisitionEcho(int x, int y, uint32_t ageMs) {
  const float t = clampf(static_cast<float>(ageMs) / kAcquisitionEchoMs, 0.0f, 1.0f);
  const int dx = x - kCx;
  const int dy = y - kCy;
  const int edgeRoom = kRadarRadius - static_cast<int>(sqrtf(dx * dx + dy * dy)) - 12;
  if (edgeRoom < 10) {
    return;
  }

  const int step = max(8, currentGridPitch() / 2);
  const int spread = min(edgeRoom, 8 + static_cast<int>(t * (step + 20.0f)));
  const int rail = min(edgeRoom, spread + step);
  const int corner = min(10, spread);
  const bool flash = ((ageMs / 68) & 1) == 0;
  const uint16_t primary = flash ? kGridBright : kGrid;
  const uint16_t secondary = flash ? kGrid : kGridDim;

  gfx->drawRect(x - spread, y - spread, spread * 2, spread * 2, secondary);
  gfx->drawFastHLine(x - spread, y - spread, corner, primary);
  gfx->drawFastVLine(x - spread, y - spread, corner, primary);
  gfx->drawFastHLine(x + spread - corner, y - spread, corner, primary);
  gfx->drawFastVLine(x + spread, y - spread, corner, primary);
  gfx->drawFastHLine(x - spread, y + spread, corner, primary);
  gfx->drawFastVLine(x - spread, y + spread - corner, corner, primary);
  gfx->drawFastHLine(x + spread - corner, y + spread, corner, primary);
  gfx->drawFastVLine(x + spread, y + spread - corner, corner, primary);

  const int gap = max(5, spread - 2);
  if (rail > gap) {
    gfx->drawFastHLine(x - rail, y, rail - gap, secondary);
    gfx->drawFastHLine(x + gap, y, rail - gap, secondary);
    gfx->drawFastVLine(x, y - rail, rail - gap, secondary);
    gfx->drawFastVLine(x, y + gap, rail - gap, secondary);
  }
}

void pushTargetTrail(RetiredTarget &target, int x, int y, uint32_t now) {
  for (int i = kTargetTrailCount - 1; i > 0; --i) {
    target.trailX[i] = target.trailX[i - 1];
    target.trailY[i] = target.trailY[i - 1];
    target.trailMs[i] = target.trailMs[i - 1];
  }
  target.trailX[0] = static_cast<int16_t>(x);
  target.trailY[0] = static_cast<int16_t>(y);
  target.trailMs[0] = now;
}

void updateTargetTrail(RetiredTarget &target, int x, int y, uint32_t now) {
  if (kShowDebugHud || kShowStarBlips) {
    return;
  }

  if (target.lastTrailMs == 0) {
    target.lastScreenX = static_cast<int16_t>(x);
    target.lastScreenY = static_cast<int16_t>(y);
    target.lastTrailMs = now;
    return;
  }

  const int dx = x - target.lastScreenX;
  const int dy = y - target.lastScreenY;
  if (dx * dx + dy * dy < kTargetTrailMovePx * kTargetTrailMovePx) {
    return;
  }

  pushTargetTrail(target, target.lastScreenX, target.lastScreenY, now);
  target.lastScreenX = static_cast<int16_t>(x);
  target.lastScreenY = static_cast<int16_t>(y);
  target.lastTrailMs = now;
}

void drawTargetTrail(const RetiredTarget &target, uint32_t now) {
  if (kShowDebugHud || kShowStarBlips) {
    return;
  }

  for (uint8_t i = 0; i < kTargetTrailCount; ++i) {
    if (target.trailMs[i] == 0) {
      continue;
    }
    const uint32_t age = now - target.trailMs[i];
    if (age > kTargetTrailFadeMs) {
      continue;
    }

    const int x = target.trailX[i];
    const int y = target.trailY[i];
    const int half = max(3, 11 - static_cast<int>(i) * 3 - static_cast<int>(age / 280));
    const uint16_t c = i == 0 ? RGB565(132, 86, 18) :
                       (i == 1 ? RGB565(82, 62, 18) : RGB565(36, 44, 18));
    gfx->drawFastHLine(x - half, y, half * 2 + 1, c);
    if (half > 4) {
      gfx->drawFastHLine(x - half + 2, y + 2, half * 2 - 3, RGB565(26, 46, 18));
      gfx->drawFastHLine(x - half + 2, y - 2, half * 2 - 3, RGB565(26, 46, 18));
    }
  }
}

void drawRectProgressFrame(int left, int top, int side, int filled, uint16_t color) {
  int remaining = constrain(filled, 0, side * 4);
  int segment = min(remaining, side);
  if (segment > 0) {
    gfx->drawFastHLine(left, top, segment, color);
  }
  remaining -= segment;

  segment = min(remaining, side);
  if (segment > 0) {
    gfx->drawFastVLine(left + side, top, segment, color);
  }
  remaining -= segment;

  segment = min(remaining, side);
  if (segment > 0) {
    gfx->drawFastHLine(left + side - segment, top + side, segment, color);
  }
  remaining -= segment;

  segment = min(remaining, side);
  if (segment > 0) {
    gfx->drawFastVLine(left, top + side - segment, segment, color);
  }
}

void drawProximityLock(int x, int y, uint32_t heldMs) {
  const int dx = x - kCx;
  const int dy = y - kCy;
  const int edgeRoom = kRadarRadius - static_cast<int>(sqrtf(dx * dx + dy * dy)) - 13;
  if (edgeRoom < 12) {
    return;
  }

  const uint32_t held = min(heldMs, kRetiredTargetHoldMs);
  const bool flash = ((millis() / 86) & 1) == 0;
  const uint16_t c = flash ? kGridBright : kGrid;
  const int r = min(16, edgeRoom);
  const int frame = min(r + 4, edgeRoom);
  const int side = frame * 2;
  const int progress = static_cast<int>((held * side * 4UL) / kRetiredTargetHoldMs);
  const int corner = 8;

  gfx->drawFastHLine(x - r, y - r, corner, c);
  gfx->drawFastVLine(x - r, y - r, corner, c);
  gfx->drawFastHLine(x + r - corner, y - r, corner, c);
  gfx->drawFastVLine(x + r, y - r, corner, c);
  gfx->drawFastHLine(x - r, y + r, corner, c);
  gfx->drawFastVLine(x - r, y + r - corner, corner, c);
  gfx->drawFastHLine(x + r - corner, y + r, corner, c);
  gfx->drawFastVLine(x + r, y + r - corner, corner, c);

  gfx->drawRect(x - frame, y - frame, side + 1, side + 1, kGridDeep);
  drawRectProgressFrame(x - frame, y - frame, side, progress, flash ? kAmber : kOrange);
}

void drawProximityEdgePulse(int x, int y, float nearness, uint32_t now) {
  if (kShowDebugHud || kShowStarBlips || nearness < 0.18f) {
    return;
  }

  const float gated = clampf((nearness - 0.18f) / 0.82f, 0.0f, 1.0f);
  const uint8_t lit = 1 + static_cast<uint8_t>(gated * (kProximityEdgeTickCount - 1));
  const int period = 210 - static_cast<int>(gated * 96.0f);
  const bool flash = ((now / max(90, period)) & 1) == 0;
  const uint16_t active = flash ? kGridBright : (nearness > 0.74f ? kAmber : kGrid);
  const uint16_t dim = flash ? kGridDim : kGridDeep;
  const int dx = x - kCx;
  const int dy = y - kCy;

  if (abs(dx) >= abs(dy)) {
    const bool right = dx >= 0;
    const int anchorX = right ? kCx + kRadarRadius - 18 : kCx - kRadarRadius + 10;
    const int anchorY = constrain(y, kCy - kRadarRadius + 44, kCy + kRadarRadius - 44);
    const int railX = right ? anchorX - 4 : anchorX + 4;
    gfx->drawFastVLine(railX, anchorY - 28, 56, dim);
    gfx->drawFastHLine(right ? anchorX - 32 : anchorX + 12, anchorY, 20, active);
    for (uint8_t i = 0; i < kProximityEdgeTickCount; ++i) {
      const int yy = anchorY + (static_cast<int>(i) - 2) * 10;
      const bool on = i < lit;
      const int w = 10 + i * 2;
      const int x0 = right ? anchorX - w : anchorX;
      const uint16_t c = on ? active : dim;
      gfx->drawRect(x0, yy, w, 4, c);
      if (on && flash && w > 4) {
        gfx->fillRect(x0 + 2, yy + 1, w - 3, 2, c);
      }
    }
  } else {
    const bool top = dy < 0;
    const int anchorY = top ? kCy - kRadarRadius + 10 : kCy + kRadarRadius - 18;
    const int anchorX = constrain(x, kCx - kRadarRadius + 44, kCx + kRadarRadius - 44);
    const int railY = top ? anchorY + 4 : anchorY - 4;
    gfx->drawFastHLine(anchorX - 28, railY, 56, dim);
    gfx->drawFastVLine(anchorX, top ? anchorY + 12 : anchorY - 32, 20, active);
    for (uint8_t i = 0; i < kProximityEdgeTickCount; ++i) {
      const int xx = anchorX + (static_cast<int>(i) - 2) * 10;
      const bool on = i < lit;
      const int h = 10 + i * 2;
      const int y0 = top ? anchorY : anchorY - h;
      const uint16_t c = on ? active : dim;
      gfx->drawRect(xx, y0, 4, h, c);
      if (on && flash && h > 4) {
        gfx->fillRect(xx + 1, y0 + 2, 2, h - 3, c);
      }
    }
  }
}

void drawCollectionStrip() {
  const int startX = kCx - 78;
  for (int i = 0; i < 7; ++i) {
    const int x = startX + i * 26;
    const bool collected = targets[i].collected;
    if (collected) {
      gfx->fillCircle(x, 82, 8, kOrange);
      gfx->fillCircle(x - 2, 80, 3, kAmber);
      drawStarMark(x, 83, i + 1, kRed);
    } else {
      gfx->drawCircle(x, 82, 7, kGridDim);
      gfx->drawFastHLine(x - 3, 82, 7, kGridDeep);
    }
  }
}

void drawRssiCalibrationStrip() {
  const int idx = strongestActiveTargetIndex();
  if (idx < 0) {
    gfx->drawRect(kCx - 70, 408, 140, 8, kGridDim);
    gfx->setTextSize(1);
    gfx->setTextColor(kGridDim);
    gfx->setCursor(kCx - 36, 422);
    gfx->print("NO ROOM");
    return;
  }

  RetiredTarget &target = targets[idx];
  const int x = kCx - 118;
  const int y = 408;
  const int w = 236;
  const int h = 8;
  const int filteredW = rssiToBarWidth(target.filteredRssi, w - 2);
  const int rawX = x + 1 + rssiToBarWidth(target.rssi, w - 2);
  const int collectX = x + 1 + rssiToBarWidth(kRetiredTargetCloseRssi, w - 2);
  const bool close = target.rssi >= kRetiredTargetCloseRssi;

  gfx->drawRect(x, y, w, h, kGridDim);
  gfx->fillRect(x + 1, y + 2, filteredW, h - 4, close ? kOrange : kGrid);
  gfx->drawFastVLine(collectX, y - 3, h + 6, kAmber);
  gfx->drawFastVLine(rawX, y - 1, h + 2, kWhite);

  if (target.closeSinceMs > 0 && !target.collected) {
    const uint32_t held = min(millis() - target.closeSinceMs, kRetiredTargetHoldMs);
    const int holdW = (held * (w - 2)) / kRetiredTargetHoldMs;
    gfx->drawFastHLine(x + 1, y + h + 3, holdW, kAmber);
  }

  char buf[36];
  snprintf(buf, sizeof(buf), "S%d R%d F%d", idx + 1, target.rssi, target.filteredRssi);
  gfx->setTextSize(1);
  gfx->setTextColor(close ? kAmber : kGrid);
  gfx->setCursor(kCx - 54, 422);
  gfx->print(buf);
}

void drawBearingCalibrationStrip() {
  const int idx = strongestActiveTargetIndex();
  const uint8_t headingBin = headingToBearingBin(headingDeg);
  const int startX = kCx - 108;
  const int baseY = 112;
  const int step = 14;
  const int barW = 8;

  for (uint8_t i = 0; i < kBearingBinCount; ++i) {
    const int x = startX + i * step;
    const uint8_t score = idx >= 0 ? targets[idx].bearingScores[i] : 0;
    const bool best = idx >= 0 && i == targets[idx].bestBearingBin && score > 0;
    const bool heading = i == headingBin;
    const int h = 2 + (score * 22) / 255;
    const uint16_t frame = heading ? kWhite : kGridDeep;
    const uint16_t fill = best ? kAmber : (score > 0 ? (heading ? kGridBright : kGrid) : kGridDim);

    gfx->drawRect(x, baseY - 25, barW, 25, frame);
    if (score > 0) {
      gfx->fillRect(x + 2, baseY - h, barW - 3, h, fill);
    } else if (heading) {
      gfx->drawFastVLine(x + barW / 2, baseY - 23, 21, kGridDim);
    }
  }
}

void retiredTargetStartPoint(const RetiredTarget &target, uint8_t index, int &x, int &y) {
  const float screenAngle = wrap360(target.worldAngleDeg);
  float radius = target.rangeNorm * currentMapScale() * (kRadarRadius - 28);
  if (radius < 58.0f) {
    radius = 58.0f + index * 7.0f;
  }
  radius = min(radius, static_cast<float>(kRadarRadius - 34));
  polarToPoint(screenAngle, radius, x, y);
  snapPointToGrid(x, y);
}

void drawRetiredTargetOverlayGathering(uint32_t elapsed) {
  const float t = smoothStep(0.0f, 1.0f,
                             clampf(elapsed / static_cast<float>(kSummonGatherMs), 0.0f, 1.0f));
  const bool flash = ((elapsed / 92) & 1) == 0;
  const uint16_t pathColor = flash ? kGrid : kGridDim;
  const uint16_t centerColor = flash ? kGridBright : kGrid;

  gfx->drawRect(kCx - 24, kCy - 24, 48, 48, kGridDim);
  gfx->drawFastHLine(kCx - 34, kCy, 68, centerColor);
  gfx->drawFastVLine(kCx, kCy - 34, 68, centerColor);

  for (uint8_t i = 0; i < 7; ++i) {
    int sx;
    int sy;
    retiredTargetStartPoint(targets[i], i, sx, sy);

    gfx->drawFastHLine(min(sx, kCx), sy, abs(sx - kCx) + 1, pathColor);
    gfx->drawFastVLine(kCx, min(sy, kCy), abs(sy - kCy) + 1, pathColor);

    float x = sx;
    float y = sy;
    const float split = 0.56f;
    if (t < split) {
      const float p = smoothStep(0.0f, split, t);
      x = lerpf(static_cast<float>(sx), static_cast<float>(kCx), p);
    } else {
      const float p = smoothStep(split, 1.0f, t);
      x = static_cast<float>(kCx);
      y = lerpf(static_cast<float>(sy), static_cast<float>(kCy), p);
    }

    const int ix = static_cast<int>(roundf(x));
    const int iy = static_cast<int>(roundf(y));
    gfx->drawRect(ix - 9, iy - 9, 18, 18, kGridDeep);
    gfx->fillCircle(ix, iy, 6, RGB565(92, 28, 0));
    gfx->fillCircle(ix, iy, 4, kOrange);
    gfx->fillCircle(ix - 1, iy - 1, 2, kAmber);
  }
}

void drawRetiredTargetOverlayCorePulse(uint32_t elapsed) {
  const bool flash = ((elapsed / 74) & 1) == 0;
  const uint16_t core = flash ? kGridBright : kGrid;
  const uint16_t dim = flash ? kGridDim : kGridDeep;
  const int step = (elapsed / 56) % 4;

  for (int layer = 0; layer < 3; ++layer) {
    const int r = 10 + layer * 11 + step * 2;
    gfx->drawRect(kCx - r, kCy - r, r * 2, r * 2, layer == 0 ? core : dim);
  }

  gfx->drawFastHLine(kCx - 42, kCy, 84, core);
  gfx->drawFastVLine(kCx, kCy - 42, 84, core);
  gfx->drawFastHLine(kCx - 18, kCy - 18, 36, dim);
  gfx->drawFastHLine(kCx - 18, kCy + 18, 36, dim);
  gfx->drawFastVLine(kCx - 18, kCy - 18, 36, dim);
  gfx->drawFastVLine(kCx + 18, kCy - 18, 36, dim);

  const int startX = kCx - 42;
  const int tickY = kCy + 55;
  uint8_t lit = 1 + ((elapsed / 118) % kSummonCoreTickCount);
  if (lit > kSummonCoreTickCount) {
    lit = kSummonCoreTickCount;
  }
  for (uint8_t i = 0; i < kSummonCoreTickCount; ++i) {
    const int x = startX + i * 14;
    const bool on = i < lit;
    gfx->drawRect(x, tickY, 8, 4, on ? core : dim);
    if (on && flash) {
      gfx->fillRect(x + 2, tickY + 1, 4, 2, core);
    }
  }
}

void drawRetiredTargetOverlayOverlay() {
  if (!retiredTargetOverlayMode) {
    return;
  }

  const uint32_t elapsed = millis() - retiredTargetOverlayStartedMs;
  const int band = (elapsed / 48) % 64;
  for (int offset = -192 + band; offset <= 192; offset += 64) {
    if (abs(offset) <= kRadarRadius) {
      const int half = circleChordHalf(offset);
      gfx->drawFastHLine(kCx - half, kCy + offset, half * 2, kGridBright);
      gfx->drawFastVLine(kCx + offset, kCy - half, half * 2, kGridBright);
    }
  }

  const float t = elapsed / 1000.0f;
  const int halo = 18 + static_cast<int>((sinf(t * 7.0f) + 1.0f) * 7.0f);
  gfx->drawRect(kCx - 34 - halo / 2, kCy - 34 - halo / 2, 68 + halo, 68 + halo, kGridDim);
  gfx->drawFastHLine(kCx - 46, kCy, 92, kGridBright);
  gfx->drawFastVLine(kCx, kCy - 46, 92, kGridBright);
  drawRetiredTargetOverlayCorePulse(elapsed);

  if (elapsed < kSummonGatherMs) {
    drawRetiredTargetOverlayGathering(elapsed);
    drawRetiredTargetOverlayCorePulse(elapsed);
    return;
  }

  const float orbitT = (elapsed - kSummonGatherMs) / 1000.0f;
  for (int i = 0; i < 7; ++i) {
    const float a = orbitT * 1.9f + i * (2.0f * kPi / 7.0f);
    const float breathe = (sinf(orbitT * 4.4f + i) + 1.0f) * 0.5f;
    const float radius = 34.0f + breathe * 10.0f;
    const int x = kCx + static_cast<int>(cosf(a) * radius);
    const int y = kCy + static_cast<int>(sinf(a) * radius);
    gfx->fillCircle(x, y, 7, RGB565(92, 28, 0));
    gfx->fillCircle(x, y, 5, kOrange);
    gfx->fillCircle(x - 1, y - 1, 2, kAmber);
  }
}

bool targetScreenPoint(float worldAngle, float range, int &x, int &y) {
  const float screenAngle = wrap360(worldAngle);
  float radius = range * currentMapScale() * kTargetMaxRadius;
  if (radius > static_cast<float>(kTargetMaxRadius)) {
    return false;
  }
  polarToPoint(screenAngle, radius, x, y);
  return true;
}

void snapPointToGrid(int &x, int &y) {
  if (!kSnapTargetsToGrid || kShowDebugHud) {
    return;
  }

  const int step = max(8, currentGridPitch() / 2);
  const int snappedX = kCx + static_cast<int>(roundf((x - kCx) / static_cast<float>(step))) * step;
  const int snappedY = kCy + static_cast<int>(roundf((y - kCy) / static_cast<float>(step))) * step;
  const int dx = snappedX - kCx;
  const int dy = snappedY - kCy;
  constexpr int kEdgeMargin = 14;
  constexpr int kLimit = kTargetMaxRadius - kEdgeMargin;
  if (dx * dx + dy * dy <= kLimit * kLimit) {
    x = snappedX;
    y = snappedY;
  }
}

void drawFocusedMemberFrame(int x, int y, uint32_t now) {
  if (focusedTargetSlot == kFocusNone || now > focusFlashUntilMs) {
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
    if (!targetScreenPoint(angle, range, x, y)) {
      continue;
    }
    snapPointToGrid(x, y);

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
      drawMotionBadge(markers[slot].x, markers[slot].y, markers[slot].courseDeg, markers[slot].speedMps);
    }
    drawOrb(markers[slot].x, markers[slot].y, 1 + slot, markers[slot].fresh, false, markers[slot].pulse);
    if (markers[slot].speaking) {
      drawSpeakingBadge(markers[slot].x, markers[slot].y, now);
    }
    if (focusedTargetSlot == static_cast<uint8_t>(kFocusRemoteApp + slot)) {
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

void drawResetFlash() {
  const uint32_t now = millis();
  if (now > resetFlashUntilMs) {
    return;
  }

  const uint32_t remaining = resetFlashUntilMs - now;
  const float p = 1.0f - clampf(static_cast<float>(remaining) / kResetFlashMs, 0.0f, 1.0f);
  const int sx = kCx - kRadarRadius + static_cast<int>(p * kRadarRadius * 2.0f);
  const int offset = sx - kCx;
  const int half = circleChordHalf(offset);
  if (half <= 0) {
    return;
  }

  const bool flash = ((remaining / 72) & 1) == 0;
  drawThickLine(sx, kCy - half, sx, kCy + half, flash ? kGridBright : kGrid, 2);
  for (int trail = 1; trail <= 2; ++trail) {
    const int tx = sx - trail * 9;
    const int trailOffset = tx - kCx;
    const int trailHalf = circleChordHalf(trailOffset);
    if (trailHalf > 0) {
      drawThickLine(tx, kCy - trailHalf + 6, tx, kCy + trailHalf - 6,
                    trail == 1 ? kGridDim : kGridDeep, 1);
    }
  }
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
    drawResetFlash();
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
  snprintf(buf, sizeof(buf), "HDG %03d", static_cast<int>(headingDeg) % 360);
  gfx->print(buf);

  gfx->setCursor(330, 54);
  const int active = activeTargetCount();
  snprintf(buf, sizeof(buf), "ORB %d/7", active);
  gfx->print(buf);

  const int energy = static_cast<int>(clampf(tiltEnergy, 0.0f, 2.0f) * 36.0f);
  gfx->drawRect(kCx - 44, 398, 88, 8, kGridDim);
  gfx->fillRect(kCx - 42, 400, energy, 4, kGrid);
  drawRssiCalibrationStrip();
  drawBearingCalibrationStrip();
  drawResetFlash();
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

  Serial.println("DIAG commands: ? help, h hardware, d display_test, z zoom, r reset/beach_right, b brightness, a audio, f frame_rate, t frame_turbo, p ping, l beach_left, x beach_swipe_left_test, y beach_swipe_right_test");
  Serial.println("DIAG line: relay <ws_url> <room_token> <device_token>");
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
    case 'r':
      if (kBeachSceneMode) {
        handleBeachSwipe(1);
        printSerialCommandResult(command, "beach_right");
      } else {
        resetRadarDisplayState();
        printSerialCommandResult(command, "reset_display");
      }
      break;
    case 'l':
      if (kBeachSceneMode) {
        handleBeachSwipe(-1);
        printSerialCommandResult(command, "beach_left");
      } else {
        printSerialCommandResult(command, "unknown");
      }
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
    case 'x':
      if (kBeachSceneMode && handleBeachSwipeGesture(kCx + 86, kCy, kCx - 86, kCy)) {
        printSerialCommandResult(command, "beach_swipe_left_test");
      } else {
        printSerialCommandResult(command, "unknown");
      }
      break;
    case 'y':
      if (kBeachSceneMode && handleBeachSwipeGesture(kCx - 86, kCy, kCx + 86, kCy)) {
        printSerialCommandResult(command, "beach_swipe_right_test");
      } else {
        printSerialCommandResult(command, "unknown");
      }
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

void handleRelaySerialCommand(const String &line) {
  int offset = 0;
  String command;
  String relayUrl;
  String roomToken;
  String deviceToken;
  nextSerialToken(line, offset, command);
  if (!nextSerialToken(line, offset, relayUrl) ||
      !nextSerialToken(line, offset, roomToken) ||
      !nextSerialToken(line, offset, deviceToken)) {
    Serial.println("DIAG relay usage: relay <ws_url> <room_token> <device_token>");
    return;
  }

  provisioning.relayUrl = relayUrl;
  provisioning.roomToken = roomToken;
  provisioning.deviceToken = deviceToken;
  provisioning.serverConfigured = provisioning.relayUrl.length() > 0 && provisioning.deviceToken.length() > 0;
  provisioning.relayConnected = false;
  provisioning.relaySocketConfigured = false;
  provisioning.relayState = provisioning.serverConfigured ? "configured" : "unconfigured";
  provisioning.lastWrite = "serial_relay";
  lastRelayAttemptMs = 0;
  lastRelayHeartbeatMs = 0;
  relaySocket.disconnect();
  saveProvisioningState();
  notifyDeviceStatus(true);

  Serial.print("DIAG relay configured url=");
  Serial.print(provisioning.relayUrl);
  Serial.print(" room=");
  Serial.print(provisioning.roomToken);
  Serial.print(" device=");
  Serial.println(provisioning.deviceToken);
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

  if (kBeachSceneMode) {
    const int gap = abs(beachWalkers[1].x - beachWalkers[0].x);
    Serial.print("DIAG beach ms=");
    Serial.print(now);
    Serial.print(" boyX=");
    Serial.print(beachWalkers[0].x);
    Serial.print(" boyDir=");
    Serial.print(beachWalkers[0].dir);
    Serial.print(" girlX=");
    Serial.print(beachWalkers[1].x);
    Serial.print(" girlDir=");
    Serial.print(beachWalkers[1].dir);
    Serial.print(" gap=");
    Serial.print(gap);
    Serial.print(" audioPreset=");
    Serial.print(audioPreset);
    Serial.print(" drawMs=");
    Serial.print(lastDrawMs);
    Serial.print(" online=");
    Serial.print(touchOnline ? "T" : "-");
    Serial.print(imuOnline ? "I" : "-");
    Serial.print(audioOnline ? "A" : "-");
    Serial.println();
    return;
  }

  Serial.print("DIAG tick ms=");
  Serial.print(now);
  Serial.print(" zoom=");
  Serial.print(zoomLevel);
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
  Serial.print(" ptt=");
  Serial.print(voiceCapture.pttActive ? "active" : "idle");
  Serial.print(" muted=");
  Serial.print(voiceCapture.muted ? "yes" : "no");
  Serial.print(" voiceTx=");
  Serial.print(voiceCapture.sequence);
  Serial.print(" voiceRx=");
  Serial.println(voiceCapture.receivedSequence);
}

void drawSettingsIconBrightness(int x, int y, uint16_t color) {
  gfx->drawCircle(x, y, 13, color);
  gfx->drawCircle(x, y, 18, kGridDim);
  for (int i = 0; i < 8; ++i) {
    const float a = i * kPi / 4.0f;
    const int x0 = x + static_cast<int>(cosf(a) * 23.0f);
    const int y0 = y + static_cast<int>(sinf(a) * 23.0f);
    const int x1 = x + static_cast<int>(cosf(a) * 33.0f);
    const int y1 = y + static_cast<int>(sinf(a) * 33.0f);
    gfx->drawLine(x0, y0, x1, y1, color);
  }
}

void drawSettingsIconVolume(int x, int y, uint16_t color) {
  gfx->drawRect(x - 27, y - 12, 10, 24, color);
  gfx->drawLine(x - 17, y - 12, x, y - 25, color);
  gfx->drawLine(x - 17, y + 12, x, y + 25, color);
  gfx->drawLine(x, y - 25, x, y + 25, color);
  if (audioPreset == 0) {
    gfx->drawLine(x + 13, y + 18, x + 33, y - 18, color);
    return;
  }

  const uint8_t arcCount = audioPreset < 3 ? audioPreset : 3;
  for (int i = 0; i < 3; ++i) {
    const int r = 16 + i * 10;
    gfx->drawArc(x + 4, y, r, r - 1, 300, 60, i < arcCount ? color : kGridDim);
  }
}

void drawSettingsRow(int y0, const char *label, uint8_t preset, bool brightnessRow) {
  const int rowH = kScreenH / 2;
  const int cy = y0 + rowH / 2;
  const uint16_t active = millis() < settingsFlashUntilMs ? kGridBright : kGrid;

  gfx->setTextSize(2);
  gfx->setTextColor(kGrid);
  gfx->setCursor(62, y0 + 31);
  gfx->print(label);

  if (brightnessRow) {
    drawSettingsIconBrightness(84, cy + 12, active);
  } else {
    drawSettingsIconVolume(88, cy + 12, active);
  }

  const int startX = 154;
  const int baseY = cy + 50;
  for (uint8_t i = 0; i < 5; ++i) {
    const int x = startX + i * 42;
    const int h = 28 + i * 12;
    const int activePreset = brightnessRow ? preset : static_cast<int>(preset) - 1;
    const bool on = i <= activePreset;
    const uint16_t c = on ? active : kGridDim;
    gfx->drawRect(x, baseY - h, 24, h, c);
    if (on) {
      gfx->fillRect(x + 5, baseY - h + 5, 14, h - 10, i == activePreset ? kGridBright : kGrid);
    }
    gfx->drawFastHLine(x + 1, baseY + 8, 22, c);
  }

  gfx->setTextSize(1);
  gfx->setTextColor(kGridDim);
  gfx->setCursor(startX, baseY + 23);
  gfx->print("I");
  gfx->setCursor(startX + 4 * 42, baseY + 23);
  gfx->print("V");
}

void drawSettingsScreen() {
  gfx->fillScreen(kBlack);

  for (int x = 0; x < kScreenW; x += 32) {
    gfx->drawFastVLine(x, 0, kScreenH, kGridDeep);
  }
  for (int y = 0; y < kScreenH; y += 32) {
    gfx->drawFastHLine(0, y, kScreenW, kGridDeep);
  }

  gfx->drawCircle(kCx, kCy, kRadarGridRadius - 1, kGridDim);
  gfx->drawCircle(kCx, kCy, kRadarGridRadius - 9, kGridDeep);
  gfx->drawFastHLine(28, kCy, kScreenW - 56, kGrid);
  gfx->drawFastHLine(56, 44, kScreenW - 112, kGridDim);
  gfx->drawFastHLine(56, kScreenH - 45, kScreenW - 112, kGridDim);
  gfx->drawFastVLine(kCx, 28, 48, kGridDim);
  gfx->drawFastVLine(kCx, kScreenH - 76, 48, kGridDim);

  gfx->setTextSize(1);
  gfx->setTextColor(kGridBright);
  gfx->setCursor(kCx - 32, 24);
  gfx->print("SYSTEM");
  gfx->setCursor(kCx - 28, kScreenH - 34);
  gfx->print("SELECT");

  drawSettingsRow(0, "LUX", brightnessPreset, true);
  drawSettingsRow(kCy, "VOL", audioPreset, false);
  gfx->flush();
}

void drawCurrentModeFrame() {
  if (kBeachSceneMode) {
    drawBeachScene();
    return;
  }

  if (settingsMode) {
    drawSettingsScreen();
    return;
  }

  if (easterMode) {
    drawEasterBadgeFrame();
    return;
  }

  if (millis() < displaySelfTestUntilMs) {
    drawDisplaySelfTest();
    gfx->flush();
    return;
  }

  const uint32_t now = millis();
  drawRadarGrid();
  if (!radarNetworkOnline() || activeRemoteAppLocationCount(now) == 0) {
    drawTargets();
  }
  drawRemoteAppMarker();
  drawButtonTapEffects(now);
  drawPttEdgeRipple(now);
  drawHomeMarker(now);
  drawSignalLostBanner(now);
  drawNetworkErrorBanner();
  gfx->flush();
}

void drawFrame() {
  drawCurrentModeFrame();
  if (!settingsMode && !easterMode && millis() >= displaySelfTestUntilMs) {
    updateMainFadeBrightness(millis());
  }
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("Dragon Radar firmware boot");
  Serial.println("AUDIO_PATH_FULL_DUPLEX_20260609_01");

  loadRuntimeSettings();
  loadProvisioningState();
  if (kBeachSceneMode) {
    audioPreset = kAudioPresetCount - 1;
  }
  initRadarChordHalfCache();
  randomSeed(esp_random());
  Wire.begin(IIC_SDA, IIC_SCL);

  setupBatteryGauge();
  setupPowerButton();
  setupButtons();
  resetPanelAndTouch();
  setupTouch();
  if (kBeachSceneMode) {
    setupAudio();
  } else {
    setupBootAudio();
  }

  if (!gfx->begin(kDisplayBusHz)) {
    Serial.println("Display init failed.");
  }
  panel->setBrightness(currentBrightness());
  gfx->fillScreen(kBlack);
  gfx->flush();

  if (kBeachSceneMode) {
    initBeachScene();
  } else {
    initTargets();
    runBootAnimation();
    setupAudio();
  }

  setupImu();
  if (!kBeachSceneMode) {
    setupBle();
  }
  printHardwareSummary();
  printSerialCommandHelp();
  printRadarEvent("start", millis());
  radarStartedMs = millis();
}

void loop() {
  readImu();
  pollPowerButton();
  pollButtons();
  pollTouch();
  provisioningTick();
  cloudRelayTick();
  voiceCaptureTick();
  serialCommandTick();
  serialDiagnosticsTick();
  handleAudioEvents();
  audioTick();

  const uint32_t now = millis();
  if (now - lastFrameMs >= currentFrameMs()) {
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
