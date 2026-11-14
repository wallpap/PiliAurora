"""Run independent Python tool suites in separate processes with bounded concurrency."""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
TEST_DIRECTORIES = {
    'tooling': 'tool',
    'android': 'tool/probes/android',
    'windows': 'tool/probes/windows',
    'engine': 'tool/engine',
    'windows-engine': 'tool/engine/windows_frame_pacing',
    'android-engine': 'tool/engine/frame_plan',
    'packaging': 'tool/packaging',
    'android-analysis': 'tool/experiments/android',
    'danmaku-analysis': 'tool/experiments/danmaku',
}
NATIVE_PROBES = {
    'frame-sampling': 'tool/probes/windows/windows_frame_sampling_probe.py',
    'angle-rollback': 'tool/probes/windows/windows_angle_rollback_probe.py',
    'renderer-release': 'tool/probes/windows/windows_renderer_release_probe.py',
}


@dataclass(frozen=True)
class Result:
    name: str
    returncode: int
    seconds: float
    output: str


def command_for(name):
    if name in TEST_DIRECTORIES:
        return [sys.executable, '-m', 'unittest', 'discover', '-s',
                TEST_DIRECTORIES[name], '-p', '*_test.py', '-v']
    return [sys.executable, NATIVE_PROBES[name]]


def run_suite(name):
    started = time.monotonic()
    # 各目录有同名测试模块，用独立进程隔离；日志完成后按组输出，避免内容交错。
    with tempfile.TemporaryFile() as output:
        try:
            process = subprocess.run(command_for(name), cwd=ROOT, stdout=output,
                                     stderr=subprocess.STDOUT)
            returncode = process.returncode
        except OSError as error:
            return Result(name, 1, time.monotonic() - started, str(error))
        output.seek(0)
        return Result(name, returncode, time.monotonic() - started,
                      output.read().decode('utf-8', errors='replace').replace('\r\n', '\n'))


def run_suites(names, jobs):
    failed = []
    with ThreadPoolExecutor(max_workers=jobs) as executor:
        pending = {executor.submit(run_suite, name): name for name in names}
        for future in as_completed(pending):
            result = future.result()
            status = 'PASS' if result.returncode == 0 else 'FAIL'
            print(f'[{status}] {result.name} ({result.seconds:.1f}s)', flush=True)
            print(result.output, end='' if result.output.endswith('\n') else '\n', flush=True)
            if result.returncode != 0:
                failed.append(result.name)
    print(f'{len(names) - len(failed)}/{len(names)} suites passed.', flush=True)
    if failed:
        print('Failed suites: ' + ', '.join(sorted(failed)), flush=True)
    return 1 if failed else 0


def positive_jobs(value):
    jobs = int(value)
    if jobs < 1:
        raise argparse.ArgumentTypeError('--jobs must be at least 1')
    return jobs


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', action='append', choices=[*TEST_DIRECTORIES, *NATIVE_PROBES],
                        help='Run only these suites; repeat to select several.')
    parser.add_argument('--jobs', type=positive_jobs, default=min(4, os.cpu_count() or 1),
                        help='Maximum parallel suites (default: up to 4 CPUs).')
    parser.add_argument('--native', action='store_true', help='Also run the three C++ host probes.')
    parser.add_argument('--list', action='store_true', help='List suites without running them.')
    args = parser.parse_args(argv)
    if args.list:
        for name, path in {**TEST_DIRECTORIES, **NATIVE_PROBES}.items():
            print(f'{name:18} {path}')
        return 0
    names = list(dict.fromkeys(args.suite or TEST_DIRECTORIES))
    if args.native:
        names = list(dict.fromkeys([*names, *NATIVE_PROBES]))
    return run_suites(names, args.jobs)


if __name__ == '__main__':
    raise SystemExit(main())
