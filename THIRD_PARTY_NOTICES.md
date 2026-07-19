# Third-Party Notices

Audit date: 2026-07-15

This inventory covers the Capsule iOS application and the Capsule radar
firmware in this repository. It records the dependency versions and license
evidence resolved by the current local build. It is not a substitute for
legal advice, and it must be regenerated whenever dependencies or the build
toolchain change.

## 1. Distribution boundaries

### Capsule iOS application

The Xcode project has no Swift Package Manager, CocoaPods, Carthage, vendored
framework, or XCFramework dependency. Its Swift sources import only Apple SDK
frameworks: AuthenticationServices, CoreBluetooth, CoreLocation, CryptoKit,
Foundation, Observation, PhotosUI, Security, SwiftUI, UIKit,
UserNotifications, and XCTest for tests.

Apple SDK frameworks are system components, not third-party code redistributed
inside the app by this repository. On the current dependency graph, the iOS
app itself therefore has no third-party Swift notice to present in-app.

The firmware and its licenses are a separate distribution surface. If an OTA
firmware binary is made available through the app, website, or hardware, the
firmware notice bundle described below must remain available to recipients.

### Hosted Relay service

This file does not inventory server-only Python packages because they are not
linked into the iOS app or firmware. If the Relay is distributed to customers
or third parties, generate a separate Python dependency/SBOM notice from the
locked deployment environment.

## 2. Firmware runtime components

| Component | Resolved version | Use in current firmware | License evidence | Authoritative source |
| --- | --- | --- | --- | --- |
| GFX Library for Arduino (Arduino_GFX) | 1.6.4 | Display driver and classic bitmap font; vendored under `lib/` | BSD two-clause text at `lib/GFX_Library_for_Arduino/license.txt` | <https://github.com/moononournation/Arduino_GFX/tree/v1.6.4> |
| SensorLib | 0.3.3 | QMI8658 IMU and CST touch drivers; vendored under `lib/` | MIT text at `lib/SensorLib/LICENSE` and `library.json` metadata | <https://github.com/lewisxhe/SensorsLib/tree/v0.3.3> |
| Arduino-ESP32 core | 3.3.8 | Arduino runtime plus Networking, Wi-Fi, TLS, HTTP, Update, Preferences, SPI, Wire, I2S, and BLE libraries | Installed package metadata declares `LGPL-2.1-or-later`; individual source files also carry LGPL-2.1-or-later, Apache-2.0, MIT, or BSD notices | <https://github.com/espressif/arduino-esp32/tree/3.3.8> |
| Arduino-ESP32 precompiled libraries | 5.5.4+sha.735507283d | ESP-IDF and chip-support archives linked by Arduino-ESP32 | Installed package metadata declares `LGPL-2.1-or-later`; this is package-level metadata and is not a verified replacement for all component/blob notices | <https://github.com/espressif/esp32-arduino-lib-builder> |
| Arduino ESP32 BLE Library | bundled with Arduino-ESP32 3.3.8 | BLE provisioning and binding | Apache-2.0 plus upstream NOTICE, copied to `lib/PLATFORMIO-RUNTIME-LICENSES/` | <https://github.com/espressif/arduino-esp32/tree/3.3.8/libraries/BLE> |
| arduinoWebSockets | PlatformIO package 2.7.3 | WebSocket client | `library.json` declares LGPL-2.1; source headers permit LGPL-2.1 or later; full local text copied to `lib/PLATFORMIO-RUNTIME-LICENSES/LGPL-2.1.txt` | <https://registry.platformio.org/libraries/links2004/WebSockets> and <https://github.com/Links2004/arduinoWebSockets> |
| libb64 | bundled in arduinoWebSockets and Arduino-ESP32 | Base64 routines | Public-domain dedication copied to `lib/PLATFORMIO-RUNTIME-LICENSES/LIBB64-PUBLIC-DOMAIN.txt` | <https://github.com/Links2004/arduinoWebSockets/tree/master/src/libb64> |

The current PlatformIO linker dependency set also resolves the following
Arduino-ESP32 libraries: Wire, BLE, WiFi, Networking, ESP_I2S, Update,
Preferences, SPI, NetworkClientSecure, and HTTPClient. They are covered by the
Arduino-ESP32 entry above, subject to the file-level notices retained in the
corresponding upstream source.

### PlatformIO build-only components

`platformio.ini` pins pioarduino `platform-espressif32` 55.03.38. Its official
package metadata declares Apache-2.0 and resolves Arduino-ESP32 3.3.8. The
compiler, debugger, uploader, SCons, and PlatformIO platform scripts are build
tools and are not copied into `firmware.bin`; their licenses are not product
runtime notices. The platform source is:
<https://github.com/pioarduino/platform-espressif32/tree/55.03.38>.

This distinction does not remove the need to preserve build-tool license
information in internal build records or to comply when those tools are
redistributed.

## 3. Bitmap font notices

The current linked firmware contains Arduino_GFX's classic fixed-space 5x7
bitmap from `src/font/glcdfont.h`, covered by Arduino_GFX's BSD license.

The vendored Arduino_GFX source tree also retains generated arrays for Chill
Bitmap 7px, Cubic 11, QuanPixel, and GNU Unifont Japanese. They are not linked
into the current firmware because U8g2 is not a resolved dependency and the
linked ELF has no corresponding `u8g2_font_*` symbols. Their notices are still
preserved for source redistribution:

- `lib/GFX_Library_for_Arduino/FONT-LICENSES.md`
- `lib/GFX_Library_for_Arduino/OFL-1.1.txt`
- `lib/GFX_Library_for_Arduino/COPYING-UNIFONT.txt`

In particular, QuanPixel is identified as OFL-licensed. GNU Unifont compiled
font data is dual-licensed under SIL OFL 1.1 or GPLv2+ with the GNU Font
Embedding Exception. Do not enable or redistribute those arrays without the
corresponding copyright and license texts.

## 4. Files explicitly excluded from product delivery

The following vendor reference assets are not compiled, not copied into the
iOS app, and not permitted in an OTA/device release package:

| Excluded path | Count in current tree | Reason |
| --- | ---: | --- |
| `lib/GFX_Library_for_Arduino/examples/**/*.gif` | 9 | Third-party/demo animation inputs used only by upstream examples |
| `lib/SensorLib/examples/**/*.gif` | 3 | Upstream gesture-recognition example media |
| `lib/SensorLib/datasheet/**/*.pdf` and `*.PDF` | 16 | Chip vendor datasheets and application notes; documentation reference only |

The excluded GIF files are:

- `examples/ImgViewer/ImgViewerAnimatedGIF_GIFDEC/data/ezgif.com-optimize.gif`
- `examples/ImgViewer/ImgViewerAnimatedGIF_GIFDEC/data/ezgif.com-resize.gif`
- `examples/ImgViewer/ImgViewerAnimatedGIF_bitbank/data/ezgif.com-optimize.gif`
- `examples/ImgViewer/ImgViewerAnimatedGIF_bitbank/data/ezgif.com-resize.gif`
- `examples/MultipleDisplay/MultipleAnimatedGIF/data/archer.gif`
- `examples/MultipleDisplay/MultipleAnimatedGIF/data/jobs.gif`
- `examples/MultipleDisplay/MultipleAnimatedGIF/data/lancer.gif`
- `examples/MultipleDisplay/MultipleAnimatedGIF/data/white.gif`
- `examples/Sprite/SpriteGif/data/city17_240.gif`
- `SensorLib/examples/BHI260AP_Klio_Recognition/action1.gif`
- `SensorLib/examples/BHI260AP_Klio_RecognizeMultiple/action1.gif`
- `SensorLib/examples/BHI260AP_Klio_RecognizeMultiple/action2.gif`

The first nine paths are relative to `lib/GFX_Library_for_Arduino/`; the last
three are relative to `lib/` as written. All sixteen files under
`lib/SensorLib/datasheet/` with a case-insensitive `.pdf` extension are also
excluded. Release packaging must use an allowlist for compiled firmware,
signed manifest/build metadata, and the notice bundle; it must never archive
the whole `lib/` tree as a product payload.

The excluded PDF files are:

- `lib/SensorLib/datasheet/BMA423.PDF`
- `lib/SensorLib/datasheet/CHSC5816触控芯片使用说明V1-20221114.pdf`
- `lib/SensorLib/datasheet/CM32181 Application Note for Archtech.pdf`
- `lib/SensorLib/datasheet/CM32181A3OP.pdf`
- `lib/SensorLib/datasheet/DRV2605.pdf`
- `lib/SensorLib/datasheet/GT911 Rev.10.pdf`
- `lib/SensorLib/datasheet/HYM8563.pdf`
- `lib/SensorLib/datasheet/LTR-553ALS-01.pdf`
- `lib/SensorLib/datasheet/PCF85063A.pdf`
- `lib/SensorLib/datasheet/PCF8563 Datasheet Rev.11.pdf`
- `lib/SensorLib/datasheet/QMC5883P.pdf`
- `lib/SensorLib/datasheet/QMC6310 Datasheet Rev.C.pdf`
- `lib/SensorLib/datasheet/QMI8658A Datasheet Rev A.pdf`
- `lib/SensorLib/datasheet/XL9555 Datasheet Rev2.3.PDF`
- `lib/SensorLib/datasheet/海栎创触摸芯片移植手册-v3.5-20220701(1).pdf`
- `lib/SensorLib/datasheet/环境光与接近传感器应用与选型.pdf`

## 5. Required firmware notice bundle

Every public firmware/device distribution must make the following files
available with the binary, in printed documentation, or through a stable URL
clearly identified from the product documentation:

- this `THIRD_PARTY_NOTICES.md`;
- `lib/GFX_Library_for_Arduino/license.txt`;
- `lib/GFX_Library_for_Arduino/FONT-LICENSES.md` and the font license files if
  the vendored source tree is distributed, or if those fonts are ever linked;
- `lib/SensorLib/LICENSE`;
- `lib/PLATFORMIO-RUNTIME-LICENSES/LGPL-2.1.txt`;
- `lib/PLATFORMIO-RUNTIME-LICENSES/Apache-2.0.txt`;
- `lib/PLATFORMIO-RUNTIME-LICENSES/ARDUINO-ESP32-BLE-NOTICE.txt`;
- `lib/PLATFORMIO-RUNTIME-LICENSES/LIBB64-PUBLIC-DOMAIN.txt`.

Retain upstream copyright and license headers in all distributed source.

## 6. LGPL release gate

Arduino-ESP32 and arduinoWebSockets include LGPL-covered code and are
statically linked into the ESP32 firmware. A copyright notice plus a GitHub
link alone is not a complete LGPL binary-distribution plan. Before public
firmware distribution, the release owner must choose and document a compliant
route, including the exact corresponding library source and modifications and
the material needed for recipients to relink the firmware with a modified
library (for example, compatible application object files and reproducible
link instructions), or replace/obtain another license for the affected
component. Preserve the required offer/source availability for the period
required by the selected LGPL distribution method.

Do not mark firmware open-source compliance complete until this relinking and
corresponding-source package has been produced and independently reviewed.

## 7. Items that still require release-owner or legal confirmation

1. **Arduino-ESP32 precompiled archives:** produce an SBOM and component-level
   license/NOTICE set for the exact 3.3.8 release archives. The installed
   `framework-arduinoespressif32-libs` package contains many ESP-IDF and binary
   components; its umbrella package metadata is insufficient evidence that
   every linked component has the same license.
2. **LGPL static-link compliance:** approve the object/source/relink delivery
   method for both Arduino-ESP32 and arduinoWebSockets, or approve a dependency
   replacement/commercial-license path.
3. **arduinoWebSockets provenance:** PlatformIO resolves registry version
   2.7.3, while the audit did not find a matching immutable upstream Git tag.
   Pin an immutable source commit or retain the exact registry archive and its
   checksum in release records.
4. **OTA notice delivery:** the current OTA packager creates firmware,
   manifest, and build metadata snapshots but does not add this notice bundle.
   Publish a stable firmware-license URL or extend the packaging/release
   process before public delivery.
5. **Final artifact check:** inspect the signed `.ipa`, firmware image, OTA
   directory, review video, screenshots, and public support site to confirm
   that no excluded example GIF/PDF or unlicensed vendor asset is present.

## 8. Upstream license sources used for missing local evidence

Only official upstream repositories or package metadata were used where the
vendored tree lacked a complete license:

- Arduino-ESP32 3.3.8 LGPL text:
  <https://github.com/espressif/arduino-esp32/blob/3.3.8/LICENSE.md>
- pioarduino platform Apache-2.0 metadata/source:
  <https://github.com/pioarduino/platform-espressif32/tree/55.03.38>
- GNU Unifont licensing and font exception:
  <https://unifoundry.com/unifont/index.html> and
  <https://unifoundry.com/LICENSE.txt>
- SIL Open Font License 1.1:
  <https://unifoundry.com/OFL-1.1.txt>
- Chill Bitmap historical font notice:
  <https://github.com/Warren2060/ChillBitmap/blob/main/LICENSE.md>
- Cubic 11 font notice:
  <https://github.com/ACh-K/Cubic-11/blob/main/OFL.txt>
- Galmuri OFL notice used by QuanPixel:
  <https://github.com/quiple/galmuri/blob/main/ofl.md>
