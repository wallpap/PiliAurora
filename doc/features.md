# 功能领域地图

从页面目录进入对应领域，再沿 API、服务和模型追踪调用。

模块边界见[架构概览](architecture.md)；启动、播放、下载和消息的时序见[运行流程图](runtime-flows.md)。
播放器、弹幕和消息设置的具体行为与生效时机见[设置行为](settings-behavior.md)。

## 领域关系图

```mermaid
flowchart TD
    Main[MainApp / 根路由]
    Discover[内容发现<br/>首页、热门、排行、搜索]
    Video[视频与番剧<br/>详情、播放、分集]
    Social[动态与社交<br/>动态、关注、粉丝]
    Messaging[消息与私信<br/>未读、会话、聊天、分享]
    Live[直播<br/>直播间、直播弹幕、直播聊天]
    Manage[内容管理<br/>收藏、历史、稍后再看、订阅]
    Account[账号与设置<br/>登录、多账号、主题、偏好]
    Download[下载与离线]
    API[lib/http]
    Models[lib/models/remote]
    Services[lib/services]
    Player[lib/plugin/pl_player]
    Main --> Discover
    Main --> Account
    Main --> Messaging
    Discover --> Video
    Discover --> Social
    Video --> Player
    Video --> API
    Live --> API
    Live --> Services
    Social --> API
    Messaging --> Services
    Manage --> API
    Account --> API
    Download --> Services
    API --> Models
    Services --> Models
```

箭头表示功能间常见入口和关联。

## 通用菜单与选择字段

- 设置页的选择字段使用 `lib/common/widgets/app_select_field.dart`，菜单表面、圆角、边框、阴影和选中态由 `lib/common/widgets/app_menu_theme.dart` 统一提供。
- 全局 `popupMenuTheme` 和 `menuTheme` 已接入同一套参数，新增 `PopupMenuButton`、`showMenu` 或 `MenuAnchor` 会继承统一表面；需要当前值标题、选中勾和长列表滚动的设置项优先使用 `AppSelectField`。
- 组件行为测试见 `test/common/widgets/app_select_field_test.dart`。

## 首页与内容发现

- 页面：`lib/pages/main/`、`home/`、`rcmd/`、`hot/`、`rank/`、`popular_*`、`search*`。
- API/模型：`lib/http/api.dart`、`search.dart`、`lib/models/remote/` 下的 `popular/`、`search/` 等。
- 入口：根路由 `/` → `MainApp`；具体子页见 `lib/router/app_pages.dart`。
- 推荐和热门功能受响应结构、分页及登录状态影响；改动后先检查对应领域的测试。
- 首页推荐通过 `lib/pages/rcmd/viewport.dart` 与卡片共用网格几何，按列表实际高度、列数和字体缩放补足可视区及一行预取余量；底部留白不参与容量判断。骨架数量随容量变化。
- 首页控制器连续下载所需批次，下载与黑名单同步、合作作者检查重叠，发布前完成黑名单准备。App 推荐按 `idx/pull` 顺序请求；Web 首包按容量请求 20–50 项，首包之后最多同时下载两页，按索引合并并去重。刷新保留历史内容和位置提示，后续分页追加在历史之后。
- 首页滚动分页及其他发现列表使用 `lib/common/widgets/feed_pagination.dart` 按实际滚动范围与预取距离加载，避免构建末项触发请求。首页首屏补足由控制器负责；连续五页无有效增长时停止，分页失败保留内容并提供点击重试，刷新、切账号和退出会使旧查询失效。相关测试位于 `test/pages/rcmd/` 与 `test/common/widgets/feed_pagination_test.dart`。
- “账号与隐私 → 增强黑名单屏蔽”默认开启。发现类列表按作者 UID 过滤并沿原来源补位；子开关“检查合作视频作者”默认开启，对列表明确标识的合作视频补查 `staff`，任一作者命中即屏蔽。补查共用缓存和并发限额，收藏、历史、稍后再看和详情访问沿用原行为。适用范围、请求开销和回归入口见[信息流黑名单屏蔽](content-filtering.md)。
- 主导航、首页与排行通过 `TabActivity` / `TickerMode` 标记活动标签。`CachedImage` 在隐藏时卸载图片，页面数据和滚动位置继续保留；解码器创建与首帧交付共用两个并发名额，原生请求完成后归还名额。内存 LRU 仍为 64 MiB / 256 项，实际 RSS 与帧耗时需实机测量。
- `NetworkImgLayer` 按卡片物理尺寸与 1 Mi 像素预算为 B 站 CDN 的质量型缩略请求补充宽高，让动图源文件同步缩小；已有尺寸或裁剪参数的请求继续沿用原构图，原图查看与下载沿用原地址。

## 视频、文章、番剧与音频

- 页面：`lib/pages/video/`、`article/`、`article_list/`、`pgc/`、`audio/`、`music/`。
- API：`lib/http/video.dart`、`pgc.dart`、`music.dart`、`reply.dart`。
- 播放：`lib/plugin/pl_player/`；播放诊断见 `lib/services/diagnostics/player_diagnostics.dart`。
- 模型：`lib/models/remote/video/`、`pgc/` 及顶层视频模型。
- 修改前确认详情、播放地址和弹幕使用的资源标识（aid、bvid、cid），再调整页面。

### 播放器统一架构

- 页面通过 `PlaybackOwner` 提交查询、加载和控制命令；点播与直播使用同一套代次、播放意图和故障切换协议。
- 规范状态在 `lib/plugin/pl_player/playback/playback_contracts.dart`，请求与命令调度在 `playback_session.dart`，原生资源和输出在 `native_playback_runtime.dart`，控件投影仍在 `controller.dart`。
- 修改播放页面时先确认 `contentKey`、来源候选、起播策略和页面副作用；不要通过 URL 判断媒体身份，也不要在页面直接调用 Player 打开媒体。
- 修改平台输出时分别检查 Android Surface 预挂载、Windows 纹理交接、输出代次与释放回执。架构约束见[架构概览](architecture.md#播放统一架构)，时序见[播放器切源与网络恢复](runtime-flows.md#播放器切源与网络恢复)。
- 回归入口为 `test/plugin/pl_player/playback/` 与 `test/plugin/pl_player/android/`；设备行为使用 `tool/probes/playback/` 下的探针确认。

### 播放性能与资源控制

- 点播与直播在 Android、Windows 上共用 `lib/pages/danmaku/window_renderer.dart` 的测量、几何、额度、命中与资源管理。点播通过 `window_coordinator.dart` 准备媒体时间窗口，直播通过 `live_queue.dart` 处理有界候选和表情；两个生产挂载分别为 `view.dart` 和 `live_layer.dart`。字体/DPI 属于显示实例，设置分批准备并在帧边界切换。旧 Windows renderer/screen 及其专属回归已移至 `tool/experiments/danmaku/baseline/`，用于像素与性能对照。
- Windows 视频输出尺寸按启动时所在显示器限制；Android 可选实验性地按设备物理分辨率缩小输出 Surface，默认关闭。尺寸变化会合并并串行提交，Android 还等待纹理帧交接，避免快速旋转或切换时重复调整旧 Surface。输出限幅减少渲染表面和纹理开销；源视频仍按其原始分辨率解码。
- 点播与直播共享播放器时，播放会话按页面归属和请求代次管理；快速切源复用原生播放器、控制器和纹理资源。Android 对 MediaCodec、Surface 和图像输出错误采用有界恢复与回退；网络读取中断可按当前媒体和缓冲状态尝试恢复。
- Windows 独立播放窗口由 `lib/services/desktop_playback_windows.dart` 管理，每个子进程使用自己的播放器。渲染资源生命周期与超分切换见[Windows 视频输出](windows-video-output.md)。
- 直播消息连接复用有序解析 worker；弹幕数据按分段与条目数限界缓存，降低长时间播放时的对象和任务堆积。
- 实际帧率和内存占用取决于设备、编码与弹幕密度，测量口径见[维护与排障](maintenance.md#复现和测量)。

## 弹幕与评论

- 使用说明见[评论与表情包](comments-and-emotes.md)。评论长按菜单由 `lib/pages/video/reply/widgets/reply_item_grpc.dart` 的 `morePanel` 共用，覆盖主评论和楼中楼；拉黑调用 `VideoHttp.relationMod`，绑定确认前的账号。
- 表情包入口为输入面板的设置按钮。管理与预览位于 `lib/pages/emote/manage.dart`、`preview.dart`；请求集中在 `ReplyHttp`。详情接口返回 `emotes`，模型同时兼容列表接口的 `emote` 字段。分类筛选位于未添加页签，预览页面通过 Navigator 压入页面栈。
- 页面：`lib/pages/danmaku/`、`danmaku_block/`、`main_reply/`、`my_reply/`。
- API/模型：`lib/http/danmaku.dart`、`reply.dart`，`lib/models/remote/danmaku/`、`reply/`。
- 渲染：通用组件和播放器插件；直播弹幕另走直播间链路。
- 视频弹幕和直播消息的生命周期不同。修改渲染或消息队列时分别检查两条链路和对应测试。
- 视频弹幕支持相似内容合并和重复字号放大；Android 提供帧率档位，Windows 自动跟随屏幕。设置入口和规则见[弹幕合并与帧率设置](danmaku-merge.md)。合并实现位于 `lib/pages/danmaku/merge.dart`，过滤与后台结果接入位于 `controller.dart`；相关测试见 `test/pages/danmaku/`。

## 直播

- 页面：`lib/pages/live/`、`live_room/`、`live_search/`、`live_follow/`、`live_dm_block/`。
- 桌面直播侧栏在 `lib/pages/live_room/widgets/desktop_sidebar.dart`，包含观众、大航海预览和聊天区。“高能观众”和观众“查看全部”共用榜单入口；两个榜单共用 `live_list_sheet.dart` 的深色弹层。大航海列表复用 `MemberGuard.panel`，关闭时释放列表控制器。
- API：`lib/http/live.dart`。
- 服务：`lib/services/live_stream/live.dart`、`live_packet.dart`、`live_packet_decoder.dart`。
- 排查直播问题时，分别检查连接、包解码、历史与未读消息、渲染和退出清理。

## 账号、登录与会员

- 页面：`login/`、`login_devices/`、`login_log/`、`member/`、`member_profile/` 等。
- API：`lib/http/login.dart`、`member.dart`、`user.dart`、`fan.dart`、`follow.dart`。
- 服务/本地状态：`lib/services/account_service.dart`、`lib/utils/accounts/`、`lib/utils/storage*`。
- 安全：严禁把 Cookie、Token、二维码登录信息或完整账号数据写入文档、日志和 issue。

## 动态、关注与粉丝

- 页面：`dynamics*`、`follow*`、`fan/`。
- API：`lib/http/dynamics.dart`、`follow.dart`、`fan.dart`。
- 模型：`lib/models/remote/dynamic/`、`follow/`。
- 互动操作通常依赖登录状态及 CSRF/请求上下文。排查失败时核对实际请求与响应。

## 消息、私信与分享

| 功能 | 页面或入口 | 业务实现 |
| --- | --- | --- |
| 未读角标 | `home/`、`main/`、`whisper/` | `overview.dart` |
| 回复、@、点赞和系统通知 | `msg_feed_top/` | `feed.dart`、`feed_notifier.dart`、`feed_adapters.dart` |
| 私信会话及二级列表 | `whisper/`、`whisper_secondary/` | `sessions.dart`、`session_models.dart`、`session_providers.dart` |
| 聊天、历史、发送和撤回 | `whisper_detail/` | `conversation.dart`、`conversation_providers.dart`、`message_models.dart` |
| 接收设置、关键词屏蔽、联系设置 | `whisper_settings/`、`whisper_block/`、`whisper_link_setting/` | `settings.dart` |
| 私信分享及附言 | `share/`；调用入口见 `lib/utils/page_utils.dart` | `sharing.dart`、`sharing_adapter.dart` |

页面路径相对于 `lib/pages/`，业务文件位于 `lib/services/messaging/`。HTTP 和 gRPC 协议入口分别为 `lib/http/msg.dart`、`lib/grpc/im.dart`；适配器把响应转换成业务模型，页面订阅 Riverpod 状态。

修改时先核对主账号 Session 和资源所有者，再检查分页、写入结果及已读同步。发送结果待确认时应核对聊天记录，重复发送可能产生重复消息。详细约定见[消息模块](../lib/services/messaging/README.md)，回归测试位于 `test/services/messaging/`。

## 收藏、历史、稍后再看与订阅

- 页面：`fav*`、`history*`、`later*`、`subscription*`。
- API：`lib/http/fav.dart`、`lib/http/pgc.dart` 以及 `lib/models/remote/history/`、`later/` 等响应模型。
- 模型：`lib/models/remote/fav/`、`history/`、`later/`。
- 检查分页、排序、文件夹类型和 PGC/UGC 分支，确认使用了对应的响应模型。

## 下载与离线文件

- 页面：`lib/pages/download/`。
- 服务：`lib/services/download/download_manager.dart`、`download_service.dart`、`download_repository.dart`、`response_adapter.dart`、`stream_writer.dart`。
- API/配置：`lib/http/download.dart`，下载路径初始化在 `lib/app/app_paths.dart`，设置键在 `lib/utils/storage_key.dart`。
- 下载异常通常与目录权限、磁盘空间、网络重试、流式写入回压或任务退出顺序有关。

## 设置、主题与本地能力

- 页面：`lib/pages/setting/`、`settings_search/`、`space_setting/`。
- 基础设施：`lib/common/style.dart`、`lib/utils/theme_utils.dart`、`storage_pref.dart`、`platform_utils.dart`。
- Windows 还涉及窗口管理、WebView、托盘和路径；Android 还涉及权限、屏幕方向、JNI。

## WebView、分享、DLNA 与第三方能力

- 页面：`webview/`、`share/`、`dlna/`、`sponsor_block/`、`bubble/`。
- 相关依赖和代码：`flutter_inappwebview`、`dlna_dart`、`share_plus` 等，具体调用从页面 import 反查。
- 这些功能存在平台差异，新增逻辑时检查 Android 和 Windows 的编译路径。

## 修改一个功能时

1. 在 `lib/router/app_pages.dart` 找到页面路由。
2. 检查 `view.dart` 中的状态持有者和事件处理。
3. 沿 import 追踪到 `lib/http` 或 `lib/services`。
4. 核对响应模型及空值、分页和错误处理。
5. 查找对应的 `test/<domain>/` 测试，按需补充回归覆盖。
6. 运行 `fvm flutter analyze` 和相关测试；涉及平台行为时，再执行对应构建或设备验证。
