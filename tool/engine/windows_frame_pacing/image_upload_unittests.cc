// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <cstdlib>
#include <cstring>
#include <iostream>

#include "flutter/shell/platform/windows/egl/manager.h"
#include "libANGLE/renderer/d3d/d3d11/Renderer11.h"
#include "libANGLE/renderer/d3d/d3d11/renderer11_utils.h"
#include "gtest/gtest.h"

namespace flutter::testing {
namespace {
void InitializeUploadFeatures(UINT vendor, UINT device, angle::FeaturesD3D* features) {
  rx::Renderer11DeviceCaps caps;
  caps.featureLevel = D3D_FEATURE_LEVEL_11_0;
  caps.supportsVpRtIndexWriteFromVertexShader = false;
  DXGI_ADAPTER_DESC adapter = {};
  adapter.VendorId = vendor;
  adapter.DeviceId = device;
  rx::d3d11::InitializeFeatures(caps, adapter, features);
}
}  // namespace

TEST(WindowsImageUploadTest, AMDUsesStagingByDefault) {
  angle::FeaturesD3D features;
  InitializeUploadFeatures(0x1002, 0x73bf, &features);
  EXPECT_FALSE(features.setDataFasterThanImageUpload.enabled);
}

TEST(WindowsImageUploadTest, PreservesOtherAdapterDefaults) {
  for (UINT vendor : {0x10deu, 0x8086u, 0x1414u}) {
    angle::FeaturesD3D features;
    InitializeUploadFeatures(vendor, 0, &features);
    EXPECT_TRUE(features.setDataFasterThanImageUpload.enabled) << vendor;
  }
  // Intel Haswell 原本关闭的上传路径继续关闭。
  angle::FeaturesD3D haswell;
  InitializeUploadFeatures(0x8086, 0x0412, &haswell);
  EXPECT_FALSE(haswell.setDataFasterThanImageUpload.enabled);
}

TEST(WindowsImageUploadTest, ExplicitOverridesCanRestoreFastUpload) {
  angle::FeaturesD3D features;
  InitializeUploadFeatures(0x1002, 0x73bf, &features);
  // 与 ANGLE 环境覆盖共用真实匹配逻辑，兼容两种命名。
  features.overrideFeatures({"setDataFasterThanImageUpload"}, true);
  EXPECT_TRUE(features.setDataFasterThanImageUpload.enabled);
  features.overrideFeatures({"set_data_faster_than_image_upload"}, false);
  EXPECT_FALSE(features.setDataFasterThanImageUpload.enabled);
}

// 设备验收在独立进程中指定期望值，防止 ANGLE 已缓存的环境覆盖污染对照。
TEST(WindowsImageUploadHardwareTest, EffectiveFeatureMatchesRequestedMode) {
  const char* expected = std::getenv("PILIAURORA_EXPECT_FAST_UPLOAD");
  if (!expected) {
    GTEST_SKIP() << "Requires an explicit device expectation in a fresh process";
  }
  ASSERT_TRUE(std::strcmp(expected, "enabled") == 0 ||
              std::strcmp(expected, "disabled") == 0);
  auto manager = egl::Manager::Create(egl::GpuPreference::NoPreference);
  ASSERT_NE(manager, nullptr);
  Microsoft::WRL::ComPtr<ID3D11Device> device;
  ASSERT_TRUE(manager->GetDevice(&device));
  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  ASSERT_TRUE(SUCCEEDED(device.As(&dxgi_device)));
  Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
  ASSERT_TRUE(SUCCEEDED(dxgi_device->GetAdapter(&adapter)));
  DXGI_ADAPTER_DESC desc = {};
  ASSERT_TRUE(SUCCEEDED(adapter->GetDesc(&desc)));
  auto query_count = reinterpret_cast<PFNEGLQUERYDISPLAYATTRIBANGLEPROC>(
      eglGetProcAddress("eglQueryDisplayAttribANGLE"));
  auto query_feature = reinterpret_cast<PFNEGLQUERYSTRINGIANGLEPROC>(
      eglGetProcAddress("eglQueryStringiANGLE"));
  ASSERT_NE(query_count, nullptr);
  ASSERT_NE(query_feature, nullptr);
  EGLAttrib count = 0;
  ASSERT_TRUE(query_count(manager->egl_display(), EGL_FEATURE_COUNT_ANGLE, &count));
  bool found = false;
  for (EGLint i = 0; i < count; ++i) {
    const char* name = query_feature(manager->egl_display(), EGL_FEATURE_NAME_ANGLE, i);
    if (name && (std::strcmp(name, "setDataFasterThanImageUpload") == 0 ||
                 std::strcmp(name, "set_data_faster_than_image_upload") == 0)) {
      const char* status = query_feature(manager->egl_display(), EGL_FEATURE_STATUS_ANGLE, i);
      ASSERT_NE(status, nullptr);
      EXPECT_STREQ(status, expected);
      std::cout << "Actual D3D11 vendor=" << desc.VendorId
                << " device=" << desc.DeviceId << " upload=" << status << std::endl;
      found = true;
    }
  }
  EXPECT_TRUE(found);
}
}  // namespace flutter::testing
