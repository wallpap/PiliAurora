# 维护与排障手册

## 修改前

1. 阅读根目录约定和 `doc/README.md`。
2. 执行 `git status --short`、`git diff`，确认并保留已有改动。
3. 从路由或页面入口沿实际 import 阅读：页面 → HTTP/Service → Model → 通用组件/平台插件。
4. 先看同领域测试和诊断代码，再决定最小修改范围。
5. 修改后运行相关测试和静态分析；播放器、直播、窗口、解码器改动还需要说明实测范围。

## 典型链路

### 播放

`lib/pages/video/` → `lib/http/video.dart`/视频模型 → `lib/plugin/pl_player/` → `media_kit` 和平台库。遇到问题时区分地址解析、网络、解码、渲染和窗口阶段；播放器证据入口是 `lib/services/diagnostics/player_diagnostics.dart`，专题资料在 `doc/dev/`。

### 视频弹幕

视频详情/播放器 → 弹幕 API 与解析 → 弹幕状态/渲染。Windows 高密度场景应同时记录编码、分辨率、输出尺寸、弹幕密度、硬件解码状态、构建模式和复现时长。

### 直播

`lib/pages/live_room/` → `lib/http/live.dart` 与 `lib/services/live_stream/` → 直播包解码 → 消息/弹幕 UI。分别排查连接、包解码、历史/未读、渲染和退出清理。

### 下载

`lib/pages/download/` → `lib/services/download/` → `lib/http/download.dart`、响应适配和流式写入 → 本地下载目录。检查权限、磁盘空间、网络重试、回压和任务生命周期。

### 登录与账号

`lib/pages/login/` → `lib/http/login.dart` → `lib/services/account_service.dart`、`lib/utils/accounts/` 和本地存储。任何日志或 issue 都必须脱敏，不得包含 Cookie、Token、二维码或签名信息。

## 诊断入口

- `lib/services/diagnostics/`：播放器、HTTP、进程指标、历史读取、记录保存和脱敏。
- `lib/services/logger.dart`：日志服务。
- `lib/pages/setting/pages/logs.dart`、`lib/pages/log_table/`：设置/日志相关 UI。
- `doc/dev/README.md`：Windows 播放、硬件解码、弹幕、性能和历史实验资料。

## 问题报告至少包含

- 应用版本、Git 提交、构建模式和目标平台；
- 操作系统、设备/显卡、Flutter/JDK 版本；
- 复现步骤、媒体编码/分辨率/清晰度、弹幕密度和复现频率；
- 登录状态、硬件解码状态、网络条件；
- 脱敏后的诊断摘要、时间范围和已排除项；
- 仍未验证的假设。

## 禁止事项

- 不删除测试、降低断言或屏蔽告警来制造通过结果。
- 不直接编辑 protobuf/JNI 生成文件。
- 不把历史实验数据当作当前所有设备的结论。
- 不覆盖用户已有改动，不清理无关产物。
- 不提交账号数据、凭据、签名密钥、媒体文件、DLL/EXE 或未脱敏日志。
