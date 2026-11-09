# 请求账号与 Cookie 拦截器

[`AccountManager`](account_mgr.dart) 是应用的 Dio 拦截器，负责给请求绑定账号、补充认证信息，并将响应 Cookie 保存到发起请求的账号。实现改编自 `dio_cookie_manager`，保留原 [MIT 许可证](LICENSE)。

## 账号绑定

请求显式传入 `RequestOptions.extra['account']` 时使用该账号；否则按 `ApiType` 的接口分类选择账号，登录接口使用匿名账号，其余未分类接口使用主账号。选定的账号保存在请求的 `extra` 中，响应和错误处理复用这份绑定，避免途中切换账号后把 Cookie 写入另一账号。

`NoAccount`、屏蔽服务和部分图片域名跳过认证处理。未登录账号的播放心跳请求会被取消。

## 请求与响应

- Web 请求合并已有 Cookie 头与账号 CookieJar 中的 Cookie，并按路径长度排序。
- App 字节响应请求使用账号的 gRPC 请求头；其他 App 请求按条件加入 access key 并重新签名。
- Web 响应中的 `Set-Cookie` 写入绑定账号的 CookieJar。3xx 响应含 `Location` 时，也处理解析后的目标 URI，随后调用 `account.onChange()`。
- 错误响应含 Cookie 时同样尝试保存；流式请求错误直接向后传递。提示逻辑位于 `toast()` 和 `dioError()`。

成功响应的 Cookie 保存失败时，请求 Future 返回包装 `AccountCookiePersistenceException` 的 DioException，保留响应、原始原因和堆栈，不会因此重放远端请求。原始 HTTP 请求已经失败时，Cookie 保存失败只记录类型和位置，调用方仍收到原 HTTP 状态与错误。

自动重试默认只用于 GET、HEAD 和 OPTIONS。gRPC 的 POST 读取通过 `extra['noRetry'] = false` 显式选择重试；普通写请求、明确禁用重试的请求和流式请求不自动重放。解析错误和程序错误也不作为瞬时网络错误重试。回归见 `test/utils/accounts/cookie_failure_test.dart` 和 `test/http/retry_interceptor_test.dart`。

请求层的创建和重试入口见 [`lib/http/init.dart`](../../../http/init.dart)；账号选择规则见 [`api_type.dart`](../api_type.dart)。消息业务在此基础上显式绑定 Session 账号，并检查旧 Session 的查询结果是否仍有效，详见[消息模块](../../../services/messaging/README.md)。

修改认证或响应处理时，应分别检查 Web、App/gRPC、匿名请求和账号切换。问题记录保留接口类型、操作顺序与脱敏错误，移除 Cookie、access key 和完整账号数据。
