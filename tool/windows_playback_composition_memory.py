"""Windows Group 合成与 Private Bytes 对照。数据匿名，仅控制自身测试进程。"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
from pathlib import Path
import statistics
import subprocess
import time

MIB = 1024 * 1024


def memory_trend(samples):
    """仅按持续播放样本拟合后半段；不是泄漏判定器。"""
    if len(samples) < 4:
        return None
    samples = sorted(samples, key=lambda sample: sample['elapsedSeconds'])
    middle = (samples[0]['elapsedSeconds'] + samples[-1]['elapsedSeconds']) / 2
    tail = [sample for sample in samples if sample['elapsedSeconds'] >= middle]
    xs = [sample['elapsedSeconds'] / 60 for sample in tail]
    ys = [sample['privateBytes'] / MIB for sample in tail]
    xmean, ymean = statistics.mean(xs), statistics.mean(ys)
    denominator = sum((x - xmean) ** 2 for x in xs)
    slope = sum((x - xmean) * (y - ymean) for x, y in zip(xs, ys)) / denominator if denominator else 0
    return {
        'sampleCount': len(samples), 'durationSeconds': samples[-1]['elapsedSeconds'] - samples[0]['elapsedSeconds'],
        'privateFirstMiB': samples[0]['privateBytes'] / MIB,
        'privateLastMiB': samples[-1]['privateBytes'] / MIB,
        'privatePeakMiB': max(sample['privateBytes'] for sample in samples) / MIB,
        'tailSlopeMiBPerMinute': slope,
        'tailRangeMiB': max(ys) - min(ys),
    }


def self_test():
    assert memory_trend([]) is None
    samples = [{'elapsedSeconds': n * 60, 'privateBytes': (100 + 2 * n) * MIB} for n in range(10)]
    assert abs(memory_trend(samples)['tailSlopeMiBPerMinute'] - 2) < 1e-9
    for sample in samples:
        sample['privateBytes'] = 100 * MIB
    assert memory_trend(samples)['tailSlopeMiBPerMinute'] == 0
    assert memory_trend(samples[::-1]) == memory_trend(samples)
    print('trend self-test: PASS')


class WindowsObserver:
    class Counters(c.Structure):
        _fields_ = [('cb', w.DWORD), ('faults', w.DWORD)] + [(name, c.c_size_t) for name in (
            'peakWorking', 'working', 'peakPaged', 'paged', 'peakNonPaged', 'nonPaged',
            'pagefile', 'peakPagefile', 'privateBytes')]

    def __init__(self):
        self.kernel = c.WinDLL('kernel32', use_last_error=True)
        self.kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
        self.kernel.OpenProcess.restype = w.HANDLE
        self.kernel.CloseHandle.argtypes = [w.HANDLE]
        self.kernel.K32GetProcessMemoryInfo.argtypes = [w.HANDLE, c.POINTER(self.Counters), w.DWORD]
        self.kernel.K32GetProcessMemoryInfo.restype = w.BOOL
        self.user = c.WinDLL('user32', use_last_error=True)
        self.callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        self.user.EnumWindows.argtypes = [self.callback, w.LPARAM]
        self.user.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
        self.user.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
        self.user.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
        self.user.PostMessageW.restype = w.BOOL

    def sample(self, handle):
        counters = self.Counters()
        counters.cb = c.sizeof(counters)
        if not self.kernel.K32GetProcessMemoryInfo(handle, c.byref(counters), counters.cb):
            raise c.WinError(c.get_last_error())
        return {'privateBytes': counters.privateBytes, 'rssBytes': counters.working,
                'peakRssBytes': counters.peakWorking, 'pageFaults': counters.faults}

    def close_window(self, pid):
        windows = []

        @self.callback
        def visit(hwnd, _):
            owner = w.DWORD()
            self.user.GetWindowThreadProcessId(hwnd, c.byref(owner))
            if owner.value == pid:
                name = c.create_unicode_buffer(128)
                self.user.GetClassNameW(hwnd, name, len(name))
                if name.value == 'FLUTTER_RUNNER_WIN32_WINDOW':
                    windows.append(hwnd)
            return True

        self.user.EnumWindows(visit, 0)
        return bool(windows and self.user.PostMessageW(windows[0], 0x0010, 0, 0))


def run_case(profile, fixtures, output, label, options, observer, max_private_mib):
    folder = output / label
    folder.mkdir(exist_ok=False)
    options = {**fixtures, 'output': folder / 'experiment.json', 'label': label,
               'repetitions': 1, 'warmup-seconds': 3, **options}
    command = [str(profile / 'PiliAurora.exe')] + [f'--{key}={value}' for key, value in options.items()]
    ready = closed = False
    samples = []
    phase = 'loading'
    started = time.monotonic()
    next_sample = started
    deadline = started + int(options['measurement-seconds']) + 150
    with (folder / 'stdout.log').open('wb') as stdout, (folder / 'stderr.log').open('wb') as stderr, \
            (folder / 'memory.jsonl').open('w', encoding='utf-8') as memory:
        process = subprocess.Popen(command, cwd=profile, stdout=stdout, stderr=stderr, creationflags=0x08000000)
        handle = observer.kernel.OpenProcess(0x0400 | 0x0010, False, process.pid)
        try:
            if not handle:
                raise c.WinError(c.get_last_error())
            with (folder / 'stdout.log').open('rb') as log:
                while process.poll() is None and time.monotonic() < deadline:
                    for line in log:
                        if b'PLAYBACK_BENCH_BEGIN ' in line:
                            phase = line.split(b'PLAYBACK_BENCH_BEGIN ', 1)[1].strip().decode('utf-8')
                        if b'PLAYBACK_BENCH_READY code=1' in line:
                            raise RuntimeError(f'{label}: benchmark error marker')
                        ready = ready or b'PLAYBACK_BENCH_READY code=0' in line
                    now = time.monotonic()
                    if now >= next_sample and not ready:
                        sample = {'elapsedSeconds': now - started, 'phase': phase, **observer.sample(handle)}
                        samples.append(sample)
                        if sample['privateBytes'] > max_private_mib * MIB:
                            raise RuntimeError(f'{label}: exceeded Private Bytes safety limit {max_private_mib} MiB')
                        memory.write(json.dumps(sample) + '\n')
                        memory.flush()
                        next_sample = now + 1
                    if ready and not closed:
                        closed = observer.close_window(process.pid)
                    time.sleep(0.1)
                if process.poll() is None:
                    raise RuntimeError(f'{label}: process timeout')
        finally:
            if handle:
                observer.kernel.CloseHandle(handle)
            if process.poll() is None:
                # 仅清理本工具创建的失败测试进程。强杀不能计作正常退出。
                process.kill()
                process.wait(timeout=5)
            (folder / 'process.json').write_text(json.dumps({
                'ready': ready, 'closeRequested': closed, 'processExit': process.returncode,
            }, indent=2), encoding='utf-8')
    if not ready or not closed or process.returncode != 0:
        raise RuntimeError(f'{label}: shutdown failed: {process.returncode}')
    data = json.loads((folder / 'experiment.json').read_text(encoding='utf-8'))
    measured = [row for row in data['results'] if 'replayWindowValid' in row]
    # 清理阶段弹幕入场计时器已停止，不对媒体进度累加器断言；仍保存原始数据。
    playback = [row for row in measured if row['phase'] == 'stress' or row['phase'].startswith('endurance-')]
    if not playback or not all(row['replayWindowValid'] and row['expectedPlaying'] for row in playback):
        raise RuntimeError(f'{label}: invalid playback window')
    if options.get('kind') == 'endurance':
        if any(row['frames'] or row['telemetrySamples'] for row in measured):
            raise RuntimeError('Endurance must not retain per-frame or telemetry records')
    summary = {
        'label': label, 'configuration': data['configuration'], 'devicePixelRatio': data['devicePixelRatio'],
        'fixture': data['fixture'], 'mpvVersion': data['mpvVersion'], 'ffmpegVersion': data['ffmpegVersion'],
        'ready': ready, 'processExit': process.returncode,
        'playbackValid': all(row['replayWindowValid'] for row in playback),
        'memoryPlayback': memory_trend([sample for sample in samples if sample['phase'].startswith('endurance-')]),
        'memoryByPhaseMiB': {
            name: {'median': statistics.median([sample['privateBytes'] / MIB for sample in samples if sample['phase'] == name]),
                   'last': [sample['privateBytes'] / MIB for sample in samples if sample['phase'] == name][-1]}
            for name in dict.fromkeys(sample['phase'] for sample in samples)
        },
        'results': [{key: value for key, value in row.items() if key != 'telemetrySamples'} for row in data['results']],
    }
    (folder / 'summary.json').write_text(json.dumps(summary, indent=2), encoding='utf-8')
    print(json.dumps({'label': label, 'playbackValid': summary['playbackValid'],
                      'memoryPlayback': summary['memoryPlayback'], 'processExit': process.returncode}), flush=True)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--video')
    parser.add_argument('--danmaku')
    parser.add_argument('--audio', default='')
    parser.add_argument('--output')
    parser.add_argument('--matrix', choices=['smoke', 'group', 'memory', 'all'], default='all')
    parser.add_argument('--memory-seconds', type=int, default=600)
    parser.add_argument('--group-seconds', type=int, default=10)
    parser.add_argument('--max-private-mib', type=int, default=2048)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.video or not args.danmaku or not args.output:
        parser.error('video, danmaku and output are required')
    if not 2 <= args.memory_seconds <= 1800 or not 2 <= args.group_seconds <= 60:
        parser.error('memory-seconds must be 2..1800; group-seconds 2..60')
    if not 256 <= args.max_private_mib <= 8192:
        parser.error('max-private-mib must be 256..8192')
    root = Path(__file__).resolve().parent.parent
    profile = root / 'build/windows/x64/runner/Profile'
    config = root / 'windows/flutter/ephemeral/generated_config.cmake'
    if not (profile / 'PiliAurora.exe').is_file() or 'FLUTTER_TARGET=tool/danmaku_playback_benchmark.dart' not in config.read_text():
        raise RuntimeError('Build the playback benchmark Profile target first')
    fixtures = {'video': Path(args.video).resolve(), 'danmaku': Path(args.danmaku).resolve()}
    if args.audio:
        fixtures['audio'] = Path(args.audio).resolve()
    if not all(path.is_file() for path in fixtures.values()):
        raise RuntimeError('Local fixture missing')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    observer = WindowsObserver()
    rows = []

    def run(label, **options):
        rows.append(run_case(profile, fixtures, output, label, options, observer, args.max_private_mib))
        (output / 'summary.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')

    run('smoke', **{'measurement-seconds': 2})
    if args.matrix == 'smoke':
        # 同时验证长测入口的释放阶段，不算长期证据。
        run('endurance-smoke', **{'kind': 'endurance', 'measurement-seconds': 2, 'telemetry-ms': 0})
    if args.matrix in ('group', 'all'):
        for iteration in range(2):
            cases = [('auto-all', .5, 'auto', True), ('reference-all', .5, 'reference-group', True),
                     ('opaque-all', 1, 'auto', True), ('auto-ordinary', .5, 'auto', False),
                     ('reference-ordinary', .5, 'reference-group', False),
                     ('auto-static', .5, 'auto', False), ('reference-static', .5, 'reference-group', False)]
            if iteration % 2:
                cases.reverse()
            for name, opacity, composition, special in cases:
                run(f'pass{iteration}-{name}', **{'measurement-seconds': args.group_seconds,
                    'opacity': opacity, 'composition': composition, 'include-special': str(special).lower(),
                    'static-only': str(name.endswith('-static')).lower()})
    if args.matrix in ('memory', 'all'):
        for label, opacity, overlay in [('video-only', .5, False), ('opaque', 1, True), ('transparent', .5, True)]:
            run(f'endurance-{label}', **{'kind': 'endurance', 'measurement-seconds': args.memory_seconds,
                'telemetry-ms': 0, 'opacity': opacity, 'overlay': str(overlay).lower()})


if __name__ == '__main__':
    main()
