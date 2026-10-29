# 弹幕实机复测

这些入口运行当前生产点播、直播组件及其帧调度器，自动采集更新、Raster与最终呈现。
实验输出位于 `build/`；账号、线上媒体地址和设备序列号不写入报告。
普通应用与探针使用同一构建目录，结束后按下文恢复普通入口。

## 两端完整复测

统一入口先运行调度回归和采集器测试，再串行测量Windows纯弹幕、Windows视频负载及Android两段视频和直播，
避免两端同时解码干扰本机GPU。Windows结束后自动重建普通入口；Android按指定APK恢复dev包。

```powershell
pwsh -NoProfile -File tool/probes/danmaku/retest.ps1 `
  -PresentMonPath <PresentMon.exe> -Media24 <24FPS本地视频> -Media60 <60FPS本地视频> `
  -AdbPath E:/SDK/Android/platform-tools/adb.exe -DeviceId <真机ID> `
  -FlutterSdk <Flutter-3.47.5隔离SDK> -AndroidSdk E:/SDK/Android `
  -RestoreApk <普通dev包.apk>
```

`-Platform windows` 或 `-Platform android` 选择单端；`-SkipRegression` 复用本轮已完成的调度回归。
输出根目录默认 `build/danmaku-retest/<时间戳>/`，`steps.json` 汇总实际执行步骤。
任一判定失败时保留报告并返回非零，其他平台继续采集。

## Android 真机

从仓库根目录运行，使用项目固定版本的隔离Flutter SDK、已准备的依赖和连接的arm64真机。
默认解包仓库正式Release引擎；`--engine-library` 可指定同版本、同模式、附身份JSON的引擎。
应用使用独立的 `io.github.wallpap.piliaurora.dev` 包，覆盖已有dev程序并保留其数据。
正式包可并存。探针关闭音频，使用本地素材，不初始化账号或网络服务。

```powershell
python tool/probes/android/measure_danmaku.py `
  --adb E:/SDK/Android/platform-tools/adb.exe --serial <真机ID> `
  --flutter-sdk <Flutter-3.47.5隔离SDK> --android-sdk E:/SDK/Android `
  --media <24FPS本地视频> --media <60FPS本地视频> `
  --restore-apk <普通dev包.apk>
```

每个点播视频连续测量30／60／90／120 FPS和跟随屏幕，最后测一次直播五档及暂停、恢复、隐藏。
每档预热4秒、测量8秒，切档复用显示实例，视频不seek，避免素材窗口失效。
建议使用至少90秒的1920×1080连续素材，避免循环边界影响时钟。报告保留硬解器和源帧率。
直播输入60条滚动／顶部／底部混合弹幕，报告保留实际活动数量。

`--modes point` 或 `--modes live` 可选择范围；`--output` 指定尚未存在的目录。
首次启动由应用创建测试目录，主机再推送素材和配置。
日志限定本次进程与探针标签，采集期间临时启用引擎呈现日志，结束时恢复原属性并停止dev包。
生产路径的Raster CPU亲和性在探针结束时恢复。

入口自动完成构建、安装、素材准备、运行、SurfaceFlinger采集、同帧关联和判定。
传入 `--restore-apk` 后，无论采集成功或失败都会重装指定普通dev包；省略时设备保留探针APK。
该选项用于恢复程序，素材与本次报告仍保留在dev包的外部files目录。

再次采集可用 `--apk <上次输出/danmaku-probe.apk>`，省略SDK参数。
复用时核对旁边身份JSON的目标入口、包名和APK摘要；源码更新后重新构建。
重复分析已有采集无需设备：

```powershell
python tool/probes/android/danmaku_frame_pacing_analysis.py <输出/00-point>
uv run --locked python -m unittest discover -s tool/probes/android -p '*_test.py' -v
```

每段输出 `probe.json`、`probe.log`、`surface.json`、`device.json`、逐档关联与连续性JSON、`summary.json`、`summary.md`。
Flutter帧号关联Raster区间，再匹配该区间唯一的EGL提交与同一EGL帧ID的实际呈现；缺失、重复和歧义均保留为缺失。
SurfaceFlinger的实际呈现时间作为独立交叉核对，采集最长60秒，因此末档可能只覆盖部分窗口。
gfxinfo可能没有Flutter Surface的帧记录，报告保留实际数量。

通过要求：五档实际频率误差<5%（按屏幕上限计算），窗口内持续有滚动弹幕，实际呈现关联率≥95%，
3／5／7帧完整窗口的速度RMS P95≤10%，含单步速度偏差>10%的窗口比例<1%。
直播还要求暂停和隐藏停止更新及请求、恢复后继续更新，SurfaceFlinger必须有有效数据。
90 FPS在120 Hz上正常出现1／2槽交替，间隔误差按同帧目标计算。
未通过返回1，原始数据全部保留；构建或采集错误同样返回非零。

## Windows 本机

准备官方PresentMon独立命令行工具，测试时保持探针窗口可见，避免其他置顶窗口遮挡。
默认Profile；验证正式引擎时使用Release：

```powershell
python third_party/flutter_engine/package.py unpack --target windows-x64 --output build/danmaku-engine/windows
pwsh -NoProfile -File tool/probes/windows/measure_danmaku.ps1 `
  -PresentMonPath <PresentMon.exe> -Mode release `
  -EngineLibrary build/danmaku-engine/windows/flutter_windows.dll `
  -Media <60FPS本地视频>
```

省略 `-Media` 测量纯弹幕负载。点播／直播各测12和60条混合弹幕，每段预热后测量10秒。
Windows生产策略跟随屏幕刷新率。入口自动构建、启动可见窗口、采集独立ETW session并分析PresentMon CSV。
`-SkipBuild` 要求输出当前确实为同一模式和引擎的探针；普通入口构建后需重新构建探针。
输出与阈值见[Windows探针](../README.md#windows-弹幕帧节奏探针)。

## 恢复普通构建入口

Windows探针结束后使用同一个引擎重建普通入口：

```powershell
pwsh -NoProfile -File tool/build.ps1 -Platform windows -Mode release `
  -EngineLibrary build/danmaku-engine/windows/flutter_windows.dll -SkipPubGet
```

Android可通过帧计划构建入口的 `--mode dev-release --target lib/main.dart` 生成普通dev包，
随后用 `--restore-apk` 交给采集入口恢复。构建与采集入口不执行Git写操作、不清空logcat或应用数据。

## 调度回归

```powershell
fvm flutter test --no-pub test/pages/danmaku/frame_rate_ticker_test.dart test/pages/danmaku/frame_cadence_test.dart test/pages/danmaku/frame_late_delivery_test.dart test/pages/danmaku/frame_deadline_replay_test.dart test/pages/danmaku/frame_plan_identity_test.dart test/pages/danmaku/video_presentation_cadence_test.dart test/pages/danmaku/window_screen_test.dart test/pages/danmaku/live_layer_test.dart tool/experiments/danmaku/frame_cadence_device_matrix_test.dart
pwsh -NoProfile -File tool/run-native-probes.ps1
```

虚拟时钟回归覆盖调度语义，最终呈现结论来自目标设备采集。Windows点播使用合成媒体时钟；
Android点播使用生产worker媒体时钟采样；两者均未覆盖完整业务页面的网络、音频、超分及长期功耗。
