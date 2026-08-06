#include <cassert>
#include <cstdint>
#include <iostream>

#include "TouchHold.h"

int main() {
  using DragonRadarTouchHold::shouldCarryConfirmationHold;

  constexpr uint32_t kGapToleranceMs = 1250;

  assert(shouldCarryConfirmationHold(
      true, true, false, 0, 1000, 1800, kGapToleranceMs));
  assert(!shouldCarryConfirmationHold(
      true, true, true, 0, 1000, 1800, kGapToleranceMs));
  assert(!shouldCarryConfirmationHold(
      true, true, false, 1, 1000, 1800, kGapToleranceMs));
  assert(!shouldCarryConfirmationHold(
      true, true, false, 0, 1000, 2300, kGapToleranceMs));
  assert(!shouldCarryConfirmationHold(
      false, true, false, 0, 1000, 1800, kGapToleranceMs));
  assert(!shouldCarryConfirmationHold(
      true, false, false, 0, 1000, 1800, kGapToleranceMs));

  // Unsigned subtraction keeps the grace window correct across millis()
  // rollover as long as the interval is much smaller than UINT32_MAX.
  assert(shouldCarryConfirmationHold(
      true, true, false, 0, UINT32_MAX - 200, 300, kGapToleranceMs));

  std::cout << "touch-confirmation-hold-ok\n";
  return 0;
}
