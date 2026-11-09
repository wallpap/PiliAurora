# 异常处理与返回类型检查

本记录跟踪逐模块检查范围，避免重复重构已有合理契约。检查从调用方开始：用户能否区分成功、失败、取消与无数据，开发者能否定位原始原因，agent 能否从类型和邻近测试判断下一步。

## 判断约定

- 业务失败返回既有领域结果；预期的可选内容缺失可使用 null，不能把保存失败、解析失败或结果待确认伪装成成功。
- 公共接口声明实际返回类型。需要抛出的失败使用 Exception，加载中读取数据等接口误用使用 StateError，不抛字符串。
- 页面只显示可读提示；协议解析失败通过 `Error.fromException` 保留 cause 与 stackTrace。诊断日志记录类型和堆栈，不拼接可能含凭据的响应正文。
- 写请求发生网络异常时，判断服务端是否可能已经接收；此时避免自动重放。消息模块继续保留 unknown 结果语义。
- 清理或消费者回调的失败不覆盖主要操作结果；异步失败沿持有该操作的 Future 返回，释放和失效检查沿用模块自身协议。

## 已完成的范围（2026-11-09）

| 模块与入口 | 结论与处理 | 直接回归 |
| --- | --- | --- |
| 登录：`lib/http/login.dart`、`pages/login/controller.dart` | 使用 LoginResult；校验二维码、验证码、公钥及身份响应，保留风控数据；认证写请求关闭重试；缺失短信凭据不启动冷却 | `test/http/login_test.dart`、`test/pages/login/request_lifecycle_test.dart` |
| 公共错误：`lib/http/loading_state.dart` | Error 实现 Exception，缺失文案提供兜底；加载中错误取值抛 StateError；原始解析原因与页面提示分离 | `test/http/loading_state_test.dart` |
| 已有解析捕获：`http/dynamics.dart`、`live.dart`、`member.dart`、`reply.dart`、`search.dart`、`video.dart` | 使用结构化解析错误，消息协议投影保留同一错误对象；分类搜索 data 的类型转换进入捕获范围；联想调试模式不再向页面抛解析异常 | `test/http/search_response_test.dart`、搜索与直播页面回归、消息目录回归 |
| 下载：`http/download.dart`、`services/download/download_manager.dart` | 失败保留业务码；按实际媒体流选择画质，允许可选元数据缺失，无媒体返回明确格式异常；完成回调只通知一次 | `test/http/download_response_test.dart`、`test/services/download/`、视频生命周期回归 |
| 图片保存：`utils/image_utils.dart` | 单文件返回 SaveResult，取消返回 null；动态图片与批量图库保存检查真实结果；选择器负责写入实际字节；批量保存复制共享缓存 | `test/utils/image_save_results_test.dart`、`test/utils/image_actions_test.dart` |
| 账号请求：`utils/accounts/account_manager/account_mgr.dart` | Cookie 持久化失败通过请求返回专用异常，保留已收到的响应以阻止重放；错误响应保存失败不覆盖原始 HTTP 失败 | `test/utils/accounts/cookie_failure_test.dart`、账号生命周期回归 |
| HTTP 重试：`http/retry_interceptor.dart` | 默认只重试 GET／HEAD／OPTIONS，gRPC POST 读取保留显式选择；解析和程序错误不重试 | `test/http/retry_interceptor_test.dart` |
| 设置恢复：`services/settings/settings_backup.dart` | JSON 解析与后续持久化失败统一沿返回的 Future 交付，格式损坏时不修改存储 | `test/services/settings/settings_backup_test.dart` |
| gRPC：`grpc/grpc_req.dart` 及 audio／dm／dyn／im／reply／space 调用 | 强制声明查询或写入；查询传输失败统一返回 Error；写入禁用重试，传输或响应无法确认时返回 UnknownResult；保留业务拒绝码及可读状态消息；解码错误保留原因，取消消费返回失效并归还额度 | `test/grpc/request_test.dart`、`test/grpc/decode_policy_test.dart`、消息、弹幕、空间搜索和空间列表回归 |
| 直播消息连接：`services/live_stream/live.dart`、`pages/live_room/controller.dart` | init 明确区分成功认证、失败及主动关闭；拒绝认证不启动心跳，等待认证有超时；保留节点真实错误；失败后释放连接与缓存令牌，迟到结果不影响当前房间，已断开的连接可重试 | `test/services/live_stream/`、`test/pages/live_room/controller_test.dart`、直播加载回归 |

## 已检查且保留的契约

- 消息 Session、聊天及分享：成功、失败、结果待确认已有独立语义；Session 保留传输不确定性，切号后拒绝旧结果，分享保留部分成功信息。HTTP 与 gRPC 返回值统一时必须保留 unknown 语义。见[消息模块](../../lib/services/messaging/README.md)。
- 设置备份与 WebDAV 的领域异常类型：备份格式校验使用 FormatException，配置误用使用 ArgumentError，传输失败使用 WebDavRequestException；保留这些类型、本地替换规则和客户端关闭逻辑。JSON 入口统一异步错误交付，见上表及 `lib/services/settings/` 回归。
- 诊断导出：已有 DiagnosticExportResult 和带阶段的 DiagnosticExportException，结果拥有临时目录并携带不完整信息，保留原实现。
- 播放会话对外结果：LoadResult、CommandResult 和 PlaybackShutdownResult 已区分就绪、失效、关闭、失败及清理不完整，保留现有类型。原生输出与设备行为仍按[构建与测试](build-and-test.md)验收。
- 黑名单／合作作者补查：可选查询失败时保留完整缓存或已知作者；null 及短暂失败缓存属于明确的降级语义，保留原实现。
- 直播协议解析：无效包头返回 null，单包损坏不阻断同帧内后续合法消息；worker 关闭或失败时结束在途 Future，连接持有者处理解析失败并释放连接。保留 `live_packet.dart` 和 `live_packet_decoder.dart` 的既有契约。

## 后续检查范围

以下范围尚不能视为完成全量检查：

- HTTP 传输、重试和其余业务适配器：逐接口核对响应形状、写入重试及调用方对可空返回值的判断；现有通用捕获的修正不等同于所有 HTTP 接口已验收。
- gRPC 各领域响应模型及业务调用方：请求、写入不确定性与解码契约已检查；模型字段和业务行为继续随各领域核对。
- 桌面播放进程和启动／退出装配；直播消息连接与协议 worker 已检查，剩余直播业务接口仍随 HTTP 模块核对。
- 启动装配已定位一项问题：`app/bootstrap.dart` 在主进程存储初始化失败时复制异常到剪贴板并调用 exit(0)，会覆盖用户剪贴板且将启动失败报告为成功。后续需完善可见的失败交付与进程结果，并验证平台窗口初始化前的路径。
- 其余页面查询、收藏／历史／动态等写入，以及公共工具与模型的返回值和异常消费。

## 验证范围

新增关键回归已列入 `tool/run-ci-tests.ps1`。测试使用模拟 HTTP、文件选择器和平台输入，文件保存回归另使用临时目录核对实际字节。Android 图库、真实账号登录、服务器写入、原生播放器、GPU 与窗口行为不由这些模拟测试证明；各次实际运行结果随提交交付记录。

2026-11-09 在 Windows 主机实际执行：

- `pwsh -NoProfile -File tool/run-ci-tests.ps1`：1048 项通过，包含 gRPC 请求契约和本机 WebSocket 连接回归。
- `fvm flutter analyze --no-pub lib/plugin/pl_player lib/pages/danmaku test tool`：无问题。
- `fvm flutter analyze --no-pub lib test tool`：24 条 info，全部位于未修改的 `lib/common/widgets/flutter/` 上游控件副本；没有 error 或 warning。
- 登录、公共错误／搜索／消息、下载、图片、账号和设置／重试分别执行过对应目录或文件的定向回归。完整范围见本页及[测试目录](../../test/README.md)。
- gRPC、消息、弹幕、空间搜索与空间列表组合回归 100 项通过，随后补充状态元数据场景后的 gRPC 请求契约 12 项通过；直播连接、页面与加载组合回归 35 项通过。两组源码和测试的定向分析均无问题。
