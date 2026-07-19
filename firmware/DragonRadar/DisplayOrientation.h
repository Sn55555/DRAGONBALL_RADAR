#pragma once

#include <stdint.h>

namespace DragonRadarDisplayOrientation {

enum class ScreenDirection : uint8_t {
  SixOClock = 6,
  TwelveOClock = 12,
};

inline constexpr ScreenDirection sanitize(uint8_t stored) {
  return stored == static_cast<uint8_t>(ScreenDirection::TwelveOClock)
             ? ScreenDirection::TwelveOClock
             : ScreenDirection::SixOClock;
}

inline constexpr bool inverted(ScreenDirection direction) {
  return direction == ScreenDirection::TwelveOClock;
}

inline constexpr uint8_t persistedValue(ScreenDirection direction) {
  return static_cast<uint8_t>(direction);
}

inline constexpr int16_t clampTouchCoordinate(int16_t coordinate, int16_t extent) {
  return coordinate < 0 ? 0 : (coordinate >= extent ? extent - 1 : coordinate);
}

inline constexpr int16_t logicalTouchCoordinate(int16_t coordinate,
                                                int16_t extent,
                                                ScreenDirection direction) {
  const int16_t clamped = clampTouchCoordinate(coordinate, extent);
  return inverted(direction) ? static_cast<int16_t>(extent - 1 - clamped) : clamped;
}

}  // namespace DragonRadarDisplayOrientation
