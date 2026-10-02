The project uses the Flutter version declared in `.fvmrc`. After installing FVM and the Android SDK or Visual Studio, use these commands to fetch Dart packages, apply the Flutter source patches, and build:

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

The Android entry point uses a short project-local temporary directory to avoid Gradle loopback failures on some Windows setups. HTTP(S) proxy settings are passed from `HTTP_PROXY`/`HTTPS_PROXY` to Gradle.

Regenerate the JNI bindings with:

```powershell
fvm dart run tool/jnigen.dart
```

Trace a running Windows debug build during a danmaku stress test:

```powershell
pwsh -File tool/trace-windows.ps1 -ProcessId 12345 -DurationSeconds 180
```

The script prints peak process memory and writes a CSV with CPU and GPU process memory samples to the Windows temporary directory. GPU fields stay empty when Windows does not provide those counters.

For short memory spikes, use `-IntervalMilliseconds 250 -SkipGpuCounters`.
`ProcessPeakWorkingMiB` records the Windows working-set peak since process startup,
including spikes between samples.

For built-in release diagnostics, open **About → Performance tracing**.

## Hardware decoder fallback

Windows and Android hardware decoding uses an ordered candidate list. Automatic
settings first let mpv select a decoder, then try platform-specific decoders in
efficiency order. Explicit decoder settings keep their configured order.

The complete list is passed to mpv, which handles initialization and runtime
fallback for each media. The player reapplies the latest settings before opening
media. Software decoding (`hwdec=no`) is the final fallback; an explicit `no`
keeps its configured position. The application does not reopen media on decoder
errors or cache failed backends across media.

Windows libmpv is pinned to the 20260819 build in
`third_party/media_kit_libs_windows_video`. It includes the FFmpeg fix for D3D12
reference-only resource pool exhaustion. CMake verifies the archive and DLL with
SHA256 and replaces stale build outputs. The AMF and D3D12 non-copy modes still
require renderer interop support; use a compatible copy mode or automatic
selection. Performance traces include the loaded mpv/FFmpeg versions and
`video-format`, alongside the requested and active hardware decoders.

After a Windows build, verify the bundled DLL, stale-cache replacement,
repeat configuration, and rejection of a corrupt archive:

```powershell
pwsh -File tool/verify-windows-libmpv.ps1 -Configuration Debug
```

Use `-Configuration Release` for the release bundle. This check uses the downloaded
archive in the build directory and discovers CMake from `CMakeCache.txt`.

## Vulkan GPU probe

The Windows Vulkan probe is an isolated native test. It does not change the
application's `media_kit_video` output path. Compile it from a Visual Studio
developer shell:

```powershell
cl /nologo /EHsc /std:c++20 `
  /IE:/Code/project/PiliAurora/build/windows/x64/libmpv/include `
  tool/windows_gpu_probe.cpp `
  /link user32.lib /OUT:build/windows/x64/runner/Debug/windows_gpu_probe.exe
```

Check whether the bundled libmpv exposes a Vulkan Render API:

```powershell
build/windows/x64/runner/Debug/windows_gpu_probe.exe `
  build/windows/x64/runner/Debug --render-api-check
```

The expected result for the current libmpv build is `result=-19` because its
public Render API exposes OpenGL and software output, not Vulkan. Vulkan output
is tested through mpv's `gpu-next` Win32 window path instead:

```powershell
build/windows/x64/runner/Debug/windows_gpu_probe.exe `
  build/windows/x64/runner/Debug `
  doc/dev/decoder-diagnosis-av1.m4s vulkan auto 8
```

The probe reports the Vulkan device, requested and active hardware decoder,
hardware interop, playback progress, frame drops, and a pass/fail verdict.
This path cannot be enabled in the Flutter player without replacing the
current external-texture integration: Flutter's Windows texture bridge and the
bundled media video plugin currently exchange D3D11/DXGI textures, while the
Vulkan `gpu-next` path renders to a Win32 window.
