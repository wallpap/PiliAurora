# 异常处理与返回类型检查

## 当前进度（2026-11-09）

检查进行中，全仓检查尚未完成。主线继续检查动态模块，子代理并行检查文章领域；共享文档与提交由主线统一处理。

账号、历史与稍后再看批次的 37 项定向回归通过；收藏详情、排序和迁移批次的 66 项通过；弹幕、评论与表情包批次的 29 项通过；搜索批次的 38 项通过。后续按改动运行必要回归，不逐批重跑完整 CI。

此前风控、音乐／赛事与空降助手批次后的完整 CI：1218 项通过（`build/error-contract-ci-tests.log`）。`fvm flutter analyze --no-pub lib test tool` 只有上游控件副本中的 24 条既有 info，没有 error 或 warning。修改文件的格式检查无改动，`git diff --check` 通过。

## 检查原则

从调用方检查结果是否清楚：用户能否区分成功、失败、取消和无数据，开发者能否找到原始原因，agent 能否通过类型和邻近测试判断下一步。已有合理契约保留，避免重复重构。

- 业务失败返回已有的领域结果。可选内容缺失可以返回 null；保存失败、解析失败和结果待确认必须与成功区分。
- 公共接口声明实际返回类型。需要抛出的失败使用 Exception；在加载中读取数据等接口误用使用 StateError，不抛字符串。
- 页面显示可读提示。协议解析失败通过 `Error.fromException` 保留 cause 与 stackTrace；诊断日志记录类型和堆栈，省去可能含凭据的响应正文。
- 写请求发生网络异常后，先判断服务端是否可能已接收请求，再决定能否重试。消息模块保留 unknown 语义。
- 清理和消费者回调失败时保留主要操作结果，异步失败通过持有该操作的 Future 返回。资源释放和结果失效沿用模块自身协议。

`Request.requestApi` 处理 code/message/data 风格的业务接口。调用方声明 `ApiCallKind` 并提供领域解码器；查询默认使用 GET，写入默认使用 POST，特殊方法通过 `Options.method` 指定。重试按操作语义决定，请求进入拦截器前按已有角色规则固定账号，多步操作显式传递同一账号。页面负责处理结果和提示。原有 raw `get`／`post` 和二进制协议继续保留，尚未迁移的适配器仍需检查响应契约。

## 已完成的检查与修改

| 模块与入口 | 已确认的行为与修改 | 回归测试 |
| --- | --- | --- |
| 登录：`lib/http/login.dart`、`pages/login/controller.dart` | 使用 LoginResult，校验二维码、验证码、公钥和身份响应，保留风控数据。认证写请求关闭重试；缺少短信凭据时不启动冷却。 | `test/http/login_test.dart`、`test/pages/login/request_lifecycle_test.dart` |
| 公共错误：`lib/http/loading_state.dart` | Error 实现 Exception，错误文案缺失时提供兜底。在加载中读取数据时抛 StateError；原始解析原因与页面提示分开保存。 | `test/http/loading_state_test.dart` |
| 已有解析捕获：`http/dynamics.dart`、`live.dart`、`member.dart`、`reply.dart`、`search.dart`、`video.dart` | 使用结构化解析错误，消息协议转换后仍保留同一错误对象。分类搜索 data 的类型转换纳入捕获范围；联想在调试模式下也不会向页面抛解析异常。 | `test/http/search_response_test.dart`、搜索与直播页面回归、消息目录回归 |
| 下载：`http/download.dart`、`services/download/download_manager.dart` | 失败保留业务码，按实际媒体流选择画质。允许可选元数据缺失；没有媒体时返回明确的格式异常。完成回调只通知一次。 | `test/http/download_response_test.dart`、`test/services/download/`、视频生命周期回归 |
| 图片保存：`utils/image_utils.dart` | 单文件返回 SaveResult，取消返回 null。动态图片和批量图库保存按实际结果判断是否成功；选择器写入文件字节，批量保存复制共享缓存。 | `test/utils/image_save_results_test.dart`、`test/utils/image_actions_test.dart` |
| 账号请求：`utils/accounts/account_manager/account_mgr.dart` | Cookie 持久化失败通过请求返回专用异常，保留已收到的响应，防止因此重放请求。保存错误响应失败时，保留原始 HTTP 失败。 | `test/utils/accounts/cookie_failure_test.dart`、账号生命周期回归 |
| HTTP 重试：`http/retry_interceptor.dart` | 默认只重试 GET／HEAD／OPTIONS；gRPC POST 读取保留显式选择。解析错误和程序错误不重试。 | `test/http/retry_interceptor_test.dart` |
| 设置恢复：`services/settings/settings_backup.dart` | 调用方通过返回的 Future 收到 JSON 解析或后续持久化失败。格式损坏时不修改存储。 | `test/services/settings/settings_backup_test.dart` |
| gRPC：`grpc/grpc_req.dart` 及 audio／dm／dyn／im／reply／space 调用 | 强制声明查询或写入。查询传输失败返回 Error；写入禁用重试，无法从传输或响应确认结果时返回 UnknownResult。保留业务拒绝码和可读状态消息；解码错误保留原因，取消消费时返回失效并归还额度。 | `test/grpc/request_test.dart`、`test/grpc/decode_policy_test.dart`、消息、弹幕、空间搜索和空间列表回归 |
| 直播消息连接：`services/live_stream/live.dart`、`pages/live_room/controller.dart` | init 区分认证成功、失败和主动关闭。认证被拒绝时不启动心跳，等待认证设有超时，并保留节点的实际错误。失败后释放连接和缓存令牌；迟到结果不影响当前房间，断开后可以重试。 | `test/services/live_stream/`、`test/pages/live_room/controller_test.dart`、直播加载回归 |
| 启动装配：`app/bootstrap.dart`、`platform_setup.dart` | StartupResult 区分成功和失败，失败保留阶段、原始原因与堆栈。存储不可用时显示独立错误页，用户点击后才复制脱敏摘要。主窗口关闭或播放子进程发生失败时使用非零退出码；日志刷新有等待上限，失败时保留原始错误。初始化 Future 等待窗口显示和聚焦完成；设置可选刷新率失败时沿用系统模式。 | `test/app/startup_test.dart`、`startup_failure_test.dart`、`platform_setup_test.dart` |
| 桌面播放进程：`services/desktop_playback_windows.dart`、窗口菜单 | 握手解析和连接异常通过启动 Future 返回，保留进程退出码。失败后释放连接，允许重试；状态完整解析后再提交。后台消息、管道和清理异常都有处理与记录，清理失败时保留主错误。凭证只使用一次，并发窗口 ID 分开管理。关闭时等待进程缓存清理并释放服务器，菜单操作显示可读失败提示。 | `test/services/desktop_playback_windows_test.dart`、尺寸、快照、请求和诊断协调回归 |
| HTTP 业务边界：`init.dart` 的 `requestApi`、`api_response.dart` | 显式区分查询和写入，由领域解码器决定空数据语义。查询失败保留原因和堆栈；写入的传输或响应无法确认结果时返回 UnknownResult，明确的业务拒绝保留业务码。写入强制关闭重试；已取消且未分发的请求返回取消。用户提示省去底层异常正文。 | `test/http/api_response_test.dart`、`relationship_response_test.dart` |
| 关注／粉丝／黑名单／弹幕屏蔽：`http/follow.dart`、`fan.dart`、`black.dart`、`danmaku_block.dart` | 接入上述契约，保留账号和 CSRF 绑定。无效规则列表返回失败，新增规则校验 ID 和类型。编辑时区分已确认删除和添加待确认，领域结果保留原因与业务码。 | HTTP 响应回归及关注、粉丝、黑名单、弹幕屏蔽页面回归 |
| 收藏适配器、快速收藏与收藏夹创建／选择：`http/fav.dart`、`common_intro_controller.dart`、`fav_create`、`fav_panel` | 35 个接口接入业务契约，保留笔记和空间列表的可空语义。收藏夹缺少 ID、名称或属性时返回失败；只有明确的 -404 响应才表示视频不可用。请求进入拦截器前固定账号，快速收藏等待实际写入并显示本次失败结果；切号后拒绝旧查询和后续写入。创建防重复提交，失败后保留草稿；空标题与加载中分开处理，迟到查询不再更新已释放的文本框。封面上传 Future 有消费者，裁剪取消时不上传。 | `test/http/fav_response_test.dart`、`test/pages/fav/operation_results_test.dart`、收藏详情、空间收藏和订阅回归 |
| 风控校验：`http/validate.dart`、`models/login/gaia_result.dart`、`RequestUtils.validate` | 挑战参数改用明确类型，取代可空 Map。验证通过时携带非空 ID，区分明确拒绝和协议／传输不确定性。空参数不发请求，缺字段不进入 WebView 或提交校验。取消、失效结果和不完整证明不触发成功回调；异步消费者完成或失败都通过同一 Future 返回。 | `test/http/validate_response_test.dart`、`test/utils/gaia_validation_test.dart`、登录回归 |
| 音乐与赛事：`http/music.dart`、`match.dart`、`pages/music`、`match_info` | 接入业务结果契约。音乐名称必需，封面、创作者、评论和赛事对象仍可缺失。重复加载、响应乱序、关闭和切号后不发布旧详情，旧评论绑定详情快照。音乐缺少评论来源时显示空状态，评论失败时保留详情；赛事详情和评论独立加载，非法路由显示可读错误。点赞显示在途状态，防止重复写入；确认成功后才更新当前账号快照，未知计数保持未知。 | `test/http/metadata_response_test.dart`、`test/pages/metadata/` |
| 空降助手：`http/sponsor_block.dart`、`pages/sponsor_block`、视频片段提交与搬运绑定入口 | 保留独立 HTTP 状态协议。8 个接口的查询解析和传输失败都通过结果返回，明确拒绝保留状态码；写入断连、服务端错误和损坏的成功响应返回 UnknownResult。页面省去原始响应正文，自定义服务器不绑定 B 站账号。统计数据先校验再展示，无效片段和配置在本地返回失败。片段提交防重入，失败时保留草稿，成功后只处理本次草稿和所属视频／面板。投票拒绝并发提交和迟到提示，状态查询拒绝旧结果；搬运查询失败时不按尚未绑定处理。 | `test/http/sponsor_block_response_test.dart`、`test/pages/sponsor_block/operation_results_test.dart`、既有跳过行为与设置兼容回归 |
| 账号、历史与稍后再看：`http/user.dart`、`pages/history*`、`pages/later*`、视频与卡片入口 | 28 个接口接入查询／写入契约，解析失败保留原因，写入待确认与明确拒绝分别交付。保留可空标签、余额和空列表语义，签名前固定账号；Cookie 登录缺少 App access key 时不再传入空签名参数。提示由调用方负责；删除和清空防重复，失败保留列表与数量，刷新、切号或换视频后拒绝旧结果。历史暂停成功后才更新状态，迟到查询不能覆盖已确认写入。 | `test/http/user_response_test.dart`、`test/pages/history/operation_results_test.dart`、收藏操作与账号查询／设置回归 |
| 收藏详情、搜索、两种排序与批量迁移：`pages/fav_detail`、`fav_search`、`fav_sort`、`fav_folder_sort`、`RequestUtils.onCopyOrMove` | 写入绑定原账号与目标收藏夹。不同条目可并发取消，同项和重叠批量操作防重复；缺少详情信息时返回可重试错误。排序失败保留草稿，确认成功后提交副本；迁移失败保留选择与数量，提交状态留在弹窗内，取消后立即释放界面。切号、换列表或关闭页面后拒绝旧结果；删除只关闭所属页面。快速收藏的前置查询与写入均检查视频归属。 | `test/pages/fav/management_results_test.dart`、收藏操作与移除身份回归、收藏响应回归 |
| 弹幕、评论与表情包：`http/danmaku.dart`、`reply.dart`、发送面板、赞踩／置顶、评论可见性检查和表情包页面 | 接入查询／写入结果契约，保留业务码和写入待确认。修正弹幕管理端点和赞踩防重入；发送按提交草稿回显，失败或关闭时保留新草稿，切号／换对象后拒绝旧结果。表情包分页固定账号并检查进度、总数与详情归属。举报在所属弹窗显示提交状态，取消后的结果不关闭新页面，举报成功与屏蔽同步失败分别反馈。可见性检查按 12022 业务码判断，查询故障和重复分页不误报不可见。 | `test/http/community_response_test.dart`、`test/pages/community/operation_results_test.dart`、表情包模型与评论生命周期回归 |
| 搜索：`http/search.dart`、搜索首页与热搜控制器 | 查询接入统一契约，保留业务码、原始原因与堆栈，签名前固定推荐账号，无效风控凭据返回解析失败。搜索首页与热搜订阅账号变化并拒绝旧响应；已有结果分页保护保留。分 P 查询保留可空包装，空列表仍返回 null，损坏响应显示可读提示。 | `test/http/search_response_test.dart`、`test/pages/search/controller_test.dart`、搜索结果分页回归 |
| 动态 HTTP：`http/dynamics.dart` | 32 个接口接入查询／写入结果契约，保留业务码、原始原因和待确认结果。跨页与签名前固定账号，过滤补页检查游标进展并有请求上限；话题等可选内容仍允许为空。投票和预约创建必须取得有效 ID，编辑允许沿用已知 ID；发布只返回调用方使用的可空动态 ID，定时发布可缺少 ID。 | `test/http/dynamics_response_test.dart`、文章内容重试回归 |
| 动态发布与管理：发布／转发、投票／预约、动态列表、话题与提及，以及图片上传／删除 | 上传前固定账号与提交草稿，确认成功后只关闭所属页面；新草稿保留，切号或换对象后拒绝旧结果。投票与预约加载失败可重试，提交互斥，选项上传按对象回写；点赞、预约和可见范围仅在确认成功后更新。动态详情拒绝错配 ID，可见性查询失败不误报不可见。列表删除／置顶防重入，话题收藏／点赞与查询账号一致；补页检查进展，折叠项按位置替换并保留后续页。发布后的页面回调失败不改变已确认的成功结果。 | `test/http/dynamic_media_response_test.dart`、`member_dynamics_response_test.dart`、`test/pages/dynamics/` |
| 直播业务：`http/live.dart`、屏蔽规则、发送面板与表情查询 | 27 个接口接入统一结果契约，保留查询角色、签名账号、可选数据和明确业务码，GET 反馈也按写入禁重试。屏蔽规则保留原 Error／UnknownResult；文本和表情发送共用在途状态，保留新草稿，切号／换房／关闭后拒绝旧结果。表情查询跟随主账号凭据变化，刷新前释放旧页签。 | `test/http/live_response_test.dart`、直播设置、发送与表情回归 |

## 检查后保留的实现

- 消息 Session、聊天和分享已区分成功、失败与结果待确认。Session 保留传输不确定性，切号后拒绝旧结果，分享保留部分成功信息。统一 HTTP 与 gRPC 返回值时继续保留 unknown 语义。见[消息模块](../../lib/services/messaging/README.md)。
- 设置备份和 WebDAV 保留已有异常类型：备份格式校验使用 FormatException，配置误用使用 ArgumentError，传输失败使用 WebDavRequestException。本地替换规则和客户端关闭逻辑也保留。JSON 入口的异步错误返回方式已统一，回归位于 `lib/services/settings/`。
- 诊断导出保留 DiagnosticExportResult 和带阶段的 DiagnosticExportException。结果持有临时目录，并携带不完整信息。
- 播放会话保留 LoadResult、CommandResult 和 PlaybackShutdownResult，已区分就绪、失效、关闭、失败与清理不完整。原生输出和设备行为仍按[构建与测试](build-and-test.md)验收。
- 黑名单／合作作者的可选补查失败时，保留完整缓存或已知作者。null 和短暂失败缓存已有明确的降级语义，保留现有行为。
- 直播协议的无效包头返回 null；单包损坏不阻断同帧后续合法消息。worker 关闭或失败时结束在途 Future，由连接持有者处理失败并释放连接。保留 `live_packet.dart` 和 `live_packet_decoder.dart` 的现有契约。

## 待检查

- HTTP 传输、重试和其余业务适配器：逐接口核对响应结构、写入重试和调用方对可空返回值的处理。通用错误捕获的修正只覆盖部分问题，其余接口仍需逐一验收；剩余直播业务接口也在此范围内。
- gRPC 各领域响应模型和调用方：请求、写入不确定性与解码契约已检查，模型字段和业务行为继续按领域核对。
- 应用退出服务，以及启动中的后台账号与网络同步。桌面播放 IPC、直播消息连接和协议 worker 已检查。
- 播放小窗异常退出后的声音归属和主窗口恢复行为。
- 其余页面查询、收藏／历史／动态等写入，以及公共工具、模型的返回值和异常处理。
- 评论发布／删除、评论投票等其余 gRPC 领域消费，以及原生表情输入。弹幕发送、HTTP 赞踩／置顶／举报、评论可见性检查和表情包管理已完成本轮检查。
- 动态聚合主页、详情互动菜单及其余列表查询的账号生命周期。发布／转发、动态列表删除／置顶、话题管理与选择、提及、动态投票／预约已完成本轮检查。
- 搜索适配器之外的视频导航调用方，以及番剧／课程资料的领域消费。搜索首页、热搜、联想与结果分页已完成本轮检查。
- 文章、课程、话题、笔记和追番等其余收藏页面，以及订阅调用方。收藏详情、收藏夹操作、两种排序、批量迁移和视频快速收藏已完成本轮检查。
- 极验 WebView 自身的脚本失败、超时和取消结果。风控协调回归使用导航替身返回弹窗结果，未启动原生 WebView。
- 赛事卡片中可选字段的降级处理。已完成的检查覆盖接口、详情／评论生命周期和失败重试。
- 空降助手设置页的其余偏好持久化，以及手动时间输入提示。搬运绑定接口已回归；UGC 绑定确认流只完成源码检查和静态分析，尚未做页面自动化或真实服务验收。

## 验证记录

新增关键回归已列入 `tool/run-ci-tests.ps1`。测试使用模拟 HTTP、文件选择器和平台输入；文件保存回归还用临时目录核对实际字节。Android 图库、真实账号登录、服务器写入、原生播放器、GPU 和窗口行为仍需设备验收，各次运行结果随提交记录。

2026-11-09 在 Windows 主机执行的阶段验证：

- `pwsh -NoProfile -File tool/run-ci-tests.ps1`：1048 项通过，包含 gRPC 请求契约和本机 WebSocket 连接回归。
- `fvm flutter analyze --no-pub lib/plugin/pl_player lib/pages/danmaku test tool`：无问题。
- `fvm flutter analyze --no-pub lib test tool`：24 条 info，全部位于未修改的 `lib/common/widgets/flutter/` 上游控件副本；没有 error 或 warning。
- 登录、公共错误／搜索／消息、下载、图片、账号、设置／重试分别运行过对应目录或文件的定向回归，范围见[测试目录](../../test/README.md)。
- gRPC、消息、弹幕、空间搜索和空间列表组合回归 100 项通过；补充状态元数据场景后，gRPC 请求契约 12 项通过。直播连接、页面和加载组合回归 35 项通过。两组源码及测试的定向分析均无问题。
- 启动结果、独立错误页、平台窗口等待、小窗加载和架构约束组合回归 17 项通过。错误页测试未初始化 Hive，窗口和剪贴板使用模拟通道；Windows 关闭退出码和 Android 系统返回仍需设备验收。
- 桌面播放进程、尺寸、内存快照、请求和诊断协调组合回归 25 项通过，定向分析无问题。连接使用真实回环 HTTP／WebSocket，进程退出和原生窗口使用替身；播放器和窗口交接仍需目标设备验收。
- 启动和桌面进程修正后的完整 CI：1074 项通过（`build/error-contract-ci-tests.log`）。启动、桌面进程、菜单和关联测试的定向分析无问题。
- HTTP 业务边界、关注／粉丝／黑名单／弹幕屏蔽、账号 Cookie、登录、gRPC 和消息协议组合回归 108 项通过。新增业务边界及相关源码、测试的定向分析无问题（`build/http-contract-tests.log`、`build/http-contract-analyze.log`）。
- 收藏接口分支、快速收藏、创建／编辑、收藏夹选择、收藏详情、空间收藏、订阅、关系响应和账号 Cookie 组合回归 94 项通过，定向分析无问题（`build/fav-contract-tests.log`、`build/fav-contract-analyze.log`）。封面选择／裁剪和真实服务端写入仍需设备及登录验收。
- 收藏与账号捕获改动后的完整 CI：1150 项通过。`fvm flutter analyze --no-pub lib test tool` 仍只有上游控件副本中的 24 条既有 info，没有 error 或 warning。
- 风控响应、验证协调和登录组合回归 29 项通过，定向分析无问题（`build/validate-contract-tests.log`、`build/validate-contract-analyze.log`）。原生极验页面和真实平台校验仍需登录设备验收。
- 音乐／赛事接口、控制器、真实音乐页面、番剧分享和成员信息流组合回归 33 项通过，定向分析无问题（`build/metadata-contract-tests.log`、`build/metadata-contract-analyze.log`）。账号写入和原生评论交互仍需登录设备验收。
- 空降助手接口、真实提交／设置页面、投票、跳过／静音和设置兼容共 36 项回归通过。新增页面操作 7 项单独复验通过（`build/sponsor-block-operations.log`）。真实服务写入和 UGC 搬运绑定确认流尚未验证。

- 账号接口 6 项回归、历史／稍后再看操作、收藏操作、账号资料生命周期、账号记录和空间设置共 37 项定向回归通过；只复跑了失败用例。修改源码与测试共 17 个文件的定向分析无问题（`build/user-contract-tests.log`、`build/user-response-tests.log`、`build/user-write-tests.log`、`build/user-contract-analyze.log`）。未重跑完整 CI，真实账号写入和设备交互尚未验收。

- 收藏详情、排序／迁移、快速收藏及响应契约共 66 项定向回归通过。取消迁移后全局加载遮罩未释放的场景修正后，复跑迁移 2 项通过；新增收藏夹排序与删除 2 项通过。源码与测试定向分析无问题（`build/fav-operations-tests.log`、`build/fav-move-tests.log`、`build/fav-folder-tests.log`、`build/fav-operations-analyze.log`、`build/fav-final-analyze.log`）。未重跑完整 CI，真实服务写入尚未验收。

- 弹幕／评论响应、表情包模型、页面操作及评论控制器／生命周期共 29 项不同用例通过。修正只读 protobuf 默认对象与测试夹具后复验页面 9 项；新增评论管理 4 项和举报部分成功 1 项分别通过（`build/community-response-tests.log`、`build/community-operations-tests.log`、`build/community-retry-tests.log`、`build/community-management-tests.log`、`build/community-report-retry.log`）。修改源码与测试定向分析的 3 条提示修正后无问题（`build/community-final-analyze.log`、`build/community-search-analyze.log`）。未重跑完整 CI，真实账号写入和播放器回显仍需设备验收。

- 搜索响应、首页／热搜状态和结果分页共 38 项不同用例通过。首轮 HTTP 7 项与结果分页 14 项通过；修正账号夹具初始化和模拟时钟等待后，分 P 单项 1 项及首页／热搜 16 项通过（`build/search-contract-tests.log`、`build/search-pagelist-tests.log`、`build/search-state-tests.log`）。修改文件定向分析无问题（`build/community-search-analyze.log`）。未重跑完整 CI，真实服务与导航、动态话题调用方留待后续检查。

- 补查账号路由时修正 HTTP 评论列表与楼中楼默认账号：继续沿用播放记录角色，显式绑定主账号的可见性检查保持原语义。新增的角色分离回归 1 项通过（`build/reply-account-tests.log`）。

- 动态 HTTP 11 项与文章内容重试 2 项共 13 项不同用例通过。首批 11 项通过后只补跑完整投票与分页上限 2 项（`build/dynamics-response-tests.log`、`build/dynamics-extra-tests.log`）。修改文件的定向分析提示已修正（`build/dynamics-response-final-analyze.log`）。未重跑完整 CI，动态发布和管理调用方继续检查，真实账号写入尚未验收。

- 直播业务响应、屏蔽设置与发送面板 22 项通过，表情查询修正可重复创建 Ticker 后单项通过，共 23 项不同用例通过（`build/live-contract-tests.log`、`build/live-emote-contract-retry.log`）。修改的 9 个文件定向分析无问题（`build/live-contract-analyze.log`）。未重跑连接／worker 或完整 CI；直播推荐与分区的账号生命周期、榜单／菜单等其余消费，以及真实服务写入仍待检查。

- 动态上传／删除、发布／转发、投票／预约、点赞／可见范围、详情目标和列表／话题管理共 29 个不同用例通过。文件异步等待、输入控件存储和 toast 队列清理夹具修正后，仅复跑相关用例；新增发布回调失败断言已单独通过。日志：`build/dynamics-publish-contract-retry.log`（HTTP 3 项及表单 3 项）、`build/dynamics-publish-callback-tests.log`（发布 1 项）、`build/dynamics-publish-remaining-tests.log`（表单与可见性 2 项）、`build/dynamics-repost-retry.log`（转发 1 项）、`build/dynamics-operation-tests.log`（互动 2 项）、`build/dynamics-operation-retry.log`（互动 2 项）、`build/dynamics-detail-target-tests.log`（详情 1 项）、`build/dynamics-management-contract-retry.log`（管理 14 项）。27 个源码／测试文件完成定向分析，唯一的测试依赖提示修正后，单文件复查无问题（`build/dynamics-contract-final-analyze.log`、`build/dynamics-publish-final-analyze.log`）。未重跑完整 CI，也未进行真实账号写入与设备交互验收。
