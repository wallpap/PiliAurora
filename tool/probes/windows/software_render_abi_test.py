"""编译生产步长声明，检查 mpv 软件渲染的 size_t* 参数契约。"""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
COMPILER = shutil.which('c++') or shutil.which('g++')


@unittest.skipUnless(COMPILER, '需要 C++17 编译器')
class SoftwareRenderAbiTest(unittest.TestCase):
    def check_stride(self, platform):
        source = (ROOT / f'third_party/media_kit_video/{platform}/video_output.cc').read_text(encoding='utf-8')
        parameter = re.search(r'\{MPV_RENDER_PARAM_SW_STRIDE,\s*&(\w+)\}', source)
        self.assertIsNotNone(parameter, '找不到生产软件渲染步长参数')
        name = parameter.group(1)
        declarations = re.findall(
            rf'^\s*(?:(?:const\s+)?(?:auto|(?:std::)?size_t|gint32|int32_t|int64_t|int))\s+{name}\s*=[^;]+;',
            source[:parameter.start()], re.M)
        self.assertTrue(declarations, '找不到生产参数的声明')
        # 使用真实声明和计算表达式；只替换窗口／GL 等外围输入。
        harness = '''
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <initializer_list>
#include <type_traits>
using gint32 = int32_t;
int main() {
  for (int32_t width : {640, 641, 1920}) {
    int32_t size[]{width, 360};
    DECLARATION
    static_assert(std::is_same_v<decltype(PARAMETER), size_t>,
                  "MPV_RENDER_PARAM_SW_STRIDE requires size_t storage");
    const void* parameter = &PARAMETER;
    assert(*static_cast<const size_t*>(parameter) == 4 * static_cast<size_t>(width));
  }
}
'''
        harness = harness.replace('DECLARATION', declarations[-1]).replace('PARAMETER', name)
        with tempfile.TemporaryDirectory(prefix='piliaurora-render-abi-') as directory:
            output = Path(directory)
            cpp, binary = output / 'probe.cc', output / 'probe.exe'
            cpp.write_text(harness, encoding='utf-8')
            compiled = subprocess.run(
                [COMPILER, '-std=c++17', '-static-libgcc', '-static-libstdc++',
                 str(cpp), '-o', str(binary)], capture_output=True, text=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            subprocess.run([str(binary)], check=True)

    def test_windows_stride_matches_mpv_abi(self):
        self.check_stride('windows')

    def test_linux_stride_matches_mpv_abi(self):
        self.check_stride('linux')


if __name__ == '__main__':
    unittest.main()
