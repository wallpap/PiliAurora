# media_kit_video 本地版本

- 本地版本：`1.2.5+piliaurora.12`；来源包版本：`1.2.5`。
- 来源仓库：https://github.com/My-Responsitories/media-kit.git
- 来源提交：`73771ec38176be2d984a3049c28177bce23b54a0`。
- 来源子目录：`media_kit_video`。
- 许可证：LICENSE。
- 保留原因：保留 Android 输出尺寸通道与 Windows ANGLE/纹理输出实现。

仅收录生产源码、构建配置、资源及许可说明；不复制上游示例、测试、缓存或 Git 元数据。
导入时除包版本、禁止发布声明及必要依赖声明外，不重写来源实现。
这些包不是 pub.dev 同名版本的镜像，不可仅修改根版本号宣称已升级。
更新流程见 `../README.md`，来源登记见 `../dependencies.json`。

本地维护修正：补齐字幕文档模板的闭合标签，不改变生产行为。

2026-10-15：Windows 创建/扩容 EGL Surface 时移除额外的 GL 纹理生成、绑定和
`eglBindTexImage`，同步移除对应释放。输出继续由 mpv 绘制到默认 framebuffer，
通过 D3D 复制交给 Flutter。真实 HEVC/AVC FLV 直播首次播放复现的全黑画面及
`INVALID_FRAMEBUFFER_OPERATION` 在移除此绑定后消失；验证入口为
`tool/probes/playback/windows_live_startup.dart`。

2026-10-09：Android 自动检测设备物理像素分辨率作为输出上限；超限源等比缩小，较小的源保持原尺寸，
一个媒体加载周期内固定，不再由 Flutter 视口触发原生 resize。增加可选 Surface
生命周期诊断回调、原生事件顺序与单调时钟；Windows 输出路径不变。

2026-10-09：Android 显示限幅由应用实验开关控制，关闭或上限不可用时按原生源尺寸更新。保留 Flutter 引擎帧通知，以消费监听确认首帧并提供当前配置以来的消费计数，移除逐帧 JNI 查找与反射。创建属性写入检查原生返回值。

Windows 支持在创建输出时指定固定尺寸。初始纹理 ID 与视频首帧就绪分别通知；软件输出的初始尺寸遵守缓冲区容量。同尺寸请求沿用已发布的视频帧，真实纹理替换仍等待渲染和可用帧通知。

2026-10-13：Windows 增加 `resetRenderer()`，在原生输出线程重建渲染上下文和 ANGLE 设备；保持 mpv 核心与媒体。释放顺序调整为在 GL 上下文 current 时释放 mpv render，再销毁 EGL/设备。重建后的纹理等新视频帧就绪再发布。应用在超分切换时调用，Android 路径保持原行为。

2026-10-14：Android 输出可按配置上报纹理消费的单调时钟微秒，每 250 ms 合并一批、最多 32 个样本；重复纹理不计，Surface 重建、重新配置和销毁清理待发批次。该路径沿用引擎的 frame-available 监听，不使用媒体 PTS 作为调度时钟。Windows 输出保持原路径。

2026-10-14：相位采样改到 frame-available 的引擎原 listener 返回后，记录纹理刷新请求完成的单调时钟；markDirty 与取图共用 monitor，因此锁等待必须计入请求时间。VideoSurfaceTexture 保留原 Handler、监听注销和纹理生命周期。请求批次仍为 250 ms、上限 32，重建和销毁时清理。消费监听继续负责首帧、尺寸交接及消费计数，Windows 输出不变。主机回调探针检查通知转发和采样顺序；另编译实际 Flutter SurfaceTextureWrapper，验证交替 0/9ms 取图等待后的样本与请求槽位一致。该探针未模拟 platform/UI 合并线程的全部行为，不作为 Scene 或最终呈现结论。

2026-10-15：Android 视频纹理按 frame-available 通知调用原生 `updateTexImage`，弹幕或控件重复绘制时复用当前图像。原子标记在取图前消耗，保留并发到达的下一帧；取图失败与 GL 上下文重建允许重新获取。关闭相位采样时沿用相同取图策略。主机探针使用固定 Flutter 的实际 wrapper 检查取图次数、并发通知和生命周期。此修正消除重复原生取图，真机日志中约 9.4ms 的周期性 Raster 峰值仍需目标设备复测。

2026-10-16：Android 输出操作使用单调高水位 token，永久撤销后拒绝旧代次 begin/wait，并在 Surface 写入临界区核对 runtime/load/output/config 代次。新增按 load 登记、preloaded 选择/准备、FILE_LOADED 几何确认与 attach 回执的两阶段协议。Windows 输出串行化 render 生命周期、合并 pending/dirty 更新并提供 token 绑定 attach 回执。消费进度携带输出操作 token；Android/Windows 的实际设备渲染与 paused-open 行为仍需目标环境验证。

2026-10-17（piliaurora.6）：Android 单视频轨的 demux 宽高有效时，在 preloaded 阶段挂载 Surface。裁剪、PAR 或旋转未确认时先使用临时缓冲区，并继续由 FILE_LOADED 核对轨道和最终几何；同尺寸复用已挂载的输出，尺寸变化沿用 VO 更新缓冲区，避免直播从 null 输出切到 GPU 后重建解码器、触发不可 seek 错误和音画偏移。完整的 preloaded 几何证据仍须满足原有确认条件。主机回归覆盖实际控制器的挂载顺序、同尺寸复用与显示几何修正；MediaCodec、首帧延迟和音画同步仍需 Android 真机验收。

2026-10-17（piliaurora.7）：修正 on_preloaded 早于 mpv 选轨的时序：写入 vid 后核对唯一候选轨道，FILE_LOADED 再核对实际 selected 与几何。Android 释放时同步设置 vo=null、wid=0 后删除 JNI Surface 全局引用，去掉原有固定 5000ms 延迟；释放回执仍等待真实 JNI 删除，失败继续隔离资源。回归覆盖未选轨启动、释放顺序和待回执重入；主机 Java 探针运行生产释放方法，检查即时回执及删除失败。MediaCodec 启动、GPU 与 JNI 并发行为仍需 Android 真机复测。

2026-10-22：新增带输出 token、采样代次、阶段和序号的视频帧通道。Android 监听注册冻结身份，请求完成与实际新 buffer 取图共同确认候选；重配、暂停和 seek 关闭采样，恢复点后的新帧确认再开启活动代次。Windows 消费回调携带已渲染纹理的身份与采样代次，经 render 队列验证后发布。首帧和健康证据继续走独立消费进度入口。同 token 重配保留批次序号，移除旧的无类型 Android 请求回调。

2026-10-23：采样开关回执返回 render／Surface 临界区冻结的代次状态。运行时等待当前操作回执，隔离先前开关的迟到状态；活动状态早于回执交付时按代次保留并在确认后处理。seek 完成后等待该 seek 的媒体时钟确认，再进入平台新帧预备窗口。Windows 新 token 重置采样准入，序号仍在同 token 重配期间连续。

2026-10-23（piliaurora.8）：Windows ANGLE 构造失败时回滚 mutex、D3D device/context、纹理与已初始化的 EGL 资源；纹理交由 ComPtr 单引用持有，旧 Windows adapter/factory 使用作用域回收并核对创建结果。共享 EGLDisplay 按 display 计数，不同插件输出线程通过同一把锁协调初始化、登记和最后终止。`tool/probes/windows/windows_angle_rollback_probe.py` 编译生产类与方法，注入各创建阶段失败，核对共享／独立 display、跨线程实例和 resize 后的资源回收。


2026-10-23（piliaurora.9）：Windows resize 与 ResetRenderer 共用持续到 Flutter 纹理注销回执完成的操作屏障；重建请求依次排队，尺寸请求继续合并，重建持有操作槽直到新后端配置完成。连续重建、失败和销毁均排空已接受请求的回执。`tool/probes/windows/windows_renderer_release_probe.py` 使用完整生产 VideoOutput 与线程池，通过延迟注销回执检查双向交错、连续重建、resize 失败、软件回退及销毁后的回调次数和资源释放。

2026-10-23（piliaurora.10）：Android 重建 Surface 时，旧 Surface 或 JNI 全局引用释放失败会终止重建，并向平台通道传播错误。未确认删除的旧引用继续由输出持有，后续释放可继续回收，避免新引用覆盖旧句柄。主机故障探针覆盖旧资源释放失败、复合故障与后续完整释放。

2026-10-23（piliaurora.11）：Android Surface 与 JNI 全局引用完整创建后再登记到输出；构造失败、JNI 引用创建抛错或返回零句柄时，回收本次新建的 Surface 并向平台通道传播错误。回滚释放失败时保留 Surface 所有权与原始错误，后续输出释放继续回收。主机故障探针补齐创建失败、零句柄、回滚失败与重试恢复。

2026-10-26（piliaurora.12）：Windows 每个渲染任务处理一帧，持续到达的更新合并后排回队尾，避免渲染循环长期占用输出线程、阻塞卸载时的输出代次撤销。`tool/probes/windows/windows_renderer_release_probe.py` 通过连续更新期间排入撤销请求，检查渲染与卸载任务的交替执行。
