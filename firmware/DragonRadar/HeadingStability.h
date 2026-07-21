#pragma once

#include <math.h>

namespace DragonRadarHeadingStability {

struct YawRateDecision {
  float rateDps = 0.0f;
  bool locked = false;
};

inline bool stationarySampleCandidate(float accelMagnitudeG,
                                      float correctedGyroMagnitudeDps,
                                      float correctedVerticalRateDps,
                                      bool gravityValid,
                                      float accelToleranceG,
                                      float gyroLimitDps,
                                      float verticalLimitDps) {
  if (!isfinite(accelMagnitudeG) ||
      !isfinite(correctedGyroMagnitudeDps) ||
      !isfinite(accelToleranceG) ||
      !isfinite(gyroLimitDps) ||
      !isfinite(verticalLimitDps) ||
      accelToleranceG < 0.0f ||
      gyroLimitDps < 0.0f ||
      verticalLimitDps < 0.0f) {
    return false;
  }
  if (fabsf(accelMagnitudeG - 1.0f) > accelToleranceG ||
      correctedGyroMagnitudeDps > gyroLimitDps) {
    return false;
  }
  return !gravityValid ||
         (isfinite(correctedVerticalRateDps) &&
          fabsf(correctedVerticalRateDps) <= verticalLimitDps);
}

// A six-axis IMU cannot observe absolute yaw while motionless. Once the
// existing acceleration/variance gates have proved that the radar is
// stationary, hold yaw instead of integrating the remaining zero-rate error.
// Motion clears stationaryCandidate before this function is called.
inline YawRateDecision stabilizedYawRate(float projectedRateDps,
                                         float stationaryMotionRateDps,
                                         bool stationaryVerified,
                                         bool stationaryCandidate,
                                         float stationaryLockLimitDps,
                                         float deadbandDps) {
  const bool finiteInputs =
      isfinite(projectedRateDps) &&
      isfinite(stationaryMotionRateDps) &&
      isfinite(stationaryLockLimitDps) &&
      isfinite(deadbandDps);
  if (!finiteInputs || stationaryLockLimitDps < 0.0f || deadbandDps < 0.0f) {
    return {};
  }

  const bool locked =
      stationaryVerified &&
      stationaryCandidate &&
      stationaryMotionRateDps <= stationaryLockLimitDps;
  if (locked || fabsf(projectedRateDps) < deadbandDps) {
    return {0.0f, locked};
  }
  return {projectedRateDps, false};
}

inline float integrateRelativeYaw(float headingDeg,
                                  float stabilizedRateDps,
                                  float dtS) {
  if (!isfinite(headingDeg) ||
      !isfinite(stabilizedRateDps) ||
      !isfinite(dtS) ||
      dtS <= 0.0f) {
    return headingDeg;
  }
  float wrapped = fmodf(headingDeg + stabilizedRateDps * dtS, 360.0f);
  if (wrapped < 0.0f) {
    wrapped += 360.0f;
  }
  return wrapped == 0.0f ? 0.0f : wrapped;
}

}  // namespace DragonRadarHeadingStability
