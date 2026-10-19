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
