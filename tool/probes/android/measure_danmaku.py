"""自动构建、运行 Android 真机生产弹幕探针，采集并判定五档帧率与呈现。"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from danmaku_frame_pacing_analysis import analyze
from frame_timing_capture import Device, choose_layer

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = 'io.github.wallpap.piliaurora.dev'
TARGET = 'tool/probes/android/danmaku_frame_pacing.dart'


def adb(args, *words, check=True):
    result = subprocess.run([str(args.adb), '-s', args.serial, *words], check=check,
                            capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=30)
    if check and result.returncode:
        raise RuntimeError('adb 命令失败')
    return result.stdout.strip()


def build(args, output):
    if args.apk:
        manifest = json.loads(args.apk.with_suffix('.json').read_text(encoding='utf-8'))
        app = manifest.get('application', {})
        with args.apk.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        if app.get('target') != TARGET or app.get('package') != PACKAGE or app.get('apkSha256') != digest:
            raise ValueError('复用 APK 的入口、包名或摘要与探针不符')
        return args.apk
    if not args.flutter_sdk or not args.android_sdk:
        raise ValueError('构建需要 --flutter-sdk 隔离SDK和 --android-sdk；复用探针传 --apk')
    engine = args.engine_library
    if engine is None:
        subprocess.run([sys.executable, 'third_party/flutter_engine/package.py', 'unpack',
                        '--target', 'android-arm64', '--output', str(output / 'engine')], cwd=ROOT, check=True,
                       stdout=subprocess.DEVNULL)
        engine = output / 'engine/libflutter.so'
    apk = output / 'danmaku-probe.apk'
    with (output / 'build.log').open('w', encoding='utf-8') as log:
        subprocess.run([sys.executable, 'tool/engine/frame_plan/build_apk.py',
                        '--flutter-sdk', str(args.flutter_sdk), '--engine-library', str(engine),
                        '--android-sdk', str(args.android_sdk), '--mode', 'dev-release', '--target', TARGET,
                        '--output', str(apk), '--skip-pub-get'], cwd=ROOT, check=True, stdout=log, stderr=subprocess.STDOUT)
    return apk


def capture(args, directory, mode, media):
    directory.mkdir()
    remote = f'/sdcard/Android/data/{PACKAGE}/files'
    # 应用先创建自己的存储目录，避免 shell 创建的目录阻止应用读写。
    adb(args, 'shell', 'am', 'start', '-W', '-n', PACKAGE + '/io.github.wallpap.piliaurora.MainActivity')
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        exists = subprocess.run([str(args.adb), '-s', args.serial, 'shell', 'test', '-d', remote], capture_output=True).returncode == 0
        if exists:
            break
        time.sleep(.25)
    else:
        raise TimeoutError('应用未创建测试目录')
    adb(args, 'shell', 'am', 'force-stop', PACKAGE)
    if media:
        adb(args, 'push', str(media), remote + '/danmaku-media.mp4')
    config = directory / 'config.json'
    config.write_text(json.dumps(dict(mode=mode, media='file://' + remote + '/danmaku-media.mp4')), encoding='utf-8')
    adb(args, 'push', str(config), remote + '/danmaku-probe.json')
    before_tag = adb(args, 'shell', 'getprop', 'log.tag.PILI_FRAME_PLAN')
    if not re.fullmatch('[A-Za-z0-9]*', before_tag):
        raise ValueError('现有日志属性格式不支持自动恢复')
    logger = surface = None
    with (directory / 'probe.log').open('w', encoding='utf-8') as log, (directory / 'surface.log').open('w', encoding='utf-8') as sf_log:
        try:
            adb(args, 'shell', 'setprop', 'log.tag.PILI_FRAME_PLAN', 'DEBUG')
            adb(args, 'shell', 'am', 'start', '-W', '-n', PACKAGE + '/io.github.wallpap.piliaurora.MainActivity')
            pid = adb(args, 'shell', 'pidof', PACKAGE)
            if not pid.isdigit():
                raise RuntimeError('探针未启动')
            logger = subprocess.Popen([str(args.adb), '-s', args.serial, 'logcat', '--pid=' + pid,
                '-T', '1', '-v', 'brief', 'flutter:I', 'PILI_FRAME_PLAN:D', 'AndroidRuntime:E', '*:S'], stdout=log, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + 110
            while time.monotonic() < deadline:
                time.sleep(.5)
                data = (directory / 'probe.log').read_text(encoding='utf-8', errors='replace')
                if surface is None and 'PILI_DANMAKU start' in data:
                    # 使用采集器的活动图层规则，已销毁层不会成为候选。
                    layer = choose_layer(Device(str(args.adb), args.serial).read('dumpsys', 'SurfaceFlinger', '--list'), PACKAGE, None)
                    surface = subprocess.Popen([sys.executable, str(Path(__file__).with_name('frame_timing_capture.py')),
                        '--adb', str(args.adb), '--serial', args.serial, '--package', PACKAGE,
                        '--layer', layer, '--seconds', '60', '--output', str(directory / 'surface.json')], stdout=sf_log, stderr=subprocess.STDOUT)
                if 'PILI_DANMAKU failed' in data or 'Unhandled Exception' in data or 'FATAL EXCEPTION' in data:
                    raise RuntimeError('探针异常，见 probe.log')
                if 'PILI_DANMAKU done' in data:
                    break
            else:
                raise TimeoutError('探针未在110秒内完成')
            adb(args, 'pull', remote + '/danmaku-report.json', str(directory / 'probe.json'))
            if surface is None or surface.wait(timeout=15) != 0:
                raise RuntimeError('SurfaceFlinger采集未完成，见 surface.log')
        finally:
            for process in (logger, surface):
                if process and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=5)
            adb(args, 'shell', 'am', 'force-stop', PACKAGE)
            adb(args, 'shell', f'setprop log.tag.PILI_FRAME_PLAN "{before_tag}"')
    media_hash = None
    if media:
        with media.open('rb') as source:
            media_hash = hashlib.file_digest(source, 'sha256').hexdigest()
    metadata = dict(android=adb(args, 'shell', 'getprop', 'ro.build.version.release'),
                    model=adb(args, 'shell', 'getprop', 'ro.product.model'), mode=mode,
                    mediaSha256=media_hash)
    (directory / 'device.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    return analyze(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adb', type=Path, default=Path('adb'))
    parser.add_argument('--serial', required=True)
    parser.add_argument('--media', type=Path, action='append', default=[], help='点播本地素材，可重复；建议每段≥90秒')
    parser.add_argument('--modes', nargs='+', choices=('point', 'live'), default=['point', 'live'])
    parser.add_argument('--flutter-sdk', type=Path)
    parser.add_argument('--android-sdk', type=Path)
    parser.add_argument('--engine-library', type=Path)
    parser.add_argument('--apk', type=Path, help='复用本入口生成且附身份JSON的APK')
    parser.add_argument('--restore-apk', type=Path, help='完成后恢复普通dev包，保留数据')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if 'point' in args.modes and not args.media:
        parser.error('点播需要至少一个 --media')
    for source in [*args.media, args.apk, args.restore_apk, args.engine_library]:
        if source is not None and not source.is_file():
            parser.error(f'输入文件不存在：{source}')
    output = (args.output or ROOT / 'build/android-danmaku-validation' / datetime.now().strftime('%Y%m%d-%H%M%S')).resolve()
    output.mkdir(parents=True, exist_ok=False)
    os.chdir(ROOT)
    if adb(args, 'shell', 'getprop', 'ro.kernel.qemu') == '1':
        parser.error('此入口用于Android真机')
    try:
        apk = build(args, output)
        print('探针构建就绪；安装到独立dev包', flush=True)
        adb(args, 'install', '-r', str(apk))
        tasks = [('point', media) for media in args.media] if 'point' in args.modes else []
        if 'live' in args.modes:
            tasks.append(('live', None))
        results = []
        for index, (mode, media) in enumerate(tasks):
            print(f'采集 {index + 1}/{len(tasks)}：{mode}', flush=True)
            result = capture(args, output / f'{index:02d}-{mode}', mode, media)
            results.append(dict(mode=mode, passed=result['passed']))
        passed = all(result['passed'] for result in results)
        (output / 'summary.json').write_text(json.dumps(dict(passed=passed, runs=results), indent=2), encoding='utf-8')
        print(f'{"通过" if passed else "未通过"}：{output}', flush=True)
        return 0 if passed else 1
    finally:
        if args.restore_apk:
            adb(args, 'install', '-r', str(args.restore_apk))


if __name__ == '__main__':
    raise SystemExit(main())
