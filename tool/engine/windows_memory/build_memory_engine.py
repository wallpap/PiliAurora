#!/usr/bin/env python3
"""在已准备的固定 Windows 引擎中增量装配内存诊断，保留原有平台补丁。"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ENGINE = 'af7e796e161ae0bb1ff0758c71a7105418bd9ded'
HERE = Path(__file__).resolve().parent


def sha(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def git(checkout: Path, *args: str, check: bool = True):
    return subprocess.run(['git', *args], cwd=checkout, check=check,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def apply_patch(checkout: Path, patch: Path):
    applies = git(checkout, 'apply', '--check', str(patch), check=False)
    if applies.returncode == 0:
        git(checkout, 'apply', str(patch))
    elif git(checkout, 'apply', '--reverse', '--check', str(patch), check=False).returncode:
        raise SystemExit(f'{patch.name} 与已有修改冲突；未覆盖任何源文件。')


def copy_helper(checkout: Path, name: str, relative: str):
    helper = HERE / name
    destination = checkout / relative / name
    if destination.exists() and sha(destination) != sha(helper):
        raise SystemExit(f'已有不同的 {name}；未覆盖。')
    if not destination.exists():
        shutil.copy2(helper, destination)


def test_idle_scheduler(output: Path, artifacts: Path):
    # 使用引擎已经登记的 MSVC 环境；不修改全局工具链或打印环境内容。
    env = os.environ.copy()
    for entry in (output / 'environment.x64').read_text().split('\0'):
        if '=' in entry:
            key, value = entry.split('=', 1)
            env[key] = value
    compiler = shutil.which('cl.exe', path=env.get('PATH'))
    if not compiler:
        raise SystemExit('引擎 MSVC 环境缺少 cl.exe，无法验证 idle 调度回归。')
    target = artifacts / 'idle-scheduler'
    target.mkdir(exist_ok=True)
    executable = target / 'idle_gpu_trim_test.exe'
    subprocess.run([compiler, '/nologo', '/EHsc', '/std:c++17', '/W4', '/WX', '/O2',
                    str(HERE / 'idle_gpu_trim_test.cc'), '/Fe:' + str(executable),
                    '/Fo:' + str(target / 'idle_gpu_trim_test.obj')],
                   env=env, check=True)
    subprocess.run([str(executable)], env=env, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True,
                        help='已有 windows_frame_pacing 隔离检出的父目录')
    parser.add_argument('--mode', choices=['profile', 'release'], default='release')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--artifacts', type=Path, default=Path('build/memory-engine'))
    parser.add_argument('--idle-trim', action='store_true',
                        help='同时启用十秒无成功呈现后的自动设备 Trim 实验')
    parser.add_argument('--idle-only', action='store_true',
                        help='只叠加自动 Trim，不包含诊断通道；需未应用内存诊断的检出')
    args = parser.parse_args()
    root = args.root.resolve()
    checkout = root / 'flutter'
    if git(checkout, 'rev-parse', 'HEAD').stdout.decode().strip() != ENGINE:
        raise SystemExit('引擎提交不匹配；保留现有检出并停止。')
    output = checkout / 'engine/src/out' / ('piliaurora_windows_' + args.mode)
    if not (output / 'build.ninja').exists():
        raise SystemExit('先通过 windows_frame_pacing/build_engine.py 准备对应模式。')
    artifacts = args.artifacts.resolve()
    artifacts.mkdir(parents=True, exist_ok=True)
    # 只首次保存同模式基线，绝不覆盖之前保存的产物。
    backup = artifacts / ('baseline' if args.mode == 'release' else 'baseline-profile')
    backup.mkdir(exist_ok=True)
    for name in ['flutter_windows.dll', 'flutter_windows.dll.pdb', 'engine-identity.json']:
        source = output / name
        if source.exists() and not (backup / name).exists():
            shutil.copy2(source, backup / name)
    patch = HERE / 'engine.patch'
    idle_patch = HERE / 'idle-trim.patch'
    idle_enabled = args.idle_trim or args.idle_only
    if args.idle_only:
        if not git(checkout, 'apply', '--reverse', '--check', str(patch), check=False).returncode:
            raise SystemExit('现有检出包含诊断通道；idle-only 不自动删除已有修改。')
    else:
        apply_patch(checkout, patch)
        copy_helper(checkout, 'graphics_memory_dump.h', 'engine/src/flutter/shell/common')
        copy_helper(checkout, 'cpu_memory_dump.h', 'engine/src/flutter/shell/common')
    if idle_enabled:
        apply_patch(checkout, idle_patch)
        for name in ['idle_gpu_trim.h', 'idle_gpu_trim_windows.h']:
            copy_helper(checkout, name, 'engine/src/flutter/shell/platform/windows')
        test_idle_scheduler(output, artifacts)
    elif not git(checkout, 'apply', '--reverse', '--check', str(idle_patch), check=False).returncode:
        raise SystemExit('现有检出已启用 idle Trim，请显式传 --idle-trim 以登记正确身份。')
    helper = HERE / 'graphics_memory_dump.h'
    env = os.environ.copy()
    env['DEPOT_TOOLS_UPDATE'] = '0'
    env['DEPOT_TOOLS_WIN_TOOLCHAIN'] = '0'
    env['PATH'] = os.pathsep.join([str(root / 'host_tools'),
                                   str(root / 'depot_tools'), env['PATH']])
    subprocess.run([str(checkout / 'third_party/ninja/ninja.exe'), '-C', str(output),
                    '-j', str(args.jobs), 'flutter_windows'], env=env, check=True)
    # 单独登记实验身份，不把内存补丁伪装成通过原平台验收的正式引擎。
    diff = git(checkout, 'diff', '--binary').stdout
    identity = {
        'schemaVersion': 1,
        'purpose': 'windowsGraphicsMemoryExperiment',
        'engineCommit': ENGINE,
        'mode': args.mode,
        'architecture': 'x64',
        'builtUtc': datetime.now(timezone.utc).isoformat(),
        'binarySha256': sha(output / 'flutter_windows.dll'),
        'pdbSha256': sha(output / 'flutter_windows.dll.pdb'),
        'memoryPatchSha256': None if args.idle_only else sha(patch),
        'dumpHelperSha256': None if args.idle_only else sha(helper),
        'cpuCacheHelperSha256': None if args.idle_only else sha(HERE / 'cpu_memory_dump.h'),
        'cpuCacheDiagnosticsEnabled': not args.idle_only,
        'diagnosticChannelsEnabled': not args.idle_only,
        'freeGpuResourcesDiagnosticsEnabled': not args.idle_only,
        'freeGpuResourcesSemantics': 'Skia internal flushAndSubmit(kNo), atlas/strike/path renderer release, unlocked resource purge; GL program cache not explicitly reset' if not args.idle_only else None,
        'idleTrimEnabled': idle_enabled,
        'idlePatchSha256': sha(idle_patch) if idle_enabled else None,
        'idleHelperSha256': sha(HERE / 'idle_gpu_trim.h') if idle_enabled else None,
        'idleWindowsHelperSha256': sha(HERE / 'idle_gpu_trim_windows.h') if idle_enabled else None,
        'idleSchedulerRegressionPassed': idle_enabled,
        'productionFeatureFlags': {'idleD3DTrimAfterTenSecondsWithoutPresent': idle_enabled},
        'fullTrackedSourceDiffSha256': hashlib.sha256(diff).hexdigest(),
        'baselineBinarySha256': sha(backup / 'flutter_windows.dll'),
        'runtimeProbePassed': False,
        'notes': 'Experimental engine; original platform changes preserved. Validate with graphics_memory.dart.',
    }
    (output / 'engine-memory-identity.json').write_text(
        json.dumps(identity, indent=2) + '\n', encoding='utf-8')
    (artifacts / ('engine-memory-' + args.mode + '.json')).write_text(
        json.dumps(identity, indent=2) + '\n', encoding='utf-8')
    print(output / 'flutter_windows.dll')


if __name__ == '__main__':
    main()
