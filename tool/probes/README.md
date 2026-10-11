# 调试工具

此目录存放供维护者运行的隔离诊断工具和平台探针。这些工具不属于应用运行时或正式构建流程。

| 目录 | 内容 |
| --- | --- |
| `android/` | 暂停旋转测试入口、画面检查脚本和 Java 帧栅栏检查。 |
| `windows/` | 窗口回调、尺寸通道、纹理首帧和输出确认探针。 |
| `playback/` | 媒体加载烟测、跳转命令和断流恢复回放。 |
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

播放链路工具位于 `playback/`。`native_media_smoke.py` 的输入、独立音轨与跳转检查命令见[工具入口](../README.md#原生媒体加载烟测)。

## 暂停旋转探针

`paused_rotation.dart` 使用本地视频检查暂停后横屏、竖屏和再次横屏时的整帧显示。配套的 `paused_rotation_probe.py` 会检查四象限、视频白边和暂停状态。输入文件应使用对应的测试图视频。

入口使用当前 Android 固定 Surface 策略，旋转由 Flutter 的 `FittedBox` 缩放画面。硬件解码关闭，默认不限制源纹理尺寸；构建时传入 `--dart-define=ANDROID_TEXTURE_SCALING=true` 可启用设备物理显示尺寸限幅，与应用的纹理缩放开关对应。

```powershell
fvm flutter build apk --debug --target tool/probes/android/paused_rotation.dart --no-pub
uv run --locked python tool/probes/android/paused_rotation_probe.py --adb <adb路径> --serial <emulator序列号> --apk build/app/outputs/flutter-apk/app-debug.apk --fixture <四象限测试视频>
```

探针会安装调试 APK、推送测试视频并清空目标模拟器日志，因此应使用独占的测试模拟器。输出默认保存在 `build/rotation-smoke/`。退出码 0 表示三个阶段通过，1 表示旋转检查失败，2 表示初始画面无效或检查未完成。该工具不检查旋转过程中的逐帧黑闪。

使用 `--dart-define=CREATE_ROTATION_FIXTURE=true` 构建入口可显示测试图，再通过模拟器 `screenrecord` 录制 H.264 视频。确认四象限和白边完整，并排除系统弹窗干扰。交付应用前需用默认入口重新构建。

## Android 帧栅栏条件探针

`android/SurfaceFrameFenceProbe.java` 在主机 JVM 上验证生产 Java 类的时间戳、尺寸与 Surface 代次条件：

```powershell
New-Item -ItemType Directory -Path build/probe-validation/frame-fence -Force | Out-Null
javac -d build/probe-validation/frame-fence third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/SurfaceFrameFence.java tool/probes/android/SurfaceFrameFenceProbe.java
java -cp build/probe-validation/frame-fence com.alexmercerind.media_kit_video.SurfaceFrameFenceProbe
```

该入口检查帧接收条件，画面像素由模拟器旋转探针检查。

## Windows 尺寸通道回归探针

`windows_source_size_channel_probe.py` 使用 Flutter 的标准编码器和生产通道处理代码，验证 int32、int64 尺寸均能传入播放器。先完成 Windows 构建以生成 Flutter C++ 头文件，再运行：

```powershell
uv run --locked python tool/probes/windows/windows_source_size_channel_probe.py
```

需要 Python 和支持 C++17 的 `g++`，可用 `--compiler` 指定编译器。输出保存在 `build/windows-playback-diagnosis/`。探针使用模拟播放器，不覆盖 GPU 和实际视频播放。

## Windows 开播纹理回归探针

`windows_playback_startup_probe.py` 提取生产视口的尺寸提交方法，使用真实的截图交接和帧确认类，验证已配置的同尺寸输出在帧统计延迟时保持活画面、真实尺寸变化仍等待对应的渲染帧。

```powershell
uv run --locked python tool/probes/windows/windows_playback_startup_probe.py
uv run --locked python tool/probes/windows/windows_texture_frame_probe.py --compiler <g++路径>
```

前者通过 FVM 运行 Flutter 测试；后者编译生产纹理方法，检查初始纹理、有效首帧和同尺寸提交。生成文件位于 `build/windows-playback-diagnosis/`，GPU 和播放器通道由模拟对象替代。

## 播放器断流恢复回归探针

`playback_network_recovery_probe.py` 回放脱敏的 Windows curl 终止错误、Android HTTPS 提前结束和 MP4 截断错误，提取生产日志分发、播放器监听和重连方法，检查断流恢复、缓冲检查升级、错误合并、冷却窗口和媒体切换。暂停状态与 CDN 切换由 `test/plugin/pl_player/native_media_source_test.dart` 覆盖。

```powershell
uv run --locked python tool/probes/playback/playback_network_recovery_probe.py
```

通过 FVM 运行 Flutter 测试，生成文件写入 `build/playback-network-diagnosis/` 下的临时目录，运行结束后自动清理。原生播放器由状态桩替代，真实网络传输、GPU、MediaCodec 和长时间播放需要实机验证。
