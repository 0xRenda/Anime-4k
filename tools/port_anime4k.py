#!/usr/bin/env python3
"""Translate the supplied mpv GLSL shader corpus to Metal and a pass manifest.

No weights are trained, substituted, or downloaded. The original MIT notice and
SHA-256 of each input accompany the generated source. Run from any directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Anime4K-master/glsl"
OUTPUT = ROOT / "vlc-ios-master/Resources/RoxyAnime4K"
DIRECTIVES = {"DESC", "HOOK", "BIND", "SAVE", "WIDTH", "HEIGHT", "COMPONENTS", "WHEN"}
FUNCTION = re.compile(r"^(\s*)(float|int|vec[234]|void)\s+(\w+)\(([^\n]*)\)\s*\{", re.M)
HEADER = """#include <metal_stdlib>
using namespace metal;
using vec2 = float2;
using vec3 = float3;
using vec4 = float4;
using ivec2 = int2;
// GLSL and Metal matrices both store columns. Spell out the columns explicitly.
inline float4x4 mat4(%s) {
    return float4x4(%s);
}
""" % (", ".join(f"float a{i}" for i in range(16)),
       ", ".join("float4(" + ", ".join(f"a{i}" for i in range(j, j + 4)) + ")"
                 for j in range(0, 16, 4)))


def parse(source: str) -> list[dict]:
    passes: list[dict] = []
    current = None
    for raw in source.splitlines():
        line = raw.strip()
        if line.startswith("//!"):
            key, value = line[3:].split(maxsplit=1)
            if key not in DIRECTIVES:
                raise ValueError(f"Unsupported directive {key}")
            if key == "DESC":
                current = {"description": value, "binds": [], "code": []}
                passes.append(current)
            elif current is None:
                raise ValueError("Directive before DESC")
            elif key == "BIND":
                current["binds"].append(value)
            else:
                current[key.lower()] = int(value) if key == "COMPONENTS" else value
        elif current is not None and line and not line.startswith("//"):
            current["code"].append(raw)
    for item in passes:
        if item.get("hook") not in ("MAIN", "PREKERNEL"):
            raise ValueError(f"Unsupported hook: {item.get('hook')}")
        if "vec4 hook()" not in "\n".join(item["code"]):
            raise ValueError("Missing hook")
        # mpv exposes the hooked MAIN texture implicitly. Clamp_Highlights
        # references it even though its explicit BIND is called HOOKED.
        if "MAIN" not in item["binds"] and re.search(r"\bMAIN_(?:tex|texOff|pos|pt|size)\b", "\n".join(item["code"])):
            item["binds"].append("MAIN")
    return passes


def metal_pass(item: dict, index: int) -> str:
    binds = item["binds"]
    code = "\n".join(item["code"])
    # MSL requires compile-time array extents and explicit thread address spaces.
    sigma = re.search(r"#define SPATIAL_SIGMA ([0-9.]+)", code)
    if sigma:
        size = max(int(float(sigma[1])), 1) * 2 + 1
        code = re.sub(r"^#define KERNELSIZE .*", f"#define KERNELSIZE {size}", code, flags=re.M)
    code = re.sub(r"\b(vec4|float) (\w+)\[KERNELLEN\](?=[,)])", r"thread \1 \2[KERNELLEN]", code)
    # The upstream median function lacks a terminal return. Avoid undefined
    # results for non-finite/roundoff edge cases without changing normal results.
    if "getMedian(" in code:
        start = code.index("vec4 getMedian(")
        opening = code.index("{", start)
        depth = 1
        end = opening + 1
        while depth:
            depth += (code[end] == "{") - (code[end] == "}")
            end += 1
        code = code[:end - 1] + "    return v[0];\n" + code[end - 1:]
    context_types = ["float2 uv", "sampler textureSampler"] + [
        f"texture2d<float, access::sample> {name}" for name in binds]
    context_values = ["uv", "textureSampler"] + binds
    definitions: list[str] = []
    names = [m[3] for m in FUNCTION.finditer(code)]

    def save_definition(match):
        args = ", ".join(context_types + ([match[4]] if match[4].strip() else []))
        definitions.append(f"{match[1]}{match[2]} {match[3]}({args}) {{")
        return f"__ROXY_FUNCTION_{len(definitions) - 1}__"

    code = FUNCTION.sub(save_definition, code)
    for name in names:
        code = re.sub(r"\b" + name + r"\(\s*", name + "(" + ", ".join(context_values) + ", ", code)
    code = code.replace(", )", ")")
    for i, definition in enumerate(definitions):
        code = code.replace(f"__ROXY_FUNCTION_{i}__", definition)
    macros = []
    for bind in binds:
        macros += [f"#define {bind}_pos uv",
                   f"#define {bind}_size float2({bind}.get_width(), {bind}.get_height())",
                   f"#define {bind}_pt (float2(1.0) / {bind}_size)",
                   f"#define {bind}_tex(pos) {bind}.sample(textureSampler, (pos), level(0.0))",
                   f"#define {bind}_texOff(off) {bind}_tex(uv + {bind}_pt * float2(off))"]
    namespace = f"roxy_pass_{index}"
    args = [f"texture2d<float, access::sample> {b} [[texture({i})]]" for i, b in enumerate(binds)]
    args += [f"texture2d<float, access::write> destination [[texture({len(binds)})]]",
             "sampler textureSampler [[sampler(0)]]", "uint2 gid [[thread_position_in_grid]]"]
    result = "\n".join(macros) + f"\nnamespace {namespace} {{\n{code}\n}}\n"
    result += f"kernel void pass_{index}({', '.join(args)}) {{\n"
    result += "    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) return;\n"
    result += "    float2 uv = (float2(gid) + 0.5) / float2(destination.get_width(), destination.get_height());\n"
    result += f"    destination.write({namespace}::hook({', '.join(context_values)}), gid);\n}}\n"
    defined = re.findall(r"^#define (\w+)", result, re.M)
    return result + "\n".join(f"#undef {name}" for name in dict.fromkeys(defined)) + "\n"


def generate(source: Path = SOURCE) -> dict[str, bytes]:
    outputs: dict[str, bytes] = {}
    shaders = []
    for path in sorted(source.rglob("*.glsl")):
        raw = path.read_bytes()
        original = raw.decode("utf-8-sig")
        passes = parse(original)
        name = path.stem
        notice = original.split("//!DESC", 1)[0]
        digest = hashlib.sha256(raw).hexdigest()
        metal = notice + f"\n// Generated by tools/port_anime4k.py; input SHA-256: {digest}\n" + HEADER
        metal += "\n".join(metal_pass(item, i) for i, item in enumerate(passes))
        outputs[name + ".metal"] = metal.encode()
        shaders.append({"name": name, "source": path.relative_to(SOURCE).as_posix(),
                        "sha256": digest, "passes": [dict(
                            (k, v) for k, v in item.items() if k != "code") | {"function": f"pass_{i}"}
                            for i, item in enumerate(passes)]})
    manifest = {"schema": 1, "shaders": shaders, "presets": {
        "low": ["Anime4K_Upscale_CNN_x2_S"],
        "medium": ["Anime4K_Restore_CNN_S", "Anime4K_Upscale_CNN_x2_M"],
        "high": ["Anime4K_Restore_CNN_L", "Anime4K_Upscale_CNN_x2_VL"]}}
    outputs["manifest.json"] = (json.dumps(manifest, indent=2) + "\n").encode()
    return outputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if generated files are stale")
    args = parser.parse_args()
    outputs = generate()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    stale = []
    for name, data in outputs.items():
        path = OUTPUT / name
        if args.check:
            if not path.exists() or path.read_bytes() != data:
                stale.append(name)
        else:
            path.write_bytes(data)
    extra = set(p.name for p in OUTPUT.glob("*.metal")) - set(outputs)
    stale.extend(sorted(extra))
    if stale:
        raise SystemExit("Stale generated shaders: " + ", ".join(stale))
    print(f"{'Verified' if args.check else 'Generated'} {len(outputs) - 1} Metal shaders")


if __name__ == "__main__":
    main()
