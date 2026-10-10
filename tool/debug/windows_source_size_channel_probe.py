#!/usr/bin/env python3
"""Exercise the production source-size channel branch with Flutter integer values."""
import argparse
from pathlib import Path
import subprocess

from windows_texture_frame_probe import method


HEADER = r"""
#include <flutter/encodable_value.h>
#include <flutter/standard_message_codec.h>
#include <cstdint>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
struct FakeCall {
  flutter::EncodableValue value;
  const flutter::EncodableValue* arguments() const { return &value; }
};
struct FakeResult {
  bool succeeded = false;
  void Success(flutter::EncodableValue) { succeeded = true; }
};
struct FakeManager {
  int64_t handle = 0, width = 0, height = 0;
  void SetSourceSize(int64_t h, int64_t w, int64_t v) {
    handle = h; width = w; height = v;
  }
};
class FixturePlugin {
 public:
  FakeManager manager;
  FakeManager* video_output_manager_ = &manager;
  void Dispatch(const FakeCall& method_call, FakeResult* result) BRANCH
};
"""

MAIN = r"""
int main() {
  int failures = 0;
  // Dart StandardMessageCodec uses int32 for ordinary video dimensions.
  for (bool wide : {false, true}) {
    FixturePlugin plugin;
    FakeResult result;
    flutter::EncodableMap arguments = {
      {flutter::EncodableValue("handle"), flutter::EncodableValue("42")},
      {flutter::EncodableValue("width"), wide ? flutter::EncodableValue(int64_t{1920})
                                             : flutter::EncodableValue(int32_t{1920})},
      {flutter::EncodableValue("height"), wide ? flutter::EncodableValue(int64_t{1080})
                                              : flutter::EncodableValue(int32_t{1080})},
    };
    try {
      const auto& codec = flutter::StandardMessageCodec::GetInstance();
      const auto bytes = codec.EncodeMessage(flutter::EncodableValue(arguments));
      const auto decoded = codec.DecodeMessage(*bytes);
      plugin.Dispatch({*decoded}, &result);
      if (!result.succeeded || plugin.manager.handle != 42 ||
          plugin.manager.width != 1920 || plugin.manager.height != 1080) {
        throw std::runtime_error("source geometry was not forwarded");
      }
      std::cout << "PASS " << (wide ? "int64" : "int32") << " source-size channel\n";
    } catch (const std::exception& error) {
      std::cout << "FAIL " << (wide ? "int64" : "int32") << ": " << error.what() << '\n';
      failures++;
    }
  }
  return failures ? 1 : 0;
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler', default='g++')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    source = (root / 'third_party/media_kit_video/windows/media_kit_video_plugin.cc').read_text(encoding='utf-8')
    branch = method(source, '} else if (method_call.method_name().compare("VideoOutputManager.SetSourceSize")')
    branch = branch[branch.index('{'):]
    build = root / 'build/windows-playback-diagnosis'
    build.mkdir(parents=True, exist_ok=True)
    fixture = build / 'source_size_channel_probe.cc'
    fixture.write_text(HEADER.replace('BRANCH', branch) + MAIN, encoding='utf-8')
    binary = build / 'source_size_channel_probe.exe'
    includes = root / 'windows/flutter/ephemeral/cpp_client_wrapper/include'
    codec = includes.parent / 'standard_codec.cc'
    subprocess.run([args.compiler, '-std=c++17', '-O0', '-static-libgcc',
                    '-static-libstdc++', '-I', str(includes), str(fixture), str(codec),
                    '-o', str(binary)], check=True)
    raise SystemExit(subprocess.run([str(binary)]).returncode)


if __name__ == '__main__':
    main()
