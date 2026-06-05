# Dragon Radar firmware

Personal ESP32-S3-Touch-AMOLED-1.75C firmware for a Dragon-Radar-style
treasure hunt prop.

This repository starts with an Arduino sketch that targets the Waveshare
ESP32-S3-Touch-AMOLED-1.75C. It draws the radar directly with Arduino_GFX,
uses the CST9217 touch controller through Waveshare's SensorLib, reads the
QMI8658 IMU when available, plays short ES8311/I2S audio cues, and scans BLE
beacon names such as `DBALL-1`.

The main screen intentionally uses a rectangular green coordinate grid clipped
by the round AMOLED screen. It does not use concentric radar rings, and the
default UI hides development status text so the running screen stays closer to
the anime prop.

The build enables `firmware/DragonRadar/private_boot_logo.h` when it exists.
That file is ignored by git and currently contains a local Capsule Corp-style
boot mark for your personal build. The startup sequence now behaves like a prop
screen warming up: the green grid wakes in, a vertical scan band crosses the
screen, subtle phosphor noise fades out, the logo scans in piece by piece, and
seven rectangular ticks fill below it. After handoff to the radar screen, a
brief text-free rectangular acquisition sweep calibrates the grid before normal
tracking. A shared scanline/edge phosphor mask gives the screen a lower-fi
prop-display texture without adding radar rings, and target blips now sit on a
short orange scanline bloom with a tiny fading afterimage stack instead of
looking like flat debug dots. Touch input adds a brief square contact echo at
the tapped point, and IMU motion adds short rectangular inertia ticks on the
grid edge, keeping controls and movement visible as prop-like geometry instead
of labels. It avoids development text on the prop screen.
Delete the private file
to fall back to the generated Capsule-style fallback, or replace it with your
own private art implementation. The copied `private_boot_logo.h.example` now
mirrors the same staged capsule body, scan line, side `C` mark, and wordmark
timing so release rebuilds do not regress to the earlier circle placeholder.
Run `tools/install_private_boot_logo.py status` to audit the local-only setup,
or `tools/install_private_boot_logo.py install-example` to create the ignored
private file from the public example when it is missing.

## Layout

- `firmware/DragonRadar/DragonRadar.ino` - main firmware sketch.
- `firmware/DragonBallBeacon/DragonBallBeacon.ino` - ESP32 test beacon.
- `firmware/DragonRadar/pin_config.h` - Waveshare pin map.
- `firmware/DragonRadar/private_boot_logo.h.example` - local artwork hook.
- `docs/board-sim-test.zh.md` - Chinese guide for one-board simulated
  hardware testing before the seven physical beacons are ready.
- `docs/product-design.zh.md` - Chinese product design and feasibility guide
  covering GPS-free BLE play, optional upgrades, innovation points, and risks.
- `docs/beacon-build.zh.md` - Chinese hands-on guide for making, flashing,
  labeling, hiding, and verifying the seven BLE `DBALL-*` beacons.
- `preview/radar_ui.html` - browser preview of the boot/radar look.
- `tools/fetch_waveshare_arduino_libs.sh` - fetches the required vendor libs.
- `tools/build_radar.sh` - builds or uploads the radar firmware presets.
- `tools/list_radar_ports.py` - lists serial ports and highlights likely ESP32-S3 radar ports.
- `tools/diagnose_usb_serial.py` - writes a Chinese USB serial diagnosis report
  when the board is not visible, including serial-port and macOS USB device-layer evidence.
- `tools/diagnose_board_runtime.py` - checks a visible radar serial port for
  firmware `DIAG` output and separates app-no-output from esptool-no-data recovery cases.
- `tools/recover_board_runtime.py` - safely tries DTR/RTS release, app reset,
  BOOT/Reset, and esptool probing when a visible serial port has no runtime output.
- `tools/send_diag_command.py` - sends runtime `DIAG` commands such as
  `frame`, `turbo`, `reset`, and waits for firmware confirmation.
- `tools/run_no_reset_display_check.py` - checks display refresh over DIAG
  without flashing or requiring manual Reset, and writes a Chinese report.
- `tools/analyze_board_photo.py` - analyzes a real board photo or video frame
  for screen region, rectangular grid, orange target dots, and banding risk.
- `tools/render_hardware_proof_packet.py` - summarizes release, bring-up,
  sim bench, photo QA, seven-beacon, and clean field-hunt evidence into a
  Chinese hardware proof checklist.
- `tools/generate_usb_bringup_card.py` - creates a Chinese USB bring-up and
  cable/BOOT/Reset troubleshooting card from the latest serial diagnosis.
- `tools/generate_refresh_perf_card.py` - creates a Chinese refresh-rate and
  flicker troubleshooting card from DIAG draw-cost evidence.
- `tools/wait_for_radar_port.py` - waits for the ESP32-S3 serial port to appear
  with USB device-layer diagnostics and can automatically launch the one-board smoke test.
- `tools/flash_release_firmware.sh` - flashes packaged factory binaries without
  rebuilding firmware.
- `tools/smoke_release_board.sh` - flashes the packaged sim image and runs the
  strict one-board simulated seven-ball bench.
- `tools/run_board_sim_test.py` - guided one-board simulation test with port
  check, packaged sim flash, mock mode, and report paths.
- `tools/run_preboard_acceptance.py` - runs the no-hardware pre-board
  acceptance suite and writes a Chinese proof-boundary report.
- `tools/selftest_release.py` - verifies a packaged handoff without hardware by
  checking package contents and running the mock one-board simulation.
- `tools/first_run_zh.py` - Chinese first-run wizard for release verification,
  serial-port checks, mock self-test, and real one-board simulation.
- `tools/run_release_acceptance.sh` - runs full hardware acceptance from a
  packaged release without rebuilding firmware.
- `tools/build_beacons.sh` - builds all seven beacon indexes.
- `tools/upload_beacon.sh` - uploads one numbered beacon to a spare ESP32.
- `tools/flash_beacon_set.sh` - guided sequential upload for all physical beacons.
- `tools/verify_beacon_set.sh` - verifies a physical seven-beacon set through the radar.
- `tools/run_missing_hardware_gates.py` - dry-runs or executes only the hardware
  proof gates still missing from the current proof packet.
- `tools/generate_beacon_labels.py` - creates printable labels for the beacon set.
- `tools/generate_field_kit.py` - creates a printable game-day setup and
  acceptance checklist.
- `tools/generate_play_cards.py` - creates printable host/player rule cards,
  DBALL hiding cards, and a proof-boundary card for friend playtests.
- `tools/render_playtest_rehearsal.py` - creates a Chinese pre-play rehearsal
  report from release self-test, mock seven-ball flow, UI audits, and USB status.
- `tools/generate_quickstart_zh.py` - creates the Chinese release quickstart
  page for handoff and first-run checks.
- `tools/generate_visual_qa_sheet.py` - creates an HTML contact sheet for the
  captured boot/radar/summon preview frames.
- `tools/generate_motion_gifs.py` - creates lightweight boot, radar, and summon
  GIFs from the verified keyframes.
- `tools/verify_motion_gifs.py` - verifies the boot, radar, and summon GIF
  frame order, timing, and color-phase progression.
- `tools/generate_motion_qa_sheet.py` - creates an HTML storyboard for the
  boot reveal, playable modes, and summon-completion animation phases.
- `tools/generate_release_index.py` - creates the top-level release `index.html`
  that links firmware, visual QA, field kit, and acceptance commands.
- `tools/generate_fidelity_review.py` - creates a Chinese UI fidelity review
  from the visual, source-contract, parity, and private-logo audits.
- `tools/verify_release_package.py` - verifies release folder contents and
  writes SHA256 checksums.
- `tools/record_field_hunt.sh` - records a real hunt while keeping the radar UI clean.
- `tools/run_hardware_acceptance.sh` - runs the complete on-board acceptance
  sequence and archives the proof reports.
- `tools/bringup_diag.sh` - uploads diag firmware and starts the monitor.
- `tools/bench_sim.sh` - uploads the one-board simulated-beacon bench firmware
  and verifies its DIAG stream.
- `tools/capture_preview_screenshots.sh` - captures visual QA screenshots.
- `tools/smoke_preview_interactions.sh` - runs a browser smoke test for preview
  keyboard controls and seven-ball collection.
- `tools/monitor_diag.py` - summarizes `diag` serial output during hardware bring-up.
- `tools/render_bench_report.py` - renders diagnostic JSON as a Markdown bench report.
- `tools/render_hunt_report.py` - renders a friend-facing post-game hunt report.
- `tools/render_goal_completion_audit.py` - renders the requirement-by-requirement
  audit for whether this full goal can be ended.
- `tools/render_project_status.py` - summarizes current software and hardware
  acceptance evidence.
- `tools/package_release.sh` - gathers built firmware, preview images, reports,
  labels, and flashing notes into one release folder.
- `tools/recommend_field_tuning.py` - converts DIAG reports into field build
  RSSI tuning commands.
- `tools/send_diag_command.py` - sends one hidden DIAG command over USB serial.
- `tools/replay_diag_log.sh` - replays a saved raw DIAG log into a fresh report.
- `tools/simulate_diag_feed.py` - emits deterministic fake `diag` lines for monitor dry-runs.
- `tools/verify_preview_visuals.py` - checks screenshots for key UI invariants.
- `tools/verify_firmware_ui_contract.py` - checks source/build invariants for
  rectangular-grid UI, clean field modes, and the private boot logo hook.
- `tools/verify_ui_parity.py` - cross-checks firmware and browser preview UI
  timing, grid, controls, and mode semantics.
- `tools/verify_private_boot_logo.py` - audits the local Capsule-style boot
  logo source, build flags, release boundary, and packaged firmware evidence.
- `tools/install_private_boot_logo.py` - checks or installs the ignored local
  `private_boot_logo.h` without exposing its source in release packages.
- `tools/verify_project.sh` - one-command local verification presets.
- `platformio.ini` - optional PlatformIO build entry.

## Arduino IDE setup

1. Install ESP32 Arduino core 3.3.x.
2. Run `tools/fetch_waveshare_arduino_libs.sh`.
3. Copy or symlink the generated `lib/*` directories into your Arduino
   libraries folder, or use PlatformIO from this repository.
4. Open `firmware/DragonRadar/DragonRadar.ino`.
5. Select an ESP32-S3 board with PSRAM enabled and USB CDC enabled.
6. Build and upload.

## PlatformIO setup

`platformio.ini` uses the community pioarduino ESP32 platform because the
official PlatformIO ESP32 platform is still tied to Arduino-ESP32 2.x, while
Waveshare's AMOLED driver requires Arduino-ESP32 3.x headers.

The `boards/waveshare_esp32_s3_touch_amoled_175c.json` definition matches the
1.75C hardware target: 32MB flash, 8MB PSRAM, QIO flash, and OPI PSRAM.

Build:

```sh
pio run -e esp32-s3-touch-amoled-175c
```

The helper script wraps the same environments and defaults to the field build,
which starts on an empty grid until a real beacon is seen:

```sh
tools/build_radar.sh
tools/build_radar.sh field
tools/build_radar.sh field upload
tools/build_radar.sh fielddiag upload
tools/build_radar.sh diag upload
tools/build_radar.sh sim upload
tools/build_radar.sh beach upload
```

`beach` flashes a lightweight pixel beach scene instead of the radar: the two
extracted pixel characters walk randomly on the sand, and a left or right swipe
on the touch screen steers both characters in that direction for a short run.

After `tools/package_release.sh` has produced `output/release-current/`, you can
flash a prebuilt factory image without rebuilding:

```sh
tools/list_radar_ports.py --shell
RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh field
RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh sim
```

The helper writes the packaged `firmware/dragon-radar-*-factory.bin` image at
offset `0x0` with ESP32-S3 flash settings matching this board. Use
`FLASH_DRY_RUN=1` first when checking the selected port or mode.

For the fastest real-board smoke test from a release package, flash the packaged
`sim` image and run the strict simulated seven-ball monitor:

```sh
tools/run_board_sim_test.py port-check
RADAR_PORT=/dev/cu.usbmodem101 tools/run_board_sim_test.py auto
RADAR_PORT=/dev/cu.usbmodem101 tools/smoke_release_board.sh all
```

The `run_board_sim_test.py` helper is the guided path: it checks for a likely
ESP32-S3 serial port, verifies the packaged release, flashes the packaged `sim`
factory image, and writes the bench reports under `output/board-sim-current/`
or `evidence/board-sim/` inside a copied release folder. This proves the
display/touch/IMU/BLE/audio bring-up path, seven deterministic targets, seven
collection events, and summon transition on the actual board without needing the
physical beacons. Use `tools/run_board_sim_test.py auto --dry-run --port /dev/cu.test`
or `SMOKE_DRY_RUN=1 RADAR_PORT=/dev/cu.test tools/smoke_release_board.sh all`
to inspect the commands first.

The Chinese handoff guide for this flow is
`docs/board-sim-test.zh.md`; the release package also copies it to
`docs/board-sim-test.zh.md`. For a shorter handoff entry, open
`docs/quickstart.zh.html` inside the release package.
For the broader product rationale and feasibility notes, read
`docs/product-design.zh.md`.
For the hands-on seven-beacon build and deployment flow, read
`docs/beacon-build.zh.md`.

For a full hardware acceptance run from the packaged release, use the copied
release helper instead of rebuilding from source:

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/run_release_acceptance.sh all
```

It flashes the packaged `diag`, `sim`, and `fielddiag` factory images as needed
and writes bring-up, one-board sim, seven-beacon, and clean hunt reports under
`evidence/release-acceptance/` when run inside a copied release folder. Use
`RELEASE_ACCEPTANCE_DRY_RUN=1 RADAR_PORT=/dev/cu.test tools/run_release_acceptance.sh all`
to inspect the exact commands.

Before hardware is attached, run the packaged mock self-test to prove the
release scripts, DIAG parser, and report renderers work end to end:

```sh
tools/first_run_zh.py check
tools/diagnose_usb_serial.py
RADAR_PORT=/dev/cu.usbmodem101 tools/diagnose_board_runtime.py --esptool-probe
RADAR_PORT=/dev/cu.usbmodem101 tools/recover_board_runtime.py
tools/first_run_zh.py live
tools/wait_for_radar_port.py --run-auto
tools/first_run_zh.py mock
tools/run_preboard_acceptance.py
tools/selftest_release.py
tools/run_board_sim_test.py mock
tools/render_playtest_rehearsal.py
RELEASE_ACCEPTANCE_MOCK=1 tools/run_release_acceptance.sh all
```

`tools/first_run_zh.py` is the Chinese first-run entry. Use `check` to verify
the release package and inspect serial ports, `tools/diagnose_usb_serial.py`
when the board is not visible, `live` for the one-command on-site assistant,
`mock` for a no-hardware local self-test, and
`RADAR_PORT=/dev/cu.usbmodem101 tools/first_run_zh.py auto` for the real
one-board simulated hardware test after the ESP32-S3 is connected.
It writes `output/first-run-current/first-run-summary.json` and
`output/first-run-current/first-run-summary.zh.md`, and it marks
`hardwareProof=true` only when the real `auto` run passes.
In `live` mode it runs pre-board acceptance, USB diagnosis, serial waiting, and
the automatic one-board simulation in order; if no board appears it writes a
`needs-hardware` report instead of claiming a software failure.

`tools/diagnose_usb_serial.py` now records both `/dev/cu.*` serial readiness
and `system_profiler SPUSBDataType` USB device-layer evidence. If the USB layer
sees an ESP32-S3/USB-JTAG style device but no serial port appears, focus on
BOOT/Reset, USB CDC/JTAG driver or permission issues, and serial monitor
contention. If neither layer sees the board, start with cable, power, and direct
USB port checks.
After a serial port is visible, `tools/diagnose_board_runtime.py` checks whether
the firmware is actually producing `DIAG` lines. Use
`RADAR_PORT=/dev/cu.usbmodem101 tools/diagnose_board_runtime.py --esptool-probe`
when `/dev/cu.usbmodem*` exists but monitors show no text: it separates
`runtime-ready`, `runtime-degraded`, `bootloader-reachable-no-diag`, and
`usb-serial-present-no-runtime`, so the next action is either reflash or physical
Reset/BOOT instead of guessing.
If that status repeats, `RADAR_PORT=/dev/cu.usbmodem101 tools/recover_board_runtime.py`
tries safe DTR/RTS release, app-reset, BOOT/Reset, and esptool probing before
asking for a physical reset or USB replug.
If you cannot press Reset manually but the serial port is visible, run the
recovery tool first; when it reports the bootloader is reachable, use
`RADAR_PORT=/dev/cu.usbmodem101 tools/flash_release_firmware.sh sim` to let
esptool's automatic reset sequence reflash the packaged simulated bench image.
For a single guided pass, run
`RADAR_PORT=/dev/cu.usbmodem101 tools/first_run_zh.py live --recover-runtime`;
it adds the runtime recovery step before waiting for the auto board simulation.
The current firmware default is `frameMs=25` for a smoother radar sweep. To
cycle the on-device runtime refresh preset through `25/33/50/65/80/120ms`, run
`RADAR_PORT=/dev/cu.usbmodem101 tools/send_diag_command.py frame`; if old NVS
settings keep the board at 33ms, run
`RADAR_PORT=/dev/cu.usbmodem101 tools/send_diag_command.py turbo` to force the
25ms preset. The next `DIAG tick` or `tools/monitor_diag.py` report records the
active `frameMs`, last `drawMs`, rolling `drawAvgMs`/`drawMaxMs`, and
`overBudget` frame count, so slow refresh can be separated from actual
per-frame draw cost.
Generate the bench card with
`tools/generate_refresh_perf_card.py --output output/refresh-performance-card.zh.md`;
release packages include it as `docs/refresh-performance-card.zh.md`.
For a connected board that you cannot manually Reset, run
`RADAR_PORT=/dev/cu.usbmodem101 tools/run_no_reset_display_check.py --command turbo`;
it only uses DIAG serial commands and writes `output/no-reset-display-check.zh.md`.
Release packages include the same report at `docs/no-reset-display-check.zh.md`.
To check a real photo or video frame of the board screen, run
`tools/analyze_board_photo.py /path/to/board-photo.png`; the sample report is
generated as `output/board-photo-qa-sample.zh.md` and packaged as
`docs/board-photo-qa-sample.zh.md`.
Add `--crop-output output/board-photo-crop.png --overlay-output
output/board-photo-overlay.png` when you want a cropped screen image and an
annotated source image showing the detected round-screen area.
To see exactly why the project still cannot be marked complete, run
`tools/render_hardware_proof_packet.py --json output/hardware-proof-packet.json --md output/hardware-proof-packet.zh.md`.
Release packages include the same report at `docs/hardware-proof-packet.zh.md`.
To close only the remaining real-board gates after the radar has been reset and
the seven beacons are powered, first dry-run
`tools/run_missing_hardware_gates.py`; then execute with
`RADAR_PORT=/dev/cu.usbmodem101 tools/run_missing_hardware_gates.py --execute`.
It writes `output/missing-hardware-gates-plan.json` and
`output/missing-hardware-gates-plan.zh.md`, packaged as
`evidence/missing-hardware-gates-plan.json` and
`docs/missing-hardware-gates-plan.zh.md`.
The CO5300 QSPI display bus defaults to `80000000` Hz. If a specific board
shows bus-related flicker, rebuild with
`DISPLAY_BUS_HZ=40000000 tools/build_radar.sh sim` to separate signal stability
from render cost.
`tools/wait_for_radar_port.py --run-auto` records the same USB device-layer
status on every polling attempt, so the wait report shows whether a cable or
BOOT/Reset change made the board appear at the USB layer before a serial port
was created.

`tools/run_preboard_acceptance.py` is the one-command no-hardware rehearsal. It
verifies the release folder, runs the packaged mock board simulation, replays a
deterministic seven-ball DIAG stream through the same monitor checks, and writes
`output/preboard-acceptance-current/preboard-acceptance-summary.json` plus a
Chinese Markdown report. The nested mock bench evidence lives at
`output/preboard-acceptance-current/release-selftest/board-sim-mock/bench-sim-report.json`.
It always keeps `hardwareProof=false`; the project status reports this as
`Mock one-board simulation` and keeps the real-board
`output/bench-sim-report.json` gate separate.

`tools/selftest_release.py` is the preferred handoff check because it verifies
the release folder, runs the packaged mock board simulation, and writes
`release-selftest-summary.json` plus a Markdown report. Mock reports are
deliberately marked with `hardwareProof=false` and must not be used as hardware
completion evidence.

`tools/render_playtest_rehearsal.py` turns the release self-test, mock seven-ball
route, UI audits, and USB diagnosis into `output/playtest-rehearsal.zh.md`, a
short Chinese rehearsal card you can read before a friend playtest.

`tools/recommend_field_tuning.py` now auto-picks the best available DIAG report:
real hardware reports first, then the mock pre-board bench report. When it uses
mock evidence, `output/field-tuning-report.md` is explicitly marked
`hardwareProof=false`; use that only as a starting `COLLECT_RSSI` and
`COLLECT_HOLD_MS` for friend play, then recalibrate with real beacons.

Field build with an empty grid until a real beacon is seen:

```sh
pio run -e esp32-s3-touch-amoled-175c-field
```

Clean field build with hidden serial diagnostics for recording a real play
session without debug HUD text:

```sh
pio run -e esp32-s3-touch-amoled-175c-fielddiag
tools/build_radar.sh fielddiag upload
```

Debug build with HUD, scan line, and star-marked Dragon Balls:

```sh
pio run -e esp32-s3-touch-amoled-175c-debug
```

Hardware diagnostics build with debug HUD, serial diagnostics, and an empty
real-play grid:

```sh
pio run -e esp32-s3-touch-amoled-175c-diag
```

Simulated-beacon board demo with the clean field UI, USB diagnostics, and
deterministic `DBALL-*` targets injected inside the radar firmware:

```sh
pio run -e esp32-s3-touch-amoled-175c-sim
```

Near-range field build for smaller rooms:

```sh
pio run -e esp32-s3-touch-amoled-175c-near
```

Optional near-only release package for a small room or tabletop hunt:

```sh
RELEASE_BUILD=1 RELEASE_MODES=near RELEASE_DIR=output/release-near tools/package_release.sh
tools/selftest_release.py output/release-near --modes near
RADAR_PORT=/dev/cu.usbmodem101 RELEASE_DIR=output/release-near tools/flash_release_firmware.sh near
```

Upload:

```sh
pio run -e esp32-s3-touch-amoled-175c -t upload
```

Optional build flags:

```text
-DDRAGON_RADAR_DEBUG_HUD=1
-DDRAGON_RADAR_SCAN_LINE=1
-DDRAGON_RADAR_STAR_BLIPS=1
-DDRAGON_RADAR_GRID_SNAP=1
-DDRAGON_RADAR_SERIAL_DIAG=1
-DDRAGON_RADAR_DEMO_ON_BOOT=0
-DDRAGON_RADAR_DEMO_TOUCH=0
-DDRAGON_RADAR_SIMULATED_BLE=1
-DDRAGON_RADAR_COLLECT_RSSI=-50
-DDRAGON_RADAR_COLLECT_HOLD_MS=1200
-DDRAGON_RADAR_BEACON_TTL_MS=18000
-DDRAGON_RADAR_BEACON_TRACE_MS=45000
-DDRAGON_RADAR_BEACON_FRESH_MS=3000
-DDRAGON_RADAR_BRIGHTNESS=184
-DDRAGON_RADAR_AUDIO_GAIN=100
```

Leave them off for the cleaner anime-style screen with simple orange radar
blips. `DRAGON_RADAR_STAR_BLIPS=1` draws small star-marked Dragon Balls instead.
`DRAGON_RADAR_GRID_SNAP=1` is the default and latches target blips to rectangular
grid coordinates; set it to `0` only if you want smoother modern motion for
debugging.
`DRAGON_RADAR_SERIAL_DIAG=1` prints hidden hardware and BLE diagnostics over USB
serial without adding anything to the default prop screen.
`DRAGON_RADAR_DEMO_ON_BOOT=0` starts on an empty grid until a real beacon is
seen.
`DRAGON_RADAR_DEMO_TOUCH=0` disables the hidden center test tap. The helper
script uses this by default for `field` and `near` builds so real play cannot
accidentally collect simulated balls; set `DEMO_TOUCH=1` when you want a field
test build with the center test tap restored.
`DRAGON_RADAR_SIMULATED_BLE=1` injects deterministic `DBALL-1..7` readings from
inside the radar firmware. Use `tools/build_radar.sh sim upload` when you want
to test the board screen, audio, collection logic, and USB diagnostics without
separate BLE beacon hardware. Do not use it for real play.

Tune collection distance without editing the sketch:

```sh
COLLECT_RSSI=-47 COLLECT_HOLD_MS=1500 tools/build_radar.sh field
COLLECT_RSSI=-47 COLLECT_HOLD_MS=1500 tools/build_radar.sh field upload
```

Less negative RSSI values require the radar to be closer to the beacon. For
example, `-45` collects closer than `-55`.

Tune screen brightness or speaker level for the enclosure without editing the
sketch:

```sh
RADAR_BRIGHTNESS=210 AUDIO_GAIN=80 tools/build_radar.sh field
RADAR_BRIGHTNESS=160 AUDIO_GAIN=120 tools/build_radar.sh field upload
```

`RADAR_BRIGHTNESS` must stay in the display-safe `0..255` range. `AUDIO_GAIN`
is a percentage from `0..200`; start below `100` if the small speaker distorts
inside the shell.

Build a temporary hardware diagnostics firmware without changing the prop UI:

```sh
tools/bringup_diag.sh all
```

The `diag` image starts like the field build, with an empty real-play grid and
center simulated collection disabled, but it adds the debug HUD and hidden
serial diagnostics. The serial stream reports display/touch/IMU/BLE/audio
online state, periodic active/collected counts, strongest beacon RSSI, touch
coordinates, RSSI bearing bins, and throttled `DBALL-*` RSSI packets.
When a ball is actually marked collected, the firmware also emits
`DIAG collect DBALL-n ...` with the collection timestamp, raw/filtered RSSI,
range estimate, and bearing bin. The monitor stores those events in order so
the JSON/Markdown report can prove which ball was collected first, second, and
so on during a bench or field run. The firmware also emits `DIAG hunt ...`
events at startup and reset. The monitor treats reset/start as a new current
session, so strict collection checks are not fooled by balls collected before a
mid-game reset.
`tools/monitor_diag.py` runs `pio device monitor -b 115200` and condenses those
lines into hardware, touch, and beacon summaries. If several serial devices are
attached, use `RADAR_PORT=/dev/cu.usbmodem101 tools/bringup_diag.sh all`.
Use `tools/bringup_diag.sh build`, `upload`, or `monitor` when you only need one
stage. The bring-up helper writes `output/bringup-diag-report.json` and renders
`output/bringup-diag-report.md` when monitoring exits; override those paths with
`DIAG_REPORT_JSON=...` and `DIAG_REPORT_MD=...` when you want to archive a dated
real-board run. It also saves the raw serial transcript to
`output/bringup-diag-raw.log`; override with `DIAG_LOG=...` when you need a
separate replay/debug log.
While a serial diagnostics build is running, you can type single-character
commands into the USB serial monitor to test controls without touching the
screen or side button. These commands only exist when `DRAGON_RADAR_SERIAL_DIAG=1`
is enabled, so the normal field firmware remains a clean prop screen:

| Key | Action |
| --- | --- |
| `?` | Print the command list. |
| `h` | Reprint display/touch/IMU/BLE/audio status. |
| `z` | Cycle map scale. |
| `r` | Reset the hunt and restart BLE scanning. |
| `b` | Cycle brightness preset. |
| `a` | Cycle audio preset. |
| `f` | Cycle display frame interval through `25/33/50/65/80/120ms` for on-board refresh tuning. |
| `t` | Force the runtime back to the 25ms turbo frame preset. |
| `c` | Collect the next demo ball for animation/audio testing. |
| `p` | Play a test ping. |
| `s` | Restart BLE scanning. |

The monitor records these as `DIAG command ...` lines and includes the last one
in the JSON/Markdown report, which makes bench-test transcripts easier to audit.
You can also send those commands without opening an interactive monitor:

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/send_diag_command.py hardware
RADAR_PORT=/dev/cu.usbmodem101 tools/send_diag_command.py ping
RADAR_PORT=/dev/cu.usbmodem101 tools/send_diag_command.py frame
RADAR_PORT=/dev/cu.usbmodem101 tools/send_diag_command.py turbo
RADAR_PORT=/dev/cu.usbmodem101 tools/send_diag_command.py reset
```

The helper waits for the `DIAG command ...` echo and exits nonzero if the board
does not confirm it, which is useful for repeatable bench scripts.
The `frame` and `turbo` commands are useful when checking whether a faster
screen cadence improves perceived smoothness. The monitor report includes
`frameMs`, `drawMs`, `drawAvgMs`, `drawMaxMs`, and `overBudget`: if draw cost
approaches or exceeds `frameMs`, the board is drawing slower than the requested
cadence; if draw cost is much lower with zero over-budget frames, the remaining
issue is likely animation cadence, brightness, or camera exposure rather than
raw render cost.
The firmware caches the round-screen chord geometry used by the rectangular
grid, sweep, phosphor mask, and summon overlay, so those high-frequency paths do
not repeatedly run floating-point square roots every frame.
To re-run the parser against a saved transcript after the session:

```sh
REPLAY_REQUIRE_ONLINE=touch,imu,ble,audio \
REPLAY_MIN_BEACONS=1 \
tools/replay_diag_log.sh output/bringup-diag-raw.log \
  output/bringup-diag-replay.json output/bringup-diag-replay.md
```

For RSSI tuning, add `DIAG_CALIBRATE=1`; after you move each beacon from far
range into the desired collection distance, the monitor prints per-ball RSSI
min/max/average, the 75th-percentile `candidateCollect` starting point for
`COLLECT_RSSI`, close-hit counts, and the bearing bins that were observed; the
same values are captured in the generated report.
Turn that report into a concrete field build command with:

```sh
tools/recommend_field_tuning.py output/bringup-diag-report.json
TUNING_DIFFICULTY=strict tools/recommend_field_tuning.py output/bringup-diag-report.json
```

It writes `output/field-tuning-report.md` and prints a ready-to-run
`COLLECT_RSSI=... COLLECT_HOLD_MS=... tools/build_radar.sh field upload`
command. Use `easy` when friends should collect from a little farther away,
`normal` as the first pass, and `strict` when the beacon should require a
closer approach.
Before hardware is attached, use the deterministic DIAG simulator to exercise
the same monitor and calibration path:

```sh
tools/simulate_diag_feed.py --beacons 3 --samples 40 --touch-events \
  | tools/monitor_diag.py --stdin --calibrate --require-online touch,imu,ble,audio --min-beacons 3
```

Use `--offline touch`, `--offline imu`, `--offline ble`, or `--offline audio`
to make the monitor fail the same way it should during hardware bring-up.
With the radar board attached but before separate Dragon Ball beacons are ready,
use the one-board bench flow:

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/bench_sim.sh all
```

It uploads the `sim` firmware, requires `DIAG simulatedBle=enabled`, waits for
all seven injected `DBALL-*` targets, verifies that all seven are collected and
that `summon=yes` appears in the diagnostic stream, and now also requires seven
ordered `DIAG collect` events covering DBALL-1 through DBALL-7. That makes the
one-board bench a stronger proof that collection, disappearance, summon entry,
audio cues, and report logging all agree. It still checks the real board's
touch/IMU/BLE/audio online state. Use `tools/bench_sim.sh monitor` when the sim
firmware is already flashed. It writes a machine-readable report to
`output/bench-sim-report.json`; override that with `SIM_REPORT_JSON=...` when
you want to archive a dated bench run. It also renders
`output/bench-sim-report.md` for quick human review; override with
`SIM_REPORT_MD=...`, and saves the raw transcript to
`output/bench-sim-raw.log`; override with `SIM_LOG=...`. Set
`SIM_REQUIRE_SUMMON=0`, `SIM_MIN_COLLECTED=0`, `SIM_MIN_COLLECTIONS=0`, or
`SIM_REQUIRE_COLLECTION_SET=0` only when you want a shorter smoke test.
For an automatic pass/fail bring-up, require the expected hardware modules and
at least one visible beacon:

```sh
RADAR_PORT=/dev/cu.usbmodem101 \
DIAG_CALIBRATE=1 \
DIAG_REQUIRE_ONLINE=touch,imu,ble,audio \
DIAG_MIN_BEACONS=1 \
DIAG_TIMEOUT=30 \
tools/bringup_diag.sh monitor
```

For an actual play session with friends, use the clean recorder firmware instead
of the debug-HUD diagnostics firmware:

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/record_field_hunt.sh all
```

The radar screen stays in the field UI, but the USB serial log still captures
hardware status, beacon RSSI, touch events, serial commands, collection events,
and summon state. It writes `output/field-hunt-report.json`, a friend-facing
post-game report at `output/field-hunt-report.md`, a more technical report at
`output/field-hunt-bench-report.md`, and the raw transcript at
`output/field-hunt-raw.log`. The post-game report focuses on whether the round
was completed, missing balls, collection timeline, RSSI at capture, and hunt
reset/start events. For a strict post-game pass/fail check after all seven balls
are found, run monitor mode with:

```sh
HUNT_MIN_COLLECTIONS=7 \
HUNT_REQUIRE_COLLECTION_SET=1 \
HUNT_REQUIRE_SUMMON=1 \
RADAR_PORT=/dev/cu.usbmodem101 \
tools/record_field_hunt.sh monitor
```

## Browser preview

Open `preview/radar_ui.html` directly in a browser to inspect the prop screen
without hardware. The segmented control below the device switches between the
same firmware personalities:

- `DEFAULT` shows the clean anime-style demo screen with simulated balls.
- `FIELD` starts on an empty rectangular grid and disables center-tap simulated
  collection, matching the helper script's real-play build.
- `SIM` mirrors the one-board bench build with a clean field UI and deterministic
  simulated `DBALL-*` targets.
- `DEBUG` enables the calibration HUD, scan line, star-marked balls, collection
  strip, 16-bin bearing strip, and RSSI-style tuning bar.

The same modes can be opened directly with `preview/radar_ui.html?mode=field`
or `preview/radar_ui.html?mode=debug`; use `preview/radar_ui.html?mode=sim` for
the simulated bench preview.

To capture repeatable visual QA snapshots after UI changes, run:

```sh
tools/capture_preview_screenshots.sh
tools/smoke_preview_interactions.sh
tools/verify_preview_visuals.py --json output/preview-visual-audit.json --md output/preview-visual-audit.md
tools/verify_firmware_ui_contract.py --json output/firmware-ui-contract.json
tools/verify_ui_parity.py --json output/firmware-preview-parity.json
tools/generate_visual_qa_sheet.py --output output/visual-qa.html
tools/generate_motion_gifs.py --image-dir output/playwright --output-dir output/motion
tools/verify_motion_gifs.py output/motion --json output/motion-gif-audit.json --md output/motion-gif-audit.md
tools/generate_motion_qa_sheet.py --output output/motion-qa.html
tools/generate_fidelity_review.py --output output/fidelity-review.zh.md
tools/generate_play_cards.py --output output/game-cards.html
tools/generate_usb_bringup_card.py --output output/usb-bringup-card.zh.md
tools/generate_refresh_perf_card.py --output output/refresh-performance-card.zh.md
tools/run_no_reset_display_check.py --sample-report output/diag-simulator-report.json
tools/analyze_board_photo.py output/playwright/radar-default.png --crop-output output/board-photo-qa-sample-crop.png --overlay-output output/board-photo-qa-sample-overlay.png
tools/render_hardware_proof_packet.py --json output/hardware-proof-packet.json --md output/hardware-proof-packet.zh.md
tools/run_missing_hardware_gates.py --json-output output/missing-hardware-gates-plan.json --md-output output/missing-hardware-gates-plan.zh.md
tools/render_goal_completion_audit.py --json output/goal-completion-audit.json --md output/goal-completion-audit.zh.md
tools/run_preboard_acceptance.py --release-dir output/release-current --output-dir output/preboard-acceptance-current
```

Or run the combined local verifier:

```sh
tools/verify_project.sh quick
tools/verify_project.sh firmware
tools/verify_project.sh full
```

`quick` runs the preview, visual checks, firmware UI contract audit,
firmware/preview parity audit, diagnostic simulator, and packaging dry-runs.
`firmware` also builds the field, fielddiag, debug, diagnostic, and
simulated-beacon radar images, and `full` also builds all seven beacon images.

To get a single current-state acceptance summary after local checks or hardware
runs:

```sh
tools/render_project_status.py --output output/project-status.md
```

That report separates proven local software evidence from missing real-hardware
evidence, so it should still say hardware completion is not proven until the
real board, one-board sim, seven physical beacons, and a clean field hunt have
all produced passing reports.

When the radar board is connected, the one-command hardware acceptance flow is:

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/run_hardware_acceptance.sh all
```

It runs the required gates in order: hardware bring-up, one-board simulated
seven-ball bench, physical seven-beacon verification, strict clean field hunt,
project status render, and release packaging. Reports are archived under
`output/hardware-acceptance-current/` and copied to the canonical `output/*.json`
paths used by `tools/render_project_status.py`. Run
`ACCEPTANCE_DRY_RUN=1 tools/run_hardware_acceptance.sh all` to print the exact
commands without touching the board.

To prepare a handoff folder after local checks, package the currently built
firmware images and evidence:

```sh
tools/package_release.sh
```

For a complete firmware handoff, build the requested radar modes first and fail
if any image is missing:

```sh
RELEASE_BUILD=1 RELEASE_STRICT=1 tools/package_release.sh
```

The package writes `index.html`, `MANIFEST.md`, `firmware/`, `preview/`, `evidence/`, and
`docs/` under `output/release/dragon-radar-*`. It intentionally copies only the
public private-logo hook example, not your ignored `private_boot_logo.h` source;
the local logo is already compiled into firmware binaries built on this machine.
The release evidence includes `evidence/private-boot-logo-setup.json` and
`evidence/private-boot-logo-setup.md`, which prove the local setup and gitignore
boundary without embedding the private source contents.
It includes `docs/board-sim-test.zh.md`, a Chinese one-board simulation guide
for testing before the seven physical BLE beacons are ready.
It includes `docs/product-design.zh.md`, a Chinese product design and
feasibility guide for the GPS-free BLE beacon approach.
It includes `docs/beacon-build.zh.md`, a Chinese hands-on guide for making,
flashing, labeling, hiding, and verifying the seven physical BLE beacons.
It includes `docs/quickstart.zh.html`, a Chinese first-run entry page with the
current hardware status, key links, and the recommended command sequence.
It also includes `tools/selftest_release.py` so the copied folder can validate
itself before hardware is attached.
It also includes `tools/run_preboard_acceptance.py` and
`docs/preboard-acceptance.zh.md` so the copied folder can prove its no-hardware
pre-board software chain without pretending to be real board evidence.
It also includes `docs/goal-completion-audit.zh.md`, a requirement-by-requirement
completion audit that should stay `not-complete` until real hardware reports
prove every gate.
It also includes `docs/usb-bringup-card.zh.md`, a Chinese USB bring-up card
that turns the latest serial diagnosis into a focused cable, BOOT/Reset, port
waiting, and first hardware-proof checklist.
It also includes `tools/diagnose_board_runtime.py`, which handles the common
case where `/dev/cu.usbmodem*` is visible but the radar app is not printing
`DIAG` lines, and tells you whether to press Reset/BOOT or reflash.
It also includes `tools/recover_board_runtime.py` for the same visible-serial
case when you want the package to try safe DTR/RTS recovery steps before manual
Reset/BOOT.
For the no-manual-reset path, pair that with
`tools/flash_release_firmware.sh sim`; the flash helper already uses esptool's
automatic reset behavior.
It also includes `docs/field-kit.html`, a printable one-page game-day checklist
covering smoke test, acceptance gates, beacon locations, and player records. It
also includes `docs/game-cards.html`, printable host/player cards for friend
playtests, DBALL hiding notes, and a proof-boundary reminder. It
also includes `docs/field-tuning-report.md`, a starting collection-threshold
recommendation generated from the best available DIAG evidence and labeled with
whether it is mock or hardware proof. It
also includes `docs/visual-qa.html`, an HTML contact sheet for the captured
boot, radar, and summon frames, plus `docs/motion-qa.html`, a storyboard for
reviewing the boot reveal, playable modes, and summon-completion motion. It
also includes `docs/fidelity-review.zh.md`, a Chinese UI fidelity review that
ties the visual audit, firmware source contract, preview/firmware parity, and
private-logo boundary together for manual anime-prop review. It
also includes `preview/boot-motion.gif`, `preview/radar-motion.gif`, and
`preview/summon-motion.gif` as lightweight playback previews generated from the
verified keyframes. These sit alongside `evidence/preview-visual-audit.json`
and `evidence/preview-visual-audit.md` with the pixel-level visual checks and a
human-readable fidelity report, plus `evidence/firmware-ui-contract.json` with
the source-level checks that keep the prop UI rectangular and the debug HUD out
of field/sim modes.
The package also includes `evidence/firmware-preview-parity.json` to prove the
browser preview and on-device firmware still agree on timing, grid scale, mode
semantics, and runtime controls. It also includes
`evidence/private-boot-logo-audit.json` and `.md` to prove the local
Capsule-style boot source was present, ignored by git, enabled in builds, and
not copied into the release package. It also includes
`evidence/usb-serial-diagnosis.zh.md` and `.json` so the latest package records
whether this computer currently sees a likely ESP32-S3 serial port. You can
also inspect `evidence/preboard-acceptance/preboard-acceptance-summary.json` to
confirm the packaged mock board simulation and seven-ball DIAG replay passed.
You can
regenerate the field kit directly with:

```sh
tools/generate_field_kit.py --output output/field-kit.html
```

The printed field kit uses the packaged acceptance command,
`tools/run_release_acceptance.sh all`, so it also works after the release folder
has been copied to another machine with PlatformIO/esptool available.

Each package also writes `RELEASE_AUDIT.json` and `CHECKSUMS.sha256`. Recheck the
folder before copying it or flashing from it with:

```sh
tools/verify_release_package.py output/release-current --write
```

It renders frozen boot keyframes, `DEFAULT`, `FIELD`, `SIM`, `DEBUG`, and two
all-collected summon frames through a temporary local HTTP server, then writes
canvas-only PNGs to `output/playwright/`. Use the boot captures to check the
staged grid wake, Capsule-style logo scan, and handoff. Use the default, field,
and sim captures to check that the playable UI remains a rectangular coordinate
grid without concentric radar rings.
The verifier enforces those same basics automatically: boot frames must contain
the expected green grid and blue/white logo pixels, field mode must stay empty
of orange targets, sim mode must show deterministic orange targets without the
debug HUD, default/debug must show targets, and default/field/sim must not look
like concentric ring radar screens. It also checks that the completed-hunt summon
frames contain green square-grid energy and orange balls converging at the
center. When run with `--json` and `--md`, it writes
`output/preview-visual-audit.json` with every pixel-count threshold, actual
value, and ring-coverage measurement, plus `output/preview-visual-audit.md` for
manual review.

## UI behavior

- Boot: no status text, just the green rectangular grid, scan wake, staged logo
  reveal, seven small rectangular progress ticks, a subtle phosphor scanline
  mask, six short phase-bound startup tones, and a short text-free acquisition
  sweep as the main radar comes online.
- Default radar: rectangular coordinate grid clipped by the circular AMOLED,
  bright center axes, small tick marks, subtle intersection shimmer, orange
  target blips snapped to the coordinate grid with a short horizontal phosphor
  bloom and fading afterimage marks, a brief square acquisition echo on the
  active target, a text-free rectangular edge pulse for the nearest clean target,
  and no concentric radar rings.
- Collected targets flash with a short square lock glyph, then disappear from
  the normal radar so the hunt keeps pointing at remaining balls.
- When a real beacon is close enough to collect, the target gets a small
  text-free corner lock with a charging square frame before the collection
  flash.
- After the seventh ball is collected, all seven stored points briefly travel
  along horizontal/vertical grid paths into the center, then a square seven-tick
  center core pulse confirms the completed set before the final orbit animation.
- Audio pings become faster, brighter, and slightly louder as the strongest
  remaining beacon gets closer. The boot sequence plays a short scan/logo/
  handoff cue ladder instead of a single generic beep.
- Map scale changes use a short three-segment green tick flash instead of
  showing `x2` or other modern UI text in the default prop mode.
- Field radar: same visual style, but starts empty until a real `DBALL-*`
  beacon is received. While empty it shows only a text-free rectangular search
  lattice and sweep ticks, never fake orange balls.
- Debug radar: adds heading/status text, a scan line, optional star-marked
  balls, a 16-bin bearing strip, and an RSSI calibration strip for tuning
  direction and collection distance.

`private_boot_logo.h.example` shows the function signature for private logo art.
The main sketch passes a `phase` value from 0.0 to 1.0, so custom artwork can
fade, pulse, or reveal without changing the main firmware.
Use `tools/install_private_boot_logo.py status --json-output output/private-boot-logo-setup.json`
before packaging if you want a fresh local setup report in `output/`.

## Beacon protocol

The firmware recognizes BLE advertisements whose name contains:

```text
DBALL-1
DBALL-2
...
DBALL-7
```

The bundled ESP32 beacon firmware also puts a compact fallback signature in
manufacturer data: exactly three bytes, `0x44 0x42 <index>`, where `<index>` is
`1..7`. The radar accepts either the name or that exact payload, which makes
field scanning more reliable if a BLE stack omits the name in one advertisement
without broadly matching unrelated BLE devices.

In the bundled beacon firmware, the name and manufacturer ID are in the primary
advertising packet; the 128-bit service UUID is moved to the scan response so
the radar can identify a ball before scan-response data arrives.

RSSI controls approximate range. Direction is intentionally game-like and does
not require GPS: as the player slowly turns the radar, each beacon accumulates
RSSI evidence across 16 IMU-derived heading bins. The strongest bin becomes the
display direction, so sweeping the radar in place makes the orange blip settle
toward the side where the signal was strongest. For reliable true direction,
add UWB or use a phone compass/GPS bridge.

RSSI is smoothed before it moves a blip, so the target does not jump on every
advertisement. The bearing bins also decay slowly, which lets the displayed
direction adapt when the player moves to a new area without snapping randomly.
A newly discovered or reacquired beacon briefly flashes a grid-aligned square
acquisition echo and then settles into a plain orange blip even while BLE
advertisements continue. If a beacon drops out briefly, the radar keeps a dimmer
last-known trace for about 45 seconds, which makes room-scale play feel steadier
when BLE packets are missed.

The strongest uncollected beacon also drives the ping cadence: far targets beep
slowly, and near targets beep faster with a higher tone.

## Test beacons

Open `firmware/DragonBallBeacon/DragonBallBeacon.ino` on any spare ESP32 board.
Build once per ball with this compile flag changed from 1 to 7:

```text
-DDRAGON_BALL_INDEX=1
```

Or build all seven indexes with:

```sh
tools/build_beacons.sh
```

The script defaults to `esp32-s3-devkitc1-n8r8`. Override it for another spare
ESP32 board with `BEACON_BOARD=... tools/build_beacons.sh`.

Beacon advertising can be tuned for response speed or battery life:

```sh
BEACON_PROFILE=fast tools/build_beacons.sh
BEACON_PROFILE=battery tools/upload_beacon.sh 1
BEACON_ADV_MIN_MS=80 BEACON_ADV_MAX_MS=160 tools/upload_beacon.sh 2
```

`fast` uses 60-120 ms advertisements, `balanced` uses 100-200 ms, and
`battery` uses 400-900 ms. Faster beacons feel more responsive but drain small
USB batteries sooner.

Upload one numbered beacon to a connected spare ESP32:

```sh
tools/upload_beacon.sh 1
tools/upload_beacon.sh 2
...
tools/upload_beacon.sh 7
```

Use `BEACON_PORT=/dev/cu.usbmodem101 tools/upload_beacon.sh 3` when multiple
boards are connected. The upload script uses the same `BEACON_BOARD`,
`BEACON_PLATFORM`, and `PIO_BIN` environment overrides as the build script. Set
`BEACON_DRY_RUN=1` to compile the selected beacon without uploading.

For the real seven-ball set, use the guided uploader. It prompts you to plug in
one spare ESP32 at a time, flashes `DBALL-1` through `DBALL-7`, and writes a
small manifest plus upload log:

```sh
tools/flash_beacon_set.sh all
BEACON_PROFILE=battery tools/flash_beacon_set.sh all
```

The default files are `output/beacon-set-manifest.md` and
`output/beacon-set-flash.log`. Override them with `BEACON_SET_MANIFEST=...` and
`BEACON_SET_LOG=...` if you want a dated record for a finished prop set. Use
`BEACON_SET_DRY_RUN=1 tools/flash_beacon_set.sh 1 2` to check the sequence
without touching hardware.

After flashing the set, power all seven beacons and verify them through the radar
diagnostic firmware:

```sh
RADAR_PORT=/dev/cu.usbmodem101 tools/verify_beacon_set.sh all
```

This requires `touch`, `imu`, `ble`, and `audio` online, waits up to 60 seconds
for all seven `DBALL-*` indexes, and writes `output/beacon-set-verify-report.json`,
`output/beacon-set-verify-report.md`, and `output/beacon-set-verify-raw.log`.
Use `tools/verify_beacon_set.sh monitor` when the diagnostic radar firmware is
already flashed.

Generate printable labels before putting the beacons into enclosures or battery
pouches:

```sh
tools/generate_beacon_labels.py
BEACON_PROFILE=battery tools/generate_beacon_labels.py --profile battery
```

The default output is `output/beacon-labels.html`; open it in a browser and
print it at 100% scale. The sheet includes one cut-out label per `DBALL-*` index
with a Dragon-Ball-style star marker and checkboxes for flashed, verified,
hidden, and found.

For a quick test, a phone BLE advertiser app can also broadcast names such as
`DBALL-1` and `DBALL-2`.

## Controls

- Press BOOT side button: cycle the map scale, like the top switch on the prop.
- Hold BOOT for about one second: reset the hunt and restart BLE scanning, with
  only a short green scan flash as confirmation.
- Tap center: collect the next simulated ball, useful for testing the complete
  seven-ball animation without BLE hardware. This is disabled by default in
  `field` and `near` helper builds. After the seventh simulated ball, one more
  center tap restarts the hunt with the same green reset sweep used by long
  press.
- Tap upper edge: same map-scale cycle, useful if the button is hard to reach
  in an enclosure.
- Tap lower edge: reset the hunt state and restart BLE scanning.
- Hold the screen for about one second: reset the hunt, matching the BOOT
  long-press behavior when the board is inside an enclosure.
- Tap left edge: cycle three screen brightness levels with a small bar flash.
- Tap right edge: cycle mute/low/normal/loud audio with a small wave flash.

The left/right edge brightness, audio preset, and display frame interval are
saved in ESP32 NVS, so the radar keeps those field adjustments across reboots.
Frame tuning is saved by milliseconds and old index-based saved values are
migrated on boot, so flashing a newer build should not silently move an old
`50ms` setting to a slower preset.

With the default build, simulated balls are shown until the first real BLE
beacon is seen so the UI can be tested immediately. A real beacon automatically
exits demo mode. Field and near helper builds start on an empty grid and disable
the center simulated-collection tap; use `DEMO_TOUCH=1 tools/build_radar.sh field`
when you explicitly want a testable field image.
The `sim` helper build goes one step further: it keeps the clean field UI but
feeds deterministic fake `DBALL-*` RSSI samples through the same target update
path used by real BLE advertisements. It is useful for a one-board bench demo
before the physical Dragon Ball beacons are ready.

When a real beacon stays above `-50 dBm` for about 1.2 seconds, that ball is
marked collected. After seven collected balls, the firmware pulls all seven
points into the center on square-grid paths, enters the complete collection
animation, and plays a repeating chime.

## Field setup checklist

1. Upload the field radar firmware:

   ```sh
   tools/build_radar.sh field upload
   ```

   If several serial devices are connected, set the port explicitly:

   ```sh
   RADAR_PORT=/dev/cu.usbmodem101 tools/build_radar.sh field upload
   ```

2. Upload one numbered beacon to each spare ESP32:

   ```sh
   tools/flash_beacon_set.sh all
   ```

3. Before hiding the beacons, power all seven and verify that the radar sees
   the complete set:

   ```sh
   RADAR_PORT=/dev/cu.usbmodem101 tools/verify_beacon_set.sh all
   ```

4. Power the beacons from small USB batteries and hide them around the play
   area. Start with a small room-scale test before moving outdoors.
5. Slowly turn in place for a second or two, then walk the radar toward the side
   where the orange blip settles. The blip moves inward as RSSI gets stronger.
   Collection triggers after about 1.2 seconds above the configured threshold,
   default `-50 dBm`. A small square lock charges around the blip while it is
   close enough; the captured blip then flashes briefly and disappears from the
   normal field radar. Use
   `DRAGON_RADAR_COLLECT_RSSI` and `DRAGON_RADAR_COLLECT_HOLD_MS` if your
   beacons are too strong or too weak in their enclosures.
6. Use the debug firmware only for calibration. Its small upper bearing strip
   shows the 16 RSSI direction bins for the strongest beacon; the white framed
   bin is the current IMU heading and the amber bin is the strongest remembered
   direction. Its bottom RSSI strip shows the strongest beacon number, raw RSSI,
   smoothed RSSI, a `-50 dBm` threshold line, and the close-hold progress. The
   normal and field builds keep the prop screen clean and text-free during play.
   If you want to record an actual round without visible debug text, use
   `tools/record_field_hunt.sh all`; it flashes the clean `fielddiag` firmware
   and records the hidden DIAG stream.
   After a manual reset, `RADAR_PORT=/dev/cu.usbmodem101 tools/run_missing_hardware_gates.py --execute`
   runs only the proof gates still missing from
   `output/hardware-proof-packet.json`, normally the seven-beacon scan and the
   clean field hunt.
7. For hardware bring-up, use `tools/bringup_diag.sh all`. Confirm `touch`,
   `imu`, `ble`, and `audio` are online, then move one beacon at a time and
   watch the `DBALL-*` RSSI, `bearingBin`, and `bearing` summaries change before
   tuning collection thresholds. Set `DIAG_CALIBRATE=1` while sweeping distance
   to get a candidate `COLLECT_RSSI` value from the observed RSSI distribution.
   Run `tools/recommend_field_tuning.py output/bringup-diag-report.json` to
   turn that calibration report into a field upload command.
   When the basics work, rerun monitor mode with `DIAG_REQUIRE_ONLINE=touch,imu,ble,audio`,
   `DIAG_MIN_BEACONS=1`, and `DIAG_TIMEOUT=30` for an automatic pass/fail check.
