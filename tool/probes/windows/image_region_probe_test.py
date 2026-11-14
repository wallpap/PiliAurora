from pathlib import Path
import json
import os
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / 'build/probes/image-region'
WORKER = OUTPUT / 'native/Release/piliaurora_image_worker.exe'


@unittest.skipUnless(os.name == 'nt' and WORKER.exists(), 'Build image_region_probe.py on Windows first')
class RegionWorkerTest(unittest.TestCase):
    def open(self, name):
        process = subprocess.Popen([str(WORKER), str(OUTPUT / name), '-', 'pipe'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.close, process)
        return process, json.loads(process.stdout.readline())

    @staticmethod
    def close(process):
        if process.poll() is None:
            process.stdin.write(b'close\n')
            process.stdin.flush()
            process.wait(timeout=5)
        for stream in [process.stdin, process.stdout, process.stderr]:
            stream.close()

    def decode(self, process, rect, index=1):
        x, y, width, height = rect
        process.stdin.write(f'0 {x} {y} {width} {height} {index}\n'.encode())
        process.stdin.flush()
        response = json.loads(process.stdout.readline())
        self.assertEqual(response['bytes'], width * height * 4)
        pixels = process.stdout.read(response['bytes'])
        self.assertEqual(len(pixels), response['bytes'])
        return pixels

    def test_lossy_alpha_crop_preserves_nonzero_origin(self):
        process, metadata = self.open('webp-alpha.webp')
        self.assertTrue(metadata['supported'])
        width, height = metadata['width'], metadata['height']
        full = self.decode(process, (0, 0, width, height))
        x, y, w, h = 228, 142, 264, 264
        crop = self.decode(process, (x, y, w, h), 2)
        # 留出 halo，比较独立整帧的核心；旧 1.6.0 在 alpha 上偏移 142 行。
        for row in range(2, h - 2):
            self.assertEqual(crop[(row * w + 2) * 4:(row * w + w - 2) * 4],
                full[((row + y) * width + x + 2) * 4:((row + y) * width + x + w - 2) * 4])

    def test_invalid_bounds_fail_and_exit(self):
        process, _ = self.open('jpeg.jpeg')
        process.stdin.write(b'0 719 549 2 2 1\n')
        process.stdin.flush()
        self.assertIn('error', json.loads(process.stdout.readline()))
        self.assertNotEqual(process.wait(timeout=5), 0)

    def test_animation_and_orientation_are_explicitly_unsupported(self):
        for name, key, expected in [('animated.gif', 'frames', 2), ('oriented.jpeg', 'orientation', 6)]:
            process, metadata = self.open(name)
            self.assertEqual(metadata[key], expected)
            self.close(process)


if __name__ == '__main__':
    unittest.main()
