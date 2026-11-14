// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#ifndef VIDEO_OUTPUT_H_
#define VIDEO_OUTPUT_H_

#include <client.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <render.h>
#include <render_gl.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <functional>
#include <future>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "angle_surface_manager.h"
#include "output_operation_token.h"
#include "thread_pool.h"
#include "video_frame_sampling.h"

typedef struct _VideoOutputConfiguration {
  std::optional<int64_t> width;
  std::optional<int64_t> height;
  bool enable_hardware_acceleration;

  _VideoOutputConfiguration(std::optional<int64_t> width = std::nullopt,
                            std::optional<int64_t> height = std::nullopt,
                            bool enable_hardware_acceleration = true)
      : width(width),
        height(height),
        enable_hardware_acceleration(enable_hardware_acceleration) {}
} VideoOutputConfiguration;

class VideoOutput {
 public:
  int64_t texture_id() const { return texture_id_; }
  int64_t width() const {
    // H/W
    if (surface_manager_ != nullptr && texture_id_) {
      return surface_manager_->width();
    }
    // S/W
    if (pixel_buffer_ != nullptr && texture_id_) {
      return pixel_buffer_textures_.at(texture_id_)->width;
    }
    return width_.value_or(1);
  }
  int64_t height() const {
    // H/W
    if (surface_manager_ != nullptr && texture_id_) {
      return surface_manager_->height();
    }
    // S/W
    if (pixel_buffer_ != nullptr && texture_id_) {
      return pixel_buffer_textures_.at(texture_id_)->height;
    }
    return height_.value_or(1);
  }

  VideoOutput(int64_t handle,
              VideoOutputConfiguration configuration,
              flutter::PluginRegistrarWindows* registrar,
              ThreadPool* thread_pool_ref,
              std::function<void(const OutputOperationToken&, int64_t, int64_t,
                                 int64_t)>
                  output_attached_callback,
              std::function<void(const OutputOperationToken&, int64_t)>
                  frame_consumed_callback,
              VideoFrameSamplingCallback frame_sampling_callback);

  ~VideoOutput();

  void SetTextureUpdateCallback(
      std::function<void(int64_t, int64_t, int64_t)> callback);

  void SetSize(std::optional<int64_t> width, std::optional<int64_t> height,
               std::function<void(bool)> on_frame_ready);

  void SetSourceSize(int64_t width,
                     int64_t height,
                     std::optional<OutputOperationToken> token);

  void ResetRenderer(std::function<void(bool)> on_ready);

  void SetFrameSampling(OutputOperationToken token, bool enabled,
                        std::function<void(std::optional<VideoFrameSamplingEvent>)>
        on_complete);

  void BeginOutputForLoad(OutputOperationToken token,
                          std::function<void(bool)> on_complete);

  void PrepareForLoad(OutputOperationToken token,
                      std::string track_id,
                      int64_t width,
                      int64_t height,
                      std::function<void(bool, int64_t, int64_t)> on_complete);

  void InvalidateOutputGeneration(OutputOperationToken token,
                                  std::function<void(bool)> on_complete);

 private:
  // 最先构造、最后析构，覆盖原生输出和全部纹理注销回执的实际存续期。
  media_kit_memory::OutputLifetime memory_lifetime_;
  media_kit_memory::ResourceRecord render_memory_{media_kit_memory::Resource::render_context, memory_lifetime_.id()};
  media_kit_memory::ResourceRecord software_memory_{media_kit_memory::Resource::software_buffer, memory_lifetime_.id()};
  void TransitionSampling(const std::string& admission);
  VideoFrameSamplingCallback frame_sampling_callback_;
  int64_t sampling_generation_ = 0, sampling_sequence_ = 0;
  int64_t sampling_valid_after_us_ = 0;
  bool sampling_enabled_ = false;
  std::string sampling_admission_ = "blocked";
  struct TextureFrameIdentity {
    OutputOperationToken token;
    int64_t generation, rendered_at_us;
  };
  std::unordered_map<int64_t, TextureFrameIdentity> texture_sampling_frames_;

  bool CreateRenderContext(int64_t width, int64_t height);

  void ReleaseRenderContext();

  void SetRenderUpdateCallback();

  void NotifyRender();

  void NotifyTextureUpdate(int64_t id, int64_t width, int64_t height);

  void NotifyFrameConsumed(int64_t texture_id);

  bool Render();

  void CheckAndResize();

  void Resize(int64_t required_width,
              int64_t required_height,
              std::function<void(bool)> on_complete = {});

  bool ApplyResize(int64_t required_width, int64_t required_height);

  void FinishResize(int64_t required_width,
                    int64_t required_height,
                    bool success);

  void UnregisterTexture(int64_t id,
                         std::function<void()> on_unregistered = {});

  bool IsCurrentToken(const OutputOperationToken& token) const;

  void ResetRendererAfterTextureRelease(std::function<void(bool)> on_ready);

  void StartRendererReset(std::function<void(bool)> on_ready);

  void FinishRendererReset(std::function<void(bool)> on_ready, bool success);

  void ProcessPendingTextureOperations();

  int64_t GetVideoWidth();

  int64_t GetVideoHeight();

  std::optional<int64_t> height_ = std::nullopt;
  std::optional<int64_t> width_ = std::nullopt;
  int64_t source_width_ = 0;
  int64_t source_height_ = 0;
  VideoOutputConfiguration configuration_ = VideoOutputConfiguration{};

  mpv_handle* handle_ = nullptr;
  mpv_render_context* render_context_ = nullptr;
  int64_t texture_id_ = 0;
  std::atomic<bool> texture_update_pending_ = false;
  bool renderer_reset_pending_ = false;
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  ThreadPool* thread_pool_ref_ = nullptr;
  // For preventing any asynchronous operations (primarily texture objects
  // deletion after unregister in |Resize|) access this object after
  // destruction.
  std::atomic<bool> destroyed_ = false;

  std::mutex render_callback_mutex_ = std::mutex();
  std::atomic<bool> render_pending_ = false;
  std::atomic<bool> render_dirty_ = false;

  std::mutex textures_mutex_ = std::mutex();
  std::mutex callback_mutex_ = std::mutex();
  std::mutex texture_unregistrations_mutex_ = std::mutex();
  std::condition_variable texture_unregistrations_cv_;
  size_t pending_texture_unregistrations_ = 0;

  std::unordered_map<int64_t, std::unique_ptr<flutter::TextureVariant>>
      texture_variants_ = {};
  std::unordered_map<int64_t, OutputOperationToken> texture_frame_tokens_ = {};

  // H/W rendering.

  std::unique_ptr<ANGLESurfaceManager> surface_manager_ = nullptr;
  std::unordered_map<int64_t,
                     std::unique_ptr<FlutterDesktopGpuSurfaceDescriptor>>
      textures_ = {};

  // S/W rendering.

  std::unique_ptr<uint8_t[]> pixel_buffer_ = nullptr;
  std::unordered_map<int64_t, std::unique_ptr<FlutterDesktopPixelBuffer>>
      pixel_buffer_textures_ = {};

  // Public notifier. This is called when a new texture is registered & texture
  // ID is changed. Only happens when video output resolution changes.
  std::function<void(int64_t, int64_t, int64_t)> texture_update_callback_ =
      [](int64_t, int64_t, int64_t) {};

  std::function<void(const OutputOperationToken&, int64_t, int64_t, int64_t)>
      output_attached_callback_ = [](const OutputOperationToken&, int64_t,
                                     int64_t, int64_t) {};
  std::function<void(const OutputOperationToken&, int64_t)>
      frame_consumed_callback_ = [](const OutputOperationToken&, int64_t) {};

  std::optional<OutputOperationToken> high_water_token_ = std::nullopt;
  std::optional<OutputOperationToken> active_token_ = std::nullopt;
  bool active_token_invalidated_ = false;
  bool output_prepared_ = false;
  std::string active_track_id_;
  std::optional<OutputOperationToken> frame_seen_token_ = std::nullopt;
  std::optional<OutputOperationToken> rendered_frame_token_ = std::nullopt;
  std::optional<OutputOperationToken> attached_token_notified_ = std::nullopt;

  bool resize_in_progress_ = false;
  bool renderer_reset_in_progress_ = false;
  std::deque<std::function<void(bool)>> queued_renderer_resets_;
  std::optional<std::pair<int64_t, int64_t>> queued_resize_ = std::nullopt;
  std::vector<std::function<void(bool)>> resize_completions_;
  std::vector<std::function<void(bool)>> queued_resize_completions_;
  int64_t renderer_reset_width_ = 1;
  int64_t renderer_reset_height_ = 1;
};

#endif  // VIDEO_OUTPUT_H_
