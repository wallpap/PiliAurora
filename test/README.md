# 测试目录

从仓库根目录运行 `fvm flutter test`。传入文件或目录可选择对应范围，环境与平台验证要求见[构建与测试说明](../doc/build-and-test.md)。

`common/widgets/image/` 覆盖图片恢复时的单次取帧、原生取消后的解码名额归还、动画时长与有限循环、CDN 缩略尺寸及淡入过渡。`pages/home/controller_lifecycle_test.dart` 检查 Get 删除时的诊断源与 Ticker 释放；`router/get_route_lifecycle_test.dart` 检查真实出栈后路由引用清理及永久依赖保留。这些回归已接入 `tool/run-ci-tests.ps1`。

| 目录 | 范围 |
| --- | --- |
| `architecture/` | 依赖政策、模块边界和发布工作流约束。 |
| `common/widgets/` | 通用控件、图片、手势和进度条。 |
| `grpc/`、`http/` | 协议解码、请求转换和 API 选择规则。 |
| `pages/` | 页面与控制器；二级评论位于 `video/reply_reply/`，诊断页面位于 `about/`。 |
| `plugin/pl_player/` | 原生媒体源、跳转、硬解配置、解码分类和预览缓存。 |
| `plugin/pl_player/android/` | Android 解码恢复、Surface 输出与帧交接。 |
| `plugin/pl_player/video_output/` | 跨平台尺寸策略、输出调度、截图桥和绘制确认。 |
| `plugin/pl_player/playback/` | 会话与页面归属、查询/加载代次、命令序列、资源释放、网络和音频恢复、shader 更新与时序契约。 |
| `services/` | 下载、直播、设置同步及平台服务。 |
| `services/messaging/` | 消息账号隔离、订阅释放、共享会话、分页竞争、发送结果与已读水位。 |
| `services/diagnostics/` | 诊断编排、脱敏、HTTP 接线、历史读取、记录存储、日志和进程采样。 |
| `utils/` | 工具函数与账号状态。 |

测试文件使用 `_test.dart` 后缀，领域内共用的 fixture 与调用者放在同一目录，例如 `services/download/download_fixtures.dart` 和 `services/messaging/messaging_fixtures.dart`。

`pages/live_room/loading_test.dart` 在直播请求持续未返回时检查加载动画、控件、刷新与失败提示；`app/desktop_playback_launch_test.dart` 检查小窗显示不等待播放流就绪。前者使用内存设置和挂起的 HTTP 响应，后者模拟窗口平台调用；实际纹理、声音交接和窗口显示仍需设备验证。

`plugin/pl_player/playback/video_frame_timings_test.dart` 覆盖请求／消费阶段、输出身份、失效代次、序号高水位与独立消费证据；`pages/danmaku/frame_plan_identity_test.dart` 另检查共用调度的合帧、订阅释放、同一 view 换屏／变频和迟到 timing 隔离；`plugin/pl_player/android/preloaded_surface_test.dart` 使用实际 Android 输出控制器与模拟平台通道，检查临时 Surface 的解码前挂载、FILE_LOADED 几何确认及同尺寸输出复用。

`plugin/pl_player/playback/native_media_clock_sampling_test.dart` 覆盖异步媒体时钟采样的通知合并、在途结果失效、冻结锚点时刻、读取失败恢复，以及释放前等待原生读取完成；属性一致性由 `native_media_clock_test.dart` 覆盖。

`plugin/pl_player/playback/native_shutdown_test.dart` 使用真实原生运行时与模拟 Player/输出，检查 stop 成功及回执超时后继续等待完整卸载证据、输出释放回执和 Player 销毁的顺序，并覆盖 open 提交前失败和提交后的迟到文件身份。

`plugin/pl_player/playback/controller_recovery_test.dart` 将真实播放器控制器、会话与网络/音轨恢复器接到模拟原生输入，检查合流、分轨、只听音频、纯视频和本地媒体在断流、缓存耗尽、静音、暂停、跳转、切源、完成及关闭时的恢复协调；恢复预算矩阵见 `playback_session_test.dart`。

EOF 回归覆盖 keep-open 播放结束通知的文件归属、重复合并与 seek 后再次结束，以及网络点播提前 EOF 的续播位置、暂停意图和三次恢复预算。正常片尾容许两秒的时间戳尾差；未知时长与直播沿用完成事件。设备探针 `tool/probes/playback/session_device_acceptance.dart` 另检查真实片尾通知。

`plugin/pl_player/playback/playback_session_test.dart` 将真实会话连接到点播显示组件，检查暂停／缓冲通知立即冻结媒体位置并停止运动帧，迟到采样保持冻结，恢复取得新样本后连续推进。

`plugin/pl_player/android/raster_scheduling_test.dart` 检查 Raster CPU 亲和性的重复取得、恢复及其它策略／线程接管；实际调度和呈现间隔使用 `tool/probes/android/playback_jank.dart` 的亲和性对照模式验证。

`plugin/pl_player/playback/native_load_readiness_test.dart` 覆盖输出就绪前 EOF、等待几何时断流、迟到输出与直播几何等待预算。`preloaded_surface_test.dart` 还覆盖 preloaded 时 selected=false、FILE_LOADED 选轨确认、Surface 创建失败后的挂载中止与清理，以及 VO/wid 解绑到原生释放回执的顺序；`tool/run-native-probes.ps1` 的主机探针运行生产 Java Surface 创建和释放方法，检查失败回滚、即时与幂等回执及 JNI 删除失败。

CI 显式选择弹幕生产链路与帧计划的核心回归，完整弹幕测试按需运行 `fvm flutter test --no-pub test/pages/danmaku/`。`frame_sync_fixture.dart` 供相位测试和帧率矩阵共用请求时间换算，两种模型都采用引擎的目标帧时钟；Android 模型由视频额外驱动 Dart 帧，隔离模型用于检查 ticker 自行唤醒。`frame_rate_diagnostics_test.dart` 检查实际更新、请求和定时器累计计数、单调时间及停止后的释放；相位测试同时检查稳定锁相状态。

`pages/danmaku/frame_plan_identity_test.dart` 模拟 BeginFrame 返回后递增 FrameData 的顺序，集中检查帧末编号与呈现目标的关联、无关和重复 timing 的隔离，以及停止后待匹配计划的清理。

同一文件注入旧回调、零值／负值／过大提前量和缺失 timing，检查异常连续确认、正常批次清除异常计数、回退后的更新间隔，以及暂停、重配和迟到批次不会反复切换。按秒批量报告的正常 timing 保持增强策略。

同一组件的场景集中在对应文件，诊断记录存储及突发写入位于 `services/diagnostics/record_store_test.dart`。页面测试与服务测试分开组织；`pages/danmaku/window_screen_test.dart` 覆盖生产点播的媒体锚点、暂停准备及期限唤醒，`live_layer_test.dart` 覆盖共用窗口上的直播运动、暂停、到期和隐藏释放。`window_renderer_test.dart` 对照实验基线检查 DPR、普通与高级弹幕透明度和重叠像素，并覆盖表情共享图片及资源预算；`window_interaction_test.dart` 检查局部来源失效后的选择、句柄和活动资源保留。旧 Windows 实现及其专属回归位于 `tool/experiments/danmaku/baseline/`。

`pages/danmaku/file_store_test.dart` 检查有序产物复用、原文件更换、取消和释放清理；`controller_test.dart` 检查暂停失败后的显式重试、最新范围收敛和规则重算；`cache_test.dart` 检查字节淘汰与覆盖状态。`window_coordinator_test.dart` 和 `echo_source_test.dart` 检查局部失效、旧就绪事件隔离及来源等待期间的本地回显；进程预留与取消后占用归还由 `services/danmaku/work_quota_test.dart` 覆盖。

`controller_test.dart` 另以 1.75 万条合法弹幕经过生产 gRPC 解码、共享租约、过滤合并和缓存提交，检查高密度分段可以完整加载；`grpc/decode_policy_test.dart` 核对已知字段与未知字段的存储估算，同时保留单条超限、字段数超限及有界 gzip 解压回归。

消息测试按业务状态、分享和协议分为 `messaging_test.dart`、`sharing_test.dart`、`protocol_test.dart`。运行入口与实际服务验证范围见[消息模块](../lib/services/messaging/README.md#验证)。

`pages/danmaku/native_video_frame_sync_test.dart` 使用独立的纹理刷新请求批次，覆盖引擎不提供零 Build timing 时的 60 FPS 相位学习、30 FPS 视频配 60 FPS 弹幕在 120 Hz 上的相位变化、匹配到失配再匹配时的退化与恢复、mpv 显示同步状态切换与订阅释放、批次限界、请求时间抖动、29.97 FPS 漂移与来源释放。相位变化测试同时断言弹幕更新频率和视频、弹幕合计刷新的次数。屏幕槽位与呈现的结论来自设备检查。

`pages/danmaku/frame_cadence_test.dart` 逐次记录更新所在屏幕槽位，覆盖24/30/60 FPS视频、60/90 FPS弹幕及稳定、每秒相位变化、请求完成时间抖动，另覆盖23.976/29.97/59.94 FPS视频的稳定源时钟漂移。120Hz无阻塞模型中检查更新间隔，防止平均帧率正常时仍夹入25ms长间隔；GPU呈现由目标设备检查。`frame_rate_diagnostics_test.dart` 另检查回调与截止时间跳过计数、间隔分布、暂停空档排除及正常槽位量化。

`pages/danmaku/frame_deadline_replay_test.dart` 使用诊断中提取的1.2秒数值时序，包含实际回调目标时间、交付时间和原生请求批次，回归亚毫秒偏差引发的连续更新延期。扩大矩阵见 `tool/experiments/danmaku/frame_cadence_device_matrix_test.dart`：用同一时序还原槽位抖动，覆盖Android目标时钟领先、119.88/120.0000076/120.12Hz读数、跟随屏幕及30/60/90/120FPS、29.97/59.94FPS视频、250ms批次与1秒积压压力；同时检查频率、最长更新间隔、屏幕上限合帧与停止后的释放。

`pages/danmaku/frame_late_delivery_test.dart` 分开模拟引擎请求截止与 Dart 回调交付，覆盖 1/8/8.333/8.5/10ms 的周期性交付延迟，检查 120Hz 屏幕上的 60FPS 仍保持两槽间距；另模拟 Timer 迟到 10/20/31.6ms，检查错过的更新合并及随后恢复。后者按实际迟到预算检查间隔。

`pages/danmaku/frame_rate_ticker_test.dart` 检查所属视图刷新率、屏幕降频、刷新率不可用、暂停与静音时的帧请求释放，以及 30/60/90/120 FPS 档位。测试使用模拟时钟，不测量设备屏幕或 GPU 合成。

`window_screen_test.dart` 在真实点播显示组件上检查 120/165Hz 下 30/60/90FPS 的实际呈现次数和最长、最短更新间隔，混入密集/稀疏锚点、突发来源通知及父组件重建。`live_layer_test.dart` 检查新消息和重建期间的实际滚动位移、限帧间隔、累计运动时间及暂停恢复。两者另交替注入 1/6ms 回调交付延迟，检查跟随屏幕时的逐帧时间和位移均匀；测试独立控制帧目标时间与单调时间。

一般弹幕场景以滚动、顶部固定、底部固定弹幕混合为基准，覆盖固定弹幕进入、驻留和到期时的滚动连续性。`window_screen_test.dart` 按 24/30/60FPS 推进视频位置，并交替注入锚点通知延迟，在混合场景中检查连续帧的媒体时间和滚动几何位移，以及两轮固定弹幕到期。

同一文件回放倍速升降和重复长按加速／恢复的媒体锚点，保留旧速率下的位置采样差，检查切速前后的逐帧位移与窗口代次。还覆盖停止通知先于新速率到达、短暂冻结／恢复、帧目标早于或晚于回调、显示空档，以及交接中的真实 seek；校准结束后仍须精确贴合原生时间。

设备上的连续性分析关联同一弹幕更新帧的实际呈现时间，保留逐帧相对波动，补充跨 1/2/3 帧的差分和 ±1/±2/±3（3/5/7 帧）完整窗口汇总，检查间隔误差、速度误差 RMS、呈现延迟极差及窗口总位移速度。组件回归中的帧目标时间用于验证运动与调度；设备探针补充 Raster 和 SurfaceFlinger 的同帧对应。

`video_presentation_cadence_test.dart` 检查 Android 点播采用的持续视频 vsync 策略：24/30/60 FPS 视频驱动下连续请求屏幕帧，弹幕仍以 60 FPS 的固定槽距推进；视频采样清空、过期、静音及停止后释放连续请求。原有按需调度和相位模型继续覆盖未启用此策略的调用路径。

`plugin/pl_player/playback/super_resolution_policy_test.dart` 检查源视频与当前屏幕物理分辨率的长短边比较，以及尺寸未知时延后加载超分的判定。`super_resolution_selection_test.dart` 检查不可用的显式选择保留档位和设置。超分入口由播放器底栏和视频更多设置面板提供。

`pages/video/playback_lifecycle_test.dart` 覆盖点播查询与媒体标识绑定、旧响应取消、暂停期间重载意图保留和字幕迟到结果隔离。`pages/live_room/controller_test.dart` 覆盖消息连接 single-flight、token/history 代次隔离、暂停/恢复以及关闭后的迟到回调；`services/audio_session_test.dart` 覆盖音频 duck 重复开始、结束先于音量命令完成及用户新音量保护；`services/audio_handler_lifecycle_test.dart` 覆盖多页面媒体归属与最后一项释放 keepalive。播放器会话、候选恢复和命令序列回归集中在 `plugin/pl_player/playback/`；其中 `playback_session_test.dart` 检查成功查询在加载完成后仍允许当前媒体的业务回写，并在新加载或 owner 失效后拒绝旧结果。`tool/run-ci-tests.ps1` 显式选择页面生命周期、播放会话与原生输出的关键回归，完整目录测试按需运行。deadline 验收通过虚拟时钟检查截止边界，不依赖机器执行耗时；播放／暂停预算回归同时检查原生调用未返回和排队等待，超时后仍串行落实最新意图。

```powershell
fvm flutter test test/plugin/pl_player/android/
fvm flutter test test/services/diagnostics/ test/pages/about/diagnostics_page_test.dart
```

按需实验位于 [`tool/experiments/`](../tool/experiments/README.md)，原生或设备探针位于 [`tool/probes/`](../tool/probes/README.md)，各入口和执行条件由对应目录文档说明。

旧 Canvas 屏幕的绘制、轨道、静音与 DPI 回归统一放在 `tool/experiments/danmaku/baseline/`，按需运行；`pages/danmaku/frame_rate_ticker_test.dart` 和 `text_renderer_test.dart` 保留当前窗口内核共用的调度及文字栅格回归。
