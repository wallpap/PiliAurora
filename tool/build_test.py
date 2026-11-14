"""Exercise the real PowerShell build entry with isolated SDK and compiler substitutes."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('pwsh'), 'PowerShell 7 is required')
class DefaultBuildTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        for directory in ('tool', '.dart_tool', 'sdk/bin', 'bin', 'android'):
            (self.root / directory).mkdir(parents=True)
        shutil.copyfile(ROOT / 'tool/build.ps1', self.root / 'tool/build.ps1')
        (self.root / '.dart_tool/package_config.json').write_text('{}')
        (self.root / 'pubspec.yaml').write_text('version: 2.0.0+555\n')
        (self.root / 'sdk/bin/flutter.bat').touch()
        (self.root / 'sdk/bin/flutter').touch()
        (self.root / 'bin/fvm.ps1').write_text('')
        (self.root / 'bin/dart.ps1').write_text(r'''
ConvertTo-Json -InputObject @('dart', $args) -Compress -Depth 5 | Add-Content "$env:BUILD_FIXTURE/calls.jsonl"
$global:LASTEXITCODE = 0
if ($args -contains 'pwsh') { Write-Output "$env:BUILD_FIXTURE/sdk/bin/flutter.bat"; return }
if ($args -contains 'build') {
    $mode = if ($args -contains '--debug') { 'Debug' } else { 'Release' }
    $runtime = "$env:BUILD_FIXTURE/build/windows/x64/runner/$mode"
    New-Item -ItemType Directory -Force $runtime | Out-Null
    Set-Content "$runtime/PiliAurora.exe" 'app'
    Set-Content "$runtime/flutter_windows.dll" 'stock'
}
''', encoding='utf-8')
        (self.root / 'bin/python.ps1').write_text(r'''
ConvertTo-Json -InputObject @('python', $args) -Compress -Depth 5 | Add-Content "$env:BUILD_FIXTURE/calls.jsonl"
$global:LASTEXITCODE = 0
if ($args -contains 'unpack') {
    if ($env:FAIL_ENGINE -eq 'true') { $global:LASTEXITCODE = 7; return }
    $output = $args[[array]::IndexOf($args, '--output') + 1]
    New-Item -ItemType Directory -Force $output | Out-Null
    Set-Content "$output/flutter_windows.dll" 'verified-engine'
    Set-Content "$output/libflutter.so" 'verified-engine'
    return
}
if ($args[0] -like '*build_apk.py') {
    $output = $args[[array]::IndexOf($args, '--output') + 1]
    New-Item -ItemType Directory -Force (Split-Path $output) | Out-Null
    Set-Content $output 'signed-apk'
    Set-Content ([IO.Path]::ChangeExtension($output, '.json')) '{"identityDigest":"verified"}'
    New-Item -ItemType Directory -Force 'build/app/outputs/flutter-apk' | Out-Null
    Set-Content 'build/app/outputs/flutter-apk/app-release.apk' 'stock-apk'
    return
}
if ($args -contains '--verify-standard-output') { return }
$profile = $args[[array]::IndexOf($args, '--profile') + 1]
$library = $args[[array]::IndexOf($args, '--library') + 1]
$hash = if ($profile -eq 'standard') { '' } else { (Get-FileHash $library).Hash.ToLowerInvariant() }
@{ identityDigest = 'verified'; identity = @{ binarySha256 = $hash }; dartDefines = @("PILIAURORA_PRESENTATION_PROFILE=$profile", 'PILIAURORA_ENGINE_IDENTITY=verified') } | ConvertTo-Json -Compress -Depth 5
''', encoding='utf-8')

    def run_build(self, *arguments, **environment):
        env = {**os.environ, 'BUILD_FIXTURE': str(self.root),
               'PATH': str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
               'ANDROID_HOME': str(self.root / 'android'), 'FAIL_ENGINE': '',
               'PILIAURORA_TEST_RELEASE': '', **environment}
        result = subprocess.run(['pwsh', '-NoProfile', '-File', str(self.root / 'tool/build.ps1'),
                                 '-SkipPubGet', '-SkipPatch', *arguments],
                                cwd=self.root, env=env, capture_output=True, text=True,
                                encoding='utf-8', errors='replace', timeout=60)
        calls = self.root / 'calls.jsonl'
        self.calls = [json.loads(line) for line in calls.read_text(encoding='utf-8-sig').splitlines()] if calls.exists() else []
        return result

    def test_default_windows_binds_and_installs_verified_release(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        runtime = self.root / 'build/windows/x64/runner/Release'
        self.assertEqual((runtime / 'flutter_windows.dll').read_text().strip(), 'verified-engine')
        self.assertEqual(json.loads((runtime / 'engine-identity.json').read_text())['identityDigest'], 'verified')
        self.assertTrue((self.root / 'build/windows-engine-config.json').is_file())
        build = next(args for tool, args in self.calls if tool == 'dart' and 'build' in args)
        self.assertIn('--release', build)
        self.assertIn('--dart-define=pili.name=2.0.0', build)
        self.assertIn('--dart-define=pili.code=555', build)
        self.assertIn('--dart-define=PILIAURORA_PRESENTATION_PROFILE=windowsDwmPaced', build)

    def test_android_default_builds_each_abi_with_matching_engine(self):
        result = self.run_build('-Platform', 'android')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        builds = [args for tool, args in self.calls if tool == 'python' and args[0].endswith('build_apk.py')]
        self.assertEqual(len(builds), 3)
        for args, abi, arch in zip(builds, ('armeabi-v7a', 'arm64-v8a', 'x86_64'), ('arm', 'arm64', 'x64')):
            self.assertEqual(args[args.index('--abi') + 1], abi)
            self.assertIn(f'android-{arch}', args[args.index('--engine-library') + 1])
            self.assertTrue((self.root / args[args.index('--output') + 1]).is_file())

    def test_dev_release_uses_arm64_and_retains_final_signed_flutter_output(self):
        result = self.run_build('-Platform', 'android', PILIAURORA_TEST_RELEASE='true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        builds = [args for tool, args in self.calls if tool == 'python' and args[0].endswith('build_apk.py')]
        self.assertEqual(len(builds), 1)
        self.assertEqual(builds[0][builds[0].index('--mode') + 1], 'dev-release')
        self.assertEqual(builds[0][builds[0].index('--abi') + 1], 'arm64-v8a')
        self.assertEqual((self.root / 'build/app/outputs/flutter-apk/app-release.apk').read_text().strip(), 'signed-apk')

    def test_failed_artifact_validation_prevents_application_compilation(self):
        result = self.run_build(FAIL_ENGINE='true')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(tool == 'dart' and 'build' in args for tool, args in self.calls))

    def test_debug_verifies_sdk_output_without_unpacking_release(self):
        result = self.run_build('-Mode', 'debug')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(any('unpack' in args for _, args in self.calls))
        self.assertTrue(any('--verify-standard-output' in args for _, args in self.calls))

    def test_profile_requires_matching_artifact_before_build(self):
        result = self.run_build('-Mode', 'profile')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls, [])

    def test_default_capture_rejects_main_application_before_launch(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for relative in ('tool/probes/windows/measure_danmaku.ps1',
                         'tool/engine/windows_frame_pacing/engine_identity.ps1'):
            destination = self.root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        result = subprocess.run([
            'pwsh', '-NoProfile', '-File', str(self.root / 'tool/probes/windows/measure_danmaku.ps1'),
            '-PresentMonPath', str(self.root / 'build/windows/x64/runner/Release/PiliAurora.exe'),
            '-SkipBuild', '-OutputDirectory', str(self.root / 'capture')],
            cwd=self.root, env={**os.environ, 'BUILD_FIXTURE': str(self.root), 'FAIL_ENGINE': '',
                                'PATH': str(self.root / 'bin') + os.pathsep + os.environ['PATH']},
            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=60)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('输出不是当前弹幕探针', result.stderr)


if __name__ == '__main__':
    unittest.main()
