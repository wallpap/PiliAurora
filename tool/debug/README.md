# 调试工具

此目录存放供维护者使用的隔离诊断入口和平台探针。它们不属于应用运行时，也不作为正式构建入口。

运行前先阅读对应脚本的参数说明和源码，确认目标平台、输入文件及输出目录。测试结果只说明该工具覆盖的范围；应用体验仍需按 [`doc/build-and-test.md`](../../doc/build-and-test.md) 中的目标平台要求验证。

## 暂停旋转探针

`paused_rotation.dart` 使用本地视频检查暂停后横屏 → 竖屏 → 横屏的整帧显示，配套 `paused_rotation_probe.py` 检查四象限、白色源边缘和暂停状态。输入必须是对应的测试图视频。

```powershell
fvm flutter build apk --debug --target tool/debug/paused_rotation.dart --no-pub
python tool/debug/paused_rotation_probe.py --adb <adb路径> --serial <emulator序列号> --apk build/app/outputs/flutter-apk/app-debug.apk --fixture <四象限测试视频>
```

探针会安装调试 APK、推送测试视频并清空目标模拟器日志，使用独占的只读模拟器实例。输出默认保存到 `build/rotation-smoke/`。退出码 0 表示三个阶段通过，1 表示旋转检查失败，2 表示初始画面无效或阶段不完整。此检查不覆盖旋转过程中的逐帧黑闪。

通过 `--dart-define=CREATE_ROTATION_FIXTURE=true` 构建入口可显示测试图，再用模拟器 `screenrecord` 录制 H.264 视频。先确认四象限与白边完整，排除系统弹窗污染。交付应用前使用默认入口重新构建。
