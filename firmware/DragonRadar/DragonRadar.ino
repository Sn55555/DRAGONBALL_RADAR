#include <Arduino.h>
#include <Arduino_GFX_Library.h>
#include <BLEAdvertisedDevice.h>
#include <BLEDevice.h>
#include <BLEScan.h>
#include <ESP_I2S.h>
#include <Preferences.h>
#include <Wire.h>
#include <esp_system.h>
#include <math.h>
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

#ifndef DRAGON_RADAR_DEMO_ON_BOOT
#define DRAGON_RADAR_DEMO_ON_BOOT 1
#endif

#ifndef DRAGON_RADAR_DEMO_TOUCH
#define DRAGON_RADAR_DEMO_TOUCH 1
#endif

#ifndef DRAGON_RADAR_SIMULATED_BLE
#define DRAGON_RADAR_SIMULATED_BLE 0
#endif

#ifndef DRAGON_RADAR_BEACH_SCENE
#define DRAGON_RADAR_BEACH_SCENE 0
#endif

#ifndef DRAGON_RADAR_BEACON_TTL_MS
#define DRAGON_RADAR_BEACON_TTL_MS 18000
#endif

#ifndef DRAGON_RADAR_BEACON_TRACE_MS
#define DRAGON_RADAR_BEACON_TRACE_MS 45000
#endif

#ifndef DRAGON_RADAR_BEACON_FRESH_MS
#define DRAGON_RADAR_BEACON_FRESH_MS 3000
#endif

#ifndef DRAGON_RADAR_COLLECT_HOLD_MS
#define DRAGON_RADAR_COLLECT_HOLD_MS 1200
#endif

#ifndef DRAGON_RADAR_COLLECT_RSSI
#define DRAGON_RADAR_COLLECT_RSSI -50
#endif

#ifndef DRAGON_RADAR_BRIGHTNESS
#define DRAGON_RADAR_BRIGHTNESS 184
#endif

#ifndef DRAGON_RADAR_AUDIO_GAIN
#define DRAGON_RADAR_AUDIO_GAIN 100
#endif

#ifndef DRAGON_RADAR_SOUND_EFFECTS
#define DRAGON_RADAR_SOUND_EFFECTS 0
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
static_assert(DRAGON_RADAR_DEMO_TOUCH == 0 || DRAGON_RADAR_DEMO_TOUCH == 1,
              "DRAGON_RADAR_DEMO_TOUCH must be 0 or 1");
static_assert(DRAGON_RADAR_SIMULATED_BLE == 0 || DRAGON_RADAR_SIMULATED_BLE == 1,
              "DRAGON_RADAR_SIMULATED_BLE must be 0 or 1");
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
constexpr float kPi = 3.14159265358979323846f;
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
constexpr uint32_t kBeaconTtlMs = DRAGON_RADAR_BEACON_TTL_MS;
constexpr uint32_t kBeaconTraceMs = DRAGON_RADAR_BEACON_TRACE_MS;
constexpr uint32_t kBeaconFreshMs = DRAGON_RADAR_BEACON_FRESH_MS;
constexpr uint32_t kScanKickMs = 30000;
constexpr uint32_t kCollectHoldMs = DRAGON_RADAR_COLLECT_HOLD_MS;
constexpr uint32_t kCaptureFlashMs = 1100;
constexpr uint32_t kResetFlashMs = 640;
constexpr uint32_t kSummonGatherMs = 1600;
constexpr uint32_t kStartupAcquireMs = 980;
constexpr uint32_t kAcquisitionEchoMs = 760;
constexpr uint32_t kTouchEchoMs = 520;
constexpr uint32_t kButtonDebounceMs = 45;
constexpr uint32_t kButtonLongPressMs = 900;
constexpr uint16_t kFarChirpIntervalMs = 820;
constexpr uint16_t kNearChirpIntervalMs = 260;
constexpr uint8_t kAxp2101Address = 0x34;
constexpr uint8_t kAxpIrqEnable1Reg = 0x41;
constexpr uint8_t kAxpIrqStatus1Reg = 0x49;
constexpr uint8_t kAxpPowerKeyLongPressBit = 0x04;
constexpr uint8_t kAxpPowerKeyShortPressBit = 0x08;
constexpr int kCollectRssi = DRAGON_RADAR_COLLECT_RSSI;
constexpr int kAudioSampleRate = 16000;
constexpr uint8_t kDisplayBrightness = DRAGON_RADAR_BRIGHTNESS;
constexpr int kAudioGainPercent = DRAGON_RADAR_AUDIO_GAIN;
constexpr bool kSoundEffectsEnabled = DRAGON_RADAR_SOUND_EFFECTS;
constexpr bool kShowDebugHud = DRAGON_RADAR_DEBUG_HUD;
constexpr bool kShowScanLine = DRAGON_RADAR_SCAN_LINE;
constexpr bool kShowStarBlips = DRAGON_RADAR_STAR_BLIPS;
constexpr bool kSnapTargetsToGrid = DRAGON_RADAR_GRID_SNAP;
constexpr bool kSerialDiagnostics = DRAGON_RADAR_SERIAL_DIAG;
constexpr bool kDemoOnBoot = DRAGON_RADAR_DEMO_ON_BOOT;
constexpr bool kDemoTouchEnabled = DRAGON_RADAR_DEMO_TOUCH;
constexpr bool kSimulatedBle = DRAGON_RADAR_SIMULATED_BLE;
constexpr bool kBeachSceneMode = DRAGON_RADAR_BEACH_SCENE;
constexpr uint8_t kZoomLevelCount = 3;
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
constexpr uint8_t kAudioPresetCount = 5;
constexpr uint8_t kFramePresetCount = 6;
constexpr uint8_t kTouchInitAttempts = 3;
constexpr uint8_t kFramePrefsSchema = 3;
constexpr size_t kRadarChordCacheSize = kRadarRadius * 2 + 1;
constexpr uint8_t kBrightnessPercents[kBrightnessPresetCount] = {35, 55, 80, 105, 125};
constexpr uint8_t kAudioRuntimePercents[kAudioPresetCount] = {0, 45, 70, 100, 130};
constexpr uint32_t kFrameRuntimeMs[kFramePresetCount] = {kFrameMs, 33, 50, 65, 80, 120};
constexpr uint32_t kLegacyFrameRuntimeMs[] = {80, 65, 50, 120};

struct DragonTarget {
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

DragonTarget targets[7];
BLEScan *bleScan = nullptr;
AudioTone tone;

volatile bool touchIrq = false;
bool touchOnline = false;
bool imuOnline = false;
bool bleOnline = false;
bool audioOnline = false;
bool powerButtonOnline = false;
bool demoMode = kDemoOnBoot;
bool scanning = true;
bool summonMode = false;
bool settingsMode = false;
bool easterMode = false;
uint8_t zoomLevel = 0;
uint8_t brightnessPreset = 2;
uint8_t audioPreset = 3;
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
uint32_t lastImuMicros = 0;
uint32_t lastScanChirpMs = 0;
uint32_t summonStartedMs = 0;
uint32_t radarStartedMs = 0;
uint32_t zoomFlashUntilMs = 0;
uint32_t resetFlashUntilMs = 0;
uint32_t brightnessFlashUntilMs = 0;
uint32_t audioFlashUntilMs = 0;
uint32_t frameFlashUntilMs = 0;
uint32_t touchEchoUntilMs = 0;
uint32_t bootButtonPressedAtMs = 0;
uint32_t altButtonPressedAtMs = 0;
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
uint16_t huntSessionId = 1;
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

void startTone(float frequency, uint16_t durationMs, int16_t level, bool force);
void startBleScan();
void snapPointToGrid(int &x, int &y);
void printHardwareSummary();
void printSerialCommandHelp();
void printHuntEvent(const char *event, uint32_t now);
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
  static const int pitches[kZoomLevelCount] = {32, 32, 32};
  const uint8_t idx = zoomLevel < kZoomLevelCount ? zoomLevel : kZoomLevelCount - 1;
  return max(10, static_cast<int>(roundf(pitches[idx] * gridGestureScale)));
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
  static const float scales[kZoomLevelCount] = {1.0f, 1.48f, 2.12f};
  const uint8_t idx = zoomLevel < kZoomLevelCount ? zoomLevel : kZoomLevelCount - 1;
  return scales[idx] * gridGestureScale;
}

uint8_t activeTargetCount() {
  const uint32_t now = millis();
  uint8_t active = 0;
  for (const auto &target : targets) {
    if (!target.collected && target.seen && now - target.lastSeenMs < kBeaconTtlMs) {
      ++active;
    }
  }
  return active;
}

uint8_t collectedTargetCount() {
  uint8_t collected = 0;
  for (const auto &target : targets) {
    if (target.collected) {
      ++collected;
    }
  }
  return collected;
}

int strongestActiveTargetIndex() {
  const uint32_t now = millis();
  int best = -1;
  int bestRssi = -128;
  for (int i = 0; i < 7; ++i) {
    const DragonTarget &target = targets[i];
    if (!target.collected && target.seen && now - target.lastSeenMs < kBeaconTtlMs &&
        target.filteredRssi > bestRssi) {
      best = i;
      bestRssi = target.filteredRssi;
    }
  }
  return best;
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

void resetBearingScores(DragonTarget &target) {
  memset(target.bearingScores, 0, sizeof(target.bearingScores));
  target.bestBearingBin = headingToBearingBin(target.worldAngleDeg);
}

void addBearingScore(DragonTarget &target, uint8_t bin, uint8_t sample) {
  const uint16_t previous = target.bearingScores[bin];
  const uint16_t blended = (previous * 3 + sample) / 4;
  uint16_t next = blended > previous ? blended : previous;
  if (next > 255) {
    next = 255;
  }
  target.bearingScores[bin] = static_cast<uint8_t>(next);
}

void updateBearingEstimate(DragonTarget &target, int rssi, bool reset) {
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

float targetNearness(const DragonTarget &target) {
  return clampf((0.96f - target.rangeNorm) / (0.96f - 0.13f), 0.0f, 1.0f);
}

uint16_t targetChirpIntervalMs(const DragonTarget &target) {
  if (target.closeSinceMs > 0) {
    return 180;
  }
  const float near = targetNearness(target);
  return static_cast<uint16_t>(lerpf(kFarChirpIntervalMs, kNearChirpIntervalMs, near));
}

float targetChirpFrequency(const DragonTarget &target, uint8_t activeCount) {
  const float near = targetNearness(target);
  float freq = lerpf(900.0f, 1540.0f, near) + activeCount * 24.0f;
  if (target.closeSinceMs > 0) {
    freq += 220.0f;
  }
  return freq;
}

uint16_t targetChirpDurationMs(const DragonTarget &target) {
  return static_cast<uint16_t>(lerpf(26.0f, 48.0f, targetNearness(target)));
}

int16_t targetChirpLevel(const DragonTarget &target) {
  return static_cast<int16_t>(lerpf(2200.0f, 3900.0f, targetNearness(target)));
}

int16_t scaledAudioLevel(int16_t level) {
  const int32_t scaled = (static_cast<int32_t>(level) * kAudioGainPercent *
                          kAudioRuntimePercents[audioPreset]) /
                         10000;
  return static_cast<int16_t>(constrain(scaled, 0L, 12000L));
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
  const uint8_t frameSchema = prefs.getUChar("frameSchema", 0);
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
    audioPreset = 3;
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

void resetTargetTrail(DragonTarget &target) {
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

void clearHuntState() {
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
  summonMode = false;
  lastActiveCount = 0;
  lastCollectedCount = 0;
}

void resetHuntSession() {
  clearHuntState();
  ++huntSessionId;
  resetFlashUntilMs = millis() + kResetFlashMs;
  startBleScan();
  startTone(620.0f, 70, 3000, true);
  printHuntEvent("reset", millis());
}

void printHuntEvent(const char *event, uint32_t now) {
  if (!kSerialDiagnostics) {
    return;
  }

  Serial.print("DIAG hunt session=");
  Serial.print(huntSessionId);
  Serial.print(" event=");
  Serial.print(event);
  Serial.print(" ms=");
  Serial.println(now);
}

void printCollectionEvent(const DragonTarget &target, uint32_t now) {
  if (!kSerialDiagnostics) {
    return;
  }

  Serial.print("DIAG collect DBALL-");
  Serial.print(target.star);
  Serial.print(" session=");
  Serial.print(huntSessionId);
  Serial.print(" ms=");
  Serial.print(now);
  Serial.print(" raw=");
  Serial.print(target.rssi);
  Serial.print(" filtered=");
  Serial.print(target.filteredRssi);
  Serial.print(" range=");
  Serial.print(target.rangeNorm, 2);
  Serial.print(" bearingBin=");
  Serial.print(target.bestBearingBin);
  Serial.print(" bearing=");
  Serial.println(target.worldAngleDeg, 1);
}

void markTargetCollected(DragonTarget &target, uint32_t now) {
  if (!target.collected) {
    target.collected = true;
    target.collectedAtMs = now;
    printCollectionEvent(target, now);
  }
}

void cycleMapScale() {
  zoomLevel = (zoomLevel + 1) % kZoomLevelCount;
  resetAllTargetTrails();
  zoomFlashUntilMs = millis() + 700;
  startTone(820.0f + zoomLevel * 220.0f, 64, 2800, true);
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
  summonMode = false;
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

void collectNextDemoTarget() {
  for (auto &target : targets) {
    if (!target.collected) {
      target.seen = true;
      target.demo = true;
      target.rssi = -42;
      target.filteredRssi = -42;
      target.bestRssi = -42;
      target.lastSeenMs = millis();
      target.revealedAtMs = target.lastSeenMs;
      target.closeSinceMs = target.lastSeenMs;
      markTargetCollected(target, target.lastSeenMs);
      return;
    }
  }
  resetHuntSession();
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

bool setupCodec16k() {
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
  ok &= codecWrite(0x32, 0x9A);
  ok &= codecRead(0x31, reg);
  reg &= ~(0x60);
  ok &= codecWrite(0x31, reg);

  return ok;
}

void startTone(float frequency, uint16_t durationMs, int16_t level, bool force = false) {
  if (!kSoundEffectsEnabled) {
    tone.active = false;
    tone.remainingSamples = 0;
    return;
  }
  if (!audioOnline) {
    return;
  }
  if (tone.active && !force) {
    return;
  }
  tone.active = true;
  tone.frequency = frequency;
  tone.phase = 0.0f;
  tone.totalSamples = (kAudioSampleRate * durationMs) / 1000;
  tone.remainingSamples = tone.totalSamples;
  tone.level = scaledAudioLevel(level);
}

void playBootAudioCues(float phase, uint8_t &nextCue) {
  while (nextCue < kBootAudioCueCount && phase >= kBootAudioCues[nextCue].phase) {
    const BootAudioCue &cue = kBootAudioCues[nextCue];
    startTone(cue.frequency, cue.durationMs, cue.level, true);
    ++nextCue;
  }
}

void audioTick() {
  if (!audioOnline || !tone.active) {
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

void setupAudio() {
  pinMode(PA, OUTPUT);
  digitalWrite(PA, HIGH);

  i2s.setPins(PIN_ES7210_BCLK, PIN_ES7210_LRCK, PIN_ES8311_DOUT, PIN_ES7210_DIN, PIN_ES7210_MCLK);
  if (!i2s.begin(I2S_MODE_STD, kAudioSampleRate, I2S_DATA_BIT_WIDTH_16BIT, I2S_SLOT_MODE_STEREO, I2S_STD_SLOT_BOTH)) {
    Serial.println("I2S audio offline.");
    return;
  }

  audioOnline = setupCodec16k();
  Serial.println(audioOnline ? "ES8311 audio online." : "ES8311 codec offline.");
  startTone(740.0f, 90, 3600, true);
}

void runBootAnimation() {
  bootStartedMs = millis();
  uint8_t nextBootCue = 0;
  const uint8_t targetBrightness = currentBrightness();
  panel->setBrightness(0);
  drawBootFrame(1.0f);
  gfx->flush();

  while (millis() - bootStartedMs < kBootDurationMs) {
    const uint32_t elapsedMs = millis() - bootStartedMs;
    const float phase = clampf(elapsedMs / static_cast<float>(kBootDurationMs), 0.0f, 1.0f);
    const float fadeIn = smoothStep(0.0f, static_cast<float>(kBootFadeInMs), static_cast<float>(elapsedMs));
    const float fadeOut = 1.0f - smoothStep(static_cast<float>(kBootDurationMs - kBootFadeOutMs),
                                            static_cast<float>(kBootDurationMs),
                                            static_cast<float>(elapsedMs));
    const float brightness = clampf(fadeIn * fadeOut, 0.0f, 1.0f);
    panel->setBrightness(static_cast<uint8_t>(targetBrightness * brightness));
    playBootAudioCues(phase, nextBootCue);
    audioTick();
    delay(18);
  }
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

int extractDragonBallIndex(BLEAdvertisedDevice &device) {
  if (device.haveName()) {
    String name = device.getName();
    name.toUpperCase();
    const int p = name.indexOf("DBALL-");
    if (p >= 0) {
      const int star = name.substring(p + 6).toInt();
      if (star >= 1 && star <= 7) {
        return star - 1;
      }
    }
  }

  if (device.haveManufacturerData()) {
    const String payload = device.getManufacturerData();
    if (payload.length() == 3) {
      const uint8_t marker0 = static_cast<uint8_t>(payload[0]);
      const uint8_t marker1 = static_cast<uint8_t>(payload[1]);
      const uint8_t star = static_cast<uint8_t>(payload[2]);
      if (marker0 == 0x44 && marker1 == 0x42 && star >= 1 && star <= 7) {
        return star - 1;
      }
    }
  }

  return -1;
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

void updateTargetFromBle(int index, int rssi) {
  if (index < 0 || index >= 7) {
    return;
  }

  DragonTarget &target = targets[index];
  const uint32_t now = millis();
  if (target.collected) {
    demoMode = false;
    return;
  }

  const bool firstSeen = !target.seen || target.lastSeenMs == 0;
  const bool stale = firstSeen || now - target.lastSeenMs > kBeaconTtlMs;
  const bool stronger = rssi > target.bestRssi + 3;

  demoMode = false;
  target.seen = true;
  target.demo = false;
  target.rssi = rssi;
  target.filteredRssi = smoothRssi(target.filteredRssi, rssi, stale);
  target.lastSeenMs = now;
  if (firstSeen || stale) {
    target.revealedAtMs = now;
  }
  const float measuredRange = rssiToRangeNorm(target.filteredRssi);
  target.rangeNorm = stale ? measuredRange : lerpf(target.rangeNorm, measuredRange, 0.35f);
  updateBearingEstimate(target, target.filteredRssi, stale);

  if (stale) {
    target.closeSinceMs = 0;
  }
  if (!kSimulatedBle && rssi >= kCollectRssi) {
    if (target.closeSinceMs == 0) {
      target.closeSinceMs = now;
    } else if (now - target.closeSinceMs >= kCollectHoldMs) {
      markTargetCollected(target, now);
    }
  } else {
    target.closeSinceMs = 0;
  }

  if (stronger || stale) {
    target.bestRssi = rssi;
  }

  if (kSerialDiagnostics && now - lastBleDiagMs[index] > 500) {
    lastBleDiagMs[index] = now;
    Serial.print("DIAG BLE DBALL-");
    Serial.print(index + 1);
    Serial.print(" raw=");
    Serial.print(target.rssi);
    Serial.print(" filtered=");
    Serial.print(target.filteredRssi);
    Serial.print(" range=");
    Serial.print(target.rangeNorm, 2);
    Serial.print(" bearingBin=");
    Serial.print(target.bestBearingBin);
    Serial.print(" bearing=");
    Serial.print(target.worldAngleDeg, 1);
    Serial.print(" close=");
    Serial.println(target.closeSinceMs > 0 ? "yes" : "no");
  }
}

void simulatedBleTick() {
  if (!kSimulatedBle || summonMode) {
    return;
  }

  const uint32_t now = millis();
  if (radarStartedMs == 0 || now - radarStartedMs < 800 || now - lastSimulatedBleMs < 220) {
    return;
  }
  lastSimulatedBleMs = now;

  for (int i = 0; i < 7; ++i) {
    if (targets[i].collected) {
      continue;
    }
    targets[i].seen = true;
    targets[i].demo = true;
    targets[i].rssi = -62;
    targets[i].filteredRssi = -62;
    targets[i].bestRssi = -62;
    targets[i].lastSeenMs = now;
    if (targets[i].revealedAtMs == 0) {
      targets[i].revealedAtMs = now;
    }
    targets[i].worldAngleDeg = wrap360(28.0f + i * 51.3f);
    targets[i].rangeNorm = 0.38f + (i % 4) * 0.13f;
    targets[i].closeSinceMs = 0;
  }
}

class DragonBeaconCallbacks : public BLEAdvertisedDeviceCallbacks {
  void onResult(BLEAdvertisedDevice advertisedDevice) override {
    const int index = extractDragonBallIndex(advertisedDevice);
    if (index >= 0) {
      updateTargetFromBle(index, advertisedDevice.getRSSI());
    }
  }
};

void startBleScan() {
  if (!bleScan) {
    return;
  }
  bleScan->stop();
  bleScan->clearResults();
  bleScan->start(0, nullptr, false);
  lastBleKickMs = millis();
  if (kSerialDiagnostics) {
    Serial.println("DIAG BLE scan restarted");
  }
}

void setupBle() {
  BLEDevice::init("CapsuleRadar");
  bleScan = BLEDevice::getScan();
  if (!bleScan) {
    return;
  }

  bleScan->setAdvertisedDeviceCallbacks(new DragonBeaconCallbacks(), true);
  bleScan->setActiveScan(true);
  bleScan->setInterval(160);
  bleScan->setWindow(96);
  bleOnline = true;
  Serial.println("BLE scan online.");
  startBleScan();
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
    if (!imuOnline) {
      headingDeg = wrap360(headingDeg + 0.08f);
    }
    return;
  }

  const uint32_t now = micros();
  const float dt = (now - lastImuMicros) / 1000000.0f;
  lastImuMicros = now;

  if (qmi.getGyroscope(gyr.x, gyr.y, gyr.z)) {
    headingDeg = wrap360(headingDeg + gyr.z * dt);
  }
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
  }

  if (pressed && !bootButtonLongHandled && bootButtonPressedAtMs > 0 &&
      now - bootButtonPressedAtMs >= kButtonLongPressMs) {
    bootButtonLongHandled = true;
    lastButtonMs = now;
    showEasterEgg();
  }

  if (!pressed && bootButtonWasPressed) {
    const uint32_t heldMs = bootButtonPressedAtMs > 0 ? now - bootButtonPressedAtMs : 0;
    if (!bootButtonLongHandled && heldMs >= kButtonDebounceMs && now - lastButtonMs > 160) {
      lastButtonMs = now;
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

void updateBleScan() {
  if (!bleOnline || !bleScan) {
    return;
  }
  if (millis() - lastBleKickMs > kScanKickMs) {
    startBleScan();
  }
}

void drawRadarGrid() {
  gfx->fillScreen(kBlack);
  gfx->fillCircle(kCx, kCy, kRadarGridRadius, kScreenBg);

  const int pitch = currentGridPitch();
  const uint16_t gridColor = RGB565(12, 157, 71);
  const int start = -((kRadarGridRadius / pitch) * pitch);

  for (int offset = start; offset <= -start; offset += pitch) {
    const int half = circleChordHalf(offset, kRadarGridRadius);
    if (half <= 0) {
      continue;
    }
    gfx->drawFastHLine(kCx - half, kCy + offset, half * 2, gridColor);
    gfx->drawFastVLine(kCx + offset, kCy - half, half * 2, gridColor);
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
  if (kShowDebugHud || kShowStarBlips || demoMode || summonMode || activeTargetCount() > 0) {
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
  const uint32_t now = millis();
  if ((now % 1000) < 180) {
    return;
  }

  const int r = 7;
  gfx->fillCircle(x, y, r + 2, RGB565(138, 42, 0));
  gfx->fillCircle(x, y, r, RGB565(255, 122, 22));
  gfx->fillCircle(x - 2, y - 2, 2, kAmber);
  gfx->drawPixel(x - 3, y - 3, kWhite);
  (void)star;
  (void)fresh;
  (void)trace;
  (void)pulse;
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

void pushTargetTrail(DragonTarget &target, int x, int y, uint32_t now) {
  for (int i = kTargetTrailCount - 1; i > 0; --i) {
    target.trailX[i] = target.trailX[i - 1];
    target.trailY[i] = target.trailY[i - 1];
    target.trailMs[i] = target.trailMs[i - 1];
  }
  target.trailX[0] = static_cast<int16_t>(x);
  target.trailY[0] = static_cast<int16_t>(y);
  target.trailMs[0] = now;
}

void updateTargetTrail(DragonTarget &target, int x, int y, uint32_t now) {
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

void drawTargetTrail(const DragonTarget &target, uint32_t now) {
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

  const uint32_t held = min(heldMs, kCollectHoldMs);
  const bool flash = ((millis() / 86) & 1) == 0;
  const uint16_t c = flash ? kGridBright : kGrid;
  const int r = min(16, edgeRoom);
  const int frame = min(r + 4, edgeRoom);
  const int side = frame * 2;
  const int progress = static_cast<int>((held * side * 4UL) / kCollectHoldMs);
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
    gfx->print("NO BEACON");
    return;
  }

  DragonTarget &target = targets[idx];
  const int x = kCx - 118;
  const int y = 408;
  const int w = 236;
  const int h = 8;
  const int filteredW = rssiToBarWidth(target.filteredRssi, w - 2);
  const int rawX = x + 1 + rssiToBarWidth(target.rssi, w - 2);
  const int collectX = x + 1 + rssiToBarWidth(kCollectRssi, w - 2);
  const bool close = target.rssi >= kCollectRssi;

  gfx->drawRect(x, y, w, h, kGridDim);
  gfx->fillRect(x + 1, y + 2, filteredW, h - 4, close ? kOrange : kGrid);
  gfx->drawFastVLine(collectX, y - 3, h + 6, kAmber);
  gfx->drawFastVLine(rawX, y - 1, h + 2, kWhite);

  if (target.closeSinceMs > 0 && !target.collected) {
    const uint32_t held = min(millis() - target.closeSinceMs, kCollectHoldMs);
    const int holdW = (held * (w - 2)) / kCollectHoldMs;
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

void summonStartPoint(const DragonTarget &target, uint8_t index, int &x, int &y) {
  const float screenAngle = wrap360(target.worldAngleDeg - headingDeg);
  float radius = target.rangeNorm * currentMapScale() * (kRadarRadius - 28);
  if (radius < 58.0f) {
    radius = 58.0f + index * 7.0f;
  }
  radius = min(radius, static_cast<float>(kRadarRadius - 34));
  polarToPoint(screenAngle, radius, x, y);
  snapPointToGrid(x, y);
}

void drawSummonGathering(uint32_t elapsed) {
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
    summonStartPoint(targets[i], i, sx, sy);

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

void drawSummonCorePulse(uint32_t elapsed) {
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

void drawSummonOverlay() {
  if (!summonMode) {
    return;
  }

  const uint32_t elapsed = millis() - summonStartedMs;
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
  drawSummonCorePulse(elapsed);

  if (elapsed < kSummonGatherMs) {
    drawSummonGathering(elapsed);
    drawSummonCorePulse(elapsed);
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
  const float screenAngle = kSimulatedBle ? worldAngle : wrap360(worldAngle - headingDeg);
  float radius = range * currentMapScale() * kTargetMaxRadius;
  if (zoomLevel > 0 && radius > kTargetMaxRadius) {
    return false;
  }
  radius = min(radius, static_cast<float>(kTargetMaxRadius));
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

void drawTargets() {
  const uint32_t now = millis();

  for (int i = 0; i < 7; ++i) {
    DragonTarget &target = targets[i];
    if (target.collected) {
      continue;
    }

    bool visible = false;
    float range = target.rangeNorm;
    float worldAngle = target.worldAngleDeg;
    bool fresh = false;
    bool trace = false;

    if (target.seen && now - target.lastSeenMs < kBeaconTraceMs) {
      const uint32_t age = now - target.lastSeenMs;
      visible = true;
      fresh = target.revealedAtMs > 0 && now - target.revealedAtMs < kBeaconFreshMs;
      trace = age >= kBeaconTtlMs;
    } else if (demoMode) {
      visible = true;
      const float t = now / 1000.0f;
      worldAngle = wrap360(28.0f + i * 51.3f + sinf(t * 0.35f + i) * 15.0f);
      range = 0.25f + 0.1f * (i % 5) + 0.08f * sinf(t * 0.6f + i * 1.7f);
      range = clampf(range, 0.18f, 0.88f);
    }

    if (!visible) {
      continue;
    }

    int x;
    int y;
    if (!targetScreenPoint(worldAngle, range, x, y)) {
      continue;
    }
    snapPointToGrid(x, y);
    const float pulseF = (sinf((now / 130.0f) + i) + 1.0f) * 0.5f;
    drawOrb(x, y, target.star, fresh, trace, static_cast<uint8_t>(pulseF * 2.0f));
  }
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
  drawCollectionStrip();
  drawBearingCalibrationStrip();
  drawResetFlash();
  drawBrightnessFlash();
  drawAudioFlash();
  drawTouchEcho();
}

void handleAudioEvents() {
  const uint8_t active = activeTargetCount();
  const uint8_t collected = collectedTargetCount();
  const uint32_t now = millis();

  if (active > lastActiveCount) {
    startTone(1480.0f, 70, 3800, true);
  }
  if (collected > lastCollectedCount) {
    startTone(1880.0f, 120, 4400, true);
  }
  if (scanning && active > 0) {
    const int idx = strongestActiveTargetIndex();
    uint16_t intervalMs = 620;
    float frequency = 1040.0f + active * 70.0f;
    uint16_t durationMs = 32;
    int16_t level = 2400;
    if (idx >= 0) {
      DragonTarget &target = targets[idx];
      intervalMs = targetChirpIntervalMs(target);
      frequency = targetChirpFrequency(target, active);
      durationMs = targetChirpDurationMs(target);
      level = targetChirpLevel(target);
    }
    if (now - lastScanChirpMs > intervalMs) {
      startTone(frequency, durationMs, level, false);
      lastScanChirpMs = now;
    }
  }

  lastActiveCount = active;
  lastCollectedCount = collected;
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
  Serial.print(" audio=");
  Serial.println(audioOnline ? "online" : "offline");
  Serial.print("DIAG pwrButton=");
  Serial.println(powerButtonOnline ? "online" : "offline");
  if (kSimulatedBle) {
    Serial.println("DIAG simulatedBle=enabled");
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

  Serial.println("DIAG commands: ? help, h hardware, d display_test, z zoom, r reset/beach_right, b brightness, a audio, f frame_rate, t frame_turbo, c collect_demo, p ping, s scan, l beach_left, x beach_swipe_left_test, y beach_swipe_right_test");
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
        resetHuntSession();
        printSerialCommandResult(command, "reset");
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
    case 'c':
      demoMode = true;
      collectNextDemoTarget();
      startTone(1320.0f, 70, 3600, true);
      printSerialCommandResult(command, "collect_demo");
      break;
    case 'p':
      startTone(1568.0f, 120, 4200, true);
      printSerialCommandResult(command, "ping");
      break;
    case 's':
      startBleScan();
      printSerialCommandResult(command, "scan");
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

void serialCommandTick() {
  if (!kSerialDiagnostics) {
    return;
  }

  while (Serial.available() > 0) {
    const char command = static_cast<char>(Serial.read());
    if (command == '\n' || command == '\r' || command == ' ' || command == '\t') {
      continue;
    }
    handleSerialCommand(command);
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

  const int idx = strongestActiveTargetIndex();
  Serial.print("DIAG tick ms=");
  Serial.print(now);
  Serial.print(" active=");
  Serial.print(activeTargetCount());
  Serial.print(" collected=");
  Serial.print(collectedTargetCount());
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
  Serial.print(" strongest=");
  if (idx >= 0) {
    Serial.print(idx + 1);
    Serial.print("/");
    Serial.print(targets[idx].filteredRssi);
  } else {
    Serial.print("none");
  }
  Serial.print(" online=");
  Serial.print(touchOnline ? "T" : "-");
  Serial.print(imuOnline ? "I" : "-");
  Serial.print(bleOnline ? "B" : "-");
  Serial.print(audioOnline ? "A" : "-");
  Serial.print(" summon=");
  Serial.println(summonMode ? "yes" : "no");
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
  for (int i = 0; i < 3; ++i) {
    const int r = 16 + i * 10;
    gfx->drawArc(x + 4, y, r, r - 1, 300, 60, i <= audioPreset ? color : kGridDim);
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
    const bool on = i <= preset;
    const uint16_t c = on ? active : kGridDim;
    gfx->drawRect(x, baseY - h, 24, h, c);
    if (on) {
      gfx->fillRect(x + 5, baseY - h + 5, 14, h - 10, i == preset ? kGridBright : kGrid);
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

  drawRadarGrid();
  drawTargets();
  drawHomeMarker(millis());
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

  loadRuntimeSettings();
  if (kBeachSceneMode) {
    audioPreset = kAudioPresetCount - 1;
  }
  initRadarChordHalfCache();
  randomSeed(esp_random());
  Wire.begin(IIC_SDA, IIC_SCL);

  setupPowerButton();
  setupButtons();
  resetPanelAndTouch();
  setupTouch();
  setupAudio();

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
  }

  setupImu();
  if (!kBeachSceneMode) {
    setupBle();
  }
  printHardwareSummary();
  printSerialCommandHelp();
  printHuntEvent("start", millis());
  radarStartedMs = millis();
}

void loop() {
  readImu();
  pollPowerButton();
  pollButtons();
  pollTouch();
  updateBleScan();
  simulatedBleTick();
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
