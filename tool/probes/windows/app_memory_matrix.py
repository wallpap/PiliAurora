"""在独立数据副本上交错比较全应用内存策略；只读采样进程树，不强制 GC/Trim。"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import time

import capture_vm_memory as vm


class ProcessEntry(c.Structure):
    _fields_ = [('size', w.DWORD), ('usage', w.DWORD), ('pid', w.DWORD),
                ('heap', c.c_size_t), ('module', w.DWORD), ('threads', w.DWORD),
                ('parent', w.DWORD), ('priority', w.LONG), ('flags', w.DWORD),
                ('name', w.WCHAR * 260)]


class Memory(c.Structure):
    _fields_ = [('size', w.DWORD), ('faults', w.DWORD)] + [
        (key, c.c_size_t) for key in ('peakWorking', 'working', 'peakPaged', 'paged',
                                    'peakNonPaged', 'nonPaged', 'pagefile', 'peakPagefile',
                                    'private', 'privateWorking')] + [('sharedCommit', c.c_uint64)]


class ProcessTree:
    def __init__(self, pid):
        self.pid = pid
        self.kernel = c.WinDLL('kernel32', use_last_error=True)
        for name, result, arguments in [
            ('CreateToolhelp32Snapshot', w.HANDLE, [w.DWORD, w.DWORD]),
            ('Process32FirstW', w.BOOL, [w.HANDLE, c.POINTER(ProcessEntry)]),
            ('Process32NextW', w.BOOL, [w.HANDLE, c.POINTER(ProcessEntry)]),
            ('OpenProcess', w.HANDLE, [w.DWORD, w.BOOL, w.DWORD]),
            ('CloseHandle', w.BOOL, [w.HANDLE]),
            ('K32GetProcessMemoryInfo', w.BOOL, [w.HANDLE, c.POINTER(Memory), w.DWORD]),
        ]:
            function = getattr(self.kernel, name)
            function.restype, function.argtypes = result, arguments

    def sample(self):
        snapshot = self.kernel.CreateToolhelp32Snapshot(2, 0)
        if snapshot == c.c_void_p(-1).value:
            raise c.WinError(c.get_last_error())
        processes = []
        try:
            entry = ProcessEntry()
            entry.size = c.sizeof(entry)
            okay = self.kernel.Process32FirstW(snapshot, c.byref(entry))
            while okay:
                processes.append((entry.pid, entry.parent, entry.name))
                okay = self.kernel.Process32NextW(snapshot, c.byref(entry))
        finally:
            self.kernel.CloseHandle(snapshot)
        owned = {self.pid}
        while True:
            descendants = {pid for pid, parent, _ in processes if parent in owned}
            if descendants <= owned:
                break
            owned |= descendants
        rows = []
        for pid, _, name in processes:
            if pid not in owned:
                continue
            handle = self.kernel.OpenProcess(0x400, False, pid)
            if not handle:
                continue  # 子进程可能已退出。
            try:
                counters = Memory()
                counters.size = c.sizeof(counters)
                if self.kernel.K32GetProcessMemoryInfo(handle, c.byref(counters), counters.size):
                    rows.append({'pid': pid, 'main': pid == self.pid, 'name': name,
                                 'privateBytes': counters.private,
                                 'privateWorkingSetBytes': counters.privateWorking,
                                 'rssBytes': counters.working})
            finally:
                self.kernel.CloseHandle(handle)
        return {'processes': rows,
                'totalPrivateBytes': sum(row['privateBytes'] for row in rows),
                'totalPrivateWorkingSetBytes': sum(row['privateWorkingSetBytes'] for row in rows),
                'rssSemantics': 'perProcessOnly; sharedResidentPagesMustNotBeSummedAsUniqueBytes'}


def run_case(executable, seed, output, name, environment, timeout, capture_vm):
    directory = output / name
    directory.mkdir(parents=True, exist_ok=False)
    data_root = directory / 'data'
    shutil.copytree(seed, data_root, ignore=shutil.ignore_patterns('diagnostics', '*.log', 'Crashpad'))
    report_path = directory / 'report.json'
    env = os.environ.copy()
    env.update(environment)
    env.update(PILIAURORA_MEMORY_ROOT=str(data_root),
               PILIAURORA_PLAYBACK_OUTPUT=str(report_path))
    startup = subprocess.STARTUPINFO()
    startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0
    start = time.monotonic()
    with (directory / 'stdout.log').open('w', encoding='utf-8') as stdout, \
            (directory / 'stderr.log').open('w', encoding='utf-8') as stderr, \
            (directory / 'process-tree.jsonl').open('w', encoding='utf-8') as trace:
        child = subprocess.Popen([str(executable)], env=env, stdout=stdout, stderr=stderr,
                                 startupinfo=startup)
        watcher = ProcessTree(child.pid)
        (directory / 'pid.txt').write_text(str(child.pid), encoding='utf-8')
        last_stage = None
        completed = None
        service = None
        last_vm = -2
        while child.poll() is None:
            elapsed = time.monotonic() - start
            if elapsed > timeout:
                child.terminate()
                raise TimeoutError(f'{name} exceeded {timeout}s')
            progress = directory / 'playback-progress.json'
            stage = 'starting'
            try:
                data = json.loads(progress.read_text(encoding='utf-8'))
                if data['stages']:
                    stage = data['stages'][-1]['stage']
            except (OSError, ValueError, KeyError):
                pass
            row = watcher.sample()
            row.update(elapsedMs=round(elapsed * 1000), stage=stage)
            if capture_vm and elapsed - last_vm >= 2:
                last_vm = elapsed
                try:
                    service = service or vm.service_uri((directory / 'stdout.log').read_text(encoding='utf-8', errors='replace'))
                    process_vm = vm.rpc(service, 'getVM')
                    if process_vm.get('pid') != child.pid:
                        raise RuntimeError('VM PID mismatch')
                    isolate = next(item for item in process_vm.get('isolates', []) if item.get('name') == 'main')
                    usage = vm.rpc(service, 'getMemoryUsage', isolateId=isolate['id'])
                    row['vm'] = {key: usage.get(key) for key in ('heapUsage', 'heapCapacity', 'externalUsage')}
                except (OSError, ValueError, KeyError, RuntimeError, StopIteration):
                    pass
            trace.write(json.dumps(row) + '\n')
            trace.flush()
            if stage != last_stage:
                print(name, stage, flush=True)
                last_stage = stage
            if report_path.exists():
                data = json.loads(report_path.read_text(encoding='utf-8'))
                if data.get('state') in ('completed', 'failed'):
                    completed = completed or time.monotonic()
                    if time.monotonic() - completed > 10:
                        child.terminate()  # 所有测量已结束，只关闭本次测试宿主。
                        break
            time.sleep(.5)
        child.wait(timeout=15)
    report = json.loads(report_path.read_text(encoding='utf-8'))
    last_idle = next((row for row in reversed(report.get('stages', []))
                      if row['stage'].endswith(':settingIdle')), None)
    summary = {}
    if last_idle:
        summary = {key: last_idle['process'].get(key) for key in
                   ('privateBytes', 'privateWorkingSetBytes', 'rssBytes')}
        summary['imageCacheBytes'] = last_idle['images']['cacheBytes']
        summary['rounds'] = [{key: row.get(key) for key in
                              ('routeToReadyMs', 'scrollFrames', 'playingFrames', 'sourceSize', 'decoder')}
                             for row in report.get('rounds', [])]
    return {'run': name, 'exitCode': child.returncode,
            'passed': report.get('passed') is True and child.returncode == 0,
            'reportPassed': report.get('passed'),
            'validWorkload': report.get('validWorkload'), 'state': report.get('state'),
            'summary': summary,
            'report': str(report_path), 'elapsedSeconds': round(time.monotonic() - start, 1)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, required=True)
    args = parser.parse_args()
    config = json.loads(args.config.read_text(encoding='utf-8'))
    if not config.get('cases') or config.get('repetitions', 3) < 1:
        parser.error('Nonempty cases and positive repetitions required')
    if any(not re.fullmatch(r'[A-Za-z0-9_-]+', name) for name in config['cases']):
        parser.error('Case names may contain only letters, digits, underscores and hyphens')
    data_seed = Path(config['dataSeed']).resolve()
    executable = Path(config['executable']).resolve()
    if not data_seed.is_dir() or not executable.is_file():
        parser.error('An existing isolated data seed and probe executable are required')
    output = Path(config['output']).resolve()
    if output.is_relative_to(data_seed):
        parser.error('Output must be outside the data seed')
    output.mkdir(parents=True, exist_ok=True)
    order = []
    cases = config['cases']
    for repetition in range(config.get('repetitions', 3)):
        names = list(cases)
        random.Random(config.get('seed', 20261111) + repetition).shuffle(names)
        order.extend((repetition + 1, name) for name in names)
    results = []
    for repetition, name in order:
        result = run_case(executable, data_seed,
                          output, f'{repetition}-{name}',
                          {**config.get('environment', {}), **cases[name]},
                          config.get('timeoutSeconds', 300), config.get('captureVm', False))
        results.append(result)
        (output / 'matrix.json').write_text(json.dumps({'order': order, 'results': results}, indent=2),
                                          encoding='utf-8')
        print(json.dumps(result), flush=True)
    return 0 if all(row['passed'] for row in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
