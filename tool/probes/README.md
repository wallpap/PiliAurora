# 调试工具

此目录存放供维护者运行的隔离诊断工具和平台探针。这些工具不属于应用运行时或正式构建流程。

| 目录 | 内容 |
| --- | --- |
| `android/` | 暂停旋转测试入口、画面检查脚本和 Java 帧栅栏检查。 |
| `windows/` | 窗口回调、尺寸通道、纹理首帧和输出确认探针。 |
| `playback/` | 媒体加载烟测、跳转命令、会话验收与 Windows 超分切换。 |
| `event_loop/` | 事件循环生命周期、ABI 检查与配套 C++ mock。 |

运行前查看脚本参数和源码，确认目标平台、输入文件及输出目录。工具结果只覆盖它实际检查的内容；应用行为还要按[构建与测试说明](../../doc/build-and-test.md)在目标平台验证。

Python 探针使用 uv 环境，首次运行前请按[工具入口中的 Python 环境说明](../README.md#python-工具环境)初始化；以下命令均从仓库根目录运行。

## 事件循环生命周期探针

`event_loop/native_event_loop_probe.dart` 使用纯 Dart 桩检查生命周期、关闭顺序和 ABI 选择：

```powershell
fvm dart tool/probes/event_loop/native_event_loop_probe.dart
```

`native_event_loop_abi_probe.dart` 与同目录的 `native_event_loop_abi_mock.cc` 配套，检查 mock DLL 的真实 FFI 调用和 isolate 事件借用生命周期。

Windows 上使用 `g++` 编译两种 ABI 的 mock，再交给 Dart 入口。下面的头文件路径由 Windows 构建准备：

```powershell
New-Item -ItemType Directory -Path build/probe-validation/event_loop -Force | Out-Null
g++ -shared -std=c++17 -O0 -static-libgcc -static-libstdc++ -I build/windows/x64/libmpv/include tool/probes/event_loop/native_event_loop_abi_mock.cc -o build/probe-validation/event_loop/registered_mock.dll
g++ -shared -std=c++17 -O0 -static-libgcc -static-libstdc++ -DMOCK_LEGACY_ABI -I build/windows/x64/libmpv/include tool/probes/event_loop/native_event_loop_abi_mock.cc -o build/probe-validation/event_loop/legacy_mock.dll
fvm dart tool/probes/event_loop/native_event_loop_abi_probe.dart build/probe-validation/event_loop/registered_mock.dll build/probe-validation/event_loop/legacy_mock.dll
```

## 原生媒体加载烟测

Windows 构建完成后，可用 Python 和 libmpv 检查独立音轨、特殊字符路径和媒体重载。
传入数秒以上的本地视频即可运行；工具不访问网络，并将测试用静音 WAV 写入 `build/native-playback-smoke/`。

```powershell
uv run --locked python tool/probes/playback/native_media_smoke.py --library build/windows/x64/runner/Debug/libmpv-2.dll --video <本地视频文件>
```

同一命令追加 `--audio-reload`，可验证后台音轨重连时音频时钟恢复、视频继续输出新帧，且媒体位置和暂停状态保持。输入需为超过 3 秒的连续视频；画面与声音在实机上检查。

传入 `--seek-target <秒数>` 可检查 Android 独立音轨的前进、后退和重复跳转命令。`tool/probes/playback/native_seek_command.dart` 会调用应用使用的命令构造器；烟测检查视频恢复后音轨等待是否小于 100 ms。视频长度应超过目标时间，目标时间应落在关键帧之间。`--keyframes-control` 使用旧策略作对照，预期会触发静音断言。

```powershell
uv run --locked python tool/probes/playback/native_media_smoke.py --library build/windows/x64/runner/Debug/libmpv-2.dll --video <本地视频文件> --seek-target 2.4
```

该检查通过 Windows libmpv、`vo=null`、`ao=null` 和软件解码运行，视频帧依据 mpv 的 trace 日志计数，覆盖 Windows 软件解码这一条路径。Android GPU/MediaCodec、扬声器输出和完整应用性能由对应平台验收，画面和硬件解码在目标设备上验证。

## 暂停旋转探针

`paused_rotation.dart` 使用本地视频检查暂停后横屏、竖屏和再次横屏时的整帧显示。配套的 `paused_rotation_probe.py` 会检查四象限、视频白边和暂停状态。输入文件应使用对应的测试图视频。

入口使用当前 Android 固定 Surface 策略，旋转由 Flutter 的 `FittedBox` 缩放画面。硬件解码关闭，默认不限制源纹理尺寸；构建时传入 `--dart-define=ANDROID_TEXTURE_SCALING=true` 可启用设备物理显示尺寸限幅，与应用的纹理缩放开关对应。

```powershell
fvm flutter build apk --debug --target tool/probes/android/paused_rotation.dart --no-pub
uv run --locked python tool/probes/android/paused_rotation_probe.py --adb <adb路径> --serial <emulator序列号> --apk build/app/outputs/flutter-apk/app-debug.apk --fixture <四象限测试视频>
```

探针会安装调试 APK、推送测试视频并清空目标模拟器日志，因此应使用独占的测试模拟器。输出默认保存在 `build/rotation-smoke/`。退出码 0 表示三个阶段通过，1 表示旋转检查失败，2 表示初始画面无效或检查未完成。该工具不检查旋转过程中的逐帧黑闪。

使用 `--dart-define=CREATE_ROTATION_FIXTURE=true` 构建入口可显示测试图，再通过模拟器 `screenrecord` 录制 H.264 视频。确认四象限和白边完整，并排除系统弹窗干扰。交付应用前需用默认入口重新构建。

## Android 主机帧调度探针

准备项目依赖、PATH 中的 JDK 25 与 Python 3 后运行：

```powershell
pwsh -NoProfile -File tool/run-native-probes.ps1
```

入口从项目依赖配置定位 `.fvmrc` 固定版本的 Flutter SDK，编译其真实 `SurfaceTextureWrapper.java`，依次执行六个主机 JVM 探针：

- `SurfaceFrameFenceProbe`：生产帧栅栏的时间戳、尺寸和 Surface 代次条件。
- `VideoFrameSamplesProbe`：请求时间缓冲的 32 个样本上限、微秒转换、批次提取和 Surface 重置清理。
- `OutputOperationGateProbe`：生产输出代次门控的永久撤销、迟到等待/开始拒绝和代次高水位。
- `VideoSurfaceTextureProbe`：生产 listener 完成后采样、回调转发、Handler、注销和消费确认。
- `VideoSurfaceTextureRequestProbe`：真实 Flutter wrapper 的 monitor 竞争，交替 0/9ms 取图锁等待计入请求样本。
- `VideoSurfaceTextureAcquireProbe`：30 FPS 视频叠加 120 FPS 重绘时取图 30 次，并检查暂停恢复、通知合并、异常重试、关闭采样和上下文重建；请求探针另检查取图期间的新通知不会丢失。

入口随后运行 `android/video_output_release_probe.py`：从生产 `VideoOutput.java` 提取释放及回执方法，编译到主机 JVM 夹具，检查 JNI 删除后的即时回执、重复释放、无引用输出和 JNI 删除失败。该探针使用 Python 标准库，产物在 `build/probe-validation/android-release/`；它不执行真实 JNI 或 GPU。

`android/video_output_surface_creation_probe.py` 提取同一生产类的 Surface 重建与释放方法，检查旧 Surface／JNI 引用释放失败时终止重建、保留旧句柄，以及故障解除后的完整释放；另覆盖新 Surface 构造失败、JNI 引用创建失败或返回零、回滚释放失败和重试恢复。产物在 `build/probe-validation/android-surface-creation/`，支持 `--source` 指定生产源码用于对照。

缺失 SDK 源码、编译或断言失败均返回非零退出码；产物留在 `build/probe-validation/android/`。Android 桩位于探针目录，不加入生产编译。探针不创建 GL、原生 Surface 或真实消息循环，也未模拟 platform/UI 合并线程的全部行为。采样顺序与 monitor 等待由主机检查，平台 API 由 Android 构建检查，实际 Scene 与呈现由目标设备检查。

## Android 帧时间采集

`android/frame_timing_capture.py` 读取指定应用的 SurfaceFlinger 图层和 gfxinfo 帧时间。启动目标应用播放固定片段、开启性能记录并准备相同弹幕密度后运行：

```powershell
uv run --locked python tool/probes/android/frame_timing_capture.py --adb <adb路径> --serial <设备序列号> --package io.github.wallpap.piliaurora.debug --seconds 10
```

省略 `--layer` 时优先选择包名对应的唯一 SurfaceView BLAST 缓冲图层，其余情况选择唯一 SurfaceView；自动选择排除带 `!handle` 的已销毁图层，多个活动缓冲图层需显式指定。Android 16 的 `RequestedLayerState{...}` 列表先提取实际 `name#id`，`--layer` 接受该名称或列表中的原始行。Release 包名为 `io.github.wallpap.piliaurora`，应与被测构建一致。采集命令为 `dumpsys SurfaceFlinger --list`、`--latency <layer>` 及 `dumpsys gfxinfo <package> framestats`；不安装 APK、不重置统计、不清理日志、不修改设备配置。

输出默认位于 `build/android-frame-timing/<UTC时间>.json`，可传 `--output` 指定不存在的文件。工具排除初始缓冲区中的已完成帧、重复行、零值和未完成 fence，保存数值行与图层摘要，不保存设备序列号、原始图层名或 dumpsys 文本。SurfaceFlinger 三列依次为期望呈现、实际呈现和帧就绪的纳秒时间，定义见 [AOSP FrameTracker](https://android.googlesource.com/platform/frameworks/native/+/878911f7df21c700ddbe9e9c9d28cd0a1776946f/services/surfaceflinger/FrameTracker.cpp#240)。gfxinfo 按输出表头提取 `Flags`、`IntendedVsync`、`Vsync`、`FrameCompleted`。

窗口范围 1–60 秒，每 500ms 读取一次，每来源最多保存 16384 条新记录。无新记录或达到上限时返回非零退出码；某个来源为空时结合输出中的行数判断系统支持。主机耗时用于控制采集窗口，设备时间保持原始时钟域。图层帧时间与 Android View 帧时间分别记录；Flutter Surface、纹理刷新、UI 帧和 Scene 使用不同口径。工具不会据这些数值自动判定“稳定 60”。读取开销、Android 版本兼容性和实际帧率需要目标设备验证。

解析、窗口去重、输出筛选和命令参数测试可在无设备时运行：

```powershell
uv run --locked python -m unittest discover -s tool/probes/android -p '*_test.py' -v
```

## Android 高刷呈现探针

`android/high_refresh.dart` 使用真实 Canvas 弹幕，在同一组本地弹幕上依次运行 120、90、60 FPS。每段先等待 3 秒，首段确认轨道与弹幕加入成功，再测量 7 秒，不读取账号或媒体，也不访问网络。使用独立 `.profile` 包运行：

```powershell
fvm flutter run --profile --no-pub -d <设备ID> -t tool/probes/android/high_refresh.dart
```

控制台 `SCENE-HIGH-REFRESH` 输出弹幕实际更新频率、Flutter 上报帧频率与平均 Build/Raster 耗时。Flutter timing 延迟批量回报，窗口边界可能有偏差；这些计数是 Flutter 上报口径，Scene 和最终呈现看 `frame_timing_capture.py` 采集的 SurfaceFlinger 数值帧时间。存在多个匹配图层时显式传入 `--layer`；优先检查具有实际 BufferQueue 帧记录的 Flutter 输出图层。

## Android 播放慢帧对照

`android/playback_jank.dart` 在本地媒体上依次测量 90、120、60、跟随屏幕四档弹幕。视频首帧呈现后开始，每档稳定 4 秒、测量 8 秒；`PILI_JANK` 输出更新频率、Raster 均值/P95/最大值、屏幕周期超预算计数和锁相状态。探针不初始化应用账号或诊断日志。使用独立 `.profile` 包，素材须为该应用可读取的本地文件；可在包已安装后用 `adb push` 和 `run-as io.github.wallpap.piliaurora.profile cp` 将素材放入其 `cache/`。

```powershell
fvm flutter run --profile --no-pub -d <设备ID> -t tool/probes/android/playback_jank.dart --dart-define=JANK_MEDIA_URI=file:///data/user/0/io.github.wallpap.piliaurora.profile/cache/jank-fixture.mp4
```

仅在首帧等待成功且 `scheduler.nativePeriodUs` 有有效视频周期时，将结果作为视频播放测量。FrameTiming 批量回报造成边界偏差；超预算计数与 Scene 呈现帧数应分别解释。首次安装时可先构建并安装 profile 包，再复制素材、启动探针。

追加 `--dart-define=JANK_RASTER_AFFINITY_ABA=true` 可在同一视频、60 FPS 弹幕下依次测量原始 Raster CPU 集合、应用可用集合、恢复原始集合。探针复用生产 `AndroidRasterScheduling`，每段记录 `startedUs/endedUs` 和实际 CPU 集合，结束及卸载时恢复。该模式需要 Android 上唯一、可扩展亲和性的 Raster 线程。它改变独立 profile 进程的线程调度，按实际设备结果评价耗时和呈现。

同时采集 SurfaceFlinger 和 Perfetto，按单调时钟截取三段测量窗口。Perfetto 配置使用 `write_into_file: true`、`file_write_period_ms: 1000`，并检查 `traced_buf_bytes_overwritten`；环形缓冲覆盖与文件传输完整是不同的检查项。将 FrameTiming、更新频率和最终呈现间隔分别比较，24 FPS 视频与 60 FPS 弹幕混合产生的图层帧数不代表弹幕更新数。

## Windows 弹幕帧节奏探针

`windows/danmaku_frame_pacing.dart` 在独立可见窗口中运行生产点播与直播弹幕组件，
分别输入 12 条和 60 条滚动／顶部／底部混合弹幕。每组预热后采样 10 秒，
记录帧目标间隔、活动数量、逐帧位移、Build/Raster 耗时和窗口状态。
探针不初始化账号或访问网络。

```powershell
pwsh -NoProfile -File tool/probes/windows/measure_danmaku.ps1 -PresentMonPath E:/tools/PresentMon-2.5.1-x64.exe
# 叠加本地视频的 mpv/ANGLE 纹理负载，音频输出为 null；复用刚构建的探针。
pwsh -NoProfile -File tool/probes/windows/measure_danmaku.ps1 -PresentMonPath E:/tools/PresentMon-2.5.1-x64.exe -Media E:/media/fixture.mp4 -SkipBuild
# 对已有采集重复执行关联与汇总，无需重新启动应用。
python tool/probes/windows/danmaku_frame_pacing_analysis.py build/my-run/probe.json build/my-run/presentmon.csv --output build/my-run
```

采集入口默认构建 Profile 探针，使用独立 ETW session 按进程 ID 采集 PresentMon
v1 QPC CSV，等待数据写入后自动执行同帧关联与汇总。默认目录为
`build/windows-danmaku-validation/时间戳/`；`-OutputDirectory` 可指定尚未存在的目录。
`-SkipBuild` 要求 Profile 目录当前就是此探针。PresentMon 使用官方独立命令行工具
（已验证 2.5.1），无需安装服务；采集失败时查看目录内的 stdout/stderr。
`-EngineLibrary <flutter_windows.dll>` 可对照[固定自编引擎](../engine/windows_frame_pacing/README.md)，
入口核对身份文件、所选构建模式、x64 架构和摘要，并将身份文件保存在采集目录。

`-Mode release` 使用 Release 应用与同模式引擎，可直接验证正式预编译引擎。
两端的完整复测流程见[弹幕实机复测](danmaku/README.md)。

探针窗口临时置顶，并确认实际可见；测量时避免其他置顶窗口遮挡它。
Windows 隐藏启动和窗口完全遮挡会影响帧交付，须结合报告里的窗口状态解释数据。
四组都有活动弹幕、帧频达到屏幕刷新率的 95%，且超过 1.5 个屏幕周期的间隔少于 1%
时，`probe.json` 的调度检查通过。处理脚本按 QPC 校准、Flutter 帧编号及 Raster
时间段唯一关联 PresentMon 呈现事件，再复用
`tool/experiments/danmaku/presentation_continuity_analysis.py` 的 ±1/±2/±3（3/5/7 帧）分析。
未匹配、重复、歧义和未显示的帧不补点；缺帧中断窗口。
最终判定要求已显示关联率 ≥95%、全部显示事件覆盖率 ≥99%，三个半径均有完整窗口，速度 RMS P95 ≤10%，
含单步速度偏差超过 10% 的窗口比例 <1%。失败返回非零退出码。

原始数据为 `probe.json`、`presentmon.csv`；`presentation-stage-*.json` 保存同帧关联，
`continuity-stage-*.json` 保存完整局部窗口、跨帧跨度及差分，
`summary.json`、`summary.csv`、`summary.md` 汇总各场景、三个窗口半径及实际 `PresentMode`。
点播使用持续有效的合成媒体时钟；可选视频检查合成负载，不覆盖真实媒体时钟校准或超分。
完成后按[构建与测试](../../doc/build-and-test.md#构建)重新构建普通应用入口。

关联、覆盖率与连续性判定的回归可独立运行：

```powershell
uv run --locked python -m unittest discover -s tool/probes/windows -p danmaku_frame_pacing_analysis_test.py -v
uv run --locked python -m unittest discover -s tool/experiments/danmaku -p presentation_continuity_analysis_test.py -v
```

## Windows 尺寸通道回归探针

`windows_source_size_channel_probe.py` 使用 Flutter 的标准编码器和生产通道处理代码，验证 int32、int64 尺寸均能传入播放器。先完成 Windows 构建以生成 Flutter C++ 头文件，再运行：

```powershell
uv run --locked python tool/probes/windows/windows_source_size_channel_probe.py
```

需要 Python 和支持 C++17 的 `g++`，可用 `--compiler` 指定编译器。输出保存在 `build/windows-playback-diagnosis/`。探针使用模拟播放器，验证命令与时序；GPU 和实际视频播放在应用内检查。

## Windows 开播纹理回归探针

`windows_playback_startup_probe.py` 提取生产视口的尺寸提交方法，使用真实的截图交接和帧确认类，验证已配置的同尺寸输出在帧统计延迟时保持活画面、真实尺寸变化仍等待对应的渲染帧。

```powershell
uv run --locked python tool/probes/windows/windows_playback_startup_probe.py
uv run --locked python tool/probes/windows/windows_texture_frame_probe.py --compiler <g++路径>
```

前者通过 FVM 运行 Flutter 测试；后者编译生产纹理方法，检查初始纹理、有效首帧和同尺寸提交。生成文件位于 `build/windows-playback-diagnosis/`，GPU 和播放器通道由模拟对象替代。

## Windows 硬解画面采样探针

`windows_video_sampling_probe.py` 使用本机 ANGLE、libmpv 和真实 GPU 解码帧，读取 media_kit 的生产渲染参数及应用初始化中的 Windows 参数，检查画面底部连续的绿色条带。先构建 Windows Release，再传入曾出现条带的本地 AV1／HEVC 片段：

```powershell
uv run --locked python tool/probes/windows/windows_video_sampling_probe.py --video <本地视频文件>
```

默认使用 `build/windows/x64/runner/Release/` 下的 DLL，以 `d3d11va` 解码并输出 `1920×1080`。可用 `--library-dir`、`--width`、`--height` 指定构建目录和输出尺寸；`--output-dir` 默认是 `build/windows-video-sampling/`，保存最后一帧 PNG、实际解码器日志与逐帧绿色行数 JSON。

追加 `--control-dumb-mode=auto` 可对照修复前的自动简化渲染模式。退出码 0 表示 16 个采样帧均无绿色边带且实际使用指定硬解器；检测到条带、帧不足或硬解回退会退出 1。输入需有至少 20 帧，画面底部应有正常内容，避免原片自身纯绿色边带造成误判。探针只打开本地视频，不访问网络或账号，覆盖 mpv／ANGLE 的像素输出；Flutter 合成、控件、全屏切换和长期性能在应用内实测。

## Windows 直播首帧探针

`playback/windows_live_startup.dart` 使用实际 Flutter、ANGLE 与 libmpv，按直播的
“暂停加载 → 开始播放 → 挂载控件”顺序检查首次播放和刷新。断言纹理包含有效像素、
没有 libmpv 渲染错误、D3D11 硬解保持启用；设置 `expectAudio` 时还检查音频时间推进。
探针使用 `ao=null`，扬声器声音需另外验证。

在 `build/` 下准备 UTF-8 JSON 清单，样片应有可见内容；直播流须在测试期间有效。
地址从清单读取，签名地址不要写入构建参数或提交到仓库。可分别加入 HEVC/AVC 直播、
本地视频，以及带 `width`、`height` 的固定输出对照：

```json
[
  {"source": "E:/media/sample.mp4", "expectAudio": true},
  {"source": "E:/media/sample.mp4", "width": 1920, "height": 1080}
]
```

```powershell
fvm flutter build windows --debug --no-pub --target tool/probes/playback/windows_live_startup.dart --dart-define=LIVE_STARTUP_INPUT=<清单绝对路径> --dart-define=LIVE_STARTUP_OUTPUT=<报告绝对路径>
& build/windows/x64/runner/Debug/PiliAurora.exe
```

报告记录各媒体首次播放与刷新的像素范围、渲染错误数、实际解码器和音频时间推进结果，
不记录媒体地址。像素断言会将纯黑或纯色内容判为失败，使用可见且有颜色变化的样片。
结束后按[构建与测试](../../doc/build-and-test.md#构建)重新构建应用默认入口。

## 暂停加载输出挂接探针

`playback/paused_output_attach.dart` 使用当前播放器和原生视频控制器，在
`open(play: false)` 后保持暂停，检查匹配的 `FILE_LOADED` 身份、轨道/几何快照、
输出确认及当前 token 的 attach 回执。探针不调用 `play()`、不初始化账号；JSON
报告不记录输入路径。Windows 使用本机可见内容的视频文件：

```powershell
fvm flutter build windows --debug --no-pub --target tool/probes/playback/paused_output_attach.dart --dart-define=PAUSED_OUTPUT_MEDIA=E:/media/fixture.mp4 --dart-define=PAUSED_OUTPUT_REPORT=build/player-refactor-validation/paused-output-windows.json
& build/windows/x64/runner/Debug/PiliAurora.exe
```

Android 使用独立 profile 包。先将本地样片放到模拟器共享存储，再授权该探针包读取视频：

```powershell
adb push build/jank-fixture/fixture.mp4 /sdcard/Movies/paused-output-fixture.mp4
adb shell pm grant io.github.wallpap.piliaurora.profile android.permission.READ_MEDIA_VIDEO
fvm flutter run --profile --no-pub -d emulator-5554 -t tool/probes/playback/paused_output_attach.dart --dart-define=PAUSED_OUTPUT_MEDIA=file:///storage/emulated/0/Movies/paused-output-fixture.mp4 --dart-define=PAUSED_OUTPUT_REPORT=build/player-refactor-validation/paused-output-android.json
```

`passed` 要求文件身份和完整视频轨快照已知、输出策略为 `prepared` 或 `legacyAttached`，
且检查时仍暂停。Android 的 `preloadedEvidence` 可显示是否在 decoder 前配置了 Surface；
Windows 的 `nativeTextureAttachReceipt` 表示该 load token 已收到原生纹理挂接确认。
本探针验证 paused-open 协议和原生输出回执，不判定画面像素、MediaCodec/GPU 画质或扬声器音频。

## 生产会话设备验收

`playback/session_device_acceptance.dart` 通过生产 `PlaybackSession` 和
`NativePlaybackRuntime` 检查暂停加载、纹理像素、播放与音频时间推进、暂停 seek、
独立音轨、连续加载取代、解码器与音频模式切换、短时稳定播放和真实释放。
输入为本地样片，不读取账号；音频输出使用 `ao=null`。

构建时传入 `DEVICE_MEDIA`、`DEVICE_REPORT`；可选 `DEVICE_AUDIO`（独立音轨）、
`DEVICE_SHADER`（Windows 本地 shader）、`DEVICE_SOAK_SECONDS`（默认 60 秒）和
`DEVICE_SEEK_MS`（暂停 seek 目标，默认 2400 毫秒）。Android 单视频沿用关键帧跳转策略，
应先用 `ffprobe` 确认样片关键帧，再将 `DEVICE_SEEK_MS` 设为对应时刻。
探针等待 seek 完成后核对位置，并检查播放时采样激活、暂停 seek 后相位样本清空。
Android 可使用独立 debug 包，将样片及报告置于该包的外部私有 `files/` 目录，
无需授予共享媒体权限；外部目录受设备限制时，可用 `run-as` 将样片及报告放到
debug 包的内部 `cache/`，并同步修改构建参数中的路径。
报告旁的 `<报告路径>.config.json` 支持以下运行配置，
修改配置后重新启动探针即可复测：

```json
{"rapidOnly": true, "rapidCount": 2}
```

`rapidOnly` 运行暂停加载、加载取代、取代后的再次加载与播放、像素及释放检查；
`rapidCount` 默认 10，`rapidIntervalMs` 默认 15，可调整间隔覆盖不同取消时机。
模拟器缺少对应硬解器时，可设置 `"decoder": "no"` 验证软件解码的会话行为；
这类报告不覆盖 MediaCodec/D3D11VA 或软硬解切换。
设置 `{"skipRapid": true, "soakSeconds": 60}` 可独立验证其他场景，避免取消失败影响后续结果。
报告记录失败阶段、命令结果、原生 playlist/idle 事实与像素范围，逐项落盘；
最终 `passed` 要求所选场景全部通过。直播 shader 场景使用本地媒体配合直播时间线策略，
真实直播、扬声器音频、旋转、DPI 和长期性能需分别验证。完成后恢复默认应用入口。

设置 `{"diagnosticReplayOnly": true}` 可运行诊断错误回放：向播放器的诊断流注入损坏包、
解码回退日志，检查会话仍为 ready、暂停/播放有效、时间线和纹理像素正常；随后加载一个
不存在的本地文件，要求带文件身份的原生 end-file error 在 5 秒内返回失败，并验证再次加载可用。
该模式回放错误通知的处理路径，网络包损坏及设备解码错误仍需相应媒体和设备复验。

设置 `{"mountAfterLoad": true, "switchSources": ["http://127.0.0.1:8765/live.flv", "http://127.0.0.1:8765/live.m3u8"]}`
可检查加载完成后才挂载视频控件、连续切换来源及 Windows 窗口大小变化。该模式使用直播时间线，
运行初次暂停加载、清单中每一次切换和资源释放；除音视频时间推进外，还要求两次纹理采样的
指纹不同。样片需持续运动并含音轨，静态画面不适用于运动断言。HTTP 服务由运行者准备，
签名地址保存在本地配置中。这里的候选切换不经过直播页面的线路选择逻辑。

设置 `{"startupOnly": true, "mountAfterLoad": true}` 可单独检查暂停加载与释放。
Windows 的 ready 结果要求输出纹理已符合屏幕限幅，避免页面挂载后再次调整初始尺寸；
报告的 `initialOutput` 保留预期尺寸与实际纹理尺寸。

## Windows 独立播放窗口验收

`playback/desktop_window_acceptance.dart` 使用生产 IPC、子进程启动、播放页面和原生纹理，
检查小窗画面持续更新、启动 ready 回执，以及视频暂停后重载保持暂停。
主进程在报告目录的 `window-host/` 创建独立空账号存储和样片副本，不读取当前应用账号。
使用持续运动、含音轨且超过 20 秒的 MP4 样片：

```powershell
fvm flutter build windows --debug --no-pub --target tool/probes/playback/desktop_window_acceptance.dart --dart-define=WINDOW_PROBE_MEDIA=E:/media/fixture.mp4 --dart-define=WINDOW_PROBE_REPORT=E:/Code/project/PiliAurora/build/window-validation/window.json
& build/windows/x64/runner/Debug/PiliAurora.exe
```

默认验证本地下载视频。在线视频可在 `<报告路径>.config.json` 中设置
`{"onlineBase": "http://127.0.0.1:8765"}`，并在另一终端从报告目录启动本地 HTTP 服务：

```powershell
python -m http.server 8765 --bind 127.0.0.1 --directory build/window-validation
```

探针替换 Dio 的业务 API 响应，让生产页面查询本地 HTTP 视频；媒体下载仍由原生播放器执行。
简单 HTTP 服务需使用 faststart MP4，可通过 FFmpeg 的 `-c copy -movflags +faststart` 准备。

设置 `{"liveBase": "http://127.0.0.1:8765", "lineSwitchOnly": true}` 可验证直播页面的六次线路切换。
服务根目录须提供 H.264/AAC `live.flv` 和 fMP4 HLS `live.m3u8` 及其分片；省略
`lineSwitchOnly` 时交替切换 FLV/HLS。候选线路使用同一本地服务的不同查询参数，
不覆盖远端 CDN 差异、断流或真实直播时间戳异常。

报告记录会话、页面挂载、解码器和纹理像素摘要；子进程额外生成 `<报告路径>.child.json`。
子进程在 bootstrap 后采样前 6 秒，要求开始播放后的纹理几何不再变化、不进入截图交接，
且窗口不会在视频纹理出现前可见。采样间隔为 50ms，不覆盖小于此间隔的显示变化。
设置 `"captureMenus": true` 会在主进程生成浅色与深色主题下的菜单预览 PNG，
并记录菜单正文实际继承的文字颜色；预览使用独立存储和合成背景。
这些检查不代表发布版切换耗时、扬声器声音或真实网站接口验收。完成后恢复默认应用入口。

## Windows 超分切换探针

`playback/session_paused_load.dart` 通过生产 `PlaybackSession` 和
`NativePlaybackRuntime` 验证暂停加载、同内容重载与真实资源释放。
使用上述 `PAUSED_OUTPUT_MEDIA` 和 `PAUSED_OUTPUT_REPORT` 参数并替换 target；
可增加 `--dart-define=SESSION_SHADER=<本地 glsl 文件绝对路径>`，检查直播时间线策略下
shader 切换和清除均重载、保留暂停意图。输入仍是本地样片，这项检查不代表真实直播网络验收。

`playback/windows_shader_switch.dart` 使用实际 Flutter、ANGLE 与 libmpv 检查 shader 切换、纹理更新、硬解、暂停状态、音频时间线和私有内存。先确认[mpv 预编译包](../../third_party/mpv/README.md)完整，并准备含音轨的本地视频，再构建专用入口：

```powershell
fvm flutter build windows --debug --no-pub --target tool/probes/playback/windows_shader_switch.dart --dart-define=SHADER_PROBE_ROOT=<仓库绝对路径> --dart-define=SHADER_PROBE_VIDEO=<本地视频绝对路径> --dart-define=SHADER_PROBE_OUTPUT=<输出目录绝对路径>
& build/windows/x64/runner/Debug/PiliAurora.exe
```

路径含空格时，将整个 `--dart-define=...` 参数放在引号内。探针创建输出目录，写入 `results.json` 和 `PASS` 或 `FAIL`，执行完毕自动退出。构建时增加 `--dart-define=SHADER_PROBE_RESET=false` 可对照直接更新 shader 的行为；默认启用重建。

入口要求实际后端为 `d3d11va`，输入画面需有可识别的明暗变化，片段长度应覆盖完整切换流程。探针开启与应用一致的 16 秒、前后各 4 MiB 缓存，默认从 4.3 秒开始播放，并检查切换期间的解码错误。可用 `--dart-define=SHADER_PROBE_START_MS=<毫秒>` 指定起点。

AV1 重建回归需使用关键帧间隔较长的片段，例如 90 秒、30 fps、300 帧 GOP 的合成视频。准备好 FFmpeg 后可生成：

```powershell
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 90 -c:v libsvtav1 -preset 10 -crf 38 -g 300 -svtav1-params "lp=4" -c:a aac -b:a 64k build/av1-shader-fixture.mp4
```

探针使用 `ao=null`，音频时间线断言不验证扬声器声音。历史本机结果与暂停回退现象见[本地 libmpv 记录](../../third_party/media_kit_libs_windows_video/LOCAL_LIBMPV.md#应用超分切换记录)。完成后按[构建与测试](../../doc/build-and-test.md#构建)重新构建应用默认入口。

Windows 采样门控的主机回归可运行 `python tool/probes/windows/windows_frame_sampling_probe.py`（C++17 编译器，默认 `g++`）。该入口抽取生产 render 队列方法，覆盖原始帧身份、开关回执、旧消费通知、准入恢复与同 token 序号连续性。

## Windows 图形资源生命周期探针

以下入口编译生产 ANGLE 与 VideoOutput 类，通过外部资源计数替身检查构造失败回滚、共享 EGLDisplay 的跨线程释放、持续渲染期间的卸载任务调度，以及 resize、重建、销毁交错时的纹理注销回执：

```powershell
python tool/probes/windows/windows_angle_rollback_probe.py
python tool/probes/windows/windows_renderer_release_probe.py
```

需要支持 C++17 的 `g++`，可用 `--compiler` 指定路径；`--source-ref` 可选择用于对照的 Git 提交。生成文件位于系统临时目录，运行后清理。
