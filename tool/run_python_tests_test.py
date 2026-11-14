"""Test suite selection, concurrent execution and failure propagation."""

from contextlib import redirect_stdout
import io
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

import run_python_tests as runner


class PythonTestRunnerTest(unittest.TestCase):
    def test_registry_covers_tool_test_directories(self):
        directories = {path.parent.relative_to(runner.ROOT).as_posix()
                       for path in (runner.ROOT / 'tool').rglob('*_test.py')}
        self.assertEqual(set(runner.TEST_DIRECTORIES.values()), directories)

    def test_selected_suites_are_deduplicated_and_add_native_probes(self):
        with patch.object(runner, 'run_suites', return_value=1) as run:
            self.assertEqual(runner.main(['--suite', 'engine', '--suite', 'engine',
                                          '--native', '--jobs', '2']), 1)
        run.assert_called_once_with(['engine', *runner.NATIVE_PROBES], 2)

    def test_list_does_not_execute_and_invalid_jobs_fail(self):
        with patch.object(runner, 'run_suites') as run, redirect_stdout(io.StringIO()):
            self.assertEqual(runner.main(['--list']), 0)
            run.assert_not_called()
        with self.assertRaises(SystemExit), patch('sys.stderr', new=io.StringIO()):
            runner.main(['--jobs', '0'])

    def test_groups_run_concurrently_and_failure_does_not_hide_other_results(self):
        rendezvous = threading.Barrier(2)

        def worker(name):
            rendezvous.wait(timeout=5)
            return runner.Result(name, 1 if name == 'failed' else 0, 0, name + '\n')

        output = io.StringIO()
        with patch.object(runner, 'run_suite', side_effect=worker), redirect_stdout(output):
            self.assertEqual(runner.run_suites(['failed', 'passed'], 2), 1)
        self.assertIn('[FAIL] failed', output.getvalue())
        self.assertIn('[PASS] passed', output.getvalue())
        self.assertIn('1/2 suites passed.', output.getvalue())

    def test_child_exit_code_and_combined_output_are_preserved(self):
        command = [sys.executable, '-c',
                   "import sys; print('stdout'); print('stderr', file=sys.stderr); sys.exit(7)"]
        with patch.object(runner, 'command_for', return_value=command):
            result = runner.run_suite('fixture')
        self.assertEqual(result.returncode, 7)
        self.assertIn('stdout', result.output)
        self.assertIn('stderr', result.output)
        self.assertNotIn('\r', result.output)

    def test_missing_interpreter_is_a_failed_suite(self):
        with patch.object(subprocess, 'run', side_effect=FileNotFoundError('missing')):
            result = runner.run_suite('engine')
        self.assertEqual(result.returncode, 1)
        self.assertIn('missing', result.output)

    def test_commands_use_current_interpreter_and_separate_discovery_roots(self):
        self.assertEqual(runner.command_for('engine'), [sys.executable, '-m', 'unittest',
            'discover', '-s', 'tool/engine', '-p', '*_test.py', '-v'])
        self.assertEqual(runner.command_for('frame-sampling'), [sys.executable,
            runner.NATIVE_PROBES['frame-sampling']])


if __name__ == '__main__':
    unittest.main()
