#!/usr/bin/env python3
"""Independent CPU evaluation of the original small CNN, for Metal parity QA."""
from pathlib import Path
import json
import math
import re
import struct

ROOT = Path(__file__).resolve().parents[1]


def half(value):
    return struct.unpack('<e', struct.pack('<e', value))[0]


def reference():
    width, height = 8, 6
    pixels = [[((x * 31 + y * 17 + c * 67) % 256) / 255 for c in range(3)] + [1.0]
              for y in range(height) for x in range(width)]
    source = (ROOT / 'Anime4K-master/glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl').read_text()
    # Evaluate the original GLSL weights directly, independently of the Metal
    # translator, including column-major matrix products and half-float stores.
    current = pixels
    for section in source.split('//!DESC ')[1:-1]:
        terms = re.findall(r'mat4\(([^)]+)\)\s*\*\s*go_(\d+)\(([^,]+),\s*([^)]+)\)', section)
        matrices = [([float(n) for n in weights.split(',')], int(branch), int(float(dx)), int(float(dy)))
                    for weights, branch, dx, dy in terms]
        bias = [float(n) for n in re.search(r'result \+= vec4\(([^)]+)\)', section)[1].split(',')]
        first = 'MAIN_texOff' in section
        result = []
        for y in range(height):
            for x in range(width):
                values = bias.copy()
                for matrix, branch, dx, dy in matrices:
                    sample = current[max(0, min(height - 1, y + dy)) * width + max(0, min(width - 1, x + dx))]
                    activation = sample if first else [max((-v if branch else v), 0) for v in sample]
                    for row in range(4):
                        values[row] += sum(matrix[column * 4 + row] * activation[column] for column in range(4))
                result.append([half(v) for v in values])
        current = result

    def linear(x, y, channel):
        x0, y0 = math.floor(x), math.floor(y)
        tx, ty = x - x0, y - y0
        total = 0
        for dx in range(2):
            for dy in range(2):
                sample = pixels[max(0, min(height - 1, y0 + dy)) * width + max(0, min(width - 1, x0 + dx))]
                total += sample[channel] * (tx if dx else 1 - tx) * (ty if dy else 1 - ty)
        return total

    expected = []
    for y in range(height * 2):
        for x in range(width * 2):
            residual = current[(y // 2) * width + x // 2][(y % 2) * 2 + x % 2]
            expected.append([half(residual + linear((x + 0.5) / 2 - 0.5, (y + 0.5) / 2 - 0.5, c)) for c in range(3)])
    return {'width': width, 'height': height, 'input': pixels, 'expectedRGB': expected, 'tolerance': 0.012}


if __name__ == '__main__':
    output = ROOT / 'tests/fixtures/cnn_s_reference.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(reference(), indent=2) + '\n')
