"""Run complete production VideoOutput with delayed Flutter unregister receipts.

Uses the production render thread pool and class declarations. Flutter, ANGLE and
libmpv are counted substitutes; generated sources/binaries use system temp only.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile


PLATFORM = r'''
#pragma once
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <thread>
#include <unordered_map>
#include <vector>
inline std::atomic<int> pending_receipts{0}, unsafe_releases{0}, context_creates{0},
    context_frees{0}, surface_creates{0}, surface_frees{0}, registrations{0};
inline bool fail_surface_create = false, fail_resize = false;
inline void CheckBarrier() { if(pending_receipts.load()) ++unsafe_releases; }
class ANGLESurfaceManager {
  int32_t width_, height_;
 public:
  ANGLESurfaceManager(int32_t width, int32_t height) : width_(width), height_(height) {
    CheckBarrier();
    if(fail_surface_create) throw std::runtime_error("injected ANGLE constructor failure");
    ++surface_creates;
  }
  ~ANGLESurfaceManager() { CheckBarrier(); ++surface_frees; }
  void SetSize(int32_t width, int32_t height) {
    if(width==width_ && height==height_) return;
    CheckBarrier();
    if(fail_resize) { fail_resize = false; throw std::runtime_error("injected resize failure"); }
    width_ = width; height_ = height;
  }
  int32_t width() const { return width_; }
  int32_t height() const { return height_; }
  void* handle() const { return reinterpret_cast<void*>(1); }
  void MakeCurrent(bool) {}
  void Read() {}
  void Draw(std::function<void()> callback) { callback(); }
};
inline void* eglGetProcAddress(const char*) { return nullptr; }
struct mpv_handle {};
struct mpv_render_context {};
struct mpv_render_param { int type; const void* data; };
struct mpv_opengl_init_params { void* (*get_proc_address)(void*, const char*); void* context; };
struct mpv_opengl_fbo { int fbo, width, height, internal_format; };
enum {MPV_RENDER_PARAM_INVALID, MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
      MPV_RENDER_PARAM_OPENGL_FBO, MPV_RENDER_PARAM_SW_SIZE, MPV_RENDER_PARAM_SW_FORMAT,
      MPV_RENDER_PARAM_SW_STRIDE, MPV_RENDER_PARAM_SW_POINTER, MPV_RENDER_UPDATE_FRAME};
#define MPV_RENDER_API_TYPE_OPENGL "opengl"
#define MPV_RENDER_API_TYPE_SW "sw"
inline int mpv_set_option_string(mpv_handle*, const char*, const char*) { return 0; }
inline int mpv_render_context_create(mpv_render_context** context, mpv_handle*, mpv_render_param*) {
  CheckBarrier(); ++context_creates; *context = new mpv_render_context; return 0;
}
inline void mpv_render_context_set_update_callback(mpv_render_context*, void (*)(void*), void*) {}
inline void mpv_render_context_free(mpv_render_context* context) {
  CheckBarrier(); ++context_frees; delete context;
}
inline uint64_t mpv_render_context_update(mpv_render_context*) { return MPV_RENDER_UPDATE_FRAME; }
inline std::function<void()> render_hook;
inline int mpv_render_context_render(mpv_render_context*, mpv_render_param*) {
  if(render_hook) render_hook();
  return 0;
}
constexpr int kFlutterDesktopPixelFormatBGRA8888 = 1;
constexpr int kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle = 1;
struct FlutterDesktopGpuSurfaceDescriptor {
  size_t struct_size; void* handle; size_t width, visible_width, height, visible_height;
  void* release_context; void (*release_callback)(void*); int format;
};
struct FlutterDesktopPixelBuffer {
  const uint8_t* buffer; size_t width, height; void* release_context; void (*release_callback)(void*);
};
namespace flutter {
struct GpuSurfaceTexture { template<class F> GpuSurfaceTexture(int, F) {} };
struct PixelBufferTexture { template<class F> PixelBufferTexture(F) {} };
struct TextureVariant { template<class T> TextureVariant(T) {} };
struct TextureRegistrar {
  int64_t next = 1;
  std::mutex mutex;
  std::map<int64_t, std::function<void()>> receipts;
  int64_t RegisterTexture(TextureVariant*) { ++registrations; return next++; }
  void UnregisterTexture(int64_t id, std::function<void()> callback) {
    std::lock_guard<std::mutex> lock(mutex);
    if(receipts.count(id)) throw std::runtime_error("duplicate unregistration");
    ++pending_receipts; receipts.emplace(id, std::move(callback));
  }
  bool MarkTextureFrameAvailable(int64_t) { return true; }
  bool Receipt() {
    std::function<void()> callback;
    {
      std::lock_guard<std::mutex> lock(mutex);
      if(receipts.empty()) return false;
      auto found = receipts.begin(); callback = std::move(found->second);
      receipts.erase(found); --pending_receipts;
    }
    callback(); return true;
  }
};
class PluginRegistrarWindows {
 public:
  TextureRegistrar textures;
  TextureRegistrar* texture_registrar() { return &textures; }
};
}
'''

MAIN = r'''
#include "video_output.h"
#include "video_output.cc"
static void Require(bool condition, const char* message) {
  if(!condition) { std::cerr << "FAIL " << message << std::endl; std::exit(1); }
}
struct Fixture {
  flutter::PluginRegistrarWindows registrar;
  ThreadPool pool{1};
  std::unique_ptr<VideoOutput> output = std::make_unique<VideoOutput>(
      1, VideoOutputConfiguration{640, 360, true}, &registrar, &pool,
      [](const auto&, auto, auto, auto) {}, [](const auto&, auto) {}, [](const auto&) {});
  Fixture() { output->SetSourceSize(640, 360, std::nullopt); Drain(); }
  void Drain() { pool.Post([] {}).get(); }
  void Receipts() {
    for(int i=0; i<20; ++i) {
      Drain(); if(!registrar.textures.Receipt()) return;
    }
    throw std::runtime_error("texture operations failed to settle");
  }
  void Destroy() {
    auto* raw = output.get();
    auto done = std::async(std::launch::async, [&] { output.reset(); });
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    // destroyed_ is made public only in the fixture's copied header.
    while(!raw->destroyed_.load()) {
      Require(std::chrono::steady_clock::now() < deadline, "destructor did not start");
      std::this_thread::yield();
    }
    for(;;) {
      Drain();
      if(done.wait_for(std::chrono::milliseconds(0)) == std::future_status::ready) break;
      registrar.textures.Receipt();
      Require(std::chrono::steady_clock::now() < deadline, "destructor release barrier stuck");
      std::this_thread::yield();
    }
    done.get();
  }
  ~Fixture() { if(output) Destroy(); }
};
static void Settled(Fixture& f) {
  f.Receipts();
  Require(pending_receipts==0, "unregistration not settled");
  Require(unsafe_releases==0, "resource mutation crossed Flutter unregister barrier");
}
int main() {
  try {
    {
      Fixture f;
      f.output->SetTextureUpdateCallback([](auto, auto, auto) {});
      const OutputOperationToken token{1, 1, 1, 0};
      f.output->BeginOutputForLoad(token, [](bool okay) {
        Require(okay, "output token rejected");
      });
      f.Drain();
      std::promise<void> first_render, resume_render, invalidated, rendered_all;
      auto resume = resume_render.get_future().share();
      auto first = first_render.get_future();
      auto retired = invalidated.get_future();
      auto all = rendered_all.get_future();
      std::atomic<int> renders{0};
      int renders_at_revoke = 0;
      // 每次渲染期间继续收到更新，退出请求排在第一帧之后。
      render_hook = [&] {
        const auto count = renders.fetch_add(1) + 1;
        if(count == 1) {
          first_render.set_value();
          resume.wait();
        }
        if(count < 64) f.output->NotifyRender();
        else if(count == 64) rendered_all.set_value();
      };
      f.output->NotifyRender();
      Require(first.wait_for(std::chrono::seconds(2)) == std::future_status::ready,
              "render did not start");
      f.output->InvalidateOutputGeneration(token, [&](bool okay) {
        Require(okay, "invalidation rejected");
        renders_at_revoke = renders.load();
        invalidated.set_value();
      });
      resume_render.set_value();
      Require(retired.wait_for(std::chrono::seconds(2)) == std::future_status::ready,
              "generation revoke did not complete");
      Require(all.wait_for(std::chrono::seconds(2)) == std::future_status::ready,
              "render updates did not settle");
      f.Drain();
      render_hook = nullptr;
      Require(renders_at_revoke < 64,
              "continuous render updates starved the unload generation revoke");
      std::cout << "PASS rendering yields to unload generation revoke\n";
    }
    {
      Fixture f; int size_calls=0, reset_calls=0, last_calls=0;
      f.output->SetSize(800, 450, [&](bool okay) { Require(okay, "resize failed"); ++size_calls; });
      f.Drain(); Require(pending_receipts==1, "resize must wait for Flutter");
      const auto frees = context_frees.load();
      f.output->ResetRenderer([&](bool okay) { Require(okay, "reset failed"); ++reset_calls; });
      f.output->SetSize(960, 540, [&](bool okay) { Require(okay, "queued resize failed"); ++last_calls; });
      f.Drain();
      Require(context_frees==frees && reset_calls==0, "reset freed renderer during pending resize receipt");
      Settled(f);
      Require(size_calls==1 && reset_calls==1 && last_calls==1, "resize/reset callbacks must complete once");
      Require(f.output->width()==960 && f.output->height()==540, "latest requested size lost");
      std::cout << "PASS resize -> reset -> resize waits for each Flutter receipt\n";
    }
    {
      Fixture f; int resets=0, sizes=0;
      f.output->ResetRenderer([&](bool okay) { Require(okay, "first reset failed"); ++resets; });
      f.Drain(); const auto before = registrations.load();
      f.output->SetSize(800, 450, [&](bool okay) { Require(okay, "size after reset failed"); ++sizes; });
      f.output->ResetRenderer([&](bool okay) { Require(okay, "second reset failed"); ++resets; });
      f.Drain();
      Require(registrations==before && resets==0 && sizes==0, "queued operation bypassed reset receipt");
      Settled(f);
      Require(resets==2 && sizes==1, "repeated reset/size callback count");
      Require(f.output->width()==800 && f.output->height()==450, "reset lost queued size");
      std::cout << "PASS reset -> resize -> reset serializes all resource changes\n";
    }
    {
      Fixture f; int failed=0, resets=0;
      fail_resize = true;
      f.output->SetSize(800, 450, [&](bool okay) { Require(!okay, "faulted resize succeeded"); ++failed; });
      f.output->ResetRenderer([&](bool okay) { Require(okay, "reset after resize fault failed"); ++resets; });
      Settled(f);
      Require(failed==1 && resets==1, "failure did not drain queued reset");
      std::cout << "PASS failed resize completes and drains queued reset\n";
    }
    {
      Fixture f; int resets=0, sizes=0;
      f.output->ResetRenderer([&](bool okay) { Require(okay, "software fallback reset failed"); ++resets; });
      f.Drain(); fail_surface_create = true;
      f.output->SetSize(800, 450, [&](bool okay) { Require(okay, "software resize failed"); ++sizes; });
      Settled(f); fail_surface_create = false;
      Require(resets==1 && sizes==1 && f.output->pixel_buffer_!=nullptr, "reset fallback did not settle");
      std::cout << "PASS reset software fallback preserves queued resize completion\n";
    }
    for(bool resize_first : {true, false}) {
      Fixture f; int resets=0, sizes=0;
      auto size = [&] { f.output->SetSize(800, 450, [&](bool okay) { Require(!okay, "destroyed size succeeded"); ++sizes; }); };
      auto reset = [&] { f.output->ResetRenderer([&](bool okay) { Require(!okay, "destroyed reset succeeded"); ++resets; }); };
      if(resize_first) { size(); reset(); } else { reset(); size(); }
      f.Drain(); Require(pending_receipts==1, "expected one delayed destructor receipt");
      f.Destroy();
      Require(resets==1 && sizes==1 && pending_receipts==0, "destruction lost queued completion");
      Require(unsafe_releases==0, "destructor crossed resource barrier");
    }
    Require(context_creates==context_frees && surface_creates==surface_frees, "renderer ownership unbalanced");
    std::cout << "PASS destruction drains resize/reset receipts and releases all renderers\n";
    return 0;
  } catch(const std::exception& error) {
    std::cout << "FAIL " << error.what() << '\n'; return 1;
  }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler", default="g++")
    parser.add_argument("--source-ref", help="Read production sources from a Git revision for baseline comparison")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    native = root / "third_party/media_kit_video/windows"
    def read(name):
        if args.source_ref:
            return subprocess.check_output(["git", "show", f"{args.source_ref}:third_party/media_kit_video/windows/{name}"],
                                           cwd=root).decode("utf-8")
        return (native / name).read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="piliaurora-renderer-release-") as directory:
        output = Path(directory)
        (output / "fake_platform.h").write_text(PLATFORM, encoding="utf-8")
        for name in ["client.h", "render.h", "render_gl.h", "angle_surface_manager.h",
                     "flutter/method_channel.h", "flutter/plugin_registrar_windows.h",
                     "flutter/standard_method_codec.h"]:
            path = output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('#include "fake_platform.h"\n', encoding="utf-8")
        header = read("video_output.h")
        (output / "video_output.h").write_text(header.replace(" private:", " public:"), encoding="utf-8")
        (output / "video_output.cc").write_text(read("video_output.cc"), encoding="utf-8")
        (output / "probe.cc").write_text(MAIN, encoding="utf-8")
        binary = output / "probe.exe"
        subprocess.run([args.compiler, "-std=c++17", "-O0", "-static-libgcc", "-static-libstdc++",
                        "-I", str(output), "-I", str(native), str(output / "probe.cc"),
                        "-o", str(binary)], check=True)
        raise SystemExit(subprocess.run([binary], timeout=15).returncode)


if __name__ == "__main__":
    main()
