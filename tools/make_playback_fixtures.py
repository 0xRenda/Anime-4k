#!/usr/bin/env python3
"""Regenerate our synthetic video samples; optional dependency: av==19.0.1."""
from fractions import Fraction
from pathlib import Path
import av

ROOT = Path(__file__).resolve().parents[1]


def main():
    for extension in ('mkv', 'mp4'):
        path = ROOT / 'tests/fixtures' / ('shared.' + extension)
        with av.open(str(path), 'w') as container:
            stream = container.add_stream('libx264', rate=24)
            stream.width, stream.height = 64, 48
            stream.pix_fmt = 'yuv420p'
            stream.options = {'preset': 'veryfast', 'crf': '28', 'threads': '1'}
            for index in range(288):
                frame = av.VideoFrame(64, 48, format='yuv420p')
                frame.pts, frame.time_base = index, Fraction(1, 24)
                for plane, value in zip(frame.planes, (20 + index % 200, 128, 144)):
                    plane.update(bytes([value]) * plane.buffer_size)
                for packet in stream.encode(frame):
                    container.mux(packet)
            for packet in stream.encode():
                container.mux(packet)
        with av.open(str(path)) as container:
            frames = list(container.decode(video=0))
            assert len(frames) == 288
            assert all((frame.width, frame.height) == (64, 48) for frame in frames)
        print(path.name, path.stat().st_size, 'bytes; decoded all 288 H.264 frames')


if __name__ == '__main__':
    main()
