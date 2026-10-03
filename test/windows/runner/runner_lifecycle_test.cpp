#include <flutter/plugin_registry.h>
#include <flutter_windows.h>
#include <windows.h>

#include <cstdio>
#include <string>
#include <vector>

#include "flutter_window.h"

int WINAPI RunnerEntryPoint(HINSTANCE, HINSTANCE, wchar_t*, int);

namespace {
bool main_case = false;
bool runner_com_released = false;
HWND test_window = nullptr;
bool callback_ran = false;
bool callback_com_ready = false;

class TestWindow : public FlutterWindow {
 public:
  using FlutterWindow::FlutterWindow;
  using FlutterWindow::OnDestroy;
};

BOOL CALLBACK FindTestWindow(HWND window, LPARAM) {
  wchar_t class_name[128] = {};
  GetClassNameW(window, class_name, 128);
  if (std::wstring(class_name) == L"FLUTTER_RUNNER_WIN32_WINDOW") {
    test_window = window;
    return FALSE;
  }
  return TRUE;
}

void OnRegistrarDestroyed(FlutterDesktopPluginRegistrarRef) {
  callback_ran = true;
  APTTYPE apartment;
  APTTYPEQUALIFIER qualifier;
  callback_com_ready = !runner_com_released &&
                       SUCCEEDED(CoGetApartmentType(&apartment, &qualifier));
  // 引擎释放插件时，真实窗口消息可重入 runner。
  SendMessageW(test_window, WM_FONTCHANGE, 0, 0);
}

int RunCase(const wchar_t* assets, const char* mode_name) {
  const std::string mode(mode_name);
  if (mode == "main-return") {
    main_case = true;
    if (RunnerEntryPoint(GetModuleHandleW(nullptr), nullptr, nullptr,
                         SW_HIDE) != 0)
      return 2;
    if (!test_window || !callback_ran || !callback_com_ready) {
      std::fprintf(stderr,
                   "FAIL main-return COM released before plugin teardown\n");
      return 1;
    }
    std::printf("PASS main-return plugin teardown with live COM\n");
    return 0;
  }
  if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 2;
  {
    flutter::DartProject project(assets);
    project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
    TestWindow window(project);
    if (!window.Create(L"Runner lifecycle regression", {0, 0}, {128, 128})) {
      std::fprintf(stderr, "FAIL engine/window creation\n");
      return 2;
    }
    test_window = window.GetHandle();
    if (mode == "font-after-destroy") {
      // OnDestroy 后、顶层 HWND 释放前，字体通知不得解引用空控制器。
      window.OnDestroy();
      SendMessageW(test_window, WM_FONTCHANGE, 0, 0);
      window.Destroy();
    } else if (mode != "scope-destroy") {
      return 2;
    }
    // scope-destroy 不先发 WM_CLOSE，覆盖提前返回时的成员析构路径。
  }
  CoUninitialize();
  if (!test_window || !callback_ran || !callback_com_ready) {
    std::fprintf(stderr, "FAIL plugin teardown callback/COM lifetime\n");
    return 1;
  }
  std::printf("PASS %s plugin teardown with live COM\n", mode.c_str());
  return 0;
}

// 捕获能到达此边界的访问冲突；Windows 回调内部的致命异常仍由进程退出码报告。
int GuardedRun(const wchar_t* assets, const char* mode) {
  __try {
    return RunCase(assets, mode);
  } __except (GetExceptionCode() == EXCEPTION_ACCESS_VIOLATION
                  ? EXCEPTION_EXECUTE_HANDLER
                  : EXCEPTION_CONTINUE_SEARCH) {
    std::fprintf(stderr, "FAIL %s access violation 0xC0000005\n", mode);
    return 1;
  }
}
}  // namespace

// 只注册测试回调，不加载任何生产插件 DLL 或 WebView 静态 COM 资源。
void RegisterPlugins(flutter::PluginRegistry* registry) {
  if (main_case) {
    EnumThreadWindows(GetCurrentThreadId(), FindTestWindow, 0);
    // 不先销毁窗口，覆盖消息循环终止后的真实 main 返回路径。
    PostQuitMessage(0);
  }
  FlutterDesktopPluginRegistrarSetDestructionHandler(
      registry->GetRegistrarForPlugin("RunnerLifecycleRegression"),
      OnRegistrarDestroyed);
}

// 入口点依赖的最小替身；实际 runner/main.cpp 仍参加编译与执行。
void WINAPI RecordCoUninitialize() {
  runner_com_released = true;
  CoUninitialize();
}

extern "C" bool SendAppLinkToInstance() { return false; }
void CreateAndAttachConsole() {}
std::vector<std::string> GetCommandLineArguments() { return {}; }

int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 2;
  const std::wstring wide_mode(argv[2]);
  std::string mode;
  for (wchar_t ch : wide_mode) mode.push_back(static_cast<char>(ch));
  const int result = GuardedRun(argv[1], mode.c_str());
  std::fflush(nullptr);
  // 故障路径可能只销毁了半个引擎；测试进程不得继续执行不完整对象的清理。
  if (result != 0) TerminateProcess(GetCurrentProcess(), result);
  return result;
}
