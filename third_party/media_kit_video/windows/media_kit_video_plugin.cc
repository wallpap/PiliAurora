// This file is a part of media_kit
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#include "media_kit_video_plugin.h"
#include "native_memory_stats.h"

#include <Windows.h>

#include <mutex>
#include <optional>
#include <vector>

#include "utils.h"

namespace media_kit_video {
namespace {
const char* ResourceName(media_kit_memory::Resource resource) {
  switch (resource) {
    case media_kit_memory::Resource::output: return "videoOutput";
    case media_kit_memory::Resource::render_context: return "renderContext";
    case media_kit_memory::Resource::device: return "d3dDevice";
    case media_kit_memory::Resource::egl_context: return "eglContext";
    case media_kit_memory::Resource::egl_surface: return "eglSurface";
    case media_kit_memory::Resource::texture: return "d3dTexture";
    case media_kit_memory::Resource::software_buffer: return "softwareBuffer";
    case media_kit_memory::Resource::count: break;
  }
  return "unknown";
}

flutter::EncodableMap EncodeMemoryStats() {
  const auto snapshot = media_kit_memory::Registry::Instance().Read();
  flutter::EncodableMap resources;
  for (size_t i = 0; i < static_cast<size_t>(media_kit_memory::Resource::count); ++i) {
    const auto resource = static_cast<media_kit_memory::Resource>(i);
    const auto& value = snapshot.resources[i];
    resources[flutter::EncodableValue(ResourceName(resource))] =
        flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("count"), flutter::EncodableValue(value.count)},
            {flutter::EncodableValue("created"), flutter::EncodableValue(value.created)},
            {flutter::EncodableValue("released"), flutter::EncodableValue(value.released)},
            {flutter::EncodableValue("estimatedBytes"), flutter::EncodableValue(value.estimated_bytes)},
        });
  }
  return flutter::EncodableMap{
      {flutter::EncodableValue("status"), flutter::EncodableValue("ok")},
      {flutter::EncodableValue("tickMs"), flutter::EncodableValue(static_cast<int64_t>(GetTickCount64()))},
      {flutter::EncodableValue("processId"), flutter::EncodableValue(static_cast<int64_t>(GetCurrentProcessId()))},
      {flutter::EncodableValue("resources"), flutter::EncodableValue(resources)},
      {flutter::EncodableValue("releasingOutputs"), flutter::EncodableValue(snapshot.releasing_outputs)},
      {flutter::EncodableValue("pendingTextureUnregistrations"), flutter::EncodableValue(snapshot.pending_texture_unregistrations)},
  };
}

struct FrameProgressBatch {
  std::mutex mutex;
  std::optional<OutputOperationToken> token;
  std::vector<int64_t> timestamps;
  bool flush_scheduled = false;
};

OutputOperationToken ReadOutputOperationToken(
    const flutter::EncodableMap& values) {
  const auto read = [&values](const char* key) {
    return std::stoll(std::get<std::string>(
        values.at(flutter::EncodableValue(key))));
  };
  return OutputOperationToken{read("runtimeId"), read("loadId"),
                              read("outputEpoch"), read("configRevision")};
}

flutter::EncodableMap EncodeOutputOperationToken(
    const OutputOperationToken& token) {
  return flutter::EncodableMap{
      {flutter::EncodableValue("runtimeId"),
       flutter::EncodableValue(std::to_string(token.runtime_id))},
      {flutter::EncodableValue("loadId"),
       flutter::EncodableValue(std::to_string(token.load_id))},
      {flutter::EncodableValue("outputEpoch"),
       flutter::EncodableValue(std::to_string(token.output_epoch))},
      {flutter::EncodableValue("configRevision"),
       flutter::EncodableValue(std::to_string(token.config_revision))},
  };
}

flutter::EncodableMap EncodeSamplingState(const VideoFrameSamplingEvent& state) {
  return flutter::EncodableMap{
    {flutter::EncodableValue("token"), flutter::EncodableValue(EncodeOutputOperationToken(state.token))},
    {flutter::EncodableValue("samplingGeneration"), flutter::EncodableValue(state.generation)},
    {flutter::EncodableValue("admission"), flutter::EncodableValue(state.admission)},
    {flutter::EncodableValue("validAfterUs"), flutter::EncodableValue(state.timestamp_us)},
  };
}

}  // namespace

void MediaKitVideoPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<MediaKitVideoPlugin>(registrar);
  registrar->AddPlugin(std::move(plugin));
}

MediaKitVideoPlugin::MediaKitVideoPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      video_output_manager_(std::make_unique<VideoOutputManager>(registrar)) {
  channel_ = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), "com.alexmercerind/media_kit_video",
      &flutter::StandardMethodCodec::GetInstance());
  platform_dispatcher_ = std::make_unique<PlatformThreadDispatcher>(registrar);
  channel_->SetMethodCallHandler([&](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

MediaKitVideoPlugin::~MediaKitVideoPlugin() {
  // In-flight worker callbacks retain dispatcher state, not this plugin.
  platform_dispatcher_.reset();
}

void MediaKitVideoPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "VideoOutputManager.MemoryStats") {
    result->Success(flutter::EncodableValue(EncodeMemoryStats()));
  } else if (method_call.method_name().compare("VideoOutputManager.Create") == 0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto configuration = std::get<flutter::EncodableMap>(
        arguments[flutter::EncodableValue("configuration")]);

    auto handle_value = std::stoll(handle);
    auto configuration_value = VideoOutputConfiguration{};

    auto configuration_width =
        std::get<std::string>(configuration[flutter::EncodableValue("width")]);
    auto configuration_height =
        std::get<std::string>(configuration[flutter::EncodableValue("height")]);
    auto configuration_enable_hardware_acceleration = std::get<bool>(
        configuration[flutter::EncodableValue("enableHardwareAcceleration")]);
    if (configuration_width.compare("null") != 0) {
      configuration_value.width =
          static_cast<int64_t>(std::stoll(configuration_width.c_str()));
    }
    if (configuration_height.compare("null") != 0) {
      configuration_value.height =
          static_cast<int64_t>(std::stoll(configuration_height.c_str()));
    }
    configuration_value.enable_hardware_acceleration =
        configuration_enable_hardware_acceleration;

    video_output_manager_->Create(
        handle_value, configuration_value,
        [channel_ptr = channel_, post = platform_dispatcher_->post(),
         handle = handle_value](
            auto id, auto width, auto height) {
          post([channel_ptr, handle, id, width, height]() {
            channel_ptr->InvokeMethod(
                "VideoOutput.Resize",
                std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                    {
                        flutter::EncodableValue("handle"),
                        flutter::EncodableValue(handle),
                    },
                    {
                        flutter::EncodableValue("id"),
                        flutter::EncodableValue(id),
                    },
                    {
                        flutter::EncodableValue("rect"),
                        flutter::EncodableValue(flutter::EncodableMap{
                            {
                                flutter::EncodableValue("left"),
                                flutter::EncodableValue(0),
                            },
                            {
                                flutter::EncodableValue("top"),
                                flutter::EncodableValue(0),
                            },
                            {
                                flutter::EncodableValue("width"),
                                flutter::EncodableValue(width),
                            },
                            {
                                flutter::EncodableValue("height"),
                                flutter::EncodableValue(height),
                            },
                        }),
                    },
                }),
                nullptr);
          });
        },
        [channel_ptr = channel_, post = platform_dispatcher_->post(),
         handle = handle_value](const auto& token, auto id, auto width,
                                auto height) {
          post([channel_ptr, handle, token, id, width, height]() {
            channel_ptr->InvokeMethod(
                "VideoOutput.Attach",
                std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                    {flutter::EncodableValue("handle"),
                     flutter::EncodableValue(handle)},
                    {flutter::EncodableValue("id"), flutter::EncodableValue(id)},
                    {flutter::EncodableValue("rect"),
                     flutter::EncodableValue(flutter::EncodableMap{
                         {flutter::EncodableValue("width"),
                          flutter::EncodableValue(width)},
                         {flutter::EncodableValue("height"),
                          flutter::EncodableValue(height)},
                     })},
                    {flutter::EncodableValue("token"),
                     flutter::EncodableValue(EncodeOutputOperationToken(token))},
                }),
                nullptr);
          });
        },
        [channel_ptr = channel_, post = platform_dispatcher_->post(),
         handle = handle_value,
         batch = std::make_shared<FrameProgressBatch>()](const auto& token,
                                                         auto timestamp_us) {
          bool should_schedule = false;
          {
            std::lock_guard<std::mutex> lock(batch->mutex);
            if (!batch->token.has_value() || !(*batch->token == token)) {
              batch->token = token;
              batch->timestamps.clear();
            }
            if (batch->timestamps.size() < 64) {
              batch->timestamps.push_back(timestamp_us);
            } else {
              batch->timestamps.back() = timestamp_us;
            }
            if (!batch->flush_scheduled) {
              batch->flush_scheduled = true;
              should_schedule = true;
            }
          }
          if (!should_schedule) return;
          post([channel_ptr, handle, batch]() {
            std::optional<OutputOperationToken> token;
            std::vector<int64_t> timestamps;
            {
              std::lock_guard<std::mutex> lock(batch->mutex);
              token = batch->token;
              timestamps = std::move(batch->timestamps);
              batch->timestamps.clear();
              batch->flush_scheduled = false;
            }
            if (!token.has_value() || timestamps.empty()) return;
            flutter::EncodableList encoded_timestamps;
            encoded_timestamps.reserve(timestamps.size());
            for (const auto timestamp : timestamps) {
              encoded_timestamps.emplace_back(timestamp);
            }
            channel_ptr->InvokeMethod(
                "VideoOutput.Progress",
                std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                    {flutter::EncodableValue("handle"),
                     flutter::EncodableValue(handle)},
                    {flutter::EncodableValue("token"),
                     flutter::EncodableValue(EncodeOutputOperationToken(*token))},
                    {flutter::EncodableValue("consumedAtMonotonicUs"),
                     flutter::EncodableValue(encoded_timestamps)},
                }),
                nullptr);
          });
        },
        [channel_ptr = channel_, post = platform_dispatcher_->post(),
         handle = handle_value](const VideoFrameSamplingEvent& event) {
          post([channel_ptr, handle, event]() {
            flutter::EncodableMap args{
                {flutter::EncodableValue("handle"),
                 flutter::EncodableValue(handle)},
                {flutter::EncodableValue("token"),
                 flutter::EncodableValue(
                     EncodeOutputOperationToken(event.token))},
                {flutter::EncodableValue("samplingGeneration"),
                 flutter::EncodableValue(event.generation)},
            };
            if (!event.admission.empty()) {
              args[flutter::EncodableValue("admission")] =
                  flutter::EncodableValue(event.admission);
              args[flutter::EncodableValue("validAfterUs")] =
                  flutter::EncodableValue(event.timestamp_us);
            } else {
              args[flutter::EncodableValue("kind")] =
                  flutter::EncodableValue("textureConsumed");
              args[flutter::EncodableValue("sequence")] =
                  flutter::EncodableValue(event.sequence);
              args[flutter::EncodableValue("monotonicUs")] =
                  flutter::EncodableValue(flutter::EncodableList{
                      flutter::EncodableValue(event.timestamp_us)});
            }
            channel_ptr->InvokeMethod(
                "VideoOutput.FrameSampling",
                std::make_unique<flutter::EncodableValue>(args), nullptr);
          });
        });
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name() ==
             "VideoOutputManager.SetFrameSampling") {
    const auto args = std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto handle = std::stoll(
        std::get<std::string>(args.at(flutter::EncodableValue("handle"))));
    const auto token = ReadOutputOperationToken(std::get<flutter::EncodableMap>(
        args.at(flutter::EncodableValue("token"))));
    const auto enabled =
        std::get<bool>(args.at(flutter::EncodableValue("enabled")));
    auto completion =
        std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
            std::move(result));
    video_output_manager_->SetFrameSampling(
        handle, token, enabled,
        [post = platform_dispatcher_->post(), completion](std::optional<VideoFrameSamplingEvent> state) {
          post([completion, state]() {
            if (state.has_value())
              completion->Success(flutter::EncodableValue(EncodeSamplingState(*state)));
            else
              completion->Error("sampling-rejected",
                                "Output generation is unavailable");
          });
        });
  } else if (method_call.method_name() ==
             "VideoOutputManager.BeginOutputForLoad") {
    const auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto handle = std::stoll(std::get<std::string>(
        arguments.at(flutter::EncodableValue("handle"))));
    const auto token = ReadOutputOperationToken(
        std::get<flutter::EncodableMap>(
            arguments.at(flutter::EncodableValue("token"))));
    auto completion = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
        std::move(result));
    video_output_manager_->BeginOutputForLoad(
        handle, token,
        [completion, post = platform_dispatcher_->post()](bool accepted) {
          post([completion, accepted]() {
            completion->Success(flutter::EncodableValue(accepted));
          });
        });
  } else if (method_call.method_name() ==
             "VideoOutputManager.PrepareForLoad") {
    const auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto handle = std::stoll(std::get<std::string>(
        arguments.at(flutter::EncodableValue("handle"))));
    const auto token = ReadOutputOperationToken(
        std::get<flutter::EncodableMap>(
            arguments.at(flutter::EncodableValue("token"))));
    const auto track_id = std::get<std::string>(
        arguments.at(flutter::EncodableValue("trackId")));
    const auto width = arguments.at(flutter::EncodableValue("width")).LongValue();
    const auto height = arguments.at(flutter::EncodableValue("height")).LongValue();
    auto completion = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
        std::move(result));
    video_output_manager_->PrepareForLoad(
        handle, token, track_id, width, height,
        [completion, post = platform_dispatcher_->post()](bool accepted,
                                                          int64_t output_width,
                                                          int64_t output_height) {
          post([completion, accepted, output_width, output_height]() {
            completion->Success(flutter::EncodableValue(flutter::EncodableMap{
                {flutter::EncodableValue("accepted"),
                 flutter::EncodableValue(accepted)},
                {flutter::EncodableValue("width"),
                 flutter::EncodableValue(output_width)},
                {flutter::EncodableValue("height"),
                 flutter::EncodableValue(output_height)},
            }));
          });
        });
  } else if (method_call.method_name() ==
             "VideoOutputManager.InvalidateOutputGeneration") {
    const auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto handle = std::stoll(std::get<std::string>(
        arguments.at(flutter::EncodableValue("handle"))));
    const auto token = ReadOutputOperationToken(
        std::get<flutter::EncodableMap>(
            arguments.at(flutter::EncodableValue("token"))));
    auto completion = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
        std::move(result));
    video_output_manager_->InvalidateOutputGeneration(
        handle, token,
        [completion, post = platform_dispatcher_->post()](bool acknowledged) {
          post([completion, acknowledged]() {
            completion->Success(flutter::EncodableValue(acknowledged));
          });
        });
  } else if (method_call.method_name().compare("VideoOutputManager.SetSourceSize") == 0) {
    const auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto handle = std::get<std::string>(arguments.at(flutter::EncodableValue("handle")));
    // Dart 通道按数值范围编码 int32/int64，普通视频尺寸会走 int32。
    const auto width = arguments.at(flutter::EncodableValue("width")).LongValue();
    const auto height = arguments.at(flutter::EncodableValue("height")).LongValue();
    std::optional<OutputOperationToken> token;
    const auto token_value = arguments.find(flutter::EncodableValue("token"));
    if (token_value != arguments.end()) {
      token = ReadOutputOperationToken(
          std::get<flutter::EncodableMap>(token_value->second));
    }
    video_output_manager_->SetSourceSize(std::stoll(handle), width, height,
                                         token);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare("VideoOutputManager.Dispose") ==
             0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto handle_value = static_cast<int64_t>(std::stoll(handle.c_str()));
    auto completion = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
        std::move(result));
    video_output_manager_->Dispose(
        handle_value,
        [completion, post = platform_dispatcher_->post()]() {
          post([completion]() {
            completion->Success(flutter::EncodableValue(std::monostate{}));
          });
        });
  } else if (method_call.method_name() == "VideoOutputManager.ResetRenderer") {
    const auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    const auto handle = std::get<std::string>(
        arguments.at(flutter::EncodableValue("handle")));
    auto completion = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
        std::move(result));
    video_output_manager_->ResetRenderer(
        std::stoll(handle),
        [completion, post = platform_dispatcher_->post()](bool ready) {
          post([completion, ready]() {
            if (ready) {
              completion->Success(flutter::EncodableValue(std::monostate{}));
            } else {
              completion->Error("video_output_reset", "Renderer reset failed");
            }
          });
        });
  } else if (method_call.method_name().compare("VideoOutputManager.SetSize") ==
             0) {
    auto arguments = std::get<flutter::EncodableMap>(*method_call.arguments());
    auto handle =
        std::get<std::string>(arguments[flutter::EncodableValue("handle")]);
    auto width =
        std::get<std::string>(arguments[flutter::EncodableValue("width")]);
    auto height =
        std::get<std::string>(arguments[flutter::EncodableValue("height")]);
    auto handle_value = static_cast<int64_t>(std::stoll(handle.c_str()));
    auto width_value = std::optional<int64_t>{};
    auto height_value = std::optional<int64_t>{};
    if (width.compare("null") != 0) {
      width_value = static_cast<int64_t>(std::stoll(width.c_str()));
    }
    if (height.compare("null") != 0) {
      height_value = static_cast<int64_t>(std::stoll(height.c_str()));
    }
    auto completion = std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(
        std::move(result));
    video_output_manager_->SetSize(
        handle_value, width_value, height_value,
        [completion, post = platform_dispatcher_->post()](bool frame_ready) {
          post([completion, frame_ready]() {
            if (frame_ready) {
              completion->Success(flutter::EncodableValue(std::monostate{}));
            } else {
              completion->Error("video_output_frame", "No rendered resize frame");
            }
          });
        });
  } else if (method_call.method_name().compare("Utils.EnterNativeFullscreen") ==
             0) {
    auto window =
        ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
    Utils::EnterNativeFullscreen(window);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else if (method_call.method_name().compare("Utils.ExitNativeFullscreen") ==
             0) {
    auto window =
        ::GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
    Utils::ExitNativeFullscreen(window);
    result->Success(flutter::EncodableValue(std::monostate{}));
  } else {
    result->NotImplemented();
  }
}

}  // namespace media_kit_video
