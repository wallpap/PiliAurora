"""Exercise the CI test entry with real PowerShell and a recording Flutter shim."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(shutil.which('pwsh'), 'PowerShell 7 is required')
class CiTestRunnerTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / 'tool').mkdir()
        (self.root / 'bin').mkdir()
        self.source = (ROOT / 'tool/run-ci-tests.ps1').read_text(encoding='utf-8')
        (self.root / 'tool/run-ci-tests.ps1').write_text(self.source, encoding='utf-8')
        (self.root / 'capture.py').write_text('''\
import json, os, sys
from pathlib import Path
output = Path(os.environ['CI_RUNNER_CALLS'])
count = len(output.read_text(encoding='utf-8').splitlines()) + 1 if output.exists() else 1
with output.open('a', encoding='utf-8') as stream:
    stream.write(json.dumps({'tool': sys.argv[1], 'args': sys.argv[2:]}) + '\\n')
if os.environ.get('CI_RUNNER_FAIL_CALL') == str(count):
    sys.exit(17)
''', encoding='utf-8')
        for tool in ('flutter', 'fvm'):
            if os.name == 'nt':
                shim = self.root / 'bin' / f'{tool}.bat'
                shim.write_text(
                    '@echo off\n'
                    f'"%CI_RUNNER_PYTHON%" "%CI_RUNNER_CAPTURE%" {tool} %*\n'
                    'exit /b %ERRORLEVEL%\n', encoding='utf-8')
            else:
                shim = self.root / 'bin' / tool
                shim.write_text(
                    '#!/bin/sh\n'
                    f'exec "$CI_RUNNER_PYTHON" "$CI_RUNNER_CAPTURE" {tool} "$@"\n',
                    encoding='utf-8')
                shim.chmod(0o755)

    def run_entry(self, tool, fail_call=None):
        calls_file = self.root / 'calls.jsonl'
        calls_file.unlink(missing_ok=True)
        env = {
            **os.environ,
            'PATH': str(self.root / 'bin') + os.pathsep + os.environ['PATH'],
            'CI_RUNNER_PYTHON': sys.executable,
            'CI_RUNNER_CAPTURE': str(self.root / 'capture.py'),
            'CI_RUNNER_CALLS': str(calls_file),
            'CI_RUNNER_FAIL_CALL': str(fail_call or ''),
        }
        result = subprocess.run(
            ['pwsh', '-NoProfile', '-File', str(self.root / 'tool/run-ci-tests.ps1'),
             '-FlutterTool', tool, '-Concurrency', '4'],
            cwd=self.root, env=env, capture_output=True, text=True,
            encoding='utf-8', errors='replace', timeout=30)
        calls = ([json.loads(line) for line in calls_file.read_text(encoding='utf-8').splitlines()]
                 if calls_file.exists() else [])
        return result, calls

    def selected_paths(self):
        common, platform = self.source.split('# 原生 Windows', 1)
        windows, linux = platform.split('elseif ($IsLinux)', 1)
        platform = windows if os.name == 'nt' else linux.split('Write-Host', 1)[0]
        return re.findall(r'^\s*"((?:test|tool)/[^"]+)"', common + platform, re.MULTILINE)

    def test_runs_every_selected_path_with_requested_concurrency(self):
        for tool in ('path', 'fvm'):
            with self.subTest(tool=tool):
                result, calls = self.run_entry(tool)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertGreater(len(calls), 1 if os.name == 'nt' else 0)
                if os.name != 'nt':
                    self.assertEqual(len(calls), 1)
                paths = []
                for call in calls:
                    arguments = call['args']
                    if tool == 'fvm':
                        self.assertEqual(arguments.pop(0), 'flutter')
                    self.assertEqual(arguments[:4], ['test', '--no-pub', '--concurrency', '4'])
                    if os.name == 'nt':
                        self.assertLess(sum(len(arg) + 3 for arg in arguments), 7000)
                    paths.extend(arguments[4:])
                self.assertEqual(paths, self.selected_paths())

    def test_failed_batch_returns_failure_after_other_batches_run(self):
        result, calls = self.run_entry('path', fail_call=1)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreater(len(calls), 1 if os.name == 'nt' else 0)


if __name__ == '__main__':
    unittest.main()
