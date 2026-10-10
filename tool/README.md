# 构建工具

项目使用 `.fvmrc` 声明的 Flutter 版本。准备好 Android SDK 或 Visual Studio 后，在仓库根目录运行：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

重新生成 Android JNI bindings：

```powershell
fvm dart run tool/jnigen.dart
```

## 原生媒体加载烟测

Windows 构建完成后，使用已有 Python 和 libmpv 验证独立音轨、特殊字符路径及重载。
传入至少数秒的本地视频，不会访问网络；测试用静音 WAV 写入 `build/native-playback-smoke/`。

```powershell
python tool/native_media_smoke.py --library build/windows/x64/runner/Debug/libmpv-2.dll --video <本地视频文件>
```

增加 `--seek-target <秒数>` 可检查 Android 独立音轨的跳转命令，覆盖前进、后退与重复跳转。命令由 `tool/debug/native_seek_command.dart` 调用正式构造器生成，烟测断言视频恢复时音轨等待小于 100 ms。视频须长于目标时间且目标落在关键帧之间；`--keyframes-control` 使用旧策略作对照，预期能触发无声断言失败。

```powershell
python tool/native_media_smoke.py --library build/windows/x64/runner/Debug/libmpv-2.dll --video <本地视频文件> --seek-target 2.4
```

该检查使用 Windows libmpv、空音视频输出与软件解码，不包含 Android GPU/MediaCodec、实际扬声器或完整应用性能测试。涉及设备画面和硬件解码的结果仍需在目标设备上验证。

## 依赖版本与来源检查

```powershell
fvm dart run tool/check_dependencies.dart
fvm flutter test --no-pub test/architecture/dependency_policy_test.dart test/common/widgets/font_awesome_icons_test.dart
```

该工具只读取工作区文件，检查 Git 来源、path 范围、来源 SHA、许可证、版本登记与锁文件一致性，也检查合并来源的目录和许可证登记。可用位置参数检查指定工作区。普通更新与本地定制包更新流程见 `third_party/README.md`。本地构建和 CI 会在解析依赖后检查；构建使用 `--enforce-lockfile`，版本更新需显式运行 `flutter pub get` 或针对包执行 `flutter pub upgrade` 后提交锁文件。
