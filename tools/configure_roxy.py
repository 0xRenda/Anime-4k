#!/usr/bin/env python3
"""Idempotent, narrow Xcode project integration for both VLC iOS targets."""
import hashlib
import json
from pathlib import Path
import plistlib
import re

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "vlc-ios-master"
PROJECT = APP / "VLC.xcodeproj/project.pbxproj"


def identifier(name):
    return hashlib.sha256(("Roxy Player:" + name).encode()).hexdigest()[:24].upper()


def object_block(text, uuid):
    pattern = re.compile(r"\t\t" + uuid + r" /\*[^\n]*\*/ = \{\n.*?\n\t\t\};", re.S)
    match = pattern.search(text)
    if not match:
        raise ValueError("Missing project object " + uuid)
    return match.group()


def insert_section(text, section, line):
    uuid = line.strip().split()[0]
    start = text.index("/* Begin " + section + " section */")
    end = text.index("/* End " + section + " section */", start)
    if re.search(r"\b" + uuid + r" /\*.*?\*/ =", text[start:end]):
        return text
    return text[:end] + line + "\n" + text[end:]


def add_to_list(text, uuid, field, line):
    block = object_block(text, uuid)
    value = line.strip().split()[0]
    if value in block:
        return text
    marker = field + " = (\n"
    if marker not in block:
        raise ValueError("Missing list " + field)
    return text.replace(block, block.replace(marker, marker + "\t\t\t\t" + line + "\n", 1), 1)


def main():
    text = PROJECT.read_text(encoding="utf-8")
    files = {"RoxyAnime4KEngine.swift": "sourcecode.swift", "RoxyAnime4KView.swift": "sourcecode.swift",
             "RoxyVLCVideoOutput.m": "sourcecode.c.objc", "RoxyVLCVideoOutput.h": "sourcecode.c.h"}
    group = identifier("group")
    group_line = f'\t\t{group} /* Roxy */ = {{isa = PBXGroup; children = (\n' + "".join(
        f"\t\t\t\t{identifier(name)} /* {name} */,\n" for name in files) + '\t\t\t); path = Roxy; sourceTree = "<group>"; };'
    text = insert_section(text, "PBXGroup", group_line)
    text = add_to_list(text, "7DC7BA6C28C892EA00109F28", "children", f"{group} /* Roxy */,")
    for name, kind in files.items():
        text = insert_section(text, "PBXFileReference",
            f'\t\t{identifier(name)} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {name}; sourceTree = "<group>"; }};')
    resource = identifier("resources")
    text = insert_section(text, "PBXFileReference",
        f'\t\t{resource} /* RoxyAnime4K */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = RoxyAnime4K; path = Resources/RoxyAnime4K; sourceTree = SOURCE_ROOT; }};')
    text = add_to_list(text, "7DC7BA6C28C892EA00109F28", "children", f"{resource} /* RoxyAnime4K */,")
    for target in ("7D94FCDA16DE7D1000F2623B", "7DA514352EF82B63000C9995"):
        # Discover phases from target rather than relying on unrelated IDs.
        block = object_block(text, target)
        product = re.search(r"productReference = ([A-F0-9]{24})", block)[1]
        text = re.sub(r'(\t\t' + product + r' /\*[^\n]*?\*/ = \{[^\n]*?path = )[^;]+;',
                      r'\1"Roxy Player.app";', text)
        for phase_type, names in (("Sources", [n for n in files if not n.endswith(".h")]), ("Resources", ["resources"])):
            phase = re.search(r"([A-F0-9]{24}) /\* " + phase_type + r" \*/", block)[1]
            for name in names:
                file_ref = resource if name == "resources" else identifier(name)
                label = "RoxyAnime4K" if name == "resources" else name
                build = identifier(target + name)
                text = insert_section(text, "PBXBuildFile",
                    f"\t\t{build} /* {label} in {phase_type} */ = {{isa = PBXBuildFile; fileRef = {file_ref} /* {label} */; }};")
                text = add_to_list(text, phase, "files", f"{build} /* {label} in {phase_type} */,")
        config_list = re.search(r"buildConfigurationList = ([A-F0-9]{24})", block)[1]
        configurations = re.findall(r"([A-F0-9]{24}) /\* (?:Debug|Release|Distribution) \*/", object_block(text, config_list))
        for config in configurations:
            original = object_block(text, config)
            changed = re.sub(r'PRODUCT_NAME = [^;]+;', 'PRODUCT_NAME = "Roxy Player";', original)
            changed = re.sub(r'PRODUCT_BUNDLE_IDENTIFIER = [^;]+;', 'PRODUCT_BUNDLE_IDENTIFIER = "${BUNDLE_IDENTIFIER_PREFIX}.player";', changed)
            changed = re.sub(r'DEVELOPMENT_TEAM = [^;]+;', 'DEVELOPMENT_TEAM = "";', changed)
            changed = re.sub(r'CODE_SIGN_ENTITLEMENTS = [^;]+;', 'CODE_SIGN_ENTITLEMENTS = Resources/iOS/Roxy.entitlements;', changed)
            changed = re.sub(r'ASSETCATALOG_COMPILER_APPICON_NAME = [^;]+;', 'ASSETCATALOG_COMPILER_APPICON_NAME = RoxyIcon;', changed)
            text = text.replace(original, changed)
    # project-level VLC module name keeps existing VLC-Swift.h imports valid.
    PROJECT.write_text(text, encoding="utf-8", newline="\n")
    scheme = APP / "VLC.xcodeproj/xcshareddata/xcschemes/Roxy.xcscheme"
    original = (scheme.parent / "VLC-iOS-no-watch.xcscheme").read_text()
    scheme.write_text(original.replace('BuildableName = "VLC-iOS-no-watch.app"', 'BuildableName = "Roxy Player.app"'))
    manifest = json.loads((APP / "Resources/RoxyAnime4K/manifest.json").read_text())
    quality = {"Type": "PSMultiValueSpecifier", "Title": "Anime4K quality", "Key": "RoxyAnime4KQuality",
               "DefaultValue": "automatic", "Titles": ["Automatic (device and temperature)", "Low", "Medium", "High"],
               "Values": ["automatic", "low", "medium", "high"]}
    shaders = [s["name"] for s in manifest["shaders"]]
    advanced = {"Type": "PSMultiValueSpecifier", "Title": "Advanced shader", "Key": "RoxyAnime4KShader",
                "DefaultValue": "preset", "Titles": ["Use quality preset"] + [s.removeprefix("Anime4K_") for s in shaders],
                "Values": ["preset"] + shaders}
    for filename in ("Root.plist", "Root.inApp.plist"):
        path = APP / "Resources/iOS/Settings.bundle" / filename
        document = plistlib.loads(path.read_bytes())
        specifiers = document["PreferenceSpecifiers"]
        specifiers[:] = [s for s in specifiers if s.get("Key") not in ("RoxyAnime4KQuality", "RoxyAnime4KShader")]
        specifiers.extend([quality, advanced])
        path.write_bytes(plistlib.dumps(document, sort_keys=False))
    info = APP / "Resources/iOS/Info.plist"
    document = plistlib.loads(info.read_bytes())
    document["CFBundleDisplayName"] = "Roxy Player"
    document["CFBundleName"] = "Roxy Player"
    for url_type in document.get("CFBundleURLTypes", []):
        url_type["CFBundleURLSchemes"] = [{"vlc": "roxy", "vlc-x-callback": "roxy-x-callback"}.get(value, value)
                                         for value in url_type.get("CFBundleURLSchemes", [])]
        if url_type.get("CFBundleURLName") == "VLC": url_type["CFBundleURLName"] = "Roxy Player"
    document["NSFaceIDUsageDescription"] = "Enable access to Face ID to unlock Roxy Player"
    info.write_bytes(plistlib.dumps(document, sort_keys=False))
    for path in (APP / "Resources").rglob("InfoPlist.strings"):
        raw = path.read_bytes()
        encoding = "utf-16" if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
        content = raw.decode(encoding)
        content = re.sub(r'("?CFBundle(?:DisplayName|Name)"?\s*=\s*)"[^"]*"', r'\1"Roxy Player"', content)
        content = content.replace('unlock VLC', 'unlock Roxy Player')
        path.write_bytes(content.encode(encoding))
    print("Configured Roxy iPhone/iPad targets, shared scheme and 49-shader selection")


if __name__ == "__main__":
    main()
