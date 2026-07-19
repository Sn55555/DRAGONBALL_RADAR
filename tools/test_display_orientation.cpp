#include <cstdio>
#include <cstdlib>

#include "DisplayOrientation.h"

namespace {

using DragonRadarDisplayOrientation::ScreenDirection;

void expectEqual(const char *label, int actual, int expected) {
  if (actual == expected) {
    return;
  }
  std::fprintf(stderr,
               "display-orientation-test-failure: %s actual=%d expected=%d\n",
               label,
               actual,
               expected);
  std::exit(1);
}

}  // namespace

int main() {
  using DragonRadarDisplayOrientation::inverted;
  using DragonRadarDisplayOrientation::logicalTouchCoordinate;
  using DragonRadarDisplayOrientation::persistedValue;
  using DragonRadarDisplayOrientation::sanitize;

  expectEqual("six persisted", persistedValue(ScreenDirection::SixOClock), 6);
  expectEqual("twelve persisted", persistedValue(ScreenDirection::TwelveOClock), 12);
  expectEqual("invalid storage falls back to six",
              persistedValue(sanitize(255)),
              6);
  expectEqual("stored twelve restores twelve",
              persistedValue(sanitize(12)),
              12);
  expectEqual("six is not inverted", inverted(ScreenDirection::SixOClock), false);
  expectEqual("twelve is inverted", inverted(ScreenDirection::TwelveOClock), true);
  expectEqual("six touch unchanged",
              logicalTouchCoordinate(40, 466, ScreenDirection::SixOClock),
              40);
  expectEqual("twelve touch x/y inverted",
              logicalTouchCoordinate(40, 466, ScreenDirection::TwelveOClock),
              425);
  expectEqual("lower bound clamps before inversion",
              logicalTouchCoordinate(-3, 466, ScreenDirection::TwelveOClock),
              465);
  expectEqual("upper bound clamps before inversion",
              logicalTouchCoordinate(466, 466, ScreenDirection::TwelveOClock),
              0);

  std::puts("display-orientation-math-ok");
  return 0;
}
