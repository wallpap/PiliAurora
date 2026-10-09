#ifndef MEDIA_KIT_VIDEO_PLATFORM_THREAD_DISPATCHER_H_
#define MEDIA_KIT_VIDEO_PLATFORM_THREAD_DISPATCHER_H_

#include <flutter/plugin_registrar_windows.h>

#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>

// Channel calls must run on the platform thread. Tasks are owned by shared
// state, not raw LPARAM pointers; shutdown can safely discard pending messages.
class PlatformThreadDispatcher {
 public:
  using Task = std::function<void()>;
  using PostTask = std::function<void(Task)>;

  explicit PlatformThreadDispatcher(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar), state_(std::make_shared<State>()) {
    // Plugin registration precedes SetChildContent in the Flutter runner.
    // Retain the view HWND, not its registration-time (unparented) root.
    state_->view = registrar_->GetView()->GetNativeWindow();
    state_->message = ::RegisterWindowMessageW(L"PiliAurora.MediaKitVideo.PlatformTask");
    const auto state = state_;
    delegate_ = registrar_->RegisterTopLevelWindowProcDelegate(
        [state](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
          if (message != state->message) return std::nullopt;
          std::deque<Task> tasks;
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->active) return 0;
            tasks.swap(state->tasks);
          }
          for (auto& task : tasks) task();
          return 0;
        });
  }

  PostTask post() const {
    const auto state = state_;
    return [state](Task task) {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (!state->active) return;
      state->tasks.push_back(std::move(task));
      const auto window = ::GetAncestor(state->view, GA_ROOT);
      if (!::PostMessageW(window, state->message, 0, 0)) {
        state->tasks.clear();
      }
    };
  }

  ~PlatformThreadDispatcher() {
    {
      std::lock_guard<std::mutex> lock(state_->mutex);
      state_->active = false;
      state_->tasks.clear();
    }
    registrar_->UnregisterTopLevelWindowProcDelegate(delegate_);
  }

 private:
  struct State {
    std::mutex mutex;
    std::deque<Task> tasks;
    HWND view = nullptr;
    UINT message = 0;
    bool active = true;
  };
  flutter::PluginRegistrarWindows* registrar_;
  std::shared_ptr<State> state_;
  int delegate_ = 0;
};

#endif
