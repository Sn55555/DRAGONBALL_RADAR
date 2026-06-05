#include <Arduino.h>
#include <BLEAdvertising.h>
#include <BLEDevice.h>

#ifndef DRAGON_BALL_INDEX
#define DRAGON_BALL_INDEX 1
#endif

#ifndef DRAGON_BALL_ADV_MIN_MS
#define DRAGON_BALL_ADV_MIN_MS 100
#endif

#ifndef DRAGON_BALL_ADV_MAX_MS
#define DRAGON_BALL_ADV_MAX_MS 200
#endif

static_assert(DRAGON_BALL_INDEX >= 1 && DRAGON_BALL_INDEX <= 7,
              "DRAGON_BALL_INDEX must be 1..7");
static_assert(DRAGON_BALL_ADV_MIN_MS >= 20, "DRAGON_BALL_ADV_MIN_MS must be >= 20");
static_assert(DRAGON_BALL_ADV_MAX_MS >= DRAGON_BALL_ADV_MIN_MS,
              "DRAGON_BALL_ADV_MAX_MS must be >= DRAGON_BALL_ADV_MIN_MS");
static_assert(DRAGON_BALL_ADV_MAX_MS <= 10240, "DRAGON_BALL_ADV_MAX_MS must be <= 10240");

namespace {

constexpr const char *kServiceUuid = "7d540001-f82d-4b2f-91c6-4f0f88aa5a11";

char beaconName[12];

constexpr uint16_t advMsToUnits(uint16_t ms) {
  return static_cast<uint16_t>((static_cast<uint32_t>(ms) * 8U + 4U) / 5U);
}

void startAdvertising() {
  snprintf(beaconName, sizeof(beaconName), "DBALL-%d", DRAGON_BALL_INDEX);

  BLEDevice::init(beaconName);
  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  BLEAdvertisementData advData;
  BLEAdvertisementData scanData;

  uint8_t payload[3] = {
      0x44,
      0x42,
      static_cast<uint8_t>(DRAGON_BALL_INDEX),
  };

  advData.setFlags(0x06);
  advData.setName(beaconName);
  advData.setManufacturerData(String(reinterpret_cast<char *>(payload), sizeof(payload)));
  scanData.setCompleteServices(BLEUUID(kServiceUuid));

  advertising->setAdvertisementData(advData);
  advertising->setScanResponseData(scanData);
  advertising->setMinInterval(advMsToUnits(DRAGON_BALL_ADV_MIN_MS));
  advertising->setMaxInterval(advMsToUnits(DRAGON_BALL_ADV_MAX_MS));
  advertising->start();
}

}  // namespace

void setup() {
  Serial.begin(115200);
  delay(200);
  startAdvertising();
  Serial.print("Advertising ");
  Serial.println(beaconName);
  Serial.print("Interval ");
  Serial.print(DRAGON_BALL_ADV_MIN_MS);
  Serial.print("-");
  Serial.print(DRAGON_BALL_ADV_MAX_MS);
  Serial.println(" ms");
}

void loop() {
  delay(1000);
}
