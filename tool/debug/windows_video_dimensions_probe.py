#!/usr/bin/env python3
"""Verify cached Windows geometry without synchronously accessing the mpv core."""
import argparse
from pathlib import Path
import subprocess

HEADER = r"""
#include <client.h>
#include <cstdint>
#include <iostream>
#include <optional>
#include <stdexcept>
constexpr int64_t SW_RENDERING_MAX_WIDTH=1920, SW_RENDERING_MAX_HEIGHT=1080;
extern "C" int mpv_get_property(mpv_handle*, const char*, mpv_format, void*) {
  throw std::runtime_error("geometry synchronously waited for mpv core");
}
class VideoOutput {
 public:
  mpv_handle* handle_=nullptr;
  std::optional<int64_t> width_,height_;
  int64_t source_width_=0,source_height_=0;
  void* pixel_buffer_=nullptr;
  int64_t GetVideoWidth();
  int64_t GetVideoHeight();
};
"""
MAIN = r"""
int main() {
  VideoOutput output;
  if(output.GetVideoWidth()!=0 || output.GetVideoHeight()!=0) return 1;
  std::cout<<"PASS startup geometry does not wait for mpv core\n";
  output.source_width_=1920;output.source_height_=1080;
  if(output.GetVideoWidth()!=1920 || output.GetVideoHeight()!=1080) return 1;
  output.source_width_=1080;output.source_height_=1920;
  if(output.GetVideoWidth()!=1080 || output.GetVideoHeight()!=1920) return 1;
  std::cout<<"PASS observed landscape and rotated portrait dimensions\n";
  output.width_=640;output.height_=360;
  if(output.GetVideoWidth()!=640 || output.GetVideoHeight()!=360) return 1;
  output.width_.reset();output.height_.reset();
  output.source_width_=3840;output.source_height_=2160;
  output.pixel_buffer_=&output;
  if(output.GetVideoWidth()!=1920 || output.GetVideoHeight()!=1080) return 1;
  std::cout<<"PASS fixed dimensions and software output limits\n";
  return 0;
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='g++')
    parser.add_argument('--headers', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    candidates = [root/'build/windows/x64/libmpv/include',
                  root/'build/windows/x64/libmpv-20260819/include/mpv']
    headers = args.headers or next((p for p in candidates if (p/'client.h').exists()), None)
    if headers is None or not (headers/'client.h').exists():
        parser.error('Pass --headers with the pinned libmpv client.h directory')
    output = root/'build/windows-playback-diagnosis'
    output.mkdir(parents=True, exist_ok=True)
    source = (root/'third_party/media_kit_video/windows/video_output.cc').read_text(encoding='utf-8')
    methods = source[source.index('int64_t VideoOutput::GetVideoWidth()'):]
    assert methods.count('int64_t VideoOutput::GetVideoHeight()') == 1
    fixture = output/'video_dimensions_probe.cc'
    fixture.write_text(HEADER+methods+MAIN, encoding='utf-8')
    binary = output/'video_dimensions_probe.exe'
    subprocess.run([args.compiler, '-std=c++17', '-O0', '-static-libgcc',
                    '-static-libstdc++', '-I', str(headers), str(fixture),
                    '-o', str(binary)], check=True)
    print('No libmpv / Flutter / ANGLE library is linked or loaded.', flush=True)
    raise SystemExit(subprocess.run([str(binary)]).returncode)

if __name__ == '__main__':
    main()
