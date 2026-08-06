#pragma once

#include <stdint.h>

namespace DragonRadarTouchHold {

inline bool shouldCarryConfirmationHold(bool confirmationActive,
                                        bool touchWasPressed,
                                        bool touchEventPending,
                                        uint8_t reportedPointCount,
                                        uint32_t lastPositivePointMs,
                                        uint32_t nowMs,
                                        uint32_t gapToleranceMs) {
  if (!confirmationActive || !touchWasPressed || touchEventPending ||
      reportedPointCount > 0 || lastPositivePointMs == 0) {
    return false;
  }
  return nowMs - lastPositivePointMs <= gapToleranceMs;
}

}  // namespace DragonRadarTouchHold
