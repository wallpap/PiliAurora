# 维护与排障

## 开始修改前

1. 阅读根目录的 `AGENTS.md` 和 [文档索引](README.md)。
2. 执行 `git status --short` 和 `git diff`，了解并保留工作区已有改动。
3. 从路由或页面入口沿实际调用关系阅读：页面 → HTTP/Service → Model → 通用组件或平台插件。
4. 查看相关测试和诊断入口，确定本次修改范围。
5. 修改后运行相关测试与静态分析。播放器、直播、窗口和解码器改动还要说明实测覆盖的平台。

## 常见调用链

### 播放

`lib/pages/video/` → `lib/http/video.dart` 和视频模型 → `lib/plugin/pl_player/` → `media_kit` 与平台库。排查时区分地址解析、网络、解码、渲染和窗口阶段。播放器诊断入口在 `lib/services/diagnostics/player_diagnostics.dart`；切源与网络恢复见[播放器流程图](runtime-flows.md#播放器切源与网络恢复)。

排查播放状态时先记录 `PlaybackSnapshot` 的 phase、stage、requestId、loadId 和 outputEpoch，再沿 owner → session → runtime 对照日志。命令返回、原生事件和输出回执必须属于同一代次；直接读取 Player 或界面控件只能作为补充证据。Android Surface、Windows 纹理和首帧像素分别验收。

Windows 视频输出的 EGL/mpv 释放顺序、超分切换重建和首帧条件见[视频输出说明](windows-video-output.md)。原生库来源与构建步骤见[mpv 构建入口](../third_party/mpv/README.md)，探针命令见[平台探针](../tool/probes/README.md)。

### 视频弹幕

视频详情或播放器 → 弹幕 API 与解析 → 弹幕状态和渲染。Windows 高密度场景请记录编码、分辨率、输出尺寸、弹幕密度、硬件解码状态、构建模式和复现时长。

Windows 点播和直播弹幕自动跟随屏幕，排查时同时记录屏幕刷新率、窗口可见状态和引擎来源。使用[Windows 弹幕帧节奏探针](../tool/probes/README.md#windows-弹幕帧节奏探针)按 QPC、Flutter 帧编号与 Raster 时间段关联 PresentMon 事件；结合实际 `PresentMode`、已显示关联率、显示事件覆盖率与 ±1/±2/±3 连续性判定定位呈现波动。隐藏或完全遮挡窗口的采集应与正常可见场景分别解释。

自编引擎的固定版本、DWM 相位、DirectComposition、计时线程修复和装配步骤见[Windows 帧节奏引擎](../tool/engine/windows_frame_pacing/README.md)。应用输出中的 `engine-identity.json` 可核对补丁与 DLL 摘要；正式发布和 CI 使用 [Git 跟踪的预编译引擎](../third_party/flutter_engine/README.md)，本地构建通过参数显式选择。

弹幕加载为空时，先对照 `grpcDecode` 与来源快照中的 `elements/rawSegments/pendingSegments`。响应已收到但出现 `DanmakuWorkTooLarge` 时，分别核对解压、protobuf 预检和合并阶段的预算。已知元素字段槽位包含在元素基数内，未知字段另行计费；解码 worker 退出后保留存活的缓冲区与解析结果，合并沿用同一租约，已预留的输入计费一次。当前进程处理配额为 64 MiB，解压响应上限为 8 MiB，单条编码上限为 64 KiB；相关回归见 `test/grpc/decode_policy_test.dart` 与 `test/pages/danmaku/controller_test.dart`。

Android 高刷屏相位问题应同时记录 Scene、视频刷新和弹幕调度。开启性能记录后，`danmaku.layer.*` 快照的 `scheduler` 提供 `updates`、`frameRequests`、`timerWakeups` 累计数，按同一窗口的差值计算频率。`updates` 是实际 ticker 更新次数；`frameRequests` 是提交给引擎的帧请求数，含被合并的请求。`mode` 为 `locked`、`independent`、`vsync`、`muted` 或 `stopped`；`nativePeriodUs`、`syncPeriodUs`、`stableIntervals` 用于检查相位学习和回退，`lastUpdateMonotonicUs` 与 `lastFrameRequestMonotonicUs` 使用本进程单调时钟。Android 与 Windows 使用同一图层快照。图层还记录活动图片、缓存、窗口、配置准备和工作集预算；直播包含候选、资源任务和在途预留。计数读取沿用现有诊断周期。

`danmaku.processWorkQuota` 独立记录进程处理任务、预留字节和等待描述，来源页面卸载后继续保留。`obsoleteRunningTasks/obsoleteReservedBytes` 表示预约绑定的取消 token 已失效、任务仍未实际结束的占用。来源快照另有 `rawEstimatedBytes`、`processedEstimatedBytes/processedByteLimit`；显示工作集包含仍持有的表情源图及直播图片任务预留。这些字段按代码中的存储计费规则统计，RSS 与 GPU 使用现有进程和平台采样读取。

播放器快照的 `appLifecycle` 记录采样时的应用生命周期。性能记录的 `route` 跟踪当前页面，弹窗和菜单沿用下方页面；旧版记录会将未命名弹窗写为 `/`，因此该值不能单独证明用户已返回首页。系统后台策略由播放会话持有，覆盖加载、切换页面和后台媒体租约存续期间。

Android 的 `nativeFrameBatches/nativeFrameSamples` 统计刷新请求批次，`consumedFrameBatches/consumedFrameSamples` 单独统计带当前输出 token 的纹理消费。弹幕相位使用请求时间，消费时间用于首帧与健康证据；两路时间不可混入同一个相位学习器。Windows 保留输出消费诊断，弹幕跟随屏幕，不向图层传入视频帧时序。播放器 `runtime.initialize.*` 日志按资源槽等待、Player 创建和输出创建分别记录累计与分段耗时，可用于区分地址请求和本地初始化的等待。

点播图层的 `mediaAnchor` 记录位置、采样单调时刻、倍速、推进状态、连续域和有效期限；`presentationTimeUs` 是实际呈现的媒体时间，`sampledAtUs` 是读取诊断的单调时刻。结合 `visible/opacity/tickerEnabled` 区分隐藏与时钟冻结。播放器额外记录规范 `session` 的 phase、stage、runtime/request/load 身份、播放意图和 inhibitor。性能记录的各部分及各来源使用独立的有界脱敏预算，慢帧详情不会耗尽后续图层的预算。

统计弹幕实际频率时，按 Player、媒体代次和 `targetFrameRate` 分组，对相邻且目标不变、active、非 muted 的采样作累计计数差分；排除暂停、缓冲与目标切换边界。`targetFrameRate=0` 表示跟随屏幕，不能与 60/90 FPS 阶段混算。`locked/independent` 切换本身不足以证明实际更新频率异常。

连续滚动由 ticker 统一推进，位移按引擎帧目标时间计算，回调实际交付时刻用于锚点有效期、消息年龄和暂停边界。点播锚点校准、来源就绪、直播消息和组件重建合并到后续限帧更新，避免通知频率改变实际滚动节奏；直播重建保留两次更新之间的累计运动时间。首次显示、暂停和媒体连续域切换仍按各自状态及时处理。直播图层以 `presentationTimeUs` 记录投影到帧目标的已呈现时间，`motionUs` 记录截至实际采样时刻的累计运动时间，两者可以相差当前帧的预测余量。

Android 点播的滚动弹幕与视频共用 Flutter 输出 Surface。存在新鲜的原生视频请求采样时，持续接收 vsync，弹幕位置与准备工作仍按所选档位更新；持续合成期间沿用自身更新节奏，避免视频锁相重新移动位移槽位。诊断的 `requestEveryVsync` 区分连续帧请求与弹幕更新频率。视频采样清空或超过 1.5 秒后恢复按需请求；固定弹幕驻留、暂停、隐藏和空图层沿用原有启停规则。此策略增加输出提交次数，CPU/GPU 成本随目标设备和负载实测。

[Android 帧计划测试包](../tool/engine/frame_plan/README.md) 使用隔离引擎在 Raster 按内容提交，并启用 ticker 的 `preserveVideoPhase`。帧号在帧末读取，再与同帧 FrameTiming 核对呈现提前量；固定 SDK 在 BeginFrame 返回后才发布 FrameData，回调中读到的编号属于上一帧。

点播连续帧按媒体有效速率外推，锚点校准在帧目标时钟下以最多 5% 的速度差收敛。倍速和暂停／恢复交接保留已呈现相位：冻结时保持屏幕位置，恢复时将帧目标原点平移实际暂停时长，后续连续帧完成校准。交接期间的帧间隔小于锚点有效期时继续校准；普通播放超过 50ms 的显示空档或明显时钟偏移重新贴合媒体锚点。真实 seek、媒体连续域切换和锚点有效期限沿用原有边界。

媒体时钟的整组 libmpv 属性读取在 worker isolate 执行，采样时刻保留读取位置时的单调时间。通知积压时合并为最新一次，返回后核对 Player、文件、seek 和连续域；播放器释放前等待读取退出。排查 UI 回调迟到时，需同时测量同步属性读取的阻塞时间。

播放会话收到暂停、缓冲或 seeking 状态时立即发布冻结锚点，终态也停止外推；推进样本受当前运行状态约束。恢复时保留冻结位置并主动重新采样，使用状态切换后的新锚点继续运动，迟到结果按采样时刻和媒体身份过滤。冻结时间使用与原生媒体锚点一致的 `Timeline.now` 时钟域。

视觉连续性使用同一帧的 UI 更新、Raster 提交和平台实际呈现时间建立对应，Android 使用 SurfaceFlinger，Windows 使用 PresentMon；同时保留逐帧间隔、呈现延迟和媒体位移／实际间隔。按跨 1/2/3 帧的时间跨度与间隔序列差分检查周期性变化，并汇总以每帧为中心的 ±1/±2/±3 窗口（3/5/7 帧）：记录相对目标间隔误差与相对媒体速率误差的 RMS、呈现延迟极差及窗口总位移速度，汇总样本数、分位数和峰值。窗口内 RMS 保留长短帧相抵时的波动，首尾和缺帧边界采用完整窗口；暂停、切档和媒体代次分段计算。分析工具见[按需实验](../tool/experiments/README.md)。平均 FPS、长间隔计数和帧目标时钟下的位移速度分别保留为调度指标。

弹幕调度快照另提供 `frameCallbacks`（收到的 Dart 帧回调）和 `deadlineSkips`（早于更新截止时间而略过的回调）。结合 `updates/frameRequests` 差分，区分引擎未交付回调与回调到达后未更新。`updateGapBuckets` 记录连续更新的系统帧时间间隔，桶互斥，上限分别为 10/20/30/40/60/100ms，最后一桶大于100ms；按相邻快照差分读取窗口分布。`maxUpdateGapUs` 为累计最大间隔，`longUpdateGaps` 统计超过目标档位正常屏幕槽位量化的间隔，例如120Hz上的60FPS超过约16.67ms、90FPS正常的1/2槽交替不计为长间隔。暂停、静音和切档中断连续统计；所有计数继续累计。这些是弹幕更新时序，最终呈现需对照 Android 的 SurfaceFlinger／Perfetto 或 Windows 的 PresentMon。

帧调度矩阵覆盖约 5.7ms 以内的回调/批次迟到。`test/pages/danmaku/frame_late_delivery_test.dart` 另覆盖回调交付跨过帧目标后，按剩余时间请求仍可到达的下一更新槽位；20–31ms 的 Timer 迟到会按迟到量合并错过的更新。唤醒预算持续扣除交付延迟，超过目标时刻后也沿用同一时间基准。

Android `media.output.preloaded` 记录预挂载策略、证据和解码前 selected 值；mpv 在 on_preloaded 之后选轨，该阶段允许唯一候选尚未 selected，FILE_LOADED 继续核对实际选轨。`runtime.shutdown.*` 分段记录文件卸载、订阅清理、输出释放与 Player 释放；`player.disposed` 是诊断停止事件，不代表原生释放完成。Surface 释放先同步解除 VO/wid，再等待 JNI 删除回执。

退出排查先核对 `runtime.shutdown.requested` 与 `begin`，区分关闭请求已发出和原生命令队列已进入清理。后续 `waiting-for-file-identity`、`stopping-file`、`waiting-for-file-retirement`、`invalidating-output`、`releasing-subscriptions`、`waiting-for-media-clock`、`releasing-output`、`disposing-player` 标记各等待阶段；结合 `loadId/entryId/outputEpoch`、`endFileSeen/unloaded`、`nativeLifecycleUnknown` 和 `batchId` 关联同一次关闭。`stop-reply-timed-out` 表示 stop 回执超时，清理仍等待后续卸载事实。文件身份等待从 libmpv 接受加载命令开始；open 的前置停播或暂停失败时直接清理输出，提交后仍等待迟到的身份与卸载证据。

直播 FILE_LOADED 后缺少有效视频几何时，最多等待 5 秒，且不超过请求剩余预算；输出就绪前的 EOF/error 立即使加载失败。正常点播沿用请求预算，纯音频沿用无视频输出路径。`media.startup.failed` 记录几何等待失败，页面显示既有失败及刷新入口。加载动画的首帧可见性和驱动行为仍需设备验证。

设备侧可运行[Android 帧时间采集](../tool/probes/README.md#android-帧时间采集)，明确指定设备和包名。采集结果与应用诊断分别保留时钟域，结合相同复现窗口检查；SurfaceFlinger 图层、Android gfxinfo、Flutter UI 和 Scene 使用各自统计口径。

Android 视频输出建立后，`AndroidRasterScheduling` 将唯一 Raster 线程的 CPU 亲和性扩展到应用主线程可用的集合，让系统选择运行核心；输出释放或初始化失败时恢复。`raster.scheduling.applied` 记录原始、应用和实际 CPU 集合，`unavailable` 与 `restore.failed` 记录应用及恢复失败。多 Raster 线程或已有集合无需扩展时沿用当前策略。排查低帧率视频卡顿时还需检查 Raster 唤醒到实际运行的延迟，这段等待可能发生在 Flutter Raster 计时开始之前。对照入口见[播放慢帧探针](../tool/probes/README.md#android-播放慢帧对照)。

### 直播

`lib/pages/live_room/` → `lib/http/live.dart` 与 `lib/services/live_stream/` → 直播包解码 → 消息和弹幕 UI。连接、包解码、历史与未读消息、渲染和退出清理需要分别检查；消息时序见[直播消息流程](runtime-flows.md#直播消息与弹幕)。

### 下载

`lib/pages/download/` → `lib/services/download/` → `lib/http/download.dart`、响应适配和流式写入 → 本地下载目录。重点检查路径权限、磁盘空间、网络重试、写入回压和任务生命周期；任务状态见[下载流程](runtime-flows.md#下载)。

### 登录与账号

`lib/pages/login/` → `lib/http/login.dart` → `lib/services/account_service.dart`、`lib/utils/accounts/` 与本地存储。日志和 issue 内容应去掉 Cookie、Token、二维码和签名信息。

### 消息与私信分享

`lib/pages/msg_feed_top/`、`whisper*`、`share/` → `lib/services/messaging/` → `lib/http/msg.dart` 或 `lib/grpc/im.dart`。主页未读角标也使用该模块。所有权与异步约定见[消息模块](../lib/services/messaging/README.md)。

- 账号切换后出现旧数据：检查 `Accounts` 是否通知 `Messaging` 更换 Session，以及响应应用前的账号和代次检查。
- 会话删除、已读或撤回被刷新覆盖：检查稳定标识、共享实体和在途请求失效处理。
- 未读数未更新：区分查询失败、字段未知和已读确认失败；聊天需消息行完成布局后调用 `markRendered`，系统通知先展示再确认已读。
- 发送或分享状态待确认：先核对聊天记录，再决定是否重发；卡片成功而附言失败时分别核对两条消息。
- 退出页面后仍有状态更新：检查 provider 订阅、聊天租约和业务句柄的释放顺序。

复现记录注明消息分类、列表或聊天入口、是否切换账号、请求完成顺序及提示结果；隐去消息正文、收件人标识和账号凭据。相关回归测试位于 `test/services/messaging/`。

## 诊断入口

- `lib/services/diagnostics/`：播放器、HTTP、进程指标、历史读取、记录保存和脱敏。
- `lib/services/logger.dart`：日志服务。
- `lib/pages/setting/pages/logs.dart`：日志等级与性能跟踪设置；`lib/pages/about/diagnostics_page.dart`：诊断记录查看与导出。
- `lib/pages/log_table/`：服务端金币、经验和登录历史记录。

应用日志和播放器日志分别使用独立队列保留最近 200 条，查看时按记录原始时间排序，页面摘要显示路由、进程与窗口来源。落盘记录包含路由、进程 ID 和运行 ID。Windows 播放子窗口通过现有回环 WebSocket 把脱敏记录转发给主进程，统一写入、轮转和导出；窗口 ID 标识记录来源。关闭子窗口前请求主进程确认写入，等待上限为 3 秒。每个子窗口在连接主窗口前准备独立的本地轮转文件（`diagnostics/window-窗口编号/`），断连后继续保存；转发失败次数见各子窗口 `status.json` 中的 `storage.forwardingFailures`，导出清单的 `children` 字段汇总这些状态；离线窗口的状态时间表示最近一次本地刷新时间。性能采样写入该窗口的 `performance.jsonl`。主窗口导出时先请求已连接子窗口暂停写入并刷新队列，再同时收集子窗口文件，文件名以窗口编号区分；转发成功的日志会同时存在于主进程和子窗口文件中，可按 runId、sequence 识别同一记录。子窗口单文件预算为应用日志 1 MiB、播放器及性能日志 4 MiB，分别保留 2、2、4 个文件。进程被强制终止时，仍可能丢失未落盘队列。主窗口的日志等级、性能开关和采样周期变更会通过 IPC 同步到已连接窗口。

导出与清除共用串行协调流程：暂停期间新日志以编码后的字节保存在缓冲，合计上限为 400 条和 8 MiB；容量不足时优先淘汰低等级记录来保留错误。操作结束后恢复写入，溢出计入 droppedRecords；清除会同时清空子窗口旧队列，操作后的新记录仍继续保存。启动中或已断连的窗口跳过协调，其本地文件在本次导出/清除中保留，清单 `storage.skippedChildWindows` 与页面提示列明这些窗口；已连接窗口未在 3 秒内确认时操作报错。父进程意外退出时，子窗口最多暂停 60 秒后自行恢复。压缩使用已复制的快照，期间日志正常写入。


主进程在读取设置前准备诊断存储，启动异常写入后刷新；正常退出和移动端进入后台也刷新待写队列。

HTTP 请求失败由诊断拦截器统一记录，账号层负责用户提示。预期失败判定统一位于 `lib/http/request_failure_policy.dart`，同时控制日志降为 debug 和跳过 toast：覆盖主动取消、后台上报/在线人数/金币/弹幕分段、GitHub 与图片资源，以及自定义 SponsorBlock 服务器的 GET skipSegments。匹配使用 host/path 与方法，不使用整段 URL 的关键字，避免查询参数或相似域名误命中；其他请求失败保留 error，性能跟踪仍统计失败。暂停期间的异常报告会等待缓冲恢复写入的结果，被清除或淘汰的报告返回失败。播放器关闭时等待延迟释放最多 3 秒，释放失败或超时写入终态日志，再由窗口关闭流程刷新并销毁窗口。日志等级设为“关闭”时，该通道的未捕获异常也停止保存。Catcher 设备信息采用允许列表，设备唯一标识和指纹不进入新报告。Windows 多窗口转发、退出时序和 Android 后台行为仍需目标设备验证。
- [构建与测试](build-and-test.md)：本地验证方式和平台限制。

## 问题报告

请附上以下信息：

- 应用版本、Git 提交、构建模式和目标平台，以及操作系统、设备或显卡型号。
- Flutter/JDK 版本、复现步骤、媒体编码与分辨率、弹幕密度和复现频率。
- 登录、硬件解码和网络状态，以及脱敏后的诊断摘要和时间范围。
- 你推测但还没确认的部分。

## 复现和测量

- 对照测量使用固定媒体片段、构建模式、显示器/DPI、弹幕密度和解码后端。分别启动进程并重复采样；累计计数使用同一测量窗口的差值，初始画面无效的样本不计入结果。
- 分别记录 Flutter Build/Raster 帧时间、mpv 丢帧、进程内存和 GPU 显存。用 `hwdec-current` 确认解码后端；零拷贝和最终显示效果需要单独验证。输出尺寸限幅会改变渲染表面，源视频仍按原分辨率解码。
- 弹幕优化要同时检查接受数量、普通与高级弹幕的像素和透明度、慢帧及内存。预热会提前承担栅格化开销；缓存淘汰后仍可能被活动图片引用，因此也要观察活动工作集、字节上限和条目上限。
- Android 解码恢复要结合媒体生命周期、暂停、缓冲、seek、EOF、持续错误和实际出帧判断。单次取图错误或播放位置推进都不足以证明画面恢复。旋转验收覆盖播放中、暂停、恢复播放和切源。
- 独立音轨和视频使用同一绝对 seek 目标。Windows 空音视频输出烟测覆盖命令和时序，实际音频与 Android MediaCodec 分别验收。
- 直播历史与滚动期间的新消息积压分别限界，并检查恢复跟随、略过计数和退出清理。WebView 与原生播放器销毁前应等待异步任务退出，再检查退出、重建和多引擎场景。

本地实验记录放在 Git 忽略的 `doc/dev/`，临时输出放在 `build/`。保留复现条件和结论，清理失效样本、重复二进制和日志。历史设备数值应重新测量后再用于当前决策。

## Windows GPU 诊断采样

开启性能记录后，Windows runner 后台线程每秒采集一次，关闭记录或销毁窗口时释放 PDH query 与线程。样本 gpu 字段记录 PID、采样窗口、原生单调时刻及缓存年龄；250ms 记录周期可重复引用同一份 GPU 样本。

- adapters 通过 LUID 关联名称、VendorId、DeviceId，flutterUi 标识 Flutter 实际渲染显卡。usedByProcess 表示 Flutter 绑定、有效显存用量或非零引擎活动所确认的本进程使用证据。
- engines 保留本 PID 各物理适配器/引擎计数，busiestEnginePercent 是其中最繁忙引擎的比例。不同引擎并行工作，数值不直接相加。
- local、nonLocal 的 usageBytes、budgetBytes 来自 DXGI，均为调用进程口径；集显的 local 内存可能来自系统内存，与独显物理显存口径不同。
- warmingUp、PDH/DXGI 和内存 HRESULT 区分初始化、接口失败与合法零值。无有效引擎实例时不生成负载数值。

播放器和 Flutter 的活动在同 PID 下汇总。当前采样按 LUID 与引擎证据呈现跨显卡活动，未把 ANGLE、纹理复制及硬解设备逐个绑定到播放器实例。混合显卡、驱动不支持、设备丢失与采集开销的实测在目标设备上进行。
