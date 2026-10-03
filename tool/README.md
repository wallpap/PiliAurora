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

### Local comparison on October 2, 2026

The probe used the bundled libmpv, the AV1 fixture in `doc/dev`, and one
20-second run per case. CPU is the probe process share of total machine CPU;
the numbers are not a full Flutter-page benchmark.

| Output path | Requested hwdec | Active hwdec | Interop | CPU | Result |
| --- | --- | --- | --- | ---: | --- |
| `gpu-next + d3d11` | `auto` | `d3d11va` | `d3d11va` | 0.31% | pass |
| `gpu-next + vulkan` | `auto` | `nvdec` | `cuda` | 0.76% | pass |
| `gpu-next + vulkan` | `nvdec` | `nvdec` | `cuda` | 0.74% | pass |
| `gpu-next + d3d11` | `nvdec` | `no` | unavailable | 0.68% | software fallback |
| `gpu-next + d3d11` | `amf` | `no` | unavailable | 0.50% | software fallback |
| `gpu-next + d3d11` | `d3d12va` | `no` | unavailable | 0.45% | software fallback |
| `gpu-next + vulkan` | `vulkan` | `no` | unavailable | 1.05% | software fallback |
| `gpu-next + vulkan` | `amf` | `no` | unavailable | 1.45% | software fallback |

The direct Vulkan path is therefore technically usable on this machine, but
this sample does not prove it is faster than native D3D11 output. Both direct
paths had zero decoder and presentation drops. The D3D11 path selected the AMD
adapter; the Vulkan path selected the RTX 3060. A Flutter integration must
benchmark the complete page, including texture publication and danmaku, before
changing the default backend.

## 真实弹幕播放实验

`tool/danmaku_playback_benchmark.dart` 接受运行时 `--name=value` 参数：

- 必填：`video`、`danmaku`。文件必须在本地。
- 可选：`audio`、`output`、`cache-mib`、`cache-entries`、`renderer`。
- `renderer`：`prepared`（默认）、`baseline` 或 `both`。
- `kind`：`stress`（默认）或 `lifecycle`。后者仅支持 prepared。
- 控制项：`start-ms`、`warmup-seconds`、`measurement-seconds`、`repetitions`、`telemetry-ms`、`prewarm`、`hwdec`、`label`。
- `telemetry-ms=0` 关闭周期遥测；其他取值必须不低于 100 ms。读取是同步操作，不保证零扰动。

只构建工具：

```powershell
flutter build windows --profile --no-pub --target tool/danmaku_playback_benchmark.dart
```

**完整插件集的短烟雾已正常退出；长时间及真实 WebView 页面仍未覆盖。** 工具写出
`PLAYBACK_BENCH_READY` 后保持引擎运行。该标记只表示测量和媒体释放完成，
不是进程退出成功。不要在工具中调用 `exit()` 或 `exitApplication()`。
批量工具必须验证 READY code=0、有效媒体窗口和进程退出码，不能仅以输出文件存在为成功。

`lifecycle` 的 small-viewport 仅改变应用内内容尺寸，不改变系统 DPI。
最终输出使用真实 DPR、播放器时间和匿名数量统计，不包含弹幕正文或媒体路径。
原始数据留在 `build/`；不提交媒体、账号数据或完整崩溃转储。

接手记录、故障边界和遥测语义见 `tool/reports/` 的 20261003 报告。


## Windows runner 生命周期回归

```powershell
pwsh -File tool/windows-runner-lifecycle.ps1
```

该命令构建空的 Dart fixture，再将真实 runner 与 Flutter 引擎连接到专用测试程序。
它不加载生产插件 DLL，不启动媒体或 WebView。覆盖字体通知、析构重入和 COM 清理顺序。
首次构建后，若 Profile 入口未改变，可使用 `-SkipFlutterBuild` 快速重复测试。
CMake 可通过 `-CMake` 指定；默认复用 Flutter 构建中记录的路径。

**fixture 会替换标准 Profile 输出。** 使用正常应用前重新构建：

```powershell
flutter build windows --profile --no-pub --target lib/main.dart
```

runner 的隔离回归通过不代表完整插件集的 `0xE0464645` 已解决。
修复证据、轨道研究及授权边界见
`tool/reports/windows-runner-repair-and-track-followup-20261003.md`。


### WebView 退出隔离与缓存对照

```powershell
pwsh -File tool/windows-runner-lifecycle.ps1 -WithWebView
```

启用生产 WebView DLL 前先测试进程本地 fail-fast 拦截器。故障时会停止该测试进程，
返回失败；不会修改 WER、注册表或终止其他应用。`webview-recreate` 覆盖三次顺序重建，
不代表跨线程或并发多 engine 已验证。

缓存对照先构建 `tool/danmaku_playback_benchmark.dart`，再运行：

```powershell
python tool/windows_playback_cache_matrix.py --video <本地视频> --audio <本地音频> --danmaku <本地弹幕> --output build/cache-matrix-new-run
```

该工具不附加调试器，先运行短烟雾，再执行 16/24/32 MiB × 预热开/关的反转顺序对照。
附加本地调试器的媒体位置曾停滞，故调试器数据只用于退出诊断，不用于性能结论。
每轮要求媒体窗口有效、READY code=0 与进程正常退出；失败立即停止。
工具只发送 WM_CLOSE 给自身 PID 的窗口，超时仅清理自身进程并判失败。
默认缓存仍为 16 MiB；新增 `evictedLayouts` / `evictedImages` / `evictedImageBytes`
区分淘汰负载，账面字节不代表已经释放的实际内存。
