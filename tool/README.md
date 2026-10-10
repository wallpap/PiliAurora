# 构建工具

项目使用 `.fvmrc` 指定的 Flutter 版本。安装 Android SDK 或 Visual Studio 后，在仓库根目录运行：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

重新生成 Android JNI bindings：

```powershell
fvm dart run tool/jnigen.dart
```

## 原生媒体加载烟测

Windows 构建完成后，可用 Python 和 libmpv 检查独立音轨、特殊字符路径和媒体重载。
传入数秒以上的本地视频即可运行；工具不访问网络，并将测试用静音 WAV 写入 `build/native-playback-smoke/`。

```powershell
python tool/native_media_smoke.py --library build/windows/x64/runner/Debug/libmpv-2.dll --video <本地视频文件>
```

传入 `--seek-target <秒数>` 可检查 Android 独立音轨的前进、后退和重复跳转命令。`tool/debug/native_seek_command.dart` 会调用应用使用的命令构造器；烟测检查视频恢复后音轨等待是否小于 100 ms。视频长度应超过目标时间，目标时间应落在关键帧之间。`--keyframes-control` 使用旧策略作对照，预期会触发静音断言。

```powershell
python tool/native_media_smoke.py --library build/windows/x64/runner/Debug/libmpv-2.dll --video <本地视频文件> --seek-target 2.4
```

该检查通过 Windows libmpv、空音视频输出和软件解码运行，不覆盖 Android GPU/MediaCodec、真实扬声器或完整应用性能。画面和硬件解码仍需在目标设备上验证。

## 依赖版本与来源检查

```powershell
fvm dart run tool/check_dependencies.dart
fvm flutter test --no-pub test/architecture/dependency_policy_test.dart test/common/widgets/font_awesome_icons_test.dart
```

该工具只读工作区，检查 Git 来源、path 范围、来源 SHA、许可证、版本登记与锁文件，并核对合并依赖的目录和许可证信息。可用位置参数指定工作区。普通依赖更新和定制包维护流程见 `third_party/README.md`。本地构建和 CI 会在依赖解析后执行检查，构建命令使用 `--enforce-lockfile`。更新版本时，运行 `flutter pub get` 或针对目标包执行 `flutter pub upgrade`，再提交锁文件。
