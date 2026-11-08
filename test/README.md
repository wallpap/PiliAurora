# 测试目录

从仓库根目录运行 `fvm flutter test`。传入文件或目录可选择对应范围，环境与平台验证要求见[构建与测试说明](../doc/development/build-and-test.md)。

## 运行范围

CI 测试脚本在共享逻辑回归之外按主机补充平台用例：Windows 运行桌面主题、浅深色窗口背景交接、小窗启动和原生全屏布局交接，Linux 运行选定的 Android 模拟平台通道测试。`plugin/pl_player/fullscreen_transition_test.dart` 依赖 `dart:io` 的实际 Windows 主机，直接在其他主机运行也会跳过；共享恢复测试中的 Windows 专用用例同样保留跳过条件。模拟通道测试不代替 Android 设备验收。

本地 Windows WebView 包的 `third_party/flutter_inappwebview_windows/test/webview_environment_channel_test.dart` 使用模拟通道检查多个 Environment 的独立创建与释放，防止实例 dispose 误发到静态工厂 id；可从仓库根目录单独运行，已接入 CI。网页纹理、Cookie 和原生图形资源仍由 Windows 设备验证。

```powershell
fvm flutter test test/plugin/pl_player/android/
fvm flutter test test/services/diagnostics/ test/pages/about/diagnostics_page_test.dart
```

按需实验位于 [`tool/experiments/`](../tool/experiments/README.md)，原生或设备探针位于 [`tool/probes/`](../tool/probes/README.md)，各入口和执行条件由对应目录文档说明。

## 目录与夹具

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

测试文件使用 `_test.dart` 后缀。同一组件的场景集中在对应文件，页面测试与服务测试分开组织。

- 领域专用 fixture 与调用者放在同一目录，例如 `services/download/download_fixtures.dart` 和 `services/messaging/messaging_fixtures.dart`。
- 简单的 Hive 内存读写共用 `support/memory_box.dart`。
- 挂起 HTTP 响应可使用 `support/controlled_http_adapter.dart`、`support/controlled_interceptor.dart`，通过 `waitForRequests` 等待真实请求到达，再提交对应响应。失败注入与订阅行为由对应领域提供。

合并测试时保留失败重试、账号与请求代次隔离、资源释放等边界，预期结果应独立于被测实现。异步用例优先等待请求或完成事件；检查计时边界时使用模拟时钟。

`testWidgets` 中持续创建 Timer 的对象应在用例体结束前释放。外层 `tearDown` 晚于测试绑定的计时器检查，不能代替这一步。

## 页面与账号

`pages/video/danmaku_pool_test.dart` 检查弹幕列表刷新、个人点赞状态恢复与取消点赞。挂起接口响应时检查首帧及慢响应期间的加载占位，另覆盖响应缺失、网络异常、查询重试不提交点赞，以及切换弹幕后迟到结果的隔离。

`pages/live_room/loading_test.dart` 在直播请求持续未返回时检查加载动画、控件、刷新与失败提示；`app/desktop_playback_launch_test.dart` 检查小窗显示不等待播放流就绪。前者使用内存设置和挂起的 HTTP 响应，后者模拟窗口平台调用；实际纹理、声音交接和窗口显示仍需设备验证。

`pages/rcmd/` 覆盖首页实际视口容量与字体缩放、页脚留白、连续下载、Web 有界并发与有序去重、合作卡片骨架与渐进揭示、历史位置保留、分页重试，以及刷新、账号切换和退出时的旧查询隔离。时序用例使用模拟延迟，覆盖数据交付；封面下载与解码沿用图片模块的独立验证。

`common/widgets/feed_pagination_test.dart` 检查控制器或快照所有者替换后旧请求不会阻塞新列表、快照修订无需 stream 即可补足视口，也检查 GetX stream 包装重建时同一列表仍保持请求串行。

`pages/blacklist/controller_test.dart` 覆盖串行分页、UID 去重、移除后的边界页补位、失败重试、账号切换与页面释放；`pages/account_queries/provider_test.dart` 覆盖设备和三类记录的账号绑定、日志隔离、行列映射、重试及旧账号内容隐藏。

`pages/follow/controller_test.dart` 覆盖关注、分组成员与关键词查询隔离、串行分页、排序切换、账号身份、分组写入回滚及过期编辑拒绝；组件回归检查搜索乱序及清空、Tab 选择保留、排序草稿隔离、分组面板计数与分享选人。`pages/follow_type/controller_test.dart` 覆盖粉丝及两类关系查询的隔离、昵称、分页、账号身份、关系写入互斥、其他本人粉丝入口刷新和分享选人；`pages/live_follow/controller_test.dart` 覆盖房间去重、离线过滤后的空页补足、分页元数据、失败重试、切号及释放。关注、直播、黑名单和关系查询均检查切号失败后不使用错误态保留的旧快照。

`pages/search/controller_test.dart` 覆盖 Riverpod 联想乱序、清空后重复输入、禁用联想、页面释放、多实例隔离、热搜/推荐刷新、共享历史、外部偏好同步与搜索页路由回传。`pages/danmaku_block/controller_test.dart` 覆盖规则刷新、不可变快照、编辑部分失败、请求账号与 CSRF 绑定、切号及订阅释放。`utils/account_profile_lifecycle_test.dart` 覆盖资料/余额的发起账号绑定、切号、页面释放和同账号查询乱序。

`pages/scoped_search/controller_test.dart` 覆盖直播／空间搜索的页面实例与关键词隔离、账号角色、分页失败重试、旧响应失效、空间视频 gRPC 及动态游标补页，并检查搜索提交、输入替换和清空重查。

`pages/space_setting/controller_test.dart` 覆盖隐私草稿、反向字段、保存互斥、失败重试、切号与刷新隔离及返回保存。`pages/live_settings/controller_test.dart` 覆盖直播屏蔽规则的房间与账号绑定、过期编辑、标签排序保存、推荐账号隔离及成功快照回调。真实直播服务与两端播放器仍需登录验收。

`pages/member_feed/controller_test.dart` 覆盖九类空间列表的账号与入口隔离、分页失败重试及去重、舰队前三名、迟到分页、专栏文集快照、充电排行和 PGC 筛选；`common/widgets/feed_pagination_test.dart` 另检查通知模式沿用父级滚动控制器。

`pages/search_results/controller_test.dart` 覆盖综合搜索分类与筛选隔离、推荐及主账号角色、综合卡片、串行分页、去重与移除、验证后原页重查、验证注册及提交的账号绑定与过期隔离、屏蔽过滤补页、离页以及分类回调。验证服务弹窗和真实视频跳转需登录后人工验收。

`services/account_providers_test.dart` 通过真实的账号切换、删除、凭据替换、刷新和清空入口，检查主账号与推荐账号通知隔离，以及最后一个订阅释放后的清理。列表测试另检查 PGC 首页与分页使用同一推荐账号、分组刷新后拒绝旧草稿、面板内新建后继续保存，以及搜索分页失败时保留已移除项。

## 图片与页面保活

`common/widgets/image/` 覆盖图片恢复时的单次取帧、原生取消后的解码名额归还、动画时长与有限循环、CDN 缩略尺寸及淡入过渡。`pages/home/controller_lifecycle_test.dart` 检查 Get 删除时的诊断源与 Ticker 释放；`router/get_route_lifecycle_test.dart` 检查真实出栈后路由引用清理及永久依赖保留。这些回归已接入 `tool/run-ci-tests.ps1`。

Windows 保活页面内存回归：先执行 `pwsh -File lib/scripts/patch.ps1 windows -SkipPubGet`，再运行 `fvm flutter test --no-pub test/common/widgets/inactive_sliver_cache_test.dart test/common/widgets/inactive_sliver_semantics_test.dart test/common/widgets/image/retained_layer_release_test.dart`。语义回归用弱引用核对已销毁卡片确实可回收，同时检查 State、数据、ScrollPosition、偏移、Focus 与语义恢复。绘制回归覆盖真实 Picture/source 释放、像素恢复与外部 Texture 保护；真实进程 Private/RSS 阈值由独立 Release 探针验证。

`image_lifecycle_test.dart` 用同一批 12 张图片检查 codec 创建上限、并发取帧和全部交付。`inactive_sliver_cache_test.dart` 直接使用生产 `InactiveFeedSliver`，保留滚动范围、资源收缩和恢复像素回归。`retained_layer_release_test.dart` 保留生产清理与实际 TabActivity、Texture、EngineLayer、viewport clip 的回归及共用场景中的策略对照。

## 服务与诊断

诊断记录存储及突发写入位于 `services/diagnostics/record_store_test.dart`。

消息业务状态、分享和协议分别由 `messaging_test.dart`、`sharing_test.dart`、`protocol_test.dart` 覆盖，设置和本地偏好另有测试。运行入口与实际服务验证范围见[消息模块](../lib/services/messaging/README.md#验证)。

`services/messaging/settings_test.dart` 检查同键串行、最后确认值回滚、不同键并发、刷新及失效。下载服务测试覆盖准备期间暂停、删除、切换、地址快照和文件提交排空；直播连接测试使用本地主机 HTTP/WebSocket 检查挂起握手取消、超时后备及认证。

`services/diagnostics/diagnostics_test.dart` 另检查 Windows 512 块检查点的独立快照预算、缓存去重及跳号后的检查点恢复，以及导出脱敏、本地原文保留和快照隔离；`redact_test.dart` 覆盖长普通文本与带前缀 token 键。VirtualQuery 与视频资源生命周期回归见平台探针，不能由 Dart 模拟通道测试替代。

## 播放会话与平台输出

`plugin/pl_player/playback/video_frame_timings_test.dart` 覆盖请求／消费阶段、输出身份、失效代次、序号高水位与独立消费证据；`pages/danmaku/frame_plan_identity_test.dart` 另检查共用调度的合帧、订阅释放、同一 view 换屏／变频和迟到 timing 隔离；`plugin/pl_player/android/preloaded_surface_test.dart` 使用实际 Android 输出控制器与模拟平台通道，检查临时 Surface 的解码前挂载、FILE_LOADED 几何确认及同尺寸输出复用。

`plugin/pl_player/playback/native_media_clock_sampling_test.dart` 覆盖异步媒体时钟采样的通知合并、在途结果失效、冻结锚点时刻、读取失败恢复，以及释放前等待原生读取完成；属性一致性由 `native_media_clock_test.dart` 覆盖。

`plugin/pl_player/playback/playback_session_test.dart` 覆盖 shader 重建触发的媒体重载，检查续播位置、原媒体源、请求身份和播放意图，并验证清除 shader 也走同一协议。实际 Windows 硬解、纹理、音频时间线和资源回收使用 `tool/probes/playback/windows_shader_switch.dart` 的生产会话模式检查。

`plugin/pl_player/playback/native_shutdown_test.dart` 使用真实原生运行时与模拟 Player/输出，检查 stop 成功及回执超时后继续等待完整卸载证据、输出释放回执和 Player 销毁的顺序，并覆盖 open 提交前失败和提交后的迟到文件身份。

`plugin/pl_player/playback/controller_recovery_test.dart` 将真实播放器控制器、会话与网络/音轨恢复器接到模拟原生输入，检查合流、分轨、只听音频、纯视频和本地媒体在断流、缓存耗尽、静音、暂停、跳转、切源、完成及关闭时的恢复协调；恢复预算矩阵见 `playback_session_test.dart`。

EOF 回归覆盖 keep-open 播放结束通知的文件归属、重复合并与 seek 后再次结束，以及网络点播提前 EOF 的续播位置、暂停意图和三次恢复预算。正常片尾容许两秒的时间戳尾差；未知时长与直播沿用完成事件。设备探针 `tool/probes/playback/session_device_acceptance.dart` 另检查真实片尾通知。

`plugin/pl_player/playback/playback_session_test.dart` 将真实会话连接到点播显示组件，检查暂停／缓冲通知立即冻结媒体位置并停止运动帧，迟到采样保持冻结，恢复取得新样本后连续推进。

`plugin/pl_player/android/raster_scheduling_test.dart` 检查 Raster CPU 亲和性的重复取得、恢复及其它策略／线程接管；实际调度和呈现间隔使用 `tool/probes/android/playback_jank.dart` 的亲和性对照模式验证。

`plugin/pl_player/playback/native_load_readiness_test.dart` 覆盖输出就绪前 EOF、等待几何时断流、迟到输出与直播几何等待预算。`preloaded_surface_test.dart` 还覆盖 preloaded 时 selected=false、FILE_LOADED 选轨确认、Surface 创建失败后的挂载中止与清理，以及 VO/wid 解绑到原生释放回执的顺序；`tool/run-native-probes.ps1` 的主机探针运行生产 Java Surface 创建和释放方法，检查失败回滚、即时与幂等回执及 JNI 删除失败。

`plugin/pl_player/playback/super_resolution_policy_test.dart` 检查源视频与当前屏幕物理分辨率的长短边比较，以及尺寸未知时延后加载超分的判定。`super_resolution_selection_test.dart` 检查不可用的显式选择保留档位和设置。超分入口由播放器底栏和视频更多设置面板提供。

`pages/video/playback_lifecycle_test.dart` 覆盖点播查询与媒体标识绑定、旧响应取消、暂停期间重载意图保留和字幕迟到结果隔离。`pages/live_room/controller_test.dart` 覆盖消息连接 single-flight、token/history 代次隔离、暂停/恢复以及关闭后的迟到回调；`services/audio_session_test.dart` 覆盖音频 duck 重复开始、结束先于音量命令完成及用户新音量保护；`services/audio_handler_lifecycle_test.dart` 覆盖多页面媒体归属与最后一项释放 keepalive。播放器会话、候选恢复和命令序列回归集中在 `plugin/pl_player/playback/`；其中 `playback_session_test.dart` 检查成功查询在加载完成后仍允许当前媒体的业务回写，并在新加载或 owner 失效后拒绝旧结果。`tool/run-ci-tests.ps1` 显式选择页面生命周期、播放会话与原生输出的关键回归，完整目录测试按需运行。deadline 验收通过虚拟时钟检查截止边界，不依赖机器执行耗时；播放／暂停预算回归同时检查原生调用未返回和排队等待，超时后仍串行落实最新意图。

## 弹幕来源与显示

`pages/danmaku/window_screen_test.dart` 覆盖生产点播的媒体锚点、暂停准备及期限唤醒，`live_layer_test.dart` 覆盖共用窗口上的直播运动、暂停、到期和隐藏释放。`window_renderer_test.dart` 对照实验基线检查 DPR、普通与高级弹幕透明度和重叠像素，并覆盖表情共享图片及资源预算；`window_interaction_test.dart` 检查局部来源失效后的选择、句柄和活动资源保留。旧 Windows 实现及其专属回归位于 `tool/experiments/danmaku/baseline/`。

`pages/danmaku/file_store_test.dart` 检查有序产物复用、原文件更换、取消和释放清理；`controller_test.dart` 检查暂停失败后的显式重试、最新范围收敛和规则重算；`cache_test.dart` 检查字节淘汰与覆盖状态。`window_coordinator_test.dart` 和 `echo_source_test.dart` 检查局部失效、旧就绪事件隔离及来源等待期间的本地回显；进程预留与取消后占用归还由 `services/danmaku/work_quota_test.dart` 覆盖。

`controller_test.dart` 另以 1.75 万条合法弹幕经过生产 gRPC 解码、共享租约、过滤合并和缓存提交，检查高密度分段可以完整加载；`grpc/decode_policy_test.dart` 核对已知字段与未知字段的存储估算，同时保留单条超限、字段数超限及有界 gzip 解压回归。

直播聊天的 10 万条压力集中在 `pages/live_room/chat_buffer_test.dart`；页面与控件使用超过 500 条容量的积压检查淘汰提示、阅读位置和退出释放。`window_screen_test.dart` 的帧率矩阵使用 6 组代表组合，每个目标帧率均覆盖 120/165 Hz 和两种采样密度。私信卡片布局保留窄屏浅色、宽屏深色两组。

## 弹幕帧调度

CI 显式选择弹幕生产链路与帧计划的核心回归，完整弹幕测试按需运行 `fvm flutter test --no-pub test/pages/danmaku/`。`frame_sync_fixture.dart` 供相位测试和帧率矩阵共用请求时间换算，两种模型都采用引擎的目标帧时钟；Android 模型由视频额外驱动 Dart 帧，隔离模型用于检查 ticker 自行唤醒。`frame_rate_diagnostics_test.dart` 检查实际更新、请求和定时器累计计数、单调时间及停止后的释放；相位测试同时检查稳定锁相状态。

`pages/danmaku/frame_plan_identity_test.dart` 模拟 BeginFrame 返回后递增 FrameData 的顺序，集中检查帧末编号与呈现目标的关联、无关和重复 timing 的隔离，以及停止后待匹配计划的清理。

`pages/danmaku/frame_plan_identity_test.dart` 注入旧回调、零值／负值／过大提前量和缺失 timing，检查异常连续确认、正常批次清除异常计数、回退后的更新间隔，以及暂停、重配和迟到批次不会反复切换。按秒批量报告的正常 timing 保持增强策略。

`pages/danmaku/native_video_frame_sync_test.dart` 使用独立的纹理刷新请求批次，覆盖引擎不提供零 Build timing 时的 60 FPS 相位学习、30 FPS 视频配 60 FPS 弹幕在 120 Hz 上的相位变化、匹配到失配再匹配时的退化与恢复、mpv 显示同步状态切换与订阅释放、批次限界、请求时间抖动、29.97 FPS 漂移与来源释放。相位变化测试同时断言弹幕更新频率和视频、弹幕合计刷新的次数。屏幕槽位与呈现的结论来自设备检查。

`pages/danmaku/frame_cadence_test.dart` 以12组代表组合记录更新所在屏幕槽位，覆盖24/30/60及23.976/29.97/59.94 FPS视频、60/90 FPS弹幕，以及稳定、每秒相位变化、请求完成时间抖动；小数帧率保留稳定源时钟漂移。120Hz无阻塞模型中检查更新间隔，防止平均帧率正常时仍夹入25ms长间隔；GPU呈现由目标设备检查。`frame_rate_diagnostics_test.dart` 另检查回调与截止时间跳过计数、间隔分布、暂停空档排除及正常槽位量化。

`pages/danmaku/frame_deadline_replay_test.dart` 使用诊断中提取的1.2秒数值时序，包含实际回调目标时间、交付时间和原生请求批次，回归亚毫秒偏差引发的连续更新延期。扩大矩阵见 `tool/experiments/danmaku/frame_cadence_device_matrix_test.dart`：用同一时序还原槽位抖动，覆盖Android目标时钟领先、119.88/120.0000076/120.12Hz读数、跟随屏幕及60/90/120FPS、29.97/59.94FPS视频、250ms批次与1秒积压压力；同时检查频率、最长更新间隔、屏幕上限合帧与停止后的释放。

`pages/danmaku/frame_late_delivery_test.dart` 分开模拟引擎请求截止与 Dart 回调交付，保留屏幕周期前、周期点和周期后的 8/8.333/8.5ms 交付延迟，检查 120Hz 屏幕上的 60FPS 仍保持两槽间距；另模拟 Timer 迟到 10/20/31.6ms，检查错过的更新合并及随后恢复。后者按实际迟到预算检查间隔。

`pages/danmaku/frame_rate_ticker_test.dart` 检查所属视图刷新率、屏幕降频、刷新率不可用、暂停与静音时的帧请求释放，以及 60/90/120 FPS 档位。测试使用模拟时钟，不测量设备屏幕或 GPU 合成。

`window_screen_test.dart` 在真实点播显示组件上检查 120/165Hz 下 60/90/120FPS 的模拟帧中的更新次数和最长、最短更新间隔，混入密集/稀疏锚点、突发来源通知及父组件重建。`live_layer_test.dart` 检查新消息和重建期间的实际滚动位移、限帧间隔、累计运动时间及暂停恢复。两者另交替注入 1/6ms 回调交付延迟，检查跟随屏幕时的逐帧时间和位移均匀；测试独立控制帧目标时间与单调时间。

一般弹幕场景以滚动、顶部固定、底部固定弹幕混合为基准，覆盖固定弹幕进入、驻留和到期时的滚动连续性。`window_screen_test.dart` 按 24/30/60FPS 推进视频位置，并交替注入锚点通知延迟，在混合场景中检查连续帧的媒体时间和滚动几何位移，以及两轮固定弹幕到期。

`window_screen_test.dart` 回放倍速升降和重复长按加速／恢复的媒体锚点，保留旧速率下的位置采样差，检查切速前后的逐帧位移与窗口代次。还覆盖停止通知先于新速率到达、短暂冻结／恢复、帧目标早于或晚于回调、显示空档，以及交接中的真实 seek；校准结束后仍须精确贴合原生时间。

设备上的连续性分析关联同一弹幕更新帧的实际呈现时间，保留逐帧相对波动，补充跨 1/2/3 帧的差分和 ±1/±2/±3（3/5/7 帧）完整窗口汇总，检查间隔误差、速度误差 RMS、呈现延迟极差及窗口总位移速度。组件回归中的帧目标时间用于验证运动与调度；设备探针补充 Raster 和 SurfaceFlinger 的同帧对应。

`video_presentation_cadence_test.dart` 检查 Android 点播采用的持续视频 vsync 策略：24/30/60 FPS 视频驱动下连续请求屏幕帧，弹幕仍以 60 FPS 的固定槽距推进；视频采样清空、过期、静音及停止后释放连续请求。原有按需调度和相位模型继续覆盖未启用此策略的调用路径。

旧 Canvas 屏幕的绘制、轨道、静音与 DPI 回归统一放在 `tool/experiments/danmaku/baseline/`，按需运行；`pages/danmaku/frame_rate_ticker_test.dart` 和 `text_renderer_test.dart` 保留当前窗口内核共用的调度及文字栅格回归。
