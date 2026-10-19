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
xcrun simctl boot "$SIMULATOR_ID" 2>/dev/null || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcodebuild test -workspace vlc-ios-master/VLC.xcworkspace -scheme Roxy-PlaybackTests \
  -configuration Release -destination "id=$SIMULATOR_ID" \
  -derivedDataPath "$ROOT/.build/SimulatorTests" \
  -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages" -onlyUsePackageVersionsFromResolvedFile \
  -resultBundlePath "$ROOT/build/playback-tests-$ROXY_QUALITY.xcresult" \
  -parallel-testing-enabled NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
  2>&1 | tee "build/playback-tests-$ROXY_QUALITY.log"
