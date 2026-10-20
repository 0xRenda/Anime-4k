import hashlib
import builtins
import importlib.util
import json
from pathlib import Path, PurePosixPath, PureWindowsPath
import plistlib
import re
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tools' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


port = module('port_anime4k')
MANIFEST = json.loads((port.OUTPUT / 'manifest.json').read_text())


def evaluate(expression, sizes):
    stack = []
    for token in expression.split():
        if token in ('+', '-', '*', '/', '<', '>'):
            rhs, lhs = stack.pop(), stack.pop()
            stack.append({'+': lambda: lhs + rhs, '-': lambda: lhs - rhs, '*': lambda: lhs * rhs,
                          '/': lambda: lhs / rhs, '<': lambda: int(lhs < rhs), '>': lambda: int(lhs > rhs)}[token]())
        elif token.endswith(('.w', '.h')):
            name, dimension = token.rsplit('.', 1)
            stack.append(sizes[name][0 if dimension == 'w' else 1])
        else:
            stack.append(float(token))
    if len(stack) != 1:
        raise ValueError('Malformed expression')
    return stack[0]


def chain(names, input_size, output_size, *, with_trace=False):
    main = input_size
    passes = 0
    deferred = []
    trace = []

    def run_pass(name, item, sizes):
        nonlocal passes
        sizes['HOOKED'] = sizes['MAIN']
        if any(bind not in sizes for bind in item['binds']): return
        if item.get('when') and not evaluate(item['when'], sizes): return
        width = evaluate(item['width'], sizes) if 'width' in item else sizes['MAIN'][0]
        height = evaluate(item['height'], sizes) if 'height' in item else sizes['MAIN'][1]
        trace.append({'shader': name, 'function': item['function'],
                      'hook': item['hook'], 'inputs': {bind: sizes[bind] for bind in item['binds']},
                      'output': (width, height)})
        sizes[item.get('save', 'MAIN')] = (width, height)
        passes += 1

    for name in names:
        shader = next(s for s in MANIFEST['shaders'] if s['name'] == name)
        sizes = {'MAIN': main, 'NATIVE': input_size, 'OUTPUT': output_size}
        for item in shader['passes']:
            if item['hook'] == 'PREKERNEL':
                deferred.append((name, item, sizes.copy()))
                continue
            run_pass(name, item, sizes)
        main = sizes['MAIN']
    # mpv's PREKERNEL stage runs after the complete MAIN hook chain. Named
    # statistics still refer to the earlier shader file's saved source data.
    for name, item, saved_sizes in deferred:
        sizes = saved_sizes | {'MAIN': main, 'NATIVE': input_size, 'OUTPUT': output_size}
        run_pass(name, item, sizes)
        main = sizes['MAIN']
    return (main, passes, trace) if with_trace else (main, passes)


class ShaderPortTests(unittest.TestCase):
    def test_complete_corpus_and_presets(self):
        self.assertEqual(len(MANIFEST['shaders']), 49)
        self.assertEqual(set(MANIFEST['presets']), {'low', 'medium', 'high'})
        for quality, names in MANIFEST['presets'].items():
            size, count = chain(names, (640, 360), (1280, 720))
            self.assertEqual(size, (1280, 720), quality)
            self.assertGreater(count, 1)

    def test_generated_sources_match_inputs(self):
        for name, expected in port.generate().items():
            with self.subTest(name=name): self.assertEqual((port.OUTPUT / name).read_bytes(), expected)

    def test_windows_and_linux_generate_identical_files(self):
        def platform_sort(path_type):
            def sort(values, *, key=None, reverse=False):
                values = list(values)
                if key is None and values and isinstance(values[0], Path):
                    key = lambda path: path_type(path.as_posix())
                return builtins.sorted(values, key=key, reverse=reverse)
            return sort

        # Simulate both platforms' default Path comparisons even when the test
        # itself runs on Windows. This reproduces the first Actions failure.
        with mock.patch.object(port, 'sorted', platform_sort(PureWindowsPath), create=True):
            windows = port.generate()
        with mock.patch.object(port, 'sorted', platform_sort(PurePosixPath), create=True):
            linux = port.generate()
        self.assertEqual(windows, linux)

    def test_original_weights_and_provenance_preserved(self):
        for shader in MANIFEST['shaders']:
            with self.subTest(name=shader['name']):
                original = (port.SOURCE / shader['source']).read_bytes()
                self.assertEqual(hashlib.sha256(original).hexdigest(), shader['sha256'])
                generated = (port.OUTPUT / (shader['name'] + '.metal')).read_text()
                matrices = re.findall(r'mat4\(([^)]+)\)', original.decode())
                self.assertEqual(matrices, re.findall(r'mat4\(([^)]+)\)', generated)[1:])
                notice = original.decode().split('//!DESC', 1)[0]
                self.assertTrue(generated.startswith(notice))
                self.assertIn('(float2(gid) + 0.5)', generated)
                self.assertIn('gid.x >= destination.get_width()', generated)
                self.assertEqual(generated.count('kernel void pass_'), len(shader['passes']))

    def test_every_shader_graph_at_multiple_scaling_ratios(self):
        for shader in MANIFEST['shaders']:
            for output in ((320, 180), (640, 360), (1280, 720), (1920, 1080), (3840, 2160)):
                with self.subTest(shader=shader['name'], output=output):
                    size, _ = chain([shader['name']], (640, 360), output)
                    self.assertGreater(size[0], 0)
                    self.assertGreater(size[1], 0)

    def test_upscale_conditions_skip_native_and_downscale(self):
        for size in ((320, 180), (640, 360)):
            actual, count = chain(MANIFEST['presets']['low'], (640, 360), size)
            self.assertEqual(actual, (640, 360))
            self.assertEqual(count, 0)

    def test_highlight_clamp_runs_after_enhancement_with_original_statistics(self):
        names = ['Anime4K_Clamp_Highlights', 'Anime4K_Restore_CNN_VL', 'Anime4K_Upscale_CNN_x2_VL']
        size, count, trace = chain(names, (640, 360), (1280, 720), with_trace=True)
        self.assertEqual(size, (1280, 720))
        self.assertEqual(count, len(trace))
        self.assertEqual(trace[0]['shader'], 'Anime4K_Clamp_Highlights')
        self.assertEqual(trace[0]['inputs']['MAIN'], (640, 360))
        final = trace[-1]
        self.assertEqual(final['shader'], 'Anime4K_Clamp_Highlights')
        self.assertEqual(final['hook'], 'PREKERNEL')
        self.assertEqual(final['inputs']['HOOKED'], (1280, 720))
        self.assertEqual(final['inputs']['STATSMAX'], (640, 360))
        self.assertEqual(final['output'], (1280, 720))

    def test_denoise_arrays_and_helper_context(self):
        source = (port.OUTPUT / 'Anime4K_Denoise_Bilateral_Median.metal').read_text()
        self.assertIn('#define KERNELSIZE 3', source)
        self.assertIn('thread vec4 v[KERNELLEN]', source)
        self.assertIn('return v[0];', source)
        self.assertNotIn('__ROXY_FUNCTION_', source)

    def test_implicit_main_binding_is_explicit_in_metal(self):
        shader = next(s for s in MANIFEST['shaders'] if s['name'] == 'Anime4K_Clamp_Highlights')
        self.assertIn('MAIN', shader['passes'][0]['binds'])
        for shader in MANIFEST['shaders']:
            generated = (port.OUTPUT / (shader['name'] + '.metal')).read_text()
            references = set(re.findall(r'\b\w+_(?:pos|pt|tex|texOff)\b', generated))
            definitions = set(re.findall(r'^#define (\w+)', generated, re.M))
            self.assertFalse(references - definitions, shader['name'])

    def test_unknown_directives_are_rejected(self):
        with self.assertRaises(ValueError): port.parse('//!DESC test\n//!COMPUTE unsupported')

    def test_numerical_reference_is_reproducible(self):
        actual = json.loads((ROOT / 'tests/fixtures/cnn_s_reference.json').read_text())
        self.assertEqual(actual, module('make_reference').reference())
        self.assertEqual(len(actual['expectedRGB']), actual['width'] * actual['height'] * 4)


class ProjectTests(unittest.TestCase):
    def test_iphone_ipad_branding_and_settings(self):
        app = ROOT / 'vlc-ios-master'
        info = plistlib.loads((app / 'Resources/iOS/Info.plist').read_bytes())
        self.assertEqual(info['CFBundleDisplayName'], 'Roxy Player')
        for name in ('Root.plist', 'Root.inApp.plist'):
            settings = plistlib.loads((app / 'Resources/iOS/Settings.bundle' / name).read_bytes())['PreferenceSpecifiers']
            shaders = [s for s in settings if s.get('Key') == 'RoxyAnime4KShader']
            self.assertEqual(len(shaders), 1)
            self.assertEqual(len(shaders[0]['Values']), 50)
        scheme = ET.parse(app / 'VLC.xcodeproj/xcshareddata/xcschemes/Roxy.xcscheme')
        self.assertTrue(all(r.attrib['BuildableName'] == 'Roxy Player.app' for r in scheme.findall('.//BuildableReference')))

    def test_sources_and_resources_in_both_ios_targets(self):
        project = (ROOT / 'vlc-ios-master/VLC.xcodeproj/project.pbxproj').read_text()
        configure = module('configure_roxy')
        for target in ('7D94FCDA16DE7D1000F2623B', '7DA514352EF82B63000C9995'):
            block = configure.object_block(project, target)
            phase = re.search(r'([A-F0-9]{24}) /\* Sources \*/', block)[1]
            contents = configure.object_block(project, phase)
            for name in ('RoxyAnime4KEngine.swift', 'RoxyAnime4KView.swift', 'RoxyInterface.swift', 'RoxyVLCVideoOutput.m'):
                self.assertIn(name, contents)


if __name__ == '__main__': unittest.main()
