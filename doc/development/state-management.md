# Riverpod 状态管理

应用根节点在 `lib/app/app.dart` 提供 `ProviderScope`。消息、搜索入口、完整热搜榜、弹幕屏蔽规则、黑名单、账号查询、粉丝与关系查询、关注直播页已使用 Riverpod；路由及其他页面沿用现有实现。迁移按功能入口推进，先明确状态所有权，再移除对应的 GetX 状态注册。

## 所有权

| 状态 | 所有者 | 入口 |
| --- | --- | --- |
| 消息、私信、未读与分享 | 主账号 Session，页面通过订阅或租约使用 | [消息模块](../../lib/services/messaging/README.md) |
| 搜索历史、记录历史开关 | 应用 ProviderScope；历史由 Notifier 统一写入，开关订阅 Hive 设置变化 | `lib/pages/search/controller.dart` |
| 联想、入口热搜与搜索发现 | 每个搜索页面独立的 autoDispose family；最后一个订阅释放时取消防抖 | `searchProvider` |
| 完整热搜榜 | autoDispose provider，离开后释放 | `lib/pages/search_trending/controller.dart` |
| 当前主账号 | 订阅 Accounts 的主账号变更通知；依赖者释放后取消订阅 | `lib/services/account_providers.dart` |
| 弹幕屏蔽规则 | 主账号变化时重建，最后一个页面订阅释放时销毁 | `lib/pages/danmaku_block/controller.dart` |
| 黑名单及分页、移除操作 | 账号绑定的 autoDispose AsyncNotifier；刷新或切号使旧查询失效 | `lib/pages/blacklist/controller.dart` |
| 登录设备、登录/硬币/经验记录 | autoDispose FutureProvider；日志按类型隔离，依赖主账号身份 | `lib/pages/login_devices/controller.dart`、`lib/pages/log_table/controller.dart` |
| 粉丝、新增粉丝、共同关注和“我关注的人也关注 TA” | autoDispose family 按查询类型、目标 UID 与新增粉丝排序隔离；账号变化重建 | `lib/pages/follow_type/controller.dart` |
| 关注直播 | 账号绑定的 autoDispose AsyncNotifier，按原始响应分页 | `lib/pages/live_follow/controller.dart` |

FocusNode、TextEditingController、TabController 和滚动装饰状态由 Widget 持有与释放。路由参数与提示也留在页面；Notifier 返回业务结果，不依赖 Get 路由或全局加载弹窗。

## 异步与写入

- 搜索输入在防抖等待前使旧查询失效；清空和选择关键词也废弃旧建议。热搜与推荐各自按请求代次采用最新响应。
- 搜索结果页通过路由参数中的 `onIndexChanged` 回调返回分类，不再通过 Get.find 查找另一个页面的控制器。
- 主账号按对象身份发布，不能使用 Account 的 mid 相等语义：同一 mid 的新凭据也需要使依赖状态重建。Accounts 的 refresh、set、deleteAll、clear 和重新登录的 replaceCredentials 保持消息 Session 与通用账号订阅同时收到通知。
- 弹幕规则读取和写入捕获发起账号，HTTP 的账号上下文与 CSRF 来自同一对象。写操作关闭网络层自动重试。账号变化、状态重建或释放后，不发布旧响应，也不发送编辑的后续请求。
- 弹幕规则写入期间拒绝重复操作及刷新。编辑先删除、再添加；删除失败保留原规则并停止，删除成功但添加失败则保留已确认的删除状态并提示部分成功。
- 弹幕规则只在成功快照变化时同步播放器与本地缓存；读取失败或页面关闭不会用空列表覆盖已有过滤规则。服务端确认的修改立即应用到打开此页面的播放器。
- 账号查询页使用 `AsyncValue` 表达加载、结果及错误；HTTP 失败进入 AsyncError，关闭 provider 的自动重试，通过页面重试刷新。切号加载时隐藏旧账号内容，设备和各类日志的请求固定使用发起时的账号。
- 黑名单分页串行执行，失败保留内容和页码并等待显式重试；移除与分页互斥。移除成功后按远端偏移重读边界页并按 UID 去重，防止剩余条目前移后漏载。刷新和账号切换后的旧操作通过捕获的 Ref 所有者失效，不回写新查询。
- `FeedPagination` 保留 stream 订阅，也接受 `dataRevision` 快照修订和按对象身份比较的 `dataSource` 查询所有者。使用 Riverpod 的列表无需额外建立 stream；所有者改变时，新分页不等待旧请求完成。
- `AsyncValue` 在刷新或切号失败后可能继续保留旧 `value`。读取计数、自动分页和写入资格都要检查 `isLoading` 与 `hasError`，不能仅用 `value != null` 判断数据有效；错误页只允许重新查询。
- 粉丝与关系查询使用同一 `FollowQuery` family；目标 UID 为空时跟随主账号，显式 UID 则保留正在浏览的目标。昵称单独查询，分享选人保留原有回调。
- 粉丝关系写入按账号互斥，绑定发起账号及查询所有者。成功后保留当前入口的确认结果，并使其他本人粉丝查询变体失效，丢弃它们的旧读取；移除后重读边界页补足前移条目。查询刷新、账号变更或释放后的迟到写结果不更新页面。
- 关注直播按房间去重，优先使用服务端总页数或原始总数。模型保留过滤离线房间前的条目数量，过滤后的空页不会提前结束；缺少分页信息时按请求页大小继续，连续五页无有效增长后停止。分页失败保留已有房间、人数和页码，等待手动重试。

新增迁移优先使用领域内的直接 Notifier 和不可变状态。公共抽象应由实际重复行为驱动；复用已有 HTTP 和模型，避免为一次调用增加转发层。消息仍使用其既有 Session 资源协议。

## 验证

```powershell
fvm flutter test --no-pub test/pages/search/controller_test.dart test/pages/danmaku_block/controller_test.dart
fvm flutter test --no-pub test/pages/blacklist/ test/pages/account_queries/ test/common/widgets/feed_pagination_test.dart
fvm flutter test --no-pub test/pages/follow_type/ test/pages/live_follow/
fvm flutter test --no-pub test/services/messaging/
fvm flutter analyze --no-pub lib test tool
```

搜索测试包含搜索页路由回传；规则、黑名单、账号、粉丝与关系查询及关注直播通过 provider 与模拟 HTTP 验证刷新、分页、写入失败、账号切换和订阅释放。分享选人、错误态旧数据隐藏与直播空页补足另有组件测试。真实服务、分享选择及播放器显示行为仍需在 Android、Windows 登录后验收。
