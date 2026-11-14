# 呈现引擎构建协议

应用统一使用 `tool/build.ps1` 装配引擎，普通 FVM 构建采用 `standard`。自编配置为 Android 的 `androidFramePlan` 和 Windows 的 `windowsDwmPaced`；平台补丁、编译和原生回归仍各自维护。

## 身份与配置

`engine_identity.py` 校验编译阶段产生的 `engine-identity.json`：`schemaVersion`、`profile`、`frameworkCommit`、`engineCommit`、`patchSha256`、`overlaySha256`、`binarySha256`、`mode`、`architecture`、`nativeTestsPassed`。二进制架构另按 ELF/PE 头检查，补丁与 overlay 摘要按当前仓库重算。

补丁与 overlay 源文件固定使用 LF 换行，保证 Windows 与 WSL 检出的构建材料摘要一致。

装配入口生成 `PILIAURORA_PRESENTATION_PROFILE` 与 `PILIAURORA_ENGINE_IDENTITY`，摘要绑定整份引擎身份。应用启动读取配置，弹幕调度根据配置及当前平台支持条件选择策略。自编装配要求原生回归通过；`--skip-tests` 产生的身份可用于继续开发，装配前须重新编译并完成回归。

Windows 输出目录保留身份和应用产物摘要。Android APK 内的 `assets/piliaurora-engine-identity.json` 保留引擎身份，APK 旁的 JSON 另在 `application` 中登记应用来源、编译参数和 APK 摘要。APK 复用会核对当前 Dart 来源与本地依赖源码、入口、引擎身份、参数和 APK 摘要。标准构建核对包内引擎与 FVM 产物，再移除该输出的旧自编身份。

## 装配

```powershell
pwsh -NoProfile -File tool/build.ps1 -Platform windows -Mode profile -EngineLibrary <flutter_windows.dll>
pwsh -NoProfile -File tool/build.ps1 -Platform android -Mode profile -EngineLibrary <libflutter.so> -FlutterSdk <隔离SDK> -AndroidSdk <AndroidSDK>
pwsh -NoProfile -File tool/build.ps1 -Platform android -Mode release -DevRelease -EngineLibrary <libflutter.so> -FlutterSdk <隔离SDK> -AndroidSdk <AndroidSDK>
```

Windows 兼容原来的 `-WindowsEngineLibrary` 参数。Android 自编装配支持三种 ABI 的正式 Release、Profile，以及 arm64 独立 dev Release 包。`-Target`、`-DartDefine` 传递应用入口与自定义参数；Android 的 `-SourceApk` 复用已验证 APK，`-Output` 指定输出。呈现配置参数由构建入口保留。

编译与原生测试见 [Android](frame_plan/README.md)、[Windows](windows_frame_pacing/README.md)。设备采集入口见 [平台探针](../probes/README.md)。

```powershell
python -m unittest discover -s tool/engine -p '*_test.py' -v
python -m unittest discover -s tool/engine/windows_frame_pacing -p '*_test.py' -v
python -m unittest discover -s tool/engine/frame_plan -p '*_test.py' -v
```

## 正式 Release 与多架构装配

Android 引擎编译入口支持 `--architecture arm`、`arm64`、`x64`，分别对应 `armeabi-v7a`、`arm64-v8a`、`x86_64`。每个架构使用独立输出目录、二进制摘要和原生回归结果。编译阶段使用的 `--skip-tests` 会将身份中的原生回归状态记为未通过，正式装配前需要完成对应架构的原生回归。

APK 装配入口使用 `--mode release --abi <ABI>` 构建正式包名，沿用 Release 签名；`--mode dev-release` 继续构建 `.dev` 测试包。统一入口对应 `tool/build.ps1 -Platform android -Mode release -Abi <ABI> -EngineLibrary <libflutter.so> -FlutterSdk <隔离SDK> -AndroidSdk <AndroidSDK>`。每份 APK 绑定当前架构的引擎身份，装配后校验包内引擎摘要与 ABI。
