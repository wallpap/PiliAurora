"""Windows 本地缓存对照。只关闭自身进程，要求 READY code=0 与正常退出。"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', required=True)
    parser.add_argument('--danmaku', required=True)
    parser.add_argument('--audio', default='')
    parser.add_argument('--output', required=True)
    parser.add_argument('--passes', type=int, default=2)
    parser.add_argument('--measurement-seconds', type=int, default=10)
    parser.add_argument('--smoke-only', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.passes <= 4 or not 2 <= args.measurement_seconds <= 60:
        parser.error('passes must be 1..4 and measurement-seconds 2..60')
    root = Path(__file__).resolve().parent.parent
    profile = root / 'build/windows/x64/runner/Profile'
    exe = profile / 'PiliAurora.exe'
    config = root / 'windows/flutter/ephemeral/generated_config.cmake'
    if not exe.is_file() or 'FLUTTER_TARGET=tool/danmaku_playback_benchmark.dart' not in config.read_text():
        raise RuntimeError('Build the playback benchmark Profile target first')
    fixtures = {'video': Path(args.video).resolve(), 'danmaku': Path(args.danmaku).resolve()}
    if args.audio:
        fixtures['audio'] = Path(args.audio).resolve()
    if not all(path.is_file() for path in fixtures.values()):
        raise RuntimeError('Local fixture missing')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    user32 = c.WinDLL('user32', use_last_error=True)
    enum_callback = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
    user32.EnumWindows.argtypes = [enum_callback, w.LPARAM]
    user32.GetWindowThreadProcessId.argtypes = [w.HWND, c.POINTER(w.DWORD)]
    user32.GetClassNameW.argtypes = [w.HWND, w.LPWSTR, c.c_int]
    user32.PostMessageW.argtypes = [w.HWND, w.UINT, w.WPARAM, w.LPARAM]
    user32.PostMessageW.restype = w.BOOL
    results = []

    def run(label, capacity, prewarm, seconds):
        folder = output / label
        folder.mkdir(exist_ok=False)
        options = {
            **fixtures, 'output': folder / 'experiment.json', 'cache-mib': capacity,
            'cache-entries': 512, 'prewarm': str(prewarm).lower(),
            'warmup-seconds': 3, 'measurement-seconds': seconds,
            'repetitions': 1, 'label': label,
        }
        command = [str(exe)] + [f'--{key}={value}' for key, value in options.items()]
        ready = closed = False
        with (folder / 'stdout.log').open('wb') as stdout, (folder / 'stderr.log').open('wb') as stderr:
            process = subprocess.Popen(command, cwd=profile, stdout=stdout, stderr=stderr, creationflags=0x08000000)
            try:
                deadline = time.monotonic() + seconds + 45
                while process.poll() is None and time.monotonic() < deadline:
                    log = (folder / 'stdout.log').read_bytes()
                    if b'PLAYBACK_BENCH_READY code=1' in log:
                        raise RuntimeError(f'{label}: benchmark error marker')
                    ready = b'PLAYBACK_BENCH_READY code=0' in log
                    if ready and not closed:
                        windows = []

                        @enum_callback
                        def visit(hwnd, _):
                            pid = w.DWORD()
                            user32.GetWindowThreadProcessId(hwnd, c.byref(pid))
                            if pid.value == process.pid:
                                name = c.create_unicode_buffer(128)
                                user32.GetClassNameW(hwnd, name, len(name))
                                if name.value == 'FLUTTER_RUNNER_WIN32_WINDOW':
                                    windows.append(hwnd)
                            return True

                        user32.EnumWindows(visit, 0)
                        closed = bool(windows and user32.PostMessageW(windows[0], 0x0010, 0, 0))
                    time.sleep(0.1)
                if process.poll() is None:
                    raise RuntimeError(f'{label}: process timeout')
            finally:
                if process.poll() is None:
                    # 仅终止自身失败测试进程；不计为生命周期成功。
                    process.kill()
                    process.wait(timeout=5)
                (folder / 'process.json').write_text(json.dumps({
                    'ready': ready, 'closeRequested': closed, 'processExit': process.returncode,
                }, indent=2), encoding='utf-8')
        if not ready or not closed or process.returncode != 0:
            raise RuntimeError(f'{label}: shutdown validation failed, exit={process.returncode}')
        data = json.loads((folder / 'experiment.json').read_text(encoding='utf-8'))
        if len(data['results']) != 1 or not data['results'][0]['replayWindowValid']:
            raise RuntimeError(f'{label}: invalid replay window, excluded')
        result = data['results'][0]
        delta = {
            key: result['statistics'][key] - result['statisticsBefore'][key]
            for key in ['layouts', 'cacheHits', 'rasterizations', 'evictions', 'evictionsByBytes',
                        'evictionsByEntries', 'evictedLayouts', 'evictedImages', 'evictedImageBytes', 'prewarmed']
        }
        summary = {
            'label': label, 'cacheMiB': capacity, 'prewarm': prewarm,
            'devicePixelRatio': data['devicePixelRatio'],
            'durationSeconds': seconds, 'accepted': result['accepted'], 'rejected': result['rejected'],
            'positionStartMs': result['positionStartMs'], 'positionEndMs': result['positionEndMs'],
            'cacheDelta': delta,
            'demandRasterizations': delta['rasterizations'] - delta['prewarmed'],
            'meanAddMicros': result['meanAddMicros'],
            'rasterP95Ms': result['raster']['p95Ms'], 'totalP95Ms': result['total']['p95Ms'],
            'privateBytesAtEnd': result['processAtEnd']['privateBytes'],
            'rssBytesAtEnd': result['processAtEnd']['rssBytes'],
        }
        results.append(summary)
        (output / 'summary.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
        print(json.dumps(summary), flush=True)

    # 新构建先用短烟雾验证媒体窗口与退出。失败后不继续矩阵。
    run('smoke', 16, True, 2)
    if args.smoke_only:
        return
    for iteration in range(args.passes):
        prewarm_modes = [True, False] if iteration % 2 == 0 else [False, True]
        for mode_index, prewarm in enumerate(prewarm_modes):
            capacities = [16, 24, 32] if (iteration + mode_index) % 2 == 0 else [32, 24, 16]
            for capacity in capacities:
                run(f'pass{iteration}-cache{capacity}-prewarm{int(prewarm)}', capacity, prewarm, args.measurement_seconds)


if __name__ == '__main__':
    main()
