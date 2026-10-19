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
