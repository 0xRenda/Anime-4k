#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
MODE="${1:-unsigned}"
export ROXY_QUALITY="${ROXY_QUALITY:-automatic}"
case "$MODE" in unsigned|signed) ;; *) echo 'Usage: bash tools/build_ipa.sh [unsigned|signed]' >&2; exit 2 ;; esac
case "$ROXY_QUALITY" in automatic|low|medium|high) ;; *) echo 'Invalid ROXY_QUALITY' >&2; exit 2 ;; esac
if [[ "$(uname -s)" != Darwin ]]; then echo 'Building an IPA requires macOS with Xcode. Use the GitHub Actions workflow.' >&2; exit 2; fi
export ROXY_SIGNED=false
if [[ "$MODE" == signed ]]; then
  export ROXY_SIGNED=true
  : "${APPLE_TEAM_ID:?Missing APPLE_TEAM_ID}"
  : "${ROXY_SIGNING_IDENTITY:?Run tools/install_signing.sh first}"
  : "${ROXY_PROFILE_NAME:?Run tools/install_signing.sh first}"
fi
mkdir -p build
xcodebuild -version
python3 tools/port_anime4k.py --check
python3 -m unittest discover -s tests -p 'test_*.py' -v
bundle check || bundle install
(cd vlc-ios-master && bundle exec pod install --deployment)
bundle exec ruby tools/prepare_ci.rb
if ! xcrun --sdk iphoneos metal --version >/dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain
fi
python3 tools/compile_metal.py --sdk iphoneos
python3 - <<'PY'
import os, plistlib
from pathlib import Path
path = Path('vlc-ios-master/Resources/iOS/Info.plist')
data = plistlib.loads(path.read_bytes())
data['RoxyDefaultAnime4KQuality'] = os.environ['ROXY_QUALITY']
data['CFBundleShortVersionString'] = '4.0.1'
data['CFBundleVersion'] = str(1000 + int(os.environ.get('GITHUB_RUN_NUMBER', '0')))
data['RoxyGitCommit'] = os.environ.get('GITHUB_SHA', 'local')
path.write_bytes(plistlib.dumps(data, sort_keys=False))
PY
BUILD_ARGS=(-workspace vlc-ios-master/VLC.xcworkspace -scheme Roxy -configuration Release
  -destination 'generic/platform=iOS' -archivePath "$ROOT/build/Roxy-$ROXY_QUALITY.xcarchive"
  -derivedDataPath "$ROOT/.build/DerivedData" -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages"
  -onlyUsePackageVersionsFromResolvedFile ARCHS=arm64 ONLY_ACTIVE_ARCH=NO)
xcodebuild -resolvePackageDependencies -workspace vlc-ios-master/VLC.xcworkspace -scheme Roxy \
  -clonedSourcePackagesDirPath "$ROOT/.build/SourcePackages" -onlyUsePackageVersionsFromResolvedFile
python3 tools/verify_vlckit.py
if [[ "$MODE" == unsigned ]]; then
  xcodebuild "${BUILD_ARGS[@]}" archive CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tee "build/xcodebuild-$ROXY_QUALITY.log"
  STAGING="$(mktemp -d "$ROOT/build/unsigned-$ROXY_QUALITY.XXXXXX")"
  mkdir -p "$STAGING/Payload"
  ditto "$ROOT/build/Roxy-$ROXY_QUALITY.xcarchive/Products/Applications/Roxy Player.app" "$STAGING/Payload/Roxy Player.app"
  # The result is intentionally unsigned and requires a sideloading signer.
  (cd "$STAGING" && /usr/bin/zip -qry "$STAGING/package.ipa" Payload)
  mv -f "$STAGING/package.ipa" "$ROOT/build/Roxy-Player-$ROXY_QUALITY-unsigned.ipa"
else
  xcodebuild "${BUILD_ARGS[@]}" archive 2>&1 | tee "build/xcodebuild-$ROXY_QUALITY.log"
  codesign --verify --deep --strict "$ROOT/build/Roxy-$ROXY_QUALITY.xcarchive/Products/Applications/Roxy Player.app"
  python3 - <<'PY'
import os, plistlib
options = {'method': os.environ.get('ROXY_EXPORT_METHOD', 'release-testing'),
           'teamID': os.environ['APPLE_TEAM_ID'], 'signingStyle': 'manual',
           'signingCertificate': os.environ['ROXY_SIGNING_IDENTITY'],
           'provisioningProfiles': {os.environ.get('ROXY_BUNDLE_ID', 'com.roxy.player'): os.environ['ROXY_PROFILE_NAME']},
           'stripSwiftSymbols': True, 'manageAppVersionAndBuildNumber': False}
with open('build/ExportOptions.plist', 'wb') as file: plistlib.dump(options, file)
PY
  xcodebuild -exportArchive -archivePath "$ROOT/build/Roxy-$ROXY_QUALITY.xcarchive" \
    -exportOptionsPlist build/ExportOptions.plist -exportPath "$ROOT/build/export-$ROXY_QUALITY" 2>&1 | tee "build/export-$ROXY_QUALITY.log"
  ditto "$ROOT/build/export-$ROXY_QUALITY/Roxy Player.ipa" "$ROOT/build/Roxy-Player-$ROXY_QUALITY-signed.ipa"
fi
python3 tools/verify_ipa.py "build/Roxy-Player-$ROXY_QUALITY-$MODE.ipa"
