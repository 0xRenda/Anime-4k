#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/playback-fixtures build
if ! command -v ffmpeg >/dev/null 2>&1; then
  brew install ffmpeg
fi
# Generated test media contains only a synthetic moving test pattern.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i 'testsrc=size=64x48:rate=24' \
  -t 12 -c:v libx264 -pix_fmt yuv420p -an .build/playback-fixtures/shared.mkv
ffmpeg -hide_banner -loglevel error -y -i .build/playback-fixtures/shared.mkv \
  -c copy .build/playback-fixtures/shared.mp4
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
