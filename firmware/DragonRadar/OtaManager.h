#pragma once

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <freertos/task.h>

namespace DragonRadarOta {

enum class Phase : uint8_t {
  Idle,
  Validating,
  Downloading,
  Verifying,
  Rebooting,
  PendingVerify,
  Success,
  Error,
  RolledBack,
  Cancelled,
};

struct Snapshot {
  Phase phase = Phase::Idle;
  uint8_t progress = 0;
  size_t receivedBytes = 0;
  size_t totalBytes = 0;
  String targetVersion;
  uint32_t targetBuild = 0;
  String error;
  uint32_t updatedMs = 0;
};

class Manager {
 public:
  void begin();
  void tick();
  void setBootHealth(bool displayReady, bool bleReady);

  bool handleControlJson(const String &json,
                         bool paired,
                         int batteryPercent,
                         bool charging,
                         bool pttActive,
                         bool wifiConnected,
                         const String &deviceToken,
                         const String &expectedHttpApiBase);

  Snapshot snapshot() const;
  String statusJson() const;
  bool active() const;
  bool blocksPowerAndVoice() const;
  bool shouldShowOverlay() const;
  const char *phaseText() const;

 private:
  struct Manifest {
    uint32_t schema = 0;
    String product;
    String hardware;
    String version;
    uint32_t build = 0;
    String minimumVersion;
    uint32_t securityCounter = 0;
    size_t size = 0;
    String sha256;
    String signatureAlgorithm;
    String keyId;
    String signatureBase64;
    String artifactUrl;
  };

  static void taskThunk(void *argument);
  void runDownloadTask();
  bool parseControl(const String &json, String &action, Manifest &manifest, String &error) const;
  bool validateManifest(const Manifest &manifest,
                        const String &expectedHttpApiBase,
                        String &error) const;
  bool verifyManifestSignature(const Manifest &manifest) const;
  String canonicalManifest(const Manifest &manifest) const;
  bool decodeRootCa(String &pem) const;
  bool urlAllowed(const String &url, bool &secure) const;
  bool urlMatchesProvisionedOrigin(const String &url,
                                   const String &expectedHttpApiBase,
                                   bool &secure,
                                   String &error) const;
  bool startTask(const Manifest &manifest, const String &deviceToken);
  void cancel();
  void fail(const String &error);
  void setPhase(Phase phase, const String &error = "");
  void setProgress(size_t received, size_t total);
  bool savePendingUpdate(const Manifest &manifest);
  void clearPendingUpdate();
  void loadBootState();
  void markRunningImageValid();
  void rollbackRunningImage(const String &reason);

  mutable SemaphoreHandle_t mutex_ = nullptr;
  TaskHandle_t taskHandle_ = nullptr;
  Manifest manifest_;
  String authorizationToken_;
  Snapshot status_;
  volatile bool cancelRequested_ = false;
  bool pendingBootVerify_ = false;
  bool displayReady_ = false;
  bool bleReady_ = false;
  uint32_t bootStartedMs_ = 0;
  uint32_t healthStableSinceMs_ = 0;
};

const char *phaseText(Phase phase);

}  // namespace DragonRadarOta
