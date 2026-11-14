// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/platform/windows/external_texture_d3d.h"
#include "gtest/gtest.h"

namespace flutter::testing {
namespace {

// 使用真实 D3D 共享纹理和 EGL 导入，覆盖跨空描述符后的同句柄恢复。
class ExternalTextureD3dTest : public ::testing::Test {
 protected:
  void SetUp() override {
    manager_ = egl::Manager::Create(egl::GpuPreference::NoPreference);
    ASSERT_NE(manager_, nullptr);
    ASSERT_TRUE(manager_->render_context()->MakeCurrent());
    Microsoft::WRL::ComPtr<ID3D11Device> device;
    ASSERT_TRUE(manager_->GetDevice(&device));
    D3D11_TEXTURE2D_DESC description = {};
    description.Width = kWidth;
    description.Height = kHeight;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags =
        D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    description.MiscFlags = D3D11_RESOURCE_MISC_SHARED;
    ASSERT_TRUE(
        SUCCEEDED(device->CreateTexture2D(&description, nullptr, &shared_)));
    Microsoft::WRL::ComPtr<IDXGIResource> resource;
    ASSERT_TRUE(SUCCEEDED(shared_.As(&resource)));
    HANDLE handle = nullptr;
    ASSERT_TRUE(SUCCEEDED(resource->GetSharedHandle(&handle)));
    descriptor_.struct_size = sizeof(descriptor_);
    descriptor_.handle = handle;
    descriptor_.width = descriptor_.visible_width = kWidth;
    descriptor_.height = descriptor_.visible_height = kHeight;
    descriptor_.release_context = this;
    descriptor_.release_callback = [](void* context) {
      auto* fixture = static_cast<ExternalTextureD3dTest*>(context);
      fixture->release_count_++;
      if (fixture->invalidate_on_release_) {
        fixture->descriptor_.visible_width = 0;
        fixture->descriptor_.visible_height = 0;
      }
    };
    available_ = &descriptor_;
    texture_ = std::make_unique<ExternalTextureD3d>(
        kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle,
        [](size_t, size_t, void* context) {
          return static_cast<ExternalTextureD3dTest*>(context)->available_;
        },
        this, manager_.get(), egl::ProcTable::Create());
  }

  void TearDown() override {
    texture_.reset();
    if (manager_) manager_->render_context()->ClearCurrent();
    shared_.Reset();
    manager_.reset();
  }

  bool Populate() {
    return texture_->PopulateTexture(kWidth, kHeight, &output_);
  }

  static constexpr size_t kWidth = 32;
  static constexpr size_t kHeight = 16;
  std::unique_ptr<egl::Manager> manager_;
  Microsoft::WRL::ComPtr<ID3D11Texture2D> shared_;
  std::unique_ptr<ExternalTextureD3d> texture_;
  FlutterDesktopGpuSurfaceDescriptor descriptor_ = {};
  const FlutterDesktopGpuSurfaceDescriptor* available_ = nullptr;
  FlutterOpenGLTexture output_ = {};
  int release_count_ = 0;
  bool invalidate_on_release_ = false;
};

TEST_F(ExternalTextureD3dTest, ReimportsSameHandleAfterNullDescriptor) {
  ASSERT_TRUE(Populate());
  const auto name = output_.name;
  for (int index = 0; index < 3; index++) {
    available_ = nullptr;
    EXPECT_FALSE(Populate());
    available_ = &descriptor_;
    ASSERT_TRUE(Populate());
    EXPECT_EQ(output_.name, name);
  }
  EXPECT_EQ(release_count_, 4);
}

TEST_F(ExternalTextureD3dTest, ReimportsSameHandleAfterNullHandle) {
  ASSERT_TRUE(Populate());
  auto handle = descriptor_.handle;
  descriptor_.handle = nullptr;
  EXPECT_FALSE(Populate());
  descriptor_.handle = handle;
  EXPECT_TRUE(Populate());
  EXPECT_EQ(release_count_, 3);
}

TEST_F(ExternalTextureD3dTest, RetriesSameHandleAfterSurfaceCreationFailure) {
  descriptor_.width = 0;
  EXPECT_FALSE(Populate());
  EXPECT_EQ(release_count_, 1);
  descriptor_.width = kWidth;
  EXPECT_TRUE(Populate());
  EXPECT_EQ(release_count_, 2);
}

TEST_F(ExternalTextureD3dTest, CopiesDescriptorFieldsBeforeRelease) {
  invalidate_on_release_ = true;
  ASSERT_TRUE(Populate());
  EXPECT_EQ(output_.width, kWidth);
  EXPECT_EQ(output_.height, kHeight);
  EXPECT_EQ(release_count_, 1);
}

TEST_F(ExternalTextureD3dTest, ReleasesInvalidDescriptorExactlyOnce) {
  descriptor_.handle = nullptr;
  EXPECT_FALSE(Populate());
  EXPECT_EQ(release_count_, 1);
  available_ = nullptr;
  EXPECT_FALSE(Populate());
  EXPECT_EQ(release_count_, 1);
}

TEST_F(ExternalTextureD3dTest, ReusesLiveTextureWithoutReleasingItsGLName) {
  ASSERT_TRUE(Populate());
  const auto name = output_.name;
  for (int index = 0; index < 10; index++) {
    ASSERT_TRUE(Populate());
    EXPECT_EQ(output_.name, name);
    EXPECT_EQ(output_.width, kWidth);
    EXPECT_EQ(output_.height, kHeight);
  }
  EXPECT_EQ(release_count_, 11);
}

}  // namespace
}  // namespace flutter::testing
