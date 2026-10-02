#define NOMINMAX
#include <windows.h>

#include <chrono>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>

#include "client.h"
#include "render.h"

class MpvApi {
 public:
  explicit MpvApi(const std::wstring& directory) {
    if (!SetDllDirectoryW(directory.c_str())) {
      throw std::runtime_error("SetDllDirectory failed");
    }
    module_ = LoadLibraryW((directory + L"\\libmpv-2.dll").c_str());
    if (!module_) {
      throw std::runtime_error("LoadLibrary failed: " +
                               std::to_string(GetLastError()));
    }
    create = Load<decltype(create)>("mpv_create");
    set_option = Load<decltype(set_option)>("mpv_set_option_string");
    initialize = Load<decltype(initialize)>("mpv_initialize");
    command = Load<decltype(command)>("mpv_command");
    wait_event = Load<decltype(wait_event)>("mpv_wait_event");
    request_logs = Load<decltype(request_logs)>("mpv_request_log_messages");
    get_property = Load<decltype(get_property)>("mpv_get_property_string");
    release = Load<decltype(release)>("mpv_free");
    terminate = Load<decltype(terminate)>("mpv_terminate_destroy");
    error_string = Load<decltype(error_string)>("mpv_error_string");
    create_render = Load<decltype(create_render)>("mpv_render_context_create");
    free_render = Load<decltype(free_render)>("mpv_render_context_free");
  }

  ~MpvApi() {
    if (module_) FreeLibrary(module_);
  }

  MpvApi(const MpvApi&) = delete;
  MpvApi& operator=(const MpvApi&) = delete;

  decltype(&mpv_create) create = nullptr;
  decltype(&mpv_set_option_string) set_option = nullptr;
  decltype(&mpv_initialize) initialize = nullptr;
  decltype(&mpv_command) command = nullptr;
  decltype(&mpv_wait_event) wait_event = nullptr;
  decltype(&mpv_request_log_messages) request_logs = nullptr;
  decltype(&mpv_get_property_string) get_property = nullptr;
  decltype(&mpv_free) release = nullptr;
  decltype(&mpv_terminate_destroy) terminate = nullptr;
  decltype(&mpv_error_string) error_string = nullptr;
  decltype(&mpv_render_context_create) create_render = nullptr;
  decltype(&mpv_render_context_free) free_render = nullptr;

 private:
  template <typename Function>
  Function Load(const char* name) {
    const auto address = GetProcAddress(module_, name);
    if (!address) throw std::runtime_error(std::string("Missing export: ") + name);
    return reinterpret_cast<Function>(address);
  }

  HMODULE module_ = nullptr;
};

class MpvSession {
 public:
  explicit MpvSession(MpvApi& api) : api_(api), handle_(api.create()) {
    if (!handle_) throw std::runtime_error("mpv_create failed");
  }

  ~MpvSession() { api_.terminate(handle_); }

  MpvSession(const MpvSession&) = delete;
  MpvSession& operator=(const MpvSession&) = delete;

  mpv_handle* handle() const { return handle_; }

  void Option(const char* name, const std::string& value) {
    const int result = api_.set_option(handle_, name, value.c_str());
    if (result < 0) {
      throw std::runtime_error(std::string(name) + ": " + api_.error_string(result));
    }
  }

  std::string Property(const char* name) {
    char* value = api_.get_property(handle_, name);
    const std::string result = value ? value : "unavailable";
    if (value) api_.release(value);
    return result;
  }

  void Initialize() {
    const int result = api_.initialize(handle_);
    if (result < 0) throw std::runtime_error(api_.error_string(result));
  }

 private:
  MpvApi& api_;
  mpv_handle* handle_;
};

class HiddenWindow {
 public:
  HiddenWindow() {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = DefWindowProcW;
    window_class.hInstance = GetModuleHandleW(nullptr);
    window_class.lpszClassName = L"PiliAuroraGpuProbe";
    if (!RegisterClassW(&window_class)) {
      throw std::runtime_error("RegisterClass failed");
    }
    handle_ = CreateWindowExW(0, window_class.lpszClassName, L"GPU probe",
                             WS_OVERLAPPEDWINDOW, 0, 0, 800, 480, nullptr,
                             nullptr, window_class.hInstance, nullptr);
    if (!handle_) throw std::runtime_error("CreateWindow failed");
  }

  ~HiddenWindow() { DestroyWindow(handle_); }

  HiddenWindow(const HiddenWindow&) = delete;
  HiddenWindow& operator=(const HiddenWindow&) = delete;

  HWND handle() const { return handle_; }

  void Dispatch() {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }

 private:
  HWND handle_ = nullptr;
};

std::string Utf8(const std::wstring& text) {
  const int length = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr,
                                       0, nullptr, nullptr);
  if (length <= 0) throw std::runtime_error("Invalid Unicode argument");
  std::string result(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, result.data(), length,
                      nullptr, nullptr);
  result.pop_back();
  return result;
}

uint64_t ProcessTime() {
  FILETIME creation{}, exit{}, kernel{}, user{};
  if (!GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user)) {
    throw std::runtime_error("GetProcessTimes failed");
  }
  return (static_cast<uint64_t>(kernel.dwHighDateTime) << 32) + kernel.dwLowDateTime +
         (static_cast<uint64_t>(user.dwHighDateTime) << 32) + user.dwLowDateTime;
}

bool LogSignal(const mpv_event_log_message& log) {
  const std::string text(log.text);
  const std::string prefix(log.prefix);
  return std::string(log.level) == "error" || std::string(log.level) == "fatal" ||
         text.find("Selected device") != std::string::npos ||
         text.find("GPU context") != std::string::npos ||
         text.find("Using hardware decoding") != std::string::npos ||
         text.find("Using software decoding") != std::string::npos ||
         text.find("interop") != std::string::npos ||
         text.find("Device name") != std::string::npos ||
         text.find("Device Name") != std::string::npos ||
         text.find("deviceName") != std::string::npos ||
         (prefix == "vd" && text.find("hwdec") != std::string::npos);
}

int CheckRenderApi(MpvApi& api) {
  MpvSession session(api);
  session.Option("config", "no");
  session.Option("vo", "libmpv");
  session.Initialize();
  mpv_render_context* render = nullptr;
  mpv_render_param parameters[] = {
      {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>("vulkan")},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  const int result = api.create_render(&render, session.handle(), parameters);
  if (render) api.free_render(render);
  std::cout << "RENDER_API api=vulkan result=" << result
            << " expected=" << MPV_ERROR_NOT_IMPLEMENTED << std::endl;
  return result == MPV_ERROR_NOT_IMPLEMENTED ? 0 : 1;
}

int wmain(int argument_count, wchar_t** arguments) {
  try {
    if (argument_count == 3 && std::wstring(arguments[2]) == L"--render-api-check") {
      MpvApi api(arguments[1]);
      return CheckRenderApi(api);
    }
    if (argument_count != 6 && argument_count != 7) {
      std::cerr << "Usage: probe DLL_DIRECTORY SAMPLE GPU_API HWDEC SECONDS [DEVICE]"
                << std::endl;
      return 2;
    }
    const std::string gpu_api = Utf8(arguments[3]);
    const std::string requested_hwdec = Utf8(arguments[4]);
    const int duration = std::stoi(Utf8(arguments[5]));
    if (duration < 3 || duration > 60) throw std::runtime_error("Invalid duration");
    HiddenWindow window;
    MpvApi api(arguments[1]);
    MpvSession session(api);
    session.Option("config", "no");
    session.Option("terminal", "no");
    session.Option("audio", "no");
    session.Option("vo", "gpu-next");
    session.Option("gpu-api", gpu_api);
    session.Option("gpu-context", gpu_api == "vulkan" ? "winvk" : "d3d11");
    session.Option("hwdec", requested_hwdec);
    session.Option("video-sync", "audio");
    session.Option("wid", std::to_string(reinterpret_cast<uintptr_t>(window.handle())));
    if (argument_count == 7) {
      session.Option(gpu_api == "vulkan" ? "vulkan-device" : "d3d11-adapter",
                     Utf8(arguments[6]));
    }
    api.request_logs(session.handle(), "v");
    session.Initialize();
    std::cout << "VERSIONS mpv=" << session.Property("mpv-version")
              << " ffmpeg=" << session.Property("ffmpeg-version") << std::endl;
    const std::string sample = Utf8(arguments[2]);
    const char* command[] = {"loadfile", sample.c_str(), nullptr};
    const int loaded = api.command(session.handle(), command);
    if (loaded < 0) throw std::runtime_error(api.error_string(loaded));
    const auto started = std::chrono::steady_clock::now();
    const uint64_t initial_cpu = ProcessTime();
    bool end_file_error = false;
    bool file_loaded = false;
    while (std::chrono::steady_clock::now() - started < std::chrono::seconds(duration)) {
      window.Dispatch();
      const auto* event = api.wait_event(session.handle(), 0.01);
      if (event->event_id == MPV_EVENT_LOG_MESSAGE) {
        const auto* log = static_cast<mpv_event_log_message*>(event->data);
        if (LogSignal(*log)) {
          std::cout << "SIGNAL " << log->prefix << " " << log->level << " " << log->text;
        }
      } else if (event->event_id == MPV_EVENT_FILE_LOADED) {
        file_loaded = true;
      } else if (event->event_id == MPV_EVENT_END_FILE) {
        const auto* ended = static_cast<mpv_event_end_file*>(event->data);
        end_file_error = ended->error < 0 || ended->reason == MPV_END_FILE_REASON_ERROR;
        std::cout << "END_FILE reason=" << ended->reason << " error=" << ended->error
                  << std::endl;
        break;
      }
    }
    const double elapsed = std::chrono::duration<double>(
        std::chrono::steady_clock::now() - started).count();
    const double cpu_one_core = static_cast<double>(ProcessTime() - initial_cpu) /
                                (elapsed * 10000000.0) * 100.0;
    SYSTEM_INFO system_info{};
    GetSystemInfo(&system_info);
    const std::string position = session.Property("time-pos");
    const std::string active_hwdec = session.Property("hwdec-current");
    const std::string current_vo = session.Property("current-vo");
    std::cout << "RESULT gpu=" << gpu_api << " requestedHwdec=" << requested_hwdec
              << " activeHwdec=" << active_hwdec << " interop=" << session.Property("hwdec-interop")
              << " currentVo=" << current_vo << " videoFormat=" << session.Property("video-format")
              << " hwPixfmt=" << session.Property("video-dec-params/hw-pixelformat")
              << " position=" << position << " frameDrops=" << session.Property("frame-drop-count")
              << " decoderDrops=" << session.Property("decoder-frame-drop-count")
              << " cpuMachinePercent=" << cpu_one_core / system_info.dwNumberOfProcessors
              << " elapsed=" << elapsed << std::endl;
    const bool progressed = position != "unavailable" && std::stod(position) >= duration * 0.35;
    const bool hardware = active_hwdec != "no" && active_hwdec != "unavailable" && !active_hwdec.empty();
    const bool exact_backend = requested_hwdec == "auto" || requested_hwdec == "auto-copy" ||
                               active_hwdec == requested_hwdec;
    const bool passed = file_loaded && !end_file_error && current_vo == "gpu-next" &&
                        progressed && exact_backend && (requested_hwdec == "no" || hardware);
    std::cout << "VERDICT " << (passed ? "PASS" : "FAIL") << std::endl;
    return passed ? 0 : 1;
  } catch (const std::exception& error) {
    std::cerr << "PROBE_ERROR " << error.what() << std::endl;
    return 2;
  }
}
