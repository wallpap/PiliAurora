from pathlib import Path
import shutil
import subprocess
import unittest


class NativeMemoryStatsTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('g++'), 'g++ required')
    def test_resource_ownership_lifecycle_and_concurrency(self):
        root = Path(__file__).resolve().parents[3]
        output = root / 'build/probes/native-memory-stats'
        output.mkdir(parents=True, exist_ok=True)
        binary = output / 'native_memory_stats_probe.exe'
        subprocess.run([
            shutil.which('g++'), '-std=c++17', '-O2', '-Wall', '-Wextra', '-Werror', '-pthread',
            '-I', str(root / 'third_party/media_kit_video/windows'),
            str(Path(__file__).with_name('native_memory_stats_probe.cc')),
            '-o', str(binary),
        ], check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=30)


if __name__ == '__main__':
    unittest.main()
