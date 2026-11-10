# 功能领域地图

页面路径相对 `lib/pages/`，API 路径相对 `lib/http/`。从 `lib/router/app_pages.dart` 找路由，沿页面的 import 追踪服务和模型。模块边界见[架构](architecture.md)，异步结果见[状态管理](state-management.md)，时序见[运行流程](runtime-flows.md)。

## 代码与测试入口

| 领域 | 页面 | API／服务／模型 | 回归入口 |
| --- | --- | --- | --- |
| 首页、热门、排行、搜索 | `main/`、`home/`、`rcmd/`、`hot/`、`rank/`、`popular_*`、`search*` | `api.dart`、`search.dart`；`models/remote/popular/`、`search/` | `test/pages/rcmd/`、`test/pages/search/`、`test/pages/search_results/` |
| 视频、文章、番剧、音频 | `video/`、`article/`、`article_list/`、`pgc/`、`audio/`、`music/` | `video.dart`、`pgc.dart`、`music.dart`、`reply.dart` | `test/pages/video/`、`test/pages/article/`、`test/pages/pgc/`、`test/pages/audio/` |
| 播放器与原生输出 | 页面通过 `PlaybackOwner` 提交计划及命令 | `lib/plugin/pl_player/playback/`；`playback_contracts.dart`、`playback_session.dart`、`native_playback_runtime.dart` | `test/plugin/pl_player/`、`tool/probes/playback/` |
| 弹幕与评论 | `danmaku/`、`danmaku_block/`、`main_reply/`、`my_reply/`、`video/reply/` | `danmaku.dart`、`reply.dart`；远端同名模型 | `test/pages/danmaku/`、`test/pages/danmaku_block/`、`test/pages/community/` |
| 表情包 | `emote/manage.dart`、`preview.dart` | `ReplyHttp`；兼容详情 `emotes` 与列表 `emote` | `test/pages/community/`、`test/http/community_response_test.dart` |
| 直播 | `live/`、`live_room/`、`live_follow/`、`live_search/`、`live_dm_block/` | `live.dart`；`lib/services/live_stream/` | `test/pages/live/`、`test/pages/live_room/`、`test/pages/live_follow/` |
| 账号、登录、会员 | `login/`、`login_devices/`、`log_table/`、`member/`、`member_profile/` | `login.dart`、`member.dart`、`member_profile.dart`、`user.dart`；`lib/services/account_service.dart`、`lib/utils/accounts/` | `test/pages/login/`、`test/pages/account_queries/`、`test/pages/member_profile/`、`test/utils/accounts/` |
| 动态、关注、粉丝 | `dynamics*`、`follow/`、`follow_type/` | `dynamics.dart`、`follow.dart`、`fan.dart` | `test/pages/dynamics/`、`test/pages/follow/`、`test/pages/follow_type/` |
| 消息、私信、分享 | `msg_feed_top/`、`whisper*`、`share/` | [消息模块](../../lib/services/messaging/README.md)；`msg.dart`、`lib/grpc/im.dart` | `test/services/messaging/` |
| 收藏、历史、稍后再看、订阅 | `fav*`、`history*`、`later*`、`subscription*` | `fav.dart`、`pgc.dart`；`models/remote/fav/`、`history/`、`later/` | `test/pages/fav/`、`test/pages/history/`、`test/pages/subscription/` |
| 下载与离线 | `download/` | `download.dart`；`lib/services/download/`；路径在 `lib/app/app_paths.dart` | `test/services/download/` |
| 设置与主题 | `setting/`、`settings_search/`、`space_setting/` | `lib/common/style.dart`、`lib/utils/theme_utils.dart`、`storage_pref.dart` | `test/pages/setting/`、`test/pages/space_setting/` |
| WebView、DLNA、空降助手 | `webview/`、`dlna/`、`sponsor_block/` | 从 import 定位插件，核对 `third_party/` 的平台实现 | `test/pages/webview/`、`test/pages/dlna/`、`test/pages/video/cast_results_test.dart`、`test/pages/sponsor_block/`、对应依赖包测试 |

表中的 `models/` 相对 `lib/`；测试及探针路径相对仓库根目录。测试选择、夹具和设备边界见[测试目录](../../test/README.md)，设置生效时机见[设置行为](settings-behavior.md)。

## 首页与内容发现

- `rcmd/viewport.dart` 与卡片共用网格几何，按实际高度、列数和字体缩放补足可视区及一行预取，页脚留白不计入容量。App 推荐按 `idx/pull` 顺序请求；Web 首包按容量取 20～50 项，之后最多并行两页，有序合并并去重。刷新保留历史内容及位置提示。
- `lib/common/widgets/feed_pagination.dart` 以实际滚动范围触发分页；首页首屏补足由控制器负责。连续五页无增长时停止，失败保留内容，刷新、切号或退出使旧查询失效。所有者与快照修订的规则见[状态管理](state-management.md#查询与分页)。
- `lib/services/blocked_authors.dart` 按主账号同步完整黑名单。同步与首页下载并行，发布前完成过滤；管理页的局部名单不覆盖完整缓存，同步失败沿用该账号缓存，应用内拉黑或解除即时更新。
- `lib/services/cooperative_authors.dart` 处理合作作者；`rights.is_cooperation`、`is_union_video` 等明确标志触发补查，已知名单直接复用，否则查询详情的 `staff`。请求合并，共用两个并发名额，成功缓存一小时、最多 256 条，失败缓存一分钟；黑名单同步缓存五分钟。
- 首页普通卡片先显示，合作卡片按检查结果局部更新；增删时才更新列表，卡片对象身份保留图片子树。过滤入口在 `common/discovery_list_controller.dart`，作者判定在 `lib/utils/media_author_filter.dart`，用户范围见[黑名单屏蔽](../guides/content.md#黑名单屏蔽)。
- `TabActivity`／`TickerMode` 标记活动标签，隐藏页卸载 `CachedImage` 并保留数据和滚动位置。`NetworkImgLayer` 为 B 站质量型缩略图补充卡片尺寸，已有裁剪参数及原图查看／下载沿用原构图或地址。缓存字节不等于全部原生纹理占用，内存与耗时需实测。

## 消息、私信与分享

`lib/services/messaging/` 按主账号 Session 管理未读、通知、会话、聊天和分享；页面通过 Riverpod 订阅或租约使用。修改前核对账号 Session、资源所有者、分页与已读水位，发送待确认时保留草稿并核对历史。入口和释放协议见[消息模块](../../lib/services/messaging/README.md)，回归在 `test/services/messaging/`。

## 播放与窗口

主窗口和启动失败页的自绘标题栏在 `lib/app/desktop_title_bar.dart`，独立播放窗口沿用播放器控件。系统窗口初始化、浮层层级和全屏约束见[桌面窗口与标题栏](architecture.md#桌面窗口与标题栏)，设置生效时机见[桌面窗口设置](settings-behavior.md#桌面窗口)。

页面修改前核对 aid、bvid、cid、`contentKey`、候选来源和起播策略，页面副作用提交时检查资源及 owner 身份。URL 不承担业务内容身份，页面通过 owner 控制播放。约束见[播放状态模型](playback-model.md)，原生交接见[运行流程](runtime-flows.md#播放器切源与网络恢复)。

`lib/services/desktop_playback_windows.dart` 为每个小窗启动独立进程与播放器；主窗口管理排列、声音、设置快照和离线进度。Windows 超分重载、纹理释放与原生验证见[Windows 视频输出](../maintenance/windows-video-output.md)。Android 的 Surface 预挂载、旋转和 MediaCodec 恢复须单独验收。

视频全屏时 `VideoDetailOffstage` 保留面板状态并停止隐藏面板动画及解码。输出限幅只减少表面与纹理开销，源视频仍按原分辨率解码。帧率和资源测量见[维护与排障](../maintenance/troubleshooting.md#复现和测量)。

## 弹幕合并与调度

点播与直播共用 `danmaku/window_renderer.dart`，分别由 `window_coordinator.dart` 和 `live_queue.dart` 提供候选，挂载为 `view.dart` 与 `live_layer.dart`。媒体时钟、资源归属与来源更新协议见[架构](architecture.md#弹幕显示与来源)。

合并在 `danmaku/merge.dart`，过滤与后台结果接入在 `controller.dart`。在线按分段处理，本地文件稳定排序并保留全文件合并锚点；8～200 字符允许有界编辑差异，数字和否定词保持独立。普通文字池 0／3 参与，自己发送、不同模式、字幕及特殊弹幕独立。匹配最多保留 2048 组、每条检查 64 个候选，后台结果在来源或页面失效后丢弃。功能参考 [PiliNara](https://github.com/Starfallan/PiliNara#改动说明未来计划)，本项目未引入拼音依赖。

帧调度依据所在视图刷新率及播放器实际显示同步状态决定合帧准入。Android 同频目标跟随 vsync，读数容差 0.5 Hz；低档位提前半周期安排唤醒并扣除更新耗时。连续六个稳定且周期匹配的视频间隔允许相位校准，不稳定或显示同步未确认时回到独立调度；设置在播放器初始化时应用，采样到来保留已安排唤醒。模拟刷新和唤醒计数只作调度对照，设备耗电另测。

点播来源就绪仍核对修订，局部失效只撤回对应半开时间区间。弹幕点赞查询与重试不提交点赞操作，菜单共用 `video/widgets/danmaku_like_control.dart` 并绑定账号、弹幕及视频。旧渲染器仅作[实验基线](../../tool/experiments/README.md)，用户设置见[播放指南](../guides/playback.md#弹幕合并与帧率)。

## 通用菜单与选择字段

设置项优先使用 `lib/common/widgets/app_select_field.dart`，主题来自 `app_menu_theme.dart`，统一当前值、选中勾和长列表滚动。全局 popup/menu theme 统一菜单表面；内部选项用 `AppPopupMenuItem` 保证悬停圆角及裁剪，普通 `PopupMenuItem` 只继承外层主题。回归在 `test/common/widgets/app_select_field_test.dart`。

## 空降助手

接口适配依据 [BilibiliSponsorBlock 0.17.1](https://github.com/hanydd/BilibiliSponsorBlock/releases/tag/0.17.1) 及其[官方 API](https://github.com/hanydd/BilibiliSponsorBlock/wiki/API)。`skip` 跳过、`mute` 静音，整片标记与精彩时刻只展示；分类按名称保存并兼容旧数组，新增分类保留已有选择。网页 DOM、画中画和灰度分组不属于客户端播放协议。

静音通过 owner 独立配置提交，保留用户音量。`test/pages/sponsor_block/block_mixin_test.dart` 与 `test/utils/sponsor_block_settings_test.dart` 验证片段及配置，播放会话测试补充独立音量、配置合并和旧 owner 失效；真实服务和两端声音需设备验证。
