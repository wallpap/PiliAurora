# 消息、私信与分享

`lib/services/messaging/` 管理回复、@、点赞、系统通知、私信会话、聊天和私信分享。页面沿用 GetX 路由，通过 Riverpod 订阅业务快照；HTTP 与 gRPC 适配器负责协议转换。

页面入口见[功能领域地图](../../../doc/features.md#消息私信与分享)，请求与账号切换的时序见[运行流程](../../../doc/runtime-flows.md#账号消息与私信)。直播聊天使用独立的 `services/live_stream/` 连接和生命周期。

## 状态所有权

`Messaging.instance.session` 提供当前主账号的 `MessagingSession`，其标识包含账号 mid 和递增的 generation。`Accounts` 在主账号变化时通知 `Messaging`：先释放旧 Session，再发布新 Session。请求捕获发起时的账号，执行前和返回后都检查 Session 有效性。

应用根 Widget 提供 `ProviderScope`。`messagingSessionProvider` 跟随 Session 变化，依赖它的 provider 重建状态。关闭页面时释放页面订阅；账号共享资源由 Session 管理，聊天通过租约保留使用中的缓存项。

| 状态 | 所有者与释放时机 | 实现入口 |
| --- | --- | --- |
| 未读概览 | Session 共享，切换账号时释放 | [`overview.dart`](overview.dart) |
| 会话实体与各文件夹列表 | Session 共享，各列表保留自己的分页和快照 | [`sessions.dart`](sessions.dart)、[`session_providers.dart`](session_providers.dart) |
| 聊天时间线 | Session 持有缓存；页面 provider 和分享操作获取租约，结束时释放租约 | [`conversation.dart`](conversation.dart)、[`conversation_providers.dart`](conversation_providers.dart) |
| 分类消息列表 | 页面 Notifier 创建句柄；订阅释放或账号切换时销毁 | [`feed.dart`](feed.dart)、[`feed_notifier.dart`](feed_notifier.dart) |
| 接收、屏蔽和联系设置 | 页面 provider 创建句柄并登记释放 | [`settings.dart`](settings.dart)及对应 `whisper*` 页面 controller |
| 私信分享 | Session 绑定最近收件人查询，发送时借用同一聊天缓存 | [`sharing.dart`](sharing.dart)、[`sharing_adapter.dart`](sharing_adapter.dart) |

会话、时间线与未读快照保存在内存中。聊天缓存达到容量时回收空闲会话；仍有租约的会话继续保留，释放后再参与回收。`providers.dart` 将 `ValueListenable` 快照桥接成同步订阅，聊天时间线通过 `conversationSnapshotProvider` 订阅快照流。

本地“禁用收到的赞入口和角标”由 `preferences.dart` 订阅，首页与消息页共享最新偏好。它控制入口和角标汇总；账号的远端接收设置继续由 `settings.dart` 管理。

## 模型与协议边界

- [`session_models.dart`](session_models.dart) 定义稳定的 `SessionKey`、文件夹、会话目标和列表快照。会话目标区分私信、群、折叠入口、系统及客服等类型，操作是否可用由目标类型决定。
- [`message_models.dart`](message_models.dart) 定义聊天目标、消息内容、分页结果和操作结果。结构化内容复制并冻结嵌套集合，避免调用方后续修改影响发送内容。
- `session_adapter.dart`、`conversation_adapter.dart`、`feed_adapters.dart` 和 `sharing_adapter.dart` 调用 `lib/http/msg.dart`、`lib/grpc/im.dart`，转换协议响应并显式传入账号。

新增消息行为时，先确定状态由 Session 还是页面持有，再接入对应句柄和 provider。协议字段转换放在适配器，页面使用业务模型和操作结果。

## 异步结果与分页

查询返回后检查账号、请求代次和对象是否仍存活。刷新会使旧分页失效，消息按稳定标识去重；会话的删除、置顶、免打扰和已读操作更新共享实体，并使相关在途列表请求失效。撤回状态在聊天合并新响应时保留。

点赞列表保留 latest 与 total 分组，刷新重新开放分页。聊天历史和最新页的表情映射按文本合并，同文本采用最近响应的映射。接收设置写入前复制 protobuf 对象，失败回滚按操作版本核对，避免覆盖较新的操作。

未读概览合并重复刷新，查询失败保留已有数值，缺失分类保持未知。分类阅读成功后立即清除对应分类的本地未读数，使旧查询失效并重新查询；主页与消息入口订阅同一份结果。

## 发送与分享

消息写请求关闭网络层自动重试。`OperationResult` 区分成功、失败和 `OperationStatus.unknown`；网络异常可能发生在服务端已经接收消息之后，页面提示核对聊天记录再操作。

聊天文本在确认发送成功、且输入仍等于本次提交文本时清理；失败或结果待确认时保留。文本、图片、分享卡片和附言共用该聊天的发送锁，操作结束时释放锁。消息发送请求成功或结果待确认后重新查询时间线，并废弃发送前的在途读取。

分享最近收件人、卡片和附言绑定打开分享时的 Session。卡片确认成功后才发送附言；卡片结果待确认时结束本轮发送，卡片已发送而附言失败或待确认时，结果消息保留卡片已发送的信息。途中切换账号后，后续请求因旧 Session 失效而停止。分享操作结束后释放聊天租约。

## 已读确认

聊天消息行完成布局后调用 `markRendered`，推进渲染水位并提交已读确认（ACK）。读取历史本身不提交 ACK，渲染和已确认水位都单调递增。失败 ACK 等待更高水位或手动刷新后重试，成功后通知会话列表与未读概览更新。

系统通知先发布读取结果，再异步确认已读。确认失败时保留消息和原未读数，手动刷新可重试确认。已发出的确认在退出页面后成功，仍会更新所属账号的未读概览。

## 验证

```powershell
fvm flutter test --no-pub test/services/messaging/
```

以下测试已接入 `tool/run-ci-tests.ps1`：

| 文件 | 覆盖范围 |
| --- | --- |
| `messaging_test.dart` | 账号切换、订阅释放、共享会话、旧响应失效、分页、发送锁、撤回、缓存租约与 ACK 水位 |
| `sharing_test.dart` | 卡片与附言账号绑定、聊天共享锁、切换账号中止、未知结果和部分成功 |
| `protocol_test.dart` | 发送关闭重试、分享卡片协议字段、系统通知展示与 ACK 超时重试 |
| `preferences_test.dart` | 本地入口偏好的即时更新与订阅释放 |

测试使用模拟响应。涉及页面或协议改动时，还需登录后在 Android、Windows 检查实际服务与界面：

- 从主页进入消息，核对分类未读数、列表分页及返回后的角标。
- 在列表加载或发送期间切换主账号，检查旧数据和旧结果是否影响新账号。
- 在聊天中加载历史、发送文本或图片、撤回并返回列表，核对消息与已读状态。
- 从分享入口发送卡片和附言，核对收件人、聊天同步及失败提示。
- 修改接收设置、关键词屏蔽和联系设置，返回后重新读取确认。

报告问题时记录操作顺序、账号是否切换及结果状态，去掉消息正文、收件人标识和账号凭据。排障入口见[维护与排障](../../../doc/maintenance.md#消息与私信分享)。
