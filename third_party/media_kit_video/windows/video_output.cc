// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.

#include "video_output.h"

#include <algorithm>
#include <chrono>
#include <cmath>

// Limit the frame size to 1080p in software rendering.
// This is for performance reasons & to avoid allocating too much memory.
#define SW_RENDERING_MAX_WIDTH 1920
#define SW_RENDERING_MAX_HEIGHT 1080
#define SW_RENDERING_PIXEL_BUFFER_SIZE \
  (SW_RENDERING_MAX_WIDTH) * (SW_RENDERING_MAX_HEIGHT) * (4)

VideoOutput::VideoOutput(int64_t handle,
                         VideoOutputConfiguration configuration,
                         flutter::PluginRegistrarWindows* registrar,
                         ThreadPool* thread_pool_ref,
                         std::function<void(const OutputOperationToken&, int64_t,
                                            int64_t, int64_t)>
                             output_attached_callback,
                         std::function<void(const OutputOperationToken&, int64_t)>
                             frame_consumed_callback,
                         VideoFrameSamplingCallback frame_sampling_callback)
    : handle_(reinterpret_cast<mpv_handle*>(handle)),
      width_(configuration.width),
      height_(configuration.height),
      configuration_(configuration),
      registrar_(registrar),
      thread_pool_ref_(thread_pool_ref),
      output_attached_callback_(std::move(output_attached_callback)),
      frame_consumed_callback_(std::move(frame_consumed_callback)),
      frame_sampling_callback_(std::move(frame_sampling_callback)) {
  // The constructor must be invoked through the thread pool, because
  // |ANGLESurfaceManager| & libmpv render context creation can conflict with
  // the existing |Render| or |Resize| calls from another |VideoOutput|
  // instances (which will result in access violation).
  auto future = thread_pool_ref_->Post([&]() {
    mpv_set_option_string(handle_, "video-sync", "audio");
    mpv_set_option_string(handle_, "video-timing-offset", "0");
    CreateRenderContext(width_.value_or(1), height_.value_or(1));
    Resize(width_.value_or(1), height_.value_or(1));
    SetRenderUpdateCallback();
  });
  future.get();
}

bool VideoOutput::CreateRenderContext(int64_t width, int64_t height) {
  // First try to initialize video playback with hardware acceleration &
  // |ANGLESurfaceManager|, use S/W API as fallback.
  auto is_hardware_acceleration_enabled = false;
  // Attempt to use H/W rendering.
  if (configuration_.enable_hardware_acceleration) {
    try {
      // OpenGL context needs to be set before |mpv_render_context_create|.
      surface_manager_ = std::make_unique<ANGLESurfaceManager>(
          static_cast<int32_t>(width),
          static_cast<int32_t>(height));
      surface_manager_->MakeCurrent(true);
      mpv_opengl_init_params gl_init_params{
          [](auto, auto name) {
            return reinterpret_cast<void*>(eglGetProcAddress(name));
          },
          nullptr,
      };
      mpv_render_param params[] = {
          {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
          {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init_params},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      // Create render context.
      if (mpv_render_context_create(&render_context_, handle_, params) == 0) {
        // Set flag to true, indicating that H/W rendering is supported.
        is_hardware_acceleration_enabled = true;
        std::cout << "media_kit: VideoOutput: Using H/W rendering."
                  << std::endl;
      }
    } catch (...) {
      // Do nothing.
      // Likely received an |std::runtime_error| from |ANGLESurfaceManager|,
      // which indicates that H/W rendering is not supported.
    }
  }
  if (!is_hardware_acceleration_enabled) {
    // 后端确定前不注册纹理；回退时释放 GL 资源，保持软硬输出互斥。
    if (render_context_ != nullptr) {
      mpv_render_context_free(render_context_);
      render_context_ = nullptr;
    }
    surface_manager_.reset();
    std::cout << "media_kit: VideoOutput: Using S/W rendering." << std::endl;
    // Allocate a "large enough" buffer ahead of time.
    pixel_buffer_ =
        std::make_unique<uint8_t[]>(SW_RENDERING_PIXEL_BUFFER_SIZE);
    // 初始固定尺寸也必须遵守软件缓冲区容量。
    if (width_) {
      width_ = std::clamp(*width_, int64_t{1},
                          int64_t{SW_RENDERING_MAX_WIDTH});
    }
    if (height_) {
      height_ = std::clamp(*height_, int64_t{1},
                           int64_t{SW_RENDERING_MAX_HEIGHT});
    }
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    mpv_render_context_create(&render_context_, handle_, params);
  }
  return render_context_ != nullptr;
}

void VideoOutput::SetRenderUpdateCallback() {
  if (render_context_ != nullptr) {
    mpv_render_context_set_update_callback(
        render_context_,
        [](void* context) {
          auto that = reinterpret_cast<VideoOutput*>(context);
          that->NotifyRender();
        },
        reinterpret_cast<void*>(this));
  }
}

void VideoOutput::ReleaseRenderContext() {
  if (surface_manager_) surface_manager_->MakeCurrent(true);
  if (render_context_) {
    mpv_render_context_set_update_callback(render_context_, nullptr, nullptr);
    mpv_render_context_free(render_context_);
    render_context_ = nullptr;
  }
  if (surface_manager_) surface_manager_->MakeCurrent(false);
  surface_manager_.reset();
  pixel_buffer_.reset();
}

void VideoOutput::ResetRenderer(std::function<void(bool)> on_ready) {
  thread_pool_ref_->Post([this, on_ready]() {
    queued_renderer_resets_.push_back(on_ready);
    ProcessPendingTextureOperations();
  });
}

void VideoOutput::StartRendererReset(std::function<void(bool)> on_ready) {
  renderer_reset_in_progress_ = true;
  if (destroyed_.load(std::memory_order_acquire)) {
    FinishRendererReset(on_ready, false);
    return;
  }
  // 软件输出没有 D3D11 纹理分配池。
  if (!surface_manager_) {
    FinishRendererReset(on_ready, true);
    return;
  }
  texture_update_pending_ = true;
  TransitionSampling("blocked");
  renderer_reset_pending_ = true;
  if (render_context_ != nullptr) {
    mpv_render_context_set_update_callback(render_context_, nullptr, nullptr);
  }
  renderer_reset_width_ = width();
  renderer_reset_height_ = height();
  frame_seen_token_.reset();
  rendered_frame_token_.reset();
  attached_token_notified_.reset();
  const auto old_texture_id = texture_id_;
  texture_id_ = 0;
  if (old_texture_id) {
    UnregisterTexture(old_texture_id, [this, on_ready]() {
      ResetRendererAfterTextureRelease(on_ready);
    });
  } else {
    ResetRendererAfterTextureRelease(on_ready);
  }
}

void VideoOutput::ResetRendererAfterTextureRelease(
    std::function<void(bool)> on_ready) {
  if (destroyed_.load(std::memory_order_acquire)) {
    FinishRendererReset(on_ready, false);
    return;
  }
  auto output_width = renderer_reset_width_;
  auto output_height = renderer_reset_height_;
  bool ready = false;
  try {
    // Texture unregistration completed on Flutter's raster worker before GL
    // and D3D resources are released or resized.
    ReleaseRenderContext();
    ready = CreateRenderContext(output_width, output_height);
    if (ready) {
      if (pixel_buffer_) {
        output_width = (std::min)(output_width, int64_t{SW_RENDERING_MAX_WIDTH});
        output_height = (std::min)(output_height, int64_t{SW_RENDERING_MAX_HEIGHT});
      }
      // 重建持有同一个纹理操作槽；旧纹理已注销，直接配置新后端。
      ready = ApplyResize(output_width, output_height);
      if (ready) {
        SetRenderUpdateCallback();
        Render();
      }
    }
  } catch (...) {
    ready = false;
  }
  FinishRendererReset(on_ready,
                      ready && !destroyed_.load(std::memory_order_acquire));
}

void VideoOutput::FinishRendererReset(std::function<void(bool)> on_ready,
                                      bool success) {
  renderer_reset_in_progress_ = false;
  on_ready(success);
  ProcessPendingTextureOperations();
}

void VideoOutput::ProcessPendingTextureOperations() {
  // texture_id_ 在注销等待期间为 0；操作槽持续持有到 Flutter 回执处理完成。
  if (resize_in_progress_ || renderer_reset_in_progress_) return;
  if (!queued_renderer_resets_.empty()) {
    auto on_ready = std::move(queued_renderer_resets_.front());
    queued_renderer_resets_.pop_front();
    StartRendererReset(std::move(on_ready));
  } else if (queued_resize_.has_value()) {
    const auto next = *queued_resize_;
    queued_resize_.reset();
    resize_completions_ = std::move(queued_resize_completions_);
    queued_resize_completions_.clear();
    Resize(next.first, next.second);
  }
}

VideoOutput::~VideoOutput() {
  {
    std::lock_guard<std::mutex> lock(render_callback_mutex_);
    destroyed_.store(true, std::memory_order_release);
  }
  // The manager calls destruction from its control worker, never from the
  // render worker. This queue barrier follows all render/resize tasks and stops
  // future update callbacks before texture release begins.
  auto quiesce = thread_pool_ref_->Post([this]() {
    if (render_context_ != nullptr) {
      mpv_render_context_set_update_callback(render_context_, nullptr, nullptr);
    }
    if (texture_id_) {
      UnregisterTexture(texture_id_);
      texture_id_ = 0;
    }
  });
  quiesce.get();

  // Resize may already have unregister callbacks in flight. Keep this object
  // and its backing buffers alive until each Flutter receipt arrives.
  {
    std::unique_lock<std::mutex> lock(texture_unregistrations_mutex_);
    texture_unregistrations_cv_.wait(
        lock, [this]() { return pending_texture_unregistrations_ == 0; });
  }

  auto release = thread_pool_ref_->Post([this]() {
    ReleaseRenderContext();
    std::lock_guard<std::mutex> lock(textures_mutex_);
    texture_variants_.clear();
    textures_.clear();
    pixel_buffer_textures_.clear();
  });
  release.get();
}

void VideoOutput::NotifyRender() {
  std::lock_guard<std::mutex> callback_lock(render_callback_mutex_);
  if (destroyed_.load(std::memory_order_acquire)) return;
  render_dirty_.store(true, std::memory_order_release);
  bool expected = false;
  if (!render_pending_.compare_exchange_strong(expected, true,
                                               std::memory_order_acq_rel)) {
    return;
  }
  try {
    thread_pool_ref_->Post([this]() {
      // 后续更新排回队尾，让卸载回执和尺寸变更在持续渲染期间也能执行。
      render_dirty_.store(false, std::memory_order_release);
      if (!destroyed_.load(std::memory_order_acquire)) {
        CheckAndResize();
        Render();
      }
      render_pending_.store(false, std::memory_order_release);
      if (!destroyed_.load(std::memory_order_acquire) &&
          render_dirty_.load(std::memory_order_acquire)) {
        NotifyRender();
      }
    });
  } catch (...) {
    render_pending_.store(false, std::memory_order_release);
  }
}

bool VideoOutput::Render() {
  if (texture_id_ && render_context_ != nullptr) {
    const bool frame_updated =
        (mpv_render_context_update(render_context_) &
         MPV_RENDER_UPDATE_FRAME) != 0;
    if (frame_updated && active_token_.has_value() &&
        !active_token_invalidated_) {
      frame_seen_token_ = *active_token_;
    }
    // 重建后的配置回调可能早于新视频帧；保留旧画面直到 mpv 提供真正的帧。
    if (renderer_reset_pending_ && !frame_updated) {
      return false;
    }
    int render_status = -1;
    // H/W
    if (surface_manager_ != nullptr) {
      surface_manager_->Draw([&]() {
        mpv_opengl_fbo fbo{
            0,
            surface_manager_->width(),
            surface_manager_->height(),
            0,
        };
        mpv_render_param params[]{
            {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        render_status = mpv_render_context_render(render_context_, params);
      });
    }
    // S/W
    if (pixel_buffer_ != nullptr) {
      int32_t size[]{
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->width),
          static_cast<int32_t>(pixel_buffer_textures_.at(texture_id_)->height),
      };
      auto pitch = 4 * size[0];
      mpv_render_param params[]{
          {MPV_RENDER_PARAM_SW_SIZE, size},
          {MPV_RENDER_PARAM_SW_FORMAT, "rgb0"},
          {MPV_RENDER_PARAM_SW_STRIDE, &pitch},
          {MPV_RENDER_PARAM_SW_POINTER, pixel_buffer_.get()},
          {MPV_RENDER_PARAM_INVALID, nullptr},
      };
      render_status = mpv_render_context_render(render_context_, params);
    }
    if (render_status < 0) return false;
    const bool current_file_frame =
        output_prepared_ && active_token_.has_value() &&
        !active_token_invalidated_ && frame_seen_token_.has_value() &&
        *frame_seen_token_ == *active_token_;
    if (current_file_frame) rendered_frame_token_ = *active_token_;
    if (current_file_frame && frame_updated && sampling_enabled_ &&
        sampling_admission_ == "blocked" && !resize_in_progress_)
      TransitionSampling("priming");
    {
      std::lock_guard<std::mutex> lock(textures_mutex_);
      if (current_file_frame) {
        texture_frame_tokens_[texture_id_] = *active_token_;
        if (frame_updated)
          texture_sampling_frames_.insert_or_assign(
              texture_id_,
              TextureFrameIdentity{
                  *active_token_, sampling_generation_,
                  std::chrono::duration_cast<std::chrono::microseconds>(
                      std::chrono::steady_clock::now().time_since_epoch())
                      .count()});
      } else {
        texture_frame_tokens_.erase(texture_id_);
        texture_sampling_frames_.erase(texture_id_);
      }
    }
    try {
      // Notify Flutter that a new frame is available.
      if (!registrar_->texture_registrar()->MarkTextureFrameAvailable(texture_id_)) {
        std::lock_guard<std::mutex> lock(textures_mutex_);
        texture_frame_tokens_.erase(texture_id_);
        texture_sampling_frames_.erase(texture_id_);
        return false;
      }
    } catch (...) {
      // Keep the protective frame if rendering/registration failed.
      std::lock_guard<std::mutex> lock(textures_mutex_);
      texture_frame_tokens_.erase(texture_id_);
      texture_sampling_frames_.erase(texture_id_);
      return false;
    }
    if (frame_updated) renderer_reset_pending_ = false;
    if (texture_update_pending_ && source_width_ > 0 && source_height_ > 0 &&
        GetVideoWidth() > 0 && GetVideoHeight() > 0) {
      texture_update_pending_ = false;
      NotifyTextureUpdate(texture_id_, width(), height());
    }
    if (current_file_frame && !texture_update_pending_ &&
        attached_token_notified_ != active_token_) {
      attached_token_notified_ = active_token_;
      output_attached_callback_(*active_token_, texture_id_, width(), height());
    }
    return true;
  }
  return false;
}

void VideoOutput::SetTextureUpdateCallback(
    std::function<void(int64_t, int64_t, int64_t)> callback) {
  {
    std::lock_guard<std::mutex> lock(callback_mutex_);
    texture_update_callback_ = callback;
  }
  // Do not queue this behind a render: rendering may wait for playback while
  // playback itself waits for this initial texture to create its controller.
  // 初始 ID 用于解除控制器创建等待；固定尺寸的空闲纹理尚无视频首帧。
  NotifyTextureUpdate(texture_id_, texture_update_pending_ ? 0 : width(),
                      texture_update_pending_ ? 0 : height());
}

bool VideoOutput::IsCurrentToken(const OutputOperationToken& token) const {
  return active_token_.has_value() && *active_token_ == token &&
         !active_token_invalidated_;
}

void VideoOutput::TransitionSampling(const std::string& admission) {
  sampling_generation_++;
  sampling_admission_ = admission;
  sampling_valid_after_us_ =
      std::chrono::duration_cast<std::chrono::microseconds>(
          std::chrono::steady_clock::now().time_since_epoch())
          .count();
  if (active_token_.has_value())
    frame_sampling_callback_({*active_token_, sampling_generation_, admission,
                              sampling_valid_after_us_, 0});
}

void VideoOutput::SetFrameSampling(OutputOperationToken token, bool enabled,
                                   std::function<void(std::optional<VideoFrameSamplingEvent>)>
        on_complete) {
  thread_pool_ref_->Post([this, token, enabled, on_complete]() {
    if (!IsCurrentToken(token)) {
      on_complete(std::nullopt);
      return;
    }
    sampling_enabled_ = enabled;
    TransitionSampling(enabled && output_prepared_ && !resize_in_progress_ &&
                               !renderer_reset_pending_
                           ? "priming"
                           : "blocked");
    on_complete(VideoFrameSamplingEvent{token, sampling_generation_,
                                       sampling_admission_, sampling_valid_after_us_, 0});
  });
}

void VideoOutput::BeginOutputForLoad(OutputOperationToken token,
    std::function<void(bool)> on_complete) {
  thread_pool_ref_->Post([this, token, on_complete]() {
    bool accepted = token.runtime_id > 0 && token.load_id > 0 &&
                    token.output_epoch > 0 && token.config_revision >= 0;
    if (accepted && high_water_token_.has_value()) {
      if (token == *high_water_token_) {
        accepted = !active_token_invalidated_ &&
                   active_token_.has_value() && *active_token_ == token;
      } else if (token.CanReplace(*high_water_token_)) {
        if (render_context_ != nullptr) {
          mpv_render_context_update(render_context_);
        }
        sampling_enabled_ = false;
        sampling_sequence_ = 0;
        high_water_token_ = token;
        active_token_ = token;
        active_token_invalidated_ = false;
        output_prepared_ = false;
        active_track_id_.clear();
        frame_seen_token_.reset();
        rendered_frame_token_.reset();
        attached_token_notified_.reset();
        std::lock_guard<std::mutex> lock(textures_mutex_);
        texture_frame_tokens_.clear();
        texture_sampling_frames_.clear();
      } else {
        accepted = false;
      }
    } else if (accepted) {
      if (render_context_ != nullptr) {
        mpv_render_context_update(render_context_);
      }
      sampling_enabled_ = false;
      sampling_sequence_ = 0;
      high_water_token_ = token;
      active_token_ = token;
      active_token_invalidated_ = false;
      output_prepared_ = false;
      active_track_id_.clear();
      frame_seen_token_.reset();
      rendered_frame_token_.reset();
      attached_token_notified_.reset();
      std::lock_guard<std::mutex> lock(textures_mutex_);
      texture_frame_tokens_.clear();
      texture_sampling_frames_.clear();
    }
    if (accepted && sampling_admission_ != "blocked")
      TransitionSampling("blocked");
    on_complete(accepted);
  });
}

void VideoOutput::PrepareForLoad(
    OutputOperationToken token,
    std::string track_id,
    int64_t width,
    int64_t height,
    std::function<void(bool, int64_t, int64_t)> on_complete) {
  thread_pool_ref_->Post([this, token, track_id = std::move(track_id), width,
                          height, on_complete]() mutable {
    if (!IsCurrentToken(token) || track_id.empty() || width < 1 || height < 1 ||
        destroyed_.load(std::memory_order_acquire)) {
      on_complete(false, 0, 0);
      return;
    }
    active_track_id_ = std::move(track_id);
    output_prepared_ = true;
    texture_update_pending_ = true;
    rendered_frame_token_.reset();
    attached_token_notified_.reset();
    source_width_ = width;
    source_height_ = height;
    {
      std::lock_guard<std::mutex> lock(textures_mutex_);
      texture_frame_tokens_.clear();
      texture_sampling_frames_.clear();
    }
    const auto required_width = GetVideoWidth();
    const auto required_height = GetVideoHeight();
    if (required_width < 1 || required_height < 1) {
      output_prepared_ = false;
      on_complete(false, 0, 0);
      return;
    }
    auto configured = [this, token, on_complete](bool success) {
      if (!success || !IsCurrentToken(token) ||
          destroyed_.load(std::memory_order_acquire)) {
        on_complete(false, 0, 0);
        return;
      }
      // on_preloaded has established the new file identity. Rendering here
      // makes the renderer/texture receipt belong to that file even when
      // open(play: false) leaves the player paused.
      // A current-file frame may arrive just after FILE_LOADED; the separate
      // token-bound Attach callback is the completion gate for that frame.
      Render();
      if (IsCurrentToken(token) && !destroyed_.load(std::memory_order_acquire)) {
        on_complete(true, this->width(), this->height());
      } else {
        on_complete(false, 0, 0);
      }
    };
    int64_t current_width = -1, current_height = -1;
    if (surface_manager_ != nullptr) {
      current_width = surface_manager_->width();
      current_height = surface_manager_->height();
    } else if (pixel_buffer_ != nullptr && texture_id_ != 0) {
      const auto texture = pixel_buffer_textures_.find(texture_id_);
      if (texture != pixel_buffer_textures_.end()) {
        current_width = texture->second->width;
        current_height = texture->second->height;
      }
    }
    if (required_width == current_width && required_height == current_height &&
        texture_id_ != 0) {
      configured(true);
    } else {
      Resize(required_width, required_height, std::move(configured));
    }
  });
}

void VideoOutput::InvalidateOutputGeneration(
    OutputOperationToken token,
    std::function<void(bool)> on_complete) {
  thread_pool_ref_->Post([this, token, on_complete]() {
    bool acknowledged = false;
    if (high_water_token_.has_value()) {
      if (*high_water_token_ == token) {
        TransitionSampling("blocked");
        active_token_invalidated_ = true;
        output_prepared_ = false;
        active_track_id_.clear();
        frame_seen_token_.reset();
        rendered_frame_token_.reset();
        attached_token_notified_.reset();
        {
          std::lock_guard<std::mutex> lock(textures_mutex_);
          texture_frame_tokens_.clear();
          texture_sampling_frames_.clear();
        }
        acknowledged = true;
      } else if (high_water_token_->CanReplace(token)) {
        // A later token already crossed the render queue barrier, so this
        // generation can no longer publish output.
        acknowledged = true;
      }
    }
    on_complete(acknowledged);
  });
}

void VideoOutput::NotifyTextureUpdate(int64_t id, int64_t width, int64_t height) {
  std::function<void(int64_t, int64_t, int64_t)> callback;
  {
    std::lock_guard<std::mutex> lock(callback_mutex_);
    callback = texture_update_callback_;
  }
  callback(id, width, height);
}

void VideoOutput::NotifyFrameConsumed(int64_t texture_id) {
  std::optional<TextureFrameIdentity> frame;
  {
    std::lock_guard<std::mutex> lock(textures_mutex_);
    const auto found = texture_sampling_frames_.find(texture_id);
    if (found != texture_sampling_frames_.end()) {
      frame = found->second;
      texture_sampling_frames_.erase(found);
    }
  }
  if (!frame.has_value()) return;
  const auto timestamp =
      std::chrono::duration_cast<std::chrono::microseconds>(
                             std::chrono::steady_clock::now().time_since_epoch())
                             .count();
  thread_pool_ref_->Post([this, frame = *frame, timestamp]() {
    if (!IsCurrentToken(frame.token)) return;
    frame_consumed_callback_(frame.token, timestamp);
    if (frame.generation != sampling_generation_ ||
        frame.rendered_at_us <= sampling_valid_after_us_ || !sampling_enabled_)
      return;
    if (sampling_admission_ == "priming")
      TransitionSampling("active");
    else if (sampling_admission_ == "active")
      frame_sampling_callback_(
          {frame.token, frame.generation, "", timestamp, ++sampling_sequence_});
  });
}

void VideoOutput::SetSize(std::optional<int64_t> width,
                          std::optional<int64_t> height,
                          std::function<void(bool)> on_frame_ready) {
  thread_pool_ref_->Post([this, width, height, on_frame_ready]() {
    bool frame_ready = false;
    try {
      if (destroyed_.load(std::memory_order_acquire)) {
        on_frame_ready(false);
        return;
      }
      if (width.has_value()) {
        // H/W
        if (surface_manager_ != nullptr) {
          width_ = width.value();
        }
        // S/W
        if (pixel_buffer_ != nullptr) {
          // Limit width if software rendering is being used.
          width_ = std::clamp(width.value(), static_cast<int64_t>(0),
                              static_cast<int64_t>(SW_RENDERING_MAX_WIDTH));
        }
      } else {
        width_ = std::nullopt;
      }
      if (height.has_value()) {
        // H/W
        if (surface_manager_ != nullptr) {
          height_ = height.value();
        }
        // S/W
        if (pixel_buffer_ != nullptr) {
          // Limit width if software rendering is being used.
          height_ = std::clamp(height.value(), static_cast<int64_t>(0),
                               static_cast<int64_t>(SW_RENDERING_MAX_HEIGHT));
        }
      } else {
        height_ = std::nullopt;
      }
      const auto required_width = GetVideoWidth();
      const auto required_height = GetVideoHeight();
      if (required_width < 1 || required_height < 1) {
        on_frame_ready(false);
        return;
      }
      int64_t current_width = -1, current_height = -1;
      if (surface_manager_ != nullptr) {
        current_width = surface_manager_->width();
        current_height = surface_manager_->height();
      } else if (pixel_buffer_ != nullptr && texture_id_ != 0) {
        const auto texture = pixel_buffer_textures_.find(texture_id_);
        if (texture != pixel_buffer_textures_.end()) {
          current_width = texture->second->width;
          current_height = texture->second->height;
        }
      }
      if (required_width != current_width || required_height != current_height ||
          texture_id_ == 0) {
        Resize(required_width, required_height,
               [this, on_frame_ready](bool resized) {
                 const bool ready = resized && Render() &&
                                    !texture_update_pending_;
                 on_frame_ready(ready);
               });
        return;
      }
      // 同尺寸沿用已发布的视频帧；真实替换仍需完成渲染和可用帧通知。
      frame_ready = texture_id_ && !texture_update_pending_;
      if (!frame_ready) frame_ready = Render() && !texture_update_pending_;
    } catch (...) {
      // Signal failure so Dart retains its protective frame and can recover.
    }
    on_frame_ready(frame_ready);
  });
}

void VideoOutput::SetSourceSize(
    int64_t width,
    int64_t height,
    std::optional<OutputOperationToken> token) {
  if (width < 1 || height < 1) return;
  thread_pool_ref_->Post([this, width, height, token]() {
    if (destroyed_.load(std::memory_order_acquire)) return;
    if (token.has_value()) {
      if (!IsCurrentToken(*token)) return;
    } else if (active_token_.has_value() && !active_token_invalidated_) {
      // Runtime-managed loads require geometry tagged with their generation.
      return;
    }
    if (source_width_ == width && source_height_ == height) return;
    source_width_ = width;
    source_height_ = height;
    CheckAndResize();
    // 固定输出的参数更新沿用 mpv 帧通知，避免额外抢占渲染队列。
    if (texture_update_pending_) Render();
  });
}

void VideoOutput::CheckAndResize() {
  if (destroyed_.load(std::memory_order_acquire)) return;
  // Check if a new texture with different dimensions is needed.
  auto required_width = GetVideoWidth(), required_height = GetVideoHeight();
  if (required_width < 1 || required_height < 1) {
    // Invalid.
    return;
  }
  int64_t current_width = -1, current_height = -1;
  if (surface_manager_ != nullptr) {
    current_width = surface_manager_->width();
    current_height = surface_manager_->height();
  }
  if (pixel_buffer_ != nullptr) {
    const auto texture = pixel_buffer_textures_.find(texture_id_);
    if (texture != pixel_buffer_textures_.end()) {
      current_width = texture->second->width;
      current_height = texture->second->height;
    }
  }
  // Currently rendered video output dimensions.
  // Either H/W or S/W rendered.
  if (required_width == current_width && required_height == current_height &&
      texture_id_ != 0) {
    // No creation of new texture required.
    return;
  }
  Resize(required_width, required_height);
}

void VideoOutput::Resize(int64_t required_width,
                         int64_t required_height,
                         std::function<void(bool)> on_complete) {
  if (resize_in_progress_ || renderer_reset_in_progress_) {
    queued_resize_ = std::make_pair(required_width, required_height);
    if (on_complete) {
      queued_resize_completions_.push_back(std::move(on_complete));
    }
    return;
  }
  if (on_complete) resize_completions_.push_back(std::move(on_complete));
  if (destroyed_.load(std::memory_order_acquire) || required_width < 1 ||
      required_height < 1) {
    FinishResize(required_width, required_height, false);
    return;
  }
  TransitionSampling("blocked");
  resize_in_progress_ = true;
  std::cout << required_width << " " << required_height << std::endl;
  const auto old_texture_id = texture_id_;
  texture_id_ = 0;
  if (old_texture_id) {
    UnregisterTexture(old_texture_id, [this, required_width, required_height]() {
      if (destroyed_.load(std::memory_order_acquire)) {
        FinishResize(required_width, required_height, false);
        return;
      }
      bool success = false;
      try {
        success = ApplyResize(required_width, required_height);
      } catch (...) {
        success = false;
      }
      FinishResize(required_width, required_height, success);
    });
    return;
  }
  bool success = false;
  try {
    success = ApplyResize(required_width, required_height);
  } catch (...) {
    success = false;
  }
  FinishResize(required_width, required_height, success);
}

bool VideoOutput::ApplyResize(int64_t required_width, int64_t required_height) {
  if (destroyed_.load(std::memory_order_acquire)) return false;
  texture_update_pending_ = true;
  {
    std::lock_guard<std::mutex> lock(textures_mutex_);
    texture_frame_tokens_.clear();
    texture_sampling_frames_.clear();
  }
  // H/W
  if (surface_manager_ != nullptr) {
    // Destroy internal ID3D11Texture2D & EGLSurface & create new with updated
    // dimensions while preserving previous EGLDisplay & EGLContext.
    surface_manager_->SetSize(static_cast<int32_t>(required_width),
                              static_cast<int32_t>(required_height));
    auto texture = std::make_unique<FlutterDesktopGpuSurfaceDescriptor>();
    texture->struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
    texture->handle = surface_manager_->handle();
    texture->width = texture->visible_width = surface_manager_->width();
    texture->height = texture->visible_height = surface_manager_->height();
    texture->release_context = nullptr;
    texture->release_callback = [](void*) {};
    texture->format = kFlutterDesktopPixelFormatBGRA8888;
    auto texture_variant =
        std::make_unique<flutter::TextureVariant>(flutter::GpuSurfaceTexture(
            kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle, [&](auto, auto) {
              FlutterDesktopGpuSurfaceDescriptor* descriptor = nullptr;
              int64_t consumed_texture_id = 0;
              {
                std::lock_guard<std::mutex> lock(textures_mutex_);
                if (texture_id_ && surface_manager_ && !texture_update_pending_) {
                  const auto texture = textures_.find(texture_id_);
                  if (texture != textures_.end()) {
                    surface_manager_->Read();
                    descriptor = texture->second.get();
                    consumed_texture_id = texture_id_;
                  }
                }
              }
              if (consumed_texture_id) NotifyFrameConsumed(consumed_texture_id);
              return descriptor;
            }));
    // Register new texture.
    texture_id_ =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    if (texture_id_ <= 0) {
      texture_id_ = 0;
      return false;
    }
    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
              << std::endl;
    std::lock_guard<std::mutex> lock(textures_mutex_);
    textures_.emplace(std::make_pair(texture_id_, std::move(texture)));
    texture_variants_.emplace(
        std::make_pair(texture_id_, std::move(texture_variant)));
    texture_frame_tokens_.erase(texture_id_);
    texture_sampling_frames_.erase(texture_id_);
  }
  // S/W
  if (pixel_buffer_ != nullptr) {
    auto pixel_buffer_texture = std::make_unique<FlutterDesktopPixelBuffer>();
    pixel_buffer_texture->buffer = pixel_buffer_.get();
    pixel_buffer_texture->width = required_width;
    pixel_buffer_texture->height = required_height;
    pixel_buffer_texture->release_context = nullptr;
    pixel_buffer_texture->release_callback = [](void*) {};
    auto texture_variant = std::make_unique<flutter::TextureVariant>(
        flutter::PixelBufferTexture([&](auto, auto) {
          FlutterDesktopPixelBuffer* buffer = nullptr;
          int64_t consumed_texture_id = 0;
          {
            std::lock_guard<std::mutex> lock(textures_mutex_);
            if (texture_id_ && !texture_update_pending_) {
              const auto texture = pixel_buffer_textures_.find(texture_id_);
              if (texture != pixel_buffer_textures_.end()) {
                buffer = texture->second.get();
                consumed_texture_id = texture_id_;
              }
            }
          }
          if (consumed_texture_id) NotifyFrameConsumed(consumed_texture_id);
          return buffer;
        }));
    // Register new texture.
    texture_id_ =
        registrar_->texture_registrar()->RegisterTexture(texture_variant.get());
    if (texture_id_ <= 0) {
      texture_id_ = 0;
      return false;
    }
    std::cout << "media_kit: VideoOutput: Create Texture: " << texture_id_
              << std::endl;
    std::lock_guard<std::mutex> lock(textures_mutex_);
    pixel_buffer_textures_.emplace(
        std::make_pair(texture_id_, std::move(pixel_buffer_texture)));
    texture_variants_.emplace(
        std::make_pair(texture_id_, std::move(texture_variant)));
    texture_frame_tokens_.erase(texture_id_);
    texture_sampling_frames_.erase(texture_id_);
  }
  return texture_id_ != 0;
}

void VideoOutput::FinishResize(int64_t required_width,
                               int64_t required_height,
                               bool success) {
  resize_in_progress_ = false;
  auto completions = std::move(resize_completions_);
  resize_completions_.clear();
  if (success && completions.empty() &&
      !destroyed_.load(std::memory_order_acquire)) {
    Render();
  }
  for (auto& completion : completions) completion(success);
  if (queued_resize_.has_value()) {
    const auto next = *queued_resize_;
    if (next.first == required_width && next.second == required_height) {
      queued_resize_.reset();
      auto queued_completions = std::move(queued_resize_completions_);
      queued_resize_completions_.clear();
      for (auto& completion : queued_completions) completion(success);
    }
  }
  ProcessPendingTextureOperations();
}

void VideoOutput::UnregisterTexture(int64_t id,
                                    std::function<void()> on_unregistered) {
  if (!id) return;
  {
    std::lock_guard<std::mutex> lock(texture_unregistrations_mutex_);
    ++pending_texture_unregistrations_;
  }
  registrar_->texture_registrar()->UnregisterTexture(id, [this, id,
                                                            on_unregistered]() {
    try {
      thread_pool_ref_->Post([this, id, on_unregistered]() {
        {
          std::lock_guard<std::mutex> lock(textures_mutex_);
          texture_variants_.erase(id);
          textures_.erase(id);
          pixel_buffer_textures_.erase(id);
          texture_frame_tokens_.erase(id);
          texture_sampling_frames_.erase(id);
        }
        if (on_unregistered) on_unregistered();
        {
          std::lock_guard<std::mutex> lock(texture_unregistrations_mutex_);
          if (pending_texture_unregistrations_ > 0) {
            --pending_texture_unregistrations_;
          }
        }
        texture_unregistrations_cv_.notify_all();
      });
    } catch (...) {
      // Without Flutter's unregister receipt the texture may still reference
      // this object. Keep its release barrier pending and quarantine the handle.
    }
  });
}

int64_t VideoOutput::GetVideoWidth() {
  // Fixed width.
  if (width_) {
    return width_.value();
  }
  // 尺寸由 Dart 的 video-out-params 观察事件送入渲染队列。
  // 同步查询会等待正在等待首帧渲染的 mpv 核心，触发超时卡顿。
  const int64_t width = source_width_;
  const int64_t height = source_height_;
  if (width < 1 || height < 1) return 0;

  if (pixel_buffer_ != nullptr) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect-ratio.
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return SW_RENDERING_MAX_WIDTH;
    }
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return (std::max)(
          int64_t{1}, static_cast<int64_t>(std::llround(
                          static_cast<double>(width) *
                          SW_RENDERING_MAX_HEIGHT / height)));
    }
  }

  return width;
}

int64_t VideoOutput::GetVideoHeight() {
  // Fixed height.
  if (height_) {
    return height_.value();
  }
  const int64_t width = source_width_;
  const int64_t height = source_height_;
  if (width < 1 || height < 1) return 0;

  if (pixel_buffer_ != NULL) {
    // Make sure |width| & |height| fit between |SW_RENDERING_MAX_WIDTH| &
    // |SW_RENDERING_MAX_HEIGHT| while maintaining aspect-ratio.
    if (height >= SW_RENDERING_MAX_HEIGHT) {
      return SW_RENDERING_MAX_HEIGHT;
    }
    if (width >= SW_RENDERING_MAX_WIDTH) {
      return (std::max)(
          int64_t{1}, static_cast<int64_t>(std::llround(
                          static_cast<double>(height) *
                          SW_RENDERING_MAX_WIDTH / width)));
    }
  }

  return height;
}
