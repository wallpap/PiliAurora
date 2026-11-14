# 构建与测试

从仓库根目录运行本页命令。首次开发按环境、依赖、构建的顺序准备；修改已有功能时直接查[静态检查与测试](#静态检查与测试)。任务导航见[文档索引](../README.md#开发)。

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

Windows 构建同时从仓库内固定的 [libwebp decoder 源码](../../third_party/libwebp/UPSTREAM.md)编译 `piliaurora_image_worker.exe`，无需额外下载或动态库。Release 目录包含该 worker 与 `licenses/libwebp/` 的来源和许可，打包时随运行清单分发。区域后端夹具、独立原生构建和 Flutter 回归命令见[图片测试契约](../../test/common/widgets/image/CONTRACTS.md#区域后端和设备验收)。

Windows 各构建模式使用官网推荐的 shinchiro 标准预编译包，无需安装 MSYS2。本地与 GitHub Windows CI 按固定 URL 获取并校验 SHA-256；版本、来源及更新流程见 [mpv 说明](../../third_party/media_kit_libs_windows_video/UPSTREAM.md)。

Windows x64 另使用 [cnativeapi 预编译包](../../third_party/nativeapi/README.md)，内部 nativeapi 已静态链接。普通应用构建跳过这两个库的源码编译；更新源码后按该说明重建。WebView NuGet 依赖按固定版本保存在 `build/windows/x64/packages/`，Windows CI 缓存该目录及 Flutter/Pub 缓存。

## 安装依赖

```powershell
fvm install
fvm flutter pub get
```

## 构建

仓库入口默认构建 Release，自动准备依赖、应用框架补丁并装配已校验的预编译引擎。本地与发布 CI 使用同一套引擎和呈现策略，采用项及设备验收边界见[默认构建与策略](build-defaults.md)。

```powershell
pwsh -NoProfile -File tool/build.ps1 -Platform windows
pwsh -NoProfile -File tool/build.ps1 -Platform android
```

Windows 输出到 `build/windows/x64/runner/Release/`。Android 默认在 `build/release-apks/` 生成三个分 ABI APK，各自携带对应引擎身份；用 `-Abi arm64-v8a`、`armeabi-v7a` 或 `x86_64` 只构建一个架构。Android SDK 从 `-AndroidSdk`、`ANDROID_HOME`、`ANDROID_SDK_ROOT` 或 `android/local.properties` 依次定位，构建工具版本为 `37.0.0`，Release 签名配置见 `android/key.properties`。

`-Verbose` 显示依赖与补丁详情。依赖和补丁已准备时可传 `-SkipPubGet`、`-SkipPatch`；依赖来源检查仍执行。构建自动生成呈现配置并核对引擎模式、架构、固定提交、补丁、二进制摘要及原生回归状态，校验失败则终止。

本地与 CI 共用 `lib/scripts/build.ps1` 生成版本元数据：版本名取自 `pubspec.yaml`（当前为 `2.0.0`），构建号取自 `git rev-list --count HEAD`，每次新增提交后自动增长。入口将同一版本、提交和时间传入 Flutter 与应用，保持程序属性、关于页和更新检查一致。本地通过构建参数传递，不改写 `pubspec.yaml`；发布元数据通过 `-DartDefine` 传入时优先使用调用方的值。构建需要完整 Git 历史，浅克隆先运行 `git fetch --unshallow`；CI 已配置 `fetch-depth: 0`。

需要断点或热重载时显式传 `-Mode debug`，使用 FVM SDK 的 Debug 引擎；引擎相关的画面、资源与性能验收使用默认 Release。Profile 引擎维护及原生重建见[引擎工具](../../tool/engine/README.md)，日常构建无需指定引擎路径。

独立包名的 Android 测试包使用 `tool/build-android-test.ps1`，同样自动装配 arm64 Release 引擎，可与正式应用并存。输入、输出和参数见[工具入口](../../tool/README.md#平台构建)。

## 发布构建与附件

### 本地构建与发布工作流

本地发布验证使用上节默认构建命令。

Android APK 位于 `build/release-apks/PiliAurora-android-<ABI>-release.apk`，每包旁有身份 JSON 和构建日志；单架构构建也将最终签署的 APK 与身份同步到 `build/app/outputs/flutter-apk/app-release.apk` 及同名 JSON。Windows 运行目录位于 `build/windows/x64/runner/Release/`，编译期引擎配置自动写入 `build/windows-engine-config.json`，供打包前置校验使用。GitHub Release 由 `.github/workflows/build.yml` 手动触发并传入 `vX.Y.Z`，通过 `build_android` 和 `build_win_x64` 选择平台；预发布须启用 `prerelease`，需要先验证附件时可同时启用 `draft_release`。Android 使用对应架构的定制引擎生成三个分 ABI APK，Windows 使用定制引擎生成 x64 便携包和安装程序。引擎产物及身份文件随 Git 保存，CI 校验后直接装配，维护步骤见[预编译引擎](../../third_party/flutter_engine/README.md)。发布工作流以 tag 指定版本名，用提交数生成构建号，并写入本次构建的 `pubspec.yaml` 和 `pili_release.json`。

### Windows 打包与覆盖安装

Windows 的 fastforge 打包前置入口为 `tool/packaging/prepare_windows_package.py`，先装配并校验定制引擎，再生成 `piliaurora-runtime.sha256`。安装版和便携版携带相同的程序文件清单；Inno 模板要求该清单存在。覆盖安装完成后，旧清单中已退役且摘要未改变的程序文件会被清理，用户修改的文件和未登记文件会保留。从尚无清单的旧安装升级时，开始记录本次包的文件归属。

安装器通过 Windows Restart Manager 检测程序文件占用。应用收到已确认的更新退出请求后，通过原生消息通道进入退出流程，保存主窗口和播放小窗的本地进度并释放播放器，跳过关闭窗口时的托盘驻留设置；安装器保留强制关闭能力，用于拒绝退出的旧版本或无响应的进程。更新前应保存当前操作并结束播放。安装器沿用相同 AppId 的历史安装目录，并为快捷方式写入与运行进程一致的 `PiliAurora.Desktop` 标识。版本检查按 `tag_name` 的数字版本比较，跳过草稿与预发布；相同版本的构建时间或 build 后缀变化不触发更新提示。

### 打包回归

覆盖安装回归使用独占临时目录，编译并运行关闭系统集成的安装器夹具，验证程序更新、退役文件清理、用户文件保留和路径边界。进程关闭夹具覆盖正常退出、隐藏驻留、多个拒绝退出的独立进程与 DLL 占用，并检查其他目录的同名程序保持运行、更新无需重启 Windows；该夹具需要 .NET Framework C# 编译器。Windows 需要 PATH 中的 Inno Setup 6：

```powershell
python -m unittest discover -s tool/packaging -p '*_test.py' -v
fvm flutter test --no-pub test/utils/app_release_test.dart
```

## 静态检查与测试

提交时记录实际执行的命令和结果。测试位置、共享夹具和异步用例约定见[测试目录](../../test/README.md#目录与夹具)。

Windows 主机首次运行测试或从 Android 环境切回后，先执行 `pwsh -NoProfile -File lib/scripts/patch.ps1 windows -SkipPubGet`（依赖须已准备）。全量测试包含依赖 Windows Flutter 补丁的隐藏页面语义回收回归；直接使用 Android 补丁状态会导致这些用例失败。

```powershell
fvm flutter analyze --no-pub lib test tool
fvm flutter test
```

常规分析覆盖应用、测试和工具代码。本地依赖包有各自的依赖上下文；更新依赖包时，按[依赖维护流程](../../third_party/README.md)单独检查。全仓库分析会包含上游源码和实验代码，结果按来源区分。

PR 检查由 `.github/workflows/checks.yml` 独立执行，使用只读仓库权限。Linux 任务运行依赖验收、共享 CI 测试、Android 主机探针、采集器单元测试、呈现引擎身份与 APK 装配回归及 Windows 采样门控的主机探针。Windows 任务运行 CI 测试、页面与 WebView 保留回归，以及固定 libmpv 包的离线分片音轨回退回归，覆盖依赖实际 Windows 主机的全屏布局交接与原生 seek。严格分析范围为 `lib/plugin/pl_player lib/pages/danmaku test tool`；全量分析还应手动运行上述命令，当前 `lib/common/widgets/flutter/` 的上游控件副本存在既存提示。

CI 从 `.fvmrc` 读取 Flutter 固定版本，避免 Windows 为解析 `pubspec.yaml` 额外安装 yq；升级 SDK 时仍须同步 `pubspec.yaml` 的版本约束。同一 PR 有新提交时自动取消旧检查，手动检查与发布构建保留独立运行。Android 发布启用 Gradle 任务缓存，配合现有 Gradle 用户目录缓存复用可缓存的任务输出；Gradle 脚本、属性与 Pub 锁文件参与缓存键。实际命中率和耗时需在后续 GitHub Actions 运行中确认。

Android libmpv 的三个原生 JAR 另缓存 `build/media_kit_libs_android_video/20*/*.jar`，缓存键取插件 Gradle 脚本摘要；这些下载产物位于项目构建目录，未被 Gradle 用户目录缓存覆盖。插件仍在使用前逐个校验 SHA-256，缓存不包含 APK 或签名配置。

```powershell
fvm flutter analyze --no-pub lib/plugin/pl_player lib/pages/danmaku test tool
pwsh -NoProfile -File tool/run-native-probes.ps1
uv run --locked python tool/run_python_tests.py --suite android
```

依赖已准备后，可用统一入口运行 GitHub Actions 当前选择的测试文件：

```powershell
pwsh -NoProfile -File tool/run-ci-tests.ps1
```

`tool/run-ci-tests.ps1` 默认调用 `fvm flutter test --no-pub`，可用 `-Concurrency 4` 指定并行测试文件数，省略时采用 Flutter 默认值。两端共用会话、消息、设置和弹幕等回归；Windows 另测桌面与原生全屏交接，Linux 另测选定的 Android 模拟通道。依赖、补丁和来源检查需预先准备，脚本只运行测试。

Python 回归使用 `uv run --locked python tool/run_python_tests.py --jobs 4`，`--suite` 选择分组，`--native` 追加三项 C++ 主机探针。组间进程隔离并汇总退出码，Linux CI 复用同一入口。分组与平台条件见[工具说明](../../tool/README.md#python-回归与并行执行)。

定位单个功能时，可将相关测试文件或目录传给 `fvm flutter test`。测试按业务领域放在 `test/` 下，目录索引见 [`test/README.md`](../../test/README.md)。

账号凭证加密、旧明文迁移与设置备份兼容改动可运行：

```powershell
fvm flutter test --no-pub test/utils/credential_cipher_test.dart test/utils/credential_migration_test.dart test/utils/accounts test/services/settings/ test/utils/account_profile_lifecycle_test.dart
```

该组覆盖随机 nonce、损坏和未知版本密文拒绝、旧 Hive 凭证迁移及明文记录清理、账号与设置备份往返，以及播放子进程使用的加密账号快照读取。Android、Windows 应用升级和实际跨设备恢复仍需目标设备验证。

弹幕合并、后台处理与帧率改动可运行：

```powershell
fvm flutter test --no-pub test/pages/danmaku/merge_test.dart test/pages/danmaku/controller_test.dart test/pages/danmaku/merge_render_test.dart test/pages/danmaku/frame_rate_ticker_test.dart test/pages/danmaku/native_video_frame_sync_test.dart
```

推荐与热门分页改动可运行 `fvm flutter test --no-pub test/common/widgets/feed_pagination_test.dart`。这些是针对模块的验证入口，CI 当前选择的文件以 `tool/run-ci-tests.ps1` 为准。

消息、私信、未读角标和私信分享改动可运行：

```powershell
fvm flutter test --no-pub test/services/messaging/
```

该组测试覆盖账号切换、订阅释放、会话共享、分页竞争、发送与已读结果，以及分享协议字段。测试使用模拟响应，登录后的实际服务交互还需按[消息模块验证说明](../../lib/services/messaging/README.md#验证)检查。

弹幕容量对照和旧渲染器重建测量位于 `tool/experiments/danmaku/`，按需单独运行：

```powershell
fvm flutter test tool/experiments/danmaku/
```

实验入口、测量范围和结果解释见 [`tool/experiments/README.md`](../../tool/experiments/README.md)。

| 改动范围 | 建议验证 |
| --- | --- |
| 页面与控件 | 对应 `test/pages/` 测试和静态分析 |
| HTTP 与模型 | 对应 `test/http/` 和模型测试 |
| 服务、下载或直播 | 对应 `test/services/` 测试 |
| 播放器 | 对应 `test/plugin/` 测试，并按平台补充实机验证 |
| Android 或 JNI | Android 构建和相关测试 |
| Windows 窗口或 WebView | Windows 构建和对应平台测试 |

现有测试和构建覆盖已运行的环境。GPU、MediaCodec、驱动、真实 WebView 和音频输出还需在目标设备上检查。

Windows 输出与 shader 更新的验证入口见[视频输出说明](../maintenance/windows-video-output.md#原生库与验证)；设备探针的输入和副作用见[平台探针](../../tool/probes/README.md)。

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
