#!/usr/bin/env python3
"""Regenerate our synthetic video samples; optional dependency: av==19.0.1."""
from fractions import Fraction
from pathlib import Path
import av

ROOT = Path(__file__).resolve().parents[1]


def color_bars():
    # Explicit BT.709 8/10-bit SDR samples. Neutral gray and RGB primaries
    # reveal channel-order/range bugs that decoding counters cannot detect.
    colors = [(220, 20, 20), (20, 220, 20), (20, 20, 220), (128, 128, 128),
              (220, 220, 220), (20, 20, 20), (20, 220, 220), (220, 220, 20)]
    for name, codec, fmt in [('bars-8bit.mkv', 'libx264', 'yuv420p'),
                             ('bars-10bit.mkv', 'libx265', 'yuv420p10le')]:
        path = ROOT / 'tests/fixtures' / name
        with av.open(str(path), 'w') as container:
            stream = container.add_stream(codec, rate=24)
            stream.width, stream.height, stream.pix_fmt = 128, 72, fmt
            stream.codec_context.thread_count = 1
            stream.codec_context.colorspace = 1
            stream.codec_context.color_primaries = 1
            stream.codec_context.color_trc = 1
            stream.codec_context.color_range = 1
            stream.options = {'preset': 'ultrafast', 'crf': '12'}
            if codec == 'libx265':
                stream.options['x265-params'] = 'pools=none:frame-threads=1:log-level=error:colorprim=bt709:transfer=bt709:colormatrix=bt709'
            for index in range(288):
                frame = av.VideoFrame(128, 72, 'rgb24')
                row = b''.join(bytes(color) * 16 for color in colors)
                plane = frame.planes[0]
                plane.update((row + bytes(plane.line_size - len(row))) * 72)
                # Match the stream's matrix, rather than relying on swscale defaults.
                frame = frame.reformat(format=fmt, dst_colorspace='ITU709')
                frame.colorspace = frame.color_primaries = frame.color_trc = 1
                frame.color_range = 1
                frame.pts, frame.time_base = index, Fraction(1, 24)
                for packet in stream.encode(frame): container.mux(packet)
            for packet in stream.encode(): container.mux(packet)
        with av.open(str(path)) as container:
            frames = list(container.decode(video=0))
            assert len(frames) == 288
            assert all((f.width, f.height) == (128, 72) for f in frames)
        print(name, path.stat().st_size, 'bytes; decoded all color-bar frames')


def main():
    color_bars()
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
