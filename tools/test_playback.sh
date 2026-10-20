#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export ROXY_QUALITY="${ROXY_QUALITY:-automatic}"
mkdir -p build
test -s tests/fixtures/shared.mkv
test -s tests/fixtures/shared.mp4
bundle exec ruby tools/prepare_playback_tests.rb
xcrun simctl list devices available --json > .build/playback-simulators.json
SIMULATOR_ID="$(python3 - <<'PY'
import json
from pathlib import Path
devices = json.loads(Path('.build/playback-simulators.json').read_text())['devices']
for runtime in sorted(devices, reverse=True):
    if '.iOS-' not in runtime:
        continue
    for device in devices[runtime]:
        if device.get('isAvailable') and device['name'].startswith('iPhone'):
            print(device['udid'])
            raise SystemExit(0)
raise SystemExit('No available iPhone simulator runtime')
PY
)"
TEST_ARGS=(-workspace vlc-ios-master/VLC.xcworkspace -scheme Roxy-PlaybackTests
  -configuration Release -destination "id=$SIMULATOR_ID"
  -derivedDataPath "$ROOT/.build/SimulatorTests"
  -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages" -onlyUsePackageVersionsFromResolvedFile
  -parallel-testing-enabled NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='')
# Compile before booting iOS so the simulator does not compete with the Swift
# compiler for the hosted runner's memory. Keep build and runtime logs separate.
xcodebuild build-for-testing "${TEST_ARGS[@]}" 2>&1 | tee "build/playback-build-$ROXY_QUALITY.log"
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcodebuild test-without-building "${TEST_ARGS[@]}" \
  -resultBundlePath "$ROOT/build/playback-tests-$ROXY_QUALITY.xcresult" \
  2>&1 | tee "build/playback-tests-$ROXY_QUALITY.log"
APP_DATA="$(xcrun simctl get_app_container "$SIMULATOR_ID" "${ROXY_BUNDLE_ID:-com.roxy.player}" data)"
mkdir -p build/rendered-validation
cp "$APP_DATA/Library/Caches/RoxyValidation/"*.png build/rendered-validation/
