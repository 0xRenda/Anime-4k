# Validation record — 2026-10-19

Executed in the Windows workspace:

| Check | Result |
| --- | --- |
| `python tools/port_anime4k.py --check` | Passed: all 49 generated sources and manifest match the supplied input corpus |
| `python -m unittest discover -s tests -p "test_*.py" -v` | Passed: 16 tests |
| Xcode project OpenStep parsing | Passed: 2,957 objects |
| Repeated `configure_roxy.py` | Passed: project and app plist remain byte-for-byte unchanged |
| Workflow YAML parsing | Passed |
| Swift grammar parsing | Passed for engine, renderer, frame queue and Metal smoke harness |
| Bash grammar parsing | Passed for build, signing and Metal test scripts |

Tests cover all original matrix coefficient strings, source hashes, pass graphs
at five scale ratios, presets, implicit texture bindings, conditional skip
behavior, the independently calculated small-CNN reference, project membership,
settings, and synthetic packaging rejection cases. Synthetic ZIP fixtures only
exercise the verifier; they are not executable IPA artifacts.

**Not executed in the initial Windows checks:** Ruby execution, CocoaPods/SPM resolution, Apple Metal
compilation, Swift typechecking, Xcode archive/export, code signing, CPU/GPU
numeric parity, or physical iPhone/iPad playback/performance tests. Grammar
parsing does not establish that code compiles against Apple's SDKs. The workflow
contains these build checks, and the device checklist remains required. The
initial Windows checks produced no IPA. Later GitHub runner results follow below.

## First GitHub Actions verification failure

The initial Linux verification run failed at the generated-shader check. Python
compares `Path` values without case on Windows and with case on Linux, which
changed the order of four entries in `manifest.json`. Shader code and weights
were identical. The generator now sorts by case-preserving relative path
components explicitly. The manifest and advanced selection lists were regenerated.

The failure was reproduced locally by simulating Linux path comparisons. All
17 tests now pass, including a regression test that simulates both platforms
and compares every generated file byte-for-byte.

## First macOS build results

[Actions run 39296829334](https://github.com/0xRenda/Anime-4k/actions/runs/39296829334)
passed Linux verification and all 17 tests. On the macOS ARM64 runner with
Xcode 26.6, all 49 Metal shaders compiled. The Swift engine and smoke harness
compiled and executed on Metal: the small-CNN CPU/GPU comparison passed with
maximum absolute error **0.0009765625** (tolerance 0.012).

CocoaPods then rejected the supplied OneDriveSDK spec checksum in deployment
mode. The lockfile now records the checksum reported by CocoaPods 1.16.2 for
the already-pinned `810f82da` commit; no dependency versions or source commits
were changed. The app archive, IPA packaging, signing, and physical-device
tests are still pending.

The next run passed CocoaPods deployment installation, all 49 iOS Metal shader
compilations, SwiftPM resolution, and the pinned VLCKit symbol checks. Archiving
failed because VLCKit's bundled `vlc.h` includes an absent `libvlc_picture.h`.
The Objective-C bridge now declares only the two public vmem callback functions
and their opaque types, matching the pinned libvlc header at `005e69e67`.
Downloaded dependencies are cached on failed builds as well as successful ones.

## Successful iOS archive and IPA

[Actions run 39300188565](https://github.com/0xRenda/Anime-4k/actions/runs/39300188565)
completed successfully for commit `f6facefa165fbbdedefc9342124c8aa224a48af9`:

- Linux verification: all 17 tests passed.
- All 49 shaders compiled for both macOS and iPhoneOS.
- The real Metal small-CNN comparison passed with maximum error 0.0009765625.
- CocoaPods deployment installation, locked SwiftPM resolution, and VLCKit
  binary API checks passed.
- The full Roxy iOS app archived successfully with Xcode 26.6.
- IPA validation confirmed the arm64 executable, iPhone and iPad device family,
  49 Metal libraries, and all three quality presets.
- The unsigned IPA and build logs were uploaded as workflow artifacts.

The IPA artifact is `Roxy-Player-automatic-unsigned` (37,189,069-byte artifact
ZIP, retained for 14 days). Signing and physical-device playback/performance
testing remain outstanding. This successful build does not certify device
performance, HDR preservation, or enhanced Picture in Picture support.

## 4.0.1 media-opening fixes

The reported symptom is that sharing an MKV opens the library without starting
video. The revised file-opening path waits for scene activation, preserves the
original open-in-place options, coordinates provider access off the main thread,
and retains file access until the corresponding LibVLC session has stopped.
The document picker now accepts readable app-owned files without requiring a
security-scope grant, detects folders by their resource type, and waits for
dismissal before opening playback. Inbox moves are serialized and remember
their destinations when another import operation already moved the same file.

Playback replacements no longer overwrite the active completion or queue before
stopping. Startup and stop callbacks serialize replacements, including requests
received while VLCKit still has its initial play operation queued. Stale parsing
callbacks cannot expand an unrelated replacement queue.

Local shader freshness, all 17 Python tests, Swift/Bash grammar parsing, workflow
YAML parsing, and whitespace checks passed. Eleven new hosted iOS tests exercise
MKV sharing, local MP4 access, missing files, extensionless documents, dotted
folder names, completion ownership, rapid replacements, and actual delivery to
the Anime4K frame queue, repeated filenames, and recovery from decoder errors.
These tests must pass on the macOS runner before the
workflow uploads the new IPA. Physical-device/file-provider testing is pending.

The initial 4.0.1 runner archived the iOS app successfully. Subsequent review
also covered reused Inbox filenames and Stopped events emitted while resetting
a previous decoder error. The playback fixtures are now checked in (under
16 KB total), with all 288 H.264 frames in each decoded and checked locally
using Python 3.12.14/PyAV 19.0.1; simulator tests no longer install an encoder.

The first complete hosted test run compiled both app and test bundle, but its
results were invalid: upstream `main.m` deliberately launches without the app
delegate when XCTest is present. Consequently no app window or registered
playback defaults existed. The hosted scheme now explicitly requests real app
startup through `ROXY_PLAYBACK_TESTS=1`, and setup fails immediately if the
delegate is absent. Logic tests retain their original startup behavior.
Simulator compilation now precedes boot to reduce competing memory use on the
runner, with separate build and runtime logs. The corrected run's results follow below.

The corrected hosted run (39332415038) passed nine of ten tests, including real
MKV decoding, rapid replacement, completion ownership, decoder-error recovery,
and actual frames reaching Anime4K. The remaining test reproduced the reported
library symptom: decoding continued but fullscreen presentation was dropped
while a previous player was dismissing. Presentation now waits for that UIKit
transition and cancels stale requests on stop/close. A further regression test
explicitly opens a second video during the first player's dismissal animation.
The eleven-test run's result follows below. Failed runs did not publish an IPA.

## Successful 4.0.1 media-opening regression build

[Actions run 39335168812](https://github.com/0xRenda/Anime-4k/actions/runs/39335168812)
completed successfully for commit `d4ae79db95f22173c3cb2d9d64cfbbec20f232c6`:

- All 17 Python source checks passed.
- All 49 Metal shaders compiled for macOS and iPhoneOS; the small-CNN CPU/Metal
  comparison passed with maximum absolute error 0.0009765625.
- The iPhone/iPad app archived and passed IPA packaging validation.
- All **11 hosted iOS playback tests passed with zero failures**, including
  shared MKV decoding and visible player presentation, extensionless picker
  files, folder order, file-access ownership, repeated filenames, rapid
  replacements, recovery from decoder failure, Anime4K frame delivery, and
  opening a second video during the previous player's dismissal animation.
- Version **4.0.1**, build **1008**, was uploaded as
  [Roxy-Player-automatic-unsigned](https://github.com/0xRenda/Anime-4k/actions/runs/39335168812/artifacts/12227240821).
  The artifact contains all quality presets and is retained for 14 days.

The new IPA was left on GitHub for the user to download. Hosted tests validate
the app's file-opening and playback paths, but do not replace physical iPhone/
iPad share-sheet, external file-provider, signing, or sustained performance
testing. Those checks remain in the device checklist.


## 4.0.2 color correction and interface

The reported purple/blue video exposed a real channel-layout error in the
callback bridge. VLC 4 at the pinned libvlc revision `005e69e67` defines RV32 as
**XRGB in memory order**. Treating that buffer as BGRA moved padding and RGB
bytes into the wrong channels. The bridge now requests the explicit `BGRA`
fourcc used by both its CoreVideo pixel buffer and Metal texture.

The earlier callback-queue test checked delivery, not pixel colors, so it could
not detect this error. New tests decode synthetic BT.709 H.264 8-bit and HEVC
10-bit MKVs through the real app and read back the production presentation
shader. Each quality must produce 256×144 from a 128×72 video, preserve primary
and neutral colors, and support Original comparison. Retina drawable dimensions
are checked against the window screen scale. The independent small-CNN CPU/Metal
reference remains a separate check on shader arithmetic.

The first expanded run compiled the app but withheld the IPA after catching a
simulator target mismatch: loading an iPhoneOS metallib could succeed before
pipeline creation rejected it. CI now compiles separate simulator libraries
only after packaging the device archive. Runtime fallback validates the entire
pipeline chain before accepting a precompiled library. A paused restart waits
for an initial callback picture, and its test uses the API's normalized 0–1
position. File grants remain retained through the asynchronous output restart.

The visible Anime4K button and glass panel expose live quality selection,
original comparison, advanced shaders and actual resolution/pass/GPU metrics.
The library has a Roxy welcome card and Open Files action, and the app menu
provides direct Anime4K access. Native Liquid Glass requires iOS 26+; older
supported devices use system material. No iOS 27 SDK compatibility is claimed.


Repeated assignments of the same video output previously detached and reattached
it, clearing paused frames. Output attachment now runs immediately on the main
thread and leaves an unchanged parent in place. The latest frame remains held
through transitions; inactive queues still reject incoming frames. Metadata
cannot classify a confirmed video track as audio-only. Rendering tests wait for
a visible, settled player and hold a delivered frame during pipeline preparation.
The automated resume preference is explicitly Never (-1), rather than Ask (0).

### Successful 4.0.2 build

[Actions run 39394555839](https://github.com/0xRenda/Anime-4k/actions/runs/39394555839),
source commit `6612e1e705413d2fd0729bcef3e103a7433ace6b`, passed:

- All 17 source/packaging tests and generated-shader verification.
- All 49 shaders compiled for macOS, iPhoneOS and iPhone Simulator; the separate
  small-CNN CPU/Metal parity check passed.
- All 15 hosted iOS tests, with zero failures, including actual 2× output on
  Low/Medium/High for both H.264 8-bit and HEVC 10-bit SDR, original comparison,
  Retina dimensions, paused live enabling, file access, sharing and reopening.
- The visible Anime4K button opened the glass settings panel. Player, menu,
  library and rendered-color PNGs were saved in the validation artifact.

All 64 sampled color bars passed: maximum RGB channel error **4/255**;
maximum red/blue difference in neutral samples **0/255**. These are
synthetic test samples, not a certification of every media color space.

Version **4.0.2**, build **1017**, was uploaded as
`Roxy-Player-automatic-unsigned` (artifact ID **12252106873**; ZIP size
**37,224,543 bytes**, retained for 14 days). The new IPA was left on GitHub;
it was not downloaded into the Windows workspace. The app includes all quality
presets and advanced shaders. Signing, physical iPhone/iPad playback, external
file-provider grants and sustained device power/performance still require the
device checklist. The enhanced path remains SDR; HDR and enhanced Picture in
Picture are not certified by these tests.

## 4.0.3 M-series quality and responsiveness

The new source removes the native-size Auto bypass for restoration-capable
presets and replaces High's L restoration with the supplied VL model. Manual
quality no longer inherits an irreversible timing ceiling. Auto observes
delivered-frame cadence, lowers quality under sustained load and can recover.
Original weights and float16 intermediates remain unchanged.

Standard/Soft/Strong select upstream restoration families. Strong uses a second
restoration and conditional upscale only for Medium/High at display enlargement
of at least 2× in both dimensions. Source highlight statistics are retained until
the final PREKERNEL clamp. Powerful devices have larger bounded memory ceilings;
Strong falls back to Standard before reducing model quality if allocation fails.

The renderer asynchronously prepares and caches immutable pipelines. One finished
enhanced frame is reused for paused comparisons, captures and presentation-only
redraws. Unrelated settings and overlay visibility do not invalidate CNN work.
Retina drawable sizing has one explicit owner; unchanged layout does not resize
it. Thermal notifications invalidate processing only when an effective limit
changes. Settings use deferred cached shader catalogs, static cards, larger
controls, brighter playback contrast and an initially expanded sheet.

The paused-frame test waits for VLC's final delivered pause frame, completed
computation and display geometry to settle before recording a baseline. It then
requires unchanged CNN counts, input sequence and decoder cadence, plus identical
PNG pixels after unrelated preferences and Original comparison. Cache revision,
target size and miss reason are recorded to distinguish new source/display work
from unnecessary filtering.

Real VLC diagnostics exposed an 80 ms paused-picture redisplay loop: the previous
renderer accepted 752 callbacks and ran 644 CNN computations during a 60-second
paused check. The callback now rejects identical visible pixels before allocating
or copying another buffer. A production-queue test covers distinct buffers with
different padding, single-pixel changes, format changes and resumed playback.
The real playback test also requires repeated VLC displays to be suppressed
without changing input sequence, CNN count or rendered pixels.

A separate regression covers delayed audio-player switches after confirmed HEVC
video. Unknown track lists no longer prove audio-only media; queued presentation
work rechecks media identity, generation and discovered video tracks. Creating an
inactive player controller no longer takes over the playback delegate. A fresh
player is created after a completed stop when changing native/callback backends;
the previous player could fail native decoding if its first session used vmem.
The regression alternates enhanced/native sessions twice, requiring decoded
video and a visible surface each time. The hosted suite now contains 19 tests.

The independent Metal tests cover sustained synthetic overload, Auto recovery,
manual High selection, native restoration, all restoration modes and a CPU-derived
5×5 source highlight bound. The nonflat native-resolution fixture changes by up
to 0.28546 in a normalized RGB channel; this proves processing, not a perceptual
quality score. The original small-CNN reference error remains 0.0009765625.

### Successful 4.0.3 build

[Actions run 39610303389](https://github.com/0xRenda/Anime-4k/actions/runs/39610303389),
source `f6a1eff73d847de04ff7b32949ecd0f81baa243b`, passed:

- All 18 source/packaging tests and generated-shader verification.
- All 49 shaders compiled for macOS, iPhoneOS and iPhone Simulator. The actual
  Metal device ran the CPU-reference check, Auto overload/recovery, manual High,
  native restoration and all three restoration modes with source highlight bounds.
- All 19 hosted iOS tests, with zero failures, in 41.280 seconds. They include
  media opening, replacement/reopening, paused live enabling, backend changes,
  8-bit/10-bit rendered colors, Retina dimensions and visible settings controls.
- All 80 sampled color bars passed: maximum RGB channel error **3/255**;
  maximum neutral red/blue difference **0/255**. These synthetic samples do not
  certify every media color space.
- The paused High frame retained input sequence **21** and CNN count **1** through
  duplicate VLC displays, unrelated preferences and Original/Anime4K comparison.
  Returning to the enhanced view also required identical rendered PNG pixels.
- Saved menu/player PNGs were visually inspected for clipping and contrast at
  portrait iPhone size. iPad layouts and accessibility sizes still need device QA.

Version **4.0.3**, build **1022**, was uploaded as
`Roxy-Player-automatic-unsigned` (artifact ID **12351921573**; ZIP size
**37,248,933 bytes**, retained for 14 days). The IPA was left on GitHub and was
not downloaded into the Windows workspace. Every app variant includes all
presets and advanced shaders with their original weights.

No physical M5 iPad benchmark was performed. GPU timing and source FPS are runtime
measurements; source FPS estimates callback delivery cadence rather than the
container's declared rate. Skipped frames count latest-frame replacements between
presentations, not every possible decoder/pool drop. The path still uses VLC
software decode, a bounded BGRA copy and ordinary Metal compute. M5 tensor/Neural
Engine acceleration, zero-copy hardware decode, HDR and enhanced PiP remain
unimplemented. Use the device checklist for sustained performance and thermals.
