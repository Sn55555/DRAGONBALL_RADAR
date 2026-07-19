#pragma once

namespace DragonRadarOtaTrust {

// Public release-verification key only. The matching private key stays outside
// the firmware source tree and is never embedded in a device image.
inline constexpr char kSigningPublicKeyPem[] = R"PEM(-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAERJP6AojGHRBbMmkTNPVSzRM8PJ+l
grKYl5uvOHIfnnjZE9rWSVZnlAAA4hD2YLqP5W59WvowPnX7CueQRMNOCA==
-----END PUBLIC KEY-----
)PEM";

inline constexpr char kSigningKeyId[] = "local-2026-01";
inline constexpr char kSignatureAlgorithm[] = "ecdsa-p256-sha256";

}  // namespace DragonRadarOtaTrust
