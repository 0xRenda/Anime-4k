#!/usr/bin/env python3
"""Compile every ported shader using the actual Apple Metal compiler."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "vlc-ios-master/Resources/RoxyAnime4K"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", choices=["iphoneos", "iphonesimulator", "macosx"], default="iphoneos")
    parser.add_argument("--output", type=Path, default=RESOURCES)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    standard = "macos-metal2.3" if args.sdk == "macosx" else "ios-metal2.3"
    target = {"iphoneos": "air64-apple-ios15.0", "iphonesimulator": "air64-apple-ios15.0-simulator",
              "macosx": "air64-apple-macosx12.0"}[args.sdk]
    with tempfile.TemporaryDirectory(prefix="roxy-metal-") as temporary:
        def compile_one(source):
            intermediate = Path(temporary) / (source.stem + ".air")
            commands = [["xcrun", "--sdk", args.sdk, "metal", "-target", target, "-std=" + standard, "-fno-fast-math", "-c", str(source), "-o", str(intermediate)],
                        ["xcrun", "--sdk", args.sdk, "metallib", str(intermediate), "-o", str(args.output / (source.stem + ".metallib"))]]
            try:
                for command in commands:
                    subprocess.run(command, check=True, capture_output=True, text=True)
                return None
            except subprocess.CalledProcessError as error:
                return source.name + "\n" + error.stdout + error.stderr
        with ThreadPoolExecutor(max_workers=4) as executor:
            failures = [result for result in executor.map(compile_one, sorted(RESOURCES.glob("*.metal"))) if result]
    if failures:
        print("\n\n".join(failures), file=sys.stderr)
        raise SystemExit(1)
    print(f"Compiled all 49 shaders for {args.sdk}")


if __name__ == "__main__":
    main()
