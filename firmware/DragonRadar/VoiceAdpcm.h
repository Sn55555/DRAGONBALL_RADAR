#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

namespace DragonRadarVoice {

constexpr uint8_t kPacketMagic0 = 'D';
constexpr uint8_t kPacketMagic1 = 'R';
constexpr uint8_t kPacketVersion = 1;
constexpr size_t kPacketHeaderBytes = 13;
constexpr uint8_t kFlagStart = 0x01;
constexpr uint8_t kFlagEnd = 0x02;
constexpr uint8_t kFlagVad = 0x04;

struct DecodedHeader {
  uint8_t flags = 0;
  uint32_t sequence = 0;
  int16_t predictor = 0;
  uint8_t stepIndex = 0;
  uint16_t sampleCount = 0;
};

inline int clampInt(int value, int minimum, int maximum) {
  return value < minimum ? minimum : (value > maximum ? maximum : value);
}

inline const int16_t *stepTable() {
  static constexpr int16_t table[89] = {
      7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
      34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130,
      143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449,
      494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411,
      1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026,
      4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
      11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623,
      27086, 29794, 32767};
  return table;
}

inline const int8_t *indexTable() {
  static constexpr int8_t table[16] = {
      -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8};
  return table;
}

inline uint8_t encodeNibble(int16_t sample, int &predictor, int &stepIndex) {
  const int step = stepTable()[stepIndex];
  int difference = static_cast<int>(sample) - predictor;
  uint8_t nibble = 0;
  if (difference < 0) {
    nibble = 8;
    difference = -difference;
  }

  int delta = step >> 3;
  if (difference >= step) {
    nibble |= 4;
    difference -= step;
    delta += step;
  }
  if (difference >= (step >> 1)) {
    nibble |= 2;
    difference -= step >> 1;
    delta += step >> 1;
  }
  if (difference >= (step >> 2)) {
    nibble |= 1;
    delta += step >> 2;
  }

  predictor += (nibble & 8) ? -delta : delta;
  predictor = clampInt(predictor, -32768, 32767);
  stepIndex = clampInt(stepIndex + indexTable()[nibble], 0, 88);
  return nibble;
}

inline int16_t decodeNibble(uint8_t nibble, int &predictor, int &stepIndex) {
  const int step = stepTable()[stepIndex];
  int delta = step >> 3;
  if (nibble & 4) delta += step;
  if (nibble & 2) delta += step >> 1;
  if (nibble & 1) delta += step >> 2;
  predictor += (nibble & 8) ? -delta : delta;
  predictor = clampInt(predictor, -32768, 32767);
  stepIndex = clampInt(stepIndex + indexTable()[nibble & 0x0f], 0, 88);
  return static_cast<int16_t>(predictor);
}

inline size_t encodedPacketBytes(size_t sampleCount) {
  if (sampleCount == 0) return 0;
  return kPacketHeaderBytes + (sampleCount / 2);
}

inline size_t encodePacket(const int16_t *samples, size_t sampleCount,
                           uint32_t sequence, uint8_t flags,
                           uint8_t *output, size_t capacity) {
  if (!samples || !output || sampleCount == 0 || sampleCount > UINT16_MAX) return 0;
  const size_t packetBytes = encodedPacketBytes(sampleCount);
  if (capacity < packetBytes) return 0;

  int predictor = samples[0];
  int stepIndex = 0;
  output[0] = kPacketMagic0;
  output[1] = kPacketMagic1;
  output[2] = kPacketVersion;
  output[3] = flags;
  output[4] = static_cast<uint8_t>(sequence);
  output[5] = static_cast<uint8_t>(sequence >> 8);
  output[6] = static_cast<uint8_t>(sequence >> 16);
  output[7] = static_cast<uint8_t>(sequence >> 24);
  output[8] = static_cast<uint8_t>(predictor);
  output[9] = static_cast<uint8_t>(static_cast<uint16_t>(predictor) >> 8);
  output[10] = static_cast<uint8_t>(stepIndex);
  output[11] = static_cast<uint8_t>(sampleCount);
  output[12] = static_cast<uint8_t>(sampleCount >> 8);

  memset(output + kPacketHeaderBytes, 0, packetBytes - kPacketHeaderBytes);
  for (size_t sampleIndex = 1; sampleIndex < sampleCount; ++sampleIndex) {
    const uint8_t nibble = encodeNibble(samples[sampleIndex], predictor, stepIndex);
    const size_t nibbleIndex = sampleIndex - 1;
    const size_t byteIndex = kPacketHeaderBytes + nibbleIndex / 2;
    if ((nibbleIndex & 1U) == 0) output[byteIndex] = nibble;
    else output[byteIndex] |= static_cast<uint8_t>(nibble << 4);
  }
  return packetBytes;
}

inline bool parseHeader(const uint8_t *packet, size_t packetBytes, DecodedHeader &header) {
  if (!packet || packetBytes < kPacketHeaderBytes ||
      packet[0] != kPacketMagic0 || packet[1] != kPacketMagic1 ||
      packet[2] != kPacketVersion) return false;
  header.flags = packet[3];
  header.sequence = static_cast<uint32_t>(packet[4]) |
                    (static_cast<uint32_t>(packet[5]) << 8) |
                    (static_cast<uint32_t>(packet[6]) << 16) |
                    (static_cast<uint32_t>(packet[7]) << 24);
  header.predictor = static_cast<int16_t>(static_cast<uint16_t>(packet[8]) |
                                          (static_cast<uint16_t>(packet[9]) << 8));
  header.stepIndex = packet[10];
  header.sampleCount = static_cast<uint16_t>(packet[11]) |
                       (static_cast<uint16_t>(packet[12]) << 8);
  return header.stepIndex <= 88 && header.sampleCount > 0 &&
         packetBytes >= encodedPacketBytes(header.sampleCount);
}

inline size_t decodePacket(const uint8_t *packet, size_t packetBytes,
                           int16_t *output, size_t outputCapacity,
                           DecodedHeader *decodedHeader = nullptr) {
  DecodedHeader header;
  if (!parseHeader(packet, packetBytes, header) || outputCapacity < header.sampleCount) return 0;
  int predictor = header.predictor;
  int stepIndex = header.stepIndex;
  output[0] = static_cast<int16_t>(predictor);
  for (size_t sampleIndex = 1; sampleIndex < header.sampleCount; ++sampleIndex) {
    const size_t nibbleIndex = sampleIndex - 1;
    const uint8_t packed = packet[kPacketHeaderBytes + nibbleIndex / 2];
    const uint8_t nibble = (nibbleIndex & 1U) == 0 ? (packed & 0x0f) : (packed >> 4);
    output[sampleIndex] = decodeNibble(nibble, predictor, stepIndex);
  }
  if (decodedHeader) *decodedHeader = header;
  return header.sampleCount;
}

}  // namespace DragonRadarVoice
