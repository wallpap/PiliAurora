"""独立 ANGLE 检出的补丁与构建身份约束。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_engine


class AnglePatchTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.angle = self.root / 'engine/src/flutter/third_party/angle'
        self.angle.mkdir(parents=True)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Local Test')
        self.git('config', 'user.email', 'test@example.invalid')
        self.source = self.angle / 'upload.cc'
        self.source.write_text('bool fast_upload = true;\n')
        self.git('add', 'upload.cc')
        self.git('commit', '-qm', 'fixture')
        revision = self.git('rev-parse', 'HEAD').strip()
        self.source.write_text('bool fast_upload = false;\n')
        self.diff = self.git('diff', '--binary')
        self.source.write_text('bool fast_upload = true;\n')
        self.patch_file = self.root / 'upload.patch'
        self.patch_file.write_text(self.diff, encoding='utf-8', newline='\n')
        self.enterContext(patch.object(build_engine, 'ANGLE_COMMIT', revision))
        self.enterContext(patch.object(build_engine, 'ANGLE_PATCH', self.patch_file))

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.angle, text=True,
                                       stderr=subprocess.PIPE)

    def test_applies_once_and_accepts_already_applied_patch(self):
        for _ in range(2):
            build_engine.apply_angle_patch(self.root, os.environ.copy())
            self.assertEqual(self.source.read_text(), 'bool fast_upload = false;\n')

    def test_rejects_wrong_dependency_revision(self):
        with patch.object(build_engine, 'ANGLE_COMMIT', 'wrong'):
            with self.assertRaisesRegex(ValueError, '提交不匹配'):
                build_engine.apply_angle_patch(self.root, os.environ.copy())
        self.assertEqual(self.source.read_text(), 'bool fast_upload = true;\n')

    def test_preserves_conflicting_change(self):
        self.source.write_text('user change\n')
        with self.assertRaisesRegex(ValueError, '补丁冲突'):
            build_engine.apply_angle_patch(self.root, os.environ.copy())
        self.assertEqual(self.source.read_text(), 'user change\n')

    def test_rejects_other_tracked_changes(self):
        self.git('config', 'core.autocrlf', 'false')
        self.source.write_text('bool fast_upload = false;\n// diagnostic change\n')
        with self.assertRaises(ValueError):
            build_engine.apply_angle_patch(self.root, os.environ.copy())
        self.assertIn('diagnostic change', self.source.read_text())


if __name__ == '__main__':
    unittest.main()
