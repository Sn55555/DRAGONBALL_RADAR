#include "OtaManager.h"

#include <HTTPClient.h>
#include <Preferences.h>
#include <Update.h>
#include <WiFiClient.h>
#include <WiFiClientSecure.h>
#include <esp_ota_ops.h>
#include <mbedtls/base64.h>
#include <mbedtls/md.h>
#include <mbedtls/pk.h>
#include <mbedtls/sha256.h>

#include <memory>
#include <time.h>
#include <vector>

#include "FirmwareVersion.h"
#include "OtaSigningPublicKey.h"

#if !defined(CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE) || !CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE
#error "Capsule Radar OTA requires CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE"
#endif

// Arduino's rollback support calls this weak C hook from initArduino().  The
// framework default returns false and immediately marks a pending OTA image as
// valid.  Capsule Radar deliberately defers that decision until OtaManager has
// observed a healthy display and BLE service for a stable interval.
extern "C" bool verifyRollbackLater() {
  return true;
}

namespace DragonRadarOta {
namespace {

constexpr uint32_t kBootHealthStableMs = 15000;
constexpr uint32_t kBootHealthTimeoutMs = 60000;
constexpr uint32_t kTerminalOverlayMs = 5000;
constexpr size_t kControlMaxBytes = 1024;
constexpr size_t kDownloadBufferBytes = 4096;
constexpr uint32_t kDownloadIdleTimeoutMs = 20000;
constexpr uint8_t kDownloadConsecutiveNoProgressAttempts = 3;
constexpr uint8_t kDownloadMaxProgressingResumeSessions = 24;
constexpr uint32_t kDownloadReconnectDelayMs = 500;
constexpr uint32_t kTimeSyncTimeoutMs = 15000;
constexpr time_t kMinimumTrustedEpoch = 1704067200;  // 2024-01-01 UTC
constexpr uint32_t kOtaTaskStackBytes = 16384;
constexpr BaseType_t kOtaTaskPriority = 1;
constexpr const char *kPreferencesNamespace = "radarOta";
constexpr const char *kArtifactPathPrefix = "/v1/firmware/artifacts/";

struct ParsedHttpUrl {
  bool secure = false;
  String host;
  uint16_t port = 0;
  String path;
};

class LockGuard {
 public:
  explicit LockGuard(SemaphoreHandle_t mutex) : mutex_(mutex) {
    if (mutex_) {
      xSemaphoreTake(mutex_, portMAX_DELAY);
    }
  }
  ~LockGuard() {
    if (mutex_) {
      xSemaphoreGive(mutex_);
    }
  }

 private:
  SemaphoreHandle_t mutex_;
};

bool isWhitespace(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

bool parsePort(const String &text, uint16_t &port) {
  if (text.length() == 0 || text.length() > 5) {
    return false;
  }
  uint32_t parsed = 0;
  for (size_t index = 0; index < text.length(); ++index) {
    const char c = text[index];
    if (c < '0' || c > '9') {
      return false;
    }
    parsed = parsed * 10 + static_cast<uint8_t>(c - '0');
  }
  if (parsed == 0 || parsed > UINT16_MAX) {
    return false;
  }
  port = static_cast<uint16_t>(parsed);
  return true;
}

bool validHostCharacters(const String &host, bool ipv6) {
  if (host.length() == 0 || host.length() > 253) {
    return false;
  }
  for (size_t index = 0; index < host.length(); ++index) {
    const char c = host[index];
    const bool digit = c >= '0' && c <= '9';
    const bool alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    if (ipv6) {
      if (!digit && !(c >= 'a' && c <= 'f') && !(c >= 'A' && c <= 'F') &&
          c != ':' && c != '.') {
        return false;
      }
    } else if (!digit && !alpha && c != '.' && c != '-') {
      return false;
    }
  }
  return true;
}

bool parseHttpUrl(const String &url, bool allowHttp, ParsedHttpUrl &parsed) {
  parsed = ParsedHttpUrl{};
  parsed.secure = url.startsWith("https://");
  const bool developmentHttp = allowHttp && url.startsWith("http://");
  const size_t schemeLength = parsed.secure ? 8 : (developmentHttp ? 7 : 0);
  if (schemeLength == 0 || url.length() <= schemeLength || url.length() > 384 ||
      url.indexOf('\r') >= 0 || url.indexOf('\n') >= 0 || url.indexOf('\t') >= 0 ||
      url.indexOf(' ') >= 0 || url.indexOf('\\') >= 0 || url.indexOf('?') >= 0 ||
      url.indexOf('#') >= 0) {
    return false;
  }

  const int pathOffset = url.indexOf('/', static_cast<unsigned int>(schemeLength));
  const String authority = pathOffset < 0 ? url.substring(schemeLength)
                                          : url.substring(schemeLength, pathOffset);
  parsed.path = pathOffset < 0 ? "/" : url.substring(pathOffset);
  if (authority.length() == 0 || authority.indexOf('@') >= 0 || parsed.path.length() == 0) {
    return false;
  }

  String portText;
  if (authority.startsWith("[")) {
    const int close = authority.indexOf(']');
    if (close <= 1) {
      return false;
    }
    parsed.host = authority.substring(1, close);
    if (!validHostCharacters(parsed.host, true)) {
      return false;
    }
    const String suffix = authority.substring(close + 1);
    if (suffix.length() > 0) {
      if (!suffix.startsWith(":") || !parsePort(suffix.substring(1), parsed.port)) {
        return false;
      }
    }
  } else {
    const int colon = authority.lastIndexOf(':');
    if (colon >= 0) {
      if (authority.indexOf(':') != colon) {
        return false;
      }
      parsed.host = authority.substring(0, colon);
      portText = authority.substring(colon + 1);
      if (!parsePort(portText, parsed.port)) {
        return false;
      }
    } else {
      parsed.host = authority;
    }
    if (!validHostCharacters(parsed.host, false)) {
      return false;
    }
  }
  parsed.host.toLowerCase();
  if (parsed.port == 0) {
    parsed.port = parsed.secure ? 443 : 80;
  }
  return true;
}

bool validArtifactPath(const String &path) {
  if (!path.startsWith(kArtifactPathPrefix)) {
    return false;
  }
  const String basename = path.substring(strlen(kArtifactPathPrefix));
  if (basename.length() == 0 || basename.length() > 128 || basename.startsWith(".") ||
      basename.indexOf("..") >= 0) {
    return false;
  }
  for (size_t index = 0; index < basename.length(); ++index) {
    const char c = basename[index];
    const bool digit = c >= '0' && c <= '9';
    const bool alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
    if (!digit && !alpha && c != '-' && c != '_' && c != '.') {
      return false;
    }
  }
  return true;
}

bool findJsonValue(const String &json, const char *key, size_t &offset) {
  String needle = "\"";
  needle += key;
  needle += "\"";
  int found = json.indexOf(needle);
  while (found >= 0) {
    size_t cursor = static_cast<size_t>(found) + needle.length();
    while (cursor < json.length() && isWhitespace(json[cursor])) {
      ++cursor;
    }
    if (cursor < json.length() && json[cursor] == ':') {
      ++cursor;
      while (cursor < json.length() && isWhitespace(json[cursor])) {
        ++cursor;
      }
      offset = cursor;
      return true;
    }
    found = json.indexOf(needle, found + needle.length());
  }
  return false;
}

bool readJsonStringAt(const String &json, size_t offset, String &value) {
  if (offset >= json.length() || json[offset] != '"') {
    return false;
  }
  value = "";
  for (size_t cursor = offset + 1; cursor < json.length(); ++cursor) {
    char c = json[cursor];
    if (c == '"') {
      return true;
    }
    if (c != '\\') {
      value += c;
      continue;
    }
    if (++cursor >= json.length()) {
      return false;
    }
    switch (json[cursor]) {
      case '"': value += '"'; break;
      case '\\': value += '\\'; break;
      case '/': value += '/'; break;
      case 'b': value += '\b'; break;
      case 'f': value += '\f'; break;
      case 'n': value += '\n'; break;
      case 'r': value += '\r'; break;
      case 't': value += '\t'; break;
      default: return false;
    }
  }
  return false;
}

bool extractJsonString(const String &json, const char *key, String &value) {
  size_t offset = 0;
  return findJsonValue(json, key, offset) && readJsonStringAt(json, offset, value);
}

bool extractJsonStringAlias(const String &json,
                            const char *shortKey,
                            const char *longKey,
                            String &value) {
  return extractJsonString(json, shortKey, value) || extractJsonString(json, longKey, value);
}

bool readJsonUnsignedAt(const String &json, size_t offset, uint64_t &value) {
  if (offset >= json.length() || json[offset] < '0' || json[offset] > '9') {
    return false;
  }
  uint64_t parsed = 0;
  size_t cursor = offset;
  while (cursor < json.length() && json[cursor] >= '0' && json[cursor] <= '9') {
    const uint8_t digit = static_cast<uint8_t>(json[cursor] - '0');
    if (parsed > (UINT64_MAX - digit) / 10) {
      return false;
    }
    parsed = parsed * 10 + digit;
    ++cursor;
  }
  value = parsed;
  return true;
}

bool extractJsonUnsigned(const String &json, const char *key, uint64_t &value) {
  size_t offset = 0;
  return findJsonValue(json, key, offset) && readJsonUnsignedAt(json, offset, value);
}

bool extractJsonUnsignedAlias(const String &json,
                              const char *shortKey,
                              const char *longKey,
                              uint64_t &value) {
  return extractJsonUnsigned(json, shortKey, value) || extractJsonUnsigned(json, longKey, value);
}

bool extractJsonObject(const String &json, const char *key, String &object) {
  size_t offset = 0;
  if (!findJsonValue(json, key, offset) || offset >= json.length() || json[offset] != '{') {
    return false;
  }
  int depth = 0;
  bool inString = false;
  bool escaped = false;
  for (size_t cursor = offset; cursor < json.length(); ++cursor) {
    const char c = json[cursor];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        inString = false;
      }
      continue;
    }
    if (c == '"') {
      inString = true;
    } else if (c == '{') {
      ++depth;
    } else if (c == '}' && --depth == 0) {
      object = json.substring(offset, cursor + 1);
      return true;
    }
  }
  return false;
}

bool safeCanonicalValue(const String &value, size_t maxLength) {
  return value.length() > 0 && value.length() <= maxLength &&
         value.indexOf('\r') < 0 && value.indexOf('\n') < 0;
}

bool parseSemver(const String &version, uint32_t parts[3]) {
  size_t cursor = 0;
  for (uint8_t index = 0; index < 3; ++index) {
    if (cursor >= version.length()) {
      return false;
    }
    uint64_t value = 0;
    size_t digits = 0;
    while (cursor < version.length() && version[cursor] >= '0' && version[cursor] <= '9') {
      value = value * 10 + static_cast<uint8_t>(version[cursor] - '0');
      if (value > UINT32_MAX) {
        return false;
      }
      ++cursor;
      ++digits;
    }
    if (digits == 0) {
      return false;
    }
    parts[index] = static_cast<uint32_t>(value);
    if (index < 2) {
      if (cursor >= version.length() || version[cursor] != '.') {
        return false;
      }
      ++cursor;
    }
  }
  return cursor == version.length();
}

int compareSemver(const String &left, const String &right) {
  uint32_t a[3] = {0};
  uint32_t b[3] = {0};
  if (!parseSemver(left, a) || !parseSemver(right, b)) {
    return INT_MIN;
  }
  for (uint8_t index = 0; index < 3; ++index) {
    if (a[index] < b[index]) return -1;
    if (a[index] > b[index]) return 1;
  }
  return 0;
}

bool isLowerHexSha256(const String &value) {
  if (value.length() != 64) {
    return false;
  }
  for (size_t index = 0; index < value.length(); ++index) {
    const char c = value[index];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
      return false;
    }
  }
  return true;
}

bool parseDecimalSlice(const String &value, size_t start, size_t end, size_t &parsed) {
  if (start >= end || end > value.length()) {
    return false;
  }
  uint64_t result = 0;
  for (size_t index = start; index < end; ++index) {
    const char c = value[index];
    if (c < '0' || c > '9') {
      return false;
    }
    const uint8_t digit = static_cast<uint8_t>(c - '0');
    if (result > (SIZE_MAX - digit) / 10) {
      return false;
    }
    result = result * 10 + digit;
  }
  parsed = static_cast<size_t>(result);
  return true;
}

bool validContentRange(const String &header, size_t expectedStart, size_t expectedTotal) {
  // Resumed downloads must be an exact slice of the same signed artifact:
  // bytes <received>-<total-1>/<total>
  if (!header.startsWith("bytes ")) {
    return false;
  }
  const int dash = header.indexOf('-', 6);
  const int slash = dash >= 0 ? header.indexOf('/', dash + 1) : -1;
  if (dash < 0 || slash < 0 || header.indexOf(' ', 6) >= 0) {
    return false;
  }
  size_t start = 0;
  size_t end = 0;
  size_t total = 0;
  if (!parseDecimalSlice(header, 6, static_cast<size_t>(dash), start) ||
      !parseDecimalSlice(header, static_cast<size_t>(dash + 1), static_cast<size_t>(slash), end) ||
      !parseDecimalSlice(header, static_cast<size_t>(slash + 1), header.length(), total)) {
    return false;
  }
  return start == expectedStart && total == expectedTotal && end == expectedTotal - 1 &&
         start <= end;
}

String bytesToLowerHex(const uint8_t *bytes, size_t length) {
  static constexpr char kHex[] = "0123456789abcdef";
  String result;
  result.reserve(length * 2);
  for (size_t index = 0; index < length; ++index) {
    result += kHex[(bytes[index] >> 4) & 0x0f];
    result += kHex[bytes[index] & 0x0f];
  }
  return result;
}

String unsignedDecimal(uint64_t value) {
  char buffer[24];
  snprintf(buffer, sizeof(buffer), "%llu", static_cast<unsigned long long>(value));
  return String(buffer);
}

bool decodeBase64(const String &encoded, std::vector<uint8_t> &decoded) {
  if (encoded.length() == 0 || encoded.length() > 4096) {
    return false;
  }
  decoded.assign(encoded.length() + 1, 0);
  size_t decodedLength = 0;
  const int result = mbedtls_base64_decode(decoded.data(), decoded.size(), &decodedLength,
                                           reinterpret_cast<const unsigned char *>(encoded.c_str()),
                                           encoded.length());
  if (result != 0 || decodedLength == 0) {
    decoded.clear();
    return false;
  }
  decoded.resize(decodedLength);
  return true;
}

uint32_t persistedSecurityCounter() {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, true)) {
    return DragonRadarFirmware::kSecurityCounter;
  }
  const uint32_t stored = preferences.getUInt("security", DragonRadarFirmware::kSecurityCounter);
  preferences.end();
  return max(stored, DragonRadarFirmware::kSecurityCounter);
}

}  // namespace

const char *phaseText(Phase phase) {
  switch (phase) {
    case Phase::Idle: return "idle";
    case Phase::Validating: return "checking";
    case Phase::Downloading: return "downloading";
    case Phase::Verifying: return "verifying";
    case Phase::Rebooting: return "rebooting";
    case Phase::PendingVerify: return "pending";
    case Phase::Success: return "success";
    case Phase::Error: return "error";
    case Phase::RolledBack: return "rollback";
    case Phase::Cancelled: return "cancelled";
    default: return "error";
  }
}

void Manager::begin() {
  if (!mutex_) {
    mutex_ = xSemaphoreCreateMutex();
  }
  bootStartedMs_ = millis();
  loadBootState();
}

void Manager::loadBootState() {
  const esp_partition_t *running = esp_ota_get_running_partition();
  esp_ota_img_states_t state = ESP_OTA_IMG_UNDEFINED;
  const bool pendingState = running &&
                            esp_ota_get_state_partition(running, &state) == ESP_OK &&
                            state == ESP_OTA_IMG_PENDING_VERIFY;

  Preferences preferences;
  bool hasPendingRecord = false;
  String targetVersion;
  uint32_t targetBuild = 0;
  uint32_t targetSecurity = 0;
  if (preferences.begin(kPreferencesNamespace, true)) {
    hasPendingRecord = preferences.getBool("pending", false);
    targetVersion = preferences.getString("pVersion", "");
    targetBuild = preferences.getUInt("pBuild", 0);
    targetSecurity = preferences.getUInt("pSecurity", 0);
    preferences.end();
  }

  if (pendingState) {
    pendingBootVerify_ = true;
    {
      LockGuard lock(mutex_);
      status_.phase = Phase::PendingVerify;
      status_.progress = 100;
      status_.targetVersion = targetVersion;
      status_.targetBuild = targetBuild;
      status_.updatedMs = millis();
    }
    if (!hasPendingRecord ||
        targetVersion != DragonRadarFirmware::kVersion ||
        targetBuild != DragonRadarFirmware::kBuild ||
        targetSecurity != DragonRadarFirmware::kSecurityCounter) {
      rollbackRunningImage("boot_mismatch");
    }
    return;
  }

  if (hasPendingRecord) {
    clearPendingUpdate();
    LockGuard lock(mutex_);
    const bool runningMatchesPending =
        targetVersion == DragonRadarFirmware::kVersion &&
        targetBuild == DragonRadarFirmware::kBuild &&
        targetSecurity == DragonRadarFirmware::kSecurityCounter;
    status_.phase = runningMatchesPending ? Phase::Success : Phase::RolledBack;
    status_.progress = runningMatchesPending ? 100 : 0;
    status_.targetVersion = targetVersion;
    status_.targetBuild = targetBuild;
    status_.error = runningMatchesPending ? "" : "rollback";
    status_.updatedMs = millis();
  }
}

void Manager::setBootHealth(bool displayReady, bool bleReady) {
  displayReady_ = displayReady;
  bleReady_ = bleReady;
  if (displayReady_ && bleReady_ && healthStableSinceMs_ == 0) {
    healthStableSinceMs_ = millis();
  } else if (!displayReady_ || !bleReady_) {
    healthStableSinceMs_ = 0;
  }
}

void Manager::tick() {
  if (!pendingBootVerify_) {
    return;
  }
  const uint32_t now = millis();
  if (displayReady_ && bleReady_ && healthStableSinceMs_ > 0 &&
      now - healthStableSinceMs_ >= kBootHealthStableMs) {
    markRunningImageValid();
    return;
  }
  if (now - bootStartedMs_ >= kBootHealthTimeoutMs) {
    rollbackRunningImage("boot_timeout");
  }
}

void Manager::markRunningImageValid() {
  if (esp_ota_mark_app_valid_cancel_rollback() != ESP_OK) {
    rollbackRunningImage("confirm_failed");
    return;
  }
  Preferences preferences;
  if (preferences.begin(kPreferencesNamespace, false)) {
    preferences.putUInt("security", DragonRadarFirmware::kSecurityCounter);
    preferences.putString("lastVersion", DragonRadarFirmware::kVersion);
    preferences.putUInt("lastBuild", DragonRadarFirmware::kBuild);
    preferences.putBool("pending", false);
    preferences.end();
  }
  pendingBootVerify_ = false;
  setPhase(Phase::Success);
}

void Manager::rollbackRunningImage(const String &reason) {
  fail(reason);
  delay(120);
  esp_ota_mark_app_invalid_rollback_and_reboot();
}

bool Manager::handleControlJson(const String &json,
                                bool paired,
                                int batteryPercent,
                                bool charging,
                                bool pttActive,
                                bool wifiConnected,
                                const String &deviceToken,
                                const String &expectedHttpApiBase) {
  String action;
  Manifest manifest;
  String error;
  if (!parseControl(json, action, manifest, error)) {
    fail(error);
    return false;
  }
  if (action == "status") {
    return true;
  }
  if (!paired) {
    fail("not_paired");
    return false;
  }
  if (action == "cancel") {
    cancel();
    return true;
  }
  if (action != "start" && action != "retry") {
    fail("bad_action");
    return false;
  }
  if (active() || pendingBootVerify_) {
    return false;
  }
  if ((!charging && batteryPercent < 30) || batteryPercent < -1) {
    fail("battery");
    return false;
  }
  if (batteryPercent < 0 && !charging) {
    fail("battery_unknown");
    return false;
  }
  if (pttActive) {
    fail("ptt");
    return false;
  }
  if (!wifiConnected) {
    fail("wifi");
    return false;
  }
  if (deviceToken.length() == 0) {
    fail("auth");
    return false;
  }

  setPhase(Phase::Validating);
  if (!validateManifest(manifest, expectedHttpApiBase, error)) {
    fail(error);
    return false;
  }
  return startTask(manifest, deviceToken);
}

bool Manager::parseControl(const String &json,
                           String &action,
                           Manifest &manifest,
                           String &error) const {
  if (json.length() == 0 || json.length() > kControlMaxBytes) {
    error = "control_size";
    return false;
  }
  if (!extractJsonStringAlias(json, "a", "action", action)) {
    error = "bad_action";
    return false;
  }
  if (action == "status" || action == "cancel") {
    return true;
  }

  String body;
  if (!extractJsonObject(json, "m", body) && !extractJsonObject(json, "manifest", body)) {
    error = "manifest_missing";
    return false;
  }

  uint64_t schema = 0;
  uint64_t build = 0;
  uint64_t securityCounter = 0;
  uint64_t size = 0;
  if (!extractJsonUnsignedAlias(body, "s", "schema", schema) || schema > UINT32_MAX ||
      !extractJsonStringAlias(body, "p", "product", manifest.product) ||
      !extractJsonStringAlias(body, "h", "hardware", manifest.hardware) ||
      !extractJsonStringAlias(body, "v", "version", manifest.version) ||
      !extractJsonUnsignedAlias(body, "b", "build", build) || build > UINT32_MAX ||
      !extractJsonStringAlias(body, "min", "minimum_version", manifest.minimumVersion) ||
      !extractJsonUnsignedAlias(body, "c", "security_counter", securityCounter) ||
      securityCounter > UINT32_MAX ||
      !extractJsonUnsignedAlias(body, "z", "size", size) || size > SIZE_MAX ||
      !extractJsonStringAlias(body, "sha", "sha256", manifest.sha256) ||
      !extractJsonStringAlias(body, "alg", "signature_algorithm", manifest.signatureAlgorithm) ||
      !extractJsonStringAlias(body, "kid", "key_id", manifest.keyId) ||
      !extractJsonStringAlias(body, "sig", "signature", manifest.signatureBase64) ||
      !extractJsonStringAlias(body, "url", "artifact_url", manifest.artifactUrl)) {
    error = "manifest_fields";
    return false;
  }
  manifest.schema = static_cast<uint32_t>(schema);
  manifest.build = static_cast<uint32_t>(build);
  manifest.securityCounter = static_cast<uint32_t>(securityCounter);
  manifest.size = static_cast<size_t>(size);
  return true;
}

bool Manager::validateManifest(const Manifest &manifest,
                               const String &expectedHttpApiBase,
                               String &error) const {
  if (manifest.schema != 1) {
    error = "schema";
    return false;
  }
  if (manifest.product != DragonRadarFirmware::kProduct) {
    error = "product";
    return false;
  }
  if (manifest.hardware != DragonRadarFirmware::kHardware) {
    error = "hardware";
    return false;
  }
  if (!safeCanonicalValue(manifest.version, 32) ||
      !safeCanonicalValue(manifest.minimumVersion, 32) ||
      compareSemver(manifest.version, DragonRadarFirmware::kVersion) == INT_MIN ||
      compareSemver(manifest.minimumVersion, DragonRadarFirmware::kVersion) == INT_MIN) {
    error = "version";
    return false;
  }
  if (compareSemver(DragonRadarFirmware::kVersion, manifest.minimumVersion) < 0) {
    error = "bootstrap";
    return false;
  }
  if (compareSemver(manifest.version, manifest.minimumVersion) < 0) {
    error = "version_floor";
    return false;
  }
  if (compareSemver(manifest.version, DragonRadarFirmware::kVersion) < 0 ||
      manifest.build <= DragonRadarFirmware::kBuild) {
    error = "downgrade";
    return false;
  }
  if (manifest.securityCounter < 1 ||
      manifest.securityCounter < persistedSecurityCounter()) {
    error = "security";
    return false;
  }
  if (manifest.size == 0 || !isLowerHexSha256(manifest.sha256)) {
    error = "image";
    return false;
  }
  const esp_partition_t *next = esp_ota_get_next_update_partition(nullptr);
  if (!next || manifest.size > next->size) {
    error = "no_slot";
    return false;
  }
  if (manifest.signatureAlgorithm != DragonRadarOtaTrust::kSignatureAlgorithm ||
      manifest.keyId != DragonRadarOtaTrust::kSigningKeyId) {
    error = "signing_key";
    return false;
  }
  bool secure = false;
  if (!urlMatchesProvisionedOrigin(manifest.artifactUrl, expectedHttpApiBase, secure, error)) {
    return false;
  }
  if (secure && strlen(DragonRadarFirmware::kOtaRootCaPemBase64) == 0) {
    error = "no_ca";
    return false;
  }
  if (!verifyManifestSignature(manifest)) {
    error = "signature";
    return false;
  }
  return true;
}

String Manager::canonicalManifest(const Manifest &manifest) const {
  String canonical = "dragon-radar-ota-v1";
  canonical += "\nschema=" + unsignedDecimal(manifest.schema);
  canonical += "\nproduct=" + manifest.product;
  canonical += "\nhardware=" + manifest.hardware;
  canonical += "\nversion=" + manifest.version;
  canonical += "\nbuild=" + unsignedDecimal(manifest.build);
  canonical += "\nminimum_version=" + manifest.minimumVersion;
  canonical += "\nsecurity_counter=" + unsignedDecimal(manifest.securityCounter);
  canonical += "\nsize=" + unsignedDecimal(manifest.size);
  canonical += "\nsha256=" + manifest.sha256;
  return canonical;
}

bool Manager::verifyManifestSignature(const Manifest &manifest) const {
  if (!safeCanonicalValue(manifest.product, 31) ||
      !safeCanonicalValue(manifest.hardware, 63) ||
      manifest.signatureBase64.length() > 128) {
    return false;
  }
  std::vector<uint8_t> signature;
  if (!decodeBase64(manifest.signatureBase64, signature)) {
    return false;
  }
  const String canonical = canonicalManifest(manifest);
  uint8_t digest[32] = {0};
  if (mbedtls_sha256(reinterpret_cast<const unsigned char *>(canonical.c_str()),
                     canonical.length(), digest, 0) != 0) {
    return false;
  }

  mbedtls_pk_context publicKey;
  mbedtls_pk_init(&publicKey);
  const int parseResult = mbedtls_pk_parse_public_key(
      &publicKey,
      reinterpret_cast<const unsigned char *>(DragonRadarOtaTrust::kSigningPublicKeyPem),
      strlen(DragonRadarOtaTrust::kSigningPublicKeyPem) + 1);
  const bool valid = parseResult == 0 &&
                     mbedtls_pk_can_do(&publicKey, MBEDTLS_PK_ECDSA) &&
                     mbedtls_pk_verify(&publicKey, MBEDTLS_MD_SHA256, digest, sizeof(digest),
                                       signature.data(), signature.size()) == 0;
  mbedtls_pk_free(&publicKey);
  return valid;
}

bool Manager::urlAllowed(const String &url, bool &secure) const {
  ParsedHttpUrl parsed;
  if (!parseHttpUrl(url, DragonRadarFirmware::kAllowDevelopmentHttp, parsed) ||
      !validArtifactPath(parsed.path)) {
    return false;
  }
  secure = parsed.secure;
  return true;
}

bool Manager::urlMatchesProvisionedOrigin(const String &url,
                                          const String &expectedHttpApiBase,
                                          bool &secure,
                                          String &error) const {
  if (expectedHttpApiBase.length() == 0) {
    error = "origin_unconfigured";
    return false;
  }
  ParsedHttpUrl artifact;
  if (!parseHttpUrl(url, DragonRadarFirmware::kAllowDevelopmentHttp, artifact)) {
    error = "url_scheme";
    return false;
  }
  if (!validArtifactPath(artifact.path)) {
    error = "artifact_path";
    return false;
  }
  ParsedHttpUrl expected;
  if (!parseHttpUrl(expectedHttpApiBase, DragonRadarFirmware::kAllowDevelopmentHttp, expected)) {
    error = "origin_invalid";
    return false;
  }
  if (artifact.secure != expected.secure || artifact.host != expected.host ||
      artifact.port != expected.port) {
    error = "origin_mismatch";
    return false;
  }
  secure = artifact.secure;
  return true;
}

bool Manager::decodeRootCa(String &pem) const {
  const String encoded = DragonRadarFirmware::kOtaRootCaPemBase64;
  std::vector<uint8_t> decoded;
  if (!decodeBase64(encoded, decoded)) {
    return false;
  }
  decoded.push_back(0);
  pem = reinterpret_cast<const char *>(decoded.data());
  return pem.startsWith("-----BEGIN CERTIFICATE-----") &&
         pem.indexOf("-----END CERTIFICATE-----") > 0;
}

bool Manager::startTask(const Manifest &manifest, const String &deviceToken) {
  {
    LockGuard lock(mutex_);
    manifest_ = manifest;
    authorizationToken_ = deviceToken;
    status_.targetVersion = manifest.version;
    status_.targetBuild = manifest.build;
    status_.totalBytes = manifest.size;
    status_.receivedBytes = 0;
    status_.progress = 0;
    status_.error = "";
    status_.updatedMs = millis();
    cancelRequested_ = false;
  }
  const BaseType_t result = xTaskCreate(taskThunk, "radar-ota", kOtaTaskStackBytes, this,
                                        kOtaTaskPriority, &taskHandle_);
  if (result != pdPASS) {
    taskHandle_ = nullptr;
    fail("task");
    return false;
  }
  return true;
}

void Manager::taskThunk(void *argument) {
  auto *manager = static_cast<Manager *>(argument);
  manager->runDownloadTask();
  manager->taskHandle_ = nullptr;
  vTaskDelete(nullptr);
}

void Manager::runDownloadTask() {
  Manifest manifest;
  String deviceToken;
  {
    LockGuard lock(mutex_);
    manifest = manifest_;
    deviceToken = authorizationToken_;
  }

  bool secure = false;
  if (!urlAllowed(manifest.artifactUrl, secure)) {
    fail("url_scheme");
    return;
  }

  String rootCa;
  if (secure) {
    if (time(nullptr) < kMinimumTrustedEpoch) {
      configTime(0, 0, "time.cloudflare.com", "pool.ntp.org", "time.google.com");
      const uint32_t syncStartedMs = millis();
      while (time(nullptr) < kMinimumTrustedEpoch &&
             millis() - syncStartedMs < kTimeSyncTimeoutMs &&
             !cancelRequested_) {
        vTaskDelay(pdMS_TO_TICKS(100));
      }
      if (cancelRequested_) {
        setPhase(Phase::Cancelled, "cancelled");
        return;
      }
      if (time(nullptr) < kMinimumTrustedEpoch) {
        fail("time_sync");
        return;
      }
    }
    if (!decodeRootCa(rootCa)) {
      fail("no_ca");
      return;
    }
  }
  if (!Update.begin(manifest.size, U_FLASH)) {
    fail(Update.getError() == UPDATE_ERROR_NO_PARTITION ? "no_slot" : "update_begin");
    return;
  }

  mbedtls_sha256_context sha;
  mbedtls_sha256_init(&sha);
  if (mbedtls_sha256_starts(&sha, 0) != 0) {
    Update.abort();
    mbedtls_sha256_free(&sha);
    fail("sha_init");
    return;
  }

  setPhase(Phase::Downloading);
  std::unique_ptr<uint8_t[]> buffer(new (std::nothrow) uint8_t[kDownloadBufferBytes]);
  if (!buffer) {
    Update.abort();
    mbedtls_sha256_free(&sha);
    fail("memory");
    return;
  }

  size_t received = 0;
  uint8_t consecutiveNoProgressFailures = 0;
  uint8_t progressingResumeSessions = 0;
  while (received < manifest.size && !cancelRequested_) {
    std::unique_ptr<NetworkClient> client;
    if (secure) {
      auto secureClient = std::make_unique<NetworkClientSecure>();
      secureClient->setCACert(rootCa.c_str());
      secureClient->setTimeout(kDownloadIdleTimeoutMs);
      client = std::move(secureClient);
    } else {
      client = std::make_unique<NetworkClient>();
      client->setTimeout(kDownloadIdleTimeoutMs);
    }

    HTTPClient http;
    http.setConnectTimeout(15000);
    http.setTimeout(kDownloadIdleTimeoutMs);
    http.setFollowRedirects(HTTPC_DISABLE_FOLLOW_REDIRECTS);
    const char *responseHeaders[] = {"Content-Range"};
    http.collectHeaders(responseHeaders, 1);
    if (!http.begin(*client, manifest.artifactUrl)) {
      http.end();
      if (consecutiveNoProgressFailures++ >=
          kDownloadConsecutiveNoProgressAttempts) {
        Update.abort();
        mbedtls_sha256_free(&sha);
        fail(received > 0 ? "resume_exhausted" : "download_exhausted");
        return;
      }
      vTaskDelay(pdMS_TO_TICKS(kDownloadReconnectDelayMs));
      continue;
    }
    http.addHeader("Authorization", String("Bearer ") + deviceToken, true, true);
    http.addHeader("Accept", "application/octet-stream");
    if (received > 0) {
      http.addHeader("Range", String("bytes=") + unsignedDecimal(received) + "-");
    }

    const int responseCode = http.GET();
    if (responseCode < 0) {
      http.end();
      if (consecutiveNoProgressFailures++ >=
          kDownloadConsecutiveNoProgressAttempts) {
        Update.abort();
        mbedtls_sha256_free(&sha);
        fail(received > 0 ? "resume_exhausted" : "download_exhausted");
        return;
      }
      vTaskDelay(pdMS_TO_TICKS(kDownloadReconnectDelayMs));
      continue;
    }
    const int expectedCode = received == 0 ? HTTP_CODE_OK : HTTP_CODE_PARTIAL_CONTENT;
    if (responseCode != expectedCode) {
      const bool redirect = responseCode >= 300 && responseCode < 400;
      http.end();
      Update.abort();
      mbedtls_sha256_free(&sha);
      fail(redirect ? "redirect" : (received == 0 ? "http_status" : "range_status"));
      return;
    }

    const size_t remaining = manifest.size - received;
    const int contentLength = http.getSize();
    if (contentLength <= 0 || static_cast<size_t>(contentLength) != remaining) {
      http.end();
      Update.abort();
      mbedtls_sha256_free(&sha);
      fail(received == 0 ? "content_length" : "range_length");
      return;
    }
    if (received > 0 && !validContentRange(http.header("Content-Range"), received, manifest.size)) {
      http.end();
      Update.abort();
      mbedtls_sha256_free(&sha);
      fail("range_mismatch");
      return;
    }

    NetworkClient *stream = http.getStreamPtr();
    const size_t sessionStartedAt = received;
    uint32_t lastDataMs = millis();
    while (received < manifest.size && !cancelRequested_) {
      const int available = stream ? stream->available() : 0;
      if (available <= 0) {
        if (!http.connected() || millis() - lastDataMs > kDownloadIdleTimeoutMs) {
          break;
        }
        vTaskDelay(pdMS_TO_TICKS(10));
        continue;
      }
      const size_t wanted = min<size_t>(
          min<size_t>(static_cast<size_t>(available), kDownloadBufferBytes),
          manifest.size - received);
      const int count = stream->read(buffer.get(), wanted);
      if (count <= 0) {
        break;
      }
      lastDataMs = millis();
      const size_t written = static_cast<size_t>(count);
      // Update and SHA advance together. A reconnect starts exactly at this
      // committed offset and keeps both contexts alive.
      if (Update.write(buffer.get(), written) != written ||
          mbedtls_sha256_update(&sha, buffer.get(), written) != 0) {
        Update.abort();
        http.end();
        mbedtls_sha256_free(&sha);
        fail("write");
        return;
      }
      received += written;
      setProgress(received, manifest.size);
    }
    http.end();

    if (received < manifest.size && !cancelRequested_) {
      const bool madeProgress = received > sessionStartedAt;
      if (madeProgress) {
        consecutiveNoProgressFailures = 0;
        if (progressingResumeSessions++ >= kDownloadMaxProgressingResumeSessions) {
          Update.abort();
          mbedtls_sha256_free(&sha);
          fail("resume_exhausted");
          return;
        }
      } else if (consecutiveNoProgressFailures++ >=
                 kDownloadConsecutiveNoProgressAttempts) {
        Update.abort();
        mbedtls_sha256_free(&sha);
        fail(received > 0 ? "resume_exhausted" : "download_exhausted");
        return;
      }
      vTaskDelay(pdMS_TO_TICKS(kDownloadReconnectDelayMs));
    }
  }

  if (cancelRequested_) {
    Update.abort();
    mbedtls_sha256_free(&sha);
    setPhase(Phase::Cancelled, "cancelled");
    return;
  }
  if (received != manifest.size) {
    Update.abort();
    mbedtls_sha256_free(&sha);
    fail("download");
    return;
  }

  setPhase(Phase::Verifying);
  uint8_t digest[32] = {0};
  if (mbedtls_sha256_finish(&sha, digest) != 0) {
    Update.abort();
    mbedtls_sha256_free(&sha);
    fail("sha_finish");
    return;
  }
  mbedtls_sha256_free(&sha);
  if (bytesToLowerHex(digest, sizeof(digest)) != manifest.sha256) {
    Update.abort();
    fail("sha256");
    return;
  }

  if (!savePendingUpdate(manifest)) {
    Update.abort();
    fail("nvs_pending");
    return;
  }
  if (!Update.end() || !Update.isFinished()) {
    clearPendingUpdate();
    fail("activate");
    return;
  }

  setProgress(manifest.size, manifest.size);
  setPhase(Phase::Rebooting);
  delay(1200);
  ESP.restart();
}

bool Manager::savePendingUpdate(const Manifest &manifest) {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, false)) {
    return false;
  }
  const bool saved = preferences.putString("pVersion", manifest.version) == manifest.version.length() &&
                     preferences.putUInt("pBuild", manifest.build) == sizeof(uint32_t) &&
                     preferences.putUInt("pSecurity", manifest.securityCounter) == sizeof(uint32_t) &&
                     preferences.putBool("pending", true) == sizeof(uint8_t);
  preferences.end();
  if (!saved) {
    clearPendingUpdate();
  }
  return saved;
}

void Manager::clearPendingUpdate() {
  Preferences preferences;
  if (!preferences.begin(kPreferencesNamespace, false)) {
    return;
  }
  preferences.putBool("pending", false);
  preferences.remove("pVersion");
  preferences.remove("pBuild");
  preferences.remove("pSecurity");
  preferences.end();
}

void Manager::cancel() {
  if (!active()) {
    return;
  }
  cancelRequested_ = true;
}

void Manager::fail(const String &error) {
  setPhase(Phase::Error, error);
}

void Manager::setPhase(Phase phase, const String &error) {
  LockGuard lock(mutex_);
  status_.phase = phase;
  status_.error = error;
  status_.updatedMs = millis();
}

void Manager::setProgress(size_t received, size_t total) {
  LockGuard lock(mutex_);
  status_.receivedBytes = received;
  status_.totalBytes = total;
  status_.progress = total > 0 ? static_cast<uint8_t>(min<size_t>(100, (received * 100) / total)) : 0;
  status_.updatedMs = millis();
}

Snapshot Manager::snapshot() const {
  LockGuard lock(mutex_);
  return status_;
}

String Manager::statusJson() const {
  const Snapshot current = snapshot();
  String json = "{\"v\":1,\"fw\":\"";
  json += DragonRadarFirmware::kVersion;
  json += "\",\"b\":" + unsignedDecimal(DragonRadarFirmware::kBuild);
  json += ",\"s\":\"" + String(DragonRadarOta::phaseText(current.phase)) + "\"";
  json += ",\"p\":" + unsignedDecimal(current.progress);
  if (current.phase == Phase::Downloading) {
    json += ",\"rx\":" + unsignedDecimal(current.receivedBytes);
    json += ",\"z\":" + unsignedDecimal(current.totalBytes);
  }
  if (current.targetVersion.length() > 0) {
    json += ",\"tv\":\"" + current.targetVersion + "\"";
    json += ",\"tb\":" + unsignedDecimal(current.targetBuild);
  }
  if (current.error.length() > 0) {
    json += ",\"e\":\"" + current.error + "\"";
  }
  json += "}";
  return json;
}

bool Manager::active() const {
  const Phase phase = snapshot().phase;
  return phase == Phase::Validating || phase == Phase::Downloading ||
         phase == Phase::Verifying || phase == Phase::Rebooting;
}

bool Manager::blocksPowerAndVoice() const {
  return active() || snapshot().phase == Phase::PendingVerify;
}

bool Manager::shouldShowOverlay() const {
  const Snapshot current = snapshot();
  if (current.phase == Phase::Validating || current.phase == Phase::Downloading ||
      current.phase == Phase::Verifying || current.phase == Phase::Rebooting ||
      current.phase == Phase::PendingVerify) {
    return true;
  }
  return current.phase != Phase::Idle && millis() - current.updatedMs < kTerminalOverlayMs;
}

const char *Manager::phaseText() const {
  return DragonRadarOta::phaseText(snapshot().phase);
}

}  // namespace DragonRadarOta
