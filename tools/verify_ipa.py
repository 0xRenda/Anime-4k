#!/usr/bin/env python3
"""Fail packaging if the real app, architecture, presets or shaders are absent."""
from pathlib import PurePosixPath
import json
import plistlib
import struct
import sys
import zipfile


def verify(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        info_paths = [name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist") and len(PurePosixPath(name).parts) == 3]
        if len(info_paths) != 1: raise ValueError("Expected exactly one top-level app")
        info = plistlib.loads(archive.read(info_paths[0]))
        app = info_paths[0].removesuffix("Info.plist")
        if str(path).endswith('-signed.ipa'):
            if app + '_CodeSignature/CodeResources' not in names or app + 'embedded.mobileprovision' not in names:
                raise ValueError('Signed IPA lacks a code signature or provisioning profile')
        if info["CFBundleDisplayName"] != "Roxy Player": raise ValueError("Incorrect app branding")
        if info.get("UIDeviceFamily") != [1, 2]: raise ValueError("Expected iPhone and iPad support")
        executable = archive.read(app + info["CFBundleExecutable"])
        # Device archives are arm64 thin Mach-O or universal with arm64 slice.
        if executable[:4] == b"\xcf\xfa\xed\xfe":
            if struct.unpack_from("<I", executable, 4)[0] != 0x0100000C: raise ValueError("Not an arm64 executable")
        elif executable[:4] in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            stride = 32 if executable[:4] == b"\xca\xfe\xba\xbf" else 20
            count = struct.unpack_from(">I", executable, 4)[0]
            if not any(struct.unpack_from(">I", executable, 8 + i * stride)[0] == 0x0100000C for i in range(count)):
                raise ValueError("Universal executable has no arm64 slice")
        else: raise ValueError("App executable is not a device Mach-O binary")
        manifest = json.loads(archive.read(app + "RoxyAnime4K/manifest.json"))
        if len(manifest["shaders"]) != 49: raise ValueError("Missing Anime4K shaders")
        if set(manifest["presets"]) != {"low", "medium", "high"}: raise ValueError("Missing quality presets")
        for shader in manifest["shaders"]:
            binary = archive.read(app + "RoxyAnime4K/" + shader["name"] + ".metallib")
            if binary[:4] != b"MTLB": raise ValueError("Invalid Metal library: " + shader["name"])
        print("Verified Roxy IPA: arm64, iPhone+iPad, 49 Metal libraries, three quality presets")


if __name__ == "__main__":
    verify(sys.argv[1])
