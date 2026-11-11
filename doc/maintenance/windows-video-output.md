# Windows 视频输出

Windows 通过 media_kit 的 libmpv 渲染接口和 ANGLE 共享纹理输出视频。应用优先配置 D3D11 硬解，实际解码器需查看 `hwdec-current`；ANGLE 初始化失败时，插件尝试软件渲染，软件输出尺寸上限为 1920×1080。

## 解码测试进程

设置页的 Windows 解码测试每组启动独立进程，在独立窗口显示预览，结果通过带一次性凭证的本机回环连接返回。只有结果有效且进程正常退出才确认成功；异常退出显示状态码，超时或停止时终止该测试进程并等待退出，然后才能开始下一组。测试子进程跳过正常启动与单实例转发，只使用内存设置，不读取账号。

2026-11-08 本机 HEVC 的 `vulkan-copy` 测试触发 AMD `amdvlk64.dll` 的 `0xc0000005`，独立 libmpv/ANGLE 采样也在同一模块与偏移复现。该类驱动访问违规会终止进程，无法由 Dart 异常捕获恢复；进程隔离保护主应用并如实报告该项失败，不代表驱动或该解码模式已修复。其他 GPU、驱动与 Android 路径需分别验收。

## 硬解纹理边缘

部分 HEVC / AV1 的 D3D11 解码纹理包含对齐填充行。ANGLE 外部纹理的线性采样按物理尺寸钳制，可能把填充行混入有效画面的最后一行。Windows 初始化加载 `assets/shaders/Windows_ChromaClamp.glsl`，在色度插值前把采样位置限制到有效首末 texel 中心，继续使用原有硬件解码器。

修正仅在亮度纹理尺寸大于当前完整源矩形时运行，按实际亮度/色度纹理比例处理子采样，并映回源纹理方向。当前 Windows 原生输出使用完整源画面、等比限幅；界面 fit / 裁切由 Flutter 完成，不使用 mpv 的 panscan、video-pan 或 video-zoom。shader 中的 `input_size` / `tex_offset` 以此为前提；未来改用 mpv 层裁切、对齐或预缩放时，须重新核对有效源边界，不能把该 shader 直接当作通用 mpv 裁切修复。

基础修正与超分 shader 分别持有。运行时每次加载、切换或关闭超分时合并两者，关闭超分后 `glsl-shaders` 仍包含边界修正，不能以列表是否为空判断超分状态。它增加受影响帧的 GPU 色度 pass；其他驱动、长期播放与性能仍按设备验收。

可用 `windows_video_sampling_probe.py` 的生产配置验证；追加 `--control-disable-chroma-clamp` 仅在探针中撤销修正，应重新检出原有单行异常。实际源码、PNG、逐帧差异和矩阵报告分别保留，不能将本机边缘修复等同于所有 Windows 黑屏问题已解决。

## 原生资源与首帧

Windows 根视图在最小化或 Flutter 报告 hidden/paused/detached 时关闭 `TickerMode`，复用点播弹幕调度停用、直播显示订阅释放及图片卸载机制。恢复后按当前媒体时间重新准备显示，播放器会话、音频与用户选择的源画质不受此视觉开关控制。失焦 `inactive` 可能仍是可见小窗，继续显示；目前没有可靠的任意窗口遮挡检测，不把失焦当作完全遮挡，也不额外轮询窗口层级。

根视图和主窗口、独立播放窗口的播放器共用窗口可见性判定，合并最小化、恢复、最大化、退出最大化及 Flutter 生命周期事件；窗口恢复事件不会覆盖仍为 hidden 的生命周期状态。开启最小化暂停时，重新可见会释放对应的暂停抑制，并保留用户后续修改的播放意图。隐藏期间撤销画面停滞检查，保留独立的网络断流恢复；重新可见后重新等待完整检查窗口，避免未消费纹理耗掉自动恢复预算。

视频健康判断要求已选中视频轨道、播放位置和当前输出令牌的实际消费帧继续推进，不依赖 `demux-fps` 是否提供。EOF 后定位沿完整媒体加载路径建立新输出代次；音频继续而画面停滞时仍由既有会话恢复流程重载，并沿用限频与次数预算。回归覆盖未知帧率、模拟长时间 EOF 停留、窗口恢复与旧帧隔离；真实 GPU 黑屏像素和驱动行为仍需设备验证。

关闭子窗口时，窗口位置查询、播放器清理、诊断刷新及 IPC 释放分别报告失败并继续后续阶段；IPC 关闭等待有界。原生纹理、ANGLE 和播放器仍按已有释放协议销毁。以上路径仅做源码审查，实际 CPU/GPU 收益、音频连续性与驱动行为需要目标设备验证。

[`VideoOutput`](../../third_party/media_kit_video/windows/video_output.cc) 在共用输出线程上创建、渲染和释放 mpv render context 与 ANGLE 资源。释放时先将对应 EGL 上下文设为 current，清除 mpv 更新回调并释放 render context，再解除 current、销毁 EGL 和设备。

渲染通知通过 pending/dirty 标记合并，每个队列任务处理一帧，后续更新排回队尾，使输出代次撤销、尺寸变更和释放任务能在持续渲染期间执行。

初始纹理 ID 用于完成 Dart 控制器创建，视频首帧就绪另行通知。真实纹理替换要等渲染成功后发布；同尺寸请求沿用已发布的画面。源尺寸由 Dart 的 `video-out-params` 观察事件送入原生队列，避免渲染线程同步查询正在等待首帧的 mpv 核心。

ANGLE Surface 的 D3D 纹理作为默认 framebuffer 的绘制目标，随后通过 D3D 复制供 Flutter
读取。绘制和复制均在输出线程提交，之后才通知 Flutter 帧可用；Raster 纹理回调只读取
已发布描述符，避免在引擎图形调用中等待输出线程的 `glFinish`。创建与扩容时不生成额外
GL 纹理或调用 `eglBindTexImage`，避免改动 mpv 共用的
GL 纹理状态。真实直播的首次播放、刷新与纹理像素验证见
[`windows_live_startup.dart`](../../tool/probes/playback/windows_live_startup.dart) 及[运行说明](../../tool/probes/README.md#windows-直播首帧探针)。

输出尺寸策略和截图交接位于 [`view.dart`](../../lib/plugin/pl_player/view/view.dart) 与 [`video_output_resizer.dart`](../../lib/plugin/pl_player/utils/video_output_resizer.dart)。Windows 首次检测 Flutter 窗口所在显示器的物理尺寸并缓存上限，窗口布局变化由 Flutter 缩放。输出限幅降低渲染目标的开销，媒体解码仍使用源分辨率。

Windows 尚无源几何时使用 1×1 占位输出，收到当前文件的原生几何后直接设置最终
限幅尺寸，并等待该尺寸的首帧回执才完成加载。这可避免尺寸观察事件先创建完整 4K
输出、随后又缩小的多余扩容；媒体仍按源分辨率解码。

Windows 降画质时，仅缩小输出纹理仍可能保留渲染器此前使用的高分辨率中间资源。
运行时保存当前文件的原生源几何；下一次加载的尺寸提示变小时，在旧媒体完整卸载后、
新媒体 open 前重建 render context 与 ANGLE。尺寸提示只决定是否回收，最终输出仍由
新文件的原生几何确认。转为纯音频或新源尺寸未知时同样回收；同尺寸切源及尺寸未知的
同源恢复复用渲染器。与超分变更重合时只重建一次，成功后记录 `media.renderer.reset`。
回收失败按加载失败处理，显式重试仍须重新取得回收回执。

判断内存尖峰时同时核对全屏切换。解码器、输出尺寸及原生计数不变时，Flutter 窗口
呈现和合成仍可能增加工作集。进程 Private、VirtualQuery 页分类、DXGI 预算和输出纹理
名义字节分别观测，不能相加，也不能将写合并页直接命名为某个纹理或驱动对象。

Windows 进入原生全屏前，先切换播放器全屏状态并等待 Flutter 提交该帧布局，再调整窗口尺寸，避免新窗口尺寸先展示普通详情布局。此等待确认 UI 提交，不代表 GPU 已完成呈现；播放器元素与纹理继续复用。回归见 `test/plugin/pl_player/fullscreen_transition_test.dart`，实际过渡闪屏仍需目标设备验证。

截图交接在收到对应 Flutter 帧的 raster 回执后才提交原生 resize。等待回执超过 3 秒时取消本次调整、撤掉截图并继续显示原生纹理；原生 resize 已提交后的截图仍保留到新输出确认，或恢复旧几何完成。

## 超分切换

视频尺寸超过当前屏幕、或尺寸尚未确认时，播放器超分入口置灰并禁用菜单；悬停或长按保留原因提示，点击灰色入口显示提示，不发起切换。显式选择请求在修改档位、保存设置和进入 shader 队列前再次检查；重复选择当前档位也直接返回，保留连续播放。媒体加载时的默认档位仍随源尺寸核对，必要时清除上一媒体的滤镜。

同内容切画质时，Session 继承用户配置后、每次打开来源前再次核对已知源尺寸。
例如在 2560×1440 屏幕上由 1080p 超分切到 4K，先清除超分再打开 4K，避免首次渲染
分配一批 4K 超分中间纹理。允许超分的分辨率继续保留当前档位；旧来源尚未完成的
shader 资源准备在切源时失效。`media.open.requested` 记录本次 `shaderCount` 和源尺寸
提示，可用于检查限制是否在首帧前落实。

页面将超分模式解析为 shader 路径后，通过 `PlaybackOwner.setShader` 提交配置命令。`PlaybackSession` 将其放入 shader 配置槽，与加载、播放意图和其他原生写入协调；加载 ready 后，控制器按已保存档位计算目标路径，并与规范快照中的期望路径比较，避免重复提交相同 shader。Windows 当前输出已有视频尺寸时，shader 变更通过 Session 的配置重载协议：

1. 保存当前点播位置和最新播放意图，等待旧媒体的卸载屏障。
2. 在下一次 open 前调用 `applyShaderList`，切换空输出、重建 render context 与 ANGLE，再提交新 shader 并恢复 `vo=libmpv`。
3. 使用同一媒体源重新加载，点播恢复位置，直播回到当前直播进度；按最新播放意图继续播放或保持暂停。

重建发生在旧媒体卸载后，可避开活跃解码链的补偿 seek 时序问题。Player 保留，网络媒体会重新请求，切换时有短暂停顿。Android、未就绪的 Windows 输出直接更新 shader；软件输出跳过原生重建。owner 关闭后，会话不再接受它的配置命令；运行时在等待已发出的 shader 更新和媒体卸载后释放输出，再销毁 Player。跨控制器资源槽等到 `Player.released` 才允许创建下一实例。

## 原生库与验证

Windows 的 Debug、Profile、Release 构建均使用官网推荐的 shinchiro 标准预编译包，固定来源和 SHA-256，GitHub CI 使用相同归档。来源及许可说明见 [mpv 说明](../../third_party/media_kit_libs_windows_video/UPSTREAM.md)。CMake 校验原始归档并提取运行文件，不再从本地补丁源码编译。

Flutter 窗口的最终呈现由引擎负责。[Windows 帧节奏引擎](../../tool/engine/windows_frame_pacing/README.md)在 ANGLE 支持时启用 DirectComposition，并调整 DWM 相位、Surface vsync 与呈现队列。本地通过 `-WindowsEngineLibrary` 显式装配到 Profile/Release 应用；正式发布和 CI 使用 [Git 跟踪的预编译引擎](../../third_party/flutter_engine/README.md)。排查弹幕呈现时使用[帧节奏探针](../../tool/probes/README.md#windows-弹幕帧节奏探针)保留实际 `PresentMode` 与逐帧关联结果。

相关验证入口：

- `test/plugin/pl_player/playback/shader_updates_test.dart`：shader 更新顺序与失败后恢复 `vo`。
- `test/plugin/pl_player/playback/native_shutdown_test.dart`：降画质回收、卸载屏障、同尺寸复用、与超分合并及失败重试。
- `test/plugin/pl_player/video_output/`：尺寸策略、调度、截图交接与帧确认。
- `tool/probes/windows/windows_texture_frame_probe.py`：模拟纹理首帧和重建后的帧发布条件。
- `tool/probes/playback/windows_shader_switch.dart`：实际 Flutter、ANGLE、libmpv 的超分切换；运行参数见[平台探针](../../tool/probes/README.md#windows-超分切换探针)。
- `tool/probes/playback/windows_resource_lifecycle.dart`：离线切画质、超分与释放的分阶段内存对照；见[资源回收探针](../../tool/probes/README.md#windows-播放器资源回收探针)。

历史本机测量中，暂停重建出现过约 0.33 秒时间线回退。2026-11-05 的生产会话探针使用长 GOP AV1，通过 8 个阶段、6 次实际重载，覆盖 D3D11 硬解、有效纹理、暂停恢复、音频时间线和超分资源回收。探针使用空音频输出，实际扬声器、长时间播放和其他 GPU 驱动仍需单独验证。

### 2026-11-11 本机资源回收结果

本次使用 AMD Radeon(TM) Graphics、本地 H.264/AAC 运动视频和空音频输出，实际解码器
为 `d3d11va`，输出物理上限为 2560×1440。生产会话探针得到以下结果：

| 场景 | 结果 |
| --- | --- |
| 720p → 4K → 720p | 相对各自首次 720p 基线的 Private 中位增量，修复前为 138.96 MiB，修复后为 23.25 MiB；同尺寸重载没有增加 render context。 |
| 首次加载未知尺寸的 4K | 累计插件 D3D 纹理创建数由 6 降为 4，最终输出为 2560×1440，画面非空。 |
| 质量／效率超分关闭 | 两档关闭后均回到本机相对门限内；降画质、同尺寸重载及两档超分关闭共四项门限通过。 |
| 两次全屏往返 | 两个恢复阶段的 Private 中位差为 4.59 MiB；全程累计输出纹理为 4、render context 为 1。 |

上述探针关闭后，插件原生资源计数全部归零。内存相对门限为 64 MiB，仅用于本机对照；
不同进程运行间的绝对 Private 仍有明显波动。相关 420 项主机测试、8 个 Dart 文件静态
分析和正常应用 Release 构建均通过。

4K 解码／渲染工作集、全屏呈现峰和多个独立进程的总占用仍会出现。短时 RW 峰及历史
匿名存续块还缺少分配调用栈，因此本次结果只确认上述两处输出资源问题的修复。完整线上
选画质 UI、多窗口全量回放、Android 真机、其他驱动和实际扬声器仍需分别验收。
