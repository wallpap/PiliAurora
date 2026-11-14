# Windows 帧节奏引擎

本目录维护 Flutter 3.47.5 Windows x64 引擎补丁及重建入口，固定版本如下：

| 依赖 | 提交 |
| --- | --- |
| Flutter 引擎 | `af7e796e161ae0bb1ff0758c71a7105418bd9ded` |
| depot_tools | `b1c2e86792a7f2b6576c181b7327ddd53b1a42a8` |
| ANGLE（独立 Git 依赖） | `84027aca9b71c9ba335bd000dad1107b8810a511` |

## 呈现与计时

ANGLE 支持时使用 DirectComposition 翻转呈现，创建失败则记录错误并回退窗口 Surface，两条路径均保留 vsync。DWM 的 QPC vblank 相位、刷新周期和当前计数器用于校准引擎时间：当前周期开始绘制，Surface 提交等待下一次 vblank；校准抖动不会重复占用同一周期。

DWM 数据不可用、周期异常、相位过期或测试指定周期时使用原调度。连续三次 DWM 数据失效后，本实例保持普通 VSync，Surface 同步仍开启。计时线程遇截止时间提前时重新等待，兼容按值保存 `wait_until` 截止时间的标准库。回归覆盖启动相位、刷新率变化、Surface 同步、唤醒及重排。

ANGLE D3D11 最大排队帧数设为一帧；设置失败记录原生警告并使用驱动策略。

## 无障碍子节点

Windows 无障碍查询检查 owner bridge 和实际 child 是否仍有效，避免按旧计数准入后解引用空节点。合法 child 与 SELF 查询保留原 COM 行为。

`AccessibilityChildLookupTest.*` 通过真实 Windows delegate、AXTree 和 `IAccessible::get_accChild` 覆盖合法查询、越界、旧计数下 child 缺失及 bridge 过期。夹具仅模拟框架启动，不加载虚构 AOT；child 缺失用例保留实际空查找，并与已有无障碍回归一同运行。

## 外部视频纹理

Windows 外部 D3D 纹理收到空描述符或空句柄时释放 EGL 导入并清除句柄缓存。相同句柄
恢复后重新导入；创建或绑定失败不缓存成功身份，回收候选资源后允许下一帧重试。
描述符的释放回调在所有字段读取完成后恰好执行一次，失败路径同样释放。

`ExternalTextureD3dTest.*` 使用真实 D3D 共享纹理与 EGL，覆盖空描述符、空句柄、导入
创建失败后的同句柄恢复，以及描述符生命周期。测试源码纳入 `overlaySha256`，
构建与预编译包验收必须运行该组。实际播放像素回归使用
[`windows_eof_black_screen.dart`](../../probes/playback/windows_eof_black_screen.dart)，见
[运行说明](../../probes/README.md#windows-eof-与重载黑屏反例)。

## AMD 图片上传

引擎 ANGLE 按实际 D3D11 适配器对 AMD 默认关闭 `setDataFasterThanImageUpload`，改用 `Image11` staging，降低浏览后的驱动内存保留。Intel、NVIDIA 和软件设备沿用上游默认值。策略不改变画质、解码尺寸或 media_kit 独立 ANGLE DLL；加载同一引擎的主窗口和独立播放窗口均生效。设备验证目前限本机 AMD。

构建单独应用并核对 [angle-image-upload.patch](angle-image-upload.patch)，该补丁和[原生上传回归](image_upload_unittests.cc) 计入 `overlaySha256`。回归调用真实 ANGLE 初始化和 override 匹配，覆盖 AMD、其他厂商及显式回退。设备上可独立运行 `WindowsImageUploadHardwareTest.*`，用 `PILIAURORA_EXPECT_FAST_UPLOAD=disabled` 或 `enabled` 检查 EGL 枚举状态。

临时恢复快速上传：启动前为进程设置 `ANGLE_FEATURE_OVERRIDES_ENABLED=setDataFasterThanImageUpload` 并重启；撤销设置再重启恢复 AMD 默认策略。ANGLE 的禁用覆盖优先于启用覆盖，同名禁用项须先移除。应用不会改写环境变量，其他同进程 ANGLE 实例也可能读取覆盖，对照时需记录播放器行为。

普通 FVM 引擎没有此策略，验证时使用当前预编译引擎或显式装配定制引擎。

## 编译

需要 Windows、Python 3.11+、Git、Visual Studio C++ 工作负载和 Windows SDK。构建使用独立目录，保留 FVM SDK；源码与工具占用较大，需预留磁盘空间。

```powershell
python tool/engine/windows_frame_pacing/build_engine.py --root <engine-root> --flutter-sdk <flutter-sdk> --visual-studio <visual-studio-root>
```

| 参数 | 行为 |
| --- | --- |
| 默认 / `--mode release` | 编译 Profile / Release；默认运行相关原生回归 |
| `--visual-studio-version` | 默认 `2026`，与 `--visual-studio` 安装目录配套 |
| `--skip-sync` | 复用已下载依赖，仍执行 hooks |
| `--skip-tests` | 仅编译，身份文件记录原生测试尚未通过 |
| `--windows-sdk E:/WindowsKits/10` | 指定非默认 SDK 根目录；默认读取安装登记 |
| `--windows-sdk-version 10.0.26100.0` | 指定版本；默认取安装目录中的最高版本 |

首次下载使用本机代理或 `HTTPS_PROXY`。Git 长路径和 VS 工具链配置仅影响本次进程树。脚本核对固定提交，经 gclient 同步、hooks 和 [windows-frame-pacing.patch](../../../doc/development/engine-patches/windows-frame-pacing.patch) 后使用 GN/Ninja 构建。检出不匹配或补丁冲突时保留文件并终止。隔离检出复用本机 SDK 的 Git 对象库，编译结束前须保留 SDK。

输出位于 `flutter/engine/src/out/piliaurora_windows_profile/` 或对应 Release 目录，包含 `flutter_windows.dll` 和 `engine-identity.json`。身份记录源码、补丁和 DLL 摘要、模式、架构及原生测试状态，遵循[共同身份协议](../README.md)。

## 对照采集

```powershell
pwsh -NoProfile -File tool/probes/windows/measure_danmaku.ps1 -PresentMonPath <presentmon.exe> -EngineLibrary <engine-root>/flutter/engine/src/out/piliaurora_windows_profile/flutter_windows.dll
```

入口通过统一构建脚本生成探针，核对 Profile/x64、应用配置和引擎身份。`-SkipBuild` 复用相同身份的输出，`-Media <本地视频>` 增加视频合成负载。独立采集目录保存原始数据、引擎身份、同帧关联和 ±1/±2/±3 汇总，流程见[平台探针](../../probes/README.md#windows-弹幕帧节奏探针)。

## 应用构建

```powershell
pwsh -NoProfile -File tool/build.ps1 -Platform windows -Mode profile -WindowsEngineLibrary <engine-root>/flutter/engine/src/out/piliaurora_windows_profile/flutter_windows.dll
```

构建核对模式、固定提交、当前补丁、DLL 摘要和原生回归，编译普通入口后装配引擎，并在输出保留 `engine-identity.json`。Release 须先以 `--mode release` 编译引擎，再将应用 `-Mode` 改为 `release`。

省略 `-WindowsEngineLibrary` 时使用 FVM 引擎，清除应用输出中的旧身份，不改写 FVM 缓存。发布与 CI 使用 [Git 跟踪的 Release 预编译引擎](../../../third_party/flutter_engine/README.md)。
