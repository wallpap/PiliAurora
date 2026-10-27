"""Exercise manifest generation and the production Inno upgrade cleanup in isolation."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

from prepare_windows_package import HEADER, MANIFEST, write_manifest

ROOT = Path(__file__).resolve().parents[2]
ISCC = shutil.which('ISCC')


class RuntimeManifestTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'win32' and ISCC, 'Requires Windows and Inno Setup')
    def test_upgrade_closes_running_app_and_preserves_other_installation(self):
        compiler = Path('C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe')
        if not compiler.is_file():
            self.skipTest('Requires .NET Framework C# compiler')
        with tempfile.TemporaryDirectory(prefix='pili-running-upgrade-') as directory:
            work = Path(directory).resolve()
            source, installed, other = (work / name for name in ('source', 'installed', 'other'))
            for folder in (source, installed, other):
                folder.mkdir()
            fixture = work / 'Window.cs'
            # 多进程对应主窗口和独立播放小窗，隐藏窗口对应托盘驻留。
            fixture.write_text('''
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;
class Window : Form {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr LoadLibrary(string path);
    public bool Refuse;
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x11) { m.Result = Refuse ? IntPtr.Zero : new IntPtr(1); return; }
        if (m.Msg == 0x16 && m.WParam != IntPtr.Zero) { Environment.Exit(0); }
        base.WndProc(ref m);
    }
    [STAThread] static void Main(string[] args) {
        var library = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "playback.dll");
        if (File.Exists(library) && LoadLibrary(library) == IntPtr.Zero) Environment.Exit(1);
        var window = new Window { Refuse = args[1] != "normal" };
        window.Shown += (s, e) => {
            if (args[1] == "hidden") window.Hide();
            File.WriteAllText(args[0], "ready");
        };
        Application.Run(window);
    }
}
''', encoding='utf-8')
            subprocess.run([str(compiler), '/nologo', '/target:winexe',
                            '/r:System.Windows.Forms.dll',
                            f'/out:{installed / "PiliAurora.exe"}', str(fixture)],
                           check=True, capture_output=True)
            shutil.copy2(installed / 'PiliAurora.exe', other / 'PiliAurora.exe')
            # 加载真实 DLL，覆盖播放器原生库随多个进程保持映射的文件占用方式。
            shutil.copy2(Path('C:/Windows/System32/version.dll'), installed / 'playback.dll')
            shutil.copy2(installed / 'playback.dll', source / 'playback.dll')
            (source / 'PiliAurora.exe').write_bytes(b'updated-app')
            write_manifest(source)
            processes = []
            try:
                scenarios = [
                    (installed, 'normal'),
                    (installed, 'hidden'),
                    (installed, 'player-1'),
                    (installed, 'orphan-player'),
                    (other, 'hidden'),
                ]
                for folder, mode in scenarios:
                    ready = folder / f'ready-{mode}'
                    process = subprocess.Popen([str(folder / 'PiliAurora.exe'), str(ready), mode])
                    processes.append(process)
                    deadline = time.monotonic() + 10
                    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertTrue(ready.exists(), 'Fixture window did not start')
                self._install(work, source, installed, '2.0.0')
                for process, (_, mode) in zip(processes[:-1], scenarios[:-1]):
                    self.assertIsNotNone(process.poll(), f'{mode} is still running')
                self.assertIsNone(processes[-1].poll(), 'Other installation was closed')
                self.assertEqual((installed / 'PiliAurora.exe').read_bytes(), b'updated-app')
                # 覆盖成功后也不能遗留等待重启替换的旧程序。
                log = (work / 'install-2.0.0.log').read_text(encoding='utf-8-sig')
                self.assertIn('Need to restart Windows? No', log)
                self.assertEqual((installed / 'playback.dll').read_bytes(),
                                 (source / 'playback.dll').read_bytes())
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                    process.wait(timeout=10)

    def test_manifest_is_deterministic_and_records_runtime_files(self):
        with tempfile.TemporaryDirectory(prefix='pili-manifest-') as directory:
            runtime = Path(directory)
            (runtime / 'PiliAurora.exe').write_bytes(b'app')
            (runtime / 'data').mkdir()
            (runtime / 'data/图片').write_bytes(b'image')
            manifest = write_manifest(runtime)
            first = manifest.read_bytes()
            write_manifest(runtime)
            self.assertEqual(first, manifest.read_bytes())
            self.assertIn(f'{hashlib.sha256(b"image").hexdigest()}\tdata/图片', first.decode())
            self.assertEqual(len(first.decode().splitlines()), 3)

    @unittest.skipUnless(sys.platform == 'win32' and ISCC, 'Requires Windows and Inno Setup')
    def test_actual_installer_preserves_user_files_and_removes_retired_runtime(self):
        # 安装器移除系统集成项，安装到本次独占目录；不创建卸载注册表或启动应用。
        with tempfile.TemporaryDirectory(prefix='pili-upgrade-') as directory:
            work = Path(directory).resolve()
            source = work / 'source'
            installed = work / 'installed'
            source.mkdir()
            installed.mkdir()
            (source / 'PiliAurora.exe').write_bytes(b'old-app')
            (source / 'retired.dll').write_bytes(b'old-library')
            (source / 'modified.dll').write_bytes(b'old-user-edited-library')
            write_manifest(source)
            self._install(work, source, installed, '1.0.0')
            (installed / 'user-settings.json').write_bytes(b'keep-user-data')
            (installed / 'modified.dll').write_bytes(b'user-changed-file')
            outside = work / 'outside.txt'
            outside.write_bytes(b'outside')
            linked = work / 'external-directory'
            linked.mkdir()
            (linked / 'keep.dll').write_bytes(b'linked-file')
            junction = installed / 'external'
            subprocess.run(['cmd', '/c', 'mklink', '/J', str(junction), str(linked)],
                           check=True, capture_output=True)
            with (installed / MANIFEST).open('a', encoding='utf-8') as stream:
                digest = hashlib.sha256(b'outside').hexdigest()
                stream.write(f'{digest}\t../outside.txt\n')
                digest = hashlib.sha256(b'linked-file').hexdigest()
                stream.write(f'{digest}\texternal/keep.dll\n')

            (source / 'PiliAurora.exe').write_bytes(b'new-app')
            (source / 'retired.dll').unlink()
            (source / 'modified.dll').unlink()
            write_manifest(source)
            self._install(work, source, installed, '1.1.0')
            self.assertEqual((installed / 'PiliAurora.exe').read_bytes(), b'new-app')
            self.assertFalse((installed / 'retired.dll').exists())
            self.assertEqual((installed / 'modified.dll').read_bytes(), b'user-changed-file')
            self.assertEqual((installed / 'user-settings.json').read_bytes(), b'keep-user-data')
            self.assertEqual(outside.read_bytes(), b'outside')
            self.assertEqual((linked / 'keep.dll').read_bytes(), b'linked-file')
            log = (work / 'install-1.1.0.log').read_text(encoding='utf-8-sig')
            self.assertIn('Removed retired runtime file: retired.dll', log)
            self.assertIn('Preserved modified file: modified.dll', log)

            # 无旧清单的首次覆盖安装保留未登记文件。
            (installed / MANIFEST).unlink()
            (installed / 'untracked.dll').write_bytes(b'legacy-file')
            self._install(work, source, installed, '1.2.0')
            self.assertEqual((installed / 'untracked.dll').read_bytes(), b'legacy-file')
            junction.rmdir()

    def _install(self, work, source, installed, version, *, timeout=30):
        values = {
            'APP_ID': 'PiliAuroraUpgradeTest', 'APP_VERSION': version,
            'DISPLAY_NAME': 'PiliAurora Upgrade Test', 'PUBLISHER_NAME': 'Test',
            'PUBLISHER_URL': 'https://example.test', 'INSTALL_DIR_NAME': str(installed),
            'OUTPUT_BASE_FILENAME': f'installer-{version}',
            'SETUP_ICON_FILE': str(ROOT / 'windows/runner/resources/app_icon.ico'),
            'PRIVILEGES_REQUIRED': 'lowest', 'SOURCE_DIR': str(source),
            'EXECUTABLE_NAME': 'PiliAurora.exe',
        }
        text = (ROOT / 'windows/packaging/exe/inno_setup.iss').read_text(encoding='utf-8')
        for key, value in values.items():
            text = text.replace('{{' + key + '}}', value)
        lines = []
        section = ''
        for line in text.splitlines():
            if line.startswith('['):
                section = line
            if section in ['[Icons]', '[Registry]', '[Run]', '[Tasks]', '[Languages]']:
                continue
            if line.startswith('SetupMutex='):
                line = 'SetupMutex=PiliAurora.IsolatedUpgradeTest'
            lines.append(line)
            if line == '[Setup]':
                lines.extend(['Uninstallable=no', 'CreateUninstallRegKey=no'])
        script = work / f'installer-{version}.iss'
        script.write_text('\n'.join(lines), encoding='utf-8-sig')
        compiled = subprocess.run([ISCC, '/Qp', str(script)], capture_output=True, text=True)
        self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
        log = work / f'install-{version}.log'
        run = subprocess.run([
            str(work / f'installer-{version}.exe'), '/VERYSILENT', '/SUPPRESSMSGBOXES',
            '/SP-', f'/DIR={installed}', f'/LOG={log}',
        ], timeout=timeout)
        self.assertEqual(run.returncode, 0, log.read_text(encoding='utf-8-sig'))


if __name__ == '__main__':
    unittest.main()
