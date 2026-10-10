# 功能领域地图

查找功能代码时，先确定所属领域，再从页面沿 API、模型和服务追踪调用关系。

## 领域关系图

```mermaid
flowchart TD
    Main[MainApp / 根路由]
    Discover[内容发现<br/>首页、热门、排行、搜索]
    Video[视频与番剧<br/>详情、播放、分集]
    Social[动态与社交<br/>动态、关注、粉丝、消息、私信]
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
    Discover --> Video
    Discover --> Social
    Video --> Player
    Video --> API
    Live --> API
    Live --> Services
    Social --> API
    Manage --> API
    Account --> API
    Download --> Services
    API --> Models
    Services --> Models
```

箭头表示常见的后续查阅方向。页面不一定经过图中的每一层，具体调用以当前源码为准。
## 首页与内容发现

- 页面：`lib/pages/main/`、`home/`、`rcmd/`、`hot/`、`rank/`、`popular_*`、`search*`。
- API/模型：`lib/http/api.dart`、`search.dart`、`lib/models/remote/` 下的 `popular/`、`search/` 等。
- 入口：根路由 `/` → `MainApp`；具体子页见 `lib/router/app_pages.dart`。
- 推荐和热门功能受响应结构、分页及登录状态影响；改动后先检查对应领域的测试。

## 视频、文章、番剧与音频

- 页面：`lib/pages/video/`、`article/`、`article_list/`、`pgc/`、`audio/`、`music/`。
- API：`lib/http/video.dart`、`pgc.dart`、`music.dart`、`reply.dart`。
- 播放：`lib/plugin/pl_player/`；播放诊断见 `lib/services/diagnostics/player_diagnostics.dart`。
- 模型：`lib/models/remote/video/`、`pgc/` 及顶层视频模型。
- 修改前确认详情、播放地址和弹幕使用的资源标识（aid、bvid、cid），再调整页面。

## 弹幕与评论

- 页面：`lib/pages/danmaku/`、`danmaku_block/`、`main_reply/`、`my_reply/`。
- API/模型：`lib/http/danmaku.dart`、`reply.dart`，`lib/models/remote/danmaku/`、`reply/`。
- 渲染：通用组件和播放器插件；直播弹幕另走直播间链路。
- 视频弹幕和直播消息的生命周期不同。修改渲染或消息队列时分别检查两条链路和对应测试。

## 直播

- 页面：`lib/pages/live/`、`live_room/`、`live_search/`、`live_follow/`、`live_dm_block/`。
- API：`lib/http/live.dart`。
- 服务：`lib/services/live_stream/live.dart`、`live_packet.dart`、`live_packet_decoder.dart`。
- 排查直播问题时，分别检查连接、包解码、历史与未读消息、渲染和退出清理。

## 账号、登录与会员

- 页面：`login/`、`login_devices/`、`login_log/`、`member/`、`member_profile/` 等。
- API：`lib/http/login.dart`、`member.dart`、`user.dart`、`fan.dart`、`follow.dart`。
- 服务/本地状态：`lib/services/account_service.dart`、`lib/utils/accounts/`、`lib/utils/storage*`。
- 安全：严禁把 Cookie、Token、二维码登录信息或完整账号数据写入文档、日志和 issue。

## 动态、关注、粉丝与消息

- 页面：`dynamics*`、`follow*`、`fan/`、`msg_feed_top/`、`whisper*`。
- API：`lib/http/dynamics.dart`、`follow.dart`、`fan.dart`、`msg.dart`。
- 模型：`lib/models/remote/dynamic/`、`follow/`、`msg/`。
- 互动操作通常依赖登录状态及 CSRF/请求上下文。失败时同时检查请求和响应，不要只依据页面提示判断。

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



