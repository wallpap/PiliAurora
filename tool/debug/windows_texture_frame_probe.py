#!/usr/bin/env python3
"""Run exact Windows Resize/Render methods with fake Flutter/ANGLE/mpv only.

Detects publishing a replacement texture before its first frame is rendered and
marked available, the observable blank-texture interval during viewport changes.
"""
import argparse
from pathlib import Path
import re
import subprocess

HEADER = r"""
#include <render.h>
#include <render_gl.h>
#include <algorithm>
#include <cassert>
#include <deque>
#include <stdexcept>
#include <cstdint>
#include <cstring>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <optional>
#include <unordered_map>
static bool frame_drawn=false, frame_notified=false;
static int render_status=0;
static bool reject_frame=false;
static bool core_waiting_for_render=false;
extern "C" int mpv_get_property(mpv_handle*, const char*, mpv_format, void*) {
  if(core_waiting_for_render) throw std::runtime_error("render thread waited for mpv core before drawing first frame");
  return MPV_ERROR_PROPERTY_UNAVAILABLE;
}
extern "C" void mpv_free_node_contents(mpv_node*) {}
extern "C" int mpv_render_context_render(mpv_render_context*, mpv_render_param*) {
  frame_drawn=render_status>=0; return render_status;
}
constexpr int kFlutterDesktopPixelFormatBGRA8888=1;
constexpr int kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle=1;
struct FlutterDesktopGpuSurfaceDescriptor {
  size_t struct_size; void* handle; size_t width,visible_width,height,visible_height;
  void* release_context; void (*release_callback)(void*); int format;
};
struct FlutterDesktopPixelBuffer {
  const uint8_t* buffer; size_t width,height; void* release_context;
  void (*release_callback)(void*);
};
namespace flutter {
struct GpuSurfaceTexture { template<class F> GpuSurfaceTexture(int,F) {} };
struct PixelBufferTexture { template<class F> PixelBufferTexture(F) {} };
struct TextureVariant { template<class T> TextureVariant(T) {} };
}
struct FakeTextureRegistrar {
  int64_t next=1;
  template<class T> int64_t RegisterTexture(T*) { frame_drawn=false; frame_notified=false; return next++; }
  void UnregisterTexture(int64_t,std::function<void()> done) { done(); }
  bool MarkTextureFrameAvailable(int64_t) { frame_notified=frame_drawn&&!reject_frame;return !reject_frame; }
};
struct FakeRegistrar { FakeTextureRegistrar textures; auto texture_registrar() { return &textures; } };
struct FakeSurface {
  int32_t w=320,h=180;
  void SetSize(int32_t width,int32_t height) {w=width;h=height;frame_drawn=false;frame_notified=false;}
  void* handle() {return this;}
  int32_t width() {return w;}
  int32_t height() {return h;}
  void Read() {}
  template<class F> void Draw(F f) {f();}
};
struct FakeFuture {bool blocked=false; void wait() {if(blocked) throw std::runtime_error("initial texture waited behind rendering");}};
struct FakeThreadPool {
  bool deferred=false;std::deque<std::function<void()>> jobs;
  template<class F> FakeFuture Post(F f) {if(deferred) jobs.push_back(f);else f();return {deferred};}
  void Drain() {while(!jobs.empty()) {auto job=jobs.front();jobs.pop_front();job();}}
};
constexpr int64_t SW_RENDERING_MAX_WIDTH=1920,SW_RENDERING_MAX_HEIGHT=1080;
class VideoOutput {
 public:
  std::optional<int64_t> width_,height_;
  mpv_handle* handle_=nullptr;
  int64_t source_width_=0,source_height_=0;
  FakeThreadPool pool; FakeThreadPool* thread_pool_ref_=&pool;
  int64_t GetVideoWidth();
  int64_t GetVideoHeight();
  void CheckAndResize();
  void SetSourceSize(int64_t,int64_t);
  void SetSize(std::optional<int64_t>,std::optional<int64_t>,std::function<void(bool)>);
  FakeRegistrar registrar; FakeRegistrar* registrar_=&registrar;
  int64_t texture_id_=0; bool destroyed_=false,texture_update_pending_=false;
  std::mutex textures_mutex_,callback_mutex_;
  std::unique_ptr<FakeSurface> surface_manager_=std::make_unique<FakeSurface>();
  std::unique_ptr<uint8_t[]> pixel_buffer_;
  std::unordered_map<int64_t,std::unique_ptr<flutter::TextureVariant>> texture_variants_;
  std::unordered_map<int64_t,std::unique_ptr<FlutterDesktopGpuSurfaceDescriptor>> textures_;
  std::unordered_map<int64_t,std::unique_ptr<FlutterDesktopPixelBuffer>> pixel_buffer_textures_;
  std::function<void(int64_t,int64_t,int64_t)> texture_update_callback_=[](auto,auto,auto){};
  mpv_render_context* render_context_=nullptr;
  int64_t width() {return surface_manager_ ? surface_manager_->width() : pixel_buffer_textures_.at(texture_id_)->width;}
  int64_t height() {return surface_manager_ ? surface_manager_->height() : pixel_buffer_textures_.at(texture_id_)->height;}
  void Resize(int64_t,int64_t);
  void NotifyTextureUpdate(int64_t,int64_t,int64_t);
  void SetTextureUpdateCallback(std::function<void(int64_t,int64_t,int64_t)>);
  RENDER_DECL
};
"""
MAIN = r"""
int main() {
  int failed=0;
  {
    VideoOutput output;output.Resize(1,1);
    core_waiting_for_render=true;
    try {
      output.CheckAndResize();output.Render();
      if(!frame_drawn) throw std::runtime_error("first frame was not drawn");
      if(!output.texture_update_pending_) throw std::runtime_error("placeholder acknowledged as a video frame");
      output.SetSourceSize(1920,1080);
      if(output.width()!=1920 || output.height()!=1080 || output.texture_update_pending_)
        throw std::runtime_error("observed dimensions did not publish the first video frame");
      std::cout<<"PASS startup renders while mpv core is waiting for the render thread\n";
    } catch(const std::exception& error) {std::cout<<"FAIL startup: "<<error.what()<<'\n';failed++;}
    core_waiting_for_render=false;
  }
  {
    VideoOutput output;output.Resize(1,1);output.pool.deferred=true;
    int initial=0;
    try {output.SetTextureUpdateCallback([&](auto,auto,auto){initial++;});}
    catch(...) {std::cout<<"FAIL initial texture registration blocked behind native rendering\n";failed++;}
    if(initial!=1) {std::cout<<"FAIL first texture was not delivered before pending render work\n";failed++;}
    else std::cout<<"PASS initial texture does not wait for video playback to begin\n";
    output.pool.deferred=false;output.pool.Drain();
  }
  for (bool hardware : {true,false}) {
    VideoOutput output;
    output.source_width_=640;output.source_height_=360;
    if(!hardware) {output.surface_manager_.reset();output.pixel_buffer_=std::make_unique<uint8_t[]>(16);}
    int published=0,early=0;
    output.texture_update_callback_=[&](auto,auto,auto) {published++;if(!frame_drawn||!frame_notified) early++;};
    for(auto size : {std::make_pair(640,360),std::make_pair(1280,720),std::make_pair(640,360)}) {
      auto before=published;
      output.Resize(size.first,size.second);
      if(published!=before) {std::cout<<"FAIL replacement texture published before native rendering\n";failed++;}
      output.Render();
      if(published!=before+1 || early) {std::cout<<"FAIL replacement has no rendered-and-notified first frame\n";failed++;}
    }
    // The actual SetSize caller must also wait for rendered/available content.
    int completions=0; bool acknowledged=false;
    output.SetSize(960,540,[&](bool ready) {
      completions++;acknowledged=ready&&frame_drawn&&frame_notified;
    });
    if(completions!=1 || !acknowledged) {std::cout<<"FAIL resize channel acknowledged an unready frame\n";failed++;}
    else std::cout<<"PASS SetSize acknowledges a rendered replacement\n";
    auto before=published;
    output.Resize(800,450);render_status=-1;
    output.Render();
    if(published!=before) {std::cout<<"FAIL failed render published a blank frame\n";failed++;}
    render_status=0;reject_frame=true;output.Render();
    if(published!=before) {std::cout<<"FAIL rejected frame published an unavailable texture\n";failed++;}
    reject_frame=false;output.Render();
    if(published!=before+1) {std::cout<<"FAIL successful render retry did not publish\n";failed++;}
    if(!early) std::cout<<"PASS "<<(hardware?"hardware":"software")<<" textures published only after first render\n";
    output.source_width_=1920;output.source_height_=1080;
    output.width_.reset();output.height_.reset();
    if(output.GetVideoWidth()!=1920 || output.GetVideoHeight()!=1080) {
      std::cout<<"FAIL automatic output lost source dimensions\n";failed++;
    }
    output.SetSourceSize(1280,720);
    if(output.width()!=1280 || output.height()!=720) {
      std::cout<<"FAIL source change did not resize automatic output\n";failed++;
    }
    output.SetSize(640,360,[](bool){});
    output.SetSourceSize(800,450);
    if(output.width()!=640 || output.height()!=360) {
      std::cout<<"FAIL source change replaced fixed output dimensions\n";failed++;
    }
    output.SetSize(std::nullopt,std::nullopt,[](bool){});
    if(output.width()!=800 || output.height()!=450) {
      std::cout<<"FAIL automatic sizing did not restore latest source dimensions\n";failed++;
    }
  }
  return failed ? 1 : 0;
}
"""

def method(source, name):
    start = source.index(name)
    start = source.rfind('\n', 0, start) + 1
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--compiler',default='g++')
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    source=(root/'third_party/media_kit_video/windows/video_output.cc').read_text(encoding='utf-8')
    render=method(source,'VideoOutput::Render()')
    resize=method(source,'VideoOutput::Resize(')
    set_size=method(source,'VideoOutput::SetSize(')
    set_callback=method(source,'VideoOutput::SetTextureUpdateCallback(')
    notify=method(source,'VideoOutput::NotifyTextureUpdate(')
    check_size=method(source,'VideoOutput::CheckAndResize()')
    geometry=method(source,'VideoOutput::GetVideoWidth()')+'\n'+method(source,'VideoOutput::GetVideoHeight()')
    source_size=method(source,'VideoOutput::SetSourceSize(')
    render_type=re.search(r'(void|bool) VideoOutput::Render',render)[1]
    build=root/'build/windows-playback-diagnosis'
    build.mkdir(parents=True,exist_ok=True)
    fixture=build/'texture_frame_probe.cc'
    fixture.write_text(HEADER.replace('RENDER_DECL',f'{render_type} Render();')+resize+'\n'+render+'\n'+set_size+'\n'+check_size+'\n'+set_callback+'\n'+notify+'\n'+geometry+'\n'+source_size+MAIN,encoding='utf-8')
    binary=build/'texture_frame_probe.exe'
    headers=root/'build/windows/x64/libmpv-20260819/include/mpv'
    subprocess.run([args.compiler,'-std=c++17','-fpermissive','-O0','-static-libgcc','-static-libstdc++','-I',str(headers),str(fixture),'-o',str(binary)],check=True)
    print('Mock-only probe: no real Flutter, ANGLE or libmpv is loaded.',flush=True)
    raise SystemExit(subprocess.run([str(binary)]).returncode)

if __name__=='__main__':
    main()

