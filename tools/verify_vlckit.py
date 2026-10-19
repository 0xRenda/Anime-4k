#!/usr/bin/env python3
"""Check the pinned VLCKit binary's callback and accessor compatibility."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    candidates = [path for path in (ROOT / '.build/SourcePackages/artifacts').rglob('VLCKit.framework/VLCKit')
                  if 'ios-arm64' in str(path) and 'simulator' not in str(path)]
    if not candidates:
        raise SystemExit('Resolved device VLCKit binary was not found')
    binary = candidates[0]
    symbols = subprocess.check_output(['xcrun', 'nm', '-gU', str(binary)], text=True, stderr=subprocess.STDOUT)
    for name in ('libvlc_video_set_callbacks', 'libvlc_video_set_format_callbacks', 'libvlc_media_player_set_nsobject'):
        if '_' + name not in symbols:
            raise SystemExit('VLCKit does not expose required callback API: ' + name)
    if b'libVLCMediaPlayer\x00' not in binary.read_bytes():
        raise SystemExit('VLCKit does not contain the required libVLCMediaPlayer selector')
    print('Verified pinned VLCKit callback APIs and player accessor selector')


if __name__ == '__main__': main()
