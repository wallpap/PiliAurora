# Riverpod 状态管理

应用根节点在 `lib/app/app.dart` 提供 `ProviderScope`。消息、搜索入口、完整热搜榜和弹幕屏蔽规则已使用 Riverpod；路由及其他页面沿用现有实现。迁移按功能入口推进，先明确状态所有权，再移除对应的 GetX 状态注册。

## 所有权

| 状态 | 所有者 | 入口 |
| --- | --- | --- |
| 消息、私信、未读与分享 | 主账号 Session，页面通过订阅或租约使用 | [消息模块](../../lib/services/messaging/README.md) |
| 搜索历史、记录历史开关 | 应用 ProviderScope；历史由 Notifier 统一写入，开关订阅 Hive 设置变化 | `lib/pages/search/controller.dart` |
| 联想、入口热搜与搜索发现 | 每个搜索页面独立的 autoDispose family；最后一个订阅释放时取消防抖 | `searchProvider` |
| 完整热搜榜 | autoDispose provider，离开后释放 | `lib/pages/search_trending/controller.dart` |
| 当前主账号 | 订阅 Accounts 的主账号变更通知；依赖者释放后取消订阅 | `lib/services/account_providers.dart` |
| 弹幕屏蔽规则 | 主账号变化时重建，最后一个页面订阅释放时销毁 | `lib/pages/danmaku_block/controller.dart` |

FocusNode、TextEditingController、TabController 和滚动装饰状态由 Widget 持有与释放。路由参数与提示也留在页面；Notifier 返回业务结果，不依赖 Get 路由或全局加载弹窗。

## 异步与写入

- 搜索输入在防抖等待前使旧查询失效；清空和选择关键词也废弃旧建议。热搜与推荐各自按请求代次采用最新响应。
- 搜索结果页通过路由参数中的 `onIndexChanged` 回调返回分类，不再通过 Get.find 查找另一个页面的控制器。
- 主账号按对象身份发布，不能使用 Account 的 mid 相等语义：同一 mid 的新凭据也需要使依赖状态重建。Accounts 的 refresh、set、deleteAll、clear 和重新登录的 replaceCredentials 保持消息 Session 与通用账号订阅同时收到通知。
- 弹幕规则读取和写入捕获发起账号，HTTP 的账号上下文与 CSRF 来自同一对象。写操作关闭网络层自动重试。账号变化、状态重建或释放后，不发布旧响应，也不发送编辑的后续请求。
- 弹幕规则写入期间拒绝重复操作及刷新。编辑先删除、再添加；删除失败保留原规则并停止，删除成功但添加失败则保留已确认的删除状态并提示部分成功。
- 弹幕规则只在成功快照变化时同步播放器与本地缓存；读取失败或页面关闭不会用空列表覆盖已有过滤规则。服务端确认的修改立即应用到打开此页面的播放器。

新增迁移优先使用领域内的直接 Notifier 和不可变状态。公共抽象应由实际重复行为驱动；复用已有 HTTP 和模型，避免为一次调用增加转发层。消息仍使用其既有 Session 资源协议。

## 验证

```powershell
fvm flutter test --no-pub test/pages/search/controller_test.dart test/pages/danmaku_block/controller_test.dart
fvm flutter test --no-pub test/services/messaging/
fvm flutter analyze --no-pub lib test tool
```

搜索测试包含搜索页路由回传；弹幕规则测试通过 provider 与模拟 HTTP 验证刷新乱序、编辑失败、账号切换和订阅释放。真实搜索服务、规则同步和播放器显示行为仍需在 Android、Windows 登录后验收。
