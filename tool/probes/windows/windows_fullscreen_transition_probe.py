"""Check the runner's resize background pixels without disabling animations."""

from pathlib import Path
import subprocess


MAIN = r'''
#include "win32_window.h"
#include <dwmapi.h>
#include <iostream>

// DWM exposes this attribute as set-only; intercept the call while forwarding
// to the real API so the probe also exercises the Windows implementation.
static bool transitions_disabled = false;
extern "C" HRESULT ProbeDwmSetWindowAttribute(
    HWND window, DWORD attribute, LPCVOID value, DWORD size) {
  const auto result = DwmSetWindowAttribute(window, attribute, value, size);
  if (attribute == DWMWA_TRANSITIONS_FORCEDISABLED) {
    transitions_disabled = SUCCEEDED(result) &&
        *static_cast<const BOOL*>(value) != FALSE;
  }
  return result;
}

int main() {
  Win32Window window;
  if (!window.Create(L"Fullscreen transition probe", {0, 0}, {640, 480})) {
    return 1;
  }
  if (transitions_disabled) {
    std::cerr << "FAIL window transitions were disabled\n";
    return 2;
  }
  auto hwnd = window.GetHandle();
  const auto style = GetWindowLongPtr(hwnd, GWL_STYLE);
  // 在白色像素夹具上执行真实窗口过程的背景擦除，避免只检查画刷配置。
  HDC dc = CreateCompatibleDC(nullptr);
  HBITMAP bitmap = CreateBitmap(640, 480, 1, 32, nullptr);
  auto previous = SelectObject(dc, bitmap);
  RECT rect{0, 0, 640, 480};
  for (const auto color : {RGB(248, 244, 239), RGB(23, 25, 29), RGB(0, 0, 0)}) {
    window.SetBackgroundColor(color);
    FillRect(dc, &rect, static_cast<HBRUSH>(GetStockObject(WHITE_BRUSH)));
    const auto erased = SendMessage(hwnd, WM_ERASEBKGND,
                                   reinterpret_cast<WPARAM>(dc), 0);
    const auto pixel = GetPixel(dc, 20, 20);
    if (!erased || pixel != color) {
      std::cerr << "FAIL resize background does not match the active theme\n";
      return 4;
    }
  }
  SelectObject(dc, previous);
  DeleteObject(bitmap);
  DeleteDC(dc);
  if (!(style & WS_CLIPCHILDREN)) {
    std::cerr << "FAIL parent background can erase the Flutter child\n";
    return 3;
  }
  for (int i = 0; i < 10; ++i) {
    SetWindowLongPtr(hwnd, GWL_STYLE, style & ~WS_OVERLAPPEDWINDOW);
    SetWindowPos(hwnd, nullptr, 0, 0, 1280, 720,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
    SetWindowLongPtr(hwnd, GWL_STYLE, style);
    SetWindowPos(hwnd, nullptr, 0, 0, 640, 480,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  }
  std::cout << "PASS light, dark and fullscreen background pixels match; Flutter children clipped\n"
            << "PASS DWM transitions remain enabled\n";
}
'''


def main():
    root = Path(__file__).resolve().parents[3]
    build = root / 'build/probe-validation/windows-fullscreen'
    build.mkdir(parents=True, exist_ok=True)
    (build / 'flutter_windows.h').write_text(
        '#pragma once\n#include <windows.h>\n'
        'inline UINT FlutterDesktopGetDpiForMonitor(HMONITOR) { return 96; }\n',
        encoding='utf-8',
    )
    # Only replace the DWM boundary. Window creation and message handling use
    # production code and real Win32 APIs; no Flutter engine is needed.
    source = (root / 'windows/runner/win32_window.cpp').read_text(encoding='utf-8')
    source = source.replace('#include <dwmapi.h>', '#include <dwmapi.h>\n'
                            'extern "C" HRESULT ProbeDwmSetWindowAttribute('
                            'HWND, DWORD, LPCVOID, DWORD);')
    source = source.replace('DwmSetWindowAttribute(window,',
                            'ProbeDwmSetWindowAttribute(window,')
    fixture = build / 'runner.cpp'
    fixture.write_text(source, encoding='utf-8')
    main_source = build / 'main.cpp'
    main_source.write_text(MAIN, encoding='utf-8')
    binary = build / 'fullscreen_probe.exe'
    subprocess.run([
        'g++', '-std=c++17', '-DUNICODE', '-D_UNICODE',
        '-static-libgcc', '-static-libstdc++',
        '-I', str(build), '-I', str(root / 'windows/runner'),
        str(fixture), str(main_source), '-ldwmapi', '-ladvapi32', '-lgdi32',
        '-o', str(binary),
    ], check=True)
    raise SystemExit(subprocess.run([str(binary)], check=False).returncode)


if __name__ == '__main__':
    main()
