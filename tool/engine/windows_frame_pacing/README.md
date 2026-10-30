# Windows 帧节奏引擎

该目录维护 Flutter 3.47.5 Windows x64 的隔离引擎补丁和重建入口。固定引擎提交为
`af7e796e161ae0bb1ff0758c71a7105418bd9ded`，depot_tools 提交为
`b1c2e86792a7f2b6576c181b7327ddd53b1a42a8`。

补丁在 ANGLE 支持时使用 DirectComposition 翻转式呈现，创建失败时记录错误并回退
原有窗口 Surface；两条路径均保留 Surface vsync。它以 DWM 的 QPC vblank 相位、刷新周期和当前
计数器校准引擎时间。绘制在当前周期开始，Surface 提交等待下一次 vblank；相位校准的
微小抖动不会重复占用同一周期。引擎启动时间不再决定正常 DWM 路径的帧相位；DWM 数据不可用、周期异常、相位过期或
测试指定周期时沿用原有回退。连续三次 DWM 数据失效后，该引擎实例保持普通 VSync 调度；Surface 同步继续开启。
计时线程在截止时间提前后重新进入等待，兼容按值保存
`wait_until` 截止时间的 C++ 标准库，避免继续等待旧截止时间。
对应引擎回归覆盖启动相位、刷新率变化、Surface 同步，以及计时线程唤醒与重排。
ANGLE D3D11 设备同时将最大排队帧数设为一帧，限制呈现积压；设置失败时记录
原生警告并继续使用驱动现有策略。

## 编译

需要 Windows、Python 3.11+、Git、Visual Studio C++ 工作负载和 Windows SDK。
构建使用独立目录，保留原 FVM SDK；源码与工具包占用较大空间，应预留足够磁盘容量。

```powershell
python tool/engine/windows_frame_pacing/build_engine.py --root <engine-root> --flutter-sdk <flutter-sdk> --visual-studio <visual-studio-root>
```

默认编译 Profile 引擎并运行相关原生回归；`--mode release` 编译 Release。
`--visual-studio-version` 默认 `2026`，使用其他版本时与 `--visual-studio` 安装目录配套指定。
`--skip-sync` 复用已下载依赖，仍执行 hooks；`--skip-tests` 用于首次仅编译引擎，
身份文件会记录原生测试尚未通过。首次下载使用本机代理设置或已有的 `HTTPS_PROXY`；
Git 长路径配置与 VS 工具链选择均限于本次进程树。
Windows SDK 默认读取安装登记；非默认位置也可传 `--windows-sdk E:/WindowsKits/10`。
`--windows-sdk-version 10.0.26100.0` 可指定已安装版本，默认选择安装目录中的最高版本。

脚本检查固定提交，调用 gclient 同步及 hooks，应用 `engine.patch`，通过 GN/Ninja
构建。已有检出提交不匹配或补丁冲突时保留原文件并终止。SDK 在编译完成前须保留，
隔离检出使用本机 SDK 的 Git 对象库。

输出目录为 `flutter/engine/src/out/piliaurora_windows_profile/` 或对应 Release 目录，
包含 `flutter_windows.dll` 与 `engine-identity.json`。身份文件登记源码提交、补丁摘要、
DLL 摘要、运行模式、架构和原生测试状态，格式遵循[共同身份协议](../README.md)。

## 对照采集

```powershell
pwsh -NoProfile -File tool/probes/windows/measure_danmaku.ps1 -PresentMonPath <presentmon.exe> -EngineLibrary <engine-root>/flutter/engine/src/out/piliaurora_windows_profile/flutter_windows.dll
```

采集入口通过统一构建脚本生成对应配置的探针，检查 Profile/x64、应用配置和引擎身份；`-SkipBuild` 复用相同身份的输出。
添加 `-Media <本地视频>` 测量视频合成负载。原始数据、引擎身份、同帧关联与
±1/±2/±3 汇总保存在独立采集目录；完整流程见[平台探针](../../probes/README.md#windows-弹幕帧节奏探针)。

## 应用构建

```powershell
pwsh -NoProfile -File tool/build.ps1 -Platform windows -Mode profile -WindowsEngineLibrary <engine-root>/flutter/engine/src/out/piliaurora_windows_profile/flutter_windows.dll
```

应用构建核对模式、固定提交、当前补丁、DLL 摘要和原生回归结果，构建普通入口后装配
自编引擎，并在应用输出目录保留 `engine-identity.json`。Release 需要先用 `--mode release`
编译同模式引擎，再将应用构建的 `-Mode` 改为 `release`。
省略 `-WindowsEngineLibrary` 使用 FVM 引擎，并清除应用输出目录的旧身份文件；构建流程不改写 FVM 引擎缓存。正式发布与 CI 使用 [Git 跟踪的 Release 预编译引擎](../../../third_party/flutter_engine/README.md)。
