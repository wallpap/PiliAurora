"""验证画面检查能拒绝具体损坏，并允许正常黑场、绿色内容和转换舍入。"""
from pathlib import Path
import unittest

from PIL import Image, ImageDraw, ImageOps

import windows_video_sampling_probe as probe


class VideoQualityTest(unittest.TestCase):
    def setUp(self):
        self.reference = Image.new('RGB', (128, 96))
        self.reference.putdata([(40 + x, 30 + y, 200 - x)
                                for y in range(96) for x in range(128)])

    def failures(self, actual, reference=None):
        return probe.quality_failures(probe.image_metrics(actual, reference or self.reference))

    def test_normal_content_and_rounding_pass(self):
        for image in (self.reference, Image.new('RGB', (128, 96), 'black'),
                      Image.new('RGB', (128, 96), (0, 70, 0))):
            with self.subTest(color=image.getpixel((0, 0))):
                self.assertEqual(self.failures(image, image), [])
        self.assertEqual(self.failures(self.reference.point(lambda n: n + 1)), [])

    def test_single_bottom_green_row_is_not_hidden_by_global_average(self):
        damaged = self.reference.copy()
        ImageDraw.Draw(damaged).line((0, 95, 127, 95), fill=(0, 70, 0))
        metrics = probe.image_metrics(damaged, self.reference)
        self.assertLess(metrics['mae'], 3)
        self.assertEqual(metrics['greenRows'], 1)
        self.assertTrue(probe.quality_failures(metrics))

    def test_local_black_patch_and_full_black_fail(self):
        damaged = self.reference.copy()
        ImageDraw.Draw(damaged).rectangle((32, 32, 63, 63), fill='black')
        self.assertTrue(self.failures(damaged))
        self.assertTrue(self.failures(Image.new('RGB', damaged.size, 'black')))

    def test_orientation_and_channel_damage_fail(self):
        self.assertTrue(self.failures(ImageOps.flip(self.reference)))
        red, green, blue = self.reference.split()
        self.assertTrue(self.failures(Image.merge('RGB', (blue, green, red))))

    def test_frozen_pixels_require_a_changing_reference(self):
        changed = shifted_frame(self.reference)
        self.assertTrue(probe.frozen_frame(self.reference, self.reference, changed, self.reference))
        self.assertFalse(probe.frozen_frame(self.reference, self.reference, self.reference, self.reference))
        self.assertFalse(probe.frozen_frame(changed, self.reference, changed, self.reference))
        self.assertTrue(self.failures(self.reference, changed))

    def test_pts_matching_rejects_between_frames_and_out_of_range(self):
        timestamps = [2.0, 2.033333, 2.1]
        self.assertEqual(probe.match_frame(2.03333, timestamps), 1)
        for pts in (2.016667, 0, 3):
            with self.subTest(pts=pts), self.assertRaisesRegex(RuntimeError, 'Unaligned'):
                probe.match_frame(pts, timestamps)

    def test_redraw_repeat_and_empty_updates_do_not_count_as_new_frames(self):
        self.assertTrue(probe.is_new_frame(1))
        self.assertTrue(probe.is_new_frame(9))
        for flags in (0, 3, 5, 7):
            with self.subTest(flags=flags):
                self.assertFalse(probe.is_new_frame(flags))

    def test_reads_current_production_options(self):
        root = Path(__file__).resolve().parents[3]
        options = probe.rendering_options(root)
        self.assertEqual(options['gpu-dumb-mode'], 'no')
        self.assertEqual(options['scale'], 'bilinear')
        self.assertEqual(Path(options['glsl-shaders']), root / 'assets/shaders/Windows_ChromaClamp.glsl')


def shifted_frame(image):
    # 模拟相邻动态帧，和单像素舍入差异保持足够距离。
    return image.point(lambda n: min(255, n + 40))


if __name__ == '__main__':
    unittest.main()
