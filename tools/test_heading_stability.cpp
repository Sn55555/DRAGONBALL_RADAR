#include <cmath>
#include <cstdio>

#include "HeadingStability.h"

namespace {

int failures = 0;

void expectNear(const char *label,
                float actual,
                float expected,
                float tolerance = 0.001f) {
  if (std::fabs(actual - expected) <= tolerance) {
    return;
  }
  std::fprintf(stderr,
               "heading-stability-test-failure: %s actual=%.6f expected=%.6f\n",
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
               "heading-stability-test-failure: %s actual=%s expected=%s\n",
               label,
               actual ? "true" : "false",
               expected ? "true" : "false");
  ++failures;
}

}  // namespace

int main() {
  using DragonRadarHeadingStability::integrateRelativeYaw;
  using DragonRadarHeadingStability::stationarySampleCandidate;
  using DragonRadarHeadingStability::stabilizedYawRate;

  constexpr float kLockLimitDps = 0.35f;
  constexpr float kDeadbandDps = 0.05f;

  expectBool("second-board vector noise remains a stationary candidate",
             stationarySampleCandidate(
                 1.092f, 0.80f, 0.16f, true, 0.10f, 1.0f, 0.35f),
             true);
  expectBool("real gravity-axis turn exits stationary candidate",
             stationarySampleCandidate(
                 1.092f, 0.80f, 0.50f, true, 0.10f, 1.0f, 0.35f),
             false);
  expectBool("handling acceleration exits stationary candidate",
             stationarySampleCandidate(
                 1.20f, 0.20f, 0.05f, true, 0.10f, 1.0f, 0.35f),
             false);
  expectBool("large tilt-axis rotation exits stationary candidate",
             stationarySampleCandidate(
                 1.00f, 2.0f, 0.05f, true, 0.10f, 1.0f, 0.35f),
             false);

  // Model the second board's residual error for thirty minutes. The first
  // 1.8 seconds are the strict stationary verification window; after that,
  // ZIYR must stop yaw from walking around the dial.
  float staticHeading = 0.0f;
  constexpr float kStaticResidualDps = 0.20f;
  constexpr float kDtS = 0.02f;
  constexpr int kVerificationSamples = 90;
  constexpr int kThirtyMinuteSamples = 90000;
  bool sawLock = false;
  for (int sample = 0; sample < kThirtyMinuteSamples; ++sample) {
    const bool stationaryVerified = sample >= kVerificationSamples;
    const auto decision = stabilizedYawRate(
        kStaticResidualDps,
        kStaticResidualDps,
        stationaryVerified,
        true,
        kLockLimitDps,
        kDeadbandDps);
    sawLock = sawLock || decision.locked;
    staticHeading = integrateRelativeYaw(staticHeading, decision.rateDps, kDtS);
  }
  expectBool("stationary yaw lock engages", sawLock, true);
  expectNear("thirty-minute static drift stays below half a degree",
             staticHeading,
             0.36f,
             0.01f);

  const auto noisyStatic = stabilizedYawRate(
      -0.08f, 0.11f, true, true, kLockLimitDps, kDeadbandDps);
  expectBool("verified noisy stationary sample remains locked",
             noisyStatic.locked,
             true);
  expectNear("verified noisy stationary rate is zero",
             noisyStatic.rateDps,
             0.0f);

  // A real turn breaks the stationary candidate and must remain responsive.
  float movingHeading = staticHeading;
  constexpr float kTurnRateDps = 12.0f;
  constexpr int kTurnSamples = 375;  // 7.5 seconds = 90 degrees
  for (int sample = 0; sample < kTurnSamples; ++sample) {
    const auto decision = stabilizedYawRate(
        kTurnRateDps,
        kTurnRateDps,
        false,
        false,
        kLockLimitDps,
        kDeadbandDps);
    expectBool("real turn is never locked", decision.locked, false);
    movingHeading = integrateRelativeYaw(movingHeading, decision.rateDps, kDtS);
  }
  expectNear("real ninety-degree turn remains visible",
             movingHeading,
             90.36f,
             0.02f);

  const auto deadband = stabilizedYawRate(
      0.04f, 0.40f, false, false, kLockLimitDps, kDeadbandDps);
  expectNear("unverified sub-deadband noise is suppressed",
             deadband.rateDps,
             0.0f);

  const auto invalid = stabilizedYawRate(
      NAN, 0.0f, true, true, kLockLimitDps, kDeadbandDps);
  expectBool("invalid sample fails closed", invalid.locked, false);
  expectNear("invalid sample cannot move heading", invalid.rateDps, 0.0f);

  if (failures != 0) {
    return 1;
  }
  std::puts("heading-stability-ok");
  return 0;
}
