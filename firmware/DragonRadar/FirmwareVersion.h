#pragma once

#include <stdint.h>

#ifndef DRAGON_RADAR_FW_VERSION
#define DRAGON_RADAR_FW_VERSION "1.0.11"
#endif

#ifndef DRAGON_RADAR_FW_BUILD
#define DRAGON_RADAR_FW_BUILD 13
#endif

#ifndef DRAGON_RADAR_FW_SECURITY_COUNTER
#define DRAGON_RADAR_FW_SECURITY_COUNTER 13
#endif

#ifndef DRAGON_RADAR_PRODUCT
#define DRAGON_RADAR_PRODUCT "dragon-radar"
#endif

#ifndef DRAGON_RADAR_HARDWARE
#define DRAGON_RADAR_HARDWARE "esp32-s3-touch-amoled-1.75c"
#endif

#ifndef DRAGON_RADAR_OTA_ROOT_CA_PEM_B64
#define DRAGON_RADAR_OTA_ROOT_CA_PEM_B64 ""
#endif

#ifndef DRAGON_RADAR_OTA_ALLOW_HTTP
#define DRAGON_RADAR_OTA_ALLOW_HTTP 0
#endif

#ifndef DRAGON_RADAR_RELEASE_BUILD
#define DRAGON_RADAR_RELEASE_BUILD 0
#endif

static_assert(DRAGON_RADAR_FW_BUILD >= 1, "DRAGON_RADAR_FW_BUILD must be >= 1");
static_assert(DRAGON_RADAR_FW_SECURITY_COUNTER >= 1,
              "DRAGON_RADAR_FW_SECURITY_COUNTER must be >= 1");
static_assert(DRAGON_RADAR_OTA_ALLOW_HTTP == 0 || DRAGON_RADAR_OTA_ALLOW_HTTP == 1,
              "DRAGON_RADAR_OTA_ALLOW_HTTP must be 0 or 1");
static_assert(DRAGON_RADAR_RELEASE_BUILD == 0 || DRAGON_RADAR_RELEASE_BUILD == 1,
              "DRAGON_RADAR_RELEASE_BUILD must be 0 or 1");
static_assert(!(DRAGON_RADAR_RELEASE_BUILD == 1 && DRAGON_RADAR_OTA_ALLOW_HTTP == 1),
              "release firmware must not allow insecure development transport");

namespace DragonRadarFirmware {

inline constexpr const char *kVersion = DRAGON_RADAR_FW_VERSION;
inline constexpr uint32_t kBuild = DRAGON_RADAR_FW_BUILD;
inline constexpr uint32_t kSecurityCounter = DRAGON_RADAR_FW_SECURITY_COUNTER;
inline constexpr const char *kProduct = DRAGON_RADAR_PRODUCT;
inline constexpr const char *kHardware = DRAGON_RADAR_HARDWARE;
inline constexpr const char *kOtaRootCaPemBase64 = DRAGON_RADAR_OTA_ROOT_CA_PEM_B64;
inline constexpr bool kAllowDevelopmentHttp = DRAGON_RADAR_OTA_ALLOW_HTTP == 1;
inline constexpr bool kReleaseBuild = DRAGON_RADAR_RELEASE_BUILD == 1;
inline constexpr bool kAllowInsecureRelay = !kReleaseBuild && kAllowDevelopmentHttp;

}  // namespace DragonRadarFirmware
