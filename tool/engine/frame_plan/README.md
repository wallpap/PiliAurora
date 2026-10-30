# Android 帧计划构建

该目录维护 Flutter 3.47.5 的隔离引擎补丁与 Profile、dev Release 测试包入口。应用仍使用 `lib/main.dart`、现有缩放 Binding、播放器和弹幕组件。Android 当前配置为 Skia/OpenGL。

固定材料：

- 引擎提交：`af7e796e161ae0bb1ff0758c71a7105418bd9ded`。
- Flutter 3.47.5 框架提交：`6a19cca56475dbfba1478ee68d7bd0c2ef891da1`。
- `engine.patch`：FrameTimeline、帧身份传递、纹理重绘合并和 EGL 输出。
- `frame_presentation_plan.h`：计划选择与跨线程预算反馈。

## 输出流程

Android 33+ 在 UI 更新前选择 FrameTimeline。计划包含 vsync ID、expected、deadline、回调起点及反馈句柄，随 FrameTimingsRecorder 和 FrameItem 到达 Raster、SurfaceFrame 与 EGL。Raster 重试保留原帧和原计划；迟到输出沿用原时间，诊断记录可用于判断错过的槽位。旧系统沿用原 Choreographer 回调。

渲染/GPU 耗时反馈用于选择可达 deadline，预算缓慢回落并受屏幕周期约束。相邻目标至少跨过半个屏幕周期，以排除不同回调对同一显示槽位的预测抖动。EGL 的提交相位余量由 deadline 与屏幕周期计算；提交前回收 GPU fence，达到在途上限时等待最早的 fence，等待上限为一个屏幕周期。Surface 重建释放所属 fence 与记录。

无有效 timeline 时立即交付普通 VSync 帧，连续三次失败后保持旧 Choreographer 回调。FrameTimeline 请求超过 100ms 未交付时，额外请求旧回调确认；旧回调先交付才关闭帧计划，迟到结果按请求序号丢弃。暂停或不可见时两种回调一起停发，等待显示恢复。呈现时间扩展失败、GPU fence 不可用或等待超时、swap 失败同样关闭帧计划，清理在途记录，后续沿用普通 Raster 与 EGL 输出，并保留仍可用的原有呈现时间提交。回退状态随引擎实例保存，通过 `PILI_FRAME_PLAN` 记录原因；重建引擎后重新探测。弹幕收到连续三次旧回调或异常提前量，或三秒缺少同帧 timing 时，保持独立更新节奏，诊断中的 `videoPhaseFallback` 记录原因。

Raster 比较图层 damage 与纹理的未消费状态，省略内容未变化的输出。Flutter 框架仍执行原有的布局、绘制、语义和 Scene 提交流程。`androidFramePlan` 配置与当前 FrameTimeline 支持条件共同启用视频保相位；ticker 通过相同 frameNumber 的 FrameTiming 还原 vsync 起点。配置和二进制身份由[共同构建协议](../README.md)绑定。

原生重绘任务携带图层树的复用身份，使用自身区域快照进行差分。此前没有绘制区域记录的树先建立完整基线；SurfaceTexture 按已发布的新帧标记取图，并在输出重建时重新取得画面。

## 准备隔离引擎

在独立 Flutter 引擎检出中固定上述提交，按根 DEPS 同步 Android 依赖，并运行 `gclient runhooks`。本机使用 WSL Ubuntu，关闭 Fuchsia、Windows、Web 和 JDK 下载。保留项目 FVM SDK，另复制同版本 SDK 用于应用编译。

```powershell
python tool/engine/frame_plan/apply.py <引擎检出> --framework-sdk <隔离Flutter-SDK>
```

在 Linux/WSL 中，从固定 DEPS 同步与 hooks 已完成的检出编译，并在连接的 Android 设备运行 `FramePresentationPlanTest.*`：

```sh
python3 tool/engine/frame_plan/build_engine.py --checkout <引擎检出> --flutter-sdk <Linux隔离SDK> --mode profile
```

入口应用固定补丁、核对源码、编译 arm64 引擎及原生回归，测试成功后在 `out/android_profile_arm64/lib.stripped/` 生成 `engine-identity.json`。Release 改为 `--mode release`；多设备可传 `--device`。复制到 Windows 时，将身份文件和 `libflutter.so` 一起保留。`--skip-tests` 的产物在装配前仍须完成原生回归。

## 构建 APK

在 Windows 仓库根目录执行：

```powershell
python tool/engine/frame_plan/build_apk.py --flutter-sdk <隔离Flutter-SDK> --engine-library <lib.stripped/libflutter.so> --android-sdk <Android-SDK>
```

默认输出 `build/android-frame-plan/PiliAurora-frame-plan-arm64-profile.apk`，包名 `io.github.wallpap.piliaurora.profile`，使用本机标准 debug keystore。脚本执行现有依赖验收与补丁流程，构建 arm64 Profile，替换自编引擎，校验签名和包内库摘要，并生成身份 JSON。`--skip-build --source-apk <已构建APK>` 可复用 AOT 产物，重新装配前核对来源 APK 的身份 JSON、目标入口、当前应用与本地依赖源码、ticker、呈现配置、自定义 Dart 编译参数与 APK 摘要。复用时传入与来源构建一致的 `--dart-define`；缺少编译参数登记的旧身份文件需重新构建。呈现配置与身份摘要由脚本生成。输入包含 preload 探针时会报错。

构建包含帧计划的 dev Release 包时，先用 `build_engine.py --mode release` 构建并完成原生回归，再执行：

```powershell
python tool/engine/frame_plan/build_apk.py --mode dev-release --flutter-sdk <隔离Flutter-SDK> --engine-library <out/android_release_arm64/lib.stripped/libflutter.so> --android-sdk <Android-SDK>
```

输出为 `build/android-test/PiliAurora-dev-arm64-v8a-release.apk`，包名 `io.github.wallpap.piliaurora.dev`。此模式通过项目现有 `PILIAURORA_TEST_RELEASE` 配置构建 Release AOT，并使用 `android/key.properties` 中的 Release 签名重新签署装配产物。签名助手在本机读取配置，密码通过子进程环境传递，日志不记录配置值。引擎与应用须使用相同运行模式。

## 验证

```powershell
fvm flutter test --no-pub test/pages/danmaku/video_presentation_cadence_test.dart
python -m unittest discover -s tool/engine/frame_plan -p '*_test.py' -v
python -m unittest discover -s tool/experiments/android -p '*_test.py' -v
```

纯计划测试可用 C++17 主机编译器编译 `frame_presentation_plan_test.cc`。Android 的 `flutter_shell_native_unittests` 目标另包含 `FramePresentationPlanTest.*`，验证 Raster 重试、跨 view 提交的计划身份、纹理消费与几何变化，以及旧树缺少区域记录时的完整重绘。

在 Linux 或 WSL 的仓库根目录运行主机计划回归：

```sh
mkdir -p build/frame-plan-validation
c++ -std=c++17 -pthread tool/engine/frame_plan/frame_presentation_plan_test.cc -o build/frame-plan-validation/plan_test
build/frame-plan-validation/plan_test
```

该回归还检查同一显示槽位的 14µs 预测抖动，避免将其当作下一输出槽位。组件、计划器与原生回归分别检查各自边界，最终呈现与设备成本沿用下面的同帧采集流程。

`prepare_device_probe.py` 复用运动夹具数据，生成使用正式 Binding、弹幕组件和原生引擎的设备入口；它使用引擎目标时间，不加载 preload 库。通过 `build_apk.py --target build/frame-plan-engine-probe/probe.dart --dart-define=JANK_MEDIA_URI=<原片URI> --output <隔离探针APK>` 构建。

设备诊断可设置 `log.tag.PILI_FRAME_PLAN=DEBUG`，读取 `submit` 与 `present` 的同一 EGL frame ID。采集结束恢复原属性。`egl_frame_association.py` 保留缺失记录，Surface 代次须分段。设备结果和原始采样保存在本地验证目录。

## 正式 Release 与多架构装配

Android 引擎编译入口支持 `--architecture arm`、`arm64`、`x64`，分别对应 `armeabi-v7a`、`arm64-v8a`、`x86_64`。每个架构使用独立输出目录、二进制摘要和原生回归结果。编译阶段使用的 `--skip-tests` 会将身份中的原生回归状态记为未通过，正式装配前需要完成对应架构的原生回归。

APK 装配入口使用 `--mode release --abi <ABI>` 构建正式包名，沿用 Release 签名；`--mode dev-release` 继续构建 `.dev` 测试包。统一入口对应 `tool/build.ps1 -Platform android -Mode release -Abi <ABI> -EngineLibrary <libflutter.so> -FlutterSdk <隔离SDK> -AndroidSdk <AndroidSDK>`。每份 APK 绑定当前架构的引擎身份，装配后校验包内引擎摘要与 ABI。

缺少 ARM32 设备时，可在 Linux 使用 `--architecture arm --qemu <qemu-arm> --android-rootfs <Android系统库目录>` 执行同一份 `flutter_shell_native_unittests`。系统库目录包含原始 Android 镜像的 `system/bin/linker` 和 `system/lib/`。此路径执行目标架构的原生回归，身份文件另记录 QEMU、Android linker 与 libc 摘要；图形输出与实际呈现效果仍需设备验证。
