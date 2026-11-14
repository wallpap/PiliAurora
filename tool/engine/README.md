# 引擎身份与维护

应用统一使用 `tool/build.ps1`，默认 Release 自动装配仓库内已通过原生回归的引擎。Windows 使用 `windowsDwmPaced`，Android 使用 `androidFramePlan`；普通命令见[构建与测试](../../doc/development/build-and-test.md#构建)，当前修复与策略见[默认构建与策略](../../doc/development/build-defaults.md)。

## 身份与配置

`engine_identity.py` 校验编译阶段产生的 `engine-identity.json`：模式、架构、固定框架和引擎提交、补丁、overlay、二进制摘要及原生回归状态。架构另按 ELF/PE 头检查，补丁与 overlay 按当前仓库重算。源码材料固定使用 LF 换行。

装配入口生成 `PILIAURORA_PRESENTATION_PROFILE` 与 `PILIAURORA_ENGINE_IDENTITY`，摘要绑定整份引擎身份。应用根据身份配置和平台支持条件选择呈现策略。调用者不能覆盖这两个定义或 `PILIAURORA_CONTENT_COMPOSITION`。原生回归未通过、材料不匹配或二进制变化时停止构建。

Windows 运行目录保留引擎和应用产物摘要；Release 编译期配置写入 `build/windows-engine-config.json`，打包前置入口核对它与最终 DLL 一致。Android 各 ABI 的 APK 在 `assets/piliaurora-engine-identity.json` 保留身份，包旁 JSON 另登记应用来源、参数和 APK 摘要。独立测试包使用相同验收流程。

Debug 使用 FVM 调试引擎与 `standard` 配置，构建后核对输出并移除该输出的旧引擎身份。直接执行 `fvm flutter build` 会绕过项目装配流程；涉及引擎修复的验收使用统一入口。

## 修改引擎

1. 按 [Android](frame_plan/README.md) 或 [Windows](windows_frame_pacing/README.md) 修改补丁或 overlay，在独立引擎检出中编译。
2. 完成对应架构、模式的原生回归；`--skip-tests` 的产物须补齐回归后重新生成身份。
3. 按[预编译产物维护](../../third_party/flutter_engine/README.md#更新产物)更新 Release 包和身份，运行普通构建及目标设备验收。
4. 更新[默认构建与策略](../../doc/development/build-defaults.md)中的采用项和验证边界。

`build.ps1` 的 `-EngineLibrary`（兼容 `-WindowsEngineLibrary`）供维护时验证尚未入库的同模式产物。Android 此时同时提供 `-FlutterSdk`、`-AndroidSdk`，支持 `-Abi`、`-DevRelease`、`-Output` 和 `-SourceApk`。Profile 无仓库预编译产物，必须提供对应库；Release 日常构建自动选库。

APK 复用核对入口、应用与本地依赖源码、ticker、引擎身份、编译参数和 APK 摘要。缺少身份或参数登记的旧包须重建。APK 装配不改写 SDK 引擎缓存，构建结束恢复 `android/local.properties` 和 `.dart_tool/package_config.json`。

两端构建、装配与身份回归使用统一测试分组：

```powershell
uv run --locked python tool/run_python_tests.py --suite engine --suite windows-engine --suite android-engine --jobs 3
```

采集命令和设备副作用见[平台探针](../probes/README.md)。Windows 内存诊断引擎位于 [windows_memory/](windows_memory/README.md)，仅用于归属和回收实验，不参与默认 Release。
