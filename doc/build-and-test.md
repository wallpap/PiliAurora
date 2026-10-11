# 构建与测试

## 环境

| 工具 | 当前配置 | 来源 |
| --- | --- | --- |
| Flutter | 3.47.5 | `.fvmrc`、`pubspec.yaml` |
| Dart | SDK `>=3.13.0` | `pubspec.yaml` |
| Gradle | 9.6.0 | `android/gradle/wrapper/gradle-wrapper.properties` |
| Android Gradle Plugin / Kotlin | 9.2.1 / 2.4.20 | `android/settings.gradle.kts` |
| JDK | 25，Gradle 与 Java/Kotlin 编译使用 | `android/gradle/gradle-daemon-jvm.properties`、`android/build.gradle.kts` |
| Android SDK | compileSdk / targetSdk 37；minSdk 由 Flutter 配置 | `android/app/build.gradle.kts` |

Android Studio 的 Gradle JDK 和 `JAVA_HOME` 都设为 25。JDK 25 是构建工具链要求，不决定 `minSdk`、`targetSdk` 或设备运行时版本。

Windows 构建需要安装 Visual Studio，并启用“使用 C++ 的桌面开发”工作负载。Windows 开发建议使用 PowerShell 7。

## 安装依赖

```powershell
fvm install
fvm flutter pub get
```

## 构建

仓库脚本会准备 Flutter 补丁和依赖，再调用对应平台的构建工具：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

将 `-Mode debug` 改为 `-Mode release` 可构建发布版。脚本参数和依赖来源检查见 [`tool/README.md`](../tool/README.md)。

## 静态检查与测试

```powershell
fvm flutter analyze --no-pub lib test tool
fvm flutter test
```

常规分析覆盖应用、测试和工具代码。本地依赖包有各自的依赖上下文；更新依赖包时，按 [`third_party/README.md`](../third_party/README.md) 单独检查。

依赖已准备后，可用统一入口运行 GitHub Actions 当前选择的测试文件：

```powershell
pwsh -NoProfile -File tool/run-ci-tests.ps1
```

`tool/run-ci-tests.ps1` 只调用 `fvm flutter test --no-pub`，不会运行 `pub get`、修改 Flutter SDK、应用补丁或构建应用。运行前需准备好依赖；依赖来源检查和补丁由 GitHub Actions 的独立步骤执行。

定位单个功能时，可将相关测试文件或目录传给 `fvm flutter test`。测试按业务领域放在 `test/` 下，目录索引见 [`test/README.md`](../test/README.md)。

弹幕容量对照和旧渲染器重建测量位于 `tool/experiments/danmaku/`，按需单独运行：

```powershell
fvm flutter test tool/experiments/danmaku/
```

实验入口、测量范围和结果解释见 [`tool/experiments/README.md`](../tool/experiments/README.md)。

| 改动范围 | 建议验证 |
| --- | --- |
| 页面与控件 | 对应 `test/pages/` 测试和静态分析 |
| HTTP 与模型 | 对应 `test/http/` 和模型测试 |
| 服务、下载或直播 | 对应 `test/services/` 测试 |
| 播放器 | 对应 `test/plugin/` 测试，并按平台补充实机验证 |
| Android 或 JNI | Android 构建和相关测试 |
| Windows 窗口或 WebView | Windows 构建和对应平台测试 |

测试和构建只覆盖实际运行过的环境。GPU、MediaCodec、驱动、真实 WebView 和音频输出还需要在目标设备上检查。

## 生成 Android JNI bindings

```powershell
fvm dart run tool/jnigen.dart
```

protobuf 和 JNI 产物应从对应源定义及生成流程更新。生成后检查差异并运行相关测试。

## 故障定位

- FVM 不可用时，检查 `fvm` 和 `dart` 是否在 PATH 中，以及 Flutter 版本是否与 `.fvmrc` 一致。
- 依赖获取失败时，检查网络、代理、缓存和 `pubspec.lock`。
- Android 构建失败时，检查 JDK 25、`JAVA_HOME`、Android SDK 和构建脚本输出。
- Windows 播放异常时，分别检查播放器初始化、硬件解码、渲染窗口和弹幕路径。

### Gradle 本地 socket 初始化失败

Windows 上若在编译前出现 `Unable to establish loopback connection`，且堆栈包含 `PipeImpl`、`UnixDomainSockets`，可将当前终端的临时目录改为仓库内 `.gradle-tmp` 后重试。`tool/build.ps1 -Platform android` 已设置这两个环境变量；直接运行 Flutter 构建时使用：

```powershell
$taskGradleTemp = Join-Path (Get-Location).Path '.gradle-tmp'
New-Item -ItemType Directory -Path $taskGradleTemp -Force | Out-Null
$env:TEMP = $taskGradleTemp
$env:TMP = $taskGradleTemp
fvm flutter build apk --debug --no-pub
```

这是本机临时目录相关的 Java socket 故障处理方式；若仍失败，检查实际堆栈并重新定位原因。IPv4 参数或 `--no-daemon` 未能解决本机这一故障。
