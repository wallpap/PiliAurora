# fix 分支审查说明

日期：2026-10-24。工作目录：PR head 的独立审查 worktree。

目录开始时为空，克隆后从远程最新 `main`（`7b29f73b8d5be089532882aa8e072cb4c80b2290`）创建 `fix`。交付前再次读取远程引用，`main` 未变化。全部修改与提交均在 `fix`；未推送、创建 PR、合并或改写历史。依赖、CI、账号存储格式均未改动。

## 修复与主要文件

| 范围 | 实际变化 | 主要文件（相对仓库根目录） |
| --- | --- | --- |
| P0 TLS | 移除代理和 Debug 模式自动接受无效证书的逻辑；HTTP/1.1、HTTP/2、fallback 使用同一显式设置。保留原有二次确认入口，启用时写入警告。 | `lib/http/init.dart`、`lib/app/bootstrap.dart` |
| P1 错误脱敏 | 账号错误保留方法、主机、端口、路径与状态码，移除查询与 URL 凭据；未知错误、LoadingState 错误字符串和统一提示组件复用 DiagnosticRedactor。补充签名、认证参数、Basic、WebSocket URL 规则及重复脱敏稳定性。日志和异常报告沿原有统一脱敏链路。 | `lib/utils/accounts/account_manager/account_mgr.dart`、`lib/services/diagnostics/redact.dart`、`lib/http/loading_state.dart`、`lib/common/widgets/custom_toast.dart` |
| P1 WebDAV | 默认 HTTPS，严格证书验证且不继承应用调试豁免；保留禁止重定向、Basic Auth、MKCOL/PUT/GET 与连接关闭。仅字面回环地址 127.0.0.1/::1 可逐次确认使用 HTTP；不保存豁免，不放行 LAN、localhost 或相似域名。保存前校验地址与用户名；错误保留安全的 Dio 类型。 | `lib/services/settings/webdav_client.dart`、`lib/pages/webdav/webdav.dart`、`lib/pages/webdav/view.dart` |
| P1 下载 | entry/index JSON 在同目录临时文件 flush/close 后替换，保留经过模型结构校验的旧副本；启动按正式文件、备份、临时文件恢复。未完成进度按媒体实际长度恢复。开始、取消、完成串行协调；完成保存失败不移出队列。续传拒绝不匹配范围，核对完成长度，网络失败保留已有文件。 | `lib/services/download/download_repository.dart`、`download_service.dart`、`download_manager.dart` |
| P2 Windows | 最小化/隐藏时通过现有 TickerMode 停止弹幕帧调度、直播显示订阅和图片显示工作；点播释放活动显示引用，恢复后按媒体时间准备。失焦但可见的小窗继续显示。关闭阶段独立报告失败并继续释放，IPC 关闭有超时。 | `lib/app/desktop_theme.dart`、`lib/pages/danmaku/window_screen.dart`、`live_layer.dart`、`lib/services/desktop_playback_windows.dart` |

## 提交记录

按领域提交，可分别审查；同一领域的后续提交依赖其首轮修复，整体回滚该领域时按逆序处理。

- `3236e77` TLS 默认验证与代理一致性。
- `aa30d8f` 网络错误与统一提示脱敏。
- `5b79186` WebDAV HTTPS 与逐次回环授权。
- `e1adf92` 下载 JSON 替换、恢复与进度处理。
- `20dfbe6` Windows 隐藏视觉工作与关闭清理。
- `02b552c` 下载结构校验、终态串行与续传完整性。
- `6f0efd1` 重复脱敏稳定性。
- `c8aee73` WebDAV 安全错误类别与回环边界用例。

## 验证证据与限制

已阅读仓库指令、相关文档和调用链，并完成逐领域差异审查。`git diff --check main..fix` 无输出；交付前工作区无未提交文件。此证据仅证明源码审查和差异检查完成。

已运行涉及文件的 `fvm flutter analyze --no-pub`，无问题；已运行定向回归测试，覆盖 `test/services/diagnostics/redact_test.dart`、`test/services/settings/webdav_client_test.dart`、`webdav_sync_test.dart`、`test/services/download/download_repository_test.dart`、`download_manager_test.dart` 和 `test/app/desktop_theme_test.dart`，全部通过。仍未运行应用构建、打包或设备探针。

仍需验证的实际边界：

- TLS 的真实 HTTP/1.1、HTTP/2、代理握手与有效/无效证书矩阵；显式禁用验证设置仍保留，仅供受控调试。
- WebDAV 历史远程 HTTP 配置仍保留，但请求会被拒绝，需用户配置 HTTPS；本机 HTTP 例外仍是明文。自签证书需建立可信证书链，不通过应用调试开关绕过。
- 文件替换依赖底层文件系统的同目录重命名语义。Windows 文件占用会报告保存失败并保留旧记录；Android 外置存储和突然断电尚未验证。没有跨文件事务或目录 fsync 保证；`.bak`/`.tmp` 是有界恢复副本，不删除媒体文件。
- Windows 任意窗口完全遮挡没有可靠信号，未引入轮询检测；inactive 不能当作遮挡。原生视频解码/纹理输出沿用既有实现，未改画质或音频策略。CPU/GPU 收益、多窗口恢复、音频连续性及关闭行为尚未做实机验证；用户原有“最小化暂停”设置继续生效。

## 后续 CI 建议（本轮未实施）

现有 checks 工作流在 Ubuntu 上运行，analyze 主要覆盖播放器、弹幕、test 与 tool。后续独立任务可：

1. 将本轮涉及的 HTTP、诊断、WebDAV、下载与 app 文件加入定向 analyzer 范围。
2. 显式纳入新增安全与持久化用例；TLS 使用本机测试证书与代理，WebDAV 覆盖 HTTPS→HTTP/跨域跳转拒绝。
3. 增加小范围 Windows job 验证文件替换/占用失败，以及窗口最小化、隐藏、恢复和清理异常；保留单独的设备验收任务检查多窗口音频与 GPU 行为。
4. 在隔离临时目录注入截断文件、替换失败、取消与完成交错；不接触真实下载目录，不以全量构建代替这些定向检查。
