// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#include "angle_surface_manager.h"

#include <iostream>

#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3d11.lib")

#define FAIL(message)                                                 \
  std::cout << "media_kit: ANGLESurfaceManager: Failure: " << message \
            << std::endl;                                             \
  return false

#define CHECK_HRESULT(message) \
  if (FAILED(hr)) {            \
    FAIL(message);             \
  }

std::mutex ANGLESurfaceManager::display_mutex_;
std::unordered_map<EGLDisplay, size_t> ANGLESurfaceManager::display_ref_counts_;

ANGLESurfaceManager::ANGLESurfaceManager(int32_t width, int32_t height, int64_t owner_id)
    : width_(width), height_(height),
      device_memory_(media_kit_memory::Resource::device, owner_id),
      context_memory_(media_kit_memory::Resource::egl_context, owner_id),
      surface_memory_(media_kit_memory::Resource::egl_surface, owner_id),
      texture_memory_(media_kit_memory::Resource::texture, owner_id) {
  mutex_ = ::CreateMutex(NULL, FALSE, NULL);
  if (mutex_ == nullptr) {
    throw std::runtime_error("Unable to create ANGLE surface mutex.");
  }
  try {
    Create();
  } catch (...) {
    // 构造失败不会调用本类析构，回退软件输出前须归还已取得的资源。
    CleanUp(true);
    ::CloseHandle(mutex_);
    mutex_ = nullptr;
    throw;
  }
}

ANGLESurfaceManager::~ANGLESurfaceManager() {
  CleanUp(true);
  ::CloseHandle(mutex_);
}

void ANGLESurfaceManager::SetSize(int32_t width, int32_t height) {
  if (width == width_ && height == height_) {
    return;
  }
  width_ = width;
  height_ = height;
  Create();
}

void ANGLESurfaceManager::Draw(std::function<void()> callback) {
  ::WaitForSingleObject(mutex_, INFINITE);
  MakeCurrent(true);
  callback();
  SwapBuffers();
  MakeCurrent(false);
  ::ReleaseMutex(mutex_);
}

bool ANGLESurfaceManager::Read(bool wait_for_completion) {
  ::WaitForSingleObject(mutex_, INFINITE);
  if (d3d_11_device_context_ == nullptr) {
    ::ReleaseMutex(mutex_);
    return false;
  }
  Microsoft::WRL::ComPtr<ID3D11Query> complete;
  if (wait_for_completion) {
    const D3D11_QUERY_DESC description{D3D11_QUERY_EVENT, 0};
    if (FAILED(d3d_11_device_->CreateQuery(&description, &complete))) {
      ::ReleaseMutex(mutex_);
      return false;
    }
  }
  d3d_11_device_context_->CopyResource(d3d_11_texture_2D_.Get(),
                                     internal_d3d_11_texture_2D_.Get());
  if (complete) d3d_11_device_context_->End(complete.Get());
  d3d_11_device_context_->Flush();
  bool copied = true;
  if (complete) {
    // Flush 只提交复制。新来源首次交给另一设备导入前，等待真正完成；
    // 后续帧保留异步提交，避免逐帧 CPU/GPU 等待扩大播放停顿。
    const ULONGLONG deadline = GetTickCount64() + 100;
    HRESULT status;
    do {
      status = d3d_11_device_context_->GetData(
          complete.Get(), nullptr, 0, D3D11_ASYNC_GETDATA_DONOTFLUSH);
      if (status != S_FALSE || GetTickCount64() >= deadline) break;
      SwitchToThread();
    } while (true);
    copied = status == S_OK;
  }
  ::ReleaseMutex(mutex_);
  return copied;
}

void ANGLESurfaceManager::MakeCurrent(bool value) {
  if (value) {
    eglMakeCurrent(display_, surface_, surface_, context_);
  } else {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
}

void ANGLESurfaceManager::SwapBuffers() {
  glFinish();
}

void ANGLESurfaceManager::Create() {
  CleanUp(false);
  if (!CreateD3DTexture()) {
    throw std::runtime_error("Unable to create Windows Direct3D device.");
    return;
  }
  if (!CreateEGLDisplay()) {
    throw std::runtime_error("Unable to create ANGLE EGL display.");
    return;
  }
  if (!CreateAndBindEGLSurface()) {
    throw std::runtime_error("Unable to create ANGLE EGL surface.");
    return;
  }
  if (internal_handle_ == nullptr || handle_ == nullptr) {
    throw std::runtime_error("Unable to retrieve Direct3D shared HANDLE.");
    return;
  }
}

void ANGLESurfaceManager::CleanUp(bool release_context) {
  if (display_ != EGL_NO_DISPLAY) {
    eglMakeCurrent(display_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  }
  if (surface_ != EGL_NO_SURFACE) {
    eglDestroySurface(display_, surface_);
    surface_ = EGL_NO_SURFACE;
    surface_memory_.Reset();
  }
  if (release_context) {
    if (display_ != EGL_NO_DISPLAY && context_ != EGL_NO_CONTEXT) {
      eglDestroyContext(display_, context_);
      context_ = EGL_NO_CONTEXT;
      context_memory_.Reset();
    }
    {
      std::lock_guard<std::mutex> lock(display_mutex_);
      const auto display = display_ref_counts_.find(display_);
      if (display != display_ref_counts_.end() && --display->second == 0) {
        eglTerminate(display_);
        display_ref_counts_.erase(display);
      }
    }
    display_ = EGL_NO_DISPLAY;
    config_ = nullptr;
  }
  // ComPtr 各持有一个引用，部分创建失败与正常释放使用同一路径。
  internal_d3d_11_texture_2D_.Reset();
  d3d_11_texture_2D_.Reset();
  texture_memory_.Reset();
  internal_handle_ = nullptr;
  handle_ = nullptr;
  if (release_context) {
    // Release D3D device & context if the instance is being destroyed.
    if (d3d_11_device_context_) {
      d3d_11_device_context_->Release();
      d3d_11_device_context_ = nullptr;
    }
    if (d3d_11_device_) {
      d3d_11_device_->Release();
      d3d_11_device_ = nullptr;
      device_memory_.Reset();
    }
  }
}

bool ANGLESurfaceManager::CreateD3DTexture() {
  if (d3d_11_device_ == nullptr) {
    // NOTE: Not enabling Feature Level 12. It crashes directly on Windows 7.
    const auto feature_levels = {
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
        D3D_FEATURE_LEVEL_9_3,
    };

    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    D3D_DRIVER_TYPE driver_type = D3D_DRIVER_TYPE_UNKNOWN;

    // NOTE: Automatically selecting adapter on Windows 10 RTM or greater.
    if (Utils::IsWindows10RTMOrGreater()) {
      driver_type = D3D_DRIVER_TYPE_HARDWARE;
    } else {
      Microsoft::WRL::ComPtr<IDXGIFactory> dxgi;
      auto hr = ::CreateDXGIFactory(__uuidof(IDXGIFactory), (void**)&dxgi);
      CHECK_HRESULT("CreateDXGIFactory");
      // As far as my experience goes, this is the safest approach. Passing NULL
      // (so-called default) seems to cause issues on Windows 7 or maybe some
      // older graphics drivers. First adapter is the default.
      // D3D_DRIVER_TYPE_UNKNOWN| must be passed with manual adapter selection.
      hr = dxgi->EnumAdapters(0, &adapter);
      CHECK_HRESULT("IDXGIFactory::EnumAdapters");
    }

    auto hr = ::D3D11CreateDevice(
        adapter.Get(), driver_type, 0, 0, feature_levels.begin(),
        static_cast<UINT>(feature_levels.size()), D3D11_SDK_VERSION,
        &d3d_11_device_, 0, &d3d_11_device_context_);
    CHECK_HRESULT("D3D11CreateDevice");
    device_memory_.Set(1);
  }

  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device = nullptr;
  auto dxgi_device_success = d3d_11_device_->QueryInterface(
      __uuidof(IDXGIDevice), (void**)&dxgi_device);
  if (SUCCEEDED(dxgi_device_success) && dxgi_device != nullptr) {
    dxgi_device->SetGPUThreadPriority(5);  // Must be in interval [-7, 7].
  }

  auto level = d3d_11_device_->GetFeatureLevel();
  std::cout << "media_kit: ANGLESurfaceManager: Direct3D Feature Level: "
            << (((unsigned)level) >> 12) << "_"
            << ((((unsigned)level) >> 8) & 0xf) << std::endl;
  auto d3d11_texture2D_desc = D3D11_TEXTURE2D_DESC{0};
  d3d11_texture2D_desc.Width = width_;
  d3d11_texture2D_desc.Height = height_;
  d3d11_texture2D_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  d3d11_texture2D_desc.MipLevels = 1;
  d3d11_texture2D_desc.ArraySize = 1;
  d3d11_texture2D_desc.SampleDesc.Count = 1;
  d3d11_texture2D_desc.SampleDesc.Quality = 0;
  d3d11_texture2D_desc.Usage = D3D11_USAGE_DEFAULT;
  d3d11_texture2D_desc.BindFlags =
      D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  d3d11_texture2D_desc.CPUAccessFlags = 0;
  d3d11_texture2D_desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  // The general idea is to create two textures, one that is used to |Draw|
  // using ANGLE & another one that is used for |Read| the rendered content
  // using |handle|.
  // The internal texture is copied to the public texture once a frame is
  // requested using |ID3D11DeviceContext::CopyResource|. This prevents any kind
  // of synchronization issues.

  // Internal.
  auto hr = d3d_11_device_->CreateTexture2D(&d3d11_texture2D_desc, nullptr,
                                            &internal_d3d_11_texture_2D_);
  CHECK_HRESULT("ID3D11Device::CreateTexture2D");
  // BGRA8 名义像素字节，不包含驱动对齐、解码器和 Flutter 导入侧分配。
  const int64_t texture_bytes = static_cast<int64_t>(width_) * height_ * 4;
  texture_memory_.Set(1, texture_bytes);
  auto resource = Microsoft::WRL::ComPtr<IDXGIResource>{};
  hr = internal_d3d_11_texture_2D_.As(&resource);
  CHECK_HRESULT("ID3D11Texture2D::As");
  // Retrieve the shared |HANDLE| for interop.
  hr = resource->GetSharedHandle(&internal_handle_);
  CHECK_HRESULT("IDXGIResource::GetSharedHandle");

  // External.
  hr = d3d_11_device_->CreateTexture2D(&d3d11_texture2D_desc, nullptr,
                                       &d3d_11_texture_2D_);
  CHECK_HRESULT("ID3D11Device::CreateTexture2D");
  texture_memory_.Set(2, texture_bytes * 2);
  hr = d3d_11_texture_2D_.As(&resource);
  CHECK_HRESULT("ID3D11Texture2D::As");
  // Retrieve the shared |HANDLE| for interop.
  hr = resource->GetSharedHandle(&handle_);
  CHECK_HRESULT("IDXGIResource::GetSharedHandle");

  return true;
}

bool ANGLESurfaceManager::CreateEGLDisplay() {
  if (display_ == EGL_NO_DISPLAY) {
    std::lock_guard<std::mutex> lock(display_mutex_);
    auto eglGetPlatformDisplayEXT =
        reinterpret_cast<PFNEGLGETPLATFORMDISPLAYEXTPROC>(
            eglGetProcAddress("eglGetPlatformDisplayEXT"));
    if (eglGetPlatformDisplayEXT) {
      const EGLint* configurations[] = {
          kD3D11DisplayAttributes, kD3D11_9_3DisplayAttributes,
          kD3D9DisplayAttributes, kWrapDisplayAttributes};
      for (const auto* attributes : configurations) {
        const auto display = eglGetPlatformDisplayEXT(
            EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, attributes);
        if (display != EGL_NO_DISPLAY &&
            eglInitialize(display, 0, 0) != EGL_FALSE) {
          display_ = display;
          ++display_ref_counts_[display_];
          return true;
        }
      }
      FAIL("eglGetPlatformDisplayEXT");
    } else {
      FAIL("eglGetProcAddress");
    }
  }
  return true;
}

bool ANGLESurfaceManager::CreateAndBindEGLSurface() {
  // Do not create |context_| again, likely due to |Resize|.
  if (context_ == EGL_NO_CONTEXT) {
    // First time from the constructor itself.
    auto count = 0;
    auto result = eglChooseConfig(display_, kEGLConfigurationAttributes,
                                  &config_, 1, &count);
    if (result == EGL_FALSE || count == 0) {
      FAIL("eglChooseConfig");
    }
    context_ = eglCreateContext(display_, config_, EGL_NO_CONTEXT,
                                kEGLContextAttributes);
    if (context_ == EGL_NO_CONTEXT) {
      FAIL("eglCreateContext");
    }
    context_memory_.Set(1);
  }
  EGLint buffer_attributes[] = {
      EGL_WIDTH,          width_,         EGL_HEIGHT,         height_,
      EGL_TEXTURE_TARGET, EGL_TEXTURE_2D, EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
      EGL_NONE,
  };
  surface_ = eglCreatePbufferFromClientBuffer(
      display_, EGL_D3D_TEXTURE_2D_SHARE_HANDLE_ANGLE, internal_handle_,
      config_, buffer_attributes);
  if (surface_ == EGL_NO_SURFACE) {
    FAIL("eglCreatePbufferFromClientBuffer");
  }
  surface_memory_.Set(1);
  // Surface 的 D3D 纹理由默认 framebuffer 绘制，再通过 Read 复制给 Flutter。
  // 创建或扩容时不额外绑定 GL 纹理，避免改变 mpv 渲染上下文的纹理状态。
  return true;
}
