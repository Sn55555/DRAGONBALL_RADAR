#include <cmath>
#include <cstdio>

#include "HeadingAlignment.h"

namespace {

int failures = 0;

void expectNear(const char *label, float actual, float expected) {
  constexpr float kToleranceDeg = 0.001f;
  if (std::fabs(actual - expected) <= kToleranceDeg) {
    return;
  }

  std::fprintf(stderr,
               "heading-alignment-test-failure: %s actual=%.6f expected=%.6f\n",
               label,
               static_cast<double>(actual),
               static_cast<double>(expected));
  ++failures;
}

void expectBool(const char *label, bool actual, bool expected) {
  if (actual == expected) {
    return;
  }

  std::fprintf(stderr,
               "heading-alignment-test-failure: %s actual=%s expected=%s\n",
               label,
               actual ? "true" : "false",
               expected ? "true" : "false");
  ++failures;
}

}  // namespace

int main() {
  using DragonRadarHeadingAlignment::northCalibrationOffsetDeg;
  using DragonRadarHeadingAlignment::imuGapRequiresIntegrationReset;
  using DragonRadarHeadingAlignment::imuGapRequiresRealignmentPrompt;
  using DragonRadarHeadingAlignment::persistedGyroBiasTrusted;
  using DragonRadarHeadingAlignment::screenAngleDeg;
  using DragonRadarHeadingAlignment::wrap360;

  const float zeroYawOffset = northCalibrationOffsetDeg(0.0f);
  expectNear("zero-yaw north calibration offset", zeroYawOffset, 0.0f);
  expectNear("north points up",
             screenAngleDeg(0.0f, 0.0f, zeroYawOffset),
             0.0f);
  expectNear("east remains clockwise of north",
             screenAngleDeg(90.0f, 0.0f, zeroYawOffset),
             90.0f);
  expectNear("clockwise physical turn follows relative yaw convention",
             screenAngleDeg(0.0f, 330.0f, zeroYawOffset),
             330.0f);

  const float nonZeroYawOffset = northCalibrationOffsetDeg(20.0f);
  expectNear("nonzero-yaw calibration offset", nonZeroYawOffset, 340.0f);
  expectNear("nonzero-yaw north points up",
             screenAngleDeg(0.0f, 20.0f, nonZeroYawOffset),
             0.0f);
  expectNear("nonzero-yaw west remains west",
             screenAngleDeg(270.0f, 20.0f, nonZeroYawOffset),
             270.0f);

  expectNear("negative angle wraps", wrap360(-1.0f), 359.0f);
  expectNear("full turns canonicalize", wrap360(720.0f), 0.0f);

  expectBool("matching-temperature persisted bias is trusted",
             persistedGyroBiasTrusted(true, true, true, 28.0f,
                                      true, 24.0f, 6.0f),
             true);
  expectBool("temperature boundary is inclusive",
             persistedGyroBiasTrusted(true, true, true, 30.0f,
                                      true, 24.0f, 6.0f),
             true);
  expectBool("temperature mismatch rejects persisted bias",
             persistedGyroBiasTrusted(true, true, true, 30.1f,
                                      true, 24.0f, 6.0f),
             false);
  expectBool("unknown current temperature rejects persisted bias",
             persistedGyroBiasTrusted(true, true, false, 0.0f,
                                      true, 24.0f, 6.0f),
             false);
  expectBool("unloaded bias is never trusted",
             persistedGyroBiasTrusted(true, false, true, 24.0f,
                                      true, 24.0f, 6.0f),
             false);

  expectBool("200ms sample gap remains integrable",
             imuGapRequiresIntegrationReset(200, 200),
             false);
  expectBool("sample gap over 200ms resets integration anchor",
             imuGapRequiresIntegrationReset(201, 200),
             true);
  expectBool("short sample gap does not request realignment",
             imuGapRequiresRealignmentPrompt(4999, 5000),
             false);
  expectBool("five-second sample gap requests realignment",
             imuGapRequiresRealignmentPrompt(5000, 5000),
             true);

  if (failures != 0) {
    return 1;
  }

  std::puts("heading-alignment-math-ok");
  return 0;
}
