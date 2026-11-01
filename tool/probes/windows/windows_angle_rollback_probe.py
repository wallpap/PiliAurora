"""Compile production ANGLE manager with counted COM/EGL/Win32 fault injection.

Requires only an existing C++17 compiler. All generated files use a system temp
directory; no application, driver or shared build output is loaded or changed.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


PLATFORM = r'''
#pragma once
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>
using HANDLE = void*;
using UINT = unsigned;
using HRESULT = long;
using EGLint = int;
using EGLDisplay = void*;
using EGLContext = void*;
using EGLSurface = void*;
using EGLConfig = void*;
#undef __uuidof
#define __uuidof(T) 0
#define FAILED(hr) ((hr) < 0)
#define SUCCEEDED(hr) ((hr) >= 0)
#define FALSE 0
#define INFINITE 0
static std::string fault;
static bool legacy = false;
static std::atomic<int> mutexes{0}, next_id{10}, display_calls{0}, concurrent_display_calls{0};
static thread_local int texture_index = 0;
static int current_destroys = 0, live_terminations = 0;
static std::mutex platform_mutex;
static int display_slot = 0;
static std::unordered_map<void*, EGLDisplay> contexts, surfaces;
static std::set<void*> displays;
static thread_local void* current_context = nullptr;
static bool Fail(const std::string& point) { return fault == point; }
inline HANDLE CreateMutex(void*, int, void*) {
  if (Fail("mutex")) return nullptr;
  ++mutexes; return reinterpret_cast<void*>(1);
}
inline void CloseHandle(HANDLE h) { if(h) --mutexes; }
inline void ReleaseMutex(HANDLE) {}
inline void WaitForSingleObject(HANDLE, int) {}
enum D3D_FEATURE_LEVEL {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
  D3D_FEATURE_LEVEL_10_0, D3D_FEATURE_LEVEL_9_3};
enum D3D_DRIVER_TYPE {D3D_DRIVER_TYPE_UNKNOWN, D3D_DRIVER_TYPE_HARDWARE};
enum {D3D11_SDK_VERSION, DXGI_FORMAT_B8G8R8A8_UNORM, D3D11_USAGE_DEFAULT,
  D3D11_BIND_RENDER_TARGET, D3D11_BIND_SHADER_RESOURCE, D3D11_RESOURCE_MISC_SHARED};
struct D3D11_TEXTURE2D_DESC {
  int Width, Height, Format, MipLevels, ArraySize;
  struct {int Count, Quality;} SampleDesc;
  int Usage, BindFlags, CPUAccessFlags, MiscFlags;
};
struct FakeCom;
static std::vector<std::unique_ptr<FakeCom>> objects;
struct FakeCom {
  int refs = 1;
  std::string kind;
  explicit FakeCom(std::string name) : kind(std::move(name)) {}
  void AddRef() { if(refs <= 0) throw std::runtime_error("AddRef after release"); ++refs; }
  void Release() { if(--refs < 0) throw std::runtime_error("double COM release"); }
  HRESULT QueryInterface(int, void** result);
  HRESULT EnumAdapters(int, FakeCom** result);
  HRESULT CreateTexture2D(D3D11_TEXTURE2D_DESC*, void*, FakeCom** result);
  HRESULT GetSharedHandle(HANDLE* result) {
    if(Fail(kind + "_handle")) return -1;
    *result = this; return 0;
  }
  void SetGPUThreadPriority(int) {}
  D3D_FEATURE_LEVEL GetFeatureLevel() { return D3D_FEATURE_LEVEL_11_0; }
  void CopyResource(FakeCom*, FakeCom*) {}
  void Flush() {}
};
static FakeCom* NewCom(const std::string& name) {
  std::lock_guard<std::mutex> lock(platform_mutex);
  objects.push_back(std::make_unique<FakeCom>(name)); return objects.back().get();
}
inline HRESULT FakeCom::QueryInterface(int, void** result) {
  *result = NewCom("dxgi_device"); return 0;
}
inline HRESULT FakeCom::EnumAdapters(int, FakeCom** result) {
  if(Fail("adapter")) return -1;
  *result = NewCom("adapter"); return 0;
}
inline HRESULT FakeCom::CreateTexture2D(D3D11_TEXTURE2D_DESC*, void*, FakeCom** result) {
  const auto name = (++texture_index % 2) ? "internal" : "external";
  if(Fail(name)) return -1;
  *result = NewCom(name); return 0;
}
using ID3D11Device = FakeCom;
using ID3D11DeviceContext = FakeCom;
using ID3D11Texture2D = FakeCom;
using IDXGIFactory = FakeCom;
using IDXGIAdapter = FakeCom;
using IDXGIDevice = FakeCom;
using IDXGIResource = FakeCom;
inline HRESULT CreateDXGIFactory(int, void** result) {
  // Keep a valid output even on failure so the old unchecked path is observable.
  *result = NewCom("factory"); return Fail("factory") ? -1 : 0;
}
inline HRESULT D3D11CreateDevice(FakeCom*, D3D_DRIVER_TYPE, int, int,
    const D3D_FEATURE_LEVEL*, UINT, int, FakeCom** device, int, FakeCom** context) {
  *device = NewCom("device"); *context = NewCom("device_context");
  return Fail("device") ? -1 : 0;
}
namespace Microsoft { namespace WRL {
template<class T> class ComPtr {
  T* value_ = nullptr;
 public:
  ComPtr() = default;
  ComPtr(std::nullptr_t) {}
  ~ComPtr() { Reset(); }
  ComPtr(const ComPtr&) = delete;
  T* Get() const { return value_; }
  T* operator->() const { return value_; }
  explicit operator bool() const { return value_ != nullptr; }
  bool operator!=(std::nullptr_t) const { return value_ != nullptr; }
  T** operator&() { Reset(); return &value_; }
  void Reset() { if(value_) { value_->Release(); value_ = nullptr; } }
  ComPtr& operator=(std::nullptr_t) { Reset(); return *this; }
  template<class U> HRESULT As(U** result) {
    if(Fail(value_->kind + "_as")) return -1;
    value_->AddRef(); *result = value_; return 0;
  }
};
}}
class Utils { public: static bool IsWindows10RTMOrGreater() { return !legacy; } };
EGL_CONSTANTS
inline EGLDisplay PlatformDisplay(EGLint, void*, const EGLint*) {
  return reinterpret_cast<void*>(2 + display_slot);
}
using PFNEGLGETPLATFORMDISPLAYEXTPROC = decltype(&PlatformDisplay);
inline void* eglGetProcAddress(const char*) {
  return Fail("getproc") ? nullptr : reinterpret_cast<void*>(&PlatformDisplay);
}
inline int eglInitialize(EGLDisplay display, int*, int*) {
  if(++display_calls != 1) ++concurrent_display_calls;
  std::this_thread::yield();
  std::lock_guard<std::mutex> lock(platform_mutex);
  const auto failed = Fail("initialize");
  if(!failed) displays.insert(display);
  --display_calls;
  return failed ? EGL_FALSE : EGL_TRUE;
}
inline int eglChooseConfig(EGLDisplay, const EGLint*, EGLConfig* config, int, int* count) {
  *count = Fail("choose") ? 0 : 1; *config = reinterpret_cast<void*>(3); return EGL_TRUE;
}
inline EGLContext eglCreateContext(EGLDisplay display, EGLConfig, EGLContext, const EGLint*) {
  std::lock_guard<std::mutex> lock(platform_mutex);
  if(Fail("context")) return EGL_NO_CONTEXT;
  auto result = reinterpret_cast<void*>(++next_id); contexts.emplace(result, display); return result;
}
inline EGLSurface eglCreatePbufferFromClientBuffer(EGLDisplay display, int, void*, EGLConfig, EGLint*) {
  std::lock_guard<std::mutex> lock(platform_mutex);
  if(Fail("surface")) return EGL_NO_SURFACE;
  auto result = reinterpret_cast<void*>(++next_id); surfaces.emplace(result, display); return result;
}
inline void eglMakeCurrent(EGLDisplay, EGLSurface, EGLSurface, EGLContext context) {
  current_context = context;
}
inline void eglDestroyContext(EGLDisplay, EGLContext context) {
  std::lock_guard<std::mutex> lock(platform_mutex);
  if(current_context == context) ++current_destroys;
  contexts.erase(context);
}
inline void eglDestroySurface(EGLDisplay, EGLSurface surface) {
  std::lock_guard<std::mutex> lock(platform_mutex); surfaces.erase(surface);
}
inline void eglTerminate(EGLDisplay display) {
  if(++display_calls != 1) ++concurrent_display_calls;
  std::this_thread::yield();
  std::lock_guard<std::mutex> lock(platform_mutex);
  for(const auto& context : contexts) if(context.second == display) ++live_terminations;
  for(const auto& surface : surfaces) if(surface.second == display) ++live_terminations;
  displays.erase(display);
  --display_calls;
}
inline void glFinish() {}
'''

MAIN = r'''
#include "angle_surface_manager.h"
#include "angle_surface_manager.cc"
#ifdef MEDIA_KIT_VIDEO_NATIVE_MEMORY_STATS_H_
static void CheckMemoryEmpty();
#endif
static int failures = 0;
static void Check(bool okay, const std::string& label) {
  if(!okay) { ++failures; std::cout << "FAIL " << label << '\n'; }
}
static int LiveCom() {
  int count = 0; for(const auto& object : objects) count += object->refs; return count;
}
#ifdef MEDIA_KIT_VIDEO_NATIVE_MEMORY_STATS_H_
static void CheckMemoryEmpty() {
  const auto snapshot = media_kit_memory::Registry::Instance().Read();
  for(const auto& resource : snapshot.resources) {
    Check(resource.count == 0 && resource.estimated_bytes == 0,
          "native memory resource gauge returns to zero");
    Check(resource.created == resource.released, "native memory lifetime totals balance");
  }
}
#endif
int main() {
  for(bool use_legacy : {false, true}) {
    legacy = use_legacy;
    for(const auto& point : {"mutex", "factory", "adapter", "device", "internal",
        "internal_as", "internal_handle", "external", "external_as", "external_handle",
        "getproc", "initialize", "choose", "context", "surface", "success"}) {
      if(!legacy && (std::string(point)=="factory" || std::string(point)=="adapter")) continue;
      fault = point; texture_index = 0;
      const auto com_before = LiveCom();
      const auto mutex_before = mutexes.load();
      const auto egl_before = contexts.size() + surfaces.size() + displays.size();
      bool threw = false;
      try { ANGLESurfaceManager manager(640, 360); manager.MakeCurrent(true); }
      catch(const std::runtime_error&) { threw = true; }
      Check(threw == (fault != "success"), fault + " failure propagation");
      Check(LiveCom() == com_before, fault + " COM references");
      Check(mutexes == mutex_before, fault + " mutex handles");
      Check(contexts.size() + surfaces.size() + displays.size() == egl_before, fault + " EGL rollback");
#ifdef MEDIA_KIT_VIDEO_NATIVE_MEMORY_STATS_H_
      CheckMemoryEmpty();
#endif
      // Isolate counters after a failed baseline case; the assertions above retain the verdict.
      for(auto& object : objects) object->refs = 0;
      mutexes = 0; contexts.clear(); surfaces.clear(); displays.clear(); current_context = nullptr;
    }
  }
  legacy = false; fault.clear(); texture_index = 0;
  {
    ANGLESurfaceManager live(640, 360);
    fault = "surface";
    try { ANGLESurfaceManager failed(800, 450); } catch(const std::runtime_error&) {}
    Check(contexts.size()==1 && surfaces.size()==1 && displays.size()==1,
          "failed sibling preserves shared EGL display and live context");
    display_slot = 1;
    try { ANGLESurfaceManager failed_other_display(800, 450); } catch(const std::runtime_error&) {}
    Check(contexts.size()==1 && surfaces.size()==1 && displays.size()==1,
          "failed sibling releases its distinct EGL display");
    fault.clear();
    {
      ANGLESurfaceManager other_display(800, 450);
      Check(displays.size()==2, "distinct live displays");
    }
    Check(displays.size()==1, "distinct display releases independently");
    display_slot = 0;
    live.SetSize(960, 540);
    live.SetSize(1280, 720);
    Check(contexts.size()==1 && surfaces.size()==1, "resize reuses context");
#ifdef MEDIA_KIT_VIDEO_NATIVE_MEMORY_STATS_H_
    const auto stats = media_kit_memory::Registry::Instance().Read();
    const auto textures = stats.resources[static_cast<size_t>(media_kit_memory::Resource::texture)];
    Check(textures.count == 2 && textures.estimated_bytes == 1280LL * 720 * 4 * 2,
          "resize replaces nominal texture bytes");
    Check(stats.resources[static_cast<size_t>(media_kit_memory::Resource::device)].count == 1,
          "resize retains one device");
#endif
  }
  Check(LiveCom()==0 && mutexes==0 && contexts.empty() && surfaces.empty() && displays.empty(),
        "shared display final release");
  Check(current_destroys==0, "detach current context before destruction");
  Check(live_terminations==0, "terminate only after final context and surface release");
  if(!failures) {
    std::atomic<int> acquired{0};
    std::vector<std::thread> workers;
    for(int i=0; i<8; ++i) workers.emplace_back([&] {
      ANGLESurfaceManager manager(640, 360);
      ++acquired;
      while(acquired < 8) std::this_thread::yield();
    });
    for(auto& worker : workers) worker.join();
    Check(concurrent_display_calls==0, "cross-manager display initialize/terminate serialization");
    Check(LiveCom()==0 && mutexes==0 && contexts.empty() && surfaces.empty() && displays.empty(),
          "cross-thread final resource release");
    Check(live_terminations==0, "cross-thread display stays alive until last user");
  }
  if(!failures) std::cout << "PASS ANGLE constructor fault matrix, shared display and resize ownership\n";
#ifdef MEDIA_KIT_VIDEO_NATIVE_MEMORY_STATS_H_
  CheckMemoryEmpty();
#endif
  return failures ? 1 : 0;
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
    header = read("angle_surface_manager.h")
    source = read("angle_surface_manager.cc")
    tokens = sorted(set(re.findall(r'\bEGL_[A-Z0-9_]+\b', header + source)))
    special = {"EGL_FALSE": "0", "EGL_TRUE": "1", "EGL_NO_DISPLAY": "nullptr",
               "EGL_NO_CONTEXT": "nullptr", "EGL_NO_SURFACE": "nullptr",
               "EGL_DEFAULT_DISPLAY": "nullptr"}
    constants = "\n".join(f"#define {token} {special.get(token, str(i+100))}"
                          for i, token in enumerate(tokens))
    # Only external platform declarations are substituted; all production members
    # and methods are compiled verbatim, including construction and destruction.
    header = re.sub(r'^#include [<"](?:EGL/|GLES2/|Windows|d3d|wrl|utils)[^\n]+\n',
                    '', header, flags=re.M)
    with tempfile.TemporaryDirectory(prefix="piliaurora-angle-rollback-") as directory:
        output = Path(directory)
        (output / "fake_platform.h").write_text(PLATFORM.replace("EGL_CONSTANTS", constants), encoding="utf-8")
        (output / "angle_surface_manager.h").write_text('#include "fake_platform.h"\n' + header, encoding="utf-8")
        (output / "angle_surface_manager.cc").write_text(source, encoding="utf-8")
        if '"native_memory_stats.h"' in header:
            (output / "native_memory_stats.h").write_text(read("native_memory_stats.h"), encoding="utf-8")
        (output / "probe.cc").write_text(MAIN, encoding="utf-8")
        binary = output / "probe.exe"
        subprocess.run([args.compiler, "-std=c++17", "-O0", "-static-libgcc", "-static-libstdc++",
                        str(output / "probe.cc"),
                        "-o", str(binary)], check=True)
        raise SystemExit(subprocess.run([binary]).returncode)


if __name__ == "__main__":
    main()
