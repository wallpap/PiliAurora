# Windows 视频输出

Windows 通过 media_kit 的 libmpv 渲染接口和 ANGLE 共享纹理输出视频。应用优先配置 D3D11 硬解，实际解码器需查看 `hwdec-current`；ANGLE 初始化失败时，插件尝试软件渲染，软件输出尺寸上限为 1920×1080。

## 原生资源与首帧

Windows 根视图在最小化或 Flutter 报告 hidden/paused/detached 时关闭 `TickerMode`，复用点播弹幕调度停用、直播显示订阅释放及图片卸载机制。恢复后按当前媒体时间重新准备显示，播放器会话、音频与用户选择的源画质不受此视觉开关控制。失焦 `inactive` 可能仍是可见小窗，继续显示；目前没有可靠的任意窗口遮挡检测，不把失焦当作完全遮挡，也不额外轮询窗口层级。

关闭子窗口时，窗口位置查询、播放器清理、诊断刷新及 IPC 释放分别报告失败并继续后续阶段；IPC 关闭等待有界。原生纹理、ANGLE 和播放器仍按已有释放协议销毁。以上路径仅做源码审查，实际 CPU/GPU 收益、音频连续性与驱动行为需要目标设备验证。

[`VideoOutput`](../third_party/media_kit_video/windows/video_output.cc) 在共用输出线程上创建、渲染和释放 mpv render context 与 ANGLE 资源。释放时先将对应 EGL 上下文设为 current，清除 mpv 更新回调并释放 render context，再解除 current、销毁 EGL 和设备。

渲染通知通过 pending/dirty 标记合并，每个队列任务处理一帧，后续更新排回队尾，使输出代次撤销、尺寸变更和释放任务能在持续渲染期间执行。

初始纹理 ID 用于完成 Dart 控制器创建，视频首帧就绪另行通知。真实纹理替换要等渲染成功后发布；同尺寸请求沿用已发布的画面。源尺寸由 Dart 的 `video-out-params` 观察事件送入原生队列，避免渲染线程同步查询正在等待首帧的 mpv 核心。

ANGLE Surface 的 D3D 纹理作为默认 framebuffer 的绘制目标，随后通过 D3D 复制供 Flutter
读取。创建与扩容时不生成额外 GL 纹理或调用 `eglBindTexImage`，避免改动 mpv 共用的
GL 纹理状态。真实直播的首次播放、刷新与纹理像素验证见
[`windows_live_startup.dart`](../tool/probes/playback/windows_live_startup.dart) 及[运行说明](../tool/probes/README.md#windows-直播首帧探针)。

输出尺寸策略和截图交接位于 [`view.dart`](../lib/plugin/pl_player/view/view.dart) 与 [`video_output_resizer.dart`](../lib/plugin/pl_player/utils/video_output_resizer.dart)。Windows 首次检测 Flutter 窗口所在显示器的物理尺寸并缓存上限，窗口布局变化由 Flutter 缩放。输出限幅降低渲染目标的开销，媒体解码仍使用源分辨率。

截图交接在收到对应 Flutter 帧的 raster 回执后才提交原生 resize。等待回执超过 3 秒时取消本次调整、撤掉截图并继续显示原生纹理；原生 resize 已提交后的截图仍保留到新输出确认，或恢复旧几何完成。

## 超分切换

视频尺寸超过当前屏幕、或尺寸尚未确认时，播放器超分入口置灰并禁用菜单；悬停或长按保留原因提示，点击灰色入口显示提示，不发起切换。显式选择请求在修改档位、保存设置和进入 shader 队列前再次检查；重复选择当前档位也直接返回，保留连续播放。媒体加载时的默认档位仍随源尺寸核对，必要时清除上一媒体的滤镜。

页面将超分模式解析为 shader 路径后，通过 `PlaybackOwner.setShader` 提交配置命令。`PlaybackSession` 将其放入 shader 配置槽，与加载、播放意图和其他原生写入协调；加载 ready 后，控制器按已保存档位计算目标路径，并与规范快照中的期望路径比较，避免重复提交相同 shader。Windows 当前输出已有视频尺寸时，`NativePlaybackRuntime` 调用 [`applyShaderList`](../lib/plugin/pl_player/playback/shader_updates.dart)：

1. 将 mpv 的 `vo` 切到 `null`，解除视频输出对 render context 的使用。
2. 调用 `resetRenderer()`，在原生输出线程释放并重建 render context 与 ANGLE 设备。
3. 提交新的 `glsl-shaders` 列表。
4. 在 `finally` 中恢复 `vo=libmpv`；重建后的纹理等待 mpv 通知实际视频帧后发布。

切换 `vo` 会同时重建 mpv 的视频解码链。固定原生库通过 `vo-reinit-seek.patch` 在重建后、返回播放循环前完成补偿 seek，使缓存读取位置和解码状态先恢复到关键帧。否则缓存中的非关键包可能耗尽解码器的 96 包等待额度，产生 AV1 参考帧错误并触发硬解回退。

该过程保留 Player 和媒体。Android、未就绪的 Windows 输出直接更新 shader；软件输出跳过原生重建。owner 关闭后，会话不再接受它的配置命令；运行时在等待已发出的 shader 更新和媒体卸载后释放输出，再销毁 Player。跨控制器资源槽等到 `Player.released` 才允许创建下一实例。

## 原生库与验证

Windows 的 Debug、Profile、Release 构建均使用 `third_party/mpv/prebuilt/` 的预编译包，GitHub CI 使用相同归档。源码、工具链和许可说明见[mpv 构建入口](../third_party/mpv/README.md)；CMake 检查构建输入和运行文件摘要，缺失或过期时终止。

Flutter 窗口的最终呈现由引擎负责。[Windows 帧节奏引擎](../tool/engine/windows_frame_pacing/README.md)在 ANGLE 支持时启用 DirectComposition，并调整 DWM 相位、Surface vsync 与呈现队列。本地通过 `-WindowsEngineLibrary` 显式装配到 Profile/Release 应用；正式发布和 CI 使用 [Git 跟踪的预编译引擎](../third_party/flutter_engine/README.md)。排查弹幕呈现时使用[帧节奏探针](../tool/probes/README.md#windows-弹幕帧节奏探针)保留实际 `PresentMode` 与逐帧关联结果。

相关验证入口：

- `test/plugin/pl_player/playback/shader_updates_test.dart`：shader 更新顺序与失败后恢复 `vo`。
- `test/plugin/pl_player/video_output/`：尺寸策略、调度、截图交接与帧确认。
- `tool/probes/windows/windows_texture_frame_probe.py`：模拟纹理首帧和重建后的帧发布条件。
- `tool/probes/playback/windows_shader_switch.dart`：实际 Flutter、ANGLE、libmpv 的超分切换；运行参数见[平台探针](../tool/probes/README.md#windows-超分切换探针)。

历史本机测量中，暂停重建出现过约 0.33 秒时间线回退。上述入口覆盖编译与模拟路径，音频输出、长时间播放和更多 GPU 驱动的实测单独进行。
