"""运行真实 Windows EOF 黑屏探针，并独立保存窗口中心的桌面像素。"""

import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import time

from PIL import ImageGrab


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--executable', required=True, type=Path)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--audio-source', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--duration-ms', required=True, type=int)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--width', type=int, default=3840)
    parser.add_argument('--height', type=int, default=2160)
    parser.add_argument('--eof-dwell-ms', type=int, default=1000)
    parser.add_argument('--decoder', default='d3d11va')
    parser.add_argument('--sequence', choices=['eof-seek-retry', 'retry-only'], default='eof-seek-retry')
    parser.add_argument('--continue-after-reproduction', action='store_true')
    parser.add_argument('--expect-healthy', action='store_true',
                        help='Require every checkpoint to advance with visible pixels and all native outputs to release')
    parser.add_argument('--timeout', type=int, default=240)
    args = parser.parse_args()
    if args.rounds < 1 or args.duration_ms <= 1200 or args.timeout < 1:
        parser.error('rounds/timeout must be positive; duration-ms must exceed 1200')
    executable = args.executable.resolve(strict=True)
    source = args.source.resolve(strict=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    config = dict(source=str(source), output=str(output/'report.json'),
                  durationMs=args.duration_ms, rounds=args.rounds,
                  width=args.width, height=args.height,
                  eofDwellMs=args.eof_dwell_ms, decoder=args.decoder,
                  sequence=args.sequence, desktopCapture=True,
                  stopAfterReproduction=not args.continue_after_reproduction)
    if args.audio_source:
        config['audioSource'] = str(args.audio_source.resolve(strict=True))
    config_file = output/'config.json'
    config_file.write_text(json.dumps(config), encoding='utf-8')
    env = dict(os.environ, PILIAURORA_BLACK_SCREEN_CONFIG=str(config_file))
    user32 = ctypes.WinDLL('user32', use_last_error=True)
    user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    user32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
    user32.FindWindowW.restype = wintypes.HWND
    captures = []
    started = time.monotonic()
    last_stage = None
    seen_rows = 0
    with (output/'stdout.log').open('w', encoding='utf-8') as stdout, \
            (output/'stderr.log').open('w', encoding='utf-8') as stderr:
        process = subprocess.Popen([str(executable)], cwd=executable.parent,
                                   env=env, stdout=stdout, stderr=stderr,
                                   creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            while process.poll() is None:
                elapsed = time.monotonic()-started
                if elapsed > args.timeout:
                    process.kill()
                    raise TimeoutError('Probe timeout; only probe process terminated')
                rows = []
                try:
                    rows = json.loads((output/'report.json').read_text(encoding='utf-8')).get('rows', [])
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                if len(rows) > seen_rows:
                    for row in rows[seen_rows:]:
                        print(row['stage'], 'counterexample='+str(row['counterexample']),
                              'pixelHighs='+str([p['high'] for p in row['pixels']]),
                              'consumedDelta='+str(row['consumedDelta']), flush=True)
                    seen_rows = len(rows)
                stage = rows[-1]['stage'] if rows else 'startup'
                hwnd = user32.FindWindowW(None, 'PiliAurora EOF pixel probe')
                if hwnd:
                    rect = wintypes.RECT()
                    if user32.GetWindowRect(hwnd, ctypes.byref(rect)):
                        width, height = rect.right-rect.left, rect.bottom-rect.top
                        if width > 100 and height > 100:
                            # 独立观测桌面中心，避开标题、标签和外围背景。
                            bbox = (rect.left+width//3, rect.top+height//3,
                                    rect.left+width*2//3, rect.top+height*2//3)
                            image = ImageGrab.grab(bbox=bbox, all_screens=True)
                            low, high = image.convert('L').getextrema()
                            record = dict(elapsed=elapsed, latestCompletedStage=stage,
                                          low=low, high=high, black=high <= 24)
                            request_file = output/'capture-request.json'
                            try:
                                request = json.loads(request_file.read_text(encoding='utf-8'))
                            except (FileNotFoundError, json.JSONDecodeError):
                                request = None
                            receipt = output/f"desktop-{request['stage']}.json" if request else None
                            if stage != last_stage or high-low <= 8 or (receipt and not receipt.exists()):
                                filename = f'desktop-{len(captures):04d}.png'
                                image.save(output/filename)
                                record['image'] = filename
                            if receipt and not receipt.exists():
                                record['requestedStage'] = request['stage']
                                record['blank'] = high-low <= 8
                                receipt.write_text(json.dumps(record), encoding='utf-8')
                            captures.append(record)
                            last_stage = stage
                time.sleep(.4)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=15)
            (output/'desktop-captures.json').write_text(
                json.dumps(captures, indent=2), encoding='utf-8')
    report_path = output/'report.json'
    report = json.loads(report_path.read_text(encoding='utf-8')) if report_path.exists() else {}
    release = report.get('afterRelease', {})
    released = (release.get('status') == 'ok'
                and release.get('pendingTextureUnregistrations') == 0
                and release.get('releasingOutputs') == 0
                and bool(release.get('resources'))
                and all(value.get('count') == 0 for value in release['resources'].values()))
    verdict = process.returncode
    if args.expect_healthy:
        verdict = (0 if process.returncode == 0 and report.get('completed') is True
                   and report.get('allStagesHealthy') is True and released else 1)
    print(json.dumps(dict(exitCode=process.returncode,
                          completed=report.get('completed'),
                          reproduced=report.get('reproduced'),
                          counterexampleObserved=report.get('counterexampleObserved'),
                          allStagesHealthy=report.get('allStagesHealthy'),
                          nativeReleased=released,
                          verdict=verdict,
                          error=report.get('error'),
                          desktopSamples=len(captures)), ensure_ascii=False))
    return verdict


if __name__ == '__main__':
    raise SystemExit(main())
