#!/usr/bin/env python3
"""准备固定 Windows Flutter 引擎，应用补丁、编译并运行帧节奏回归。"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request


ENGINE = 'af7e796e161ae0bb1ff0758c71a7105418bd9ded'
DEPOT_TOOLS = 'b1c2e86792a7f2b6576c181b7327ddd53b1a42a8'
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import engine_identity

PATCH = engine_identity.PATCHES['windowsDwmPaced']


def run(command, *, cwd, env, capture=False, check=True):
    command = [str(part) for part in command]
    if Path(command[0]).suffix.lower() == '.bat':
        command = ['cmd.exe', '/d', '/c', subprocess.list2cmdline(command)]
    return subprocess.run(command, cwd=cwd, env=env, check=check, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)


def sha256(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def prepare(root, sdk, env, jobs, skip_sync):
    checkout = root / 'flutter'
    depot = root / 'depot_tools'
    root.mkdir(parents=True, exist_ok=True)
    # 固定版本 GN 仍调用 git.bat，新版 depot_tools 已不再提供该包装。
    host_tools = root / 'host_tools'
    host_tools.mkdir(exist_ok=True)
    git_exe = shutil.which('git.exe', path=env['PATH'])
    if not git_exe:
        raise ValueError('需要 Git for Windows')
    (host_tools / 'git.bat').write_text('@echo off\n' + subprocess.list2cmdline([git_exe]) + ' %*\n', encoding='utf-8')
    if not checkout.exists():
        run(['git', 'clone', '--shared', '--no-checkout', sdk, checkout], cwd=root, env=env)
        run(['git', 'checkout', '--detach', ENGINE], cwd=checkout, env=env)
    revision = run(['git', 'rev-parse', 'HEAD'], cwd=checkout, env=env, capture=True).stdout.strip()
    if revision != ENGINE:
        raise ValueError('引擎检出提交不匹配；请使用独立的固定版本检出。')
    if not depot.exists():
        run(['git', 'clone', '--depth=1', '--no-checkout',
             'https://chromium.googlesource.com/chromium/tools/depot_tools.git', depot], cwd=root, env=env)
        run(['git', 'fetch', '--depth=1', 'origin', DEPOT_TOOLS], cwd=depot, env=env)
        run(['git', 'checkout', '--detach', DEPOT_TOOLS], cwd=depot, env=env)
    if run(['git', 'rev-parse', 'HEAD'], cwd=depot, env=env, capture=True).stdout.strip() != DEPOT_TOOLS:
        raise ValueError('depot_tools 提交不匹配。')
    env['PATH'] = os.pathsep.join([str(host_tools), str(depot), env['PATH']])
    gclient = checkout / '.gclient'
    if not gclient.exists():
        solution = {'name': '.', 'url': 'https://github.com/flutter/flutter.git',
                    'managed': False, 'deps_file': 'DEPS', 'custom_deps': {},
                    'custom_vars': {'download_android_deps': False, 'download_linux_deps': False,
                                    'download_fuchsia_deps': False, 'download_fuchsia_sdk': False,
                                    'download_windows_deps': True, 'download_emsdk': False,
                                    'download_jdk': False, 'setup_githooks': False}}
        gclient.write_text(f'solutions = {[solution]!r}\ntarget_os = ["win"]\ntarget_cpu = ["x64"]\n', encoding='utf-8')
    if not skip_sync:
        # 首次单独引导 CIPD，避免批处理静默吞掉连接错误。
        run([depot / 'cipd.bat', 'ensure', '-log-level', 'info', '-ensure-file',
             depot / 'cipd_manifest.txt', '-root', depot / '.cipd_bin'], cwd=root, env=env)
        run([depot / 'gclient.bat', 'sync', '--no-history', '--shallow', '--nohooks',
             '-j', jobs, '--verbose'], cwd=checkout, env=env)
    run([depot / 'gclient.bat', 'runhooks'], cwd=checkout, env=env)
    applies = run(['git', 'apply', '--check', PATCH.resolve()], cwd=checkout, env=env,
                  capture=True, check=False)
    if applies.returncode == 0:
        run(['git', 'apply', PATCH.resolve()], cwd=checkout, env=env)
    elif run(['git', 'apply', '--reverse', '--check', PATCH.resolve()], cwd=checkout,
             env=env, capture=True, check=False).returncode != 0:
        raise ValueError('引擎补丁与当前文件冲突；已有修改已保留。')
    diff = run(['git', 'diff', '--binary'], cwd=checkout, env=env, capture=True).stdout
    if not engine_identity.patch_matches(diff, PATCH.read_text(encoding='utf-8')):
        raise ValueError('引擎还包含补丁之外的修改，无法登记准确的构建身份。')
    return checkout, depot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True, help='隔离引擎与 depot_tools 的父目录')
    parser.add_argument('--flutter-sdk', type=Path, required=True, help='固定 Flutter 3.47.5 SDK')
    parser.add_argument('--visual-studio', type=Path, help='本机 Visual Studio 安装目录')
    parser.add_argument('--visual-studio-version', default='2026')
    parser.add_argument('--windows-sdk', type=Path, help='Windows Kits/10 安装目录')
    parser.add_argument('--windows-sdk-version', help='指定已安装的 Windows SDK 版本')
    parser.add_argument('--mode', choices=['profile', 'release'], default='profile')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--skip-sync', action='store_true', help='复用已下载依赖，仍执行 hooks')
    parser.add_argument('--skip-tests', action='store_true', help='首次测量时仅构建引擎')
    args = parser.parse_args()
    if sys.platform != 'win32':
        parser.error('需要 Windows 主机')
    sdk = args.flutter_sdk.resolve()
    if (sdk / 'bin/internal/engine.version').read_text().strip() != ENGINE:
        parser.error('SDK engine.version 与固定引擎不匹配')
    env = os.environ.copy()
    env.update({'DEPOT_TOOLS_UPDATE': '0', 'DEPOT_TOOLS_WIN_TOOLCHAIN': '0'})
    if args.visual_studio:
        env['GYP_MSVS_OVERRIDE_PATH'] = str(args.visual_studio.resolve())
        env['GYP_MSVS_VERSION'] = args.visual_studio_version
    if args.windows_sdk:
        env['WINDOWSSDKDIR'] = str(args.windows_sdk.resolve())
    elif 'WINDOWSSDKDIR' not in env:
        import winreg
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE,
                            r'SOFTWARE\Microsoft\Windows Kits\Installed Roots') as key:
            env['WINDOWSSDKDIR'] = winreg.QueryValueEx(key, 'KitsRoot10')[0]
    sdk_versions = [p.name for p in (Path(env['WINDOWSSDKDIR']) / 'Include').iterdir()
                    if p.is_dir() and (p / 'um').exists()]
    env['WINDOWSSDKVERSION'] = args.windows_sdk_version or max(
        sdk_versions, key=lambda v: tuple(int(part) for part in v.split('.')))
    # 仅影响本次进程树，不修改系统或全局 Git 设置。
    index = int(env.get('GIT_CONFIG_COUNT', '0'))
    env.update({'GIT_CONFIG_COUNT': str(index + 1), f'GIT_CONFIG_KEY_{index}': 'core.longpaths',
                f'GIT_CONFIG_VALUE_{index}': 'true'})
    proxy = urllib.request.getproxies().get('https')
    if proxy:
        env.setdefault('HTTPS_PROXY', proxy)
        env.setdefault('HTTP_PROXY', proxy)
    checkout, depot = prepare(args.root.resolve(), sdk, env, args.jobs, args.skip_sync)
    src = checkout / 'engine/src'
    name = 'piliaurora_windows_' + args.mode
    run([depot / 'vpython3.bat', src / 'flutter/tools/gn', '--windows-cpu', 'x64',
         '--runtime-mode', args.mode, '--no-lto', '--no-goma', '--no-build-engine-artifacts',
         '--target-dir', name], cwd=src, env=env)
    output = src / 'out' / name
    targets = ['flutter_windows']
    if not args.skip_tests:
        targets.append('flutter_windows_unittests')
    run([checkout / 'third_party/ninja/ninja.exe', '-C', output, '-j', args.jobs, *targets], cwd=src, env=env)
    if not args.skip_tests:
        run([output / 'flutter_windows_unittests.exe',
             '--gtest_filter=FlutterWindowsEngineTest.*Vsync*:FlutterWindowsViewTest.*VSync*:TaskRunnerTest.*'],
            cwd=output, env=env)
    library = output / 'flutter_windows.dll'
    identity = engine_identity.create_identity(
        library, profile='windowsDwmPaced', mode=args.mode, sdk=sdk,
        native_tests_passed=not args.skip_tests, depotToolsCommit=DEPOT_TOOLS,
        windowsSdkVersion=env['WINDOWSSDKVERSION'])
    (output / 'engine-identity.json').write_text(json.dumps(identity, indent=2) + '\n', encoding='utf-8')
    print('Windows engine:', library)


if __name__ == '__main__':
    main()
