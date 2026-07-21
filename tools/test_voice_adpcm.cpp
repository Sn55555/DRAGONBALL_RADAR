#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>

#include "../firmware/DragonRadar/VoiceAdpcm.h"

int main() {
  constexpr size_t samplesPerFrame = 320;
  int16_t input[samplesPerFrame];
  for (size_t i = 0; i < samplesPerFrame; ++i) {
    input[i] = static_cast<int16_t>(12000.0 * sin(2.0 * 3.141592653589793 * 440.0 * i / 16000.0));
  }

  uint8_t packet[192];
  const size_t packetBytes = DragonRadarVoice::encodePacket(
      input, samplesPerFrame, 42,
      DragonRadarVoice::kFlagStart | DragonRadarVoice::kFlagVad,
      packet, sizeof(packet));
  assert(packetBytes == 173);

  int16_t decoded[samplesPerFrame];
  DragonRadarVoice::DecodedHeader header;
  assert(DragonRadarVoice::decodePacket(packet, packetBytes, decoded, samplesPerFrame, &header) == samplesPerFrame);
  assert(header.sequence == 42);
  assert((header.flags & DragonRadarVoice::kFlagStart) != 0);
  assert(decoded[0] == input[0]);

  uint64_t squaredError = 0;
  for (size_t i = 0; i < samplesPerFrame; ++i) {
    const int32_t error = static_cast<int32_t>(input[i]) - decoded[i];
    squaredError += static_cast<uint64_t>(error * error);
  }
  const double rmse = sqrt(static_cast<double>(squaredError) / samplesPerFrame);
  assert(rmse < 1800.0);
  printf("voice-adpcm packet=%zu bytes rmse=%.1f\n", packetBytes, rmse);
  return 0;
}
