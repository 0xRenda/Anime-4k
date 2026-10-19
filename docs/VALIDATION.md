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

**Not executed here:** Ruby execution, CocoaPods/SPM resolution, Apple Metal
compilation, Swift typechecking, Xcode archive/export, code signing, CPU/GPU
numeric parity, or physical iPhone/iPad playback/performance tests. Grammar
parsing does not establish that code compiles against Apple's SDKs. The workflow
contains these build checks, and the device checklist remains required. No IPA
has been produced or claimed to work on a particular device.
