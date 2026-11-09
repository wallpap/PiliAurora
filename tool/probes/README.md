# 调试工具

此目录存放供维护者运行的隔离诊断工具和平台探针。这些工具不属于应用运行时或正式构建流程。

| 目录 | 内容 |
| --- | --- |
| `android/` | 暂停旋转测试入口、画面检查脚本和 Java 帧栅栏检查。 |
| `windows/` | 窗口回调、尺寸通道、纹理首帧和输出确认探针。 |
| `playback/` | 媒体加载烟测、跳转命令、会话验收与 Windows 超分切换。 |
| `event_loop/` | 事件循环生命周期、ABI 检查与配套 C++ mock。 |

运行前查看脚本参数和源码，确认目标平台、输入文件及输出目录。工具结果只覆盖它实际检查的内容；应用行为还要按[构建与测试说明](../../doc/development/build-and-test.md)在目标平台验证。

Python 探针使用 uv 环境，首次运行前请按[工具入口中的 Python 环境说明](../README.md#python-工具环境)初始化；以下命令均从仓库根目录运行。

## mpv 软件渲染参数 ABI

`windows/software_render_abi_test.py` 提取 Windows、Linux 生产源码中的步长声明，使用 C++17 编译器检查 `MPV_RENDER_PARAM_SW_STRIDE` 的 `size_t*` 契约，并读回多个宽度的步长。不创建 GL 或播放器；缺少 `c++` / `g++` 时跳过，真实输出仍需设备验证。该文件由 Linux CI 的 Windows 探针单元测试发现入口执行。

```powershell
python -m unittest discover -s tool/probes/windows -p software_render_abi_test.py -v
```

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

`playback/session_device_acceptance.dart` 使用真实播放会话与平台输出，检查暂停加载、画面采样、跳转、快速切源、解码与音频模式切换、自然片尾通知和释放。构建时用 `DEVICE_MEDIA` 指定设备可读样片，`DEVICE_REPORT` 指定报告路径，`DEVICE_SOAK_SECONDS` 控制连续播放时长。探针使用 `ao=null`，不检查扬声器输出。

该探针的暂停跳转断言要求落点距目标小于 500ms。Android 普通音视频沿用关键帧跳转策略，应提供关键帧间隔不超过 500ms 的样片；稀疏关键帧样片用于单独验证跳转策略，不适用这个精度断言。独立音轨的精确跳转验证使用上文 `--seek-target` 入口。

## Windows 独立音轨断流回归

`playback/native_audio_stream_recovery.py` 在127.0.0.1临时HTTP端口提供合成WAV，发送4秒音频后通过RST终止连接，
复现curl传输失败、音频缓存耗尽但视频继续、缓存内向右跳转仍无声，再解除故障并执行 `audio-reload`。
输入为至少20秒的本地连续视频，探针关闭mpv原生重试以缩短故障注入窗口，使用现有libmpv和软件解码。

```powershell
python tool/probes/playback/native_audio_stream_recovery.py --library build/windows/x64/runner/Release/libmpv-2.dll --video <本地视频文件>
```

入口检查跳转期间未新建音频连接、视频时间持续推进，以及重连后音频时间恢复并保留播放状态。
报告默认保存到 `build/native-audio-stream-recovery/<时间戳>/summary.json`；`--output` 指定不存在的目录。
任一前置场景未复现或恢复失败返回非零。合成音轨用于时钟检查，输出采用 `vo=null`、`ao=null`；
应用的恢复监视、缓存等待和重试预算由 `test/plugin/pl_player/playback/audio_recovery_test.dart` 覆盖，扬声器由实机验收。

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

输出默认位于 `doc/dev/diagnostics/android-frame-timing/<UTC时间>.json`，可传 `--output` 指定不存在的文件。工具排除初始缓冲区中的已完成帧、重复行、零值和未完成 fence，保存数值行与图层摘要，不保存设备序列号、原始图层名或 dumpsys 文本。SurfaceFlinger 三列依次为期望呈现、实际呈现和帧就绪的纳秒时间，定义见 [AOSP FrameTracker](https://android.googlesource.com/platform/frameworks/native/+/878911f7df21c700ddbe9e9c9d28cd0a1776946f/services/surfaceflinger/FrameTracker.cpp#240)。gfxinfo 按输出表头提取 `Flags`、`IntendedVsync`、`Vsync`、`FrameCompleted`。

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
`doc/dev/diagnostics/windows-danmaku-validation/时间戳/`；`-OutputDirectory` 可指定尚未存在的目录。
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
完成后按[构建与测试](../../doc/development/build-and-test.md#构建)重新构建普通应用入口。

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

需要 Python 和支持 C++17 的 `g++`，可用 `--compiler` 指定编译器。输出保存在 `doc/dev/diagnostics/windows-playback-diagnosis/`。探针使用模拟播放器，验证命令与时序；GPU 和实际视频播放在应用内检查。

## Windows 开播纹理回归探针

`windows_playback_startup_probe.py` 提取生产视口的尺寸提交方法，使用真实的截图交接和帧确认类，验证已配置的同尺寸输出在帧统计延迟时保持活画面、真实尺寸变化仍等待对应的渲染帧。

```powershell
uv run --locked python tool/probes/windows/windows_playback_startup_probe.py
uv run --locked python tool/probes/windows/windows_texture_frame_probe.py --compiler <g++路径>
```

前者通过 FVM 运行 Flutter 测试；后者编译生产纹理方法，检查初始纹理、有效首帧和同尺寸提交。生成文件位于 `doc/dev/diagnostics/windows-playback-diagnosis/`，GPU 和播放器通道由模拟对象替代。

## Windows 硬解画面采样探针

设置页的真实解码测试另有 `playback/decoder_test_acceptance.dart`，使用相同的会话工厂：Windows 每组启动独立测试进程，子进程使用 `NativeDecoderTestSession` 和可见纹理消费路径。配置 JSON 为本地样片数组，例如 `[{"path":"E:/media/av1.mp4","codec":13,"width":1920,"height":1080}]`，编码编号 AVC=7、HEVC=12、AV1=13。每项可用 `decoders` 数组指定要测的 mpv 模式，默认检查 `no`、`d3d11va`、`d3d11va-copy`。构建时用 `DECODER_TEST_CONFIG`、`DECODER_TEST_REPORT` 指定配置与报告绝对路径；只使用内存设置，不读取账号，等待每组进程退出后继续。驱动崩溃会在该组结果中记录异常退出码，报告仍保留后续组的结果，任一组失败则验收入口最终退出 1。它验证播放推进与出画，不替代下方像素参考对照。

依赖与补丁准备后，可用独立构建目录运行，避免占用日常应用的程序文件。将下方配置、报告路径改为本机绝对路径；样片应包含至少 10 秒可持续播放的画面：

```powershell
fvm flutter build windows --release --no-pub --flavor decoder-test --target=tool/probes/playback/decoder_test_acceptance.dart --dart-define=DECODER_TEST_CONFIG=E:/media/decoder-inputs.json --dart-define=DECODER_TEST_REPORT=E:/media/decoder-results.json
& ./build/windows/x64/decoder-test/runner/Release/PiliAurora.exe
```

`windows_video_sampling_probe.py` 使用本机 ANGLE、libmpv 和真实解码帧，读取 media_kit 与 controller 的生产渲染参数。暂停后逐帧推进，用 libmpv 的 `NEXT_FRAME_INFO` 排除 REDRAW / REPEAT，绘制真正新帧后再按视频时间与 FFmpeg 软件参考帧对齐，评估整帧、最坏行和局部区域。探针关闭时间戳起点归零，非零起始时间也沿用容器时间；软件参考固定色度位置、完整色度插值和颜色范围，运行时核对 mpv 的实际色度位置。先构建 Windows Release，并在 PATH 提供 `ffmpeg`、`ffprobe`：

```powershell
uv run --locked python tool/probes/windows/windows_video_sampling_probe.py --video <本地视频文件>
```

默认使用 `build/windows/x64/runner/Release/` 下的 DLL、`d3d11va` 和源视频尺寸。输入须为明确标记色域与范围的 SDR BT.709、8-bit yuv420p、方形像素、无旋转视频，至少 30 帧。可用 `--library-dir`、成对的 `--width` / `--height` 指定构建目录和保持宽高比的输出尺寸；HDR 等其他输入会明确失败，不生成不适用的画质结论。该探针只打开本地视频。

`--frames` 默认 30，`--sample-every` 默认 5，检查 30 个连续视频时间戳及其中 7 个像素样本。每帧记录 `hwdec-current`；显式解码器不符时失败，`--decoder no` 验证软件解码，`--decoder auto` 等自动模式允许回退并记录事实。可用 `--decoder dxva2 --expect-decoder no` 明确验证不支持的编码回退，或用 `--expect-decoder` 收紧自动模式的预期。追加 `--control-dumb-mode=auto` 对照简化渲染模式。

探针同时加载 controller 配置的 Windows 基础色度边界 shader。追加 `--control-disable-chroma-clamp` 仅撤销此修正，生成独立命名的报告，可验证 HEVC / AV1 直通纹理底边异常仍可被检测；无需修改播放器源码或默认解码器。

`--output-dir` 默认 `build/windows-video-sampling/`，保存采样 PNG、实际/参考/放大差异接触表和 JSON。画质门限为 MAE ≤ 3、PSNR ≥ 30 dB、通道误差 > 32 的像素占比 ≤ 1%、最坏行/32×32 区域 MAE ≤ 12；另检查相对参考新增的黑色、绿色底边及动态参考下的冻结像素。精确相同的帧以 `psnrDb=null` 表示无误差。黑场和绿色原片内容本身不会被判损坏。退出码 0 表示帧身份、实际解码器与所有画质检查通过，任一失败返回 1 并保留报告。该测试暂停逐帧，不衡量实时吞吐或流畅度，也不覆盖 Flutter 共享纹理导入和最终屏幕呈现。

使用矩阵入口顺序比较 AVC / HEVC / AV1 与 `d3d11va`、`d3d11va-copy`、`no`，每种路径独立进程，报告汇总到 `summary.json`，失败用例不会中止后续检查：

```powershell
uv run --locked python tool/probes/windows/windows_video_decode_matrix.py --video <AVC片段> --video <HEVC片段> --video <AV1片段> --output-dir build/windows-decode-matrix
uv run --locked python -m unittest discover -s tool/probes/windows -p windows_video_sampling_probe_test.py -v
```

矩阵可重复传入 `--decoder` 限定路径，也接受 `--frames`、`--sample-every`、`--width` / `--height`。比较不同输出尺寸时使用不同输出目录。画质单测通过注入一行绿条、局部/整帧黑块、翻转、颜色通道错位、冻结和不对齐时间戳验证失败信号。

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
结束后按[构建与测试](../../doc/development/build-and-test.md#构建)重新构建应用默认入口。

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
设置 `{"eofOnly": true}` 可单独检查自然 EOF 后的暂停定位、连续定位取代、在途播放/暂停意图和从零复播。
此模式在首次加载时同时使用可选的 `DEVICE_AUDIO`，可用本地 HTTP Range 服务提供分离音视频，
检查暂停定位后的实际落点、纹理像素和当前输出的首帧消费事实；报告不保存媒体地址。
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
fvm flutter build windows --debug --no-pub --target tool/probes/playback/desktop_window_acceptance.dart --dart-define=WINDOW_PROBE_MEDIA=E:/media/fixture.mp4 --dart-define=WINDOW_PROBE_REPORT=build/window-validation/window.json
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

`playback/windows_shader_switch.dart` 使用实际 Flutter、ANGLE 与 libmpv 检查 shader 切换、纹理更新、硬解、暂停状态、音频时间线和私有内存。准备含音轨的本地视频，并确认[上游 mpv 包](../../third_party/media_kit_libs_windows_video/UPSTREAM.md)可下载且通过校验，然后构建专用入口：

```powershell
fvm flutter build windows --debug --no-pub --target tool/probes/playback/windows_shader_switch.dart --dart-define=SHADER_PROBE_ROOT=<仓库绝对路径> --dart-define=SHADER_PROBE_VIDEO=<本地视频绝对路径> --dart-define=SHADER_PROBE_OUTPUT=<输出目录绝对路径>
& build/windows/x64/runner/Debug/PiliAurora.exe
```

路径含空格时，将整个 `--dart-define=...` 参数放在引号内。探针创建输出目录，写入 `results.json` 和 `PASS` 或 `FAIL`，执行完毕自动退出。原位对照模式默认重建渲染器，增加 `--dart-define=SHADER_PROBE_RESET=false` 可改为直接更新 shader。

验收当前应用行为时，增加 `--dart-define=SHADER_PROBE_SESSION=true`，通过生产 Session/Runtime 卸载并重载媒体。该模式按 shader 实际变化重载，重复相同列表不重建，也不使用上述 RESET 开关。不传 SESSION 开关时运行原位重建对照；标准上游库在这一旧路径下仍可能出现 AV1 解码错误。

入口要求实际后端为 `d3d11va`，输入画面需有可识别的明暗变化，片段长度应覆盖完整切换流程。探针开启与应用一致的 16 秒、前后各 4 MiB 缓存，默认从 4.3 秒开始播放，并检查切换期间的解码错误。可用 `--dart-define=SHADER_PROBE_START_MS=<毫秒>` 指定起点。

AV1 重建回归需使用关键帧间隔较长的片段，例如 90 秒、30 fps、300 帧 GOP 的合成视频。准备好 FFmpeg 后可生成：

```powershell
ffmpeg -f lavfi -i "testsrc2=size=640x360:rate=30" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 90 -c:v libsvtav1 -preset 10 -crf 38 -g 300 -svtav1-params "lp=4" -c:a aac -b:a 64k build/av1-shader-fixture.mp4
```

探针使用 `ao=null`，音频时间线断言不验证扬声器声音。历史本机结果与暂停回退现象见[本地 libmpv 记录](../../third_party/media_kit_libs_windows_video/LOCAL_LIBMPV.md#应用超分切换记录)。完成后按[构建与测试](../../doc/development/build-and-test.md#构建)重新构建应用默认入口。

Windows 采样门控的主机回归可运行 `python tool/probes/windows/windows_frame_sampling_probe.py`（C++17 编译器，默认 `g++`）。该入口抽取生产 render 队列方法，覆盖原始帧身份、开关回执、旧消费通知、准入恢复与同 token 序号连续性。

## Windows 内存观测与 ETW

`windows/memory_logging.dart` 构建独立数据目录的人工复现包。默认数据保存在可执行文件旁的 `memory-data/`，也可由 `PILIAURORA_MEMORY_ROOT` 指定；不读取现用程序的账号或设置。性能记录自动开启，页面操作由复现者完成。构建后将整套输出复制到独立目录，并将测试 exe 命名为 `PiliAuroraMemory-<8至32位十六进制编号>.exe`，保留所有 DLL 与 data 目录：

```powershell
pwsh -NoProfile -File tool/build.ps1 -Platform windows -Mode release -Target tool/probes/windows/memory_logging.dart
```

`--smoke` 参数只用 `PILIAURORA_MEMORY_MEDIA` 指定的本地视频验证播放/退出后的原生计数和 VirtualQuery 快照，不连接业务接口。结果写入数据目录的 `smoke.json`，同时保留完整诊断记录；短测不代表完整浏览流程满足 500 MiB 目标。

原生扫描器的主机回归执行真实 VirtualAlloc/VirtualProtect/VirtualFree、文件映射及 image 查询，检查 ID、保护分类、限界、释放复用及启停：

```powershell
New-Item -ItemType Directory -Force build/probe-validation/memory-metrics
g++ -std=c++17 -Wall -Wextra -Werror -pedantic -I windows/runner windows/runner/memory_metrics.cpp tool/probes/windows/memory_metrics_probe.cc -o build/probe-validation/memory-metrics/memory_metrics_probe.exe
& build/probe-validation/memory-metrics/memory_metrics_probe.exe
```

需要分配/释放调用栈时，在测试程序启动前运行以下命令。Start 通过 UAC 启动隐藏采集进程；提示就绪后，在普通权限下手动运行测试 exe。每次使用一个新输出目录：

```powershell
pwsh -NoProfile -File tool/probes/windows/record-memory.ps1 -Executable <独立测试exe> -OutputDirectory <新采集目录> -Seconds 300 -Heap
pwsh -NoProfile -File tool/probes/windows/record-memory.ps1 -Action Stop -OutputDirectory <采集目录>
pwsh -NoProfile -File tool/probes/windows/record-memory.ps1 -Action Status -OutputDirectory <采集目录>
```

省略 `-Heap` 仅采 VirtualAllocation；加上它会为该测试 exe 名称临时启用 IFEO 堆追踪，要求启动前不存在同名 IFEO 配置和运行实例。追踪会影响耗时与堆开销，应与常规日志对照。脚本使用 WPR filemode，最长 30 分钟；Stop 或到时后仅停止自己的命名会话，finally 撤销本次堆配置。`status.json` 的 completed、cleanupErrors 和 `wpr.log` 表示实际采集及清理结果，合并 ETL 可能在停止后继续耗时。系统/采集进程异常退出后，按状态文件中的独立名称在管理员终端执行 `wpr -cancel -instancename <session>`、`wpr -heaptracingconfig <exe名称> disable` 恢复，不操作其他会话或现用程序。

ETL 保存本地分配元数据与调用栈，不保存内存内容；VirtualAllocation 为系统范围，ETL 仍可能包含其他进程名、模块路径及系统元数据，不会自动脱敏或上传。用 WPA 按测试进程 PID 和时间段过滤 Virtual Allocations/Heap Allocations，核对事件丢失及分配栈。符号须与对应二进制匹配；原生栈无法直接展开到每个 Dart 对象或驱动内部对象。常规匿名块日志不含地址，和 ETW 以进程、时间、大小、保护类型对应，无法保证唯一逐块匹配。

批处理现有目录或导出的 ZIP：

```powershell
python tool/probes/windows/analyze_memory.py <日志目录或ZIP> --output build/memory-analysis
```

输出 performance.csv、memory-snapshots.csv、region-changes.csv 和 summary.json。脚本跳过播放器大段 trace，只保留性能与内存结构化字段；核对检查点/差分批次数量并报告缺失。旧版缺少的字段留空，缺失不等于零；差分与页面操作的时间相关不能单独证明分配原因。完成后按常规构建入口恢复默认应用 target。

## Windows 自动浏览与播放内存验收

`windows/browsing_memory.dart` 自动进入推荐、热门、排行、番剧、影视、直播、动态和我的，
每页等待加载并滚动不超过一屏，最后进入设置页静置70秒。它复用正常应用路由和数据加载，
不销毁保活首页。构建后按上节复制完整运行目录、使用独立数据根和编号exe：

```powershell
pwsh -NoProfile -File tool/build.ps1 -Platform windows -Mode release -Target tool/probes/windows/browsing_memory.dart
$env:PILIAURORA_BROWSING_ACTIONS = 'resumeRcmd,settingIdle'
$env:PILIAURORA_BROWSING_OUTPUT = '<独立输出目录>/browsing-probe.json'
```

独立数据根缺少账号时需要在测试实例登录；不要把现用程序的数据目录直接设为测试根。
报告只有八页均加载成功且确实进入设置路由时才有 `validWorkload=true`。
`baselineRetentionTarget.passed` 要求无干预基线的Private和RSS均低于500MiB。
`resumeValidation.passed` 另检查推荐controller、数据状态与滚动位置保持。
退出码不能代替这些字段；短停留或未加载内容的结果不属于真实负载验收。

验收可设置 `PILIAURORA_BROWSING_DETAILS=false`：保留相同页面流程、进程/默认堆计数和
图片缓存标量，省去各stage的完整诊断深复制、UI树遍历和原生详细查询；应用正常性能日志
仍按原设置采集。阈值始终取 `observedProcess` 的实时Private/RSS，数值标准不变。
`progress.json` 只写最近stage及stageCount，完整stages历史在最终报告一次性写出。
轻量模式与详细模式分别标记 `detailedStageSnapshots`，比较时应核对观察开销。

普通FVM引擎不支持实验通道，明确返回unsupported。调查时可显式设置逗号分隔的actions：
`sampleHeaps` 只查询默认进程堆；`optimizeHeaps` 单次调用HeapOptimizeResources；
`sampleCPU/purgeCPUResources/purgeCPUFonts/purgeCPUHarfBuzz` 分别使用
[实验引擎](../engine/windows_memory/README.md) 的独立CPU通道。
同一实验引擎的 `freeGpuRaster/freeGpuIO` 调用所选上下文的freeGpuResources；
该Skia API内部会flushAndSubmit，不与单独purge混为同一控制。
其它cache、frame、GPU purge/Trim、VM GC、路由销毁动作也只用于归因。
这些动作均在baseline之后执行，后续降低不能算作产品通过。默认action序列含清理动作，
常规验收应像示例一样显式选择回切与静置，或使用 `--browse-only` 只保留基线。

各stage的 `observedProcess` 是独立实时进程读数，`processHeap` 仅覆盖不可销毁的默认堆，
不枚举并发创建/销毁的其它堆。Private提交、RSS、私有工作集分别记录，不能相加；
allocated与committed差额也不全是可释放碎片。停止诊断采集后
`diagnostics.process` 可能为空或旧值，应使用 `observedProcess`。
输出中的native、vm、cpu分别保留对应通道的覆盖范围和unsupported/unavailable回执。

`windows/playback_memory.dart` 同样使用隔离存储，自动执行两轮真实推荐视频播放、
确认进度与原生输出、走正常返回路径，再静置70秒。构建时替换上述target即可；
`PILIAURORA_PLAYBACK_OUTPUT` 指定报告，`PILIAURORA_PLAYBACK_SECONDS` 默认20，
`PILIAURORA_PLAYBACK_IDLE_SECONDS` 默认70。须同时检查 `validWorkload`、
各round的 `nativeResourcesReleased/retentionTargetPassed` 和最终 `passed`。
采样/插桩引擎的绝对占用不能代替普通Release验收；完成后重建正常 `lib/main.dart`。

两个自动入口在最终采样、日志flush和报告写入完成后，才卸载Widget树并等待新根绘制帧结束，
让页面同步释放托盘等原生句柄，再销毁测试窗口。该收尾不参与内存阈值判断，报告中的
`shutdownPolicy` 标明此顺序；不能把结束时的Widget卸载当作正常浏览回收策略。
仍需核对原生进程退出码；这一帧结束不代表所有异步存储或服务已全部关闭。

## Windows 图形资源生命周期探针

以下入口编译生产 ANGLE 与 VideoOutput 类，通过外部资源计数替身检查构造失败回滚、共享 EGLDisplay 的跨线程释放、持续渲染期间的卸载任务调度，以及 resize、重建、销毁交错时的纹理注销回执：

```powershell
python tool/probes/windows/windows_angle_rollback_probe.py
python tool/probes/windows/windows_renderer_release_probe.py
```

需要支持 C++17 的 `g++`，可用 `--compiler` 指定路径；`--source-ref` 可选择用于对照的 Git 提交。生成文件位于系统临时目录，运行后清理。

## Windows Profile VM 堆归因

以下工具只用于明确指定的独立测试实例，定位对象类型与引用链。Profile 包含额外的代码、源码映射等元数据，采集也会影响运行时序；其绝对内存不能作为 Release 的内存阈值验收结果。Release 阈值仍需在对应 Release 包、有效浏览负载和无干预基线下验证。

保留 VM service 默认认证，只绑定 loopback。将该测试实例启动日志或完整 service URI 保存在本地文件，不把认证 URI 粘贴到公开日志。采集器只接受 loopback，并要求 `--pid` 与 service 的进程 PID 一致；不会自动查找或连接其他进程。Windows 显式传入固定 SDK 的 `dart.exe`，避免通过 `.bat` 启动辅助进程：

```powershell
python tool/probes/windows/capture_vm_memory.py --uri-file <本地启动日志或URI文件> --pid <测试PID> --output build/vm-capture-before --heap-snapshot --dart <固定SDK的dart.exe>
```

`--output` 必须是新目录；`--uri` 可替代 `--uri-file`，但后者可避免认证 URI 出现在命令行中。默认选择名为 `main` 的唯一 isolate，也可用 `--isolate-id` 明确指定。HTTP 调用 `getVM`、`getIsolate`、`getAllocationProfile(gc:true)`，输出 `allocation.json`、`classes.csv`；`gc:true` 只表示请求 GC，不保证一定执行。stdout 仅显示类名、实例数和字节数，不输出对象值或认证 URI。

可选 `--heap-snapshot` 通过 `capture_vm_heap.dart` 和项目现有 `vm_service` 依赖接收 WebSocket 二进制事件，保存 `heap.heapsnapshot`，无需安装全局依赖。辅助进程从 stdin 接收认证 URI，并再次核对 PID。快照失败时在 `allocation.json` 标明状态，已有分配摘要仍保留；失败留下的部分二进制文件不能当作完整快照。

离线分析完整快照：

```powershell
fvm dart --packages=.dart_tool/package_config.json tool/probes/windows/analyze_vm_heap.dart --input build/vm-capture-before/heap.heapsnapshot --output build/vm-heap-before
```

输出 `heap-summary.json` 和有界的类摘要，包括类浅层大小、从 snapshot root 可达的大小、最大 retained 候选，以及大存储对象和代表 UI 类的 dominator/应用 owner 字段路径。`--top` 限制摘要数量，`--focus` 可指定逗号分隔的类名。工具不导出 `object.data` 或任意对象的 String 内容；原始快照可能包含这些内容，必须留在本地，不提交、不外传。

当前分析上限为 512 MiB 文件、200 万对象、2000 万引用；dominator 计算最多 50 轮，按 60 秒预算检查，单轮处理可能越过该时间。未收敛时不报告 retained size。类浅层大小与嵌套 retained size 是不同口径，重叠的 retained 值不能相加；快照也可能包含不可达对象，应优先核对 root 可达统计。对照采集必须使用同一构建、同一进程和明确阶段，不能把销毁主路由等诊断操作当作正常浏览修复。

解析检查：`python -m unittest discover -s tool/probes/windows -p capture_vm_memory_test.py`。共享子对象的手工 diamond 图与 String canary 验证可保留在本地 `build/` 实验目录，不需要新增应用测试框架。


`windows/inspect_vm_semantics.dart` 针对同一完整快照补充 RenderObject 的 owner/parent 保活统计，区分 attached、detached 与根可达性，并输出有界的 detached RenderParagraph 字段引用路径：

```powershell
fvm dart --packages=.dart_tool/package_config.json tool/probes/windows/inspect_vm_semantics.dart --input build/vm-capture-before/heap.heapsnapshot --output build/vm-semantics-before.json
```

该工具与通用堆分析一样不解码对象值，路径仅使用类名和字段名。单次堆快照的根可达性用于定位保活链；修复效果还需同场景前后对照和独立 Release 内存验收。

## Windows 切页与播放卡顿对照

`windows/stutter_validation.dart` 使用与内存探针相同的隔离存储入口，执行首页首次加载、
复访与两轮同内容播放。复访、播放均按 debug/off/off/debug 顺序对照诊断开关，
切换后先静置，再由独立 FrameTiming 和 5ms Timer 保留帧耗时、真实帧时间和唤醒间隔。
`inactivePaintCleanup` 单独记录绘制层清理耗时；`grpcDecode` 另记录排队、解析及消费耗时，
消费包含异步任务等待，后台解析计时包含 isolate 调度，均不能直接等同于 UI CPU 时间。

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode release -Target tool/probes/windows/stutter_validation.dart -SkipPubGet
$env:PILIAURORA_MEMORY_ROOT = '<独立测试种子目录>'
$env:PILIAURORA_STUTTER_OUTPUT = '<本地输出目录>/report.json'
# 将完整构建目录复制到独立位置后启动该位置的 PiliAurora.exe。
python tool/probes/windows/analyze_stutter.py --input <report.json> --logs <测试种子/support/diagnostics> --output <summary.json>
```

探针会切页、静音播放及改变隔离设置；不要指向现用账号存储。结束时按内存探针相同方式
关闭窗口，再恢复正常发布入口。日志、账号种子、快照和实验报告放在本地忽略目录。
在线列表可变化，先检查 `validWorkload`、各tab的loaded状态和播放进度；首次使用与复访分段解释。

可选 PresentMon 使用测试PID、独立session_name和 `--qpc_time`。在采集期间保存同一时刻的
UTC纳秒、QPC纳秒为 `utcNs/qpcNs`，并记录真实QueryPerformanceFrequency。
离线分析另传 `--present <csv> --qpc-anchor <json> --qpc-frequency <频率>`。
DXGI提交间隔与实际屏幕呈现分开解释；显示时间为NA时保留缺测，不按零延迟处理。
