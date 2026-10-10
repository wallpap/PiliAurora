# 调试工具

此目录存放供维护者运行的隔离诊断工具和平台探针。这些工具不属于应用运行时或正式构建流程。

运行前查看脚本参数和源码，确认目标平台、输入文件及输出目录。工具结果只覆盖它实际检查的内容；应用行为还要按[构建与测试说明](../../doc/build-and-test.md)在目标平台验证。

## 暂停旋转探针

`paused_rotation.dart` 使用本地视频检查暂停后横屏、竖屏和再次横屏时的整帧显示。配套的 `paused_rotation_probe.py` 会检查四象限、视频白边和暂停状态。输入文件应使用对应的测试图视频。

```powershell
fvm flutter build apk --debug --target tool/debug/paused_rotation.dart --no-pub
python tool/debug/paused_rotation_probe.py --adb <adb路径> --serial <emulator序列号> --apk build/app/outputs/flutter-apk/app-debug.apk --fixture <四象限测试视频>
```

探针会安装调试 APK、推送测试视频并清空目标模拟器日志，因此应使用独占的测试模拟器。输出默认保存在 `build/rotation-smoke/`。退出码 0 表示三个阶段通过，1 表示旋转检查失败，2 表示初始画面无效或检查未完成。该工具不检查旋转过程中的逐帧黑闪。

使用 `--dart-define=CREATE_ROTATION_FIXTURE=true` 构建入口可显示测试图，再通过模拟器 `screenrecord` 录制 H.264 视频。确认四象限和白边完整，并排除系统弹窗干扰。交付应用前需用默认入口重新构建。

## Windows 尺寸通道回归探针

`windows_source_size_channel_probe.py` 使用 Flutter 的标准编码器和生产通道处理代码，验证 int32、int64 尺寸均能传入播放器。先完成 Windows 构建以生成 Flutter C++ 头文件，再运行：

```powershell
python tool/debug/windows_source_size_channel_probe.py
```

需要 Python 和支持 C++17 的 `g++`，可用 `--compiler` 指定编译器。输出保存在 `build/windows-playback-diagnosis/`。探针使用模拟播放器，不覆盖 GPU 和实际视频播放。

## Windows 开播纹理回归探针

`windows_playback_startup_probe.py` 提取生产视口的尺寸提交方法，使用真实的截图交接和帧确认类，验证已配置的同尺寸输出在帧统计延迟时保持活画面、真实尺寸变化仍等待对应的渲染帧。

```powershell
python tool/debug/windows_playback_startup_probe.py
python tool/debug/windows_texture_frame_probe.py --compiler <g++路径>
```

前者通过 FVM 运行 Flutter 测试；后者编译生产纹理方法，检查初始纹理、有效首帧和同尺寸提交。生成文件位于 `build/windows-playback-diagnosis/`，GPU 和播放器通道由模拟对象替代。
