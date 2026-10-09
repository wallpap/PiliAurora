#!/usr/bin/env python3
"""Compile exact production geometry methods against fake mpv only.

The failure path populates an undefined/stale node deterministically. Any read
or free of that failed result is caught without a native assertion or DLL load.
"""
import argparse
from pathlib import Path
import subprocess

HEADER = '#include <client.h>\n#include <cstdint>\n#include <cstring>\n#include <iostream>\n#include <optional>\n#include <stdexcept>\n\nconstexpr int64_t SW_RENDERING_MAX_WIDTH=1920;\nconstexpr int64_t SW_RENDERING_MAX_HEIGHT=1080;\nstatic bool property_available=false;\nstatic int invalid_frees=0;\nstatic int valid_frees=0;\nstatic mpv_node_list stale_map{};\nstatic mpv_node_list valid_map{};\nstatic mpv_node values[3]{};\nstatic char k_dw[]="dw", k_dh[]="dh", k_rotate[]="rotate";\nstatic char* keys[]={k_dw,k_dh,k_rotate};\nextern "C" int mpv_get_property(mpv_handle*, const char*, mpv_format, void* out) {\n  auto node=static_cast<mpv_node*>(out);\n  // On failure the result is undefined: model stale stack contents safely.\n  // This is deliberately not a libmpv allocation, and must never be freed.\n  node->format=MPV_FORMAT_NODE_MAP;\n  node->u.list=property_available ? &valid_map : &stale_map;\n  return property_available ? 0 : MPV_ERROR_PROPERTY_UNAVAILABLE;\n}\nextern "C" void mpv_free_node_contents(mpv_node* node) {\n  if (!property_available) {\n    invalid_frees++;\n    throw std::runtime_error("free_node_contents called on failed/undefined property output");\n  }\n  valid_frees++;\n  node->format=MPV_FORMAT_NONE;\n}\nclass VideoOutput {\n public:\n  mpv_handle* handle_=nullptr;\n  std::optional<int64_t> width_,height_;\n  void* pixel_buffer_=nullptr;\n  int64_t GetVideoWidth();\n  int64_t GetVideoHeight();\n};\n'
MAIN = '\nint main() {\n  int failed=0;\n  VideoOutput output;\n  for (auto axis : {0,1}) {\n    try {\n      auto actual=axis==0 ? output.GetVideoWidth() : output.GetVideoHeight();\n      if (actual != 0) throw std::runtime_error("failed property produced stale dimensions");\n      std::cout << "PASS unavailable " << (axis==0 ? "width" : "height") << \'\\n\';\n    } catch (const std::exception& error) {\n      failed++;\n      std::cout << "FAIL unavailable " << (axis==0 ? "width" : "height") << ": " << error.what() << \'\\n\';\n    }\n  }\n  property_available=true;\n  valid_map.num=3;valid_map.values=values;valid_map.keys=keys;\n  for (int i=0;i<3;i++) values[i].format=MPV_FORMAT_INT64;\n  values[0].u.int64=1920;values[1].u.int64=1080;values[2].u.int64=0;\n  if (output.GetVideoWidth()!=1920 || output.GetVideoHeight()!=1080 || valid_frees!=2) {\n    std::cout << "FAIL valid source dimensions/cleanup\\n";failed++;\n  } else std::cout << "PASS valid source dimensions and exactly-once cleanup\\n";\n  std::cout << "Invalid result frees: " << invalid_frees << \'\\n\';\n  return failed ? 1 : 0;\n}\n'

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
