# Font notices for the vendored Arduino_GFX source tree

This file records the licenses for bitmap font data present under `src/font/`.
It is separate from `license.txt`, which covers the Arduino_GFX software under
the BSD license.

## Current firmware inclusion

The current Capsule firmware includes Arduino_GFX's classic fixed-space 5x7
bitmap (`src/font/glcdfont.h`). That file is derived from Adafruit_GFX and is
covered by this vendor directory's `license.txt`.

The following generated U8g2 font arrays remain in the vendored source tree,
but the current firmware does not compile or link them: the application does
not include U8g2, `U8g2lib.h` is absent from the resolved PlatformIO
dependencies, and the linked ELF contains no `u8g2_font_chill*`,
`u8g2_font_cubic*`, `u8g2_font_quan*`, or `u8g2_font_unifont*` symbols. Their
licenses are nevertheless preserved because the source files are retained.

## Chill Bitmap 7px

Applies to `src/font/u8g2_font_chill7_h_cjk.h`.

Copyright (c) 2020-2022 by warren2060. All rights reserved.

These fonts are free software. Unlimited permission is granted to use, copy,
and distribute them, with or without modification, either commercially or
noncommercially. THESE FONTS ARE PROVIDED "AS IS" WITHOUT WARRANTY.

Authoritative source for the 2.400 font referenced by the vendored
Arduino_GFX README:
<https://github.com/Warren2060/ChillBitmap/blob/main/LICENSE.md>

## Cubic 11

Applies to `src/font/u8g2_font_cubic11_h_cjk.h`.

The upstream notice states that Cubic 11 and its incorporated bitmap-font
sources are free software with unlimited permission to use, copy, and
distribute, with or without modification, commercially or noncommercially,
and are provided without warranty. Upstream also distributes the font under
the SIL Open Font License 1.1. The complete OFL text is in `OFL-1.1.txt`.

Authoritative source:
<https://github.com/ACh-K/Cubic-11/blob/main/OFL.txt>

## QuanPixel

Applies to `src/font/u8g2_font_quan7_h_cjk.h`.

The generated header identifies its sources as Galmuri8, Chill Bitmap, and
diaowinner, copyright 2022, under the SIL Open Font License. The complete OFL
1.1 text is in `OFL-1.1.txt`.

The vendored Arduino_GFX README identifies the source as:
<https://diaowinner.itch.io/galmuri-extended>

Galmuri's authoritative OFL notice is also available at:
<https://github.com/quiple/galmuri/blob/main/ofl.md>

## GNU Unifont Japanese 17.0.03

Applies to:

- `src/font/u8g2_font_unifont_h_chinese.h`
- `src/font/u8g2_font_unifont_h_chinese4.h`
- `src/font/u8g2_font_unifont_h_cjk.h`
- `src/font/u8g2_font_unifont_h_utf8.h`

Copyright (C) 1998-2025 Roman Czyborra, Paul Hardy, Qianqian Fang, Andrew
Miller, Johnnie Weaver, David Corbett, Nils Chiana Moskopp, Rebecca
Bettencourt, Minseo Lee, Ho-Seok Ee, et al.

GNU Unifont compiled fonts are dual-licensed under:

- SIL Open Font License 1.1; or
- GNU General Public License version 2 or later, with the GNU Font Embedding
  Exception.

The complete OFL text is in `OFL-1.1.txt`. The complete GNU Unifont license,
including GPLv2 and the font embedding exception, is in
`COPYING-UNIFONT.txt`.

Authoritative sources:

- <https://unifoundry.com/unifont/index.html>
- <https://unifoundry.com/LICENSE.txt>
- <https://unifoundry.com/OFL-1.1.txt>

## Distribution rule

If any generated font array is enabled in a future firmware build, retain its
copyright notice and applicable license text in the distributed third-party
notices. Modified OFL fonts must remain under OFL and must respect any
Reserved Font Names. Modified GNU Unifont font data must follow the selected
branch of its dual license.
