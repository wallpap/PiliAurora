# 工具入口

从仓库根目录运行各命令。工具按用途分组：

| 位置 | 用途 |
| --- | --- |
| `build.ps1`、`jnigen.dart` | 平台构建与 JNI 生成，保留稳定入口。 |
| `build-android-test.ps1` | 构建独立包名的 arm64 Release 测试包。 |
| `run-ci-tests.ps1` | 本地运行 GitHub Actions 选择的测试范围。 |
| `run_python_tests.py` | 按组并行运行 Python 回归，可附加 C++ 主机探针。 |
| `run-native-probes.ps1` | 使用项目固定 Flutter 源码执行 Android 主机 Java 探针。 |
| `check_dependencies.dart` | 依赖版本、来源和许可证验收。 |
| `verify_libmpv.py` | 校验 Windows libmpv 下载归档、合并通知及原文哈希。 |
| [`packaging/`](packaging/README.md) | Windows 打包前置、程序文件清单及覆盖安装回归。 |
| [`probes/`](probes/README.md) | Android、Windows、播放链路和事件循环的隔离回归探针。 |
| [`experiments/`](experiments/README.md) | 按业务领域组织的按需对照与性能测量。 |
| [`engine/`](engine/README.md) | 默认引擎的身份、配置生成、装配协议及原生维护入口。 |
| [`engine/frame_plan/`](engine/frame_plan/README.md) | Android 帧计划的固定引擎补丁、隔离构建与设备验证。 |
| [`engine/windows_frame_pacing/`](engine/windows_frame_pacing/README.md) | Windows 帧节奏的固定引擎补丁、隔离构建与呈现对照。 |
| [`engine/windows_memory/`](engine/windows_memory/README.md) | Windows 专用内存诊断引擎与资源观测。 |
| [`artwork/`](artwork/README.md) | 图标、插画源稿及资源导出。 |
| [`artwork/icons/`](artwork/icons/README.md) | SVG 图标字体与 Dart 常量生成。 |

默认自动化测试位于 [`test/`](../test/README.md)，测试选择方式见[构建与测试说明](../doc/development/build-and-test.md)。

`lib/scripts/patch.ps1` 及其相邻补丁由构建入口使用；`lib/scripts/material/` 对应 material_ui，外层补丁对应 Flutter SDK。`lib/scripts/build.ps1` 是发布工作流写入版本与 `pili_release.json` 的前置步骤，日常构建仍用 `tool/build.ps1`。

## 本地 CI 测试

依赖已准备后，在仓库根目录运行与 GitHub Actions 相同的测试范围：

```powershell
pwsh -NoProfile -File tool/run-ci-tests.ps1
```

`run-ci-tests.ps1` 默认使用 FVM，通过 `flutter test --no-pub` 执行 GitHub Actions 选择的范围，覆盖依赖政策、诊断、消息、设置、弹幕及播放恢复等模块；清单以脚本中的 `$ciTests` 为准。默认清单显式选择关键行为回归；扩大帧率矩阵、实验对照和其余模块测试在本地通过 `fvm flutter test` 按需运行。依赖需预先准备；脚本不解析或安装依赖、不修改 Flutter SDK、不应用补丁，也不构建应用。GitHub Actions 由补丁步骤统一解析一次依赖，随后运行依赖验收工具并调用同一测试脚本；测试和构建阶段均使用 `--no-pub`。

独立测试文件由 Flutter 并行执行，默认采用其并发配置；传入 `-Concurrency 4` 可指定同时运行的文件数。共用构建输出的 Flutter 命令仍使用同一入口执行。

`.github/workflows/checks.yml` 在 PR 和手动触发时以 `contents: read` 执行检查。Linux 任务覆盖依赖验收、严格静态分析、共享 CI 测试、Java 探针及 Python 工具回归；Windows 任务覆盖 CI 测试及页面、WebView 回归，原生全屏时序测试只在 Windows 主机运行。`.github/workflows/build.yml` 统一构建 Android 和 Windows 发布包，可分别选择平台，并在 Windows 构建前校验 libmpv 与 cnativeapi 预编译包。

Java 探针要求 PATH 中有 JDK 25，依赖已通过固定 Flutter SDK 准备：

```powershell
pwsh -NoProfile -File tool/run-native-probes.ps1
```

入口从 `.dart_tool/package_config.json` 定位 SDK，核对 `.fvmrc` 版本，编译实际 `SurfaceTextureWrapper.java`；源码缺失或编译、断言失败会返回非零退出码。产物保存在 `build/probe-validation/android/`。覆盖范围与设备采集命令见[平台探针](probes/README.md)。

## 平台构建

Windows 构建使用[标准上游 mpv 预编译包](../third_party/media_kit_libs_windows_video/UPSTREAM.md)，构建脚本自动校验和解压。工具链要求见[构建与测试](../doc/development/build-and-test.md)。

项目使用 `.fvmrc` 固定 Flutter，`build.ps1` 默认构建 Release，自动选择仓库预编译引擎。日常命令、输出、Debug 调试及签名要求统一见[构建与测试](../doc/development/build-and-test.md#构建)，引擎与应用默认策略见[默认构建与策略](../doc/development/build-defaults.md)。

Android 不传 `-Abi` 时生成三个分架构 APK；传入 `-Abi arm64-v8a`、`armeabi-v7a` 或 `x86_64` 时只生成对应架构。Windows 不接受 `-Abi`。

真机性能测试可构建独立包名的 arm64-v8a release 包：

```powershell
pwsh -NoProfile -File tool/build-android-test.ps1
```

脚本通过 `PILIAURORA_TEST_RELEASE=true` 启用现有 `dev` 包名和应用名，自动装配默认 arm64-v8a Release 引擎。包名为 `io.github.wallpap.piliaurora.dev`，应用名为 `PiliAurora dev`，可与正式应用并存，账号与私有数据独立。沿用本机 release 签名配置，输出到 `build/android-test/PiliAurora-dev-arm64-v8a-release.apk`，保留同名身份 JSON 并显示 SHA256。支持 `-SkipPubGet`、`-SkipPatch` 和 `-Verbose`；构建参数通过子进程传递，结束后恢复原有环境变量。

构建脚本统一执行一次 `pub get --enforce-lockfile`，随后检查并补齐补丁、验收依赖来源，最后通过 `--no-pub` 构建。已应用的补丁会复用；切换到 Windows 时会移除项目的 Android 专用补丁。补丁目标按 `.dart_tool/package_config.json` 的实际解析结果定位。

常规输出显示准备步骤的汇总和构建进度。使用 `-Verbose` 可查看完整依赖解析输出和逐项补丁状态；步骤失败时会显示错误详情。依赖声明和锁文件未改动、依赖已准备时，可传入 `-SkipPubGet`；补丁已准备时，可再传入 `-SkipPatch`：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug -SkipPubGet -SkipPatch
```

CI 直接调用 `lib/scripts/patch.ps1` 时，补丁脚本会先准备依赖；调用方已执行依赖解析时可传入 `-SkipPubGet`。

重新生成 Android JNI bindings：

```powershell
fvm dart run tool/jnigen.dart
```

## Python 工具环境

Python 探针使用根目录的 `.python-version`、`pyproject.toml` 和 `uv.lock` 管理环境。首次准备环境时，在仓库根目录运行：

```powershell
uv python install 3.14
uv sync --locked
```

之后用 `uv run --locked python ...` 启动 Python 工具。Pillow 固定为 13.0.0，供视觉资源导出、截图检查及图片解码夹具使用，与 Windows CI 一致；其余 Python 工具使用标准库。

## Python 回归与并行执行

```powershell
uv run --locked python tool/run_python_tests.py --list
uv run --locked python tool/run_python_tests.py --jobs 4
uv run --locked python tool/run_python_tests.py --suite engine --suite android-engine --jobs 2
uv run --locked python tool/run_python_tests.py --native --jobs 4
```

默认运行工具入口、Android/Windows 探针、引擎身份、两端引擎构建、打包，以及 Android/弹幕离线分析器共 9 组回归；`--suite` 可重复选择，`--jobs` 默认不超过 4。各组使用当前 Python 解释器启动独立进程，避免同名模块串用，日志按组输出。所有选定组完成后汇总，任一失败返回非零退出码。

`--native` 追加帧采样、ANGLE 回滚及 renderer 释放三项 C++17 主机探针，需要 g++。Linux CI 使用同一入口。依赖平台、编译器、Inno Setup 或图片 worker 的用例保留原跳过条件，需核对日志中的 skipped。图片原生用例先按[图片测试契约](../test/common/widgets/image/CONTRACTS.md#区域后端和设备验收)准备夹具。

此入口只运行回归。SDK 补丁、应用/引擎构建及夹具生成按依赖顺序执行；性能、GPU 和真机测量单独运行，避免资源竞争影响数据。

## 原生与设备验证

媒体加载、独立音轨、跳转、旋转、纹理首帧和超分切换的运行命令集中在[平台探针](probes/README.md)。探针分别使用模拟对象、原生库或测试设备，运行前按入口说明准备输入文件与输出目录。

## 依赖版本与来源检查

```powershell
fvm dart run tool/check_dependencies.dart
fvm flutter test --no-pub test/architecture/dependency_policy_test.dart
```

该工具只读工作区，检查 Git 来源、path 范围、来源 SHA、许可证、版本登记与锁文件，并核对合并依赖的目录和许可证信息。可用位置参数指定工作区。普通依赖更新和定制包维护流程见 `third_party/README.md`。本地构建和 CI 会在依赖解析后执行检查，依赖解析使用 `--enforce-lockfile`。更新版本时先修改精确约束，再运行 `fvm flutter pub get` 并核对锁文件差异。

## 播放图标资源

播放图标的媒体卡片、播放三角和进度细节源稿保存在 `tool/artwork/play.svg`，阴影由 `tool/generate_play_icon.dart` 预渲染。从仓库根目录重新生成 1×、2×、3×、4× PNG：

```powershell
fvm flutter test --no-pub tool/generate_play_icon.dart
```

产物为 `assets/images/play.png` 及同目录下的分辨率变体。图形逻辑尺寸为 60×60，四周各留 12 像素透明边距容纳阴影；`PlayIcon` 在布局时扣除该边距。修改源定义后需同步更新这四张资源。

## 应用插画与背景

可编辑 SVG 与导出脚本位于 `tool/artwork/`；角色应用图标、硬币和投币盒的 imagegen 原稿位于 `tool/artwork/raster/`。使用 `fvm flutter test --no-pub tool/generate_app_artwork.dart tool/generate_play_icon.dart` 导出，再运行 `python tool/artwork/export.py` 同步头像、动画和 Android / Windows 图标。仅更新应用图标时运行 `python tool/artwork/export.py --icons-only`，从四款浅色原稿同步明暗图标、启动图和 ICO。投币 GIF 的运动轨迹定义在 `tool/artwork/coin_motion.py`；资源清单、背景导出参数和实际提示词见[资源说明](artwork/README.md)。
