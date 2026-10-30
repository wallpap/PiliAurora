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

Windows 各构建模式使用 `third_party/mpv/prebuilt/` 中的预编译包，无需为普通应用构建安装 MSYS2。本地与 GitHub Windows CI 校验归档、构建材料和运行文件摘要；原生库更新时可在 UCRT64 终端或独立工作流中从固定源码重建，见[mpv 构建说明](../third_party/mpv/README.md)。

Windows x64 另使用 [cnativeapi 预编译包](../third_party/nativeapi/README.md)，内部 nativeapi 已静态链接。普通应用构建跳过这两个库的源码编译；更新源码后按该说明重建。WebView NuGet 依赖按固定版本保存在 `build/windows/x64/packages/`，Windows CI 缓存该目录及 Flutter/Pub 缓存。

## 安装依赖

```powershell
fvm install
fvm flutter pub get
```

## 构建

仓库脚本统一准备一次依赖，复用已应用的 Flutter 和 `material_ui` 补丁，再调用对应平台的构建工具：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

将 `-Mode debug` 改为 `-Mode release` 可构建发布版。默认输出显示准备步骤汇总和构建进度，`-Verbose` 显示详细输出。已准备的环境可按需使用 `-SkipPubGet` 和 `-SkipPatch`，参数条件与依赖来源检查见 [`tool/README.md`](../tool/README.md)。

Android 默认生成包含所有 ABI 的通用 APK。可使用 `-Abi arm64-v8a`、`-Abi armeabi-v7a` 或 `-Abi x86_64` 只打包指定架构；省略参数时保留通用 APK 行为。

Android 帧计划测试包使用[隔离引擎构建入口](../tool/engine/frame_plan/README.md)。`tool/build-android-test.ps1` 使用 FVM 预编译引擎；需要帧计划的 dev 包时，先编译同一运行模式的自定义引擎，再用 `build_apk.py --mode dev-release` 装配，沿用本机 Release 签名。两种 dev 构建均输出到 `build/android-test/`；帧计划产物另有身份 JSON，记录模式、包名、APK、引擎和补丁摘要。隔离 SDK、引擎检出及二进制留在本地，源码补丁与重建步骤随仓库维护。

两端自编引擎共用[身份与呈现配置协议](../tool/engine/README.md)，由 `tool/build.ps1` 分派装配。Android 可传 `-EngineLibrary`、`-FlutterSdk`、`-AndroidSdk` 和 `-Abi` 选择对应架构的 Profile/Release；arm64 独立 Release 测试包再传 `-DevRelease`。

Windows 帧节奏自编引擎使用[固定补丁与隔离构建入口](../tool/engine/windows_frame_pacing/README.md)。先构建并通过原生回归，再显式装配同模式的 Profile/Release 引擎：

```powershell
pwsh -NoProfile -File tool/build.ps1 -Platform windows -Mode profile -WindowsEngineLibrary <engine-root>/flutter/engine/src/out/piliaurora_windows_profile/flutter_windows.dll
```

脚本核对框架／引擎固定提交、模式、x64 架构、当前补丁／overlay、DLL 摘要及原生回归状态，并在应用输出目录保留 `engine-identity.json`。省略 `-WindowsEngineLibrary` 使用 FVM 引擎并清除旧身份文件；正式发布与 CI 使用 [Git 跟踪的 Release 预编译引擎](../third_party/flutter_engine/README.md)。

## 发布构建与附件

本地发布验证分别执行：

```powershell
pwsh -File tool/build.ps1 -Platform android -Mode release
pwsh -File tool/build.ps1 -Platform windows -Mode release
```

Android 通用 APK 位于 `build/app/outputs/flutter-apk/app-release.apk`，Windows 运行目录位于 `build/windows/x64/runner/Release/`。正式 GitHub Release 由 `.github/workflows/build.yml` 手动触发并传入 `vX.Y.Z`：Android 使用对应架构的定制引擎生成三个分 ABI APK，Windows 使用定制引擎生成 x64 便携包和安装程序。引擎产物及身份文件随 Git 保存，CI 校验后直接装配，维护步骤见[预编译引擎](../third_party/flutter_engine/README.md)。版本名与构建号取自 `pubspec.yaml`，工作流会用 tag 重写本次构建的版本和 `pili_release.json`。

Windows 的 fastforge 打包前置入口为 `tool/packaging/prepare_windows_package.py`，先装配并校验定制引擎，再生成 `piliaurora-runtime.sha256`。安装版和便携版携带相同的程序文件清单；Inno 模板要求该清单存在。覆盖安装完成后，旧清单中已退役且摘要未改变的程序文件会被清理，用户修改的文件和未登记文件会保留。从尚无清单的旧安装升级时，开始记录本次包的文件归属。

安装器通过 Windows Restart Manager 检测程序文件占用。应用收到已确认的更新退出请求后，通过原生消息通道进入退出流程，保存主窗口和播放小窗的本地进度并释放播放器，跳过关闭窗口时的托盘驻留设置；安装器保留强制关闭能力，用于拒绝退出的旧版本或无响应的进程。更新前应保存当前操作并结束播放。安装器沿用相同 AppId 的历史安装目录，并为快捷方式写入与运行进程一致的 `PiliAurora.Desktop` 标识。版本检查按 `tag_name` 的数字版本比较，跳过草稿与预发布；相同版本的构建时间或 build 后缀变化不触发更新提示。

覆盖安装回归使用独占临时目录，编译并运行关闭系统集成的安装器夹具，验证程序更新、退役文件清理、用户文件保留和路径边界。进程关闭夹具覆盖正常退出、隐藏驻留、多个拒绝退出的独立进程与 DLL 占用，并检查其他目录的同名程序保持运行、更新无需重启 Windows；该夹具需要 .NET Framework C# 编译器。Windows 需要 PATH 中的 Inno Setup 6：

```powershell
python -m unittest discover -s tool/packaging -p '*_test.py' -v
fvm flutter test --no-pub test/utils/app_release_test.dart
```

## 静态检查与测试

提交时记录实际执行的命令和结果。

```powershell
fvm flutter analyze --no-pub lib test tool
fvm flutter test
```

常规分析覆盖应用、测试和工具代码。本地依赖包有各自的依赖上下文；更新依赖包时，按[依赖维护流程](../third_party/README.md)单独检查。全仓库分析会包含上游源码和实验代码，结果按来源区分。

PR 检查由 `.github/workflows/checks.yml` 独立执行，以只读仓库权限运行依赖验收、CI 测试、Android 主机探针、采集器单元测试、呈现引擎身份与 APK 装配回归及 Windows 采样门控主机探针。严格分析范围为 `lib/plugin/pl_player lib/pages/danmaku test tool`；全量分析还应手动运行上述命令，当前 `lib/common/widgets/flutter/` 的上游控件副本存在既存提示。

```powershell
fvm flutter analyze --no-pub lib/plugin/pl_player lib/pages/danmaku test tool
pwsh -NoProfile -File tool/run-native-probes.ps1
uv run --locked python -m unittest discover -s tool/probes/android -p '*_test.py' -v
```

依赖已准备后，可用统一入口运行 GitHub Actions 当前选择的测试文件：

```powershell
pwsh -NoProfile -File tool/run-ci-tests.ps1
```

`tool/run-ci-tests.ps1` 只调用 `fvm flutter test --no-pub`，不会运行 `pub get`、修改 Flutter SDK、应用补丁或构建应用。运行前需准备好依赖；依赖来源检查和补丁由 GitHub Actions 的独立步骤执行。

定位单个功能时，可将相关测试文件或目录传给 `fvm flutter test`。测试按业务领域放在 `test/` 下，目录索引见 [`test/README.md`](../test/README.md)。

弹幕合并、后台处理与帧率改动可运行：

```powershell
fvm flutter test --no-pub test/pages/danmaku/merge_test.dart test/pages/danmaku/controller_test.dart test/pages/danmaku/merge_render_test.dart test/pages/danmaku/frame_rate_ticker_test.dart test/pages/danmaku/native_video_frame_sync_test.dart
```

推荐与热门分页改动可运行 `fvm flutter test --no-pub test/common/widgets/feed_pagination_test.dart`。这些是针对模块的验证入口，CI 当前选择的文件以 `tool/run-ci-tests.ps1` 为准。

消息、私信、未读角标和私信分享改动可运行：

```powershell
fvm flutter test --no-pub test/services/messaging/
```

该组测试覆盖账号切换、订阅释放、会话共享、分页竞争、发送与已读结果，以及分享协议字段。测试使用模拟响应，登录后的实际服务交互还需按[消息模块验证说明](../lib/services/messaging/README.md#验证)检查。

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

现有测试和构建覆盖已运行的环境。GPU、MediaCodec、驱动、真实 WebView 和音频输出还需在目标设备上检查。

Windows 输出与 shader 更新的验证入口见[视频输出说明](windows-video-output.md#原生库与验证)；设备探针的输入和副作用见[平台探针](../tool/probes/README.md)。

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

### Gradle 原生访问与目录监听

JDK 25 下，Gradle 启动器使用 `--enable-native-access=ALL-UNNAMED` 显式允许加载原生库，避免原生访问警告。`tool/build.ps1 -Platform android` 通过 `JAVA_OPTS` 传递此参数；Android CI 通过 `GRADLE_OPTS` 传递。直接运行 Flutter 或 Gradle 时，可在当前终端的 `JAVA_OPTS` 中追加此参数。

Android CI 另设置 `-Dorg.gradle.vfs.watch=false`，绕过重复目录监听异常 `Already watching path`。这会关闭跨构建保留文件系统状态的优化，本地构建保留默认监听行为。
