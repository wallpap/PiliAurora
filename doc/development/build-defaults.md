# 默认构建与策略

`tool/build.ps1` 默认构建 Release，自动使用 `third_party/flutter_engine/prebuilt/` 的固定引擎。本地和发布 CI 采用相同的引擎材料、身份协议和应用默认策略，日常构建无需传入引擎路径或额外的呈现定义。命令、签名和输出见[构建与测试](build-and-test.md#构建)。

## 构建契约

| 入口 | 引擎与输出 |
| --- | --- |
| Windows 默认 Release | `windows-x64`，呈现配置 `windowsDwmPaced`；运行目录附引擎身份，打包配置自动生成 |
| Android 默认 Release | `android-arm`、`android-arm64`、`android-x64`，呈现配置 `androidFramePlan`；默认生成三个分 ABI APK，`-Abi` 选择一个架构 |
| Android 独立测试包 | 同一 arm64 Release 引擎与 `.dev` 包名，使用本机 Release 签名 |
| 显式 Debug | FVM SDK 的调试引擎，呈现配置 `standard`；适合断点与热重载 |
| 引擎维护 Profile | 独立编译同模式引擎后验证；维护流程见[引擎工具](../../tool/engine/README.md#修改引擎) |

Flutter 与引擎提交、模式、架构、补丁和 overlay、二进制摘要、原生回归状态均须匹配。身份校验失败终止构建。直接调用 Flutter 构建会绕过装配；引擎相关验收使用项目入口。引擎版本和许可证集中在[预编译引擎](../../third_party/flutter_engine/README.md)。

## 当前采用项

以下行为随正常 Release 生效。用户已保存的偏好继续按各设置的生效时机使用。

| 领域 | 当前行为 | 源码与维护入口 |
| --- | --- | --- |
| Windows 呈现 | DirectComposition 支持探测、DWM 相位校准和有界呈现队列；异常时沿既有回退路径运行 | [Windows 引擎](../../tool/engine/windows_frame_pacing/README.md#呈现与计时) |
| Android 呈现 | FrameTimeline 帧计划、同帧身份、纹理更新合并和 EGL 输出；不支持或失败时退回普通调度 | [Android 引擎](../../tool/engine/frame_plan/README.md#输出流程) |
| Windows 重载黑屏 | 释放 EGL 导入时清除共享句柄缓存；同句柄恢复重新导入，导入失败可重试，描述符只释放一次（`40e8c6eb4`） | [外部纹理](../../tool/engine/windows_frame_pacing/README.md#外部视频纹理)、[视频输出](../maintenance/windows-video-output.md#原生资源与首帧) |
| Windows 图形内存 | 主窗口和独立播放窗口的 Skia raster 预算为 64 MiB；引擎 ANGLE 对实际 AMD D3D11 适配器默认使用 staging 图片上传（`46812470f`） | [架构](architecture.md#桌面窗口与标题栏)、[AMD 上传](../../tool/engine/windows_frame_pacing/README.md#amd-图片上传) |
| 视频资源交接 | 旧媒体卸载后消费延迟 reset；新代次首个有效共享纹理复制确认 GPU 完成后再发布，普通帧保持异步（`d4c28821c`）；降画质和超分重建按会话协议执行 | [播放状态模型](playback-model.md)、[Windows 输出](../maintenance/windows-video-output.md) |
| 点播缓存 | 默认均衡、基准 4 MiB、时长 16 秒；每个 demuxer 前向 16 MiB、后向 4 MiB。缺失或未知策略回退均衡，下一次加载捕获；直播独立（`58963f2b2`） | [设置行为](settings-behavior.md)、[缓存策略](../../lib/plugin/pl_player/models/video_buffer_policy.dart)、[偏好](../../lib/utils/storage_pref.dart) |
| 缓存条 | 加载、重载及 seek 交接后立即同步当前缓存边界，允许淘汰后回退；缓存内跳转继续复用 | [控制器](../../lib/plugin/pl_player/controller.dart)、[播放器测试](../../test/plugin/pl_player/) |
| Windows Gallery | 有界区域解码与 worker 生命周期进入生产路径；WIC 拒绝嵌入色彩配置时回退，失败显示可见提示（`df340cf01`、`1f0afc176`、`c6591f459`） | [图片模块](../../lib/common/widgets/image/README.md)、[测试契约](../../test/common/widgets/image/CONTRACTS.md) |
| 弹幕 | 每 100ms 桶显示 12 条、逐帧准备 8 条；来源预算 20 MiB／36000 条，文件每桶保留 120 条供范围读取 | [架构](architecture.md)、[配置选择证据](../../tool/experiments/README.md#2026-11-07-配置选择) |

缓存由时长和字节共同限制，倍速仅换算时长。Windows 固定 libmpv 支持字节补读阈值；Android 不传该选项。缓存预算分别约束各 demuxer，不能视为进程总内存上限。图片、Skia、视频纹理和驱动内存同样分别计量。

## 证据与待验收范围

2026-11-14 核对线程 `01a1d8b4-7df2-7bf3-b57b-b79cfd3e06ba`、当前源码及本地报告，采用以下边界：

- 黑屏修复前的真实反例同实例重载 9/10 次黑屏，修复后 NVIDIA 的 26 次重载、55 个画面检查点无黑屏，已登记资源最终归零。消费帧回执早于 EGL 导入，单凭计数推进无法认定画面正常。
- 黑屏提交当时 2734 项 Flutter 全量与 49 项原生回归通过；后续缓存提交运行的是 526 项定向回归，两组结果按提交分别使用。
- 缓存原生对照使用 24 Mb/s 素材、软件解码和空音视频输出。均衡策略最低领先量从旧配置 1.933 秒增至 6.100 秒，覆盖缓存内复用、淘汰重读和远距离跳转；未覆盖网络抖动或真实音画。
- AMD 旧日志设置页后 60 秒 Private 约 587.6 MiB，接近最早基线约 589.3 MiB。上一包约 851.7 MiB 含引擎差异，不能将约 264.1 MiB 的变化归因于黑屏补丁。
- Gallery 压力组曾测得峰值下降 23.19%，p95 增加 153ms，原延迟门槛未通过；该结果保留为取舍记录，不能宣称全部性能门槛通过。

正式发布前仍需修复版 AMD 核显的 EOF、seek 与连续重载验收，以及正常详情页真实声音、画质和全屏切换、退页重进与释放。Android 设备与对应 ABI 另行验收。本次重新运行严格分析，仍有五条既有 `avoid_slow_async_io` info，均位于未修改的 `test/common/widgets/image/image_source_store_contract_test.dart`；无 error／warning，命令返回 1。默认采用与正式发布验收分别记录。

Windows 内存诊断引擎、空闲强制回收、单解码及小缓存等未采用实验继续留在研究入口。它们的历史测量不能作为当前默认值来源。策略变更应同时更新源码、相关回归及本页；补丁变更还须重建预编译引擎。

## 本地证据导航

原始日志、设备截图和完整报告保留在忽略的 `doc/dev/`，按[实验资料归档](../../tool/experiments/README.md#实验资料归档)生成全量索引。关键报告路径：

| 主题 | 本地路径（相对 `doc/dev/`） |
| --- | --- |
| 黑屏反例与根因 | `diagnostics/reports/black-screen-counterexample-20261114.md`、`black-screen-root-cause-20261114.md`（同目录） |
| 两 GPU 日志与发布准备 | `diagnostics/reports/gpu-comparison-20261114.md`、`release-readiness-20261114.md`（同目录） |
| 缓存策略 | `diagnostics/reports/video-cache-policy-20261114.md` |
| Gallery 方案与生产取舍 | `diagnostics/cases/diagnostics-1794574491802/` 中各实验报告及 `gallery-production-implementation-20261114.md` |
| 早期内存与应用策略 | `diagnostics/reports/memory-investigation-summary-20261111.md`、`app-memory-strategies-20261111.md`（同目录） |

历史报告保留当时的命令、失败路线和更正，不随默认构建迁移改写。共享文档只保存可复用结论、维护入口与验证范围；本地索引不代表逐份报告已重新验收。
