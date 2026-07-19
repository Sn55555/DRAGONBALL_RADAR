#pragma once

#include <math.h>
#include <stdint.h>

namespace DragonRadarHeadingAlignment {

// Angles in this helper are finite degrees. Geographic bearings are clockwise
// from north; the radar's relative gyro yaw is counter-clockwise positive.
inline float wrap360(float degrees) {
  float wrapped = fmodf(degrees, 360.0f);
  if (wrapped < 0.0f) {
    wrapped += 360.0f;
  }
  // Canonicalize negative zero so diagnostics and tests show a stable 0.
  return wrapped == 0.0f ? 0.0f : wrapped;
}

// The user points the radar's physical zero/12-o'clock direction north, then
// captures the current relative yaw. The inverse yaw makes geographic north
// render at screen angle zero at that instant.
inline float northCalibrationOffsetDeg(float relativeYawDeg) {
  return wrap360(-relativeYawDeg);
}

inline float screenAngleDeg(float geographicBearingDeg,
                            float relativeYawDeg,
                            float offsetDeg) {
  return wrap360(geographicBearingDeg + relativeYawDeg + offsetDeg);
}

// A stored gyro bias is safe to reuse only when it was loaded from the
// validated persistence schema and both the saved and current sensor
// temperatures are known and close. Unknown temperature deliberately falls
// back to the stricter in-session stationary verification path.
inline bool persistedGyroBiasTrusted(bool biasValid,
                                     bool biasLoaded,
                                     bool currentTemperatureValid,
                                     float currentTemperatureC,
                                     bool biasTemperatureValid,
                                     float biasTemperatureC,
                                     float maxTemperatureDeltaC) {
  return biasValid && biasLoaded &&
         currentTemperatureValid && biasTemperatureValid &&
         isfinite(currentTemperatureC) && isfinite(biasTemperatureC) &&
         isfinite(maxTemperatureDeltaC) && maxTemperatureDeltaC >= 0.0f &&
         fabsf(currentTemperatureC - biasTemperatureC) <= maxTemperatureDeltaC;
}

// A sampling gap is a scheduler/sensor freshness problem, not proof that the
// user's manual north alignment is wrong. Skip integration across the missing
// interval, but keep the captured screen offset.
inline bool imuGapRequiresIntegrationReset(uint32_t gapMs,
                                           uint32_t maxIntegrationGapMs) {
  return gapMs > maxIntegrationGapMs;
}

// Only a sustained outage makes relative direction unavailable. The manual
// alignment offset is still retained so recovery is non-destructive and the
// user can choose whether to calibrate again.
inline bool imuGapRequiresRealignmentPrompt(uint32_t gapMs,
                                            uint32_t unavailableAfterMs) {
  return gapMs >= unavailableAfterMs;
}

}  // namespace DragonRadarHeadingAlignment
