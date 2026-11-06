"""使用生产 CMake 验证全新解压目录满足播放器的头文件布局约定。"""
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CMAKE = shutil.which('cmake')


@unittest.skipUnless(CMAKE, 'Requires CMake')
class LibmpvLayoutTest(unittest.TestCase):
    def test_clean_extraction_provides_consumer_headers_and_refreshes_them(self):
        with tempfile.TemporaryDirectory(prefix='mpv-layout-') as directory:
            work = Path(directory)
            package = work / 'package'
            package.mkdir()
            production = ROOT / 'third_party/media_kit_libs_windows_video/windows'
            shutil.copy2(production / 'libmpv.cmake', package / 'libmpv.cmake')
            members = {'libmpv-2.dll': b'fixture dll', 'libmpv.dll.a': b'fixture import library'}
            for name in ('client.h', 'render.h', 'render_gl.h', 'stream_cb.h'):
                members[f'include/mpv/{name}'] = f'// fixture {name}\n'.encode()
            archive = work / 'upstream.tar.gz'
            with tarfile.open(archive, 'w:gz') as bundle:
                for name, content in members.items():
                    entry = tarfile.TarInfo(name)
                    entry.size = len(content)
                    bundle.addfile(entry, io.BytesIO(content))
            (package / 'libmpv.json').write_text(json.dumps({
                'url': archive.as_uri(),
                'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
            }), encoding='utf-8')
            for name in ('THIRD_PARTY_NOTICES.txt', 'NOTICE_SOURCES.json'):
                (package / name).write_text('fixture', encoding='utf-8')
            (work / 'CMakeLists.txt').write_text(
                'cmake_minimum_required(VERSION 3.19)\n'
                'project(mpv_layout NONE)\ninclude(package/libmpv.cmake)\n', encoding='utf-8')
            command = [CMAKE, '-S', str(work), '-B', str(work / 'build')]

            def configure():
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            configure()
            installed = work / 'build/libmpv'
            for name, content in members.items():
                # media_kit_video 使用 <client.h>，包含目录为 libmpv/include。
                relative = name.replace('include/mpv/', 'include/')
                self.assertTrue((installed / relative).is_file(), f'Missing consumer file: {relative}')
                self.assertEqual((installed / relative).read_bytes(), content)
            header = installed / 'include/client.h'
            header.write_bytes(b'stale cache')
            configure()
            self.assertEqual(header.read_bytes(), members['include/mpv/client.h'])


if __name__ == '__main__':
    unittest.main()
