#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .build/metal-tests
if ! xcrun --sdk macosx metal --version >/dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain
fi
python3 tools/compile_metal.py --sdk macosx --output .build/metal-tests
# Runtime engine falls back to source compilation on macOS. Never mix a macOS
# metallib with an iOS one in the application resource directory.
xcrun --sdk macosx swiftc -swift-version 5 -framework Metal \
  vlc-ios-master/Sources/Roxy/RoxyAnime4KEngine.swift tests/MetalSmoke.swift \
  -o .build/metal-tests/smoke
.build/metal-tests/smoke "$ROOT"
